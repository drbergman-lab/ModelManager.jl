export CalibrationParameter

################## Source types ##################

"""
    DVSource <: AbstractCalibrationSource

Tracks that a [`CalibrationParameter`](@ref) originated from a [`DistributedVariation`](@ref).
Stored for display-format CSV reconstruction and JLD2 persistence.
"""
struct DVSource
    dv::DistributedVariation
end

"""
    CVSource <: AbstractCalibrationSource

Tracks that a [`CalibrationParameter`](@ref) originated from a
[`CoVariation{DistributedVariation}`](@ref).
Stored for display-format CSV reconstruction and JLD2 persistence.
"""
struct CVSource
    cv::CoVariation{DistributedVariation}
end

"""
    LVSource <: AbstractCalibrationSource

Tracks that a [`CalibrationParameter`](@ref) originated from a user-supplied
[`LatentVariation{<:Distribution}`](@ref).
Stored for display-format CSV reconstruction and JLD2 persistence.
"""
struct LVSource
    lv::LatentVariation{<:Distribution}
end

const AbstractCalibrationSource = Union{DVSource, CVSource, LVSource}

################## CalibrationParameter ##################

"""
    CalibrationParameter

Internal type pairing an `AbstractCalibrationSource` (the original user-supplied variation)
with the derived `LatentVariation{<:Distribution}` used by the ABC-SMC algorithm.

`CalibrationParameter` objects are stored in a [`CalibrationProblem`](@ref) and are
passed through the calibration loop. The `source` is used only for:
- Writing human-readable display CSVs with interpretable target parameter values.
- Serializing to `problem.jld2` via JLD2 for [`resumeABC`](@ref) without re-supplying
  the original problem.

Users never construct `CalibrationParameter` directly — it is created automatically when
building a [`CalibrationProblem`](@ref) from `DistributedVariation`,
`CoVariation{DistributedVariation}`, or `LatentVariation{<:Distribution}` arguments.

# Fields
- `source::Union{DVSource,CVSource,LVSource}`: The original variation type for provenance.
- `lv::LatentVariation{<:Distribution}`: The derived latent variation used internally
  by the ABC-SMC loop.
"""
struct CalibrationParameter
    source::AbstractCalibrationSource
    lv::LatentVariation{<:Distribution}
end

################## Conversion ##################

"""
    _toCalibrationParameter(av::AbstractVariation) → CalibrationParameter

Convert a user-supplied variation to a [`CalibrationParameter`](@ref).

Accepted inputs:
- [`DistributedVariation`](@ref) → `DVSource`-wrapped parameter
- [`CoVariation{DistributedVariation}`](@ref) → `CVSource`-wrapped parameter
- [`LatentVariation{<:Distribution}`](@ref) → `LVSource`-wrapped parameter

Rejected inputs throw `ArgumentError`.
"""
function _toCalibrationParameter(dv::DistributedVariation)
    return CalibrationParameter(DVSource(dv), LatentVariation(dv))
end

function _toCalibrationParameter(cv::CoVariation{DistributedVariation})
    return CalibrationParameter(CVSource(cv), LatentVariation(cv))
end

function _toCalibrationParameter(lv::LatentVariation{<:Distribution})
    return CalibrationParameter(LVSource(lv), lv)
end

#! Why a reason-returning function rather than throwing directly: `CalibrationProblem` converts its
#! parameters in a comprehension, so a throwing converter reports only the *first* offender. A user
#! with eight variations, two of them unusable, learns about one per run. The throwing methods below
#! are one-liners over this, so a direct `_toCalibrationParameter` call still raises the same message.
"""
    _calibrationRejection(av::AbstractVariation) → Union{Nothing,String}

Return why `av` cannot be a calibration parameter, or `nothing` if it can.
"""
_calibrationRejection(::DistributedVariation) = nothing
_calibrationRejection(::CoVariation{DistributedVariation}) = nothing
_calibrationRejection(::LatentVariation{<:Distribution}) = nothing

_calibrationRejection(::DiscreteVariation) =
    "DiscreteVariation cannot be used as a calibration parameter. " *
    "Use DistributedVariation(location, xml_path, prior) instead."

_calibrationRejection(::CoVariation{<:DiscreteVariation}) =
    "CoVariation{DiscreteVariation} cannot be used as a calibration parameter. " *
    "Use CoVariation{DistributedVariation} instead."

_calibrationRejection(::LatentVariation) =
    "LatentVariation for ABC-SMC calibration must have Distribution latent parameters, " *
    "not discrete values. Use LatentVariation{<:Distribution}."

_calibrationRejection(av::AbstractVariation) =
    "Unsupported variation type for calibration: $(typeof(av))."

_toCalibrationParameter(av::DiscreteVariation) = throw(ArgumentError(_calibrationRejection(av)))
_toCalibrationParameter(av::CoVariation{<:DiscreteVariation}) = throw(ArgumentError(_calibrationRejection(av)))
_toCalibrationParameter(av::LatentVariation) = throw(ArgumentError(_calibrationRejection(av)))
_toCalibrationParameter(av::AbstractVariation) = throw(ArgumentError(_calibrationRejection(av)))

#! `variationName` covers ElementaryVariation, CoVariation and LatentVariation; anything else is by
#! definition an unsupported type, and naming it by type is the more useful message there anyway.
_variationLabel(av) = applicable(variationName, av) ? variationName(av) : string(typeof(av))

