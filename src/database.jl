using DataFrames

# simulationsTable and printSimulationsTable are simulator-specific — exported by the simulator package

################## Database Initialization Functions ##################

"""
    initializeDatabase()

Initialize the central database, creating the schema if it does not already exist.
"""
function initializeDatabase()
    close(centralDB())
    mm_globals().db = SQLite.DB(centralDB().file)
    SQLite.transaction(centralDB(), "EXCLUSIVE")
    try
        createSchema()
    catch e
        SQLite.rollback(centralDB())
        println("Error initializing database: $e")
        mm_globals().initialized = false
    else
        SQLite.commit(centralDB())
        mm_globals().initialized = true
    end
end

"""
    reinitializeDatabase()

Reinitialize the database, scanning `data/inputs/` to register any new folders.
"""
function reinitializeDatabase()
    if !isInitialized()
        println("Database not initialized. Initialize first with `initializeModelManager`.")
        return
    end
    mm_globals().initialized = false
    initializeDatabase()
    return isInitialized()
end

"""
    createSchema()

Create all tables in the central database.
"""
function createSchema()
    @assert necessaryInputsPresent() "Necessary input folders are not present. Please check the inputs directory."

    sim = mm_globals().simulator
    createMMTable(simulatorVersionTableName(sim), simulatorVersionSchema(sim))
    simulator().current_version_id = resolveSimulatorVersionID(sim)

    for (location, location_dict) in pairs(inputsDict())
        table_name = locationTableName(location)
        table_schema = """
            $(locationIDName(location)) INTEGER PRIMARY KEY,
            folder_name UNIQUE,
            description TEXT
        """
        createMMTable(table_name, table_schema)

        location_path = locationPath(location)
        @assert !location_dict["required"] || isdir(location_path) "$location_path is required but not found."
        folders = readdir(location_path; sort=false) |> filter(x -> isdir(joinpath(location_path, x)))
        for folder in folders
            insertFolder(location, folder)
        end
    end

    sim_version_id_name = simulatorVersionIDName(sim)
    sim_version_table_name = simulatorVersionTableName(sim)
    simulations_schema = """
        simulation_id INTEGER PRIMARY KEY,
        $(sim_version_id_name) INTEGER,
        $(inputIDsSubSchema()),
        $(inputVariationIDsSubSchema()),
        status_code_id INTEGER,
        $(abstractSamplingForeignReferenceSubSchema()),
        FOREIGN KEY (status_code_id)
            REFERENCES status_codes (status_code_id)
    """
    createMMTable("simulations", simulations_schema)

    createMMTable("monads", monadsSchema())
    createMMTable("samplings", samplingsSchema())

    trials_schema = """
        trial_id INTEGER PRIMARY KEY,
        datetime TEXT,
        description TEXT
    """
    createMMTable("trials", trials_schema)

    createDefaultStatusCodesTable()
    createMMTable("calibrations", calibrationsSchema())
end

"""
    calibrationsSchema()

Return the SQL schema string for the `calibrations` table.
"""
function calibrationsSchema()
    return """
    calibration_id INTEGER PRIMARY KEY,
    datetime TEXT,
    description TEXT,
    method TEXT
    """
end

"""
    necessaryInputsPresent()

Return `true` if all required input directories exist.
"""
function necessaryInputsPresent()
    success = true
    for (location, location_dict) in pairs(inputsDict())
        if !location_dict["required"]
            continue
        end
        location_path = locationPath(location)
        if !isdir(location_path)
            println("No $location_path found. This is where to put the folders for $(locationFolder(location)).")
            success = false
        end
    end
    return success
end

"""
    monadsSchema()

Return the SQL schema string for the `monads` table.
"""
function monadsSchema()
    sim = mm_globals().simulator
    sim_version_id_name = simulatorVersionIDName(sim)
    sim_version_table_name = simulatorVersionTableName(sim)
    return """
    monad_id INTEGER PRIMARY KEY,
    $(sim_version_id_name) INTEGER,
    $(inputIDsSubSchema()),
    $(inputVariationIDsSubSchema()),
    $(abstractSamplingForeignReferenceSubSchema()),
    UNIQUE ($(sim_version_id_name),
            $(join([locationIDName(k) for k in keys(inputsDict())], ",\n")),
            $(join([locationVariationIDName(k) for (k, d) in pairs(inputsDict()) if any(d["varied"])], ",\n"))
            )
   """
end

"""
    samplingsSchema()

Return the SQL schema string for the `samplings` table.
"""
function samplingsSchema()
    sim = mm_globals().simulator
    sim_version_id_name = simulatorVersionIDName(sim)
    return """
    sampling_id INTEGER PRIMARY KEY,
    $(sim_version_id_name) INTEGER,
    $(inputIDsSubSchema()),
    $(abstractSamplingForeignReferenceSubSchema())
    """
end

"""
    inputIDsSubSchema()

Return the SQL fragment for all input ID columns.
"""
function inputIDsSubSchema()
    return join(["$(locationIDName(k)) INTEGER" for k in keys(inputsDict())], ",\n")
end

"""
    inputVariationIDsSubSchema()

Return the SQL fragment for all variation ID columns.
"""
function inputVariationIDsSubSchema()
    return join(["$(locationVariationIDName(k)) INTEGER" for (k, d) in pairs(inputsDict()) if any(d["varied"])], ",\n")
end

"""
    abstractSamplingForeignReferenceSubSchema()

Return the SQL fragment for foreign key constraints referencing the simulator
version table and all input tables.
"""
function abstractSamplingForeignReferenceSubSchema()
    sim = mm_globals().simulator
    sim_version_id_name = simulatorVersionIDName(sim)
    sim_version_table_name = simulatorVersionTableName(sim)
    return """
    FOREIGN KEY ($(sim_version_id_name))
        REFERENCES $(sim_version_table_name) ($(sim_version_id_name)),
    $(join(["""
    FOREIGN KEY ($(locationIDName(k)))
        REFERENCES $(locationTableName(k)) ($(locationIDName(k)))\
    """ for k in keys(inputsDict())], ",\n"))
    """
end

"""
    createMMTable(table_name::String, schema::String; db::SQLite.DB=centralDB())

Create a table in the central database if it does not already exist.

The table name must end in `"s"` (for ID naming conventions) and the schema must
include a `PRIMARY KEY` column named `<table_singular>_id`.
"""
function createMMTable(table_name::String, schema::String; db::SQLite.DB=centralDB())
    if last(table_name) != 's'
        throw(ErrorException("Table name must end in 's' (got $(table_name))."))
    end
    id_name = tableIDName(table_name)
    if !occursin("$(id_name) INTEGER PRIMARY KEY", schema)
        throw(ErrorException("Schema must have PRIMARY KEY named $(id_name)."))
    end
    SQLite.execute(db, "CREATE TABLE IF NOT EXISTS $(table_name) (\n$(schema)\n)")
