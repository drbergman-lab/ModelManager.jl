using LinearAlgebra: Symmetric, I, Diagonal, cholesky, Cholesky, dot, diag
using Distributions: pdf
using Statistics: mean
using Sobol

################## ABC-SMC Core Algorithm ##################
#
# This file is framework-agnostic: the ABC-SMC loop operates on a generic
# `evaluate_batch` callback. Simulator-specific wiring (Monad creation,
# addVariations, Sampling assembly, run) is handled by the caller in abc.jl.
#
# Parallelism strategy
# --------------------
# Rather than evaluating one particle at a time, each generation proposes a
# batch of candidate parameter vectors and hands the entire batch to
# `evaluate_batch`. The callback runs all candidates concurrently (via a
# Sampling) and returns results in proposal order.
#
#   Generation 1  — one batch of exactly `population_size` proposals (all accepted).
#   Generation t  — iterative adaptive batching:
#                   batch_size = ceil(n_needed / acceptance_rate_est)
#                   Repeat until `population_size` particles accepted; trim overshoot.
#

################## Fitted Kernel Structs ##################

abstract type AbstractFittedKernel end

struct FittedGaussianKernel <: AbstractFittedKernel
    Sigma::Matrix{Float64}
    chol::Cholesky{Float64, Matrix{Float64}}
    d::Int
end

struct FittedComponentwiseKernel <: AbstractFittedKernel
    variances::Vector{Float64}
    d::Int
end

struct FittedLocalNNKernel <: AbstractFittedKernel
    tree::KDTree
    X::Matrix{Float64}            # d × N_prev
    bandwidths::Vector{Float64}   # h_j per particle
    Sigma_global::Matrix{Float64}
    global_chol::Cholesky{Float64, Matrix{Float64}}
    d::Int
    N_prev::Int
end

struct FittedLocalNNCovKernel <: AbstractFittedKernel
    tree::KDTree
    X::Matrix{Float64}            # d × N_prev
    chols::Vector{Cholesky{Float64, Matrix{Float64}}}
    d::Int
    N_prev::Int
end

################## Kernel Fitting ##################

# Minimum diagonal variance for the perturbation kernel, derived from the CDF grid spacing
# at the effective resolution k_eff.  Ensures proposals can reach neighbouring grid cells
# even when all particles have collapsed to a single point (Cov → 0).
# Without snapping (k_eff = nothing) fall back to the numerical regularisation floor.
_minDiagVar(::Nothing) = 1e-10
_minDiagVar(k_eff::Int) = (1.0 / 2^(k_eff + 1))^2

