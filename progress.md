# progress.md — ModelManager.jl Session Journal

> **Purpose:** Session-level decisions, rejected approaches, and open questions.
> Unlike [PRD.md](PRD.md) (specification) and [README.md](README.md) (completion status), this file captures the *reasoning* behind decisions — things that would otherwise exist only in ended chat history.

---

## Session: GSA sensitivity plot recipes (2026-06-17)

### Goal
The calibration result objects have `RecipesBase.jl` recipes (`src/calibration/visualize.jl`), but the GSA sampling results (`MOATSampling`, `SobolSampling`, `RBDSampling`) had none. Add bar-chart recipes mirroring SmoreGSA's `SensitivityResult` recipe, plus richer MOAT visualizations.

### Design decisions

**New file `src/sensitivity_visualize.jl`**, included after `sensitivity.jl`. Parallels `calibration/visualize.jl`. `RecipesBase` is already a direct dep, so recipes live in-package (not in an extension like SmoreGSA, which keeps Makie/Plots out of its core deps — ModelManager already committed to the in-package approach for calibration).

**Internal plot-data wrappers + builders take `(results, monad_ids_df, …)`, not the `GSASampling`.** This is the key testability decision: constructing a real `MOATSampling`/etc. requires a `Sampling` (and a live SQLite project). By having the user-facing recipe extract `m.results`/`m.monad_ids_df` and delegate to a builder (`_moatBarData`, `_sobolBarData`, …) that returns a lightweight wrapper (`_GSABarData`, `_GSAViolinData`, `_GSAScatterData`), the tests fabricate `GlobalSensitivity.MorrisResult`/`SobolResult` objects + a plain `DataFrame` and call `RecipesBase.apply_recipe` directly — no DB, no simulations. Same `_CornerPlotData` pattern as calibration.

**One series per sensitivity function**, iterated in `_gsaFunctionLabel`-sorted order (the `results` Dict order is otherwise unspecified → nondeterministic legends). Labels prefix the function name only when `length(results) > 1`, matching SmoreGSA's `multi_out` convention.

**Parameter names from `monad_ids_df` columns**, dropping the per-method bookkeeping columns: `base` (MOAT, index 1), `A`/`B` (Sobolʼ, indices 1–2), none (RBD). These align with the index-vector ordering already established in `sensitivity.jl` (`perturb_headers`/`focus_indices`).

**MOAT got three styles** (user request beyond the SmoreGSA bar-only Morris recipe), dispatched via a `style::Symbol` positional like calibration's `plot(result, :transition)`:
- `:bar` (default) — µ* bars; `show_sigma=true` adds σ = `sqrt(variances)` whiskers via the `yerror` attribute. `_GSABarGroup` carries an optional `yerror::Union{Nothing,Vector}` for this.
- `:violin` — distribution of `elementary_effects` (the full `n_base × d` matrix MorrisResult already stores) per parameter. Emits `seriestype := :violin`; resolved by the backend (StatsPlots) at plot time, so no new dep.
- `:scatter` — classic Morris µ*–σ screening plot, one point per parameter. Parameter names are placed via offset `annotations` (nudged 2% of the axis span, anchored `:left,:bottom`) rather than `series_annotations`, which centers text on the marker and overlaps it.

**Sobolʼ `show_ST=true`** overlays ST at `fillalpha=0.45` (matches SmoreGSA). RBD is first-order bars only. Both reuse the shared `_GSABarData` recipe.

### Rejected / considered
- **Three independent recipes with duplicated styling** — rejected in favor of the shared `_GSABarData` recipe so xlabel/ylabel/legend/`:bar` styling stays consistent and the bar logic is written once.
- **Putting recipes in an `ext/` extension (SmoreGSA style)** — unnecessary here since `RecipesBase` is already a hard dep and the calibration recipes set the in-package precedent.

### Files changed
- `src/sensitivity_visualize.jl` — new file: shared helpers, `_GSABarData`/`_GSAViolinData`/`_GSAScatterData` wrappers + recipes, builders, and the five user-facing `@recipe`s (MOAT bar/violin/scatter, Sobolʼ, RBD)
- `src/ModelManager.jl` — `include("sensitivity_visualize.jl")` after `sensitivity.jl`
- `test/runtests.jl` — `using RecipesBase` + `import GlobalSensitivity`; module-level `_gsa_fA`/`_gsa_fB` keys; `@testset "GSA plot recipes"` (series counts, σ whiskers, param-name extraction, empty-results errors)
- `README.md`, `PRD.md` — sensitivity visualization documented

### Open questions
- None. Violin requires a `:violin`-capable backend (StatsPlots); documented in the docstring rather than adding a dep.

## Session: calibration progress reporting (2026-06-17)

### Goal
A calibration run printed nothing between the end of JIT compilation and the completion of generation 1 — a long silent window for slow simulations. Add console feedback at multiple granularities.

### Problem diagnosis
- `evaluate_batch` calls `run(sampling; quiet=true)` (`abc.jl`); `quiet=true` suppresses *all* per-simulation/per-trial output in the runner.
- The only calibration log (`@info "ABC-SMC generation t: ..."`) fires *after* a generation completes (`abc_smc.jl`).
- So all wall-time inside a generation's `run()` call is silent.

### Key Design Decisions

