using Dates

export deleteSimulation, deleteSimulations, deleteSimulationsByStatus, resetDatabase

"""
    deleteSimulations(simulation_ids; delete_supers, filters)
    deleteSimulation(args...; kwargs...)

Delete simulations from the database and from disk.

If `delete_supers` is `true` (default), also removes any monads/samplings/trials
that become empty after the deletion.  `filters` adds extra SQL `WHERE` conditions.

# Examples
```julia
deleteSimulations(1:3)
deleteSimulations(4)
deleteSimulations(1:100; filters=Dict("config_id" => 1))
```
"""
function deleteSimulations(simulation_ids::AbstractVector{<:Union{Integer,Missing}};
                            delete_supers::Bool=true,
                            filters::Dict{<:AbstractString,<:Any}=Dict{AbstractString,Any}())
    assertInitialized()
    simulation_ids = Vector(simulation_ids)
    filter!(x -> !ismissing(x), simulation_ids)
    where_stmt, params = buildWhereClause("simulations", simulation_ids, filters)
    stmt_str = constructSelectQuery("simulations", where_stmt)
    sim_df = stmtToDataFrame(stmt_str, params)
    simulation_ids = sim_df.simulation_id

    DBInterface.execute(centralDB(), "DELETE FROM simulations WHERE simulation_id IN ($(join(simulation_ids, ",")));")

    for row in eachrow(sim_df)
        rm_hpc_safe(trialFolder(Simulation, row.simulation_id); force=true, recursive=true)

        for (location, location_dict) in pairs(inputsDict())
            if !any(location_dict["varied"])
                continue
            end
            id_name = locationIDName(location)
            row_id = row[id_name]
            folder = inputFolderName(location, row_id)
            result_df = constructSelectQuery(
                "simulations",
                "WHERE $(id_name) = $(row_id) AND $(locationVariationIDName(location)) = $(row[locationVariationIDName(location)])";
                selection="COUNT(*)"
            ) |> queryToDataFrame
            if result_df.var"COUNT(*)"[1] == 0
                rm_hpc_safe(joinpath(locationPath(location, folder), locationVariationsTableName(location), "$(location)_variation_$(row[locationVariationIDName(location)]).xml"); force=true)
            end
        end
    end

    if !delete_supers
        return nothing
    end

    monad_ids = constructSelectQuery("monads"; selection="monad_id") |> queryToDataFrame |> x -> x.monad_id
    monad_ids_to_delete = Int[]
    for monad_id in monad_ids
        monad_simulation_ids = constituentIDs(Monad, monad_id)
        if !any(x -> x in simulation_ids, monad_simulation_ids)
            continue
        end
        filter!(x -> !(x in simulation_ids), monad_simulation_ids)
        if isempty(monad_simulation_ids)
            push!(monad_ids_to_delete, monad_id)
        else
            recordConstituentIDs(Monad, monad_id, monad_simulation_ids)
        end
    end
    if !isempty(monad_ids_to_delete)
        deleteMonad(monad_ids_to_delete; delete_subs=false, delete_supers=true)
    end
    return nothing
end

deleteSimulations(simulation_id::Int; kwargs...) = deleteSimulations([simulation_id]; kwargs...)
deleteSimulations(simulations::Vector{Simulation}; kwargs...) = deleteSimulations([sim.id for sim in simulations]; kwargs...)
deleteSimulations(simulation::Simulation; kwargs...) = deleteSimulations([simulation]; kwargs...)

"""
    deleteSimulation(args...; kwargs...)

Alias for [`deleteSimulations`](@ref).
"""
deleteSimulation = deleteSimulations

"""
    deleteAllSimulations(; kwargs...)

Delete all simulations. See [`deleteSimulations`](@ref) for keyword arguments.
"""
deleteAllSimulations(; kwargs...) = simulationIDs() |> x -> deleteSimulations(x; kwargs...)

"""
    deleteMonad(monad_ids; delete_subs, delete_supers)

Delete monads by ID, optionally cascading to their simulations and to empty
samplings/trials above them.
"""
function deleteMonad(monad_ids::AbstractVector{<:Integer}; delete_subs::Bool=true, delete_supers::Bool=true)
    DBInterface.execute(centralDB(), "DELETE FROM monads WHERE monad_id IN ($(join(monad_ids, ",")));")
    simulation_ids_to_delete = Int[]
    for monad_id in monad_ids
        if delete_subs
            append!(simulation_ids_to_delete, constituentIDs(Monad, monad_id))
        end
        rm_hpc_safe(trialFolder(Monad, monad_id); force=true, recursive=true)
    end
    if !isempty(simulation_ids_to_delete)
        deleteSimulations(simulation_ids_to_delete; delete_supers=false)
    end

    if !delete_supers
        return nothing
    end

    sampling_ids = constructSelectQuery("samplings"; selection="sampling_id") |> queryToDataFrame |> x -> x.sampling_id
    sampling_ids_to_delete = Int[]
    for sampling_id in sampling_ids
        sampling_monad_ids = constituentIDs(Sampling, sampling_id)
        if !any(x -> x in monad_ids, sampling_monad_ids)
            continue
        end
        filter!(x -> !(x in monad_ids), sampling_monad_ids)
        if isempty(sampling_monad_ids)
            push!(sampling_ids_to_delete, sampling_id)
        else
            recordConstituentIDs(Sampling, sampling_id, sampling_monad_ids)
        end
    end
    if !isempty(sampling_ids_to_delete)
        deleteSampling(sampling_ids_to_delete; delete_subs=false, delete_supers=true)
    end
    return nothing
