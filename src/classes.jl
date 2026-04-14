using DataFrames, Dates

export Simulation, Monad, Sampling, Trial, InputFolders

########################################################
############   Abstract trial hierarchy   ##############
########################################################

"""
    AbstractTrial

Abstract type for the [`Simulation`](@ref), [`Monad`](@ref), [`Sampling`](@ref),
and [`Trial`](@ref) types.
"""
abstract type AbstractTrial end

"""
    AbstractSampling <: AbstractTrial

Abstract type for [`Simulation`](@ref), [`Monad`](@ref), and [`Sampling`](@ref).

All associated simulations share the same input folders; only variations differ.
"""
abstract type AbstractSampling <: AbstractTrial end

"""
    AbstractMonad <: AbstractSampling

Abstract type for [`Simulation`](@ref) and [`Monad`](@ref).

All associated simulations share both input folders and variation IDs.
"""
abstract type AbstractMonad <: AbstractSampling end

trialType(::T) where T<:AbstractTrial = T

"""
    locationPath(location::Symbol, S::AbstractSampling)

Return the full path to the input folder for `location` used by sampling `S`.
"""
locationPath(location::Symbol, S::AbstractSampling) = locationPath(location, S.inputs[location].folder)
trialID(T::AbstractTrial) = T.id

Base.length(T::AbstractTrial) = simulationIDs(T) |> length

########################################################
############   InputFolders   ##########################
########################################################

"""
    InputFolder

Hold the information for a single input folder (location + folder name + metadata).

Created automatically by [`InputFolders`](@ref) constructors.

# Fields
- `location::Symbol`: The location key (e.g. `:config`, `:custom_code`).
- `id::Int`: Database row ID for this folder.
- `folder::String`: Folder name within `data/inputs/<path_from_inputs>/`.
- `basename::Union{String,Missing}`: Primary input file name, or `missing`.
- `required::Bool`: Whether this location is required.
- `varied::Bool`: Whether this folder supports parameter variations.
- `path_from_inputs::String`: Relative path from `data/inputs/` to this folder.
"""
struct InputFolder
    location::Symbol
    id::Int
    folder::String
    basename::Union{String,Missing}
    required::Bool
    varied::Bool
    path_from_inputs::String

    function InputFolder(location::Symbol, id::Int, folder::String)
        location_dict = inputsDict()[location]
        required = location_dict["required"]
        if isempty(folder)
            if required
                error("Folder for $location must be provided")
            end
            return new(location, id, folder, missing, required, false, "")
        end
        path_from_inputs = joinpath(location_dict["path_from_inputs"], folder)
        basename = location_dict["basename"]
        varied = folderIsVaried(location, folder)
        if basename isa Vector
            possible_files = [joinpath(locationPath(location, folder), x) for x in basename]
            basename_index = possible_files .|> isfile |> findfirst
            if isnothing(basename_index)
                error("Neither of $possible_files exist")
            end
            basename = basename[basename_index]
        end
        return new(location, id, folder, basename, required, varied, path_from_inputs)
    end

    function InputFolder(location::Symbol, id::Int)
        folder = inputFolderName(location, id)
        return InputFolder(location, id, folder)
    end

    function InputFolder(location::Symbol, folder::String)
        id = inputFolderID(location, folder)
        return InputFolder(location, id, folder)
    end
end

function Base.show(io::IO, input_folder::InputFolder)
    println(io, "InputFolder:")
    println(io, "  Location: $(input_folder.location)")
    println(io, "  ID: $(input_folder.id)")
    println(io, "  Folder: $(input_folder.folder)")
    println(io, "  Basename: $(input_folder.basename)")
    println(io, "  Required: $(input_folder.required)")
    println(io, "  Varied: $(input_folder.varied)")
end

"""
    locationPath(input_folder::InputFolder)

Return the full path to the input folder described by `input_folder`.
"""
locationPath(input_folder::InputFolder) = locationPath(input_folder.location, input_folder.folder)

