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
table always reflects the current state of the campaign.

## Post-processing each simulation

After each simulation completes, ModelManager runs three steps in order:

1. the backend's [`postSimulationProcessing`](@ref) hook — simulator-specific, **non-destructive**
   work (e.g. standardizing output);
2. your `post_processor` — an optional function you pass to `run`, invoked once per
   **successfully completed** simulation;
3. the backend's [`postSimulationCleanup`](@ref) hook — simulator-specific, **destructive**
   cleanup/pruning.

Because your callback runs *before* cleanup, it always sees the intact (but processed) output
folder:

```julia
run(sampling; post_processor = sp -> (; final_count = countCells(simulationID(sp))))
```

The callback receives a [`SimulationProcess`](@ref). Use the accessors
[`simulationID`](@ref), [`monadID`](@ref), [`wasSuccessful`](@ref), and
[`pathToOutputFolder`](@ref)`(sp)` rather than reaching into its fields. Reading the actual
simulation output into usable data is the backend's job — expect your simulator package to
provide loaders keyed by `simulationID`.

The return value decides storage:

- `nothing` → nothing is stored (pure side effects — compute, write files, or clean up however
  you like).
- a `NamedTuple` or `AbstractDict` of `name => scalar` (where each value is a `Real`, `Bool`, or
  `String`) → one row (keyed by `simulation_id`) is upserted into the project's post-processing
  sink at `data/outputs/postprocessing.db`. Columns are added on demand, so a quantity not
  computed for a given simulation reads back as `missing`; re-running overwrites that
  simulation's row. Anything else (including a non-scalar value such as a vector) raises an
  `ArgumentError`.

### Storing nothing (side effects only)

If you only want side effects — writing your own output file, deleting data, logging — return
`nothing` explicitly. This matters: a callback's value is its **last expression**, so a block
that ends with a computation would store that value by accident. End with `return nothing`
(or a bare `nothing`) to store nothing:

```julia
run(sampling; post_processor = function (sp)
    writeCustomSummary(pathToOutputFolder(sp))   # your own file, in the sim's output folder
    return nothing                               # <-- required; without it the summary would be stored
end)
```

### Storing a NamedTuple

The most concise form. Each field becomes a sink column:

```julia
run(sampling; post_processor = sp -> (; final_count = countCells(simulationID(sp)),
                                        mean_speed  = meanCellSpeed(simulationID(sp))))
```

### Storing a Dict

Useful when column names are computed or come from data. Keys are used as column names:

```julia
run(sampling; post_processor = function (sp)
    cells = loadCells(simulationID(sp))          # a loader from your simulator package
    return Dict("n_alive" => countAlive(cells),
                "n_dead"  => countDead(cells))
end)
```

(`countCells`, `meanCellSpeed`, `loadCells`, … are stand-ins for whatever loaders your
simulator package provides — see its documentation.)

Read the collected quantities back with [`postProcessingTable`](@ref) (or
[`printPostProcessingTable`](@ref)); the result is keyed by `:SimID`:

```julia
postProcessingTable(sampling)      # one row per simulation with stored quantities
```

To see the quantities alongside each simulation's parameters, pass `post_processing=true` to
[`simulationsTable`](@ref) — it appends one column per quantity (`missing` where a quantity was
not computed):

```julia
simulationsTable(sampling; post_processing=true)
```

The sink stays consistent with the central database: deleting simulations (see
[Managing data](@ref)) removes their sink rows, and [`resetDatabase`](@ref) removes the sink
entirely.

If your `post_processor` (or a simulator hook) throws, `run` **fails fast** — it rethrows a
clear error naming the stage (`post_processor` vs. a simulator hook) and the simulation, with
the original stacktrace. It never hangs or silently swallows the exception, so a typo or a
bad assumption in a callback surfaces immediately rather than parking a long HPC campaign.

For cluster execution, see [HPC support](@ref). For the complete runner API
([`SimulationSpec`](@ref), [`prepareTrialHierarchy`](@ref), [`pendingSimulationSpecs`](@ref),
[`SimulationProcess`](@ref)), see the [Runner](@ref) reference.
