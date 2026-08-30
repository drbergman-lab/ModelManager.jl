using Parameters, SQLite

export ModelManagerGlobals, mm_globals_ref, mm_globals
export centralDB, dataDir, isInitialized, assertInitialized
export projectLocations, inputsDict, simulator
export initializeModelManager, waitForDiagnostics

"""
    ModelManagerGlobals

Mutable struct holding all global state for a ModelManager project.

The active instance is accessed via [`mm_globals`](@ref).  Concrete simulator
packages (e.g. `PhysiCellModelManager`) create an instance of this struct and
register it via [`mm_globals_ref`](@ref) in their `__init__`.

# Fields
- `initialized::Bool`: `true` after [`initializeModelManager`](@ref) succeeds.
- `data_dir::String`: Absolute path to the project `data/` directory.
- `simulator::AbstractSimulator`: The active simulator backend.
- `inputs_dict::Dict{Symbol,Any}`: Parsed contents of `inputs.toml`.
- `project_locations::ProjectLocations`: Derived from `inputs_dict`.
- `db::SQLite.DB`: Connection to the central project database.
- `run_on_hpc::Bool`: `true` to submit simulations as SLURM jobs and to route file removal
  through the staging path of [`rm_hpc_safe`](@ref). [`initializeModelManager`](@ref) sets it
  from [`isRunningOnHPC`](@ref) on every call; override afterwards with [`useHPC`](@ref).
- `sbatch_options::Dict{String,Any}`: Options forwarded to `sbatch`.
- `max_number_of_parallel_simulations::Int`: Concurrency limit.
- `diagnostics_task::Union{Nothing,Task}`: The background `Task` running
  `databaseDiagnostics`, set by [`initializeModelManager`](@ref).
  `nothing` before initialization or if diagnostics have not been launched.
  Use [`waitForDiagnostics`](@ref) to block until it completes.
- `provenance_id::Union{Nothing,Int}`: Row in `provenances` describing the current
  creation context (session, launching script, git state). Re-resolved on entry to
  `createTrial` and `run`, and stamped onto the objects they create.
- `session_id::String`: Random per-session identifier recorded as `mm:session`.
  Assigned lazily on first use.
- `tag_hints::Bool`: Whether to show the one-time tagging hints. See
  [`setTagHints!`](@ref).
- `tag_hint_shown::Bool`, `tag_recovery_hint_shown::Bool`: Once-per-session latches
  for those hints.
- `trash_staged_warning_shown::Bool`: Once-per-project latch for the warning
  [`rm_hpc_safe`](@ref) issues when a shared filesystem forces it to stage a path in
  `data/.trash/` instead of removing it. Its `:unremoved` case — where it can do neither — is
  deliberately not latched, since each occurrence names a different leaked path.
- `last_trash_sweep::String`: `yymmdd` stamp of the day `data/.trash/` was last swept, so a
  session that outlives a single day re-sweeps instead of relying on the one at startup.
"""
@with_kw mutable struct ModelManagerGlobals
    initialized::Bool = false

    data_dir::String = ""
    simulator::AbstractSimulator  # required; provided by the simulator package

    inputs_dict::Dict{Symbol,Any} = Dict{Symbol,Any}()
    project_locations::ProjectLocations = ProjectLocations(inputs_dict)

    db::SQLite.DB = SQLite.DB()

    run_on_hpc::Bool = false
    sbatch_options::Dict{String,Any} = defaultJobOptions()

    max_number_of_parallel_simulations::Int = 1

    diagnostics_task::Union{Nothing,Task} = nothing

    provenance_id::Union{Nothing,Int} = nothing
    session_id::String = ""
    tag_hints::Bool = true
    tag_hint_shown::Bool = false
    tag_recovery_hint_shown::Bool = false
    trash_staged_warning_shown::Bool = false
    last_trash_sweep::String = ""
end

"""
    mm_globals_ref

Module-level `Ref` holding the active [`ModelManagerGlobals`](@ref) instance.

Set by the concrete simulator package in its `__init__`, e.g.:
```julia
function __init__()
    ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = MySimulator(), ...)
end
```
"""
const mm_globals_ref = Ref{Union{Nothing,ModelManagerGlobals}}(nothing)

