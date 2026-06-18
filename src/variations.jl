using Distributions
import Distributions: cdf

export ElementaryVariation, DiscreteVariation, DistributedVariation, CoVariation, LatentVariation, variationName
export UniformDistributedVariation, NormalDistributedVariation
export GridVariation, LHSVariation, SobolVariation, RBDVariation

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
    name::String

    function DiscreteVariation(location::Symbol, target::XMLPath, values::Vector{T}; name::Union{Nothing,AbstractString}=nothing) where T
        default_name = shortVariationName(location, columnName(target))
        variation_name = isnothing(name) ? default_name : String(name)
        return new{T}(location, target, values, variation_name)
    end
end

DiscreteVariation(location::Symbol, target::XMLPath, value::T; name::Union{Nothing,AbstractString}=nothing) where T =
    DiscreteVariation(location, target, Vector{T}([value]); name=name)

Base.length(discrete_variation::DiscreteVariation) = length(discrete_variation.values)

function Base.show(io::IO, dv::DiscreteVariation)
    println(io, "DiscreteVariation ($(variationDataType(dv))):")
    println(io, "  name: $(variationName(dv))")
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
    name::String

    function DistributedVariation(location::Symbol, target::XMLPath, distribution::Distribution; flip::Bool=false, name::Union{Nothing,AbstractString}=nothing)
        default_name = shortVariationName(location, columnName(target))
        variation_name = isnothing(name) ? default_name : String(name)
        return new(location, target, distribution, flip, variation_name)
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

"""
    variationName(av::AbstractVariation)

Get the user-facing name of a variation used in reports and sensitivity scheme headers.
If no explicit name was provided to the constructor, this is a convention-based default
derived from `shortVariationName(location, columnName(target))`.
"""
variationName(ev::ElementaryVariation) = ev.name

columnName(ev::ElementaryVariation) = variationTarget(ev) |> columnName

Base.length(::DistributedVariation) = -1

function Base.show(io::IO, dv::DistributedVariation)
    println(io, "DistributedVariation" * (dv.flip ? " (flipped)" : "") * ":")
    println(io, "  name: $(variationName(dv))")
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
    name::String

    function CoVariation(inputs::Vararg{Tuple{Vector{<:AbstractString},Distribution},N}; name::Union{Nothing,AbstractString}=nothing) where {N}
        variations = DistributedVariation[]
        for (xml_path, distribution) in inputs
            @assert xml_path isa Vector{<:AbstractString} "xml_path must be a vector of strings"
            push!(variations, DistributedVariation(xml_path, distribution))
        end
        default_name = join(variationName.(variations), " AND ")
        variation_name = isnothing(name) ? default_name : String(name)
        return new{DistributedVariation}(variations, variation_name)
    end

    function CoVariation(inputs::Vararg{Tuple{Vector{<:AbstractString},Vector},N}; name::Union{Nothing,AbstractString}=nothing) where {N}
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
        default_name = join(variationName.(variations), " AND ")
        variation_name = isnothing(name) ? default_name : String(name)
        return new{DiscreteVariation}(variations, variation_name)
    end

    function CoVariation(evs::Vector{DistributedVariation}; name::Union{Nothing,AbstractString}=nothing)
        default_name = join(variationName.(evs), " AND ")
        variation_name = isnothing(name) ? default_name : String(name)
        return new{DistributedVariation}(evs, variation_name)
    end

    function CoVariation(evs::Vector{<:DiscreteVariation}; name::Union{Nothing,AbstractString}=nothing)
        @assert (length.(evs) |> unique |> length) == 1 "All DiscreteVariations in a CoVariation must have the same length."
        default_name = join(variationName.(evs), " AND ")
        variation_name = isnothing(name) ? default_name : String(name)
        return new{DiscreteVariation}(evs, variation_name)
    end

    function CoVariation(inputs::Vararg{T}; name::Union{Nothing,AbstractString}=nothing) where {T<:ElementaryVariation}
        return CoVariation(Vector{T}([inputs...]); name=name)
    end
end

variationTarget(cv::CoVariation) = variationTarget.(cv.variations)
variationLocation(cv::CoVariation) = variationLocation.(cv.variations)
variationName(cv::CoVariation) = cv.name
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
    println(io, "  Name: $(variationName(cv))")
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

# Fields
- `latent_parameters`: Discrete value vectors or prior `Distribution`s, one per latent dimension.
- `latent_parameter_names`: User-friendly names for each latent dimension.
- `locations`: XML location symbols, one per target.
- `targets`: XML paths to each target parameter.
- `target_names`: User-friendly display names for each target parameter. Derived from the source
  variation names when constructed via factory methods (`DistributedVariation`, `CoVariation`).
  For direct construction, supply via the `target_names` keyword; defaults to
  `shortVariationName(location, columnName(target))` for each target.
