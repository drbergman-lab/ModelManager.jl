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
    CSV.write(path_to_csv, Tables.table(compressIDs(ids)); header=false)
end

recordConstituentIDs(T::AbstractTrial, ids::Array{Int}) = recordConstituentIDs(typeof(T), T.id, ids)

################## Compression Functions ##################

"""
    compressIDs(ids) → Vector{String}

Compress a collection of IDs into a compact run-length representation.

Consecutive ranges are stored as `"first:last"`; isolated IDs as plain integer
strings.  The result is a `Vector{String}` — callers decide what to do with it:

- **Write to CSV:** `CSV.write(path, Tables.table(compressIDs(ids)); header=false)`
- **Display in a message:** `join(compressIDs(ids), ", ")`

This format is read back by [`constituentIDs`](@ref).

# Examples
```julia
compressIDs([1, 2, 3, 5, 7, 8])  # → ["1:3", "5", "7:8"]
compressIDs([4])                   # → ["4"]
compressIDs(Int[])                 # → String[]
```
"""
function compressIDs(ids::AbstractArray{<:Integer})
    ids = ids |> vec |> unique |> sort
    lines = String[]
    while !isempty(ids)
        if length(ids) == 1
            push!(lines, string(ids[1]))
            popfirst!(ids)
        else
            I = findfirst(diff(ids) .!= 1)
            I = isnothing(I) ? length(ids) : I
            if I > 1
                push!(lines, "$(ids[1]):$(ids[I])")
                ids = ids[I+1:end]
            else
                push!(lines, string(ids[1]))
                popfirst!(ids)
            end
        end
    end
    return lines
end

compressIDs(ids::AbstractSet{<:Integer}) = compressIDs(collect(ids))

"""
    _compressedIDStr(ids) → String

Format a collection of IDs as a compact human-readable string for log messages
and warnings.  Consecutive ranges appear as `"first-last"`; isolated IDs as plain
integers; entries are comma-separated.

# Examples
```julia
_compressedIDStr([1, 2, 3, 5, 7, 8])  # → "1-3, 5, 7-8"
```
"""
_compressedIDStr(ids) = replace(join(compressIDs(ids), ", "), ":" => "-")