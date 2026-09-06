export CalibrationParameter

################## Source types ##################

"""
    AbstractCalibrationSource

Supertype of the records tracking which variation a [`CalibrationParameter`](@ref) came from.

A source exists so a particle can be reported in the user's own terms — display names, priors,
target values — rather than as the bare CDF coordinates the sampler works in.

Sources are serialised into `problem.jld2` so a run can resume. A source whose maps are derived
from data it already carries round-trips as itself; one holding user-supplied functions may not,
and overrides `_toManifestSource` to strip what JLD2 cannot store.
"""
abstract type AbstractCalibrationSource end

"""
    DVSource <: AbstractCalibrationSource

Tracks that a [`CalibrationParameter`](@ref) originated from a [`DistributedVariation`](@ref).
Stored for display-format CSV reconstruction and JLD2 persistence.
"""
struct DVSource <: AbstractCalibrationSource
    dv::DistributedVariation
end

"""
    CVSource <: AbstractCalibrationSource

Tracks that a [`CalibrationParameter`](@ref) originated from a
[`CoVariation{DistributedVariation}`](@ref).
Stored for display-format CSV reconstruction and JLD2 persistence.
"""
struct CVSource <: AbstractCalibrationSource
    cv::CoVariation{DistributedVariation}
end

"""
    LVSource <: AbstractCalibrationSource

Tracks that a [`CalibrationParameter`](@ref) originated from a user-supplied
[`LatentVariation{<:Distribution}`](@ref).
Stored for display-format CSV reconstruction and JLD2 persistence.
"""
struct LVSource <: AbstractCalibrationSource
    lv::LatentVariation{<:Distribution}
end

"""
    DiscreteSource <: AbstractCalibrationSource

Tracks that a [`CalibrationParameter`](@ref) originated from a [`DiscreteVariation`](@ref).
Stored for display-format CSV reconstruction and JLD2 persistence.
"""
struct DiscreteSource <: AbstractCalibrationSource
    dv::DiscreteVariation
end

"""
    DiscreteCoSource <: AbstractCalibrationSource

Tracks that a [`CalibrationParameter`](@ref) originated from a
[`CoVariation`](@ref) of [`DiscreteVariation`](@ref)s.
Stored for display-format CSV reconstruction and JLD2 persistence.
"""
struct DiscreteCoSource <: AbstractCalibrationSource
    cv::CoVariation{<:DiscreteVariation}
end

#! `DiscreteSource`/`DiscreteCoSource` are new types rather than a widening of `DVSource`/`CVSource`
#! to accept any `ElementaryVariation`. The sources are JLD2-serialised inside `_ProblemManifest`,
#! which stores the concrete type, so re-parameterising an existing one would stop older
#! `problem.jld2` files from loading as themselves and break resume. Adding types is compatible;
#! changing them is not. Gaining a supertype is also compatible — verified against a `problem.jld2`
#! written before these structs subtyped anything.

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

#! Discrete parameters are calibratable. They are represented as `DiscreteUniform` over their value
#! indices, so a particle coordinate stays a CDF value in [0,1] and the quantile does the quantising —
#! the perturbation kernels never see a target value and need no discrete counterpart. What a discrete
#! parameter costs is resolution, not correctness: the sampler explores within-bin variation that has
#! no effect on the simulation, which `cdf_grid_k` snapping and the `SimulationBank` already mitigate
#! by collapsing repeated grid points.
_calibrationRejection(::DiscreteVariation) = nothing
_calibrationRejection(::CoVariation{<:DiscreteVariation}) = nothing

#! Still rejected: a `LatentVariation` whose latent parameters are a raw value vector rather than a
#! distribution. `variationValues` treats that branch's latent values as *indices* in the CDF path,
#! which is a different convention from the one ABC-SMC needs. Build it from a `DiscreteVariation`
#! instead and the conversion happens for you.
_calibrationRejection(::LatentVariation) =
    "A LatentVariation for calibration must have Distribution latent parameters. Pass the " *
    "DiscreteVariation itself — it is converted to a DiscreteUniform over its value indices — or " *
    "construct the LatentVariation with Distribution latent parameters."

_calibrationRejection(av::AbstractVariation) =
    "Unsupported variation type for calibration: $(typeof(av))."

function _toCalibrationParameter(dv::DiscreteVariation)
    return CalibrationParameter(DiscreteSource(dv), LatentVariation(dv))
end

function _toCalibrationParameter(cv::CoVariation{<:DiscreteVariation})
    return CalibrationParameter(DiscreteCoSource(cv), LatentVariation(cv))
end
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

_displayColumns(s::DiscreteSource, ::LatentVariation) =
    [variationName(s.dv)]

_displayColumns(s::DiscreteCoSource, ::LatentVariation) =
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

#! This is JLD2's own test -- `T <: Function && isgensym(Symbol(T))` at
#! JLD2/src/data/writing_datatypes.jl:446, where it warns that it "only stores functions by name" --
#! spelled out rather than called, because `JLD2.isgensym` is internal and a one-line predicate is not
#! worth coupling to a private name; a change there then shows up as a behaviour difference, not a
#! load error. It asks about the *type*: a top-level function's singleton type prints as
#! `typeof(sq)`, a closure's as `var"#f#make##0"{Int64}` and a lambda's as `var"#12#13"`, both
#! carrying a `#`, while a callable struct's type is its own ordinary name. The earlier
#! `nameof`-prefix test asked about the function instead, and `nameof` of a closure defined as
#! `f(s) = k` inside `make(k)` is just `:f`.
"""
    _isAnonymousFunction(f::Function) → Bool

Whether `f` cannot be restored by name in a fresh Julia session -- which is what JLD2 needs to bring
a saved `CalibrationProblem` back, and the same test JLD2 itself applies before warning that it only
stores functions by name. `false` for a function defined at the top level of a module and for a
callable struct (JLD2 stores those as a type plus fields); `true` for a lambda *and* for a named
function defined inside another function, a `let` or a `@testset`, because those are closure types
whose names exist only in the session that compiled them.
"""
_isAnonymousFunction(f::Function) = occursin('#', string(typeof(f)))

#! A `QoI` is only as restorable as the two functions inside it, so it is anonymous if either is. Both
#! are checked: a named `compute` with an anonymous `reduce` would round-trip as a QoI that silently
#! averages instead of doing the monad-level step it was written for.
_isAnonymousFunction(q::QoI) = _isAnonymousFunction(q.compute) || _isAnonymousFunction(q.reduce)
_isAnonymousFunction(qs::AbstractVector{QoI}) = any(_isAnonymousFunction, qs)

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

#! The value, not the index: `variationValues` maps the CDF through the latent `DiscreteUniform` and
#! the forward map, so the display CSV carries what the model was actually run with.
function _particleRowToDisplay(::DiscreteSource, lv::LatentVariation, cdf_vals::Vector{Float64})
    return variationValues(lv, cdf_vals)
end

function _particleRowToDisplay(::DiscreteCoSource, lv::LatentVariation, cdf_vals::Vector{Float64})
    return variationValues(lv, cdf_vals)
end

function _particleRowToDisplay(::LVSource, lv::LatentVariation, cdf_vals::Vector{Float64})
    lp_vals     = [quantile(d, cdf) for (d, cdf) in zip(lv.latent_parameters, cdf_vals)]
    target_vals = variationValues(lv, cdf_vals)
    return [lp_vals..., target_vals...]
end
