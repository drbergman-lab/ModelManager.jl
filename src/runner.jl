import Base.run

"""
    simulationFailed(simulation::Simulation, monad_id::Int)
    simulationFailed(simulation_id::Int, monad_id::Int)

Mark a simulation as failed and remove it from its monad's constituent list.
"""
simulationFailed(simulation::Simulation, monad_id::Int) = simulationFailed(simulation.id, monad_id)

function simulationFailed(simulation_id::Int, monad_id::Int)
    DBInterface.execute(centralDB(), "UPDATE simulations SET status_code_id=$(statusCodeID("Failed")) WHERE simulation_id=$(simulation_id);")
    eraseSimulationIDFromConstituents(simulation_id; monad_id=monad_id)
end

"""
    SimulationProcess

Holds the outcome of a single simulation run.

# Fields
- `simulation::Simulation`
- `monad_id::Int`
- `process::Union{Nothing,Base.Process}`: the local process, or `nothing` when the simulation ran
  as a SLURM job (there is no local process to hold) or no command could be built.
- `success::Bool`
- `cmd::Union{Nothing,Cmd}`: the command [`simulationCommand`](@ref) returned, or `nothing` if it
  could not build one.

`process` alone cannot tell a simulator hook what happened, because it is `nothing` for two
unrelated reasons: a SLURM job (which ran, elsewhere) and a simulation that never had a command.
`cmd` separates them — `isnothing(cmd)` means nothing was ever launched — and it is also the field
to print when reporting a failure, since it is the simulator's own command on both paths rather
than the `sbatch` wrapper.
"""
struct SimulationProcess
    simulation::Simulation
    monad_id::Int
    process::Union{Nothing,Base.Process}
    success::Bool
    cmd::Union{Nothing,Cmd}
end

#! Four-argument form for the "no command" case and for backends constructing this themselves.
SimulationProcess(simulation::Simulation, monad_id::Int, process, success::Bool) =
    SimulationProcess(simulation, monad_id, process, success, nothing)

"""
    simulationID(simulation::Simulation)
    simulationID(simulation_process::SimulationProcess)

Return a simulation's ID.

A `post_processor` (see [`run`](@ref)) is called with a [`Simulation`](@ref), so that is the form to
use in one — `simulationID(sim)` rather than reaching for `sim.id`. The `SimulationProcess` method
serves the runner and the `AbstractSimulator` hooks
([`postSimulationProcessing`](@ref), [`postSimulationCleanup`](@ref)), which still receive that type.
"""
simulationID(simulation_process::SimulationProcess) = simulation_process.simulation.id

simulationID(simulation::Simulation) = simulation.id

"""
    monadID(simulation_process::SimulationProcess)

Return the ID of the monad enclosing this simulation.
"""
monadID(simulation_process::SimulationProcess) = simulation_process.monad_id

"""
    wasSuccessful(simulation_process::SimulationProcess)

Return `true` if the simulation completed successfully.
"""
wasSuccessful(simulation_process::SimulationProcess) = simulation_process.success

"""
    pathToOutputFolder(simulation_process::SimulationProcess)

Return the path to the output folder for the simulation this process ran.
"""
pathToOutputFolder(simulation_process::SimulationProcess) = pathToOutputFolder(simulationID(simulation_process))

"""
    prepCmdForWrap(cmd::Cmd)

Strip surrounding backticks from the string representation of `cmd`.
"""
function prepCmdForWrap(cmd::Cmd)
    cmd = string(cmd)
    cmd = strip(cmd, '`')
    return cmd
end

"""
    _shQuote(s::AbstractString) → String

Wrap `s` in POSIX single quotes so the shell reads it as a literal, escaping any single quotes it
contains via the standard `'\\''` idiom. Nothing inside single quotes is expanded, so a path
containing `\$`, a backtick, a double quote, or a space survives intact.
"""
_shQuote(s::AbstractString) = "'" * replace(s, "'" => "'\\''") * "'"

