# Planning briefs

Each file here is a **pre-filled design brief** in the format CLAUDE.md's "Required Workflow for Any Change"
mandates. A fresh Claude Code session can be launched directly from one: every brief is self-contained, cites
verified `file:line` anchors, names the `test/runtests.jl` testsets to extend, and flags whether its schema
change needs a `src/up.jl` migration or is additive.

A brief is a *proposal*, not an approval. The session that picks one up should still present it to the user,
get sign-off, create its branch ref, and log to `progress.md` as it goes.

## Execution order

| # | Brief | Topic | Risk | Why here |
|---|---|---|---|---|
| 1 | [01-migration-guard.md](01-migration-guard.md) | Mid-session package update skips a DB migration | Low | Silent data-integrity corruption. Independent. Do it first, unconditionally. |
| 2 | [02-id-accessor-symmetry.md](02-id-accessor-symmetry.md) | `monadIDs(::MMOutput)` and accessor gaps | Low | Trivial, zero interaction; also settles `trialID(::Vector{Sampling})`, which #4 may make load-bearing. |
| 3 | [03-failed-sim-records.md](03-failed-sim-records.md) | Record failed sims for post-hoc inspection | Low-Med | `runner.jl` only. Record-only; automatic retry was considered and rejected. |
| 4 | [04-calibration-sampling-views.md](04-calibration-sampling-views.md) | Calibration as a poset of `Sampling` views; taggable `Calibration` | Med-High | **Gate for #5–#8.** Settles the types and tagging machinery they build on. |
| 5 | [05-calibration-api-and-tagging.md](05-calibration-api-and-tagging.md) | Unify `runABC`/`runCalibration`/`resumeABC`/`ABCSMC`; `description` vs tags | Med | **Gate for #6–#8.** Settles the keyword surface. Fixes a live crash. |
| 6 | [06-distance-distribution-plot.md](06-distance-distribution-plot.md) | Distance histogram with accepted tail; unambiguous epsilon names | Med | Persistence first, recipe second. |
| 7 | [07-shared-study-objects.md](07-shared-study-objects.md) | Build once, use for sensitivity and calibration | Low→Med per stage | Staged. Stage 1 is independently valuable and gates #8. |
| 8 | [08-bayesflow-scoping.md](08-bayesflow-scoping.md) | BayesFlow options + training-set export | Low-Med | Last. Decision document plus one concrete increment. |

## Parallelism

- **`{1, 2, 3}` are mutually independent** — run them in three worktrees at once if you like.
- **`{5, 6}` is the only safe pair inside `src/calibration/`.** They touch disjoint regions of `abc.jl`:
  #5 owns the entrypoint section (`~:265-403`) and the serializer section (`~:436-469`, `~:1071-1094`);
  #6 owns the persistence section (`~:1096-1328`) plus `abc_smc.jl` and `visualize.jl`.
- **Everything else in `src/calibration/` is strictly sequential.** #4, #5, #7 and #8 all contend for the same
  files.

## Cross-brief dependencies

```
01 ─┐
02 ─┼─ independent
03 ─┘

04 ──▶ 05 ──▶ 06        (05 ∥ 06 is safe)
        │
        └───▶ 07 Stage 1 ──▶ 08
```

- **04 before 05:** 04 makes `Calibration` taggable (by moving `include("tags.jl")` last and adding per-type
  methods), so `tag!(calibration, …)` works. 05 adds the `tags=` *keyword*, and it must come second — 05 gives
  `runABC` a `kwargs...` splat into `ABCSMC(; kwargs...)`, so a `tags=` keyword added first would later be
  silently swallowed.
- **05 before 06, 07 Stage 2+, 08:** it settles the keyword surface and the `method.toml` `"type"` key.
- **07 Stage 1 before 08:** `ParsedVariations(::CalibrationProblem)`.
- **02 relates to 04:** both touch `monadIDs`. 02 also splits `trialID(::Vector{Sampling})` into a pure lookup
  plus an internal `_findOrCreateTrialID`; if 04 gives each generation a `Trial` row it must call the latter.
- **`calibrationMonadIDs` is fixed by whichever of 04 / 05 lands first.** Both name it; record it in
  `progress.md` so the other session does not redo it.

## Two rules every brief carries

**Review-only comments are marked `#REVIEW:` and stripped before merge.** The repo already uses `#!` for
*permanent* design-rationale comments (316 of them), so review scaffolding needs its own marker. Every brief's
pre-merge checklist requires `rg '#REVIEW:' src/ test/` to return nothing. Write as much explanatory comment as
helps the review — just mark it.

**Docs explain how to use the code as it now is, never how we got here.** User-facing prose is for an outside
reader with no knowledge of this repo's history. Where a "why" is needed it must be the grand-narrative why:

> ✅ "Updates are delayed until the next Julia session so as not to corrupt the currently loaded session state."
> ❌ "Updates must be delayed because updating mid-session had the potential to produce incorrect session states where upgrades would never actually proceed."

The second sentence belongs in `progress.md`, which is where each session logs its decisions anyway.

## Decisions already made by the user

These are settled — the briefs reflect them, and a session should not reopen them:

- **No automatic retry of failed simulations** (item 3). Re-running after an error is not good form, and
  ModelManager cannot distinguish a transient fault from a deterministic one. Left to the user to manage.
  `output.err` must never be deleted on a failed simulation.
- **`trialID(::Vector{Sampling})` becomes a pure lookup** returning `nothing` on no match, with find-or-create
  moved to an internal (item 2). Breaking; takes a `0.9.0` bump.
- **`tags.jl` moves to the bottom of the include list** and stays there as more types gain tagging methods
  (item 4) — rather than introducing an `AbstractTaggable` supertype.
- **The epsilon rename lands**, including the user-visible `ConvergenceSummary` column (item 6).

## Baseline

Verified green on `claude/planning-simulation-topics-08b7bf` at the time these were written:
`1423/1423` tests passing via `julia --project=. -e 'using Pkg; Pkg.test()'`.
