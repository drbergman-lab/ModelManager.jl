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
- Required interface methods have default bodies in `abstract_simulator.jl` that throw an error naming the method a simulator must implement.
- Optional interface methods have working defaults.
- ModelManager dispatches on `mm_globals().simulator` for all simulator-specific calls.

**Required interface methods (error by default):**
- `simulationCommand(sim, spec::SimulationSpec)` → `Union{Nothing,Cmd}` — the command that runs one simulation; `nothing` means none could be built, failing that one simulation
- `simulatorDir(sim)` → `String`
- `simulatorVersionSchema(sim)` → `String` (SQL sub-schema for version table)
- `simulatorVersionIDName(sim)` → `String` (FK column name in simulations/monads/samplings)
- `simulatorVersionTableName(sim)` → `String`
- `resolveSimulatorVersionID(sim)` → `Int`
- `currentSimulatorVersionID(sim)` → `Int`
- `simulatorInfo(sim)` → `String`
- `setupMonad(sim, monad::AbstractMonad; kwargs...)` → `Bool`
- `setupSampling(sim, sampling::AbstractSampling; kwargs...)` → `Bool`
- `dbVersionTableName(sim)` → `String` — the table tracking migration state
- `upgradeMilestones(sim)` → `Vector{VersionNumber}`
- `upgradeToMilestone(sim, version, auto_upgrade)` → `Bool`

`variationLocation` and `addVariationRows` are not interface methods: `variationLocation` dispatches
on variation objects (the caller resolves targets to locations before constructing them), and
`addVariationRows` takes no simulator argument.

**Optional interface methods (working defaults):**
- `runSimulation(sim, spec::SimulationSpec)` → `SimulationProcess` — default built on `simulationCommand`; override only for a simulator that is not an external process
- `postInitDisplay(sim)` — prints the generic project fields after initialization
- `postSimulationProcessing(sim, simulation_process; kwargs...)` — **non-destructive** processing, run *before* the user `post_processor`; must not delete output (default no-op)
- `postSimulationCleanup(sim, simulation_process; kwargs...)` — **destructive** cleanup (pruning/deleting output, removing error files), run *after* the user `post_processor` and regardless of success (default no-op)
- `initializeInputFolder(sim, input_folder)` — per-folder setup on insert (default no-op)
- `getInputFolderDescription(sim, path)` → `String` (default `""`)
- `clearSimulatorArtifacts(sim)` — remove build artifacts on database reset (default no-op)
- `simulationThreads(sim, simulation)` → `Union{Nothing,Int}` — threads the simulation will start, requested as `--cpus-per-task` on SLURM (default `nothing`: no request)
- `postVariationXMLProcessing(sim, location, path)` — after a variation XML file is written (default no-op)
- `centralDBFileName(sim)` → `String` (default `"mm.db"`)

**Visibility:** these methods are deliberately **not exported** — a simulator package implements
`ModelManager.runSimulation`, it never calls an exported one — but they are public API and are
declared `@compat public` so that downstream docs builds can resolve `@ref` links to them. See
the "Docstring Cross-References" section of `CLAUDE.md`.

**Acceptance criteria:**
- A package implementing all required methods compiles and runs simulations end-to-end.
- A package implementing only optional methods falls back gracefully to defaults.
- Every interface method satisfies `Base.ispublic(ModelManager, name)` on Julia ≥ 1.11.

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
- `initializeModelManager` seeds `run_on_hpc` from `isRunningOnHPC()` (a probe for `sbatch` on the `PATH`) on every call, placed after all early-return failure paths and before `postInitDisplay` prints it. `useHPC(use)` overrides it afterwards; a subsequent `initializeModelManager` re-detects unconditionally and discards the override.
- `useHPC(true)` when `run_on_hpc` is already `true` emits a one-time `@warn` that the call is redundant.

**Acceptance criteria:**
- Calling `mm_globals()` before initialization throws a descriptive error.
- After a simulator package sets `mm_globals_ref[]`, all zero-arg accessors return correct values.
- After `initializeModelManager` returns `true`, `mm_globals().run_on_hpc == isRunningOnHPC()`.

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

*Accessors*
- `simulationIDs` and `monadIDs` accept any level of the hierarchy, an array of levels, the `MMOutput` returned by `run`, a `GSASampling`, or no argument (everything in the database). They descend the full hierarchy; `constituentIDs` stops one level down and also accepts an `MMOutput`, but throws for a `Simulation`, which has no constituents.
- `monadIDs(simulation)` resolves the monad for that simulation's parameterization by matching the `monads` key tuple that `monadsSchema` declares `UNIQUE` — simulator version, input folders and variation IDs. It is a pure `SELECT`: an accessor never creates a row.
  - The version component is read from the simulation's own `simulations` row, not from `currentSimulatorVersionID()`. The two differ after a simulator upgrade within a project, and using the ambient value would miss the monad the simulation actually belongs to. The writer (`Monad(inputs, variation_id)`) keeps the ambient value, since re-creating a parameterization under a new simulator version is deliberately a new monad row.
  - Matching on parameterization is not matching on membership. `Simulation(inputs, variation_id)` and `Simulation(monad)` insert into `simulations` alone, so such a simulation resolves to the monad sharing its parameters without appearing in that monad's replicate list; `run` is what adds it. A failed simulation, removed from its monad's list by `simulationFailed`, likewise still resolves to it.
  - `Int[]` means no monad shares the parameterization at all. An empty table beats an error, which is why `monadsTable(simulation)` returns zero rows in that case.
- `trialID(T::AbstractTrial)` and `trialID(output::MMOutput)` read an ID. `trialID(samplings::Vector{Sampling})` looks up the trial containing exactly those samplings and returns `missing` when none does — it does not create one. Creation belongs to `Trial(samplings)`, which routes through the internal find-or-create.
- `trialType` reports the concrete type; on an `MMOutput` it comes from the type parameter and is known at compile time. `length` counts simulations. `trialFolder` gives the output folder. Both also accept an `MMOutput`.
- `MMOutput` is not an `AbstractTrial`: it has no `id` field, and `run(::AbstractTrial)` does not accept an `MMOutput{Sampling}`/`MMOutput{Trial}` (a `MethodError`).

**Acceptance criteria:**
- `Simulation(id)` reconstructs a simulation from the database by ID.
- `Monad(inputs, variation_id; n_replicates, use_previous)` creates or retrieves a monad.
- `Sampling(inputs, location_variation_ids; n_replicates, use_previous)` creates or retrieves a sampling.
- `constituentIDs(T, id)` returns the IDs of the next level down in the hierarchy.
- `monadsTable` and `simulationsTable` work for every `AbstractTrial`, including a bare `Simulation` and mixed vectors such as `[simulation, monad]`.
- Calling `monadIDs` on a monad-less simulation leaves the `monads` row count unchanged; calling `trialID` on an unmatched sampling set leaves the `trials` row count unchanged.
- `trialID(samplings)` returns `missing` before `Trial(samplings)` is called and that trial's ID afterwards; a second `Trial(samplings)` reuses the row.
- `monadIDs(simulation)` still finds the simulation's monad after the project's simulator version changes.

---

## Feature: Parameter Variations

**One-line description:** Define, store, and retrieve parameter variations in per-folder SQLite databases.

**Priority:** Must-have

**Behavioral specification:**
- `XMLPath` holds an XML path as a `Vector{String}`.
- `DiscreteVariation(location, target, values)` holds an explicit location, a target and a vector of values.
- `DistributedVariation(location, target, distribution)` holds a location, a target and a `Distribution`; supports `flip`.
- `CoVariation` groups multiple elementary variations that move together.
- `LatentVariation` maps latent parameters to target parameters via user-supplied functions.
- `ParsedVariations` converts any mix of variation types to `LatentVariation`s for uniform processing.
- `addVariations(method, inputs, avs, reference_variation_id)` writes rows to the variations DB and returns `Vector{VariationID}`.
- `addVariationRows(inputs, reference_variation_id, loc_dicts)` is the internal write operation; it takes no simulator argument.
- A discrete parameter is represented internally as a `DiscreteUniform` over its value indices, so the grid and CDF sampling paths (`LHSVariation`, `SobolVariation`, `RBDVariation`, and every `GSAMethod`) agree, and ABC-SMC can accept it (its kernels work in [0, 1] CDF space; the quantile does the quantising).
- `size(lv)` reports a latent parameter's support cardinality, or `-1` when it cannot be enumerated; `GridVariation` rejects the sentinel. Enumerable means a `DiscreteUnivariateDistribution` with finite bounds — `Uniform(0,1)` is bounded but not enumerable.

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
- `run(Ts::AbstractVector; kwargs...)` bundles a collection of already-built trials (`Simulation`/`Monad`/`Sampling`/`Trial`, possibly in a `Vector{Any}`) into one `Trial` via `createTrial(::AbstractVector)` and runs it as a single parallelized batch. Non-`AbstractTrial` elements and empty vectors raise `ArgumentError`.
- `kwargs` are forwarded to `prepareTrialHierarchy` (simulator hooks like `force_recompile`) and to `postSimulationProcessing`/`postSimulationCleanup`. The `post_processor` hook (see the Post-Processing feature) runs per successful simulation between them. `runSimulation` takes no kwargs — it receives only the `SimulationSpec`.
- `run` first calls `prepareTrialHierarchy(T; kwargs...)`, which creates folders and calls the `setupSampling`/`setupMonad` hooks (dispatching on `AbstractMonad`, `Sampling` and `Trial`; a bare `Simulation`/`Monad` gets both hooks called on itself with no wrapping `Sampling` row), then `pendingSimulationSpecs(T)`, which enumerates unstarted simulations and marks them `Queued`. `SimulationSpec` is a plain struct with `simulation::Simulation` and `monad_id::Int`; setup always precedes collection, so `monad_id` is always a real monad ID.
- `runSimulation` has a default: it asks the backend for the command via `simulationCommand(sim, spec)::Union{Nothing,Cmd}` and owns everything else — output folder, `output.log`/`output.err`, working directory, and local-vs-SLURM dispatch. A backend overrides it only if its simulation is not an external process. On HPC each simulation is wrapped in an `sbatch --wrap` invocation submitted with `--parsable`; see the HPC Job Completion feature for how the runner learns it finished.
- The command must be a bare `Cmd`: a `pipeline` is rejected (redirections are added by the runner), and so is a `Cmd` carrying an environment, because `Cmd.env` *replaces* the environment locally while a SLURM job inherits the submitting one — the same command would mean two different things. Both raise `ArgumentError`. A `Cmd`'s own `dir` is honored identically on both paths, falling back to `simulatorDir`.
- `SimulationProcess` carries `cmd`, the command `simulationCommand` returned, or `nothing` if none could be built. `process` alone cannot say what happened — it is `nothing` both for a SLURM job (which ran elsewhere) and for a simulation that never launched — so `isnothing(cmd)` is the discriminator, and `cmd` is the command to report on failure.
- A simulation whose launch **throws** is recorded as unsuccessful before the exception is rethrown, so its row never stays at `"Running"` and a later run does not skip it as already started.
- A simulation that fails is marked `"Failed"` in the database and removed from its monad's constituent list. If the monad becomes empty, it is deleted along with empty parents.
- Already-started simulations are skipped (idempotent re-runs).