"""
    _sentinelWrap(cmd_str::AbstractString, sentinel::String) → String

Prefix `cmd_str` with a shell trap that records the command's exit code at `sentinel` when the job
script exits.

The trap writes to `<sentinel>.tmp` and `mv`s it into place. That rename is atomic, so the waiting
worker only ever sees a sentinel whose contents are already complete. The path is fixed before
submission -- the trap needs nothing about the job's identity -- which is what makes the name unique
per submission and the wait race-free.

The path is bound to a shell variable, single-quoted, *before* the trap is installed, and the trap
body then refers only to that variable. Interpolating the path into the trap body directly would
put it inside double quotes in code that is re-parsed when the trap fires, so a `done_dir`
containing `\$`, a backtick or a `"` would be expanded or would break the quoting -- and `done_dir`
is user-settable. Binding it once means exactly one thing needs escaping, by exactly one rule.

Only `EXIT` is trapped, not `TERM`. A job killed by the scheduler produces no sentinel at all, and
that is already handled correctly: it leaves the queue, the reaper notices, and after the grace
period the simulation is failed. Trapping signals would make that detection faster without making
it more correct, at the cost of shell that has to be right under every `sh`.
"""
function _sentinelWrap(cmd_str::AbstractString, sentinel::String)
    bind = "mm_sentinel=$(_shQuote(sentinel))"
    trap_body = "mm_ec=\$?; echo \$mm_ec > \"\${mm_sentinel}.tmp\" && mv \"\${mm_sentinel}.tmp\" \"\${mm_sentinel}\""
    return "$(bind); trap '$(trap_body)' EXIT; $(cmd_str)"
end

"""
    _userJobFlags(simulation_id::Int) → Vector{String}

Render the global `sbatch_options` as `--key=value` flags, resolving `Function` values against
`simulation_id` and rejecting any key ModelManager sets itself.
"""
function _userJobFlags(simulation_id::Int)
    flags = String[]
    for (k, v) in mm_globals().sbatch_options
        @assert !(k in _RESERVED_SBATCH_KEYS) "The key $k is reserved for ModelManager to set in the sbatch command."
        if typeof(v) <: Function
            v = v(simulation_id)
        end
        #! `sbatch_options` is a `Dict{String,Any}`, so a numeric value like
        #! `"cpus-per-task" => 4` is ordinary; stringify rather than assuming `AbstractString`.
        #! A value containing a space needs no quoting: each flag is one argv element, so no shell
        #! ever word-splits it, and added quotes would reach sbatch as part of the value.
        push!(flags, "--$k=$(v)")
    end
    return flags
end

const _RESERVED_SBATCH_KEYS = ["wrap", "output", "error", "wait", "parsable", "chdir"]

"""
    _prepareHPCSubmitCommand(cmd::Cmd, simulation_id::Int, sentinel::String) → Cmd

Wrap `cmd` in the `sbatch` invocation `_runHPCSimulation` submits: `--parsable` (never `--wait`),
the exit-code sentinel installed by `_sentinelWrap` at `sentinel`, per-simulation
`--output`/`--error` so each simulation keeps its own `output.log` and `output.err`, and the global
job options.

`--chdir` honors the `Cmd`'s own `dir` when the backend set one, and falls back to the simulator
directory otherwise -- the same rule the local path applies, so a command means the same thing on
the cluster as on a laptop.
"""
function _prepareHPCSubmitCommand(cmd::Cmd, simulation_id::Int, sentinel::String)
    path_to_simulation_folder = trialFolder(Simulation, simulation_id)
    flags = ["--wrap=$(_sentinelWrap(prepCmdForWrap(Cmd(cmd.exec)), sentinel))",
             "--parsable",
             "--output=$(joinpath(path_to_simulation_folder, "output.log"))",
             "--error=$(joinpath(path_to_simulation_folder, "output.err"))",
             "--chdir=$(_workingDirectory(cmd))"
            ]
    append!(flags, _userJobFlags(simulation_id))
    return `sbatch $flags`
end

"""
    _workingDirectory(cmd::Cmd) → String

Where a simulation command runs: the `Cmd`'s own `dir` if the backend set one, else the simulator
directory. Applied identically by the local and SLURM paths.
"""
_workingDirectory(cmd::Cmd) = isempty(cmd.dir) ? simulatorDir(mm_globals().simulator) : cmd.dir

