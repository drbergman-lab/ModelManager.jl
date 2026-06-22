# Product Requirements Document — ModelManager.jl

> **Purpose:** This document defines the complete feature set of ModelManager in behavioral terms. It is the authoritative answer to "what should this system do?" Read this at the start of any feature session to establish alignment between intent and implementation plan.

---

## Product Overview

**Vision:** ModelManager provides simulator-agnostic ABM infrastructure so that any Julia-based agent-based modeling framework can inherit a complete simulation management stack — parameter variation, space-filling designs, sensitivity analysis, database provenance, and HPC support — without reimplementing it.

**Target Users:** Julia package authors building simulator-specific frontends (e.g. PhysiCellModelManager.jl).

**Business Objectives:**
1. Eliminate duplicated infrastructure across simulator packages.
2. Provide a stable, well-tested base that simulator packages inherit without modification.
3. Allow simulator authors to focus on their domain logic rather than bookkeeping.

---

## Feature: AbstractSimulator Interface

**One-line description:** Define the extension contract that simulator packages must fulfill.

**Priority:** Must-have

**Behavioral specification:**
- `abstract type AbstractSimulator end` is the base type.
- Required interface methods are declared as bare `function foo end` stubs with docstrings in `abstract_simulator.jl`.
- Optional interface methods have default no-op implementations.
- ModelManager dispatches on `mm_globals().simulator` for all simulator-specific calls.

**Required interface methods:**
- `runSimulation(sim, spec::SimulationSpec)` → `SimulationProcess`
- `simulatorDir(sim)` → `String`
- `simulatorVersionSchema(sim)` → `String` (SQL sub-schema for version table)
- `simulatorVersionIDName(sim)` → `String` (FK column name in simulations/monads/samplings)
- `simulatorVersionTableName(sim)` → `String`
- `resolveSimulatorVersionID(sim)` → `Int`
- `currentSimulatorVersionID(sim)` → `Int`
- `simulatorInfo(sim)` → `String`
- `postInitDisplay(sim)` — print startup info
- `setupMonad(sim, monad; force_recompile)` → `Bool`
- `setupSampling(sim, sampling; force_recompile)` → `Bool`
- `variationLocation(sim, target)` → `Symbol`
- `addVariationRows(sim, inputs, reference_variation_id, loc_dicts)` → `Vector{VariationID}`

**Optional interface methods (default no-ops):**
- `postSimulationProcessing(sim, simulation_process; kwargs...)` — pruning, cleanup
- `initializeInputFolder(sim, input_folder)` — per-folder setup on insert
- `getInputFolderDescription(sim, path)` → `String` (default `""`)
- `clearSimulatorArtifacts(sim)` — remove build artifacts on database reset
- `packageName(sim)` → `String` — for version lookup via `Pkg`
- `dbVersionTableName(sim)` → `String` — tracks migration state
- `upgradeMilestones(sim)` → `Vector{VersionNumber}`
- `upgradeToMilestone(sim, version, auto_upgrade)` → `Bool`

**Acceptance criteria:**
- A package implementing all required methods compiles and runs simulations end-to-end.
- A package implementing only optional methods falls back gracefully to defaults.

---

## Feature: Global State

**One-line description:** Provide a typed, globally accessible state object that simulator packages set during `__init__`.

**Priority:** Must-have

**Behavioral specification:**
- `ModelManagerGlobals` is a `@with_kw mutable struct` with fields for all generic state (db, data_dir, inputs_dict, etc.).
- The `simulator` field has no default — it must be provided by the caller.
- `mm_globals_ref = Ref{Union{Nothing,ModelManagerGlobals}}(nothing)` is the module-level storage.
- `mm_globals()` returns the current globals, asserting it has been initialized.
- Simulator packages call `mm_globals_ref[] = ModelManagerGlobals(simulator=MySimulator(...))` in their `__init__`.
- Zero-arg accessor functions (`centralDB()`, `dataDir()`, `projectLocations()`, etc.) read from `mm_globals()`.

**Acceptance criteria:**
- Calling `mm_globals()` before initialization throws a descriptive error.
- After a simulator package sets `mm_globals_ref[]`, all zero-arg accessors return correct values.

---

## Feature: Trial Hierarchy

**One-line description:** Typed containers that organize simulations into monads, samplings, and trials.

**Priority:** Must-have

**Behavioral specification:**
- `Simulation` — a single run with fixed inputs and variation IDs.
- `Monad` — a set of replicate simulations sharing the same inputs and variation IDs.
- `Sampling` — a set of monads sweeping variation space.
- `Trial` — a set of samplings (e.g. across multiple input folder combinations).
- `InputFolders` — named tuple of `InputFolder` objects, one per location.
- `VariationID` — named tuple mapping location symbols to their current variation row IDs.

**Acceptance criteria:**
- `Simulation(id)` reconstructs a simulation from the database by ID.
- `Monad(inputs, variation_id; n_replicates, use_previous)` creates or retrieves a monad.
- `Sampling(inputs, location_variation_ids; n_replicates, use_previous)` creates or retrieves a sampling.
- `constituentIDs(T, id)` returns the IDs of the next level down in the hierarchy.

---

## Feature: Parameter Variations

**One-line description:** Define, store, and retrieve parameter variations in per-folder SQLite databases.

**Priority:** Must-have

