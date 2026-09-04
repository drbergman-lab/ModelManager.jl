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

Return a `Dict` with default SLURM options.

Current defaults:
- `"job-name"` — `simulation_id -> "S\$(simulation_id)"`
- `"mem"` — `"1G"`
"""
function defaultJobOptions()
    return Dict{String,Any}(
        "job-name" => simulation_id -> "S$(simulation_id)",
        "mem" => "1G"
    )
end

"""
    HPCCompletionOptions

How the runner learns that a SLURM job has finished. Held on
[`ModelManagerGlobals`](@ref); adjust with [`setHPCCompletionOptions`](@ref).

Jobs report their exit code by writing a sentinel file to a shared directory; the worker that
submitted each job waits for its file. `squeue` is consulted only as a reaper, for jobs that died
without writing anything, through one answer shared by every waiting worker.

# Fields
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

Each key–value pair becomes a `--key=value` flag appended to the `sbatch`
command when running simulations on an HPC. Values that are `Function`s are
called with the simulation ID at runtime.
"""
function setJobOptions(options::Dict)
    for (key, value) in options
        mm_globals().sbatch_options[key] = value
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
