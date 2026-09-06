"""
    shellCommandExists(cmd::Union{String,Cmd})

Check if a shell command exists in the current environment.
"""
function shellCommandExists(cmd::Union{String,Cmd})
    cmd_ = Sys.iswindows() ? `where $cmd` : `which $cmd`
    p = quietRun(ignorestatus(cmd_))
    return p.exitcode == 0
end

"""
    isRunningOnHPC()

Return `true` if the current environment is an HPC environment, `false` otherwise.

Currently checks for a SLURM environment by probing for the `sbatch` command.
"""
isRunningOnHPC() = shellCommandExists(`sbatch`)

"""
    useHPC([use::Bool=true])

Set the global `run_on_hpc` flag to `use`.

# Examples
```julia
useHPC()        # enable sbatch wrapping
useHPC(true)    # same
useHPC(false)   # run simulations locally
```
"""
function useHPC(use::Bool=true)
    #! Turning HPC mode on when it is already on means the caller is working around the
    #! pre-ModelManager-v0.9.0 bug where `run_on_hpc` was never auto-detected and stayed `false`
    #! on a cluster. `initializeModelManager` now seeds it, so the call is dead weight.
    #! The warning names ModelManager explicitly: it surfaces in a downstream package's console
    #! (PhysiCellModelManager and friends), where a bare version number reads as theirs.
    if use && mm_globals().run_on_hpc
        @warn """
        `useHPC(true)` is redundant here — HPC mode is already on.
        Before ModelManager v0.9.0 the `run_on_hpc` global was never auto-detected, so scripts \
        had to call `useHPC()` by hand to get `sbatch` submission on a cluster. ModelManager's \
        `initializeModelManager` now probes for SLURM at startup; this call can be deleted.
        """ maxlog=1
    end
    mm_globals().run_on_hpc = use
end

"""
    defaultJobOptions()

Return a `Dict` with default SLURM options. Two keys, both resolved per simulation:

- `"job-name"`: `S<simulation id>`, so a job can be found again with `sacct --name=S<id>`.
- `"cpus-per-task"`: whatever the backend's [`simulationThreads`](@ref) reports for the
  simulation; `nothing` (the default for a backend that does not implement it) omits the flag.

Everything else -- `time`, `mem`, `partition` -- is left to the site's defaults until
[`setJobOptions`](@ref) says otherwise: a memory or time default chosen here would be wrong for
most simulators, and a job that exceeds it is killed silently and takes minutes to be declared
failed.
"""
function defaultJobOptions()
    return Dict{String,Any}(
        "job-name" => simulation -> "S$(simulation.id)",
        "cpus-per-task" => simulation -> simulationThreads(mm_globals().simulator, simulation),
    )
end

#! Flags ModelManager renders itself in `_prepareHPCSubmitCommand`. A user value for one of them
#! would either be overridden or make the submission line contradict itself, so they are refused
#! when set rather than when the first job is built.
const _RESERVED_SBATCH_KEYS = ["wrap", "output", "error", "wait", "parsable", "chdir"]