- `maps`: Forward maps — each `map_j(lp_vals::Vector) → scalar` computes one target value from all latent values.
- `inverse_maps`: Optional inverse maps — each `inv_map_i(target_vals::Vector{Float64}) → Float64` recovers
  the latent parameter value `lp_i` for latent dimension `i` from the full vector of target values (ordered
  by `targets`). The library applies `cdf(dist_i, lp_i)` internally to obtain the CDF coordinate. One
  inverse per latent dimension. Required for `SimulationBank` support with `LVSource` calibration parameters.
  Auto-constructed for [`DVSource`](@ref)/[`CVSource`](@ref)-backed `LatentVariation`s. Supply via the
  `inverse_maps` keyword argument when constructing a user-defined `LatentVariation{<:Distribution}`.
  Monotonicity of the forward map is a user responsibility and is not validated at construction time beyond
  a round-trip accuracy check.
- `types`: Output `eltype` of each forward map's return value.
- `name`: User-supplied or default name.

# Construction

## From existing variation types (preferred for single-parameter calibration)

```julia
# From a DistributedVariation — inverse_maps auto-constructed
dv = DistributedVariation(:config, XMLPath(["tumor", "growth_rate"]), Uniform(0.01, 0.5))
lv = LatentVariation(dv)

# From a CoVariation{DistributedVariation} — inverse_maps auto-constructed
cv = CoVariation(DistributedVariation(:config, XMLPath(["k1"]), Uniform(0.1, 1.0)),
                 DistributedVariation(:config, XMLPath(["k2"]), Uniform(0.5, 5.0)))
lv = LatentVariation(cv)
```

## Direct construction with continuous latent parameters

The positional arguments are:
`LatentVariation(latent_parameters, targets, maps, lp_names, locations; inverse_maps, name)`

- **1 latent dim, 1 target** — log-normal forward map:
```julia
# lp ~ Normal(0,1); target = exp(lp)
lv = LatentVariation(
    [Normal(0.0, 1.0)],
    XMLPath[XMLPath(["tumor", "growth_rate"])],
    Function[lp -> exp(lp[1])],
    ["log_growth_rate"],
    Symbol[:config];
    target_names=["growth rate"],
    inverse_maps=Function[tv -> log(tv[1])]   # returns lp, not CDF
)
```

- **2 latent dims, 2 targets** — independent priors:
```julia
# lp1 ~ Uniform(0,1), lp2 ~ Uniform(0,1); target1 = 4*lp1, target2 = 2*lp2
lv = LatentVariation(
    [Uniform(0.0, 1.0), Uniform(0.0, 1.0)],
    XMLPath[XMLPath(["k1"]), XMLPath(["k2"])],
    Function[lp -> 4.0 * lp[1], lp -> 2.0 * lp[2]],
    ["lp1", "lp2"],
    Symbol[:config, :config];
    target_names=["rate k1", "rate k2"],
    inverse_maps=Function[tv -> tv[1] / 4.0, tv -> tv[2] / 2.0]
)
```

- **2 latent dims, 2 targets** — coupled targets (e.g. p1 = lp1, p2 = lp1 + lp2):
```julia
lv = LatentVariation(
    [Uniform(0.0, 1.0), Uniform(0.0, 1.0)],
    XMLPath[XMLPath(["p1"]), XMLPath(["p2"])],
    Function[lp -> lp[1], lp -> lp[1] + lp[2]],
    ["lp1", "lp2"],
    Symbol[:config, :config];
    target_names=["p1", "p2"],
    inverse_maps=Function[tv -> tv[1], tv -> tv[2] - tv[1]]
)
```

## Direct construction with discrete latent parameters

