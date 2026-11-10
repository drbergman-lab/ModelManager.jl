using Distributions, DataFrames, CSV, FFTW
using Sobol
import GlobalSensitivity

export MOAT, Sobolʼ, SobolMM, RBD

"""
    GSAMethod

Abstract type for global sensitivity analysis methods.

# Subtypes
[`MOAT`](@ref), [`Sobolʼ`](@ref), [`RBD`](@ref)
"""
abstract type GSAMethod end

"""
    GSASampling

Abstract type for global sensitivity analysis sampling results.
"""
abstract type GSASampling end

#! Public despite not being exported: `GSASampling` is the return type of the exported
#! `run(::GSAMethod, ...)`, so users hold one; the three concrete subtypes are what they actually get
#! back, `GSAMethod` is the method argument they pass in, and `getMonadIDDataFrame` /
#! `methodString` are the accessors the manual tells them to call on the result.
#! See CLAUDE.md, "Docstring cross-references".
@compat public GSASampling, GSAMethod, MOATSampling, SobolSampling, SobolIndices, RBDSampling,
               getMonadIDDataFrame, methodString, gsaLabels

"""
    getMonadIDDataFrame(gsa_sampling::GSASampling)

Return the `DataFrame` of monad IDs that define the sampling scheme.
"""
getMonadIDDataFrame(gsa_sampling::GSASampling) = gsa_sampling.monad_ids_df

"""
    simulationIDs(gsa_sampling::GSASampling)

Return the simulation IDs run in the sensitivity analysis.
"""
simulationIDs(gsa_sampling::GSASampling) = simulationIDs(gsa_sampling.sampling)

"""
    monadIDs(gsa_sampling::GSASampling)

Return the IDs of the monads evaluated in the sensitivity analysis.

These are the same monads that [`getMonadIDDataFrame`](@ref) reports, flattened and
deduplicated: the data frame arranges them in the shape the method's design requires — one
column per factor for [`MOAT`](@ref), for instance — while this gives the flat set, which is
what [`monadsTable`](@ref) and the deletion functions want.
"""
monadIDs(gsa_sampling::GSASampling) = monadIDs(gsa_sampling.sampling)

"""
    methodString(gsa_sampling::GSASampling)

Return a lowercase string identifier for the GSA method (e.g. `"moat"`, `"sobol"`).
"""
function methodString(gsa_sampling::GSASampling)
    method = typeof(gsa_sampling) |> string |> lowercase
    method = split(method, ".")[end]
    return endswith(method, "sampling") ? method[1:end-8] : method
end

#! Sorted, because a `Dict`'s iteration order is unspecified and these labels drive plot series and
#! `show` output — both of which should be identical between two runs of the same script.
"""
    gsaLabels(gsa_sampling::GSASampling)

The labels of the sensitivity analyses computed on `gsa_sampling`, sorted.

One label is not one `functions=` entry. A [`QoI`](@ref) whose `reduce` returns a `Dict` or
`NamedTuple` yields one analysis per key, labelled `"<qoi name>.<key>"`; a `Real` yields one
labelled with the QoI's name. Each label indexes `gsa_sampling.results`.
"""
gsaLabels(gsa_sampling::GSASampling) = sort(collect(keys(gsa_sampling.results)))

"""
    run(method::GSAMethod, inputs::InputFolders, avs; functions, kwargs...)
    run(method::GSAMethod, reference::AbstractMonad, avs; functions, kwargs...)

Run a global sensitivity analysis and return a [`GSASampling`](@ref) result.

`kwargs` are forwarded to [`run`](@ref)`(::Sampling; ...)` and from there to the
simulator hooks — pass any simulator-specific options here.
"""
function run(method::GSAMethod, inputs::InputFolders, avs::AbstractVector{<:AbstractVariation}; functions::AbstractVector=Any[], kwargs...)
    pv = ParsedVariations(avs)
    gsa_sampling = runSensitivitySampling(method, inputs, pv; kwargs...)
    sensitivityResults!(gsa_sampling, functions)
    return gsa_sampling
end

#! Rejected rather than silently honoured. `reference_variation_id` is passed here *before* `kwargs...`,
#! and Julia lets the rightmost duplicate win, so a caller supplying one used to override the reference's
#! own variation — accidentally, and undocumented. The reference is the reference:
#! `createTrial(method, reference::AbstractMonad, avs; ...)` offers no override either, and the
#! `InputFolders` form is where a variation ID is genuinely an independent argument.
function run(method::GSAMethod, reference::AbstractMonad, avs::Vector{<:AbstractVariation}; functions::AbstractVector=Any[], kwargs...)
    haskey(kwargs, :reference_variation_id) && throw(ArgumentError(
        "run(::GSAMethod, reference::AbstractMonad, ...) takes its reference variation from " *
        "`reference`, so `reference_variation_id` cannot also be given — it would override the " *
        "thing that makes `reference` a reference. Pass `InputFolders` instead to supply a " *
        "variation ID independently."))
    return run(method, reference.inputs, avs; reference_variation_id=reference.variation_id, functions, kwargs...)
end

#! `kwargs...` comes last so a caller's explicit `n_replicates=` beats the spec's, rather than the spec
#! silently winning. Julia gives the rightmost duplicate keyword precedence — the same mechanism that
#! used to let a caller override a *reference monad's* variation, which is now refused. Harmless here,
#! because a spec's fields are defaults the user set, not an identity carried by an object.
function run(method::GSAMethod, spec::StudySpec;
             functions::AbstractVector=Any[], kwargs...)
    return run(method, spec.inputs, spec.variations;
               functions=functions,
               reference_variation_id=spec.reference_variation_id,
               n_replicates=spec.n_replicates,
               use_previous=spec.use_previous,
               kwargs...)
end

function run(method::GSAMethod, inputs_or_ref::Union{InputFolders,AbstractMonad}, av1::AbstractVariation, avs::Vararg{AbstractVariation}; kwargs...)
    return run(method, inputs_or_ref, [av1; avs...]; kwargs...)
end

"""
    sensitivityResults!(gsa_sampling, functions)

Calculate sensitivity indices for `functions` and record the sampling scheme.
"""
function sensitivityResults!(gsa_sampling::GSASampling, functions::AbstractVector)
    calculateGSA!(gsa_sampling, functions)
    recordSensitivityScheme(gsa_sampling)
