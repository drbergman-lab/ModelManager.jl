# Design Brief: Calibration as a poset of `Sampling` views, and a taggable `Calibration`

> **Order:** 4 of 8. **Gate for briefs 05–08** — it settles the types and the tagging machinery they build
> on. Land it before them; do not run it beside them.
>
> **Ordering constraint that matters:** this brief provides the tagging *machinery* (`tag!(calibration, …)`
> works when it is done). Brief 05 adds the `tags=` **keyword** to the calibration entry points, and it must
> come second: brief 05 gives `runABC` a `kwargs...` splat into `ABCSMC(; kwargs...)`, so a `tags=` keyword
> added before that splat exists would later be silently swallowed and throw from the `ABCSMC` constructor.

## Preflight

1. Read `CLAUDE.md`: the design-brief-first workflow, `camelCase` functions, the `@ref`-public-bindings-only
   rule, the Definition of Done, and the "Known Trade-offs" entry on concurrent trial creation — directly
   relevant here.
2. **Read `src/tags.jl` end to end before touching it.** 1448 lines, and tagging, `simulationsTable(…; tags=true)`,
   provenance and deletion all depend on it.
3. Read `docs/src/man/trial_hierarchy.md`, `docs/src/man/tagging.md`, `docs/src/man/calibration.md`, and the
   tagging entry in `README.md`'s Implementation Status.
4. Per CLAUDE.md step 2: add PRD entries for the views and the taggable calibration, and open a dated
   `progress.md` entry.
5. `git branch feature/calibration-sampling-views`, then have the user check it out before you code.
6. All paths are repo-relative. Work only inside your worktree.

## Motivation

A calibration run is not addressable as an object. `Calibration` is a bare `struct Calibration; id::Int; end`
(`src/calibration/problem.jl:116`) outside every type hierarchy, so `simulationIDs(calibration)` does not
exist, the run cannot be tagged, and there is no way to ask "which monads did generation 3 evaluate?" without
regex-scanning filenames. Its only run-level label is `description`, which is **write-only** — there is no
`SELECT` against the `calibrations` table anywhere in `src/`.

## The structural fact that drives the design

**A generation is not one `Sampling`.** The batch loop runs `while length(accepted) < population_size`
(`src/calibration/abc_smc.jl:615`) and *each batch* constructs its own `Sampling(monads, problem.inputs)`
(`src/calibration/abc.jl:167`). So the containment reads:

```
batch        → Sampling  (one per batch, as today)
generation   → the monads of all its batches
calibration  → the monads of all its generations
```

But a `Sampling` is defined by **all input folders matching** (`src/classes.jl:505-512`), and every monad in
a calibration shares `problem.inputs`. So a generation's monads are a valid `Sampling`, and so are the whole
calibration's. These are **overlapping views over the same monads** — which a strictly-ordered chain cannot
express, since a `Sampling`'s constituents are `Monad`s, not other `Sampling`s.

**Therefore: do not insert `Calibration` into the trial containment hierarchy.** Not as a fifth level, and
not as `Calibration <: AbstractTrial`. It is a poset, not a total order. The GSA precedent does not transfer
directly either — `GSASampling` is *not* an `AbstractTrial`; it wraps exactly one `sampling` field and
forwards `simulationIDs` to it (`src/sensitivity.jl:44`). A calibration has many samplings, so there is
nothing single to wrap **until you coalesce**. Coalescing is what makes the GSA pattern applicable.

## Scope

- **Files affected:**
  - `src/ModelManager.jl` — under Option A, move `include("tags.jl")` after `include("calibration/calibration.jl")`
  - `src/classes.jl` — accessor forwards; under Option B also a new `abstract type AbstractTaggable end` with
    `AbstractTrial <: AbstractTaggable` (`:15`) and a widened `lowerClassString` (`:806-813`)
  - `src/calibration/problem.jl:116` — `Calibration` gains a supertype only under Option B
  - `src/tags.jl` — ten `Calibration` methods (Option A) or ~21 widened signatures (Option B);
    `TAG_CLASSES` (`:33`)
  - `src/database.jl` — `calibrationsSchema()` (`:155-162`) gains `provenance_id INTEGER`
  - `src/calibration/calibration.jl` — the coalesced views, the `calibrationMonadIDs` fix,
    `createCalibration` (`:36-49`), new `calibrationsTable` / `printCalibrationsTable` / `Base.show(::Calibration)`
  - `src/deletion.jl` — `deleteCalibration`
  - `src/ModelManager.jl` — exports (and, under Option A, the moved `include`)
  - `docs/src/man/calibration.md`, `docs/src/man/tagging.md`, `docs/src/man/trial_hierarchy.md`, `PRD.md`,
    `README.md`, `test/runtests.jl`
