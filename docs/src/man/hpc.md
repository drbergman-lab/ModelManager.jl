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

When HPC mode is active, the runner submits each simulation's command to `sbatch` instead of
spawning a local process. From your script's perspective nothing changes — you still call
[`run`](@ref) on a trial; the runner decides per-simulation whether to execute locally or
submit a job.

Each job still writes its own `output.log` and `output.err` into that simulation's output folder,
and `setNumberOfParallelSims` still bounds how many jobs sit in the queue at once.

## How completion is detected

Jobs are submitted with `--parsable` rather than `--wait`. Each job's script records its exit code
in a sentinel file whose name was chosen before submission, and the worker that submitted it waits
for that one file — a `stat` a second. `squeue` is consulted only as a reaper, for jobs killed by
the scheduler (out of memory, time limit, node failure) or cancelled before they started, which
never get the chance to write anything — and only through one answer shared by every waiting
worker, so the scheduler sees one query per interval however many jobs are in flight.

This matters on a shared cluster. `sbatch --wait` is a poll, not a callback: each waiting `sbatch`
queries the controller on a 2-to-32-second cycle, so one waiter per simulation put load on
slurmctld proportional to your parallelism — and worst for short simulations, because every waiter
restarts that cycle at two seconds.

Tune it with [`setHPCCompletionOptions`](@ref):

```julia
setHPCCompletionOptions(
    done_dir = "/scratch/\$(ENV["USER"])/mm_done",  # sentinels only — not your data/
    poll_interval = 1.0,     # seconds between a worker's checks for its own sentinel
    reap_interval = 300.0,   # how long one squeue answer is shared before it is refreshed
    grace_period  = 270.0,   # how long a vanished job may take to produce its sentinel
)
```

The one setting worth knowing about is `done_dir`. NFS caches directory attributes for 30–60
seconds by default, which delays how quickly a sentinel written on a compute node becomes visible
to your driver. Lustre and GPFS have no such delay. If your project lives on NFS and you want
faster turnaround, point `done_dir` at a faster filesystem — **only the sentinel directory needs to
move; your `data/` can stay where it is.** Sentinels live for seconds and are consumed and deleted,
so a purge policy on scratch cannot harm them.

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
