export AbstractCalibrationMethod, ABCSMC, runCalibration
export GaussianKernel, ComponentwiseKernel, LocalNNKernel, LocalNNCovKernel

"""
    AbstractCalibrationMethod

Abstract supertype for calibration methods. Concrete subtypes define the algorithm
and its settings.

Current implementations:
- [`ABCSMC`](@ref): Approximate Bayesian Computation — Sequential Monte Carlo

Future implementations may include GP-accelerated ABC, Bayesian optimization, etc.
"""
abstract type AbstractCalibrationMethod end

"""
    AbstractKernel

Abstract supertype for ABC-SMC perturbation kernels. Concrete subtypes define how
particles are perturbed between generations.

Current implementations:
- [`GaussianKernel`](@ref): Full multivariate Gaussian using weighted covariance.
- [`ComponentwiseKernel`](@ref): Diagonal covariance — independent 1D Gaussians per parameter.
- [`LocalNNKernel`](@ref): Global covariance shape scaled per-particle by k-NN bandwidth.
- [`LocalNNCovKernel`](@ref): Per-particle local covariance estimated from k nearest neighbors.
"""
abstract type AbstractKernel end

"""
    GaussianKernel(scale = 2.0)

Full multivariate Gaussian perturbation kernel using `scale × weighted_covariance`
(Beaumont et al. 2009).

`scale` may be a scalar `Float64` (constant across generations) or a `Vector{Float64}`
generation schedule: generation `t` uses `scale[min(t, end)]`.

Default `scale=2.0` preserves the Beaumont et al. rule of thumb.
"""
struct GaussianKernel <: AbstractKernel
    scale::Union{Float64, Vector{Float64}}
    function GaussianKernel(scale::Float64)
        scale > 0 || throw(ArgumentError("GaussianKernel scale must be positive, got $scale"))
        new(scale)
    end
    function GaussianKernel(scale::Vector{Float64})
        isempty(scale) && throw(ArgumentError("GaussianKernel scale vector must be non-empty"))
        all(>(0), scale) || throw(ArgumentError("All GaussianKernel scale values must be positive"))
        new(scale)
    end
end
GaussianKernel() = GaussianKernel(2.0)
GaussianKernel(scale::Real) = GaussianKernel(Float64(scale))
GaussianKernel(scale::AbstractVector{<:Real}) = GaussianKernel(Float64.(scale))

"""
    ComponentwiseKernel(scale = 2.0)

Diagonal-covariance perturbation kernel: independent 1D Gaussians per parameter,
using `scale × weighted_variance` for each dimension. More robust than
[`GaussianKernel`](@ref) in high dimensions where off-diagonal covariance estimation
is noisy with small populations.

`scale` semantics are identical to [`GaussianKernel`](@ref).
"""
struct ComponentwiseKernel <: AbstractKernel
    scale::Union{Float64, Vector{Float64}}
    function ComponentwiseKernel(scale::Float64)
        scale > 0 || throw(ArgumentError("ComponentwiseKernel scale must be positive, got $scale"))
        new(scale)
    end
    function ComponentwiseKernel(scale::Vector{Float64})
        isempty(scale) && throw(ArgumentError("ComponentwiseKernel scale vector must be non-empty"))
        all(>(0), scale) || throw(ArgumentError("All ComponentwiseKernel scale values must be positive"))
        new(scale)
    end
end
ComponentwiseKernel() = ComponentwiseKernel(2.0)
ComponentwiseKernel(scale::Real) = ComponentwiseKernel(Float64(scale))
ComponentwiseKernel(scale::AbstractVector{<:Real}) = ComponentwiseKernel(Float64.(scale))

"""
    LocalNNKernel(; k = 10, scale = 1.0)

Per-particle bandwidth kernel: `h_j = scale × dist(θ_j, θ_j^{(k)})` where `θ_j^{(k)}`
is the k-th nearest neighbor of particle `j` (Chebyshev metric). All particles share the
global weighted covariance *shape* `Σ_global`; only the scalar bandwidth `h_j` varies
per particle. Proposal for parent `j`: `N(θ_j, h_j² × Σ_global)`.

Bandwidth shrinks automatically as the particle cloud concentrates, so an explicit
generation schedule is not needed. Requires only one Cholesky factorization per generation.

For fully local covariance (adapts direction as well as scale), see [`LocalNNCovKernel`](@ref).
"""
struct LocalNNKernel <: AbstractKernel
    k::Int
    scale::Float64
end
function LocalNNKernel(; k::Int=10, scale::Real=1.0)
    k >= 1 || throw(ArgumentError("LocalNNKernel k must be ≥ 1, got $k"))
    scale > 0 || throw(ArgumentError("LocalNNKernel scale must be positive, got $scale"))
    return LocalNNKernel(k, Float64(scale))
end