"""
    mm_globals()::ModelManagerGlobals

Return the active [`ModelManagerGlobals`](@ref) instance.

Throws an assertion error if no simulator package has registered its globals yet.
"""
function mm_globals()::ModelManagerGlobals
    g = mm_globals_ref[]
    @assert !isnothing(g) "ModelManager globals not initialized. Make sure a simulator package (e.g. PhysiCellModelManager) is loaded and has called initializeModelManager."
    return g
end

"""
    centralDB()

Return the central `SQLite.DB` connection for the current project.
"""
centralDB() = mm_globals().db

"""
    dataDir()

Return the path to the current project's `data/` directory.
"""
dataDir() = mm_globals().data_dir

"""
    isInitialized()

Return `true` if the model manager has been successfully initialized.
"""
isInitialized() = mm_globals().initialized

"""
    projectLocations()

Return the [`ProjectLocations`](@ref) for the current project.
"""
projectLocations() = mm_globals().project_locations

"""
    inputsDict()

Return the parsed `inputs.toml` dictionary for the current project.
"""
inputsDict() = mm_globals().inputs_dict

"""
    simulator()

Return the active [`AbstractSimulator`](@ref) backend.
"""
simulator() = mm_globals().simulator

"""
    simulatorVersionIDName()

Return the SQL column name used for the simulator version FK.
Delegates to [`simulatorVersionIDName(sim)`](@ref) on the active simulator.
"""
simulatorVersionIDName() = simulatorVersionIDName(mm_globals().simulator)

"""
    currentSimulatorVersionID()

Return the current simulator version row ID from the database.
Delegates to [`currentSimulatorVersionID(sim)`](@ref) on the active simulator.
"""
currentSimulatorVersionID() = currentSimulatorVersionID(mm_globals().simulator)

"""
    assertInitialized()

Assert that the model manager has been initialized, throwing an informative error if not.
"""
function assertInitialized()
    @assert isInitialized() "The model manager has not been initialized for a project. Please run `initializeModelManager` first."
end

#! Every early return from `initializeModelManager` funnels through here. `initialized` is already
#! cleared on entry, so clearing it again is belt-and-braces; the reset that matters here is
#! dropping `data_dir` and the connection, so a later query cannot read a half-configured project.
function _abortInitialization()
    close(centralDB())
    mm_globals().db = SQLite.DB()
    mm_globals().data_dir = ""
    mm_globals().initialized = false
    return false
end