end

deleteMonad(monad_id::Int; kwargs...) = deleteMonad([monad_id]; kwargs...)

"""
    deleteSampling(sampling_ids; delete_subs, delete_supers)

Delete samplings by ID, optionally cascading.
"""
function deleteSampling(sampling_ids::AbstractVector{<:Integer}; delete_subs::Bool=true, delete_supers::Bool=true)
    DBInterface.execute(centralDB(), "DELETE FROM samplings WHERE sampling_id IN ($(join(sampling_ids, ",")));")
    monad_ids_to_delete = Int[]
    for sampling_id in sampling_ids
        if delete_subs
            append!(monad_ids_to_delete, constituentIDs(Sampling, sampling_id))
        end
        rm_hpc_safe(trialFolder(Sampling, sampling_id); force=true, recursive=true)
    end
    if !isempty(monad_ids_to_delete)
        all_sampling_ids = constructSelectQuery("samplings"; selection="sampling_id") |> queryToDataFrame |> x -> x.sampling_id
        for sampling_id in all_sampling_ids
            if sampling_id in sampling_ids
                continue
            end
            monad_ids = constituentIDs(Sampling, sampling_id)
            filter!(x -> !(x in monad_ids), monad_ids_to_delete)
        end
        deleteMonad(monad_ids_to_delete; delete_subs=true, delete_supers=false)
    end

    if !delete_supers
        return nothing
    end

    trial_ids = constructSelectQuery("trials"; selection="trial_id") |> queryToDataFrame |> x -> x.trial_id
    trial_ids_to_delete = Int[]
    for trial_id in trial_ids
        trial_sampling_ids = constituentIDs(Trial, trial_id)
        if !any(x -> x in sampling_ids, trial_sampling_ids)
            continue
        end
        filter!(x -> !(x in sampling_ids), trial_sampling_ids)
        if isempty(trial_sampling_ids)
            push!(trial_ids_to_delete, trial_id)
        else
            recordConstituentIDs(Trial, trial_id, trial_sampling_ids)
        end
    end
    if !isempty(trial_ids_to_delete)
        deleteTrial(trial_ids_to_delete; delete_subs=false)
    end
    return nothing
end

deleteSampling(sampling_id::Int; kwargs...) = deleteSampling([sampling_id]; kwargs...)

"""
    deleteTrial(trial_ids; delete_subs)

Delete trials by ID, optionally cascading to their samplings.
"""
function deleteTrial(trial_ids::AbstractVector{<:Integer}; delete_subs::Bool=true)
    DBInterface.execute(centralDB(), "DELETE FROM trials WHERE trial_id IN ($(join(trial_ids, ",")));")
    sampling_ids_to_delete = Int[]
    for trial_id in trial_ids
        if delete_subs
            append!(sampling_ids_to_delete, constituentIDs(Trial, trial_id))
        end
        rm_hpc_safe(trialFolder(Trial, trial_id); force=true, recursive=true)
    end
    if !isempty(sampling_ids_to_delete)
        all_trial_ids = constructSelectQuery("trials"; selection="trial_id") |> queryToDataFrame |> x -> x.trial_id
        for trial_id in all_trial_ids
            if trial_id in trial_ids
                continue
            end
            sampling_ids = constituentIDs(Trial, trial_id)
            filter!(x -> !(x in sampling_ids), sampling_ids_to_delete)
        end
        deleteSampling(sampling_ids_to_delete; delete_subs=true, delete_supers=false)
    end
    return nothing
end

deleteTrial(trial_id::Int; kwargs...) = deleteTrial([trial_id]; kwargs...)