"""
    InputFolders

Consolidate the folder information for a simulation / monad / sampling.

# Constructors

1. All folders as keyword arguments (omitted ⟹ `""`):
```julia
InputFolders(; config="default", custom_code="default")
```
2. Required folders as positional args (alphabetical order), optional as kwargs:
```julia
InputFolders("default", "default"; ic_cell="cells_in_disc")
```

# Fields
- `input_folders::NamedTuple`: Keys are location symbols; values are [`InputFolder`](@ref)s.
"""
struct InputFolders
    input_folders::NamedTuple

    function InputFolders(location_pairs::Vector{<:Pair{Symbol,<:Union{String,Int}}})
        locs_already_here = first.(location_pairs)
        invalid_locations = setdiff(locs_already_here, projectLocations().all)
        @assert isempty(invalid_locations) "Invalid locations: $invalid_locations.\nPossible locations are: $(projectLocations().all)"
        for loc in setdiff(projectLocations().all, locs_already_here)
            push!(location_pairs, loc => "")
        end
        return new([loc => InputFolder(loc, val) for (loc, val) in location_pairs] |> NamedTuple)
    end

    function InputFolders(; kwargs...)
        return InputFolders([loc => val for (loc, val) in kwargs])
    end
end

#! Let the linter know about the positional-argument form defined below.
function InputFolders(args...; kwargs...) end

function InputFolders(req_loc_folders::Vararg{String}; opt_loc_folders...)
    assertInitialized()
    req_locs = projectLocations().required
    @assert length(req_loc_folders) == length(req_locs) "Number of required location folders provided ($(length(req_loc_folders))) does not match number of required locations ($(length(req_locs))). Required locations are: $(req_locs)."

    location_pairs = Vector{Pair{Symbol,Union{String,Int}}}()
    for (loc, folder) in zip(req_locs, req_loc_folders)
        push!(location_pairs, loc => folder)
    end
    for (loc, val) in pairs(opt_loc_folders)
        push!(location_pairs, loc => val)
    end
    return InputFolders(location_pairs)
end

Base.getindex(input_folders::InputFolders, loc::Symbol)::InputFolder = input_folders.input_folders[loc]

function Base.show(io::IO, input_folders::InputFolders)
    printInputFolders(io, input_folders)
end

"""
    printInputFolders(io::IO, input_folders::InputFolders, n_indent::Int=0)

Print the folder information for each used location in `input_folders`.
"""
function printInputFolders(io::IO, input_folders::InputFolders, n_indent::Int=0)
    println(io, "  "^n_indent, "Input Folders:")
    if_nt = input_folders.input_folders
    used_locs = [loc for loc in keys(if_nt) if !isempty(if_nt[loc].folder)]
    max_width = maximum(length(string(loc)) for loc in used_locs)
    last_used_loc = last(used_locs)
    for loc in used_locs
        input_folder = if_nt[loc]
        print(io, "  "^(n_indent + 1), "$(rpad("$loc:", max_width + 1)) $(input_folder.folder)")
        if loc != last_used_loc
            println(io)
        end
    end
end

########################################################
############   VariationID   ###########################
########################################################

"""
    VariationID

Record the variation row IDs for each varied input location.

A value of `-1` means the location is not in use; `0` means the base (unvaried)
file is being used.
"""
struct VariationID
    ids::NamedTuple

    function VariationID(inputs::InputFolders)
        return new((loc => inputs[loc].id == -1 ? -1 : 0 for loc in projectLocations().varied) |> NamedTuple)
    end

    function VariationID(x::Vector{Pair{Symbol,Int}})
        return new(x |> NamedTuple)
    end
end

Base.getindex(variation_id::VariationID, loc::Symbol)::Int = variation_id.ids[loc]

function Base.show(io::IO, variation_id::VariationID)
    printVariationID(io, variation_id)
end

function printVariationID(io::IO, variation_id::VariationID, n_indent::Int=0)
    println(io, "  "^n_indent, "Variation ID:")
    used_locs = [loc for loc in keys(variation_id.ids) if variation_id.ids[loc] != -1]
    max_width = maximum(length(string(loc)) for loc in used_locs)
    last_used_loc = last(used_locs)
    for loc in used_locs
        id = variation_id.ids[loc]
        print(io, "  "^(n_indent + 1), "$(rpad("$loc:", max_width + 1)) $id")
        if loc != last_used_loc
            println(io)
        end
    end
end

########################################################
############   Simulation   ############################
########################################################

