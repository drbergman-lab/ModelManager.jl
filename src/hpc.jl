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

Set the global `run_on_hpc` flag to `use`, and keep it set across later calls to
[`initializeModelManager`](@ref).

The pinning is what makes the call worth writing in a script. `initializeModelManager` seeds
`run_on_hpc` from the SLURM probe every time it runs, and a downstream package's `__init__` may
initialize a project before your script has said anything; without the pin, re-initializing would
silently undo `useHPC(false)` on a machine that happens to have `sbatch` installed. The pin lasts
for the session and applies to every project opened in it.

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
    mm_globals().run_on_hpc_overridden = true
    #! Turning HPC mode on by hand is the other moment a user could want the driver template, and
    #! it is the only one on a machine where the SLURM probe fails. It needs a project to write
    #! into, so before initialization there is nothing to do and nothing worth saying: the flag is
    #! what the caller asked for, and the next `initializeModelManager` writes the template.
    use && isInitialized() && _writeDriverTemplate()
    return use
end

"""
    _driverTemplatePath() → String

Where the driver batch-script template belongs: `scripts/driver_template.sbatch` under the project
root if that folder exists (a downstream `createProject` makes one), else `driver_template.sbatch`
in the project root itself.

The project root is the parent of `dataDir()`, so the template lands beside the scripts a user
actually edits and runs rather than inside the `data/` tree the campaign writes into and the
deletion helpers sweep.
"""
function _driverTemplatePath()
    root = dirname(dataDir())
    scripts = joinpath(root, "scripts")
    return joinpath(isdir(scripts) ? scripts : root, "driver_template.sbatch")
end

"""
    _driverTemplateContents() → String

The text of the driver-job template, with `--project` pinned to the environment active when it is
written.

The template runs `julia --project=… "\$@"`, so the script to drive a campaign with is an argument
to `sbatch`, not part of the file: one template serves every campaign in the project.
"""
function _driverTemplateContents()
    #! Quoted because a project path can contain spaces, and the line is re-read by bash.
    project = _shQuote(string(Base.active_project()))
    return """
    #!/bin/bash
    #SBATCH --job-name=mm-driver     # so `squeue --name=mm-driver` finds this job
    #SBATCH --time=48:00:00          # must cover the WHOLE campaign -- including the queue wait of every simulation job this driver submits, since the driver sits blocked until the last one finishes
    #SBATCH --cpus-per-task=1        # the driver only submits and waits; each simulation gets its own allocation
    #SBATCH --mem=4G                 # Julia's own footprint, not a simulation's
    #SBATCH --output=driver-%j.log   # the driver's stdout, %j being the job id
    #SBATCH --error=driver-%j.err    # the driver's stderr

    # Written by ModelManager because SLURM was detected on this machine. It is a starting point,
    # not something ModelManager owns: edit it freely, it is written once and never overwritten.
    #
    #   submit:  sbatch driver_template.sbatch my_script.jl
    #   watch:   squeue -j <jobid>
    #   after:   sacct -j <jobid>
    #
    # Inside this job, HPC detection stays on and each simulation is still submitted as its own
    # job. That is the design -- SLURM schedules the simulations, ModelManager does not -- so the
    # driver itself needs no more than the single core and small memory request above.

    # module load julia   # uncomment / adjust for your site

    echo "ModelManager driver job \$SLURM_JOB_ID starting on \$(hostname) at \$(date)"

    julia --project=$(project) "\$@"

    echo "ModelManager driver job \$SLURM_JOB_ID finished at \$(date)"
    """
end

"""
    _writeDriverTemplate() → String

Write the driver-job template if it is not already there, and return its path. Announces the write
on stdout the first time; says nothing on any later call.

The Julia process that calls `run` is what records outcomes, so it should be a job itself rather
than a login-node process an SSH drop or a reaper can kill. ModelManager writes a template instead
of submitting the driver for the user: submission is a one-line `sbatch`, while what to put *above*
that line is site knowledge ModelManager does not have -- a `module load julia`, a specific Julia
version, an account or partition -- and starting Julia and a whole simulator package just to
assemble that command line would be minutes of load time to do a string substitution.

Never overwrites: after the first write the file is the user's, and the next session finding it
already edited is the normal case.
"""
function _writeDriverTemplate()
    path = _driverTemplatePath()
    ispath(path) && return path
    write(path, _driverTemplateContents())
    println("Wrote a SLURM driver-job template to $(path) — submit a campaign with `sbatch $(basename(path)) my_script.jl`.")
    flush(stdout)
    return path
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

*Where* that directory is is deliberately not one of these options. It is
`data/outputs/.hpc_done` unless the `MODELMANAGER_HPC_DONE_DIR` environment variable says
otherwise, and it is fixed for the session: [`initializeModelManager`](@ref) reads the variable
once, checks that the directory can be created and written, and diagnostics reads the directory at
that moment — a location that could move mid-session would leave it looking where the sentinels are
not.

# Fields
- `submit_retry_period::Float64`: How long a worker keeps retrying a submission that `sbatch`
  refused for a reason that clears up on its own -- a per-user submit limit while earlier jobs
  drain, a controller that is not answering -- before giving up. Retries back off from 2 s to
  60 s. A refusal that does not look transient (a wrong partition, an invalid option, no
  `sbatch` at all) is not retried. Either way, giving up stops the run and puts the simulation
  back to `Not Started`; it is never recorded as failed, because no job ever ran.
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
    poll_interval::Float64 = 1.0
    reap_interval::Float64 = 300.0
    grace_period::Float64 = 270.0
end

"""
    setHPCCompletionOptions(; kwargs...)

Set any of the [`HPCCompletionOptions`](@ref) fields on the active globals.

```julia
setHPCCompletionOptions(grace_period=600.0)   # a filesystem slower than the 270 s default assumes
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