"""
    resetDatabase(; force_reset, force_continue)

Reset the database after user confirmation: delete all output folders, clear all
variation files, call [`clearSimulatorArtifacts`](@ref) on the active simulator,
then reinitialize the database.
"""
function resetDatabase(; force_reset::Bool=false, force_continue::Bool=false)
    assertInitialized()
    if !force_reset
        println("Are you sure you want to reset the database? (y/n)")
        response = readline()
        if response != "y"
            println("\tYou entered '$response'.\n\tResetting the database has been cancelled.")
            if !force_continue
                println("\nDo you want to continue with the script? (y/n)")
                response = readline()
                if response != "y"
                    println("\tYou entered '$response'.\n\tThe script has been cancelled.")
                    error("Script cancelled.")
                end
                println("You entered '$response'.\n\tThe script will continue.")
            end
            return
        end
    end
    for folder in ["simulations", "monads", "samplings", "trials", "calibrations"]
        rm_hpc_safe(joinpath(dataDir(), "outputs", folder); force=true, recursive=true)
    end

    for (location, location_dict) in pairs(inputsDict())
        if !any(location_dict["varied"])
            continue
        end
        path_to_location = locationPath(location)
        for folder in (readdir(path_to_location, sort=false, join=true) |> filter(x -> isdir(x)))
            resetFolder(location, folder)
        end
        folders = constructSelectQuery(locationTableName(location); selection="folder_name") |> queryToDataFrame |> x -> x.folder_name
        for folder in folders
            resetFolder(location, joinpath(path_to_location, folder))
        end
    end

    clearSimulatorArtifacts(mm_globals().simulator)

    rm_hpc_safe("$(centralDB().file)"; force=true)
    initializeDatabase()
    return nothing
end

"""
    resetFolder(location::Symbol, folder::String)

Remove the variations DB and variations folder from `folder` in `location`.
"""
function resetFolder(location::Symbol, folder::String)
    inputs_dict_entry = inputsDict()[location]
    path_to_folder = locationPath(location, folder)
    if !isdir(path_to_folder)
        return
    end
    if inputs_dict_entry["basename"] isa Vector
        ind = findfirst(x -> joinpath(path_to_folder, x) |> isfile, inputs_dict_entry["basename"])
        if isnothing(ind)
            return
        end
        for base_file in inputs_dict_entry["basename"][ind+1:end]
            rm_hpc_safe(joinpath(path_to_folder, base_file); force=true)
        end
    end
    rm_hpc_safe(joinpath(path_to_folder, locationVariationsDBName(location)); force=true)
    rm_hpc_safe(joinpath(path_to_folder, locationVariationsTableName(location)); force=true, recursive=true)
end

"""
    deleteSimulationsByStatus(status_codes_to_delete::Vector{String}=["Failed"]; user_check::Bool=true)
    deleteSimulationsByStatus(status_code_to_delete::String; user_check::Bool=true)

Delete simulations filtered by status code.
"""
function deleteSimulationsByStatus(status_codes_to_delete::Vector{String}=["Failed"]; user_check::Bool=true)
    assertInitialized()
    df = """
        SELECT simulations.simulation_id, simulations.status_code_id, status_codes.status_code
        FROM simulations
        JOIN status_codes
        ON simulations.status_code_id = status_codes.status_code_id;
    """ |> queryToDataFrame

    for status_code in status_codes_to_delete
        simulation_ids = df.simulation_id[df.status_code .== status_code]
        if isempty(simulation_ids)
            continue
        end
        if user_check
            println("Are you sure you want to delete all $(length(simulation_ids)) simulations with status code '$status_code'? (y/n)")
            response = readline()
            println("You entered '$response'.")
            if response != "y"
                println("\tDeleting simulations with status code '$status_code' has been cancelled.")
                continue
            end
        end
        println("\tDeleting $(length(simulation_ids)) simulations with status code '$status_code'.")
        deleteSimulations(simulation_ids)
    end
end

deleteSimulationsByStatus(status_code_to_delete::String; kwargs...) = deleteSimulationsByStatus([status_code_to_delete]; kwargs...)

"""
    rm_hpc_safe(path::String; force, recursive)

Remove `path`, using a `.trash/` staging area on HPC (NFS) filesystems to avoid
lock issues.
"""
function rm_hpc_safe(path::String; force::Bool=false, recursive::Bool=false)
    if !mm_globals().run_on_hpc
        rm(path; force=force, recursive=recursive)
        return
    end
    if !ispath(path)
        return
    end
    src = path
    path_rel_to_data = replace(path, "$(dataDir())/" => "")
    date_time = Dates.format(now(), "yymmdd")
    initial_dest = joinpath(dataDir(), ".trash", "data-$(date_time)", path_rel_to_data)
    main_path, file_ext = splitext(initial_dest)
    suffix = ""
    path_to_dest(m, s, e) = s == "" ? "$(m)$(e)" : "$(m)-$(s)$(e)"
    while ispath(path_to_dest(main_path, suffix, file_ext))
        suffix = suffix == "" ? "1" : string(parse(Int, suffix) + 1)
    end
    dest = path_to_dest(main_path, suffix, file_ext)
    mkpath(dirname(dest))
    mv(src, dest; force=force)
end