"""
    Simulation

A single run of the model.

# Constructors
```julia
Simulation(simulation_id)          # retrieve existing
Simulation(inputs, variation_id)   # create new (inserts into DB)
Simulation(monad)                  # new sim with same params as monad
```

# Fields
- `id::Int`
- `inputs::InputFolders`
- `variation_id::VariationID`
"""
struct Simulation <: AbstractMonad
    id::Int
    inputs::InputFolders
    variation_id::VariationID

    function Simulation(id::Int, inputs::InputFolders, variation_id::VariationID)
        @assert id > 0 "Simulation id must be positive. Got $id."
        for location in projectLocations().varied
            if inputs[location].required
                @assert variation_id[location] >= 0 "$(location) variation id must be non-negative. Got $(variation_id[location])."
            elseif inputs[location].id == -1
                @assert variation_id[location] == -1 "$(location) variation id must be -1 because there is no associated folder. Got $(variation_id[location])."
            elseif !inputs[location].varied
                @assert variation_id[location] == 0 "$(inputs[location].folder) in $(location) is not varying but variation id is not 0. Got $(variation_id[location])."
            else
                @assert variation_id[location] >= 0 "$(location) variation id must be non-negative. Got $(variation_id[location])."
            end
        end
        return new(id, inputs, variation_id)
    end
end

function Simulation(inputs::InputFolders, variation_id::VariationID=VariationID(inputs))
    simulation_id = DBInterface.execute(centralDB(),
    """
    INSERT INTO simulations (\
    $(simulatorVersionIDName()),\
    $(join(locationIDNames(), ",")),\
    $(join(locationVariationIDNames(), ",")),\
    status_code_id\
    ) \
    VALUES(\
    $(currentSimulatorVersionID()),\
    $(join([inputs[loc].id for loc in projectLocations().all], ",")),\
    $(join([variation_id[loc] for loc in projectLocations().varied],",")),\
    $(statusCodeID("Not Started"))
    )
    RETURNING simulation_id;
    """
    ) |> DataFrame |> x -> x.simulation_id[1]
    return Simulation(simulation_id, inputs, variation_id)
end

function Simulation(simulation_id::Int)
    assertInitialized()
    df = constructSelectQuery("simulations", "WHERE simulation_id=$(simulation_id);") |> queryToDataFrame
    if isempty(df)
        error("Simulation $(simulation_id) not in the database.")
    end
    inputs = [loc => df[1, locationIDName(loc)] for loc in projectLocations().all] |> InputFolders
    variation_id = [loc => df[1, locationVariationIDName(loc)] for loc in projectLocations().varied] |> VariationID
    return Simulation(simulation_id, inputs, variation_id)
end

Base.length(::Simulation) = 1

function Base.show(io::IO, simulation::Simulation)
    println(io, "Simulation (ID=$(simulation.id)):")
    printInputFolders(io, simulation.inputs, 1)
    println(io)
    printVariationID(io, simulation.variation_id, 1)
end

########################################################
############   Monad   #################################
########################################################

"""
    Monad

A group of identical-up-to-randomness simulations.

# Constructors
```julia
Monad(inputs, variation_id; n_replicates=0, use_previous=true)
Monad(monad_id; n_replicates=0, use_previous=true)
Monad(simulation)
```

# Fields
- `id::Int`
- `inputs::InputFolders`
- `variation_id::VariationID`
"""
struct Monad <: AbstractMonad
    id::Int
    inputs::InputFolders
    variation_id::VariationID

    function Monad(inputs::InputFolders, variation_id::VariationID=VariationID(inputs); n_replicates::Integer=0, use_previous::Bool=true)
        feature_str = """
        (\
        $(simulatorVersionIDName()),\
        $(join(locationIDNames(), ",")),\
        $(join(locationVariationIDNames(), ","))\
        ) \
        """
        value_str = """
        (\
        $(currentSimulatorVersionID()),\
        $(join([inputs[loc].id for loc in projectLocations().all], ",")),\
        $(join([variation_id[loc] for loc in projectLocations().varied],","))\
        ) \
        """
        monad_id = DBInterface.execute(centralDB(),
            """
            INSERT OR IGNORE INTO monads $feature_str VALUES $value_str RETURNING monad_id;
            """
        ) |> DataFrame |> x -> x.monad_id
        if isempty(monad_id)
            monad_id = constructSelectQuery(
                "monads",
                """
                WHERE $feature_str=$value_str
                """;
                selection="monad_id"
            ) |> queryToDataFrame |> x -> x.monad_id[1]
        else
            monad_id = monad_id[1]
        end
        return Monad(monad_id, inputs, variation_id, n_replicates, use_previous)
    end

    function Monad(id::Int, inputs::InputFolders, variation_id::VariationID, n_replicates::Int, use_previous::Bool)
        @assert id > 0 "Monad id must be positive. Got $id."
        @assert n_replicates >= 0 "Monad n_replicates must be non-negative. Got $n_replicates."

        previous_simulation_ids = constituentIDs(Monad, id)
        new_simulation_ids = Int[]
        num_sims_to_add = n_replicates - (use_previous ? length(previous_simulation_ids) : 0)
        if num_sims_to_add > 0
            for _ = 1:num_sims_to_add
                simulation = Simulation(inputs, variation_id)
                push!(new_simulation_ids, simulation.id)
            end
            recordConstituentIDs(Monad, id, [previous_simulation_ids; new_simulation_ids])
        end
        return new(id, inputs, variation_id)
    end