- **New files:** none.
- **Breaking changes:** no public signature breaks. One *test*-visible break: `test/runtests.jl:3795` asserts
  `orphanedTagCounts() == Dict("simulation"=>0, "monad"=>0, "sampling"=>0, "trial"=>0)` by exact equality and
  needs a fifth key.
- **DB schema:** additive and idempotent — see "Provenance" below. **No `src/up.jl` migration milestone.**

## Proposed Architecture

### Stage 1 — Coalesced `Sampling` views

```julia
Sampling(calibration::Calibration)                          # all monads, all generations
Sampling(calibration::Calibration, generation::Integer)     # all monads of one generation
```

Both build `Vector{Monad}` and hand it to the existing find-or-insert `Sampling(monads, inputs)`
(`src/classes.jl:517`). Read that constructor before implementing — three properties are load-bearing:

1. **Matching is on the exact monad set**, not a subset: it scans candidate samplings and accepts one only
   when `symdiff(monad_ids_in_sampling, monad_ids) |> isempty` (`:536-542`). So a coalesced view **never
   collides with a batch row**, and calling the same view twice returns the same row. This is what makes the
   design safe.
2. The inner constructor asserts `Set(constituentIDs(Sampling, id)) == Set(monad_ids)` (`:569`) and that all
   monads share `inputs` (`:566`) — both hold for calibration monads.
3. On insert it calls `recordConstituentIDs` and `applyCreationTags(Sampling, id)` (`:558-559`), so a
   coalesced view gets a `monads.csv` and creation/provenance tags like any other sampling.

**⚠ Materialize lazily, and document the mid-run caveat.** Because matching is exact-set, materializing the
calibration-wide view *during* a run creates a row for the partial monad set that will never be reused — the
final set differs, producing a second row. So build views **on demand** from `calibrationMonadIDs`, never
eagerly inside the ABC loop, and document that `Sampling(calibration)` on an in-progress run describes the
monads evaluated *so far*.

**Filter to surviving monads.** `Monad(id)` throws for a deleted monad, and calibration deletes monads whose
every simulation failed (`src/runner.jl:513` → `src/deletion.jl:116`). The view builders must drop IDs with
no `monads` row, or a run with any total monad failure cannot be viewed at all.

**Fix `calibrationMonadIDs` here — it has two bugs, and both become load-bearing.**
`src/calibration/calibration.jl:57-62`:

- It filters `endswith(f, "_monads.csv")`, which also matches `generation_{NNN}_failed_monads.csv`
  (written at `src/calibration/abc.jl:1134-1137`), folding failed-monad IDs into the "all monads evaluated"
  list — and those are exactly the deleted ones. `reduce(vcat, …)` does not dedupe either.
- `sort` is **lexicographic**, so `generation_10` precedes `generation_9` whenever the zero-padding differs
  between the original run and a resume with a larger `max_nr_populations` — contradicting the documented
  "evaluation order".

Fix with `occursin(r"^generation_\d+_monads\.csv$", basename(f))`, a numeric sort key, and `unique!`.
Brief 05 lists the same defect; whichever lands first fixes it — record it in `progress.md` so the other
session does not redo it.

**Accessors** (mirroring `GSASampling` at `src/sensitivity.jl:44`):

```julia
simulationIDs(calibration::Calibration) = simulationIDs(Sampling(calibration))
monadIDs(calibration::Calibration)      = monadIDs(Sampling(calibration))
```

Coordinate with brief 02, which adds `monadIDs` methods in the same neighborhood.

### Stage 2 — A taggable `Calibration`: two viable mechanisms, pick one

