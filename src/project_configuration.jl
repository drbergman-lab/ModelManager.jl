using TOML

export ProjectLocations

"""
    ProjectLocations

A struct that contains information about the locations of input files in the project.

Created by reading the `inputs.toml` file in the data directory via
[`parseProjectInputsConfigurationFile`](@ref).

# Fields
- `all::NTuple{L,Symbol}`: All registered location names (alphabetically sorted).
- `required::NTuple{M,Symbol}`: Locations whose input folder is mandatory.
- `varied::NTuple{N,Symbol}`: Locations that support parameter variations.
"""
struct ProjectLocations{L,M,N}
    all::NTuple{L,Symbol}
    required::NTuple{M,Symbol}
    varied::NTuple{N,Symbol}

    function ProjectLocations(d::Dict{Symbol,Any})
        all_locations = (location for location in keys(d)) |> collect |> sort |> Tuple
        required = (location for (location, location_dict) in pairs(d) if location_dict["required"]) |> collect |> sort |> Tuple
        varied_locations = (location for (location, location_dict) in pairs(d) if any(location_dict["varied"])) |> collect |> sort |> Tuple
        return new{length(all_locations),length(required),length(varied_locations)}(all_locations, required, varied_locations)
    end
end

"""
    sanitizePathElement(path_element::String)

Validate and return `path_element`, raising an `ArgumentError` for unsafe values.

Disallows `".."`, absolute paths, and characters in `~*?<>|:`.
"""
function sanitizePathElement(path_element::String)
    if path_element == ".."
        throw(ArgumentError("Path element '..' is not allowed"))
    end
    if isabspath(path_element)
        throw(ArgumentError("Absolute paths are not allowed"))
    end
    if contains(path_element, r"[~*?<>|:]")
        throw(ArgumentError("Path element contains invalid characters"))
    end
    return path_element
end

"""
    parseProjectInputsConfigurationFile()

Parse `inputs.toml` and update [`mm_globals`](@ref) with the resulting
[`ProjectLocations`](@ref) and `inputs_dict`.

Returns `true` on success, `false` if the file is missing or malformed.
"""
function parseProjectInputsConfigurationFile()
    inputs_dict_temp = Dict{String,Any}()
    try
        inputs_dict_temp = pathToInputsConfig() |> TOML.parsefile
    catch e
        println("Error parsing project configuration file: ", e)
        return false
    end
    for (location, location_dict) in pairs(inputs_dict_temp)
        @assert haskey(location_dict, "required") "inputs.toml: $(location): required must be defined."
        @assert haskey(location_dict, "varied") "inputs.toml: $(location): varied must be defined."
        if !("path_from_inputs" in keys(location_dict))
            location_dict["path_from_inputs"] = locationFolder(location)
        else
            location_dict["path_from_inputs"] = location_dict["path_from_inputs"] .|> sanitizePathElement |> joinpath
        end
        if !("basename" in keys(location_dict))
            @assert location_dict["varied"] isa Bool && (!location_dict["varied"]) "inputs.toml: $(location): basename must be defined if varied is true."
            location_dict["basename"] = missing
        elseif location_dict["varied"] isa Vector
            @assert location_dict["basename"] isa Vector && length(location_dict["varied"]) == length(location_dict["basename"]) "inputs.toml: $(location): varied must be a Bool or a Vector of the same length as basename."
        end
    end
    mm_globals().inputs_dict = [Symbol(location) => location_dict for (location, location_dict) in pairs(inputs_dict_temp)] |> Dict{Symbol,Any}
    mm_globals().project_locations = ProjectLocations(mm_globals().inputs_dict)
    return true
end

"""
    locationIDName(location)

Return the ID column name for `location` (e.g. `"config_id"`).
"""
locationIDName(location::Union{String,Symbol}) = tableIDName(String(location); strip_s=false)

"""
    locationVariationIDName(location)

Return the variation ID column name for `location` (e.g. `"config_variation_id"`).
"""
locationVariationIDName(location::Union{String,Symbol}) = "$(location)_variation_id"

"""
    locationIDNames()

Return an iterator over the ID column names for all locations.
"""
locationIDNames() = (locationIDName(loc) for loc in projectLocations().all)

"""
    locationVariationIDNames()

Return an iterator over the variation ID column names for all varied locations.
"""
locationVariationIDNames() = (locationVariationIDName(loc) for loc in projectLocations().varied)

"""
    locationTableName(location)

Return the database table name for `location` (e.g. `"configs"`).
"""
locationTableName(location::Union{String,Symbol}) = "$(location)s"

"""
    locationFolder(location::Union{String,Symbol})

Return the name of the folder for `location` within `data/inputs/`.
Defaults to [`locationTableName`](@ref).
"""
locationFolder(location::Union{String,Symbol}) = locationTableName(location)

"""
    locationVariationsTableName(location)

Return the name of the variations table for `location` (e.g. `"config_variations"`).
"""
locationVariationsTableName(location::Union{String,Symbol}) = "$(location)_variations"

"""
    locationVariationsFolder(location)

Return the name of the variations folder for `location`.
"""
locationVariationsFolder(location::Union{String,Symbol}) = locationVariationsTableName(location)

"""
    locationVariationsDBName(location::Union{String,Symbol})

Return the filename of the per-folder variations SQLite database for `location`.
"""
locationVariationsDBName(location::Union{String,Symbol}) = "$(locationVariationsTableName(location)).db"

"""
    locationPath(location::Symbol[, folder])

Return the path to `location`'s input directory.  If `folder` is given, join it.
"""
function locationPath(location::Symbol, folder=missing)
    location_dict = inputsDict()[Symbol(location)]
    path_to_locations = joinpath(dataDir(), "inputs", location_dict["path_from_inputs"])
    return ismissing(folder) ? path_to_locations : joinpath(path_to_locations, folder)
end

# locationPath(InputFolder) and locationPath(Symbol, AbstractSampling) are defined in classes.jl
# after those types are available.

"""
    folderIsVaried(location::Symbol, folder::String)

Return `true` if `folder` in `location` can have parameter variations applied.
"""
function folderIsVaried(location::Symbol, folder::String)
    location_dict = inputsDict()[location]
    varieds = location_dict["varied"]
    if !any(varieds)
        return false
    end
    basenames = location_dict["basename"]
    basenames = basenames isa Vector ? basenames : [basenames]
    @assert varieds isa Bool || length(varieds) == length(basenames) "varied must be a Bool or a Vector of the same length as basename"
    varieds = varieds isa Vector ? varieds : fill(varieds, length(basenames))

    path_to_folder = locationPath(location, folder)
    for (basename, varied) in zip(basenames, varieds)
        path_to_file = joinpath(path_to_folder, basename)
        if isfile(path_to_file)
            return varied
        end
    end
    throw(ErrorException("No basename files found in folder $(path_to_folder). Must be one of $(basenames)"))
end

"""
    pathToInputsConfig()

Return the path to `inputs.toml`.
"""
pathToInputsConfig() = joinpath(dataDir(), "inputs", "inputs.toml")
