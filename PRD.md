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

Neither `variationLocation` nor `addVariationRows` is part of this interface. `variationLocation`
dispatches on variation objects (the caller resolves targets to locations before constructing
them), and `addVariationRows` takes no simulator argument. Both were listed here in error.

**Optional interface methods (default no-ops):**
- `postSimulationProcessing(sim, simulation_process; kwargs...)` — **non-destructive** processing, run *before* the user `post_processor`; must not delete output, or the user callback would be handed an incomplete folder
- `postSimulationCleanup(sim, simulation_process; kwargs...)` — **destructive** cleanup (pruning/deleting output, removing error files), run *after* the user `post_processor` and regardless of success
- `initializeInputFolder(sim, input_folder)` — per-folder setup on insert
- `getInputFolderDescription(sim, path)` → `String` (default `""`)
- `clearSimulatorArtifacts(sim)` — remove build artifacts on database reset
- `postVariationXMLProcessing(sim, location, path)` — after a variation XML file is written
- `centralDBFileName(sim)` → `String` (default `"mm.db"`)
- `dbVersionTableName(sim)` → `String` — tracks migration state
- `upgradeMilestones(sim)` → `Vector{VersionNumber}`
- `upgradeToMilestone(sim, version, auto_upgrade)` → `Bool`

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
- `useHPC(true)` when `run_on_hpc` is already `true` emits a one-time `@warn` that the call is redundant — pre-v0.8.4 scripts called it to work around the auto-detection that was specified but never implemented.

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
- `MMOutput` deliberately stays outside `AbstractTrial`: it has no `id` field, so `trialID(::AbstractTrial)`, `trialFolder`, `lowerClassString` and every `T.id` in the runner, tagging and deletion paths would need guards; and `run(::AbstractTrial)` would silently start accepting `MMOutput{Sampling}`/`MMOutput{Trial}` and re-running them, where today that is a `MethodError`. Monad-wrapping outputs would keep dispatching to the more specific `run(::MMOutput{<:AbstractMonad}, args...)`.

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
- `run(Ts::AbstractVector; kwargs...)` bundles a collection of already-built trials (`Simulation`/`Monad`/`Sampling`/`Trial`, possibly in a `Vector{Any}`) into one `Trial` via `createTrial(::AbstractVector)` and runs it as a single parallelized batch. Non-`AbstractTrial` elements and empty vectors raise `ArgumentError`.
- `kwargs` are forwarded to `prepareTrialHierarchy` (simulator hooks like `force_recompile`) and to `postSimulationProcessing`/`postSimulationCleanup`. The `post_processor` hook (see the Post-Processing feature) runs per successful simulation between them. `runSimulation` takes no kwargs — it receives only the `SimulationSpec`.
- On HPC, each simulation is wrapped in an `sbatch --wrap` invocation.
- A simulation that fails is marked `"Failed"` in the database and removed from its monad's constituent list. If the monad becomes empty, it is deleted along with empty parents.
- Already-started simulations are skipped (idempotent re-runs).

**Acceptance criteria:**
- `run(simulation)` runs a single simulation and returns `MMOutput{Simulation}`.
- `run(monad)` runs all pending replicates and returns correct success counts.
- A failed simulation does not prevent other simulations in the same monad from running.
- `run([sim, monad, sampling])` runs every constituent simulation as one batch and returns `MMOutput{Trial}`; a vector containing a non-trial element raises `ArgumentError`.

---

## Feature: Per-Simulation Post-Processing

**One-line description:** Run a user-supplied function after each successful simulation, optionally collecting returned quantities of interest into a standardized sink.

**Priority:** Should-have

**Behavioral specification:**
- Per-simulation ordering is: `postSimulationProcessing` (simulator-specific, non-destructive) → `post_processor` (user) → `postSimulationCleanup` (simulator-specific, destructive, e.g. pruning). The user callback therefore always sees the intact (but processed) output folder; destructive cleanup is deferred until after it. `postSimulationProcessing` and `post_processor` are only meaningful pre-cleanup; `postSimulationCleanup` runs regardless of success so failed simulations are still cleaned up.
- `run(T; post_processor::Union{Nothing,Function}=nothing, …)` invokes `post_processor(simulation_process)` once per **successfully completed** simulation, in the ordering above. Failed/skipped simulations do not trigger it.
- The callback receives the `SimulationProcess`; from it the user reaches `simulation.id`, `monad_id`, and the output folder via `pathToOutputFolder(id)`. Inside the callback the user may do anything (compute quantities, write files, delete outputs).
- Return-value contract:
  - `nothing` → nothing is stored.
  - `NamedTuple` / `AbstractDict` of `name => scalar` (`Real`, `Bool`, or `String`) → one row keyed by `simulation_id` is upserted into the sink DB `data/outputs/postprocessing.db`, table `post_processing`. Columns are added on demand; a re-run overwrites the existing row for that `simulation_id`.
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
- **`tags.jl` is the last `include` in `src/ModelManager.jl`.** A method signature is evaluated when the method is defined, so a tagging method for a type declared in a later file would be an `UndefVarError`. Loading tagging last puts every type in the package ahead of it, which makes this a one-time move rather than a recurring negotiation; a `#!` comment at the include site states the rule. Nothing before it needs its names at load time — every call into tagging from an earlier file (`applyCreationTags` in the four trial constructors, `deleteTagsFor` in `deletion.jl`, `refreshProvenance!` in the runner and user API, `tagsSchema`/`ensureProvenanceColumns` in `createSchema`, `tagReserved!` in GSA and ABC-SMC) is inside a function body, which Julia resolves lazily. A violation is therefore a load-time error, never silent.
- An `AbstractTaggable` capability supertype was considered and rejected: it would make the marginal cost of the next taggable type one line instead of ~15 small methods, but it widens ~21 signatures in `tags.jl`, touches `classes.jl`, and adds a layer to the documented public type tree. Per-type methods are the cheaper trade at two taggable families. The private implementation cores in `tags.jl` are keyed by class *string* (`_tags`, `_tagsTable`, `_deleteTagRows`, `_deleteTagsFor`, `_applyCreationTags`, `_tagReserved`, `_idsWithDirectTags`, `_appendTags!`), so the per-type methods are thin delegations rather than duplicated bodies.
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
- The accessor is `tags`. Renaming it to `trialTags` was considered, because a bare `tags` is easily masked by a user variable of the same name and Julia allows that shadowing silently, but the shorter name won; `ModelManager.tags(sim)` is the workaround if it ever bites.