**Tiered verbosity, not a boolean.** `progress::Symbol` on `runABC`/`runCalibration`/`resumeABC` with stacked levels `:none < :generation < :batch < :bar`, plus `:auto`. Rejected a simple `verbose::Bool` because HPC/SLURM (redirected, non-TTY) logs want textual milestones but *not* a carriage-return progress bar. `:auto` resolves to `:bar` on a TTY and `:generation` otherwise — the right default for both interactive and batch contexts. Runtime-only; deliberately **not** persisted to `method.toml` (it's an I/O preference, not an algorithm setting, and resume should be free to choose its own).

**Generic `on_progress` hook on `run`, not calibration-aware progress in the runner.** `run` gains `on_progress::Union{Nothing,Function}=nothing` and emits `:init`/`:step`/`:finish` events from its existing single-threaded `take!(result_channel)` completion loop (which already fires once per completed sim, identically for local and `sbatch --wait` HPC). The runner learns nothing about calibration — it just emits ticks. When `on_progress === nothing` the runner is byte-for-byte unchanged, so every existing caller and test is unaffected (verified: 914 passing). Rejected putting a `ProgressMeter` directly in `run` because that would couple the simulator-agnostic runner to a calibration-rendering concern and the bar would lack generation/batch framing.

**Bar sized inside `run`, framed outside.** The bar's total = the batch's *pending* simulation count, which only `run` knows (after `pendingSimulationSpecs`). So the renderer is built in the calibration layer (with the gen/batch label as `desc`) but receives its size via the `:init` event. Zero-pending batches (all monads reused) create no bar.

**ProgressMeter imported qualified.** `using ProgressMeter: next!` shadowed `Sobol.next!`, breaking `_runFirstGeneration`'s SobolSeq iteration (caught by the test suite — `MethodError: no method matching next!(::SobolSeq)`). Switched to `import ProgressMeter` + qualified `ProgressMeter.next!`/`.Progress`/`.finish!`. Lesson: prefer qualified import for any package whose exported names (`next!`, `update!`, `finish!`) are likely to collide.

**New dependency:** ProgressMeter.jl (approved), compat relaxed to `"1"`.

### Tests added (12 new, 914 passing)
- `calibration progress verbosity` — rank ordering, `_resolveVerbosity` pass-through + `:auto` + `ArgumentError`, `_batchProgressCallback` returns `nothing` below `:bar`, full bar lifecycle including zero-pending no-op.
- `run on_progress hook` (DB-backed) — `:init` first, `:finish` last and once, init size and step count both equal `n_scheduled`.
- `runCalibration progress levels` (DB-backed) — all four explicit levels run end-to-end; invalid setting throws before any work.

### Files
- New: `src/calibration/progress.jl` (included first in `calibration.jl`).
- `src/runner.jl` — `on_progress` hook.
- `src/calibration/abc_smc.jl` — `verbosity` kwarg on `_runABCSMC`, gen-start log, gated gen-end/stop logs.
- `src/calibration/abc.jl` — `progress` kwarg threaded through `runCalibration`/`runABC`/`resumeABC`; `_buildEvaluateBatch` tracks per-gen batch index, logs batch start, passes `on_progress` to `run`.

---

## Session: feature/latent-inverse-maps — Visualization, resume robustness, LatentVariation enhancements (2026-05-17)

### Goal
Ship posterior visualization recipes, harden `resumeABC`, and extend `LatentVariation` with user-facing `target_names` and `inverse_maps` for LVSource calibration parameters.

### Key Design Decisions

**`LatentVariation.target_names` for LVSource display**
Added `target_names` field to `LatentVariation` (already existed on `DVSource`/`CVSource` auto-constructed LVs). User-supplied `LatentVariation`s can now name their target columns, which appear in display CSVs and the `parameters.toml` mapping. Persisted under `"target_display_names"` in the LVSource TOML entry.

**`inverse_maps` scope**
For `DVSource`/`CVSource`, `inverse_maps` are auto-constructed at `LatentVariation` creation (always present). For user-supplied `LatentVariation` (`LVSource`), `inverse_maps` is optional — omitting it disables simulation bank lookup for that parameter. When supplied, `_validateInverseMaps` checks round-trip accuracy at construction time. This unifies the bank-lookup path (`_bankCdfCoords`) across all source types without requiring users to implement inverses they don't need.

**`_validateStructuralMatch` for LVSource**
`resumeABC` previously crashed on `LVSource` parameters with "Unexpected saved source type". Added the `elseif src isa LVSource` branch matching on `latent_parameter_names`, target column names, `target_names`, and `lv.name`. The `_StrippedLVSource` path (anonymous functions stripped at save time) was already handled; the non-stripped path was missing.

**Scan-based `_loadGenerations`**
Changed from tag-construction loop (`generation_$(lpad(t, ndigits, '0')).csv`) to directory scan + parse. Fixes resume when `max_nr_populations` changed between the original run and `resumeABC`. Tags with any zero-padding are found correctly.

**`generation_cdfs/` as subdirectory of `generations/`**
The save side was already using `joinpath(generations_dir, "generation_cdfs")` (single-dir form). The load side (`_findLastGenerationCSVs`, `resumeABC`) was incorrectly computing `generation_cdfs/` as a sibling of `generations/`. Fixed by making both sides use `joinpath(calibrationFolder(c), "generations", "generation_cdfs")` consistently.

**Posterior visualization via RecipesBase**
Four recipes added to `visualize.jl`. All use `RecipesBase.@recipe` so they work with any Plots.jl backend without a hard dependency. Key decisions:
- `_safeKDE1D`/`_safeKDE2D` guard against zero-variance inputs (collapsed posteriors, test data) — return a synthetic spike or `nothing` rather than crashing or producing unsorted GKS output.
- Rejected proposals for the `:transition` plot are lazily loaded from disk (`generation_{t+1}_monads.csv` → subtract accepted IDs → `simulationsTable(short_names=false)`). Requires `inverse_maps` to convert display values back to CDF space for `:cdf` display; falls back gracefully to accepted-only if maps unavailable or monads file absent.
- `short_names=false` kwarg added to `simulationsTable` / `locationVariationsTable` / `appendVariations` so the transition-plot loader gets raw XML-path column names matching `parameters.toml` keys. The variation ID column is always renamed regardless of `short_names`.

**Removed: `_reconstructCDFFromDisplay` and `_loadGenerationsFromDisplay`**
Initially added as a fallback for resuming calibrations whose `generation_cdfs/` directory was missing (old code path). Removed because: (a) `generation_cdfs/` has always been written since the dual-CSV output feature shipped, so no real user is affected; (b) correct reconstruction for DVSource required `inverse_maps` (not the latent prior, which is `Uniform(0,1)` internally), making the code non-trivial and the added surface area unjustified.

### Tests added (feature/latent-inverse-maps, 818 passing)
- `_validateStructuralMatch` — 6 new LVSource (non-stripped) cases
- `generation persistence` — cross-padding test (save max_pops=10, load max_pops=5)
- `resume path` — verifies `_loadGenerations` reads raw CDF coords from `generation_cdfs/`, not display values

### Status
Branch `feature/latent-inverse-maps` is ready to merge. MM version bumped to `0.7.0`. PCMM CI is failing because `0.7.0` is not yet registered in BergmanLabRegistry — register it after merging to `main`, then re-run PCMM CI.

---

## Session: Phase 2b — Populate ModelManager with generic infrastructure (2026-04-12)

### Goal
Extract all simulator-agnostic code from PCMM into ModelManager so that BergiCell (a new Julia ABM package) can build on the same infrastructure without duplication.

### Key Design Decisions

**Global state cross-package pattern**
ModelManager cannot default `simulator` to `PhysiCellSimulator()` because it doesn't know about PCMM. Solution: `mm_globals_ref = Ref{Union{Nothing,ModelManagerGlobals}}(nothing)` — PCMM sets it in `__init__`. Accessing `mm_globals()` before initialization asserts and throws a descriptive error.

**`postSimulationProcessing` placement**
User requested: "pruner.jl should just be an interface for post-simulation processing. PCMM should own the pruner.jl logic and classes." Decision: ModelManager gets only a no-op stub `postSimulationProcessing(sim, proc; kwargs...)`. PCMM implements `postSimulationProcessing(::PhysiCellSimulator, proc; prune_options=PruneOptions())`.

**`run` signature generalization**
Old PCMM: `run(T; prune_options::PruneOptions=PruneOptions())`. New ModelManager: `run(T; force_recompile=false, kwargs...)` where `kwargs` forwarded to `postSimulationProcessing`. PCMM then picks up `prune_options` from `kwargs` in its implementation.

**`addVariationRows` as an interface method**
The actual DB writes for variation rows (adding columns, inserting values, handling `par_key`) are PhysiCell/XML-specific (`addColumns`, `ColumnSetup`, `setUpColumns`). ModelManager defines the interface stub `addVariationRows(sim, inputs, reference_variation_id, loc_dicts)` and PCMM implements it.

**`variationLocation` dispatch**
Old PCMM called `variationLocation(xp::XMLPath)` directly. New ModelManager dispatches on the simulator: `variationLocation(mm_globals().simulator, target)`. PCMM implements `variationLocation(::PhysiCellSimulator, xp::XMLPath)` with the PhysiCell path-prefix logic.

**`insertFolder` hooks**
Two PCMM-specific behaviors in `insertFolder`: (1) reading `metadata.xml` for a description, (2) calling `prepareBaseFile` for initial setup. Replaced with `getInputFolderDescription(sim, path)` (default `""`) and `initializeInputFolder(sim, input_folder)` (default no-op).

**`columnName` placement**
`columnName(xml_path::Vector{<:AbstractString}) = join(xml_path, "/")` is defined in PCMM's `configuration.jl`. Moved to `ModelManager/src/variations.jl` as it is a generic utility for XMLPath column naming.

**`SobolMM` alias**
PCMM uses `SobolPCMM` as an ASCII alias for `Sobolʼ`. ModelManager uses `SobolMM` as the ASCII alias instead, since `PCMM` in the name would be wrong for a generic package.

**`locationPath` overloads for `InputFolder` and `AbstractSampling`**
These overloads use types defined in `classes.jl`, which is included after `project_configuration.jl`. Moved them: `locationPath(input_folder::InputFolder)` goes to `classes.jl`; `locationPath(location, S::AbstractSampling)` also goes to `classes.jl` (right after `AbstractSampling` is defined).

**`database_utils.jl` simplification**
Original `database_utils.jl` had full implementations of `queryToDataFrame`, `tableExists`, `tableColumns`, `columnsExist`. These were needed before `globals.jl` existed (no `centralDB()` default). Now that `database.jl` provides these with `centralDB()` defaults, `database_utils.jl` is reduced to just `using SQLite, DataFrames; import SQLite.DBInterface`.

### Files Created
- `src/abstract_simulator.jl` — updated with new stubs
- `src/hpc.jl` — SLURM utilities
- `src/project_configuration.jl` — `ProjectLocations`, location path utilities
- `src/globals.jl` — `ModelManagerGlobals`, `mm_globals_ref`, zero-arg accessors
- `src/recorder.jl` — `recordConstituentIDs`, `compressIDs`
- `src/classes.jl` — full trial hierarchy + `MMOutput`
- `src/database.jl` — generic schema + DB utilities
- `src/runner.jl` — parallel runner, HPC wrapping
- `src/deletion.jl` — cascade delete, `resetDatabase`, `rm_hpc_safe`
- `src/variations.jl` — XMLPath, all variation types, space-filling designs
- `src/sensitivity.jl` — MOAT, Sobol', RBD
- `src/user_api.jl` — `createTrial`, `run` convenience overloads
- `src/ModelManager.jl` — updated includes and exports

### Open Questions
- Should `initializeModelManager` live in ModelManager (generic) or remain in PCMM? Currently in PCMM; deferred to Phase 3.
- Should `createProject` live in ModelManager? Currently in PCMM; deferred to Phase 3.
- `LatentVariation.show` in ModelManager calls `columnName(tar)` for the target display — the `shortVariationName` (PhysiCell-specific human-readable names) was intentionally dropped; verify this is acceptable.

### Next Steps (Phase 2c)
1. Update PCMM `globals.jl` to use `ModelManagerGlobals` and set `mm_globals_ref`.
2. Update PCMM to slim down files that were moved: `classes.jl`, `recorder.jl`, `hpc.jl`, `deletion.jl`.
3. Update PCMM `database.jl` — add `simulatorVersionTableName(::PhysiCellSimulator)`, fix `physicell_version_id` references.
4. Update PCMM `PhysiCellModelManager.jl` — remove moved includes, add `const PCMMOutput = MMOutput`.
5. Run full PCMM test suite and fix failures.

---

## 2026-04-25 — Flatten SimulationSpec; split setup from collection

### Context

`AbstractSimulationSpec` was introduced as a future extension point but serves no current purpose — `AbstractSimulator` is the dispatch axis. `collectPendingSimulations` conflated folder creation, simulator hook calls, and simulation enumeration into one function, making the responsibilities hard to name and test independently.

### Design decisions

**No `AbstractSimulationSpec`; `SimulationSpec.monad_id::Int`**
`SimulationSpec` is now a plain struct. `monad_id` is always a real Int — setup always precedes collection, so `ismissing` is never needed.

**`prepareTrialHierarchy` dispatches on `AbstractMonad` directly**
`Simulation <: AbstractMonad <: AbstractSampling`, so a `Simulation` or `Monad` passed directly to `prepareTrialHierarchy` calls `setupSampling(simulator, M)` + `setupMonad(simulator, M)` without creating a wrapping `Sampling` in the DB. This avoids unnecessary database rows and output folders. Rejected: `_toSampling(T::AbstractMonad)` wrapper — clean conceptually but creates DB artifacts.

**`setupSampling`/`setupMonad` stubs generalized to `AbstractSampling`/`AbstractMonad`**
`loadCustomCode(S::AbstractSampling)` and `prepareVariedInputFolder(loc, M::AbstractMonad)` already accept these abstract types in MM, so the generalization has no downstream implementation cost in PCMM.

**`pendingSimulationSpecs(simulation::Simulation)` uses `Monad(simulation)`**
`createTrial` always creates a Monad before returning a Simulation (`INSERT OR IGNORE`), so `Monad(simulation)` is always an idempotent lookup, not a creation.

**`run` unchanged in structure**
No normalization of the input `T` needed. `MMOutput{T}` preserves the original type. Existing tests pass without change.

### Files touched
- `src/runner.jl`: removed `AbstractSimulationSpec`; `SimulationSpec.monad_id::Int`; replaced `collectPendingSimulations` with `prepareTrialHierarchy` + `pendingSimulationSpecs`; simplified `run`.
- `src/abstract_simulator.jl`: updated stub comments/docstrings for `setupSampling` and `setupMonad`.

---

## 2026-04-25 — Calibration infrastructure migration from PCMM

### Goal
Migrate all framework-agnostic calibration code from PCMM into ModelManager so that any simulator package can use ABC-SMC calibration without depending on PhysiCell-specific infrastructure.

### Scope
Files moved to `src/calibration/`:
- `methods.jl` — `AbstractCalibrationMethod`, `ABCSMC` struct + validation, `runCalibration` stub
- `problem.jl` — `CalibrationParameter`, `CalibrationProblem`, `Calibration`, `GenerationResult`, `ABCResult`, `posterior`
- `distance.jl` — `mseDistance` (only; PhysiCell summary stats stayed in PCMM)
- `abc_smc.jl` — full ABC-SMC core loop: `_runABCSMC`, `_runFirstGeneration`, `_runSubsequentGeneration`, importance weighting, epsilon adaptation
- `abc.jl` — MM-specific adapter: `_createMonadForParams`, `_buildEvaluateParticle`, `runCalibration(ABCSMC)`, `runABC`, `resumeABC`, `_saveMethod`, `_loadMethod`, `_saveGeneration`, `_loadGenerations`
- `calibration.jl` — orchestrator (includes), folder helpers, DB operations

### Key Design Decisions

**`_saveGeneration` / `_loadGenerations` in `abc.jl`, not `calibration.jl`**
These are ABC-SMC-specific persistence helpers. Grouping them in `abc.jl` keeps `calibration.jl` as a generic orchestrator. Same rationale for `_saveMethod` / `_loadMethod`.

**`calibrationsSchema()` moved to MM's `database.jl`**
The `calibrations` table is now standard infrastructure, created by `createSchema()`. PCMM's `upgradeToV0_3_0` migration updated to call `ModelManager.calibrationsSchema()` so old upgrade paths still work.

**No new MM dependencies**
`Distributions`, `CSV`, `DataFrames`, `LinearAlgebra`, `Statistics` were already in `Project.toml`. Zero `Project.toml` changes needed.

**PhysiCell summary statistics stayed in PCMM**
`endpointPopulationCounts`, `endpointPopulationFractions`, `meanPopulationTimeSeries` moved into `src/analysis/standard_qois.jl` in PCMM — not into MM.

**PCMM calibration files stubbed rather than deleted**
The bash sandbox mounts the macOS filesystem via FUSE which blocks `unlink()`, making `git rm` fail. Files were overwritten with stub comments; user runs `git rm src/calibration/*.jl` from their own terminal.

---

## 2026-04-25 — Remove kwargs from `runSimulation`

### Context

PCMM's `runSimulation` and `prepareSimulationCommand` do not use any of the kwargs that `run` was passing through. Keeping `; kwargs...` on the interface created unnecessary noise and false expectations for future simulator implementors.

### Change

`runSimulation(sim, spec::SimulationSpec)` no longer accepts kwargs. The `run` function still forwards kwargs to `prepareTrialHierarchy` (→ `setupSampling` / `setupMonad`) and to `postSimulationProcessing`, which do use them. Only the `runSimulation` call site was narrowed.

### Files touched
- `src/runner.jl`: removed `; kwargs...` from the `runSimulation` call site and updated the `run` docstring
- `src/abstract_simulator.jl`: removed `; kwargs...` from the stub signature, error message, and `AbstractSimulator` docstring list
- `PRD.md`: updated `runSimulation` signature and runner behavioral description

---

### Files touched (MM) — calibration migration
- `src/calibration/calibration.jl` — new
- `src/calibration/methods.jl` — new
- `src/calibration/problem.jl` — new
- `src/calibration/distance.jl` — new
- `src/calibration/abc_smc.jl` — new
- `src/calibration/abc.jl` — new
- `src/database.jl` — added `calibrationsSchema()`, wired into `createSchema()`
- `src/ModelManager.jl` — added exports and `include("calibration/calibration.jl")`
- `test/runtests.jl` — new full test suite
- `Project.toml` — bumped version `0.4.0` → `0.5.0`

---

## 2026-04-27 — ABC-SMC parallel batch evaluation

### Goal

Replace one-by-one sequential particle evaluation in the ABC-SMC loop with batch evaluation that exploits MM's parallel Sampling runner. Each generation now schedules all its candidate simulations concurrently via a single `run(sampling)` call instead of `population_size` sequential `run(monad)` calls.

### Scope

- `src/calibration/abc_smc.jl` — core loop refactored
- `src/calibration/abc.jl` — adapter refactored

### Key Design Decisions

**`evaluate_particle` → `evaluate_batch` interface**
The framework-agnostic core (`abc_smc.jl`) previously held a callback `Dict → (Float64, Any)`. Changed to `Vector{Dict} → Vector{(Float64, Any)}`. The core proposes a whole batch, hands it to the callback, and gets results in the same order. The core remains simulator-agnostic; MM-specific wiring stays in `abc.jl`.

**Generation 1: single batch**
All `population_size` proposals are sampled upfront, passed to `evaluate_batch` once, and all accepted. `n_evaluations = population_size`.

**Generation t > 1: iterative adaptive batching**
Initial acceptance rate estimate = `population_size / prev.n_evaluations`. Each round proposes `ceil(n_needed / acceptance_rate_est)` candidates, runs them as a Sampling, accepts those below epsilon, and updates the rate estimate. Stops once `length(accepted) >= population_size`; trims any overshoot. Rationale for adaptive over fixed multiplier: a fixed 2× wastes work when acceptance rate is already high (early generations); adapting from `prev.n_evaluations` asymptotically minimizes proposals.

**Overshoot trimming**
After a batch, `accepted` may exceed `population_size`. Trimmed to exactly `population_size`. Particles within a batch are exchangeable (same proposal distribution), so truncation bias is negligible.

**Acceptance rate floor**
`acceptance_rate_est` is clamped to a minimum of `0.01` after each round to prevent degenerate batch sizes when a round yields zero acceptances.

**`_buildEvaluateBatch` in abc.jl**
Takes `Vector{Dict{String,Float64}}`, creates one Monad per proposal via `_createMonadForParams`, forms `Sampling(monads, problem.inputs)`, calls `run(sampling; quiet=true)`, appends all monad IDs to `monads.csv`, then maps over monads to compute distances. Returns `Vector{Tuple{Float64,Int}}` in proposal order.

### Open Questions
- None at this time.

### Files touched
- `src/calibration/abc_smc.jl`
- `src/calibration/abc.jl`

---

## 2026-04-29 — Remove CalibrationParameter; CalibrationProblem accepts AbstractVariation directly *(REVERTED — see 2026-04-30 redesign below)*

> **Note:** This design was implemented then fully reverted before being replaced by the 2026-04-30 `CalibrationParameter` tagged-union redesign. Kept here for rationale history only. The current codebase does **not** reflect this design.

### Goal

Align `CalibrationParameter` with the existing `LatentVariation` / `CoVariation` infrastructure so that users can calibrate any parameter that can be expressed as a variation — including covaried parameters and general multi-dimensional latent relationships — without a bespoke data structure. Then go one step further: eliminate `CalibrationParameter` as a user-visible type entirely, so users simply pass their existing variation objects (`DistributedVariation`, `CoVariation`, `LatentVariation{<:Distribution}`) to `CalibrationProblem` directly.

### Scope

- `src/variations.jl` — fix `LatentVariation` convenience constructors
- `src/calibration/problem.jl` — remove `CalibrationParameter` entirely; add `_toCalibrationVariation`; store parameters as `Vector{LatentVariation{<:Distribution}}`
- `src/calibration/abc.jl` — update `_createMonadForParams`, `param_names`/`priors` extraction
- `src/ModelManager.jl` — remove `CalibrationParameter` from exports
- `test/runtests.jl` — replace `CalibrationParameter construction` testset; fix `posterior` test

### Key Design Decisions

**`CalibrationParameter` removed entirely**
It was a single-field struct wrapping `LatentVariation{<:Distribution}` with no logic of its own. No reason to expose it. `CalibrationProblem.parameters` now stores `Vector{LatentVariation{<:Distribution}}` directly.

**`CalibrationProblem` accepts `AbstractVector{<:AbstractVariation}`**
The outer constructors call `_toCalibrationVariation(av)` on each element. The resulting `Vector{LatentVariation{<:Distribution}}` is stored in the struct. Users never interact with the stored type — they just pass their variation objects.

**`_toCalibrationVariation` validates at construction time**
Dispatches on concrete types:
- `DistributedVariation` → `LatentVariation(dv)`
- `CoVariation{DistributedVariation}` → `LatentVariation(cv)`
- `LatentVariation{<:Distribution}` → identity
- Everything else → `ArgumentError` with a helpful message

**CDF values are the particle coordinates**
ABC-SMC draws particle values from the latent priors directly. For a `DistributedVariation`-backed latent variation the prior is `Uniform(0,1)`, so the particle coordinate IS the CDF value. `variationValues(lv, cdfs)` converts those draws to concrete target values through the quantile maps. This keeps the algorithm on a bounded, well-conditioned space regardless of the underlying distribution.

**Fix `LatentVariation` convenience constructors (pre-existing bug)**
All four outer constructors (`DistributedVariation`, `DiscreteVariation`, `CoVariation{Distributed}`, `CoVariation{Discrete}`) were calling the inner constructor without the required `locations` argument — a silent `MethodError` on any call. Added `locations = [variationLocation(dv)]` / `variationLocation(cv)` to each.

**`_createMonadForParams` iterates over `LatentVariation`s directly**
For each `lv` in `problem.parameters`: extract CDF values from `params` dict by `lv.latent_parameter_names`, call `variationValues(lv, cdfs)` to get target values, build one `DiscreteVariation(loc, tar, typ(val))` per target. Supports multi-target `CoVariation` and general `LatentVariation` maps with no extra code.

**`param_names`/`priors` via `vcat`**
```julia
param_names = vcat([lv.latent_parameter_names for lv in problem.parameters]...)
priors      = vcat([lv.latent_parameters      for lv in problem.parameters]...)
```
Multi-dimensional `LatentVariation`s contribute M names and M priors; single-dim cases contribute 1. ABC-SMC core sees a flat vector of named priors regardless.

### Files touched
- `src/variations.jl` — added `locations` to all four `LatentVariation` outer constructors
- `src/calibration/problem.jl` — removed `CalibrationParameter`; added `_toCalibrationVariation`; `CalibrationProblem.parameters::Vector{LatentVariation{<:Distribution}}`; `ABCResult.parameters::Vector{LatentVariation{<:Distribution}}`; updated docstrings
- `src/calibration/abc.jl` — `_createMonadForParams` iterates over `LatentVariation`s; `param_names`/`priors` extraction updated in `runCalibration` and `resumeABC`
- `src/ModelManager.jl` — removed `CalibrationParameter` from exports
- `test/runtests.jl` — replaced `CalibrationParameter construction` testset with `_toCalibrationVariation and CalibrationProblem parameter conversion`; `posterior` test uses `LatentVariation{<:Distribution}[]`
- `PRD.md` — updated `CalibrationParameter` spec and `evaluate_batch` description

---

### Files touched (PCMM)
- `src/calibration/*.jl` — stubbed (6 files)
- `src/analysis/standard_qois.jl` — new (PhysiCell summary stats)
- `src/analysis/calibration_summaries.jl` — stubbed (renamed to `standard_qois.jl`)
- `src/analysis/analysis.jl` — added `include("standard_qois.jl")`
- `src/PhysiCellModelManager.jl` — removed calibration include and `calibrations` table creation
- `src/database.jl` — removed `calibrationsSchema()`
- `src/up.jl` — updated migration to call `ModelManager.calibrationsSchema()`
- `test/test-scripts/CalibrationTests.jl` — updated namespace qualifications

---

## 2026-04-29 — Task #17 design: CDF-grid snapping with generational refinement

### Motivation

ABC-SMC re-runs simulations for every proposal even when a nearby simulation already exists in the database. Snapping particle CDF coordinates to a dyadic grid means proposals in high-probability regions converge on a finite set of grid points. The second time a grid point is proposed, `use_previous=true` returns the existing monad at zero cost.

### Design decisions (from clarifying questions)

**k notation:** k is the exponent (not the number of divisions). Grid spacing = 1/2^k; interior grid points per dimension = 2^k − 1. With k=4 (default): 15 interior points/dim.

**Default k_start = 4.** Auto-increase at construction: find smallest k ≥ k_start such that (2^k−1)^d ≥ population_size. For population_size=200, d=2: (2^4−1)^2 = 225 ≥ 200, so k=4 suffices.

**Generation 1 sampling:** Sobol sequence of length population_size in [0,1]^d, then snap to G(k). The Sobol sequence provides quasi-random coverage of the grid without deduplication logic. If any point snaps to 0 or 1, replace from remaining valid grid points (sampling without replacement to preserve coverage).

**Generational refinement:** k_t = k_initial + (t−1). Each generation doubles the grid resolution (2^k → 2^(k+1) intervals, 2^k−1 → 2^(k+1)−1 interior points per dim). Simulation reuse is most valuable in early generations where many particles share grid points; later generations run with finer grids and more novel simulations.

**Importance weights at snapped position.** No Jacobian correction. The algorithm treats the snapped position as if it were the actual draw. Rationale: the snap introduces a small approximation (O(1/2^k) error in each dimension) that diminishes each generation as k grows. Avoids extra machinery and is consistent with the `use_previous=true` simulation reuse intent.

**Boundary/rejection:** A draw x ∈ [0,1] snaps to round(x·2^k)/2^k. If this equals 0 or 1, the particle is rejected. Every interior grid point has a catchment zone of exactly 1/2^k width, so no interior point is favored over another. Values in [0, 1/(2^(k+1))) snap to 0 → rejected; values in [(2^(k+1)−1)/2^(k+1), 1] snap to 1 → rejected.

**Interface:** Add `cdf_grid_k::Union{Nothing,Int}` to `ABCSMC` (default `nothing` → snapping disabled, backward-compatible). When set to an integer, enables snapping with k_start = that value.

### Open questions
- None. All design questions resolved. Implementation completed 2026-05-02.

---

## 2026-04-30 — CalibrationParameter refactor + dual-CSV generation persistence

### Motivation
The `generation_NNN.csv` files were storing raw CDF coordinates instead of interpretable
parameter values, making them useless for human inspection. `resumeABC` also required the
caller to re-supply the full `CalibrationProblem`, making session restarts awkward.

### Design decisions

**`CalibrationParameter` as internal tagged union.** Rather than modifying `LatentVariation`
to carry an inverse map, we introduced a new `CalibrationParameter` struct pairing:
- `source::Union{DVSource,CVSource,LVSource}` — the original user-supplied variation, for
  display-column construction and JLD2 serialization provenance
- `lv::LatentVariation{<:Distribution}` — the derived variation used by the ABC-SMC loop

`inverse_maps` in `LatentVariation` was explicitly rejected by the user.

**Dual CSV output.** Each generation now writes two CSV files:
- `generations/generation_NNN.csv` — human-readable target parameter values (DVSource/
  CVSource → actual calibrated quantity; LVSource → latent samples + target values)
- `generation_cdfs/generation_NNN.csv` — raw CDF coordinates for `resumeABC`

**JLD2 as hard dependency** for serializing the full `CalibrationProblem` to
`problem.jld2`. This enables `resumeABC(Calibration(id))` with no re-supplied problem.
Anonymous functions and closures are serialized by JLD2. Non-serializable captures are
a user concern, documented in `_saveProblem`.

**`posterior` dispatch split:**
- `posterior(result::ABCResult)` — in-memory: converts CDF particles → display format
  using `_buildDisplayDF` (handles empty params by returning particles unchanged)
- `posterior(cal::Calibration)` — reads directly from `generations/generation_NNN.csv`
  on disk; strips weight/distance/monad_id columns

**`resumeABC` signature change (breaking):** `resumeABC(calibration::Calibration)` — no
`problem` argument required. The old `resumeABC(calibration, problem, ...)` signature is
removed (no backward compat, as approved).

**`_saveGeneration` / `_loadGenerations` API:**
- `_saveGeneration(dir, gen, max_pops[, cps])` — single-dir form used in tests; writes
  display to `dir/` and CDF to `dir/generation_cdfs/`
- `_loadGenerations(dir, param_names, max_pops)` — reads from `dir/generation_cdfs/`
- High-level `_saveGeneration(calibration, ...)` uses `generations/` + `generation_cdfs/`

**`_buildDisplayDF` fallback:** When `cps` is empty (e.g. test-constructed `ABCResult`)
returns a copy of `gen.particles` unchanged, preserving backward compatibility with unit
tests that construct `GenerationResult` directly.

### Files changed
- `src/calibration/parameters.jl` (new) — `CalibrationParameter`, source types,
  `_toCalibrationParameter`, `_displayColumns`, `_particleRowToDisplay`
- `src/calibration/problem.jl` — `CalibrationProblem.parameters::Vector{CalibrationParameter}`;
  `ABCResult.parameters::Vector{CalibrationParameter}`; dual `posterior` dispatch
- `src/calibration/abc.jl` — `_buildDisplayDF`, dual-CSV `_saveGeneration`,
  `generation_cdfs`-reading `_loadGenerations`, JLD2 `_saveProblem`/`_loadProblem`,
  new `resumeABC(Calibration; ...)` signature, updated `runCalibration`
- `src/calibration/calibration.jl` — added `include("parameters.jl")`
- `Project.toml` — JLD2 added as hard dependency (UUID 033835bb, compat 0.4, 0.5)
- `test/runtests.jl` — updated to `_toCalibrationParameter`, new display-conversion
  tests, updated generation persistence tests for dual-CSV structure, `CalibrationParameter[]`

---

## Session: Fix acceptance rate overshoot bias (2026-04-30)

### Problem
`acceptance_rate = population_size / n_evaluations` undercounts accepted particles when
the final batch of a generation overshoots. Example: population_size=100, final batch
proposes 50 particles, 30 pass epsilon, but only 20 are needed to fill the population.
Old code reported 20/50 for that round, biasing the aggregate rate downward.

### Fix
Track `n_accepted_total` separately — increments for **every** proposal passing epsilon,
regardless of whether it is kept. Only the `push!` to `accepted` is gated on
`length(accepted) < population_size`. `acceptance_rate = n_accepted_total / n_evaluations`.

`n_accepted_this_round` for adaptive batch sizing also now counts all passing proposals,
so the estimate is unbiased on the last batch too (though this rarely matters since
there is no subsequent batch in that generation).

**Generation 1** is unchanged: no truncation possible (all N proposals accepted),
passes `n_accepted = N = n_evaluations` → rate = 1.0.

### Key decision
The acceptance rate should reflect the algorithm's efficiency at generating valid
particles given the current kernel and epsilon — **not** a function of the arbitrary
population size cap. Truncation is a bookkeeping artifact, not a rejection.

### Files changed
- `src/calibration/abc_smc.jl` — loop restructure, `n_accepted_total` counter,
  `_buildGenerationResult` gains `n_accepted::Int` parameter
- `test/runtests.jl` — regression test: `_buildGenerationResult` with n_accepted=7,
  n_evaluations=10, 5 kept particles → asserts rate=0.7 not 0.5; integration test
  via `_runABCSMC` with all-pass evaluate_batch

---

## 2026-05-01 — SimulationBank implementation (task #15)

### Motivation
The CDF-grid snapping algorithm (task #17) requires a pre-built registry of existing
monads whose calibrated parameters lie in the prior interior `(0,1)^d` in CDF space.
These can be reused rather than re-simulated when a proposal falls within one grid cell.

### Design decisions

**Terminology (established during review):**
- *Column* — a parameter that already has a column in the variation DB.
- *Parameter* — a user-specified `CalibrationParameter` target; may or may not have a DB column.

**`variation_id=0` as universal fallback.** This row always exists and holds the current
defaults for all columns in the variation table. Used as fallback when a candidate row has
`NULL` for a column. The reference variation ID fallback chain is: reference row value →
`variation_id=0` default → missing.

**Calibrated parameters with no DB column** (never varied before — column doesn't exist in
the table). The correct default is read from the XML config file via `getColumnDefaults`
(same logic as `addColumns`). This is not the `variation_id=0` row — the column doesn't
exist there either. If the config-file default falls outside the prior support, the entire
location is skipped (`skip_loc = true`). Otherwise, all candidate variation IDs at that
location inherit this base value for CDF computation.

**LVSource disabled.** `LVSource` parameters have no generic inverse map from target
values to latent CDF coordinates. Bank is disabled (returns empty `SimulationBank`) for
any problem containing an `LVSource` parameter. An `@info` message is emitted. Future
extension: add optional inverse maps to `LatentVariation`.

**CVSource joint consistency.** CDF coordinate u is recovered from the first target via
inversion. All other targets are forward-mapped from u and compared to their stored values
with relative tolerance 1e-8. Monads not on the co-variation curve are excluded.

**Non-calibrated column filtering.** DB columns within a calibrated location that are not
targeted by any `CalibrationParameter` must exactly match the effective reference values.
This ensures the bank only contains monads that were run with the intended background
parameters.

**Four-phase algorithm:**
1. Central DB query by simulator version, folder IDs, and reference variation IDs for
   non-calibrated varied locations.
2. Per-location variation filtering: batch-query all candidate vids + vid=0 + ref_vid;
   build effective-value maps; check non-calibrated column equality and calibrated column
   support bounds.
3. Per-monad CDF inversion: merge target maps across calibrated locations; call
   `_bankCdfCoords` per `CalibrationParameter`.
4. Interior filter: discard any monad with a CDF coordinate at exactly 0 or 1.

**`isInitialized()` guard.** Added early return when called in test context (uninitialized
DB), so unit tests for `_bankCdfCoords` and struct construction don't throw.

### Open questions
- None currently. The bank is built; it will be threaded into the proposal loop in task #17.

### Files changed
- `src/calibration/bank.jl` (new) — `SimulationBank` struct, `_buildSimulationBank`,
  `_bankColDistribution`, `_bankCdfCoords`
- `src/calibration/calibration.jl` — added `include("bank.jl")`
- `test/runtests.jl` — `@testset "SimulationBank struct and _bankCdfCoords"`: DVSource
  standard/flipped/missing/boundary, CVSource consistent/missing, LVSource, struct
  construction, `_buildSimulationBank` uninitialized-DB guard

---

## 2026-05-02 — CDF-grid snapping implementation (tasks #23–26)

### Goal
Implement the CDF-grid snapping and simulation bank lookup described in the task #17 design, including all prerequisite struct changes.

### Design decisions

**`cdf_coords` in `GenerationResult` (task #23).** Added `cdf_coords::Matrix{Float64}` (n_dims × n_particles) as a new field. This is the same data as `particles` but in matrix form, avoiding repeated DataFrame column lookups in tight loops. `_buildGenerationResult` constructs it via `reduce(hcat, [[p.params[name] for name in param_names] for p in accepted])`, preserving `param_names` order independent of DataFrame column ordering. `_loadGenerations` reconstructs it via `permutedims(Matrix{Float64}(particles[!, param_names]))`. A 9-arg backward-compatible outer constructor derives `cdf_coords` from `particles` automatically, so all existing tests (which construct `GenerationResult` with 9 positional args) continue to work unchanged.

**`cdf_grid_k` in `ABCSMC` (task #23).** Added as last field with default `nothing`. Validated ≥ 1 when set. Persisted to `method.toml` as a top-level key (omitted when `nothing`) and restored on resume via `_loadMethod`.

**Snap helpers (task #24).** Seven stateless functions in `abc_smc.jl`:
- `_effectiveK(k_base, t)` — `k_base + t - 1`
- `_snapToCDFGrid(u, k_eff)` — nearest interior grid point, boundary-clamped
- `_bankBoxRadius(k_base, t)` — `1/2^(k_base+t)`, half the grid spacing
- `_cdfToGridKey(snapped_cdf, k_eff)` — integer index vector for set membership
- `_bankBoxCandidates(bank, snapped_cdf, radius)` — L^∞ box monad lookup
- `_selectBankCandidate(bank, snapped_cdf, radius)` — first candidate or `nothing`
- `_snapAndLookup(params, param_names, k_eff, radius, bank, used_set)` — full snap+dedup+bank-resolve step; returns `(effective_params, grid_key)` or `nothing` if the snap key is already in `used_set`

**Bank reuse via proposal substitution (task #25).** When `_snapAndLookup` finds a bank candidate, it returns the bank monad's *actual* CDF coordinates (not the snapped grid point) as the effective proposal. The caller's `evaluate_batch` then calls `_createMonadForParams` with those coords; `use_previous=true` finds the existing monad without re-simulation. This keeps the `evaluate_batch` interface unchanged — no special bank-hit path needed.

**Gen 1 with snapping (task #25).** Switches from single-batch to iterative. Proposals are drawn in batches of `n_needed`. Each proposal is snapped, deduplicated within-batch (via a temporary `batch_key_set`) and against accepted particles (via `used_set`), then bank-resolved. Evaluation is batched for efficiency. Grid keys are registered to `used_set` immediately on acceptance.

**Gen t with snapping (task #25).** The existing proposal-building loop gains an `if snap_active` branch that calls `_snapAndLookup`. Proposals whose snap key is already in `used_set` are silently dropped (not counted in `n_evaluations`). Within a batch, two proposals may snap to the same unused key — only the first accepted one registers the key; the second passes epsilon but misses the `key ∉ used_set` check and is not added. Both are counted in `n_accepted_this_round` for an unbiased acceptance-rate estimate. This is rare when the grid is large relative to `population_size`.

**`used_set` type.** `Set{Vector{Int}}` — Julia's default array hash is content-based, so `[1,2]` and a separately constructed `[1,2]` hash equally and compare equal.

> **Note — this design was subsequently revised before the session ended.** See the 2026-05-02 revision entry below for the final implementation.

### Files changed (initial draft)
- `src/calibration/methods.jl` — `cdf_grid_k::Union{Nothing,Int}` field + validation
- `src/calibration/abc.jl` — `_saveMethod`/`_loadMethod` handle `cdf_grid_k`
- `src/calibration/problem.jl` — `GenerationResult` gains `cdf_coords` field + 9-arg compat constructor
- `src/calibration/abc_smc.jl` — snap helpers; `_snapAndLookup`; updated generation runners
- `test/runtests.jl` — snap helper unit tests; integration tests

---

## 2026-05-02 — KD-tree spatial index for SimulationBank

### Motivation

`_bankBoxCandidates` was doing a linear O(n_bank × n_dims) scan over all bank entries on every proposal. With banks potentially reaching tens of thousands of entries, this becomes the dominant cost. Replaced the scan with a KD-tree (Chebyshev metric) built once when the bank is constructed, reducing each query to O(log n + k).

### Design decisions

**`NearestNeighbors.jl` as the indexing backend.** Pure-Julia, maintained by a Julia core developer, no native dependencies. `KDTree` with `Chebyshev()` metric matches the existing L∞ box semantics exactly — `inrange(tree, point, radius)` returns the same set of candidates as the old loop.

**`tree::Union{Nothing,NNTree}` field on `SimulationBank`.** `nothing` when the bank is empty (no entries to index). Abstract field type is acceptable here: `SimulationBank` is not accessed in simulation hot loops.

**3-arg outer constructor preserves all call sites.** `SimulationBank(ids, coords, names)` auto-builds the tree, so every existing constructor call in tests, `_buildSimulationBank`, and the `abc_smc.jl` default argument works without modification.

**`_selectBankCandidate` removed.** Dead code — `_lookupAndSnap` already handles candidate selection inline. Its test was also removed.

### Files changed
- `Project.toml` — added `NearestNeighbors` to `[deps]` and `[compat]`
- `src/ModelManager.jl` — added `using NearestNeighbors`
- `src/calibration/bank.jl` — `SimulationBank` gains `tree` field; 3-arg outer constructor added
- `src/calibration/abc_smc.jl` — `_bankBoxCandidates` uses `inrange`; `_selectBankCandidate` deleted
- `test/runtests.jl` — added `using NearestNeighbors`; added tree field assertions; removed `_selectBankCandidate` testset

---

## 2026-05-02 — Revise CDF-grid snapping: lookup-first, monad-ID dedup, remove `cdf_coords` from `GenerationResult`

### Motivation

Three architectural issues identified during review of the initial snapping implementation:

1. **`GenerationResult.cdf_coords` is redundant.** It stores `permutedims(Matrix{Float64}(particles))` — the same data as the `particles` DataFrame in transposed matrix form. Nothing in the source code reads `gen.cdf_coords`; the matrix used for bank lookup lives on `SimulationBank.cdf_coords`. Carrying a duplicate field adds memory overhead and a maintenance burden with no benefit.

2. **`_snapAndLookup` had snap-first order.** The original function snapped θ_prop to the grid first, then looked for bank candidates near the snapped point. There is no reason to prefer this: looking near the **original** proposal first maximises reuse of existing simulations, and snapping is only needed as a fallback when no usable bank monad exists nearby.

3. **Two separate dedup structures.** Bank hits were deduplicated by monad ID (inside `_snapAndLookup`, checking `used_set` of grid keys), while fallback snaps were deduplicated by grid key vector. These are logically the same concern — "don't re-run the same simulation within a generation" — but were handled by different mechanisms. The user also pointed out that once a monad has been evaluated, re-running it is pointless regardless of acceptance: it produces the same result.

### Design decisions

**Remove `cdf_coords` from `GenerationResult`.** Struct drops from 10 to 9 fields; the redundant backward-compat constructor is also removed. `_buildGenerationResult` and `_loadGenerations` no longer build or carry it.

**Unified `used_monad_ids::Set{Int}`.** Both the bank-hit path (monad ID known before evaluation, from the bank registry) and the fallback-snap path (monad ID resolved pre-evaluation via `get_monad_id`) feed into the same `Set{Int}`. A per-batch scratch `batch_monad_ids::Set{Int}` handles within-batch dedup. After evaluation, ALL returned monad IDs — accepted or not — are added to `used_monad_ids`. This ensures the same monad is never run twice in a generation.

**`get_monad_id` resolver callback.** `_buildGetMonadID(problem)` in `abc.jl` returns a closure `params::Dict → monad_id::Int` that calls `_createMonadForParams(problem, params).id` without running simulations. `addVariations` with `GridVariation` is idempotent, so repeated calls for the same params return the same monad ID. The callback is built by `runCalibration`/`resumeABC` only when `cdf_grid_k` is set, and threaded through `_runABCSMC` → generation runners → `_lookupAndSnap`. `_runABCSMC` asserts `get_monad_id !== nothing` when `cdf_grid_k` is set.

**`_lookupAndSnap` replaces `_snapAndLookup`.** New lookup-first order: (1) search bank within radius of original θ_prop, (2) filter by `used_monad_ids` + `batch_monad_ids`, (3) if usable candidates: pick random, return `(bank_coords, bank_mid)`, (4) else snap to grid, resolve monad ID, check against sets, return `(snapped_params, snap_mid)` or `nothing`.

**`_bankBoxCandidates` docstring update.** Parameter renamed from `snapped_cdf` to `query_cdf` to reflect that the input need not be snapped — it is any CDF vector.

### Files changed
- `src/calibration/problem.jl` — removed `cdf_coords` field and compat constructor from `GenerationResult`
- `src/calibration/abc.jl` — removed `cdf_coords` matrix from `_loadGenerations`; added `_buildGetMonadID`; `runCalibration` and `resumeABC` build and pass `get_monad_id`
- `src/calibration/abc_smc.jl` — `_runABCSMC` gains `get_monad_id` kwarg + guard; generation runners switched to `used_monad_ids::Set{Int}` + `batch_monad_ids::Set{Int}`; `_snapAndLookup` replaced by `_lookupAndSnap`; `_buildGenerationResult` drops `cdf_coords`; `_bankBoxCandidates` docstring updated
- `test/runtests.jl` — removed `GenerationResult cdf_coords field` and `_buildGenerationResult populates cdf_coords` testsets; replaced `_snapAndLookup` testset with `_lookupAndSnap` (new interface, monad-ID return, `batch_monad_ids` coverage); integration test updated with consistent `get_monad_id_fn`/`evaluate_batch` mocks

---

## 2026-05-03 — CDF-grid safeguards: k_base correction, snap_retry_limit, max_evaluations

### Motivation

Three robustness gaps identified in the CDF-grid snapping implementation:

1. **Coarse k_base.** If `cdf_grid_k` is too small for the population size and parameter
   dimension, the grid has fewer interior points than `population_size`, making it impossible
   for gen-1 to fill its population. Need a pre-run correction.

2. **Stuck proposal loop.** If the grid fills up (all unused snap points exhausted within
   `used_monad_ids`), `_lookupAndSnap` will return `nothing` on every call, spinning
   forever. Need a mechanism to escape by increasing grid resolution.

3. **Unbounded evaluation cost.** No way to cap total simulations. For calibration runs
   used as budget-capped exploratory searches, the user needs a hard budget stop.

### Design decisions

**k_base correction (in `_runABCSMC`).** Computed once at run start:
`k_min = ceil(Int, log2(N^(1/d) + 1))` where N = `population_size`, d = number of
latent dimensions. This is the smallest k such that `(2^k - 1)^d ≥ N`. The effective
base is `k_base_eff = max(method.cdf_grid_k, k_min)`. An `@info` message is emitted if
the correction fires. The corrected value is passed to the generation runners as a kwarg,
never written back to the struct.

**`snap_retry_limit` (new `ABCSMC` field).** Counts consecutive `_lookupAndSnap` failures
(returning `nothing`). Resets to 0 on any success. When the count reaches the limit,
`k_eff` is incremented by 1 and the counter resets. Default: `nothing` when `cdf_grid_k`
is `nothing`; `100` otherwise. Exposed as a user-visible kwarg because 100 is a
reasonable default but the correct value is problem-dependent.

**`max_evaluations` (new `ABCSMC` field).** `budget::Ref{Int}` initialized to the sum
of `n_evaluations` from any `start_generations` (for correct resume accounting).
Incremented by `length(params_list)` after each `evaluate_batch` call. When
`budget[] >= method.max_evaluations`, `budget_hit[]` is set. The outer loop in
`_runABCSMC` checks `budget_hit[]` after each generation and breaks. Within
`_runSubsequentGeneration`, the inner while loop also breaks immediately after each
batch where `budget_hit[]` is set, so the partial generation is returned with however
many particles were accepted.

**`snap_failures` reset on success.** The counter tracks *consecutive* failures. On any
successful `_lookupAndSnap` call (returning non-nothing), it resets to 0. This means a
single stuck run of failures triggers the escape; recovery doesn't penalize future rounds.

**Helper extraction to eliminate duplicated code.** After the three safeguards were
implemented, both `_runFirstGeneration` and `_runSubsequentGeneration` contained identical
blocks for (a) tracking `snap_failures` / widening `k_eff`, and (b) incrementing the
`budget` Ref and setting `budget_hit`. These were extracted into two helpers:

- `_snapAndTrack(params, param_names, k_eff, radius, bank, used_monad_ids,
  batch_monad_ids, get_monad_id, snap_failures, snap_retry_limit)` — wraps `_lookupAndSnap`
  and the `snap_failures` / `k_eff` widening logic. Returns `(result, k_eff, radius,
  snap_failures)` as a tuple; callers rebind all four. Emits `@info` when `k_eff` is
  widened (not `@warn` — the widening is expected normal behavior, not a warning).

- `_updateBudget!(budget, budget_hit, n, max_evaluations)` — increments `budget[]` by `n`
  and sets `budget_hit[] = true` when the budget is exceeded.

**`_stoppingReason` budget integration.** The outer `_runABCSMC` loop originally had two
separate checks: `if budget_hit[] ... break end` followed by `stop_reason =
_stoppingReason(...)`. These were unified by adding a `budget_hit::Bool=false` kwarg to
`_stoppingReason`. When `budget_hit=true`, it returns `"max_evaluations=N reached"` before
checking any other criterion. The redundant explicit break was removed.

### Files changed
- `src/calibration/methods.jl` — added `snap_retry_limit::Union{Nothing,Int}` and
  `max_evaluations::Union{Nothing,Int}` fields; constructor defaults; validation
- `src/calibration/abc_smc.jl` — `_runABCSMC`: k_base_eff correction block, budget Ref
  pair, pass to runners, unified stop-check via `_stoppingReason(…; budget_hit=…)`;
  `_runFirstGeneration`: new kwargs `k_base_eff`, `budget`, `budget_hit`; snap logic via
  `_snapAndTrack`; budget via `_updateBudget!`; `_runSubsequentGeneration`: same kwargs;
  `snap_active` and `_effectiveK` use `k_base_eff`; proposal loop uses `_snapAndTrack` and
  `_updateBudget!`; new helper functions `_snapAndTrack`, `_updateBudget!` in CDF-Grid
  Snap Helpers section; `_stoppingReason` gains `budget_hit::Bool=false` kwarg
- `src/calibration/abc.jl` — `runABC`: added `snap_retry_limit` and `max_evaluations`
  kwargs; `_saveMethod`: persists both (omit when nothing); `_loadMethod`: loads both
- `test/runtests.jl` — four new testsets: fields + validation, save/load round-trip,
  k_base_eff correction integration test, max_evaluations stopping integration test

---

## Task #19 — LatentVariation inverse maps + LVSource bank support (2026-05-04)

**Goal.** Enable `SimulationBank` for calibration problems that include `LVSource` parameters by adding optional inverse maps to `LatentVariation`.

### Design decisions

**`inverse_maps` field.** `LatentVariation` gains `inverse_maps::Union{Nothing,Vector{Function}}`. Each `inv_map_i(target_vals::Vector{Float64}) → Float64` maps the full ordered vector of target values to the CDF coordinate `u_i ∈ (0,1)` for latent dimension `i`. One inverse per latent dimension.

**Auto-construction for DV/CV.** The `LatentVariation(dv::DistributedVariation)` and `LatentVariation(cv::CoVariation{DistributedVariation})` factory constructors auto-construct `inverse_maps` from `cdf(dist, ·)`. The CVSource inverse also embeds a joint-consistency check (returns `NaN` when co-variation constraint is violated), which `_bankCdfCoords` treats as `nothing`.

**Round-trip validation.** The continuous inner constructor calls `validateInverseMaps(lv)` when `inverse_maps` is non-`nothing`. This validates both directions: `u → target → u′` (checks round-trip accuracy and `u′ ∈ (0,1)`) and `u → target → u′ → target′` (checks `target′ ≈ target`). Throws `ArgumentError` on failure. Exported so users can also call it independently.

**`_bankCdfCoords` refactor.** The three per-source dispatch methods (`DVSource`, `CVSource`, `LVSource`) were removed in favour of a single `_bankCdfCoords(lv::LatentVariation, vals)` method that dispatches on `!isnothing(lv.inverse_maps)`. The top-level entry `_bankCdfCoords(cp, vals)` now delegates to `cp.lv`.

**Phase 2 LVSource bounds.** `_buildSimulationBank` Phase 2 checks source type directly (`cp.source isa LVSource`) before calling `_bankColDistribution` to avoid triggering the `@warn` bug-indicator path. LVSource columns skip support-bounds pre-filtering (no per-target distribution exists); Phase 3 CDF inversion handles exclusion via `0 < u < 1`.

**Partial enablement.** LVSource parameters without `inverse_maps` still disable the bank (informational log). Only when all LVSource parameters in a problem carry `inverse_maps` is the bank enabled.

### Files changed
- `src/variations.jl` — `LatentVariation` struct: new `inverse_maps` field; both inner constructors: `inverse_maps` keyword, validation call; new exported `validateInverseMaps`; DV/CV factory constructors: auto-constructed `inverse_maps`
- `src/calibration/bank.jl` — LVSource early-exit replaced with inverse_maps check; Phase 2 LVSource bounds skipped; `_bankCdfCoords` rewritten to use `lv.inverse_maps`; docstrings updated
- `test/runtests.jl` — updated LVSource comment; added LVSource-with-inverse, CVSource inconsistency, and `validateInverseMaps` testsets
- `PRD.md` — planned item updated to reflect implementation

---

## Task #20 — Kernel type hierarchy: `AbstractKernel` (2026-05-06)

**Goal.** Replace `perturbation_kernel::Symbol` on `ABCSMC` with a proper `AbstractKernel` type hierarchy enabling dispatch-based perturbation strategies.

### Design decisions

**`AbstractFittedKernel` parent.** User requested that all fitted structs share an abstract supertype so that `_computeWeights` and other callers can type-annotate at the `AbstractFittedKernel` level and get correct dispatch. Added alongside `AbstractKernel`.

**`LocalNNCovKernel` as a fourth type.** Original plan had only `LocalNNKernel` (global covariance shape + per-particle bandwidth scalar). User pointed out this poorly handles banana-shaped or anisotropic posteriors because the *direction* of the kernel is fixed. Added `LocalNNCovKernel` which stores N per-particle Cholesky factorizations — each particle's kernel covariance is estimated from its k nearest neighbors. Cost: N Cholesky factorizations per generation vs. 1 for `LocalNNKernel`.

**Inner constructors for validation.** `GaussianKernel` and `ComponentwiseKernel` required inner constructors with `new(...)` because Julia's dispatch prefers the auto-generated inner struct constructor over outer constructors when the argument type exactly matches the field type. Outer `GaussianKernel(-1.0)` was silently bypassing validation. `LocalNNKernel` and `LocalNNCovKernel` use positional inner constructors (no ambiguity issue with keyword outer constructors).

**No `MvNormal` in `_kernelDensity`.** `Distributions.MvNormal` doesn't accept a `Cholesky` object directly (requires `PDMats.AbstractPDMat`). All `_kernelDensity` methods use the Cholesky log-pdf formula directly: `log_det = 2Σ log(U_ii)`, `quad = dot(diff, chol \ diff)`, `return exp(-quad/2 - log_det/2 - (d/2)*log(2π))`.

**TOML subtable format.** Kernel serialized as `[perturbation_kernel]` with `type = "GaussianKernel"` etc. Legacy flat-string format (`perturbation_kernel = "gaussian"`) detected in `_deserializeKernel` and raises a descriptive `ErrorException`.

### Files changed
- `src/calibration/methods.jl` — `AbstractKernel`, 4 kernel types with inner-constructor validation, `_effectiveKernelScale`, updated `ABCSMC` struct/constructor/docstring
- `src/calibration/abc_smc.jl` — `AbstractFittedKernel`, 4 fitted structs, `_fitKernel`/`_proposeParticle`/`_kernelDensity` (4 methods each), refactored `_runSubsequentGeneration`, deleted `_buildPerturbationKernel`/`_perturbParticle`, updated `_computeWeights`
- `src/calibration/abc.jl` — `_serializeKernel`/`_deserializeKernel`/`_toKernelScale`, updated `_saveMethod`/`_loadMethod`, updated `runABC` signature
- `src/ModelManager.jl` — export `AbstractKernel, GaussianKernel, ComponentwiseKernel, LocalNNKernel, LocalNNCovKernel`
- `test/runtests.jl` — `using LinearAlgebra`, 3 updated existing tests, ~200 lines of new testsets (kernel construction, `_effectiveKernelScale`, `_fitKernel` × 4, `_proposeParticle`, `_kernelDensity`, ABC-SMC with each kernel type, TOML round-trip, legacy Symbol error)
- `PRD.md` — `LocalNNCovKernel` added, `AbstractFittedKernel` noted in private structs list
- `README.md` — kernel type hierarchy marked complete

---

## 2026-05-06 — Posterior visualization — all four recipes (task #7)

### Goal

Implement all four RecipesBase visualization recipes for `ABCResult`, plus the supporting data model (`store_rejected`, `rejected_proposals`) and `KernelDensity.jl` dependency.

### Design decisions

**`space=:cdf` not `:latent`.** The keyword is `space=:cdf` (not `:latent`) to avoid confusion with "latent parameters" — a term the codebase already uses for `LVSource`-backed parameters. `:cdf` is unambiguous: it refers to the ABC internal CDF coordinate space.

**Primary space is target-parameter.** All visualization recipes default to `space=:target` (biological units / user-facing parameter values). CDF space is diagnostic only.

**`store_rejected` is opt-in (default `false`).** Rejected proposals can be 10–50× accepted count; only needed for the transition plot. Stored as CDF coordinates in `GenerationResult.rejected_proposals` (consistent with `particles`); converted to target space at plot time via the same path as `posterior()`.

**Lazy disk fallback for rejected proposals.** When `rejected_proposals === nothing`, the `:transition` recipe loads all evaluated monad IDs from `generation_{t+1}_monads.csv`, subtracts the accepted IDs, and fetches target values via `simulationsTable`. This makes the full accepted/rejected plot available by default without requiring `store_rejected=true`, as long as the calibration folder is on disk. For `space=:cdf`, additionally requires inverse maps on all parameters (LVSource without inverse maps → skip, accepted-only).

**Duplicate encoding.** With CDF-grid snapping, many proposals share the same grid point. Default (`aggregate_duplicates=true`): group by unique position; accepted bubble area ∝ aggregate weight, rejected bubble area ∝ count × `w_ref` (where `w_ref = 1/population_size`) — same scale for direct comparison. 1D diagonal: stacked strip chart — duplicate positions stack vertically, so height = count directly.

**Recipe dispatch.** `@recipe function f(result::ABCResult)` for the pairs plot; `@recipe function f(result::ABCResult, style::Symbol)` with internal branching on `:ridgeline` and `:transition`; `@recipe function f(cs::DataFrame)` for the convergence trace. No named functions like `plot_transitions` are generated.

**`latent_params`/`target_params` generation keyword.** Both accessor functions accept `generation=:final` (default) or an integer index.

### Open questions
- None at this time.

### Files changed
- `src/calibration/methods.jl` — `store_rejected::Bool` field + keyword on `ABCSMC`; `_saveMethod`/`_loadMethod` updated
- `src/calibration/problem.jl` — `rejected_proposals` field on `GenerationResult`; `latent_params`/`target_params` accessors
- `src/calibration/abc_smc.jl` — collect rejected coords in `_runSubsequentGeneration`; `_buildGenerationResult` signature updated
- `src/calibration/visualize.jl` — new file: all four recipes + `_lazyLoadRejected` helper
- `src/ModelManager.jl` — exports + `include("calibration/visualize.jl")`
- `Project.toml` — `KernelDensity` added to `[deps]` and `[compat]`
- `PRD.md` — task #7 expanded with `:transition` recipe, `store_rejected` data model, lazy-load fallback; `space=:latent` renamed to `space=:cdf`

---

## 2026-05-18 — Relax CalibrationProblem type constraints; extend mseDistance

### Goal
Remove the `Dict{String,Any}` coercions that forced all users into dict-based summary statistics and distance functions, and extend `mseDistance` with vector and scalar calling conventions.

### Design decisions

**`observed_data::Any`.** Changed from `Dict{String,Any}` to `Any` in the `CalibrationProblem` struct. Both outer constructors drop the `Dict{String,Any}(observed_data)` coercion and store the value as-is. Constructor argument types also broadened from `Dict{String,<:Any}` to `Any`.

**No coercion in `evaluate_batch`.** The two-line dict coercion in `abc.jl`:
```julia
simulated_dict = Dict{String,Any}(String(k) => v for (k, v) in simulated)
distance = problem.distance(simulated_dict, problem.observed_data)
```
collapsed to a single line: `distance = problem.distance(simulated, problem.observed_data)`. The `distance` function is now fully responsible for interpreting both arguments.

**Three `mseDistance` methods.** Added two new methods alongside the existing dict method:
- `mseDistance(sim::Real, obs::Real)` → `(sim - obs)²` — squared difference is the trivial MSE for a single value.
- `mseDistance(sim::AbstractVector{<:Real}, obs::AbstractVector{<:Real})` → `Σ(simᵢ−obsᵢ)²` — sum of squared distances with a length guard.

The three methods are intentionally heterogeneous in their reduction: absolute error for scalars, L2 norm for vectors, mean-of-per-key-MSE for dicts. Each is the natural quantity for its input shape.

### Files changed
- `src/calibration/problem.jl` — `observed_data::Any`; both constructors broadened
- `src/calibration/abc.jl` — removed dict coercion in `evaluate_batch`
- `src/calibration/distance.jl` — two new `mseDistance` methods; docstring updated
- `test/runtests.jl` — new tests for vector/scalar `mseDistance`; `DimensionMismatch`; non-dict `observed_data` round-trip; non-dict `evaluate_batch` integration
- `PRD.md` — updated `mseDistance` spec and acceptance criteria