**Do not subtype `AbstractTrial`.** `run(T::AbstractTrial; …)` (`src/runner.jl:256`) would immediately
dispatch on a `Calibration` and call `prepareTrialHierarchy` on it, and `AbstractTrial` carries assumptions
about `inputs`, `constituentIDs`, `length` and `trialFolder` that a calibration run does not satisfy. That
much is settled.

Beyond that there are **two real options**, and the choice is a genuine trade-off rather than a forced move.

#### The constraint, stated precisely

Verified include order in `src/ModelManager.jl`: `classes.jl` at `:72`, `tags.jl` at `:75`,
`calibration/calibration.jl` at `:83`. So `_tagClass(::Type{Calibration})` written in `tags.jl` **today** is an
`UndefVarError` — a method signature is evaluated when the method is defined, and `Calibration` does not exist
yet.

But that constrains only *this ordering*, not the approach. Verified facts about relaxing it:

- **`tags.jl` defines no types** — only constants (`MM_TAG_PREFIX`, `TAG_CLASSES`, `MAX_MATERIALIZED_TRIALS`,
  `RECOMMENDED_TAG_KEYS`, `PROVENANCE_COLUMNS`, `MM_CREATED_KEY`, `_PKG_SOURCE_DIR`) and functions.
- **Nothing loaded after `tags.jl` mentions those constants in a method signature** — checked across
  `runner.jl`, `deletion.jl`, `xml_utilities.jl`, `variations.jl`, `sensitivity.jl`,
  `sensitivity_visualize.jl`, `user_api.jl`.
- The calls *into* tags from earlier files (`applyCreationTags` at `src/classes.jl:313`, `:425`, `:558`,
  `:695`; `deleteTagsFor` from `deletion.jl`) are all inside **function bodies**, which Julia resolves lazily.
- `createSchema`'s use of `tagsSchema()` / `ensureProvenanceColumns` happens at *runtime* via
  `initializeDatabase()`, not at load.

**So moving `include("tags.jl")` to after `include("calibration/calibration.jl")` is viable.**

#### Option A — reorder the includes, add per-type methods (smaller; **default**)

Move one line in `src/ModelManager.jl`, then write explicit `Calibration` methods in `tags.jl`:
`_tagClass`, `tag!`, `untag!`, `tags`, `hasTag`, `tagReserved!`, `applyCreationTags`, `deleteTagsFor`,
`appendTags!`, `findTrials` — roughly ten small methods. `lowerClassString` needs **no** change, because
`_tagClass(::Type{Calibration}) = "calibration"` is hardcoded rather than derived.

Pros: one line of structural change; `classes.jl` untouched; no new type in the public type tree; failures are
load-time and therefore loud, never silent.
Cons: ~10 methods per taggable type, forever. Moving `tags.jl` last also makes the include list slightly
misleading, since `classes.jl` depends on tags functionally.

#### Option B — an `AbstractTaggable` capability supertype

```julia
# src/classes.jl
abstract type AbstractTaggable end          # anything with an integer PK in a `<class>s` table
abstract type AbstractTrial <: AbstractTaggable end
```

```julia
# src/calibration/problem.jl:116
struct Calibration <: AbstractTaggable
    id::Int
end
```

Then widen ~21 of the 24 `T<:AbstractTrial` signatures in `tags.jl` to `T<:AbstractTaggable`, and widen
`lowerClassString` (`src/classes.jl:806-813`) so `_tagClass(Calibration) == "calibration"` derives correctly.

Pros: the marginal cost of the *next* taggable is one line (`<: AbstractTaggable`) instead of ten methods, and
the repo already has candidates — `Generation` (open question below) and arguably `GSASampling`. It also names
a real category instead of leaving it enumerated by hand.
Cons: 21 one-token signature edits; touches `classes.jl`, the most load-bearing file; adds a layer to the
public documented type tree, and `AbstractTrial`'s supertype changes from `Any`.

#### Decision: Option A, and `tags.jl` moves to LAST

The user has decided: **reorder the includes, and adopt a standing rule that `tags.jl` stays at the bottom.**
As more types acquire tagging methods, the include simply stays last rather than being renegotiated.

