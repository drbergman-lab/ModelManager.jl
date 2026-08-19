# Design Brief: Distance-distribution plot with the accepted tail highlighted, and unambiguous epsilon names

> **Order:** 6 of 8. Touches disjoint regions of `abc.jl` from brief 05 (this brief: the persistence section
> `~:1096-1328`, plus `abc_smc.jl` and `visualize.jl`; brief 05: the entrypoint section `~:265-403` and the
> serializer section `~:436-469`, `~:1071-1094`). **05 ∥ 06 is the one safe parallel pair** — at worst a
> trivial merge in `abc.jl`.

> **⚠ Line-number anchors were verified at commit `403530e`, before PRs #30 (migration guard),
> #31 (accessor gaps) and #32 (calibration `Sampling` views + tagging) merged.** Those PRs added ~237 lines to
> `src/tags.jl`, ~370 to `src/calibration/calibration.jl`, and touched `src/classes.jl`, `src/sensitivity.jl`,
> `src/ModelManager.jl`, `src/database.jl` and `src/calibration/abc.jl`. Every **symbol** named below still
> exists; some **line numbers have shifted**. Locate each anchor by symbol name (`rg 'functionName' src/`) and
> re-verify before relying on it. `src/runner.jl` is unaffected.

## Preflight

1. Read `CLAUDE.md`: the design-brief-first workflow, the `@ref`-public-bindings-only rule, and the
   Definition of Done.
2. Read `src/sensitivity_visualize.jl` — the repo's reference `@recipe` file (298 lines) — and
   `@testset "GSA plot recipes"` (`test/runtests.jl:3377-3486`). That testset is the template for this one,
   and it is currently the **only** recipe testset in the suite.
3. Per CLAUDE.md step 2: update `PRD.md` and open a dated `progress.md` entry.
4. `git branch feature/distance-distribution-plot`, then have the user check it out before you code.
5. All paths are repo-relative. Work only inside your worktree.

## Motivation

The requested plot — the distribution of all proposal distances for a generation with the accepted left tail
colored — **cannot be produced from the data ModelManager currently stores.** Acceptance happens at
`src/calibration/abc_smc.jl:654-664`:

```julia
if !ismissing(distance) && distance <= epsilon
    n_accepted_this_round += 1
    can_add = method.accept_overflow || length(accepted) < method.population_size
    can_add && push!(accepted, _ParticleResult(proposals[i][1], distance, metadata))
elseif !isnothing(rejected_coords)
    push!(rejected_coords, proposals[i][1])
end
```

A rejected proposal's **distance is dropped on the floor** — only its CDF coordinates are kept, and only when
`store_rejected=true`, which is documented as never persisted (`methods.jl:196-199`) and hardcoded to
`nothing` on load (`abc.jl:1324`). `GenerationResult.distances` (`problem.jl:152`) holds accepted particles
only. The one disk route to rejected particles, `_lazyLoadRejected` / `_lazyLoadRejectedFromDisk`
(`visualize.jl:104-141`, `:58-80`), set-differences `generation_{NNN}_monads.csv` against the accepted
`monad_id` column and re-queries `simulationsTable` — recovering *parameter values*, not distances.
Recomputing rejected distances by re-calling the user's `summary_statistic` is not viable: it is arbitrarily
expensive user code, and monads whose simulations all failed have been deleted.

**A second, independent problem: the word "epsilon" currently means three things and the file records one.**

| Quantity | Today | Value |
|---|---|---|
| Achieved epsilon for generation `t` | **stored** as `generation_{NNN}.toml` key `"epsilon"` (`abc.jl:1272`, from `abc_smc.jl:1007`) | `maximum(distances)` over *accepted* particles |
| Threshold used to build generation `t` | **never stored** (`abc_smc.jl:367-373`) | `epsilon_schedule[t-1]`, else `max(minimum_epsilon, quantile(prev.distances, epsilon_quantile))` |
| Generation 1's threshold | does not exist | generation 1 accepts every proposal (`abc_smc.jl:537`) |

The previous generation's stored value is **not** the next generation's threshold except when
`epsilon_quantile == 1.0`: at the default `0.5` the threshold is the *median* of the previous generation's
accepted distances while the stored value is the *max*.

So this brief is one third persistence, one third naming, one third recipe — plus the first-ever test coverage
for the calibration recipes.

## Scope