end

"""
    calculateGSA!(gsa_sampling, functions; recompute=false)
    calculateGSA!(gsa_sampling, f; recompute=false)

Calculate sensitivity indices for `functions` (or for the single measurement `f`) and file them in
`gsa_sampling.results` under their labels — see [`gsaLabels`](@ref).

A measurement whose results are already present is **skipped**, so adding a quantity to an analysis
costs only the new one: `run(method, spec; functions=[q1])` followed by
`calculateGSA!(gsa, [q1, q2])` reads each simulation's output for `q2` alone.

Results **accumulate**. A measurement absent from `functions` keeps whatever it produced earlier —
that is what makes adding a quantity cheap, and its indices are not stale, having been computed from
this same sampling. What `recompute` replaces is the labels of the measurements you *do* name, so a
measurement whose value now carries different keys leaves nothing behind; it never prunes ones you do
not name. `empty!(gsa_sampling.results)` is how you start over.

# Keywords
- `recompute`: evaluate even where results already exist, *replacing* every label that measurement
  owns rather than merging into them — so a measurement whose value now carries different keys leaves
  nothing stale behind. Needed when the measurement itself has changed, because nothing can detect that — redefining a function's body in place leaves
  it indistinguishable from the one already evaluated, the same reason a [`QoI`](@ref)'s `stored`
  defaults to `:never`.

# Errors
Two entries of `functions` that produce the same label — most easily two [`QoI`](@ref)s with the same
`name` — are refused, since one would silently replace the other. Nothing is filed when this happens;
the whole call is rejected before any result is stored.
"""
function calculateGSA!(gsa_sampling::GSASampling, functions::AbstractVector; recompute::Bool=false)
    #! Collision is checked on the FLATTENED labels rather than on the QoI names, because a QoI that
    #! spreads contributes labels its name alone does not reveal. And everything is computed before
    #! anything is stored, so a rejected call leaves `results` exactly as it found it rather than
    #! half-written.
    #!
    #! Scoped to this call on purpose. Checking against `results` as a whole would make a second
    #! `calculateGSA!` for the same quantity an error, and refreshing a result is the documented
    #! reason this function is public.
    labelled = Pair{String,Any}[]
    sources = Dict{String,String}()
    evaluated = String[]
    for f in functions
        q = _asQoI(f)
        recompute || !_hasGSAResults(gsa_sampling, q) || continue
        push!(evaluated, q.name)
        for (label, result) in _gsaResults(gsa_sampling, q)
            haskey(sources, label) && throw(ArgumentError(
                "Sensitivity labels must be unique within one `calculateGSA!` call, but " *
                "\"$(label)\" comes from both QoI \"$(sources[label])\" and QoI \"$(q.name)\". " *
                "Rename one of them."))
            sources[label] = q.name
            push!(labelled, label => result)
        end
    end
    _replaceGSAResults!(gsa_sampling, evaluated, labelled)
    return
end

function calculateGSA!(gsa_sampling::GSASampling, f::Union{Function,QoI}; recompute::Bool=false)
    q = _asQoI(f)
    recompute || !_hasGSAResults(gsa_sampling, q) || return
    _replaceGSAResults!(gsa_sampling, [q.name], _gsaResults(gsa_sampling, q))
    return
end

#! A re-evaluated QoI REPLACES its labels; it does not merge into them. Storing only what the new
#! evaluation produced would leave a label the previous reducer made and this one no longer does --
#! holding a number from a measurement that no longer exists, reported by `gsaLabels` as current and
#! drawn as a series. That is precisely the case `recompute` is for, so it is the case that must not
#! silently keep stale results.
"""
    _replaceGSAResults!(gsa_sampling, names, labelled)

File `labelled` in `gsa_sampling.results`, first dropping every label already belonging to one of
`names`.
"""
function _replaceGSAResults!(gsa_sampling::GSASampling, names, labelled)
    for name in names, label in _gsaLabelsOf(gsa_sampling, name)
        delete!(gsa_sampling.results, label)
    end
    for (label, result) in labelled
        gsa_sampling.results[label] = result
    end
    return
end

#! Decided from the NAME, not from the labels, and that is the whole point: a spreading QoI's labels
#! come from `reduce`'s return and are unknown until it has run on a monad, so a check that needed
#! them would have to do the expensive work first and save nothing. Every label a QoI produces is
#! either its name or its name followed by `.` and a key, so the name alone answers the question
#! before any output is read.
#!
#! The inference is EXACT, not a heuristic, and only because `QoI` refuses a name containing a `.`.
#! Without that, `QoI("counts.x", …)` and a `QoI("counts", …)` spreading to key `"x"` would both
#! claim the label `counts.x`: caught within one `calculateGSA!` call by the collision check, but
#! across calls it would silently skip one of them -- in one ordering the whole spreading QoI, so
#! `counts.y` would never be computed. See the constructor in `src/qoi.jl`.
#! A QoI whose name ModelManager derived from an anonymous `compute` is never treated as already
#! evaluated. The derived name comes from the closure's *type*, and every closure a factory returns
#! has the same type whatever it captured -- `make("tumor")` and `make("immune")` both become
#! `anon_f_make_0` -- so the label proves nothing about which measurement sits under it, and skipping
#! on it would keep the tumor indices when the user asked for immune. Such a QoI is re-evaluated and
#! its result replaces whatever the label held. Only a name the user chose, or a top-level
#! function's own, can mean "already done".
"""
    _hasGSAResults(gsa_sampling, q) → Bool

Whether `gsa_sampling` already holds results for `q`, decided from `q`'s name before evaluating it.
Exact rather than heuristic, because a [`QoI`](@ref) name cannot contain the `.` separator, and
never claimed for an auto-named closure, whose derived name identifies nothing.
"""
_hasGSAResults(gsa_sampling::GSASampling, q::QoI) =
    !_isAutoNamedAnonymous(q) && any(k -> _isQoILabelOf(k, q.name), keys(gsa_sampling.results))