"""
    SimulationSpec

A pending simulation to be launched. Produced by `pendingSimulationSpecs`
and consumed by [`run`](@ref), which wraps each spec in a `@task` that calls
[`runSimulation`](@ref) on the active simulator.

`monad_id` is always a real monad ID — `prepareTrialHierarchy` always runs
before spec collection, so setup is guaranteed to have completed.

# Fields
- `simulation::Simulation`: The simulation to launch.
- `monad_id::Int`: ID of the enclosing monad. [`setupMonad`](@ref) has already run
  for this monad before the spec was built.
"""
struct SimulationSpec
    simulation::Simulation
    monad_id::Int
end

#! Public despite not being exported: both appear in `AbstractSimulator` interface
#! signatures (`runSimulation` takes a `SimulationSpec` and returns a `SimulationProcess`;
#! `postSimulationProcessing` takes a `SimulationProcess`), so simulator authors need their
#! docs. See CLAUDE.md, "Docstring cross-references".
@compat public SimulationSpec, SimulationProcess

#! Public despite not being exported: PhysiCellModelManager's interface docstrings `@ref`
#! `ModelManager.prepareTrialHierarchy` (`src/simulator_interface.jl:28`, `:192`), which cannot
#! resolve in a downstream build that renders only our public API.
#! See CLAUDE.md, "Docstring cross-references".
@compat public prepareTrialHierarchy

"""
    runSimulation(sim::AbstractSimulator, spec::SimulationSpec) → SimulationProcess

Run the simulation described by `spec` and report how it went. This default asks the backend for
the command via [`simulationCommand`](@ref) and does everything else: it creates the simulation's
output folder, sends stdout and stderr to `output.log` and `output.err` there, runs the command in
[`simulatorDir`](@ref) (or the `Cmd`'s own `dir`), and -- when `run_on_hpc` is set -- submits it as
a SLURM job instead and waits for it. Called by [`run`](@ref) inside each worker task.

A backend only overrides this if its simulation is not an external process; for those,
`SimulationProcess.process` may be `nothing`.

[`simulationCommand`](@ref) may return `nothing` to say no command could be built for this
simulation; that is recorded as a failed simulation and the rest of the trial continues.

Otherwise the command must be a bare `Cmd`. Redirections and pipelines are added here, so a
`pipeline(...)` is rejected; and it must not carry an environment (`Cmd(...; env=...)`, `setenv`,
`addenv`). Julia's `Cmd.env` *replaces* the environment, so locally the simulation would see only
the variables listed; as a SLURM job the environment is not forwarded at all and the job inherits
the submitting one. The same command would mean two different things, so it is refused rather than
made silently path-dependent. Put what the simulation needs in the command's arguments or its
working directory.

A local process that fails to start (missing executable, unwritable folder) is recorded as a failed
simulation, not raised: one broken simulation should not abort a campaign of thousands. A process
killed by a signal is also a failure -- Julia reports `exitcode == 0` for those, so the check is
`success(p)`, not the exit code.
"""
function runSimulation(sim::AbstractSimulator, spec::SimulationSpec)
    cmd = simulationCommand(sim, spec)
    #! A backend that cannot build a command for one simulation says so with `nothing`. Failing
    #! just that simulation is the point: throwing here would reach run()'s fail-fast completion
    #! loop and discard every other simulation in the trial.
    isnothing(cmd) && return SimulationProcess(spec.simulation, spec.monad_id, nothing, false)
    cmd isa Cmd || throw(ArgumentError("simulationCommand must return a bare Cmd or nothing, got $(typeof(cmd)); ModelManager adds redirections itself."))
    #! The overwhelmingly likely spelling here is `env=ENV`, which means "inherit" -- and is already
    #! what happens without it. Say so, because the fix is a deletion and the generic message would
    #! send someone looking for a way to pass variables they never needed to pass.
    isnothing(cmd.env) || throw(ArgumentError("""
        simulationCommand returned a Cmd carrying an environment, which ModelManager cannot apply \
        the same way on both paths. Locally, Julia's `Cmd.env` *replaces* the environment, so the \
        simulation would see only the variables listed -- no PATH, no HOME, no module state. As a \
        SLURM job the environment is not forwarded at all: the job inherits the submitting one. So \
        the same command would mean two different things depending on where it ran.
        If you wrote `env=ENV`, delete it -- a child process inherits the environment anyway, so \
        removing it changes nothing locally, and it never reached the cluster to begin with.
        If you need specific variables, put them in the command's arguments or its working directory."""))
    simulation_id = spec.simulation.id
    folder = trialFolder(Simulation, simulation_id)
    mkpath(folder)

    if mm_globals().run_on_hpc
        exit_code = _runHPCSimulation(cmd, simulation_id)
        return SimulationProcess(spec.simulation, spec.monad_id, nothing, exit_code == 0, cmd)
    end

    local_cmd = Cmd(cmd; dir=_workingDirectory(cmd))
    p = try
        run(pipeline(ignorestatus(local_cmd);
                     stdout=joinpath(folder, "output.log"),
                     stderr=joinpath(folder, "output.err")))
    catch e
        @error "Simulation $(simulation_id) could not be started." exception=(e, catch_backtrace())
        #! `cmd` is carried even here: a command existed, it just could not be spawned.
        return SimulationProcess(spec.simulation, spec.monad_id, nothing, false, cmd)
    end
    return SimulationProcess(spec.simulation, spec.monad_id, p, success(p), cmd)
