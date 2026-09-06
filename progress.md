# progress.md — ModelManager.jl Session Journal

> **Purpose:** Session-level decisions, rejected approaches, and open questions.
> Unlike [PRD.md](PRD.md) (specification) and [README.md](README.md) (completion status), this file captures the *reasoning* behind decisions — things that would otherwise exist only in ended chat history.

---

## Session: a refused `sbatch` submission is not a failed simulation (2026-09-05) — ships in v0.10.0

### Trigger
An architecture review of the 0.9 HPC path, from the user's seat: what happens on a cluster whose
per-user submit limit is smaller than `setNumberOfParallelSims`, or when slurmctld times out for
thirty seconds mid-campaign.

### What happened before
`_submitHPCJob` returned `nothing` on any nonzero `sbatch` exit; `runSimulation` turned that into
`success=false`; `updateDatabaseOnCompletion` called `simulationFailed`, which marked the row `Failed`
and erased it from its monad -- deleting the monad and its superiors when it was the last
constituent. A refused worker returns instantly and takes the next spec, so with 100 workers and a
submit limit of 20, the other 80 marked ~980 simulations failed and deleted their monads within
seconds. The generated script template defaults `n_replicates = 1`, so every monad had one simulation.

### Decisions
- **A refusal throws.** `_SubmissionRefused` is a distinct exception, caught in the task wrapper
  (which resets the row to `Not Started` instead of recording a failure) and classified by the
  worker as stage `:submission` with its simulation ID, so `run` fails fast with the scheduler's own
  message. The reaped-job path (`_waitForHPCJob` returning `nothing`) is unchanged: there a job did
  run and died, which is a result.
- **Transient refusals are retried, by message.** Every refusal exits 1, so the text is the only
  signal. A curated pattern list (QOS/submit-limit wording, socket timeouts, controller unreachable)
  is retried with backoff 2 s doubling to 60 s for `submit_retry_period` (900 s default, on
  `HPCCompletionOptions`), then refused. The QOS wording is shared by submit-count limits
  (transient) and size/time limits (permanent); retrying the latter for 15 minutes is the price of
  not shredding the former. Unmatched messages fail fast -- a wrong partition does not fix itself.
  Rejected: retrying every refusal for a fixed short window (a submit limit lasts as long as the
  jobs ahead of it, so a minute is not enough), and retrying indefinitely (hides a permanent error).
- **`run` closes its queue in a `finally`.** Whether the completion loop ends normally, by fail-fast
  or by Ctrl-C, no further simulation starts, and every simulation no worker picked up is returned
  from `Queued` to `Not Started` (guarded on the row still being `Queued`). Before this the worker
  tasks kept draining the queue after `run` had thrown -- submitting jobs with options the user was
  in the middle of fixing -- and then blocked forever on the never-closed channel, one leaked task
  per worker per `run`. Jobs already submitted are deliberately *not* cancelled: they are paid for,
  and their workers record them as they finish. The queue is now filled synchronously (it holds
  every task, so `put!` never blocks) so there is no producer task to race the `close`.
- **`defaultJobOptions` loses `"mem" => "1G"`.** A one-gigabyte default is PhysiCell-sized at best
  and wrong for most 3D runs; a job killed for exceeding it writes no sentinel and takes five to ten
  minutes to be declared failed. The site default is the honest default. `job-name` stays, because
  `S<id>` is the only bridge from a simulation to `sacct` besides `hpc.out`.
- **Reserved sbatch keys are refused in `setJobOptions`**, not asserted at the first submission;
  so are non-`String` keys (review).
- **`cpus-per-task` is a default, filled by the backend.** Review asked whether the manual's
  `sim_id -> threadsFor(sim_id)` example should be a real function, and of a `Simulation` rather
  than an ID. Yes to both: only the backend knows its thread count, so ModelManager stubs
  `simulationThreads(sim, simulation)` (default `nothing`, which omits the flag) and
  `defaultJobOptions` requests it per submission; PCMM implements it from `omp_num_threads`. Every
  `Function`-valued job option now receives the `Simulation`, matching the measurement contract.
- **Ownership is tracked, not inferred.** Review (Copilot) found the shutdown reset used
  `istaskstarted` as "no worker took this", which lies between a worker's dequeue and its
  `schedule`; a retried `run` could then schedule the same simulation twice. Workers now mark a
  `claimed` bit the instant they dequeue an index, with no yield in between, and the reset consults
  that.
- **The reaper's warning is uncapped.** `maxlog=10` hid the SLURM-specific cause (and the
  `sacct -j` hint) after ten kills; one line per reaped job is the right amount.

### Not done here, recorded for the brief
Driver death still strands `Running` rows with only a destructive recovery (`deleteSimulationsByStatus`);
a non-destructive reconcile that reads leftover sentinels and `sacct` is designed but not built.
`isRunningOnHPC` still overrides a `useHPC` call on re-initialization and does not recognise
`SLURM_JOB_ID`. Both are documented in the manual's new "Keeping the driver alive" section instead.

---

## Session: QoI evaluation moves into qoi.jl (2026-09-05) — ships in v0.9.1

### Trigger
Reviewing PR #49: "why is sensitivity.jl owning the code for computing QoIs?" It is a fair question
about placement, but the substance turned out to be a divergence, not an aesthetic.

### The two implementations had drifted
`qoi.jl`'s `_reduceOverMonad` and an inline loop in `evaluateFunctionOnSampling` did the same job —
compute a QoI over a monad's simulations and reduce the replicates — and only one of them was right:

- `_reduceOverMonad` batch-loads through `simulationsFromIDs`, with a `#!` comment naming the N+1
  pattern it deliberately avoids, and guards both an empty monad and a constituent list that
  disagrees with the database.
- GSA's copy called `_computeOn(q, simulation_id)` once per ID — that same N+1 pattern, one
  `Simulation(sid)` round trip each — and carried neither guard, so an empty monad reached
  `q.reduce([])` and an inconsistent one went unnoticed.

GSA now calls `_reduceOverMonad`, gaining the batch query and both guards. Checked before switching
that this is not a trade: `stored=:prefer` already queries per simulation inside `_storedValue`
regardless of which path is taken, so the batch version is better or equal in every case rather than
only in the `stored=:never` default.

### One separator, not four string literals
`"<name>.<key>"` was written out in `_asPostProcessor` and in `evaluateFunctionOnSampling`, and the
`"."` was hardcoded a third time in `_isGSALabelOf` and a fourth in the `QoI` constructor's refusal.
Four sites that must agree, none of which said so. Now `_QOI_LABEL_SEPARATOR`, `_qoiLabel` and
`_isQoILabelOf` in `qoi.jl`, with a test that ties the constructor's refusal to the label helper:
whatever `_qoiLabel` builds is exactly what a name may not look like.

### Moved, and what stayed
`_gsaComponentKeys`, `_gsaComponentValue` and `_gsaDuplicateLabelMessage` became `_qoiComponentKeys`,
`_qoiComponentValue` and `_qoiDuplicateLabelMessage` in `qoi.jl` — they describe what a *measurement*
names, not anything about sensitivity. `_gsaLabelsOf` stayed in `sensitivity.jl`, because it is about
a `GSASampling`'s stored results rather than about a QoI.

Their error messages still name sensitivity analysis, and that is deliberate: it is the only consumer
requiring a `Real` per component, since calibration hands whatever `reduce` returns to its `distance`
and the sink never calls `reduce` at all. A `#!` comment says so, so the next reader does not
"correct" it into something vaguer.

---

## Session: restorable means "JLD2 can name it"; stored values read back as written (2026-09-05) — ships in v0.10.0

### Trigger
An architecture review of the QoI seam, adversarially verified: four medium bugs, all in what the
seam *promised* rather than in the reduction it performs.

### Closures passed as restorable
`_isAnonymousFunction` tested `startswith(string(nameof(f)), "#")`. A named function defined inside
another function -- `f(s) = k` inside `make(k)`, exactly the shape `_saveProblem`'s own tip
recommended -- answers `nameof` with `:f`, so it passed, the manifest was saved "complete", and a
fresh session failed to load it with a raw JLD2 `ReconstructedMutable` MethodError. Worse, because
`resumeCalibration` read the manifest *before* consulting `problem=`, the documented rescue failed
the same way. Verified by the reviewer in a two-process probe on 1.12.7.

Decision: the predicate now asks the question that matters -- can a fresh session restore this by
name? A callable struct's type has an ordinary name (JLD2 stores it as type plus fields): restorable.
A type named `#<name>` exactly, resolving to `f` in its parent module: a top-level function,
restorable. Anything else (`#f#make##0`, `#12#13`): not. `_loadProblem` takes `required=`, so with
a `problem=` in hand an unreadable file is a warning and the supplied problem is used unvalidated;
without one it is an error naming both ways out. Rejected: validating the supplied problem against
`parameters.toml` instead of the manifest -- more machinery than the case warrants today.

