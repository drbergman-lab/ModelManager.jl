using Distributions
import Distributions: cdf

export ElementaryVariation, DiscreteVariation, DistributedVariation, CoVariation, LatentVariation
export UniformDistributedVariation, NormalDistributedVariation
export GridVariation, LHSVariation, SobolVariation, RBDVariation
export addVariations

################## Column name utility ##################

"""
    columnName(xml_path::Vector{<:AbstractString})

Join an XML path vector into a slash-separated column name string.
"""
columnName(xml_path::Vector{<:AbstractString}) = join(xml_path, "/")

################## XMLPath ##################

"""
    XMLPath

Hold an XML path as a vector of strings, where each element is a node in the path.

A `:` in a path element denotes an attribute filter, e.g. `"cell_definition:name:default"` selects
the `<cell_definition>` whose `name` attribute equals `"default"`.
A double-colon `::` separates a parent tag from a child tag used as a filter.
"""
struct XMLPath
    xml_path::Vector{String}

    function XMLPath(xml_path::AbstractVector{<:AbstractString})
        for path_element in xml_path
            tokens = split(path_element, ":")
            if length(tokens) < 4
                continue
            end
            msg = """
            Invalid XML path: $(path_element)
            It has $(length(tokens)) tokens (':' is the delimiter) but the only valid path element with >3 tokens is one of:
            - <tag>::<child_tag>:<child_tag_content>
            - <tag>:<attribute>:custom:<custom_data_name>
            - <tag>:<attribute>:custom: <custom_data_name>
            """
            @assert (isempty(tokens[2]) || tokens[3] == "custom") msg
        end
        return new(xml_path)
    end
end

columnName(xp::XMLPath) = columnName(xp.xml_path)

Base.show(io::IO, xp::XMLPath) = print(io, "XMLPath: $(columnName(xp))")

################## Abstract Variations ##################

"""
    AbstractVariation

Abstract type for variations.

# Subtypes
[`ElementaryVariation`](@ref), [`DiscreteVariation`](@ref), [`DistributedVariation`](@ref), [`CoVariation`](@ref)
"""
abstract type AbstractVariation end

"""
    ElementaryVariation <: AbstractVariation

The base type for variations of a single parameter.
"""
abstract type ElementaryVariation <: AbstractVariation end

"""
    DiscreteVariation{T} <: ElementaryVariation

The location, target, and values of a discrete variation.

# Fields
- `location::Symbol`: The location (input-folder category) for this variation.
- `target::XMLPath`: The XML path to the element being varied.
- `values::Vector{T}`: The possible values that the target can take on.

A singleton value can be passed in place of `values` for convenience.

`location` must be provided explicitly.  Simulator packages (e.g. PhysiCellModelManager)
may provide convenience constructors that infer `location` from the target.
"""
struct DiscreteVariation{T} <: ElementaryVariation
    location::Symbol
    target::XMLPath
    values::Vector{T}

    function DiscreteVariation(location::Symbol, target::XMLPath, values::Vector{T}) where T
        return new{T}(location, target, values)
    end
end

DiscreteVariation(location::Symbol, target::XMLPath, value::T) where T = DiscreteVariation(location, target, Vector{T}([value]))

Base.length(discrete_variation::DiscreteVariation) = length(discrete_variation.values)

function Base.show(io::IO, dv::DiscreteVariation)
    println(io, "DiscreteVariation ($(variationDataType(dv))):")
    println(io, "  location: $(dv.location)")
    println(io, "  target: $(columnName(dv))")
    println(io, "  values: $(dv.values)")
end

function ElementaryVariation(location::Symbol, target::XMLPath, v; kwargs...)
    if v isa Distribution{Univariate}
        return DistributedVariation(location, target, v; kwargs...)
    else
        return DiscreteVariation(location, target, v; kwargs...)
    end
end

"""
    DistributedVariation <: ElementaryVariation

The location, target, and distribution of a distributed variation.

# Fields
- `location::Symbol`: The location (input-folder category) for this variation.
- `target::XMLPath`: The XML path to the element being varied.
- `distribution::Distribution`: The distribution of the variation.
- `flip::Bool=false`: Whether to flip the distribution (iCDF of `1-x` instead of `x`).

`location` must be provided explicitly.  Simulator packages (e.g. PhysiCellModelManager)
may provide convenience constructors that infer `location` from the target.
"""
struct DistributedVariation <: ElementaryVariation
    location::Symbol
    target::XMLPath
    distribution::Distribution
    flip::Bool

    function DistributedVariation(location::Symbol, target::XMLPath, distribution::Distribution; flip::Bool=false)
        return new(location, target, distribution, flip)
    end
end

"""
    variationTarget(av::AbstractVariation)

Get the [`XMLPath`](@ref) target(s) of a variation.
"""
variationTarget(ev::ElementaryVariation) = ev.target

"""
    variationLocation(av::AbstractVariation)

Get the location of a variation as a `Symbol`.
"""
variationLocation(ev::ElementaryVariation) = ev.location

columnName(ev::ElementaryVariation) = variationTarget(ev) |> columnName

Base.length(::DistributedVariation) = -1