"""
    _gsaLabelsOf(gsa_sampling, name) → Vector{String}

Every label in `gsa_sampling.results` that a QoI called `name` produced.
"""
_gsaLabelsOf(gsa_sampling::GSASampling, name::AbstractString) =
    filter(k -> _isQoILabelOf(k, name), collect(keys(gsa_sampling.results)))

#! Computes without storing. Split out so the vector method above can see every label a call will
#! produce before it commits any of them.
"""
    _gsaResults(gsa_sampling, q::QoI) → Vector{Pair{String,result}}

The sensitivity indices `q` yields on `gsa_sampling`, one labelled entry per quantity it measures.
Stores nothing.
"""
function _gsaResults end

############# Morris One-At-A-Time (MOAT) #############

"""
    MOAT <: GSAMethod

Morris One-At-A-Time global sensitivity analysis.

# Fields
- `lhs_variation::LHSVariation`

# Examples
```julia
MOAT()      # default 15 base points
MOAT(10)    # 10 base points
MOAT(10; add_noise=true)
```
"""
struct MOAT <: GSAMethod
    lhs_variation::LHSVariation
end

MOAT() = MOAT(LHSVariation(15))
MOAT(n::Int; kwargs...) = MOAT(LHSVariation(n; kwargs...))

"""
    MOATSampling <: GSASampling

Result of a [`MOAT`](@ref) sensitivity analysis.
"""
struct MOATSampling <: GSASampling
    sampling::Sampling
    monad_ids_df::DataFrame
    results::Dict{String,GlobalSensitivity.MorrisResult}
end

MOATSampling(sampling::Sampling, monad_ids_df::DataFrame) = MOATSampling(sampling, monad_ids_df, Dict{String,GlobalSensitivity.MorrisResult}())

function Base.show(io::IO, moat_sampling::MOATSampling)
    println(io, "MOAT sampling")
    println(io, "-------------")
    println(io, moat_sampling.sampling)
    println(io, "Sensitivity quantities calculated:")
    for label in gsaLabels(moat_sampling)
        println(io, "  $label")
    end
end

"""
    buildAndRunSensitivitySampling(method, monads; n_replicates, use_previous, kwargs...)

Assemble `monads` into a [`Sampling`](@ref), label it with the sensitivity method
that produced it, and run it. Returns the `Sampling`.

The label is written before any simulation is dispatched, so an interrupted sweep
keeps it and the sampling is queryable by method while it is still running.
"""
function buildAndRunSensitivitySampling(method::GSAMethod, monads;
                                        n_replicates::Integer, use_previous::Bool, kwargs...)
    sampling = Sampling(unique(monads); n_replicates=n_replicates, use_previous=use_previous)
    #! Constituents match through inheritance, so only the sampling itself is labelled.
    tagReserved!(sampling, ["mm:method" => string(nameof(typeof(method)))])
    run(sampling; kwargs...)
    return sampling
end

"""
    runSensitivitySampling(method, inputs, pv; kwargs...)

Internal dispatch: create the sampling design, run simulations, and return a `GSASampling`.
`kwargs` are forwarded to [`run`](@ref)`(::Sampling; ...)`.
"""
function runSensitivitySampling end

function runSensitivitySampling(method::MOAT, inputs::InputFolders, pv::ParsedVariations;
    reference_variation_id::VariationID=VariationID(inputs),
    ignore_indices::AbstractVector{<:Integer}=Int[],
    n_replicates::Int=1,
    use_previous::Bool=true,
    kwargs...)

    if !isempty(ignore_indices)
        error("MOAT does not support ignoring indices. Only Sobolʼ does.")
    end
    add_variations_result = addVariations(method.lhs_variation, inputs, pv, reference_variation_id)
    base_variation_ids = add_variations_result.variation_ids

    perturbed_variation_ids = stack(zip(base_variation_ids, eachcol(add_variations_result.cdfs)); dims=1) do (variation_id, cdf_col)
        perturbVariation(pv, inputs, variation_id, cdf_col)
    end

    variation_ids = hcat(base_variation_ids, perturbed_variation_ids)
    monads = variationsToMonads(inputs, variation_ids)
    monad_ids = [monad.id for monad in monads]
    perturb_headers = mapreduce(lv -> lv.latent_parameter_names, vcat, pv.latent_variations)
    header_line = ["base"; perturb_headers]
    monad_ids_df = DataFrame(monad_ids, header_line)
    sampling = buildAndRunSensitivitySampling(method, monads;
                                              n_replicates=n_replicates, use_previous=use_previous, kwargs...)
    return MOATSampling(sampling, monad_ids_df)
end

"""
    perturbVariation(pv, inputs, reference_variation_id, cdf_col)

Generate one-at-a-time perturbations of `cdf_col` for MOAT analysis.
"""
function perturbVariation(pv::ParsedVariations, inputs::InputFolders, reference_variation_id::VariationID, cdf_col::AbstractVector{<:Real})
    perturbed_cdfs = repeat(cdf_col, 1, length(cdf_col))
    for (d, col) in enumerate(eachcol(perturbed_cdfs))
        dcdf = cdf_col[d] < 0.5 ? 0.5 : -0.5
        col[d] += dcdf
    end
    perturbed_variation_ids = addCDFVariations(inputs, pv, reference_variation_id, perturbed_cdfs)
    @assert length(perturbed_variation_ids) == length(cdf_col) "Expected one perturbation per latent dimension."
    return perturbed_variation_ids
end

function _gsaResults(moat_sampling::MOATSampling, q::QoI)
    out = Pair{String,GlobalSensitivity.MorrisResult}[]
    for (label, vals) in evaluateFunctionOnSampling(moat_sampling, q)
        effects = 2 * (vals[:,2:end] .- vals[:,1])
        means = mean(effects, dims=1)
        means_star = mean(abs.(effects), dims=1)
        variances = var(effects, dims=1)
        push!(out, label => GlobalSensitivity.MorrisResult(means, means_star, variances, effects))
    end
    return out
end

############# Sobolʼ Indices #############