end

"""
    tableIDName(table::String; strip_s::Bool=true)

Return the ID column name for `table` (e.g. `"config_id"` for `"configs"`).
"""
function tableIDName(table::String; strip_s::Bool=true)
    if strip_s
        @assert last(table) == 's' "Table name must end in 's' to strip it."
        table = table[1:end-1]
    end
    return "$(table)_id"
end

"""
    insertFolder(location::Symbol, folder::String, description::String="")

Insert `folder` into the database for `location` (if not already present), create
its per-folder variations SQLite database, and call
[`initializeInputFolder`](@ref) on the active simulator.
"""
function insertFolder(location::Symbol, folder::String, description::String="")
    path_to_folder = locationPath(location, folder)
    sim = mm_globals().simulator
    sim_description = getInputFolderDescription(sim, path_to_folder)
    description = isempty(sim_description) ? description : sim_description

    stmt_str = "INSERT OR IGNORE INTO $(locationTableName(location)) (folder_name, description) VALUES (:folder, :description);"
    params = (; :folder => folder, :description => description)
    stmt = SQLite.Stmt(centralDB(), stmt_str)
    DBInterface.execute(stmt, params)
    if !folderIsVaried(location, folder)
        initializeInputFolder(sim, InputFolder(location, folder))
        return
    end
    db_variations = joinpath(path_to_folder, locationVariationsDBName(location)) |> SQLite.DB
    location_variation_id_name = locationVariationIDName(location)
    table_name = locationVariationsTableName(location)
    createMMTable(table_name, "$location_variation_id_name INTEGER PRIMARY KEY, par_key BLOB UNIQUE"; db=db_variations)
    DBInterface.execute(db_variations, "INSERT OR IGNORE INTO $table_name ($location_variation_id_name, par_key) VALUES(?, ?)", (0, UInt8[]))
    input_folder = InputFolder(location, folder)
    initializeInputFolder(sim, input_folder)
end

"""
    recognizedStatusCodes()

Return the list of valid simulation status code strings.
"""
recognizedStatusCodes() = ["Not Started", "Queued", "Running", "Completed", "Failed"]

"""
    createDefaultStatusCodesTable()

Create (if absent) and populate the `status_codes` table.
"""
function createDefaultStatusCodesTable()
    status_codes_schema = """
        status_code_id INTEGER PRIMARY KEY,
        status_code TEXT UNIQUE
    """
    createMMTable("status_codes", status_codes_schema)
    for status_code in recognizedStatusCodes()
        DBInterface.execute(centralDB(), "INSERT OR IGNORE INTO status_codes (status_code) VALUES ('$status_code');")
    end
end

"""
    statusCodeID(status_code::String)

Return the database ID for `status_code`.
"""
function statusCodeID(status_code::String)
    @assert status_code in recognizedStatusCodes() "Status code $(status_code) is not recognized. Must be one of $(recognizedStatusCodes())."
    query = constructSelectQuery("status_codes", "WHERE status_code='$status_code';"; selection="status_code_id")
    return queryToDataFrame(query; is_row=true) |> x -> x[1, :status_code_id]
end

"""
    isStarted(simulation_id::Int[; new_status_code])

Return `true` if the simulation has been started.  Optionally update its status
atomically (using an `EXCLUSIVE` transaction when a new status is provided).
"""
function isStarted(simulation_id::Int; new_status_code::Union{Missing,String}=missing)
    query = constructSelectQuery("simulations", "WHERE simulation_id=$(simulation_id)"; selection="status_code_id")
    mode = ismissing(new_status_code) ? "DEFERRED" : "EXCLUSIVE"
    SQLite.transaction(centralDB(), mode)
    status_code = queryToDataFrame(query; is_row=true) |> x -> x[1, :status_code_id]
    is_started = status_code != statusCodeID("Not Started")
    if !ismissing(new_status_code) && !is_started
        query = "UPDATE simulations SET status_code_id=$(statusCodeID(new_status_code)) WHERE simulation_id=$(simulation_id);"
        DBInterface.execute(centralDB(), query)
    end
    SQLite.commit(centralDB())
    return is_started
end

isStarted(simulation::Simulation; new_status_code::Union{Missing,String}=missing) = isStarted(simulation.id; new_status_code=new_status_code)

################## DB Interface Functions ##################

"""
    locationVariationsDatabase(location::Symbol, folder::String)

Return a `SQLite.DB` connection to the per-folder variations database for
`location`/`folder`, `nothing` if the folder is empty (location unused), or
`missing` if the variations DB file does not exist.
"""
function locationVariationsDatabase(location::Symbol, folder::String)
    if folder == ""
        return nothing
    end
    path_to_db = joinpath(locationPath(location, folder), locationVariationsDBName(location))
    if !isfile(path_to_db)
        return missing
    end
    return path_to_db |> SQLite.DB
end

function locationVariationsDatabase(location::Symbol, id::Int)
    folder = inputFolderName(location, id)
    return locationVariationsDatabase(location, folder)
end

function locationVariationsDatabase(location::Symbol, S::AbstractSampling)
    folder = S.inputs[location].folder
    return locationVariationsDatabase(location, folder)
end

########### Retrieving Database Information Functions ###########

"""
    queryToDataFrame(query::String; db::SQLite.DB=centralDB(), is_row::Bool=false)

Execute `query` and return the result as a `DataFrame`.

If `is_row` is `true`, asserts that exactly one row is returned.
"""
function queryToDataFrame(query::String; db::SQLite.DB=centralDB(), is_row::Bool=false)
    df = DBInterface.execute(db, query) |> DataFrame
    if is_row
        @assert size(df, 1) == 1 "Did not find exactly one row matching the query:\n\tDatabase: $(db.file)\n\tQuery: $(query)\nResult: $(df)"
    end
    return df
end

"""
    stmtToDataFrame(stmt_str, params; db::SQLite.DB=centralDB(), is_row::Bool=false)
    stmtToDataFrame(stmt::SQLite.Stmt, params; is_row::Bool=false)

Execute a prepared statement with `params` and return the result as a `DataFrame`.
"""
function stmtToDataFrame(stmt::SQLite.Stmt, params; is_row::Bool=false)
    df = DBInterface.execute(stmt, params) |> DataFrame
    if is_row
        @assert size(df, 1) == 1 "Did not find exactly one row matching the statement."
    end
    return df