```julia
# Discrete index maps to named configurations
lv = LatentVariation(
    [[1.0, 2.0, 3.0]],
    XMLPath[XMLPath(["scenario"])],
    Function[lp -> lp[1]],
    ["scenario_index"],
    Symbol[:config]
)
```
"""
struct LatentVariation{T<:Union{Vector{<:Real},<:Distribution}} <: AbstractVariation
    latent_parameters::Vector{T}
    latent_parameter_names::Vector{String}
    locations::Vector{Symbol}
    targets::Vector{XMLPath}
    target_names::Vector{String}
    maps::Vector{<:Function}
    inverse_maps::Union{Nothing,Vector{Function}}
    types::Vector{DataType}
    name::String

    function LatentVariation(latent_parameters::Vector{<:Vector{T}}, targets::AbstractVector{XMLPath}, maps::Vector{<:Function}, lp_names::AbstractVector{<:AbstractString}, locations::AbstractVector{Symbol}; target_names::Union{Nothing,AbstractVector{<:AbstractString}}=nothing, inverse_maps::Union{Nothing,AbstractVector{<:Function}}=nothing, name::Union{Nothing,AbstractString}=nothing) where T<:Real
        @assert length(targets) == length(maps) "LatentVariation requires the number of targets and maps to be the same. Found $(length(targets)) and $(length(maps)), respectively."
        @assert length(targets) == length(locations) "LatentVariation requires the number of targets and locations to be the same. Found $(length(targets)) and $(length(locations)), respectively."
        if !isnothing(target_names)
            @assert length(target_names) == length(targets) "target_names length ($(length(target_names))) must equal targets length ($(length(targets)))."
        end
        inv = isnothing(inverse_maps) ? nothing : Vector{Function}(inverse_maps)
        if !isnothing(inv)
            @assert length(inv) == length(latent_parameters) "inverse_maps must have one entry per latent dimension ($(length(latent_parameters))). Got $(length(inv))."
        end
        types = map(maps) do fn
            sample_input = [lp[1] for lp in latent_parameters]
            sample_output = fn(sample_input)
            eltype(sample_output)
        end
        tnames = isnothing(target_names) ? shortVariationName.(locations, columnName.(targets)) : Vector{String}(target_names)
        default_name = join(shortVariationName.(locations, columnName.(targets)), " | ")
        variation_name = isnothing(name) ? default_name : String(name)
        return new{Vector{T}}(latent_parameters, lp_names, locations, targets, tnames, maps, inv, types, variation_name)
    end

    function LatentVariation(latent_parameters::Vector{T}, targets::AbstractVector{XMLPath}, maps::Vector{<:Function}, lp_names::AbstractVector{<:AbstractString}, locations::AbstractVector{Symbol}; target_names::Union{Nothing,AbstractVector{<:AbstractString}}=nothing, inverse_maps::Union{Nothing,AbstractVector{<:Function}}=nothing, name::Union{Nothing,AbstractString}=nothing) where T<:Distribution
        @assert length(targets) == length(maps) "LatentVariation requires the number of targets and maps to be the same. Found $(length(targets)) and $(length(maps)), respectively."
        @assert length(targets) == length(locations) "LatentVariation requires the number of targets and locations to be the same. Found $(length(targets)) and $(length(locations)), respectively."
        if !isnothing(target_names)
            @assert length(target_names) == length(targets) "target_names length ($(length(target_names))) must equal targets length ($(length(targets)))."
        end
        inv = isnothing(inverse_maps) ? nothing : Vector{Function}(inverse_maps)
        if !isnothing(inv)
            @assert length(inv) == length(latent_parameters) "inverse_maps must have one entry per latent dimension ($(length(latent_parameters))). Got $(length(inv))."
        end
        types = map(maps) do fn
            sample_input = [quantile(lp, 0.5) for lp in latent_parameters]
            sample_output = fn(sample_input)
            eltype(sample_output)
        end
        tnames = isnothing(target_names) ? shortVariationName.(locations, columnName.(targets)) : Vector{String}(target_names)
        default_name = join(shortVariationName.(locations, columnName.(targets)), " | ")
        variation_name = isnothing(name) ? default_name : String(name)
        lv = new{T}(latent_parameters, lp_names, locations, targets, tnames, maps, inv, types, variation_name)
        isnothing(inv) || _validateInverseMaps(lv)
        return lv
    end
end

"""
    defaultLatentParameterNames(latent_parameters::Vector, targets::Vector{XMLPath})

Generate default names for latent parameters based on target column names.

For each latent parameter, the name is constructed as:
`"<target_1> | <target_2> | ... | lp#<i>"` where `<target_n>` is the column name of the n-th target parameter and `<i>` is the index of the latent parameter.

# Returns
- `Vector{String}`: A vector of default names for the latent parameters.
"""
function defaultLatentParameterNames(latent_parameters::Vector, targets::Vector{XMLPath})
    par_names = join(columnName.(targets), " | ")
    return [par_names * " | lp#$(i)" for i in 1:length(latent_parameters)]
end

"""
    _validateInverseMaps(lv::LatentVariation{<:Distribution}; n_samples=20, rtol=1e-6)

Check that `lv.inverse_maps` are consistent with `lv.maps` via two round-trip tests.

**Forward-then-inverse** (`u → lp → target_vals → lp′`): for `n_samples` draws of `u ∈ (0,1)^n`,
compute latent and target values via the forward maps, then recover latent parameter values via the
inverse maps. Verifies `lp′ ≈ lp_vals` and that `cdf(dist_i, lp′_i) ∈ (0,1)`.

**Inverse-then-forward** (`lp → target_vals → lp′ → target_vals′`): using the same draws,
forward-maps `lp′` back to target values and verifies `target_vals′ ≈ target_vals`.

Returns `nothing` on success. Throws `ArgumentError` on the first failure with details.
Returns immediately (no-op) if `lv.inverse_maps` is `nothing`.

# Arguments
- `n_samples`: Number of random `u` draws to test (default 20).
- `rtol`: Relative tolerance for `isapprox` (default 1e-6).

