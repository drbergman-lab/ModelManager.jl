# Product Requirements Document — ModelManager.jl

> **Purpose:** This document defines the complete feature set of ModelManager in behavioral terms. It is the authoritative answer to "what should this system do?" Read this at the start of any feature session to establish alignment between intent and implementation plan.

---

## Product Overview

**Vision:** ModelManager provides simulator-agnostic ABM infrastructure so that any Julia-based agent-based modeling framework can inherit a complete simulation management stack — parameter variation, space-filling designs, sensitivity analysis, database provenance, and HPC support — without reimplementing it.

**Target Users:** Julia package authors building simulator-specific frontends (e.g. PhysiCellModelManager.jl, BergiCell.jl).

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
- `runSimulation(sim, simulation, monad_id; do_full_setup, force_recompile)` → `SimulationProcess`
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

---

## Feature: Simulation Runner

**One-line description:** Execute pending simulations in parallel (local or HPC) and track results in the database.

**Priority:** Must-have

**Behavioral specification:**
- `run(T::AbstractTrial; force_recompile, kwargs...)` collects simulation tasks, executes up to `mm_globals().max_number_of_parallel_simulations` concurrently, and returns `MMOutput{T}`.
- `kwargs` are forwarded to `postSimulationProcessing` (simulator-specific cleanup/pruning).
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
