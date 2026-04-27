using Parameters, SQLite

export ModelManagerGlobals, mm_globals_ref, mm_globals
export centralDB, dataDir, isInitialized, assertInitialized
export projectLocations, inputsDict, simulator
export initializeModelManager

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
- `run_on_hpc::Bool`: `true` when `sbatch` is available (auto-detected).
- `sbatch_options::Dict{String,Any}`: Options forwarded to `sbatch`.
- `max_number_of_parallel_simulations::Int`: Concurrency limit.
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
6. Call [`postInitDisplay`](@ref) to print startup information.
7. Run [`databaseDiagnostics`](@ref).

Returns `true` on success, `false` on any initialization failure — including errors that
would otherwise throw (e.g. an unwritable `data_dir`). All mutated globals are reset to
a clean state before any `false` return so that subsequent retries start fresh.

Simulator packages typically provide their own path-level overloads (e.g. accepting
`path_to_physicell` and `path_to_data`) that validate paths, set simulator-specific
state, then delegate here.
"""
function initializeModelManager(simulator::AbstractSimulator, data_dir::AbstractString; auto_upgrade::Bool=false)
    mm_globals().simulator = simulator
    mm_globals().data_dir = abspath(normpath(data_dir))

    try
        mm_globals().db = SQLite.DB(joinpath(mm_globals().data_dir, centralDBFileName(simulator)))
    catch e
        println("Could not open database: $e")
        mm_globals().data_dir = ""
        return false
    end

    if !resolvePackageVersion(simulator, centralDB(); auto_upgrade=auto_upgrade)
        close(centralDB())
        mm_globals().db = SQLite.DB()
        mm_globals().data_dir = ""
        return false
    end
    if !parseProjectInputsConfigurationFile()
        close(centralDB())
        mm_globals().db = SQLite.DB()
        mm_globals().data_dir = ""
        return false
    end
    initializeDatabase()
    if !isInitialized()
        close(centralDB())
        mm_globals().db = SQLite.DB()
        mm_globals().data_dir = ""
        return false
    end
    postInitDisplay(simulator)
    flush(stdout)
    try
        databaseDiagnostics()
    catch e
        println("""
        Database diagnostics failed during initialization with error: $(e).
        ModelManager was not able to check the integrity of the database.
        This is unexpected behavior; please report this issue on the ModelManager.jl GitHub page.
        """)
    end
    return isInitialized()
end