The same predicate now drives `_qoiNameFromFunction`: a closure's name comes from its type and is an
`anon_…` form. Two closures from one factory still share it (same type, different captures), so the
name is treated as saying nothing: the sink refuses to store under it (as before) and
`calculateGSA!`'s name-based skip ignores it (`_isAutoNamedAnonymous`). Before, `run(...;
functions=[countOf("tumor")])` followed by `calculateGSA!(gsa, [countOf("immune")])` was skipped and
the tumor indices sat under the shared label `f`. A real name is kept in any alphabet; `μstar` used to
become `anon_star` and collide with `σstar`.

### `stored=` could not see what the sink wrote
`_storedValue` looked for a column literally named after the QoI and coerced it to `Float64`. A
`String` value crashed in the conversion; a keyed QoI -- whose columns the sink writes as
`<name>.<key>` -- was reported as never stored, so `:prefer` recomputed from pruned output and
`:require` threw with the row right there in `postProcessingTable`. `verifyStoredValues` had the
same `Float64` coercion on both sides.

Decision: read back the way the sink wrote. A bare column returns the value as held; otherwise every
`<name>.<key>` column is reassembled into a `Dict{String,Any}`, with `String` keys because that is
all a column name can carry (documented: a NamedTuple-keyed compute reads back string-keyed).
`verifyStoredValues` compares numbers with `isapprox`, keyed values key by key with the fresh keys
stringified, everything else with `isequal`, and counts a `missing`/`nothing` fresh value as
unverifiable rather than as a mismatch.

---

## Session: GSA spreads a keyed measurement (2026-09-04) — ships in v0.9.1

Issue #48, raised from PCMM: a `QoI` whose `reduce` yields `Dict(name => value)` fed calibration and
the post-processing sink unchanged, but GSA refused it, so one measurement had to be rewritten as one
scalar QoI per key to ask a sensitivity question about the same numbers.

### Decisions
- **`gsa.results` is keyed by a `String` label** (`Dict{String,T}`, breaking). Once one QoI yields
  several analyses the user needs `gsa.results["counts.tumor"]`. Label keys also delete
  `_gsaFunctionLabel`, which had only a `::Function` method and threw a `MethodError` on any results
  dict holding two QoI keys. Exposure was small: `results` was documented nowhere and its QoI-key half
  crashed on any plot.
- **One naming rule, `"<qoi name>.<key>"`, in GSA and the sink.** The sink used to drop the QoI's name
  and use the bare key. The separator is `.` because `_` is legal inside both a QoI name and a key,
  making `a_b_c` ambiguous.
- **An anonymous compute is refused whenever it stores anything.** Prefixing makes the sink consult the
  QoI's name for every column, so the Dict branch's exemption had to go; name the QoI or pass a named
  function. No `up.jl` milestone: the sink never promised column stability (renaming a bare function
  already starts a new column silently).
- **The sink guard stays lazy** (per simulation, after the `nothing`/`missing` skip), so an anonymous
  callback returning `nothing` keeps working and a `Vector` still reaches the sink's own type error.
- **A `Vector` is not spread by index.** The only cross-monad check would be length, and equal length is
  not equal meaning. The error carries the reasoning so the user supplies keys.
- **The `calculateGSA!` skip stays, keyed on the QoI's name**, decided before any output is read (a
  prefix test on the name, since every label is the name or the name plus `.` and a key). Labels
  cannot be used: a spreading QoI's labels are unknown until `reduce` has run. `recompute=true` is the
  explicit escape, because a changed measurement is undetectable (same impossibility as
  `stored=:never`). The dominant reason to call again is adding a quantity, not correcting one.
- **`recompute=true` drops every label the QoI owns before filing** (`_replaceGSAResults!`); otherwise
  a reducer that drops a key left the old label holding a stale number reported as current.
- **An empty `Dict`/`NamedTuple` from `reduce` is refused**; it named nothing, stored nothing and never
  counted as evaluated, so every later call re-read all output for nothing.
- **A QoI name may not contain a `.`.** Otherwise `QoI("counts.x", …)` and a `QoI("counts", …)`
  spreading to `x` claim one label; across calls the collision is silent in both orderings, and one
  skips the entire spreading QoI. Fails at construction where the user can act.
- **Label collisions are checked per call on the flattened labels**, and `_gsaResults` computes without
  storing so a rejected call leaves `results` untouched.

### Rejected
- Keeping object keys and filing spread results under derived `QoI(string(k), …)` objects: non-breaking
  and re-evaluable, but the per-key analyses would not be addressable by name, and two QoIs sharing a
  name would plot as two identically-labelled series.
- Removing the skip and always recomputing: re-reads every simulation's output in the common
  add-a-quantity case.
- A `Set` of evaluated QoI names as a struct field, or documenting the dotted-name hole: forbidding the
  dot removes the cause instead of compensating.

### Traps
- `sort(v; by=f)` never calls `f` on a one-element vector, so a single-entry test cannot catch a
  missing method used only inside `by`; the recipe tests passed a single bare `Function` and missed
  this. Test with two entries.
- Changing a behaviour means grepping for every place that *describes* it, not only the places that
  implement it; three rendered doc sites outside the diff still described the old sink.
- Sensitivity analysis is the only consumer that needs a `Real` per component; calibration hands
  `reduce`'s value to its `distance` and the sink never calls `reduce`. Error messages naming GSA are
  deliberate.

---

## Session: replace `sbatch --wait` polling (2026-09-03) — ships in v0.9.0

`sbatch --wait` is a poll of slurmctld (`slurm_load_job` on a 2 s → 32 s backoff that restarts per
job), one waiter per in-flight simulation; ~100 slots churning short simulations is order 50 RPC/s
against the controller. Landed: one sentinel file per job that its own worker waits on, with the
scheduler consulted only as a reaper. Nextflow's grid executor has the same shape (`.exitcode` file,
batched queue status, `exitReadTimeout` 270 s), checked rather than assumed.

### Decisions
- **Sentinel file plus one filesystem check; scheduler as reaper only.** The problem was never
  "polling" but *what* was polled: slurmctld is a contended bottleneck, the parallel filesystem is
  built for metadata traffic.
- **Grace period 270 s** (Nextflow's default). The cost of being wrong is asymmetric: waiting delays
  one result, giving up early reports a successful simulation as failed.
- **No empty-file check.** The sentinel is staged through a temp name and `mv`'d, so a listed sentinel
  always has its content.
- **`squeue -u`, not `-j <list>`.** `-u` maps to `slurm_load_job_user`, server-side filtered, one RPC
  regardless of tracked count; the source does not show `-j` avoiding a full job dump.
- **A failed `squeue` query resolves nothing** (`nothing`, never an empty set). Conflating them fails
  every tracked simulation the first time slurmctld is slow; first test written.
- **`trap ... EXIT` only, no `TERM`.** A scheduler kill resolves through the reaper; signal traps add
  shell that must be right under every `sh`. Generated text verified under macOS `sh` and `dash`.
- **Completion machinery keys off a job existing, never off `run_on_hpc`.**
- **No central watcher.** Each worker waits on its own sentinel (`isfile` once a second). Gone: the
  registry `Dict`, per-job `Channel`, lazy lifecycle and its race, one-bad-sweep blast radius. The
  reaper is one TTL-cached `squeue` snapshot behind a `trylock`, one RPC per `reap_interval`.
- **ModelManager runs the command.** `simulationCommand(sim, spec)` is the required hook;
  `runSimulation` is a default owning output folder, `output.log`/`output.err`, working directory and
  local-vs-SLURM dispatch. `prepareHPCCommand`/`runHPCSimulation` deleted; `hpcDoneDir` internal.
- **The sentinel is named before submission**, `<sim_id>.<time_ns hex>`, baked into the wrap. Unique
  per submission, so no stale-sentinel `rm`, no race, and no `$SLURM_JOB_ID` in the trap.
- **Snapshots stamp the query's start**; workers skip snapshots with `taken_at <= submitted_at`;
  monotonic `time_ns()`. The grace clock is worker-local, set at first absence, cleared on reappearance.
- `-t all` (SUSPENDED is otherwise invisible); `SQUEUE_*` cleared from the environment; parse only
  after `wait(p)`; a hung `squeue` is killed and left, not waited on (a grandchild can hold the pipe);
  the local path uses `success(p)` because a signal-killed child reports `exitcode == 0`.
- **A `Cmd` with an environment is rejected**: `Cmd.env` *replaces* locally while `sbatch --export`
  extends, so the same command would mean two things.
- The default `runSimulation` `mkpath`s the simulation folder (`prepareTrialHierarchy` makes monad
  folders only). Stray sweep runs on `reap_interval`; the age gate is the safety property.
- **The wait returns the exit code** (`Union{Nothing,Int}`); the default `runSimulation` is the one
  place that collapses it to `SimulationProcess.success`.
- **Job-ID parsing is line-anchored, exactly one, classic `Submitted batch job N` accepted.** A site
  banner had made the old parse fail while the job ran unobserved.
- **Production `Ref` test seams removed**; tests put file-driven `sbatch`/`squeue` scripts on `PATH`.
- **`done_dir` configurable, defaulting inside `data/`.**
- **Ships as v0.9.0, not a v0.8.4 patch.** v0.8.3 does not auto-detect `run_on_hpc`, so 0.9.0 is where
  the exposure appears; dropping compat allowed the cleaner fix. Nothing in source mentions v0.8.4.
  PCMM must implement `simulationCommand`, drop its `runSimulation` override, and take a minor bump.
- **Deferred:** a throwing `runSimulation`/hook strands rows at `Running` and a re-run reports them as
  found. `simulationFailed` is not the abort route (it erases constituents and cascades deletion).

### Rejected
- One watcher polling `squeue` for every job: the poll interval becomes a throughput tax that grows as
  simulations get shorter.
- "Sentinel files don't work on clusters": conflated inotify event delivery (local-kernel) with
  visibility (`readdir` works on NFS/Lustre/GPFS).
- A TCP callback from the job: no POSIX-guaranteed way for a job to send, compute nodes may not route
  back, and batch semantics sever submitter from job.
- A non-blocking `sbatch --parsable` from `prepareHPCCommand`: a simulator running the `Cmd` itself
  would record every simulation Completed at submission. Deprecate-and-add-alongside: inert until
  PCMM released. A blocking `prepareHPCCommand` (first pass) was superseded once compat was dropped.
- Moving `data/` to scratch: purge-swept.
- Re-basing the grace clock on each refreshed snapshot: with `grace > reap + poll` a killed job hangs
  forever.

### Traps
- A test that publishes a sentinel after a fixed `sleep` races a cold JIT; every hand-rolled repro
  passed because it had warmed the JIT. The helper now reads the sentinel path from the shim's recorded
  `sbatch` argv.
- NFS caches directory attributes (30–60 s), so a sentinel can take up to a minute to appear; a visible
  sentinel does not prove the simulation's *output* is visible, so a `post_processor` enumerating output
  on a laggy mount may need a bounded retry.

---

## Session: mid-session package update silently skipped migrations (2026-08-17)

`getPackageVersion` read the installed version from the manifest while `upgradeMilestones` came from
the loaded module. After `Pkg.update()`, a re-`initializeModelManager` (or a new project created in the
same session) stamped the new version with the old code's milestone list, so the migration was skipped
permanently and silently; the resulting database is byte-identical to a clean one.

### Decisions
- **Migrate to the loaded version; never refuse for a version mismatch.** The loaded release is the
  furthest a session can correctly migrate to, so the recorded version and the applied migrations come
  from one source and the corruption is unrepresentable. The next session applies the remainder.
- **The guard sits above `getDBPackageVersion`**, which stamps a database with no version table — the
  only code on the new-project-mid-session path (mutation-tested: reverting it corrupted that path).
- **`@warn`, `maxlog=1`** when loaded differs from installed in either direction; fixed per session.
- **No determinable loaded version → warn and return `true` without migrating.** Nothing to migrate
  *with*; the project opens untracked. `getDBPackageVersion` throws in that state rather than inventing
  a version, and is unreachable from init because the short-circuit returns first.
- **`upgradePackage` keeps its own guard, refusing (`>`) rather than clamping**; a target below the
  loaded version is legitimate (resuming a partly-applied chain).
- **The "database is newer" remedy is split**: restart Julia when the session lags the environment,
  upgrade the package otherwise.
- **Identity is the module defining `typeof(sim)`**: `_packageModule(sim) =
  Base.moduleroot(parentmodule(typeof(sim)))`, internal and not configurable. `upgradeMilestones` and
  `upgradeToMilestone` dispatch on the simulator type, so the schema-owning code *is* that type's
  package; defining them elsewhere would be piracy. Loaded version via `pkgversion(mod)`; installed via
  `Pkg` keyed on the module's UUID, because a `PkgId` is `(uuid, name)` and a name lookup takes
  whichever match iteration reaches first.
- **`packageName` removed outright.** Messages interpolate `nameof(_packageModule(sim))`, so the name
  shown cannot disagree with the version reported. Required PCMM change: its `packageName` method fails
  at precompile with `UndefVarError`.
- **`getPackageVersion` → `getInstalledVersion`** (exported; breaking, not deprecated, pre-1.0).
- **All version diagnostics in one block** in `package_version.jl` with one vocabulary
  (`installed`/`loaded`/`db_version`): `@warn` for restart-recoverable, `@error` for unsupported,
  `@info` for progress. `continueMilestoneUpgrade` stays `println`, since a `readline` follows.
- **`initializeModelManager` clears `initialized` at entry and every early-`false` path goes through
  `_abortInitialization()`** (four sites, including the DB-open `catch`, which had left `db` pointing at
  the previous project). Safe: nothing before `initializeDatabase` consults `isInitialized()`.
- **A throwing `getInstalledVersion`** (reachable: `Pkg.activate(mktempdir())` after loading) is caught
  and routed through `_abortInitialization`; a cosmetic lookup must not kill initialization.
- **Released as 0.9.0.** Two public names disappear; PCMM's `"0.8"` compat keeps it on the old version
  until it raises the bound and deletes the method together.
- **The `@ref` guard testset reports "public but has no docstring"** separately from "not public";
  Documenter fails an `@ref` to either.
- **Backend discipline instead of a `migrations_applied` table**; revisit if a release ever ships a
  schema change without its milestone. Recorded as a warning admonition in
  `docs/src/misc/database_upgrades.md`.

### Rejected
- Refusing to initialize on loaded ≠ installed: for a backend whose type lives in a different package
  than the one named, the mismatch holds every session, so it bricks that backend.
- Detecting the update in `__init__`: it runs before the discrepancy exists, no project or database
  exists yet, and the version that matters is the backend's.
- A `migrations_applied` audit table: the only way to detect an already-corrupted database, but the
  corrupted set is unknowable rather than small; user's call.
- An `allow_version_mismatch` keyword: mooted once the refusal was dropped.
- `loadedPackageVersion` as a public overridable hook: no override case survives, since any value other
  than the real loaded version breaks the comparison. Made internal, then deleted with
  `_loadedModuleNamed` when identity moved to the module.
- A `packageModule` redirect hook: a capability nobody should want.
- Fixing `currentSimulatorVersionID()` staleness here: distinct, pre-existing, backend-driven.

### Traps
- `success == true` from `upgradePackage` does not mean a migration ran; an empty `pending` satisfies it.
- A milestone added *below* a version some database already recorded is skipped forever, because
  `pkg_version == db_version` short-circuits before `upgradePackage`.
- A `#!` comment between a docstring and *any* definition form (one-line or `function…end`) silently
  detaches the docstring. CLAUDE.md says "every definition form".
- A manual-page anchor `@ref` in a `src/` docstring breaks downstream builds (PCMM renders the
  docstrings, not the manual pages); the guard testset matches only backticked binding refs.
- Submodules are not in `Base.loaded_modules`, and `pkgversion` resolves through `moduleroot`, so a type
  in a submodule reports its package's version without any override.
- A warning must not promise an outcome a later branch can refuse ("will be migrated" → "migrations
  target <loaded>").
- A test asserting zero milestone calls after a refused upgrade proves nothing when the milestone list
  is empty.
- Rationale that felt necessary while a bug was live reads as padding once the fix is in; it belongs
  here, not in docstrings.

---

## Session: Calibration as coalesced `Sampling` views + taggable `Calibration` (2026-08-17)

Brief 4 of 8. A calibration's monads become addressable as `Sampling` views (run-wide and per
generation), and `Calibration` joins the tag subsystem.

### Decisions
- **`Calibration` is not in the containment hierarchy and not an `AbstractTrial`.** Containment is
  batch → generation → calibration and the groupings overlap (a poset, not a chain); a `Sampling`'s
  constituents are `Monad`s and never other `Sampling`s. Subtyping would also make `run(::AbstractTrial)`
  dispatch on a `Calibration` and call `prepareTrialHierarchy` on it.
- **Views are legal because every calibration monad shares `problem.inputs`**, so any subset is a valid
  sampling. Coalescing is what makes the `GSASampling` single-wrapper pattern applicable.