function Base.show(io::IO, dv::DistributedVariation)
    println(io, "DistributedVariation" * (dv.flip ? " (flipped)" : "") * ":")
    println(io, "  location: $(dv.location)")
    println(io, "  target: $(columnName(dv))")
    println(io, "  distribution: $(dv.distribution)")
end

"""
    UniformDistributedVariation(location, xml_path, lb, ub; flip=false)

Create a `DistributedVariation` with a `Uniform(lb, ub)` distribution.

`location` must be provided explicitly.  Simulator packages (e.g. PhysiCellModelManager)
may provide convenience constructors that infer `location` from the target.
"""
function UniformDistributedVariation(location::Symbol, target::XMLPath, lb::T, ub::T; flip::Bool=false) where {T<:Real}
    return DistributedVariation(location, target, Uniform(lb, ub); flip=flip)
end

"""
    NormalDistributedVariation(location, target, mu, sigma; lb=-Inf, ub=Inf, flip=false)

Create a (possibly truncated) `DistributedVariation` with a Normal distribution.

`location` must be provided explicitly.  Simulator packages (e.g. PhysiCellModelManager)
may provide convenience constructors that infer `location` from the target.
"""
function NormalDistributedVariation(location::Symbol, target::XMLPath, mu::T, sigma::T; lb::Real=-Inf, ub::Real=Inf, flip::Bool=false) where {T<:Real}
    return DistributedVariation(location, target, truncated(Normal(mu, sigma), lb, ub); flip=flip)
end

"""
    variationValues(ev::ElementaryVariation[, cdf])

Get the values of an [`ElementaryVariation`](@ref).
"""
variationValues(discrete_variation::DiscreteVariation) = discrete_variation.values

function variationValues(discrete_variation::DiscreteVariation, cdf::Vector{<:Real})
    index = floor.(Int, cdf * length(discrete_variation)) .+ 1
    index[index.==(length(discrete_variation)+1)] .= length(discrete_variation)
    return discrete_variation.values[index]
end

function variationValues(dv::DistributedVariation, cdf::Vector{<:Real})
    return map(Base.Fix1(quantile, dv.distribution), dv.flip ? 1 .- cdf : cdf)
end

variationValues(ev, cdf::Real) = variationValues(ev, [cdf])

variationValues(::DistributedVariation) = error("A cdf must be provided for a DistributedVariation.")

"""
    variationValues(f::Function, ev::ElementaryVariation[, cdf])

Apply a function `f` to each of the variation values.
"""
variationValues(f::Function, args...) = f.(variationValues(args...))

"""
    variationDataType(ev::ElementaryVariation)

Get the data type of the variation values.
"""
variationDataType(::DiscreteVariation{T}) where T = T
variationDataType(dv::DistributedVariation) = eltype(dv.distribution)

"""
    sqliteDataType(ev::ElementaryVariation)
    sqliteDataType(data_type::DataType)

Map a Julia data type to its SQLite column type string.
"""
function sqliteDataType(ev::ElementaryVariation)
    return sqliteDataType(variationDataType(ev))
end

function sqliteDataType(data_type::DataType)
    if data_type == Bool
        return "TEXT"
    elseif data_type <: Integer
        return "INT"
    elseif data_type <: Real
        return "REAL"
    else
        return "TEXT"
    end
end

"""
    cdf(ev::ElementaryVariation, x::Real)

Get the cumulative distribution function value of the variation at `x`.
"""
function cdf(discrete_variation::DiscreteVariation, x::Real)
    if !(x in discrete_variation.values)
        error("Value not in elementary variation values.")
    end
    return (findfirst(isequal(x), discrete_variation.values) - 1) / (length(discrete_variation) - 1)
end

function cdf(dv::DistributedVariation, x::Real)
    out = cdf(dv.distribution, x)
    if dv.flip
        return 1 - out
    end
    return out
end

cdf(ev::ElementaryVariation, ::Real) = error("cdf not defined for $(typeof(ev))")

################## Co-Variations ##################

"""
    CoVariation{T<:ElementaryVariation} <: AbstractVariation

A co-variation of one or more [`ElementaryVariation`](@ref)s that are varied together.

Each constituent variation must be of the same subtype (all `DiscreteVariation` or all
`DistributedVariation`).
"""
struct CoVariation{T<:ElementaryVariation} <: AbstractVariation
    variations::Vector{T}

    function CoVariation(inputs::Vararg{Tuple{Vector{<:AbstractString},Distribution},N}) where {N}
        variations = DistributedVariation[]
        for (xml_path, distribution) in inputs
            @assert xml_path isa Vector{<:AbstractString} "xml_path must be a vector of strings"
            push!(variations, DistributedVariation(xml_path, distribution))
        end
        return new{DistributedVariation}(variations)
    end

    function CoVariation(inputs::Vararg{Tuple{Vector{<:AbstractString},Vector},N}) where {N}
        variations = DiscreteVariation[]
        n_discrete = -1
        for (xml_path, val) in inputs
            n_vals = length(val)
            if n_discrete == -1
                n_discrete = n_vals
            else
                @assert n_discrete == n_vals "All discrete vals must have the same length"
            end
            push!(variations, DiscreteVariation(xml_path, val))
        end
        return new{DiscreteVariation}(variations)
    end

    CoVariation(evs::Vector{DistributedVariation}) = return new{DistributedVariation}(evs)

    function CoVariation(evs::Vector{<:DiscreteVariation})
        @assert (length.(evs) |> unique |> length) == 1 "All DiscreteVariations in a CoVariation must have the same length."
        return new{DiscreteVariation}(evs)
    end

    function CoVariation(inputs::Vararg{T}) where {T<:ElementaryVariation}
        return CoVariation(Vector{T}([inputs...]))
    end