end

function Monad(monad_id::Integer; n_replicates::Integer=0, use_previous::Bool=true)
    assertInitialized()
    df = constructSelectQuery("monads", "WHERE monad_id=$(monad_id);") |> queryToDataFrame
    if isempty(df)
        error("Monad $(monad_id) not in the database.")
    end
    inputs = [loc => df[1, locationIDName(loc)] for loc in projectLocations().all] |> InputFolders
    variation_id = [loc => df[1, locationVariationIDName(loc)] for loc in projectLocations().varied] |> VariationID
    return Monad(monad_id, inputs, variation_id, n_replicates, use_previous)
end

function Monad(simulation::Simulation; n_replicates::Integer=0, use_previous::Bool=true)
    monad = Monad(simulation.inputs, simulation.variation_id; n_replicates=n_replicates, use_previous=use_previous)
    addSimulationID(monad, simulation.id)
    return monad
end

function Monad(monad::Monad; n_replicates::Integer=0, use_previous::Bool=true)
    return Monad(monad.id, monad.inputs, monad.variation_id, n_replicates, use_previous)
end

"""
    addSimulationID(monad::Monad, simulation_id::Int)

Append `simulation_id` to `monad`'s constituent IDs CSV (if not already present).
"""
function addSimulationID(monad::Monad, simulation_id::Int)
    simulation_ids = simulationIDs(monad)
    if simulation_id in simulation_ids
        return
    end
    push!(simulation_ids, simulation_id)
    recordConstituentIDs(monad, simulation_ids)
end

Simulation(monad::Monad) = Simulation(monad.inputs, monad.variation_id)

function Base.show(io::IO, monad::Monad)
    println(io, "Monad (ID=$(monad.id)):")
    printInputFolders(io, monad.inputs, 1)
    println(io)
    printVariationID(io, monad.variation_id, 1)
    println(io)
    printSimulationIDs(io, monad)
end

function printSimulationIDs(io::IO, T::AbstractTrial, n_indent::Int=1)
    simulation_ids = simulationIDs(T) |> compressIDs
    simulation_ids = join(simulation_ids[1], ", ")
    simulation_ids = replace(simulation_ids, ":" => "-")
    print(io, "  "^n_indent, "Simulations: $simulation_ids")
end

########################################################
############   Sampling   ##############################
########################################################

"""
    Sampling

A group of monads sharing the same input folders but differing in parameter values.

# Fields
- `id::Int`
- `inputs::InputFolders`
- `monads::Vector{Monad}`
"""
struct Sampling <: AbstractSampling
    id::Int
    inputs::InputFolders
    monads::Vector{Monad}

    function Sampling(monads::AbstractVector{Monad}, inputs::InputFolders)
        id = -1
        sampling_ids = constructSelectQuery(
            "samplings",
            """
            WHERE (\
            $(simulatorVersionIDName()),\
            $(join(locationIDNames(), ","))\
            )=\
            (\
            $(currentSimulatorVersionID()),\
            $(join([inputs[loc].id for loc in projectLocations().all], ","))\
            );\
            """;
            selection="sampling_id"
        ) |> queryToDataFrame |> x -> x.sampling_id

        monad_ids = [monad.id for monad in monads]
        if !isempty(sampling_ids)
            for sampling_id in sampling_ids
                monad_ids_in_sampling = constituentIDs(Sampling, sampling_id)
                if symdiff(monad_ids_in_sampling, monad_ids) |> isempty
                    id = sampling_id
                    break
                end
            end
        end

        if id == -1
            id = DBInterface.execute(centralDB(),
                """
                INSERT INTO samplings \
                (\
                $(simulatorVersionIDName()),\
                $(join(locationIDNames(), ","))\
                ) \
                VALUES(\
                $(currentSimulatorVersionID()),\
                $(join([inputs[loc].id for loc in projectLocations().all], ","))\
                ) RETURNING sampling_id;
                """
            ) |> DataFrame |> x -> x.sampling_id[1]
            recordConstituentIDs(Sampling, id, monad_ids)
        end
        return Sampling(id, inputs, monads)
    end

    function Sampling(id::Int, inputs::InputFolders, monads::Vector{Monad})
        @assert id > 0 "Sampling id must be positive. Got $id."
        @assert !isempty(monads) "At least one monad must be provided"
        for monad in monads
            @assert monad.inputs == inputs "All monads must have the same inputs. Got $(monad.inputs) and $(inputs)."
        end
        @assert Set(constituentIDs(Sampling, id)) == Set([monad.id for monad in monads]) "Monad ids do not match those in the database for Sampling $(id)."
        return new(id, inputs, monads)
    end