**Behavioral specification:**
- `XMLPath` holds an XML path as a `Vector{String}`.
- `DiscreteVariation` holds a target and a vector of values; location is inferred via `variationLocation(sim, target)`.
- `DistributedVariation` holds a target and a `Distribution`; supports `flip`.
- `CoVariation` groups multiple elementary variations that move together.
- `LatentVariation` maps latent parameters to target parameters via user-supplied functions.
- `ParsedVariations` converts any mix of variation types to `LatentVariation`s for uniform processing.
- `addVariations(method, inputs, avs, reference_variation_id)` writes rows to the variations DB and returns `Vector{VariationID}`.
- `addVariationRows(sim, inputs, reference_variation_id, loc_dicts)` is the simulator-dispatched write operation.

**Space-filling methods:** `GridVariation`, `LHSVariation`, `SobolVariation`, `RBDVariation`.

**Acceptance criteria:**
- `DiscreteVariation(xml_path, values)` constructs without error when `mm_globals` is set.
- `addVariations(GridVariation(), inputs, [dv])` inserts rows and returns one `VariationID` per grid point.
- Re-adding an identical variation returns the existing ID (idempotent).

**Future enhancement (not yet scoped):** Let variation constructors accept a bare
`Vector{String}` target. ModelManager would identify the input file's format (from the target
location) and convert the vector to the appropriate path type — `XMLPath` for XML, another path
type for other formats — so users need not wrap the path themselves. Today the constructors
require an explicit path object (`XMLPath`) to keep the core format-agnostic; this would add the
ergonomic shortcut *without* baking XML into the API. Would cover `DiscreteVariation`,
`DistributedVariation`, `Uniform`/`NormalDistributedVariation`, `LatentVariation`, and the
`CoVariation` tuple forms, and requires a format-detection/dispatch mechanism keyed on the
target location's file type.

---

## Feature: Simulation Runner

**One-line description:** Execute pending simulations in parallel (local or HPC) and track results in the database.

**Priority:** Must-have

**Behavioral specification:**
- `run(T::AbstractTrial; force_recompile, kwargs...)` collects simulation tasks, executes up to `mm_globals().max_number_of_parallel_simulations` concurrently, and returns `MMOutput{T}`.
- `kwargs` are forwarded to `prepareTrialHierarchy` (simulator hooks like `force_recompile`) and to `postSimulationProcessing` (simulator-specific cleanup/pruning). `runSimulation` takes no kwargs — it receives only the `SimulationSpec`.
- On HPC, each simulation is wrapped in an `sbatch --wrap` invocation.
- A simulation that fails is marked `"Failed"` in the database and removed from its monad's constituent list. If the monad becomes empty, it is deleted along with empty parents.
- Already-started simulations are skipped (idempotent re-runs).

**Acceptance criteria:**
- `run(simulation)` runs a single simulation and returns `MMOutput{Simulation}`.
- `run(monad)` runs all pending replicates and returns correct success counts.
- A failed simulation does not prevent other simulations in the same monad from running.

---

## Feature: Deletion

**One-line description:** Remove simulations and their parent containers from the database and disk.

**Priority:** Must-have

**Behavioral specification:**
- `deleteSimulations(ids)` removes simulations from DB and disk; optionally cascades to empty monads/samplings/trials (`delete_supers=true`).
- `deleteMonad`, `deleteSampling`, `deleteTrial` cascade up and down as appropriate.
- `resetDatabase()` deletes all outputs, clears variation files, calls `clearSimulatorArtifacts(sim)`, and reinitializes the DB.
- On HPC, file removal goes through `rm_hpc_safe` (staging in `.trash/`) to avoid NFS lock issues.

**Acceptance criteria:**
- After `deleteSimulations(ids)`, no rows remain in `simulations` for those IDs.
- Empty monads are removed when `delete_supers=true`.
- `resetDatabase()` leaves the project in the same state as a fresh `initializeDatabase()`.

---

## Feature: Global Sensitivity Analysis

**One-line description:** Run MOAT, Sobol', and RBD sensitivity analyses on any scalar output function.

**Priority:** Must-have

**Behavioral specification:**
- `MOAT`, `Sobolʼ` (`SobolMM`), and `RBD` are subtypes of `GSAMethod`.
- `run(method, inputs, avs; functions, kwargs...)` creates the sampling design, runs simulations, computes indices for each function in `functions`, and records the scheme to CSV.
- `functions` is a `Vector{Function}` where each `f(simulation_id) -> Real`.
- `kwargs` are forwarded to `run(::Sampling; ...)`.

**Acceptance criteria:**
- `run(MOAT(5), inputs, [dv])` creates `5*(d+1)` monads and returns a `MOATSampling`.
- `calculateGSA!(gsa_sampling, f)` is idempotent (re-running with the same function does not repeat computation).
- `recordSensitivityScheme` writes a CSV with monad IDs matching the sampling design.

