```@meta
CurrentModule = ModelManager
```

# [Tagging and recovering simulations](@id tagging)

Finding simulations by ID is not a robust way to find your own work later. A script that records
`[41, 42, 43]` is correct exactly once; add replicates, regenerate the sweep, or come back
in six months and the list means nothing. Parameter values are not much better — they say
what a simulation *was*, not what it was *for*.

Tags fix this by letting you attach `key => value` pairs to any trial object — or to a
[`Calibration`](@ref) run — and then search by them.

## The short version

```julia
# Label as you go.
run(inputs, variations; n_replicates = 10,
    tags = ("project" => "immune-escape", "purpose" => "figure", "figure" => "3b"))

# Come back later and find it.
ids = findSimulationIDs(tags = ("project" => "immune-escape", "figure" => "3b"),
                        status = "Completed")
simulationsTable(ids; tags = true)
```

## You get provenance for free

Even if you never write a single tag, ModelManager records where each object came from:

| Key | What it holds |
|-----|---------------|
| `mm:created` | ISO-8601 creation timestamp |
| `mm:session` | Random per-session ID, grouping one session's work |
| `mm:script` | Script that created the object. In an interactive session, the script you `include`d or else the launcher that opened the prompt — read together with `mm:interactive` |
| `mm:interactive` | Present when the session was interactive |
| `mm:git`, `mm:git.branch`, `mm:git.dirty` | Commit and branch of the script's repository, and whether the tree had uncommitted changes |
| `mm:method` | The sensitivity method (`MOAT`, `Sobolʼ`, `RBD`) that produced a sweep, or the calibration method (`ABCSMC`) that produced a run |
| `mm:calibration`, `mm:generation` | The calibration run and generation that proposed a monad |

So this works on a database you never tagged by hand:

```julia
findSimulationIDs(tags = ("mm:script" => "fig3_sweep.jl",))
```

`mm:script` matches on either the bare filename or the full path.

Read it differently depending on `mm:interactive`. For a script run — `julia sweep.jl` —
it is the script that produced the result. In an interactive session it means "how this
session started": a script you `include`d from the project if there is one, otherwise
whatever launched the REPL, which in VS Code is the extension's own
`scripts/terminalserver/terminalserver.jl`. That still tells you which front-end the work
came from; it just is not a file you can re-run. The git state is read at
each `createTrial`/`run` call, so edits you make partway through a session are reflected in
whatever you create next.

`mm:created` is worth calling out — the `simulations`, `monads`, and `samplings` tables had
no timestamp of their own before, so this is the only way to ask "what did I run last
Tuesday?".

`mm:interactive` and `mm:git.dirty` are both reproducibility caveats, and worth reading
together. A dirty tree means the code on disk did not match the commit; an interactive
session means the script was not the whole story — globals you had defined, a function you
had redefined, or an earlier edit-and-re-include all fed into the run and are not
recoverable. A run with neither flag is one you can expect to reproduce from the recorded
commit and script alone.

An object records the context that **created** it, not the last one to touch it. If a
second script reuses a monad and adds replicates, the monad keeps its original `mm:script`
while the new simulations carry the second script's — so both are attributed correctly.

!!! note "The simulator version is not a tag"
    Your simulator's version (for PhysiCell, the PhysiCell hash) is already a foreign-keyed
    column on every simulation, monad, and sampling row. `mm:git` records *your*
    repository, not the simulator's.

## Tagging as you go

`createTrial` and `run` both take a `tags` keyword:

```julia
sampling = createTrial(inputs, variations; n_replicates = 5,
                       tags = ("project" => "immune-escape", "arm" => "control"))

run(sampling)
```

The tags go on the object you get back. Its monads and simulations are *not* tagged
individually — they match through inheritance instead, which is what keeps the answer
right when you add replicates later.

If you build trials up front and batch them into one `run` for parallelism, tagging the
run covers them:

```julia
lo = createTrial(inputs, v_lo; tags = ("arm" => "control",))
hi = createTrial(inputs, v_hi; tags = ("arm" => "anti_pd1",))

run([lo, hi]; tags = ("project" => "immune-escape",))
```

The rule is that **`run` tags exactly the objects you hand it** — never the containers it
builds to hold them. So `lo` and `hi` are tagged; the `Trial` created to batch them is not,
because two unrelated trials run together for convenience are not thereby one experiment.