*Automatic provenance*
- Every created object records its creation time and creation context, surfaced as `mm:created`, `mm:session`, `mm:script`, `mm:git`, `mm:git.branch`, and `mm:git.dirty`.
- **Stored as columns, not tag rows.** `simulations`, `monads`, `samplings`, and `trials` each gain a `datetime` and a `provenance_id` column; the session-invariant facts live once in a `provenances` table (`UNIQUE` across all its columns). Measured at 10⁵ objects this costs 21 bytes/object — ~21 MB at 10⁶ simulations — against 1139 bytes/object (1.14 GB) for one tag row per fact. The `tags` table is entity-attribute-value and each row is stored three times (table, `UNIQUE` index, lookup index), which is what makes per-fact rows expensive; a column in an existing row costs neither.
- **The presented model is unchanged.** The columns are synthesized back into `mm:` keys by `tags`, `tagsTable`, `appendTags!`, `tagKeys`, and `tagValues`, and `findTrials` translates such a filter into a column lookup. Callers never see a `provenance_id`.
- Provenance attaches per object at creation, **not** per monad with inheritance: simulations may be added to an existing monad in a later session, which would otherwise stamp the original session's script and commit onto much later work.
- **First writer wins.** An object that already carries provenance keeps it, so a monad reports the context that created it rather than the last one to touch it. Work done later is not lost: simulations added by a later script are new rows and carry that script's provenance, so a monad grown from 2 to 5 replicates by a second script has 2 simulations attributed to the first and 3 to the second.
- `provenances.script` holds one path; queries match on either the bare filename or the full path, so no second column is needed.
- The launching script comes from `PROGRAM_FILE`, falling back to a stacktrace walk, and is empty when the work cannot be attributed to a file. Frame filtering relies on `isfile` rather than matching `REPL[` by name, which rejects every front-end's pseudo-file (REPL inputs, IJulia `In[3]`, Pluto cell ids) uniformly.
- The session mode is a **separate** field, `mm:interactive`, rather than a sentinel in the script field: `isinteractive()` is a property of the session while the script is a property of the frame, and an interactive session that `include`s a script must still be attributed to that script. Recording both means the attribution survives *and* carries its caveat — `mm:interactive` and `mm:git.dirty` are the two flags that say a run may not reproduce from the recorded commit and script alone.
- Git state is read via `LibGit2` (`GitRepoExt` discovers the repo from a subdirectory and works inside worktrees).
- Both are resolved on entry to `createTrial` and `run` — once per call, not once per object — so edits made during a long session are reflected in what is created next. A changed git state produces a new `provenances` row via the `UNIQUE` constraint.
- **Columns are added without a migration milestone.** `ensureProvenanceColumns` runs from `createSchema` and `ALTER TABLE`s only what `columnsExist` reports missing, so existing projects gain them on the next `initializeModelManager` and simulator packages implement nothing. The loop covers `calibrations` too, and is keyed through `_tagClass` rather than `lowerClassString` so it can name `Calibration`. That the mechanism is additive matters more here than elsewhere: `upgradeMilestones`/`upgradeToMilestone` are `AbstractSimulator` methods, so any milestone ModelManager needed would have to be implemented by every downstream simulator.
- `calibrations` already carried a `datetime`, so only `provenance_id` is added to it — and a calibration created before this change therefore still reports `mm:created` (synthesized from the column it always had) while reporting no provenance, exactly as objects predating the tagging upgrade do.
- `createCalibration` writes its stamp in the same `"yyyy-mm-ddTHH:MM:SS"` form as every other table. It used a space separator until the column was first read back; `_normalizeStamp` special-cases only the 10-digit legacy `trials` format, so the old spelling would have surfaced `mm:created` in a different shape for calibrations alone.
- Sensitivity analyses stamp `mm:method` on their sampling; calibration stamps `mm:method` on the *run* (the method type, e.g. `"ABCSMC"`, so the key reads the same way across both) and `mm:calibration`/`mm:generation` on each batch sampling. The `calibrations.method` column keeps its own human-facing spelling (`"ABC-SMC"`).
- Simulator version is deliberately **not** tagged: it is already a foreign-keyed column on every row via `simulatorVersionTableName`/`resolveSimulatorVersionID`, which the downstream simulator package owns.

*Retrieval*
- `findSimulationIDs(; tags, any_of, status, inherit=true)` returns sorted IDs; `findSimulations` returns constructed objects; `findMonads` works one level up; `findTrials(T; ...)` dispatches on type — `Simulation`, `Monad`, `Sampling`, `Trial`, or `Calibration`.
- **Calibration-class tags do not inherit downward** (v1 decision). Inheritance is resolved at query time and only downward, by walking Trial→Sampling→Monad→Simulation; a `Calibration` is not on that chain, and `_inheritedIDs(::Type{Calibration}, …)` returns `Int[]` so `inherit=true` is a no-op for it rather than an error. The route to a run's monads is the `mm:calibration` tag every generation's sampling already carries: `findMonads(tags = ("mm:calibration" => "42",))`. Real inheritance would require the finders to traverse a new edge whose parent/child mapping lives in per-generation CSVs on disk, and would duplicate a route that already works.
- The tags are nevertheless the *more durable* of the two records, which is the reason to prefer tagging the run for anything worth keeping: tag rows die with the object they point at, and a sampling all of whose monads were deleted is itself deleted — so a batch's `mm:calibration` tag can vanish with the work it described. The `calibrations` row is never removed by a monad cascade.
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