"""
    _toCalibrationParameters(parameters::AbstractVector) → Vector{CalibrationParameter}

Convert every element, reporting **all** unusable parameters in one error rather than the first.
"""
function _toCalibrationParameters(parameters::AbstractVector)
    rejected = Tuple{Int,String,String}[]
    for (i, av) in enumerate(parameters)
        reason = _calibrationRejection(av)
        isnothing(reason) || push!(rejected, (i, _variationLabel(av), reason))
    end
    if !isempty(rejected)
        lines = ["  [$(i)] $(name): $(reason)" for (i, name, reason) in rejected]
        throw(ArgumentError("""
        $(length(rejected)) of $(length(parameters)) parameters cannot be used for calibration:
        $(join(lines, "\n"))
        These are usable for sensitivity analysis, which accepts discrete variations; ABC-SMC needs a
        continuous prior for every parameter in order to weight and perturb particles.
        """))
    end
    return CalibrationParameter[_toCalibrationParameter(av) for av in parameters]
end

################## Display column helpers ##################

"""
    _displayColumns(cp::CalibrationParameter) → Vector{String}

Return the column names used in human-readable generation CSVs for this parameter.

- `DVSource`: one column — `variationName(dv)`, i.e. the user-supplied name (or its
  `shortVariationName` default). This is the friendly name, not the raw DB column.
- `CVSource`: one column per covaried target — `variationName(v)` for each individual
  `DistributedVariation` in the `CoVariation`.
- `LVSource`: latent parameter names (user-supplied, actual sampled values not CDFs)
  followed by `columnName.(lv.targets)` for the target columns.

The mapping from display names back to DB column names is written to `parameters.toml`
by `_writeParametersTOML`.
"""
_displayColumns(cp::CalibrationParameter) = _displayColumns(cp.source, cp.lv)

_displayColumns(s::DVSource, ::LatentVariation) =
    [variationName(s.dv)]

_displayColumns(s::CVSource, ::LatentVariation) =
    [variationName(v) for v in s.cv.variations]

_displayColumns(::LVSource, lv::LatentVariation) =
    [lv.latent_parameter_names..., lv.target_names...]

################## Distribution string representation ##################

"""
    _distString(d::Distribution) → String

Return a concise human-readable string representation of a distribution for use in
`parameters.toml`. Uses the type name and named field values (e.g.
`"Uniform(a=0.0, b=1.0)"`, `"Normal(μ=0.0, σ=1.0)"`). Not intended for eval/roundtrip.
"""
function _distString(d::Distribution)
    T = typeof(d)
    type_name = string(Base.nameof(T))
    fns = fieldnames(T)
    isempty(fns) && return type_name * "()"
    params = join(["$(fn)=$(getfield(d, fn))" for fn in fns], ", ")
    return "$(type_name)($(params))"
end

################## _StrippedLVSource — serializable substitute for LVSource ##################

"""
    _StrippedLVSource

Serializable substitute for `LVSource` used when the associated
[`LatentVariation`](@ref) contains anonymous-function maps that JLD2 cannot serialize.
Stores all data fields of the `LatentVariation` (distributions, names, targets, types)
but omits `maps` and `inverse_maps`. Saved by `_saveProblem` when anonymous functions
are detected; at resume time the user must re-supply the full `CalibrationProblem` and
the maps are validated against stored particle data.
"""
struct _StrippedLVSource
    latent_parameters::Vector  # elements: <:Distribution
    latent_parameter_names::Vector{String}
    locations::Vector{Symbol}
    targets::Vector{XMLPath}
    target_names::Vector{String}
    types::Vector{DataType}
    name::String
end

function _StrippedLVSource(lv::LatentVariation{<:Distribution})
    return _StrippedLVSource(lv.latent_parameters, lv.latent_parameter_names,
                             lv.locations, lv.targets, lv.target_names, lv.types, lv.name)
end
_StrippedLVSource(src::LVSource) = _StrippedLVSource(src.lv)

"""
    _isAnonymousFunction(f::Function) → Bool

Return `true` if `f` is an anonymous function or compiler-generated closure
(i.e. `nameof(f)` starts with `#`). Named functions defined with
`function foo(...) end` or `foo(...) = ...` return `false`.
"""
_isAnonymousFunction(f::Function) = startswith(string(nameof(f)), "#")

################## Row conversion: CDF coords → display values ##################

"""
    _particleRowToDisplay(cp::CalibrationParameter, cdf_vals::Vector{Float64}) → Vector{Float64}

Convert a row of CDF coordinates to human-readable display values.

- `DVSource` / `CVSource`: returns the actual target parameter value(s). The internal
  `LatentVariation` applies `quantile(prior, cdf)` (and the user's map) to obtain
  interpretable values.
- `LVSource`: returns the latent parameter samples — i.e., `quantile(D_i, cdf_i)` for
  each latent dimension — followed by the target parameter values.

The returned vector corresponds element-wise to `_displayColumns`.
"""
_particleRowToDisplay(cp::CalibrationParameter, cdf_vals::Vector{Float64}) =
    _particleRowToDisplay(cp.source, cp.lv, cdf_vals)

function _particleRowToDisplay(::DVSource, lv::LatentVariation, cdf_vals::Vector{Float64})
    return variationValues(lv, cdf_vals)
end

function _particleRowToDisplay(::CVSource, lv::LatentVariation, cdf_vals::Vector{Float64})
    return variationValues(lv, cdf_vals)
end

function _particleRowToDisplay(::LVSource, lv::LatentVariation, cdf_vals::Vector{Float64})
    lp_vals     = [quantile(d, cdf) for (d, cdf) in zip(lv.latent_parameters, cdf_vals)]
    target_vals = variationValues(lv, cdf_vals)
    return [lp_vals..., target_vals...]
end