One consequence worth knowing: batching objects *below* the `Sampling` level wraps each in
a single-object `Sampling` so the `Trial` can hold it, and those wrappers are containers
too, so they go untagged:

```julia
run([monad_a, monad_b]; tags = ("project" => "x",))

findSimulationIDs(tags = ("project" => "x",))   # all their simulations
findMonads(tags = ("project" => "x",))          # [monad_a, monad_b]
findTrials(Sampling; tags = ("project" => "x",))  # empty — the wrappers are plumbing
```

Pass `Sampling`s instead of `Monad`s and they are the objects, so they are tagged and the
last query returns them.

Tags are written **before** any simulation is dispatched. An interrupted run keeps its
tags, and a multi-day HPC job is queryable by tag while it is still running.

!!! warning "Do not create trials in parallel"
    Trial creation is not concurrency-safe — neither across tasks in one session, nor
    across two Julia sessions sharing a project. It reads before it writes in several
    places, and those reads include files on disk that no database lock covers. Build
    trials sequentially, then run them in parallel, which is where the time goes anyway.

    Two sessions cannot corrupt the database — SQLite serializes writers itself — but they
    can leave duplicate `samplings` or `trials` rows behind.

## Tagging after the fact

This is often the easier way to start, and it works on simulations you ran long before you
had any tagging scheme — you usually do not know what is interesting until you have looked
at the results:

```julia
# Label everything that finished.
tag!(findSimulationIDs(status = "Completed"), "project" => "legacy")

# Label what you found interesting.
df = simulationsTable()
tag!(df[df.final_population .> 1_000, :SimID], "verdict" => "runaway_growth")
```

[`tag!`](@ref) accepts a trial object, a type plus IDs, a vector of objects, a bare vector
of integers (read as simulation IDs), or the [`MMOutput`](@ref) returned by `run`.

## Key and value rules

Keys are identifiers; values are data.

|  | Keys | Values |
|---|---|---|
| Characters | `[a-z0-9][a-z0-9_.-]*` | anything |
| Case | lowercased on write | preserved |
| Whitespace | stripped | trimmed at the ends only |
| Length | ≤ 64 | unbounded |

Keys are restricted because they become column headers when tags are pivoted into a table.
Lowercasing means `"Cohort"` and `"cohort"` can never become two different tags.

The `mm:` namespace is reserved — [`tag!`](@ref) will not write it, so your tags can never
collide with or overwrite provenance.

[`recommendedTagKeys`](@ref) suggests a small starting vocabulary — `project`, `purpose`,
`figure`, `arm`, `verdict`, `note` — but any legal key is accepted. Use [`tagKeys`](@ref)
and [`tagValues`](@ref) to see what you have actually been using and to spot typos.

## Multiple values, and bare labels

A key may hold several values on one object, and a tag with no value is a plain label:

```julia
tag!(sim, "cohort" => "pilot", "cohort" => "paper")
tags(sim; include_auto = false)     # Dict("cohort" => ["paper", "pilot"])

tag!(sim, "baseline")               # stored with an empty value
```

Re-applying an existing tag is a no-op.

## Inheritance

A tag on a `Monad`, `Sampling`, or `Trial` is stored once, on that object. It is not copied
onto the constituent simulations — that would go stale the moment you add a replicate.
Queries expand the hierarchy at lookup time instead:

```julia
tag!(sampling, "project" => "immune-escape")

findSimulationIDs(tags = ("project" => "immune-escape",))                  # all its sims
findSimulationIDs(tags = ("project" => "immune-escape",), inherit = false) # none
```

Inheritance only ever runs downward — tagging one simulation never tags its monad.

## Tagging a calibration run

A [`Calibration`](@ref) is tagged the same way, and shows up in [`findTrials`](@ref) alongside
the four trial types:

```julia
result = runABC(problem)
tag!(result, "project" => "immune-escape")   # or tag!(result.calibration, ...)

findTrials(Calibration; tags = ("project" => "immune-escape",))
findTrials(Calibration; tags = ("mm:method" => "ABCSMC",))
calibrationsTable(; tags = true)
```

A calibration is a *run*, not a container of simulations, so it sits outside the hierarchy above
and its tags do not reach the monads it evaluated. Reach those through the `mm:calibration` tag
that every generation's sampling already carries:

