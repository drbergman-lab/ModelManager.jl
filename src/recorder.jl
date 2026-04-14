"""
    recordConstituentIDs(T::Type{<:AbstractTrial}, id::Int, ids::Array{Int})
    recordConstituentIDs(T::AbstractTrial, ids::Array{Int})

Write the constituent IDs of an [`AbstractTrial`](@ref) to a CSV file inside its
output folder.  The file is named after the constituent type (e.g. `simulations.csv`
inside a monad folder).
"""
function recordConstituentIDs(T::Type{<:AbstractTrial}, id::Int, ids::Array{Int})
    path_to_folder = trialFolder(T, id)
    mkpath(path_to_folder)
    path_to_csv = joinpath(path_to_folder, constituentTypeFilename(T))
    lines_table = compressIDs(ids)
    CSV.write(path_to_csv, lines_table; header=false)
end

recordConstituentIDs(T::AbstractTrial, ids::Array{Int}) = recordConstituentIDs(typeof(T), T.id, ids)

################## Compression Functions ##################

"""
    compressIDs(ids::AbstractArray{Int})

Compress a sorted list of IDs into a compact run-length representation.

Consecutive ranges are stored as `"first:last"` strings; isolated IDs are stored
as plain integers.  This mirrors the on-disk format written by
[`recordConstituentIDs`](@ref).

# Examples
```julia
compressIDs([1, 2, 3, 5, 7, 8]) # → Tables.table(["1:3", "5", "7:8"])
```
"""
function compressIDs(ids::AbstractArray{Int})
    ids = ids |> vec |> unique |> sort
    lines = String[]
    while !isempty(ids)
        if length(ids) == 1
            next_line = string(ids[1])
            popfirst!(ids)
        else
            I = findfirst(diff(ids) .!= 1)
            I = isnothing(I) ? length(ids) : I
            if I > 1
                next_line = "$(ids[1]):$(ids[I])"
                ids = ids[I+1:end]
            else
                next_line = string(ids[1])
                popfirst!(ids)
            end
        end
        push!(lines, next_line)
    end
    return Tables.table(lines)
end