const _SobolIndexMethods = NamedTuple{(:first_order,:total_order),Tuple{Symbol,Symbol}}
const _DEFAULT_SOBOL_INDEX_METHODS = (first_order=:Jansen1999, total_order=:Jansen1999)
const _DEFAULT_N_BOOTSTRAP = 1000
const _DEFAULT_CONF_LEVEL = 0.95
#! A fixed seed, not `Random.default_rng()`: every bootstrap draws from a `copy` of this, so the CIs
#! are reproducible with no action from the user and a script's own `Random.seed!` stream is never
#! advanced by running an analysis.
_defaultBootstrapRNG() = Random.Xoshiro(0)

const _SOBOL_FIRST_ORDER_METHODS = (:Jansen1999, :Sobol1993, :Saltelli2010)
const _SOBOL_TOTAL_ORDER_METHODS = (:Jansen1999, :Homma1996, :Sobol2007)

#! An unrecognised estimator name would otherwise leave its indices at zero without complaint.
function _checkSobolSettings(sobol_index_methods::_SobolIndexMethods, n_bootstrap::Int, conf_level::Real)
    sobol_index_methods.first_order in _SOBOL_FIRST_ORDER_METHODS || throw(ArgumentError(
        "Unknown first-order Sobol' estimator :$(sobol_index_methods.first_order). Use one of $(_SOBOL_FIRST_ORDER_METHODS)."))
    sobol_index_methods.total_order in _SOBOL_TOTAL_ORDER_METHODS || throw(ArgumentError(
        "Unknown total-order Sobol' estimator :$(sobol_index_methods.total_order). Use one of $(_SOBOL_TOTAL_ORDER_METHODS)."))
    n_bootstrap >= 0 || throw(ArgumentError("`n_bootstrap` must be non-negative (0 disables the bootstrap); got $(n_bootstrap)."))
    0 < conf_level < 1 || throw(ArgumentError("`conf_level` must lie strictly between 0 and 1; got $(conf_level)."))
    return
end

"""
    Sobolʼ <: GSAMethod

Sobol' variance-based global sensitivity analysis.

The `ʼ` (rasp) symbol avoids conflict with the `Sobol` module. Type `\\rasp<tab>` in VS Code.
[`SobolMM`](@ref) is provided as a plain-ASCII alias.

    Sobolʼ(n; sobol_index_methods, second_order=false, n_bootstrap=1000, conf_level=0.95, rng, kwargs...)

`n` is the number of rows in each of the base matrices A and B. Other `kwargs` go to
[`SobolVariation`](@ref).

# Keywords
- `sobol_index_methods`: estimators for the first- and total-order indices, as
  `(first_order=…, total_order=…)`. First order: `:Jansen1999` (default), `:Sobol1993`,
  `:Saltelli2010`. Total order: `:Jansen1999` (default), `:Homma1996`, `:Sobol2007`.
- `second_order`: also compute the pairwise interaction indices `S2`. This adds `n*d` monads to
  the `n*(d+2)` of a first-order design. `S2` always subtracts Saltelli 2010 first-order
  estimates, whatever `sobol_index_methods.first_order` says.
- `n_bootstrap`: number of bootstrap resamples behind the confidence intervals; `0` skips them.
  Resampling reuses the simulations already run.
- `conf_level`: coverage of the percentile confidence intervals.
- `rng`: where the bootstrap draws its resamples. Each bootstrap uses a `copy`, so `rng` itself
  never advances, and the default (a fixed-seed `Xoshiro`) makes the intervals reproducible. This
  does not touch the design, whose randomization is `SobolVariation`'s `randomization` keyword.

# Examples
```julia
Sobolʼ(15)
Sobolʼ(15; second_order=true)
Sobolʼ(15; n_bootstrap=5000, conf_level=0.9, rng=Random.Xoshiro(42))
Sobolʼ(15; skip_start=true)
```
"""
struct Sobolʼ <: GSAMethod
    sobol_variation::SobolVariation
    sobol_index_methods::_SobolIndexMethods
    second_order::Bool
    n_bootstrap::Int
    conf_level::Float64
    rng::AbstractRNG

    function Sobolʼ(sobol_variation::SobolVariation, sobol_index_methods::_SobolIndexMethods,
                    second_order::Bool, n_bootstrap::Int, conf_level::Real, rng::AbstractRNG)
        _checkSobolSettings(sobol_index_methods, n_bootstrap, conf_level)
        return new(sobol_variation, sobol_index_methods, second_order, n_bootstrap, conf_level, rng)
    end
end

Sobolʼ(sobol_variation::SobolVariation, sobol_index_methods::_SobolIndexMethods) =
    Sobolʼ(sobol_variation, sobol_index_methods, false, _DEFAULT_N_BOOTSTRAP, _DEFAULT_CONF_LEVEL, _defaultBootstrapRNG())

Sobolʼ(n::Int; sobol_index_methods::_SobolIndexMethods=_DEFAULT_SOBOL_INDEX_METHODS,
       second_order::Bool=false, n_bootstrap::Int=_DEFAULT_N_BOOTSTRAP,
       conf_level::Real=_DEFAULT_CONF_LEVEL, rng::AbstractRNG=_defaultBootstrapRNG(), kwargs...) =
    Sobolʼ(SobolVariation(n; n_matrices=2, kwargs...), sobol_index_methods, second_order, n_bootstrap, conf_level, rng)

"""
    SobolMM

ASCII alias for [`Sobolʼ`](@ref).
"""
const SobolMM = Sobolʼ

"""
    SobolIndices

Sobol' indices for one sensitivity quantity of a [`SobolSampling`](@ref), over its focus parameters
in `monad_ids_df` order.

- `S1`, `ST`: first- and total-order indices.
- `S2`: symmetric matrix of second-order indices with a `NaN` diagonal, or `nothing` unless the
  analysis was run with `second_order=true`.
- `S1_CI`, `ST_CI`, `S2_CI`: percentile-bootstrap bounds, with lower and upper bound along the last
  dimension (`S1_CI[i, :] == [lo, hi]`, `S2_CI[j, k, :] == [lo, hi]`), or `nothing` when
  `n_bootstrap == 0`. A bound is `NaN` when some resample had no variance to decompose. The bounds
  need not bracket the estimate, which is computed from every row while the bounds come from
  resamples.
- `conf_level`, `n_bootstrap`: how the intervals were made.
"""
struct SobolIndices
    S1::Vector{Float64}
    ST::Vector{Float64}
    S2::Union{Nothing,Matrix{Float64}}
    S1_CI::Union{Nothing,Matrix{Float64}}
    ST_CI::Union{Nothing,Matrix{Float64}}
    S2_CI::Union{Nothing,Array{Float64,3}}
    conf_level::Float64
    n_bootstrap::Int