**Sensitivity visualization:** `RecipesBase.jl` recipes (no backend dependency) for the three `GSASampling` subtypes, mirroring the calibration recipes in `sensitivity_visualize.jl`. Each emits one series per sensitivity function in the `results` dict, iterated in label-sorted order for reproducibility; the series label includes the function name only when more than one function is present. Parameter (x-axis) names come from the `monad_ids_df` columns after the method's bookkeeping columns (`base` for MOAT; `A`,`B` for Sobolʼ; none for RBD).
  - **`plot(m::MOATSampling, style=:bar; show_sigma=false)`** — grouped bar chart of µ* (`means_star`); `show_sigma=true` overlays σ = `sqrt(variances)` as ±whiskers (`yerror`).
  - **`plot(m::MOATSampling, :violin)`** — violin of the full `elementary_effects` distribution per parameter (requires a `:violin`-capable backend, e.g. `StatsPlots`).
  - **`plot(m::MOATSampling, :scatter)`** — classic Morris µ* (x) vs σ (y) screening scatter, points annotated with parameter names.
  - **`plot(s::SobolSampling; show_ST=true)`** — first-order `S1` bars plus, when `show_ST`, total-order `ST` bars at reduced opacity (`fillalpha=0.45`); `ST` skipped if absent.
  - **`plot(r::RBDSampling)`** — first-order index bars.
  - Internal plot-data wrappers (`_GSABarData`, `_GSAViolinData`, `_GSAScatterData`) and builder functions (`_moatBarData`, `_moatViolinData`, `_moatScatterData`, `_sobolBarData`, `_rbdBarData`) take `(results, monad_ids_df, …)` so the chart logic is unit-testable via `RecipesBase.apply_recipe` without constructing a live `Sampling`/DB. Empty `results` raises an informative error.

**Visualization acceptance criteria:**
- `apply_recipe` on each builder's output yields one series per function (Sobolʼ: ×2 when `show_ST` and `ST` present).
- MOAT `show_sigma=true` populates the bar group's `yerror` with `sqrt(variances)`.
- Parameter-name extraction drops the correct leading bookkeeping columns per method.

---

## Feature: Schema Migrations

**One-line description:** Versioned database migrations so projects can be upgraded across package versions.

**Priority:** Must-have

**Behavioral specification:**
- `upgradePackage(sim; auto_upgrade)` walks from the DB's recorded version to the current package version, calling `upgradeToMilestone(sim, v, auto_upgrade)` for each milestone.
- Simulator packages implement `upgradeMilestones`, `upgradeToMilestone`, `dbVersionTableName`, and `packageName`.
- `continueMilestoneUpgrade(version, auto_upgrade)` prompts the user for destructive migrations (unless `auto_upgrade=true`).

**Acceptance criteria:**
- A project at version N can be upgraded to version N+2 by walking through N→N+1→N+2.
- If the user declines at a milestone, the upgrade stops and the DB remains at the last successfully upgraded version.

---

## Feature: Flatten SimulationSpec and Separate Setup from Collection

**One-line description:** Remove `AbstractSimulationSpec`, harden `SimulationSpec`, and split `collectPendingSimulations` into `prepareTrialHierarchy` + `pendingSimulationSpecs`.

**Priority:** Must-have (internal quality)

**Behavioral specification:**
- `SimulationSpec` is a plain struct (no abstract supertype) with `simulation::Simulation` and `monad_id::Int`. `monad_id` is always a real monad ID — setup always precedes collection.
- `prepareTrialHierarchy(T::AbstractTrial; kwargs...) → Bool` recurses down the trial hierarchy creating folders and calling simulator hooks. Dispatches on `AbstractMonad` (Simulation/Monad), `Sampling`, and `Trial`. Never marks simulations as Queued.
  - `AbstractMonad`: mkpath + `setupSampling` hook + `setupMonad` hook (both called on `M` directly — no wrapping `Sampling` created).
  - `Sampling`: mkpath + `setupSampling` once for the sampling + mkpath and `setupMonad` for each monad.
  - `Trial`: mkpath + recurse into samplings.
- `pendingSimulationSpecs(T::AbstractTrial) → Vector{SimulationSpec}` enumerates unstarted simulations and marks them Queued. Always called after `prepareTrialHierarchy`.
  - `Simulation`: returns `[SimulationSpec(simulation, Monad(simulation).id)]` if not started.
  - `Monad`: returns one spec per unstarted sim.
  - `Sampling`/`Trial`: recurse.
- `run(T; kwargs...)` calls `prepareTrialHierarchy` then `pendingSimulationSpecs`, then launches tasks. No normalization of `T` needed.
- The `setupSampling` and `setupMonad` simulator hook stubs accept `AbstractSampling` and `AbstractMonad` respectively (previously `Sampling`/`Monad`).

**Acceptance criteria:**
- `run(simulation)` still returns `MMOutput{Simulation}`.
- `run(monad)`, `run(sampling)`, `run(trial)` all behave identically to before with no new DB rows created.
- No references to `AbstractSimulationSpec` remain anywhere.
- No `monad_id=missing` or `ismissing(spec.monad_id)` patterns remain.

---

## Feature: Calibration Infrastructure (ABC-SMC)

**One-line description:** Framework-agnostic ABC-SMC parameter calibration migrated from PCMM.

**Priority:** Must-have

