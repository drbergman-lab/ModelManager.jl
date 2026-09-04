#! Completion detection for SLURM jobs, without `sbatch --wait`.
#!
#! `sbatch --wait` is not a callback -- it is a poll. `_job_wait` in SLURM's `src/sbatch/sbatch.c`
#! sleeps and calls `slurm_load_job` (a `REQUEST_JOB_INFO_SINGLE` RPC to slurmctld) on a
#! 2s -> 8s -> 32s backoff, capped by a compiled-in `MAX_WAIT_SLEEP_TIME` of 32. The runner kept one
#! waiter per in-flight simulation, so controller load scaled with
#! `max_number_of_parallel_simulations`; and because every waiter restarts its backoff at 2s, a slot
#! churning short simulations never reached the 32s plateau. That is the load this file removes.
#!
#! The replacement is the standard grid-executor pattern (Nextflow's `GridTaskHandler` has the same
#! shape): the job writes its exit code to a sentinel file on the shared filesystem, and the worker
#! that submitted it waits for that one file. The scheduler is consulted only as a reaper, for jobs
#! that died without getting to write anything -- and only through one `squeue` answer shared by
#! every waiting worker, so it is one RPC per `reap_interval` no matter how many jobs are in flight.
#!
#! Four things this deliberately does NOT do:
#!
#! - It does not run a central watcher task. Each worker already blocks for the length of its own
#!   simulation, so it may as well do its own waiting: `isfile` on one known path, once a second.
#!   A shared watcher would trade N cheap `stat`s for one `readdir`, and pay for it with a registry,
#!   a channel per job, a task lifecycle with a start/stop race, and a failure mode where one bad
#!   sweep fails every tracked job. Here, nothing one worker does can hang or fail another.
#! - It does not watch the directory. inotify (and so Julia's `FileWatching`) is a local-kernel
#!   mechanism with no hook into the NFS/Lustre/GPFS protocol, so it never sees a file created by
#!   another node. Reading works; being *notified* does not.
#! - It does not open a socket for the job to call back on. There is no POSIX-guaranteed way for a
#!   job to send a TCP message (`nc`, `curl`, `python3`, bash's `/dev/tcp` are each merely likely),
#!   compute nodes cannot always route back to the submitting host, and batch semantics deliberately
#!   sever the submitter from the job, which may start hours later. Writing a file needs only `>`.
#! - It does not clean up with `rm_hpc_safe`. That exists for output directories a *running* job on
#!   another node still holds open; a sentinel's writer has exited before the file is even readable.
#!   It would also stage into `data/.trash/` -- a cross-mount move whenever `done_dir` is on another
#!   filesystem -- and warn about the staged path, all for a few bytes.

"""
    _hpcDoneDir()

Absolute path to the directory where SLURM jobs deposit their exit-code sentinels, creating it if
needed. Defaults to `<dataDir()>/.hpc_done`; see `HPCCompletionOptions.done_dir` for when to move it.
"""
function _hpcDoneDir()
    configured = mm_globals().hpc_completion.done_dir
    dir = isempty(configured) ? joinpath(dataDir(), ".hpc_done") : configured
    mkpath(dir)
    return dir
end

#! One `squeue` may take this long before it is killed and counted as a failed query. Without a
#! bound, an unresponsive slurmctld would pin the refresh lock and disable the reaper for everyone.
#! A `Ref` only so the test suite can exercise the timeout without waiting a minute; there is no
#! other test seam -- tests put fake `sbatch`/`squeue` scripts on `PATH`.
const _SQUEUE_TIMEOUT_S = Ref(60.0)
#! A failed query is retried sooner than a good one is refreshed, so a transient hiccup does not
#! add a whole `reap_interval` to every killed job's detection time.
const _FAILED_QUERY_TTL_S = 30.0

"""
    _QueueSnapshot

One answer from `squeue`, shared by every waiting worker.

`taken_at` is `time_ns()` at the moment the query *started*, not finished. A worker compares it
against its own submission time: a snapshot that started before the job was submitted cannot
contain the job and says nothing about it. `jobs === nothing` means the query failed, which is a
distinct fact from "no jobs", and is cached too so a slow controller is retried once per TTL rather
than once per worker per tick.

Both stamps use `time_ns()`, which is monotonic, because the ordering argument would be unsound
under wall-clock `time()` the moment NTP stepped the clock backwards.
"""
struct _QueueSnapshot
    taken_at::UInt64
    jobs::Union{Nothing,Set{Int}}
