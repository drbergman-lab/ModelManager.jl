# progress.md — ModelManager.jl Session Journal

> **Purpose:** Session-level decisions, rejected approaches, and open questions.
> Unlike [PRD.md](PRD.md) (specification) and [README.md](README.md) (completion status), this file captures the *reasoning* behind decisions — things that would otherwise exist only in ended chat history.

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

### Files touched (PCMM)
- `src/calibration/*.jl` — stubbed (6 files)
- `src/analysis/standard_qois.jl` — new (PhysiCell summary stats)
- `src/analysis/calibration_summaries.jl` — stubbed (renamed to `standard_qois.jl`)
- `src/analysis/analysis.jl` — added `include("standard_qois.jl")`
- `src/PhysiCellModelManager.jl` — removed calibration include and `calibrations` table creation
- `src/database.jl` — removed `calibrationsSchema()`
- `src/up.jl` — updated migration to call `ModelManager.calibrationsSchema()`
- `test/test-scripts/CalibrationTests.jl` — updated namespace qualifications