end

"""
    prepareTrialHierarchy(T::AbstractTrial; kwargs...) → Bool

Recurse down the trial hierarchy, creating output folders and calling the simulator's
[`setupSampling`](@ref) and [`setupMonad`](@ref) hooks. Returns `true` on success,
`false` if any hook fails (in which case the remaining hierarchy is skipped).

`kwargs` are forwarded to both hooks — any simulator-specific flags flow through this
channel. This function has no knowledge of console output and does not touch simulation
status codes.

Dispatch behaviour:
- `AbstractMonad` (`Simulation` or `Monad`): mkpath + `setupSampling` on `M` (compile
  code, etc.) + `setupMonad` on `M` (prepare varied input folders).
- `Sampling`: mkpath + `setupSampling` once for the whole sampling + mkpath and
  `setupMonad` for each constituent monad. `setupSampling` is called only once,
  not once-per-monad.
- `Trial`: mkpath + recurse into each sampling.
"""
function prepareTrialHierarchy(M::AbstractMonad; kwargs...)
    mkpath(trialFolder(M))
    success = setupSampling(mm_globals().simulator, M; kwargs...)
    success || return false
    return setupMonad(mm_globals().simulator, M; kwargs...)
end

function prepareTrialHierarchy(sampling::Sampling; kwargs...)
    mkpath(trialFolder(sampling))
    success = setupSampling(mm_globals().simulator, sampling; kwargs...)
    success || return false
    for monad in sampling.monads
        mkpath(trialFolder(monad))
        success = setupMonad(mm_globals().simulator, monad; kwargs...)
        success || return false
    end
    return true
end

function prepareTrialHierarchy(trial::Trial; kwargs...)
    mkpath(trialFolder(trial))
    for sampling in trial.samplings
        success = prepareTrialHierarchy(sampling; kwargs...)
        success || return false
    end
    return true
end

"""
    pendingSimulationSpecs(T::AbstractTrial) → Vector{SimulationSpec}

Return a [`SimulationSpec`](@ref) for every simulation in `T` that has not yet
started, marking each as `"Queued"` in the database. Always called after
`prepareTrialHierarchy` so all monad folders and input files are in place.

Dispatch behaviour:
- `Simulation`: returns one spec (against the enclosing monad) if not started.
- `Monad`: returns one spec per unstarted simulation in the monad.
- `Sampling` / `Trial`: recurse.
"""
function pendingSimulationSpecs(simulation::Simulation)
    isStarted(simulation; new_status_code="Queued") && return SimulationSpec[]
    return [SimulationSpec(simulation, Monad(simulation).id)]
end

function pendingSimulationSpecs(monad::Monad)
    specs = SimulationSpec[]
    for sim_id in simulationIDs(monad)
        isStarted(sim_id; new_status_code="Queued") && continue
        push!(specs, SimulationSpec(Simulation(sim_id), monad.id))
    end
    return specs
end

pendingSimulationSpecs(sampling::Sampling) =
    reduce(vcat, pendingSimulationSpecs.(sampling.monads); init=SimulationSpec[])

pendingSimulationSpecs(trial::Trial) =
    reduce(vcat, pendingSimulationSpecs.(trial.samplings); init=SimulationSpec[])