end

function Sampling(inputs::InputFolders, variation_ids::AbstractArray{VariationID}; n_replicates::Integer=0, use_previous::Bool=true)
    monads = [Monad(inputs, variation_id; n_replicates=n_replicates, use_previous=use_previous) for variation_id in variation_ids]
    return Sampling(monads, inputs)
end

function Sampling(inputs::InputFolders,
                  location_variation_ids::Dict{Symbol,<:Union{Integer,AbstractArray{<:Integer}}};
                  n_replicates::Integer=0,
                  use_previous::Bool=true)
    if all(x -> x isa Integer, values(location_variation_ids))
        for (loc, loc_var_ids) in pairs(location_variation_ids)
            location_variation_ids[loc] = [loc_var_ids]
        end
    else
        ns = [length(x) for x in values(location_variation_ids) if !(x isa Integer)]
        @assert all(x -> x == ns[1], ns) "location variation ids must have the same length if they are not integers. Got $(ns)."
        for (loc, loc_var_ids) in pairs(location_variation_ids)
            if loc_var_ids isa Integer
                location_variation_ids[loc] = fill(loc_var_ids, ns[1])
            end
        end
    end
    n = location_variation_ids |> values |> first |> length
    for loc in setdiff(projectLocations().varied, keys(location_variation_ids))
        location_variation_ids[loc] = fill(inputs[loc].id == -1 ? -1 : 0, n)
    end
    variation_ids = [([loc => loc_var_ids[i] for (loc, loc_var_ids) in pairs(location_variation_ids)] |> VariationID) for i in 1:n]
    return Sampling(inputs, variation_ids; n_replicates=n_replicates, use_previous=use_previous)
end

function Sampling(Ms::AbstractArray{<:AbstractMonad}; n_replicates::Integer=0, use_previous::Bool=true)
    @assert !isempty(Ms) "At least one monad must be provided"
    inputs = Ms[1].inputs
    for M in Ms
        @assert M.inputs == inputs "All Ms must have the same inputs. Got $(M.inputs) and $(inputs)."
    end
    monads = [Monad(M; n_replicates=n_replicates, use_previous=use_previous) for M in Ms]
    return Sampling(monads, inputs)
end

Sampling(M::AbstractMonad; kwargs...) = Sampling([M]; kwargs...)

function Sampling(sampling_id::Int; n_replicates::Integer=0, use_previous::Bool=true)
    assertInitialized()
    df = constructSelectQuery("samplings", "WHERE sampling_id=$(sampling_id);") |> queryToDataFrame
    if isempty(df)
        error("Sampling $(sampling_id) not in the database.")
    end
    monad_ids = constituentIDs(Sampling, sampling_id)
    monads = Monad.(monad_ids; n_replicates=n_replicates, use_previous=use_previous)
    inputs = monads[1].inputs
    return Sampling(sampling_id, inputs, monads)
end

Sampling(sampling::Sampling; kwargs...) = Sampling(sampling.id; kwargs...)

function Base.show(io::IO, sampling::Sampling)
    println(io, "Sampling (ID=$(sampling.id)):")
    printInputFolders(io, sampling.inputs, 1)
    println(io)
    printMonadIDs(io, sampling)
end