- **The accessors do not materialize** (deviation from the brief): `monadIDs(cal[, t])` and
  `simulationIDs(cal[, t])` are pure reads; only `Sampling(cal[, t])` inserts. A mid-run read would
  otherwise pin a partial monad set the finished run never reuses. Documented rather than gated: the
  `calibrations` row has no completion flag, and generation count against `max_nr_populations`
  misreports every run that stopped early on a convergence criterion.
- **Exact-set find-or-insert means a single-batch run's run-wide view *is* the batch row.** A feature,
  pinned both ways (multi-generation run gets its own row; single-batch run adds none).
- **`include("tags.jl")` moves to the bottom of `src/ModelManager.jl`.** A method signature is evaluated
  at definition, so `_tagClass(::Type{Calibration})` needs the type loaded; every call *into* tagging
  from an earlier file is inside a function body, so nothing before it needs its names. A `#!` at the
  include site states the rule.
- **Per-type `Calibration` methods (19), as thin delegations** over the string-keyed private cores
  (`_tags`, `_tagsTable`, `_deleteTagRows`, …). Deliberately not extended: `tag!(ids::Vector{Int})`
  (a bare integer vector means simulation IDs), `findSimulations`/`findMonads` (inheritance-aware),
  `trialFolder` (`calibrationFolder` yields the same path).
- **Calibration-class tags do not inherit downward (v1).** `_inheritedIDs(::Type{Calibration}, …)`
  returns `Int[]`; `mm:calibration` on each generation's sampling is the route to a run's monads. The
  run-level tag is the durable record, since a monad cascade never touches the `calibrations` row.
- **`calibrationMonadIDs` returns sorted, deduplicated IDs**, not generation-grouped: `compressIDs`
  sorts as it writes, so within-generation order is unrecoverable, and `monadIDs(Sampling(cal))` reads
  back sorted anyway. Fixed here: an `endswith` match that folded the failed-monads file in, no dedupe,
  and a lexicographic sort that misordered mixed padding. Generation scope is `calibrationMonadIDs(cal, t)`.
- **`mm:method` on the run is the method type (`"ABCSMC"`)**, matching GSA; the `calibrations.method`
  column keeps `"ABC-SMC"`. Stamped in `runCalibration` only, since the tag records what created the run.
- **`createCalibration`'s stamp uses the ISO `T` form**; safe because the column had been write-only.
- **No `up.jl` milestone**: `provenance_id` is added by `ensureProvenanceColumns`. A pre-existing
  calibration reports `mm:created` (from its `datetime`) but no provenance.
- **Everything new lives in `src/calibration/calibration.jl`**, since `database.jl`/`deletion.jl` load
  before `Calibration` exists.
- `calibrationsTable` takes no `limit` (nothing materializes); `show(::Calibration)` never throws
  (`Calibration(999999)` is constructible); `calibrationFolder`/`calibrationsDir`/`calibrationMonadIDs`
  stay internal.
- **The run-level surface also dispatches on `ABCResult`**: `Sampling`, `monadIDs`, `simulationIDs`,
  `tag!`, `untag!`, `tags`, `hasTag`, `tagsTable`, `calibrationsTable`, `deleteCalibration`.
- **`description` is not decided here.** The manual steers users to tags. Recommendation for the entry
  point unification: keep the column, stop documenting the keyword, have it write a tag.
- **Rowid reuse is real** (no MM table uses `AUTOINCREMENT`, so a deleted max-rowid ID is reissued).
  Tag rows and parent CSVs are cleaned at deletion, so tag-based recovery is immune. Exposed:
  `deleteSimulations(ids; delete_supers=false)` returns before parent-CSV filtering, and calibration's
  per-generation monads record is never rewritten. It cannot reach a posterior, because a deleted
  monad's distance is `missing` and never accepted. `AUTOINCREMENT` is a CLAUDE.md to-do for the next
  migration.

### Rejected
- An `AbstractTaggable` supertype: widens ~21 signatures in `tags.jl`, touches `classes.jl`, adds a
  layer to the public type tree. Revisit if a third taggable family appears; the delegation layer is
  what it would replace.
- Generations as `Trial` rows or a `Generation` type: `posterior` and the recipes need no identity; a
  `Trial` row would make the find-or-insert `trialID(::Vector{Sampling})` load-bearing; a type needs a
  sixth `TAG_CLASSES` member and its own table.
- An `AbstractMMOutput` supertype: the three wrappers name their payloads differently, so it unifies
  nothing without a `resultTarget` accessor. The shape to build if a fourth wrapper appears.
- Subtracting `failed_monads.csv` to recover deleted monads: it holds monads with at least one failure,
  not monads with no success.

### Traps
- **Sobol' determinism pins values in calibration tests.** Generation 1's first CDF draw is exactly
  `0.5`, so `Uniform(a, b)` runs the monad at `(a+b)/2` to completion — a continuous prior still pins an
  exact parameter value. Calibration test ranges live in 100–117, disjoint from every fixed
  `DiscreteVariation` value (0.5, 1, 7, 31, 41, 42, 43, then nothing until 311).
- Rowid reuse looks like the cause of ordering-dependent test failures and usually is not.
- Building a view is one `SELECT` per monad (no bulk `Monad` constructor); the follow-up if it bites.
- `tagValues(MM_CREATED_KEY)` iterates `TAG_CLASSES` and gained `calibrations` the moment the class
  was added; adding a class exercises every such loop.
- Pure-lookup accessors are a repo convention arrived at twice (#31 for `trialID`/`monadIDs`, this change
  for the calibration accessors); do not "simplify" either back into a find-or-insert.

---

## Session: `run_on_hpc` was never auto-detected (2026-08-05)

`run_on_hpc` had exactly one writer (`useHPC`); `isRunningOnHPC()` was exported dead code, and both
`src/globals.jl` and `hpc.md` already described the auto-detection that did not exist. On a cluster
`rm_hpc_safe`'s staging was off and PCMM never reached `sbatch` unless the user called `useHPC()`.

### Decisions
- **Probe just before `postInitDisplay`**, after every early-return path of `initializeModelManager`,
  so no failure block gains a fourth global to reset.
- **Re-detect unconditionally on every init**; a prior `useHPC(false)` is discarded. No sticky override
  flag: a new global for a rare case, and init already resets other per-session state. Not documented
  for users.
- **`useHPC(true)` when already on warns once** (`maxlog=1`): that call is the signature of a script
  written to work around this bug. (Shipped in v0.9.0; the v0.8.4 tag planned here was never cut.)
- **Reverses #26's delegation of detection to backends.** A PCMM audit found `useHPC` only in its tests
  and `isRunningOnHPC()` called only to pick `march_flag`; delegating duplicates the decision per
  backend and leaves `isRunningOnHPC` dead here.
- Verified with a fake `sbatch` shim on `PATH`. The testset asserts `run_on_hpc == isRunningOnHPC()`
  and restores the detected value in a `finally`, since a stale `true` would send every later deletion
  test down the staging path.

### Rejected
- A lazily computed `Union{Nothing,Bool}` field: touches `deletion.jl`, `postInitDisplay` and every
  PCMM read for no gain over a one-line eager set.
- Asserting the warning with `@test_logs`: `TestLogger`'s `maxlog` handling varies across the 1.10 floor.

### Open questions
- `run_on_hpc` is the wrong predicate for "my data is on NFS" (from #26); auto-detection sharpens it,
  since staging now switches itself on wherever `sbatch` exists.

---

## Session: rm_hpc_safe try-then-stage, warning, and sweep (2026-08-03)

On HPC `rm_hpc_safe` only renamed the target into `data/.trash/`, and nothing ever emptied it: a
cluster project never reclaimed a byte and `resetDatabase` doubled disk usage.

### Decisions
- **Try `rm` first; stage only what survives.** Returns `:removed`/`:staged`/`:unremoved`; a staging
  failure warns and returns `:unremoved` rather than throwing, since callers have already deleted rows
  and mostly loop.
- **Warn once per project for `:staged`**, latched on `trash_staged_warning_shown::Bool` (cleared by
  `initializeModelManager`). **`:unremoved` is never latched**: each occurrence names a different leaked
  path and is the only record of it. `maxlog=1` cannot implement warn-once (per call site per session;
  `TestLogger` resets it per block).
- **Background sweep** from the diagnostics task, gated on `isdir(".trash")` rather than `run_on_hpc`
  (`useHPC()` is usually called after init). `databaseDiagnostics` reports what remains and distinguishes
  an unreadable `.trash` from an empty one.
- **No age threshold on the sweep.** Concurrency is handled where it happens: `_stageInto` recreates the
  bucket and retries the move up to three times, recomputing the destination each attempt. The sweep
  touches only `^data-\d{6}$` entries. `last_trash_sweep` is stamped before the `isdir` check, and
  staging re-sweeps when the day rolls over.
- **Staging cannot go cross-mount.** A cross-mount `mv` is `cp` then `rm(src)`, and that `rm` is the
  refused operation (demonstrated: 100 000 bytes copied, delete failed, consumption doubled). Put
  `data/` on scratch instead.
- **Path mapping is strict component-wise containment** plus an `_external/` branch; the old
  `replace`-based mapping could silently rename a target in place. An empty `dataDir()` is an explicit
  error surfaced as `:unremoved`.
- **The collision-suffix search is unbounded**, with strict `ispath`/`islink`; each iteration tests a
  distinct path, so the check terminates. `_existsQuietly` stays only for the residue check, where
  "cannot tell" must mean "something may be there".
- Fault injection in tests is root-proof: `recursive=false` on a non-empty directory, and a regular file
  where `.trash` should be.

### Rejected
- Stage first, then delete: better interruption safety, more machinery than warranted.
- `emptyTrash()`/`trashPath()`: the sweep plus warnings naming a ready `rm -rf` cover it, and a shell
  `rm -rf` beats Julia's `rm`, which aborts its walk on the first non-`EACCES` error.
- A silencer for these warnings: they report a requested deletion that did not happen.
- A `stat().device` cross-device guard: APFS volume groups share `st_dev`; moot once the staging root
  stopped being configurable.
- A two-day age threshold on the sweep: replaced by retry-where-it-happens.

### Traps
- On Julia 1.10/1.11, `rm`'s recursive walk aborts on the first `EACCES` child (per-child recovery
  arrived in 1.12), `mv` falls back to `cp` + `rm` on any error, and there is no portable strict rename.
- `Date("260803", "yymmdd")` parses the year as 26; build the `Date` from digit pairs.
- A `\$` in a docstring is what makes the rendered text contain a live `$(...)`; a bare `$`
  interpolates at load time.
- Tests restore `useHPC(false)` in a `finally`; a throw skips the rest of a testset body.

### Open questions
- `run_on_hpc` is the wrong predicate for "my data is on NFS": Lustre/GPFS users pay for staging they
  do not need, and an NFS lab server that never calls `useHPC()` gets bare `rm`.
- `.trash` was an accidental undo buffer on HPC (nothing was ever deleted there); an undocumented
  capability loss that belongs in release notes.

---

## Session: docs findability pass (2026-08-01)

Post-processing was undiscoverable: 96 lines inside `man/running_simulations.md` under a `##` heading
Documenter only surfaces once you are on the page, and the analysis-table API had 12 lines of narrative
under `man/database.md`'s `## Querying`.

### Decisions
- New `man/post_processing.md` and `man/tables.md`; `index.md` rewritten as task-grouped routing tables;
  a Results & Analysis sidebar group; `@id` anchors on every man/misc H1 with inbound heading refs
  converted in the same commit.
- **Deleted the 18 `Public = false` `@autodocs` blocks.** Search index 524 → 361 entries, 86 → 0
  underscore-prefixed. Not rendering is the only lever: Documenter indexes every rendered docstring
  unconditionally and no option excludes anything from search. The blocks were not load-bearing for the
  guard testset, which reads `Docs.meta(ModelManager)` and never opens `docs/`.
- **27 bindings the manual documented but never declared** were resolved by CLAUDE.md's existing
  criteria: 19 promoted to `@compat public` (types and accessors in public signatures, the backend
  contract, functions the manual tells users to call) and 8 delinked to plain code spans.
- **PCMM dependency audit** at `674785d3c`: 83 bindings reached into ModelManager, 33 undeclared. The 16
  used in PCMM's `src/` were promoted (the XML layer, `prepareTrialHierarchy`, …); the 17 used only in
  PCMM's tests were left undeclared, since tests poking internals is not an API contract.
  `prepareTrialHierarchy` came back because PCMM docstrings `@ref` it, not because of a call.
- No PRD entry or README row: `PRD.md` has never carried a documentation entry.
- Two stale `#!` ownership comments removed: `database.jl:3` (claimed `simulationsTable` was
  simulator-specific) and the phantom `runSensitivity` in four places.

### Traps
- **An explicit `@id` *replaces* a heading's title slug**; every inbound bare `[Exact Title](@ref)`
  breaks and must be converted in the same commit. A green build is the link check (no `warnonly`).
