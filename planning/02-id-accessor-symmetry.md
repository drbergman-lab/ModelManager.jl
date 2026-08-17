# Design Brief: `monadIDs(::MMOutput)` and trial-ID accessor symmetry

> **Order:** 2 of 8. Independent — safe to run in parallel with 01 and 03. Small enough to be a good
> warm-up, but it contains one genuine trap (see "pure SELECT" below) and one decision that needs the
> user's sign-off.

## Preflight

1. Read `CLAUDE.md`: the design-brief-first workflow, `camelCase` functions, the rule that docstrings may
   `@ref` **only** exported or `@compat public` bindings, and the Definition of Done (item 2 in particular —
   it is what makes the docstring work in this brief mandatory rather than optional).
2. Read `docs/src/man/trial_hierarchy.md`.
3. Per CLAUDE.md step 2: update `PRD.md` if the accessor contract changes and open a dated `progress.md`
   entry.
4. `git branch feature/id-accessor-symmetry`, then have the user check it out before you code.
5. All paths are repo-relative. Work only inside your worktree.

## Motivation

`simulationIDs(out)` works on an `MMOutput` but `monadIDs(out)` is a `MethodError`, so the natural follow-up
to `out = run(sampling)` — "which monads did that produce?" — forces `monadIDs(out.trial)`. Closing that gap
exposes a second, larger hole: `monadIDs(::Simulation)` does not exist at all, which makes
`monadsTable(simulation)` and `monadsTable([sim, monad])` throw even though `monadsTable`'s own docstring
promises that any `AbstractTrial` (or array thereof) works.

## Scope

- **Files affected:** `src/classes.jl`, `src/sensitivity.jl`, `test/runtests.jl`,
  `docs/src/man/trial_hierarchy.md`.
- **New files:** none.
- **Breaking changes:** Yes — `trialID(::Vector{Sampling})` becomes a pure lookup returning `Union{Int,Nothing}`
  instead of find-or-INSERT (decided; see below). Requires a **`0.9.0` bump**. The rest is additive.
- **DB schema:** no change, no `src/up.jl` migration.

### In scope (recommended)

Six items, all in `src/classes.jl` unless noted. The unifying rule: **ID accessors and trivially-derived
accessors on wrapper types only** — functions whose entire job is to answer "which objects does this refer
to".

1. `monadIDs(output::MMOutput)` — the request. Sits next to `simulationIDs(output::MMOutput)` at
   `src/classes.jl:861`.
2. `monadIDs(simulation::Simulation)` — the real bug. Insert with the other `monadIDs` methods at
   `src/classes.jl:790-794`.
3. `monadIDs(gsa_sampling::GSASampling)` in `src/sensitivity.jl`, immediately after
   `simulationIDs(gsa_sampling::GSASampling)` at `:44`, with its own docstring mirroring `:39-43`.
4. `Base.length(output::MMOutput)` — mirrors `Base.length(T::AbstractTrial)` at `src/classes.jl:45`.
5. `trialFolder(output::MMOutput)` — mirrors `trialFolder(T::AbstractTrial)` at `src/classes.jl:803`.
6. Docstrings for the two exported-but-undocumented names `trialType` (`:35`) and `trialID` (`:43`), plus an
   update to the shared `monadIDs` docstring at `:784-789`.
7. `trialID(::Vector{Sampling})` → pure lookup returning `nothing` on no match, with find-or-create extracted
   into an internal `_findOrCreateTrialID` for the `Trial` constructor. **Breaking; `0.9.0` bump.**

### Out of scope, and why the line is there

Over-widening a one-line request is the real risk here.

- **`simulationsTable` / `monadsTable` / `postProcessingTable` accepting an `MMOutput`.** These are not
  accessors; each is a family of 4 methods with a `Vararg` form and a documented keyword surface
  (`src/database.jl:1061`, `:1130`, `:1354`). Forwarding all three properly means ~12 new methods plus
  docstring edits on three exported functions, for a case where `simulationsTable(out.trial)` is one word
  longer. `out.trial` is a *documented public field* (`src/classes.jl:835`), not an internal reach-in.
- **`untag!` / `tags` / `hasTag` on `MMOutput`.** `tag!(output::MMOutput, ...)` exists at `src/tags.jl:342`
  for a specific reason: it returns `output` so it chains with the `tags=` keyword ergonomics. The three
  read/remove functions have no such motivation, and adding them invites the same question about
  `tagsTable`, `findTrials`, `deleteSimulations`, and everything else taking an `AbstractTrial`. The
  stopping rule has to be somewhere; "ID accessors" is defensible, "everything that takes an
  `AbstractTrial`" is not.