- **Discrete parameters are represented as `DiscreteUniform` over their value indices.** This is internal — a user passes a `DiscreteVariation` and never sees the distribution — but it is what makes the grid and CDF sampling paths agree. Storing the raw value list with `first` as the map made the CDF path (`LHSVariation`, `SobolVariation`, `RBDVariation`, and therefore every `GSAMethod`) yield the *index* rather than the value, and produced an out-of-range index at `cdf = 1.0`. The same representation is what lets ABC-SMC accept a discrete parameter, since its kernels work purely in [0,1] CDF space and the quantile does the quantising.
- **`size(lv)` reports support cardinality, or `-1` when a latent parameter cannot be enumerated.** `GridVariation` checks for that sentinel. The test is `DiscreteUnivariateDistribution` with finite bounds, not finite bounds alone: `Uniform(0,1)` is finitely *bounded* but not finitely *enumerable*, so the grid must keep rejecting it.

## Feature: Global Sensitivity Analysis

**One-line description:** Run MOAT, Sobol', and RBD sensitivity analyses on any scalar output function.

**Priority:** Must-have

**Behavioral specification:**
- `MOAT`, `Sobolʼ` (`SobolMM`), and `RBD` are subtypes of `GSAMethod`.
- `run(method, inputs, avs; functions, kwargs...)` creates the sampling design, runs simulations, computes indices for each function in `functions`, and records the scheme to CSV.
- `functions` is a `Vector{Function}` where each `f(simulation_id) -> Real`. Values are averaged over a monad's replicates by the library, unlike calibration's `summary_statistic`, which is per-monad and aggregates however the user chooses.
- `kwargs` are forwarded to `run(::Sampling; ...)`.
- `run(method, problem::CalibrationProblem; functions, kwargs...)` runs the analysis over a calibration problem's parameters and base model, so one study definition serves both workflows. It takes `inputs`, the parameters, `n_replicates` and `reference_variation_id` from the problem; `observed_data`, `summary_statistic` and `distance` are unused, since a sensitivity analysis has no observation to compare against.
- `ParsedVariations(problem::CalibrationProblem)` is the conversion behind that entry point, and is lossless: both workflows normalize through the same `LatentVariation` factories and the problem retains each parameter's latent variation. The reverse direction is deliberately absent — it would lose a `DistributedVariation`'s display name, which the generation CSVs are keyed by.

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
- **One folder per generation.** A calibration's artifacts live at `generations/{t}/` — `particles.csv`, `cdfs.csv`, `metadata.toml`, `monads.csv`, `proposals.csv`, and the two failure records — so the generation number appears once, in the folder name, instead of in every filename. The separate `generation_cdfs/` directory is gone; those coordinates are `cdfs.csv` beside the rest.
  - **Artifacts are addressed by role, never by filename.** `_GENERATION_ARTIFACTS` maps a role to a basename, and `_generationArtifact(gen_dir, t, role)` resolves it: the folder layout first, then the historical flat layout at any padding width. This is what lets one set of call sites serve both, and it is why a calibration written by an earlier version needs no conversion before it can be read, plotted, or resumed.
  - **The folder name is zero-padded to `ndigits(max_nr_populations)`, but nothing depends on that.** `_generationIndices` parses the index, so ordering never relies on the width. Raising the cap on resume re-pads existing folders; lowering it narrows them, but only to the width the generations already on disk require, so no folder is ever orphaned.
  - **Migration runs on resume, not on read.** `_migrateGenerationLayout!` moves flat-layout artifacts into folders and re-pads folder names. It is cosmetic by construction — readers handle either layout — so a failed move is logged and skipped rather than aborting the run, and a calibration that is only plotted is read where it lies. There is no database migration: these are files under `data/outputs/`, which `upgradeMilestones` does not reach.
  - **Writes prefer an existing folder over a computed one.** A generation retried after a resume changed the cap would otherwise start a second folder and split its monad and failure records in two.