end

#! For the four-argument `SobolSampling` constructor, whose results dictionary may hold
#! `GlobalSensitivity.SobolResult`s, the type results had before 0.13. Drop at v1.0 with the
#! unprefixed `monad_ids_df` layout.
SobolIndices(r::GlobalSensitivity.SobolResult) =
    SobolIndices(r.S1, r.ST, r.S2, nothing, nothing, nothing, _DEFAULT_CONF_LEVEL, 0)
SobolIndices(r::SobolIndices) = r

"""
    SobolSampling <: GSASampling

Result of a [`Sobolʼ`](@ref) sensitivity analysis. Each entry of `results` is a
[`SobolIndices`](@ref).
"""
struct SobolSampling <: GSASampling
    sampling::Sampling
    monad_ids_df::DataFrame
    results::Dict{String,SobolIndices}
    sobol_index_methods::_SobolIndexMethods
    n_bootstrap::Int
    conf_level::Float64
    rng::AbstractRNG

    function SobolSampling(sampling::Sampling, monad_ids_df::DataFrame, results::Dict{String,SobolIndices},
                           sobol_index_methods::_SobolIndexMethods, n_bootstrap::Int, conf_level::Real,
                           rng::AbstractRNG)
        _checkSobolSettings(sobol_index_methods, n_bootstrap, conf_level)
        return new(sampling, monad_ids_df, results, sobol_index_methods, n_bootstrap, conf_level, rng)
    end
end

SobolSampling(sampling::Sampling, monad_ids_df::DataFrame, results::AbstractDict,
              sobol_index_methods::_SobolIndexMethods) =
    SobolSampling(sampling, monad_ids_df,
                  Dict{String,SobolIndices}(k => SobolIndices(v) for (k, v) in results),
                  sobol_index_methods, _DEFAULT_N_BOOTSTRAP, _DEFAULT_CONF_LEVEL, _defaultBootstrapRNG())

SobolSampling(sampling::Sampling, monad_ids_df::DataFrame;
              sobol_index_methods::_SobolIndexMethods=_DEFAULT_SOBOL_INDEX_METHODS,
              n_bootstrap::Int=_DEFAULT_N_BOOTSTRAP, conf_level::Real=_DEFAULT_CONF_LEVEL,
              rng::AbstractRNG=_defaultBootstrapRNG()) =
    SobolSampling(sampling, monad_ids_df, Dict{String,SobolIndices}(), sobol_index_methods,
                  n_bootstrap, conf_level, rng)

function Base.show(io::IO, sobol_sampling::SobolSampling)
    println(io, "Sobol sampling")
    println(io, "--------------")
    println(io, sobol_sampling.sampling)
    println(io, "Sobol index methods:")
    println(io, "  First order: $(sobol_sampling.sobol_index_methods.first_order)")
    println(io, "  Total order: $(sobol_sampling.sobol_index_methods.total_order)")
    println(io, "  Second order: $(isempty(_sobolColumns(sobol_sampling.monad_ids_df).ba) ? "no" : "yes (Saltelli2002)")")
    if sobol_sampling.n_bootstrap > 0
        println(io, "Confidence intervals: $(sobol_sampling.conf_level) percentile bootstrap, $(sobol_sampling.n_bootstrap) resamples")
    else
        println(io, "Confidence intervals: none")
    end
    println(io, "Sensitivity quantities calculated:")
    for label in gsaLabels(sobol_sampling)
        println(io, "  $label")
    end
end

const _SOBOL_AB_PREFIX = "A_B:"
const _SOBOL_BA_PREFIX = "B_A:"

#! Column positions in a Sobolʼ `monad_ids_df`. Columns 1 and 2 are A and B; the rest are prefixed
#! `A_B:` or `B_A:`. A frame with no prefixed column is the pre-0.13 layout, in which every column
#! after B was an A_B column named for its parameter. Drop that branch at v1.0.
function _sobolColumns(monad_ids_df::DataFrame)
    cols = names(monad_ids_df)[3:end]
    ab = findall(startswith(_SOBOL_AB_PREFIX), cols)
    ba = findall(startswith(_SOBOL_BA_PREFIX), cols)
    if isempty(ab) && isempty(ba)
        return (ab=collect(3:length(cols)+2), ba=Int[], names=cols)
    end
    ab_names = [chopprefix(c, _SOBOL_AB_PREFIX) for c in cols[ab]]
    @assert isempty(ba) || [chopprefix(c, _SOBOL_BA_PREFIX) for c in cols[ba]] == ab_names "The B_A: columns of a Sobolʼ design must name the same parameters, in the same order, as its A_B: columns."
    return (ab=ab .+ 2, ba=ba .+ 2, names=String.(ab_names))
end

function runSensitivitySampling(method::Sobolʼ, inputs::InputFolders, pv::ParsedVariations;
    reference_variation_id::VariationID=VariationID(inputs),
    ignore_indices::AbstractVector{<:Integer}=Int[],
    n_replicates::Int=1,
    use_previous::Bool=true,
    kwargs...)

    add_variations_result = addVariations(method.sobol_variation, inputs, pv, reference_variation_id)
    variation_ids = add_variations_result.variation_ids
    cdfs = add_variations_result.cdfs
    d = nLatentDims(pv)
    focus_indices = [i for i in 1:d if !(i in ignore_indices)]

    A = cdfs[:,1,:]
    B = cdfs[:,2,:]
    #! `X` with parameter `i`'s row taken from `Y`: A_B^i for (A, B), B_A^i for (B, A).
    function swapped(X, Y)
        return stack(focus_indices) do i
            Xᵢ = copy(X)
            Xᵢ[i,:] .= Y[i,:]
            addCDFVariations(inputs, pv, reference_variation_id, Xᵢ)
        end
    end
    all_latent_names = mapreduce(lv -> lv.latent_parameter_names, vcat, pv.latent_variations)
    focus_names = all_latent_names[focus_indices]
    variation_id_blocks = [variation_ids, swapped(A, B)]
    header_line = ["A"; "B"; _SOBOL_AB_PREFIX .* focus_names]
    if method.second_order
        push!(variation_id_blocks, swapped(B, A))
        append!(header_line, _SOBOL_BA_PREFIX .* focus_names)
    end
    monads = variationsToMonads(inputs, reduce(hcat, variation_id_blocks))
    monad_ids = [monad.id for monad in monads]
    monad_ids_df = DataFrame(monad_ids, header_line)
    sampling = buildAndRunSensitivitySampling(method, monads;
                                              n_replicates=n_replicates, use_previous=use_previous, kwargs...)
    return SobolSampling(sampling, monad_ids_df; sobol_index_methods=method.sobol_index_methods,
                         n_bootstrap=method.n_bootstrap, conf_level=method.conf_level, rng=method.rng)