# Example
```julia
lv = LatentVariation([Normal(0,1)], [path], [lp -> exp(lp[1])], ["log_rate"], [:cell];
                     inverse_maps=[tv -> log(tv[1])])
ModelManager._validateInverseMaps(lv)  # passes silently
```
"""
function _validateInverseMaps(lv::LatentVariation{<:Distribution};
                               n_samples::Int=20, rtol::Real=1e-6)
    isnothing(lv.inverse_maps) && return nothing
    n = nLatentDims(lv)
    for s in 1:n_samples
        u = rand(n)
        lp_vals = [quantile(d, u_i) for (d, u_i) in zip(lv.latent_parameters, u)]
        target_vals = Float64[fn(lp_vals) for fn in lv.maps]
        lp′ = [inv_map(target_vals) for inv_map in lv.inverse_maps]

        # Check that cdf(dist_i, lp′_i) ∈ (0,1) (lp′ is in distribution support)
        for (i, (d, lp_i)) in enumerate(zip(lv.latent_parameters, lp′))
            u_i = cdf(d, lp_i)
            if !(0 < u_i < 1)
                throw(ArgumentError(
                    "_validateInverseMaps: cdf(dist_$(i), inverse_maps[$(i)](target_vals)) = $(u_i) " *
                    "for target_vals=$(target_vals), which is outside (0,1). " *
                    "Inverse maps must return latent parameter values in the distribution support."))
            end
        end

        # Check lp′ ≈ lp_vals
        if !isapprox(lp′, lp_vals; rtol=rtol)
            throw(ArgumentError(
                "_validateInverseMaps: forward-then-inverse round-trip failed at sample $(s). " *
                "lp_vals=$(lp_vals), target_vals=$(target_vals), inv_maps(target_vals)=$(lp′). " *
                "Max relative error: $(maximum(abs.(lp′ .- lp_vals) ./ max.(1.0, abs.(lp_vals))))."))
        end

        # Check forward(lp′) ≈ target_vals
        target_vals′ = Float64[fn(lp′) for fn in lv.maps]
        if !isapprox(target_vals′, target_vals; rtol=rtol)
            throw(ArgumentError(
                "_validateInverseMaps: inverse-then-forward round-trip failed at sample $(s). " *
                "target_vals=$(target_vals), lp′=$(lp′), forward(lp′)=$(target_vals′). " *
                "Max relative error: $(maximum(abs.(target_vals′ .- target_vals) ./ max.(1.0, abs.(target_vals))))."))
        end
    end
    return nothing
end

function LatentVariation(dv::T; name::Union{Nothing,AbstractString}=nothing) where T<:DiscreteVariation
    latent_parameters = [dv.values]
    targets = [variationTarget(dv)]
    locations = [variationLocation(dv)]
    maps = [first]
    resolved_name = isnothing(name) ? variationName(dv) : String(name)
    tnames = [variationName(dv)]
    return LatentVariation(latent_parameters, targets, maps, [resolved_name], locations; target_names=tnames, name=resolved_name)
end

function LatentVariation(dv::T; name::Union{Nothing,AbstractString}=nothing) where T<:DistributedVariation
    latent_parameters = [Uniform(0,1)]
    targets = [variationTarget(dv)]
    locations = [variationLocation(dv)]
    maps = [dv.flip ? us -> quantile(dv.distribution, 1 - us[1]) : us -> quantile(dv.distribution, us[1])]
    inverse_maps = [dv.flip ? tv -> 1 - cdf(dv.distribution, tv[1]) : tv -> cdf(dv.distribution, tv[1])]
    resolved_name = isnothing(name) ? variationName(dv) : String(name)
    tnames = [variationName(dv)]
    return LatentVariation(latent_parameters, targets, maps, [resolved_name], locations; target_names=tnames, inverse_maps=inverse_maps, name=resolved_name)
end

function LatentVariation(cv::CoVariation{T}; name::Union{Nothing,AbstractString}=nothing) where T<:DiscreteVariation
    latent_parameters = [collect(1:length(cv))]
    targets = variationTarget(cv)
    locations = variationLocation(cv)
    maps = [I -> variation.values[I[1]] for variation in cv.variations]
    resolved_name = isnothing(name) ? variationName(cv) : String(name)
    tnames = [variationName(v) for v in cv.variations]
    return LatentVariation(latent_parameters, targets, maps, [resolved_name], locations; target_names=tnames, name=resolved_name)
end

function LatentVariation(cv::CoVariation{T}; name::Union{Nothing,AbstractString}=nothing) where T<:DistributedVariation
    latent_parameters = [Uniform(0.0, 1.0)]
    targets = variationTarget(cv)
    locations = variationLocation(cv)
    maps = map(cv.variations) do dv
        dv.flip ? us -> quantile(dv.distribution, 1 - us[1]) : us -> quantile(dv.distribution, us[1])
    end
    dv1 = cv.variations[1]
    # Recover u from first target; return NaN if remaining targets are inconsistent with u.
    inverse_maps = [tv -> begin
        u = dv1.flip ? 1 - cdf(dv1.distribution, tv[1]) : cdf(dv1.distribution, tv[1])
        for i in 2:length(cv.variations)
            dv_i  = cv.variations[i]
            exp_i = dv_i.flip ? quantile(dv_i.distribution, 1 - u) : quantile(dv_i.distribution, u)
            abs(exp_i - tv[i]) > 1e-8 * max(1.0, abs(exp_i)) && return NaN
        end
        u
    end]
    resolved_name = isnothing(name) ? variationName(cv) : String(name)
    tnames = [variationName(v) for v in cv.variations]
    return LatentVariation(latent_parameters, targets, maps, [resolved_name], locations; target_names=tnames, inverse_maps=inverse_maps, name=resolved_name)
end

LatentVariation(lv::LatentVariation) = lv

variationName(lv::LatentVariation) = lv.name

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

    println(io, indent, "Name: $(variationName(lv))")
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
    for (n, tname, loc, tar) in zip(all_target_nums, lv.target_names, variationLocation(lv), variationTarget(lv))
        println(io, indent, indent, lpad(n, biggest_width), " $(tname)")
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

"""
    AddGridVariationsResult <: AddVariationsResult

Result of [`addVariations`](@ref) with [`GridVariation`](@ref): the full factorial grid.