```julia
findMonads(tags = ("mm:calibration" => string(result.calibration.id),))
findMonads(tags = ("mm:calibration" => "42", "mm:generation" => "3"))
```

Tagging the run is nevertheless the more durable of the two, and this is the reason to prefer it
for anything you want to keep. Tag rows are deleted with the object they point at, and a sampling
whose monads have all been deleted is itself deleted — so a batch's `mm:calibration` tag can
disappear along with the work it described. The `calibrations` row is never removed by a monad
cascade, so a tag placed on the run survives it:

```julia
tag!(result, "purpose" => "figure")
deleteMonad(monadIDs(result))                          # the batch tags go with the samplings

findTrials(Calibration; tags = ("purpose" => "figure",))   # still finds the run
```

## Composing filters

```julia
# AND — must match every filter
findSimulationIDs(tags = ("project" => "immune-escape", "arm" => "control"))

# OR — must match at least one
findSimulationIDs(any_of = ("arm" => "control", "arm" => "anti_pd1"))

# A bare key matches any value for that key
findSimulationIDs(tags = ("verdict",))

# Restrict by execution status
findSimulationIDs(tags = ("figure" => "3b",), status = "Completed")
```

Inherited and direct tags compose freely: a simulation tagged `arm => control` inside a
sampling tagged `project => immune-escape` matches a query for both.

Use [`findSimulationIDs`](@ref) for large result sets and [`findSimulations`](@ref) when
you want constructed objects. [`findMonads`](@ref) works one level up, and
[`findTrials`](@ref) dispatches on type — `Simulation`, `Monad`, `Sampling`, `Trial`, or
[`Calibration`](@ref).

A tag on a parent matches everything beneath it, so a query can select far more than you
intended. The ID-returning form hands that back without complaint; the object-returning
forms stop at 10 000 and tell you to work with IDs instead. Pass `limit` when you really do
want them all:

```julia
findSimulationIDs(tags = ("project" => "big",))              # fine at any size
findSimulations(tags = ("project" => "big",), limit = 50_000)
```

## Tags in tables

```julia
simulationsTable(ids; tags = true)
monadsTable(ids; tags = true)
calibrationsTable(; tags = true)
```

adds a `tag:<key>` column per key. The prefix keeps tag columns from colliding with ID,
folder, or parameter columns. Multi-valued keys render joined by `|`; objects without a
value get `missing`. Pass `include_auto_tags = true` to include the `mm:` columns.

Parent tags are inherited into these columns, so a simulation recovered *by* a
sampling-level tag also shows a column for it. Call [`appendTags!`](@ref) with
`inherit = false` for only the tags placed directly on each simulation.

## Tags versus computed outcomes

Tags are for **asserted** features — intent, provenance, grouping — and are low-cardinality
strings known at creation or curation time.

**Computed** outcomes (final population, time to extinction, fit residual) belong in the
post-processing sink instead, via `run(T; post_processor = f)`; see
[Post-processing and quantities of interest](@ref post_processing). That store has typed, numeric columns and
supports range queries, which tags do not.

Both are keyed by `simulation_id`, so a recovery query can use them together:

```julia
ids = findSimulationIDs(tags = ("project" => "immune-escape",), status = "Completed")
innerjoin(simulationsTable(ids; tags = true), postProcessingTable(ids), on = :SimID)
```

## Housekeeping

Tag rows are removed automatically whenever the object they point at is deleted.
[`orphanedTagCounts`](@ref) reports any left behind by an interrupted deletion, and
`databaseDiagnostics` warns about them at startup. Orphans are harmless — queries filter
them out.

The hints ModelManager prints the first time you create a trial without tags can be turned
off with [`setTagHints!`](@ref):

```julia
setTagHints!(false)
```

ModelManager also honors an environment variable for this, so the hints can be silenced
without changing code — the better option in a job script:

```sh
MODELMANAGER_TAG_HINTS=0 julia scripts/GenerateData.jl
```

## What this costs at scale

Provenance adds about 21 bytes per object — two columns on the row the object already has,
with the session-invariant parts shared through a lookup table. At 10⁶ simulations that is
roughly 21 MB. User tags cost more per tag but you write far fewer of them.

## Upgrading an existing project

None required. The tagging tables and columns are added the next time you call
`initializeModelManager` on the project — there is no migration milestone to run.
