export mseDistance

#! Strict about keys, where it used to warn once and impute an absent key as zero. Zero-filling turned
#! a naming mistake into a converged, wrong posterior: a summary keyed one way and an `observed_data`
#! keyed another compared every key against 0, which is a perfectly finite distance, so ABC-SMC
#! accepted particles on it and returned the prior with one `@warn maxlog=1` somewhere in the log.
#! There is no fill that makes the answer approximate rather than wrong, so the mismatch is refused.
"""
    mseDistance(simulated, observed)

Built-in distance functions for use as `distance` in a [`CalibrationProblem`](@ref).
Two calling conventions are supported:

- `mseDistance(sim::AbstractDict, obs::AbstractDict)` — mean of the per-key squared errors
  `(sim[k] − obs[k])²`. The two must carry **exactly the same keys**; a mismatch is an
  `ArgumentError` listing what each side has. The keys are the ones your `compute`/`reduce`
  produced, so `observed_data` is written with those.

- `mseDistance(sim::Real, obs::Real)` — squared difference `(sim − obs)²`.
"""
function mseDistance(simulated::AbstractDict, observed::AbstractDict)
    if Set(keys(simulated)) != Set(keys(observed))
        throw(ArgumentError("""
        mseDistance was given a simulated and an observed value with different keys, so there is no \
        set of quantities to compare.
        - simulated: $(repr(sort(string.(collect(keys(simulated))))))
        - observed:  $(repr(sort(string.(collect(keys(observed))))))
        A summary statistic's keys are the ones its `compute`/`reduce` produced — for a vector of \
        QoIs, a `Real`-valued one contributes its own name and a keyed one contributes its keys. \
        Key `observed_data` the same way.
        """))
    end
    n = length(observed)
    n == 0 && return 0.0
    total = 0.0
    for (k, obs_val) in observed
        total += _mseContribution(simulated[k], obs_val)
    end
    return total / n
end

# Scalar contribution: single squared error term
_mseContribution(sim::Real, obs::Real) = Float64((sim - obs)^2)

mseDistance(simulated::Real, observed::Real) = Float64((simulated - observed)^2)