# Fields
- `variation_ids::AbstractArray{VariationID}`: One [`VariationID`](@ref) per grid point,
  i.e. per combination of the discrete variation values. The array's shape mirrors the grid
  axes (one dimension per varied parameter).
"""
struct AddGridVariationsResult <: AddVariationsResult
    variation_ids::AbstractArray{VariationID}
end

"""
    AddLHSVariationsResult <: AddVariationsResult

Result of [`addVariations`](@ref) with [`LHSVariation`](@ref) (Latin Hypercube Sampling).

# Fields
- `cdfs::Matrix{Float64}`: The sampled CDF coordinates in `[0, 1]`, one row per latent
  dimension and one column per sample point (shape `(d, n)`).
- `variation_ids::Vector{VariationID}`: One [`VariationID`](@ref) per sample point, in the
  same order as the columns of `cdfs`.
"""
struct AddLHSVariationsResult <: AddVariationsResult
    cdfs::Matrix{Float64}
    variation_ids::Vector{VariationID}
end

"""
    AddSobolVariationsResult <: AddVariationsResult

Result of [`addVariations`](@ref) with [`SobolVariation`](@ref) (Sobol quasi-random sequence).

# Fields
- `cdfs::Array{Float64,3}`: The Sobol CDF coordinates in `[0, 1]`, indexed by latent
  dimension, sample, and design matrix.
- `variation_ids::AbstractArray{VariationID}`: One [`VariationID`](@ref) per sample,
  arranged with one row per sample and one column per design matrix (shape `(n, n_matrices)`).
"""
struct AddSobolVariationsResult <: AddVariationsResult
    cdfs::Array{Float64,3}
    variation_ids::AbstractArray{VariationID}
end

"""
    AddRBDVariationsResult <: AddVariationsResult

Result of [`addVariations`](@ref) with [`RBDVariation`](@ref) (Random Balance Design).

# Fields
- `variation_ids::AbstractArray{VariationID}`: One [`VariationID`](@ref) per sampled point,
  in CDF-sample order.
- `variation_matrix::Matrix{VariationID}`: The same IDs re-sorted into the RBD layout — one
  column per latent parameter, rows ordered along each parameter's periodic RBD curve. This
  is the form consumed by the RBD-FAST spectral analysis.
"""
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
    return addVariationRows(inputs, reference_variation_id, loc_dicts) |> AddGridVariationsResult
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
    return addVariationRows(inputs, reference_variation_id, loc_dicts)
end

################## Database Helper Functions ##################

"""
    validateParsBytes(db::SQLite.DB, table_name::String)

Assert that the `par_key` blob in every row of `table_name` matches the float64
reinterpretation of the other columns.
"""
function validateParsBytes(db::SQLite.DB, table_name::String)
    df = queryToDataFrame("SELECT * FROM $table_name;", db=db)
    @assert names(df)[1] == tableIDName(table_name) "$(table_name) does not have the primary key as the first column."
    @assert names(df)[2] == "par_key" "$(table_name) does not have par_key as the second column."
    for row in eachrow(df)
        par_key = row[:par_key]
        vals = [row[3:end]...]
        vals[vals .== "true"] .= 1.0
        vals[vals .== "false"] .= 0.0
        expected_par_key = reinterpret(UInt8, Vector{Float64}(vals))
        @assert par_key == expected_par_key """
        par_key does not match the expected values for $(table_name) ID $(row[1]).
        Expected: $(expected_par_key)
        Found: $(par_key)
        """
    end
end

"""
    ColumnSetup

A struct to hold the setup for the columns in a variations database.

# Fields
- `db::SQLite.DB`: The database connection to the variations database.
- `table::String`: The name of the table in the database.
- `variation_id_name::String`: The name of the variation ID column in the table.
- `ordered_inds::Vector{Int}`: Indexes into the concatenated static and varied values to get the parameters in the order of the table columns (excluding the variation ID and par_key columns).
- `static_values_db::Vector{String}`: The static values as strings for DB insertion.
- `static_values_key::Vector{Float64}`: The static values as floats for the par_key hash.
- `feature_str::String`: The string representation of the features (columns) in the table.
- `types::Vector{DataType}`: The data types of the columns in the table.
- `placeholders::String`: The string representation of the placeholders for the values in the table.
- `stmt_insert::SQLite.Stmt`: The prepared statement for inserting new rows into the table.
- `stmt_select::SQLite.Stmt`: The prepared statement for selecting existing rows from the table.
"""
struct ColumnSetup
    db::SQLite.DB
    table::String
    variation_id_name::String
    ordered_inds::Vector{Int}
    static_values_db::Vector{String}
    static_values_key::Vector{Float64}
    feature_str::String
    types::Vector{DataType}
    placeholders::String
    stmt_insert::SQLite.Stmt
    stmt_select::SQLite.Stmt
end

"""
    addVariationRow(column_setup::ColumnSetup, varied_values::Vector{<:Real})

