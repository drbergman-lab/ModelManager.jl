```@meta
CurrentModule = ModelManager
```

# [Result tables](@id result_tables)

Once a campaign has run, the usual next question is "what did I actually run, and how did it
turn out?" ModelManager answers it with a small family of functions that return tidy
`DataFrame`s: one row per simulation (or per monad), with the varied parameters expanded into
columns.

These are the readable, analysis-facing view of the project. For the schema underneath them,
and for writing your own SQL, see [The database](@ref database).

## One row per simulation

[`simulationsTable`](@ref) is the workhorse. It accepts whatever you happen to have in hand:

```julia
simulationsTable(sampling)                   # a trial object
simulationsTable([monad_3, sampling_2])      # an array of trial objects, mixed levels
simulationsTable(monad_3, sampling_2)        # the same, as separate arguments
simulationsTable([41, 42, 43])               # a vector of simulation IDs
simulationsTable()                           # every simulation in the project
```

Each row is a simulation; each column is either an identifier, an input-folder name, or a
parameter that varied across the set. Columns whose value is the same for every row are
dropped, on the grounds that a constant is not what you are comparing.

[`monadsTable`](@ref) is the monad-level analogue — one row per [`Monad`](@ref) rather than
per simulation — and takes the same arguments and keywords.

## Shaping the table

Both functions share these keywords:

| Keyword | Default | Effect |
| --- | --- | --- |
| `remove_constants` | `true` | Drop columns that are identical across every row. Set `false` to keep the full picture. |
| `sort_by` | `String[]` | Column names to sort by. Empty means *sort by every parameter column in table order*, so the first parameter column acts as the primary key. `:SimID` is not sorted on unless you ask for it. |
| `sort_ignore` | `String[]` | Extra columns to exclude from the default sort, on top of the always-excluded variation-ID columns. |
| `short_names` | `true` | Shorten parameter column names. Pass `false` for raw XML-path names — what you want when matching against `parameters.toml` `db_column` entries. |

A practical order of operations: print the table once with the defaults, read the column
names off it, then pass the ones you care about to `sort_by`.

The full keyword reference lives on [`simulationsTableFromQuery`](@ref) and
[`monadsTableFromQuery`](@ref). Those two are also the raw-SQL escape hatch — hand them a
query string and they apply the same column expansion and shaping to its result.

## Printing and exporting

Every table function has a `print…` variant that routes the `DataFrame` through a `sink`,
which defaults to `println`:

```julia
printSimulationsTable(sampling)                       # to the terminal
printMonadsTable(sampling; remove_constants=false)

using CSV
printSimulationsTable(; sink=CSV.write("all_simulations.csv"))
```

Any function of one `DataFrame` works as a sink, so this is also the hook for writing
Arrow, Parquet, or your own formatter.

## Adding outcomes and intent

Two keywords widen the table beyond parameters, and they answer different questions:

```julia
simulationsTable(sampling; post_processing=true)              # how each run turned out
simulationsTable(sampling; tags=true)                         # what each run was for
simulationsTable(sampling; tags=true, post_processing=true)   # both, side by side
```

`post_processing=true` left-joins each simulation's stored quantities of interest onto the
table by `:SimID`, one column per quantity, `missing` where a quantity was not computed for
that simulation. See [Post-processing and quantities of interest](@ref post_processing) for
how those quantities get there in the first place.

`tags=true` appends one `tag:<key>` column per tag key in use, inheriting tags from a parent
`Monad`, `Sampling`, or `Trial` so a simulation recovered *by* a sampling-level tag still
shows a column for it. Add `include_auto_tags=true` to include ModelManager's own `mm:`
provenance columns. See [Tagging and recovering simulations](@ref tagging).

Both sets of columns are appended as-is: they are not subject to `remove_constants` and are
not sorted on. `monadsTable` supports `tags` but not `post_processing`, since the sink is
keyed by simulation.

## Quantities on their own

[`postProcessingTable`](@ref) reads the post-processing sink directly, without the parameter
columns. It takes the same argument forms as `simulationsTable` and is keyed by `:SimID`:

```julia
postProcessingTable(sampling)
printPostProcessingTable(sampling; sink=CSV.write("qois.csv"))
```

Simulations with no stored quantities are absent from the table rather than present with
`missing`s; if no post-processing has run at all, the result is empty.

Because every table here is keyed by `simulation_id`, they compose with an ordinary join:

```julia
ids = findSimulationIDs(tags = ("project" => "immune-escape",), status = "Completed")
innerjoin(simulationsTable(ids; tags = true), postProcessingTable(ids), on = :SimID)
```

For the complete set of table functions and their signatures, see the
[Database](@ref database_lib) API reference.
