```@meta
CurrentModule = ModelManager
```

# [Post-processing and quantities of interest](@id post_processing)

A campaign is only useful if you can get numbers out of it. ModelManager lets you attach a
`post_processor` callback to [`run`](@ref): a function invoked once per successfully completed
simulation, whose return value is stored in a per-project sink and read back later as a table.

Use it for anything you want computed *while the output is still on disk* — final cell counts,
time to extinction, fit residuals, summary statistics — and for side effects such as writing
your own reduced-output files before a backend prunes the raw output.

## Where your callback runs

After each simulation completes, ModelManager runs three steps in order:

1. the backend's [`postSimulationProcessing`](@ref) hook — simulator-specific,
   **non-destructive** work (e.g. standardizing output);
2. your `post_processor` — invoked once per **successfully completed** simulation;
3. the backend's [`postSimulationCleanup`](@ref) hook — simulator-specific, **destructive**
   cleanup/pruning.

Because your callback runs *before* cleanup, it always sees the intact (but processed) output
folder:

```julia
run(sampling; post_processor = sp -> (; final_count = countCells(simulationID(sp))))
```

## The callback signature

The callback receives a [`SimulationProcess`](@ref). Use the accessors
[`simulationID`](@ref), [`monadID`](@ref), [`wasSuccessful`](@ref), and
[`pathToOutputFolder`](@ref)`(sp)` rather than reaching into its fields. Reading the actual
simulation output into usable data is the backend's job — expect your simulator package to
provide loaders keyed by `simulationID`.

## What to return

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

## Reading the quantities back

Read the collected quantities with [`postProcessingTable`](@ref) (or
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

Quantities and [tags](@ref tagging) are both keyed by
`simulation_id`, so a recovery query can join them:

```julia
ids = findSimulationIDs(tags = ("project" => "immune-escape",), status = "Completed")
innerjoin(simulationsTable(ids; tags = true), postProcessingTable(ids), on = :SimID)
```

## Lifecycle and error handling

The sink stays consistent with the central database: deleting simulations (see
[Managing data](@ref managing_data)) removes their sink rows, and [`resetDatabase`](@ref) removes the sink
entirely.

If your `post_processor` (or a simulator hook) throws, `run` **fails fast** — it rethrows a
clear error naming the stage (`post_processor` vs. a simulator hook) and the simulation, with
the original stacktrace. It never hangs or silently swallows the exception, so a typo or a
bad assumption in a callback surfaces immediately rather than parking a long HPC campaign.

For the storage layer itself (schema, [`postProcessingDBPath`](@ref)) see
[The database](@ref database). For the runner API around the callback
([`SimulationProcess`](@ref), [`SimulationSpec`](@ref)), see the [Runner](@ref) reference.