end

variationTarget(cv::CoVariation) = variationTarget.(cv.variations)
variationLocation(cv::CoVariation) = variationLocation.(cv.variations)
columnName(cv::CoVariation) = columnName.(cv.variations) |> x -> join(x, " AND ")

function Base.length(cv::CoVariation)
    return length(cv.variations[1])
end

function Base.show(io::IO, cv::CoVariation)
    data_type = typeof(cv).parameters[1]
    data_type_str = string(data_type)
    title_str = "CoVariation ($(data_type_str)):"
    println(io, title_str)
    println(io, "-"^length(title_str))
    locations = variationLocation(cv)
    unique_locations = unique(locations)
    for location in unique_locations
        println(io, "  Location: $location")
        location_inds = findall(isequal(location), locations)
        for ind in location_inds
            println(io, "  Variation $ind:")
            println(io, "    target: $(columnName(cv.variations[ind]))")
            if data_type == DiscreteVariation
                println(io, "    values: $(variationValues(cv.variations[ind]))")
            elseif data_type == DistributedVariation
                println(io, "    distribution: $(cv.variations[ind].distribution)")
                println(io, "    flip: $(cv.variations[ind].flip)")
            end
        end
    end
end

################## Latent Variations ##################

"""
    LatentVariation{T<:Union{Vector{<:Real},<:Distribution}} <: AbstractVariation

A variation that uses latent parameters to generate target parameter values via mapping functions.

Whereas [`CoVariation`](@ref)s enforce a 1D relationship between parameters,
[`LatentVariation`](@ref)s allow multi-dimensional relationships via user-supplied maps.
The latent parameters themselves are not stored in the database; only the derived target values are.

Internally, [`ParsedVariations`](@ref) converts all variations to `LatentVariation`s for processing.
"""
struct LatentVariation{T<:Union{Vector{<:Real},<:Distribution}} <: AbstractVariation
    latent_parameters::Vector{T}
    latent_parameter_names::Vector{String}
    locations::Vector{Symbol}
    targets::Vector{XMLPath}
    maps::Vector{<:Function}
    types::Vector{DataType}

    function LatentVariation(latent_parameters::Vector{<:Vector{T}}, targets::AbstractVector{XMLPath}, maps::Vector{<:Function}, lp_names::AbstractVector{<:AbstractString}, locations::AbstractVector{Symbol}) where T<:Real
        @assert length(targets) == length(maps) "LatentVariation requires the number of targets and maps to be the same. Found $(length(targets)) and $(length(maps)), respectively."
        @assert length(targets) == length(locations) "LatentVariation requires the number of targets and locations to be the same. Found $(length(targets)) and $(length(locations)), respectively."
        types = map(maps) do fn
            sample_input = [lp[1] for lp in latent_parameters]
            sample_output = fn(sample_input)
            eltype(sample_output)
        end
        return new{Vector{T}}(latent_parameters, lp_names, locations, targets, maps, types)
    end

    function LatentVariation(latent_parameters::Vector{T}, targets::AbstractVector{XMLPath}, maps::Vector{<:Function}, lp_names::AbstractVector{<:AbstractString}, locations::AbstractVector{Symbol}) where T<:Distribution
        @assert length(targets) == length(maps) "LatentVariation requires the number of targets and maps to be the same. Found $(length(targets)) and $(length(maps)), respectively."
        @assert length(targets) == length(locations) "LatentVariation requires the number of targets and locations to be the same. Found $(length(targets)) and $(length(locations)), respectively."
        types = map(maps) do fn
            sample_input = [quantile(lp, 0.5) for lp in latent_parameters]
            sample_output = fn(sample_input)
            eltype(sample_output)
        end
        return new{T}(latent_parameters, lp_names, locations, targets, maps, types)
    end
end

"""
    defaultLatentParameterNames(latent_parameters, targets)

Generate default names for latent parameters based on target column names.
"""
function defaultLatentParameterNames(latent_parameters::Vector, targets::Vector{XMLPath})
    par_names = join(columnName.(targets), " | ")
    return [par_names * " | lp#$(i)" for i in 1:length(latent_parameters)]
end

function LatentVariation(dv::T) where T<:DiscreteVariation
    latent_parameters = [dv.values]
    targets = [variationTarget(dv)]
    maps = [first]
    return LatentVariation(latent_parameters, targets, maps, [columnName(dv)])
end