function printMonadIDs(io::IO, sampling::Sampling, n_indent::Int=1)
    monad_ids = constituentIDs(sampling) |> compressIDs
    monad_ids = join(monad_ids[1], ", ")
    monad_ids = replace(monad_ids, ":" => "-")
    print(io, "  "^n_indent, "Monads: $(monad_ids)")
end

########################################################
############   Trial   #################################
########################################################

"""
    Trial

A group of samplings that may have different input folders.

# Fields
- `id::Int`
- `samplings::Vector{Sampling}`
"""
struct Trial <: AbstractTrial
    id::Int
    samplings::Vector{Sampling}

    function Trial(id::Integer, samplings::Vector{Sampling})
        @assert id > 0 "Trial id must be positive. Got $id."
        @assert Set(constituentIDs(Trial, id)) == Set([sampling.id for sampling in samplings]) "Samplings do not match the samplings in the database."
        return new(id, samplings)
    end
end

function Trial(Ss::AbstractArray{<:AbstractSampling}; n_replicates::Integer=0, use_previous::Bool=true)
    samplings = Sampling.(Ss; n_replicates=n_replicates, use_previous=use_previous)
    id = trialID(samplings)
    return Trial(id, samplings)
end

function Trial(trial_id::Int; n_replicates::Integer=0, use_previous::Bool=true)
    assertInitialized()
    df = constructSelectQuery("trials", "WHERE trial_id=$(trial_id);") |> queryToDataFrame
    @assert !isempty(df) "Trial $(trial_id) not in the database."
    samplings = Sampling.(constituentIDs(Trial, trial_id); n_replicates=n_replicates, use_previous=use_previous)
    @assert !isempty(samplings) "No samplings found for trial_id=$trial_id."
    return Trial(trial_id, samplings)
end

function trialID(samplings::Vector{Sampling})
    sampling_ids = [sampling.id for sampling in samplings]
    id = -1
    trial_ids = constructSelectQuery("trials"; selection="trial_id") |> queryToDataFrame |> x -> x.trial_id
    if !isempty(trial_ids)
        for trial_id in trial_ids
            sampling_ids_in_db = constituentIDs(Trial, trial_id)
            if symdiff(sampling_ids_in_db, sampling_ids) |> isempty
                id = trial_id
                break
            end
        end
    end

    if id == -1
        id = DBInterface.execute(centralDB(), "INSERT INTO trials (datetime) VALUES($(Dates.format(now(),"yymmddHHMM"))) RETURNING trial_id;") |> DataFrame |> x -> x.trial_id[1]
        recordConstituentIDs(Trial, id, sampling_ids)
    end
    return id
end

function Base.show(io::IO, trial::Trial)
    println(io, "Trial (ID=$(trial.id)):")
    last_sampling = last(trial.samplings)
    for sampling in trial.samplings
        println(io, "  Sampling (ID=$(sampling.id)):")
        printMonadIDs(io, sampling, 2)
        if sampling != last_sampling
            println(io)
        end
    end
end

########################################################
############   Trial hierarchy utilities   #############
########################################################

"""
    constituentType(T)

Return the type of the sub-objects of trial type `T`.
"""
constituentType(::Type{Simulation}) = throw(ArgumentError("Type Simulation does not have constituents."))
constituentType(::Type{Monad}) = Simulation
constituentType(::Type{Sampling}) = Monad
constituentType(::Type{Trial}) = Sampling
constituentType(T::AbstractTrial) = constituentType(typeof(T))

"""
    constituentTypeFilename(T)

Return the CSV filename that stores the constituent IDs for type `T`.
"""
constituentTypeFilename(T) = "$(T |> constituentType |> lowerClassString)s.csv"

"""
    constituentIDs(T::AbstractTrial)
    constituentIDs(::Type{T}, id::Int)

Read the constituent IDs for trial `T` from its CSV file.
"""
function constituentIDs(path_to_csv::String)
    if !isfile(path_to_csv)
        return Int[]
    end
    df = CSV.read(path_to_csv, DataFrame; header=false, silencewarnings=true, types=String, delim=",")
    ids = Int[]
    for i in axes(df, 1)
        s = df.Column1[i]
        I = split(s, ":") .|> x -> parse(Int, x)
        if length(I) == 1
            push!(ids, I[1])
        else
            append!(ids, I[1]:I[2])
        end
    end
    return ids
end

