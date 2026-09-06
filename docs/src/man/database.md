```@meta
CurrentModule = ModelManager
```

# [The database](@id database)

ModelManager records every project's structure in a single SQLite database living in the
data directory. The database is the source of truth for what has been run: it is what makes
re-runs cheap, lets you query results, and keeps the trial hierarchy reproducible.

## What the database stores

The schema is generated from the project's [locations](@ref project_configuration), so the
exact columns depend on `inputs.toml`. The core tables are:

- **`simulations`** — one row per [`Simulation`](@ref). Holds the simulator version, one
  input-folder ID per location, one variation ID per varied location, and a status code.
- **`monads`**, **`samplings`**, **`trials`** — the higher levels of the
  [trial hierarchy](@ref trial_hierarchy). Their constituent IDs are stored as compressed
  lists, written by `recordConstituentIDs` and encoded by `compressIDs`.
- **per-location folder tables** (e.g. `configs`) — registered input folders.
- **`<simulator>_versions`** — the simulator's version table (name supplied by the backend
  via [`simulatorVersionTableName`](@ref)).
- **`calibrations`** — calibration runs (see [Calibration](@ref calibration_man)).
- a status-codes table with the values from [`ModelManager.recognizedStatusCodes`](@ref):
  `"Not Started"`, `"Queued"`, `"Running"`, `"Completed"`, `"Failed"`.

Per-folder **variations** are not stored in the central database. Each input folder that
supports variation gets its own small SQLite database (e.g. `config_variations.db`) inside
the folder, reached via [`locationVariationsDatabase`](@ref). This keeps variation rows next
to the inputs they modify. See [Variations](@ref variations).

Likewise, **post-processing quantities of interest** are kept in a separate database,
`data/outputs/postprocessing.db` (path from [`postProcessingDBPath`](@ref)), created lazily
the first time a `post_processor` returns quantities to store. See
[Post-processing and quantities of interest](@ref post_processing).

[`ModelManager.initializeDatabase`](@ref) creates the schema if needed; [`createMMTable`](@ref) and
[`insertFolder`](@ref) are the building blocks backends use to register tables and folders.

## Querying

Most read access goes through a few helpers that return
[`DataFrame`](https://dataframes.juliadata.org/)s:

```julia
# Run an arbitrary query.
df = queryToDataFrame("SELECT * FROM simulations WHERE status_code_id = 5;")

# Build a SELECT against a known table.
q  = constructSelectQuery("monads", "WHERE monad_id = 12;")
df = queryToDataFrame(q)

# Parameterized statements (safe interpolation of values).
df = stmtToDataFrame("SELECT * FROM simulations WHERE config_id = ?;", [3])
```

Useful building blocks:

- [`constructSelectQuery`](@ref) — assemble a `SELECT` with an optional `WHERE`/condition and column selection.
- [`ModelManager.buildWhereClause`](@ref) — turn a vector of IDs plus a filter `Dict` into a `WHERE` clause.
- [`tableExists`](@ref), [`tableColumns`](@ref) — introspect the schema.
- [`tableIDName`](@ref) — the primary-key column name for a table.

These are the low-level route. For reading a campaign back as a tidy table — with parameters
expanded into columns, and optionally each simulation's quantities of interest and tags
alongside them — use [`simulationsTable`](@ref) and its relatives, described in
[Result tables](@ref result_tables).

## Consistency diagnostics

After [`initializeModelManager`](@ref) succeeds, it launches [`ModelManager.databaseDiagnostics`](@ref)
in a background task. These are five read-only checks that verify the database and filesystem
agree (DB↔filesystem sync, orphaned entries, constituent-ID integrity, and simulation
status). Because they run in the background, their output may appear shortly after
initialization returns; call [`waitForDiagnostics`](@ref) if you need them to finish first
(useful in short scripts or tests).

See the [Database](@ref database_lib) API reference for the complete set of functions.