**Acceptance criteria:**
- `run(simulation)` runs a single simulation and returns `MMOutput{Simulation}`.
- `run(monad)` runs all pending replicates and returns correct success counts.
- A failed simulation does not prevent other simulations in the same monad from running.
- `run([sim, monad, sampling])` runs every constituent simulation as one batch and returns `MMOutput{Trial}`; a vector containing a non-trial element raises `ArgumentError`.

---

## Feature: HPC Job Completion Detection

**One-line description:** Learn that a submitted SLURM job has finished without giving every in-flight simulation its own poller against the scheduler.

**Priority:** Must-have

**Behavioral specification:**
- Jobs are submitted with `sbatch --parsable`, never `--wait`. `--output`/`--error` point at the simulation's own folder, so each simulation keeps its own `output.log` and `output.err`. `--chdir` is the `Cmd`'s own `dir` if the backend set one, else `simulatorDir`.
- The `sbatch` client's own streams are written to `hpc.out` and `hpc.err` in the simulation's folder — distinct from `output.log`/`output.err`, which `sbatch` fills with what the job printed on the compute node. With `--parsable`, `hpc.out` is the only place a simulation's SLURM job ID lands on disk, which is what allows a finished run to be correlated with `sacct`. Failure to write them never fails a submission.
- The wrapped command is prefixed with a shell `trap ... EXIT` that writes the command's exit code to a sentinel path chosen **before submission**: `<done_dir>/<simulation_id>.<time_ns hex>`. The write is staged through `<path>.tmp` and `mv`'d into place, so a listed sentinel always has its content. Because the name is unique per submission, nothing left behind by an earlier submission or a recycled SLURM job ID can be read as this job's result, and no post-submission cleanup step is needed. Only `EXIT` is trapped; a scheduler kill produces no sentinel and is resolved by the reaper.
- **Each worker waits for its own sentinel** (`isfile` on one path every `poll_interval`, default 1s). There is no central watcher task, no registry, and no channel per job: nothing one worker does can hang or fail another. The wait blocks the worker, so `max_number_of_parallel_simulations` still bounds how many jobs sit in the queue.
- **The scheduler is a reaper only**, consulted through one `squeue -h -u $USER -t all -o %i` answer shared by every waiting worker and refreshed by whichever worker finds it older than `reap_interval` (default 300s) — one RPC per interval regardless of N. `-u` maps to `slurm_load_job_user`, filtered server-side. `-t all` keeps SUSPENDED jobs visible. `SQUEUE_*` environment variables are cleared for the call so a user's profile cannot filter live jobs out of the answer. The call is bounded by a timeout and killed if it hangs.
- A worker fails its job only when **all** hold: a snapshot taken *after* the job was submitted does not list it; it has been absent for `grace_period` (default 270s); and a *second* snapshot, taken after the first absence, still does not list it. The grace clock is worker-local, starts at first absence, and is cleared if the job reappears. Timestamps are monotonic (`time_ns()`).
- **A failed `squeue` query resolves nothing.** It is cached as a distinct "unknown" state (never conflated with an empty queue) and retried on a shorter TTL.
- Internally the wait returns the job's exit code (`nothing` if it never produced one); the default `runSimulation` is the one place that collapses it to `SimulationProcess.success`.
- Files nothing can still be waiting on (crashed-driver sentinels, staged `.tmp` writes from killed jobs, `.nfsXXXX`) are swept once per `reap_interval`, age-gated to `max(4·grace_period, 1h)` so a `done_dir` shared across sessions is safe.
- `setHPCCompletionOptions(; done_dir, poll_interval, reap_interval, grace_period)`. `done_dir` defaults to `<dataDir()>/.hpc_done` and may be pointed at a faster filesystem without moving `data/`.

**Acceptance criteria:**
- A sentinel containing `0` yields exit code 0; any other integer yields that code; the file is consumed. The `sbatch` argv carries `--parsable` and not `--wait`.
- A failed `squeue` query, repeated, resolves no waiting job; they still resolve once their sentinels appear.
- A job absent from the queue with no sentinel is failed, but only after a second snapshot confirms it, and even when `grace_period > reap_interval`.
- A snapshot taken before submission cannot fail the job, and is not refreshed while fresh.
- A sentinel arriving after the job left the queue, within grace, decides the outcome.
- With 20 jobs waiting, `squeue` is called once per interval, not once per job.
- A submission `sbatch` refuses is not a simulation failure: no job ran. A refusal whose message looks transient (QOS/submit limit, controller not answering) is retried with backoff (2 s doubling to 60 s) for up to `submit_retry_period` (default 900 s), with one warning per session; any other refusal, or a transient one that outlasts the period, throws `_SubmissionRefused`. `run` reports it as the `:submission` stage naming the simulation, puts that simulation back to `Not Started`, and fails fast; nothing is erased from any monad.
- `run`'s completion loop closes the task queue however it exits (normally, fail-fast, or interrupt), so no further simulation starts and worker tasks end instead of blocking on the channel for the rest of the session; every simulation no worker picked up is returned from `Queued` to `Not Started`. Jobs already submitted keep running and are recorded by their workers.
- `defaultJobOptions()` sets `job-name` (`S<id>`) and `cpus-per-task`, the latter resolved per simulation through the optional interface method `simulationThreads(sim, simulation)::Union{Nothing,Int}` (default `nothing`, which omits the flag). A `Function`-valued job option is called with the `Simulation` about to be submitted; `nothing` omits that flag. `setJobOptions` refuses non-`String` keys and the keys ModelManager renders itself (`wrap`, `output`, `error`, `wait`, `parsable`, `chdir`) with an `ArgumentError`.
- The shutdown reset tracks ownership explicitly: a worker marks a simulation claimed the instant it dequeues it, before scheduling, so only simulations no worker ever took are returned to `Not Started`.
- A leftover sentinel for the same simulation is neither consumed nor deleted, and does not affect the result.
- An unreadable sentinel directory neither fails nor kills the worker; an undeletable sentinel still resolves the job.
- Stale strays are swept, fresh ones left alone, at most once per interval.
- `squeue` argv contains `-t all`; `SQUEUE_*` variables are absent from its environment; a nonzero exit is `nothing`; a hang returns `nothing` within the timeout rather than blocking on the pipe.
- `sbatch` output with a banner line before or after the ID, or in the classic `Submitted batch job N` form, parses; two IDs or none is refused.
- The generated `--wrap` text, run under `/bin/sh`, records the true exit code at the given path and preserves the script's own status, for paths containing spaces, `$`, backticks, quotes and shell metacharacters.
- `hpc.out` holds the submitted job's ID; a refused submission puts the scheduler's message in `hpc.err`. A transient refusal that clears is retried until it succeeds, against the same sentinel.
- After `run` ends by fail-fast, no simulation is left at `Queued` or `Running`; those never started are `Not Started`.
- `setJobOptions` refuses reserved keys and non-`String` keys; `defaultJobOptions()` has exactly the keys `job-name` and `cpus-per-task`, and a backend whose `simulationThreads` is the default produces no `--cpus-per-task` flag while one that returns `n` produces `--cpus-per-task=n`.
- A `Function`-valued job option receives the `Simulation`, not its ID.
- `simulationCommand` returning `nothing` fails that one simulation and lets the trial continue; a `Cmd` with an environment or a `pipeline` raises `ArgumentError`.
- A backend that throws on launch leaves no simulation at `"Running"`.
- The default `runSimulation` writes `output.log`/`output.err` into the simulation folder, runs in `simulatorDir` or the `Cmd`'s `dir`, records a signal-killed or unstartable process as failed rather than throwing, rejects a `Cmd` with an environment or a `pipeline`, and routes to SLURM when `run_on_hpc` is set.

---

## Feature: Per-Simulation Post-Processing

**One-line description:** Run a user-supplied function after each successful simulation, optionally collecting returned quantities of interest into a standardized sink.

**Priority:** Should-have