end

function _gsaResults(sobol_sampling::SobolSampling, q::QoI)
    out = Pair{String,SobolIndices}[]
    for (label, vals) in evaluateFunctionOnSampling(sobol_sampling, q)
        push!(out, label => _sobolResult(sobol_sampling, vals))
    end
    return out
end

#! The index arithmetic, on one set of rows. `fAB[:, i]` is f(A_B^i), `fBA[:, i]` is f(B_A^i) or
#! `fBA === nothing` for a first-order design. Separate from `_sobolResult` so the bootstrap can call
#! it on resampled rows, and so it can be checked against an analytic function without simulations.
function _sobolIndices(fA::AbstractVector, fB::AbstractVector, fAB::AbstractMatrix,
                       fBA::Union{Nothing,AbstractMatrix}, methods::_SobolIndexMethods)
    d = size(fAB, 2)
    expected_value² = mean(fA .* fB)
    total_variance = var([fA; fB])
    first_order_variances = zeros(Float64, d)
    total_order_variances = zeros(Float64, d)
    saltelli_first_order_variances = zeros(Float64, d)
    for i in 1:d
        Aᵦ = @view fAB[:, i]
        saltelli_first_order_variances[i] = mean(fB .* (Aᵦ .- fA))
        if methods.first_order == :Sobol1993
            first_order_variances[i] = mean(fB .* Aᵦ) - expected_value²
        elseif methods.first_order == :Jansen1999
            first_order_variances[i] = total_variance - 0.5 * mean((fB .- Aᵦ) .^ 2)
        elseif methods.first_order == :Saltelli2010
            first_order_variances[i] = saltelli_first_order_variances[i]
        end
        if methods.total_order == :Homma1996
            total_order_variances[i] = total_variance - mean(fA .* Aᵦ) + expected_value²
        elseif methods.total_order == :Jansen1999
            total_order_variances[i] = 0.5 * mean((Aᵦ .- fA) .^ 2)
        elseif methods.total_order == :Sobol2007
            total_order_variances[i] = mean(fA .* (fA .- Aᵦ))
        end
    end
    S1 = first_order_variances ./ total_variance
    ST = total_order_variances ./ total_variance
    isnothing(fBA) && return (S1=S1, ST=ST, S2=nothing)
    #! Saltelli 2002: B_A^j and A_B^k share exactly parameters j and k, so the mean of their product
    #! less f₀² is the closed variance V_jk^c = V_j + V_k + V_jk. Subtracting V_j and V_k leaves V_jk.
    #! Those are Saltelli 2010 first-order variances whatever `methods.first_order` is, because that
    #! estimator has the same product form as the closed term; another estimator's V_j would leave
    #! the difference between estimators in S2.
    #!
    #! The outputs are shifted by their mean before any of this, purely for floating-point accuracy.
    #! The products are of order (mean output)², while V_jk is a small difference between them, so a
    #! large mean output (10⁹, say) leaves V_jk as rounding noise. Shifting every block by the same
    #! constant does not change what the estimator estimates. The first-order terms are recomputed on
    #! the shifted outputs so both sides of the difference are rounded alike. S1 and ST are not
    #! shifted: the default Jansen estimators use only differences of outputs, which never grow
    #! with the mean.
    c = mean(fA) / 2 + mean(fB) / 2
    cA, cB = fA .- c, fB .- c
    cAB, cBA = fAB .- c, fBA .- c
    centred_first_order_variances = [mean(cB .* (view(cAB, :, i) .- cA)) for i in 1:d]
    S2 = fill(NaN, d, d)
    for j in 1:d, k in (j+1):d
        closed = mean(view(cBA, :, j) .* view(cAB, :, k) .- cA .* cB)
        S2[j, k] = S2[k, j] = (closed - centred_first_order_variances[j] - centred_first_order_variances[k]) / total_variance
    end
    return (S1=S1, ST=ST, S2=S2)
end

#! Bounds from a set of resampled values. A non-finite value means a resample with zero variance:
#! `NaN` when its hybrid outputs are constant too, `±Inf` when they are not. Either way that draw
#! has no index, so the interval is undefined rather than an error from `quantile` or a bound that
#! silently mixes in infinities.
function _percentileBounds(samples::AbstractVector{Float64}, conf_level::Float64)
    all(isfinite, samples) || return (NaN, NaN)
    α = (1 - conf_level) / 2
    return (quantile(samples, α), quantile(samples, 1 - α))
end

#! `[lo hi]` along a new last dimension, one bound per entry of the estimate.
function _bootstrapBounds(draws::Vector{<:AbstractArray{Float64}}, conf_level::Float64)
    sz = size(first(draws))
    out = Array{Float64}(undef, sz..., 2)
    for I in CartesianIndices(sz)
        lo, hi = _percentileBounds([draw[I] for draw in draws], conf_level)
        out[I, 1] = lo
        out[I, 2] = hi
    end
    return out
end

_sobolResult(sobol_sampling::SobolSampling, vals::Matrix{Float64}) =
    _sobolResult(vals, sobol_sampling.monad_ids_df, sobol_sampling.sobol_index_methods,
                 sobol_sampling.n_bootstrap, sobol_sampling.conf_level, sobol_sampling.rng)

