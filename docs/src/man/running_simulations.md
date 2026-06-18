```@meta
CurrentModule = ModelManager
```

# Running simulations

Once you have a [trial](@ref "The trial hierarchy"), [`run`](@ref) executes it. The runner is
generic: it prepares the trial, figures out which simulations are still pending, dispatches
them in parallel, and writes results back to the database. The simulator backend only
provides the per-simulation launch via [`runSimulation`](@ref).

## The two-phase run

`run` is split into two phases so that setup happens once and execution can be parallelized:

1. **Preparation** — [`prepareTrialHierarchy`](@ref) compiles shared code and materializes
   varied input folders for the whole trial. It calls the backend's [`setupSampling`](@ref)
   once per unique input-folder group and [`setupMonad`](@ref) for each monad.
2. **Execution** — [`pendingSimulationSpecs`](@ref) returns a
   [`SimulationSpec`](@ref) for every simulation that has not yet completed, and the runner
   launches each one through the backend's [`runSimulation`](@ref) inside its own task.

Because preparation is separated from execution, the backend's `runSimulation` can assume the
monad is fully prepared and receives everything it needs in the `SimulationSpec` — no keyword
arguments are threaded through.

```julia
output = run(inputs, dv; n_replicates=3)     # build + run in one call
# or, equivalently:
trial  = createTrial(inputs, dv; n_replicates=3)
output = run(trial)
```

`run` returns an [`MMOutput`](@ref) wrapping the trial that was executed, which you can pass
straight back into [`createTrial`](@ref)/`run` to build follow-up trials from it.

## Cheap re-runs

The runner only launches **pending** simulations. Because monads are keyed in the database by
their parameterization (see [The database](@ref)), re-running a script reuses everything that
already completed and runs only what is missing. To force fresh runs, set `use_previous=false`
when constructing the trial.

## Parallelism

By default ModelManager runs one simulation at a time. Raise the concurrency with
[`setNumberOfParallelSims`](@ref):

```julia
setNumberOfParallelSims(9)   # up to 9 simulations at once
```

Backends typically also honor an environment variable for this (for example PCMM reads
`PCMM_NUM_PARALLEL_SIMS`) so the limit can be set without changing code:

```sh
PCMM_NUM_PARALLEL_SIMS=9 julia scripts/GenerateData.jl
```

The runner schedules simulations across Julia tasks up to this limit, regardless of which
backend is in use.

## Status tracking

Each simulation moves through the status codes from [`recognizedStatusCodes`](@ref) —
`Not Started` → `Queued`/`Running` → `Completed` or `Failed`. The runner updates these as
work progresses ([`updateDatabaseOnCompletion`](@ref)), so a query against the `simulations`
table always reflects the current state of the campaign. After each simulation finishes, the
backend's [`postSimulationProcessing`](@ref) hook runs for any cleanup or pruning.

For cluster execution, see [HPC support](@ref). For the complete runner API
([`SimulationSpec`](@ref), [`prepareTrialHierarchy`](@ref), [`pendingSimulationSpecs`](@ref),
[`SimulationProcess`](@ref)), see the [Runner](@ref) reference.