- **Making `MMOutput <: AbstractTrial`** — argued against below.

## Proposed Architecture

### Forwarding mechanism: hand-written methods, no `trial()` accessor

**(a) Hand-written forwarding methods per function** — the current style at `src/classes.jl:861-863`.
**Chosen.**

**(b) A `trial(out::MMOutput)` unwrapping accessor.** Rejected for a concrete reason: `trial` must not be
exported. Users routinely write `trial = createTrial(inputs, dv)` at top level, and if `ModelManager` exports
a binding named `trial`, that assignment fails with
`cannot assign a value to imported variable ModelManager.trial from module Main`. Unexported-but-`@compat public`
avoids the hazard but produces an accessor nobody will type (`ModelManager.trial(out)` is strictly worse than
`out.trial`). Since `MMOutput`'s docstring already documents `trial` as a field (`:835`), the field *is* the
accessor. If a later brief wants a function, `trialOf` is the safe name.

**(c) Making `MMOutput` iterate or convert.** Rejected. `MMOutput` is not a collection, and an implicit
`convert(AbstractTrial, ::MMOutput)` would silently satisfy every `AbstractTrial` signature in the package —
including `run(::AbstractTrial)`, which would collide with the deliberate
`run(output_ref::MMOutput{<:AbstractMonad}, args...)` at `src/user_api.jl:200`, whose meaning is "build a
*new* trial using this as a reference", not "re-run this".

**Do not make `MMOutput <: AbstractTrial`.** Two hard blockers: (i) `MMOutput` has no `id` field, so
`trialID(T::AbstractTrial) = T.id` (`:43`), `trialFolder(T::AbstractTrial)` (`:803`), `lowerClassString`,
and every `T.id` in `src/runner.jl`, `src/tags.jl`, `src/deletion.jl` would break or need guards;
(ii) `run(::AbstractTrial)` would start accepting an `MMOutput` and re-running it, silently changing the
semantics above. Also, `MMOutput{T}`'s type parameter is what makes `trialType(::MMOutput{T})` a
compile-time answer — that property is lost the moment it joins the hierarchy under an abstract supertype.

### ⚠ `monadIDs(::Simulation)` must be a pure SELECT, not `Monad(simulation).id`

**This is the one non-obvious correctness decision in the brief.** `Monad(simulation::Simulation)` at
`src/classes.jl:459-463` **writes to the database**: it runs `INSERT OR IGNORE INTO monads ... RETURNING monad_id`
(via the `Monad(inputs, variation_id)` constructor at `:389`) and then `addSimulationID(monad, simulation.id)`,
which rewrites the monad's `simulations.csv`. That is correct for
`pendingSimulationSpecs(simulation::Simulation)` at `src/runner.jl:195`, where creating the enclosing monad
is the point — but completely wrong for an accessor. **`monadIDs(sim)` must never create a row.**

The read-only equivalent exists because `simulations` and `monads` share the same key columns: compare
`simulations_schema` (`src/database.jl:117-126`) and `monadsSchema()` (`:189-204`) — both carry
`simulatorVersionIDName(sim)`, `inputIDsSubSchema()` and `inputVariationIDsSubSchema()`, and `monads`
declares `UNIQUE` over exactly that tuple (`:199-202`). The `simulations` table has **no** `monad_id`
column, so the key-match SELECT is the only non-CSV-scanning route. The `Monad(inputs, variation_id)`
constructor already contains the query to copy, in its `isempty(inserted)` fallback branch at
`src/classes.jl:411-419`.

Implementation shape (new private helper beside the other `monadIDs` methods):

```julia
_monadIDForKey(inputs::InputFolders, variation_id::VariationID) -> Vector{Int}
monadIDs(simulation::Simulation) = _monadIDForKey(simulation.inputs, simulation.variation_id)
```

`_monadIDForKey` is one `constructSelectQuery("monads", "WHERE <key>=<values>"; selection="monad_id")`,
returning `Int[]` on no match.

