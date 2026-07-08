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
- `process::Union{Nothing,Base.Process}`: `nothing` if the command could not be built.
- `success::Bool`
"""
struct SimulationProcess
    simulation::Simulation
    monad_id::Int
    process::Union{Nothing,Base.Process}
    success::Bool
end

"""
    simulationID(simulation_process::SimulationProcess)

Return the ID of the simulation this process ran. Accessor for use inside a `post_processor`
(see [`run`](@ref)) so users need not reach into `simulation_process.simulation.id`.
"""
simulationID(simulation_process::SimulationProcess) = simulation_process.simulation.id

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
    prepareHPCCommand(cmd::Cmd, simulation_id::Int)

Wrap `cmd` in an `sbatch` invocation using the global job options.
"""
function prepareHPCCommand(cmd::Cmd, simulation_id::Int)
    path_to_simulation_folder = trialFolder(Simulation, simulation_id)
    base_cmd_str = "sbatch"
    flags = ["--wrap=$(prepCmdForWrap(Cmd(cmd.exec)))",
             "--wait",
             "--output=$(joinpath(path_to_simulation_folder, "output.log"))",
             "--error=$(joinpath(path_to_simulation_folder, "output.err"))",
             "--chdir=$(simulatorDir(mm_globals().simulator))"
            ]
    for (k, v) in mm_globals().sbatch_options
        @assert !(k in ["wrap", "output", "error", "wait", "chdir"]) "The key $k is reserved for ModelManager to set in the sbatch command."
        if typeof(v) <: Function
            v = v(simulation_id)
        end
        if occursin(" ", v)
            v = "\"$v\""
        end
        push!(flags, "--$k=$v")
    end
    return `$base_cmd_str $flags`
end

"""
    SimulationSpec

A pending simulation to be launched. Produced by [`pendingSimulationSpecs`](@ref)
and consumed by [`run`](@ref), which wraps each spec in a `@task` that calls
[`runSimulation`](@ref) on the active simulator.

`monad_id` is always a real monad ID — [`prepareTrialHierarchy`](@ref) always runs
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
[`prepareTrialHierarchy`](@ref) so all monad folders and input files are in place.

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
  It is called as `post_processor(simulation_process::SimulationProcess)`. Use the accessors
  [`simulationID`](@ref), [`monadID`](@ref), [`wasSuccessful`](@ref), and
  [`pathToOutputFolder`](@ref)`(simulation_process)` to access these fields;
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
- All other `kwargs` flow through to [`prepareTrialHierarchy`](@ref) (which forwards
  them to the simulator's [`setupSampling`](@ref) / [`setupMonad`](@ref) hooks) and to
  both [`postSimulationProcessing`](@ref) and [`postSimulationCleanup`](@ref) (e.g.
  `prune_options`). Any simulator-specific flags flow through this channel.
  [`runSimulation`](@ref) takes no kwargs.
"""
function run(T::AbstractTrial; quiet::Bool=false,
             on_progress::Union{Nothing,Function}=nothing,
             post_processor::Union{Nothing,Function}=nothing, kwargs...)
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
            runSimulation(mm_globals().simulator, spec)
        end
        for spec in specs
    ]

    queue_channel = Channel{Task}(n_simulation_tasks)
    result_channel = Channel{_PostProcessedResult}(n_simulation_tasks)
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
                _PostProcessedResult(nothing, nothing,
                                     (stage=:simulation, sim_id=nothing, exception=e, backtrace=catch_backtrace()))
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
            isnothing(result.error) || _rethrowWorkerError(result.error)
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
[`SimulationProcess`](@ref), the value returned by the user `post_processor` (or `nothing`),
and any captured error.

`process` is `nothing` only when the simulation task itself threw before a
`SimulationProcess` was produced. `error`, when non-`nothing`, is a `NamedTuple`
`(stage, sim_id, exception, backtrace)` identifying where the failure occurred (`:simulation`,
`:postSimulationProcessing`, `:post_processor`, or `:postSimulationCleanup`); the completion
loop in [`run`](@ref) rethrows it with context so a failure surfaces as a clear error instead
of silently hanging the run. Kept private so the public `SimulationProcess` struct stays
unchanged.
"""
struct _PostProcessedResult
    process::Union{Nothing,SimulationProcess}
    qoi::Any
    error::Union{Nothing,NamedTuple}
end

_PostProcessedResult(process, qoi) = _PostProcessedResult(process, qoi, nothing)

"""
    _runStage(stage::Symbol, sim_id, thunk) -> (error_or_nothing, value_or_nothing)

Run `thunk()` capturing any exception as a `(stage, sim_id, exception, backtrace)` NamedTuple
instead of letting it escape. Returns `(nothing, value)` on success and `(error, nothing)` on
failure. Used by [`processSimulationTask`](@ref) so a throwing per-simulation stage becomes a
result carried back to the completion loop rather than a lost exception that hangs the run.
"""
function _runStage(stage::Symbol, sim_id::Union{Nothing,Int}, thunk)
    try
        return (nothing, thunk())
    catch e
        return ((stage=stage, sim_id=sim_id, exception=e, backtrace=catch_backtrace()), nothing)
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

Each stage's exceptions are captured (with which stage and which simulation) and returned in a
[`_PostProcessedResult`](@ref) rather than thrown, so the worker never dies silently. The
captured value (if any) is written to the post-processing sink by the caller's serial
completion loop, not here, so this function never touches the sink DB.
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
    err, _ = _runStage(:postSimulationProcessing, sid,
                       () -> postSimulationProcessing(mm_globals().simulator, simulation_process; kwargs...))
    isnothing(err) || return _PostProcessedResult(simulation_process, nothing, err)

    qoi = nothing
    if !isnothing(post_processor) && simulation_process.success
        err, qoi = _runStage(:post_processor, sid, () -> post_processor(simulation_process))
        isnothing(err) || return _PostProcessedResult(simulation_process, nothing, err)
    end

    err, _ = _runStage(:postSimulationCleanup, sid,
                       () -> postSimulationCleanup(mm_globals().simulator, simulation_process; kwargs...))
    isnothing(err) || return _PostProcessedResult(simulation_process, qoi, err)

    return _PostProcessedResult(simulation_process, qoi, nothing)
end

"""
    _rethrowWorkerError(err::NamedTuple)

Rethrow a per-simulation error captured by a worker task (see [`_runStage`](@ref)) as a clear,
actionable `ErrorException` naming the stage and simulation and embedding the original
stacktrace. Distinguishes a failure in the user `post_processor` (actionable by the user) from
one in a simulator hook (actionable by the simulator package author).
"""
function _rethrowWorkerError(err::NamedTuple)
    stage_desc = err.stage === :post_processor          ? "the user post_processor" :
                 err.stage === :postSimulationProcessing ? "the simulator's postSimulationProcessing hook" :
                 err.stage === :postSimulationCleanup    ? "the simulator's postSimulationCleanup hook" :
                                                           "the simulation worker"
    sim_str = isnothing(err.sim_id) ? "" : " (simulation $(err.sim_id))"
    error("run failed in $(stage_desc)$(sim_str):\n\n" *
          sprint(showerror, err.exception, err.backtrace))
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
