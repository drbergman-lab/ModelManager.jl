using Dates

export deleteSimulation, deleteSimulations, deleteAllSimulations, deleteSimulationsByStatus
export deleteMonad, deleteSampling, deleteTrial, resetDatabase

"""
    deleteSimulations(simulation_ids; delete_supers, filters)
    deleteSimulation(args...; kwargs...)

Delete simulations from the database and from disk.

Also removes each deleted simulation's row (if any) from the post-processing sink
(`data/outputs/postprocessing.db`), keeping it consistent with the central database.

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

    # Keep the post-processing sink consistent with the central DB. Every cascading deletion
    # (deleteMonad/deleteSampling/deleteTrial with delete_subs) routes actual simulation
    # removal through here, so this one call covers them all.
    _deletePostProcessingRows(simulation_ids)

    # SQLite cannot foreign-key the polymorphic (trial_class, trial_id) pair in `tags`,
    # so tag cleanup rides along here, at the same single choke point.
    deleteTagsFor(Simulation, simulation_ids)

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
    deleteTagsFor(Monad, monad_ids)
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
    deleteTagsFor(Sampling, sampling_ids)
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
    deleteTagsFor(Trial, trial_ids)
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

Reset the database after user confirmation: delete all output folders, remove the
post-processing sink (`data/outputs/postprocessing.db`), clear all variation files,
call [`clearSimulatorArtifacts`](@ref) on the active simulator, then reinitialize the
database.

On a shared filesystem some of what this removes may be staged in `data/.trash/` rather than
deleted — see [`rm_hpc_safe`](@ref). That space is not reclaimed until the files are released
and a later session retries them.
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
    rm_hpc_safe(postProcessingDBPath(); force=true)

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

    #! The one call site where a swallowed failure is corruption rather than a leak:
    #! `initializeDatabase` below reopens by path, so a file we failed to remove would be built
    #! on top of while this reports a successful reset. `:staged` is fine — the path is gone and
    #! a fresh database is created.
    if rm_hpc_safe("$(centralDB().file)"; force=true) === :unremoved
        error("""
        Could not remove the central database file
            $(centralDB().file)
        so the reset cannot finish — reinitializing now would build on top of the old database.
        The warning above names the underlying filesystem error. Output folders have already been
        removed or staged; rerun `resetDatabase` once the file can be deleted.
        """)
    end
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

Remove `path`, tolerating shared cluster filesystems that refuse to release files.

Off HPC — the default; see [`useHPC`](@ref) — this is exactly `rm(path; force, recursive)`,
exceptions included.

On HPC that same `rm` is attempted first, since removing is the only thing that actually frees
disk space. A network filesystem routinely refuses to remove a directory that a process on
another node still holds open, and `rm` throws. Whatever survives is then *moved* into
`data/.trash/data-YYMMDD/`, mirroring its position under `data/`, which succeeds where removal
does not because a rename never releases the file. A path outside `data/` is staged under
`_external/`.

Returns:

- `:removed` — `rm` succeeded.
- `:staged` — the residue was moved into `data/.trash/`. **Nothing staged there has had its
  space reclaimed**, and the first time it happens in a project a warning says so and names the
  directory. [`initializeModelManager`](@ref) retries the removal in the background at the start
  of every later session, so staged paths clear themselves once the jobs holding them exit.
- `:unremoved` — neither worked. `path` is left where it is and a warning names it.

In HPC mode a filesystem failure does not throw: every caller deletes the corresponding database
rows *before* calling this, and most call it inside a loop over many simulations, so an exception
here would abandon a bulk deletion with the rows already gone. Check the return value where a
removal must be guaranteed — [`resetDatabase`](@ref) does, for the central database file. A
missing `path` with `force=false` still throws, exactly as `rm` does.

# Examples
```julia
rm_hpc_safe(joinpath(dataDir(), "outputs", "simulations", "7"); force=true, recursive=true)

if rm_hpc_safe(path_to_file; force=true) === :staged
    @info "still on disk under \$(joinpath(dataDir(), ".trash"))"
end
```
"""
function rm_hpc_safe(path::String; force::Bool=false, recursive::Bool=false)
    if !mm_globals().run_on_hpc
        rm(path; force=force, recursive=recursive)
        return :removed
    end
    #! Try the real removal first. Staging alone never frees a byte, which is why a cluster
    #! project has never reclaimed anything: every deletion relocated its output tree into
    #! `data/.trash` and left it there, and `resetDatabase` roughly doubled disk usage.
    try
        rm(path; force=force, recursive=recursive)
    catch rm_error
        rm_error isa InterruptException && rethrow()
        return _stageResidue(path, rm_error)
    end
    return :removed