end

function stmtToDataFrame(stmt_str::AbstractString, params; db::SQLite.DB=centralDB(), is_row::Bool=false)
    stmt = SQLite.Stmt(db, stmt_str)
    try
        return stmtToDataFrame(stmt, params; is_row=is_row)
    catch e
        println("""
        Error executing SQLite statement:
            Statement: $stmt_str
            Parameters: $params
            Database: $(db.file)
            Is row: $is_row
        """)
        rethrow(e)
    end
end

"""
    constructSelectQuery(table_name::String, condition_stmt::String=""; selection::String="*")

Build a `SELECT` SQL string for `table_name`.
"""
constructSelectQuery(table_name::String, condition_stmt::String=""; selection::String="*") =
    "SELECT $(selection) FROM $(table_name) $(condition_stmt);"

"""
    inputFolderName(location::Symbol, id::Int)

Return the folder name for the database row with `id` in `location`.
"""
function inputFolderName(location::Symbol, id::Int)
    if id == -1
        return ""
    end
    query = constructSelectQuery(locationTableName(location), "WHERE $(locationIDName(location))=$(id)"; selection="folder_name")
    return queryToDataFrame(query; is_row=true) |> x -> x.folder_name[1]
end

"""
    inputFolderID(location::Symbol, folder::String)

Return the database row ID for `folder` in `location`.
"""
function inputFolderID(location::Symbol, folder::String)
    if folder == ""
        return -1
    end
    primary_key_string = locationIDName(location)
    stmt_str = constructSelectQuery(locationTableName(location), "WHERE folder_name=(:folder)"; selection=primary_key_string)
    params = (; :folder => folder)
    df = stmtToDataFrame(stmt_str, params; is_row=true)
    return df[1, primary_key_string]
end

"""
    tableExists(table_name::String; db::SQLite.DB=centralDB())

Return `true` if `table_name` exists in `db`.
"""
function tableExists(table_name::String; db::SQLite.DB=centralDB())
    valid_table_names = DBInterface.execute(db, "SELECT name FROM sqlite_master WHERE type='table';") |> DataFrame |> x -> x.name
    return table_name in valid_table_names
end

"""
    columnsExist(column_names, table_name::String; kwargs...)
    columnsExist(column_names, valid_column_names)

Return `true` if all `column_names` exist in the specified table (or list).
"""
function columnsExist(column_names::AbstractVector{<:AbstractString}, table_name::String; kwargs...)
    valid_column_names = tableColumns(table_name; kwargs...)
    return columnsExist(column_names, valid_column_names)
end

function columnsExist(column_names::AbstractVector{<:AbstractString}, valid_column_names::AbstractVector{<:AbstractString})
    return all(c -> c in valid_column_names, column_names)
end

"""
    tableColumns(table_name::String; db::SQLite.DB=centralDB())

Return the column names of `table_name` in `db`.
"""
function tableColumns(table_name::String; db::SQLite.DB=centralDB())
    @assert tableExists(table_name; db=db) "Table $(table_name) does not exist in the database."
    return queryToDataFrame("PRAGMA table_info($(table_name));"; db=db) |> x -> x.name
end

"""
    buildWhereClause(table_name::String, ids::Vector{<:Integer}, filters::Dict; db::SQLite.DB=centralDB())

Build a `WHERE` clause with `ids` and optional column `filters`.
"""
function buildWhereClause(table_name::String, ids::Vector{<:Integer}, filters::Dict{<:AbstractString,<:Any}; db::SQLite.DB=centralDB())
    id_name = tableIDName(table_name)
    valid_column_names = tableColumns(table_name; db=db)
    @assert columnsExist(keys(filters) |> collect, valid_column_names) "Invalid filter keys for table $(table_name): $(collect(setdiff(keys(filters), valid_column_names))). Valid columns: $(valid_column_names)."
    clauses = ["$id_name IN ($(join(ids, ",")))"; ["$col = ?" for col in keys(filters)]]
    params = values(filters) |> collect
    return "WHERE " * join(clauses, " AND "), params
end

########### Database diagnostics ###########

"""
    _snapshotMaxIDs() → Dict{Type{<:AbstractTrial}, Int}

Capture the highest ID currently present for each trial type in both the database
and the output folder tree. Called by [`initializeModelManager`](@ref) just before
launching the background diagnostics task so that [`databaseDiagnostics`](@ref) only
inspects entities that existed at initialization time and is not confused by
in-progress runs started later in the same session.
"""
function _snapshotMaxIDs()
    result = Dict{Type{<:AbstractTrial}, Int}()
    for T in (Simulation, Monad, Sampling, Trial)
        table = lowerClassString(T) * "s"
        id_col = tableIDName(table)

        # Highest ID in the database (MAX returns NULL on empty table → missing)
        val = queryToDataFrame(constructSelectQuery(table; selection="MAX($id_col)"))[1, 1]
        db_max = ismissing(val) ? 0 : Int(val)

        # Highest ID present as an output folder
        out_dir = joinpath(dataDir(), "outputs", table)
        fs_max = if isdir(out_dir)
            ids = filter(!isnothing, tryparse.(Int, readdir(out_dir)))
            isempty(ids) ? 0 : maximum(ids)
        else
            0
        end

        result[T] = max(db_max, fs_max)
    end
    return result
end