Add a new row to the location variations database using the prepared statement.
If the row already exists, it returns the existing variation ID.
"""
function addVariationRow(column_setup::ColumnSetup, varied_values::AbstractVector{<:Real})
    db_varied_values = [t == Bool ? v == 1.0 : v for (t, v) in zip(column_setup.types, varied_values)] .|> string
    db_pars = [column_setup.static_values_db; db_varied_values]
    pars_for_key = [column_setup.static_values_key; varied_values] |> Vector{Float64}

    par_key = reinterpret(UInt8, pars_for_key[column_setup.ordered_inds])
    params = Tuple([db_pars; [par_key]])
    new_id = stmtToDataFrame(column_setup.stmt_insert, params) |> x -> x[!, 1]

    new_added = length(new_id) == 1
    if !new_added
        df = stmtToDataFrame(column_setup.stmt_select, params; is_row=true)
        new_id = df[!, 1]
    end
    @debug validateParsBytes(column_setup.db, column_setup.table)
    return new_id[1]
end

"""
    getColumnDefaults(location::Symbol, folder_id::Int, loc_targets::Vector{XMLPath})
    getColumnDefaults(::AbstractSimulator, location::Symbol, folder_id::Int, loc_targets::Vector{XMLPath})

Return the default values (as strings) for `loc_targets` columns when they are first added
to the variation database for `location`/`folder_id`. Called by [`addColumns`](@ref).

Default implementation reads the base XML file for the location and extracts values via
[`getSimpleContent`](@ref). Simulator packages may override for non-XML variation sources.
"""
getColumnDefaults(location::Symbol, folder_id::Int, loc_targets::Vector{XMLPath}) =
    getColumnDefaults(simulator(), location, folder_id, loc_targets)
function getColumnDefaults(::AbstractSimulator, location::Symbol, folder_id::Int, loc_targets::Vector{XMLPath})
    folder = inputFolderName(location, folder_id)
    basenames = inputsDict()[location]["basename"]
    basenames = basenames isa Vector ? basenames : [basenames]
    basename_is_varied = inputsDict()[location]["varied"] .&& ([splitext(bn)[2] .== ".xml" for bn in basenames])
    basename_ind = findall(basename_is_varied .&& isfile.([joinpath(locationPath(location, folder), bn) for bn in basenames]))
    @assert !isnothing(basename_ind) "Folder $(folder) does not contain a valid $(location) file to support variations. The options are $(basenames[basename_is_varied])."
    @assert length(basename_ind) == 1 "Folder $(folder) contains multiple valid $(location) files to support variations. The options are $(basenames[basename_is_varied])."
    path_to_xml = joinpath(locationPath(location, folder), basenames[basename_ind[1]])
    xml_doc = parse_file(path_to_xml)
    default_values = [getSimpleContent(xml_doc, xp.xml_path) for xp in loc_targets]
    free(xml_doc)
    return default_values
end

"""
    addColumns(location::Symbol, folder_id::Int, loc_types::Vector{DataType}, loc_targets::Vector{XMLPath})

Add columns to the variations database for the given location and folder_id.
"""
function addColumns(location::Symbol, folder_id::Int, loc_types::Vector{DataType}, loc_targets::Vector{XMLPath})
    folder = inputFolderName(location, folder_id)
    db_columns = locationVariationsDatabase(location, folder)

    table_name = locationVariationsTableName(location)

    @debug validateParsBytes(db_columns, table_name)

    id_column_name = locationVariationIDName(location)
    prev_par_column_names = tableColumns(table_name; db=db_columns)
    filter!(x -> !(x in (id_column_name, "par_key")), prev_par_column_names)
    varied_par_column_names = [columnName(xp.xml_path) for xp in loc_targets]

    is_new_column = [!(varied_column_name in prev_par_column_names) for varied_column_name in varied_par_column_names]
    if any(is_new_column)
        new_column_names = varied_par_column_names[is_new_column]
        new_column_data_types = loc_types[is_new_column] .|> sqliteDataType
        default_values_for_new = getColumnDefaults(location, folder_id, loc_targets[is_new_column])
        for (new_column_name, data_type) in zip(new_column_names, new_column_data_types)
            DBInterface.execute(db_columns, "ALTER TABLE $(table_name) ADD COLUMN '$(new_column_name)' $(data_type);")
        end

        columns = join("\"" .* new_column_names .* "\"", ",")
        placeholders = join(["?" for _ in new_column_names], ",")
        query = "UPDATE $table_name SET ($columns) = ($placeholders);"
        stmt = SQLite.Stmt(db_columns, query)
        DBInterface.execute(stmt, Tuple(default_values_for_new))

        select_query = constructSelectQuery(table_name; selection="$(tableIDName(table_name)), par_key")
        par_key_df = queryToDataFrame(select_query; db=db_columns)

        default_values_for_new[default_values_for_new.=="true"] .= "1"
        default_values_for_new[default_values_for_new.=="false"] .= "0"

        new_bytes = reinterpret(UInt8, parse.(Float64, default_values_for_new))
        for row in eachrow(par_key_df)
            id = row[1]
            par_key = row[2]
            append!(par_key, new_bytes)
            DBInterface.execute(db_columns, "UPDATE $table_name SET par_key = ? WHERE $(tableIDName(table_name)) = ?;", (par_key, id))
        end
    end

    @debug validateParsBytes(db_columns, table_name)

    static_par_column_names = deepcopy(prev_par_column_names)
    previously_varied_names = varied_par_column_names[.!is_new_column]
    filter!(x -> !(x in previously_varied_names), static_par_column_names)

    return static_par_column_names, varied_par_column_names
end

"""
    setUpColumns(location::Symbol, folder_id::Int, loc_types::Vector{DataType}, loc_targets::Vector{XMLPath}, reference_variation_id::Int)