Note this has a natural floor, which makes it a one-time move rather than an ongoing chore: moving
`include("tags.jl")` after `include("calibration/visualize.jl")` puts every type in the package ahead of it, so
no future taggable can be out of reach. Encode the rule as a `#!` comment at the include site — something like
"`tags.jl` is included last so its methods can dispatch on any type in the package; keep it last when adding a
new include" — so the next person adding an `include` does not undo it.

Option B is not needed and should not be built. It stays documented below only as the escalation path if the
per-type method count ever becomes the dominant cost.

Whichever you pick, everything below is unchanged: the same ten entry points must accept a `Calibration`, the
same three must not, and `TAG_CLASSES` gains the same member.

<details>
<summary>Option B's declarations and full widening list, if chosen</summary>

This is a capability supertype, not a containment level — it adds no constituents, no ordering, and nothing
dispatches `run` on it:

```julia
# src/classes.jl
abstract type AbstractTaggable end          # anything with an integer PK in a `<class>s` table
abstract type AbstractTrial <: AbstractTaggable end
```

```julia
# src/calibration/problem.jl:116
#! AbstractTaggable, not AbstractTrial: a calibration is a run, not a collection of
#! simulations, and subtyping AbstractTrial would make `run(::Calibration)` dispatch
#! into the simulation runner.
struct Calibration <: AbstractTaggable
    id::Int
end
```

Then widen the tag generics from `T<:AbstractTrial` to `T<:AbstractTaggable`. There are **24** `AbstractTrial`
occurrences in `src/tags.jl`; classify every one deliberately. Widen: `_tagClass` (`:234-235`), `tag!`
(`:314`, `:323`, `:325`, `:330`), `tagReserved!` (`:355`), `untag!` (`:383`, `:408-412`), `applyCreationTags`
(`:642`), `tags` (`:728`, `:750`), `hasTag` (`:765`, `:777`), `tagsTable` (`:814`, `:833`), `findTrials`
(`:1256`), the `_inheritedIDs` catch-all (`:1308`), `appendTags!` (`:1335`), `deleteTagsFor` (`:1410`).

Under Option B, `lowerClassString` (`src/classes.jl:806-813`) is **also** widened, which is what makes
`_tagClass(Calibration) == "calibration"` derive rather than being hardcoded. Under Option A it is left alone.
Either way `_tagTable("calibration") == "calibrations"`, and that table's ID column `calibration_id` already
matches `tableIDName`'s strip-the-`s` convention (`src/database.jl:284-290`).

</details>

**Deliberately NOT extended to `Calibration` — under either option:**
- `tag!(ids::AbstractVector{<:Union{Integer,Missing}})` (`src/tags.jl:340`) — a bare integer vector must keep
  meaning simulation IDs.
- `findSimulations` / `findMonads` — the inheritance-aware finders (see the inheritance decision below).
- `trialFolder` (`src/classes.jl:802`) — `calibrationFolder` (`src/calibration/calibration.jl:25`) already
  produces the identical `data/outputs/calibrations/{id}` path.

**Blast radius of `TAG_CLASSES += "calibration"`** — five iteration sites, each already guarded:

| Site | Guard | Effect on `calibrations` |
|---|---|---|
| `_countTaggableObjects` `:835-839` | `tableExists && columnsExist(["provenance_id","datetime"])` | included once `provenance_id` is added |
| `_syntheticTagRows` `:845-847` | same | included; yields `mm:created` + provenance rows |
| `tagValues(MM_CREATED_KEY)` `:931-936` | `columnsExist(["datetime"])` only | included immediately |
| `_objectsWithSyntheticKey` `:1021-1023` | provenance-gated | included once `provenance_id` is added |
| `orphanedTagCounts` `:1437-1439` | `tableExists` only | included immediately — **breaks the exact-equality test at `test/runtests.jl:3795`** |

**Provenance — additive, no migration.** Add `provenance_id INTEGER` to `calibrationsSchema()`
(`src/database.jl:155-162`) for fresh databases, and add `Calibration` to `ensureProvenanceColumns`'s loop
(`src/tags.jl:141`) so existing databases gain the column on their next `initializeModelManager`. This is
exactly the mechanism the `#!` comment at `src/database.jl:142-143` describes, so **no `src/up.jl` milestone
is required and simulator packages implement nothing.** That matters here: `upgradeMilestones` /
`upgradeToMilestone` are `AbstractSimulator` methods, so any milestone ModelManager needs must be implemented
by every downstream simulator.

