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
5. Register your simulator in your package's `__init__`:
```julia
function __init__()
    ModelManager.registerSimulator!(MySimulator(...))
end
```

---

## Implementation Status

> For Claude Code sessions: this section is the authoritative record of what has been built. Update it as features are completed. See [PRD.md](PRD.md) for behavioral specifications and [progress.md](progress.md) for decision rationale.

### Completed

*Core*

- [x] `AbstractSimulator` interface — the extension point for simulator backends. A required method has no default and errors naming the concrete type; an optional one has a default, so a backend implements only what it needs
- [x] `ModelManagerGlobals` and `registerSimulator!(sim)` — the one line a backend writes in its `__init__`. It creates the globals, returns the existing ones untouched when the same backend type re-registers (so a package reload does not discard an open project), and warns naming both types when it replaces a different backend's; `mm_globals_ref` is internal, neither exported nor public
- [x] `initializeModelManager(::AbstractSimulator, data_dir)` — the generic entry point, with `centralDBFileName` and `postInitDisplay` as extension points
- [x] Project configuration — `inputs.toml` parsing, `ProjectLocations`, location path utilities
- [x] Trial hierarchy — `Simulation`, `Monad`, `Sampling`, `Trial`, `InputFolders`, `VariationID`
- [x] Symmetric trial-ID accessors — `simulationIDs` / `monadIDs` / `constituentIDs` / `trialID` / `trialType` / `length` / `trialFolder` accept every level of the hierarchy plus the `MMOutput` that `run` returns (`constituentIDs` excepted for a `Simulation`, which has no constituents), and `monadIDs` also accepts a `Simulation` and a `GSASampling`. Accessors never write: `monadIDs(simulation)` resolves the monad for that simulation's *parameterization* by a pure `SELECT` against the `UNIQUE` key tuple `monads` shares with `simulations` — built by the shared `_monadKeyStrings`, and reading the version from the simulation's own row so a mid-project simulator upgrade orphans nothing — and `trialID(::Vector{Sampling})` returns `missing` on no match, find-or-create living in the `Trial(Ss)` constructor
- [x] Database schema and utilities — a generic SQLite schema parameterized by simulator version table/column names; `queryToDataFrame`, `constructSelectQuery`, `buildWhereClause`; every open (central, post-processing sink, per-folder variations) carries a busy timeout, through the single `_openDB`
- [x] Schema migrations — the `up.jl` framework with `upgradePackage` and `upgradeToMilestone`. Migrations target the version *loaded* in the session, read from the package defining the simulator type, so updating the environment mid-session defers the schema change to the next session rather than recording a version whose migration never ran
- [x] Runner — parallel simulation execution over Julia tasks and channels, with setup and collection as separate passes (`prepareTrialHierarchy` then `pendingSimulationSpecs`)
- [x] Deletion — `deleteSimulations`, `deleteMonad`, `deleteSampling`, `deleteTrial`, `deleteCalibration`, `resetDatabase`, each also clearing the deleted objects' tag rows
- [x] Parameter variations — `XMLPath`, `DiscreteVariation`, `DistributedVariation`, `CoVariation`, `LatentVariation`; every elementary constructor takes its location explicitly, ModelManager having no way to infer one from a target
- [x] Space-filling designs — `GridVariation`, `LHSVariation`, `SobolVariation`, `RBDVariation`
- [x] `createTrial` / `run` user API — convenience wrappers over the trial hierarchy; `run(Ts::AbstractVector)` / `createTrial(::AbstractVector)` bundle pre-built trials into one `Trial` for a single batched run; `run_kwargs::NamedTuple` is accepted alongside the loose keyword splat and merged loose-wins, so a bundle of simulator options assembled once is portable to any entry point
- [x] Analysis tables — `simulationsTable` / `printSimulationsTable` (one row per simulation) and `monadsTable` / `printMonadsTable` (one row per monad); shared `remove_constants` / `sort_by` / `sort_ignore` / `short_names` keywords
- [x] PCMM migration — PhysiCellModelManager wired to use `ModelManagerGlobals` and implement the `AbstractSimulator` interface

*HPC*