**Semantics to document explicitly:** a `Simulation` returned by `createTrial(inputs, dv; n_replicates=1)`
has **no monad row yet** — the row is created by `run` via `pendingSimulationSpecs`. So `monadIDs(sim)`
returns `Int[]` before the first `run` and `[mid]` after. Returning an empty vector rather than throwing is
right: `monadIDs` returns a `Vector` everywhere else, `monadIDs(trial)` already uses `init=Int[]` for the
empty case (`:793`), and `monadsTable(unrun_simulation)` returning an empty table is a far better answer than
an error. State this in the docstring and pin it with a test — it is genuinely surprising.

### Docstring work

**Why `checkdocs=:exports` currently passes.** `docs/make.jl:68` sets `checkdocs=:exports`, which audits
*docstrings that exist* and errors if any is not included in a rendered page. `trialID` and `trialType` have
no docstring at all, so they contribute no entry to `Docs.meta(ModelManager)` and are invisible to the
check. **This is not a live docs failure.** It *is* a violation of CLAUDE.md's Definition of Done item 2,
and this brief is the natural place to fix it since it touches exactly those lines. Once the docstrings
exist they render automatically via the `Pages = ["classes.jl"]` / `Private = false` autodocs block in
`docs/src/lib/classes.md` — no `docs/make.jl` edit needed, since both names are exported.

**The shared `monadIDs` docstring** (`:784-789`) should enumerate the methods explicitly — including the new
`Simulation` and `MMOutput` forms — and state the `Int[]`-for-no-monad rule. Do the same tightening for
`simulationIDs` (`:771-776`), which is vague and omits the `MMOutput` form that already exists at `:861`.

**`@ref` discipline.** Safe to link: `MMOutput`, `Simulation`, `Monad`, `Sampling`, `Trial`,
`simulationIDs`, `monadIDs`, `constituentIDs`, `trialFolder`, `run`, `createTrial`, `monadsTable` (all
exported from `src/ModelManager.jl:28-40`), and `GSASampling` (`@compat public` at `src/sensitivity.jl:29-30`).
**Not** linkable — use plain code spans: `_monadIDForKey`, `pendingSimulationSpecs`, `addSimulationID`,
`constituentType`, `lowerClassString`. The `"docstrings only @ref public bindings"` testset
(`test/runtests.jl:4310`) is the guard and catches a mistake without a docs build.

### `trialID(::Vector{Sampling})` becomes a pure lookup — DECIDED

`trialID(samplings::Vector{Sampling})` at `src/classes.jl:680-698` is **not an accessor**. It scans every row
of `trials` and, on a miss, `INSERT`s a new trial row, calls `recordConstituentIDs(Trial, id, sampling_ids)`
and `applyCreationTags(Trial, id)`. It shares an exported name with `trialID(T::AbstractTrial) = T.id`
(`:43`), whose semantics are the exact opposite. It is also one of the two find-or-insert blocks named in
CLAUDE.md's "Known Trade-offs" as unsafe under concurrent trial creation.

**The user has decided: make it a pure lookup that returns `nothing` when no trial matches those samplings.**
This is better than the rename this brief originally proposed — it keeps the exported name and makes it
*honest*, consistent with `trialID(::AbstractTrial) = T.id`, instead of hiding a writer behind an accessor's
name.

```julia
trialID(samplings::Vector{Sampling}) -> Union{Int,Nothing}   # pure SELECT; nothing on no match
```

Use `nothing`, not `missing`: it matches Julia's `findfirst`/`tryparse` convention for "no result", and this
repo already uses `missing` for a different meaning — absent/unknown *data* in a DB sense, as in
`eraseSimulationIDFromConstituents(simulation_id; monad_id=missing)` (`src/runner.jl:490`). Note the return
type is then `Union{Int,Nothing}` for this method while `trialID(::AbstractTrial)` returns `Int`; that is fine,
they are separate methods.

**The creation path must move, not vanish.** The one internal caller,
`Trial(Ss::AbstractArray{<:AbstractSampling})` at `src/classes.jl:667`, genuinely needs find-or-create. Extract
that into an internal `_findOrCreateTrialID(samplings::Vector{Sampling})` — lookup via the new `trialID`, then
the existing `INSERT` + `recordConstituentIDs` + `applyCreationTags` block on a miss — and have the `Trial`
constructor call it. The insert logic is unchanged; only its entry point moves.

**Verified blast radius:** exactly **one** internal caller (`:667`). Zero occurrences in `test/runtests.jl`.
Zero in `docs/`. Breaking, and `Project.toml:3` declares `0.8.4`, so this needs a **`0.9.0` bump** — the user
has agreed to it.