`createCalibration` then calls `applyCreationTags(Calibration, calibration_id)` after the insert, and
calibration runs get `mm:created`, `mm:session`, `mm:script`, `mm:git`, `mm:git.branch`, `mm:git.dirty` for
free — a real capability `description` never provided.

**⚠ One catch:** `createCalibration` writes its stamp as `"yyyy-mm-dd HH:MM:SS"`
(`src/calibration/calibration.jl:37`) while every other table uses `"yyyy-mm-ddTHH:MM:SS"`, and
`_normalizeStamp` (`src/tags.jl:680-690`) only special-cases the 10-digit legacy `trials` format — so
`mm:created` would read back in a different shape for calibrations. Fix the format at `calibration.jl:37`;
the column is write-only today, so there is no compatibility risk.

Also add `tagReserved!(calibration, ["mm:method" => "ABCSMC"])`, mirroring GSA's `src/sensitivity.jl:163`.
Read filters already accept `mm:` keys (`_filterToKeyValue`, `:1046-1057`), so
`findTrials(Calibration; tags=("mm:method" => "ABCSMC",))` works.

**The durable win worth stating:** the `calibrations` row is never deleted by a monad cascade, so tags placed
on the calibration survive the exact scenario where the existing mitigation evaporates — when every monad of
a sampling fails, the sampling row and its `mm:calibration`/`mm:generation` tags are deleted
(`src/deletion.jl:161`).

### Inheritance — recommend "no" for v1

Tag inheritance is resolved at *query* time and only *downward*: `_simulationIDsMatching`
(`src/tags.jl:1059`) and `_monadIDsMatching` (`:1081`) walk Trial→Sampling→Monad→Simulation. `Calibration` is
not in that chain. With the widened `_inheritedIDs` catch-all returning `Int[]`, a calibration's tags do not
propagate to its samplings/monads/simulations.

That is the recommendation for v1, because the `mm:calibration` tag `src/calibration/abc.jl:169` already puts
on every generation sampling gives a two-step route: `findMonads(tags=("mm:calibration" => "42",))` works
today. Real inheritance would require the finders to traverse a new edge. **This is the biggest semantic call
in the brief** — record the decision explicitly.

### New read path — required, not optional

Without it nothing selects from the `calibrations` table and the "is `description` worth keeping?" question
(brief 05) stays academic.

- `calibrationsTable(; tags::Bool=false, limit=MAX_MATERIALIZED_TRIALS)` → `DataFrame` with `CalibrationID`,
  `DateTime`, `Method`, `Description`; when `tags=true`, `appendTags!(df, Calibration, :CalibrationID; inherit=false)`.
  Model the signature and the `printX`/`X` pairing on `monadsTable`/`printMonadsTable`.
- `Base.show(io::IO, cal::Calibration)` printing id, datetime, method, description, generation count and
  final ε — the last two read from `generations/generation_*.toml`. Model on `Base.show(::MOATSampling)`
  (`src/sensitivity.jl:140-148`).

### `deleteCalibration`

There is no per-calibration deletion today — `src/deletion.jl:271` only lists `"calibrations"` among folders
wiped by a full reset. Once a calibration carries tag rows it needs a cleanup verb: delete the row,
`deleteTagsFor(Calibration, ids)`, and `rm_hpc_safe(calibrationFolder(id); recursive=true)`.

Whether it should also delete constituent monads is a real question — a calibration's monads may be shared
with other work via `use_previous=true` and the `SimulationBank`, so cascading is dangerous. Recommend
`delete_subs::Bool=false`, matching the conservative choice `simulationFailed` already makes
(`src/runner.jl:514`).

### Should generations be addressable objects?

