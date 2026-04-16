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
    dispatchSimulation(simulation; monad_id, do_full_setup, force_recompile)

Dispatch a single simulation via [`runSimulation`](@ref) on the active simulator.
"""
function dispatchSimulation(simulation::Simulation; monad_id::Union{Missing,Int}=missing, do_full_setup::Bool=true, force_recompile::Bool=false)
    if ismissing(monad_id)
        monad = Monad(simulation)
        monad_id = monad.id
    end
    return runSimulation(mm_globals().simulator, simulation, monad_id;
                         do_full_setup=do_full_setup, force_recompile=force_recompile)
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
    collectSimulationTasks(T::AbstractTrial; force_recompile, do_full_setup)

Collect `Task` objects for every simulation that needs to run under `T`.
"""
collectSimulationTasks(simulation::Simulation; force_recompile::Bool=false) =
    isStarted(simulation; new_status_code="Queued") ? Task[] : [@task dispatchSimulation(simulation; do_full_setup=true, force_recompile=force_recompile)]

function collectSimulationTasks(monad::Monad; do_full_setup::Bool=true, force_recompile::Bool=false)
    mkpath(trialFolder(monad))

    setup_success = setupMonad(mm_globals().simulator, monad; force_recompile=force_recompile, do_full_setup=do_full_setup)
    if !setup_success
        return Task[]
    end

    simulation_tasks = Task[]
    for simulation_id in simulationIDs(monad)
        if isStarted(simulation_id; new_status_code="Queued")
            continue
        end
        simulation = Simulation(simulation_id)
        push!(simulation_tasks, @task dispatchSimulation(simulation; monad_id=monad.id, do_full_setup=false, force_recompile=false))
    end
    return simulation_tasks
end

function collectSimulationTasks(sampling::Sampling; force_recompile::Bool=false)
    mkpath(trialFolder(sampling))

    setup_success = setupSampling(mm_globals().simulator, sampling; force_recompile=force_recompile)
    if !setup_success
        return Task[]
    end

    simulation_tasks = []
    for monad in Monad.(constituentIDs(sampling))
        append!(simulation_tasks, collectSimulationTasks(monad; do_full_setup=false, force_recompile=false))
    end
    return simulation_tasks
end

function collectSimulationTasks(trial::Trial; force_recompile::Bool=false)
    mkpath(trialFolder(trial))
    simulation_tasks = []
    for sampling in Sampling.(constituentIDs(trial))
        append!(simulation_tasks, collectSimulationTasks(sampling; force_recompile=force_recompile))
    end
    return simulation_tasks
end

"""
    run(T::AbstractTrial; force_recompile, kwargs...)

Run all pending simulations in `T` and return an [`MMOutput`](@ref).

`kwargs` are forwarded to [`postSimulationProcessing`](@ref) for each completed
simulation.  For example, `PhysiCellModelManager` accepts `prune_options`.
"""
function run(T::AbstractTrial; force_recompile::Bool=false, kwargs...)
    simulation_tasks = collectSimulationTasks(T; force_recompile=force_recompile)
    n_simulation_tasks = length(simulation_tasks)
    n_success = 0

    println("Running $(typeof(T)) $(T.id) requiring $(n_simulation_tasks) simulation$(n_simulation_tasks == 1 ? "" : "s")...")

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
    end

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

Schedule and fetch a simulation task, then call
[`postSimulationProcessing`](@ref) on the active simulator.
"""
function processSimulationTask(simulation_task; kwargs...)
    schedule(simulation_task)
    simulation_process = fetch(simulation_task)
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
