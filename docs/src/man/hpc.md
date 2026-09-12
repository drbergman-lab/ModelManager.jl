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

The override sticks for the rest of the session, including across later calls to
[`initializeModelManager`](@ref) — otherwise a re-initialization, which a simulator package may do
on its own at load time, would silently put the probed value back.

## Job options

SLURM job parameters are held in a `Dict` of `sbatch` options. [`ModelManager.defaultJobOptions`](@ref) sets
two: a job name, `S<simulation id>`, and `cpus-per-task` from the backend's `simulationThreads`
when it implements that hook (PhysiCellModelManager does, from the config's `omp_num_threads`).
Time, memory and partition are the site's defaults until you say otherwise with
[`setJobOptions`](@ref):

```julia
setJobOptions(Dict(
    "time"          => "02:00:00",
    "mem"           => "8G",
    "cpus-per-task" => 6,
    "partition"     => "compute",
))
```

Set `time` and `mem` explicitly. A job the scheduler kills for exceeding either writes no exit
code, so it is only noticed by the reaper described below -- several minutes later, per job. If
your backend does not implement `simulationThreads`, set `cpus-per-task` yourself to the thread
count the simulator actually uses: SLURM allocates one CPU by default, and a simulator that starts
more threads than that runs them all on one core. A value may be a function of the `Simulation`
about to be submitted, so an option can follow a varied parameter; returning `nothing` omits the
flag for that simulation:

```julia
setJobOptions(Dict("comment" => simulation -> "monad \$(only(monadIDs(simulation)))"))
```

These options are applied to every job the runner submits for the current session. The flags
ModelManager renders itself (`wrap`, `output`, `error`, `wait`, `parsable`, `chdir`) cannot be set.

`setNumberOfParallelSims` bounds how many jobs are in the queue at once, and its default is 1 --
one job at a time, however large the cluster. Raise it, but not above your per-user submit limit
(`sacctmgr show qos format=name,maxsubmitjobsperuser`): a submission the scheduler refuses for that
reason is retried for a while, then stops the run.

## How jobs are launched

When HPC mode is active, the runner submits each simulation's command to `sbatch` instead of
spawning a local process. From your script's perspective nothing changes — you still call
[`run`](@ref) on a trial; the runner decides per-simulation whether to execute locally or
submit a job.

Each job still writes its own `output.log` and `output.err` into that simulation's output folder,
and `setNumberOfParallelSims` still bounds how many jobs sit in the queue at once.

### When `sbatch` refuses a job

A refused submission is not a failed simulation: no job ran, so nothing is known about the
simulation, and it is left pending rather than recorded as failed. What happens next depends on
the refusal:

- A message that clears up on its own -- a per-user submit limit while earlier jobs drain, a
  controller that is not answering -- is retried with backoff for up to `submit_retry_period`
  (default 15 minutes; see [`setHPCCompletionOptions`](@ref)). A warning says so the first time.
- Anything else (a wrong partition, an invalid option, no `sbatch` on this machine), or a
  transient refusal that outlasts the period, stops the run immediately with the scheduler's own
  message. Every simulation not yet submitted is back at `Not Started`, so fixing the problem and
  calling `run` again continues where it stopped. Jobs that were already submitted keep running
  and are recorded as they finish, as long as the Julia session stays alive.

### Interrupting a run

Ctrl-C stops `run` from submitting anything further and returns the not-yet-submitted simulations
to `Not Started`. Jobs already in the queue are *not* cancelled: they run to completion and, if the
Julia session is still alive, their outcomes are recorded. To abandon them, `scancel` them
yourself -- each simulation's folder holds its job ID in `hpc.out`, and the default job name is
`S<simulation id>`, so `scancel --name=S123` also works.

### Keeping the driver alive

The Julia process that called `run` is what waits for the jobs and records their outcomes; if it
dies, the jobs still finish but nothing writes their results to the database, and the simulations
they belonged to stay at `Running`.

The fix is to make the driver a job too, so it runs on a compute node under SLURM's clock rather
than in an SSH session. `tmux`, `screen` and `nohup julia script.jl &` also survive a dropped
connection, but not a login node that reaps long-running processes.

If a driver does die anyway, the next `initializeModelManager` recovers what it left behind. Its
statuses say how far each simulation got: `Queued` means a `run` scheduled it and no worker had
claimed it yet, `Running` means a worker claimed it and was about to call the backend. So for every
simulation still at `Running`, `databaseDiagnostics` reads the exit code its job recorded, or asks
`sacct` about the job ID in that simulation's `hpc.out` — one `sacct` call for the whole pass,
carrying every job ID it still needs an answer for — and marks the simulation `Completed` or
`Failed` accordingly; every simulation at `Queued`, and on a cluster every `Running` one that never
reached the scheduler, goes back to `Not Started`. It reports what it changed. A simulation whose
job is still queued or running is left alone, so re-running the diagnostics after those jobs finish
resolves them.

### Running the driver as a job

The first initialization on a machine with `sbatch` — or the first `useHPC(true)` after one —
writes a template into your project, into `scripts/` if you have one and else next to `data/`:

```
driver_template.sbatch
```

Submit a campaign with it, passing the script to run as an argument:

```bash
sbatch driver_template.sbatch run_campaign.jl
```

The template is a starting point, not something ModelManager owns: it is written once, never
overwritten, and the commented-out `module load julia` line near the top is there because loading
Julia is site-specific and ModelManager cannot know your site's incantation. Edit the `#SBATCH`
lines and that one to taste.

Two things to get right:

- **The driver's `--time` must cover the whole campaign**, including the time its simulation jobs
  spend waiting in the queue — the driver sits blocked until the last of them finishes. It is the
  one job whose wall clock is not about how long any computation takes.
- The driver itself needs almost nothing: one core and a small memory request. Inside the driver
  job, detection stays on and each simulation is still submitted as its own job, which is the
  point — SLURM schedules them, not ModelManager.

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

A job the scheduler kills therefore takes a while to be noticed: up to one `reap_interval` for
the queue snapshot to refresh, plus the `grace_period`, plus a second snapshot -- five to ten
minutes with the defaults. Each such job is reported with its job ID so `sacct -j` can say why.

Tune it with [`setHPCCompletionOptions`](@ref):

```julia
setHPCCompletionOptions(
    poll_interval = 1.0,     # seconds between a worker's checks for its own sentinel
    reap_interval = 300.0,   # how long one squeue answer is shared before it is refreshed
    grace_period  = 270.0,   # how long a vanished job may take to produce its sentinel
    submit_retry_period = 900.0,  # how long a transiently refused submission is retried
)
```

Sentinels are written to `data/outputs/.hpc_done` by default. That default is on the same
filesystem the jobs already write their output into, so it is somewhere the compute nodes can write
by construction — which matters, because a sentinel directory the nodes cannot write makes every
successful job look scheduler-killed and says nothing about why. What it costs is turnaround on
NFS: it caches directory attributes for 30–60 seconds by default, so a sentinel written on a
compute node can take that long to become visible to your driver, and that is then the floor on how
quickly one simulation finishing frees a slot for the next. Lustre and GPFS have no such delay, and
neither does a project on scratch.

To put the sentinels somewhere else — scratch, say, to escape that NFS delay — set
`MODELMANAGER_HPC_DONE_DIR` before starting Julia:

```bash
export MODELMANAGER_HPC_DONE_DIR=/scratch/$USER/mm_done
```

That environment variable is the only way to move the directory, and it is read once, by
`initializeModelManager`: changing it mid-session does nothing until the next initialization. The
directory is created and write-tested at that point, and an `ArgumentError` naming the variable
says so if either fails, rather than leaving you to discover it a campaign later. The cost of
moving it is the obvious one, and it is on you: sentinels written into the previous directory are
not where diagnostics looks, so switching between launches means a campaign stranded under the old
value cannot be reconciled from its sentinels. Changing the variable is deliberate, so it is worth
a moment's thought about where the sentinels of any campaign still in flight are.

### Finding a job again

Each simulation's folder holds the `sbatch` client's own output in `hpc.out` (the job ID) and
`hpc.err` (a refusal message, if any), beside the `output.log`/`output.err` the job itself wrote.
With the default job name, `sacct --name=S<simulation id>` finds the scheduler's record without
opening either file.

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
exit; `ModelManager.databaseDiagnostics` reports whatever is still there.

If you want that space reclaimed automatically instead, put the project's `data/` directory on
scratch — `data/.trash` then lives on scratch too and your site's purge policy sweeps it with
everything else. Pointing the staging area itself at another filesystem cannot work: moving
across mounts is a copy followed by a delete of the source, and that delete is the operation
being refused.

See the [HPC & SLURM](@ref hpc_lib) API reference for the full set of functions.