function LatentVariation(dv::T) where T<:DistributedVariation
    latent_parameters = [Uniform(0,1)]
    targets = [variationTarget(dv)]
    maps = [dv.flip ? us -> quantile(dv.distribution, 1 - us[1]) : us -> quantile(dv.distribution, us[1])]
    return LatentVariation(latent_parameters, targets, maps, [columnName(dv)])
end

function LatentVariation(cv::CoVariation{T}) where T<:DiscreteVariation
    latent_parameters = [collect(1:length(cv))]
    targets = variationTarget(cv)
    maps = [I -> cv.variations[i].values[I[1]] for i in 1:length(cv.variations)]
    return LatentVariation(latent_parameters, targets, maps, [columnName(cv)])
end

function LatentVariation(cv::CoVariation{T}) where T<:DistributedVariation
    latent_parameters = [Uniform(0.0, 1.0)]
    targets = variationTarget(cv)
    maps = map(cv.variations) do dv
        dv.flip ? us -> quantile(dv.distribution, 1 - us[1]) : us -> quantile(dv.distribution, us[1])
    end
    return LatentVariation(latent_parameters, targets, maps, [columnName(cv)])
end

LatentVariation(lv::LatentVariation) = lv

Base.size(lv::LatentVariation{<:Vector{<:Real}}) = length.(lv.latent_parameters)
Base.size(lv::LatentVariation{<:Distribution}) = -ones(Int, length(lv.latent_parameters))
nLatentDims(lv::LatentVariation) = length(lv.latent_parameters)

variationTarget(lv::LatentVariation) = lv.targets
nTargetDims(lv::LatentVariation) = length(variationTarget(lv))
columnName(lv::LatentVariation) = variationTarget(lv) .|> columnName

variationLocation(lv::LatentVariation) = lv.locations

function Base.show(io::IO, lv::LatentVariation)
    data_type = lv.latent_parameters[1] isa Distribution ? "Distribution" : "Discrete"
    n_latent = nLatentDims(lv)
    n_targets = nTargetDims(lv)
    title_str = "LatentVariation ($data_type), $(n_latent) -> $(n_targets):"
    println(io, title_str)
    println(io, "-"^length(title_str))
    indent = "  "

    println(io, indent, "Latent Parameters (n = $n_latent):")
    all_latent_nums = ["lp#$(i)." for i in 1:nLatentDims(lv)]
    biggest_width = maximum(length.(all_latent_nums))
    for (n, name, lp) in zip(all_latent_nums, lv.latent_parameter_names, lv.latent_parameters)
        print(io, indent, indent, lpad(n, biggest_width), " $(name)")
        if lp isa Distribution
            println(io, " ($(lp))")
        else
            println(io, " ([", join(lp, ", "), "])")
        end
    end

    println(io, indent, "Target Parameters (n = $n_targets):")
    all_target_nums = ["tp#$(i)." for i in 1:nTargetDims(lv)]
    biggest_width = maximum(length.(all_target_nums))
    indent2 = indent * indent * ' '^(biggest_width + 3)
    last_n = last(all_target_nums)
    for (n, loc, tar) in zip(all_target_nums, variationLocation(lv), variationTarget(lv))
        println(io, indent, indent, lpad(n, biggest_width), " $(columnName(tar))")
        println(io, indent2, "Location: $(loc)")
        print(io, indent2, "Target: $(tar)")
        if n != last_n
            println(io)
        end
    end
end

"""
    variationValues(lv::LatentVariation)

Compute the variation values for all combinations of discrete latent parameters.
"""
function variationValues(lv::LatentVariation{<:Vector{<:Real}})
    cart_inds = CartesianIndices(Dims(size(lv)))
    lin_inds = LinearIndices(Dims(size(lv)))
    ret_val = Array{Float64}(undef, length(lv.maps), prod(size(lv)))
    for (I, li) in zip(cart_inds, lin_inds)
        lp_vals = [lps[i] for (i, lps) in zip(I.I, lv.latent_parameters)]
        ret_val[:, li] .= [fn(lp_vals) for fn in lv.maps]
    end
    return ret_val
end

function variationValues(lv::LatentVariation{<:Vector{<:Real}}, cdfs::AbstractVector{<:Real})
    @assert length(cdfs) == nLatentDims(lv) "CDF vector length must match number of latent parameters."
    latent_pars = [floor(Int, cdf * length(lp)) + 1 for (cdf, lp) in zip(cdfs, lv.latent_parameters)]
    return [fn(latent_pars) for fn in lv.maps]
end

function variationValues(lv::LatentVariation{<:Distribution}, cdfs::AbstractVector{<:Real})
    @assert length(cdfs) == nLatentDims(lv) "CDF vector length must match number of latent parameters."
    lp_vals = [quantile(d, cdf_val) for (d, cdf_val) in zip(lv.latent_parameters, cdfs)]
    return [fn(lp_vals) for fn in lv.maps]
end

function variationValues(lv::LatentVariation{<:Distribution}, cdfs::AbstractVector{<:AbstractVector})
    return stack(sample_cdfs -> variationValues(lv, sample_cdfs), cdfs)
end

function variationValues(lv::LatentVariation{<:Distribution}, cdfs::AbstractMatrix{<:Real})
    @assert size(cdfs, 1) == nLatentDims(lv) "CDF matrix number of rows must match number of latent parameters."
    return stack(sample_cdfs -> variationValues(lv, sample_cdfs), eachcol(cdfs))