"""
    databaseDiagnostics(max_ids::Dict{Type{<:AbstractTrial},Int} = Dict{Type{<:AbstractTrial},Int}())

Check consistency between the database and the output folders.
Prints warnings for any discrepancies found.

When `max_ids` is provided (as returned by [`_snapshotMaxIDs`](@ref)), each check is
restricted to IDs ≤ the snapshot value for that type. This prevents false positives from
simulations that were created or started after `initializeModelManager` returned.
"""
function databaseDiagnostics(max_ids::Dict{Type{<:AbstractTrial},Int}=Dict{Type{<:AbstractTrial},Int}())
    assertInitialized()
    consensus_ids = Dict{Type{<:AbstractTrial}, Set{Int}}()

    #! check that all tables exist and that all entries in the database have corresponding folders
    db_ids = Dict{Type{<:AbstractTrial}, Set{Int}}()
    folder_ids = Dict{Type{<:AbstractTrial}, Set{Int}}()
    missing_dirs = Dict{Type{<:AbstractTrial}, Set{Int}}()
    missing_db_entries = Dict{Type{<:AbstractTrial}, Set{Int}}()
    for T in (Simulation, Monad, Sampling, Trial)
        table_name = lowerClassString(T) * "s"
        db = centralDB()
        @assert tableExists(table_name; db=db) "Table $(table_name) does not exist in $(basename(db.file)). Database is not complete."
        query = constructSelectQuery(table_name; selection=tableIDName(table_name))
        df = queryToDataFrame(query; db=db)
        all_db_ids = Set(df[!, 1])

        path_to_output_folder = joinpath(dataDir(), "outputs", "$(lowerClassString(T))s")
        if isdir(path_to_output_folder)
            folders = readdir(joinpath(dataDir(), "outputs", "$(lowerClassString(T))s"))
        else
            folders = String[]
        end

        folder_ids_found = tryparse.(Int, folders)
        filter!(!isnothing, folder_ids_found)
        all_folder_ids = Set(folder_ids_found)

        # Restrict to IDs that existed at snapshot time (if a snapshot was provided)
        if haskey(max_ids, T)
            cap = max_ids[T]
            db_ids[T]     = filter(id -> id ≤ cap, all_db_ids)
            folder_ids[T] = filter(id -> id ≤ cap, all_folder_ids)
        else
            db_ids[T]     = all_db_ids
            folder_ids[T] = all_folder_ids
        end

        missing_dirs[T] = setdiff(db_ids[T], folder_ids[T])
        missing_db_entries[T] = setdiff(folder_ids[T], db_ids[T])
        consensus_ids[T] = intersect(db_ids[T], folder_ids[T])
    end

    warning_msg_dirs = ""
    for (T, missing_ids) in pairs(missing_dirs)
        if !isempty(missing_ids)
            warning_msg_dirs *= "- $(lowerClassString(T))s with IDs: $(_compressedIDStr(missing_ids))\n"
        end
    end
    if !isempty(warning_msg_dirs)
        warning_msg_dirs = "The following have entries in the database but not a corresponding folder. This can happen if the object is created, but never run.\n" * warning_msg_dirs
        @warn warning_msg_dirs
    end

    warning_msg_dbs = ""
    for (T, missing_ids) in pairs(missing_db_entries)
        if !isempty(missing_ids)
            warning_msg_dbs *= "- $(lowerClassString(T))s with IDs: $(_compressedIDStr(missing_ids))\n"
        end
    end
    if !isempty(warning_msg_dbs)
        warning_msg_dbs = "The following folders exist but are missing their corresponding entries in the database:\n" * warning_msg_dbs
        @error warning_msg_dbs
    end

    #! check that all abstract trials have extant constituent trials
    msg = ""
    for T in (Monad, Sampling, Trial)
        all_recorded_constituent_ids = Set{Int}()
        for id in consensus_ids[T]
            push!(all_recorded_constituent_ids, constituentIDs(T, id)...)
        end
        all_extant_constituent_ids = consensus_ids[constituentType(T)]
        missing_ids = setdiff(all_recorded_constituent_ids, all_extant_constituent_ids)
        if isempty(missing_ids)
            continue
        end
        msg *= "- $(lowerClassString(T))s reference non-existent $(lowerClassString(constituentType(T))) IDs: $(_compressedIDStr(missing_ids))\n"
    end
    if !isempty(msg)
        msg = "The following constituents are expected but not found:\n" * msg
        @error msg
    end

    #! check simulation status of all simulations; warn on concerning codes, info on Failed
    query = constructSelectQuery("simulations"; selection="simulation_id, status_code_id")
    df = queryToDataFrame(query)
    # Restrict to simulations that existed at snapshot time
    if haskey(max_ids, Simulation)
        filter!(row -> row.simulation_id ≤ max_ids[Simulation], df)
    end
    status_codes = recognizedStatusCodes()

    codes_with_issues = String[]
    for status_code in status_codes
        if status_code ∈ ("Completed", "Failed")
            continue
        end
        status_code_id = statusCodeID(status_code)
        concerning_ids = df[df.status_code_id .== status_code_id, :simulation_id]
        if !isempty(concerning_ids)
            @warn "Found $(length(concerning_ids)) simulations in the database with status code '$(status_code)' (ID: $(status_code_id)): $(_compressedIDStr(concerning_ids))."
            push!(codes_with_issues, status_code)
        end
    end

    failed_status_code_id = statusCodeID("Failed")
    failed_ids = df[df.status_code_id .== failed_status_code_id, :simulation_id]
    if !isempty(failed_ids)
        @info "Found $(length(failed_ids)) simulations in the database with status code 'Failed' (ID: $(failed_status_code_id)): $(_compressedIDStr(failed_ids))."
        push!(codes_with_issues, "Failed")
    end

    if !isempty(codes_with_issues)
        arg_string = length(codes_with_issues) == 1 ? "\"$(codes_with_issues[1])\"" : "[$(join(["\"$c\"" for c in codes_with_issues], ", "))]"
        @info """
        If these simulations are no longer needed, you can use `deleteSimulations(simulation_ids)` to remove them from the database.
        You can also use `deleteSimulationsByStatus($arg_string; user_check=false)` to remove all simulations with these status codes.
        """
    end
end

########### Summarizing functions (generic) ###########

"""
    variationIDs(location::Symbol, M::AbstractMonad)
    variationIDs(location::Symbol, sampling::Sampling)

Return the variation IDs for `location` associated with `M` or `sampling`.
"""
variationIDs(location::Symbol, M::AbstractMonad) = [M.variation_id[location]]
variationIDs(location::Symbol, sampling::Sampling) = [monad.variation_id[location] for monad in sampling.monads]

"""
    shortLocationVariationID(fieldname::Symbol)
    shortLocationVariationID(fieldname::String)
    shortLocationVariationID(type::Type, fieldname)

Return the abbreviated column-name symbol for `fieldname`'s variation ID in display tables.

Dispatches to `shortLocationVariationID(simulator(), fieldname)`. The default implementation
returns `locationVariationIDName(fieldname) |> Symbol`. Simulator packages should extend
`shortLocationVariationID(::TheirSimulator, fieldname::Symbol)` to provide custom abbreviations.
"""
shortLocationVariationID(fieldname::Symbol) = shortLocationVariationID(simulator(), fieldname)
shortLocationVariationID(::AbstractSimulator, fieldname::Symbol) = locationVariationIDName(fieldname) |> Symbol
shortLocationVariationID(fieldname::String) = shortLocationVariationID(Symbol(fieldname))
shortLocationVariationID(type::Type, fieldname) = type(shortLocationVariationID(fieldname))