- Documenter's `Header` resolver runs before `Docs`, so a heading `## LHSVariation` silently captures
  ``[`LHSVariation`](@ref)`` while a heading with a qualifier does not.
- The guard testset scans docstrings only: manual-page `@ref`s, anchor-form refs, and names in `#!`
  comments are outside it. Inheriting a neighbouring comment's phrasing inherits its bugs.
- CLAUDE.md's premise that a downstream build renders only the public API was not true of PCMM at
  `674785d3c` (it carried `Public = false` blocks for `ModelManager`); the promotions declare a real
  surface rather than repair a build.
- `running_simulations.md` deliberately names the three-hook order in two sentences; do not re-expand it.

### Open questions
- 22 backticked type refs land on same-page headings rather than docstrings (`space_filling.md`,
  `variations.md`, `trial_hierarchy.md`, `project_configuration.md`); the fix is the
  `## Qualifier: TypeName` heading pattern.
- `## Building a backend` in `installation.md` duplicates steps 1–2 of `building_a_simulator.md`, and
  the registry step exists only there.
- Shared-filesystem guidance is duplicated across `hpc.md` and `managing_data.md` with no cross-link.
- `src/sensitivity_visualize.jl` is in no lib page's `Pages` list; `endswith` matching would land it on
  `lib/calibration.md`, and `lib/utilities.md`'s leading-slash `Pages` entry is the only, undocumented,
  defence.

---

## Session: Trial tagging and feature-based recovery (2026-07-29)

Nothing in the schema recorded *why* a simulation exists — identity, configuration and status only —
so recovery depended on a script's ID list staying in sync with the database. Two consequences shaped
the design: the highest-value tags had to be automatic (a table users must remember to fill has the
same failure mode as the ID list), and retroactive tagging off a query result is the primary path.

### Decisions
- **One denormalized `tags` table with a polymorphic `trial_class` TEXT column**, matching the
  `for T in (Simulation, Monad, Sampling, Trial)` idiom. SQLite cannot foreign-key it, so integrity
  rests on the deletion hooks plus `orphanedTagCounts` in diagnostics.
- **Key/value, with `tag_value` inside the `UNIQUE` constraint** so a key can be multi-valued.
  `tag_value` defaults to `''`, never `NULL`: SQLite treats `NULL`s as distinct under `UNIQUE`.
- **Keys are identifiers, values are data.** Keys lowercased, whitespace-stripped,
  `[a-z0-9][a-z0-9_.-]*`, max 64; values trimmed of surrounding whitespace only. `mm:` is unforgeable
  because `:` is outside the key charset — no reserved-word check exists.
- **No migration milestone.** `CREATE TABLE IF NOT EXISTS` plus `ensureProvenanceColumns` `ALTER
  TABLE`s guarded by `columnsExist`, both from `createSchema`; PCMM implements nothing. Tested by
  dropping the tables and the columns, reinitializing twice.
- **A tag is stored once, on the object it is placed on; inheritance is resolved at query time** by
  walking constituent CSVs (parent/child edges are not in SQL). Fanning out would go stale when a
  replicate is added.
- **Tags are a keyword argument** on `createTrial`/`run`: construct, then `tag!` the result. No ambient
  scope, no global mutable tag state. Framework tags use the same path via `tagReserved!`.
- **`run(Ts::AbstractVector; tags)` tags the constituents, not the umbrella `Trial`.** The umbrella is
  deduplicated plumbing that `deleteTrial(id; delete_subs=false)` removes; measured: with the tag on the
  umbrella alone, deleting it made every simulation unfindable. A container too ephemeral to label is
  too ephemeral to be a label's only home.
- **Tags are written before dispatch**, so an interrupted run keeps them and an in-flight campaign is
  queryable. `mm:method` on GSA likewise moved before the run (`buildAndRunSensitivitySampling`).
- **Provenance is stored as columns** (`datetime`, `provenance_id` on the four trial tables; a
  `provenances` table `UNIQUE` across its columns) and synthesized back into `mm:` keys by `tags`,
  `tagsTable`, `appendTags!`, `tagKeys`, `tagValues`, `findTrials`. Measured at 10⁵ objects: 21
  bytes/object, against 290 for two normalized tag rows and 1139 for six tag rows (each EAV row is
  stored three times: table, `UNIQUE` index, lookup index).
- **Provenance attaches per object, first writer wins** (`WHERE provenance_id IS NULL`), stamped only on
  the branch that inserts. A monad grown from 2 to 5 replicates by a second script keeps the first
  script on itself and its first two simulations.
- **Script attribution**: non-interactive → `PROGRAM_FILE`; interactive → the outermost frame under
  the active project or working directory (an `include`d script wins), else the launcher, else `""`.
  `mm:interactive` is a separate flag, since interactivity is a session property and the script a frame
  property. Frames are filtered by `isfile` rather than by matching `REPL[`, which rejects every
  front-end's pseudo-file uniformly.
- **Git via `LibGit2`** (approved), read on entry to each `createTrial`/`run` call so mid-session edits
  are attributed; a changed state yields a new `provenances` row through `UNIQUE`. Branch captured.
- **`simulationsFromIDs` builds objects in one query**; object-returning finders refuse result sets
  above `MAX_MATERIALIZED_TRIALS = 10_000` (`limit` overrides); ID-returning forms stay unbounded.
- **`tag!`/`untag!` accept `AbstractVector{<:Union{Integer,Missing}}`**, the type a
  `simulationsTable` `SimID` column has (found by the sandbox, not the suite).
- **The accessor stays `tags`**; `ModelManager.tags(sim)` is the workaround if a user variable shadows it.
- **No `EXCLUSIVE` transaction anywhere.** `Monad` and provenance use `INSERT OR IGNORE` against
  `UNIQUE`, which self-corrects; `_insertTagRows` uses a plain transaction for batching only. `Sampling`
  and `trialID` scan constituent CSVs before inserting, so holding the write lock across file I/O would
  also need `busy_timeout`; concurrent trial creation is unsupported by decision. Remedy if duplicate
  `samplings`/`trials` rows ever appear: `withTransaction(mode="EXCLUSIVE")` at those two sites plus
  `PRAGMA busy_timeout` in a single `openCentralDB`.
- Pivoted columns are `tag:<key>`; `tagsTable()` with auto tags is guarded by `MAX_MATERIALIZED_TRIALS`;
  `findSimulationIDs` uses one bounded query; hint latches fire before deciding; `appendTags!` memoizes
  constituent reads.
- `inherit=true` is the default; `mm:` stays a string prefix; simulator version is not tagged (already
  a foreign-keyed column the backend owns).
- `sandbox/` with a `ToySimulator` demonstrates recovery without IDs against a real database.

### Rejected
- A normalized `tags`/`taggings` pair, four per-class tables, bare labels only.
- Copying parent tags down (goes stale); storing outcomes as tags (the sink has types and ranges);
  tagging only at `createTrial` (`run` operates on upstream inputs); a registered vocabulary (deferred).
- Ambient scope, `withTags`, `@tag`, task-local storage, a provenance TTL: all deleted once tags became
  a keyword — two design rounds spent on a mechanism whose only advantage a helper's own `tags` kwarg
  provides.