end

################## Parsed Variations ##################

"""
    ParsedVariations{T<:LatentVariation}

Holds all variations converted to `LatentVariation`s, ready for sampling.
"""
struct ParsedVariations{T<:LatentVariation}
    latent_variations::Vector{T}

    function ParsedVariations(avs::Vector{<:AbstractVariation})
        s = Set{Tuple{Symbol,XMLPath}}()
        lvs = LatentVariation.(avs) |> Vector{LatentVariation}
        for lv in lvs
            for (loc, tar) in zip(variationLocation(lv), variationTarget(lv))
                @assert !in((loc, tar), s) """The following XMLPath for location $(loc) is repeated (being set twice). Please correct

                    $tar
                """
                push!(s, (loc, tar))
            end
        end
        return new{eltype(lvs)}(lvs)
    end
end

function variationValues(pv::ParsedVariations, cdf_col::AbstractVector{<:Real})
    @assert length(cdf_col) == nLatentDims(pv) "CDF vector length must match number of latent parameters."
    next_ind = 1
    sample_par_vals = []
    for lv in pv.latent_variations
        n_latent_dims = nLatentDims(lv)
        cdf_subset = cdf_col[next_ind:(next_ind+n_latent_dims-1)]
        next_ind += n_latent_dims
        par_values = variationValues(lv, cdf_subset)
        push!(sample_par_vals, par_values)
    end
    vcat(sample_par_vals...)
end

nLatentDims(pv::ParsedVariations) = mapreduce(nLatentDims, +, pv.latent_variations)
nTargetDims(pv::ParsedVariations) = mapreduce(nTargetDims, +, pv.latent_variations)

################## AddVariationMethod Types ##################

"""
    AddVariationMethod

Abstract type for variation sampling methods.

# Subtypes
[`GridVariation`](@ref), [`LHSVariation`](@ref), [`SobolVariation`](@ref), [`RBDVariation`](@ref)
"""
abstract type AddVariationMethod end

"""
    GridVariation <: AddVariationMethod

Enumerate all combinations of discrete variation values (full factorial grid).
"""
struct GridVariation <: AddVariationMethod end

"""
    LHSVariation <: AddVariationMethod

Latin Hypercube Sampling.

# Fields
- `n::Int`: Number of samples.
- `add_noise::Bool=false`: Whether to add noise within each bin.
- `rng::AbstractRNG=Random.GLOBAL_RNG`
- `orthogonalize::Bool=true`
"""
struct LHSVariation <: AddVariationMethod
    n::Int
    add_noise::Bool
    rng::AbstractRNG
    orthogonalize::Bool
end
LHSVariation(n; add_noise::Bool=false, rng::AbstractRNG=Random.GLOBAL_RNG, orthogonalize::Bool=true) = LHSVariation(n, add_noise, rng, orthogonalize)
LHSVariation(; n::Int=4, kwargs...) = LHSVariation(n; kwargs...)

"""
    SobolVariation <: AddVariationMethod

Sobol quasi-random sequence sampling.

# Fields
- `n::Int`: Number of samples.
- `n_matrices::Int=1`: Number of design matrices.
- `randomization::RandomizationMethod=NoRand()`
- `skip_start::Union{Missing,Bool,Int}=missing`
- `include_one::Union{Missing,Bool}=missing`
"""
struct SobolVariation <: AddVariationMethod
    n::Int
    n_matrices::Int
    randomization::RandomizationMethod
    skip_start::Union{Missing,Bool,Int}
    include_one::Union{Missing,Bool}
end
SobolVariation(n::Int; n_matrices::Int=1, randomization::RandomizationMethod=NoRand(), skip_start::Union{Missing,Bool,Int}=missing, include_one::Union{Missing,Bool}=missing) = SobolVariation(n, n_matrices, randomization, skip_start, include_one)
SobolVariation(; pow2::Int=1, n_matrices::Int=1, randomization::RandomizationMethod=NoRand(), skip_start::Union{Missing,Bool,Int}=missing, include_one::Union{Missing,Bool}=missing) = SobolVariation(2^pow2, n_matrices, randomization, skip_start, include_one)

"""
    RBDVariation <: AddVariationMethod

Random Balance Design sampling.

# Fields
- `n::Int`
- `rng::AbstractRNG=Random.GLOBAL_RNG`
- `use_sobol::Bool=true`
- `pow2_diff::Union{Missing,Int}=missing`
- `num_cycles::Union{Missing,Int,Rational}=missing`
"""
struct RBDVariation <: AddVariationMethod
    n::Int
    rng::AbstractRNG
    use_sobol::Bool
    pow2_diff::Union{Missing,Int}
    num_cycles::Rational

    function RBDVariation(n::Int, rng::AbstractRNG, use_sobol::Bool, pow2_diff::Union{Missing,Int}, num_cycles::Union{Missing,Int,Rational})
        if use_sobol
            k = log2(n) |> round |> Int
            if ismissing(pow2_diff)
                pow2_diff = n - 2^k
            else
                @assert pow2_diff == n - 2^k "pow2_diff must be n - 2^k for RBDVariation with Sobol sequence"
            end
            @assert abs(pow2_diff) <= 1 "n must be within 1 of a power of 2 for RBDVariation with Sobol sequence"
            if ismissing(num_cycles)
                num_cycles = 1 // 2
            else
                @assert num_cycles == 1 // 2 "num_cycles must be 1//2 for RBDVariation with Sobol sequence"
            end
        else
            pow2_diff = missing
            if ismissing(num_cycles)
                num_cycles = 1
            else
                @assert num_cycles == 1 "num_cycles must be 1 for RBDVariation with random sequence"
            end
        end
        return new(n, rng, use_sobol, pow2_diff, num_cycles)
    end
