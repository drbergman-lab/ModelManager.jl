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