"""
    shortVariationName(location::Symbol, name::String)

Return the display name for variation column `name` at `location`.

Dispatches to `shortVariationName(simulator(), location, name)`. The default returns `name`
unchanged. Simulator packages should extend `shortVariationName(::TheirSimulator, location, name)`
to provide human-readable column names.
"""
shortVariationName(location::Symbol, name::String) = shortVariationName(simulator(), location, name)
shortVariationName(::AbstractSimulator, ::Symbol, name::String) = name

"""
    locationVariationsTable(query::String, db::SQLite.DB; remove_constants::Bool=false)

Return a DataFrame from `query` against `db`, dropping the `par_key` column.
Removes constant columns if `remove_constants` is `true` and there is more than one row.
"""
function locationVariationsTable(query::String, db::SQLite.DB; remove_constants::Bool=false)
    df = queryToDataFrame(query, db=db)
    select!(df, Not(:par_key))
    if remove_constants && size(df, 1) > 1
        col_names = names(df)
        filter!(n -> length(unique(df[!,n])) > 1, col_names)
        select!(df, col_names)
    end
    return df
end

"""
    locationVariationsTable(location::Symbol, variations_database::SQLite.DB, variation_ids::AbstractVector{<:Integer}; remove_constants::Bool=false, short_names::Bool=true)

Return a DataFrame of variation rows for `variation_ids` from `variations_database`.
When `short_names=false`, column names are kept as raw XML paths (joined with `/`) rather
than being passed through `shortVariationName`.
"""
function locationVariationsTable(location::Symbol, variations_database::SQLite.DB, variation_ids::AbstractVector{<:Integer}; remove_constants::Bool=false, short_names::Bool=true)
    used_variation_ids = filter(x -> x != -1, variation_ids)
    query = constructSelectQuery(locationVariationsTableName(location), "WHERE $(locationVariationIDName(location)) IN ($(join(used_variation_ids,",")))")
    df = locationVariationsTable(query, variations_database; remove_constants=remove_constants)
    if short_names
        rename!(name -> shortVariationName(location, name), df)
    else
        # Always rename the variation ID column so appendVariations can join on it;
        # leave parameter columns as raw XML paths for db_column matching.
        id_raw   = locationVariationIDName(location)
        id_short = shortLocationVariationID(String, location)
        id_raw in names(df) && rename!(df, id_raw => id_short)
    end
    return df
end

"""
    locationVariationsTable(location::Symbol, S::AbstractSampling; remove_constants::Bool=false, short_names::Bool=true)

Return a DataFrame of variation rows for the given location and sampling.
"""
function locationVariationsTable(location::Symbol, S::AbstractSampling; remove_constants::Bool=false, short_names::Bool=true)
    return locationVariationsTable(location, locationVariationsDatabase(location, S), variationIDs(location, S); remove_constants=remove_constants, short_names=short_names)
end

"""
    locationVariationsTable(location::Symbol, ::Nothing, variation_ids; kwargs...)

Return a single-column DataFrame for a location that is not being used (all IDs = -1).
"""
function locationVariationsTable(location::Symbol, ::Nothing, variation_ids::AbstractVector{<:Integer}; kwargs...)
    @assert all(x -> x == -1, variation_ids) "If the $(location) is not being used, then all $(locationVariationIDName(location))s must be -1."
    return DataFrame(shortLocationVariationID(location)=>variation_ids)
end

"""
    locationVariationsTable(location::Symbol, ::Missing, variation_ids; kwargs...)

Return a single-column DataFrame for a location whose folder has no variations database (all IDs = 0).
"""
function locationVariationsTable(location::Symbol, ::Missing, variation_ids::AbstractVector{<:Integer}; kwargs...)
    @assert all(x -> x == 0, variation_ids) "If the $(location)_folder does not contain a $(locationVariationsDBName(location)), then all $(locationVariationIDName(location))s must be 0."
    return DataFrame(shortLocationVariationID(location)=>variation_ids)
end

"""
    appendVariations(location::Symbol, df::DataFrame; short_names::Bool=true)

Join the varied parameters for `location` onto `df`.
When `short_names=false`, column names are kept as raw XML paths rather than being
shortened by `shortVariationName`.
"""
function appendVariations(location::Symbol, df::DataFrame; short_names::Bool=true)
    short_var_name = shortLocationVariationID(location)
    var_df = DataFrame(short_var_name => Int[], :folder_name => String[])
    unique_tuples = [(row["$(location)_folder"], row[locationVariationIDName(location)]) for row in eachrow(df)] |> unique
    for unique_tuple in unique_tuples
        temp_df = locationVariationsTable(location, locationVariationsDatabase(location, unique_tuple[1]), [unique_tuple[2]]; remove_constants=false, short_names=short_names)
        temp_df[!,:folder_name] .= unique_tuple[1]
        append!(var_df, temp_df, cols=:union)
    end
    folder_pair = ("$(location)_folder" |> Symbol) => :folder_name
    id_pair = (locationVariationIDName(location) |> Symbol) => short_var_name
    return outerjoin(df, var_df, on = [folder_pair, id_pair])
end

"""
    simulationsTableFromQuery(query::String; remove_constants::Bool=true, sort_by=String[], sort_ignore=String[], short_names::Bool=true, post_processing::Bool=false)

Return a DataFrame for the given SQL query on the simulations table.

By default, constant columns and raw ID columns are removed.

# Arguments
- `query::String`: The SQL query to execute.

# Keyword Arguments
- `remove_constants::Bool`: If true, removes columns that have the same value for all simulations. Defaults to true.
- `sort_by::Vector{String}`: A vector of column names to sort the table by. When empty (the default), sorts by every parameter column in table order (i.e. the first parameter column is the primary key), excluding `:SimID` and the variation-ID columns. `:SimID` is *not* sorted by default but may be requested explicitly here. To populate this argument, it is recommended to first print the table to see the column names.
- `sort_ignore::Vector{String}`: Additional column names to exclude from sorting, on top of the always-excluded variation-ID columns. Defaults to none.
- `short_names::Bool`: If true (default), column names are shortened via `shortVariationName`. Pass `false` to keep raw XML-path column names (e.g. for matching against `parameters.toml` `db_column` entries).
- `post_processing::Bool`: If true, left-joins each simulation's stored post-processing quantities (see [`postProcessingTable`](@ref)) onto the table by `:SimID`, appending one column per quantity (`missing` where a quantity was not computed). Defaults to false. Post-processing columns are appended as-is and are not subject to `remove_constants` or sorting.
"""
function simulationsTableFromQuery(query::String;
                                   remove_constants::Bool=true,
                                   sort_by=String[],
                                   sort_ignore=String[],
                                   short_names::Bool=true,
                                   post_processing::Bool=false)
    df = _variationsTableFromQuery(query, :simulation_id, :SimID;
                                   remove_constants=remove_constants, sort_by=sort_by,
                                   sort_ignore=sort_ignore, short_names=short_names)
    post_processing && _appendPostProcessing!(df)
    return df
