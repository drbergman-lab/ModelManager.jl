using SQLite, DataFrames

"""
    queryToDataFrame(query::String; db::SQLite.DB, is_row::Bool=false)

Execute `query` against `db` and return the result as a `DataFrame`.

If `is_row` is `true`, asserts that exactly one row was returned.
"""
function queryToDataFrame(query::String; db::SQLite.DB, is_row::Bool=false)
    df = DBInterface.execute(db, query) |> DataFrame
    if is_row
        @assert size(df, 1) == 1 """
        Did not find exactly one row matching the query:
        \tDatabase file: $(db)
        \tQuery: $(query)
        Result: $(df)"""
    end
    return df
end

"""
    tableExists(table_name::String; db::SQLite.DB)

Return `true` if a table named `table_name` exists in `db`.
"""
function tableExists(table_name::String; db::SQLite.DB)
    names = DBInterface.execute(db, "SELECT name FROM sqlite_master WHERE type='table';") |> DataFrame |> x -> x.name
    return table_name in names
end

"""
    tableColumns(table_name::String; db::SQLite.DB)

Return the column names of `table_name` in `db`.
"""
function tableColumns(table_name::String; db::SQLite.DB)
    @assert tableExists(table_name; db=db) "Table $(table_name) does not exist in the database."
    return queryToDataFrame("PRAGMA table_info($(table_name));"; db=db) |> x -> x.name
end

"""
    columnsExist(column_names, table_name::String; db::SQLite.DB)
    columnsExist(column_names, valid_column_names)

Return `true` if every name in `column_names` is a column in `table_name` (or in
the pre-fetched `valid_column_names` vector).
"""
function columnsExist(column_names::AbstractVector{<:AbstractString}, table_name::String; db::SQLite.DB)
    return columnsExist(column_names, tableColumns(table_name; db=db))
end

function columnsExist(column_names::AbstractVector{<:AbstractString},
                      valid_column_names::AbstractVector{<:AbstractString})
    return all(c -> c in valid_column_names, column_names)
end