**Behavioral specification:**
- Per-simulation ordering is: `postSimulationProcessing` (simulator-specific, non-destructive) → `post_processor` (user) → `postSimulationCleanup` (simulator-specific, destructive, e.g. pruning). The user callback therefore always sees the intact (but processed) output folder; destructive cleanup is deferred until after it. `postSimulationProcessing` and `post_processor` are only meaningful pre-cleanup; `postSimulationCleanup` runs regardless of success so failed simulations are still cleaned up.
- `run(T; post_processor=nothing, …)` invokes `post_processor(simulation)` once per **successfully completed** simulation, in the ordering above. Failed/skipped simulations do not trigger it.
- The callback receives the `Simulation` — the same argument a `QoI`'s `compute` gets, so one measurement function serves the sink, sensitivity analysis and calibration alike. From it the user reaches `simulationID(sim)`, the output folder via `pathToOutputFolder(sim)`, and the owning monad via `only(monadIDs(sim))`. Inside the callback the user may do anything (compute quantities, write files, delete outputs).
- Return-value contract:
  - `nothing` or `missing` → nothing is stored.
  - a scalar (`Real`, `Bool`, or `String`) → stored under the QoI's name; one row keyed by `simulation_id` is upserted into the sink DB `data/outputs/postprocessing.db`, table `post_processing`. Columns are added on demand; a re-run overwrites the existing row for that `simulation_id`.
  - `NamedTuple` / `AbstractDict` of `name => scalar` → the same row, **each key becoming the column `"<qoi name>.<key>"`** — the rule sensitivity analysis uses for a spread `reduce`, so one measurement names its parts identically wherever it is consumed and two QoIs that both report a `tumor` land in separate columns. `NamedTuple` field order is preserved.
  - **A bare anonymous function cannot write to the sink.** Its derived name is a regularised gensym (`anon_9`) that varies between sessions, so every column it named would be unstable. Wrap it (`QoI("counts", f)`) or pass a named function; returning `nothing` is unaffected.
  - any other return type, or a non-scalar value → `ArgumentError`.
  - quantity names are quoted safely for SQL (interior `"` doubled); an `AbstractDict` whose keys collide after string conversion (e.g. `1` and `"1"`) → `ArgumentError`.
- `post_processor` is not forwarded to the simulator setup hooks. The callback runs inside the per-simulation worker task; **all sink writes are serialized** in the main completion loop, so user code never writes the sink DB concurrently.
- **Fail-fast on errors.** An exception in the `post_processor`, a simulator hook (`postSimulationProcessing`/`postSimulationCleanup`), or the simulation worker is captured per-simulation and rethrown by `run` as a clear error naming the stage and simulation ID with the original stacktrace. `run` never hangs or silently drops the exception (the worker pool always delivers exactly one result per scheduled simulation).
- `postProcessingTable(args...)` / `printPostProcessingTable` read the sink back as a `DataFrame` keyed by `:SimID` (joinable to `simulationsTable`), with `missing` for quantities not computed for a given simulation. `postProcessingDBPath()` returns the sink path.
- `simulationsTable(args...; post_processing=true)` appends the stored quantities directly onto the simulations table (left-join by `:SimID`, `missing` where not computed, row order preserved; the appended columns are not subject to `remove_constants` or sorting). The kwarg is simulation-level only — `monadsTable` does not accept it, since quantities are per-simulation.
- Deletion keeps the sink consistent with the central database: `deleteSimulations` removes each deleted simulation's sink row (so cascading `deleteMonad`/`deleteSampling`/`deleteTrial` do too, since they route through it), and `resetDatabase` removes the sink database entirely.

**Acceptance criteria:**
- The callback fires exactly once per successful simulation and not at all when nothing is re-scheduled (`use_previous`).
- A `nothing` return leaves no sink row; a NamedTuple/Dict return produces a joinable row.
- A new quantity introduces a new column; earlier rows read back `missing` for it.
- Re-writing a `simulation_id` overwrites its stored quantities.
- Unsupported return types, and dict keys that collide after string conversion, raise `ArgumentError`.
- A quantity name containing a `"` round-trips through the sink unchanged.
- A throwing `post_processor` or simulator hook makes `run` throw a clear, stage-tagged error within bounded time — it never hangs.
- `run` without `post_processor` behaves exactly as before.
- After `deleteSimulations`/`deleteMonad`/`deleteSampling`/`deleteTrial`, the deleted simulations have no rows in the sink; after `resetDatabase`, the sink database no longer exists.

---

## Feature: Analysis Tables

**One-line description:** Tabular summaries of trials and their varied parameters, at simulation and monad granularity.

**Priority:** Must-have

