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
- All other `kwargs` flow through to [`prepareTrialHierarchy`](@ref) (which forwards
  them to the simulator's [`setupSampling`](@ref) / [`setupMonad`](@ref) hooks) and to
  [`postSimulationProcessing`](@ref). Any simulator-specific flags flow through this
  channel. [`runSimulation`](@ref) takes no kwargs.
"""
function run(T::AbstractTrial; quiet::Bool=false,
             on_progress::Union{Nothing,Function}=nothing, kwargs...)
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
    result_channel = Channel{SimulationProcess}(n_simulation_tasks)
    @async for simulation_task in simulation_tasks
        put!(queue_channel, simulation_task)
    end

    for _ in 1:mm_globals().max_number_of_parallel_simulations
        @async for simulation_task in queue_channel
            put!(result_channel, processSimulationTask(simulation_task; kwargs...))
        end
    end

    for _ in 1:n_simulation_tasks
        simulation_process = take!(result_channel)
        n_success += simulation_process.success
        isnothing(on_progress) || on_progress(:step, 1)
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
    processSimulationTask(simulation_task; kwargs...)

Schedule and fetch a simulation task, update the database with the outcome, then call
[`postSimulationProcessing`](@ref) on the active simulator.
"""
function processSimulationTask(simulation_task; kwargs...)
    schedule(simulation_task)
    simulation_process = fetch(simulation_task)
    updateDatabaseOnCompletion(simulation_process.simulation.id,
                               simulation_process.monad_id,
                               simulation_process.success)
    postSimulationProcessing(mm_globals().simulator, simulation_process; kwargs...)
    return simulation_process
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
