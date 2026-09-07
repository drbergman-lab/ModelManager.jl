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
@compat public GSASampling, GSAMethod, MOATSampling, SobolSampling, RBDSampling,
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
reducer that drops or renames a key leaves nothing behind; it never prunes ones you do not name.
`empty!(gsa_sampling.results)` is how you start over.

# Keywords
- `recompute`: evaluate even where results already exist, *replacing* every label that measurement
  owns rather than merging into them — so a reducer that drops or renames a key leaves nothing stale
  behind. Needed when the measurement itself has changed, because nothing can detect that — redefining a function's body in place leaves
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
"""
    _hasGSAResults(gsa_sampling, q) → Bool

Whether `gsa_sampling` already holds results for `q`, decided from `q`'s name before evaluating it.
Exact rather than heuristic, because a [`QoI`](@ref) name cannot contain the `.` separator.
"""
_hasGSAResults(gsa_sampling::GSASampling, q::QoI) =
    any(k -> _isQoILabelOf(k, q.name), keys(gsa_sampling.results))

"""
    _gsaLabelsOf(gsa_sampling, name) → Vector{String}

Every label in `gsa_sampling.results` that a QoI called `name` produced.
"""
_gsaLabelsOf(gsa_sampling::GSASampling, name::AbstractString) =
    filter(k -> _isQoILabelOf(k, name), collect(keys(gsa_sampling.results)))

#! Computes without storing. Split out so the vector method above can see every label a call will
#! produce before it commits any of them.
"""
    _gsaResults(gsa_sampling, f) → Vector{Pair{String,result}}

The sensitivity indices `f` yields on `gsa_sampling`, one labelled entry per quantity it measures.
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

function _gsaResults(moat_sampling::MOATSampling, f::Union{Function,QoI})
    out = Pair{String,GlobalSensitivity.MorrisResult}[]
    for (label, vals) in evaluateFunctionOnSampling(moat_sampling, f)
        effects = 2 * (vals[:,2:end] .- vals[:,1])
        means = mean(effects, dims=1)
        means_star = mean(abs.(effects), dims=1)
        variances = var(effects, dims=1)
        push!(out, label => GlobalSensitivity.MorrisResult(means, means_star, variances, effects))
    end
    return out
end

############# Sobolʼ Indices #############

"""
    Sobolʼ <: GSAMethod

Sobol' variance-based global sensitivity analysis.

The `ʼ` (rasp) symbol avoids conflict with the `Sobol` module. Type `\\rasp<tab>` in VS Code.
[`SobolMM`](@ref) is provided as a plain-ASCII alias.

# Fields
- `sobol_variation::SobolVariation`
- `sobol_index_methods::NamedTuple{(:first_order,:total_order),Tuple{Symbol,Symbol}}`

# Examples
```julia
Sobolʼ(15)
Sobolʼ(15; sobol_index_methods=(first_order=:Jansen1999, total_order=:Jansen1999))
Sobolʼ(15; skip_start=true)
```
"""
struct Sobolʼ <: GSAMethod
    sobol_variation::SobolVariation
    sobol_index_methods::NamedTuple{(:first_order,:total_order),Tuple{Symbol,Symbol}}
end

Sobolʼ(n::Int; sobol_index_methods::NamedTuple{(:first_order,:total_order),Tuple{Symbol,Symbol}}=(first_order=:Jansen1999, total_order=:Jansen1999), kwargs...) =
    Sobolʼ(SobolVariation(n; n_matrices=2, kwargs...), sobol_index_methods)

"""
    SobolMM

ASCII alias for [`Sobolʼ`](@ref).
"""
const SobolMM = Sobolʼ

"""
    SobolSampling <: GSASampling