end

"""
    monadsTableFromQuery(query::String; remove_constants::Bool=true, sort_by=String[], sort_ignore=String[], short_names::Bool=true)

Return a DataFrame for the given SQL query on the `monads` table. This is the monad-level
analogue of [`simulationsTableFromQuery`](@ref): one row per monad and its varied parameters.

Keyword arguments match [`simulationsTableFromQuery`](@ref), except the display ID column
excluded from the default sort is `:MonadID` (rather than `:SimID`).
"""
function monadsTableFromQuery(query::String;
                              remove_constants::Bool=true,
                              sort_by=String[],
                              sort_ignore=String[],
                              short_names::Bool=true)
    return _variationsTableFromQuery(query, :monad_id, :MonadID;
                                     remove_constants=remove_constants, sort_by=sort_by,
                                     sort_ignore=sort_ignore, short_names=short_names)
end

"""
    _asSymbolVector(x) -> Vector{Symbol}

Coerce a column argument (e.g. `sort_by`, `sort_ignore`) — a single `Symbol`/`String`, or a
collection thereof — to a `Vector{Symbol}`.
"""
_asSymbolVector(x::AbstractVector) = Symbol.(x)
_asSymbolVector(x::Tuple)          = collect(Symbol.(x))
_asSymbolVector(x::Symbol)         = [x]
_asSymbolVector(x::AbstractString) = [Symbol(x)]

"""
    _variationsTableFromQuery(query::String, id_column::Symbol, display_id_column::Symbol; kwargs...)

Shared implementation behind [`simulationsTableFromQuery`](@ref) and
[`monadsTableFromQuery`](@ref). Runs `query`, keeps only `id_column` from the raw ID columns
(renaming it to `display_id_column`), joins on folder-name and varied-parameter columns, then
optionally drops constant columns and sorts.

Both the `simulations` and `monads` tables carry the same input-ID and variation-ID columns,
so the join logic ([`addFolderNameColumns!`](@ref) / [`appendVariations`](@ref)) is identical;
only the primary key column differs.
"""
function _variationsTableFromQuery(query::String, id_column::Symbol, display_id_column::Symbol;
                                   remove_constants::Bool=true,
                                   sort_by=String[],
                                   sort_ignore,
                                   short_names::Bool=true)
    sort_by     = _asSymbolVector(sort_by)
    sort_ignore = _asSymbolVector(sort_ignore)

    df = queryToDataFrame(query)
    id_col_names_to_remove = names(df)

    filter!(n -> n != string(id_column), id_col_names_to_remove)
    addFolderNameColumns!(df)

    for loc in projectLocations().varied
        df = appendVariations(loc, df; short_names=short_names)
    end

    select!(df, Not(id_col_names_to_remove))
    rename!(df, id_column => display_id_column)

    #! validate against the full column set, before `remove_constants` prunes anything: a `sort_by`
    #! entry not found here names no column at all (likely a typo) and is a hard error.
    col_names = names(df) .|> Symbol
    unknown = setdiff(sort_by, col_names)
    isempty(unknown) || throw(ArgumentError("`sort_by` names column(s) that do not exist: " *
        "$(join(unknown, ", ")). Valid columns are: $(join(col_names, ", "))."))

    if remove_constants && size(df, 1) > 1
        col_names = filter(n -> length(unique(df[!, n])) > 1, col_names)
        select!(df, col_names)
    end

    #! variation-ID columns are never a valid sort key — forced, regardless of user `sort_ignore`.
    #! (a user who really wants to sort by them can do so on the returned DataFrame.)
    never_sort = [shortLocationVariationID.(projectLocations().varied); sort_ignore]
    setdiff!(sort_by, never_sort)

    #! a requested column that survived validation but is gone from the final table was dropped by
    #! `remove_constants` — warn rather than silently ignoring it, then drop it from the sort.
    dropped = setdiff(sort_by, col_names)
    isempty(dropped) || @warn "`sort_by` column(s) were removed from the table before sorting and " *
        "will not affect ordering (likely constant columns removed by `remove_constants=true`): $(join(dropped, ", "))."
    setdiff!(sort_by, dropped)

    #! default: sort by every parameter column (in table order), excluding the display ID column
    isempty(sort_by) && (sort_by = setdiff(col_names, [display_id_column; never_sort]))
    sort!(df, sort_by)
    return df
end

"""
    simulationsTable(args...; kwargs...)

Return a DataFrame with simulation data. See [`simulationsTableFromQuery`](@ref) for keyword arguments.

`args...` can be:
- Any `AbstractTrial` objects (or arrays thereof)
- A vector of simulation IDs
- Omitted (returns data for all simulations)

Pass `post_processing=true` to append each simulation's stored post-processing quantities
(see [`postProcessingTable`](@ref)) as extra columns:

```julia
simulationsTable(sampling; post_processing=true)
```
"""
function simulationsTable(T::AbstractArray{<:AbstractTrial}; kwargs...)
    query = constructSelectQuery("simulations", "WHERE simulation_id IN ($(join(simulationIDs(T),",")));")
    return simulationsTableFromQuery(query; kwargs...)
end

simulationsTable(T::AbstractTrial, Ts::Vararg{AbstractTrial}; kwargs...) = simulationsTable([T; Ts...]; kwargs...)

function simulationsTable(simulation_ids::AbstractVector{<:Integer}; kwargs...)
    assertInitialized()
    query = constructSelectQuery("simulations", "WHERE simulation_id IN ($(join(simulation_ids,",")));")
    return simulationsTableFromQuery(query; kwargs...)
end

function simulationsTable(; kwargs...)
    assertInitialized()
    query = constructSelectQuery("simulations")
    return simulationsTableFromQuery(query; kwargs...)
end

