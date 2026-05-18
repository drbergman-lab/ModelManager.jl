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
    methodString(gsa_sampling::GSASampling)

Return a lowercase string identifier for the GSA method (e.g. `"moat"`, `"sobol"`).
"""
function methodString(gsa_sampling::GSASampling)
    method = typeof(gsa_sampling) |> string |> lowercase
    method = split(method, ".")[end]
    return endswith(method, "sampling") ? method[1:end-8] : method
end

"""
    run(method::GSAMethod, inputs::InputFolders, avs; functions, kwargs...)
    run(method::GSAMethod, reference::AbstractMonad, avs; functions, kwargs...)

Run a global sensitivity analysis and return a [`GSASampling`](@ref) result.

`kwargs` are forwarded to [`run`](@ref)`(::Sampling; ...)` and from there to the
simulator hooks — pass any simulator-specific options here.
"""
function run(method::GSAMethod, inputs::InputFolders, avs::AbstractVector{<:AbstractVariation}; functions::AbstractVector{<:Function}=Function[], kwargs...)
    pv = ParsedVariations(avs)
    gsa_sampling = runSensitivitySampling(method, inputs, pv; kwargs...)
    sensitivityResults!(gsa_sampling, functions)
    return gsa_sampling
end

function run(method::GSAMethod, reference::AbstractMonad, avs::Vector{<:AbstractVariation}; functions::AbstractVector{<:Function}=Function[], kwargs...)
    return run(method, reference.inputs, avs; reference_variation_id=reference.variation_id, functions, kwargs...)
end

function run(method::GSAMethod, inputs_or_ref::Union{InputFolders,AbstractMonad}, av1::AbstractVariation, avs::Vararg{AbstractVariation}; kwargs...)
    return run(method, inputs_or_ref, [av1; avs...]; kwargs...)
end

"""
    sensitivityResults!(gsa_sampling, functions)

Calculate sensitivity indices for `functions` and record the sampling scheme.
"""
function sensitivityResults!(gsa_sampling::GSASampling, functions::AbstractVector{<:Function})
    calculateGSA!(gsa_sampling, functions)
    recordSensitivityScheme(gsa_sampling)
end

"""
    calculateGSA!(gsa_sampling, functions)

