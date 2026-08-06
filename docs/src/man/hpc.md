```@meta
CurrentModule = ModelManager
```

# [HPC support](@id hpc)

ModelManager can dispatch each simulation as a SLURM job instead of a local task, so the same
script that runs on a laptop scales to a cluster without modification.

## Detection

[`isRunningOnHPC`](@ref) returns `true` when the `sbatch` command is available on the `PATH`.
[`initializeModelManager`](@ref) probes for it at startup and stores the result in
`run_on_hpc`, so HPC mode turns itself on wherever SLURM exists. When it is on, the runner
submits each pending simulation as a job rather than running it in a local task, and file
removal goes through the staging path described below.

Override the detected value with [`useHPC`](@ref), after initializing:

```julia
useHPC(true)    # force HPC mode on
useHPC(false)   # force local execution even on a cluster login node
```

## Job options

SLURM job parameters are held in a `Dict` of `sbatch` options. [`defaultJobOptions`](@ref)
provides sensible defaults; [`setJobOptions`](@ref) merges your overrides in:

```julia
setJobOptions(Dict(
    "time"      => "02:00:00",
    "mem"       => "8G",
    "partition" => "compute",
))
```

These options are applied to every job the runner submits for the current session.

## How jobs are launched

When HPC mode is active, the runner wraps each simulation command for `sbatch` submission
(`prepareHPCCommand` and `prepCmdForWrap` in the runner) instead of
spawning a local process. From your script's perspective nothing changes — you still call
[`run`](@ref) on a trial; the runner decides per-simulation whether to execute locally or
submit a job.

## Filesystem safety on shared clusters

A network filesystem will not remove a file that a process on another node still holds open, so
`rm` fails part-way through and leaves the directory behind. [`rm_hpc_safe`](@ref) absorbs that:
it attempts the real removal first — the only thing that frees disk space — and *moves* whatever
survives into `data/.trash/`, which succeeds where removal does not because a rename never
releases the file. [`resetDatabase`](@ref) and the deletion helpers use it internally (see
[Managing data](@ref managing_data)); prefer it over `rm` in your own cleanup code too.

Anything staged this way **still occupies disk and quota** — it is out of `outputs/` and out of
the database, but it has not been deleted. The first time it happens in a project, a warning says
so and names the directory.
[`initializeModelManager`](@ref) retries the removal in the background at the start of every
later session, so staged paths normally clear themselves once the jobs holding those files
exit; `databaseDiagnostics` reports whatever is still there.

If you want that space reclaimed automatically instead, put the project's `data/` directory on
scratch — `data/.trash` then lives on scratch too and your site's purge policy sweeps it with
everything else. Pointing the staging area itself at another filesystem cannot work: moving
across mounts is a copy followed by a delete of the source, and that delete is the operation
being refused.

See the [HPC & SLURM](@ref hpc_lib) API reference for the full set of functions.
