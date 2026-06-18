```@meta
CurrentModule = ModelManager
```

# HPC support

ModelManager can dispatch each simulation as a SLURM job instead of a local task, so the same
script that runs on a laptop scales to a cluster without modification.

## Detection

[`isRunningOnHPC`](@ref) returns `true` when the `sbatch` command is available on the
`PATH`. [`initializeModelManager`](@ref) checks this at startup and stores the result; when
SLURM is detected, the runner submits each pending simulation as a job rather than running it
in a local task.

You can override the auto-detected value with [`useHPC`](@ref):

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
(see [`prepareHPCCommand`](@ref) and [`prepCmdForWrap`](@ref) in the runner) instead of
spawning a local process. From your script's perspective nothing changes — you still call
[`run`](@ref) on a trial; the runner decides per-simulation whether to execute locally or
submit a job.

## Filesystem safety on shared clusters

Some shared filesystems intermittently fail or delay `unlink`/`rm` operations. Use
[`rm_hpc_safe`](@ref) instead of `rm` when removing files inside ModelManager workflows on
HPC; it tolerates these transient failures. [`resetDatabase`](@ref) and the deletion helpers
use it internally (see [Managing data](@ref)).

See the [HPC support](@ref) API reference for the full set of functions.