- Provenance on monads with inheritance: stamps a later session's simulations with the original context.
- Renaming the accessor `trialTags`; a `datetimes` lookup table (a pointer costs as much as a stamp);
  a `ReentrantLock` (SQLite.jl's do-block `transaction` is a `SAVEPOINT` and nests fine).
- Shelling out to `git` (used until `LibGit2` was approved).

### Traps
- A `#!` comment between a docstring and its definition detaches the docstring silently; seven were
  orphaned and only the one `@ref`'d from another page errored.
- VS Code launches its REPL as `julia …/terminalserver.jl`, so `PROGRAM_FILE` names the extension
  driver. Two reproductions were wrong before one was right: "I reproduced it" needs the scrutiny of
  "I fixed it". The `isfile` test must precede the containment test, because `Base` frames report bare
  filenames that `abspath` resolves under `pwd()`.
- Every test built ID vectors from `simulationIDs` (a clean `Vector{Int}`), never from a table.
- Julia 1.12 lets a top-level assignment shadow a `using`-imported function silently, even after it
  has been called.
- `"mm:"[4:end]` is a valid empty slice, not a `BoundsError`; pinned by a test.
- `PRAGMA busy_timeout` is per-connection and reset by a reopen; ModelManager opens the central
  connection twice (`initializeModelManager`, then `initializeDatabase`).
- SQLite.jl's do-block `transaction` sets `PRAGMA synchronous = OFF` for its duration.
- A mechanical rename needs a read-through afterwards ("The accessor is `tags`, not `tags`").
- Scale bugs hide in a test project: a full `SELECT` per finder call, an unlatched `COUNT(*)` on
  every query, a CSV walk per tag row.

### Open questions
- Orphaned `provenances` rows are never cleaned up; bounded by session count.
- Concurrent `createTrial` (in-session or across sessions) is unsupported; `recordConstituentIDs` is
  read-modify-write on a CSV outside SQLite's reach.
- Exact-value queries on `mm:created` compare the stored string, so a legacy `yymmddHHMM` `trials`
  stamp does not match an ISO filter. Moving the `datetime` columns to INTEGER unix seconds (and
  dropping `_normalizeStamp`) was targeted for a breaking release.
- Should `reinitializeDatabase` be exported? Tag-based seeding of a `SimulationBank` is not done.

---

## Session: GSA sensitivity plot recipes (2026-06-17)

The calibration results had `RecipesBase` recipes; `MOATSampling`/`SobolSampling`/`RBDSampling` had none.

### Decisions
- New `src/sensitivity_visualize.jl`, in-package: `RecipesBase` is already a hard dependency and the
  calibration recipes set the precedent.
- **Builders take `(results, monad_ids_df, …)`, not the `GSASampling`**, returning lightweight wrappers
  (`_GSABarData`, `_GSAViolinData`, `_GSAScatterData`); tests fabricate `MorrisResult`/`SobolResult`
  objects plus a `DataFrame` and call `apply_recipe` with no database.
- One series per quantity in sorted label order; the label prefix appears only when more than one.
- Parameter names come from `monad_ids_df` minus the per-method bookkeeping columns (`base`; `A`,`B`; none).
- MOAT has three styles via a positional `style::Symbol` (`:bar` with `show_sigma` whiskers, `:violin`
  resolved by the backend, `:scatter` with offset `annotations` rather than `series_annotations`, which
  centres text on the marker). Sobolʼ `show_ST` overlays at `fillalpha=0.45`.

### Rejected
- Three independent recipes with duplicated styling; an `ext/` extension.

---

## Session: documentation rework + logo (2026-06-17)

Replaced a single-page `@autodocs` dump with a `man/` + `lib/` split (`checkdocs=:exports`, one lib
page per source file, calibration aggregated) and added the gear-disc logo.

### Traps
- `CurrentModule = ModelManager` is required on every man/misc page; without it `@ref`s to
  non-exported symbols resolve against `Main`, while exported ones work and mask the problem.
- Documenter's `Pages` filter is a path *suffix* match: `"utilities.jl"` also matched
  `xml_utilities.jl`; use `"/utilities.jl"`.
- Lib page titles must not collide with man H1s or `@ref` becomes ambiguous; the two Calibration pages
  use explicit `@id`s (`calibration_man`, `calibration_lib`). Multi-word header refs are quoted.
- `checkdocs=:exports` does not flag an *undocumented* export; it rendered blank.
- Variation examples wrap targets in `XMLPath(...)`; the constructors require it to keep the core
  format-agnostic.

---

## Session: calibration progress reporting (2026-06-17)

A run printed nothing between JIT and the end of generation 1, because `evaluate_batch` runs with
`quiet=true`.

### Decisions
- **Tiered `progress::Symbol`** (`:none < :generation < :batch < :bar`, plus `:auto` → `:bar` on a TTY,
  `:generation` otherwise). SLURM logs want textual milestones without carriage returns. Runtime-only;
  not persisted to `method.toml`, since it is an I/O preference.
- **A generic `on_progress` hook on `run`** emitting `:init`/`:step`/`:finish` from the existing
  completion loop; with `nothing` the runner is byte-for-byte unchanged. The bar is sized inside `run`
  (only it knows the pending count) and framed outside; zero-pending batches create no bar.
- **ProgressMeter imported qualified**: `using ProgressMeter: next!` shadowed `Sobol.next!`. New
  dependency approved.

### Rejected
- A `verbose::Bool`; a `ProgressMeter` inside `run` (couples the runner to a calibration concern).

---

## Session: feature/latent-inverse-maps — Visualization, resume robustness, LatentVariation enhancements (2026-05-17)

### Decisions
- `LatentVariation.target_names` names an `LVSource`'s target columns in display CSVs and
  `parameters.toml` (persisted as `target_display_names`).
- `inverse_maps` are auto-constructed for `DVSource`/`CVSource` and optional user input for `LVSource`,
  validated by round-trip at construction; omitting them disables bank lookup for that parameter
  only. `_bankCdfCoords` dispatches on `lv.inverse_maps` for every source type.
- `_validateStructuralMatch` gained the non-stripped `LVSource` branch `resumeABC` was crashing on.
- `_loadGenerations` scans the directory and parses indices, so a resume with a changed
  `max_nr_populations` finds files at any padding.
- `generation_cdfs/` made a subdirectory of `generations/` on both the save and load sides (the layout
  later replaced by per-generation folders).
- Recipes: `_safeKDE1D`/`_safeKDE2D` guard zero-variance inputs; `:transition`'s rejected proposals
  are lazily loaded from disk and fall back to accepted-only; `short_names=false` added to
  `simulationsTable` so raw XML-path names match `parameters.toml` keys.

### Rejected
- A `_reconstructCDFFromDisplay` fallback for runs missing `generation_cdfs/`: the directory has always
  been written, and a correct DVSource reconstruction needs `inverse_maps`.

---

## Session: Phase 2b — Populate ModelManager with generic infrastructure (2026-04-12)

Extract every simulator-agnostic piece of PCMM into ModelManager.

### Decisions
- **`mm_globals_ref = Ref{Union{Nothing,ModelManagerGlobals}}(nothing)`**, set by the simulator
  package in `__init__`; `mm_globals()` throws descriptively before that.
- **`postSimulationProcessing` is a no-op stub**; PCMM owns pruning. `run(T; force_recompile=false,
  kwargs...)` forwards `kwargs` to the hooks, so PCMM reads `prune_options` from them.
- `addVariationRows` is an interface stub (the writes are XML-specific); `insertFolder`'s PhysiCell
  behaviours became `getInputFolderDescription` (default `""`) and `initializeInputFolder` (no-op).
- `columnName` moved to `variations.jl`; `SobolMM` replaces `SobolPCMM` as the ASCII alias;
  `locationPath` overloads for `InputFolder`/`AbstractSampling` live in `classes.jl` after those types;
  `database_utils.jl` reduced to imports now that `database.jl` has `centralDB()` defaults.

### Open questions
- `shortVariationName` (PhysiCell-specific) was dropped from `LatentVariation.show` in favour of
  `columnName`.

---

## 2026-04-25 — Flatten SimulationSpec; split setup from collection

### Decisions
- **No `AbstractSimulationSpec`; `SimulationSpec.monad_id::Int`.** Setup always precedes collection,
  so `monad_id` is never `missing`.
- **`prepareTrialHierarchy` dispatches on `AbstractMonad` directly**, calling `setupSampling` and
  `setupMonad` on the object without creating a wrapping `Sampling` row or folder. `setupSampling`/
  `setupMonad` stubs take `AbstractSampling`/`AbstractMonad`.
- `pendingSimulationSpecs(::Simulation)` uses `Monad(simulation)`, an idempotent lookup because
  `createTrial` always creates the monad first.

### Rejected
- A `_toSampling(T::AbstractMonad)` wrapper: clean conceptually, but it creates database artifacts.

---

## 2026-04-25 — Calibration infrastructure migration from PCMM

### Decisions
- Files move to `src/calibration/`; `_saveGeneration`/`_loadGenerations`/`_saveMethod`/`_loadMethod`
  live in `abc.jl` (ABC-specific persistence) so `calibration.jl` stays a generic orchestrator.
- `calibrationsSchema()` moves to `database.jl` and is created by `createSchema()`; PCMM's
  `upgradeToV0_3_0` calls it so old upgrade paths still work.
- PhysiCell summary statistics stay in PCMM (`src/analysis/standard_qois.jl`). No new dependencies.

### Traps
- The bash sandbox's FUSE mount blocked `unlink()`, so PCMM's files were stubbed and the user ran
  `git rm` from their own terminal.

---

## 2026-04-25 — Remove kwargs from `runSimulation`

- `runSimulation(sim, spec::SimulationSpec)` takes no kwargs: no backend used them. `run` still
  forwards `kwargs` to `prepareTrialHierarchy` (→ `setupSampling`/`setupMonad`) and
  `postSimulationProcessing`, which do.

---

## 2026-04-27 — ABC-SMC parallel batch evaluation

### Decisions
- **`evaluate_particle` → `evaluate_batch`** (`Vector{Dict} → Vector{(Float64, Any)}` in proposal
  order); the core proposes a whole batch and stays simulator-agnostic, MM wiring stays in `abc.jl`.
- **Generation 1 is a single batch**, all accepted. **Generation t > 1 batches adaptively**: each round
  proposes `ceil(n_needed / acceptance_rate_est)`, the estimate initialised from the previous
  generation and floored at `0.01`; overshoot is trimmed, which is unbiased because particles within a
  batch are exchangeable.
- `_buildEvaluateBatch` creates one `Monad` per proposal, records monad IDs, runs one `Sampling`
  with `quiet=true`, and maps distances.

### Rejected
- A fixed 2× proposal multiplier: wastes work when acceptance is already high.

---

## 2026-04-29 — Remove CalibrationParameter; CalibrationProblem accepts AbstractVariation directly *(REVERTED — see 2026-04-30 redesign below)*

Implemented, then fully reverted in favour of the 2026-04-30 tagged-union redesign. Kept from it:

- **CDF values are the particle coordinates.** A `DistributedVariation`-backed latent prior is
  `Uniform(0,1)`, so the coordinate *is* the CDF and `variationValues(lv, cdfs)` maps it through the
  quantile; the algorithm lives on a bounded, well-conditioned space.
- `CalibrationProblem` accepts `AbstractVector{<:AbstractVariation}` and converts at construction,
  rejecting unsupported types with an `ArgumentError`.
- The four `LatentVariation` outer constructors were missing the `locations` argument (a silent
  `MethodError` on any call); fixed.
- `param_names`/`priors` are flattened with `vcat` so a multi-dimensional `LatentVariation` contributes
  M names and M priors.

### Rejected
- Storing `Vector{LatentVariation{<:Distribution}}` directly: loses the user's variation (display
  names, source provenance), which the next entry restores.

---

## 2026-04-29 — Task #17 design: CDF-grid snapping with generational refinement

### Decisions
- `k` is the exponent: spacing `1/2^k`, `2^k − 1` interior points per dimension. Default `k_start = 4`,
  auto-increased so `(2^k−1)^d ≥ population_size`.
- Generation 1 draws a Sobol sequence and snaps it; `k_t = k_initial + (t−1)` doubles resolution each
  generation, since reuse is most valuable early.
- Importance weights are computed at the snapped position with no Jacobian: the `O(1/2^k)` error
  shrinks each generation.
- A draw snapping to 0 or 1 is rejected; every interior point has an equal catchment.
- `cdf_grid_k::Union{Nothing,Int}` on `ABCSMC`, default `nothing` (disabled).

---

## 2026-04-30 — CalibrationParameter refactor + dual-CSV generation persistence

Generation CSVs held raw CDF coordinates (useless for inspection), and `resumeABC` required the
caller to re-supply the problem.