**Behavioral specification:**
- `simulationsTable(args...; kwargs...)` returns a `DataFrame` with one row per simulation and its varied parameters. `printSimulationsTable` routes the result through a `sink` (default `println`).
- `monadsTable(args...; kwargs...)` is the monad-level analogue: one row per monad and its varied parameters. `printMonadsTable` routes the result through a `sink`.
- Both accept the same `args...` forms: `AbstractTrial` objects (or arrays), a vector of IDs (simulation IDs / monad IDs respectively), or no argument (all simulations / all monads). ID collection uses `simulationIDs` / `monadIDs`, so every level works — including a bare `Simulation`, whose monad is resolved by key lookup. A simulation with no monad yields an empty table rather than an error.
- Both share keyword arguments (via `simulationsTableFromQuery` / `monadsTableFromQuery`): `remove_constants` (default `true`, drop columns constant across rows), `sort_by`, `sort_ignore` (defaults to the table's ID column plus variation-ID columns), and `short_names` (default `true`, shorten column names via `shortVariationName`; `false` keeps raw XML-path names).
- The primary-key column is renamed for display: `:SimID` for simulations, `:MonadID` for monads.
- `tags=true` (default `false`) pivots user tags into `tag:<key>` columns; `include_auto_tags=true` additionally pivots `mm:` provenance. See *Trial Tagging and Feature-Based Recovery*.

**Acceptance criteria:**
- For a `Sampling` of `m` monads with `r` replicates each, `monadsTable(sampling)` has `m` rows and `simulationsTable(sampling)` has `m·r` rows.
- Varied parameters appear as columns; a parameter held constant is dropped when `remove_constants=true` and retained when `false`.
- `short_names=false` yields raw `columnName` (XML-path) column names.
- `monadsTable(monad_ids)`, `monadsTable(monad)`, and `monadsTable(trial)` agree with the underlying monad set.

---

## Feature: Trial Tagging and Feature-Based Recovery

**One-line description:** Attach key/value tags to any trial object — automatically for provenance, manually for intent — so past work can be recovered by what it *was for* rather than by simulation ID or parameter value.

**Priority:** Must-have

**Motivation:** Nothing in the schema recorded *why* a simulation exists. Recovery therefore depended on a script's hard-coded ID list staying in sync with the database, which it does not.

**Behavioral specification:**

*Storage*
- A `tags` table in the central database: `tag_id INTEGER PRIMARY KEY, trial_class TEXT, trial_id INTEGER, tag_key TEXT, tag_value TEXT DEFAULT '', datetime TEXT`, with `UNIQUE (trial_class, trial_id, tag_key, tag_value)`.
- `trial_class` is one of `"simulation"`, `"monad"`, `"sampling"`, `"trial"`, `"calibration"` — the members of `TAG_CLASSES`. SQLite cannot foreign-key a polymorphic column, so consistency is maintained by the deletion hooks plus a diagnostics check.
- The first four derive from `lowerClassString(T)`; `"calibration"` is stated in `_tagClass(::Type{Calibration})` because `lowerClassString` is defined for `AbstractTrial` only and a `Calibration` is deliberately not one. All the store requires of a class is an integer primary key in a `<class>s` table, which `calibrations.calibration_id` already satisfies under `tableIDName`'s strip-the-`s` convention.
- **`tags.jl` is the last `include` in `src/ModelManager.jl`**, so a tagging method signature can name any type in the package; a `#!` comment at the include site states the rule. Every call into tagging from an earlier file is inside a function body, so a violation is a load-time error, never silent.
- The private implementation cores in `tags.jl` are keyed by class *string* (`_tags`, `_tagsTable`, `_deleteTagRows`, `_deleteTagsFor`, `_applyCreationTags`, `_tagReserved`, `_idsWithDirectTags`, `_appendTags!`); the per-type methods are thin delegations.
- `tag_value` defaults to `''`, never `NULL`: SQLite treats `NULL`s as distinct in a `UNIQUE` constraint, which would permit duplicate bare labels.
- Because the value is inside the `UNIQUE` constraint, one object may carry several values for one key.
- Purely additive, so `createSchema`'s `CREATE TABLE IF NOT EXISTS` brings existing databases up to date on the next `initializeModelManager`. **No migration milestone is required.**
- An index on `(tag_key, tag_value)` serves the `findTrials` direction; the `UNIQUE` constraint already indexes the "what tags does this object have?" direction.

*Key and value rules*
- Keys are identifiers: lowercased and whitespace-stripped on write, restricted to `[a-z0-9][a-z0-9_.-]*`, max 64 characters. Enforced by `normalizeTagKey`.
- Values are data: stored as given apart from trimming surrounding whitespace. Case, internal whitespace, punctuation, and unicode all survive.
- The `mm:` namespace is reserved for framework-generated tags. Because `:` is not in the legal key character set, the namespace is unforgeable through the public API — no separate reserved-word check exists.
- `recommendedTagKeys()` returns the suggested vocabulary: `project`, `purpose`, `figure`, `arm`, `verdict`, `note`. Recommendations only; any legal key is accepted.

*Writing*
- `tag!(target, tags...)` accepts an `AbstractTrial`, a `Calibration`, a type plus ID(s), a vector of objects, a bare vector of integers (interpreted as simulation IDs), or an `MMOutput`. Each tag is a `Pair` or a bare key (stored with an empty value). Re-applying is idempotent.
- `tag!(ids::AbstractVector{<:Integer})` is deliberately **not** extended to calibrations: a bare integer vector must keep meaning simulation IDs. Nor are `findSimulations`/`findMonads`, which are the inheritance-aware finders (see below), or `trialFolder`, since `calibrationFolder` already produces the identical `data/outputs/calibrations/{id}` path.
- `untag!(target, tags...)` removes a specific pair (`key => value`) or every value for a key (bare key). `untag!(target)` removes all user tags but never `mm:` provenance.
- A tag on a `Monad`/`Sampling`/`Trial` is stored **once, on that object**. It is never copied onto constituent simulations — that would go stale when replicates are added later.

*Applying tags at creation*
- `createTrial(...; tags=(...))` and `run(...; tags=(...))` apply `tags` to the object they return. There is no ambient scope and no global mutable tag state: the tags travel in the call, so parallel trial creation cannot mis-attribute them.
- Tags land on the returned object only. Its monads and simulations are matched through query-time inheritance rather than being tagged individually, which is what keeps the answer right when replicates are added later.
- `run(Ts::AbstractVector; tags=...)` tags each trial it was handed and **not** the umbrella `Trial` built to batch them. Inheritance would reach the constituents from a tag on the `Trial`, so this is a durability choice rather than a reachability one: that `Trial` is deduplicated plumbing which `deleteTrial(id; delete_subs=false)` removes on its own, and if it held the only copy of the tag, deleting it would silently make those simulations unfindable. Tagging the constituents also makes `hasTag` true for the objects the caller actually passed.
- The same reasoning applies one level down: batching objects below `Sampling` wraps each in a single-object `Sampling` so the `Trial` can hold it, and those wrappers are containers too, so they go untagged. `findTrials(Sampling; ...)` therefore returns nothing for such a batch, while `findSimulationIDs` and `findMonads` return everything expected.
- Tags are written before any simulation is dispatched, so they survive an interrupted run and are queryable while it is in flight.
- Framework-generated `mm:` tags use the same path via `tagReserved!`, which accepts the reserved namespace `tag!` rejects.
- The accessor is `tags`; a user variable of the same name shadows it silently, and `ModelManager.tags(sim)` is the workaround.

*Automatic provenance*
- Every created object records its creation time and creation context, surfaced as `mm:created`, `mm:session`, `mm:script`, `mm:git`, `mm:git.branch`, and `mm:git.dirty`.
- **Stored as columns, not tag rows.** `simulations`, `monads`, `samplings`, and `trials` each gain a `datetime` and a `provenance_id` column; the session-invariant facts live once in a `provenances` table (`UNIQUE` across all its columns).
- **The presented model is unchanged.** The columns are synthesized back into `mm:` keys by `tags`, `tagsTable`, `appendTags!`, `tagKeys`, and `tagValues`, and `findTrials` translates such a filter into a column lookup. Callers never see a `provenance_id`.
- Provenance attaches per object at creation, **not** per monad with inheritance: simulations may be added to an existing monad in a later session, which would otherwise stamp the original session's script and commit onto much later work.
- **First writer wins.** An object that already carries provenance keeps it, so a monad reports the context that created it rather than the last one to touch it. Work done later is not lost: simulations added by a later script are new rows and carry that script's provenance, so a monad grown from 2 to 5 replicates by a second script has 2 simulations attributed to the first and 3 to the second.
- `provenances.script` holds one path; queries match on either the bare filename or the full path, so no second column is needed.
- The launching script comes from `PROGRAM_FILE`, falling back to a stacktrace walk, and is empty when the work cannot be attributed to a file. Frame filtering relies on `isfile` rather than matching `REPL[` by name, which rejects every front-end's pseudo-file (REPL inputs, IJulia `In[3]`, Pluto cell ids) uniformly.
- The session mode is a **separate** field, `mm:interactive`, rather than a sentinel in the script field: `isinteractive()` is a property of the session while the script is a property of the frame, and an interactive session that `include`s a script must still be attributed to that script. Recording both means the attribution survives *and* carries its caveat — `mm:interactive` and `mm:git.dirty` are the two flags that say a run may not reproduce from the recorded commit and script alone.
- Git state is read via `LibGit2` (`GitRepoExt` discovers the repo from a subdirectory and works inside worktrees).
- Both are resolved on entry to `createTrial` and `run` — once per call, not once per object — so edits made during a long session are reflected in what is created next. A changed git state produces a new `provenances` row via the `UNIQUE` constraint.
- **Columns are added without a migration milestone.** `ensureProvenanceColumns` runs from `createSchema` and `ALTER TABLE`s only what `columnsExist` reports missing, so existing projects gain them on the next `initializeModelManager` and simulator packages implement nothing. The loop covers `calibrations` too, and is keyed through `_tagClass` rather than `lowerClassString` so it can name `Calibration`.
- `calibrations` already carries a `datetime`, so only `provenance_id` is added to it; a calibration created before provenance existed reports `mm:created` (synthesized from that column) and no provenance, as objects predating the tagging upgrade do.
- `createCalibration` writes its stamp in the same `"yyyy-mm-ddTHH:MM:SS"` form as every other table; `_normalizeStamp` special-cases only the 10-digit legacy `trials` format.
- Sensitivity analyses stamp `mm:method` on their sampling; calibration stamps `mm:method` on the *run* (the method type, e.g. `"ABCSMC"`, so the key reads the same way across both) and `mm:calibration`/`mm:generation` on each batch sampling. The `calibrations.method` column keeps its own human-facing spelling (`"ABC-SMC"`).
- Simulator version is deliberately **not** tagged: it is already a foreign-keyed column on every row via `simulatorVersionTableName`/`resolveSimulatorVersionID`, which the downstream simulator package owns.

*Retrieval*
- `findSimulationIDs(; tags, any_of, status, inherit=true)` returns sorted IDs; `findSimulations` returns constructed objects; `findMonads` works one level up; `findTrials(T; ...)` dispatches on type — `Simulation`, `Monad`, `Sampling`, `Trial`, or `Calibration`.
- **Calibration-class tags do not inherit downward** (v1 decision). Inheritance is resolved at query time and only downward, by walking Trial→Sampling→Monad→Simulation; a `Calibration` is not on that chain, and `_inheritedIDs(::Type{Calibration}, …)` returns `Int[]` so `inherit=true` is a no-op for it rather than an error. The route to a run's monads is the `mm:calibration` tag every generation's sampling carries: `findMonads(tags = ("mm:calibration" => "42",))`.
- A tag on the run is the durable record: a batch's `mm:calibration` tag dies with its sampling when every monad is deleted, while the `calibrations` row is never removed by a monad cascade.
- `findTrials(Calibration; status=...)` throws, as it does for `Sampling` and `Trial`: `status` is a simulations-only filter.
- The ID-returning form is unbounded — with `inherit=true` a tag on a `Trial` legitimately expands to every simulation beneath it. The **object**-returning forms build objects through `simulationsFromIDs` (a single query, not one `SELECT` per object) and refuse result sets above `MAX_MATERIALIZED_TRIALS` (10 000), overridable per call via `limit`.
- `tags` filters combine with AND, `any_of` with OR; given both, the results intersect. A filter is a `key => value` pair (exact) or a bare key (any value).
- `inherit=true` (default) makes a tag on a parent match its constituents, resolved at query time by walking `constituentIDs` — parent/child edges live in CSVs, not SQL, so this cannot be a single query. `inherit=false` matches only direct tags. Tags never propagate upward.
- Results are always intersected with the objects that still exist, so orphaned tag rows never surface.
- `simulationsTable(...; tags=true)`, `monadsTable(...; tags=true)`, and `calibrationsTable(...; tags=true)` pivot tag keys into `tag:<key>` columns (namespaced so they cannot collide with ID, folder, or parameter columns). Multi-valued keys join with `|`; untagged objects get `missing`. `include_auto_tags=true` also pivots `mm:` tags.
- `tagsTable`, `printTagsTable`, `tagKeys`, `tagValues` support discovery of the vocabulary actually in use.

*Hints*
- A one-time-per-session `@info` fires when a trial is created with no user tags, showing the provenance that was captured automatically and the syntax for adding more. A second fires when a recovery query runs against a database with no user tags.
- Suppressed by `setTagHints!(false)` or `MODELMANAGER_TAG_HINTS=0`.

*Concurrency*
- `withTransaction(f; mode)` wraps a transaction and joins rather than nests when already inside one. It is used in exactly one place — batching tag inserts into a single commit — and always with the default mode.
- No write path uses `EXCLUSIVE`. A single statement is already atomic, and an `INSERT OR IGNORE` against a `UNIQUE` constraint is self-correcting, since a losing racer's lookup finds the winner's row. That covers `Monad` and provenance resolution.
- `Sampling` and `_findOrCreateTrialID` (reached through the `Trial` constructor) scan before inserting with no `UNIQUE` constraint to fall back on, so two *sessions* creating the same object could each insert a row. This is accepted: concurrent trial creation is unsupported, and protecting it would mean holding the database write lock across constituent-CSV file reads. The remedy, should duplicates ever appear, is recorded in `progress.md`; `withTransaction`'s `mode` keyword exists to make it a one-word change.
- Two sessions cannot corrupt the database — SQLite serializes writers itself.
- This serializes against **other processes** sharing the project (concurrent HPC jobs, a second REPL). It does not serialize tasks within one session, because SQLite locks are per-connection and ModelManager shares one. Concurrent trial creation in a session is unsupported by design; `recordConstituentIDs` is read-modify-write on a CSV outside SQLite's reach.

*Integrity*
- Tag rows are deleted at all five deletion choke points (`deleteSimulations`, `deleteMonad`, `deleteSampling`, `deleteTrial`, `deleteCalibration`). `resetDatabase` needs no hook — it deletes the central database file.
- `orphanedTagCounts()` reports tag rows per class whose object no longer exists, including `"calibration"`; `databaseDiagnostics` warns when any are found. It does not assert the table's existence, so databases predating tagging degrade gracefully.
- Tag writes never take down a run: `applyCreationTags`, `tagReserved!`, and provenance resolution route through `_quietly`, which swallows and `@debug`s their errors.

**Acceptance criteria:**
- Tagging and retrieving round-trips for all four classes; re-tagging is idempotent; a key may hold multiple values; bare labels dedupe.
- `createTrial(...; tags=...)` tags the returned object and nothing beneath it; those constituents still match the tag through inheritance.
- `run([t1, t2]; tags=...)` tags both trials, not only the umbrella `Trial`.
- Zero `mm:`-prefixed rows in `tags` after ordinary use; every created object has non-null `datetime` and `provenance_id`; all objects created in one session share a single `provenances` row.
- `findSimulationIDs(tags = ("mm:session" => id,))` and `("mm:script" => "sweep.jl",)` both resolve through the columns.
- Object-returning finders throw above `limit`; `simulationsFromIDs` agrees with `Simulation.(ids)` and skips missing IDs.
- `tag!(sim, "mm:created" => ...)` throws `ArgumentError`.
- `createTrial(...; tags=...)` and `run(...; tags=...)` tag the object returned or handed in; objects created outside the call are unaffected.
- A tag on a `Sampling` matches its simulations with `inherit=true` and none with `inherit=false`.
- Inherited and direct tags compose under AND; `any_of` composes under OR.
- Deleting an object removes its tag rows; deleted objects never surface from a tag query; `orphanedTagCounts()` stays at zero.
- `simulationsTable(ids; tags=true)` adds `tag:`-prefixed columns only, with `missing` for untagged rows.
- Dropping the `tags` table and reinitializing recreates it with no migration; dropping `calibrations.provenance_id` and reinitializing restores it, twice over, without duplicating the column.
- `_tagClass(Calibration) == "calibration"`, `_tagTable("calibration") == "calibrations"`, and `TAG_CLASSES` has five members.
- A calibration round-trips through `tag!`/`tags`/`hasTag`/`untag!`/`tagsTable`/`findTrials`; `untag!` leaves its `mm:` keys; `tag!` rejects `mm:` keys on it while `tagReserved!` accepts them.
- A tag on a calibration is *not* matched by `findSimulationIDs`/`findMonads`, and survives `deleteMonad` of every monad the run evaluated.

---

## Feature: Deletion

**One-line description:** Remove simulations and their parent containers from the database and disk.

**Priority:** Must-have

**Behavioral specification:**
- `deleteSimulations(ids)` removes simulations from DB and disk; optionally cascades to empty monads/samplings/trials (`delete_supers=true`).
- `deleteMonad`, `deleteSampling`, `deleteTrial` cascade up and down as appropriate.
- `resetDatabase()` deletes all outputs, clears variation files, calls `clearSimulatorArtifacts(sim)`, and reinitializes the DB.
- Each deletion routine also removes the deleted objects' rows from the `tags` table (see *Trial Tagging*), since SQLite cannot foreign-key the polymorphic `trial_class`/`trial_id` pair.

*Removal on shared filesystems*
- All file removal goes through `rm_hpc_safe`. Off HPC it is exactly `rm(path; force, recursive)`, exceptions included.
- On HPC it attempts that same `rm` first — removal is the only thing that reclaims space — and *moves* whatever survives into `data/.trash/data-YYMMDD/`, mirroring the path's position under `data/` (a path outside `data/` goes under `_external/`). A rename succeeds where an unlink does not because it never releases the file.
- Returns `:removed`, `:staged`, or `:unremoved`. In HPC mode a filesystem failure is warned about, not thrown: callers delete the matching database rows first, and most call it in a loop, so an exception would abandon a bulk deletion. A missing path with `force=false` still throws, as `rm` does.
- The `:staged` warning fires at most once per project per session, latched on `ModelManagerGlobals.trash_staged_warning_shown` and cleared by `initializeModelManager`. The `:unremoved` warning is not latched: each occurrence names a different leaked, untracked path and is the only record of it that will ever exist.
- `initializeModelManager` retries the removal of staged paths in the background, ahead of `databaseDiagnostics`, which then reports whatever is still there. The sweep touches only top-level entries named `data-YYMMDD`, never anything it did not create, and applies no age threshold: a bucket another session is concurrently staging into is handled where it happens, by recreating the directory and retrying the move.
- Staging also re-sweeps when the calendar day rolls over, at most once per day, so a session that outlives a single day does not accumulate residue that nothing retries until the next startup.
- Staging cannot be redirected to another filesystem: a cross-mount move is a copy followed by a delete of the source, and that delete is the refused operation. Put `data/` on scratch instead.

**Acceptance criteria:**
- After `deleteSimulations(ids)`, no rows remain in `simulations` for those IDs.
- Empty monads are removed when `delete_supers=true`.
- `resetDatabase()` leaves the project in the same state as a fresh `initializeDatabase()`, and errors rather than reinitializing if the central database file could not be removed or staged.
- On HPC, a removable path is actually removed and `data/.trash/` is never created; only a path the filesystem refuses to release is staged, and it is staged whole.
- The sweep clears an old bucket and removes `data/.trash/` itself when it empties, leaving today's and any future-dated bucket untouched, along with any entry it did not create.

---

## Feature: Global Sensitivity Analysis

**One-line description:** Run MOAT, Sobol', and RBD sensitivity analyses on any measured output.

**Priority:** Must-have

**Behavioral specification:**
- `MOAT`, `Sobolʼ` (`SobolMM`), and `RBD` are subtypes of `GSAMethod`.
- `run(method, inputs, avs; functions, kwargs...)` creates the sampling design, runs simulations, computes indices for each function in `functions`, and records the scheme to CSV.
- `functions` holds `QoI`s or bare functions; either way each is called once per *simulation* with a `Simulation`, and a monad's replicates are combined by the QoI's `reduce` (`mean` for a bare function).
- **A `QoI` whose `reduce` returns a `Dict` or `NamedTuple` yields one analysis per key**, labelled `"<qoi name>.<key>"`; a `Real` yields one labelled with the QoI's own name, so a keyed measurement serves all three QoI consumers unchanged.
  - Every monad must reduce to the *same* keys, since each key's indices need a value from every monad in the design and a hole has no defensible fill. A mismatch is an `ArgumentError` naming both key sets. This is deliberately stricter than `mseDistance`, which imputes an absent key as zero and warns once.
  - A `Vector` is **not** spread by index: only its length can be checked across monads, and equal length is not equal meaning (two series sampled at different times share a length and not a meaning). The error says so rather than merely reporting the type.
  - The sink uses the same rule, so a keyed measurement names its parts identically in both places.
  - **A QoI name may not contain a `.`**, refused at construction, so a label can always be read back to the QoI that produced it. Names ModelManager derives itself are regularised to `[A-Za-z_][A-Za-z0-9_]*`.
- `gsa_sampling.results` is keyed by **label** (`Dict{String,...}`), not by the function or `QoI` object; `gsaLabels(gsa_sampling)` returns them sorted.
- `kwargs` are forwarded to `run(::Sampling; ...)`.
- `run(method, spec::StudySpec; functions, kwargs...)` runs the analysis over a study specification shared with calibration (see *Calibration Infrastructure*); there is no `run(method, ::CalibrationProblem)`.
- `ParsedVariations(problem::CalibrationProblem)` is lossless (both workflows normalize through the same `LatentVariation` factories); the reverse direction is absent, since it would lose a `DistributedVariation`'s display name, which the generation CSVs are keyed by.

**Acceptance criteria:**
- `run(MOAT(5), inputs, [dv])` creates `5*(d+1)` monads and returns a `MOATSampling`.
- `calculateGSA!(gsa_sampling, fs; recompute=false)` **skips a measurement whose results are already present**, decided from the QoI's *name* before any simulation output is read (every label a QoI produces is its name, or its name plus `.` and a key); adding a quantity to an existing analysis evaluates only the new one. An auto-derived `anon_…` name never triggers the skip.
- `recompute=true` forces re-evaluation, dropping every label the QoI previously owned before filing the new ones. It is required when the measurement itself changed, which is undetectable.
- Two entries of `functions` producing the same label are refused, and nothing is filed when they are — the call is rejected before any result is stored.
- `recordSensitivityScheme` writes a CSV with monad IDs matching the sampling design.

**Sensitivity visualization:** `RecipesBase.jl` recipes (no backend dependency) for the three `GSASampling` subtypes, in `sensitivity_visualize.jl`. Each emits one series per label in the `results` dict, in sorted order for reproducibility; the series label includes the quantity's own label only when more than one is present. Parameter (x-axis) names come from the `monad_ids_df` columns after the method's bookkeeping columns (`base` for MOAT; `A`,`B` for Sobolʼ; none for RBD).
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
- `upgradePackage(sim, db, from_version, to_version, auto_upgrade)` walks the milestones in `(from_version, to_version]`, calling `upgradeToMilestone(sim, v, auto_upgrade)` for each.
- Simulator packages implement `upgradeMilestones`, `upgradeToMilestone`, and `dbVersionTableName`.
- `continueMilestoneUpgrade(version, auto_upgrade)` prompts the user for destructive migrations (unless `auto_upgrade=true`).
- The package whose version the database tracks is **not configurable**: it is the package defining `typeof(sim)`, resolved through `Base.moduleroot` so a type in a submodule reports its package. Both the loaded version (`pkgversion` of that module) and the installed version (`Pkg` keyed on that module's UUID) derive from it, as does the name used in messages. There is no backend hook for any of it.
- `_loadedPackageVersion` is internal, yielding `nothing` when that module belongs to no versioned package — a simulator written in a script or at the REPL.
- `getInstalledVersion(sim)` reports the version recorded in the active environment's manifest.
- **Migrations target the loaded version, not the installed one.** The milestone list comes from the loaded code, so the loaded release is the furthest a session can correctly migrate to; targeting it keeps the recorded version and the applied migrations in step by construction.
  - `resolvePackageVersion` compares the recorded version against the loaded one and migrates to it. Equal → `true`; loaded newer → `upgradePackage`; loaded older → returns `false`.
  - With no determinable loaded version, `resolvePackageVersion` warns and returns `true` without migrating: which milestones belong to the running code is unknowable, so there is nothing to migrate with. The project opens and simply gets no version tracking — a simulator prototyped in a script keeps working. The warning states that a database created by a versioned build may not match the running code.
  - `getDBPackageVersion` stamps a database with no version table using the loaded version, so a project created mid-session records the version whose code built its schema. It throws when that version cannot be determined, rather than inventing one; `resolvePackageVersion` returns before reaching it in that case.
  - `upgradePackage` refuses a `to_version` above the loaded version. Unreachable from `resolvePackageVersion`; it guards direct callers, which supply `to_version` themselves. Refuses rather than clamping, so a caller is never silently migrated somewhere other than where they asked. A target at or below the loaded version is permitted, since resuming a partly-applied chain is legitimate.
- Every version diagnostic is emitted from one place, at a consistent level: `@warn` when the loaded version differs from the installed one in either direction (`maxlog=1`, since the loaded version is fixed for a session) and when the loaded version is behind the database; `@error` when the database is ahead of the installed version, and when a migration target is beyond the loaded version; `@info` for migration progress. Each names a mid-session `Pkg` change as the cause. `continueMilestoneUpgrade` remains a `println`, since a `readline` follows it.
- Every early `false` return from `initializeModelManager` clears `initialized`, `data_dir`, and the central DB handle, so `isInitialized()` reports `false` after a failed initialization — including one that follows an earlier success.

**Acceptance criteria:**
- A project at version N can be upgraded to version N+2 by walking through N→N+1→N+2.
- If the user declines at a milestone, the upgrade stops and the DB remains at the last successfully upgraded version.
- After the environment is updated mid-session, initialization still succeeds and the database is stamped with the *loaded* version, never the installed one — both when re-initializing an existing project and when creating a new one.
- A session restarted with the newer version loaded applies the deferred milestone and advances the recorded version, so the delay resolves on its own.
- A database recorded ahead of the loaded version stops initialization with `isInitialized()` `false` and `dataDir()` `""`.
- A direct `upgradePackage` call to a version beyond the loaded one returns `false`, applies no milestone, and leaves the recorded version unchanged.
- A simulator type belonging to no package opens its project unmigrated and unstamped, with a warning, rather than being refused.

---

## Feature: Calibration Infrastructure (ABC-SMC)

**One-line description:** Framework-agnostic ABC-SMC parameter calibration.

**Priority:** Must-have

**Behavioral specification:**

*Problem definition*
- `CalibrationProblem` groups inputs, parameters, observed data, summary statistic, and distance function. `parameters` accepts any `AbstractVector{<:AbstractVariation}` — `DistributedVariation`, `CoVariation{DistributedVariation}`, `DiscreteVariation`, `CoVariation{<:DiscreteVariation}`, or `LatentVariation{<:Distribution}` — converted via `_toCalibrationParameter` to `CalibrationParameter` objects. Each pairs an `AbstractCalibrationSource` (the original variation: `DVSource`/`CVSource`/`LVSource`/`DiscreteSource`/`DiscreteCoSource`) with the derived `LatentVariation{<:Distribution}` the ABC-SMC loop uses. Every unusable variation is reported in one `ArgumentError`, by index and name. The loop samples CDF values on [0, 1] per latent dimension; the `LatentVariation`'s maps convert them into target values at simulation time.
- **Discrete and mixed parameter spaces are calibratable.** A discrete parameter is a `DiscreteUniform` over its value indices, so a particle coordinate is a CDF value in [0, 1] exactly as for a continuous parameter and the quantile does the quantising; the perturbation kernels operate on CDF coordinates and need no discrete counterpart. Posterior CSVs and the recipes report the *level*, not the index; `metadata.toml` records `"values"` (the levels) for a discrete source; the `SimulationBank` returns a `DiscreteNonParametric` over the sorted levels for a discrete column and bounds-checks a base value with `insupport`. A discrete parameter costs resolution, not correctness (the sampler can move within a bin); `cdf_grid_k` snapping and the bank mitigate this. A `LatentVariation` whose latent parameters are a raw `Vector{<:Real}` is rejected, the error naming the `DiscreteVariation` form to use instead.
- **A reference monad's variation cannot be overridden.** The `AbstractMonad` constructor takes it from the reference; `run(::GSAMethod, reference::AbstractMonad, avs; reference_variation_id=…)` raises an `ArgumentError` naming the `InputFolders` form as where a variation ID is an independent argument.
- `observed_data` is typed `Any`; any type accepted by the user's `distance` is valid. `summary_statistic` may return any type `distance` accepts as its first argument; no dict coercion is applied.
- `mseDistance(simulated, observed)`: `Dict`/`Dict` → mean of per-key squared errors (scalar keys) or mean squared errors (vector keys), averaged across `observed`'s keys; `AbstractVector`/`AbstractVector` → `Σ(simᵢ−obsᵢ)²`, `DimensionMismatch` on unequal lengths; `Real`/`Real` → `(sim − obs)²`.

*Shared study objects*
- **`StudySpec` is the model-and-parameters half of a study**: `inputs`, the user's `variations`, `reference_variation_id`, `n_replicates`, `use_previous`. Consumed through `run(::GSAMethod, spec; functions=…)` and `CalibrationProblem(spec, observed_data, summary_statistic, distance)`; there are no other named entry points.
  - It holds nothing a single consumer needs: `observed_data`, `summary_statistic` and `distance` stay on `CalibrationProblem`; `functions` stays on the sensitivity entry point. `use_previous` is the one field calibration ignores (it reuses through the `SimulationBank`) and is marked "(sensitivity only)" wherever it appears.
  - The user's own variations are kept, not normalised; `ParsedVariations(spec)` derives the normalised form on demand.
  - The `AbstractMonad` form takes its reference variation from the reference and accepts no override.
  - A caller keyword beats the spec's value: the spec's fields are defaults the user set.
  - `show` is the whole reporting surface: one line per parameter with its kind and whether sensitivity and calibration can use it, flagging a latent variation without `inverse_maps` (accepted by calibration, but it disables the `SimulationBank`).
- **`QoI(name, compute; reduce=mean, stored=:never)` is the seam between a user's measurement and its three consumers.** `compute` is called with one `Simulation`; `reduce` combines a parameter set's replicate values. A `QoI` is passed directly to `run(::GSAMethod, …; functions=)`, to `CalibrationProblem`'s `summary_statistic`, and to `run(…; post_processor=)`; there are no adapter functions in the public API.
  - There is no level to declare: per-simulation `compute` plus `reduce` is strictly more expressive than a monad-level `compute`, because `reduce` receives everything `compute` returned.
  - Sensitivity analysis honours the reducer; each component of the reduced value must be a `Real`, failing at the QoI naming it.
  - A plain `Function` is wrapped into a `QoI` at the boundary, gaining a name (`_qoiNameFromFunction`; an anonymous function becomes `anon_…`) and `reduce = mean`. Nothing downstream branches on which was given.
  - A keyed value is spread by both the sink and sensitivity analysis under one naming rule, `"<qoi name>.<key>"` (see *Global Sensitivity Analysis* and *Per-Simulation Post-Processing*).
  - The value constraint comes from the consumer: sensitivity analysis needs `reduce` to return a `Real` or a `Dict`/`NamedTuple` of them; calibration needs whatever its `distance` accepts; the sink constrains `compute` (a scalar, or a `NamedTuple`/`Dict` of scalars), since it fires once per simulation and `reduce` is never called.
  - A single `QoI` `summary_statistic` reports its value directly; a vector of QoIs reports a `Dict` keyed by QoI name. A bare `summary_statistic` function that does not declare a `Simulation` argument is accepted with a warning (the declared type is the only signal that it computes per simulation rather than per monad); the warning fires once per function.
- **A `QoI` can read a value the post-processing sink stored earlier**, via `stored=:prefer` (stored if present, else compute) or `stored=:require` (stored or error).
  - A stored value is read back as written: a scalar as the sink holds it (`Float64`, `Int64` or `String`, never coerced), a keyed QoI reassembled from its `"<name>.<key>"` columns into a `Dict` with `String` keys.
  - `stored` defaults to `:never` because nothing records which `compute` produced a stored value and no fingerprint can: redefining a body leaves `hash` and `nameof` unchanged, and two textually identical anonymous functions hash differently.
  - `verifyStoredValues(q, T)` recomputes wherever the output folder survives and reports agreements, mismatches (with simulation IDs and both values), how many were never stored, and how many are unverifiable. Numbers compare with `isapprox`, keyed values key by key, other values with `isequal`; a `compute` returning `missing`/`nothing` counts as unverifiable. A clean result requires `n_agreed > 0`.
- **Restorability is decided by what JLD2 can name.** `_isAnonymousFunction` is true for a lambda and for a named function defined inside another function, a `let` or a `@testset`, and false for a top-level function or a callable struct. A closure is stripped from `problem.jld2` and its derived QoI name is an `anon_…` form, which the sink refuses to store under and which sensitivity analysis never uses to skip work. `resumeCalibration(...; problem=)` works even when `problem.jld2` cannot be read back: with no `problem=` the error names both ways out (re-`include` the defining file, or pass `problem=`); with one, a warning and the supplied problem, unvalidated.
- **`run_kwargs` and a loose keyword splat are one channel.** `run(::AbstractTrial)`, `run(::AbstractVector)` and `run(::AddVariationMethod, …)` accept `run_kwargs::NamedTuple` alongside loose keywords, merged loose-wins; calibration's entry points accept `run_kwargs`. `runCalibration` has no loose splat, keeping its `MethodError` on a mistyped keyword; a bundle cannot replace calibration's own `quiet`/`on_progress`.

*Method and entry points*
- `ABCSMC <: AbstractCalibrationMethod` holds SMC settings: `population_size`, `max_nr_populations`, `minimum_epsilon`, `epsilon_quantile` (in (0, 1)), `perturbation_kernel`, `epsilon_schedule::Union{Nothing,Vector{Float64}}`, `min_acceptance_rate`, `min_epsilon_decrease`, `min_ess_fraction` (each default `0.0`, disabled), `accept_overflow`, `cdf_grid_k`, `max_evaluations`, `store_rejected`.
- **Calibration flows through `run`.** `run(method::ABCSMC, problem)` starts a run; `run(calibration::Calibration[, method])` continues one, the bare form reloading problem and method from disk. Method-first mirrors `run(::GSAMethod, inputs, avs)`, and returning an `ABCResult` mirrors returning a `GSASampling`.
- **Two complete pairs of named entry points**: `runCalibration(method, problem; …)`/`resumeCalibration(calibration[, method]; …)` are method-agnostic; `runABC(problem; kwargs...)`/`resumeABC(calibration; …)` are the ABC-specific shorthand. Neither pair is deprecated.
- **Resuming.** `resumeCalibration` loads the `CalibrationProblem` from `problem.jld2` and the saved generations; no problem argument is required. It validates structural match for all source types and errors informatively on mismatch, checks stopping criteria against completed generations before starting the loop, and warns when the generation range is empty.
  - A method setting passed as a keyword patches the saved method; a method object replaces it wholesale (fields it does not name take constructor defaults). Passing both is an `ArgumentError`.
  - The effective settings are written back to `method.toml` whenever they differ, with the changed keys reported.
  - A resume only appends generations, so a changed setting takes effect from the next generation and nothing is refused. `population_size` gives new generations the new size while earlier ones keep theirs (weights are normalised per generation); `perturbation_kernel` is refitted per generation; `cdf_grid_k` is resolved once at loop entry, so bank reuse differs either side of the resume. `epsilon_schedule` is indexed by absolute generation: generation `t` reads `epsilon_schedule[t-1]` and generation 1 consumes no entry, so an `L`-entry schedule covers generations 2 through `L+1`; when a schedule does not cover every new generation the warning reports the covered range and the remaining generations use `epsilon_quantile`.
- **Console progress.** `progress::Symbol=:auto` on `runABC`/`runCalibration`/`resumeCalibration`: `:none` < `:generation` (one `@info` per generation start and finish, plus the stopping reason) < `:batch` (one per evaluation batch) < `:bar` (a live `ProgressMeter.jl` bar per batch, sized to its pending simulations). `:auto` is `:bar` on a TTY and `:generation` otherwise. Runtime-only, not persisted. Driven by a generic, default-`nothing` `on_progress` hook on `run` emitting `:init`/`:step`/`:finish`; with `on_progress === nothing` the runner is unchanged.

*Algorithm*
- Particle evaluations are batched per generation: each batch creates one `Monad` per proposal (`_createMonadForParams`, converting CDF values to target `DiscreteVariation`s through each `CalibrationParameter`'s maps), records every monad ID to `monads.csv` **before** running (crash safety), assembles a `Sampling`, and runs it with `quiet=true`. `evaluate_batch(t, params_list)` returns `Vector{Tuple{Union{Float64,Missing},Int}}` (distance, monad_id) in proposal order.
- **Generation 1** proposes exactly `population_size` particles in one batch (Sobol' sequence), all accepted; no threshold. **Generation t > 1** batches adaptively: each round proposes `ceil(n_needed / acceptance_rate_est)`, the estimate updated after each round (initialised from the previous generation) and floored at `0.01`; the excess of an overshooting round is trimmed unless `accept_overflow=true`.
- **Parent selection uses systematic resampling** (Kitagawa 1996): one `u ~ Uniform(0, 1/n)` places `n` evenly spaced points on the weight CDF, so each parent appears ⌊n·wᵢ⌋ or ⌈n·wᵢ⌉ times. A perturbed proposal outside the prior is dropped and the shortfall redrawn with a fresh `u`.
- The threshold for generation `t` is `epsilon_schedule[t-1]` if supplied, else `max(minimum_epsilon, quantile(prev.distances, epsilon_quantile))`.
- **Two epsilons, named apart.** `max_epsilon_accepted` is the largest distance a generation accepted; `epsilon_threshold` is the cutoff it ran against (absent for generation 1). They never coincide, since `epsilon_quantile` is strictly below 1.
- `GenerationResult` stores `acceptance_rate` (proposals passing ε / proposals evaluated — **not** capped at `population_size`), `ess` (`1/Σwᵢ²`), `n_evaluations`, `max_epsilon_accepted`, `epsilon_threshold`, `proposal_distances`, and `rejected_proposals` (CDF coordinates of rejected proposals, populated only with `store_rejected=true`; `nothing` for generation 1 and on resume). Generation metadata is logged and saved to `metadata.toml`.
- **Every evaluated proposal's distance is recorded** in `proposals.csv` (`monad_id`, `distance`, `accepted`), written unconditionally. `accepted` means passed ε, not kept: `sum(accepted)` equals `n_accepted_total` and may exceed the posterior's row count. `missing` distances are omitted (those monads are in the failed-monads file).
- **Stopping criteria** are checked after each generation, `max_evaluations` first: `minimum_epsilon`, `max_nr_populations` (a cumulative cap), `min_acceptance_rate` (accepted/proposed), `min_epsilon_decrease` (relative), `min_ess_fraction` (`ess / population_size`).
- `ConvergenceSummary(result)` and `ConvergenceSummary(cal::Calibration)` build a per-generation table with columns `t`, `max_epsilon_accepted`, `epsilon_threshold`, `acceptance_rate`, `n_accepted`, `ess`, `ess_fraction` (`ess / n_accepted`), `n_evaluations`; the `Calibration` form reads the on-disk TOML.
- **Evaluation budget.** `max_evaluations::Union{Nothing,Int}` caps proposals sent to `evaluate_batch` across the whole run, counted whether or not the monad already existed. Enforced **before** each batch is dispatched: `_capBatchToBudget` trims a planned batch to the remaining allowance (generation 1 included, when the budget is below `population_size`); an empty trimmed batch sets `budget_hit`. After dispatch `_updateBudget!` advances the count. The current generation's accepted particles are saved before the run stops with `"max_evaluations=N reached"`. Persisted to `method.toml`; `nothing` disables it.

*Perturbation kernels*
- `perturbation_kernel::AbstractKernel` on `ABCSMC`; two-level hierarchy `AbstractKernel` / `AbstractFittedKernel`, with shared logic (e.g. `_effectiveKernelScale`) in free functions. Concrete kernels (exported): `GaussianKernel(scale=2.0)` — full weighted covariance (Beaumont et al. 2009), a `Vector{Float64}` scale being a per-generation schedule with generation `t` using `scale[min(t, end)]`; `ComponentwiseKernel(scale=2.0)` — diagonal covariance; `LocalNNKernel(k=10, scale=1.0)` — global covariance shape with a per-particle bandwidth from the k-th nearest neighbour (Chebyshev metric, KD-tree); `LocalNNCovKernel(k=10, scale=1.0)` — per-particle covariance from the k nearest neighbours.
- Interface: `_fitKernel(kernel, particles, weights, param_names, t)` once per generation; `_proposeParticle(fitted, parent, param_names)` per proposal; `_kernelDensity(fitted, from, to)` per accepted particle. Fitted structs are ephemeral and private. Kernels are serialised under a `[perturbation_kernel]` TOML subtable with a `type` key; the legacy flat-string form raises a descriptive error.

*Simulation bank and CDF-grid snapping*
- `SimulationBank` is built once at calibration start from existing monads whose calibrated parameters lie strictly inside `(0,1)^d` in CDF space: `monad_ids`, `cdf_coords` (n_latent_dims × n_monads), `param_names`, and a KD-tree (`NearestNeighbors.jl`, Chebyshev metric; `nothing` when empty) for O(log n + k) L∞ box queries.
- Admission criteria per monad: (1) all location folder IDs match `problem.inputs`; (2) every varied location with no calibrated parameters matches `problem.reference_variation_id[loc]`; (3) in each calibrated location, non-calibrated columns match the effective reference value (reference row → `variation_id=0` default → missing), calibrated columns fall within the prior's support, a calibrated parameter with no DB column takes its base value from the config file (a value outside the support disqualifies the whole location), and a `CVSource` must be jointly consistent (rtol 1e-8); (4) all CDF coordinates strictly in `(0, 1)`; (5) at least one simulation is `Running` or `Completed` — applied at load time and to monads evaluated mid-run, which keeps deleted and never-started monads out of the bank.
- `LatentVariation.inverse_maps` (`target_vals → u_i`, one per latent dimension) are auto-constructed for `DVSource`/`CVSource` and user-supplied for `LVSource`, validated by round trip at construction (`_validateInverseMaps`). An `LVSource` without inverse maps disables the bank with an informational log.
- **CDF-grid snapping** (`cdf_grid_k::Union{Nothing,Int}`, default `nothing` = disabled; validated ≥ 1; persisted): grid `G(k) = {j/2^k : j=1,…,2^k−1}` per dimension; the snap is `clamp(round(Int, x·2^k), 1, 2^k−1) / 2^k`; `k_eff = k_base_eff + t − 1`; the L∞ box radius is `1/2^(k_eff+1)`.
  - `k_base_eff = max(cdf_grid_k, k_min)` with `k_min = ceil(Int, log2(N^(1/d) + 1))`, the smallest `k` for which `(2^k − 1)^d ≥ population_size`; `@info` when corrected.
  - Per proposal: draw θ; query the bank within the L∞ box around the **original** θ and, if an unused candidate exists, use its actual coordinates (`use_previous=true` reuses the monad without re-simulation); otherwise snap to the grid, resolve the monad ID without running, and discard the proposal if that monad was already evaluated this generation. After evaluation every monad ID, accepted or not, joins the generation's used set, so no monad runs twice in a generation.
  - Importance weights use the effective coordinates with prior density 1 (`Uniform(0,1)` per dimension); the bank-hit path's proposal-distribution mismatch is an acknowledged approximation.

*Failed simulations*
- After each batch, `_batchOutcome` compares a pre-run snapshot of every monad's simulation IDs against current status codes (one query per batch) and returns failed simulations, monads with a failure, and monads with no `Completed` simulation.
- Failures are recorded per generation in `failed_simulations.csv` and `failed_monads.csv` (compressed-ID format, accumulating across batches), with **one warning per generation** naming both files (silent at `progress=:none`). Nothing is written for a batch without failures.
- A monad with no successful simulation is never handed to user code. `on_monad_failure::Symbol=:reject` (`:reject` or `:error`, validated up front): `:reject` gives the particle a distance of `missing`; `:error` stops the run naming the monad, the two files, and the simulations' output folders (which survive their monad).
- `missing` is the failure signal, never a sentinel distance. Generation 1 drops `missing` particles before ε is set, warns how many, renormalises the weights over the survivors, counts them in `n_evaluations`, and errors if no monad succeeded; later generations reject them. A non-finite ε is not an error (`Inf` is a legal distance and round-trips TOML as `+inf`); the run recovers on its own.
- Partially failed monads are evaluated from what succeeded; no top-off re-runs.
- A `summary_statistic`/`distance` failure on a monad with output is fatal regardless of `on_monad_failure`: logged with the monad ID (and its failed-simulation count) and rethrown with the original backtrace; a `distance` return that is not a `Real` raises immediately, naming the type.

*Persistence*
- `runABC`/`runCalibration` write `method.toml` (settings), `problem.jld2` (the `CalibrationProblem`), and `parameters.toml` (display name → DB column mapping plus prior strings) to the calibration folder.
- **One folder per generation.** `generations/{t}/` holds `particles.csv` (display columns via `variationName`, plus `weight`, `distance`, `monad_id`), `cdfs.csv` (raw CDF coordinates plus the same three), `metadata.toml` (`t`, `max_epsilon_accepted`, `epsilon_threshold` when present, `acceptance_rate`, `ess`, `n_evaluations`), `monads.csv`, `proposals.csv`, and the two conditional failure records.
  - Artifacts are addressed by role: `_GENERATION_ARTIFACTS` maps roles to basenames and `_generationArtifact(gen_dir, t, role)` resolves the folder layout first, then the legacy flat layout at any padding width, so runs written under the flat layout are read, plotted and resumed without conversion.
  - The folder name is zero-padded to `ndigits(max_nr_populations)`; nothing depends on the width, since `_generationIndices` parses the index. A resume re-pads to `ndigits(max(max_nr_populations, highest existing generation))`.
  - `_migrateGenerationLayout!` moves flat-layout artifacts into folders on resume only; a failed move is logged and skipped. There is no database migration for these files.
  - Writes prefer an existing folder over a computed one.
- Older generation metadata that recorded a single `epsilon` is upgraded on read by `_loadGenerations` (write-then-rename; a read-only filesystem warns and continues); `epsilon_threshold` stays absent for those generations.
- The `calibrations` table is created by `createSchema()` with columns `calibration_id`, `datetime`, `description`, `method`, `provenance_id`.
- `posterior(result::ABCResult)` returns `(df, weights)` with one display column per parameter; `posterior(cal::Calibration)` reads `particles.csv` and returns the same shape.

*A calibration run as coalesced `Sampling` views*
- `Calibration` is not an `AbstractTrial` and not a level of the trial hierarchy: containment runs batch → generation → calibration and the groupings overlap, which a strict chain cannot express. `run(::Calibration)` is unambiguous against `run(::AbstractTrial)` for the same reason.
- Every monad of a calibration shares the problem's `inputs`, so any subset is a valid `Sampling`. `Sampling(calibration)` and `Sampling(calibration, generation)` hand a `Vector{Monad}` to the find-or-insert `Sampling(monads, inputs)`; matching is on the exact monad set, so repeated calls return one row, and a run that finished in a single batch shares that batch's row.
- The accessors `monadIDs(calibration[, generation])` and `simulationIDs(calibration[, generation])` are pure reads; only the `Sampling` constructors insert. Building the run-wide view mid-run pins a partial monad set the finished run will not reuse; documented, not gated (the `calibrations` row has no completion flag).
- Views exclude monads that no longer exist: `calibrationMonadIDs` returns the raw on-disk record (deleted monads included; deduplicated and sorted), `monadIDs(calibration)` the surviving subset.
- Generations are views, not objects: no row, no ID, no tags.

*Read path and deletion*
- `calibrationsTable(; tags=false, include_auto_tags=false)` returns one row per run with `CalibrationID`, `DateTime`, `Method`, `Description` (never `provenance_id`), plus ID-vector and `Calibration` forms; `printCalibrationsTable` pairs with it. An empty result is a correctly shaped empty `DataFrame`. No `limit` keyword.
- `Base.show(::IO, ::Calibration)` prints id, creation time, method, description (omitted when empty), completed generation count and final ε, and never throws: an uninitialized project prints the bare id, a missing row says so, malformed TOML is skipped.
- `deleteCalibration(ids; delete_subs=false)` deletes the row, its tag rows, and `data/outputs/calibrations/{id}` via `rm_hpc_safe`, collecting monad IDs before removing anything. `delete_subs` defaults to `false` because the `SimulationBank` and `use_previous` share monads across runs.
- `calibrationsTable`, `printCalibrationsTable` and `deleteCalibration` are exported; `calibrationFolder`, `calibrationsDir` and `calibrationMonadIDs` are internal. All of it lives in `src/calibration/calibration.jl`.
- Run-level functions (`Sampling`, `monadIDs`, `simulationIDs`, `tag!`, `untag!`, `tags`, `hasTag`, `tagsTable`, `calibrationsTable`, `deleteCalibration`) also accept the `ABCResult` that `runABC` returns.

**Posterior visualization** (`RecipesBase.jl`; any Plots- or Makie-compatible backend):
- `plot(result::ABCResult)` / `plot(cal::Calibration)` — corner plot: weighted 1D KDE marginals on the diagonal, weighted 2D KDE contours over weighted scatter off it. `space = :target` (default) or `:cdf`.
- `plot(result, :ridgeline)` — one panel per parameter, stacked weighted 1D KDEs per generation, earliest lightest; same `space` keyword.
- `plot(result, :distances)` / `plot(Calibration(id), :distances; generation=t, logscale=false)` — histogram of every proposal a generation evaluated, the accepted ones coloured separately and the threshold drawn on a bin boundary. Bin edges are computed by the recipe so both series share them, and each series is confined to its own side of the threshold. Legend labels carry counts; the title notes when more passed ε than were kept. Generation 1 draws no threshold; a run recorded before proposal distances were kept plots from its accepted distances and says so; `logscale=true` bins in log10 and reports dropped non-positive distances.
- `plot(ConvergenceSummary(result))` — three panels sharing a generation axis: epsilon, acceptance rate, ESS fraction.
- `plot(result, :transition; generation=t, show_particles=false, space=:target, aggregate_duplicates=true)` — generation `t`'s posterior KDE with generation `t+1`'s proposals overlaid, accepted and rejected coloured apart (requires ≥ 2 generations; default `t = length(result.generations) - 1`). With `rejected_proposals === nothing` the rejected points are loaded lazily from the generation's monads record minus the accepted IDs, via `simulationsTable`; `space=:cdf` additionally needs inverse maps on every parameter, else accepted-only with a title note. Diagonal panels: 1D KDE plus a stacked strip chart (accepted ticks up, rejected down; duplicates stack). Off-diagonal: 2D KDE contour plus aggregate bubbles (accepted area ∝ weight, rejected ∝ count × `1/population_size`); `aggregate_duplicates=false` shows translucent individual points. `show_particles=true` adds generation-`t` rug marks.
- `latent_params(result; generation=:final)` and `target_params(result; generation=:final)` return the particle DataFrame in CDF and target space respectively.

**Not planned:** MCMC rejuvenation steps (systematic resampling, per-generation monad dedup and grid refinement address the degeneracy they target); warm-start/custom initial populations (subsumed by the `SimulationBank`). Additional distance functions (`maeDistance`, normalized variants) are unscoped; users supply their own.

**Acceptance criteria:**
- `runABC(problem; population_size=50, max_nr_populations=3)` completes on a toy model with a known posterior.
- `resumeABC(Calibration(id))` loads `problem.jld2` and saved generations and continues from the next one without a re-supplied `CalibrationProblem`; it validates structural match for all source types (`DVSource`, `CVSource`, `LVSource`) and errors informatively on mismatch.
- `mseDistance` returns 0.0 when simulated equals observed (all three calling conventions); `mseDistance([1.0, 2.0], [3.0, 4.0]) ≈ 8.0`; `mseDistance(3.0, 1.0) == 4.0`; `mseDistance([1.0], [1.0, 2.0])` throws `DimensionMismatch`.
- `ABCSMC` throws on invalid settings (`population_size < 1`, `epsilon_quantile` outside (0, 1)).
- The `calibrations` table exists after `createSchema()` with columns `calibration_id`, `datetime`, `description`, `method`, `provenance_id`.
- `Sampling(calibration)` twice returns the same `sampling_id`; on a multi-generation run it differs from every batch `sampling_id`, while on a single-batch run it *is* the batch's row and adds none.
- `monadIDs(Sampling(calibration, t)) ⊆ monadIDs(Sampling(calibration))`, their union over all generations equals the run-wide set, and `simulationIDs(calibration)` equals the union of the batch samplings' simulation IDs.
- With a monad forced to lose every simulation, its ID appears in `calibrationMonadIDs` but not in `monadIDs(calibration)`, and both views still build.
- `Sampling(calibration, 99)` on a run with no generation 99 throws an `ArgumentError` naming the generations that exist.
- The accessors add no `samplings` row; only the `Sampling` constructors do.
- `calibrationsTable()` has exactly the columns `CalibrationID`, `DateTime`, `Method`, `Description`, one row per run, reads back the `description` passed to `runCalibration`, and its `DateTime` matches `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$`.
- `deleteCalibration` removes the row, its tags, and its folder while leaving the monads and simulations intact; with `delete_subs=true` it removes those too.
- `plot(result)`, `plot(result, :ridgeline)`, `plot(result, :distances)`, `plot(ConvergenceSummary(result))`, and `plot(result, :transition)` all produce plots without error on a completed `ABCResult` with ≥ 2 generations; the `:distances` recipe's accepted and rejected bins are disjoint.
- `_validateInverseMaps(lv)` passes for auto-constructed DV/CVSource inverse maps; user-supplied LVSource inverse maps are checked at construction time.
- `_loadGenerations` finds generation files regardless of layout or zero-padding; `ConvergenceSummary(cal).df.t` and `posterior(cal; generation=t)` use the parsed generation index, never a listing position.
- `max_evaluations=N` never dispatches more than `N` proposals, including when `N < population_size`.