end

RBDVariation(n::Int; rng::AbstractRNG=Random.GLOBAL_RNG, use_sobol::Bool=true, pow2_diff=missing, num_cycles=missing) = RBDVariation(n, rng, use_sobol, pow2_diff, num_cycles)

################## AddVariationsResult Types ##################

"""
    AddVariationsResult

Abstract type for the result of [`addVariations`](@ref).
"""
abstract type AddVariationsResult end

struct AddGridVariationsResult <: AddVariationsResult
    variation_ids::AbstractArray{VariationID}
end

struct AddLHSVariationsResult <: AddVariationsResult
    cdfs::Matrix{Float64}
    variation_ids::Vector{VariationID}
end

struct AddSobolVariationsResult <: AddVariationsResult
    cdfs::Array{Float64,3}
    variation_ids::AbstractArray{VariationID}
end

struct AddRBDVariationsResult <: AddVariationsResult
    variation_ids::AbstractArray{VariationID}
    variation_matrix::Matrix{VariationID}
end

################## addVariations entry point ##################

"""
    addVariations(method::AddVariationMethod, inputs::InputFolders, avs::Vector{<:AbstractVariation},
                  reference_variation_id::VariationID=VariationID(inputs))

Add variations to `inputs` using `method` and return an [`AddVariationsResult`](@ref).
"""
function addVariations(method::AddVariationMethod, inputs::InputFolders, avs::Vector{<:AbstractVariation}, reference_variation_id::VariationID=VariationID(inputs))
    pv = ParsedVariations(avs)
    return addVariations(method, inputs, pv, reference_variation_id)
end

################## Grid Variations ##################

function addVariations(::GridVariation, inputs::InputFolders, pv::ParsedVariations, reference_variation_id::VariationID)
    if isempty(pv.latent_variations)
        return AddGridVariationsResult([reference_variation_id])
    end
    @assert all(lv -> all(!=(-1), size(lv)), pv.latent_variations) "GridVariation does not work with distributions."
    lv_col_iters = [eachcol(variationValues(lv)) for lv in pv.latent_variations]
    locs = mapreduce(variationLocation, vcat, pv.latent_variations)
    unique_locs = unique(locs)
    targets = mapreduce(variationTarget, vcat, pv.latent_variations)
    types = mapreduce(lv -> lv.types, vcat, pv.latent_variations)
    loc_inds = [loc => findall(==(loc), locs) for loc in unique_locs] |> Dict
    dim_szs = [prod(size(lv)) for lv in pv.latent_variations]
    cart_inds = CartesianIndices(Dims(dim_szs))
    all_vals = stack(vec(cart_inds)) do I
        mapreduce(vcat, zip(I.I, lv_col_iters)) do (i, lv_col_iter)
            lv_col_iter[i]
        end
    end
    loc_dicts = map(unique_locs) do loc
        loc => (all_vals[loc_inds[loc], :], types[loc_inds[loc]], targets[loc_inds[loc]])
    end |> Dict
    return addVariationRows(mm_globals().simulator, inputs, reference_variation_id, loc_dicts) |> AddGridVariationsResult
end

################## Latin Hypercube Sampling ##################

"""
    orthogonalLHS(k::Int, d::Int)

Generate an orthogonal Latin Hypercube Sample in `d` dimensions with `k` subdivisions.
"""
function orthogonalLHS(k::Int, d::Int)
    n = k^d
    lhs_inds = zeros(Int, (n, d))
    for i in 1:d
        n_bins = k^(i - 1)
        bin_size = k^(d - i + 1)
        if i == 1
            lhs_inds[:, 1] = 1:n
        else
            bin_inds_gps = [(j - 1) * bin_size .+ (1:bin_size) |> collect for j in 1:n_bins]
            for pt_ind = 1:bin_size
                ind = zeros(Int, n_bins)
                for (j, bin_inds) in enumerate(bin_inds_gps)
                    rand_ind_of_ind = rand(1:length(bin_inds))
                    ind[j] = popat!(bin_inds, rand_ind_of_ind)
                end
                lhs_inds[ind, i] = shuffle(1:n_bins) .+ (pt_ind - 1) * n_bins
            end
        end
        lhs_inds[:, 1:i] = sortslices(lhs_inds[:, 1:i], dims=1, by=x -> (x ./ (n / k) .|> ceil .|> Int))
    end
    return lhs_inds
end

