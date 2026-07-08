```@meta
CurrentModule = ModelManager
```

# [Building a Simulator Backend](@id building_a_simulator)

This is the guide for the audience ModelManager exists to serve: developers writing a Julia
package that drives a particular simulator. You implement one interface — [`AbstractSimulator`](@ref) —
and ModelManager provides the trial hierarchy, variations, database, runner, sensitivity
analysis, and calibration on top of it.

[PhysiCellModelManager.jl](https://github.com/drbergman-lab/PhysiCellModelManager.jl) is the
reference implementation; this page describes the contract it (and your package) fulfills.

## The big picture

```
Arrows point from caller to callee (X ──▶ Y means "X calls Y").

You define one concrete type and implement a handful of methods on it:

  MySimulator <: AbstractSimulator

ModelManager calls your methods at the right moments during a run:

  runner                ──▶  runSimulation(sim, spec)     dispatch each pending simulation
  prepareTrialHierarchy ──▶  setupSampling / setupMonad   prepare before running
  database + versioning ──▶  simulatorVersion* methods    schema + version tracking
  migration framework   ──▶  upgrade* methods             schema migrations

You call ModelManager once, at load time, to wire everything up:

  __init__ (sets mm_globals_ref) ──▶  initializeModelManager
```

You supply a concrete type and a handful of methods; ModelManager calls them at the right
moments. Anything you do **not** override falls back to a sensible default (no-op or error,
depending on whether the method is optional or required).

## 1. Define the simulator type

```julia
using ModelManager

mutable struct MySimulator <: AbstractSimulator
    dir::String
    version::VersionNumber
    # ...any state your backend needs
end
```

## 2. Register globals in `__init__`

ModelManager keeps all per-project state in a [`ModelManagerGlobals`](@ref) accessed through
[`mm_globals`](@ref). Your package creates the instance and stores it in
[`mm_globals_ref`](@ref) when it loads:

```julia
function __init__()
    ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = MySimulator("/path", v"0.1.0"))
end
```

## 3. Provide an initialization entry point

Expose a function your users call to open a project. Do any backend-specific validation, then
delegate to [`initializeModelManager`](@ref), which opens the database, resolves/migrates the
version, parses `inputs.toml`, builds the schema, and launches diagnostics:

```julia
function initializeMyProject(path_to_data::AbstractString)
    # ...validate paths, set simulator-specific globals...
    return initializeModelManager(simulator(), path_to_data)
end
```

## 4. Implement the required interface

These methods have no default — ModelManager errors if they are called and not implemented.
Dispatch each on your concrete type.

### Running a simulation

```julia
ModelManager.runSimulation(sim::MySimulator, spec::SimulationSpec)::SimulationProcess
```

The workhorse. Called by the [runner](@ref "Running simulations") inside a task for each pending
simulation. Setup has already happened (see below), so everything you need is in the
[`SimulationSpec`](@ref). Return a [`SimulationProcess`](@ref) describing the outcome. No
keyword arguments — encode all per-simulation configuration in `spec`.

### Setup hooks

```julia
ModelManager.setupSampling(sim::MySimulator, S::AbstractSampling; kwargs...)::Bool
ModelManager.setupMonad(sim::MySimulator, M::AbstractMonad; kwargs...)::Bool
```

Called by [`prepareTrialHierarchy`](@ref) before any simulation runs. `setupSampling` runs
once per unique input-folder group (typically: compile shared custom code); `setupMonad`
prepares each monad's varied input folders. Both return `true`/`false` for success. They
accept the abstract types so they work for a bare `Simulation` or `Monad` without a wrapping
object.

### Simulator metadata and versioning

```julia
ModelManager.simulatorDir(sim::MySimulator)::String
ModelManager.simulatorInfo(sim::MySimulator)::String
ModelManager.simulatorVersionSchema(sim::MySimulator)::String
ModelManager.simulatorVersionIDName(sim::MySimulator)::String      # e.g. "my_version_id"
ModelManager.simulatorVersionTableName(sim::MySimulator)::String   # e.g. "my_versions"
ModelManager.resolveSimulatorVersionID(sim::MySimulator)::Int
ModelManager.currentSimulatorVersionID(sim::MySimulator)::Int
```

These let ModelManager build the database schema (one version table and one version-FK column
per simulator) and stamp every simulation with the simulator version that produced it.

### Variation row writing

```julia
ModelManager.addVariationRows(sim::MySimulator, inputs, reference_variation_id, loc_dicts)::Vector{VariationID}
```

Given the variation combinations ModelManager has computed, write them into the per-location
variations databases and return the resulting [`VariationID`](@ref)s. This is where your
backend's knowledge of the input-file format lives.

### Database migration interface

To support schema upgrades as your package evolves:

```julia
ModelManager.packageName(sim::MySimulator)::String                 # e.g. "MyModelManager"
ModelManager.dbVersionTableName(sim::MySimulator)::String          # e.g. "my_version"
ModelManager.upgradeMilestones(sim::MySimulator)::Vector{VersionNumber}
ModelManager.upgradeToMilestone(sim::MySimulator, version, auto_upgrade)::Bool
```

See [Database upgrades](@ref) for how these are orchestrated by [`upgradePackage`](@ref).

## 5. Override optional hooks as needed

These have working defaults; override only when your simulator needs them.

| Method | Default | Override to… |
| --- | --- | --- |
| [`postInitDisplay`](@ref) | prints generic fields | prepend a logo/version banner |
| [`centralDBFileName`](@ref) | `"mm.db"` | use a custom database filename |
| [`postSimulationProcessing`](@ref) | no-op | **non-destructive** processing after each run, *before* the user `post_processor` (e.g. standardize output the user will read) |
| [`postSimulationCleanup`](@ref) | no-op | **destructive** cleanup/pruning after each run, *after* the user `post_processor` (so the callback sees the intact output) |
| [`initializeInputFolder`](@ref) | no-op | compile a template into a new input folder |
| [`getInputFolderDescription`](@ref) | `""` | read folder metadata for the DB |
| [`clearSimulatorArtifacts`](@ref) | no-op | remove compiled artifacts on database reset |

## Boundary rules

- **`location` is explicit.** ModelManager does not resolve a variation target to a project
  location — your package must pass `location` when constructing variations (or provide
  convenience constructors that infer it). See [Variations](@ref).
- **No simulator specifics leak into ModelManager.** If you find yourself wanting ModelManager
  to know something about your simulator, that knowledge belongs behind one of these interface
  methods — add or override a hook rather than special-casing the core.

For the exact signatures and contracts of every method, see the
[AbstractSimulator interface](@ref) API reference.