"""
    printSimulationsTable(args...; sink=println, kwargs...)

Print a table of simulations and their varied values. See [`simulationsTable`](@ref).

# Keyword Arguments
- `sink`: A function to receive the DataFrame (default `println`). Can also use `CSV.write`.

# Examples
```julia
printSimulationsTable([simulation_1, monad_3, sampling_2, trial_1])
```
```julia
sim_ids = [1, 2, 3]
printSimulationsTable(sim_ids; remove_constants=false)
```
```julia
using CSV
printSimulationsTable(; sink=CSV.write("temp.csv"))
```
"""
function printSimulationsTable(args...; sink=println, kwargs...)
    assertInitialized()
    simulationsTable(args...; kwargs...) |> sink
end

"""
    monadsTable(args...; kwargs...)

Return a DataFrame with one row per monad and its varied parameters — the monad-level
analogue of [`simulationsTable`](@ref). See [`monadsTableFromQuery`](@ref) for keyword arguments.

`args...` can be:
- Any `AbstractTrial` objects (or arrays thereof) — the monads they contain are collected
  via [`monadIDs`](@ref).
- A vector of monad IDs.
- Omitted (returns data for all monads).

# Examples
```julia
monadsTable(sampling)
```
```julia
monad_ids = [1, 2, 3]
monadsTable(monad_ids; remove_constants=false)
```
"""
function monadsTable(T::AbstractArray{<:AbstractTrial}; kwargs...)
    query = constructSelectQuery("monads", "WHERE monad_id IN ($(join(monadIDs(T),",")));")
    return monadsTableFromQuery(query; kwargs...)
end

monadsTable(T::AbstractTrial, Ts::Vararg{AbstractTrial}; kwargs...) = monadsTable([T; Ts...]; kwargs...)

function monadsTable(monad_ids::AbstractVector{<:Integer}; kwargs...)
    assertInitialized()
    query = constructSelectQuery("monads", "WHERE monad_id IN ($(join(monad_ids,",")));")
    return monadsTableFromQuery(query; kwargs...)
end

function monadsTable(; kwargs...)
    assertInitialized()
    query = constructSelectQuery("monads")
    return monadsTableFromQuery(query; kwargs...)
end

"""
    printMonadsTable(args...; sink=println, kwargs...)

Print a table of monads and their varied values. See [`monadsTable`](@ref).

# Keyword Arguments
- `sink`: A function to receive the DataFrame (default `println`). Can also use `CSV.write`.

# Examples
```julia
printMonadsTable([monad_3, sampling_2, trial_1])
```
```julia
using CSV
printMonadsTable(; sink=CSV.write("temp.csv"))
```
"""
function printMonadsTable(args...; sink=println, kwargs...)
    assertInitialized()
    monadsTable(args...; kwargs...) |> sink
end

############## Post-processing sink ##############

const _POST_PROCESSING_TABLE = "post_processing"

"""
    postProcessingDBPath()

Return the path to the project's post-processing sink database
(`<data_dir>/outputs/postprocessing.db`). The file is created lazily the first time a
`post_processor` (see [`run`](@ref)) returns quantities of interest to store.
"""
postProcessingDBPath() = joinpath(dataDir(), "outputs", "postprocessing.db")

"""
    _openPostProcessingDB()

Open (creating if necessary) the post-processing sink database and ensure the
`post_processing` table exists with `simulation_id` as its primary key. Additional
columns are added on demand by [`_writePostProcessingRow`](@ref).
"""
function _openPostProcessingDB()
    assertInitialized()
    path = postProcessingDBPath()
    mkpath(dirname(path))
    db = SQLite.DB(path)
    DBInterface.execute(db, "CREATE TABLE IF NOT EXISTS $(_POST_PROCESSING_TABLE) (simulation_id INTEGER PRIMARY KEY);")
    return db
end

"""
    _postProcessingColumnSpec(name, value) -> (sqlite_type, db_value)

Map a single quantity-of-interest `value` to its SQLite column type and stored value.
Only scalar `Bool`, `Integer`, `Real`, and `AbstractString` values are supported; anything
else throws an `ArgumentError` (richer outputs should be written to the simulation's output
folder by the `post_processor` itself).
"""
function _postProcessingColumnSpec(name, value)
    if value isa Bool
        return "INTEGER", Int(value)
    elseif value isa Integer
        return "INTEGER", value
    elseif value isa Real
        return "REAL", float(value)
    elseif value isa AbstractString
        return "TEXT", String(value)
    end
    throw(ArgumentError("post_processor returned an unsupported value for `$(name)`: a $(typeof(value)). " *
        "Post-processing sink values must be a scalar Real, Bool, or String. " *
        "For richer per-simulation outputs, write a file to the simulation's output folder instead."))
end

"""
    _normalizePostProcessingQoI(qoi) -> Vector{Tuple{String,String,Any}}

Normalize a `post_processor` return value into `(column_name, sqlite_type, db_value)` tuples.
Accepts a `NamedTuple` or an `AbstractDict` of `name => scalar`; throws an `ArgumentError`
for any other type.
"""
function _normalizePostProcessingQoI(qoi)
    named_pairs = if qoi isa NamedTuple
        [String(k) => v for (k, v) in pairs(qoi)]
    elseif qoi isa AbstractDict
        [string(k) => v for (k, v) in qoi]
    else
        throw(ArgumentError("post_processor must return `nothing`, a NamedTuple, or an AbstractDict " *
            "of name => scalar; got a $(typeof(qoi))."))
    end
    col_names = first.(named_pairs)
    if !allunique(col_names)
        dups = unique(name for name in col_names if count(==(name), col_names) > 1)
        throw(ArgumentError("post_processor produced duplicate quantity name(s) after conversion to " *
            "strings: $(join(dups, ", ")). Distinct keys that map to the same column name " *
            "(e.g. `1` and \"1\") are not allowed."))
    end
    return [(name, _postProcessingColumnSpec(name, value)...) for (name, value) in named_pairs]
end

"""
    _qIdent(name::AbstractString) -> String

Return `name` as a safely-quoted SQLite identifier: wrapped in double quotes with any interior
double quotes doubled. Used for the user-controlled quantity-of-interest column names in the
post-processing sink so a name containing a `"` cannot break or inject into the SQL.
"""
_qIdent(name::AbstractString) = "\"" * replace(String(name), "\"" => "\"\"") * "\""

