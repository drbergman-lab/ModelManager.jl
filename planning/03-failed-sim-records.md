# Design Brief: Preserve failed-simulation context for post-hoc inspection

> **⏭ SKIPPED — the user chose not to pursue this.** Kept for the record. The analysis below still
> stands, including the two corrected premises in the CLAUDE.md to-do (the `simulations` row and its
> output folder both survive a failure, so variation IDs are already recoverable) and the finding that
> `output.err` already sits outside the prunable `output/` directory. Revisit only if the missing
> sim→monad linkage becomes a real obstacle.

> **Order:** 3 of 8. Independent of every other brief — safe to run in parallel with 01 and 02.
>
> **Scope note:** an earlier draft of this brief paired the failure record with an `n_retries` keyword on
> `run` that would auto-rerun failed simulations. **The user has walked that back deliberately** — see
> "Automatic retry: considered and rejected" below. Do not reintroduce it. This brief is now record-only,
> which also drops it from Medium-High risk to Low-Medium: no concurrency changes at all.

> **⚠ Line-number anchors were verified at commit `403530e`, before PRs #30 (migration guard),
> #31 (accessor gaps) and #32 (calibration `Sampling` views + tagging) merged.** Those PRs added ~237 lines to
> `src/tags.jl`, ~370 to `src/calibration/calibration.jl`, and touched `src/classes.jl`, `src/sensitivity.jl`,
> `src/ModelManager.jl`, `src/database.jl` and `src/calibration/abc.jl`. Every **symbol** named below still
> exists; some **line numbers have shifted**. Locate each anchor by symbol name (`rg 'functionName' src/`) and
> re-verify before relying on it. `src/runner.jl` is unaffected.

## Preflight

1. Read `CLAUDE.md`: the design-brief-first workflow, `camelCase` functions / `snake_case` kwargs, the rule
   that docstrings may `@ref` **only** exported or `@compat public` bindings, the Definition of Done, and the
   "## To-dos" entry about preserving failed-simulation artifacts (this brief implements it, with two of its
   premises corrected below).
2. Read `docs/src/man/running_simulations.md` §"Status tracking" and `docs/src/man/tagging.md`.
3. Per CLAUDE.md step 2: update `PRD.md` §"Feature: Simulation Runner" and open a dated `progress.md` entry.
4. `git branch feature/failed-sim-records`, then have the user check it out before you code.
5. All paths are repo-relative. Work only inside your worktree.

## Motivation

Nothing durably links a failed simulation to the monad it belonged to. When that monad (and possibly its
sampling) is deleted, the link and the monad's tags are unrecoverable, so a calibration rejection cannot be
reproduced afterwards.

## Two corrections to the CLAUDE.md to-do's premises

Verify both before designing — they shrink the feature sharply.

1. **The `simulations` row survives.** `simulationFailed` only `UPDATE`s `status_code_id`
   (`src/runner.jl:12`), and the monad deletion passes `delete_subs=false` (`:514`), so the row *and* the
   output folder both persist.
2. **The parameter values survive too.** The row carries every `<loc>_variation_id`, and no deletion path
   removes a row from a per-location variations DB — `deleteSimulations` deletes only the compiled
   per-variation XML, and only when no simulation still references it (`src/deletion.jl:47-66`). So
   `simulationsTable([sim_id])` (`src/database.jl:1068`) already reconstructs the full parameter set, and
   `findSimulationIDs(status="Failed")` (`src/tags.jl:1168`) already enumerates every failed simulation.
   The to-do's claim that target parameter values "exist only transiently" is not true post-hoc:
   `_createMonadForParams` (`src/calibration/abc.jl:15-28`) discards its `DiscreteVariation`s, but
   `addVariations` has by then persisted them.

## What is genuinely lost

- **The sim→monad linkage.** `simulations` has no `monad_id` column —
  `abstractSamplingForeignReferenceSubSchema` (`src/database.jl:246-258`) emits FK declarations only for the
  version and input-folder columns. The link lives solely in the monad's `simulations.csv`, which
  `eraseSimulationIDFromConstituents` rewrites (`:517-518`) or `deleteMonad` deletes
  (`src/deletion.jl:124`). Nuance: *while the monad row exists*, the link is reconstructible by matching the
  simulation's input+variation IDs against `monads` — the trick `eraseSimulationIDFromConstituents` itself
  uses when handed `monad_id=missing` (`src/runner.jl:492-507`). It becomes unrecoverable only in the
  last-simulation case — which is the common case for calibration at `n_replicates=1`.