- **Files affected:**
  - `src/calibration/problem.jl` — `GenerationResult` (`:148-159`): rename one field, add two, plus a
    back-compat constructor; docstring `:122-147`; `ConvergenceSummary` (`:277-301`, `:329-354`)
  - `src/calibration/abc_smc.jl` — `_runABCSMC` (`:357-380`, threshold plumbing), `_runFirstGeneration`
    (`:485-532`), `_runSubsequentGeneration` (`:592-679`, the acceptance loop at `:653-664`),
    `_buildGenerationResult` (`:998-1013`), `_stoppingReason` (`:426-427`, `:452-458`)
  - `src/calibration/abc.jl` — new `_generationProposalsPath` (beside `_generationMonadsPath`, `:1111`);
    `_saveGeneration` (`:1251-1278`); `_loadGenerations` (`:1292-1328`)
  - `src/calibration/visualize.jl` — new `_DistanceData` + `@recipe`; a `:distances` branch and error-message
    update in the two style-dispatch recipes (`:597-657`, `:673-748`); the convergence recipe (`:350`)
  - `docs/src/man/calibration.md` — `:150-162` (rewrite the plotting block, fixing the `plot_type=` errors)
    and the generation-file list in the troubleshooting section
  - `README.md:79` — Implementation Status
  - `test/runtests.jl` — see Testing Strategy
- **New files:** none. `visualize.jl` is included directly from `src/ModelManager.jl:84` (not from
  `calibration/calibration.jl`) — leave that as is.
- **New on-disk artifact:** `data/outputs/calibrations/{id}/generations/generation_{NNN}_proposals.csv`
- **Breaking changes:** the `GenerationResult.epsilon` field and the TOML `"epsilon"` key are **renamed** (see
  below). No DB schema change and **no `src/up.jl` migration** — these are files, and the reader carries a
  fallback.

## Proposed Architecture

### Part 1 — Epsilon naming: rename, with a one-line read fallback

**Decision (from the user): rename rather than preserve. Make the key say what it holds.**

- `GenerationResult.epsilon` → **`max_epsilon_accepted`**; TOML key `"epsilon"` → `"max_epsilon_accepted"`.
- New field and key **`epsilon_threshold::Union{Nothing,Float64}`** — the cutoff actually used for acceptance;
  `nothing` for generation 1.

The rename propagates to `_buildGenerationResult` (`abc_smc.jl:1007`), `_stoppingReason`
(`abc_smc.jl:426-427` and the `min_epsilon_decrease` comparison at `:452-458`), `_saveGeneration`
(`abc.jl:1272`), `_loadGenerations` (`abc.jl:1317-1320`), `ConvergenceSummary` (`problem.jl:329-354` — note
its output **column** renames too), and the convergence recipe (`visualize.jl:350`). Grep `\.epsilon\b` and
`"epsilon"` and fix every hit.

**The fallback is one line per reader**, and it is what keeps `resumeCalibration` and `ConvergenceSummary`
working on pre-rename runs:

```julia
max_eps = get(d, "max_epsilon_accepted", get(d, "epsilon", nothing))
```

⚠ **Note for whoever writes this:** `_loadGenerations` and `ConvergenceSummary` currently index these keys
**hard** (`d["epsilon"]`, `d["acceptance_rate"]`, `d["ess"]`, `d["n_evaluations"]`), so a missing key is a
`KeyError`, not a `nothing`. Read `epsilon_threshold` with `get(d, "epsilon_threshold", nothing)`.

**Why this cannot ride the migration framework, and what that means.** These artifacts are on-disk TOML under
`data/outputs/calibrations/`, so `upgradeMilestones` does not reach them — and more fundamentally
ModelManager has no upgrade path of its own: `getDBPackageVersion` records the *simulator package's* version
and `upgradeMilestones`/`upgradeToMilestone` are `AbstractSimulator` hooks. A read-fallback is therefore the
only tool available. **Do not invent a migration channel in this brief** — it is logged as a CLAUDE.md to-do.

### Part 2 — Persistence: a new per-generation CSV

**Chosen: a new file. The two alternatives are rejected for concrete reasons.**

*Rejected — extend `generation_{NNN}.csv` with an `accepted::Bool` column and all proposals.* Disqualifying
blast radius on the most-read file in the calibration output:

| Consumer | Breakage |
|---|---|
| `posterior(::Calibration)` `problem.jl:269-272` | `select(df, Not([:weight,:distance,:monad_id]))` would return rejected rows as posterior samples with garbage weights — **silent statistical corruption** |
| `ConvergenceSummary(::Calibration)` `problem.jl:342-343` | `n_accepted` = `nrow(CSV.read(csv; select=[:weight]))` would count all proposals |
| `_readGenCSV` `visualize.jl:683-690` | `Float64.(raw[!,:weight])` breaks once `weight` is `Union{Missing,Float64}` |
| `_vizParticles` `:11`, `_cdfDFToTarget` `:29`, corner recipe `:282` | strip exactly those three columns |
| `_lazyLoadRejectedFromDisk` `:58-80` | set-differences against the accepted `monad_id` column — would find nothing rejected |
| `test/runtests.jl:741` | asserts the exact column set `Set(["alpha","beta","weight","distance","monad_id"])` |

*Rejected — a `rejected_distances` field on `GenerationResult` gated by `store_rejected`.* Cannot serve
`plot(Calibration(42), :distances)` or any post-restart case, which is the main use.

**The design: `generation_{NNN}_proposals.csv`, always written, holding every evaluated proposal that produced
a real distance.**

```
monad_id::Int, distance::Float64, accepted::Bool
```

- **Every proposal, not just rejected ones.** One file means the two histogram series are binned from one
  array — no join, no possibility of mismatched bins, and the reader is a single `CSV.read`. The redundancy
  with `generation_{NNN}.csv`'s `distance` column is ~24 bytes per proposal (~30 KB for a 100×10 run).
- **`accepted` means "passed ε", not "in the posterior".** With `accept_overflow=false` a particle can pass ε
  and still be discarded because the batch overshot `population_size` (`abc_smc.jl:659-660`) — a *third*
  bucket whose distance is discarded today. Recording it as `accepted=true` is the statistically honest
  choice: the histogram describes the acceptance *process*. Document the consequence:
  `sum(proposals.accepted) == n_accepted_total ≥ nrow(generation_{NNN}.csv)`.
- **`missing` distances are not written.** A `missing` distance means the monad had no successful simulation
  (`abc.jl:125-127`) — not a distance, and unhistogrammable; those monad IDs are already in
  `generation_{NNN}_failed_monads.csv`. Keeping them out makes `distance` a plain `Float64` column, so the
  reader needs no `Union{Missing,Float64}` hint and no all-missing-column inference trap. The failed count
  stays recoverable as `n_evaluations - nrow(proposals)`; document the identity
  `n_evaluations = n_accepted_total + n_rejected + n_failed`.
- **Always on, not gated by `store_rejected`.** `store_rejected`'s cost is RAM for a full CDF-coordinate
  `DataFrame`; this is three numbers per proposal on disk. Leave `store_rejected` untouched — it serves the
  `:transition` recipe's CDF coordinates and is orthogonal. Say so in both docstrings.

**`GenerationResult` gains two fields (and renames one), with a back-compat constructor:**

```julia
struct GenerationResult
    …                                            # 9 existing fields; `epsilon` → `max_epsilon_accepted`
    epsilon_threshold::Union{Nothing,Float64}    # cutoff used for acceptance; nothing for gen 1
    proposal_distances::Union{Nothing,DataFrame} # monad_id/distance/accepted, every real distance
end

#! Ten-argument form so every existing positional call site keeps compiling; the two trailing
#! fields are absent for legacy runs anyway.
GenerationResult(t, particles, weights, distances, max_epsilon_accepted, n_evaluations,
                 monad_ids, acceptance_rate, ess, rejected_proposals) =
    GenerationResult(t, particles, weights, distances, max_epsilon_accepted, n_evaluations,
                     monad_ids, acceptance_rate, ess, rejected_proposals, nothing, nothing)
```

This shrinks the diff from ~20 positional call sites to 2 — it preserves `_loadGenerations` (`abc.jl:1322`),
the dummy in `_cdfDFToTarget` (`visualize.jl:25`), and every test construction (`:688`, `:703`, `:825`,
`:895`, …). Same trick as `MOATSampling`'s two-argument convenience constructor (`sensitivity.jl:138`).

Collection in `_runSubsequentGeneration`, replacing `abc_smc.jl:653-664`:

```julia
for (i, (distance, metadata)) in enumerate(results)
    mid = metadata isa Integer ? Int(metadata) : 0     # matches _buildGenerationResult:1006
    if !ismissing(distance) && distance <= epsilon
        n_accepted_this_round += 1
        push!(proposal_rows, (monad_id=mid, distance=distance, accepted=true))
        can_add = method.accept_overflow || length(accepted) < method.population_size
        can_add && push!(accepted, _ParticleResult(proposals[i][1], distance, metadata))
    else
        ismissing(distance) || push!(proposal_rows, (monad_id=mid, distance=distance, accepted=false))
        isnothing(rejected_coords) || push!(rejected_coords, proposals[i][1])
    end
end
```

Note the `elseif` becomes `else` with an inner guard — this **preserves** today's behavior that a
`missing`-distance proposal *does* land in `rejected_coords`. `_runFirstGeneration` builds the same frame with
all rows `accepted=true` and passes `epsilon_threshold=nothing`.

### Part 3 — The recipe

Builder struct plus `@recipe`, matching the file's `_CornerPlotData` / `_RidgelineData` / `_TransitionData`
pattern:

```julia
struct _DistanceData
    edges::Vector{Float64}          # shared bin edges, computed once in the builder
    accepted_counts::Vector{Float64}
    rejected_counts::Vector{Float64}
    epsilon_threshold::Union{Nothing,Float64}
    max_epsilon_accepted::Float64
    t::Int
    logscale::Bool
    note::String
end
```

**Binning is computed in the builder, never delegated to the backend.** Emitting two `:histogram` series and
hoping the backend picks identical bins fails exactly here, because the rejected set extends far to the right
of the accepted set, so per-series auto-binning misaligns the tail. Instead:

1. `all_vals = vcat(accepted, rejected)`; `nbins = clamp(round(Int, sqrt(length(all_vals))), 10, 50)`.
2. **Put the threshold on a bin edge.** Because acceptance is `distance <= ε`, the two sets are disjoint
   except in whichever bin straddles ε. With `w = (max-min)/nbins`, build
   `edges = [ε - i*w for i in k_left:-1:0] ∪ [ε + i*w for i in 1:k_right]` where
   `k_left = ceil(Int, (ε-min)/w)` and `k_right = ceil(Int, (max-ε)/w)`. Uniform width, ε exactly on an edge,
   so the two series occupy **disjoint bins** and two plain overlaid `:bar` series render correctly on any
   backend — no `bar_position := :stack`, which is a Plots-level attribute a backend-agnostic recipe should
   not require.
3. Count with `searchsortedlast` into `accepted_counts` / `rejected_counts`.
4. Emit `:bar` at `midpoints(edges)` with `bar_width := step`, `linewidth := 0`, `fillcolor := :green`,
   `label := "accepted"`; the same in `:red` for rejected; and the threshold as `seriestype := :path` over
   `[ε, ε], [0, maxcount]` — **not** `:vline`, since `sensitivity_visualize.jl` deliberately restricts itself
   to `:bar`/`:violin`/`:scatter`/`:path` for backend portability (see its note at `:195`).

**No new dependency.** `RecipesBase` (hard dep, `Project.toml:33`) and `Statistics` (`ModelManager.jl:6`)
suffice. The repo has **zero precedent for package extensions** — no `[weakdeps]`, no `[extensions]`, no
`ext/` — and needs none here.

Two defaults worth a sanity check but with clear answers:

- **Unweighted by default.** The subject is the proposal→acceptance process, i.e. counts of what the sampler
  evaluated. Importance weights describe the posterior, and rejected proposals have no weight at all, so a
  weighted accepted series against an unweighted rejected series is not comparable. Offer
  `weighted::Bool=false`; when `true`, weight only the accepted series (sum-of-weights per bin, rescaled by
  `length(accepted)` so both stay on one axis) and append a note.
- **Linear x by default**, with `logscale::Bool=false`. Squared-error distances often span orders of
  magnitude, so log is frequently more readable, but linear matches the zero-surprise default of every other
  recipe in the file. Under `logscale=true`, bin in `log10` space, set `xscale := :log10`, and filter
  non-positive distances (`mseDistance` legitimately returns `0.0` on a perfect match) with the count
  appended to `note` rather than raising.

**Entry points, mirroring the existing pairing.** Add `:distances` to both style-dispatch recipes and extend
their error messages (`visualize.jl:655`, `:746`) from "Use :ridgeline or :transition." to include
`:distances`; update the two dispatch docstrings (`:580-596`, `:659-672`).