#! `vals` is laid out like `monad_ids_df`: one row per design row, one column per matrix.
function _sobolResult(vals::Matrix{Float64}, monad_ids_df::DataFrame, methods::_SobolIndexMethods,
                      n_bootstrap::Int, conf_level::Float64, stored_rng::AbstractRNG)
    cols = _sobolColumns(monad_ids_df)
    fA = vals[:, 1]
    fB = vals[:, 2]
    fAB = vals[:, cols.ab]
    fBA = isempty(cols.ba) ? nothing : vals[:, cols.ba]
    point = _sobolIndices(fA, fB, fAB, fBA, methods)

    n_bootstrap == 0 && return SobolIndices(point.S1, point.ST, point.S2, nothing, nothing, nothing, conf_level, 0)

    #! Rows are the resampling unit: row r is one paired draw across A, B and every A_B^i / B_A^i,
    #! so a resample must keep them together. A `copy` of the stored RNG, so every quantity sees the
    #! same resamples whatever order it is evaluated in and the caller's RNG never advances.
    rng = copy(stored_rng)
    N = length(fA)
    S1_draws = Vector{Vector{Float64}}(undef, n_bootstrap)
    ST_draws = Vector{Vector{Float64}}(undef, n_bootstrap)
    S2_draws = Vector{Matrix{Float64}}(undef, isnothing(fBA) ? 0 : n_bootstrap)
    for b in 1:n_bootstrap
        rows = rand(rng, 1:N, N)
        draw = _sobolIndices(view(fA, rows), view(fB, rows), view(fAB, rows, :),
                             isnothing(fBA) ? nothing : view(fBA, rows, :), methods)
        S1_draws[b] = draw.S1
        ST_draws[b] = draw.ST
        isnothing(fBA) || (S2_draws[b] = draw.S2)
    end
    S1_CI = _bootstrapBounds(S1_draws, conf_level)
    ST_CI = _bootstrapBounds(ST_draws, conf_level)
    S2_CI = isnothing(fBA) ? nothing : _bootstrapBounds(S2_draws, conf_level)
    return SobolIndices(point.S1, point.ST, point.S2, S1_CI, ST_CI, S2_CI, conf_level, n_bootstrap)
end

############# Random Balance Design (RBD) #############

"""
    RBD <: GSAMethod

Random Balance Design global sensitivity analysis.

# Fields
- `rbd_variation::RBDVariation`
- `num_harmonics::Int`

# Examples
```julia
RBD(15)
RBD(15; num_harmonics=10)
RBD(15; use_sobol=false)
```
"""
struct RBD <: GSAMethod
    rbd_variation::RBDVariation
    num_harmonics::Int
end

RBD(n::Integer; num_harmonics::Integer=6, kwargs...) = RBD(RBDVariation(n; kwargs...), num_harmonics)

"""
    RBDSampling <: GSASampling

Result of an [`RBD`](@ref) sensitivity analysis.
"""
struct RBDSampling <: GSASampling
    sampling::Sampling
    monad_ids_df::DataFrame
    results::Dict{String,Vector{<:Real}}
    num_harmonics::Int
    num_cycles::Union{Int,Rational}
end

RBDSampling(sampling::Sampling, monad_ids_df::DataFrame, num_cycles; num_harmonics::Int=6) =
    RBDSampling(sampling, monad_ids_df, Dict{String,Vector{<:Real}}(), num_harmonics, num_cycles)

function Base.show(io::IO, rbd_sampling::RBDSampling)
    println(io, "RBD sampling")
    println(io, "------------")
    println(io, rbd_sampling.sampling)
    println(io, "Number of harmonics: $(rbd_sampling.num_harmonics)")
    println(io, "Number of cycles (1/2 or 1): $(rbd_sampling.num_cycles)")
    println(io, "Sensitivity quantities calculated:")
    for label in gsaLabels(rbd_sampling)
        println(io, "  $label")
    end
end

function runSensitivitySampling(method::RBD, inputs::InputFolders, pv::ParsedVariations;
    reference_variation_id::VariationID=VariationID(inputs),
    ignore_indices::AbstractVector{<:Integer}=Int[],
    n_replicates::Int=1,
    use_previous::Bool=true,
    kwargs...)

    if !isempty(ignore_indices)
        error("RBD does not support ignoring indices. Only Sobolʼ does.")
    end
    add_variations_result = addVariations(method.rbd_variation, inputs, pv, reference_variation_id)
    variation_matrix = add_variations_result.variation_matrix
    monads = variationsToMonads(inputs, variation_matrix)
    monad_ids = [monad.id for monad in monads]
    header_line = mapreduce(lv -> lv.latent_parameter_names, vcat, pv.latent_variations)
    monad_ids_df = DataFrame(monad_ids, header_line)
    sampling = buildAndRunSensitivitySampling(method, monads;
                                              n_replicates=n_replicates, use_previous=use_previous, kwargs...)
    return RBDSampling(sampling, monad_ids_df, method.rbd_variation.num_cycles; num_harmonics=method.num_harmonics)
end

function _gsaResults(rbd_sampling::RBDSampling, q::QoI)
    out = Pair{String,Vector{<:Real}}[]
    for (label, vals) in evaluateFunctionOnSampling(rbd_sampling, q)
        if rbd_sampling.num_cycles == 1 // 2
            vals = vcat(vals, vals[end-1:-1:2, :])
        end
        ys = fft(vals, 1) .|> abs2
        ys ./= size(vals, 1)
        V = sum(ys[2:end, :], dims=1)
        Vi = 2 * sum(ys[2:(min(size(ys, 1), rbd_sampling.num_harmonics + 1)), :], dims=1)
        push!(out, label => ((Vi ./ V) |> vec))
    end
    return out
end

############# Generic Helper Functions #############

"""
    recordSensitivityScheme(gsa_sampling)

Write the monad ID scheme to a CSV file inside the sampling's trial folder.
"""
function recordSensitivityScheme(gsa_sampling::GSASampling)
    method = methodString(gsa_sampling)
    path_to_csv = joinpath(trialFolder(gsa_sampling.sampling), "$(method)_scheme.csv")
    return CSV.write(path_to_csv, getMonadIDDataFrame(gsa_sampling); header=true)
end