### Decisions
- **`CalibrationParameter` as an internal tagged union**: `source` (`DVSource`/`CVSource`/`LVSource`,
  the user's variation, for display columns and serialization provenance) plus `lv`, the derived
  `LatentVariation{<:Distribution}` the loop uses. `inverse_maps` on `LatentVariation` was rejected by
  the user at this point (adopted 2026-05-17).
- **Dual CSV output**: a human-readable display file in target space plus a raw CDF file for resume
  (then `generations/generation_NNN.csv` and `generation_cdfs/generation_NNN.csv`).
- **JLD2 as a hard dependency** serializing the full `CalibrationProblem` to `problem.jld2`, so
  `resumeABC(Calibration(id))` needs no problem. The old `resumeABC(calibration, problem, …)` is
  removed (breaking, approved).
- `posterior(::ABCResult)` converts in memory via `_buildDisplayDF`; `posterior(::Calibration)` reads
  the display CSV and strips `weight`/`distance`/`monad_id`. `_buildDisplayDF` returns particles
  unchanged when there are no parameters, so test-constructed results still work.

---

## Session: Fix acceptance rate overshoot bias (2026-04-30)

- **`acceptance_rate = n_accepted_total / n_evaluations`**, counting every proposal that passed ε
  whether or not it was kept. Truncation to `population_size` is bookkeeping, not rejection, so the
  rate reflects the kernel and ε rather than the population cap. `n_accepted_this_round` counts the
  same way, so the adaptive batch estimate is unbiased on the last batch too.

---

## 2026-05-01 — SimulationBank implementation (task #15)

### Decisions
- Terminology: a *column* has a column in the variation DB; a *parameter* is a `CalibrationParameter`
  target, which may not.
- **`variation_id=0` is the universal fallback row**: reference row value → `variation_id=0` → missing.
- **A calibrated parameter with no DB column** reads its base value from the config file via
  `getColumnDefaults`; outside the prior support the whole location is skipped, inside it every
  candidate variation inherits that value for CDF computation.
- **`CVSource` joint consistency**: recover `u` from the first target, forward-map the rest, compare at
  rtol `1e-8`; monads off the co-variation curve are excluded.
- **Non-calibrated columns in a calibrated location must equal the effective reference value**, so the
  bank holds only monads run with the intended background.
- Four phases: central query (version, folders, reference IDs for non-calibrated locations);
  per-location variation filtering; per-monad CDF inversion; interior filter `(0, 1)`.
- `LVSource` disabled the bank at this point (no inverse); superseded by task #19.

---

## 2026-05-02 — CDF-grid snapping implementation (tasks #23–26)

### Decisions
- `cdf_grid_k` on `ABCSMC`, validated ≥ 1, persisted as a top-level `method.toml` key (omitted when
  `nothing`).
- **Bank reuse by proposal substitution**: a bank hit returns the bank monad's *actual* CDF coordinates
  as the effective proposal, so `evaluate_batch` is unchanged and `use_previous=true` finds the monad.
- Generation 1 with snapping becomes iterative, deduplicating within the batch and against accepted
  particles. Two proposals snapping to one unused key within a batch: only the first registers, both
  count toward the acceptance-rate estimate.

### Rejected (same day)
- `GenerationResult.cdf_coords`: a transposed copy of `particles` nothing read.
- Grid-key dedup (`Set{Vector{Int}}`) and snap-first order: see the revision below.

---

## 2026-05-02 — KD-tree spatial index for SimulationBank

- `NearestNeighbors.jl` `KDTree` with `Chebyshev()` matches the L∞ box exactly; `inrange` returns the
  same candidates as the linear scan, in O(log n + k). `tree::Union{Nothing,NNTree}` is `nothing` for
  an empty bank; the 3-arg outer constructor auto-builds it so every call site is untouched.
  `_selectBankCandidate` deleted as dead code.

---

## 2026-05-02 — Revise CDF-grid snapping: lookup-first, monad-ID dedup, remove `cdf_coords` from `GenerationResult`

### Decisions
- **Lookup-first.** Search the bank around the *original* proposal and snap only when nothing usable is
  nearby; snapping first threw away reuse for no reason.
- **One dedup structure, `used_monad_ids::Set{Int}`** (plus a per-batch `batch_monad_ids`), fed by
  both the bank-hit path and the fallback snap. After evaluation every returned monad ID, accepted or
  not, is added: a monad already evaluated produces the same result, so it never runs twice in a
  generation.
- **`get_monad_id` resolver** (`_buildGetMonadID(problem)`) returns a snapped proposal's monad ID
  without running anything, since `addVariations` with `GridVariation` is idempotent; built only when
  `cdf_grid_k` is set and asserted present in `_runABCSMC`.

---

## 2026-05-03 — CDF-grid safeguards: k_base correction, snap_retry_limit, max_evaluations

### Decisions
- **`k_base_eff = max(cdf_grid_k, k_min)`** with `k_min = ceil(Int, log2(N^(1/d) + 1))`, the smallest
  `k` for which `(2^k − 1)^d ≥ N`; computed once, `@info` when it fires, never written to the struct.
- **`snap_retry_limit`** (default 100 when snapping; since removed from `ABCSMC`): that many *consecutive* `_lookupAndSnap`
  failures widen `k_eff` by one and reset the counter; any success resets it. `@info`, since widening
  is expected.
- **`max_evaluations`**: a `budget::Ref{Int}` initialised from resumed generations' `n_evaluations`;
  `_stoppingReason(…; budget_hit)` reports `"max_evaluations=N reached"` before any other criterion.
  (Enforced before dispatch since 2026-07-08.)
- `_snapAndTrack` and `_updateBudget!` extracted so the two generation runners share one copy.

---

## Task #19 — LatentVariation inverse maps + LVSource bank support (2026-05-04)

### Decisions
- `LatentVariation.inverse_maps::Union{Nothing,Vector{Function}}`, one per latent dimension, each
  `target_vals → u_i`. Auto-constructed from `cdf(dist, ·)` for DV/CV (the CV inverse returns `NaN` on
  a violated constraint, which `_bankCdfCoords` treats as `nothing`); user-supplied for LV.
- `validateInverseMaps` checks both round-trip directions at construction (now internal, as `_validateInverseMaps`).
- `_bankCdfCoords` dispatches on `!isnothing(lv.inverse_maps)` for every source type; Phase 2 skips
  support bounds for LVSource columns and Phase 3 excludes via `0 < u < 1`. The bank is enabled only
  when every LVSource parameter carries inverses.

---

## Task #20 — Kernel type hierarchy: `AbstractKernel` (2026-05-06)

### Decisions
- `AbstractKernel` plus `AbstractFittedKernel` (requested so `_computeWeights` can annotate at the
  fitted level). No intermediate abstract tier: abstract types carry no fields, so shared logic lives
  in free functions such as `_effectiveKernelScale`.
- **`LocalNNCovKernel` added as a fourth kernel** (user: a fixed covariance *direction* handles banana
  posteriors poorly); N Cholesky factorizations per generation against one for `LocalNNKernel`.
- **Inner constructors for validation.** An outer `GaussianKernel(-1.0)` was bypassed by the
  auto-generated inner constructor when the argument type matched the field type exactly.
- `_kernelDensity` uses the Cholesky log-pdf formula directly; `MvNormal` does not accept a `Cholesky`.
- Serialized as a `[perturbation_kernel]` TOML subtable with a `type` key; the legacy flat string
  raises a descriptive error.

---

## 2026-05-06 — Posterior visualization — all four recipes (task #7)

### Decisions
- **`space=:cdf`, not `:latent`** ("latent" already means LVSource parameters); default `:target`.
- **`store_rejected` is opt-in** (rejected proposals run 10–50× the accepted count), stored as CDF
  coordinates like `particles`.
- **Lazy disk fallback** for the `:transition` plot: the generation's monads record minus the accepted
  IDs, target values via `simulationsTable`; `space=:cdf` additionally needs inverse maps on every
  parameter, else accepted-only.
- Duplicates (common under snapping) are aggregated: accepted bubble area ∝ weight, rejected ∝
  count × `1/population_size`; the diagonal strip chart stacks so height is count.
- Recipes dispatch on `(::ABCResult)`, `(::ABCResult, ::Symbol)` and `(::DataFrame)` for the
  convergence trace; no named `plot_*` functions. `latent_params`/`target_params` take `generation=`.
  `KernelDensity` added as a dependency.

---

## 2026-05-18 — Relax CalibrationProblem type constraints; extend mseDistance

- `observed_data::Any`, and `evaluate_batch` no longer coerces the summary statistic to a
  `Dict{String,Any}`: the `distance` function interprets both arguments.
- Three `mseDistance` methods, deliberately heterogeneous in their reduction: `(sim − obs)²` for
  scalars, `Σ(simᵢ−obsᵢ)²` with a `DimensionMismatch` guard for vectors, mean of per-key MSE for dicts.

---

## Session: monadsTable — monad-level analysis table (2026-07-07)

### Decisions
- **One shared helper, `_variationsTableFromQuery(query, id_column, display_id_column; …)`**;
  `simulationsTableFromQuery` and `monadsTableFromQuery` are thin wrappers fixing the key column and
  the `sort_ignore` default, so the two tables cannot drift. The public `simulationsTableFromQuery`
  signature is unchanged.
- `monadsTable` mirrors `simulationsTable`'s four forms, collecting IDs through `monadIDs`.

### Rejected
- A `@test_throws` on `assertInitialized`: not testable inside the DB-backed testset, and
  `simulationsTable` has none either.

---

## Session: String variation values — considered and rejected (2026-07-07)

- **Do not add string values to `DiscreteVariation`.** Categorical parameters use a separate input
  folder per value; folders are already first-class. Strings would need Float64-locked internals
  generalised in three layers — the `LatentVariation{T<:Union{Vector{<:Real},<:Distribution}}` type,
  `variationValues`/`addVariationRow` sampling, and the `par_key` fingerprint
  (`reinterpret(UInt8, Vector{Float64}(vals))`) — ~150–250 LOC of medium risk for no gain over the
  folder route. `sqliteDataType` already maps non-numeric to `TEXT`, so nothing blocks that route.

---

## Session: Per-simulation post-processing hook + QoI sink (2026-07-07)

### Decisions
- **Two layers: a callback primitive and an opt-in sink.** `run(T; post_processor=f)` calls `f` once
  per successful simulation; `nothing` → side effects only, a `NamedTuple`/`AbstractDict` of scalars →
  an upserted row, anything else → `ArgumentError`.
- **One sink database at `data/outputs/postprocessing.db`, separate from the central one**, so there
  is no `up.jl` migration and no PCMM coordination. Table `post_processing`, PK `simulation_id`,
  columns grown by `ALTER TABLE ADD COLUMN` typed by value; created lazily on the first stored quantity
  so a side-effect-only callback never makes the file. Latest write wins.
- **The callback runs in the worker task; every sink write happens in the single-threaded completion
  loop**, the value riding the result channel in `_PostProcessedResult`. User code never touches the
  sink connection.
- `post_processor` is an explicit keyword, not forwarded to the setup hooks; `MMOutput` is unchanged.
- **Ordering: `postSimulationProcessing` (non-destructive) → `post_processor` → `postSimulationCleanup`
  (destructive, regardless of success).** The first cut ran PCMM's pruning before the callback and
  handed it a gutted folder. `postSimulationCleanup` is a new no-op stub, so PCMM must move its pruning
  there — a coordinated bump.
- **ModelManager identifies the simulation and locates its output; parsing output is the backend's
  job.** The callback originally received a `SimulationProcess` with accessors; it later became the
  `Simulation` itself.
- **Deletion consistency**: `_deletePostProcessingRows` inside `deleteSimulations`, the single choke
  point every cascade routes through; `resetDatabase` removes the sink file. The deletion functions the
  manual used bare were not exported; now they are.
- **`simulationsTable(...; post_processing=true)`** appends quantities by an order-preserving Dict
  lookup rather than `leftjoin`; appended columns are exempt from `remove_constants` and sorting;
  simulation-level only.

### Rejected
- Storing quantities in the central database (migration plus a PCMM `up.jl` entry).

### Traps
- `df.SimID` comes back `Union{Missing,Int}` from SQLite; narrow before an ID query.

---

## Session: Batch run/createTrial over a vector (task f) (2026-07-07)

### Decisions
- **`run(Ts::AbstractVector)` is `run(createTrial(Ts))`**: one `Trial`, one parallel pool across every
  constituent simulation. `_toAbstractTrialVector` narrows a `Vector{Any}`; a `Trial` element flattens to
  its samplings, everything else wraps through `Sampling.` since `Simulation`/`Monad`/`Sampling` are all
  `<: AbstractSampling`.
- A single-element vector still returns `MMOutput{Trial}`; pre-built trials are wrapped with
  `n_replicates=0`/`use_previous=true`; empty vectors and non-trial elements raise `ArgumentError`
  naming the indices; `MMOutput` elements are not accepted (pass `.trial`).

---

## Session: Calibration evaluation budget — enforce before dispatch (task c, corrected) (2026-07-08)

- First mis-implemented as a global per-`run` simulation budget (`setSimulationBudget`, a `force`
  kwarg) and fully reverted: the budget is `ABCSMC.max_evaluations`, checked **before** a batch is
  dispatched rather than after. `_capBatchToBudget` trims a planned batch to `max_evaluations −
  budget[]` at all three dispatch sites; generation 1 is trimmed too (weights renormalised); an empty
  trimmed batch sets `budget_hit` and breaks so the acceptance-rate update never divides by zero.

---

## Session: PR #20 review fixes — async hang + sink hardening (2026-07-08)

### Decisions
- **The worker pool always delivers exactly one result per scheduled simulation.** A throwing
  `processSimulationTask` used to kill its `@async` worker silently, so the completion loop's `take!`
  blocked forever (a PCMM run hung 9+ hours on a `MethodError`). Now `_SimulationStageError(stage,
  sim_id, CapturedException)` travels the result channel, `_runStage` tags each per-simulation stage,
  and the completion loop rethrows it. Fail-fast; no `:skip_and_continue` policy (YAGNI).
- Sink hardening: `_qIdent` quotes every identifier (interior `"` doubled); `AbstractDict` keys that
  collide after `string(k)` raise `ArgumentError`; `printPostProcessingTable` asserts initialised.
- Not changed: "Real, Bool, or String" already covers `Integer <: Real`; `max_evaluations ≥ 1` is
  validated in the constructor.

### Rejected
- Go-style `(err, value)` returns from `_runStage` with a hand-built rethrow: same guarantees, more
  mechanisms, and display logic outside `showerror`.

---

## Session: Handle failed simulations in calibration (2026-07-28)

A PCMM cluster run died when one simulation failed: the runner erased it from its monad, deleted the
emptied monad and its constituent CSV, and the user's `summary_statistic` then queried a monad that no
longer existed (or returned `missing` into `distance`). One bad parameter set killed a multi-day run.

### Decisions
- **Detect the unusable monad before user code runs** rather than catching the user's failure and
  inferring the cause: "this monad has no successful simulation" is knowable from the database.
- **`_batchOutcome` compares a pre-run snapshot of each monad's simulation IDs against post-run status
  codes** (one `_simulationStatusIDs` query per batch) and returns failed simulations, monads with a
  failure, and monads with no `Completed` simulation. The snapshot must precede the batch because a
  deleted monad takes its constituent CSV — the only monad→simulation mapping — with it; status codes
  rather than vanished IDs so a monad whose simulations never ran is covered too.
- **Failures are recorded per generation and warned once per generation**, in the compressed-ID
  format via `_appendCompressedIDs` (now also used for the monads record). Replaced a
  throttle-to-five-warnings mechanism and a `rejection_counts` dict threaded out of the closure.
- **No top-off re-runs for partially failed monads** (user): evaluate from what succeeded; chasing the
  last successes can spin indefinitely.
- **Two failure classes.** No successful simulation → `on_monad_failure=:reject` (default) or `:error`,
  naming the monad, both failure files and the surviving output folders. A `summary_statistic`/
  `distance` failure on a monad *with* output is a user bug and always fatal, including a non-`Real`
  `distance` return; `_evaluateParticle` logs the monad ID (and its failed-simulation count) and
  `rethrow()`s so the original backtrace survives.
- **`missing` carries the failure, not `Inf`.** `Inf` is a value a user's `distance` may return, so
  using it as a control signal conflates "monad failed" with "terrible fit" and forced generation 1 to
  decide acceptance by finiteness. `evaluate_batch` returns `Vector{Tuple{Union{Float64,Missing},Int}}`;
  `_ParticleResult.distance` and `GenerationResult.distances` stay `Float64` since only accepted
  particles reach them.
- **Generation 1 drops `missing` particles** (`_acceptFirstGeneration`), warns, renormalises the
  uniform weights, keeps `n_evaluations` honest, and errors when no monad succeeded. Later generations
  need no backstop: the adaptive loop keeps proposing under `max_evaluations`, and throwing would let
  one bad monad in a small batch kill a healthy run.
- **A non-finite ε is left alone** (an error for it was added and then removed at the user's
  direction): generation 2 accepting everything is a second uniform draw and the quantile rule
  recovers; `Inf` round-trips TOML as `+inf`.
- **Bank reusability is keyed on the monad's own state**: `_monadsWithStartedSimulations` keeps monads
  with at least one `Running`/`Completed` simulation, gating `_buildSimulationBank` at load and
  `_updateMidGenAdditions!` (now called only when `snap_active`). Deletedness falls out, since
  `constituentIDs` reports nothing for a deleted monad. This also closes the hazard of a bank monad
  whose only simulation was `Not Started` being scheduled, failing, and dangling as a `known_mid` later
  in the same generation.
- **`_batchOutcome` throws on a constituent with no database row**: the records and the database
  disagree, and guessing either way is wrong in a specific direction.
- **No `isInitialized()` fudge in `_monadsWithStartedSimulations`**; the two algorithm-level testsets
  that drove `_runABCSMC` without a database moved into the DB-backed section.

### Rejected
- Filtering bank membership on `isfinite(distance)`: a user's `distance` may legitimately return `Inf`
  for a good monad.
- An `AbstractMonadCompletion` extension point plus a runner-level `keep_failed_monads` opt-out:
  designed and dropped with the top-off idea.

### Traps
- `createTrial(inputs, [dv]; n_replicates=1)` returns a `Simulation`, not a `Monad`; use
  `n_replicates=2` when a monad is wanted. `use_previous=true` silently reuses a `DiscreteVariation`
  value another testset used, so a "never started" fixture needs an untouched value.
- `missing <= epsilon` is `missing`, which throws as a condition; the `!ismissing(distance) &&` guard
  in `_runSubsequentGeneration` has a test that would catch its removal.

### Open questions
- Nothing records which variation a failed simulation came from once its monad is deleted (the
  failed-simulation artifact store in the CLAUDE.md to-do).

---

## Session: Portable docstring cross-references (2026-07-31)

PCMM's docs build died with `:cross_references`: ModelManager docstrings `@ref` internals, and a
downstream build renders only the public API. Our own build never caught it because every lib page
carried both `Private = false` and `Public = false` blocks.

### Decisions
- **The strong rule: no docstring `@ref`s a non-public binding, anywhere.** The narrower "public
  docstrings only" leaves private→private links that break in any downstream build mirroring our page
  structure. Trivially testable via `Base.ispublic`.
- **61 non-public targets split three ways**: genuine `_`-prefixed internals → plain code spans; the
  `AbstractSimulator` interface methods → `@compat public` (unexported by design — a simulator
  implements `ModelManager.runSimulation`, never calls it — but the documented contract);
  public-in-effect names (`SimulationSpec`/`SimulationProcess`, `GSASampling`,
  `simulationsTableFromQuery`/`monadsTableFromQuery`, which carry the keyword documentation) → public.
  Not promoted, since `public` is hard to reverse and delinking costs a hyperlink: `SimulationBank`,
  `ParsedVariations`, `AddVariationsResult`, the source types, `addVariations`, `databaseDiagnostics`.
- **`addVariationRows` reverted to internal and both stale docs claims deleted**: it takes no simulator
  argument. Rule, now in CLAUDE.md: verify against the signature; never promote a name to keep a link.
- **The guard test is wrapped in `@static if isdefined(Base, :ispublic)`.** On 1.10 `@compat public` is
  a no-op, so every interface method looks private and skipping is the correct semantics, not a
  workaround. Docs CI must run 1.11+ (it runs 1.12).
- PRD hook descriptions were reversed (`postSimulationProcessing` glossed as pruning); fixed.
- Verified with a scratch Documenter build rendering only `Private = false`; our `docs/make.jl` cannot
  test this class of bug.

### Rejected
- PCMM setting `warnonly = [:cross_references]`: hides real breakage.
- DocumenterInterLinks/`@extref`: right for inbound PCMM → MM links, irrelevant to our docstrings.

### Traps
- Julia errors on declaring an already-exported name `public` (`postInitDisplay`, `centralDBFileName`).
- A regex sweep leaves dangling "See `_x`." pointers; hand-rewrite them to name the artifact.

### Open questions
- `prepareBaseFile` is an `AbstractSimulator`-dispatched override point left private, inconsistent
  with `postVariationXMLProcessing`. Inbound PCMM links need `@extref` on PCMM's side.

---

## Session: Trial-ID accessor symmetry; `trialID(::Vector{Sampling})` made a pure lookup (2026-08-17)

`monadIDs(out)` on an `MMOutput` was a `MethodError`; `monadIDs(::Simulation)` did not exist, so
`monadsTable(simulation)` threw despite the PRD's "any `AbstractTrial`" promise; and `trialID` was
exported with two opposite meanings, a field read and a find-or-INSERT.

### Decisions
- **`monadIDs(::Simulation)` is a pure `SELECT` on the `monads` `UNIQUE` key tuple**, never
  `Monad(simulation)`, which writes a row and rewrites `simulations.csv`. `_monadKeyStrings(inputs,
  variation_id[, version_id])` was extracted from the `Monad` constructor so accessor and writer cannot
  drift.
- **The version component is read from the simulation's own row** (`_simulationVersionID`), not
  `currentSimulatorVersionID()`. After a simulator upgrade inside a project the ambient value misses the
  monad (reproduced), and would attribute a re-created trial's simulation to a monad whose replicate
  list excludes it. The writer keeps the ambient default. Pinned by a version-bump test.
- **Matching is on parameterization, not membership**: `Simulation(monad)` resolves to a monad whose
  replicate list excludes it, and a failed simulation still resolves. Docstring, manual and PRD all
  say so, because a reader assuming membership misreads `monadsTable(sim)`.
- **`Int[]` when no monad shares the key**: `monadIDs` returns a `Vector` at every level, SQLite accepts
  `IN ()`, and an empty `monadsTable` beats an error.
- **`trialID(::Vector{Sampling})` is a pure lookup returning `missing`**; the insert moved verbatim into
  `_findOrCreateTrialID`, called only by `Trial(Ss)`. `missing` rather than `nothing` was the user's
  explicit choice, reading like `monad_id=missing`: an ID the database does not have. An `EXCLUSIVE`
  transaction would now go in `_findOrCreateTrialID`, spanning lookup and insert.
- **`MMOutput` stays outside `AbstractTrial`**: it has no `id` field, and `run(::AbstractTrial)` would
  silently begin accepting `MMOutput{Sampling}`/`MMOutput{Trial}` where today those are a `MethodError`.
  (The original "collides with `run(::MMOutput{<:AbstractMonad}, args...)`" argument was wrong — Vararg
  dispatch resolves it — and is corrected.)
- `constituentIDs(::MMOutput)` added; `constituentIDs(::Simulation)` throws by design and the manual
  table marks the exception.
- `trialID`/`trialType` were exported with no docstring, which `checkdocs=:exports` cannot see; documented.
  `0.8.4` → `0.9.0`, breaking.
- Scope held: no table functions on `MMOutput` (~12 methods to save `.trial`), no `untag!`/`tags`/
  `hasTag` on it (only `tag!` chains with the `tags=` keyword).

### Rejected
- A `trial(out)` accessor: `trial` cannot be exported because users write `trial = createTrial(...)`;
  `out.trial` is the accessor, `trialOf` the safe name if ever wanted.

### Traps
- The planning brief asserted `createTrial(inputs, dv; n_replicates=1)` leaves no monad row. False:
  `_buildTrial` creates the `Monad` first. The genuine `Int[]` case is the raw
  `Simulation(inputs, variation_id)` constructor, and the test mints a variation row via `addVariations`
  with no monad.
- Reusing a writer's key builder for a reader inherits the writer's ambient values.

### Open questions
- `monadIDs` on an array is not deduplicated (`[sim, monad]` yields the ID twice; `monadsTable`
  collapses it only because SQL `IN` does). `simulationIDs` has the same property.

---

## 2026-08-19 — Shared study objects, Stage 1: GSA over a CalibrationProblem

Stage 1 of the shared-study brief: one study definition driving both workflows, without new types.

### Decisions
- **A shared object must keep the user's original variations.** `CalibrationProblem → ParsedVariations`
  is lossless (both workflows normalise through the same `LatentVariation` factories); the reverse is
  not — a `DistributedVariation` comes back as an `LVSource`, changing the display columns of the
  generation CSVs and `posterior()`. `StudySpec` (Stage 2) is designed on that basis.
- Methods naming `CalibrationProblem` live in `calibration/problem.jl`, since `variations.jl` loads first.
- `_toCalibrationParameters` collects every rejected variation into one `ArgumentError` (index and
  `variationName`) instead of failing on the first.
- The manual described `functions` as `monad_id -> Real`; they receive per-simulation input, averaged
  over replicates — the asymmetry with calibration's monad-level `summary_statistic` that the QoI seam
  later resolved.
- Deferred: discrete calibration pending a kernel assessment; Stages 2–4 pending entry-point unification.

---

## 2026-08-19 — Discrete variations ride the Distribution branch (and a GSA bug this fixes)

### Decisions
- **A discrete parameter is `DiscreteUniform(1, k)` over its value indices**, the map indexing into the
  values and the inverse recovering the index, so the grid and CDF sampling paths agree by construction.
  The bug this fixes: the CDF path computed an *index* and passed it to a `first` map, so every
  space-filling design — and therefore every GSA method — wrote a discrete parameter's index into the
  model, out of range at `cdf = 1.0`. Invisible because the grid testset used a discrete variation and
  the LHS testset a continuous one.
- The same representation makes a discrete parameter calibratable, since the kernels work in CDF space;
  accepting it in `_toCalibrationParameter` was left to a separate change.
- `size(lv)` reports support cardinality via `_supportSize`, `-1` when unenumerable; the test is
  `DiscreteUnivariateDistribution` with finite bounds, because `Uniform(0,1)` is bounded but not
  enumerable and the grid must keep rejecting it.
- `_validateInverseMaps` tests `insupport` rather than `0 < cdf < 1`, which rejected the top level of
  every discrete parameter.

---

## 2026-08-19 — Naming the two epsilons apart, and upgrading old metadata on read

### Decisions
- **`GenerationResult.epsilon` → `max_epsilon_accepted`, plus a new `epsilon_threshold`** recording the
  cutoff the generation ran against, which is not recoverable from the achieved value (the threshold is
  a quantile of the *previous* generation's distances) and is absent for generation 1. Rename over
  preserve, the user's call.
- **Old metadata is upgraded on read, from `_loadGenerations` only**: resume already writes into that
  folder, `ConvergenceSummary` is a repeatable read, and a mutating `show` is worse than a nagging one.
  Write-then-rename; a read-only filesystem warns and continues; `epsilon_threshold` is not inferred
  for old generations.
- Upgrade-on-read may be the right shape for MM-owned on-disk artifacts generally: per-run folders are
  read lazily, so upgrading what you touch needs no version row.
- The two new `GenerationResult` fields are keyword arguments, removing the compatibility shim rather
  than scheduling its deprecation.

### Traps
- A rename that changes an assignment but not the constructor argument surfaces only as a test
  `UndefVarError`; a read-fallback cannot protect against it.

---

## 2026-08-23 — Proposal-distance histogram (item 6, part 2)

### Decisions
- **Every evaluated proposal's distance is persisted** (`monad_id`, `distance`, `accepted`), because
  rejected distances were discarded and recomputing means running arbitrarily expensive user code on
  monads that may be deleted. A separate file, since `posterior(::Calibration)` strips exactly three
  columns from the display CSV and rejected rows there would become posterior samples. `missing`
  distances are omitted. `accepted` means passed ε, not kept: `sum(accepted) == n_accepted_total`.
- **Bin edges are computed in the builder** with the threshold on an edge, and each series is
  constrained to its own side: `distance == ε` is accepted, but `searchsortedlast` places it in the
  first rejected bin. Test: `maximum(accepted_bins) < minimum(rejected_bins)`.
- `:bar` and `:path` only; `bar_position := :stack` is a Plots-level attribute.
- Degradation: generation 1 draws one series and no line; older runs plot accepted distances and say
  so in the title; `logscale=true` drops non-positive distances and reports how many.
- Legend labels carry counts and the title notes when passed-ε and kept differ (six of ten generations
  in a reference run).
- **Reading a generation file must never assume a padding width.** Four sites got it wrong, each in a
  different direction (live cap, `method.toml` cap, lexicographic last, fresh names on write); all now
  go through `_findGenerationFile` on `_indexedGenerationFiles`, and write paths prefer an existing
  file. Padding is normalised on resume to `ndigits(max(cap, highest existing))`; cosmetic, so a failed
  rename is logged.
- `_runABCSMC` warns when a resume's generation range is empty.
- Smoke tests added for the four pre-existing calibration recipes; the manual's and README's
  `plot_type=` examples (never valid) fixed.

---

## 2026-08-24 — One folder per generation

### Decisions
- **Artifacts are addressed by role.** `_GENERATION_ARTIFACTS` maps roles to basenames and
  `_generationArtifact(gen_dir, t, role)` resolves folder layout first, flat layout second — one
  function instead of a branch at ~12 read sites. No migration channel exists for on-disk calibration
  artifacts, so reading both layouts is what keeps old runs plottable; `_migrateGenerationLayout!`
  tidies on resume, where we already write.
- **Four sites used listing position as the generation index** (`posterior`, `ConvergenceSummary`, the
  `:ridgeline` and `:transition` `Calibration` recipes). With generations 1, 2, 10 on disk,
  `ConvergenceSummary` reported `t = [1, 2, 3]` with ε misordered and `posterior(cal)` returned
  generation 2. All take the index from `_generationIndices`; pinned by a mixed-width testset.
- Path builders collapsed onto `_generationArtifactToWrite` (prefer-existing-else-compute, once);
  `_saveGeneration` lost its `cdf_dir` argument.
- Padding kept so `ls` sorts; nothing depends on it.
- Verified on a real ten-generation run: 50 files migrated into 10 folders with identical results.

---

## 2026-08-22 — Calibration accepts discrete parameters

### Decisions
- **The kernels needed nothing**: all four take and return CDF coordinates and never see a target
  value; `_minDiagVar` already floors the one degenerate case (a generation in one bin).
- **New source types `DiscreteSource`/`DiscreteCoSource`** rather than re-parameterising
  `DVSource`/`CVSource`: JLD2 stores the concrete parameterisation, so re-parameterising makes an
  older `problem.jld2` load as a `ReconstructedMutable` and breaks `resumeABC`. Tested both ways.
- `_parameterTOMLEntry` records `"values"` (the levels) for a discrete source.
- **`_bankColDistribution` returns a `DiscreteNonParametric` over the sorted levels**, never `nothing`
  (the bank's bug signal): it answers in target space, where the caller bounds-checks a base config
  value, and `DiscreteUniform(1, k)` would bound by `[1, k]`. The no-DB-column check uses `insupport`,
  not min/max, since a range admits the gaps between levels.
- `_discreteValueIndex` keeps throwing on a non-level; `_bankCdfCoords` catches it and returns
  `nothing`, its established "not reusable" signal.
- **`AbstractCalibrationSource` is a real abstract type**, not a `Union`, so the documented type tree
  is true. Gaining a supertype is not a JLD2-breaking change (verified on an older `problem.jld2`).
- Still rejected: a `LatentVariation` over a raw `Vector{<:Real}` (its latent values are indices in the
  CDF path); the error names the fix.
- Known cost: a discrete parameter loses resolution, not correctness; snapping and the bank mitigate.

### Rejected
- Returning an out-of-support `0` from `_discreteValueIndex`: a sentinel that is a valid-looking number
  fails much later, if at all.

### Traps
- The end-to-end test found three things the unit conversions passed; write it first.

---

## 2026-08-24 — Calibration entry points made symmetric, and `method=` stopped resetting the run

`resumeABC(cal; method=ABCSMC(max_nr_populations=15))` read as "raise the cap" but replaced the whole
method: a saved `population_size=64, epsilon_quantile=0.3, minimum_epsilon=1e-4, ComponentwiseKernel`
silently became `100, 0.5, 0.01, GaussianKernel`.

### Decisions
- **A keyword patches the saved method (`_methodWithOverrides`); a method object replaces it wholesale;
  both at once is an `ArgumentError`.** `_methodFromKeywords` could not be reused, since it builds a
  fresh `ABCSMC` — the behaviour being fixed.
- **The effective method is written back to `method.toml`** when it differs, with the changed keys
  reported; otherwise the next resume silently reverts. Comparison is on the serialised dict.
- **Everything flows through `run`**: `run(::ABCSMC, problem)` and `run(calibration[, method])`. Free
  because `run(::GSAMethod, …)` already returns an analysis object and `Calibration` sits outside the
  containment hierarchy.
- **A resume only appends generations, so every changed setting takes effect from the next generation
  and nothing is refused.** `population_size` yields heterogeneous generations; `cdf_grid_k` resolves
  once at loop entry; `epsilon_schedule` is indexed by *absolute* generation (generation `t` reads
  entry `t-1`, generation 1 none), so a schedule sized for the remaining generations falls through to
  the quantile rule — the only silent case, so it warns with the covered range. The first warning was
  off by one: `L == n_done` still schedules one generation from the last entry.
- **`runCalibration` takes the method first** (breaking, pre-1.0); `resumeCalibration(calibration[,
  method])` leads with the object.
- **The accidental GSA override is an error.** `run(::GSAMethod, reference::AbstractMonad, avs; …)`
  honoured a caller's `reference_variation_id` only because the rightmost duplicate wins in a splat;
  `createTrial` never allowed it. It throws, naming the `InputFolders` form.
- **`resumeABC` is not deprecated**: two complete pairs, and the alias costs one line.
- `_runControlKeywords` used `only(methods(runABC))`, which throws as soon as `runABC` gains a second
  method — while building an error message. Now `which(runABC, Tuple{CalibrationProblem})`.
- The shared bank/evaluator/SMC tail is `_executeCalibration(…; start_generations)`;
  `_latentNamesAndPriors` is separate because resume needs the names before loading generations.

### Rejected
- A `reference_variation_id` keyword on the `AbstractMonad` `CalibrationProblem` form: added on the
  grounds that a default of `ref.variation_id` was harmless, then reverted because `createTrial(method,
  reference, avs)` offers no override, so the keyword introduced an inconsistency rather than removing one.
- Deprecating `resumeABC` in favour of `resumeCalibration`: would leave `runABC` without a partner.

### Traps
- **An unreachable ε has no bound.** `while length(accepted) < population_size` with the default
  `max_evaluations=nothing` proposes forever with no diagnostic; a test with `epsilon_schedule=[0.5]`
  against a constant distance of 1.0 hung CI for 50+ minutes. Tests set `max_evaluations`.
- The `#!` docstring guard caught a comment between `_executeCalibration`'s docstring and its
  definition within minutes of the function being written.

### Open questions
- A user who sets `epsilon_schedule` or `minimum_epsilon` below what the model can achieve gets an
  unbounded run and no message. Options: a default cap proportional to `population_size`; a warning
  after some multiple of `population_size` proposals with no acceptance; documenting the hazard beside
  `epsilon_schedule`. Needs a decision, not a quiet default change.

---

## 2026-08-26 — StudySpec (item 7, Stage 2)

### Decisions
- **No new named entry points** (user's steer; `runSensitivity` had existed and been removed).
  Consumption is `run(::GSAMethod, spec)` and `CalibrationProblem(spec, …)`. The brief's
  `runABC(inputs, priors, data, …)` convenience layer was dropped, not deferred.
- **It holds nothing a single consumer needs**: no `observed_data`, `summary_statistic`, `distance` or
  `functions`; an optional field half the consumers ignore is how a shared abstraction rots.
  `use_previous` is the one asymmetry (calibration reuses via the bank), marked "(sensitivity only)"
  in the docstring and `show`.
- The field is a concrete `Vector{AbstractVariation}` because `ParsedVariations`' inner constructor is
  invariant; normalising through `convertToAbstractVariationVector` from `user_api.jl` (loaded later)
  is fine because only signatures constrain include order.
- **`kwargs...` is forwarded last** so a caller's keyword beats the spec's: a spec's fields are defaults
  the user set, whereas a monad's variation is an identity — the distinction that made the same
  mechanism a bug for a reference monad.

### Traps
- `printInputFolders` leaves its last line unterminated.
- Derive `show` test expectations from `_calibrationRejection` rather than hardcoding which variation
  kinds are calibratable.

---

## 2026-08-30 — The QoI seam (item 7, Stage 3)

The to-do's premise was partly wrong: `populationCountQoI` never existed here (the builders are
PCMM-side), so the work was to build the seam. Sensitivity called `f(simulation_id)` with a hard-coded
`mean`, calibration `summary_statistic(monad_id)`, the sink `post_processor(::SimulationProcess)`.

### Decisions
- **`QoI(name, compute; reduce=mean)`, with no level.** A monad-level `compute` is the per-simulation
  pair with the reduction folded in: since `reduce` receives everything `compute` returned, a
  measurement needing the replicates jointly returns raw material and pools in `reduce`. (Review's
  point; the first cut had `QoI{Simulation}`/`QoI{Monad}` with a `hasmethod` check and three adapter
  functions, all removed, together with the docstring defending the type parameter — explaining a
  rejected alternative is confusing.)
- **Sensitivity analysis honours the reducer**; `evaluateFunctionOnSampling` no longer hard-codes
  `mean`, which removed the refusal of a non-`mean` reducer. Fix the internals rather than document
  the limitation.
- **`stored=:never` by default, decided by measurement.** Nothing records which `compute` produced a
  stored value and no fingerprint can: redefining a body leaves `hash` and `nameof` unchanged, and two
  textually identical anonymous functions hash differently. `verifyStoredValues` recomputes where
  output survives and reports `n_unverifiable` where it does not.

### Traps
- A sink test reusing parameter values another testset ran gets `use_previous` reuse, and the
  post-processor never fires; use unique values and `use_previous=false`.
- Test `stored=:prefer` with a `compute` that throws, proving the stored path was taken.

---

## 2026-08-30 — One simulator-option channel (item 7, Stage 4)

### Decisions
- **`run_kwargs::NamedTuple` is accepted on the splat-based `run` entry points**, merged by
  `_mergeRunKwargs` with the loose keyword winning, so a bundle assembled once reaches any entry
  point. Calibration's entry points bundle by necessity: their splat forwards `ABCSMC` fields.
- **`runCalibration` does not gain a loose splat** (contra the scoping): it would turn a `MethodError`
  on a mistyped keyword into a silent forward to permissive simulator hooks.
- **Calibration's own `quiet`/`on_progress` come after the splat** in the per-batch `run`;
  `run_kwargs=(quiet=false,)` had silently replaced the progress machinery — the third rightmost-wins
  override that week.
- Tests assert the bundle reaches `setupSampling`, not merely that it merges.

### Traps
- The docstring guard caught a helper placed between `run`'s *own* docstring and its definition —
  detaching documentation the author had not written.

---

## One contract for user measurement functions

A bare `Function` meant four things: a simulation ID in GSA's `functions=`, a *monad* ID in
`CalibrationProblem`'s `summary_statistic`, a `SimulationProcess` at the sink, and a `Simulation` for a
`QoI`'s `compute`. Two of those were dense positive `Int`s meaning different entities, so a calibration
summary handed to `functions=` computed on the wrong thing and returned a plausible number.

### Decisions
- **One contract: a measurement function is called once per simulation with a `Simulation`; replicates
  are combined by `reduce`.** A bare `Function` is the shorthand for `reduce = mean`.
- **Every bare `Function` is wrapped into a `QoI` at the boundary (`_asQoI`)**; nothing downstream sees
  one. `_qoiNameFromFunction` keeps a named function's name and regularises an anonymous one
  (`#3#4` → `anon_3_4`), since the name becomes a sink column and a `Dict` key.
- **A single `QoI` reports its value directly; a vector reports a `Dict` keyed by name.** The rule is
  arity, and it preserves the scalar and vector `observed_data` shapes `mseDistance` supports. A
  judgement call; uniformity is the honest counter.
- **A bare `summary_statistic` that does not declare a `Simulation` argument warns** (`_declaresSimulation`:
  first parameter `T !== Any && Simulation <: T`, a `where` bound resolved through its `TypeVar`). An
  old monad-level summary re-read per-simulation-then-mean returns a different number (225 against 250
  on the worked example) with no error. A warning rather than a refusal, since refusing `sim ->
  measure(sim)` was the worse cost; suppression keyed on the function, not `maxlog`. Not extended to
  `functions=`/`post_processor`, which fail loudly at the call.
- **The problem stores the QoI it was handed** and dispatches at the call site; collapsing it into a
  closure at construction made every QoI-backed problem unrestorable.
- **The sink hands over a `Simulation`; `SimulationProcess` leaves the user-facing contract.** It
  carried nothing recoverable a `Simulation` lacks (`monad_id` is `only(monadIDs(sim))`, `success` is
  always true there, `process` is meaningless post hoc). The runner reads
  `simulation_process.simulation` itself; `simulationID(::Simulation)` added. The `AbstractSimulator`
  hooks still take a `SimulationProcess`.
- **A QoI's `compute` returning a `NamedTuple`/`Dict` spreads into columns** rather than nesting under
  the name. Keys pass through unstringified so the sink's own collision check keeps its error type;
  `NamedTuple` order is preserved by handing the sink ordered pairs.
- A bare anonymous post-processor cannot write an auto-derived `anon_9` column (refused whenever the
  sink would store the value; a user-named `QoI` with an anonymous `compute` is fine).
- `_isCompleteManifest` requires the stored summary to be a `QoI`, so a legacy manifest routes to the
  existing "pass `problem=`" message.
- `_reduceOverMonad` batches through `simulationsFromIDs` (the N+1 pattern had been reintroduced).
- `verifyStoredValues`' documented pass condition requires `n_agreed > 0`, since `n_mismatched == 0` is
  also what an empty check reports.

### Rejected
- **Dispatch-sniffing** the user's method table to adapt the three old contracts: an untyped argument
  is `::Any`, so `hasmethod` is true for every candidate and sniffing would silently pick the
  `Simulation` branch for nearly every existing function.
- Making the old-contract case loud by wrapping the value under `nameof(f)`: `mseDistance(::Dict,
  ::Dict)` warns and computes on disjoint keys, so a `Dict` observation still returns a number.
- Refusing every bare `summary_statistic` (first cut): heavier than the annotation signal.
- Not wrapping bare functions because anonymous names would collide: measured, lambdas get distinct
  gensyms (`#2`, `#5`); the hazard was imaginary.
- Four alternative architectures from an adversarial review (measurement-as-data, sink-as-only-path,
  level-in-the-type): each presupposes the nominal-typing cure and buys its benefit with a type,
  contract or persisted-format change the package has no migration channel for.

### Traps
- `m.sig.parameters[2]` throws on a method with a `where` clause or zero arguments; guard introspection
  at every step, or a correctly migrated `f(s::S) where {S<:Simulation}` cannot be passed.
- `maxlog=1` counts callsite hits, not distinct offenders.
- The suite is the guard: 36 failures on the first run, every one a call site on an old contract;
  `Int(::Simulation)` is a `MethodError`, so a missed site fails rather than mis-computes.

### Open questions
- Whether `stored` and `verifyStoredValues` should exist at all: the correctness judge's strongest
  recommendation was to delete both, since a flag guarded by a verifier that can report clean on an
  empty check is worse than neither. The owner's decision.