Result of a [`Sobolʼ`](@ref) sensitivity analysis.
"""
struct SobolSampling <: GSASampling
    sampling::Sampling
    monad_ids_df::DataFrame
    results::Dict{String,GlobalSensitivity.SobolResult}
    sobol_index_methods::NamedTuple{(:first_order,:total_order),Tuple{Symbol,Symbol}}
end

SobolSampling(sampling::Sampling, monad_ids_df::DataFrame; sobol_index_methods::NamedTuple{(:first_order,:total_order),Tuple{Symbol,Symbol}}=(first_order=:Jansen1999, total_order=:Jansen1999)) =
    SobolSampling(sampling, monad_ids_df, Dict{String,GlobalSensitivity.SobolResult}(), sobol_index_methods)

function Base.show(io::IO, sobol_sampling::SobolSampling)
    println(io, "Sobol sampling")
    println(io, "--------------")
    println(io, sobol_sampling.sampling)
    println(io, "Sobol index methods:")
    println(io, "  First order: $(sobol_sampling.sobol_index_methods.first_order)")
    println(io, "  Total order: $(sobol_sampling.sobol_index_methods.total_order)")
    println(io, "Sensitivity quantities calculated:")
    for label in gsaLabels(sobol_sampling)
        println(io, "  $label")
    end
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
    variation_ids_Aᵦ = stack(focus_indices) do i
        Aᵦ = copy(A)
        Aᵦ[i,:] .= B[i,:]
        addCDFVariations(inputs, pv, reference_variation_id, Aᵦ)
    end
    monads = variationsToMonads(inputs, hcat(variation_ids, variation_ids_Aᵦ))
    monad_ids = [monad.id for monad in monads]
    all_latent_names = mapreduce(lv -> lv.latent_parameter_names, vcat, pv.latent_variations)
    perturb_headers = all_latent_names[focus_indices]
    header_line = ["A"; "B"; perturb_headers]
    monad_ids_df = DataFrame(monad_ids, header_line)
    sampling = buildAndRunSensitivitySampling(method, monads;
                                              n_replicates=n_replicates, use_previous=use_previous, kwargs...)
    return SobolSampling(sampling, monad_ids_df; sobol_index_methods=method.sobol_index_methods)
end

function _gsaResults(sobol_sampling::SobolSampling, f::Union{Function,QoI})
    out = Pair{String,GlobalSensitivity.SobolResult}[]
    for (label, vals) in evaluateFunctionOnSampling(sobol_sampling, f)
        push!(out, label => _sobolResult(sobol_sampling, vals))
    end
    return out
end

function _sobolResult(sobol_sampling::SobolSampling, vals::Matrix{Float64})
    d = size(vals, 2) - 2
    A_values = @view vals[:, 1]
    B_values = @view vals[:, 2]
    Aᵦ_values = [vals[:, 2+i] for i in 1:d]
    expected_value² = mean(A_values .* B_values)
    total_variance = var([A_values; B_values])
    first_order_variances = zeros(Float64, d)
    total_order_variances = zeros(Float64, d)
    si_method = sobol_sampling.sobol_index_methods.first_order
    st_method = sobol_sampling.sobol_index_methods.total_order
    for (i, Aᵦ) in enumerate(Aᵦ_values)
        if si_method == :Sobol1993
            first_order_variances[i] = mean(B_values .* Aᵦ) .- expected_value²
        elseif si_method == :Jansen1999
            first_order_variances[i] = total_variance - 0.5 * mean((B_values .- Aᵦ) .^ 2)
        elseif si_method == :Saltelli2010
            first_order_variances[i] = mean(B_values .* (Aᵦ .- A_values))
        end
        if st_method == :Homma1996
            total_order_variances[i] = total_variance - mean(A_values .* Aᵦ) + expected_value²
        elseif st_method == :Jansen1999
            total_order_variances[i] = 0.5 * mean((Aᵦ .- A_values) .^ 2)
        elseif st_method == :Sobol2007
            total_order_variances[i] = mean(A_values .* (A_values .- Aᵦ))
        end
    end
    first_order_indices = first_order_variances ./ total_variance
    total_order_indices = total_order_variances ./ total_variance
    return GlobalSensitivity.SobolResult(first_order_indices, nothing, nothing, nothing, total_order_indices, nothing)
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

function _gsaResults(rbd_sampling::RBDSampling, f::Union{Function,QoI})
    out = Pair{String,Vector{<:Real}}[]
    for (label, vals) in evaluateFunctionOnSampling(rbd_sampling, f)
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
    evaluateFunctionOnSampling(gsa_sampling, f) → Vector{Pair{String,Matrix{Float64}}}

Evaluate `f` on every monad in the sampling and return one labelled matrix per quantity it measures.

Each matrix is shaped like [`getMonadIDDataFrame`](@ref)`(gsa_sampling)` — one entry per cell of the
method's design, holding that monad's reduced value — which is the layout each method's index
arithmetic reads. A [`QoI`](@ref) whose `reduce` returns a `Real` gives one such matrix; one that
returns a `Dict` or `NamedTuple` gives one per key.
"""
function evaluateFunctionOnSampling(gsa_sampling::GSASampling, f::Union{Function,QoI})
    #! A bare `Function` is wrapped into a `QoI` here, so the rest of this works on one object with
    #! one contract: `compute` gets a `Simulation`, `reduce` combines the replicates (`mean` for a
    #! wrapped function, which is what this always did).
    q = _asQoI(f)
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
    reduced = Dict{Int,Any}()
    for monad_id in monad_ids
        haskey(reduced, monad_id) && continue
        reduced[monad_id] = _reduceOverMonad(q, monad_id)
    end

    #! Every monad is checked, not just the first. A key set that differs anywhere leaves a hole in
    #! that key's design matrix, and there is no defensible value to fill it with. A sensitivity
    #! index computed over a hole is wrong rather than approximate, so this refuses instead. The
    #! same reasoning covers a monad that reduced to `missing`; `_qoiComponentKeys` has a method for
    #! it so the message says no replicate produced a value rather than naming a type.
    reference_id = first(monad_ids)
    component_keys = _qoiComponentKeys(q, reduced[reference_id], reference_id)
    #! Walked in DESIGN order, so the monad an error names is the first mismatch someone scanning
    #! their design would reach -- iterating `reduced` instead would name whichever monad hashing
    #! happens to visit first, which is reproducible but not meaningful. Each DISTINCT monad is
    #! checked once, because a design can place the same monad in many cells: RBD's matrix is one set
    #! of variations permuted per column, so every column repeats them all.
    checked = Set{Int}()
    for monad_id in monad_ids
        monad_id in checked && continue
        push!(checked, monad_id)
        _qoiComponentKeys(q, reduced[monad_id], monad_id) == component_keys || throw(ArgumentError(
            "QoI \"$(q.name)\": every monad must reduce to the same keys, since each key becomes " *
            "its own sensitivity analysis and needs a value from every monad in the design. Monad " *
            "$(reference_id) gave $(repr(component_keys)) but monad $(monad_id) gave " *
            "$(repr(_qoiComponentKeys(q, reduced[monad_id], monad_id)))."))
    end

    #! An empty `Dict`/`NamedTuple` is not "no components" -- it is a reducer that named nothing, and
    #! silently storing no result for a QoI the user explicitly asked for is the kind of quiet
    #! nothing this path exists to avoid. It would also never be marked evaluated, so every later
    #! call would re-read every simulation's output to store nothing again.
    isnothing(component_keys) || !isempty(component_keys) || throw(ArgumentError(
        "QoI \"$(q.name)\": its `reduce` returned an empty $(typeof(reduced[reference_id])), so it " *
        "names no quantities and there is nothing to analyse. Return a `Real`, or a " *
        "`Dict`/`NamedTuple` with at least one key."))
    labels = isnothing(component_keys) ? [q.name] : [_qoiLabel(q.name, k) for k in component_keys]
    #! Checked HERE, where the keys are still in hand, because afterwards only the labels survive.
    #! Two distinct keys can land on one label -- `1` and `"1"`, the same collision the sink guards
    #! against -- and neither downstream path handles it: `calculateGSA!`'s cross-QoI check reports
    #! "comes from both QoI \"q\" and QoI \"q\". Rename one of them", advice that cannot work,
    #! while the single-measurement method has no such check and simply lets one analysis overwrite
    #! the other.
    allunique(labels) || throw(ArgumentError(
        "QoI \"$(q.name)\": " * _qoiDuplicateLabelMessage(component_keys, labels)))
    out = Pair{String,Matrix{Float64}}[]
    for (i, label) in enumerate(labels)
        vals = zeros(Float64, size(monad_id_df))
        for (ind, monad_id) in enumerate(monad_ids)
            v = reduced[monad_id]
            vals[ind] = _qoiComponentValue(q, label, monad_id,
                                           isnothing(component_keys) ? v : v[component_keys[i]])
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