end

#! The only state shared between workers: the latest snapshot, the lock that serializes refreshing
#! it (never held while waiting), and the last time strays were swept.
const _queue_snapshot = Ref(_QueueSnapshot(0, nothing))
const _queue_lock = ReentrantLock()
const _last_stray_sweep = Ref{UInt64}(0)

_elapsedSeconds(since::UInt64) = (time_ns() - since) / 1e9

"""
    _currentUser() → String

Username to pass to `squeue -u`. Prefers `\$USER`, falling back to `id -un`; warns once if neither
works, because without it the reaper never runs and a scheduler-killed job would block forever.
"""
function _currentUser()
    u = get(ENV, "USER", "")
    isempty(u) || return u
    u = try
        readchomp(`id -un`)
    catch
        ""
    end
    isempty(u) && @warn "Could not determine the current user (\$USER unset and `id -un` failed); \
                         SLURM jobs that die without writing an exit code cannot be detected." maxlog=1
    return u
end

"""
    _squeueUserJobs() → Union{Nothing,Set{Int}}

The SLURM job IDs the scheduler currently holds for this user, or `nothing` if the query failed.
Never throws.

`nothing` is load-bearing and must never be conflated with an empty set: absence from this set is
the reaper's signal that a job is gone, and if a failed query read as an empty set every waiting
job would be declared dead at once.

`-u` rather than `-j <list>`: it maps to `slurm_load_job_user` (`REQUEST_JOB_USER_INFO`), filtered
server-side, one RPC regardless of how many jobs are tracked. `-t all` because squeue's default
state filter omits SUSPENDED (preemption, `scontrol suspend`), which would make a live job look gone
-- a completed job also lingers for `MinJobAge` under `-t all`, which only delays the reaper, and the
sentinel resolves it first anyway. `SQUEUE_*` variables are cleared because a `SQUEUE_STATES=R` or
`SQUEUE_PARTITION=…` in the user's profile would silently filter live jobs out of the answer.
"""
function _squeueUserJobs()
    try
        user = _currentUser()
        isempty(user) && return nothing
        out = IOBuffer()
        cleared = [k => nothing for k in keys(ENV) if startswith(k, "SQUEUE_")]
        p = withenv(cleared...) do
            run(pipeline(ignorestatus(`squeue -h -u $(user) -t all -o %i`); stdout=out, stderr=devnull); wait=false)
        end
        if timedwait(() -> process_exited(p), _SQUEUE_TIMEOUT_S[]) === :timed_out
            #! Kill and leave -- do NOT `wait(p)`. That would block until the stdout pipe closes,
            #! and a grandchild (a site wrapper's real `squeue`, say) can hold it open long after
            #! the wrapper is dead: the very hang the timeout exists to bound.
            kill(p)
            return nothing
        end
        #! `process_exited` does not join the stdout copy task; `wait` does. Parsing before it
        #! could read a truncated listing as a complete one and reap live jobs.
        wait(p)
        success(p) || return nothing
        ids = Set{Int}()
        for line in eachline(seekstart(out))
            s = strip(line)
            isempty(s) && continue
            #! An array task prints as "12345_3"; its base ID is what was registered at submission.
            v = tryparse(Int, first(split(s, '_')))
            isnothing(v) || push!(ids, v)
        end
        return ids
    catch
        return nothing
    end
end

"""
    _queueSnapshot() → _QueueSnapshot

The shared `squeue` answer, refreshed if it is older than its TTL.

Whichever worker finds it stale refreshes it; workers that arrive while a refresh is in progress
take the existing snapshot rather than waiting on the lock, so a slow `squeue` never keeps anyone
from checking its own sentinel. The lock guards only the refresh.
"""
function _queueSnapshot()
    reap = mm_globals().hpc_completion.reap_interval
    ttl(s) = isnothing(s.jobs) ? min(_FAILED_QUERY_TTL_S, reap) : reap
    snap = _queue_snapshot[]
    _elapsedSeconds(snap.taken_at) < ttl(snap) && return snap
    trylock(_queue_lock) || return snap
    try
        snap = _queue_snapshot[]
        _elapsedSeconds(snap.taken_at) < ttl(snap) && return snap
        started = time_ns()
        snap = _QueueSnapshot(started, _squeueUserJobs())
        _queue_snapshot[] = snap
        return snap
    finally
        unlock(_queue_lock)
    end
