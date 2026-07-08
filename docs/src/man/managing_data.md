```@meta
CurrentModule = ModelManager
```

# Managing data

Over a long campaign you accumulate simulations you no longer need — failed runs, abandoned
sweeps, stale parameterizations. ModelManager provides targeted deletion at every level of the
[trial hierarchy](@ref "The trial hierarchy") and a full project reset, all keeping the database
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

Deletions also keep the [post-processing sink](@ref "Post-processing each simulation")
consistent: a deleted simulation's stored quantities are removed from
`data/outputs/postprocessing.db` (cascading deletes route through `deleteSimulations`, so they
are covered too).

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

The deletion helpers remove output directories with [`rm_hpc_safe`](@ref) rather than `rm`, so
they tolerate the transient `unlink` failures common on shared HPC filesystems. If you write
your own cleanup code in a ModelManager workflow on a cluster, prefer `rm_hpc_safe` for the
same reason (see [HPC support](@ref)).

See the [Deletion](@ref) API reference for full signatures.
