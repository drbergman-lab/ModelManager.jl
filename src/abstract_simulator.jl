"""
    AbstractSimulator

Abstract supertype for simulator backends.

Concrete subtypes are responsible for preparing and executing a single simulation
via the [`runSimulation`](@ref) dispatch, and for providing simulator-specific
metadata (version schema, display info, etc.).

This is the primary extension point for using the ModelManager infrastructure with
any simulator. To support a new simulator:
1. Define `MySimulator <: AbstractSimulator`
2. Implement the required interface methods listed below

# Required interface methods
- [`runSimulation`](@ref)`(::MySimulator, spec::SimulationSpec)::SimulationProcess`
- [`simulatorDir`](@ref)`(::MySimulator)::String`
- [`simulatorVersionSchema`](@ref)`(::MySimulator)::String`
- [`simulatorVersionIDName`](@ref)`(::MySimulator)::String`
- [`simulatorVersionTableName`](@ref)`(::MySimulator)::String`
- [`resolveSimulatorVersionID`](@ref)`(::MySimulator)::Int`
- [`currentSimulatorVersionID`](@ref)`(::MySimulator)::Int`
- [`simulatorInfo`](@ref)`(::MySimulator)::String`
- [`setupMonad`](@ref)`(::MySimulator, M::AbstractMonad; kwargs...)::Bool`
- [`setupSampling`](@ref)`(::MySimulator, S::AbstractSampling; kwargs...)::Bool`
- [`addVariationRows`](@ref)`(::MySimulator, inputs, reference_variation_id, loc_dicts)::Vector{VariationID}`

Note: `variationLocation` is **not** part of the ModelManager interface.  The calling
framework (e.g. PhysiCellModelManager) is responsible for resolving variation targets
to their locations before constructing variation objects — the `location::Symbol` argument
must be passed explicitly when constructing [`DiscreteVariation`](@ref) or
[`DistributedVariation`](@ref).
"""
abstract type AbstractSimulator end

########################################################
############   Required interface methods   ############
########################################################

"""
    runSimulation(::AbstractSimulator, spec::SimulationSpec) -> SimulationProcess

Launch the simulation described by `spec` on the active simulator and return a
[`SimulationProcess`](@ref) describing the outcome.

This is the simulator-dispatched workhorse called by [`run`](@ref) inside each `@task`.
Each simulator package implements its own method dispatching on `AbstractSimulator`.
Setup (compilation, varied input folders) is always performed by
[`prepareTrialHierarchy`](@ref) before this function is called, so implementations
can assume the monad is fully prepared. No kwargs are accepted — all per-simulation
configuration is encoded in `spec`.
"""
function runSimulation(sim::AbstractSimulator, args...)
    error("$(nameof(typeof(sim))) must implement: runSimulation(::$(nameof(typeof(sim))), spec::SimulationSpec)")
end

"""
    simulatorDir(sim::AbstractSimulator)::String

Return the path to the simulator's root directory.
"""
function simulatorDir(sim::AbstractSimulator)
    error("$(nameof(typeof(sim))) must implement: simulatorDir(::$(nameof(typeof(sim))))::String")
end

"""
    simulatorVersionSchema(sim::AbstractSimulator)::String

Return the SQL sub-schema (as a `String`) for the simulator version table.
Used when initializing the database.
"""
function simulatorVersionSchema(sim::AbstractSimulator)
    error("$(nameof(typeof(sim))) must implement: simulatorVersionSchema(::$(nameof(typeof(sim))))::String")
end

"""
    simulatorVersionIDName(sim::AbstractSimulator)::String

Return the SQL column name used for the simulator version FK in the `simulations`,
`monads`, and `samplings` tables (e.g. `"physicell_version_id"`).
"""
function simulatorVersionIDName(sim::AbstractSimulator)
    error("$(nameof(typeof(sim))) must implement: simulatorVersionIDName(::$(nameof(typeof(sim))))::String")
end

"""
    simulatorVersionTableName(sim::AbstractSimulator)::String

Return the name of the simulator version table in the database
(e.g. `"physicell_versions"`).
"""
function simulatorVersionTableName(sim::AbstractSimulator)
    error("$(nameof(typeof(sim))) must implement: simulatorVersionTableName(::$(nameof(typeof(sim))))::String")