"""
    _fitKernel(kernel, particles, weights, param_names, t; k_eff) → AbstractFittedKernel

Fit the perturbation kernel to the previous generation's weighted particles. Called once
per generation before proposals are drawn.

`k_eff` is the effective CDF grid resolution for this generation. When provided, the
minimum diagonal variance is set to `(1/2^(k_eff+1))^2` so perturbations span at least
one grid cell even if particles have collapsed to a single point.
"""
function _fitKernel(kernel::GaussianKernel, particles::DataFrame,
                    weights::Vector{Float64}, param_names::Vector{String}, t::Int;
                    k_eff::Union{Int,Nothing}=nothing)
    s = _effectiveKernelScale(kernel.scale, t)
    d = length(param_names)
    X = Matrix{Float64}(particles[!, param_names])   # N × d
    mu = vec(sum(weights .* X, dims=1))
    Xc = X .- mu'
    min_var = _minDiagVar(k_eff)
    Sigma = s * (Symmetric(Xc' * Diagonal(weights) * Xc) + min_var * I(d))
    c = cholesky(Sigma)
    return FittedGaussianKernel(Matrix(Sigma), c, d)
end

function _fitKernel(kernel::ComponentwiseKernel, particles::DataFrame,
                    weights::Vector{Float64}, param_names::Vector{String}, t::Int;
                    k_eff::Union{Int,Nothing}=nothing)
    s = _effectiveKernelScale(kernel.scale, t)
    d = length(param_names)
    X = Matrix{Float64}(particles[!, param_names])   # N × d
    mu = vec(sum(weights .* X, dims=1))
    min_var = _minDiagVar(k_eff)
    vars = s .* max.(vec(sum(weights .* (X .- mu').^2, dims=1)), min_var)
    return FittedComponentwiseKernel(vars, d)
end

function _fitKernel(kernel::LocalNNKernel, particles::DataFrame,
                    weights::Vector{Float64}, param_names::Vector{String}, t::Int;
                    k_eff::Union{Int,Nothing}=nothing)
    d = length(param_names)
    X = Matrix{Float64}(particles[!, param_names])'  # d × N
    N = size(X, 2)
    k_nn = min(kernel.k, N - 1)
    tree = KDTree(X, Chebyshev())
    _, dists = knn(tree, X, k_nn + 1, true)  # k_nn+1 so self (dist=0) is included
    mu = vec(sum(weights .* X', dims=1))
    Xc = X' .- mu'
    min_var = _minDiagVar(k_eff)
    Sigma_global = Symmetric(Xc' * Diagonal(weights) * Xc) + min_var * I(d)
    Sg = Matrix(Sigma_global)
    # Adaptive bandwidth floor: ensure h² · Σ[i,i] ≥ min_var for all i.
    # min_diag(Sg) = min_var when collapsed, so floor = 1.0; smaller when well-spread.
    min_bw = sqrt(min_var / minimum(diag(Sg)))
    bandwidths = max.(kernel.scale .* [ds[end] for ds in dists], min_bw)
    return FittedLocalNNKernel(tree, X, bandwidths, Sg, cholesky(Sg), d, N)
end

function _fitKernel(kernel::LocalNNCovKernel, particles::DataFrame,
                    weights::Vector{Float64}, param_names::Vector{String}, t::Int;
                    k_eff::Union{Int,Nothing}=nothing)
    d = length(param_names)
    X = Matrix{Float64}(particles[!, param_names])'  # d × N
    N = size(X, 2)
    k_nn = min(kernel.k, N - 1)
    tree = KDTree(X, Chebyshev())
    idxs, _ = knn(tree, X, k_nn + 1, true)  # +1 to include self; neighbors are [2:end]
    min_var = _minDiagVar(k_eff)

    chols = map(1:N) do j
        neighbor_cols = X[:, idxs[j][2:end]]   # d × k_nn (exclude self)
        mu_local = vec(mean(neighbor_cols, dims=2))
        Xc = neighbor_cols .- mu_local
        Sigma_local = kernel.scale * (Symmetric(Xc * Xc' / k_nn) + min_var * I(d))
        cholesky(Matrix(Sigma_local))
    end

    return FittedLocalNNCovKernel(tree, X, chols, d, N)
end

################## Kernel Proposal ##################

"""
    _proposeParticle(fitted, parent_particle, param_names) → Dict or nothing

Perturb a parent particle using the fitted kernel. Returns `nothing` if the perturbed
particle falls outside `[0, 1]` in any dimension (rejection step).
"""
function _proposeParticle(fitted::FittedGaussianKernel, parent::Dict{String,Float64},
                          param_names::Vector{String})
    z = fitted.chol.L * randn(fitted.d)
    proposal = Dict{String,Float64}()
    for (i, name) in enumerate(param_names)
        val = parent[name] + z[i]
        (0.0 <= val <= 1.0) || return nothing
        proposal[name] = val
    end
    return proposal
end

function _proposeParticle(fitted::FittedComponentwiseKernel, parent::Dict{String,Float64},
                          param_names::Vector{String})
    proposal = Dict{String,Float64}()
    for (i, name) in enumerate(param_names)
        val = parent[name] + sqrt(fitted.variances[i]) * randn()
        (0.0 <= val <= 1.0) || return nothing
        proposal[name] = val
    end
    return proposal
end

function _proposeParticle(fitted::FittedLocalNNKernel, parent::Dict{String,Float64},
                          param_names::Vector{String})
    parent_vec = [parent[name] for name in param_names]
    j_idxs, _ = knn(fitted.tree, parent_vec, 1)
    h = fitted.bandwidths[j_idxs[1]]
    z = h .* (fitted.global_chol.L * randn(fitted.d))
    proposal = Dict{String,Float64}()
    for (i, name) in enumerate(param_names)
        val = parent[name] + z[i]
        (0.0 <= val <= 1.0) || return nothing
        proposal[name] = val
    end
    return proposal
end

function _proposeParticle(fitted::FittedLocalNNCovKernel, parent::Dict{String,Float64},
                          param_names::Vector{String})
    parent_vec = [parent[name] for name in param_names]
    j_idxs, _ = knn(fitted.tree, parent_vec, 1)
    z = fitted.chols[j_idxs[1]].L * randn(fitted.d)
    proposal = Dict{String,Float64}()
    for (i, name) in enumerate(param_names)
        val = parent[name] + z[i]
        (0.0 <= val <= 1.0) || return nothing
        proposal[name] = val
    end
    return proposal
end

################## Kernel Density ##################

"""
    _kernelDensity(fitted, from_particle, to_particle, param_names) → Float64

Evaluate the kernel density K(to | from) — used in the importance weight denominator.
"""
function _kernelDensity(fitted::FittedGaussianKernel, from::Dict{String,Float64},
                        to::Dict{String,Float64}, param_names::Vector{String})
    diff = [to[n] - from[n] for n in param_names]
    d = fitted.d
    log_det = 2 * sum(log(fitted.chol.U[i, i]) for i in 1:d)
    quad = dot(diff, fitted.chol \ diff)
    return exp(-quad / 2 - log_det / 2 - (d / 2) * log(2π))
end

function _kernelDensity(fitted::FittedComponentwiseKernel, from::Dict{String,Float64},
                        to::Dict{String,Float64}, param_names::Vector{String})
    p = 1.0
    for (i, n) in enumerate(param_names)
        σ2 = fitted.variances[i]
        p *= exp(-((to[n] - from[n])^2) / (2σ2)) / sqrt(2π * σ2)
    end
    return p
end

function _kernelDensity(fitted::FittedLocalNNKernel, from::Dict{String,Float64},
                        to::Dict{String,Float64}, param_names::Vector{String})
    from_vec = [from[n] for n in param_names]
    j_idxs, _ = knn(fitted.tree, from_vec, 1)
    h = fitted.bandwidths[j_idxs[1]]
    h2 = h^2
    diff = [to[n] - from[n] for n in param_names]
    d = fitted.d
    # log|h² Σ| = d·log(h²) + log|Σ|; log|Σ| = 2·Σ log(U_kk)
    log_det_Sigma = 2 * sum(log(fitted.global_chol.U[i, i]) for i in 1:d)
    log_det = d * log(h2) + log_det_Sigma
    # (h² Σ)^{-1} diff = (1/h²) Σ^{-1} diff
    v = fitted.global_chol \ diff
    quad = dot(diff, v) / h2
    return exp(-quad / 2 - log_det / 2 - (d / 2) * log(2π))
end

function _kernelDensity(fitted::FittedLocalNNCovKernel, from::Dict{String,Float64},
                        to::Dict{String,Float64}, param_names::Vector{String})
    from_vec = [from[n] for n in param_names]
    j_idxs, _ = knn(fitted.tree, from_vec, 1)
    c = fitted.chols[j_idxs[1]]
    diff = [to[n] - from[n] for n in param_names]
    d = fitted.d
    log_det = 2 * sum(log(c.U[i, i]) for i in 1:d)
    quad = dot(diff, c \ diff)
    return exp(-quad / 2 - log_det / 2 - (d / 2) * log(2π))
end

"""
    _ParticleResult

Internal: result of evaluating a single ABC-SMC particle.
"""
struct _ParticleResult
    latent_cdfs::Dict{String,Float64}
    distance::Float64
    metadata::Any  # caller-specific payload (e.g., monad_id)
end

"""
    _runABCSMC(method, param_names, priors, evaluate_batch, on_generation;
               bank, start_generations, verbosity)

Run the ABC-SMC algorithm. This is the framework-agnostic core.

Generation 1 samples fresh from the prior (no warm-start bias). Exact-match reuse of
previously evaluated parameter points is handled by the caller's `evaluate_batch`
(e.g. `Monad(...; use_previous=true)`) — this keeps the gen-1 population an
unbiased prior sample while still avoiding redundant simulation work.

# Arguments
- `method::ABCSMC`: Algorithm settings.
- `param_names::Vector{String}`: Parameter names (column order in results).
- `priors::Vector{<:Distribution}`: Prior distributions, one per parameter.
- `evaluate_batch::Function`: `(t::Int, proposals::Vector{Tuple{Dict{String,Float64},Union{Nothing,Int}}}) →
  Vector{Tuple{Float64,Any}}`. Each proposal is `(latent_cdfs, known_mid)` where `known_mid`
  is an `Int` for bank/mid-generation reuses and `nothing` for fresh grid snaps.
  Returns `(distance, monad_id)` for each in the same order. Receiving `t` allows the
  caller to route provenance records to a per-generation file.
- `on_generation::Function`: `(gen::GenerationResult) → nothing`.
  Called after each completed generation (for persistence / logging).
- `bank::SimulationBank`: Pre-built registry of existing monads in CDF space, built once
  at calibration start by `_buildSimulationBank`. Passed through to generation runners
  for use by the CDF-grid snapping proposal logic. Defaults to an empty bank
  (snapping disabled).
- `start_generations::Vector{GenerationResult}`: Previously-completed generations to
  resume from (empty for a fresh run).
- `verbosity::Symbol`: Resolved console-feedback level (see [`_resolveVerbosity`](@ref)).
  `:generation` (the default) and higher emit the generation-start, generation-finish,
  and stopping-reason `@info` lines; `:none` suppresses them entirely.

# Returns
`Vector{GenerationResult}`: All completed generations (including resumed ones).
"""
function _runABCSMC(method::ABCSMC, param_names::Vector{String},
                    priors::Vector{<:Distribution}, evaluate_batch::Function,
                    on_generation::Function;
                    bank::SimulationBank=SimulationBank(Int[], Matrix{Float64}(undef, 0, 0), String[]),
                    start_generations::Vector{GenerationResult}=GenerationResult[],
                    verbosity::Symbol=:generation)

    # ── k_base correction ────────────────────────────────────────────────────
    # Ensure the effective base resolution is large enough that the grid has at
    # least population_size interior points: (2^k - 1)^d ≥ N.
    # k_min = ceil(log2(N^(1/d) + 1)).  Computed once; no struct mutation needed.
    k_base_eff = if !isnothing(method.cdf_grid_k)
        n_dims = length(param_names)
        N      = method.population_size
        k_min  = ceil(Int, log2(N ^ (1.0 / n_dims) + 1))
        kb     = max(method.cdf_grid_k, k_min)
        if kb > method.cdf_grid_k
            @info "ABC-SMC: cdf_grid_k=$(method.cdf_grid_k) is too coarse for " *
                  "population_size=$N in $n_dims dims (need k≥$k_min); " *
                  "raising effective base to $kb."
        end
        kb
    else
        nothing
    end

    # ── Evaluation budget ────────────────────────────────────────────────────
    # budget[] accumulates total evaluated particles across all generations
    # (including any already-completed ones from start_generations).
    n_evals_prior = isempty(start_generations) ? 0 :
                    sum(gen.n_evaluations for gen in start_generations)
    budget      = Ref(n_evals_prior)
    budget_hit  = Ref(false)

    generations = copy(start_generations)
    t_start = length(generations) + 1
    snap_active = !isnothing(k_base_eff)

    # mid_gen_additions: new grid snaps from the current generation, used within the
    # generation for lightweight intra-generation reuse and absorbed into the bank
    # between generations via _updateBankFromGeneration.
    mid_gen_additions = Tuple{Vector{Float64},Int}[]

    for t in t_start:method.max_nr_populations
        empty!(mid_gen_additions)

        if t == 1
            _logGenerationStart(verbosity, 1, nothing, method.population_size)
            gen = _runFirstGeneration(method, param_names, priors, evaluate_batch, bank;
                                      k_base_eff=k_base_eff,
                                      mid_gen_additions=mid_gen_additions,
                                      budget=budget, budget_hit=budget_hit)
        else
            prev = generations[end]
            epsilon_t = if !isnothing(method.epsilon_schedule) &&
                           t - 1 <= length(method.epsilon_schedule)
                method.epsilon_schedule[t - 1]
            else
                _adaptEpsilon(prev.distances, method.epsilon_quantile, method.minimum_epsilon)
            end
            _logGenerationStart(verbosity, t, epsilon_t, method.population_size)
            gen = _runSubsequentGeneration(method, param_names, priors, evaluate_batch,
                                           prev, epsilon_t, t, bank;
                                           k_base_eff=k_base_eff,
                                           mid_gen_additions=mid_gen_additions,
                                           budget=budget, budget_hit=budget_hit)
        end

        # Absorb this generation's new grid evaluations into the bank before the next.
        snap_active && (bank = _updateBankFromGeneration(bank, mid_gen_additions))

        push!(generations, gen)
        on_generation(gen)

        if _verbosityRank(verbosity) >= _verbosityRank(:generation)
            n_accepted = length(gen.distances)
            @info "ABC-SMC generation $(gen.t): " *
                  "ε=$(round(gen.epsilon; digits=6)), " *
                  "$(n_accepted)/$(gen.n_evaluations) proposals accepted " *
                  "($(round(100*gen.acceptance_rate; digits=1))%), " *
                  "ESS=$(round(gen.ess; digits=1)) " *
                  "($(round(100 * gen.ess / n_accepted; digits=1))%)"
        end

        stop_reason = _stoppingReason(method, generations; budget_hit=budget_hit[])
        if !isnothing(stop_reason)
            _verbosityRank(verbosity) >= _verbosityRank(:generation) &&
                @info "ABC-SMC: $stop_reason — stopping."
            break
        end
    end

    return generations
end

"""
    _stoppingReason(method, generations; budget_hit=false) → Union{Nothing, String}

Check all stopping criteria against the most recent generation. Returns a human-readable
reason string if any criterion is met, `nothing` otherwise.

`budget_hit=true` is checked first and supersedes all other criteria.
"""
function _stoppingReason(method::ABCSMC, generations::Vector{GenerationResult};
                         budget_hit::Bool=false)
    isempty(generations) && return nothing

    budget_hit &&
        return "max_evaluations=$(method.max_evaluations) reached"

    gen = generations[end]

    gen.epsilon <= method.minimum_epsilon &&
        return "ε=$(round(gen.epsilon; digits=6)) reached minimum_epsilon ($(method.minimum_epsilon))"

    method.min_acceptance_rate > 0.0 &&
        gen.acceptance_rate < method.min_acceptance_rate &&
        return "acceptance rate ($(round(gen.acceptance_rate; digits=4))) " *
               "below min_acceptance_rate ($(method.min_acceptance_rate))"

    if method.min_ess_fraction > 0.0
        ess_frac = gen.ess / method.population_size
        if ess_frac < method.min_ess_fraction
            n_accepted = length(gen.distances)
            # When accept_overflow produced more particles than population_size, the ESS
            # fraction used here (ESS/population_size) differs from the one shown in the
            # generation log (ESS/n_accepted). Add a note so the user isn't confused.
            note = n_accepted != method.population_size ?
                " (note: generation log showed " *
                "ESS/n_accepted=ESS/$(n_accepted)=$(round(100*gen.ess/n_accepted; digits=1))%; " *
                "stopping criterion uses " *
                "ESS/population_size=ESS/$(method.population_size)=$(round(100*ess_frac; digits=1))%)" : ""
            return "ESS fraction ($(round(ess_frac; digits=4))) " *
                   "below min_ess_fraction ($(method.min_ess_fraction))" *
                   note
        end
    end

    if method.min_epsilon_decrease > 0.0 && length(generations) > 1
        prev_eps = generations[end - 1].epsilon
        if prev_eps > 0.0
            rel_decrease = (prev_eps - gen.epsilon) / prev_eps
            rel_decrease < method.min_epsilon_decrease &&
                return "relative ε decrease ($(round(rel_decrease; digits=4))) " *
                       "below min_epsilon_decrease ($(method.min_epsilon_decrease))"
        end
    end

    return nothing
end

################## Generation Runners ##################

"""
    _runFirstGeneration(method, param_names, priors, evaluate_batch, bank;
                        k_base_eff, mid_gen_additions, budget, budget_hit)

Run generation 1: place `population_size` particles using a Sobol low-discrepancy
sequence and accept all.

Generation 1 uses a Sobol sequence (from `Sobol.jl`) instead of a random prior sample
to guarantee good prior coverage: no region of `(0,1)^d` is over- or under-represented.
The sequence naturally avoids 0 and 1.

**Without CDF-grid snapping**: evaluates the Sobol points directly as a single batch.

**With CDF-grid snapping**: each Sobol point is passed through [`_lookupAndSnap`](@ref).
Nearby bank or mid-generation monads are reused (mid known); otherwise the point snaps
to the base grid (mid = nothing, resolved by `evaluate_batch`). `mid_gen_additions` is
updated after the batch with newly resolved monads.
"""
function _runFirstGeneration(method::ABCSMC, param_names::Vector{String},
                             priors::Vector{<:Distribution}, evaluate_batch::Function,
                             bank::SimulationBank;
                             k_base_eff::Union{Nothing,Int}=nothing,
                             mid_gen_additions::Vector{Tuple{Vector{Float64},Int}}=Tuple{Vector{Float64},Int}[],
                             budget::Ref{Int}=Ref(0),
                             budget_hit::Ref{Bool}=Ref(false))
    N = method.population_size
    d = length(param_names)

    # Sobol sequence: N points in (0,1)^d, naturally bounded away from 0 and 1
    seq = SobolSeq(d)
    pts = [next!(seq) for _ in 1:N]

    if isnothing(k_base_eff)
        # ── No snapping: evaluate Sobol points directly, accept all. ────────────
        proposals = Tuple{Dict{String,Float64}, Union{Nothing,Int}}[
                        (Dict(param_names[i] => pts[j][i] for i in 1:d), nothing) for j in 1:N]
        results   = evaluate_batch(1, proposals)
        accepted  = [_ParticleResult(proposals[i][1], results[i][1], results[i][2]) for i in 1:N]
        weights   = fill(1.0 / N, N)
        _updateBudget!(budget, budget_hit, N, method.max_evaluations)
        return _buildGenerationResult(1, accepted, weights, N, N, param_names)
    end

    # ── CDF-grid snapping: snap each Sobol point, accumulate N proposals. ───────
    k_eff  = _effectiveK(k_base_eff, 1)
    radius = _bankBoxRadius(k_eff)

    proposals = Tuple{Dict{String,Float64}, Union{Nothing,Int}}[]
    sizehint!(proposals, N)
    for j in 1:N
        latent_cdfs = Dict(param_names[i] => pts[j][i] for i in 1:d)
        push!(proposals, _lookupAndSnap(latent_cdfs, param_names, k_eff, radius, bank,
                                         mid_gen_additions))
    end

    results  = evaluate_batch(1, proposals)
    accepted = [_ParticleResult(proposals[i][1], results[i][1], results[i][2]) for i in 1:N]
    _updateMidGenAdditions!(mid_gen_additions, proposals, results, bank, param_names)
    _updateBudget!(budget, budget_hit, N, method.max_evaluations)
    weights = fill(1.0 / N, N)
    return _buildGenerationResult(1, accepted, weights, N, N, param_names)
end

"""
    _runSubsequentGeneration(method, param_names, priors, evaluate_batch, prev, epsilon, t, bank;
                             k_base_eff, mid_gen_additions, budget, budget_hit)

Run generation t > 1: resample from previous generation, perturb, accept if distance ≤ epsilon.

Proposals are batched and evaluated concurrently; batching repeats until `population_size`
accepted particles are collected. Batch sizing: `ceil(n_needed / acceptance_rate_est)`,
updated after each round.

**With CDF-grid snapping**: each perturbed proposal is processed by [`_lookupAndSnap`](@ref).
Duplicate monad IDs are allowed within and across batches — the same monad may appear as
multiple particles, each receiving its own weight. `mid_gen_additions` accumulates all new
grid evaluations within this generation and is shared between batches (growing throughout).

Budget accounting is delegated to [`_updateBudget!`](@ref). When `budget_hit` is set, the
completed portion of the generation is returned (possibly fewer than `population_size`).
"""
function _runSubsequentGeneration(method::ABCSMC, param_names::Vector{String},
                                  priors::Vector{<:Distribution}, evaluate_batch::Function,
                                  prev::GenerationResult, epsilon::Float64, t::Int,
                                  bank::SimulationBank;
                                  k_base_eff::Union{Nothing,Int}=nothing,
                                  mid_gen_additions::Vector{Tuple{Vector{Float64},Int}}=Tuple{Vector{Float64},Int}[],
                                  budget::Ref{Int}=Ref(0),
                                  budget_hit::Ref{Bool}=Ref(false))
    accepted = _ParticleResult[]
    rejected_coords = method.store_rejected ? Dict{String,Float64}[] : nothing
    n_evaluations = 0

    # Seed the acceptance rate estimate from the previous generation.
    acceptance_rate_est = prev.acceptance_rate

    n_accepted_total = 0

    snap_active = !isnothing(k_base_eff)
    k_eff       = snap_active ? _effectiveK(k_base_eff, t) : 0
    fitted = _fitKernel(method.perturbation_kernel, prev.particles, prev.weights, param_names, t;
                        k_eff=snap_active ? k_eff : nothing)
    radius      = snap_active ? _bankBoxRadius(k_eff)      : 0.0

    while length(accepted) < method.population_size
        n_needed     = method.population_size - length(accepted)
        n_to_propose = max(n_needed, ceil(Int, n_needed / acceptance_rate_est))

        proposals = Tuple{Dict{String,Float64}, Union{Nothing,Int}}[]
        sizehint!(proposals, n_to_propose)
        while length(proposals) < n_to_propose
            n_remaining = n_to_propose - length(proposals)
            for j in _systematicResample(prev.weights, n_remaining)
                prev_latent_cdfs = Dict(name => prev.particles[j, name] for name in param_names)
                latent_cdfs = _proposeParticle(fitted, prev_latent_cdfs, param_names)
                isnothing(latent_cdfs) && continue

                if snap_active
                    push!(proposals, _lookupAndSnap(latent_cdfs, param_names, k_eff, radius,
                                                     bank, mid_gen_additions))
                else
                    push!(proposals, (latent_cdfs, nothing))
                end
            end
        end

        results = evaluate_batch(t, proposals)
        n_evaluations += length(proposals)
        _updateMidGenAdditions!(mid_gen_additions, proposals, results, bank, param_names)
        _updateBudget!(budget, budget_hit, length(proposals), method.max_evaluations)

        n_accepted_this_round = 0
        for (i, (distance, metadata)) in enumerate(results)
            if distance <= epsilon
                n_accepted_this_round += 1
                can_add = method.accept_overflow || length(accepted) < method.population_size
                can_add && push!(accepted, _ParticleResult(proposals[i][1], distance, metadata))
            elseif !isnothing(rejected_coords)
                push!(rejected_coords, proposals[i][1])
            end
        end
        n_accepted_total += n_accepted_this_round

        acceptance_rate_est = max(0.01,
                                  n_accepted_this_round == 0 ?
                                    acceptance_rate_est / 2 :
                                    n_accepted_this_round / length(proposals))
        budget_hit[] && break
    end

    weights = _computeWeights(accepted, param_names, prev, fitted)
    rejected_df = isnothing(rejected_coords) ? nothing :
        DataFrame(Dict(name => [p[name] for p in rejected_coords] for name in param_names))
    return _buildGenerationResult(t, accepted, weights, n_evaluations, n_accepted_total,
                                  param_names; rejected_proposals=rejected_df)
end

################## Sampling ##################

"""
    _sampleFromPrior(param_names) → Dict{String,Float64}

Draw one CDF value from the joint prior (independent marginals).
"""
function _sampleFromPrior(param_names::Vector{String})
    return Dict(pname => rand() for pname in param_names)
end

"""
    _systematicResample(weights, n) → Vector{Int}

Draw `n` parent indices from a categorical distribution defined by `weights` using
systematic resampling (Kitagawa 1996).

A single uniform draw `u ~ Uniform(0, 1/n)` places `n` evenly-spaced points
`u, u+1/n, ..., u+(n-1)/n` on [0, 1]. A single left-to-right walk through the
cumulative weight distribution assigns each point to the particle whose CDF interval
contains it. The result is that particle `i` appears exactly `⌊n·wᵢ⌋` or `⌈n·wᵢ⌉`
times — strictly lower variance than `n` independent multinomial draws, at O(n) cost.

Note: `n` is the number of *samples to draw*, not the number of parent-generation
particles. When `n` is small relative to the population some parents will receive
0 copies, which is correct; callers that need more proposals simply call again with
a fresh `u`.
"""
function _systematicResample(weights::Vector{Float64}, n::Int)
    N = length(weights)
    indices = Vector{Int}(undef, n)
    u = rand() / n          # single draw in [0, 1/n)
    j = 1
    cumulative = weights[1]
    for i in 1:n
        target = u + (i - 1) / n
        # j < N guard: stops the walk at the last particle if floating-point drift
        # leaves cumulative just below 1.0 on the final target.
        while j < N && cumulative < target
            j += 1
            cumulative += weights[j]
        end
        indices[i] = j
    end
    return indices
end

################## Weight Computation ##################

"""
    _computeWeights(accepted, param_names, prev, fitted) → Vector{Float64}

Compute and normalize importance weights for generation t > 1.

    w_i = π(θ_i) / Σ_j [ w_j^{t-1} · K(θ_i | θ_j^{t-1}) ]

where π is the prior density and K is evaluated via `_kernelDensity`.

ABC-SMC operates entirely in CDF-coordinate space where all dimensions have a
`Uniform(0,1)` prior, so `π(u) = 1.0` for every particle regardless of the
underlying latent parameter distributions.
"""
function _computeWeights(accepted::Vector{_ParticleResult}, param_names::Vector{String},
                          prev::GenerationResult, fitted::AbstractFittedKernel)
    N_prev = nrow(prev.particles)
    weights = Vector{Float64}(undef, length(accepted))
    prev_particles = [Dict(n => prev.particles[j, n] for n in param_names) for j in 1:N_prev]

    for (i, particle) in enumerate(accepted)
        # CDF space: Uniform(0,1) prior for all dimensions → prior density = 1.0
        prior_density = 1.0

        denom = 0.0
        for j in 1:N_prev
            denom += prev.weights[j] * _kernelDensity(fitted, prev_particles[j],
                                                       particle.latent_cdfs, param_names)
        end

        weights[i] = denom > 0 ? prior_density / denom : 0.0
    end

    total = sum(weights)
    if total > 0
        weights ./= total
    else
        weights .= 1.0 / length(weights)
    end

    return weights
end

################## CDF-Grid Snap Helpers ##################

"""
    _effectiveK(k_base, t) → Int

Return the effective CDF grid resolution at generation `t` with base `k_base`.

The grid doubles each generation: at generation `t` the grid is
`G(k_eff) = {j/2^k_eff : j=1,...,2^k_eff-1}` where `k_eff = k_base + t - 1`.
"""
_effectiveK(k_base::Int, t::Int) = k_base + t - 1

"""
    _snapToCDFGrid(u, k_eff) → Float64

Snap a scalar CDF value `u ∈ [0,1]` to the nearest interior grid point at resolution
`k_eff`, i.e. the nearest value in `{j/2^k_eff : j=1,...,2^k_eff-1}`.

Boundary clamping: `u=0` snaps to `1/2^k_eff`; `u=1` snaps to `(2^k_eff-1)/2^k_eff`.
"""
function _snapToCDFGrid(u::Float64, k_eff::Int)
    n = 2^k_eff
    j = clamp(round(Int, u * n), 1, n - 1)
    return j / n
end

"""
    _bankBoxRadius(k_eff) → Float64

Return the L∞ box radius for bank lookup at effective grid resolution `k_eff`.

Equal to half the grid spacing at that resolution: `1 / 2^(k_eff + 1)`.
"""
_bankBoxRadius(k_eff::Int) = 1.0 / 2^(k_eff + 1)

"""
    _cdfToGridKey(snapped_cdf, k_eff) → Vector{Int}

Convert a snapped CDF vector to integer grid indices for use as a set membership key.

Each component is `round(Int, snapped_cdf[i] * 2^k_eff)`, which recovers the integer `j`
from `j/2^k_eff`. Safe to call only on already-snapped values (no rounding error).
"""
function _cdfToGridKey(snapped_cdf::Vector{Float64}, k_eff::Int)
    n = 2^k_eff
    return [round(Int, u * n) for u in snapped_cdf]
end

"""
    _bankBoxCandidates(bank, query_cdf, radius) → Vector{Int}

Return all monad IDs in `bank` whose CDF coordinates lie within the L∞ box of
`radius` around `query_cdf` along with their index in the bank.
An empty vector is returned when the bank is empty.
`query_cdf` need not be snapped to the grid.

Uses the pre-built KD-tree (`bank.tree`) with the Chebyshev metric for O(log n + k)
queries instead of a linear scan.
"""
function _bankBoxCandidates(bank::SimulationBank, query_cdf::Vector{Float64},
                             radius::Float64)
    isempty(bank.monad_ids) && return Tuple{Int,Int}[]
    n_dims = length(query_cdf)
    @assert n_dims == size(bank.cdf_coords, 1) "Bank has " *
        "$(size(bank.cdf_coords, 1)) latent dimensions but query_cdf has $n_dims. " *
        "This is a bug — the bank must be built from the same CalibrationProblem " *
        "that drives the generation runners."
    idxs = inrange(bank.tree, query_cdf, radius)
    return [(idx, bank.monad_ids[idx]) for idx in idxs]
end

"""
    _lookupAndSnap(latent_cdfs, param_names, k_eff, radius, bank, mid_gen_additions)
    → Tuple{Dict{String,Float64}, Union{Nothing,Int}}

Core bank-lookup and fallback-snap step for a single proposed CDF vector.

**Lookup order**: both the KD-tree bank and the `mid_gen_additions` list are searched
concurrently. If any candidates lie within the L∞ box of `radius` around `latent_cdfs`,
one is chosen at random and its stored coordinates and monad ID are returned.
Otherwise the proposal is snapped to the nearest interior grid point of `G(k_eff)` and
`nothing` is returned for the monad ID (resolved later by `evaluate_batch`).

Duplicate monad IDs are intentional — the same monad may appear as multiple particles
within a generation, each receiving its own weight.
"""
function _lookupAndSnap(latent_cdfs::Dict{String,Float64}, param_names::Vector{String},
                         k_eff::Int, radius::Float64, bank::SimulationBank,
                         mid_gen_additions::Vector{Tuple{Vector{Float64},Int}})
    raw_cdf = [latent_cdfs[name] for name in param_names]

    # Concurrent lookup: KD-tree bank + mid-generation additions
    bank_cands = _bankBoxCandidates(bank, raw_cdf, radius)
    batch_cands = Tuple{Int,Int}[(idx, mid) for (idx, (coords, mid)) in enumerate(mid_gen_additions)
                      if all(pair -> abs(pair[1] - pair[2]) ≤ radius, zip(coords, raw_cdf))]
    all_cands = [bank_cands; batch_cands]

    if !isempty(all_cands)
        i = rand(1:length(all_cands))
        idx, mid = all_cands[i]
        if i <= length(bank_cands)
            eff_cdfs = Dict(param_names[j] => bank.cdf_coords[j, idx]
                            for j in eachindex(param_names))
        else
            coords = mid_gen_additions[idx][1]
            eff_cdfs = Dict(param_names[j] => coords[j] for j in eachindex(param_names))
        end
        return (eff_cdfs, mid)
    end

    # Fallback: snap to grid — monad ID resolved by evaluate_batch
    snapped_cdfs = Dict(name => _snapToCDFGrid(latent_cdfs[name], k_eff) for name in param_names)
    return (snapped_cdfs, nothing)
end

"""
    _updateMidGenAdditions!(mid_gen_additions, proposals, results, bank, param_names)

Update `mid_gen_additions` after an `evaluate_batch` call. For each proposal whose
monad ID was `nothing` (a fresh grid snap), the resolved monad ID from `results` is
recorded alongside the proposal's CDF coordinates. Monads already in the bank or
already tracked in `mid_gen_additions` are skipped to maintain the invariant that
entries are unique and not in the bank.
"""
function _updateMidGenAdditions!(mid_gen_additions::Vector{Tuple{Vector{Float64},Int}},
                                  proposals::Vector{Tuple{Dict{String,Float64}, Union{Nothing,Int}}},
                                  results::Vector{<:Tuple},
                                  bank::SimulationBank,
                                  param_names::Vector{String})
    tracked = Set(mid for (_, mid) in mid_gen_additions)
    for ((eff_cdfs, proposal_mid), (_, result_mid)) in zip(proposals, results)
        if isnothing(proposal_mid) && result_mid ∉ bank.monad_ids && result_mid ∉ tracked
            push!(mid_gen_additions, ([eff_cdfs[name] for name in param_names], result_mid))
            push!(tracked, result_mid)
        end
    end
end

"""
    _updateBankFromGeneration(bank, mid_gen_additions) → SimulationBank

Add all newly evaluated monads from `mid_gen_additions` to the bank and rebuild the
KD-tree. Called between generations so the next generation's lookups can reuse monads
evaluated in all prior generations.

Monads already in the bank (by monad ID) are skipped to avoid duplicates.
"""
function _updateBankFromGeneration(bank::SimulationBank,
                                    mid_gen_additions::Vector{Tuple{Vector{Float64},Int}})
    isempty(mid_gen_additions) && return bank
    new_ids    = [mid for (_, mid) in mid_gen_additions]
    new_coords = hcat([coords for (coords, _) in mid_gen_additions]...)
    all_ids    = [bank.monad_ids..., new_ids...]
    all_coords = isempty(bank.monad_ids) ? new_coords : hcat(bank.cdf_coords, new_coords)
    return SimulationBank(all_ids, all_coords, bank.param_names)
end

"""
    _updateBudget!(budget, budget_hit, n, max_evaluations)

Increment `budget[]` by `n` and set `budget_hit[] = true` if `max_evaluations` is
reached. No-op when `max_evaluations` is `nothing`.
"""
function _updateBudget!(budget::Ref{Int}, budget_hit::Ref{Bool},
                         n::Int, max_evaluations::Union{Nothing,Int})
    budget[] += n
    !isnothing(max_evaluations) && budget[] >= max_evaluations && (budget_hit[] = true)
end

################## Epsilon Adaptation ##################

"""
    _adaptEpsilon(distances, quantile_val, minimum_epsilon) → Float64

Compute the next generation's epsilon as a quantile of the current distances,
clamped to `minimum_epsilon`.
"""
function _adaptEpsilon(distances::Vector{Float64}, quantile_val::Float64,
                        minimum_epsilon::Float64)
    return max(minimum_epsilon, quantile(distances, quantile_val))
end

################## Result Construction ##################

"""
    _buildGenerationResult(t, accepted, weights, n_evaluations, n_accepted, param_names) → GenerationResult

Assemble a `GenerationResult` from accepted particles, computing diagnostics.

`n_accepted` is the total number of proposals that passed the epsilon criterion across
all batches in this generation — **not** capped at `population_size`. This is larger
than `length(accepted)` when the final batch overshoots the target population, and
gives the correct (unbiased) acceptance rate for the proposal-distribution/epsilon pair.
"""
function _buildGenerationResult(t::Int, accepted::Vector{_ParticleResult},
                                 weights::Vector{Float64}, n_evaluations::Int,
                                 n_accepted::Int, param_names::Vector{String};
                                 rejected_proposals::Union{Nothing,DataFrame}=nothing)
    N = length(accepted)
    particles = DataFrame(Dict(name => [p.latent_cdfs[name] for p in accepted]
                               for name in param_names))
    distances        = [p.distance for p in accepted]
    monad_ids        = [p.metadata isa Integer ? Int(p.metadata) : 0 for p in accepted]
    epsilon          = maximum(distances)
    acceptance_rate  = n_evaluations > 0 ? n_accepted / n_evaluations : 1.0
    ess              = 1.0 / sum(w^2 for w in weights)

    return GenerationResult(t, particles, weights, distances, epsilon,
                            n_evaluations, monad_ids, acceptance_rate, ess,
                            rejected_proposals)
end
