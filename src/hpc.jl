using Dates

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
    return use
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

"""
    _driverJobDir() → String

A fresh, timestamped directory under `data/outputs/drivers/` for one driver submission, holding
the generated batch script, the job's own streams, and the `sbatch` client's. A second submission
inside the same second gets a `-2`, `-3`, … suffix rather than overwriting the first one's logs.
"""
function _driverJobDir()
    root = joinpath(dataDir(), "outputs", "drivers")
    stamp = Dates.format(now(), "yyyymmdd-HHMMSS")
    dir = joinpath(root, stamp)
    n = 1
    while ispath(dir)
        n += 1
        dir = joinpath(root, "$(stamp)-$(n)")
    end
    mkpath(dir)
    return dir
end

"""
    _driverJobFlags(options) → Vector{String}

Render a `submitDriver` keyword splat as `--key=value` flags, defaulting `job-name` to
`mm-driver`. An underscore in a keyword becomes a hyphen, since `cpus_per_task=4` is writable and
`var"cpus-per-task"=4` is not.
"""
function _driverJobFlags(options)
    opts = Dict{String,Any}("job-name" => "mm-driver")
    for (key, value) in options
        flag = replace(String(key), "_" => "-")
        flag in _RESERVED_SBATCH_KEYS && throw(ArgumentError(
            "The sbatch option `$(flag)` is set by ModelManager itself and cannot be overridden; " *
            "reserved keys are $(join(_RESERVED_SBATCH_KEYS, ", "))."))
        #! No `Function` values here, unlike `setJobOptions`: there is no `Simulation` to call one
        #! with. The driver is one job, so a literal is the only thing that could be meant.
        value isa Union{AbstractString,Number} || throw(ArgumentError(
            "The sbatch option `$(flag)` for submitDriver must be a String or a number; got " *
            "$(repr(value))::$(typeof(value))."))
        opts[flag] = value
    end
    #! Sorted so the submitted command line is reproducible between sessions.
    return ["--$(k)=$(opts[k])" for k in sort(collect(keys(opts)))]
end

"""
    submitDriver(script; project=Base.active_project(), options...) → Int

Submit `script` itself as a SLURM job, so the Julia process that drives a campaign runs on a
compute node under the scheduler's clock instead of in an SSH session that a dropped connection
would kill. Returns the job ID, and prints the `squeue`/`sacct` lines that follow it.

The job's body is `julia --project=<project> <script>`, resolved from the `PATH` the job inherits
(SLURM exports the submitting environment by default), so submit from a shell where `julia` runs.
Each `options` keyword becomes an `sbatch` flag, with underscores turned into hyphens
(`cpus_per_task=4` → `--cpus-per-task=4`); values must be strings or numbers, and the flags
ModelManager renders itself are refused. `job-name` defaults to `mm-driver`. The generated batch
script and the job's `output.log`/`output.err` are kept under
`data/outputs/drivers/<timestamp>/`.

**The driver's own `--time` has to cover the entire campaign** — not just the compute, but the
queue wait of every simulation job it will submit, since it sits blocked until the last one
finishes. A driver killed at its time limit strands exactly the rows this helper exists to
protect; `databaseDiagnostics` can recover them afterwards, but the campaign still stops.

Inside the driver job, HPC detection stays on and each simulation is still submitted as its own
job. That is the intended design — it hands scheduling to SLURM — so the driver itself needs only
one core and a small memory request, whatever the simulations need.

```julia
submitDriver("run_campaign.jl"; time="48:00:00", mem="4G", partition="long")
```
"""
function submitDriver(script::AbstractString; project=Base.active_project(), options...)
    assertInitialized()
    isfile(script) || throw(ArgumentError("submitDriver: no script at `$(script)`."))
    dir = _driverJobDir()
    body = "julia --project=$(_shQuote(string(project))) $(_shQuote(abspath(script)))"
    job_script = joinpath(dir, "driver.sh")
    #! `exec` so the job's exit status is Julia's own, with no shell frame in between for SLURM to
    #! report instead. sbatch requires the leading shebang.
    write(job_script, "#!/bin/sh\nexec $(body)\n")
    chmod(job_script, 0o755)

    flags = ["--parsable",
             "--output=$(joinpath(dir, "output.log"))",
             "--error=$(joinpath(dir, "output.err"))"]
    append!(flags, _driverJobFlags(options))
    out, err = IOBuffer(), IOBuffer()
    p = try
        run(pipeline(ignorestatus(`sbatch $flags $job_script`); stdout=out, stderr=err))
    catch e
        throw(SubmissionRefused(nothing, "sbatch could not be invoked: $(sprint(showerror, e))"))
    end
    stdout_text, stderr_text = String(take!(out)), String(take!(err))
    #! The same pair the per-simulation path writes, for the same reason: with `--parsable` this is
    #! the only place the job ID lands on disk.
    write(joinpath(dir, "hpc.out"), stdout_text)
    write(joinpath(dir, "hpc.err"), stderr_text)
    success(p) || throw(SubmissionRefused(nothing, "sbatch exited $(p.exitcode): $(strip(stderr_text))"))
    job_id = _parseJobID(stdout_text)
    isnothing(job_id) && throw(SubmissionRefused(nothing,
        "could not find exactly one job ID in sbatch's output. Output was:\n$(stdout_text)"))

    println("""
    Submitted driver job $(job_id): $(body)
        while it waits or runs:  squeue -j $(job_id)
        once it has finished:    sacct -j $(job_id)
        its output:              $(joinpath(dir, "output.log"))
    """)
    flush(stdout)
    return job_id
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