- **Calibration flows through `run`.** `run(method::ABCSMC, problem::CalibrationProblem)` starts a run and `run(calibration::Calibration[, method])` continues one, alongside `run(::AbstractTrial)` and `run(::GSAMethod, ...)`. Method-first mirrors `run(::GSAMethod, inputs, avs)`, and returning an `ABCResult` mirrors that method returning a `GSASampling`. `run(::Calibration)` is unambiguous against `run(::AbstractTrial)` precisely because `Calibration` was kept out of the containment hierarchy.
- **A resumed run only ever appends generations, so a changed setting takes effect from the next generation.** No setting is refused, because a generation is the unit of change and none can take effect part-way through one. `max_nr_populations` (a cumulative cap), the four stopping criteria, `epsilon_quantile`, `accept_overflow`, `max_evaluations` and `store_rejected` simply apply to new generations. `population_size` gives new generations the new size while earlier ones keep theirs — legal, since weights are normalised per generation, but the run ends up heterogeneous. `perturbation_kernel` is refitted from the previous generation each time, so each stays internally consistent. `cdf_grid_k` is resolved once at loop entry, so snapping applies only to new generations and bank reuse differs either side of the resume. `epsilon_schedule` is **indexed by absolute generation** (`epsilon_schedule[t-1]` behind a length guard), so one sized for the remaining generations rather than the whole run would silently fall back to `epsilon_quantile` — that case is warned about.
- `ABCSMC <: AbstractCalibrationMethod` holds SMC settings: `population_size`, `max_nr_populations`, `minimum_epsilon`, `epsilon_quantile`, `perturbation_kernel`, plus optional stopping criteria and epsilon schedule.
- `runABC(problem; kwargs...)` and `runCalibration(problem, ABCSMC(); ...)` run the full SMC loop.
- `resumeCalibration(calibration::Calibration, method=nothing; kwargs...)` resumes from saved generation files, with `resumeABC` as its ABC-specific alias. No `problem` argument required — the `CalibrationProblem` is loaded from `problem.jld2`.
  - **The entry points come in two complete pairs**, deliberately: `runCalibration`/`resumeCalibration` take the method as an argument and read like `run(::GSAMethod, ...)`, while `runABC`/`resumeABC` are the ABC-specific shorthand. Neither half of either pair is deprecated; an asymmetric surface where only one is would be the confusing outcome.
  - **A method setting passed as a keyword patches the saved method; a method *object* replaces it wholesale.** `resumeCalibration(cal; max_nr_populations=15)` keeps every other saved field, whereas `resumeCalibration(cal, ABCSMC(max_nr_populations=15))` supplies all thirteen fields, so the twelve it does not name take constructor defaults rather than the values the run used. Passing both forms at once is an `ArgumentError`.
  - **The effective settings are written back to `method.toml`** whenever they differ from what is stored, with the changed keys reported. Without this the file would describe a run that no longer matches it, and the *next* resume would silently revert to the original values.
- `mseDistance(simulated, observed)` is a family of built-in distance functions:
  - `mseDistance(::Dict{String,<:Any}, ::Dict{String,<:Any})` — mean of per-key squared errors (scalar keys) or mean squared errors (vector keys), averaged across all keys in `observed`.
  - `mseDistance(::AbstractVector{<:Real}, ::AbstractVector{<:Real})` — sum of squared differences `Σ(simᵢ−obsᵢ)²`; requires equal lengths (throws `DimensionMismatch` otherwise).
  - `mseDistance(::Real, ::Real)` — squared difference `(sim − obs)²`.