end

"""
    _readSentinel(path::String) → Union{Nothing,Int}

The exit code recorded in the sentinel at `path`; `nothing` if it is not there yet or cannot be
read this tick. Never throws.

`isfile` sits inside the `try` on purpose: it only swallows ENOENT, and a stale NFS handle, EIO or
EACCES would otherwise escape the worker and abort the whole run. A sentinel that exists but does
not parse is treated as a failure -- it is a real file the job wrote, just not a number -- and is
reported as `-1`, which no process can actually exit with.
"""
function _readSentinel(path::String)
    contents = try
        isfile(path) ? read(path, String) : nothing
    catch
        nothing
    end
    isnothing(contents) && return nothing
    ec = tryparse(Int, strip(contents))
    return isnothing(ec) ? -1 : ec
end

"""
    _waitForHPCJob(job_id::Int, sentinel::String, submitted_at::UInt64) → Union{Nothing,Int}

Block until the job has written `sentinel`, or until the scheduler has demonstrably lost it. Return
the recorded exit code, or `nothing` if the job was reaped without ever writing one.

The sentinel is the completion path and wins whenever it appears. The reaper fails the job only
when three things hold at once: a snapshot taken *after* submission does not list it; the job has
been absent for `grace_period`, so a sentinel written on a compute node has had time to become
visible here; and a *second* snapshot, taken after the first absence, still does not list it -- so
a single wrong answer cannot fail a live job. The grace clock is worker-local: it starts on the
first absence, is cleared if the job reappears, and is never touched by a refresh.
"""
function _waitForHPCJob(job_id::Int, sentinel::String, submitted_at::UInt64)
    gone_since = nothing
    while true
        opts = mm_globals().hpc_completion
        sleep(opts.poll_interval)

        ec = _readSentinel(sentinel)
        if !isnothing(ec)
            #! Resolved; a failed delete is a leaked file (swept as a stray later), not a failure.
            try
                rm(sentinel; force=true)
            catch
            end
            return ec
        end

        snap = _queueSnapshot()
        (isnothing(snap.jobs) || snap.taken_at <= submitted_at) && continue
        if job_id in snap.jobs
            gone_since = nothing
            continue
        end
        gone_since = something(gone_since, time_ns())
        if snap.taken_at > gone_since && _elapsedSeconds(gone_since) >= opts.grace_period
            @warn "SLURM job $(job_id) left the queue without recording an exit code; treating the \
                   simulation as failed. This is what a job killed by the scheduler (out of memory, \
                   time limit, node failure) or cancelled while pending looks like — check its \
                   output.err and `sacct -j $(job_id)`." maxlog=10
            return nothing
        end
    end
end

"""
    _sweepStraysIfDue(done_dir::String)

Once per `reap_interval`, delete files in `done_dir` that nothing can still be waiting on:
sentinels left by crashed drivers, staged `.tmp` writes from jobs killed between the `echo` and the
`mv`, NFS `.nfsXXXX` artifacts. Never throws.

How often this runs is tidiness only -- nothing reads the directory listing on the hot path, so
strays cost bytes, not time. The safety property is the age gate: a file is touched only once it is
older than any grace period a live job could still be inside, so a `done_dir` shared across sessions
is safe.
"""
function _sweepStraysIfDue(done_dir::String)
    opts = mm_globals().hpc_completion
    _elapsedSeconds(_last_stray_sweep[]) < opts.reap_interval && return
    _last_stray_sweep[] = time_ns()
    max_age = max(4 * opts.grace_period, 3600.0)
    try
        for name in readdir(done_dir)
            path = joinpath(done_dir, name)
            try
                time() - mtime(path) > max_age && rm(path; force=true)
            catch
            end
        end
    catch
    end
    return