"""
    LocalNNCovKernel(; k = 10, scale = 1.0)

Per-particle local covariance kernel: for each previous-generation particle `j`, its
perturbation kernel is `N(θ_j, scale × Σ_local,j)` where `Σ_local,j` is the sample
covariance of particle `j`'s `k` nearest neighbors. Unlike [`LocalNNKernel`](@ref), the
covariance *direction* adapts locally — useful for banana-shaped or anisotropic posteriors.

Cost: `N` Cholesky factorizations per generation (one per particle). For `N ≤ 5000`,
`d ≤ 10`, this is fast in practice.
"""
struct LocalNNCovKernel <: AbstractKernel
    k::Int
    scale::Float64
end
function LocalNNCovKernel(; k::Int=10, scale::Real=1.0)
    k >= 1 || throw(ArgumentError("LocalNNCovKernel k must be ≥ 1, got $k"))
    scale > 0 || throw(ArgumentError("LocalNNCovKernel scale must be positive, got $scale"))
    return LocalNNCovKernel(k, Float64(scale))
end

# Resolve generation-indexed scale: scalar stays constant; vector uses clamped indexing.
_effectiveKernelScale(s::Float64, t::Int) = s
_effectiveKernelScale(s::Vector{Float64}, t::Int) = s[min(t, length(s))]

"""
    ABCSMC

Settings for ABC-SMC (Approximate Bayesian Computation — Sequential Monte Carlo)
calibration (Toni et al. 2009, Beaumont et al. 2009).

# Fields
- `population_size::Int`: Number of accepted particles per generation (default `100`).
- `max_nr_populations::Int`: Maximum number of SMC generations (default `10`).
- `minimum_epsilon::Float64`: Stop when the maximum accepted distance drops to or below
  this value (default `0.01`). Acts as a hard floor: the algorithm always runs a full
  generation at this threshold before stopping, ensuring all accepted particles satisfy it.
- `epsilon_quantile::Float64`: Quantile of accepted distances used to set the next
  generation's threshold when no `epsilon_schedule` is supplied (default `0.5`, i.e.
  median). Ignored when `epsilon_schedule` is provided.
- `perturbation_kernel::AbstractKernel`: Kernel for perturbing resampled particles.
  Accepts [`GaussianKernel`](@ref), [`ComponentwiseKernel`](@ref),
  [`LocalNNKernel`](@ref), or [`LocalNNCovKernel`](@ref). Default `GaussianKernel()`
  uses twice the weighted covariance (Beaumont et al. 2009).
- `epsilon_schedule::Union{Nothing,Vector{Float64}}`: Optional explicit decreasing
  sequence of acceptance thresholds. When supplied, generation `t` uses
  `epsilon_schedule[t-1]` instead of the adaptive quantile rule. If the schedule is
  shorter than `max_nr_populations`, the adaptive rule resumes for remaining generations.
  All values must be positive and strictly decreasing. Default `nothing`.
- `min_acceptance_rate::Float64`: Stop after any generation whose acceptance rate
  (accepted / proposed) falls below this value. `0.0` disables this check (default `0.0`).
- `min_epsilon_decrease::Float64`: Stop after any generation where the proportional
  (relative) decrease in epsilon is less than this value. Formally, stop when
  `(ε_{t-1} - ε_t) / ε_{t-1} < min_epsilon_decrease`. A value of `0.1` requires at
  least a 10 % reduction each generation; `0.0` disables this check (default `0.0`).
- `min_ess_fraction::Float64`: Stop after any generation where the effective sample size
  as a fraction of `population_size` falls below this value. ESS = 1 / Σwᵢ². A value
  of `0.2` stops when fewer than 20 % of particles carry meaningful weight. `0.0`
  disables this check (default `0.0`).
- `accept_overflow::Bool`: When `true`, keep **all** particles that pass the epsilon
  threshold in a batch, even if their count exceeds `population_size`. `population_size`
  then acts as a *minimum* rather than an exact target. When `false` (default), any
  overflow from the final batch is discarded so each generation contains exactly
  `population_size` particles. The ESS stopping criterion always compares against
  `population_size` regardless of this flag; the log line reports ESS as a fraction
  of the actual accepted count.
- `cdf_grid_k::Union{Nothing,Int}`: Base grid resolution for CDF-grid snapping.
  When set, proposal CDF coordinates are snapped to the dyadic grid `{j/2^k : j=1,...,2^k-1}`
  at generation 1, with effective resolution doubling each generation (`2^(k+t-1)` points).
  The snap box radius at generation `t` is `1/2^(k+t)`. Bank entries within the snap box are
  reused without re-simulation; if none, the proposal snaps to the grid for a fresh simulation.
  Duplicate monad proposals within a generation are allowed — the same monad can appear as
  multiple particles (each receiving its own weight). The bank is updated between generations
  with all newly evaluated monads. Generation 1 uses a Sobol low-discrepancy sequence for
  good prior coverage. `nothing` (default) disables snapping. At runtime, the effective base
  resolution is raised to satisfy `(2^k-1)^d ≥ population_size`; an `@info` is emitted when
  this correction fires.
- `max_evaluations::Union{Nothing,Int}`: Maximum total number of evaluated particles
  (monads) across the entire calibration run. Each proposal sent to `evaluate_batch`
  counts as one evaluation, regardless of whether the monad was a fresh simulation or a
  bank reuse. The budget is enforced **before each batch is dispatched**: a planned batch
  that would exceed the budget is trimmed to exactly the remaining allowance, so the run
  never evaluates more than `max_evaluations` simulations. The completed portion of the
  current generation is then saved (possibly with fewer than `population_size` accepted
  particles) and the run stops. If the budget is smaller than `population_size`, even
  generation 1 is trimmed. `nothing` (default) disables the budget. Persisted to
  `method.toml`.
- `store_rejected::Bool`: When `true`, each `GenerationResult` (for generations t > 1)
  stores all rejected proposal CDF coordinates in `rejected_proposals::DataFrame` (same
  column names as `particles`; converted to target space at plot time). Useful for the
  `:transition` visualization recipe, which can also recover rejected proposals from disk
  via a lazy lookup when this is `false` (default). Not persisted to disk; always
  `nothing` on resume and for generation 1.

# Examples
```julia
# Fully adaptive run
method = ABCSMC(population_size=200, max_nr_populations=15, minimum_epsilon=0.005)

# Manual epsilon schedule with acceptance-rate safety stop
method = ABCSMC(
    population_size = 100,
    epsilon_schedule = [50.0, 20.0, 5.0, 1.0],
    min_acceptance_rate = 0.01,
)

result = runCalibration(problem, method)
```
"""
struct ABCSMC <: AbstractCalibrationMethod
    population_size::Int
    max_nr_populations::Int
    minimum_epsilon::Float64
    epsilon_quantile::Float64
    perturbation_kernel::AbstractKernel
    epsilon_schedule::Union{Nothing,Vector{Float64}}
    min_acceptance_rate::Float64
    min_epsilon_decrease::Float64
    min_ess_fraction::Float64
    accept_overflow::Bool
    cdf_grid_k::Union{Nothing,Int}
    max_evaluations::Union{Nothing,Int}
    store_rejected::Bool