**Behavioral specification:**
- `CalibrationProblem` groups inputs, parameters, observed data, summary statistic, and distance function. The `parameters` field accepts any `AbstractVector{<:AbstractVariation}` — specifically `DistributedVariation`, `CoVariation{DistributedVariation}`, or `LatentVariation{<:Distribution}` — and converts them internally via `_toCalibrationParameter` to `CalibrationParameter` objects. Each `CalibrationParameter` pairs an `AbstractCalibrationSource` (the original variation, one of `DVSource`/`CVSource`/`LVSource`) with the derived `LatentVariation{<:Distribution}` used by the ABC-SMC loop. The ABC-SMC algorithm samples CDF values on [0, 1] for each latent dimension; the stored `LatentVariation`'s maps convert those values into concrete target parameter values at simulation time. The `summary_statistic` and `distance` functions are user-supplied and may be simulator-specific.
- `ABCSMC <: AbstractCalibrationMethod` holds SMC settings: `population_size`, `max_nr_populations`, `minimum_epsilon`, `epsilon_quantile`, `perturbation_kernel`, plus optional stopping criteria and epsilon schedule.
- `runABC(problem; kwargs...)` and `runCalibration(problem, ABCSMC(); ...)` run the full SMC loop.
- `resumeABC(calibration::Calibration; method=nothing, run_kwargs=(;))` resumes from saved generation files. No `problem` argument required — the `CalibrationProblem` is loaded from `problem.jld2` (written by `runABC`/`runCalibration`). Pass `method=ABCSMC(...)` to override the saved settings.
- `mseDistance(simulated, observed)` is a family of built-in distance functions:
  - `mseDistance(::Dict{String,<:Any}, ::Dict{String,<:Any})` — mean of per-key squared errors (scalar keys) or mean squared errors (vector keys), averaged across all keys in `observed`.
  - `mseDistance(::AbstractVector{<:Real}, ::AbstractVector{<:Real})` — sum of squared differences `Σ(simᵢ−obsᵢ)²`; requires equal lengths (throws `DimensionMismatch` otherwise).
  - `mseDistance(::Real, ::Real)` — squared difference `(sim − obs)²`.