#! `run_kwargs` and a loose splat are one channel, not two. Calibration has to bundle -- `runABC`
#! and `resumeCalibration` spend their splat on `ABCSMC` field forwarding, so there is none left for
#! simulator options -- while `run` has always taken loose keywords. Accepting both everywhere means a
#! bundle built once is portable to any entry point, and a loose keyword still works where it always did.
#!
#! Loose wins on a collision: it is the more deliberate spelling at the call site, while the bundle is
#! the form that gets passed around and forgotten.
"""
    _mergeRunKwargs(run_kwargs::NamedTuple, kwargs) → NamedTuple

Combine a `run_kwargs` bundle with loose keyword arguments; a loose key overrides the bundle's.
"""
_mergeRunKwargs(run_kwargs::NamedTuple, kwargs) = merge(run_kwargs, values(kwargs))

"""
    run(T::AbstractTrial; quiet=false, kwargs...) -> MMOutput

Run all pending simulations in `T` and return an [`MMOutput`](@ref).

# Keyword arguments
- `quiet::Bool=false`: when `true`, suppresses per-simulation and per-trial console
  output. Per-sim "Running simulation: N..." lines, the leading "Running ..." header,
  and the trailing "Finished ..." block are all gated by this flag. Used by ABC-SMC
  calibration to keep console output focused on per-generation progress.
- `on_progress::Union{Nothing,Function}=nothing`: optional progress hook. When supplied,
  it is called as `on_progress(:init, n_simulation_tasks)` once after the pending
  simulation count is known, `on_progress(:step, 1)` after each simulation completes, and
  `on_progress(:finish, n_success)` once at the end. When `nothing` (default) the runner
  behaves exactly as before — this keeps the per-simulation completion loop framework-
  agnostic while letting callers (e.g. ABC-SMC calibration) render a live progress bar.
- `post_processor::Union{Nothing,Function}=nothing`: optional user hook run once per
  **successfully completed** simulation, after the simulator's non-destructive
  [`postSimulationProcessing`](@ref) and before its destructive [`postSimulationCleanup`](@ref)
  — so the callback always sees the intact (but processed) output folder.
  It is called as `post_processor(simulation::Simulation)` — the same argument a [`QoI`](@ref)'s
  `compute` receives, so one measurement function serves the sink, sensitivity analysis and
  calibration alike. A [`QoI`](@ref) or a vector of them may be passed instead of a function. Use
  [`simulationID`](@ref) and [`pathToOutputFolder`](@ref)`(simulation)` rather than reaching into
  fields; the hook only fires for simulations that succeeded, and the owning monad is
  `only(monadIDs(simulation))` (which queries the database, and throws if the simulation is gone);
  reading the actual simulation output into usable data is the responsibility of the user
  or the simulator package (e.g. PhysiCellModelManager loaders keyed by `simulationID`).
  Its return value determines storage:
  - `nothing` → nothing is stored (pure side effects).
  - a `NamedTuple` or `AbstractDict` of `name => scalar` → one row keyed by `simulation_id`
    is upserted into the project's post-processing sink (`data/outputs/postprocessing.db`),
    readable via [`postProcessingTable`](@ref). Columns grow dynamically; sims lacking a
    given quantity have `NULL`.
  - any other type → an `ArgumentError` is thrown.
  The callback runs inside the per-simulation worker task (so heavy compute parallelizes),
  but all sink writes are serialized in the main completion loop; user code never touches the
  sink DB directly. `post_processor` is not forwarded to the simulator hooks. If the callback
  (or a simulator hook) throws, `run` **fails fast**: it rethrows a clear error naming the
  stage and simulation with the original stacktrace — it never hangs or swallows the exception.
- All other `kwargs` flow through to `prepareTrialHierarchy` (which forwards
  them to the simulator's [`setupSampling`](@ref) / [`setupMonad`](@ref) hooks) and to
  both [`postSimulationProcessing`](@ref) and [`postSimulationCleanup`](@ref) (e.g.
  `prune_options`). Any simulator-specific flags flow through this channel.
  [`runSimulation`](@ref) takes no kwargs.
- `run_kwargs::NamedTuple=(;)`: simulator options as a bundle, equivalent to passing them
  loosely. Calibration must bundle — `runABC` and `resumeCalibration` spend their keyword
  splat on `ABCSMC` fields — so accepting the bundle here means one assembled once is
  portable to any entry point. Where a key appears both ways, the loose keyword wins.
"""
function run(T::AbstractTrial; quiet::Bool=false,
             on_progress::Union{Nothing,Function}=nothing,
             post_processor=nothing, tags=(),
             run_kwargs::NamedTuple=(;), kwargs...)
    kwargs = _mergeRunKwargs(run_kwargs, kwargs)
    #! A `QoI` (or a vector of them) is accepted here as well as a bare function; `_asPostProcessor`
    #! is the identity on a function, so nothing already written changes. Note the annotation stays
    #! off `post_processor`: a `QoI` is not a `Function`, so restoring it would reject one.
    post_processor = isnothing(post_processor) ? nothing : _asPostProcessor(post_processor)
    #! Applied before anything is dispatched, so tags survive an interrupted run and the
    #! trial is queryable by tag while its simulations are still in flight.
    refreshProvenance!()
    tag!(T, tags...)
    setup_success = prepareTrialHierarchy(T; kwargs...)
    specs = setup_success ? pendingSimulationSpecs(T) : SimulationSpec[]
    n_simulation_tasks = length(specs)
    n_success = 0

    quiet || println("Running $(typeof(T)) $(T.id) requiring $(n_simulation_tasks) simulation$(n_simulation_tasks == 1 ? "" : "s")...")
    isnothing(on_progress) || on_progress(:init, n_simulation_tasks)

    #! Build @task wrappers here. The per-sim println sits inside @task begin … end
    #! so it fires when the task is *scheduled* (i.e. when the simulation actually
    #! starts running), not when the list comprehension constructs the task.
    simulation_tasks = [
        @task begin
            if !quiet
                println("\tRunning simulation: $(spec.simulation.id)...")
                flush(stdout)
            end
            DBInterface.execute(centralDB(), "UPDATE simulations SET status_code_id=$(statusCodeID("Running")) WHERE simulation_id=$(spec.simulation.id);")
            #! A throwing `runSimulation` would otherwise leave the row at "Running" forever:
            #! `isStarted` treats everything except "Not Started" as started, so every later run
            #! skips it *and* reports "found matching simulations ... not re-running them". A
            #! backend bug that throws for every simulation therefore bricks the whole trial.
            #! Record it the same way any other unsuccessful simulation is recorded, then rethrow
            #! so `run` still fails fast -- a bug in the backend is not a result.
            try
                runSimulation(mm_globals().simulator, spec)
            catch
                updateDatabaseOnCompletion(spec.simulation.id, spec.monad_id, false)
                rethrow()
            end
        end
        for spec in specs
    ]

    queue_channel = Channel{Task}(n_simulation_tasks)
    result_channel = Channel{Union{_PostProcessedResult,_SimulationStageError}}(n_simulation_tasks)
    @async for simulation_task in simulation_tasks
        put!(queue_channel, simulation_task)
    end

    for _ in 1:mm_globals().max_number_of_parallel_simulations
        @async for simulation_task in queue_channel
            #! Always deliver a result. Without this catch, an exception in
            #! processSimulationTask (a throwing runSimulation/fetch, simulator hook, or user
            #! post_processor) would kill this worker silently and the completion loop's
            #! `take!` would block forever — a silent, indefinite hang.
            result = try
                processSimulationTask(simulation_task; post_processor=post_processor, kwargs...)
            catch e
                e isa _SimulationStageError ? e :
                    _SimulationStageError(:simulation, nothing, CapturedException(e, catch_backtrace()))
            end
            put!(result_channel, result)
        end
    end

    #! Sink writes are funneled through this single-threaded loop (never the worker tasks)
    #! so a `yield` inside user post-processing code cannot interleave a half-written row.
    #! The sink DB is opened lazily on the first stored quantity, so a post_processor that
    #! only ever returns `nothing` (pure side effects) never creates the file.
    sink_db = nothing
    try
        for _ in 1:n_simulation_tasks
            result = take!(result_channel)
            #! Fail fast on any captured per-simulation error rather than hanging or silently
            #! dropping it. In-flight simulations may still be running; their results are
            #! discarded once we throw.
            result isa _SimulationStageError && throw(result)
            n_success += result.process.success
            if !isnothing(result.qoi)
                isnothing(sink_db) && (sink_db = _openPostProcessingDB())
                _writePostProcessingRow(sink_db, result.process.simulation.id, result.qoi)
            end
            isnothing(on_progress) || on_progress(:step, 1)
        end
    finally
        isnothing(sink_db) || close(sink_db)
    end
    isnothing(on_progress) || on_progress(:finish, n_success)

    if !quiet
        n_asterisks = 1
        asterisks = Dict{String,Int}()
        size_T = length(T)
        println("Finished $(typeof(T)) $(T.id).")
        println("\t- Consists of $(size_T) simulations.")
        print(  "\t- Scheduled $(n_simulation_tasks) simulations to complete this $(typeof(T)).")
        print_low_schedule_message = n_simulation_tasks < size_T
        if print_low_schedule_message
            println(" ($(repeat("*", n_asterisks)))")
            asterisks["low_schedule_message"] = n_asterisks
            n_asterisks += 1
        else
            println()
        end
        print("\t- Successful completion of $(n_success) simulations.")
        print_low_success_warning = n_success < n_simulation_tasks
        if print_low_success_warning
            println(" ($(repeat("*", n_asterisks)))")
            asterisks["low_success_warning"] = n_asterisks
            n_asterisks += 1
        else
            println()
        end
        if print_low_schedule_message
            println("\n($(repeat("*", asterisks["low_schedule_message"]))) ModelManager found matching simulations and will save you time by not re-running them!")
        end
        if print_low_success_warning
            println("\n($(repeat("*", asterisks["low_success_warning"]))) Some simulations did not complete successfully. Check the output.err files for more information.")
        end
        println("\n--------------------------------------------------\n")
    end
    return MMOutput(T, n_simulation_tasks, n_success)