Answer it even if the answer is "not yet". Today a generation is identified only by a zero-padded filename
that `_loadGenerations` rediscovers by regex (`src/calibration/abc.jl:1299-1301`).
`Sampling(calibration, generation)` gives it an *object* but not an *identity* — no row, no stable ID, no
place to hang a tag. Options: leave as a view (recommended for v1 — it is what `posterior` and the recipes
need); give each generation a `Trial` row over its batch samplings, which makes brief 02's
`trialID(::Vector{Sampling})` find-or-insert load-bearing and inherits its concurrency caveat; or add a
`Generation` type — cheap under Option B, ten more methods under Option A.

### Costs to price honestly

- **Extra sampling rows.** A 10-generation run gains up to 11 coalesced rows plus constituent CSVs, on top of
  one row per batch. Bounded and small, but state it.
- **No `UNIQUE` constraint on `samplings`.** The find-or-insert scan is the mechanism CLAUDE.md's "Known
  Trade-offs" names as unsafe under concurrent trial creation. Coalesced views inherit that caveat exactly;
  add a sentence to that entry rather than pretending the surface did not grow.
- **Resume.** A generation-level view can only be built once that generation's batches are known, so on a
  resumed run it is reconstructed from `generation_{NNN}_monads.csv` — another reason the filter and sort bugs
  must be fixed here.

### Summary

- **Current:** a calibration is an integer with a folder; its monads are reachable only by scanning
  per-generation CSVs, and the run itself cannot be tagged, listed or deleted.
- **Proposed:** coalesced `Sampling` views at generation and calibration scope; `Calibration` brought into the
  tag subsystem without touching containment; provenance and a real read path; a conservative
  `deleteCalibration`.
- **Key decisions:** no containment-hierarchy insertion (a poset, not a total order); lazy view materialization
  because `Sampling` matching is exact-set; **Option A: reorder the includes so `tags.jl` is last, then add per-type
  methods** (decided; `AbstractTaggable` explicitly not built); no downward inheritance
  for calibration-class tags in v1.

## Testing Strategy

Calibration tests live in the DB-backed block (`test/runtests.jl:2094`); failure-path anchors are `:2624`,
`:2653-2667`, `:2758-2792`, and `_fail_sim_predicate` is at `:66-72`.

**Mitigation for the riskiest part: run the full suite after the `classes.jl` change alone, before touching
`tags.jl`.**

- **Unit:** `_tagClass(Calibration) == "calibration"` and `_tagTable("calibration") == "calibrations"` in a
  new small testset near `"tag key and value normalization"` (`:3490`); `calibrationMonadIDs` excludes
  `_failed_monads.csv`, dedupes, and orders `generation_9` before `generation_10` under mixed padding —
  build a `generations/` directory by hand; `findTrials(Calibration; limit=0)` throws (extend
  `"materialization guard and bulk construction"`, `:4212`).
- **Views:** `Sampling(calibration)` twice returns the **same** `sampling_id` (the exact-set dedupe property);
  a coalesced view's `sampling_id` differs from every batch `sampling_id`; `simulationIDs(calibration)` equals
  the union of the batch samplings' simulation IDs; `monadIDs(Sampling(calibration, 1)) ⊆ monadIDs(Sampling(calibration))`.
- **Failure path:** with `_fail_sim_predicate` forcing one monad to fail totally, the views still build and
  exclude the deleted monad — the regression test for the `calibrationMonadIDs` fix.
- **Tagging:** new `@testset "calibration runs are taggable"` after `"runCalibration end-to-end"` (`:2561`) —
  `tag!(cal, "project" => "x")`; `tags(cal)["project"] == ["x"]`; `hasTag(cal, "project" => "x")`;
  `findTrials(Calibration; tags=("project" => "x",)) == [cal]`; `haskey(tags(cal), "mm:created")`;
  `tags(cal)["mm:method"] == ["ABCSMC"]`; `!isempty(tagsTable(cal))`; `untag!(cal, "project")` leaves the
  `mm:` keys; **the tag survives deleting every monad** (the durability claim); `tagReserved!` accepts `mm:`
  on a `Calibration` while `tag!` rejects it (extend `:3597`).