Set up the columns for the variations database for the given location and folder_id.
"""
function setUpColumns(location::Symbol, folder_id::Int, loc_types::Vector{DataType}, loc_targets::Vector{XMLPath}, reference_variation_id::Int)
    static_par_column_names, varied_par_column_names = addColumns(location, folder_id, loc_types, loc_targets)
    db_columns = locationVariationsDatabase(location, folder_id)
    table_name = locationVariationsTableName(location)
    variation_id_name = locationVariationIDName(location)

    if isempty(static_par_column_names)
        static_values_db = String[]
        static_values_key = Float64[]
        table_features = String[]
    else
        query = constructSelectQuery(table_name, "WHERE $(variation_id_name)=$(reference_variation_id);"; selection=join("\"" .* static_par_column_names .* "\"", ", "))
        static_values = queryToDataFrame(query; db=db_columns, is_row=true) |> x -> [c[1] for c in eachcol(x)]
        static_values_db = string.(static_values) |> Vector{String}
        static_values_key = copy(static_values)
        static_values_key[static_values_key.=="true"] .= 1.0
        static_values_key[static_values_key.=="false"] .= 0.0
        static_values_key = Vector{Float64}(static_values_key)
        table_features = copy(static_par_column_names)
    end
    append!(table_features, varied_par_column_names)

    feature_str = join("\"" .* table_features .* "\"", ",") * ",par_key"
    placeholders = join(["?" for _ in table_features], ",") * ",?"

    stmt_insert = SQLite.Stmt(db_columns, "INSERT OR IGNORE INTO $(table_name) ($(feature_str)) VALUES($placeholders) RETURNING $(variation_id_name);")
    where_str = "WHERE ($(feature_str))=($(placeholders))"
    stmt_str = constructSelectQuery(table_name, where_str; selection=variation_id_name)
    stmt_select = SQLite.Stmt(db_columns, stmt_str)

    column_to_full_index = Dict{String,Int}()
    for (ind, col_name) in enumerate(table_features)
        column_to_full_index[col_name] = ind
    end
    param_column_names = tableColumns(table_name; db=db_columns)
    filter!(x -> !(x in (variation_id_name, "par_key")), param_column_names)
    ordered_inds = [column_to_full_index[col_name] for col_name in param_column_names]

    return ColumnSetup(db_columns, table_name, variation_id_name, ordered_inds, static_values_db, static_values_key, feature_str, loc_types, placeholders, stmt_insert, stmt_select)
end

"""
    addVariationRows(inputs::InputFolders, reference_variation_id::VariationID, loc_dicts::Dict)

Add new rows to the per-location variation databases and return the resulting variation IDs.

`loc_dicts` maps each varied location symbol to a 3-tuple
`(values_matrix, types, targets)` where `values_matrix` is a `#targets × #samples`
numeric matrix.

Called by [`addVariations`](@ref) (Grid, LHS, Sobol, RBD) and [`addCDFVariations`](@ref)
after the generic sampling logic computes the parameter values.
"""
function addVariationRows(inputs::InputFolders, reference_variation_id::VariationID, loc_dicts::Dict)
    location_variation_ids = Dict{Symbol, Vector{Int}}()
    for (loc, (loc_vals, loc_types, loc_targets)) in pairs(loc_dicts)
        column_setup = setUpColumns(loc, inputs[loc].id, loc_types, loc_targets, reference_variation_id[loc])
        location_variation_ids[loc] = [addVariationRow(column_setup, c) for c in eachcol(loc_vals)]
    end
    n_par_vecs = length(first(values(location_variation_ids)))
    for loc in projectLocations().varied
        get!(location_variation_ids, loc, fill(reference_variation_id[loc], n_par_vecs))
    end
    return [([loc => location_variation_ids[loc][i] for loc in projectLocations().varied] |> VariationID) for i in 1:n_par_vecs]
end

################## Parameter Value Utilities ##################

"""
    parseValueFromString(v::String)

Parse a string value: return `Bool` for `"true"`/`"false"`, `Float64` if numeric, or the
original string otherwise.
"""
function parseValueFromString(v::String)
    if v ∈ ("true", "false")
        return v == "true"
    elseif tryparse(Float64, v) |> !isnothing
        return parse(Float64, v)
    end
    return v
end

"""
    getParameterValue(M::AbstractMonad, location::Symbol, xp::XMLPath)

Get the parameter value for `xp` at `location` from the monad's variations database if
the column exists, otherwise fall back to the base XML file.