end

"""
    _submitHPCJob(cmd::Cmd, simulation_id::Int) → Union{Nothing,Int}

Run the prepared `sbatch` command and return the job ID, or `nothing` if submission failed.
"""
function _submitHPCJob(cmd::Cmd, simulation_id::Int)
    out = IOBuffer()
    err = IOBuffer()
    p = try
        run(pipeline(ignorestatus(cmd); stdout=out, stderr=err))
    catch e
        @error "Failed to invoke sbatch for simulation $(simulation_id)." exception=(e, catch_backtrace())
        return nothing
    end
    if !success(p)
        @error "sbatch rejected the job for simulation $(simulation_id) (exit $(p.exitcode)): $(strip(String(take!(err))))"
        return nothing
    end
    stdout_text = String(take!(out))
    job_id = _parseJobID(stdout_text)
    #! Getting this wrong is worse than a failed submission: the job runs, and nothing waits for it.
    #! So the raw output goes in the message -- a site wrapper with an unexpected format is then a
    #! one-line diagnosis instead of an orphaned job.
    isnothing(job_id) && @error "Could not find exactly one job ID in sbatch's output for simulation \
                                 $(simulation_id). Output was:\n$(stdout_text)"
    return job_id
end

"""
    _parseJobID(stdout_text::AbstractString) → Union{Nothing,Int}

The job ID in `sbatch`'s stdout, or `nothing` unless exactly one is found.

`--parsable` prints `jobid` or `jobid;cluster` on a line of its own, and nothing else -- but sites
routinely wrap `sbatch` in a script that adds a banner, or that drops `--parsable` and prints the
classic `Submitted batch job N`. Both are accepted; anything ambiguous is refused, because waiting on
the wrong ID means the real job runs unobserved.
"""
function _parseJobID(stdout_text::AbstractString)
    ids = [parse(Int, m.captures[1]) for m in eachmatch(r"^(\d+)(?:;\S*)?\s*$"m, stdout_text)]
    if isempty(ids)
        ids = [parse(Int, m.captures[1]) for m in eachmatch(r"Submitted batch job (\d+)", stdout_text)]
    end
    return length(ids) == 1 ? only(ids) : nothing
end

"""
    _runHPCSimulation(cmd::Cmd, simulation_id::Int) → Union{Nothing,Int}

Submit `cmd` as a SLURM job, block until it finishes, and return its exit code -- or `nothing` if
it never produced one, because `sbatch` refused it or the scheduler lost it before it could write.
The caller decides what a nonzero code means; this only reports it.

Blocking the calling worker is what preserves the throttle: `max_number_of_parallel_simulations`
bounds how many jobs sit in the queue exactly as it did under `sbatch --wait`.
"""
function _runHPCSimulation(cmd::Cmd, simulation_id::Int)
    done_dir = _hpcDoneDir()
    _sweepStraysIfDue(done_dir)
    #! The sentinel's name is chosen here, before submission, and baked into the job script. It has
    #! to be unique per submission, and neither ID on offer is: simulation IDs are recycled when a
    #! simulation is deleted, and SLURM job IDs wrap at `MaxJobId` and reset on a `slurmctld -c`.
    #! So the name is `<simulation_id>.<time_ns>`, and the two parts split the work -- the simulation
    #! ID separates *concurrent* workers (no two in-flight jobs share one), the monotonic timestamp
    #! separates *sequential* submissions of the same ID. Nothing left behind by an earlier
    #! submission can ever share a name with this one, so there is nothing to clean up first. (Naming
    #! by job ID would need a "discard anything already there" step after submission, which races a
    #! fast job's real sentinel.) The job ID is used only for the reaper's liveness check, where a
    #! recycled ID can at worst delay a reap, never produce a wrong result.
    sentinel = joinpath(done_dir, "$(simulation_id).$(string(time_ns(); base=16))")
    job_id = _submitHPCJob(_prepareHPCSubmitCommand(cmd, simulation_id, sentinel), simulation_id)
    isnothing(job_id) && return nothing
    return _waitForHPCJob(job_id, sentinel, time_ns())
end