- **Provenance:** extend `"provenance lives in object columns, not tag rows"` (`:3906`) — the `calibrations`
  row has a non-null `provenance_id` and `tags` holds no `mm:session` row for `trial_class='calibration'`.
  Extend `"tags table is created on an existing database"` (`:4242`) — *the* guard for the additive-schema
  claim — to assert `columnsExist(["provenance_id"], "calibrations")` after re-initializing an old database.
- **Read path:** new `@testset "calibrationsTable"` modelled on `"monadsTable"` (`:2295`): column names, one
  row per run, `tags=true` adds `tag:project`, and `show(::Calibration)` output contains the description and
  the generation count.
- **Deletion:** `deleteCalibration` removes the row, tags and folder and leaves monads intact by default —
  extend `"tag cleanup on deletion"` (`:3778`), and **update `:3795`'s exact-equality assertion to include
  `"calibration" => 0`.**
- **Guards:** grep for any other test asserting an exact `TAG_CLASSES` list or count.
  `"docstrings only @ref public bindings"` (`:4310`) covers the new docstrings — `calibrationsTable` and
  `printCalibrationsTable` each need description, arguments, return value and an example.

## Estimated Effort

- **Lines of code:** ~40 in `src/tags.jl` (mechanical widening across ~21 sites), ~8 in `src/classes.jl`, ~2
  in `src/calibration/problem.jl`, ~1 in `src/database.jl`, ~170 in `src/calibration/calibration.jl` (views +
  `calibrationsTable` + `printCalibrationsTable` + `show` + docstrings), ~20 in `src/deletion.jl`; ~200 in
  `test/runtests.jl`; ~40 in docs/README.
- **Risk level:** **Medium-High** — not because any single edit is hard, but because it inserts a level into
  the type hierarchy every feature sits on, touches a 1448-line subsystem, and widens the find-or-insert
  surface that is already the known concurrency weak point.
- **Dependencies:** none hard. Coordinate with brief 02 (both touch `monadIDs`) and brief 05 (both fix
  `calibrationMonadIDs`; brief 05 must come after this one).

## Open questions for the user

1. **Should calibration tags inherit down to samplings/monads/simulations?** Recommend no for v1; the
   existing `mm:calibration` batch tags already give the query route. Biggest semantic decision here.
2. **Mid-run view materialization** — document the partial-set caveat (recommended) or refuse to build the
   calibration-wide view until the run is complete?
3. **Generations as first-class objects** — leave as views (recommended), a `Trial` row each, or a
   a `Generation` type? Ties to brief 02's `trialID(::Vector{Sampling})` decision.
4. **Should `deleteCalibration` be able to cascade to monads?** Recommend `delete_subs=false` because monads
   are shared via `use_previous` and the `SimulationBank`.

## Cross-cutting rules

**Review-only comments.** The repo uses `#!` for *permanent* design-rationale comments (316 of them). Any
comment written purely so the user can follow your reasoning during review must be marked `#REVIEW:` and
removed before merge.

**Docs are for an outside reader, not a changelog.** User-facing prose explains how to use the code as it now
is. Where a "why" is needed it must be the grand-narrative why, never this repo's history:

> ✅ "Updates are delayed until the next Julia session so as not to corrupt the currently loaded session state."
> ❌ "Updates must be delayed because updating mid-session had the potential to produce incorrect session states where upgrades would never actually proceed."

The second sentence belongs in `progress.md`.

## Pre-merge checklist

- [ ] `julia --project=. -e 'using Pkg; Pkg.test()'` green.
- [ ] `rg '#REVIEW:' src/ test/` returns nothing.
- [ ] All 24 `AbstractTrial` sites in `src/tags.jl` classified deliberately — widened or left narrow, each
      with a reason in `progress.md`.
- [ ] Every new exported/`@compat public` binding has a docstring with description, arguments, return value
      and a usage example.
- [ ] CLAUDE.md "Known Trade-offs" notes that coalesced views widen the find-or-insert surface.
- [ ] Docs written outside-in per the rule above; no repo history in `docs/`.
- [ ] `README.md` Implementation Status and `PRD.md` updated.
- [ ] `#!` comment at the `include("tags.jl")` site stating the keep-it-last rule.
- [ ] `progress.md` records: why no containment insertion, the include-order rule, the
      inheritance decision, and that `calibrationMonadIDs` was fixed here.
