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
    #! pre-ModelManager-v0.8.4 bug where `run_on_hpc` was never auto-detected and stayed `false`
    #! on a cluster. `initializeModelManager` now seeds it, so the call is dead weight.
    #! The warning names ModelManager explicitly: it surfaces in a downstream package's console
    #! (PhysiCellModelManager and friends), where a bare version number reads as theirs.
    if use && mm_globals().run_on_hpc
        @warn """
        `useHPC(true)` is redundant here — HPC mode is already on.
        Before ModelManager v0.8.4 the `run_on_hpc` global was never auto-detected, so scripts \
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

#! Public despite not being exported: PhysiCellModelManager depends on it at `src/movie.jl:75`.
#! See CLAUDE.md, "Docstring cross-references".
@compat public shellCommandExists