- Boolean strings (`"true"` / `"false"`) are returned as `Bool`.
- Numeric strings are returned as `Float64`.
- Everything else is returned as-is.
"""
function getParameterValue(M::AbstractMonad, location::Symbol, xp::XMLPath)
    db = locationVariationsDatabase(location, M)
    @assert !isnothing(db) "XMLPath $(xp.xml_path) corresponds to location $(location), but that location is not being varied in this $(nameof(typeof(M)))."
    @assert !ismissing(db) "Variations database for location $(location) not found in folder $(M.inputs[location].folder)."
    if columnsExist([columnName(xp)], locationVariationsTableName(location); db=db)
        query = constructSelectQuery(locationVariationsTableName(location), "WHERE $(locationVariationIDName(location))=$(M.variation_id[location])"; selection="\"" * columnName(xp) * "\"")
        df = queryToDataFrame(query; db=db, is_row=true)
        v = df[1, columnName(xp)]
        if v ∈ ("true", "false")
            return v == "true"
        end
        return v
    else
        path_to_xml = prepareBaseFile(M.inputs[location])
        xml_doc = parse_file(path_to_xml)
        v = getSimpleContent(xml_doc, xp.xml_path)
        free(xml_doc)
        return parseValueFromString(v)
    end
end

################## getAllParameterValues ##################

"""
    getAllParameterValues(simulation_id::Int)
    getAllParameterValues(S::AbstractSampling)

Get all parameter values for the given simulation, monad, or sampling as a DataFrame.
Simulation ID can also be passed directly as an integer.

# Identifying attributes
If sibling elements have identical tags, attributes are programmatically searched to find one that can be used to identify them.
Priority is given to "name", "ID", and "id" attributes.
If sibling elements cannot be uniquely identified by an attribute, artificial IDs will be added to the XML paths to ensure uniqueness for the column names.
These will show up as `<tag>:temp_id:<index>` in the column names.
Search for them with `contains(col_name, ":temp_id:")`.
Note: these are not added to the XML files themselves.
Users must manually insert such artificial IDs into their XML files to use PCMM to vary those parameters.

# Converting column names into XML paths
To convert the column names in the returned DataFrame back into XML paths, split the column names by '/':

```julia
df = getAllParameterValues(simulation_id)
col1 = names(df)[1]
xml_path = split(col1, '/')
```

Alternatively, [`columnNameToXMLPath`](@ref) can be used.

```julia
xml_path = columnNameToXMLPath(col1)
```
"""
function getAllParameterValues(S::Sampling)
    monad_ids = monadIDs(S)
    dfs = [getAllParameterValues(Monad(monad_id)) for monad_id in monad_ids]
    df = vcat(dfs...)
    df.monad_id = monad_ids
    return df
end

function getAllParameterValues(M::AbstractMonad)
    D = Dict{String,Any}()
    for (loc, input_folder) in pairs(M.inputs.input_folders)
        if !input_folder.varied
            continue
        end

        if isempty(input_folder.folder)
            continue
        end

        path_to_xml = createXMLFile(loc, M)
        xml_doc = parse_file(path_to_xml)
        xml_root = root(xml_doc)
        current_path = String[]

        recurseToGetParameterValues!(D, current_path, xml_root)
        free(xml_doc)
    end
    return DataFrame(D)
end

function getAllParameterValues(simulation_id::Int)
    simulation = Simulation(simulation_id)
    return getAllParameterValues(simulation)
end

"""
    recurseToGetParameterValues!(D::Dict{String,Any}, current_path::Vector{String}, element::XMLElement)

Recursively traverse the XML element tree to extract parameter values into `D`.
Used by [`getAllParameterValues`](@ref).
"""
function recurseToGetParameterValues!(D::Dict{String,Any}, current_path::Vector{String}, element::XMLElement)
    if elementIsTerminal(element)
        v = content(element)
        key = columnName(XMLPath(current_path))
        D[key] = parseValueFromString(v)
        return
    end
    child_tags = [name(c) for c in child_elements(element)]
    priority_attributes = ("name", "ID", "id")
    for tag in unique(child_tags)
        these_children = [c for c in child_elements(element) if name(c) == tag]
        common_attributes = intersect([collect(attributes_dict(c) |> keys) for c in these_children]...)
        if length(these_children) == 1
            priority_attribute_found = false
            for attr in priority_attributes
                if attr in common_attributes
                    priority_attribute_found = true
                    recurseToGetParameterValues!(D, [current_path; "$tag:$attr:$(attribute(these_children[1], attr))"], these_children[1])
                    break
                end
            end
            if !priority_attribute_found
                recurseToGetParameterValues!(D, [current_path; tag], these_children[1])
            end
            continue
        end
        unique_attribute = nothing
        for attr in priority_attributes
            if !(attr in common_attributes)
                continue
            end
            attr_values = [attribute(c, attr) for c in these_children]
            if length(unique(attr_values)) == length(these_children)
                unique_attribute = attr
                break
            end
        end
        if isnothing(unique_attribute)
            for attr in common_attributes
                attr_values = [attribute(c, attr) for c in these_children]
                if length(unique(attr_values)) == length(these_children)
                    unique_attribute = attr
                    break
                end
            end
        end
        if isnothing(unique_attribute)
            @warn "Could not find unique attribute to distinguish between multiple children with tag $(tag) under path $(columnName(current_path)). Adding artificial IDs to make unique keys."
            for (i, c) in enumerate(these_children)
                recurseToGetParameterValues!(D, [current_path; "$tag:temp_id:$i"], c)
            end
        else
            for c in these_children
                recurseToGetParameterValues!(D, [current_path; "$tag:$unique_attribute:$(attribute(c, unique_attribute))"], c)
            end
        end
    end
end