end

#! Move what `rm` could not remove out of the project tree; a rename succeeds where an unlink
#! does not, precisely because it never releases the file. Never throws for a filesystem failure
#! — see the `rm_hpc_safe` docstring for why a throw here is worse than a leak. The catch is
#! deliberately broad (only `InterruptException` is re-raised) because the contract is "do not
#! throw"; the caught exception is interpolated into the warning so a genuine bug stays visible.
function _stageResidue(path::AbstractString, rm_error)
    if !_existsQuietly(path)
        #! `rm` threw but left nothing behind, or the path never existed. In the latter case the
        #! error is the one the local branch would have raised (`force=false` on a missing path),
        #! so preserve it rather than papering over the mistake only on a cluster.
        throw(rm_error)
    end
    local dest
    try
        dest = _trashDestination(path)
        mkpath(dirname(dest))
        #! No `force`: `dest` is unique by construction, so `force` would only license
        #! clobbering something staged earlier.
        mv(path, dest)
    catch e
        e isa InterruptException && rethrow()
        _warnOnce(:unremoved, """
        Could not remove
            $(path)
        and could not move it out of the way either.
            `rm` failed with:    $(rm_error)
            staging failed with: $(e)
        Its database rows have already been deleted, so nothing tracks this path any more —
        remove it yourself once the filesystem allows it. Deletion continued with the remaining
        entries rather than stopping part-way. Only the first such path in this project is
        reported.
        """)
        return :unremoved
    end
    _warnOnce(:staged, """
    This filesystem would not let ModelManager finish removing a path, so what was left of it was
    moved aside rather than deleted:
        $(path)
     -> $(dest)
    That is expected on a cluster: a network filesystem keeps a file alive until every node has
    released it. The path is out of the project tree and out of the database, but whatever is
    staged still occupies disk and quota, and none of it is a backup.
    ModelManager retries the removal in the background at the start of every session, so this
    normally clears itself once the jobs holding those files exit. To check or clear it now:
        du -sh $(_trashRoot())
        rm -rf $(_trashRoot())
    Only the first staged path in this project is reported.
    """)
    return :staged
end

_trashRoot() = joinpath(dataDir(), ".trash")

#! `path` is normally inside `dataDir()`, but never assume it: `rm_hpc_safe` is exported and the
#! manual tells users to prefer it in their own cleanup code. The old mapping was
#! `replace(path, "$(dataDir())/" => "")`, which hardcoded `/` and, for anything outside `data/`,
#! left the string absolute — `joinpath` discards everything before an absolute component, so
#! `dest` came back equal to `path`, the collision loop bumped it to `<path>-1`, and the "move"
#! silently renamed the target in place and never staged it, with no error at all. Plain
#! `relpath` is not the fix either: it yields `../..` prefixes that escape the trash, and `.` for
#! `dataDir()` itself, which would move `data/` into its own subtree.
function _trashDestination(path::AbstractString)
    #! Guard before `abspath`, which turns an empty `dataDir()` into the current working
    #! directory — staging would then quietly create `.trash` wherever Julia happens to be
    #! running. `_stageResidue` turns this into an `:unremoved` warning naming the reason.
    isempty(dataDir()) && error("ModelManager is not initialized for a project, so there is " *
                                "nowhere to stage `$(path)`.")
    p = abspath(normpath(path))
    root = abspath(normpath(dataDir()))
    rel = _isStrictlyUnder(p, root) ? relpath(p, root) : joinpath("_external", basename(p))
    base = joinpath(root, ".trash", "data-$(Dates.format(now(), "yymmdd"))", rel)
    stem, ext = splitext(base)
    dest = base
    #! Never overwrite: the same folder created and deleted twice on one day must not clobber its
    #! own earlier staging. Bounded so an unstattable destination cannot spin.
    for n in 1:1_000
        _existsQuietly(dest) || break
        dest = "$(stem)-$(n)$(ext)"
    end
    return dest