"""
    HPCCompletionOptions

How the runner submits a SLURM job and learns that it has finished. Held on
[`ModelManagerGlobals`](@ref); adjust with [`setHPCCompletionOptions`](@ref).

Jobs report their exit code by writing a sentinel file to a shared directory; the worker that
submitted each job waits for its file. `squeue` is consulted only as a reaper, for jobs that died
without writing anything, through one answer shared by every waiting worker.

# Fields
- `submit_retry_period::Float64`: How long a worker keeps retrying a submission that `sbatch`
  refused for a reason that clears up on its own -- a per-user submit limit while earlier jobs
  drain, a controller that is not answering -- before giving up. Retries back off from 2 s to
  60 s. A refusal that does not look transient (a wrong partition, an invalid option, no
  `sbatch` at all) is not retried. Either way, giving up stops the run and puts the simulation
  back to `Not Started`; it is never recorded as failed, because no job ever ran.
- `done_dir::String`: Where sentinels are written. Empty means `<dataDir()>/.hpc_done`. Point it
  at a faster filesystem when the project lives on an NFS mount: NFS caches directory attributes
  for `acdirmin`/`acdirmax` (30s/60s by default), which delays how quickly a sentinel written on a
  compute node becomes visible here. Only this directory needs to move; `data/` stays where it is.
- `poll_interval::Float64`: Seconds between each waiting worker's check for its own sentinel — one
  `stat` per in-flight job per interval. This is the completion path.
- `reap_interval::Float64`: How long one `squeue` answer is shared by every waiting worker before
  it is refreshed. This is *only* the reaper, so it is deliberately long; lowering it buys nothing
  for jobs that exit normally.
- `grace_period::Float64`: How long a job may be absent from the queue with no sentinel before it
  is declared failed. Covers the lag between a compute node writing the file and this node seeing
  it, so it must exceed the filesystem's worst-case directory-attribute staleness.
"""
@with_kw mutable struct HPCCompletionOptions
    submit_retry_period::Float64 = 900.0
    done_dir::String = ""
    poll_interval::Float64 = 1.0
    reap_interval::Float64 = 300.0
    grace_period::Float64 = 270.0
end

"""
    setHPCCompletionOptions(; kwargs...)

Set any of the [`HPCCompletionOptions`](@ref) fields on the active globals.

The default worth knowing about is `done_dir`: on a project whose `data/` lives on an NFS mount,
pointing it at a faster filesystem cuts completion latency without moving the project itself.

```julia
setHPCCompletionOptions(done_dir="/scratch/\$(ENV["USER"])/mm_done")
```
"""
function setHPCCompletionOptions(; kwargs...)
    opts = mm_globals().hpc_completion
    for (key, value) in kwargs
        @assert key in fieldnames(HPCCompletionOptions) "Unknown HPC completion option: $(key). Valid options are $(join(fieldnames(HPCCompletionOptions), ", "))."
        setfield!(opts, key, convert(fieldtype(HPCCompletionOptions, key), value))
    end
    return opts
end

"""
    setJobOptions(options::Dict)

Merge `options` into the global `sbatch_options` dictionary.

Each key–value pair becomes a `--key=value` flag appended to the `sbatch` command when running
simulations on an HPC. A value that is a `Function` is called with the [`Simulation`](@ref) about
to be submitted, so an option can follow a varied parameter; returning `nothing` omits the flag
for that simulation:

```julia
setJobOptions(Dict("time" => "02:00:00", "mem" => "8G",
                   "comment" => simulation -> "monad \$(only(monadIDs(simulation)))"))
```

Keys must be `String`s. The keys ModelManager renders itself (`wrap`, `output`, `error`, `wait`,
`parsable`, `chdir`) are refused with an `ArgumentError`.
"""
function setJobOptions(options::Dict)
    for (key, value) in options
        key isa AbstractString || throw(ArgumentError(
            "sbatch option keys must be Strings naming the flag (\"time\", \"mem\", …); got " *
            "$(repr(key))::$(typeof(key))."))
        key in _RESERVED_SBATCH_KEYS && throw(ArgumentError(
            "The sbatch option `$(key)` is set by ModelManager itself and cannot be overridden; " *
            "reserved keys are $(join(_RESERVED_SBATCH_KEYS, ", "))."))
        mm_globals().sbatch_options[String(key)] = value
    end
end

#! Public despite not being exported: the manual documents it as the starting point users
#! copy and edit to configure sbatch. See CLAUDE.md, "Docstring cross-references".
@compat public defaultJobOptions

#! Public despite not being exported: it is the type of the documented `hpc_completion` field on
#! `ModelManagerGlobals` and the return of the exported `setHPCCompletionOptions`, so it appears in
#! a public signature. See CLAUDE.md, "Docstring cross-references".
@compat public HPCCompletionOptions

#! Public despite not being exported: PhysiCellModelManager depends on it at `src/movie.jl:75`.
#! See CLAUDE.md, "Docstring cross-references".
@compat public shellCommandExists