- `ABCResult` (`:597`): `generation=` resolution already yields `T` for non-`:transition` styles (`:604-608`)
  — the right default. Prefer the in-memory `gen.proposal_distances`; fall back to disk when it is `nothing`
  (a resumed run's older generations).
- `Calibration` (`:673`): `t = isnothing(generation) ? T : Int(generation)` in the new branch
  (`:transition`'s `T-1` default at `:705` is specific to needing a gen+1). Discover the proposals file by
  scanning `gen_dir` with a regex, following `_loadGenerations`'s padding-agnostic precedent
  (`abc.jl:1299-1301`), rather than computing a tag from `method.toml`'s `max_nr_populations`, which may
  differ from the run that wrote the files. While there, hoist the `method.toml` read at `:720-726` into a
  small `_calibrationMethodMeta(cal, T)` helper shared by both branches.

**Degradation — every path returns a plot or a clear error, never a crash:**

| Situation | Behavior |
|---|---|
| Generation 1 | all proposals accepted (`_acceptFirstGeneration`, `abc_smc.jl:550-571`); one green series, no threshold line, note "generation 1 accepts every evaluated proposal" |
| Legacy run, no `_proposals.csv` | accepted-only histogram from `generation_{NNN}.csv`'s `distance` column; note "rejected distances were not recorded for this run" |
| Resumed run, mixed | per-generation, so newer generations plot fully and older ones degrade; the note is per-generation |
| `accept_overflow=true` | overflow ε-passers are `accepted=true` in the file but absent from the posterior CSV; the histogram is the honest one — documented |
| `max_evaluations` hit mid-generation | the file holds exactly what was evaluated; nothing special needed |
| Whole batch of monads failed | those proposals contribute no rows; cross-reference `generation_{NNN}_failed_monads.csv` |
| Empty data / no parameters | `error(...)` with a clear message, matching the existing recipes (`:216`, `:400`) |

## Testing Strategy

**Unit:**
- `"GenerationResult fields"` (`test/runtests.jl:688`) — the renamed field, the two new fields, and that the
  10-argument constructor still works and yields `nothing, nothing`.
- `"generation persistence (save/load round-trip)"` (`:703`) — `_proposals.csv` written and read back;
  `epsilon_threshold` round-trips through the TOML; **a legacy case: a TOML with the old `"epsilon"` key and
  no `"epsilon_threshold"` loads with `max_epsilon_accepted` populated from the fallback and
  `epsilon_threshold === nothing`.** That case is the guard on the rename.
  **Leave the exact column-set assertion at `:741` unchanged** — its continued passing is the proof that this
  design does not touch `generation_{NNN}.csv`.
- `"accept_overflow keeps all epsilon-passing particles"` (`:1126`) — assert
  `sum(gen.proposal_distances.accepted) == n_accepted_total`,
  `nrow(gen.proposal_distances) <= gen.n_evaluations`, and
  `Set(gen.distances) ⊆ Set(gen.proposal_distances.distance[gen.proposal_distances.accepted])`.
- `"later generations reject missing distances without comparing to epsilon"` (`:1095`) — `missing`-distance
  proposals produce no rows.
- `"epsilon_schedule overrides adaptive epsilon"` (`:962`) — `gen.epsilon_threshold == schedule[t-1]` for
  `t>1`, and `isnothing(generations[1].epsilon_threshold)`.

**New `@testset "calibration plot recipes"`**, placed immediately after `"GSA plot recipes"` (`:3377-3486`)
and reusing its `apply(d) = RecipesBase.apply_recipe(Dict{Symbol,Any}(), d)` helper (`:3397`). **There is
currently no testset for any calibration recipe** — `_CornerPlotData`, `_RidgelineData`, `ConvergenceSummary`
and `_TransitionData` are all untested — so add smoke coverage for those four at the same time; it is the
natural moment and the marginal cost is small. For `:distances`:

- builder: `edges` is uniform, contains `epsilon_threshold` exactly, and accepted/rejected bin supports are
  disjoint;
- `nseries(apply(dd))` == 3 with both groups plus threshold, 2 with an empty rejected set plus a known
  threshold, 1 with neither;
- `logscale=true` drops non-positive distances and records them in `note`;
- `weighted=true` keeps both series on one axis;
- `@test_throws ErrorException apply(_DistanceData(…empty…))`, mirroring `:3472-3477`;
- style dispatch: `RecipesBase.apply_recipe(Dict{Symbol,Any}(), result, :distances)[1].args[1] isa ModelManager._DistanceData`
  and `@test_throws ErrorException … :nope`, mirroring `:3054-3056`, for **both** the `ABCResult` and the
  `Calibration` recipe.

**Integration:** extend `"runCalibration end-to-end"` (`:2561`) to assert `generation_2_proposals.csv` exists
and that recipe application on `Calibration(id)` with `:distances` returns a `_DistanceData`.

**Docs:** a new subsection under `## [Visualizing calibration results](@id abc_plots)`
(`docs/src/man/calibration.md:150-162`). This is the right place to fix the wrong plotting docs: `:158-161`
shows `plot(result; plot_type=:corner|:ridgeline|:convergence|:transition)`, but the real recipes take a
**positional** `style::Symbol` accepting only `:ridgeline` and `:transition` (`visualize.jl:597`, `:673`) —
corner is the no-style default (`:261`, `:268`) and convergence is `plot(ConvergenceSummary(result))`
(`:350`). Rewrite the block correctly and add `:distances`. `README.md:79` gets the same correction.
Also add the new file to the `Calibration` docstring's folder listing (`problem.jl:94-111`), and document the
three epsilon quantities where users will meet them.

## Estimated Effort

- **Lines of code:** ~35 in `abc_smc.jl`, ~65 in `abc.jl` (path helper, writer, loader), ~20 in `problem.jl`,
  ~150 in `visualize.jl`; ~250 in `test/runtests.jl` (about half first-ever coverage of the four existing
  calibration recipes); ~45 in docs/README. Plus the rename sweep — mechanical but touches ~8 sites.
- **Risk level:** **Medium.** The back-compat constructor and the read-fallback are what keep it there rather
  than High. Main risks: the bin-edge-on-threshold arithmetic at the boundaries (ε below `min` or above `max`
  — clamp `k_left`/`k_right` to ≥ 0 and handle a degenerate single-value range), `CSV.read` type inference on
  the new file (pass `types=` explicitly), and missing a `.epsilon` call site in the rename sweep.
- **Dependencies:** none — no new package dep, no schema change, no `up.jl` migration.

## Open questions for the user

1. **Should generation 1 get a proposals file at all**, given it is 100% accepted and duplicates
   `generation_1.csv`'s `distance` column? Uniformity says yes; frugality says no. Default if unanswered: yes,
   write it.
2. **Distance histogram defaults** — linear or log10 x? Recommended default is linear for consistency with the
   other recipes, but log10 is usually more readable for squared-error distances.
3. **`ConvergenceSummary`'s output column** renames along with the field (`epsilon` →
   `max_epsilon_accepted`). Confirm that is wanted, since it is the one user-visible table column affected.

## Cross-cutting rules

**Review-only comments.** The repo uses `#!` for *permanent* design-rationale comments (316 of them). Any
comment written purely so the user can follow your reasoning during review must be marked `#REVIEW:` and
removed before merge.

**Docs are for an outside reader, not a changelog.** User-facing prose explains how to use the code as it now
is. Where a "why" is needed it must be the grand-narrative why, never this repo's history:

> ✅ "Updates are delayed until the next Julia session so as not to corrupt the currently loaded session state."
> ❌ "Updates must be delayed because updating mid-session had the potential to produce incorrect session states where upgrades would never actually proceed."

Applied here: document what `max_epsilon_accepted` and `epsilon_threshold` *are*. Do not write that the key
"used to be called `epsilon`" — that belongs in `progress.md`.

## Pre-merge checklist

- [ ] `julia --project=. -e 'using Pkg; Pkg.test()'` green.
- [ ] `rg '#REVIEW:' src/ test/` returns nothing.
- [ ] `rg '\.epsilon\b|"epsilon"' src/` shows no stale references from the rename.
- [ ] A pre-rename `generation_{NNN}.toml` still loads through the fallback — the resume guard.
- [ ] `test/runtests.jl:741`'s exact column-set assertion still passes untouched.
- [ ] Docs written outside-in per the rule above; the `plot_type=` errors in
      `docs/src/man/calibration.md:158-161` and `README.md:79` corrected.
- [ ] `README.md` Implementation Status and `PRD.md` updated.
- [ ] `progress.md` records the rename, the fallback, and why option (a) beat extending `generation_{NNN}.csv`.
