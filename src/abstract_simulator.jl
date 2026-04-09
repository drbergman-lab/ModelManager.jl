export AbstractSimulator

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
- [`runSimulation`](@ref)`(::MySimulator, simulation, monad_id; do_full_setup, force_recompile)`
- [`simulatorDir`](@ref)`(::MySimulator)::String`
- [`simulatorVersionSchema`](@ref)`(::MySimulator)::String`
- [`simulatorVersionIDName`](@ref)`(::MySimulator)::String`
- [`simulatorVersionTableName`](@ref)`(::MySimulator)::String`
- [`resolveSimulatorVersionID`](@ref)`(::MySimulator)::Int`
- [`currentSimulatorVersionID`](@ref)`(::MySimulator)::Int`
- [`simulatorInfo`](@ref)`(::MySimulator)::String`
- [`postInitDisplay`](@ref)`(::MySimulator)`
- [`setupMonad`](@ref)`(::MySimulator, monad; force_recompile::Bool)::Bool`
- [`setupSampling`](@ref)`(::MySimulator, sampling; force_recompile::Bool)::Bool`
"""
abstract type AbstractSimulator end

########################################################
############   Required interface methods   ############
########################################################

"""
    runSimulation(sim::AbstractSimulator, simulation, monad_id::Int; do_full_setup::Bool=true, force_recompile::Bool=false)

Prepare inputs for and execute a single simulation using the given simulator backend.

Implementations are responsible for:
1. Preparing any varied input files for this simulation.
2. Compiling / loading custom code (if applicable) when `do_full_setup` is `true`.
3. Executing the simulation (e.g. launching a subprocess, calling a Julia function).
4. Updating the database with the success status.

Return a `SimulationProcess` describing the outcome.
"""
function runSimulation end

"""
    simulatorDir(sim::AbstractSimulator)::String

Return the path to the simulator's root directory.
"""
function simulatorDir end

"""
    simulatorVersionSchema(sim::AbstractSimulator)::String

Return the SQL sub-schema (as a `String`) for the simulator version table.
Used when initializing the database.
"""
function simulatorVersionSchema end

"""
    simulatorVersionIDName(sim::AbstractSimulator)::String

Return the SQL column name used for the simulator version FK in the `simulations`,
`monads`, and `samplings` tables (e.g. `"physicell_version_id"`).
"""
function simulatorVersionIDName end

"""
    simulatorVersionTableName(sim::AbstractSimulator)::String

Return the name of the simulator version table in the database
(e.g. `"physicell_versions"`).
"""
function simulatorVersionTableName end

"""
    resolveSimulatorVersionID(sim::AbstractSimulator)::Int

Resolve the current simulator version against the database, inserting a new row if
necessary. Returns the resolved integer version ID.
"""
function resolveSimulatorVersionID end

"""
    currentSimulatorVersionID(sim::AbstractSimulator)::Int

Return the integer row ID of the currently active simulator version.
"""
function currentSimulatorVersionID end

"""
    simulatorInfo(sim::AbstractSimulator)::String

Return a human-readable string describing the current simulator version.
"""
function simulatorInfo end

"""
    postInitDisplay(sim::AbstractSimulator)

Print simulator-specific information after initialization.
"""
function postInitDisplay end

"""
    setupMonad(sim::AbstractSimulator, monad; force_recompile::Bool=false)::Bool

Perform all monad-level setup (compilation, input folder preparation) before
launching per-simulation tasks. Return `true` on success, `false` on failure.
"""
function setupMonad end

"""
    setupSampling(sim::AbstractSimulator, sampling; force_recompile::Bool=false)::Bool

Perform all sampling-level setup (typically: compile the shared custom code once)
before collecting monad tasks. Return `true` on success, `false` on failure.
"""
function setupSampling end