- `CalibrationProblem.observed_data` is typed `Any`; any type accepted by the user-supplied `distance` function is valid.
- `summary_statistic` may return any type accepted by `distance` as its first argument; no dict coercion is applied.
- Particle evaluations are batched per generation, not run one-by-one. Each generation proposes a batch of candidate parameter vectors, creates one `Monad` per candidate via `addVariations` + `Monad(...)`, assembles them into a `Sampling`, and calls `run(sampling; quiet=true)` — exploiting MM's parallel runner.
- **Generation 1:** proposes exactly `population_size` particles in a single batch (all are accepted, no epsilon threshold). One `Sampling` run per generation.
- **Generation t > 1:** uses iterative adaptive batching. The batch size for each round is `ceil(n_needed / acceptance_rate_est)`, where `acceptance_rate_est` is updated after each round (initialized from the previous generation's acceptance rate). Batching repeats until `population_size` accepted particles are collected; if a round overshoots, the excess is trimmed.
- The `evaluate_batch` callback in `abc.jl` takes `(t::Int, params_list::Vector{Dict{String,Float64}})`, where `t` is the generation index. For each proposal it creates a `Monad` via `_createMonadForParams` (which uses each `CalibrationParameter`'s `lv` maps to convert CDF values to target `DiscreteVariation`s), records all monad IDs to `generation_{NNN}_monads.csv` **before** running simulations (crash safety), assembles a `Sampling`, calls `run(sampling; quiet=true)`, and returns `Vector{Tuple{Float64,Int}}` (distance, monad_id) in proposal order.
- Per-generation results are saved in two forms. **Human-readable:** `generations/generation_{NNN}.csv` (columns: user-friendly parameter display names, `weight`, `distance`, `monad_id`) and `generations/generation_{NNN}.toml` (generation-level metadata: `epsilon`, `acceptance_rate`, `ess`, `n_evaluations`). **Machine-readable (resume):** `generation_cdfs/generation_{NNN}.csv` (raw CDF coordinates + `weight`, `distance`, `monad_id`). `NNN` is zero-padded to `ndigits(max_nr_populations)`.
- Display column names in `generations/` CSVs use `variationName(dv)` (user-supplied or `shortVariationName`-derived) rather than raw DB column names (`columnName(target)`). The mapping from display names to DB column names is written to `parameters.toml` for human inspection without loading Julia.
- `runABC`/`runCalibration` write three persistence files to the calibration folder: `method.toml` (ABCSMC settings), `problem.jld2` (full `CalibrationProblem` serialized via JLD2), `parameters.toml` (display-name → DB-column mapping + prior strings).
- `resumeABC` checks stopping criteria against already-completed generations before starting the loop (handles the case where the run already finished and `resumeABC` is called again).
- The `calibrations` table is created as standard infrastructure in `createSchema()`.
- `posterior(result::ABCResult)` returns `(df, weights)` where `df` has one column per parameter in display format (CDF coords converted to target values). `posterior(calibration::Calibration)` reads from the `generations/` disk CSV and returns the same shape, useful after a session restart when only the ID is available.

- `GenerationResult` stores `acceptance_rate` (all proposals passing epsilon / all proposals evaluated — **not** capped at `population_size`; overshoot in the final batch does not bias the rate downward), `ess` (= 1/Σwᵢ²), `n_evaluations`, and `epsilon` per generation. These are logged after each generation and saved to `generations/generation_{NNN}.toml`.
- **Console progress reporting.** `runABC`, `runCalibration`, and `resumeABC` accept `progress::Symbol=:auto` controlling console feedback during a run. Levels stack: `:none` (silent) < `:generation` (one `@info` when each generation starts and finishes) < `:batch` (adds one `@info` per evaluation batch, numbered within the generation) < `:bar` (adds a live `ProgressMeter.jl` bar per batch, sized to that batch's pending simulations and advancing as each simulation completes). `:auto` resolves to `:bar` when `stdout` is an interactive TTY and `:generation` otherwise, so SLURM/redirected logs receive clean textual milestones rather than carriage-return bar output. The setting is runtime-only (not persisted to `method.toml`). The bar is driven by a generic, default-`nothing` `on_progress` hook on `run` that emits `:init`/`:step`/`:finish` events; when `on_progress === nothing` the runner is byte-for-byte unchanged, keeping the per-simulation completion loop framework-agnostic. Generation-start milestones report the target ε (for `t > 1`) and `population_size`; the existing generation-finish summary and stopping-reason lines are gated to `:generation` and above (so `:none` is fully silent). Verbosity helpers (`_resolveVerbosity`, `_verbosityRank`, `_logGenerationStart`, `_logBatchStart`, `_batchProgressCallback`) live in `src/calibration/progress.jl`. Because `Sobol.next!` is already in scope, ProgressMeter is brought in as a qualified `import` (not `using ... : next!`) to avoid shadowing the Sobol iterator.
- `ABCSMC` supports additional stopping criteria: `min_acceptance_rate` (stop when accepted/proposed < threshold), `min_epsilon_decrease` (stop when relative ε decrease < tol), `min_ess_fraction` (stop when ESS/N < fraction). All default to `0.0` (disabled).
- `ABCSMC` supports an optional `epsilon_schedule::Union{Nothing,Vector{Float64}}`: when provided, generation `t` uses `epsilon_schedule[t-1]` instead of the adaptive quantile rule.
- `ConvergenceSummary(result::ABCResult)` and `ConvergenceSummary(cal::Calibration)` construct a per-generation convergence table with columns `t`, `epsilon`, `acceptance_rate`, `n_accepted`, `ess`, `ess_fraction`, `n_evaluations` — one row per completed generation. The `Calibration` form loads from on-disk TOML metadata files. `ess_fraction = ess / n_accepted` (weight quality of the actual accepted set); the ESS stopping criterion uses `ess / population_size` (whether the effective count meets the target).
- **Parent selection uses systematic resampling** (Kitagawa 1996). For each adaptive batch of `n_to_propose` proposals, `_systematicResample(prev.weights, n_to_propose)` draws all parent indices at once with a single `u ~ Uniform(0, 1/n)`, placing `n` evenly-spaced points on the weight CDF. Each parent appears exactly ⌊n·wᵢ⌋ or ⌈n·wᵢ⌉ times — strictly lower variance than `n` independent draws. Any perturbed proposal that falls outside the prior is dropped; if the pass yields fewer than `n_to_propose` valid proposals, the loop calls `_systematicResample` again for the remainder with a fresh `u`.

**Planned / not yet implemented (in priority order):**

*Medium priority — algorithm quality*

- **Kernel type hierarchy — `AbstractKernel`**: Replaces `perturbation_kernel::Symbol` on `ABCSMC` with `perturbation_kernel::AbstractKernel`. Two-tiered hierarchy — `AbstractKernel` at the root, concrete subtypes directly beneath it. No intermediate abstract tier: Julia abstract types cannot carry fields, so shared logic (e.g., generation-indexed scale lookup `_kernelScale(kernel, t)`) lives in free utility functions rather than in an abstract parent.

  *Concrete kernel types (all exported):*
  - `GaussianKernel(scale::Union{Float64,Vector{Float64}} = 2.0)` — full multivariate Gaussian using `scale × weighted_covariance` (Beaumont et al. 2009). `Vector{Float64}` scale enables an explicit generation schedule: generation `t` uses `scale[min(t, end)]`. Default `scale=2.0` preserves current behavior.
  - `ComponentwiseKernel(scale::Union{Float64,Vector{Float64}} = 2.0)` — diagonal covariance; independent 1D Gaussians per parameter. More robust in high dimensions where off-diagonal covariance estimation is noisy with small populations. Same `scale` semantics as `GaussianKernel`.
  - `LocalNNKernel(k::Int = 10, scale::Float64 = 1.0)` — per-particle bandwidth: `h_j = scale × dist(θ_j, θ_j^{(k)})` where `θ_j^{(k)}` is the k-th nearest neighbor of particle `j` in the previous generation (Chebyshev metric, KD-tree via existing `NearestNeighbors.jl`). All particles share the global weighted covariance *shape* `Σ_global`; only the scalar bandwidth `h_j` varies per particle. Narrow kernels near the posterior mode, wide kernels in sparse regions. Bandwidths shrink automatically as the particle cloud concentrates, eliminating the need for an explicit generation schedule. Cost: one Cholesky per generation + O(N) knn lookups per proposal.
  - `LocalNNCovKernel(k::Int = 10, scale::Float64 = 1.0)` — per-particle fully-local covariance: for each previous-generation particle `j`, its perturbation kernel is `N(θ_j, scale × Σ_local,j)` where `Σ_local,j` is the sample covariance of particle `j`'s `k` nearest neighbors. Unlike `LocalNNKernel`, the covariance *direction* adapts locally — useful for banana-shaped or anisotropic posteriors. Cost: N Cholesky factorizations per generation (one per particle); fast in practice for N ≤ 5000, d ≤ 10.

  *Interface stubs on `AbstractKernel` (defined in `abc_smc.jl`):*
  - `_fitKernel(kernel, particles, weights, param_names, t)` → fitted kernel state; called once per generation after the previous generation's particles are known
  - `_proposeParticle(fitted, parent_particle, param_names)` → `Dict{String,Float64}`; called once per proposal
  - `_kernelDensity(fitted, from_particle, to_particle)` → `Float64`; called once per accepted particle for importance weight denominator

  *Private fitted structs (not exported):* All subtypes of `AbstractFittedKernel`. `FittedGaussianKernel` (covariance matrix + Cholesky), `FittedComponentwiseKernel` (per-parameter variance vector), `FittedLocalNNKernel` (KD-tree + per-particle bandwidth vector + global Cholesky for covariance shape), `FittedLocalNNCovKernel` (KD-tree + N per-particle Cholesky factorizations). Kernel spec types are immutable and serialized to `method.toml` under `[perturbation_kernel]` with a `type` key; fitted structs are ephemeral, rebuilt each generation.

  *Serialization:* `_saveMethod`/`_loadMethod` serialize/deserialize kernel type and parameters under a `[perturbation_kernel]` TOML subtable with a `type` key.

- **Posterior visualization** (`task #7`): Implemented via `RecipesBase.jl` (no backend dependency; works with any Plots.jl- or Makie-compatible backend). Four recipe types and two accessor functions:

  - **Pairs / corner plot** — `plot(result::ABCResult)` / `plot(cal::Calibration)`. Diagonal panels: weighted 1D KDE marginal per parameter (via `KernelDensity.jl`). Off-diagonal panels: weighted 2D KDE contours overlaid on weighted scatter (opacity encodes weight). Keyword `space = :target` (default, biological quantities) or `space = :cdf` (ABC internal CDF coordinates; should be ≈ Uniform(0,1) in early generations, useful for prior support diagnostics). Note: `contourf` requires `contourf(k2.x, k2.y, k2.density')` — the transpose is required.

  - **Posterior narrowing plot** — `plot(result::ABCResult, :ridgeline)` (ABC-SMC analog of MCMC chain plots). One panel per parameter. Stacked weighted 1D KDE curves per generation, vertically offset and shaded, earliest generation lightest, final generation darkest. Diagnoses whether the sequential posteriors are narrowing toward the data; stagnant adjacent curves flag a stuck run, just as a flat MCMC chain flags poor mixing. Same `space` keyword as the pairs plot.

  - **Convergence trace** — `plot(ConvergenceSummary(result))` or `plot(ConvergenceSummary(Calibration(id)))`. Three panels sharing a generation axis: epsilon, acceptance rate, and ESS fraction. Diagnoses convergence rate and algorithm efficiency.

  - **Generation transition plot** — `plot(result::ABCResult, :transition; generation=t, show_particles=false, space=:target, aggregate_duplicates=true)`. For generation `t` (default: `length(result.generations) - 1`, the last complete gen→gen+1 transition; requires ≥ 2 generations), renders the gen-t posterior KDE with gen-(t+1) proposal points overlaid: **accepted** in green, **rejected** in red. Default space is **target-parameter** (biological quantities for `DVSource`/`CVSource`, latent values for `LVSource`); `space=:cdf` switches to ABC CDF coordinates. When `GenerationResult.rejected_proposals === nothing` (the default with `store_rejected=false`), performs a lazy disk lookup: loads all evaluated monad IDs from `generation_{t+1}_monads.csv`, subtracts accepted IDs, fetches target-parameter values via `simulationsTable`. For `space=:cdf`, additionally inverts target→CDF via each parameter's prior CDF — requires all parameters to have inverse maps; `LVSource` parameters without user-supplied inverse maps cause the lazy lookup to be skipped (accepted-only, with title note). Also falls back to accepted-only if the monads file is absent. Layout: `d × d` corner-plot panels.
    - *Diagonal panels*: 1D KDE curve (gen t) + stacked strip chart below x-axis — accepted ticks point up (green), rejected ticks point down (red); duplicate proposals at the same position stack vertically so height = count.
    - *Off-diagonal panels*: 2D KDE contour (gen t) + aggregate bubble scatter. Accepted bubble area ∝ aggregate weight; rejected bubble area ∝ count × `w_ref` (where `w_ref = 1/population_size`), giving a common size scale. `aggregate_duplicates=false` shows individual translucent points (alpha=0.3) — coincident points saturate darker.
    - `show_particles=true` additionally renders gen-t particles as small grey rug marks beneath the KDE.

  `store_rejected::Bool = false` on `ABCSMC`: when `true`, each `GenerationResult` populates `rejected_proposals::Union{Nothing,DataFrame}` — a CDF-coordinate DataFrame of all rejected proposals (same column names as `particles`; converted to target space at plot time). Not persisted to disk; loaded as `nothing` on resume (lazy disk fallback used instead). Always `nothing` for generation 1 (all Sobol proposals are accepted).

  *Accessor functions (exported):*
  - `latent_params(result::ABCResult; generation=:final)` → particle DataFrame in CDF-coordinate space
  - `target_params(result::ABCResult; generation=:final)` → particle DataFrame in target-parameter space

- **Evaluation budget — `max_evaluations`**: `max_evaluations::Union{Nothing,Int} = nothing` on `ABCSMC`. Counts total evaluated particles (monads) across the entire calibration run — one count per entry in `evaluate_batch`'s results, regardless of whether the monad was already in the DB or was a fresh simulation. `_runABCSMC` initializes a shared `budget::Ref{Int}` counter and `budget_hit::Ref{Bool}` flag, then passes them to both generation runners. Each runner calls `_updateBudget!(budget, budget_hit, n, max_evaluations)` after every `evaluate_batch` call, which increments `budget[]` by `n` and sets `budget_hit[] = true` when the budget is reached. After each generation, `_stoppingReason` checks `budget_hit` first (before all other criteria) and returns `"max_evaluations=N reached"` when true; the current generation's accepted particles are saved before stopping. Log level is `@info`. `nothing` disables the safeguard (default). This is the ultimate backstop for overaggressive `epsilon_schedule` runs and for snapping runs with difficult-to-reach grid regions. Persisted to `method.toml`.

*Low priority — advanced / power-user features*

- **SimulationBank — pre-built CDF-space registry** (`task #15`): Built once at calibration start by `_buildSimulationBank(problem)`. Queries all existing monads whose calibrated parameters lie strictly in the interior of the prior support `(0,1)^d` in CDF space. Stored as a `SimulationBank` struct: `monad_ids::Vector{Int}`, `cdf_coords::Matrix{Float64}` (n_latent_dims × n_monads), `param_names::Vector{String}`, `tree::Union{Nothing,NNTree}` (KD-tree with Chebyshev metric, `nothing` for empty banks). A 3-arg outer constructor `SimulationBank(ids, coords, names)` auto-builds the tree. `_bankBoxCandidates` uses `inrange(bank.tree, query_cdf, radius)` for O(log n + k) L∞ queries.

  *Terminology used throughout:*
  - **Column**: a parameter that already has a column in the variation DB (was varied in a previous calibration or exploration run).
  - **Parameter**: a user-specified `CalibrationParameter` target — may or may not have a DB column yet.

  *Compatibility criteria for each monad:*
  1. All location folder IDs match `problem.inputs`.
  2. For every varied location with no calibrated parameters, the variation ID exactly matches `problem.reference_variation_id[loc]`.
  3. For each calibrated location, the variation row passes:
     - **Non-calibrated columns** (DB columns not targeted by any `CalibrationParameter`) must match the effective reference value — defined as: reference row value → `variation_id=0` default → missing. Mismatches disqualify the monad.
     - **Calibrated columns** (parameters that already exist as DB columns): effective value (row → `variation_id=0` fallback) must lie in `[minimum(dist), maximum(dist)]` of the prior.
     - **Calibrated parameters without a DB column** (never varied before — the column does not exist in the variation table at all): the base value is read from the XML config file via `getColumnDefaults` (same logic as `addColumns`). If it falls outside the prior support, no monad at that location qualifies (`skip_loc = true`). If it is within the support, all candidate variation IDs at that location inherit that base value for CDF computation.
     - **`variation_id=0` semantics**: this row always exists and holds the defaults for all columns currently in the variation table. It serves as the fallback when a candidate row has `NULL` for a column.
     - **`CVSource` joint consistency**: the latent CDF recovered from the first target must forward-map back to all other targets within relative tolerance 1e-8. Monads not on the co-variation curve are excluded.
  4. All CDF coordinates must be strictly in `(0, 1)`.

  *`LVSource` and `LatentVariation` inverse maps:* `LatentVariation` carries `inverse_maps::Union{Nothing,Vector{Function}}` — each `inv_map_i(target_vals::Vector{Float64}) → Float64` recovers the CDF coordinate `u_i ∈ (0,1)` for latent dimension `i` from the full ordered vector of target values. For `DVSource`- and `CVSource`-backed `LatentVariation`s, `inverse_maps` is auto-constructed at `LatentVariation` construction time (via `cdf(dist, ·)`; the CVSource inverse also verifies joint consistency, returning `NaN` on failure). For `LVSource`, users supply `inverse_maps` via the `inverse_maps` keyword argument; the continuous inner constructor calls `validateInverseMaps` at construction time to verify round-trip accuracy. `LVSource` parameters without `inverse_maps` still disable the bank (informational log). `_bankCdfCoords` now dispatches on `lv.inverse_maps` uniformly for all source types. Phase 2 of `_buildSimulationBank` skips target-space support bounds for `LVSource` columns (no per-column prior distribution exists); Phase 3 CDF inversion handles exclusion. `validateInverseMaps(lv; n_samples, rtol)` is exported and callable by users to verify their inverse maps independently. This also opens a path to removing `CalibrationParameter` entirely: once display names also live on `LatentVariation`, `CalibrationParameter` adds no new functionality and can be eliminated.

  *Implementation phases:*
  1. **Phase 1** — central DB query filtering by simulator version ID, all location folder IDs, and reference variation IDs for non-calibrated locations.
  2. **Phase 2** — per-location variation filtering: for each calibrated location, batch-query all candidate variation rows (including `vid=0` and the reference vid), check non-calibrated column equality, check calibrated column support bounds, and collect `col → Float64` target maps for each passing variation ID.
  3. **Phase 3** — for each row in the Phase 1 result, merge target maps across all calibrated locations; invoke `_bankCdfCoords` per `CalibrationParameter` to invert to CDF coordinates.
  4. **Phase 4** — retain only monads where all CDF coordinates are strictly in `(0, 1)`.

- **CDF-grid snapping with simulation bank lookup** (`task #17`, implemented): All computation happens in CDF (latent coordinate) space. Every generation follows the same procedure; only the proposal source differs (prior for t=1, kernel perturbation of previous particles for t>1).

  *Grid definition.* G(k) = {j/2^k : j=1,…,2^k−1} in each dimension (2^k−1 interior points per dimension, not including 0 or 1). The snap of a scalar x to G(k) is `clamp(round(Int, x·2^k), 1, 2^k−1) / 2^k` (boundary clamping ensures the result is always interior). The effective resolution at generation t with base k is `k_eff = k + t − 1` (grid doubles each generation). The L^∞ box radius at generation t is `1/2^(k_eff+1)` — exactly half the grid spacing at k_eff, ensuring the box catchment of one grid cell.

  *Per-generation procedure:*

  1. **Draw θ_prop.** For t=1: sample from the prior (uniform CDF draw). For t>1: resample a parent from the previous generation and perturb with the Gaussian kernel (systematic resampling).
  2. **Bank lookup (lookup-first).** Query the pre-built `SimulationBank` for monad entries whose CDF coordinates lie within the L^∞ box of radius `1/2^(k_eff+1)` around the **original** θ_prop (without snapping first). Filter candidates not already evaluated this generation. If usable candidates remain, pick one at random and use its actual CDF coordinates as the effective proposal — `evaluate_batch` reuses the existing monad via `use_previous=true` without re-simulation.
  3. **Fallback snap.** Only if the bank lookup yields no usable candidate: snap θ_prop to the nearest interior grid point g* at resolution k_eff. If that grid point was already evaluated this generation, discard the proposal. Otherwise use g* as the effective proposal (a new simulation is launched at the grid point).
  4. **Evaluate, accept/reject.** Standard epsilon threshold for t>1; all proposals accepted for t=1. After evaluation, every monad's ID is added to the generation's evaluated-monad set regardless of acceptance — the same monad is never run twice in a generation.

  *Weight approximation.* Importance weights use the standard ABC-SMC formula (prior density / Σ prev_weights · kernel) with the effective proposal coordinates. Since ABC-SMC operates in CDF space, the prior density is always 1.0 (`Uniform(0,1)` for every dimension). The bank-hit path does not match the true proposal distribution; this correction is omitted as an acknowledged approximation.

  *Snap helpers (`abc_smc.jl`):* `_effectiveK`, `_snapToCDFGrid`, `_bankBoxRadius`, `_cdfToGridKey`, `_bankBoxCandidates`, `_lookupAndSnap`, `_updateBudget!` (increments `budget[]` and sets `budget_hit[]`).

  *k_base correction.* At the start of `_runABCSMC`, before any generation runs, compute `k_min = ceil(Int, log2(N^(1/d) + 1))` (the minimum k for which `(2^k − 1)^d ≥ N`). Example: N=10, d=2 → `k_min = ceil(log2(sqrt(10)+1)) = ceil(2.056) = 3` since `(2^3−1)^2 = 49 ≥ 10` but `(2^2−1)^2 = 9 < 10`. Set `k_base_eff = max(cdf_grid_k, k_min)`. Thread `k_base_eff` down to both generation runners; every generation uses `k_eff = k_base_eff + t − 1`. If correction was applied, emit `@info`. This is computed once, requires no struct mutation, and ensures all generations start with a grid large enough to hold `population_size` particles.

  *Interface.* `cdf_grid_k::Union{Nothing,Int}` field on `ABCSMC` (default `nothing` → feature disabled, existing algorithm runs unchanged). Validated ≥ 1 when set. Persisted to `method.toml` and restored on resume.

- **Additional distance functions**: `maeDistance`, normalized variants. Minor additions; users can supply their own in the meantime.

**Ruled out:**
- **MCMC rejuvenation steps** (Del Moral et al. 2012): Addressed by existing infrastructure. Systematic resampling reduces weight collapse variance; CDF-grid snapping with mid-generation monad tracking prevents re-running identical parameter points within a generation; grid refinement (`k_eff` increasing each generation) expands the proposal space as the posterior narrows. Together these prevent the particle degeneracy that MCMC rejuvenation is designed to fix in standard ABC-SMC. Not planned.
- **Warm-start / custom initial population**: Subsumed by the `SimulationBank`, which automatically captures all eligible monads from any prior simulation campaign in the DB. An explicit seeding mechanism adds no value on top of the bank's always-on reuse. Not planned.

**Acceptance criteria:**
- `runABC(problem; population_size=50, max_nr_populations=3)` completes on a toy model with a known posterior.
- `resumeABC(Calibration(id))` correctly loads `problem.jld2` and saved generations, and continues from the next one without re-supplying the `CalibrationProblem`.
- `resumeABC` validates structural match for all source types (`DVSource`, `CVSource`, `LVSource`) and errors informatively on mismatch.
- `mseDistance` returns 0.0 when simulated equals observed (all three calling conventions).
- `mseDistance([1.0, 2.0], [3.0, 4.0]) ≈ 8.0` and `mseDistance(3.0, 1.0) == 4.0`.
- `mseDistance([1.0], [1.0, 2.0])` throws `DimensionMismatch`.
- `ABCSMC` throws on invalid settings (`population_size < 1`, `epsilon_quantile` outside (0,1]).
- The `calibrations` table exists after `createSchema()` with columns `calibration_id`, `datetime`, `description`, `method`.
- `plot(result)` (corner pairs plot), `plot(result, :ridgeline)`, `plot(ConvergenceSummary(result))`, and `plot(result, :transition)` all produce plots without error on a completed `ABCResult` with ≥ 2 generations.
- `_validateInverseMaps(lv)` passes for auto-constructed DV/CVSource inverse maps; user-supplied LVSource inverse maps are checked at construction time.
- `generation_cdfs/` is always a subdirectory of `generations/`; `_loadGenerations` finds files regardless of zero-padding used during the original run.