- [x] HPC utilities — `isRunningOnHPC` (probed by `initializeModelManager`, so HPC mode turns itself on where SLURM exists), `useHPC` (which pins the flag for the session, so a re-initialization — including one a simulator package does in its own `__init__` — cannot silently undo it), `setJobOptions`, `defaultJobOptions`
- [x] HPC job completion — each worker waits for its own job's exit-code sentinel on the shared filesystem; `squeue` is a reaper only, through one answer shared by all workers (tuned with `setHPCCompletionOptions`). `runSimulation` has a default built on the `simulationCommand` interface method
- [x] HPC submission robustness — a submission `sbatch` refuses is retried while the message looks transient (submit limits, controller timeouts) and otherwise stops the run, leaving the simulation at `Not Started` rather than recording a failure that would erase it from its monad; `run` closes its queue on any exit, so an interrupted or failed run leaves nothing at `Queued`; `defaultJobOptions` requests a job name and, through the backend's `simulationThreads`, the CPUs a simulation will use; a `Function`-valued job option receives the `Simulation`
- [x] Surviving a dead driver — `databaseDiagnostics` reconciles what a driver that died left behind. The exit-code sentinel its job wrote (the latest submission, ordered by the stamp in the file's name rather than by `mtime`), or one `sacct` call carrying every outstanding job ID from the simulations' `hpc.out` files, decides `Completed`/`Failed`; a `Queued` simulation, and on a cluster a `Running` one that never reached the scheduler, returns to `Not Started`. An initialization that detects SLURM also writes a `driver_template.sbatch` into the project (`scripts/` if there is one) — once, never overwritten — for a user to edit and submit as `sbatch driver_template.sbatch my_script.jl`. Sentinels live at `data/outputs/.hpc_done`, or wherever `MODELMANAGER_HPC_DONE_DIR` says, which is created and write-tested at init, because a directory the compute nodes cannot write makes every successful job look scheduler-killed
- [x] HPC-safe removal — `rm_hpc_safe` tries the real `rm` first and stages only what a shared filesystem refuses to release into `data/.trash/`, returning `:removed` / `:staged` / `:unremoved` and warning once per project rather than throwing mid-deletion; `initializeModelManager` retries staged paths in the background and `databaseDiagnostics` reports whatever remains

*Measurement, post-processing and sensitivity*

- [x] `postSimulationProcessing` / `postSimulationCleanup` / `initializeInputFolder` / `getInputFolderDescription` / `clearSimulatorArtifacts` interface stubs — a backend overrides these for non-destructive processing (before the user hook), destructive cleanup (after it), and per-folder setup
- [x] User post-processing hook — `run(T; post_processor=f)` runs `f` after each successful simulation, in the order `postSimulationProcessing` → `post_processor` → `postSimulationCleanup`, so the callback sees the intact output folder. A returned `Real`, or a flat `NamedTuple`/`Dict` of them, upserts one row per `simulation_id` into the `data/outputs/postprocessing.db` sink (columns added on demand); read it back with `postProcessingTable` / `printPostProcessingTable`, or join it onto the simulations table with `simulationsTable(...; post_processing=true)`. The callback receives a `Simulation`, so simulator-specific output loading stays downstream
- [x] `QoI` seam — `QoI(name, compute; reduce, stored, skip_missing, data)` writes a measurement once and is passed directly to `run(::GSAMethod, ...; functions=)`, to `CalibrationProblem`'s `summary_statistic`, and to `run(...; post_processor=)`. There is no level to declare: per-simulation `compute` plus `reduce` is strictly more expressive than a monad-level compute. A plain `Function` is wrapped at the boundary, gaining a name and the default keyed-aware mean reducer; `data=` carries whatever the measurement needs besides the simulation and switches `compute`/`reduce` to their two-argument form, so both stay named functions and a calibration resumes with the data intact
- [x] Value constraints belong to the consumer that needs them — the seam interprets nothing: `compute` returns a value or `missing`, `reduce` returns a value or `missing`, `nothing` is refused. The **sink** requires a `Real` or a flat `Dict`/`NamedTuple` of them (each becomes a column; no `Vector`, no nested value, no `String` — text about a simulation is a tag), **sensitivity analysis** requires the same of `reduce`'s value (each key becomes an analysis needing one number per monad), and **calibration** requires nothing, `distance` receiving whatever `reduce` returned. `reduce` need not keep the shape it was given, and only the default reducer needs the replicates to agree about their keys
- [x] One naming rule for a keyed measurement — every component is `(qoi name, key)`, spelled `"<qoi name>.<key>"` as a sink column and as a sensitivity label, and reaching `distance` inside a `SummaryValues` keyed by the pair, which resolves `"name"`, `"name.key"`, or a bare `"key"` when only one QoI reports it. A QoI name may not contain a `.`; QoI names need not be unique, but the `(name, key)` pair must be. A bare anonymous function that stores anything is refused, its gensym-derived name varying between sessions
- [x] Stored QoI values — `stored=:prefer` / `:require` lets a `QoI` read a value the sink wrote earlier (a keyed one reassembled from its `"<name>.<key>"` columns), for when post-simulation cleanup has removed what it was computed from. The default is `:never`, no fingerprint of the producing `compute` being possible; `verifyStoredValues` recomputes where the output survives and reports mismatches and unverifiable cases rather than assuming
- [x] Restorability is decided by what JLD2 can name — a closure (a lambda, or a named function defined inside another function) is stripped from `problem.jld2` and given an `anon_…` QoI name that neither the sink nor sensitivity analysis's skip trusts, while a top-level function or callable struct is kept. An unreadable `problem.jld2` names the way out and does not block `resumeCalibration(...; problem=)`
- [x] Sensitivity analysis — MOAT, Sobol', RBD-FAST, generic and free of simulator-specific logic. A `QoI` whose value is a `Dict`/`NamedTuple` yields one analysis per key; `gsa.results` is keyed by those labels and `gsaLabels` lists them. A monad whose value is `missing` is refused, a sensitivity index having no cell for it
- [x] Sensitivity visualization — `RecipesBase.jl` recipes for `MOATSampling` (`:bar` with optional σ whiskers, `:violin`, `:scatter` µ*–σ screening), `SobolSampling` (S1/ST grouped bars, `show_ST` toggle) and `RBDSampling` (first-order bars); one series per sensitivity quantity; `parameters` keyword on every recipe to draw a subset in a chosen order (any DataFrames column selector, shared with the calibration recipes)
- [x] `StudySpec` — the model-and-parameters half of a study, built once and consumed by either `run(::GSAMethod, spec)` or `CalibrationProblem(spec, observed, summary, distance)`. It keeps the user's own variations rather than normalising them, takes its reference variation from a monad without override, and reports per-parameter sensitivity/calibration usability through `show`

*Calibration*

- [x] Calibration infrastructure — `CalibrationProblem`, `ABCSMC`, `mseDistance`, the ABC-SMC core algorithm, generation persistence, and the `calibrations` table
- [x] Symmetric entry points — `runCalibration`/`resumeCalibration` are the method-agnostic pair, `runABC`/`resumeABC` the ABC-specific shorthand; neither is deprecated. On resume, an `ABCSMC` field given as a keyword patches the saved method while a method object replaces it wholesale, and the effective settings are written back to `method.toml` with the changed keys reported. The shared bank/evaluator/SMC tail is one `_executeCalibration` used by both
- [x] ABC-SMC algorithm — parallel batch evaluation, systematic resampling, ESS and acceptance-rate tracking, `ConvergenceSummary`, manual epsilon schedule, the `min_acceptance_rate` / `min_epsilon_decrease` / `min_ess_fraction` stopping criteria, `accept_overflow`, `max_evaluations` as a run-wide budget (recomputed on resume from what is on disk), and JLD2 problem persistence so `resumeABC(Calibration(id))` needs no re-supplied problem
- [x] Kernel type hierarchy — `AbstractKernel` / `AbstractFittedKernel`; `GaussianKernel`, `ComponentwiseKernel`, `LocalNNKernel`, `LocalNNCovKernel`; dispatch-based `_fitKernel`, `_proposeParticle`, `_kernelDensity`; TOML serialization under a `[perturbation_kernel]` subtable; generation-indexed scale via `_effectiveKernelScale`
- [x] Discrete and mixed parameter spaces — a `DiscreteVariation` or `CoVariation{<:DiscreteVariation}` may be passed to `CalibrationProblem` alongside continuous parameters. It is represented internally as a `DiscreteUniform` over value indices, so a particle coordinate stays a CDF value in [0, 1] and the quantile does the quantising, and the four kernels need no discrete counterpart. Posterior CSVs and the recipes report the level rather than the index; a single-level parameter is rejected; a `LatentVariation` built from a raw value vector is rejected, with the error naming the conversion to use
- [x] Simulation bank — `SimulationBank` / `_buildSimulationBank`, a pre-built CDF-space registry of existing monads for reuse, with a KD-tree (Chebyshev metric, `NearestNeighbors.jl`) for O(log n + k) L∞ box queries. Admission requires at least one `Running`/`Completed` simulation, keeping deleted and never-started monads out
- [x] CDF-grid snapping — `cdf_grid_k` on `ABCSMC`: lookup-first bank reuse, then a fallback snap of the *continuous* coordinates to a dyadic grid (a discrete coordinate is left unsnapped, the grid not dividing evenly into its levels), generational refinement `k_eff = k_base + t − 1`, per-generation monad-ID dedup so each monad runs at most once per generation, and automatic `k_base_eff` correction when `cdf_grid_k` is too coarse for `population_size` × parameter dimension
- [x] Per-generation output folders — a calibration writes `generations/{t}/{particles,cdfs,metadata,monads,proposals}` plus two conditional failure records. Artifacts are addressed by role rather than by filename, so a run written under the historical flat layout is read, plotted and resumed without conversion, and is moved into folders the first time it is resumed. A folder holding only `monads.csv` is a generation in flight, not a completed one, and every reader that presents a run to a user says so
- [x] Simulation-failure handling — failed simulation IDs and the monads they belong to are recorded per generation (`{t}/failed_simulations.csv`, `{t}/failed_monads.csv`) with one warning per generation. A monad left with no successful simulation is detected before user code runs and its distance recorded as `missing`, never a sentinel value, either rejecting the particle or failing the run via `on_monad_failure` (`:reject` default, `:error`); a monad whose summary statistic is `missing` follows the same policy rather than being reported as a bug in the user's functions. Partially failed monads are evaluated from what succeeded. A `summary_statistic`/`distance` failure on a healthy monad — including a non-`Real` distance — is always fatal, with the monad named
- [x] Calibration progress reporting — a `progress` keyword (`:auto`, `:none`, `:generation`, `:batch`, `:bar`) on the four entry points, with generation- and batch-start milestones and a live per-simulation `ProgressMeter.jl` bar, driven by a generic `on_progress` hook on `run`; `:auto` resolves to `:bar` on a TTY and `:generation` otherwise
- [x] Posterior visualization — `RecipesBase.jl` recipes for `ABCResult`/`Calibration`: the corner pairs plot (the no-style default), the ridgeline posterior-narrowing plot (`:ridgeline`), the generation transition plot (`:transition`), the proposal-distance histogram with the accepted tail highlighted (`:distances`), and convergence diagnostics via `plot(ConvergenceSummary(result))`; `parameters` keyword on the corner, `:ridgeline` and `:transition` recipes to draw a subset of parameters in a chosen order
- [x] Posterior sampling — `samplePosterior` draws parameter sets from a generation's posterior: weighted resampling of the accepted particles by default (each draw carries its `monad_id`, so predictive checks reuse existing outputs), or an opt-in Gaussian KDE in CDF space with a Scott's-rule/ESS bandwidth and boundary reflection, mapped through the prior quantiles so draws stay in support and discrete parameters land on a level; works from an `ABCResult` or from disk via `Calibration`; `createTrial(result_or_calibration, draws)` turns any draw frame into a runnable `Sampling`, one monad per distinct parameter set against the run's reference variation, so plain draws resolve to their existing monads and smoothed draws get new ones
- [x] `LatentVariation` enhancements — a `target_names` field for LVSource display column naming; `inverse_maps` auto-constructed for DV/CVSource and user-supplied for LVSource with a `_validateInverseMaps` round-trip check at construction; `_validateStructuralMatch` covering every source type; scan-based, padding-agnostic `_loadGenerations`
- [x] Calibration runs as coalesced `Sampling` views, and a taggable `Calibration` — `Sampling(calibration)` and `Sampling(calibration, generation)` coalesce the monads a run evaluated into addressable samplings, with `monadIDs`/`simulationIDs` accessors that read without recording anything, since sampling identity is the exact monad set and materializing a view mid-run would pin a partial one. `Calibration` is deliberately not part of the containment hierarchy and not an `AbstractTrial`: containment runs batch → generation → calibration and those groupings overlap, which a strict chain cannot express. It is a fifth `TAG_CLASSES` member, which is why `include("tags.jl")` is last in `src/ModelManager.jl`. Calibration-class tags do not inherit downward; the `mm:calibration` batch tags are the route to a run's monads, while a tag on the run itself is the durable one, the `calibrations` row outliving any monad cascade. `calibrationsTable` / `printCalibrationsTable` and `show(::Calibration)` are the read path; `deleteCalibration` defaults to `delete_subs=false`, and with `delete_subs=true` deletes only the monads no other sampling or calibration uses

*Documentation and downstream surface*

- [x] Portable docstring cross-references — docstrings `@ref` only *public* bindings (exported, or declared `@compat public`), so they resolve in downstream docs builds that render only ModelManager's public API. The `AbstractSimulator` interface methods, `SimulationSpec`/`SimulationProcess`, `GSASampling`, and `simulationsTableFromQuery`/`monadsTableFromQuery` are declared public; references to true internals are plain code spans. Enforced by the `"docstrings only @ref public bindings"` testset, which runs with the ordinary suite and needs no docs build. See the "Docstring Cross-References" section of [CLAUDE.md](CLAUDE.md)
- [x] Downstream-developer surface — `variationFilePath(location, M)` publishes the path `createXMLFile` writes, and `quietRun` is public rather than copied. `dbVersionTableName` defaults to the lowercased name of the package defining the simulator type plus `_version`, `upgradeMilestones` to empty, and `upgradeToMilestone` to a throw naming the missing milestone implementation, so a backend whose schema has never changed implements none of the three. Manual pages qualify every public-but-unexported name a reader is meant to call as `ModelManager.name`, a downstream `@reexport` forwarding only exports

### Remaining

- [ ] `createProject` generic entry point
- [ ] GP-accelerated ABC — `GPAcceleratedABC <: AbstractCalibrationMethod` using a surrogate to reduce simulator evaluations; the `AbstractCalibrationMethod` hierarchy is already in place
- [ ] Additional distance functions — `maeDistance` and normalized variants; `mseDistance` is currently the only built-in