end

"""
    runAbstractTrial(T::AbstractTrial; kwargs...)

Deprecated alias for [`run`](@ref).
"""
function runAbstractTrial(T::AbstractTrial; kwargs...)
    Base.depwarn("`runAbstractTrial` is deprecated. Use `run` instead.", :runAbstractTrial; force=true)
    return run(T; kwargs...)
end

"""
    _PostProcessedResult

Internal pairing carried back from a worker task to the main completion loop: the
[`SimulationProcess`](@ref) plus the value returned by the user `post_processor` (or
`nothing` when there is no post-processor or the simulation failed). Kept private so the
public `SimulationProcess` struct stays unchanged. Failures travel on the same channel as a
`_SimulationStageError` instead.
"""
struct _PostProcessedResult
    process::SimulationProcess
    qoi::Any
end

"""
    _SimulationStageError <: Exception

A failure inside a per-simulation worker: which stage threw (`:simulation` for the launch and
bookkeeping itself, `:postSimulationProcessing`, `:post_processor`, or
`:postSimulationCleanup`), which simulation (when known), and the original exception with its
backtrace as a `CapturedException`.

Workers must never let an exception escape — that would kill the worker task silently and
leave the completion loop in [`run`](@ref) blocked forever on `take!`. Instead the failure is
sent through the result channel as one of these and rethrown by the completion loop, so `run`
fails fast with a message that distinguishes a bug in the user's `post_processor` (actionable
by the user) from one in a simulator hook (actionable by the simulator package author).
"""
struct _SimulationStageError <: Exception
    stage::Symbol
    sim_id::Union{Nothing,Int}
    captured::CapturedException