end

#! Component-wise, so it is separator-agnostic and immune to the `"/a/bc"` starts-with `"/a/b"`
#! trap. Strict: `p == root` is false, since staging `dataDir()` itself would move it into its
#! own subtree.
function _isStrictlyUnder(p::AbstractString, root::AbstractString)
    isempty(root) && return false
    pp = splitpath(p)
    pr = splitpath(root)
    length(pp) > length(pr) || return false
    return all(i -> pp[i] == pr[i], eachindex(pr))
end

#! `ispath` follows symlinks, so a dangling one reads as absent even though `rm` can and should
#! remove it; and it throws `Base.IOError` on an unreadable parent, inside a function whose
#! contract is not to throw. An unanswerable question is treated as "something may be there", so
#! the outcome is a reported staging failure rather than a silent claim of success.
function _existsQuietly(path::AbstractString)
    try
        return ispath(path) || islink(path)
    catch e
        e isa InterruptException && rethrow()
        return true
    end
end

#! Same latch-on-globals idiom as `_maybeShowTagHint` in src/tags.jl: once per project, cleared
#! by `initializeModelManager`. `maxlog=1` was the zero-field option and is wrong here — it is
#! keyed per call site for the whole Julia session, so it never re-arms for a second project, and
#! `Test.TestLogger` gets fresh `message_limits` for every `@test_logs` block, which makes a
#! `maxlog` warn-once indistinguishable from warn-always under test.
function _warnOnce(kind::Symbol, msg::AbstractString)
    kind in mm_globals().trash_notices_shown && return nothing
    push!(mm_globals().trash_notices_shown, kind)
    @warn msg
    return nothing
end

#! Retry what `rm_hpc_safe` had to stage. The handles that blocked the original removal belong to
#! jobs that have since exited, so a later attempt usually just works — this, not the staging, is
#! what actually reclaims the space. Runs in the background task launched by
#! `initializeModelManager` and must never take initialization down with it.
function _sweepTrash()
    try
        isempty(dataDir()) && return nothing
        trash = _trashRoot()
        isdir(trash) || return nothing
        #! Two days, not one: the bucket label comes from `now()` in whichever session created
        #! it, and with the UTC-12..UTC+14 spread a bucket a concurrent session is still staging
        #! into can be dated a day either side of our local date. Sweeping one out from under it
        #! would turn a healthy stage into a spurious `:unremoved`. Skipping anything dated after
        #! two days ago covers a future-dated bucket for free.
        cutoff = today() - Day(2)
        for entry in readdir(trash)
            d = _trashBucketDate(entry)
            #! Only touch buckets this package created, and only once they are old enough.
            (isnothing(d) || d > cutoff) && continue
            try
                rm(joinpath(trash, entry); force=true, recursive=true)
            catch e
                e isa InterruptException && rethrow()
                #! Still held open somewhere; a later session gets it.
            end
        end
        #! Remove the directory itself when empty, so its absence is the signal that nothing was
        #! left behind.
        isempty(readdir(trash)) && rm(trash)
    catch e
        e isa InterruptException && rethrow()
        #! Housekeeping must never fail an initialization.
    end
    return nothing
end

#! `data-YYMMDD` -> `Date`, or `nothing` for anything this package did not create. Note that
#! `Date("260803", "yymmdd")` parses the year as 26 rather than 2026, so build it from the digit
#! pairs instead.
function _trashBucketDate(entry::AbstractString)
    m = match(r"^data-(\d{2})(\d{2})(\d{2})$", entry)
    isnothing(m) && return nothing
    return tryparse(Date, "20$(m[1])-$(m[2])-$(m[3])")
end

#! Public despite not being exported: the manual documents it as the targeted alternative to
#! a full `resetDatabase`. See CLAUDE.md, "Docstring cross-references".
@compat public resetFolder
