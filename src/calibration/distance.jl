export mseDistance

"""
    mseDistance(simulated, observed)

Built-in distance functions for use as `distance` in a [`CalibrationProblem`](@ref).
Three calling conventions are supported:

- `mseDistance(sim::Dict{String,<:Any}, obs::Dict{String,<:Any})` — mean of per-key MSE
  contributions, averaged across all keys in `obs`. Scalar keys contribute `(sim−obs)²`;
  vector keys contribute `mean((sim .- obs).^2)`. Keys missing from `sim` are treated as
  zero. Keys in `sim` not in `obs` are ignored (with a one-time warning).

- `mseDistance(sim::AbstractVector{<:Real}, obs::AbstractVector{<:Real})` — sum of squared
  differences `Σ(simᵢ−obsᵢ)²`. Throws `DimensionMismatch` when lengths differ.

- `mseDistance(sim::Real, obs::Real)` — squared difference `(sim − obs)²`.
"""
function mseDistance(simulated::Dict{String,<:Any}, observed::Dict{String,<:Any})
    if any(!in(keys(observed)), keys(simulated))
        @warn """
        Found keys in simulated that are not in the observed dict.
        - Keys in simulated but not observed: $(setdiff(keys(simulated), keys(observed)))
        - These will not contribute to the MSE calculation.
        """ maxlog=1
    end
    if any(!in(keys(simulated)), keys(observed))
        @warn """
        Found keys in observed that are not in the simulated dict.
        - Keys in observed but not simulated: $(setdiff(keys(observed), keys(simulated)))
        - The MSE will be calculated by assuming the simulated value is 0.
        """ maxlog=1
    end
    n = length(observed)
    n == 0 && return 0.0
    total = 0.0
    for (k, obs_val) in observed
        sim_val = get(simulated, k, _zeroLike(obs_val))
        total += _mseContribution(sim_val, obs_val)
    end
    return total / n
end

# Scalar contribution: single squared error term
_mseContribution(sim::Real, obs::Real) = Float64((sim - obs)^2)

# Vector contribution: mean squared error across the time series
function _mseContribution(sim::AbstractVector{<:Real}, obs::AbstractVector{<:Real})
    length(sim) == length(obs) || throw(DimensionMismatch(
        "Simulated and observed vectors have different lengths ($(length(sim)) vs $(length(obs))). " *
        "Ensure the time grids match."
    ))
    return mean((sim .- obs) .^ 2)
end

# Zero sentinel that matches the shape of the observed value (used for missing keys)
_zeroLike(::Real) = 0.0
_zeroLike(v::AbstractVector{<:Real}) = zeros(Float64, length(v))

function mseDistance(simulated::AbstractVector{<:Real}, observed::AbstractVector{<:Real})
    length(simulated) == length(observed) || throw(DimensionMismatch(
        "Simulated and observed vectors have different lengths " *
        "($(length(simulated)) vs $(length(observed)))."
    ))
    return sum((simulated .- observed) .^ 2)
end

mseDistance(simulated::Real, observed::Real) = Float64((simulated - observed)^2)
