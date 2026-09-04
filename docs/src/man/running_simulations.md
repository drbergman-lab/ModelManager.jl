```@meta
CurrentModule = ModelManager
```

# [Running simulations](@id running_simulations)

Once you have a [trial](@ref trial_hierarchy), [`run`](@ref) executes it. The runner is
generic: it prepares the trial, figures out which simulations are still pending, dispatches
them in parallel, runs each one (locally or as a SLURM job), and writes results back to the
database. The simulator backend only supplies the command via [`simulationCommand`](@ref).

## The two-phase run

`run` is split into two phases so that setup happens once and execution can be parallelized:

1. **Preparation** — the runner compiles shared code and materializes varied input folders for
   the whole trial. It calls the backend's [`setupSampling`](@ref) once per unique
   input-folder group and [`setupMonad`](@ref) for each monad.
2. **Execution** — the runner collects a [`SimulationSpec`](@ref) for every simulation that has
   not yet completed and launches each one inside its own task, asking the backend for the
   command via [`simulationCommand`](@ref) and handling the rest itself: output folder,
   `output.log`/`output.err`, working directory, and local-versus-SLURM dispatch.

Because preparation is separated from execution, the backend's `simulationCommand` can assume the
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

## Batching pre-built trials

If you accumulate trials in a vector, pass the whole vector to `run` (or `createTrial`) to
launch them together as one parallelized batch:

```julia
sims = []
push!(sims, createTrial(inputs, dv1))
push!(sims, createTrial(inputs, dv2))
run(sims)                 # one Trial, one parallel pool across all constituent simulations
```

Elements may be any mix of `Simulation`, `Monad`, `Sampling`, or `Trial` (even in a loosely
typed `Vector{Any}`); they are bundled into a single [`Trial`](@ref), so `run` returns an
`MMOutput{Trial}`. A non-trial element raises an `ArgumentError`.

## [Cheap re-runs](@id cheap_reruns)

The runner only launches **pending** simulations. Because monads are keyed in the database by
their parameterization (see [The database](@ref database)), re-running a script reuses everything that
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
work progresses (`updateDatabaseOnCompletion`), so a query against the `simulations`
table always reflects the current state of the campaign.

Simulations that end in `Failed` are removed from their monad's constituent list, so a failed
parameter set leaves no record of the variation it came from. If failures are showing up
during a calibration, [When things go wrong](@ref calibration_troubleshooting) covers how to
read the per-generation failure files and what `on_monad_failure` does with them.

## After each simulation

When a simulation completes, ModelManager runs the backend's
[`postSimulationProcessing`](@ref) hook, then your optional `post_processor` callback, then
the backend's [`postSimulationCleanup`](@ref) hook. The callback is how you compute and store
quantities of interest from a finished run:

```julia
run(sampling; post_processor = sp -> (; final_count = countCells(simulationID(sp))))
```

See [Post-processing and quantities of interest](@ref post_processing) for the callback
signature, what you may return, and how to read the results back.

For cluster execution, see [HPC support](@ref hpc). For the complete runner API
([`SimulationSpec`](@ref), [`SimulationProcess`](@ref)), see the [Runner](@ref) reference.
