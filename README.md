<p align="center"><img src="docs/src/assets/logo-hero.svg" width="250" alt="ModelManager.jl"></p>

# ModelManager.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://drbergman-lab.github.io/ModelManager.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://drbergman-lab.github.io/ModelManager.jl/dev/)
[![Build Status](https://github.com/drbergman-lab/ModelManager.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/drbergman-lab/ModelManager.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/drbergman-lab/ModelManager.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/drbergman-lab/ModelManager.jl)

Simulator-agnostic infrastructure for agent-based model (ABM) management in Julia.

ModelManager provides the generic base layer for managing simulation runs, parameter variations, sensitivity analysis, and database bookkeeping. Simulator-specific packages (e.g. [PhysiCellModelManager.jl](https://github.com/drbergman-lab/PhysiCellModelManager.jl)) extend this package by implementing the `AbstractSimulator` interface.

## Quick start

ModelManager is not used directly by end users — use a concrete simulator package instead. If you are building a new simulator package on top of ModelManager:

1. Add the BergmanLabRegistry:
```julia-repl
pkg> registry add https://github.com/drbergman-lab/BergmanLabRegistry
```
2. Add ModelManager as a dependency:
```julia-repl
pkg> add ModelManager
```
3. Define your simulator:
```julia
using ModelManager

mutable struct MySimulator <: AbstractSimulator
    dir::String
    # ...simulator-specific fields
end
```
4. Implement the required interface methods (see `AbstractSimulator` docstring).
5. Set the global state in your package's `__init__`:
```julia
function __init__()
    ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator=MySimulator(...))
end
```

---

## Implementation Status

> For Claude Code sessions: this section is the authoritative record of what has been built. Update it as features are completed. See [PRD.md](PRD.md) for behavioral specifications and [progress.md](progress.md) for decision rationale.

### Completed

- [x] `AbstractSimulator` interface — extension point for simulator backends
- [x] `ModelManagerGlobals` — generic global state; simulator-specific fields live on the concrete simulator
- [x] Project configuration — `inputs.toml` parsing, `ProjectLocations`, location path utilities
- [x] Trial hierarchy — `Simulation`, `Monad`, `Sampling`, `Trial`, `InputFolders`, `VariationID`
- [x] Database schema — generic SQLite schema parameterized by simulator version table/column names
- [x] Database utilities — `queryToDataFrame`, `constructSelectQuery`, `buildWhereClause`, etc.
- [x] Schema migrations — `up.jl` framework with `upgradePackage`, `upgradeToMilestone`; migrations target the version loaded in the session, read from the package defining the simulator type
- [x] Runner — parallel simulation execution via Julia tasks/channels; `prepareTrialHierarchy` + `pendingSimulationSpecs` split; a default `runSimulation` built on the `simulationCommand` interface method
- [x] Deletion — `deleteSimulations`, `deleteMonad`, `deleteSampling`, `deleteTrial`, `deleteCalibration`, `resetDatabase`
- [x] Parameter variations — `XMLPath`, `DiscreteVariation`, `DistributedVariation`, `CoVariation`, `LatentVariation`; a discrete parameter is a `DiscreteUniform` over its value indices, so grid and CDF sampling agree
- [x] Space-filling designs — `GridVariation`, `LHSVariation`, `SobolVariation`, `RBDVariation`
- [x] Sensitivity analysis — MOAT, Sobol', RBD-FAST; `gsa.results` is keyed by label (`gsaLabels` lists them); a keyed `reduce` yields one analysis per key, labelled as described under QoI; `calculateGSA!` skips measurements already evaluated unless `recompute=true`
- [x] Sensitivity visualization — `RecipesBase.jl` recipes for `MOATSampling` (`:bar` with optional σ whiskers, `:violin`, `:scatter`), `SobolSampling` (S1/ST grouped bars, `show_ST`), and `RBDSampling` (first-order bars); one series per quantity
- [x] `createTrial` / `run` user API — convenience wrappers over the trial hierarchy; `run(Ts::AbstractVector)` / `createTrial(::AbstractVector)` bundle pre-built trials into one `Trial` for a single batched run
- [x] Analysis tables — `simulationsTable` / `printSimulationsTable` and `monadsTable` / `printMonadsTable` with shared `remove_constants` / `sort_by` / `sort_ignore` / `short_names` kwargs; `simulationsTable(...; post_processing=true)` joins stored quantities
- [x] `postSimulationProcessing` / `postSimulationCleanup` interface hooks — non-destructive processing before the user hook, destructive cleanup after it
- [x] User post-processing hook — `run(T; post_processor=f)` calls `f(simulation)` after each successful simulation; a scalar or keyed return is upserted into `data/outputs/postprocessing.db` (dynamic columns, one row per `simulation_id`, labelled as described under QoI); read back via `postProcessingTable` / `printPostProcessingTable`
- [x] `initializeInputFolder` / `getInputFolderDescription` / `clearSimulatorArtifacts` interface hooks
- [x] `initializeModelManager` generic entry point — `initializeModelManager(::AbstractSimulator, data_dir)` with `centralDBFileName` and `postInitDisplay` extension points
- [x] HPC utilities — `isRunningOnHPC` (probed by `initializeModelManager`), `useHPC`, `setJobOptions`, `defaultJobOptions`
- [x] HPC job completion — each worker waits for its own job's exit-code sentinel on the shared filesystem; `squeue` is a reaper only, one answer shared by all workers (`setHPCCompletionOptions`)
- [x] HPC submission robustness — a refused `sbatch` submission is retried while the message looks transient and otherwise stops the run, leaving the simulation at `Not Started`; `run` closes its queue on any exit so nothing is left at `Queued`
- [x] HPC-safe removal — `rm_hpc_safe` tries `rm` first and stages only what a shared filesystem refuses to release into `data/.trash/`, returning `:removed`/`:staged`/`:unremoved`; `initializeModelManager` retries staged paths in the background and `databaseDiagnostics` reports what remains
- [x] PCMM migration — PCMM uses `ModelManagerGlobals` and implements all `AbstractSimulator` methods
- [x] Calibration infrastructure — `CalibrationProblem`, `ABCSMC`, `runCalibration` / `resumeCalibration` and the `runABC` / `resumeABC` shorthand, `run(::ABCSMC, problem)` / `run(::Calibration)`, `mseDistance`, generation persistence, `calibrations` DB table
- [x] ABC-SMC algorithm — parallel batch evaluation, systematic resampling, ESS, acceptance-rate tracking, `ConvergenceSummary`, manual epsilon schedule, stopping criteria (`min_acceptance_rate`, `min_epsilon_decrease`, `min_ess_fraction`, `max_evaluations` enforced before dispatch), `accept_overflow`, `store_rejected`, `CalibrationParameter` display layer, JLD2 problem persistence
- [x] Symmetric calibration entry points — a keyword on resume patches the saved method, a method object replaces it, and the effective settings are written back to `method.toml`
- [x] Calibration over discrete and mixed parameter spaces — `DiscreteVariation` / `CoVariation{<:DiscreteVariation}` accepted alongside continuous parameters; posterior CSVs and recipes report the level
- [x] Simulation bank — `SimulationBank` registry of existing monads in CDF space with KD-tree (Chebyshev) box queries; admission requires at least one `Running`/`Completed` simulation
- [x] CDF-grid snapping — `cdf_grid_k` on `ABCSMC`; lookup-first bank reuse with fallback snap to a dyadic grid refined each generation; per-generation monad-ID dedup; automatic `k_base_eff` correction
- [x] Kernel type hierarchy — `AbstractKernel` / `AbstractFittedKernel`; `GaussianKernel`, `ComponentwiseKernel`, `LocalNNKernel`, `LocalNNCovKernel`; TOML serialization under `[perturbation_kernel]`
- [x] Calibration progress reporting — `progress` keyword (`:auto`, `:none`, `:generation`, `:batch`, `:bar`) driven by a generic `on_progress` hook on `run`
- [x] Posterior visualization — `RecipesBase.jl` recipes for `ABCResult`/`Calibration`: corner plot (default), `:ridgeline`, `:transition`, `:distances`, and `plot(ConvergenceSummary(result))`
- [x] Simulation-failure handling in calibration — failed simulations and monads recorded per generation with one warning per generation; a monad with no successful simulation gets a `missing` distance and is rejected or stops the run via `on_monad_failure` (`:reject`, `:error`); `summary_statistic`/`distance` errors on a healthy monad are fatal
- [x] Per-generation output folders — `generations/{t}/` holds `particles.csv`, `cdfs.csv`, `metadata.toml`, `monads.csv`, `proposals.csv` and two conditional failure records; artifacts are addressed by role, so legacy flat-layout runs are read, plotted and resumed, and migrated into folders on resume
- [x] `LatentVariation` enhancements — `target_names` for LVSource display; `inverse_maps` auto-constructed for DV/CVSource and user-supplied for LVSource, round-trip validated at construction; padding-agnostic generation loading; `short_names=false` on `simulationsTable`
- [x] Trial tagging and feature-based recovery — polymorphic `tags` table; `tag!` / `untag!` / `tags` / `hasTag` on objects, type+IDs, vectors, or an `MMOutput`; `tags=` keyword on `createTrial`/`run`; automatic `mm:` provenance (created, session, script, git state, method, calibration/generation) stored as columns plus a `provenances` table; `findSimulationIDs` / `findSimulations` / `findMonads` / `findTrials` with AND/OR composition, `status` filtering and query-time downward inheritance; `simulationsTable(...; tags=true)`; `tagsTable` / `tagKeys` / `tagValues` / `recommendedTagKeys`; tag rows removed at every deletion choke point, `orphanedTagCounts` in `databaseDiagnostics`
- [x] Symmetric trial-ID accessors — `simulationIDs` / `monadIDs` / `constituentIDs` / `trialID` / `trialType` / `length` / `trialFolder` accept every level of the hierarchy and the `MMOutput` that `run` returns; `monadIDs(simulation)` and `trialID(::Vector{Sampling})` are pure lookups that never create rows
- [x] Calibration runs as coalesced `Sampling` views, and a taggable `Calibration` — `Sampling(calibration[, generation])`, read-only `monadIDs`/`simulationIDs` accessors, `Calibration` as a fifth `TAG_CLASSES` member, `calibrationsTable` / `printCalibrationsTable`, `show(::Calibration)`, `deleteCalibration`
- [x] Portable docstring cross-references — docstrings `@ref` only public bindings (exported or `@compat public`); the `AbstractSimulator` interface methods, `SimulationSpec`/`SimulationProcess`, `GSASampling`, and `simulationsTableFromQuery`/`monadsTableFromQuery` are public; enforced by a testset that needs no docs build
- [x] `StudySpec` — the model-and-parameters half of a study, consumed by `run(::GSAMethod, spec)` or `CalibrationProblem(spec, observed, summary, distance)`; keeps the user's own variations and reports per-parameter usability through `show`
- [x] `QoI` seam — `QoI(name, compute; reduce=mean)` is passed directly to `run(::GSAMethod, ...; functions=)`, `CalibrationProblem`'s `summary_statistic`, and `run(...; post_processor=)`; `compute` runs per simulation, `reduce` combines replicates, and a plain `Function` is wrapped at the boundary. A keyed `Dict`/`NamedTuple` is spread by both the sink and sensitivity analysis into `"<qoi name>.<key>"`; a bare anonymous callback that stores anything is refused
- [x] Stored QoI values — `stored=:prefer`/`:require` reads a value the post-processing sink wrote earlier (default `:never`); a keyed QoI is reassembled from its `<name>.<key>` columns; `verifyStoredValues` recomputes where the output survives and reports mismatches and unverifiable cases
- [x] Restorability — a closure is stripped from `problem.jld2` and given an `anon_…` QoI name; a top-level function or callable struct is kept; an unreadable `problem.jld2` does not block `resumeCalibration(...; problem=)`
- [x] One simulator-option channel — `run_kwargs::NamedTuple` is accepted alongside loose keywords on `run(::AbstractTrial)`, `run(::AbstractVector)` and `run(::AddVariationMethod, ...)`, merged loose-wins

### Remaining

- [ ] `createProject` generic entry point
- [ ] GP-accelerated ABC — `GPAcceleratedABC <: AbstractCalibrationMethod` using a surrogate to reduce simulator evaluations; `AbstractCalibrationMethod` hierarchy is already in place.