"""
    initializeModelManager(simulator::AbstractSimulator, data_dir::AbstractString; auto_upgrade::Bool=false)

Initialize ModelManager for a project rooted at `data_dir` using `simulator` as the
concrete backend.

This is the generic entry point that simulator packages (e.g. PhysiCellModelManager)
call from their own path-level overloads after setting any simulator-specific fields.
It performs all framework-agnostic initialization steps in order:

1. Register `simulator` and `data_dir` on the active [`ModelManagerGlobals`](@ref).
2. Open the central SQLite database (filename determined by [`centralDBFileName`](@ref)).
3. Resolve the package version, creating or upgrading the DB schema if needed.
4. Parse `inputs.toml`.
5. Initialize the database schema (tables, folder registration).
6. Detect whether SLURM is available via [`isRunningOnHPC`](@ref) and store the result in
   `run_on_hpc`. Override it afterwards with [`useHPC`](@ref).
7. Call [`postInitDisplay`](@ref) to print startup information.
8. Launch a background `@async` task that retries the removal of anything
   [`rm_hpc_safe`](@ref) had to stage in `data/.trash/`, then runs `databaseDiagnostics`.

Returns `true` on success, `false` on any initialization failure — including errors that
would otherwise throw (e.g. an unwritable `data_dir`). All mutated globals are reset to
a clean state before any `false` return, so [`isInitialized`](@ref) reports `false` and a
subsequent retry starts fresh.

Simulator packages typically provide their own path-level overloads (e.g. accepting
`path_to_physicell` and `path_to_data`) that validate paths, set simulator-specific
state, then delegate here.

!!! note
    Database diagnostics run in the background and may print after this function returns.
    Call [`waitForDiagnostics`](@ref) if you need them to complete before proceeding.
"""
function initializeModelManager(simulator::AbstractSimulator, data_dir::AbstractString; auto_upgrade::Bool=false)
    # If a previous diagnostics task is still running, let it finish before we
    # mutate shared globals — otherwise it may observe a partially-updated state.
    waitForDiagnostics()
    mm_globals().diagnostics_task = nothing

    mm_globals().simulator = simulator
    mm_globals().data_dir = abspath(normpath(data_dir))

    #! From here until `initializeDatabase` succeeds there is no usable project, so a stale `true`
    #! left over from a previous one must not make `isInitialized()` vouch for this one.
    mm_globals().initialized = false

    #! Provenance, hint, and trash-staging latches are per-project: a new project in the
    #! same session should re-resolve its script/git context, hint again, and warn again
    #! about its own `data/.trash`.
    mm_globals().provenance_id = nothing
    mm_globals().tag_hint_shown = false
    mm_globals().tag_recovery_hint_shown = false
    mm_globals().trash_staged_warning_shown = false
    mm_globals().last_trash_sweep = ""

    try
        mm_globals().db = _openDB(joinpath(mm_globals().data_dir, centralDBFileName(simulator)))
    catch e
        println("Could not open database: $e")
        #! The assignment above never happened, so this closes the *previous* project's
        #! connection — which is correct: that project is being abandoned either way.
        return _abortInitialization()
    end

    #! Reported rather than thrown, so this function keeps its documented contract of returning
    #! `false` on any initialization failure. Version resolution has several throwing paths: the
    #! loaded package can be absent from the active environment (loaded through a stacked
    #! environment, or `Pkg.activate` ran after it was loaded), a version table can hold an
    #! unparsable version, and a backend milestone can throw part-way through a migration.
    #! `println` rather than `@error` to match the database-open failure a few lines above; the
    #! `@warn`/`@error` split belongs to the version diagnostics in `package_version.jl`.
    version_resolved = try
        resolvePackageVersion(simulator, centralDB(); auto_upgrade=auto_upgrade)
    catch e
        println("Could not resolve the package version: $e")
        false
    end
    if !version_resolved
        return _abortInitialization()
    end
    if !parseProjectInputsConfigurationFile()
        return _abortInitialization()
    end
    initializeDatabase()
    if !isInitialized()
        return _abortInitialization()
    end
    #! Detected here, after every failure path has returned, so that `_abortInitialization`
    #! need not know about this field. Still ahead of `postInitDisplay`, which prints it.
    mm_globals().run_on_hpc = isRunningOnHPC()
    postInitDisplay(simulator)
    flush(stdout)
    # Snapshot max IDs now (before any simulations launch) so that diagnostics
    # only check entities that existed at init time and won't be confused by
    # in-progress runs started later in the same session.
    snapshot = _snapshotMaxIDs()
    mm_globals().diagnostics_task = @async begin
        try
            #! Before the report, not after: `databaseDiagnostics` only warns about what is
            #! left in `data/.trash`, so the retry has to have had its turn first.
            _sweepTrash()
            databaseDiagnostics(snapshot)
        catch e
            println("""
            Database diagnostics failed during initialization with error: $(e).
            ModelManager was not able to check the integrity of the database.
            This is unexpected behavior; please report this issue on the ModelManager.jl GitHub page.
            """)
        end
    end
    return isInitialized()
end

"""
    waitForDiagnostics()

Block until the background `databaseDiagnostics` task launched during
[`initializeModelManager`](@ref) completes. Returns immediately if diagnostics
have already finished or were never started.

[`initializeModelManager`](@ref) runs five read-only consistency checks
(DB↔filesystem sync, orphaned entries, constituent ID integrity, simulation status)
in a background task so initialization returns promptly. In interactive sessions the
diagnostics typically finish during the first idle moment. In scripts and HPC jobs
the task runs opportunistically during I/O-heavy work (e.g. simulation runs); call
`waitForDiagnostics()` explicitly if you need the output before a particular step.

# Example
```julia
initializeModelManager(sim, data_dir)

# Optional: block until database consistency checks have printed their results.
# Useful in scripts that exit quickly or test suites that inspect diagnostic output.
# waitForDiagnostics()

# ... rest of your workflow ...
```
"""
function waitForDiagnostics()
    t = mm_globals().diagnostics_task
    isnothing(t) || wait(t)
    return nothing
end