"""
    _writePostProcessingRow(db::SQLite.DB, simulation_id::Integer, qoi)

Upsert one row of quantities of interest for `simulation_id` into the post-processing sink.
New quantities become new columns (typed via [`_postProcessingColumnSpec`](@ref)); an
existing row for the same `simulation_id` is overwritten. Called only from the serial
completion loop in [`run`](@ref), never from a worker task.
"""
function _writePostProcessingRow(db::SQLite.DB, simulation_id::Integer, qoi)
    specs = _normalizePostProcessingQoI(qoi)
    isempty(specs) && return nothing

    existing = tableColumns(_POST_PROCESSING_TABLE; db=db)
    for (name, sqlite_type, _) in specs
        if !(name in existing)
            DBInterface.execute(db, "ALTER TABLE $(_POST_PROCESSING_TABLE) ADD COLUMN $(_qIdent(name)) $(sqlite_type);")
            push!(existing, name)
        end
    end

    col_names = [s[1] for s in specs]
    all_cols = ["simulation_id"; col_names]
    cols_sql = join(_qIdent.(all_cols), ", ")
    placeholders = join(fill("?", length(all_cols)), ", ")
    update_sql = join(["$(_qIdent(c))=excluded.$(_qIdent(c))" for c in col_names], ", ")
    stmt = "INSERT INTO $(_POST_PROCESSING_TABLE) ($(cols_sql)) VALUES ($(placeholders)) " *
           "ON CONFLICT(simulation_id) DO UPDATE SET $(update_sql);"
    DBInterface.execute(db, stmt, Tuple(Any[simulation_id; [s[3] for s in specs]]))
    return nothing
end

"""
    _deletePostProcessingRows(simulation_ids::AbstractVector{<:Integer})

Remove sink rows for the given `simulation_ids` from the post-processing database, keeping it
consistent with deletions from the central database. A no-op if no sink database exists yet.
Called by [`deleteSimulations`](@ref) — the single choke point through which every cascading
deletion removes simulations.
"""
function _deletePostProcessingRows(simulation_ids::AbstractVector{<:Integer})
    isempty(simulation_ids) && return nothing
    path = postProcessingDBPath()
    isfile(path) || return nothing
    db = SQLite.DB(path)
    try
        tableExists(_POST_PROCESSING_TABLE; db=db) || return nothing
        DBInterface.execute(db, "DELETE FROM $(_POST_PROCESSING_TABLE) WHERE simulation_id IN ($(join(simulation_ids, ",")));")
    finally
        close(db)
    end
    return nothing
end

"""
    _readPostProcessingTable(query::String) -> DataFrame

Run `query` against the post-processing sink and return the result with `simulation_id`
renamed to `:SimID`. Returns an empty `DataFrame` (with a `:SimID` column) if no sink
database exists yet.
"""
function _readPostProcessingTable(query::String)
    assertInitialized()
    path = postProcessingDBPath()
    isfile(path) || return DataFrame(SimID=Int[])
    db = SQLite.DB(path)
    df = try
        queryToDataFrame(query; db=db)
    finally
        close(db)
    end
    "simulation_id" in names(df) && rename!(df, :simulation_id => :SimID)
    return df
end

"""
    postProcessingTable(args...)

Return a `DataFrame` of stored post-processing quantities of interest, one row per
simulation (keyed by `:SimID`). See [`run`](@ref)'s `post_processor` keyword for how rows
are produced. The result is joinable to [`simulationsTable`](@ref) on `:SimID`.

`args...` can be:
- Any `AbstractTrial` objects (or arrays thereof) — their simulations are collected via
  [`simulationIDs`](@ref).
- A vector of simulation IDs.
- Omitted (returns data for all simulations that have stored quantities).

Simulations without stored quantities are absent from the table; quantities not computed for
a given simulation appear as `missing`. Returns an empty table if no post-processing has run.

# Examples
```julia
out = run(sampling; post_processor = sp -> (; final_count = countCells(simulationID(sp))))
postProcessingTable(sampling)
```
"""
function postProcessingTable(T::AbstractArray{<:AbstractTrial})
    return _readPostProcessingTable(constructSelectQuery(_POST_PROCESSING_TABLE, "WHERE simulation_id IN ($(join(simulationIDs(T),",")));"))
end

postProcessingTable(T::AbstractTrial, Ts::Vararg{AbstractTrial}) = postProcessingTable([T; Ts...])

function postProcessingTable(simulation_ids::AbstractVector{<:Integer})
    return _readPostProcessingTable(constructSelectQuery(_POST_PROCESSING_TABLE, "WHERE simulation_id IN ($(join(simulation_ids,",")));"))
end

postProcessingTable() = _readPostProcessingTable(constructSelectQuery(_POST_PROCESSING_TABLE))

"""
    _appendPostProcessing!(df::DataFrame)

Append each simulation's stored post-processing quantities to `df` (which must have a `:SimID`
column), preserving `df`'s row order. Adds one column per quantity, with `missing` where a
simulation has no stored value. A no-op if `df` has no `:SimID` column or the sink is empty.
Backs the `post_processing=true` keyword of [`simulationsTable`](@ref).
"""
function _appendPostProcessing!(df::DataFrame)
    "SimID" in names(df) || return df
    sim_ids = Vector{Int}(df.SimID)   # SQLite columns come back as Union{Missing,Int}
    isempty(sim_ids) && return df
    pp = postProcessingTable(sim_ids)
    for col in names(pp)
        col == "SimID" && continue
        lookup = Dict(pp.SimID .=> pp[!, col])
        df[!, col] = [get(lookup, sid, missing) for sid in sim_ids]
    end
    return df
end

"""
    printPostProcessingTable(args...; sink=println)

Print the post-processing quantities-of-interest table. See [`postProcessingTable`](@ref).

# Keyword Arguments
- `sink`: A function to receive the DataFrame (default `println`). Can also use `CSV.write`.
"""
function printPostProcessingTable(args...; sink=println)
    assertInitialized()
    postProcessingTable(args...) |> sink
end

"""
    addFolderNameColumns!(df::DataFrame)

Append `<location>_folder` columns to `df` by looking up folder names.
"""
function addFolderNameColumns!(df::DataFrame)
    for (location, location_dict) in pairs(inputsDict())
        if !(locationIDName(location) in names(df))
            continue
        end
        unique_ids = unique(df[!, locationIDName(location)])
        folder_names_dict = [id => inputFolderName(location, id) for id in unique_ids] |> Dict{Int,String}
        if location_dict["required"]
            @assert !any(folder_names_dict |> values .|> isempty) "Some $(location) folders are empty/missing, but they are required."
        end
        df[!, "$(location)_folder"] .= [folder_names_dict[id] for id in df[!, locationIDName(location)]]
    end
    return df
end