"""
    evaluateFunctionOnSampling(gsa_sampling, q::QoI) → Vector{Pair{String,Matrix{Float64}}}

Evaluate `q` on every monad in the sampling and return one labelled matrix per quantity it measures.

Each matrix is shaped like [`getMonadIDDataFrame`](@ref)`(gsa_sampling)` — one entry per cell of the
method's design, holding that monad's reduced value — which is the layout each method's index
arithmetic reads. A [`QoI`](@ref) whose `reduce` returns a `Real` gives one such matrix; one that
returns a flat `Dict` or `NamedTuple` of `Real`s gives one per key.

This is where that requirement is imposed, and it is a requirement on `reduce`'s value alone:
every cell of the design needs one number, so anything else — a `Vector`, a nested keyed value, a
value that is `missing` for some monad, or a key set that differs between monads — is refused here.
`compute` may return whatever the reducer knows how to turn into that.
"""
function evaluateFunctionOnSampling(gsa_sampling::GSASampling, q::QoI)
    #! A `QoI` only: `calculateGSA!` wraps a bare function with `_asQoI` before anything reaches
    #! `_gsaResults`, which is this function's only caller, and neither is public -- so accepting a
    #! `Function` here was a second entrance to a room with one door.
    monad_id_df = getMonadIDDataFrame(gsa_sampling)
    monad_ids = monad_id_df |> Matrix

    #! One reduction per DISTINCT monad: a design repeats monads (every RBD column holds the same
    #! set), and `compute` may be expensive. The cache holds the RAW reduced value, because its shape
    #! is what decides how many analyses this QoI yields.
    #!
    #! The reduction itself is `_reduceOverMonad`, the same function calibration uses, rather than a
    #! second copy here. The copy had drifted: it built one `Simulation` per ID -- the N+1 pattern
    #! `simulationsFromIDs` exists to avoid, and which `_reduceOverMonad` already avoided for
    #! calibration -- and it carried neither of that function's guards, so an empty monad reached
    #! `q.reduce([])` and a monad whose constituent list disagreed with the database went unnoticed.
    #!
    #! Wrapped the way `_evaluateParticle` wraps its two calls to user code, and for the same reason:
    #! `compute` and `reduce` are the user's, and what they raise says nothing about WHERE. The
    #! default reducer refusing to average two ragged replicates, say, throws from inside `_qoiMean`,
    #! which knows neither the QoI's name nor the monad. Both are known here.
    reduced = Dict{Int,Any}()
    for monad_id in monad_ids
        haskey(reduced, monad_id) && continue
        reduced[monad_id] = try
            _reduceOverMonad(q, monad_id)
        catch
            @error "Sensitivity analysis failed evaluating QoI \"$(q.name)\" on monad $(monad_id)."
            rethrow()
        end
    end

    #! THE place `reduce`'s value is held to a shape, and the only one: what a sensitivity index
    #! needs is a number per monad, per key, so that requirement belongs to sensitivity analysis
    #! rather than to the seam every consumer shares. (The sink applies the same rule to `compute`'s
    #! value, which it and only it reads; calibration applies none.)
    #!
    #! Every monad is checked, not just the first. A key set that differs anywhere leaves a hole in
    #! that key's design matrix, and there is no defensible value to fill it with. A sensitivity
    #! index computed over a hole is wrong rather than approximate, so this refuses instead. The
    #! same reasoning covers a monad that reduced to `missing`; `_qoiValueShape` has a method for it
    #! so the message says the monad has no value rather than naming a type. The source string is
    #! this caller's to supply, like every other shape check's.
    reduceSource(monad_id) = "`reduce` on monad $(monad_id)"
    reference_id = first(monad_ids)
    component_keys = _qoiValueShape(q, reduced[reference_id], reduceSource(reference_id))
    #! Walked in DESIGN order, so the monad an error names is the first mismatch someone scanning
    #! their design would reach -- iterating `reduced` instead would name whichever monad hashing
    #! happens to visit first, which is reproducible but not meaningful. Each DISTINCT monad is
    #! checked once, because a design can place the same monad in many cells: RBD's matrix is one set
    #! of variations permuted per column, so every column repeats them all.
    checked = Set{Int}()
    for monad_id in monad_ids
        monad_id in checked && continue
        push!(checked, monad_id)
        these_keys = _qoiValueShape(q, reduced[monad_id], reduceSource(monad_id))
        these_keys == component_keys || throw(ArgumentError(
            "QoI \"$(q.name)\": every monad must reduce to the same keys, since each key becomes " *
            "its own sensitivity analysis and needs a value from every monad in the design. Monad " *
            "$(reference_id) gave $(repr(component_keys)) but monad $(monad_id) gave " *
            "$(repr(these_keys))."))
    end

    #! Labels and values both come from `_keyedEntries`, the strict spreader the sink also uses;
    #! calibration's `_summaryEntries` names components identically and differs only in imposing no
    #! rule on what they hold. Building them here meant sensitivity analysis and the sink each wrote
    #! `"<name>.<key>"` themselves and agreed only by inspection. It also refuses two keys that
    #! collide once stringified (`1` and `"1"`), where the raw keys are still in hand, which is why
    #! no `allunique(labels)` check follows: neither downstream path handled that case
    #! (`calculateGSA!`'s cross-QoI check would name one QoI twice, and the single-measurement
    #! method let one analysis overwrite the other).
    entries = Dict{Int,Vector{Pair{_SummaryKey,Float64}}}(
        monad_id => _keyedEntries(q, reduced[monad_id], "`reduce` on monad $(monad_id)")
        for monad_id in checked)
    labels = [summaryLabel(key) for (key, _) in entries[reference_id]]
    out = Pair{String,Matrix{Float64}}[]
    for (i, label) in enumerate(labels)
        vals = zeros(Float64, size(monad_id_df))
        for (ind, monad_id) in enumerate(monad_ids)
            vals[ind] = last(entries[monad_id][i])
        end
        push!(out, label => vals)
    end
    return out
end

"""
    variationsToMonads(inputs, variation_ids)

Return an array of `Monad`s matching the shape of `variation_ids`.
"""
function variationsToMonads(inputs::InputFolders, variation_ids::AbstractArray{VariationID})
    monad_dict = Dict{VariationID,Monad}()
    return [get!(monad_dict, variation_id, Monad(inputs, variation_id)) for variation_id in variation_ids]
end