"""
    generateLHSCDFs(n::Int, d::Int; add_noise=false, rng=Random.GLOBAL_RNG, orthogonalize=true)

Generate a Latin Hypercube Sample of CDFs for `n` samples in `d` dimensions.
"""
function generateLHSCDFs(n::Int, d::Int; add_noise::Bool=false, rng::AbstractRNG=Random.GLOBAL_RNG, orthogonalize::Bool=true)
    cdfs = (Float64.(1:n) .- (add_noise ? rand(rng, Float64, n) : 0.5)) / n
    k = n^(1 / d) |> round |> Int
    if orthogonalize && (n == k^d)
        lhs_inds = orthogonalLHS(k, d)
    else
        lhs_inds = reduce(hcat, [shuffle(rng, 1:n) for _ in 1:d])
    end
    return cdfs[lhs_inds]
end

function addVariations(lhs_variation::LHSVariation, inputs::InputFolders, pv::ParsedVariations, reference_variation_id::VariationID)
    d = nLatentDims(pv)
    cdfs = generateLHSCDFs(lhs_variation.n, d; add_noise=lhs_variation.add_noise, rng=lhs_variation.rng, orthogonalize=lhs_variation.orthogonalize)
    cdfs_reshaped = permutedims(cdfs)
    variation_ids = addCDFVariations(inputs, pv, reference_variation_id, cdfs_reshaped)
    return AddLHSVariationsResult(cdfs_reshaped, variation_ids)
end

################## Sobol Sequence Sampling ##################

"""
    generateSobolCDFs(n::Int, d::Int[; n_matrices::Int=1, randomization::RandomizationMethod=NoRand(), skip_start::Union{Missing, Bool, Int}=missing, include_one::Union{Missing, Bool}=missing])

Generate `n_matrices` Sobol sequences of the Cumulative Distribution Functions (CDFs) for `n` samples in `d` dimensions.

The subsequence of the Sobol sequence is chosen based on the value of `n` and the value of `include_one`.
If it is one less than a power of 2, e.g. `n=7`, skip 0 and start from 0.5.
Otherwise, it will always start from 0.
If it is one more than a power of 2, e.g. `n=9`, include 1 (unless `include_one` is `false`).

The `skip_start` field can be used to control this by skipping the start of the sequence.
If `skip_start` is `true`, skip to the smallest consecutive subsequence with the same denominator that has at least `n` elements.
If `skip_start` is `false`, start from 0.
If `skip_start` is an integer, skip that many elements in the sequence, e.g. `skip_start=1` skips 0 and starts at 0.5.

If you want to include 1 in the sequence, set `include_one` to `true`.
If you want to exclude 1 (in the case of `n=9`, e.g.), set `include_one` to `false`.

# Arguments
- `n::Int`: The number of samples to take.
- `d::Int`: The number of dimensions to sample.
- `n_matrices::Int=1`: The number of matrices to use in the Sobol sequence (effectively, the dimension of the sample is `d` x `n_matrices`).
- `randomization::RandomizationMethod=NoRand()`: The randomization method to use on the deterministic Sobol sequence.
- `skip_start::Union{Missing, Bool, Int}=missing`: Whether to skip the start of the sequence. `missing` means ModelManager will choose the best option.
- `include_one::Union{Missing, Bool}=missing`: Whether to include 1 in the sequence. `missing` means ModelManager will choose the best option.

# Returns
- `cdfs::Array{Float64, 3}`: The CDFs for the samples. First dimension is features, second is matrix index, third is sample points.

# Examples
```jldoctest
cdfs = ModelManager.generateSobolCDFs(11, 3)
size(cdfs)
# output
(3, 1, 11)
```
```jldoctest
cdfs = ModelManager.generateSobolCDFs(7, 5; n_matrices=2)
size(cdfs)
# output
(5, 2, 7)
```
"""
function generateSobolCDFs(n::Int, d::Int; n_matrices::Int=1, T::Type=Float64, randomization::RandomizationMethod=NoRand(), skip_start::Union{Missing,Bool,Int}=missing, include_one::Union{Missing,Bool}=missing)
    s = SobolSeq(d * n_matrices)
    if ismissing(skip_start)
        if ispow2(n + 1)
            skip_start = 1
        else
            skip_start = false
            if ispow2(n - 1)
                include_one |= ismissing(include_one)
            elseif ispow2(n)
                nothing
            end
        end
    end
    n_draws = n - (include_one === true)
    if skip_start == false
        cdfs = randomize(reduce(hcat, [zeros(T, n_matrices * d), [next!(s) for i in 1:n_draws-1]...]), randomization)
    else
        cdfs = Matrix{T}(undef, d * n_matrices, n_draws)
        num_to_skip = skip_start === true ? ((1 << (floor(Int, log2(n_draws - 1)) + 1))) : skip_start
        num_to_skip -= 1
        for _ in 1:num_to_skip
            next!(s)
        end
        for col in eachcol(cdfs)
            next!(s, col)
        end
        cdfs = randomize(cdfs, randomization)
    end
    if include_one === true
        cdfs = hcat(cdfs, ones(T, d * n_matrices))
    end
    return reshape(cdfs, (d, n_matrices, n))