constituentIDs(T::AbstractTrial) = constituentIDs(joinpath(trialFolder(T), constituentTypeFilename(T)))
constituentIDs(::Type{T}, id::Int) where {T<:AbstractTrial} = constituentIDs(joinpath(trialFolder(T, id), constituentTypeFilename(T)))

function samplingSimulationIDs(sampling_id::Int)
    monad_ids = constituentIDs(Sampling, sampling_id)
    return vcat([constituentIDs(Monad, monad_id) for monad_id in monad_ids]...)
end

function trialSimulationIDs(trial_id::Int)
    sampling_ids = constituentIDs(Trial, trial_id)
    return vcat([samplingSimulationIDs(sampling_id) for sampling_id in sampling_ids]...)
end

"""
    simulationIDs()

Return all simulation IDs in the database.  Overloaded forms accept a trial,
sampling, monad, or simulation object.
"""
simulationIDs() = constructSelectQuery("simulations"; selection="simulation_id") |> queryToDataFrame |> x -> x.simulation_id
simulationIDs(simulation::Simulation) = [simulation.id]
simulationIDs(monad::Monad) = constituentIDs(monad)
simulationIDs(sampling::Sampling) = samplingSimulationIDs(sampling.id)
simulationIDs(trial::Trial) = trialSimulationIDs(trial.id)
simulationIDs(Ts::AbstractArray{<:AbstractTrial}) = reduce(vcat, simulationIDs.(Ts))

"""
    monadIDs()

Return all monad IDs in the database.  Overloaded forms accept a monad, sampling,
or trial object.
"""
monadIDs() = constructSelectQuery("monads"; selection="monad_id") |> queryToDataFrame |> x -> x.monad_id
monadIDs(monad::Monad) = [monad.id]
monadIDs(sampling::Sampling) = constituentIDs(sampling)
monadIDs(trial::Trial) = vcat([constituentIDs(Sampling, s) for s in constituentIDs(Trial, trial.id)]...)
monadIDs(Ts::AbstractArray{<:AbstractTrial}) = reduce(vcat, monadIDs.(Ts))

"""
    trialFolder(T::Type{<:AbstractTrial}, id::Int)
    trialFolder(T::AbstractTrial)

Return the output folder path for trial type `T` with the given ID.
"""
trialFolder(T::Type{<:AbstractTrial}, id::Int) = joinpath(dataDir(), "outputs", "$(lowerClassString(T))s", string(id))
trialFolder(T::AbstractTrial) = trialFolder(typeof(T), T.id)

"""
    lowerClassString(T)

Return the lowercase name of `T`'s concrete type (e.g. `"simulation"`).
"""
function lowerClassString(::Type{T}) where {T<:AbstractTrial}
    return nameof(T) |> String |> lowercase
end
lowerClassString(T::AbstractTrial) = lowerClassString(typeof(T))

"""
    pathToOutputFolder(simulation_id::Int)

Return the path to the output folder for `simulation_id`.
"""
pathToOutputFolder(simulation_id::Int) = joinpath(trialFolder(Simulation, simulation_id), "output")

########################################################
############   MMOutput   ##############################
########################################################

"""
    MMOutput{T<:AbstractTrial}

Hold the result of a [`run`](@ref) call.

# Fields
- `trial::T`: The trial that was run.
- `n_scheduled::Int`: Number of simulations scheduled in this run.
- `n_success::Int`: Number of simulations that completed successfully.
"""
struct MMOutput{T<:AbstractTrial}
    trial::T
    n_scheduled::Int
    n_success::Int

    function MMOutput(trial::T, n_scheduled::Int, n_success::Int) where T<:AbstractTrial
        new{T}(trial, n_scheduled, n_success)
    end
end

function Base.show(io::IO, output::MMOutput)
    println(io, "MM Output")
    println(io, "------------")
    println(io, output.trial)
    println(io, "")
    println(io, "In completing this trial:")
    println(io, "  - Scheduled $(output.n_scheduled) simulations.")
    println(io, "  - Successfully completed $(output.n_success) simulations.")
end

simulationIDs(output::MMOutput) = simulationIDs(output.trial)
trialType(::MMOutput{T}) where T<:AbstractTrial = T
trialID(output::MMOutput) = trialID(output.trial)

"""
    setNumberOfParallelSims(n::Int)

Set the maximum number of parallel simulations.
"""
function setNumberOfParallelSims(n::Int)
    mm_globals().max_number_of_parallel_simulations = n
end