`_findOrCreateTrialID` is internal, so it may only appear in docstrings as a plain code span, never `@ref`
(CLAUDE.md). `trialID`'s new docstring must document all three methods and state the `nothing` case
explicitly, with a test pinning it.

Note for brief 04: that brief may make find-or-create *load-bearing* (a `Trial` per generation), so it will
call `_findOrCreateTrialID` rather than `trialID`. Record the split in `progress.md`.

## Testing Strategy

Fixtures `xp_x`, `xp_y`, `inputs` are defined at `test/runtests.jl:2144-2146` inside the
`"DB-backed integration"` block (`:2094`), so DB-backed additions must live inside that `mktempdir` scope.

- `"constituentIDs and simulationIDs"` (`:2282`) — rename to
  `"constituentIDs, simulationIDs, and monadIDs"`. Add `length(monadIDs(samp)) == 3`;
  `monadIDs(Monad(monadIDs(samp)[1])) == [that id]`; `monadIDs(samp) == constituentIDs(samp)`.
- `"monadsTable"` (`:2295`) — the regression test for the documented-but-broken promise. Add
  `nrow(monadsTable(sim)) == 1` for a *run* simulation; `nrow(monadsTable([sim, monad])) == 2`; and the
  pre-run case — a simulation from `createTrial(...; n_replicates=1)` never run gives
  `monadIDs(sim) == Int[]` and `nrow(monadsTable(sim)) == 0`.
- `"run/createTrial over a vector"` (`:2252`) — already asserts `trialType(out) == Trial` at `:2266`. Add
  `monadIDs(out) == monadIDs(out.trial)`; `length(out) == length(out.trial)`;
  `trialFolder(out) == trialFolder(out.trial)`; `simulationIDs(out) == simulationIDs(out.trial)`;
  `trialID(out) == out.trial.id`.
- `"GSA — MOAT"` (`:3039`) — add
  `sort(monadIDs(samp)) == sort(unique(vec(Matrix(ModelManager.getMonadIDDataFrame(samp)))))` to pin that the
  flat form agrees with the design matrix.
- **The most important new test — non-mutation.** Capture
  `nrow(queryToDataFrame(constructSelectQuery("monads")))` before and after calling `monadIDs(sim)` on an
  unrun simulation and assert it is unchanged. This is the test that would have caught a
  `Monad(simulation).id` implementation.
- `"docstrings only @ref public bindings"` (`:4310`) runs automatically over the new docstrings.
- **`trialID(::Vector{Sampling})` returns `nothing`** for a sampling set with no trial row, and does NOT create
  one — assert the `trials` row count is unchanged across the call, the same non-mutation discipline as
  `monadIDs(::Simulation)`. Then assert `Trial([samp1]) isa Trial` still works (already covered at `:2270`),
  proving the extracted `_findOrCreateTrialID` kept the creation path intact.

**Docs:** `docs/src/man/trial_hierarchy.md:116` lists `simulationIDs`, `constituentIDs`, `trialID` as the
helper functions — add `monadIDs`.

## Estimated Effort

- **Lines of code:** ~45 implementation (five one-liners, `_monadIDForKey`, and the `trialID`/`_findOrCreateTrialID`
  split), ~80 docstrings, ~55 tests.
- **Risk level:** Low. The only non-trivial correctness question is the non-mutating `monadIDs(::Simulation)`,
  and it is directly pinned by a test.
- **Dependencies:** none.

## Open questions for the user

None outstanding. The one decision this brief carried — what to do about `trialID(::Vector{Sampling})` — has
been settled: make it a pure lookup returning `nothing`, move find-or-create to an internal, and take the
`0.9.0` bump.

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
- [ ] Non-mutation tests present and passing for BOTH `monadIDs(::Simulation)` and `trialID(::Vector{Sampling})`.
- [ ] `Project.toml` version bumped to `0.9.0` (breaking: `trialID(::Vector{Sampling})` no longer creates).
- [ ] `trialID` and `trialType` now have docstrings with description, arguments, return value, and an example.
- [ ] Docs written outside-in per the rule above; no repo history in `docs/`.
- [ ] `README.md` Implementation Status updated if the accessor surface is listed there; `PRD.md` matches.
- [ ] `progress.md` records the `trialID` lookup/create split and why `MMOutput` stays outside `AbstractTrial`.