end

"""
    resolveSimulatorVersionID(sim::AbstractSimulator)::Int

Resolve the current simulator version against the database, inserting a new row if
necessary. Returns the resolved integer version ID.
"""
function resolveSimulatorVersionID(sim::AbstractSimulator)
    error("$(nameof(typeof(sim))) must implement: resolveSimulatorVersionID(::$(nameof(typeof(sim))))::Int")
end

"""
    currentSimulatorVersionID(sim::AbstractSimulator)::Int

Return the integer row ID of the currently active simulator version.
"""
function currentSimulatorVersionID(sim::AbstractSimulator)
    error("$(nameof(typeof(sim))) must implement: currentSimulatorVersionID(::$(nameof(typeof(sim))))::Int")
end

"""
    simulatorInfo(sim::AbstractSimulator)::String

Return a human-readable string describing the current simulator version.
"""
function simulatorInfo(sim::AbstractSimulator)
    error("$(nameof(typeof(sim))) must implement: simulatorInfo(::$(nameof(typeof(sim))))::String")
end

"""
    postInitDisplay(sim::AbstractSimulator)

Print initialization information. The default implementation prints the generic
ModelManager fields (data directory, database path, inputs config, HPC status,
parallelism). Simulator packages can specialize this method to prepend a logo,
version banner, and simulator-specific fields.
"""
function postInitDisplay(::AbstractSimulator)
    println(rpad("Path to data:", 25, ' ') * dataDir())
    println(rpad("Path to database:", 25, ' ') * centralDB().file)
    println(rpad("Path to inputs.toml:", 25, ' ') * pathToInputsConfig())
    println(rpad("Running on HPC:", 25, ' ') * string(mm_globals().run_on_hpc))
    println(rpad("Max parallel sims:", 25, ' ') * string(mm_globals().max_number_of_parallel_simulations))
end

"""
    centralDBFileName(sim::AbstractSimulator)::String

Return the filename (not full path) of the central SQLite database for this simulator.
The file will be created inside `dataDir()`.  The default is `"mm.db"`.  Simulator
packages can override this to use a different name or implement legacy-name detection.
"""
centralDBFileName(::AbstractSimulator) = "mm.db"

"""
    setupMonad(sim::AbstractSimulator, M::AbstractMonad; kwargs...)::Bool

Perform monad-level setup (prepare varied input folders, etc.) for `M`. Called by
[`prepareTrialHierarchy`](@ref) after [`setupSampling`](@ref) has already run for
the enclosing sampling or directly for the monad. Return `true` on success, `false`
on failure.

Accepts `AbstractMonad` so it handles both `Simulation` and `Monad` inputs without
requiring a wrapping `Sampling` to be created.
"""
function setupMonad(sim::AbstractSimulator, args...; kwargs...)
    error("$(nameof(typeof(sim))) must implement: setupMonad(::$(nameof(typeof(sim))), M::AbstractMonad; kwargs...)::Bool")
end

"""
    setupSampling(sim::AbstractSimulator, S::AbstractSampling; kwargs...)::Bool

Perform sampling-level setup (typically: compile the shared custom code once for all
monads sharing the same `InputFolders`). Called once per unique input-folder group
by [`prepareTrialHierarchy`](@ref). Return `true` on success, `false` on failure.

Accepts `AbstractSampling` so it can be called on a `Simulation`, `Monad`, or
`Sampling` without requiring a wrapping object to be created.
"""
function setupSampling(sim::AbstractSimulator, args...; kwargs...)
    error("$(nameof(typeof(sim))) must implement: setupSampling(::$(nameof(typeof(sim))), S::AbstractSampling; kwargs...)::Bool")
end

########################################################
############   Database upgrade interface   ############
########################################################

"""
    packageName(sim::AbstractSimulator)::String

Return the registered Julia package name for this simulator framework
(e.g. `"PhysiCellModelManager"`). Used by [`getPackageVersion`](@ref) to look up
the runtime version via `Pkg`.
"""
function packageName(sim::AbstractSimulator)
    error("$(nameof(typeof(sim))) must implement: packageName(::$(nameof(typeof(sim))))::String")