end

function Base.showerror(io::IO, err::_SimulationStageError)
    stage_desc = err.stage === :post_processor           ? "the user post_processor" :
                 err.stage === :postSimulationProcessing ? "the simulator's postSimulationProcessing hook" :
                 err.stage === :postSimulationCleanup    ? "the simulator's postSimulationCleanup hook" :
                                                           "the simulation worker"
    sim_str = isnothing(err.sim_id) ? "" : " (simulation $(err.sim_id))"
    println(io, "run failed in ", stage_desc, sim_str, ":\n")
    showerror(io, err.captured)
end

"""
    _runStage(stage::Symbol, sim_id, thunk)

Run `thunk()`, rethrowing any exception as a `_SimulationStageError` tagged with
`stage` and `sim_id` so [`run`](@ref) can report where a per-simulation failure occurred.
"""
function _runStage(stage::Symbol, sim_id::Union{Nothing,Int}, thunk)
    try
        return thunk()
    catch e
        throw(_SimulationStageError(stage, sim_id, CapturedException(e, catch_backtrace())))
    end
end

"""
    processSimulationTask(simulation_task; post_processor=nothing, kwargs...)

Schedule and fetch a simulation task, update the database with the outcome, then run the
per-simulation post steps in order:
1. [`postSimulationProcessing`](@ref) — non-destructive simulator processing.
2. the user `post_processor` (only for a successful simulation) — return value captured.
3. [`postSimulationCleanup`](@ref) — destructive simulator cleanup (e.g. pruning), so the
   user callback always sees the intact output folder.

A throwing stage surfaces as a `_SimulationStageError` naming the stage and
simulation. The captured value (if any) is written to the post-processing sink by the
caller's serial completion loop, not here, so this function never touches the sink DB.
"""
function processSimulationTask(simulation_task; post_processor::Union{Nothing,Function}=nothing, kwargs...)
    schedule(simulation_task)
    simulation_process = fetch(simulation_task)
    updateDatabaseOnCompletion(simulation_process.simulation.id,
                               simulation_process.monad_id,
                               simulation_process.success)
    sid = simulation_process.simulation.id

    #! Per-simulation ordering: non-destructive simulator processing → user post_processor
    #! → destructive simulator cleanup. The user callback must see the intact (but processed)
    #! output folder, so pruning/deletion is deferred to postSimulationCleanup.
    _runStage(:postSimulationProcessing, sid,
              () -> postSimulationProcessing(mm_globals().simulator, simulation_process; kwargs...))
    qoi = nothing
    if !isnothing(post_processor) && simulation_process.success
        #! The user's callback takes a `Simulation`; the adapter no longer re-wraps it back into
        #! something that accepts a `SimulationProcess`, so the field is read here instead.
        qoi = _runStage(:post_processor, sid,
                        () -> post_processor(simulation_process.simulation))
    end
    _runStage(:postSimulationCleanup, sid,
              () -> postSimulationCleanup(mm_globals().simulator, simulation_process; kwargs...))
    return _PostProcessedResult(simulation_process, qoi)