Calculate sensitivity indices for each function in `functions`.
"""
function calculateGSA!(gsa_sampling::GSASampling, functions::AbstractVector{<:Function})
    for f in functions
        calculateGSA!(gsa_sampling, f)
    end
    return
end

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
    results::Dict{Function,GlobalSensitivity.MorrisResult}
end

MOATSampling(sampling::Sampling, monad_ids_df::DataFrame) = MOATSampling(sampling, monad_ids_df, Dict{Function,GlobalSensitivity.MorrisResult}())

function Base.show(io::IO, moat_sampling::MOATSampling)
    println(io, "MOAT sampling")
    println(io, "-------------")
    println(io, moat_sampling.sampling)
    println(io, "Sensitivity functions calculated:")
    for f in keys(moat_sampling.results)
        println(io, "  $f")
    end
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
    sampling = Sampling(unique(monads); n_replicates=n_replicates, use_previous=use_previous)
    run(sampling; kwargs...)
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

function calculateGSA!(moat_sampling::MOATSampling, f::Function)
    if f in keys(moat_sampling.results)
        return
    end
    vals = evaluateFunctionOnSampling(moat_sampling, f)
    effects = 2 * (vals[:,2:end] .- vals[:,1])
    means = mean(effects, dims=1)
    means_star = mean(abs.(effects), dims=1)
    variances = var(effects, dims=1)
    moat_sampling.results[f] = GlobalSensitivity.MorrisResult(means, means_star, variances, effects)
    return
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
    results::Dict{Function,GlobalSensitivity.SobolResult}
    sobol_index_methods::NamedTuple{(:first_order,:total_order),Tuple{Symbol,Symbol}}
end

SobolSampling(sampling::Sampling, monad_ids_df::DataFrame; sobol_index_methods::NamedTuple{(:first_order,:total_order),Tuple{Symbol,Symbol}}=(first_order=:Jansen1999, total_order=:Jansen1999)) =
    SobolSampling(sampling, monad_ids_df, Dict{Function,GlobalSensitivity.SobolResult}(), sobol_index_methods)

function Base.show(io::IO, sobol_sampling::SobolSampling)
    println(io, "Sobol sampling")
    println(io, "--------------")
    println(io, sobol_sampling.sampling)
    println(io, "Sobol index methods:")
    println(io, "  First order: $(sobol_sampling.sobol_index_methods.first_order)")
    println(io, "  Total order: $(sobol_sampling.sobol_index_methods.total_order)")
    println(io, "Sensitivity functions calculated:")
    for f in keys(sobol_sampling.results)
        println(io, "  $f")
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
    sampling = Sampling(unique(monads); n_replicates=n_replicates, use_previous=use_previous)
    run(sampling; kwargs...)
    return SobolSampling(sampling, monad_ids_df; sobol_index_methods=method.sobol_index_methods)
end

function calculateGSA!(sobol_sampling::SobolSampling, f::Function)
    if f in keys(sobol_sampling.results)
        return
    end
    vals = evaluateFunctionOnSampling(sobol_sampling, f)
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
    sobol_sampling.results[f] = GlobalSensitivity.SobolResult(first_order_indices, nothing, nothing, nothing, total_order_indices, nothing)
    return
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
    results::Dict{Function,Vector{<:Real}}
    num_harmonics::Int
    num_cycles::Union{Int,Rational}
end

RBDSampling(sampling::Sampling, monad_ids_df::DataFrame, num_cycles; num_harmonics::Int=6) =
    RBDSampling(sampling, monad_ids_df, Dict{Function,Vector{<:Real}}(), num_harmonics, num_cycles)

function Base.show(io::IO, rbd_sampling::RBDSampling)
    println(io, "RBD sampling")
    println(io, "------------")
    println(io, rbd_sampling.sampling)
    println(io, "Number of harmonics: $(rbd_sampling.num_harmonics)")
    println(io, "Number of cycles (1/2 or 1): $(rbd_sampling.num_cycles)")
    println(io, "GSA functions:")
    for f in keys(rbd_sampling.results)
        println(io, "  $f")
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
    sampling = Sampling(unique(monads); n_replicates=n_replicates, use_previous=use_previous)
    run(sampling; kwargs...)
    return RBDSampling(sampling, monad_ids_df, method.rbd_variation.num_cycles; num_harmonics=method.num_harmonics)
end

function calculateGSA!(rbd_sampling::RBDSampling, f::Function)
    if f in keys(rbd_sampling.results)
        return
    end
    vals = evaluateFunctionOnSampling(rbd_sampling, f)
    if rbd_sampling.num_cycles == 1 // 2
        vals = vcat(vals, vals[end-1:-1:2, :])
    end
    ys = fft(vals, 1) .|> abs2
    ys ./= size(vals, 1)
    V = sum(ys[2:end, :], dims=1)
    Vi = 2 * sum(ys[2:(min(size(ys, 1), rbd_sampling.num_harmonics + 1)), :], dims=1)
    rbd_sampling.results[f] = (Vi ./ V) |> vec
    return
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
    evaluateFunctionOnSampling(gsa_sampling, f)

Evaluate `f` (a function of `simulation_id`) on each monad in the sampling, averaging replicates.
"""
function evaluateFunctionOnSampling(gsa_sampling::GSASampling, f::Function)
    monad_id_df = getMonadIDDataFrame(gsa_sampling)
    value_dict = Dict{Int,Float64}()
    vals = zeros(Float64, size(monad_id_df))
    for (ind, monad_id) in enumerate(monad_id_df |> Matrix)
        if !haskey(value_dict, monad_id)
            simulation_ids = constituentIDs(Monad, monad_id)
            sim_values = [f(simulation_id) for simulation_id in simulation_ids]
            value_dict[monad_id] = mean(sim_values)
        end
        vals[ind] = value_dict[monad_id]
    end
    return vals
end

"""
    variationsToMonads(inputs, variation_ids)

Return an array of `Monad`s matching the shape of `variation_ids`.
"""
function variationsToMonads(inputs::InputFolders, variation_ids::AbstractArray{VariationID})
    monad_dict = Dict{VariationID,Monad}()
    return [get!(monad_dict, variation_id, Monad(inputs, variation_id)) for variation_id in variation_ids]
end