end

"""
    dbVersionTableName(sim::AbstractSimulator)::String

Return the name of the SQLite table used to persist the package version in the
project database (e.g. `"pcmm_version"`). The generic upgrade machinery reads and
writes this table to track which version a given database was last migrated to.
"""
function dbVersionTableName(sim::AbstractSimulator)
    error("$(nameof(typeof(sim))) must implement: dbVersionTableName(::$(nameof(typeof(sim))))::String")
end

"""
    upgradeMilestones(sim::AbstractSimulator)::Vector{VersionNumber}

Return a **sorted** vector of milestone `VersionNumber`s that have associated
database schema changes. [`upgradeToMilestone`](@ref) is called for each milestone
between the current database version and the target package version.
"""
function upgradeMilestones(sim::AbstractSimulator)
    error("$(nameof(typeof(sim))) must implement: upgradeMilestones(::$(nameof(typeof(sim))))::Vector{VersionNumber}")
end

"""
    upgradeToMilestone(sim::AbstractSimulator, version::VersionNumber, auto_upgrade::Bool)::Bool

Apply the database schema migration required to bring the project database up to
`version`. Called by [`upgradePackage`](@ref) for each milestone that needs to be
crossed. Return `true` on success, `false` to abort the upgrade chain.

Implementations are responsible for:
1. Prompting the user (when `auto_upgrade` is `false`) for any large/destructive migrations.
2. Making all necessary DDL/DML changes to the database.
3. **Not** updating the version table — [`upgradePackage`](@ref) does that after a
   successful return.
"""
function upgradeToMilestone(sim::AbstractSimulator, args...)
    error("$(nameof(typeof(sim))) must implement: upgradeToMilestone(::$(nameof(typeof(sim))), version::VersionNumber, auto_upgrade::Bool)::Bool")
end

########################################################
############   Post-simulation processing   ############
########################################################

"""
    postSimulationProcessing(sim::AbstractSimulator, simulation_process; kwargs...)

Perform any simulator-specific work immediately after a simulation finishes.

Called by [`processSimulationTask`](@ref) for every completed simulation.
The default implementation is a no-op; simulator packages override this to
clean up error files, prune output, log diagnostics, etc.

Common keyword arguments (simulator-defined):
- `prune_options` — options controlling which output files to delete
  (used by `PhysiCellModelManager`).
"""
function postSimulationProcessing(sim::AbstractSimulator, simulation_process; kwargs...) end

########################################################
############   Input folder initialization  ############
########################################################

"""
    initializeInputFolder(sim::AbstractSimulator, input_folder)

Perform any simulator-specific initialization for a newly-inserted input folder.

Called by [`insertFolder`](@ref) after the folder row has been written to the
database and the per-folder variations SQLite database has been created.
The default implementation is a no-op.

Implementations may, for example, compile an initial XML parameter file from a
template, create derived assets, etc.
"""
function initializeInputFolder(sim::AbstractSimulator, input_folder) end

"""
    getInputFolderDescription(sim::AbstractSimulator, path_to_folder::String)::String

Return a human-readable description for the input folder at `path_to_folder`.

Called by [`insertFolder`](@ref) when inserting a new folder into the database.
The default implementation returns `""`.  Simulator packages may override this
to read metadata from a file in the folder (e.g. a `metadata.xml` or TOML file).
"""
getInputFolderDescription(sim::AbstractSimulator, path_to_folder::String) = ""

########################################################
############   Simulator-specific utilities  ###########
########################################################

"""
    clearSimulatorArtifacts(sim::AbstractSimulator)

Remove all simulator-generated build artifacts from input folders during a
database reset. The default implementation is a no-op.

Called by [`resetDatabase`](@ref) after all output folders have been deleted.
Implementations should remove compiled executables, object files, and any other
files generated by the simulator that do not belong to the base inputs.
"""
function clearSimulatorArtifacts(sim::AbstractSimulator) end