- `CalibrationProblem.observed_data` is typed `Any`; any type accepted by the user-supplied `distance` function is valid.
- `summary_statistic` may return any type accepted by `distance` as its first argument; no dict coercion is applied.
- Particle evaluations are batched per generation, not run one-by-one. Each generation proposes a batch of candidate parameter vectors, creates one `Monad` per candidate via `addVariations` + `Monad(...)`, assembles them into a `Sampling`, and calls `run(sampling; quiet=true)` — exploiting MM's parallel runner.
- **Generation 1:** proposes exactly `population_size` particles in a single batch (all are accepted, no epsilon threshold). One `Sampling` run per generation.
- **Generation t > 1:** uses iterative adaptive batching. The batch size for each round is `ceil(n_needed / acceptance_rate_est)`, where `acceptance_rate_est` is updated after each round (initialized from the previous generation's acceptance rate). Batching repeats until `population_size` accepted particles are collected; if a round overshoots, the excess is trimmed.
- The `evaluate_batch` callback in `abc.jl` takes `(t::Int, params_list::Vector{Dict{String,Float64}})`, where `t` is the generation index. For each proposal it creates a `Monad` via `_createMonadForParams` (which uses each `CalibrationParameter`'s `lv` maps to convert CDF values to target `DiscreteVariation`s), records all monad IDs to `{t}/monads.csv` **before** running simulations (crash safety), assembles a `Sampling`, calls `run(sampling; quiet=true)`, and returns `Vector{Tuple{Float64,Int}}` (distance, monad_id) in proposal order.
- Per-generation results are saved in two forms. **Human-readable:** `generations/{t}/particles.csv` (columns: user-friendly parameter display names, `weight`, `distance`, `monad_id`) and `generations/{t}/metadata.toml` (generation-level metadata: `max_epsilon_accepted`, `epsilon_threshold` when the generation had one, `acceptance_rate`, `ess`, `n_evaluations`). **Machine-readable (resume):** `{t}/cdfs.csv` (raw CDF coordinates + `weight`, `distance`, `monad_id`). `NNN` is zero-padded to `ndigits(max_nr_populations)`.
- Display column names in `generations/` CSVs use `variationName(dv)` (user-supplied or `shortVariationName`-derived) rather than raw DB column names (`columnName(target)`). The mapping from display names to DB column names is written to `parameters.toml` for human inspection without loading Julia.
- `runABC`/`runCalibration` write three persistence files to the calibration folder: `method.toml` (ABCSMC settings), `problem.jld2` (full `CalibrationProblem` serialized via JLD2), `parameters.toml` (display-name → DB-column mapping + prior strings).
- `resumeABC` checks stopping criteria against already-completed generations before starting the loop (handles the case where the run already finished and `resumeABC` is called again).
- The `calibrations` table is created as standard infrastructure in `createSchema()`.
- `posterior(result::ABCResult)` returns `(df, weights)` where `df` has one column per parameter in display format (CDF coords converted to target values). `posterior(calibration::Calibration)` reads from the `generations/` disk CSV and returns the same shape, useful after a session restart when only the ID is available.

*A calibration run as coalesced `Sampling` views*

- **A calibration is not a level of the trial hierarchy, and `Calibration` is not an `AbstractTrial`.** Containment runs batch → generation → calibration, one level deeper than the four levels, because the batch loop (`while length(accepted) < population_size`) constructs a `Sampling` per batch and a generation is generally several. Those groupings *overlap* — a monad belongs to its batch's sampling, its generation, and the run at once — which a strict chain cannot express, since a `Sampling`'s constituents are `Monad`s and never other `Sampling`s. Subtyping `AbstractTrial` would additionally make `run(::AbstractTrial)` dispatch on a `Calibration` and call `prepareTrialHierarchy` on it.
- What makes views legal is the `Sampling` guarantee itself: all constituent simulations share input folders. Every monad of a calibration is built from one `CalibrationProblem`'s `inputs`, so *any* subset of them is a valid sampling.
- `Sampling(calibration)` and `Sampling(calibration, generation)` build a `Vector{Monad}` and hand it to the existing find-or-insert `Sampling(monads, inputs)`. `inputs` is taken from the first monad rather than loaded from `problem.jld2`: the inner constructor already asserts every monad's `inputs` agree, so the cheap route is the checked one.
- Matching is on the **exact** monad set (`symdiff(...) |> isempty`), which is what makes coalescing safe: asking for the same view twice returns the same row rather than accumulating duplicates. When a view's monads are exactly one batch's — a run that converged in a single generation of a single batch — the view *is* that batch's sampling, the same property seen from the other side.
- **Views are built lazily and materialize only on demand.** Because matching is exact-set, building the run-wide view mid-run records a row for the partial monad set that the finished run will not reuse. The accessors are therefore pure reads that insert nothing: `monadIDs(calibration)`, `monadIDs(calibration, generation)`, `simulationIDs(calibration)`, `simulationIDs(calibration, generation)`. Only the `Sampling` constructors insert. The caveat is documented rather than gated: there is no completion flag on the `calibrations` row, and the only available heuristic — generation count against `max_nr_populations` — misreports every run that stopped early on a convergence criterion, which is the normal successful ending.
- **Views exclude monads that no longer exist.** `Monad(id)` throws for a deleted monad and the runner deletes a monad that loses every simulation, so without a survival filter a run with any total monad failure could not be viewed at all. `calibrationMonadIDs` returns the raw on-disk record (which may name deleted monads); `monadIDs(calibration)` returns the surviving subset, filtered against `monadIDs()` in one query.
- `calibrationMonadIDs` matches `^generation_(\d+)_monads\.csv$` rather than testing `endswith(f, "_monads.csv")`, which also matched `{t}/failed_monads.csv` — folding the deleted monads back in. It sorts on the generation number parsed from the name, not on the name, because the zero-padding is `ndigits(max_nr_populations)` and a resume with a larger `max_nr_populations` writes wider names into the same directory (`generation_10_…` precedes `generation_9_…` lexicographically). It also dedupes: a monad reused from the bank is recorded in every generation that evaluated it.
- Ordering is by generation, ascending by ID within a generation. Not evaluation order: the record is written through `compressIDs`, which sorts as it writes, so within-generation proposal order is not recoverable from it.
- Generations stay **views, not objects** (v1 decision). `Sampling(calibration, t)` gives a generation an object but no identity — no row, no stable ID, nowhere to hang a tag. That is what `posterior` and the plot recipes need. Giving each generation a `Trial` row over its batch samplings would make the find-or-insert `trialID(::Vector{Sampling})` load-bearing and inherit its concurrency caveat; a `Generation` type would need a sixth `TAG_CLASSES` member and its own table.

*Read path and deletion*

- `calibrationsTable(; tags=false, include_auto_tags=false)` returns one row per run with columns `CalibrationID`, `DateTime`, `Method`, `Description`, plus ID-vector and `Calibration` argument forms; `printCalibrationsTable` pairs with it as `printMonadsTable` does with `monadsTable`. `provenance_id` is dropped from the output on purpose — provenance is presented as `mm:` keys, never as a raw row id. An empty result returns a correctly-shaped empty `DataFrame` rather than a column-less one. No `limit` keyword: nothing here materializes objects, matching `simulationsTable`/`monadsTable`.
- Until this existed nothing in `src/` `SELECT`ed from the `calibrations` table at all, which made `description` write-only.
- `Base.show(::IO, ::Calibration)` prints the id, creation time, method, description (omitted when empty), completed generation count, and final ε — the last two read from `generations/{t}/metadata.toml`. It never throws: an uninitialized project prints the bare id, an id with no row says so, and a malformed TOML is skipped. The struct validates nothing, so `Calibration(999999)` is constructible and must display.
- `deleteCalibration(ids; delete_subs=false)` deletes the row, its tag rows, and `data/outputs/calibrations/{id}` via `rm_hpc_safe`. Monad IDs are collected *before* anything is removed, because the per-generation CSVs inside that folder are the only record of which monads the run evaluated. `delete_subs` defaults to `false` — the opposite of the trial-level deleters — because a calibration's monads are not its private property: the `SimulationBank` reuses monads across runs and `use_previous=true` means a monad may predate the calibration entirely. This matches the conservative choice `simulationFailed` already makes.
- The three new exports are `calibrationsTable`, `printCalibrationsTable`, and `deleteCalibration`. `calibrationFolder`, `calibrationsDir`, and `calibrationMonadIDs` stay internal; `monadIDs`/`simulationIDs` are the public accessors. All of it lives in `src/calibration/calibration.jl` rather than `database.jl`/`deletion.jl`, since a `::Calibration` argument in a signature is evaluated at definition time and both those files load first.

- `GenerationResult` stores `acceptance_rate` (all proposals passing epsilon / all proposals evaluated — **not** capped at `population_size`; overshoot in the final batch does not bias the rate downward), `ess` (= 1/Σwᵢ²), `n_evaluations`, `max_epsilon_accepted` and `epsilon_threshold` per generation. These are logged after each generation and saved to `generations/{t}/metadata.toml`.
- **Console progress reporting.** `runABC`, `runCalibration`, and `resumeABC` accept `progress::Symbol=:auto` controlling console feedback during a run. Levels stack: `:none` (silent) < `:generation` (one `@info` when each generation starts and finishes) < `:batch` (adds one `@info` per evaluation batch, numbered within the generation) < `:bar` (adds a live `ProgressMeter.jl` bar per batch, sized to that batch's pending simulations and advancing as each simulation completes). `:auto` resolves to `:bar` when `stdout` is an interactive TTY and `:generation` otherwise, so SLURM/redirected logs receive clean textual milestones rather than carriage-return bar output. The setting is runtime-only (not persisted to `method.toml`). The bar is driven by a generic, default-`nothing` `on_progress` hook on `run` that emits `:init`/`:step`/`:finish` events; when `on_progress === nothing` the runner is byte-for-byte unchanged, keeping the per-simulation completion loop framework-agnostic. Generation-start milestones report the target ε (for `t > 1`) and `population_size`; the existing generation-finish summary and stopping-reason lines are gated to `:generation` and above (so `:none` is fully silent). Verbosity helpers (`_resolveVerbosity`, `_verbosityRank`, `_logGenerationStart`, `_logBatchStart`, `_batchProgressCallback`) live in `src/calibration/progress.jl`. Because `Sobol.next!` is already in scope, ProgressMeter is brought in as a qualified `import` (not `using ... : next!`) to avoid shadowing the Sobol iterator.
- `ABCSMC` supports additional stopping criteria: `min_acceptance_rate` (stop when accepted/proposed < threshold), `min_epsilon_decrease` (stop when relative ε decrease < tol), `min_ess_fraction` (stop when ESS/N < fraction). All default to `0.0` (disabled).
- **Two epsilons, named apart.** `max_epsilon_accepted` is the largest distance a generation accepted; `epsilon_threshold` is the cutoff it was run against. They are not the same number — the threshold for generation `t` is `max(minimum_epsilon, quantile(prev.distances, epsilon_quantile))`, so at the default quantile of `0.5` it is the *median* of the previous generation's accepted distances while `max_epsilon_accepted` is the *maximum*. They coincide only when `epsilon_quantile == 1.0`. Generation 1 has no threshold, so `epsilon_threshold` is absent for it.
- **Every evaluated proposal's distance is recorded** in `generations/{t}/proposals.csv` (`monad_id`, `distance`, `accepted`), written unconditionally. A separate file rather than extra rows in the display CSV, because `posterior(::Calibration)` reads that one and strips exactly `weight`/`distance`/`monad_id` — rejected rows there would return as posterior samples with meaningless weights. `accepted` means "passed ε", not "reached the posterior": with `accept_overflow=false` a particle can pass ε and still be dropped for overshooting `population_size`, so `sum(accepted)` equals `n_accepted_total` and may exceed the posterior's row count. `missing` distances are omitted — they mean the monad had no successful simulation, and those IDs are already in the failed-monads file. Unrelated to `store_rejected`, which holds CDF coordinates in memory for the `:transition` plot.
- **Older generation metadata is upgraded on read.** Runs that recorded a single `epsilon` are still readable by every consumer, and `_loadGenerations` — the resume path, which already writes into that folder — rewrites the file to the current key names and reports it once with a warning. The rewrite is write-then-rename, and a read-only filesystem warns and continues rather than failing the resume. `epsilon_threshold` stays absent for those generations because it was never recorded; it is not inferred.
- `ABCSMC` supports an optional `epsilon_schedule::Union{Nothing,Vector{Float64}}`: when provided, generation `t` uses `epsilon_schedule[t-1]` instead of the adaptive quantile rule.
- `ConvergenceSummary(result::ABCResult)` and `ConvergenceSummary(cal::Calibration)` construct a per-generation convergence table with columns `t`, `max_epsilon_accepted`, `epsilon_threshold`, `acceptance_rate`, `n_accepted`, `ess`, `ess_fraction`, `n_evaluations` — one row per completed generation. The `Calibration` form loads from on-disk TOML metadata files. `ess_fraction = ess / n_accepted` (weight quality of the actual accepted set); the ESS stopping criterion uses `ess / population_size` (whether the effective count meets the target).
- **Parent selection uses systematic resampling** (Kitagawa 1996). For each adaptive batch of `n_to_propose` proposals, `_systematicResample(prev.weights, n_to_propose)` draws all parent indices at once with a single `u ~ Uniform(0, 1/n)`, placing `n` evenly-spaced points on the weight CDF. Each parent appears exactly ⌊n·wᵢ⌋ or ⌈n·wᵢ⌉ times — strictly lower variance than `n` independent draws. Any perturbed proposal that falls outside the prior is dropped; if the pass yields fewer than `n_to_propose` valid proposals, the loop calls `_systematicResample` again for the remainder with a fresh `u`.
- **Failed simulations during calibration.** After each batch runs, `evaluate_batch` classifies its simulations via `_batchOutcome`, which compares the pre-run snapshot of every monad's simulation IDs against their current `status_code_id` (one `_simulationStatusIDs` query per batch) and returns three sorted ID vectors: simulations now marked `Failed`, monads with at least one such simulation, and monads with **no** `Completed` simulation. The snapshot must be taken *before* the batch runs: when every simulation in a monad fails, the runner marks each `Failed`, erases it from the monad's constituent list, and deletes the emptied monad (`simulationFailed` → `eraseSimulationIDFromConstituents` → `deleteMonad`), taking with it the constituent CSV that is the only monad→simulation mapping (the `simulations` table stores input/variation IDs, not monad membership).
  - **Failures are recorded per generation**, in the same compressed-ID format as `{t}/monads.csv`: `generations/{t}/failed_simulations.csv` and `generations/{t}/failed_monads.csv`, both written through `_appendCompressedIDs` so successive batches accumulate into one deduplicated, sorted record. `_recordBatchFailures` writes nothing when a batch had no failures. `_warnFailuresRecorded` warns **once per generation** (tracked in a `Set{Int}` owned by the `_buildEvaluateBatch` closure) naming both files; later batches in that generation add to them silently. Silent at `progress=:none`. This replaces any reliance on the runner's own low-success notice, which `quiet=true` suppresses.
  - **A monad with no successful simulation has no output for `summary_statistic` to read**, so it is never handed to user code. `runABC`, `runCalibration`, and `resumeABC` accept `on_monad_failure::Symbol=:reject` (validated up front; `ArgumentError` on anything but `:reject`/`:error`). `:reject` gives the particle a distance of `missing`, so ABC-SMC never accepts it and the run continues; `:error` stops the run via `_throwNoSuccessfulSimulations`, naming the monad, the two failure files, and the simulations' own output folders (which survive their monad, since `deleteMonad` is called with `delete_subs=false`).
  - **`missing` is the failure signal, not a sentinel distance.** `evaluate_batch` returns `Vector{Tuple{Union{Float64,Missing},Int}}`; `missing` means no distance exists for that particle, which is categorically different from any value a user's `distance` may return — `Inf` included. Generation 1 drops `missing` particles before ε is set; later generations reject them with an explicit `!ismissing(distance) && distance <= epsilon` guard (an unguarded `missing <= epsilon` evaluates to `missing`, which throws when used as a condition). `_ParticleResult.distance` and `GenerationResult.distances` stay `Float64`, since only accepted particles reach them.
  - **Partially failed monads are evaluated normally** from whatever succeeded; their failed simulations are still recorded. Re-running to "top off" the missing replicates is deliberately not attempted — it risks spinning for a long time chasing the last few successes.
- **User-supplied functions must produce a `Real`.** `_evaluateParticle` wraps the `summary_statistic` → `distance` pair for monads that *do* have a successful simulation. Because output exists, any failure there is a fault in the user's functions rather than a simulation failure, and is fatal regardless of `on_monad_failure`: an exception is logged with the monad ID (and, when non-zero, the count of that monad's failed simulations, the likeliest reason otherwise-correct code trips) and then rethrown with `rethrow()` so the original backtrace survives; a `distance` return value that is not a `<:Real` raises immediately, naming the offending type. This is what stops a `missing`/`nothing` from propagating into the ABC-SMC internals and surfacing much later as an unrelated `MethodError`.
- **Generation 1 and failed monads.** Generation 1 has no epsilon threshold and accepts every proposal, setting `max_epsilon_accepted = maximum(distances)` and leaving `epsilon_threshold` absent. `_acceptFirstGeneration` drops `missing`-distance proposals before the result is built, warns how many were dropped, and renormalizes the uniform weights over the survivors; `n_evaluations` still counts every proposal while `n_accepted` counts only survivors, so the acceptance rate stays honest. It errors when *no* monad succeeded — a whole generation of failed monads is a broken model, not sampling noise. Rejected particles are not replaced, so generation 1 holds fewer than `population_size` particles whenever a monad failed. Later generations need no such handling: a `missing` distance is rejected outright, and a generation whose batches all fail keeps proposing (bounded by `max_evaluations`) rather than aborting, so one bad monad in a small batch cannot kill a run. A non-finite ε is **not** treated as an error: `Inf` is a value a user's `distance` may return, and the run recovers on its own — generation 2 accepts every proposal (a second uniform draw in CDF space) and the usual quantile rule then pulls ε back to a finite value. `Inf` also round-trips through `method.toml`/generation TOML as `+inf`, so resume is unaffected.
- **Reusability rule for monad IDs.** `_monadsWithStartedSimulations(monad_ids)` returns those with at least one simulation whose status is `Running` or `Completed`, in a single status query. The bank exists to snap onto nearby work that is already (partly) done, so three cases are excluded: a monad whose simulations are all `Not Started` (nothing to reuse, and it would be re-proposed and rejected every generation); a monad whose simulations all failed — the runner deletes such a monad, and `constituentIDs` reports no simulations for it, so it fails the test without a separate existence check; and a monad that is absent for any other reason. Applied in two places:
  - `_buildSimulationBank` as admission criterion 5, filtering the bank at load time. This also closes a hazard: a bank monad whose only simulation was `Not Started` could be scheduled, fail, and be deleted mid-generation, after which a **later batch in the same generation** would receive its now-dangling ID as a `known_mid` and `Monad(known_mid)` would throw.
  - `_updateMidGenAdditions!` for monads evaluated during the run, so a monad deleted this generation never enters the bank. The test is on the monad's own database state rather than on the particle's distance, so a legitimately infinite distance returned by a user's `distance` function does not silently bar a good monad from reuse.

  `_updateMidGenAdditions!` is now called only when snapping is active (`snap_active`): `mid_gen_additions` feeds the bank, which is consulted only then, and the reusability test costs a query per batch. Without an initialized project the test treats every ID as reusable, since there are no statuses to consult — the algorithm-level tests drive `_runABCSMC` with mock monad IDs and no database.

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

  - **Proposal distances** — `plot(result, :distances)` or `plot(Calibration(id), :distances)`. Histogram of every proposal a generation evaluated, with the accepted ones coloured separately and the threshold drawn on a bin boundary. Bin edges are computed by the recipe, not the backend: the rejected distances extend well past the accepted ones, so per-series auto-binning would misalign the very boundary the plot is about. Accepted and rejected bars are provably disjoint — acceptance is `distance <= ε`, so a distance equal to ε is constrained to the last accepted bin rather than the first rejected one. `logscale=true` bins in log10 and drops non-positive distances, reporting how many.
  - **Convergence trace** — `plot(ConvergenceSummary(result))` or `plot(ConvergenceSummary(Calibration(id)))`. Three panels sharing a generation axis: epsilon, acceptance rate, and ESS fraction. Diagnoses convergence rate and algorithm efficiency.

  - **Generation transition plot** — `plot(result::ABCResult, :transition; generation=t, show_particles=false, space=:target, aggregate_duplicates=true)`. For generation `t` (default: `length(result.generations) - 1`, the last complete gen→gen+1 transition; requires ≥ 2 generations), renders the gen-t posterior KDE with gen-(t+1) proposal points overlaid: **accepted** in green, **rejected** in red. Default space is **target-parameter** (biological quantities for `DVSource`/`CVSource`, latent values for `LVSource`); `space=:cdf` switches to ABC CDF coordinates. When `GenerationResult.rejected_proposals === nothing` (the default with `store_rejected=false`), performs a lazy disk lookup: loads all evaluated monad IDs from `generation_{t+1}_monads.csv`, subtracts accepted IDs, fetches target-parameter values via `simulationsTable`. For `space=:cdf`, additionally inverts target→CDF via each parameter's prior CDF — requires all parameters to have inverse maps; `LVSource` parameters without user-supplied inverse maps cause the lazy lookup to be skipped (accepted-only, with title note). Also falls back to accepted-only if the monads file is absent. Layout: `d × d` corner-plot panels.
    - *Diagonal panels*: 1D KDE curve (gen t) + stacked strip chart below x-axis — accepted ticks point up (green), rejected ticks point down (red); duplicate proposals at the same position stack vertically so height = count.
    - *Off-diagonal panels*: 2D KDE contour (gen t) + aggregate bubble scatter. Accepted bubble area ∝ aggregate weight; rejected bubble area ∝ count × `w_ref` (where `w_ref = 1/population_size`), giving a common size scale. `aggregate_duplicates=false` shows individual translucent points (alpha=0.3) — coincident points saturate darker.
    - `show_particles=true` additionally renders gen-t particles as small grey rug marks beneath the KDE.

  `store_rejected::Bool = false` on `ABCSMC`: when `true`, each `GenerationResult` populates `rejected_proposals::Union{Nothing,DataFrame}` — a CDF-coordinate DataFrame of all rejected proposals (same column names as `particles`; converted to target space at plot time). Not persisted to disk; loaded as `nothing` on resume (lazy disk fallback used instead). Always `nothing` for generation 1 (all Sobol proposals are accepted).

  *Accessor functions (exported):*
  - `latent_params(result::ABCResult; generation=:final)` → particle DataFrame in CDF-coordinate space
  - `target_params(result::ABCResult; generation=:final)` → particle DataFrame in target-parameter space

- **Evaluation budget — `max_evaluations`**: `max_evaluations::Union{Nothing,Int} = nothing` on `ABCSMC`. Caps total evaluated particles (monads) across the entire calibration run — one count per proposal sent to `evaluate_batch`, regardless of whether the monad was already in the DB or was a fresh simulation. `_runABCSMC` initializes a shared `budget::Ref{Int}` counter and `budget_hit::Ref{Bool}` flag, then passes them to both generation runners. The budget is enforced **before each batch is dispatched**: `_capBatchToBudget(proposals, budget, max_evaluations)` trims a planned batch to the remaining allowance (`max_evaluations - budget[]`) so the run never evaluates more than `max_evaluations` simulations — including generation 1, which is trimmed when the budget is smaller than `population_size`. After dispatch, `_updateBudget!(budget, budget_hit, n, max_evaluations)` increments `budget[]` by the dispatched count and sets `budget_hit[]` when the budget is reached; an empty trimmed batch also sets it. After each generation, `_stoppingReason` checks `budget_hit` first (before all other criteria) and returns `"max_evaluations=N reached"` when true; the current generation's accepted particles are saved before stopping. Log level is `@info`. `nothing` disables the safeguard (default). This is the ultimate backstop for overaggressive `epsilon_schedule` runs and for snapping runs with difficult-to-reach grid regions. Persisted to `method.toml`.

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
  5. At least one simulation has status `Running` or `Completed` (see the reusability rule above). A monad whose simulations have not started has nothing to reuse, and one whose simulations all failed no longer exists.

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
- The `calibrations` table exists after `createSchema()` with columns `calibration_id`, `datetime`, `description`, `method`, `provenance_id`.
- `Sampling(calibration)` twice returns the same `sampling_id`; on a multi-generation run it differs from every batch `sampling_id`, while on a single-batch run it *is* the batch's row and adds none.
- `monadIDs(Sampling(calibration, t)) ⊆ monadIDs(Sampling(calibration))`, their union over all generations equals the run-wide set, and `simulationIDs(calibration)` equals the union of the batch samplings' simulation IDs.
- With a monad forced to lose every simulation, its ID appears in `calibrationMonadIDs` but not in `monadIDs(calibration)`, and both views still build.
- `Sampling(calibration, 99)` on a run with no generation 99 throws an `ArgumentError` naming the generations that exist.
- The accessors add no `samplings` row; only the `Sampling` constructors do.
- `calibrationsTable()` has exactly the columns `CalibrationID`, `DateTime`, `Method`, `Description`, one row per run, and reads back the `description` passed to `runCalibration`; its `DateTime` matches `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$`.
- `deleteCalibration` removes the row, its tags, and its folder while leaving the monads and simulations intact; with `delete_subs=true` it removes those too.
- `plot(result)` (corner pairs plot), `plot(result, :ridgeline)`, `plot(ConvergenceSummary(result))`, and `plot(result, :transition)` all produce plots without error on a completed `ABCResult` with ≥ 2 generations.
- `_validateInverseMaps(lv)` passes for auto-constructed DV/CVSource inverse maps; user-supplied LVSource inverse maps are checked at construction time.
- `generation_cdfs/` is always a subdirectory of `generations/`; `_loadGenerations` finds files regardless of zero-padding used during the original run.