- **The monad's ID, row and tags** (`deleteTagsFor(Monad, …)`, `src/deletion.jl:118`), and — when the monad
  was its sampling's last — the sampling row and *its* tags (`src/deletion.jl:161`). That is where
  `mm:calibration`/`mm:generation` live (`src/calibration/abc.jl:169`), so the existing tag mitigation
  evaporates precisely in the worst case.
- **The pairing needed to reproduce a calibration rejection.**
  `generation_{NNN}_failed_simulations.csv` gives failed sim IDs, `..._failed_monads.csv` gives failed monad
  IDs (`src/calibration/abc.jl:1122`, `:1134`), and `generation_cdfs/generation_{NNN}.csv` gives CDF
  coordinates keyed by `monad_id` (`:1263`). With three failures across three monads you hold three sim IDs
  and three monad IDs and **no pairing** — and the monad rows are gone, so it cannot be re-derived. This is
  the precise gap.
- Provenance is *not* lost: `provenance_id` sits on the surviving row.

## Scope

- **Files affected:** `src/runner.jl` (`simulationFailed`, `:11-14`), `src/database.jl` or `src/tags.jl`
  (new read path), `src/ModelManager.jl` (two exports), `docs/src/man/running_simulations.md` (§"Status
  tracking"), `docs/src/man/tagging.md` (`mm:` key table), `docs/src/man/managing_data.md`, `PRD.md`,
  `README.md`, `test/runtests.jl`.
- **New files:** none.
- **Breaking changes:** none. **No schema change, no new table, no new column, therefore no `src/up.jl`
  migration milestone.** Everything rides the existing `tags` table, created idempotently from `createSchema`
  (`src/database.jl:142-147`, whose comment documents exactly this exemption).

## Proposed Architecture

### Where the record lives: reserved tags + a per-simulation manifest

**Recommended: reserved `mm:` tags on the surviving `simulations` row, plus a human-readable manifest in the
simulation's own folder.** Explicitly **not** the to-do's literal `data/outputs/failed/` proposal.

Tags, written with `tagReserved!(<Simulation object>, …)` (`src/tags.jl:355`) — `tag!` rejects the reserved
`mm:` namespace:

| key | value |
|---|---|
| `mm:failed` | `""` — bare marker; a bare key in a *query* means "has this key with any value" (`src/tags.jl:1056-1058`) |
| `mm:failed.monad` | the monad ID |
| `mm:failed.at` | ISO-8601 stamp, formatted like `MM_CREATED_KEY` (`"yyyy-mm-ddTHH:MM:SS"`, `src/tags.jl:997`) |

Dots are legal in tag keys (`TAG_KEY_BODY_REGEX`, `src/tags.jl:29`; precedent `mm:git.branch`).

Manifest at **`joinpath(trialFolder(Simulation, sim_id), "failure.toml")`** — deliberately *not* under
`pathToOutputFolder` (`src/classes.jl:824`), because `simulationFailed` runs at `src/runner.jl:452` *before*
`postSimulationCleanup` (`:466`), and a backend that prunes `output/` would delete a manifest written inside
it. Contents: `simulation_id`, `monad_id`, `datetime`, the varied `variation_ids`, the flattened parameter
row (dump the single row of `simulationsTable([sim_id]; remove_constants=false, short_names=false)` so the
record is self-contained without the DB — **do not** use `getAllParameterValues`, which re-materializes XML
via `createXMLFile` that cleanup may have removed), the monad's own variation IDs and
`tags(Monad, monad_id)` captured while it still exists, and `output_folder` with an `isdir` flag.

### ⚠ `output.err` must survive — verify, then pin it

The user's explicit requirement: **do not delete `output.err` on failed simulations; it is essential for
debugging.** Good news — this already holds structurally, and the brief's job is to verify and *pin* it rather
than build anything:

`prepareHPCCommand` writes `output.log` and `output.err` to `trialFolder(Simulation, id)`
(`src/runner.jl:80-86`), which is a **sibling** of `trialFolder(Simulation, id)/output/` — the directory
`pathToOutputFolder` names (`src/classes.jl:824`) and the only thing a backend's `postSimulationCleanup`
would plausibly prune. So the stderr file is already outside the pruning target.

Two things to do about it:
- Add `output_err` and `output_log` path entries to the manifest, each with an `isfile` flag, so a user
  reading `failure.toml` is pointed straight at the diagnostics.
- Add a test asserting that after a failed simulation the `trialFolder` still contains whatever the backend
  wrote there. Note that locally **nothing captures streams at all** — only the HPC path redirects them — so
  the test must not assume `output.err` exists; assert that MM does not *remove* files it finds there.

Also state plainly in the docs that local runs capture no stderr; `src/runner.jl:360` already tells users to
"Check the output.err files", which is misleading off-HPC. Correcting that sentence is in scope.

### Why tags over a new table or a `failed/` area

- Tags give the query path, the table-append path (`simulationsTable(…; tags=true, include_auto_tags=true)`),
  the deletion cleanup and the docs vocabulary **for free** from 1448 already-tested lines. Nothing new for
  a user to learn.
- The EAV cost objection that pushed provenance into columns (`src/tags.jl:38-44`) does not apply: it was
  decisive because provenance touches *every* object; failures are a small fraction. That asymmetry is
  exactly what makes tags right here and wrong there.
- A `failed_simulations` table would duplicate `simulations` columns and need its own deletion hook, reader,
  docs and diagnostics — for information that fits in three tag rows. It **is** the right answer if
  per-*attempt* rows with timings are ever wanted (tags cannot hold a time series), but with automatic retry
  now off the table there are no attempts to record. Name it as the escape hatch and move on.
- `data/outputs/failed/` is a third location for simulation data to keep consistent with two others, with no
  query path, no natural cleanup, and one more path `rm_hpc_safe` can leak into `data/.trash/`
  (`src/deletion.jl:476`). If the goal is "one place to see all failures", that is a *function*, not a
  folder.

### Write site: inside `simulationFailed`

Insert `_recordFailedSimulation(simulation_id, monad_id)` at `src/runner.jl:13`, between the status `UPDATE`
and `eraseSimulationIDFromConstituents`. `simulationFailed` is:

- the single choke point every failure passes through (its only caller today is
  `updateDatabaseOnCompletion` `:480`, but placing it here means no future caller can bypass it);
- the **last moment the monad still exists**.

The concurrency objection that applies to `recordConstituentIDs` does not apply here: `_insertTagRows` is a
plain `INSERT` guarded by `UNIQUE` (`src/tags.jl:80-88`) and the TOML write targets a per-simulation path, so
there is no shared mutable state. Rejected alternatives: `processSimulationTask` (`:452`, duplicates what
`simulationFailed` funnels) and `deleteMonad` (`src/deletion.jl:116`, also reached by user-invoked deletion,
where recording a "failure" is wrong).

### Automatic retry: considered and rejected

Record this in `progress.md` as a decision, following the repo's existing "considered and rejected" precedent
(see the 2026-07-07 "String variation values" entry). A future session should not have to re-derive it.

The user's reasoning: **re-running a simulation after an error is not good form.** ModelManager cannot tell a
transient fault from a deterministic one — `SimulationProcess` carries only `success::Bool`
(`src/runner.jl:31`), the backend produces it, and MM never sees an exit code or a signal. The only case that
would justify a retry is a clearly-identifiable transient infrastructure fault, such as an HPC node crash, and
distinguishing that is not feasible at this layer. So retry is left to the user to manage.

This is consistent with a call the codebase already made: `src/calibration/abc.jl:130-132` documents a
deliberate decision **not** to re-run to "top off" missing replicates.

Consequence for this brief: the failure record is written once, at the only failure, so there is no notion of
attempts — no `mm:failed.attempts` key, no `mm:retries` key, no `n_retries`/`retry_delay` keywords, and no
change to the task pool at `src/runner.jl:274-329`.

### Calibration's existing CSVs: keep as-is

`_recordBatchFailures` (`src/calibration/abc.jl:1165`) stays untouched. It answers a different question
("which simulations failed in generation 3?"), it is what `on_monad_failure=:error` points the user at
(`:128`), and it is covered by tests at `:2653-2667` and `:2758-2792`. Add one sentence to `runABC`'s
docstring pointing from those files to the per-simulation record.

### Retention

Nothing new to prune. Tag rows die with the simulation via `deleteTagsFor(Simulation, ids)`
(`src/deletion.jl:44`); the manifest dies with the folder via `rm_hpc_safe(trialFolder(Simulation, id))`
(`:48`); `resetDatabase` clears everything. The record's lifetime is exactly the simulation's lifetime — the
correct invariant, and the main reason this beats a separate `failed/` area needing its own reaper.
`deleteSimulationsByStatus(["Failed"])` (`src/deletion.jl:339`) remains the "clear my failures" verb and
destroys the record by design; document that.

### Read path

Existing API covers most of it: `findSimulationIDs(tags=("mm:failed",))`,
`findSimulationIDs(status="Failed")`, `tags(Simulation, id)`,
`simulationsTable(ids; tags=true, include_auto_tags=true)`. Add one named entry point for discoverability,
mirroring the `printSimulationsTable`/`printMonadsTable`/`printPostProcessingTable`/`printTagsTable` family:

```julia
failedSimulationsTable(; kwargs...)                                    # exported
printFailedSimulationsTable(args...; sink=println, kwargs...)          # exported
```

defaulting to
`simulationsTable(findSimulationIDs(status="Failed"); tags=true, include_auto_tags=true, remove_constants=false, kwargs...)`.
Both need a docstring with a usage example (Definition of Done #2). `_recordFailedSimulation` is internal and
may only ever appear as a plain code span, never `@ref`. No new docs page — extend §"Status tracking" in
`docs/src/man/running_simulations.md` and add the keys to the `mm:` table in `docs/src/man/tagging.md`.

### Summary

- **Current:** a failure leaves an orphaned `Failed` row whose monad linkage and monad-level context are
  destroyed moments later.
- **Proposed:** at the instant of failure, stamp three reserved tags on the surviving row and drop a
  self-contained TOML manifest beside its output folder, pointing at the stderr file.
- **Key decisions:** tags for the index (free query/cleanup/docs), manifest for the narrative; write inside
  `simulationFailed` because that is the last instant the monad exists; no new table and no migration; **no
  automatic retry**.

## Testing Strategy

- **Unit:** `_recordFailedSimulation` writes both artifacts; the manifest parses and contains the monad's
  variation IDs and the actual parameter value (mirror the value-per-testset discipline of the "reusability
  filter" testset, `test/runtests.jl:2793`, which uses unique values like `41.0` to avoid `use_previous`
  collisions); `mm:failed` is rejected by `tag!` (extend `:3597`); the manifest path is `trialFolder`, not
  `pathToOutputFolder`.
- **Integration:** new testset in the DB-backed block, after `:2737` and before "failure recording and
  reporting" (`:2758`) so `_fail_sim_predicate` (`:66-72`) is in scope — (a) `n_replicates=1`, sole
  simulation fails → monad deleted → `hasTag(Simulation, sid, "mm:failed")`,
  `tags(...)["mm:failed.monad"] == string(mid)`, manifest present and parseable; (b) partially failed monad
  (2 replicates, 1 fails) → monad survives, the failed ID is gone from `simulations.csv` but recorded in the
  manifest; (c) `findSimulationIDs(tags=("mm:failed",))` equals `findSimulationIDs(status="Failed")`;
  (d) `failedSimulationsTable()` has one row per failure with a `tag:mm:failed.monad` column;
  (e) `deleteSimulations([sid])` removes both tag rows and the manifest — extend "tag cleanup on deletion"
  (`:3778`) and "deleteSimulations" (`:3012`).
- **The `output.err` guard:** write a sentinel file into `trialFolder(Simulation, id)` before the run, force
  the simulation to fail, and assert the sentinel is still there afterwards. This pins "MM does not remove
  diagnostics from the simulation folder on failure" without assuming stream capture, which does not happen
  off-HPC.
- Regression guards already in place: `tagKeys()` filters `mm:%` by default (`src/tags.jl:898`), so
  `:3582-3583` and `:3954` are unaffected by new `mm:` keys. Grep for any test asserting an exact `mm:` key
  set.

## Estimated Effort

- **Lines of code:** ~120 in `src/`, ~150 in tests.
- **Risk level:** **Low-Medium.** No concurrency change, no schema change. The one real trap is the
  manifest-vs-cleanup ordering; the second is remembering that local runs capture no stderr.
- **Dependencies:** none.

## Open questions for the user

None outstanding. Both decisions this brief carried have been settled: the record shape is tags + manifest
(not a `failed_simulations` table, not a `data/outputs/failed/` tree), and automatic retry is **rejected**.

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
- [ ] The `output.err` / simulation-folder preservation test is present and passing.
- [ ] `src/runner.jl:360`'s "Check the output.err files" message corrected for the local case.
- [ ] Every new exported binding has a docstring with description, arguments, return value, and a usage
      example.
- [ ] Docs written outside-in per the rule above; no repo history in `docs/`.
- [ ] `README.md` Implementation Status updated; `PRD.md` matches what shipped.
- [ ] `progress.md` records the record-shape decision **and** automatic retry as considered-and-rejected, with
      the reasoning, so it is not re-proposed.