end

function ABCSMC(; population_size::Int=100,
                  max_nr_populations::Int=10,
                  minimum_epsilon::Float64=0.01,
                  epsilon_quantile::Float64=0.5,
                  perturbation_kernel::AbstractKernel=GaussianKernel(),
                  epsilon_schedule::Union{Nothing,Vector{Float64}}=nothing,
                  min_acceptance_rate::Float64=0.0,
                  min_epsilon_decrease::Float64=0.0,
                  min_ess_fraction::Float64=0.0,
                  accept_overflow::Bool=false,
                  cdf_grid_k::Union{Nothing,Int}=nothing,
                  max_evaluations::Union{Nothing,Int}=nothing,
                  store_rejected::Bool=false)

    population_size > 0 ||
        throw(ArgumentError("population_size must be positive, got $population_size"))
    max_nr_populations > 0 ||
        throw(ArgumentError("max_nr_populations must be positive, got $max_nr_populations"))
    minimum_epsilon >= 0 ||
        throw(ArgumentError("minimum_epsilon must be non-negative, got $minimum_epsilon"))
    0 < epsilon_quantile < 1 ||
        throw(ArgumentError("epsilon_quantile must be in (0, 1), got $epsilon_quantile"))
    if !isnothing(epsilon_schedule)
        length(epsilon_schedule) > 0 ||
            throw(ArgumentError("epsilon_schedule must be non-empty"))
        all(v > 0 for v in epsilon_schedule) ||
            throw(ArgumentError("All epsilon_schedule values must be positive"))
        all(epsilon_schedule[i] > epsilon_schedule[i+1]
            for i in 1:length(epsilon_schedule)-1) ||
            throw(ArgumentError("epsilon_schedule must be strictly decreasing"))
    end

    0 <= min_acceptance_rate < 1 ||
        throw(ArgumentError("min_acceptance_rate must be in [0, 1), got $min_acceptance_rate"))
    0 <= min_epsilon_decrease < 1 ||
        throw(ArgumentError("min_epsilon_decrease must be in [0, 1), got $min_epsilon_decrease"))
    0 <= min_ess_fraction < 1 ||
        throw(ArgumentError("min_ess_fraction must be in [0, 1), got $min_ess_fraction"))

    if !isnothing(cdf_grid_k)
        cdf_grid_k >= 1 ||
            throw(ArgumentError("cdf_grid_k must be a positive integer, got $cdf_grid_k"))
    end

    if !isnothing(max_evaluations)
        max_evaluations >= 1 ||
            throw(ArgumentError("max_evaluations must be a positive integer, got $max_evaluations"))
    end

    return ABCSMC(population_size, max_nr_populations, minimum_epsilon, epsilon_quantile,
                  perturbation_kernel, epsilon_schedule,
                  min_acceptance_rate, min_epsilon_decrease, min_ess_fraction,
                  accept_overflow, cdf_grid_k, max_evaluations, store_rejected)
end

# Generic dispatch stub. The user-facing docstring lives on the method-specific
# implementation (e.g. `runCalibration(::CalibrationProblem, ::ABCSMC)` in abc.jl)
# so the rendered API reference shows a single, detailed entry.
function runCalibration end
