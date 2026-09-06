```@meta
CurrentModule = ModelManager
```

# [Managing data](@id managing_data)

Over a long campaign you accumulate simulations you no longer need — failed runs, abandoned
sweeps, stale parameterizations. ModelManager provides targeted deletion at every level of the
[trial hierarchy](@ref trial_hierarchy) and a full project reset, all keeping the database
and filesystem consistent.

## Deleting by level

Each level has a deletion function that, by default, also cleans up the levels it depends on:

```julia
deleteSimulations([12, 13, 14])   # delete specific simulations
deleteSimulation(12)              # singular alias
deleteAllSimulations()            # every simulation in the project

deleteMonad([5])                  # delete monads (and, by default, their simulations)
deleteSampling([3])               # delete samplings
deleteTrial([1])                  # delete trials
```

The `delete_subs` / `delete_supers` keywords control how far the cascade reaches:

- `delete_subs` (default `true`) — also delete the constituent (lower-level) entities.
- `delete_supers` (default `true`) — also delete the containing (higher-level) entities that
  would be left incomplete.

[`deleteSimulations`](@ref) additionally accepts `filters` to restrict which rows are removed.

Deletions also keep the [post-processing sink](@ref post_processing)
consistent: a deleted simulation's stored quantities are removed from
`data/outputs/postprocessing.db` (cascading deletes route through `deleteSimulations`, so they
are covered too).

## Deleting a calibration run

[`deleteCalibration`](@ref) removes a calibration's record, its tags, and its output folder:

```julia
deleteCalibration(3)                      # keep every monad it evaluated
deleteCalibration(3; delete_subs = true)  # remove the ones no one else uses
```

The default is the opposite of the levels above: `delete_subs` is `false`, because a
calibration's monads are not its private property. The simulation bank reuses monads across runs,
and a monad the calibration snapped onto may predate it entirely.

`delete_subs = true` deletes the monads **only that run used**, and their simulations. A monad
another calibration's generation record lists, or one belonging to any sampling other than the
run's own per-generation batches, is kept. The batches themselves shrink to the monads that
survive and disappear once empty.

Deleting the run does discard its posterior, since the generation CSVs and the serialized problem
live in the folder — see [Calibration](@ref calibration_man).

## Deleting by status

To clear out failed runs (the most common cleanup):

```julia
deleteSimulationsByStatus(["Failed"])           # prompts before deleting
deleteSimulationsByStatus(["Failed"]; user_check=false)
```

The status values are those from [`recognizedStatusCodes`](@ref).

## Resetting a project

[`resetDatabase`](@ref) wipes the database and all generated output, returning the project to
a clean state (input folders are preserved; simulator build artifacts are removed via the
backend's [`clearSimulatorArtifacts`](@ref) hook):

```julia
resetDatabase()                       # prompts for confirmation
resetDatabase(; force_reset=true)     # skip the prompt (scripts/CI)
```

This is destructive and irreversible — every simulation, monad, sampling, and trial is
deleted, and the post-processing sink (`data/outputs/postprocessing.db`) is removed. Use it
deliberately. [`resetFolder`](@ref) resets a single input folder's variation state without
touching the rest of the project.

## Safe removal on shared filesystems

The deletion helpers remove output directories with [`rm_hpc_safe`](@ref) rather than `rm`. Off
HPC that is exactly `rm`. On a cluster it first attempts the real removal, then *moves* anything
the filesystem refuses to release — typically a directory some other node still has a file open
in — into `data/.trash/`, and returns `:removed`, `:staged`, or `:unremoved` to say which
happened. A failure is reported rather than thrown, so one stubborn folder cannot abandon a bulk
deletion after its database rows are already gone.

Staged paths **still occupy disk and quota** — they are out of `outputs/` and out of the database,
but they have not been deleted. ModelManager retries the removal in the background each
time [`initializeModelManager`](@ref) runs, so it normally empties itself once the jobs holding
those files exit. To reclaim it now, delete the directory from a shell. If you write your own
cleanup code in a workflow on a cluster, prefer `rm_hpc_safe` for the same reason (see
[HPC support](@ref hpc)).

See the [Deletion](@ref) API reference for full signatures.