end

generateSobolCDFs(sobol_variation::SobolVariation, d::Int) = generateSobolCDFs(sobol_variation.n, d; n_matrices=sobol_variation.n_matrices, randomization=sobol_variation.randomization, skip_start=sobol_variation.skip_start, include_one=sobol_variation.include_one)

function addVariations(sobol_variation::SobolVariation, inputs::InputFolders, pv::ParsedVariations, reference_variation_id::VariationID)
    d = nLatentDims(pv)
    cdfs = generateSobolCDFs(sobol_variation, d)
    cdfs_reshaped = reshape(cdfs, (d, sobol_variation.n_matrices * sobol_variation.n))
    variation_ids = addCDFVariations(inputs, pv, reference_variation_id, cdfs_reshaped)
    variation_ids = reshape(variation_ids, (sobol_variation.n_matrices, sobol_variation.n)) |> permutedims
    return AddSobolVariationsResult(cdfs, variation_ids)
end

################## Random Balance Design Sampling ##################

"""
    generateRBDCDFs(rbd_variation::RBDVariation, d::Int)

Generate CDFs and sorting indices for a Random Balance Design in `d` dimensions.
"""
function generateRBDCDFs(rbd_variation::RBDVariation, d::Int)
    if rbd_variation.use_sobol
        println("Using Sobol sequence for RBD.")
        if rbd_variation.n == 1
            rbd_sorting_inds = fill(1, (1, d))
            cdfs = 0.5 .+ zeros(Float64, (1, d))
        else
            @assert !ismissing(rbd_variation.pow2_diff) "pow2_diff must be calculated for RBDVariation constructor with Sobol sequence."
            @assert rbd_variation.num_cycles == 1 // 2 "num_cycles must be 1//2 for RBDVariation with Sobol sequence."
            if rbd_variation.pow2_diff == -1
                skip_start = 1
            elseif rbd_variation.pow2_diff == 0
                skip_start = true
            else
                skip_start = false
            end
            cdfs = generateSobolCDFs(rbd_variation.n, d; n_matrices=1, randomization=NoRand(), skip_start=skip_start, include_one=rbd_variation.pow2_diff == 1)
            cdfs = reshape(cdfs, d, rbd_variation.n) |> permutedims
            rbd_sorting_inds = stack(sortperm, eachcol(cdfs))
        end
    else
        @assert rbd_variation.num_cycles == 1 "num_cycles must be 1 for RBDVariation with random sequence."
        sorted_s_values = range(-π, stop=π, length=rbd_variation.n + 1) |> collect
        pop!(sorted_s_values)
        permuted_s_values = [sorted_s_values[randperm(rbd_variation.rng, rbd_variation.n)] for _ in 1:d] |> x -> reduce(hcat, x)
        cdfs = 0.5 .+ asin.(sin.(permuted_s_values)) ./ π
        rbd_sorting_inds = stack(sortperm, eachcol(permuted_s_values))
    end
    return cdfs, rbd_sorting_inds
end

function addVariations(rbd_variation::RBDVariation, inputs::InputFolders, pv::ParsedVariations, reference_variation_id::VariationID)
    d = nLatentDims(pv)
    cdfs, rbd_sorting_inds = generateRBDCDFs(rbd_variation, d)
    cdfs_reshaped = permutedims(cdfs)
    variation_ids = addCDFVariations(inputs, pv, reference_variation_id, cdfs_reshaped)
    variation_matrix = createSortedRBDMatrix(variation_ids, rbd_sorting_inds)
    return AddRBDVariationsResult(variation_ids, variation_matrix)
end

"""
    createSortedRBDMatrix(variation_ids, rbd_sorting_inds)

Sort variation IDs according to the RBD parameter ordering.
"""
function createSortedRBDMatrix(variation_ids::Vector{VariationID}, rbd_sorting_inds::Matrix{Int})
    return stack(inds -> variation_ids[inds], eachcol(rbd_sorting_inds))
end

################## CDF Variations Helper ##################

"""
    addCDFVariations(inputs, pv, reference_variation_id, cdfs)

Convert CDF samples to parameter values and write new variation rows to the database.
Used internally by LHS, Sobol, and RBD `addVariations` implementations.
"""
function addCDFVariations(inputs::InputFolders, pv::ParsedVariations, reference_variation_id::VariationID, cdfs::AbstractMatrix{Float64})
    all_vals = stack(cdf_col -> variationValues(pv, cdf_col), eachcol(cdfs))

    locs = mapreduce(variationLocation, vcat, pv.latent_variations)
    unique_locs = unique(locs)
    targets = mapreduce(variationTarget, vcat, pv.latent_variations)
    types = mapreduce(lv -> lv.types, vcat, pv.latent_variations)
    loc_inds = [loc => findall(==(loc), locs) for loc in unique_locs] |> Dict

    loc_dicts = map(unique_locs) do loc
        loc => (all_vals[loc_inds[loc], :], types[loc_inds[loc]], targets[loc_inds[loc]])
    end |> Dict
    return addVariationRows(mm_globals().simulator, inputs, reference_variation_id, loc_dicts)
end