end

"""
    updateDatabaseOnCompletion(simulation_id::Int, monad_id::Int, success::Bool)

Update the simulation status in the database after it finishes.
"""
function updateDatabaseOnCompletion(simulation_id::Int, monad_id::Int, success::Bool)
    if success
        DBInterface.execute(centralDB(), "UPDATE simulations SET status_code_id=$(statusCodeID("Completed")) WHERE simulation_id=$(simulation_id);")
    else
        simulationFailed(simulation_id, monad_id)
    end
end

"""
    eraseSimulationIDFromConstituents(simulation_id::Int; monad_id)

Remove `simulation_id` from its monad's constituent CSV.  If the monad becomes
empty, the monad (and its superiors) are deleted.
"""
function eraseSimulationIDFromConstituents(simulation_id::Int; monad_id::Union{Missing,Int}=missing)
    if ismissing(monad_id)
        query = constructSelectQuery("simulations", "WHERE simulation_id = $(simulation_id)")
        df = queryToDataFrame(query)
        all_id_features = [locationIDName(loc) for loc in projectLocations().varied]
        add_id_values = [df[1, id_feature] for id_feature in all_id_features]
        all_variation_id_features = [locationVariationIDName(loc) for loc in projectLocations().varied]
        all_variation_id_values = [df[1, variation_id_feature] for variation_id_feature in all_variation_id_features]
        all_features = [all_id_features; all_variation_id_features]
        all_values = [add_id_values; all_variation_id_values]

        @assert columnsExist(all_features, "monads") "The columns $(all_features) do not all exist in the 'monads' table."
        placeholders = join(["?" for _ in all_features], ",")
        where_str = "WHERE ($(join(all_features, ", "))) = ($placeholders)"
        stmt_str = constructSelectQuery("monads", where_str; selection="monad_id")
        df = stmtToDataFrame(stmt_str, all_values; is_row=true)
        monad_id = df.monad_id[1]
    end
    simulation_ids = constituentIDs(Monad, monad_id)
    index = findfirst(x -> x == simulation_id, simulation_ids)
    if isnothing(index)
        return
    end
    if length(simulation_ids) == 1
        deleteMonad(monad_id; delete_subs=false, delete_supers=true)
        return
    end
    deleteat!(simulation_ids, index)
    recordConstituentIDs(Monad, monad_id, simulation_ids)
end
