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

#! Backward-compatible alias used by PCMM and legacy code.
const createPCMMTable = createMMTable

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
    databaseDiagnostics()

Check consistency between the database and the output folders.
Prints warnings for any discrepancies found.
"""
function databaseDiagnostics()
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
        db_ids[T] = Set(df[!, 1])

        path_to_output_folder = joinpath(dataDir(), "outputs", "$(lowerClassString(T))s")
        if isdir(path_to_output_folder)
            folders = readdir(joinpath(dataDir(), "outputs", "$(lowerClassString(T))s"))
        else
            folders = String[]
        end

        folder_ids_found = tryparse.(Int, folders)
        filter!(!isnothing, folder_ids_found)
        folder_ids[T] = Set(folder_ids_found)

        missing_dirs[T] = setdiff(db_ids[T], folder_ids[T])
        missing_db_entries[T] = setdiff(folder_ids[T], db_ids[T])
        consensus_ids[T] = intersect(db_ids[T], folder_ids[T])
    end

    warning_msg_dirs = ""
    for (T, missing_ids) in pairs(missing_dirs)
        if !isempty(missing_ids)
            warning_msg_dirs *= "- $(lowerClassString(T))s with IDs: $(sort(collect(missing_ids)))\n"
        end
    end
    if !isempty(warning_msg_dirs)
        warning_msg_dirs = "The following have entries in the database but not a corresponding folder. This can happen if the object is created, but never run.\n" * warning_msg_dirs
        @warn warning_msg_dirs
    end

    warning_msg_dbs = ""
    for (T, missing_ids) in pairs(missing_db_entries)
        if !isempty(missing_ids)
            warning_msg_dbs *= "- $(lowerClassString(T))s with IDs: $(sort(collect(missing_ids)))\n"
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
        msg *= "- $(lowerClassString(T))s reference non-existent $(lowerClassString(constituentType(T))) IDs: $(sort(collect(missing_ids)))\n"
    end
    if !isempty(msg)
        msg = "The following constituents are expected but not found:\n" * msg
        @error msg
    end

    #! check simulation status of all simulations; warn on concerning codes, info on Failed
    query = constructSelectQuery("simulations"; selection="simulation_id, status_code_id")
    df = queryToDataFrame(query)
    status_codes = recognizedStatusCodes()

    codes_with_issues = String[]
    for status_code in status_codes
        if status_code ∈ ("Completed", "Failed")
            continue
        end
        status_code_id = statusCodeID(status_code)
        concerning_ids = df[df.status_code_id .== status_code_id, :simulation_id]
        if !isempty(concerning_ids)
            @warn "Found $(length(concerning_ids)) simulations in the database with status code '$(status_code)' (ID: $(status_code_id)): $(sort(collect(concerning_ids)))."
            push!(codes_with_issues, status_code)
        end
    end

    failed_status_code_id = statusCodeID("Failed")
    failed_ids = df[df.status_code_id .== failed_status_code_id, :simulation_id]
    if !isempty(failed_ids)
        @info "Found $(length(failed_ids)) simulations in the database with status code 'Failed' (ID: $(failed_status_code_id)): $(sort(collect(failed_ids)))."
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
