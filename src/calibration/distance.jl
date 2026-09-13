export mseDistance

#! ONE term helper, again. It was inlined when there was one shape to compare -- a squared difference
#! between two numbers -- and a value may now be an array or anything that broadcasts, so the
#! arithmetic and its failure message have a real body to hold. `_mseContribution` was the name that
#! implied a family which never existed; this one IS the family, and it returns a COUNT as well as a
#! sum so the caller can divide once at the end.
"""
    _mseTerms(simulated, observed[, label]) → (sum of squares, number of differences)

The squared-error contribution of one pair of values: `(sim − obs)²` and a count of 1 for two
`Real`s, and `sum(abs2, sim .- obs)` with `length` for anything that broadcasts. Raises an
`ArgumentError` naming both types — and both lengths, when both sides have one — for a pair that
cannot be compared. `label` names the summary entry the pair came from, when there is one.
"""
_mseTerms(simulated::Real, observed::Real, label=nothing) =
    (Float64((simulated - observed)^2), 1)

function _mseTerms(simulated, observed, label=nothing)
    try
        d = simulated .- observed
        return (Float64(sum(abs2, d)), length(d))
    catch
        #! Both lengths, because a 101-point observation against a 100-point simulation is the
        #! commonest array mistake by a distance and "cannot compare a Vector{Float64} with a
        #! Vector{Float64}" is an infuriating way to be told about it. Only when both sides have a
        #! `length`: a struct that does not is reported by type alone rather than by a `MethodError`
        #! raised while building the message.
        sizes = if applicable(length, simulated) && applicable(length, observed)
            " (lengths $(length(simulated)) and $(length(observed)))"
        else
            ""
        end
        where_ = isnothing(label) ? "" : " for \"$(label)\""
        throw(ArgumentError(
            "mseDistance cannot compare a $(typeof(simulated)) with a $(typeof(observed))" *
            "$(sizes)$(where_). It needs two `Real`s, or two values for which " *
            "`sum(abs2, simulated .- observed)` works — two arrays of the same shape, typically. " *
            "Reduce the measurement to something comparable, or supply your own `distance`."))
    end
end

#! The comparison is over the OBSERVED keys. Extra simulated components are ignored, because we
#! always know more about a simulation than about the data: a summary reporting six cell types
#! against an observation of two is an ordinary calibration, not a mistake, and refusing it forced
#! the user to list every component of every QoI in `observed_data` or drop QoIs from the summary.
#! Nothing is zero-filled in the other direction -- an observed key that does not resolve is still an
#! error -- because there is no fill that turns a naming mistake into a comparison.
"""
    mseDistance(simulated, observed)

Built-in distance functions for use as `distance` in a [`CalibrationProblem`](@ref).

**The observed keys are the comparison; extra simulated components are ignored**, since a simulation
is always known better than the data. An observed key that does not resolve is an error — there is
no fill that would make it a comparison.

**One global mean.** The squared differences of every term are summed and divided by *how many
differences were computed*, so a single array-valued key gives exactly `mean(abs2, sim .- obs)` and
`mseDistance(v1, v2)` agrees with the same two arrays inside a one-key summary. For all-scalar keys
that is the mean of the per-key squared errors, as before. The consequence worth knowing: a
100-point series contributes 100 differences where a scalar key contributes one, so weight them in
a `distance` of your own — or reduce the series — if that is not what you want.

Five calling conventions are supported:

- `mseDistance(sim::SummaryValues, obs)` for a keyed `obs` (an `AbstractDict` or a `NamedTuple`) —
  every key of `obs` is resolved through [`SummaryValues`](@ref)' own lookup, so it may be written
  `"counts.tumor"`, or `"tumor"` when only one QoI reports that key, or `"counts"` for a
  `Real`-valued QoI, or as an exact `("counts", "tumor")` tuple. An unresolvable or ambiguous key
  raises that lookup's error. Three things are refused: an `obs` that names nothing, two keys of
  `obs` that resolve to one summary entry, and a resolved value that is `missing`.

- `mseDistance(sim::SummaryValues, obs)` for anything else — the summary must hold exactly one
  value; otherwise an `ArgumentError` lists what it holds, since which of several a bare
  observation meant cannot be guessed. That one value is compared with `obs` directly, so a
  one-entry summary holding a series works against a series.

- `mseDistance(sim, obs)` for two keyed values outside calibration — matched by `string(k)`, so a
  `Dict` may be compared with a `NamedTuple` and a `Symbol` key with a `String` one. An observed key
  the simulated value does not have is an `ArgumentError` listing each side's raw keys.

- `mseDistance(sim::Real, obs::Real)` — squared difference `(sim − obs)²`.

- `mseDistance(sim, obs)` for anything else — two arrays, or any pair that broadcasts.
"""
function mseDistance(simulated::SummaryValues, observed::Union{AbstractDict,NamedTuple})
    #! An observation naming nothing is refused, and it is the zero-fill failure trying to come back
    #! in through the other door: with no terms the mean is 0/0, and returning 0.0 for it would make
    #! every particle perfect, so ABC-SMC would accept the whole prior and report convergence.
    isempty(pairs(observed)) && throw(ArgumentError(
        "mseDistance was given an observation with no entries, so there is nothing to compare. " *
        "The summary reports $(_summaryLabelListStr(simulated)) — key `observed_data` by one or " *
        "more of those."))
    total = 0.0
    n = 0
    claimed = Dict{_SummaryKey,Any}()
    for (k, obs_val) in pairs(observed)
        #! The lookup raises for an unresolvable or an ambiguous key, naming what the summary holds,
        #! so nothing is repeated here.
        key = _summaryKeyFor(simulated, k)
        #! Two spellings of one entry -- `"tumor"` and `"counts.tumor"` in one `observed_data` --
        #! would otherwise count that component twice and weight it double against the rest. It is
        #! only visible from here, since each spelling resolves perfectly well on its own.
        haskey(claimed, key) && throw(ArgumentError(
            "mseDistance was given two observed keys that name one value: $(repr(claimed[key])) " *
            "and $(repr(k)) both resolve to \"$(summaryLabel(key))\". It would be compared twice " *
            "and weighted double — keep one spelling."))
        claimed[key] = k
        sim_val = simulated[key]
        #! A `missing` component is a `reduce` that returned `Dict(k => missing)`: legal, since
        #! nothing constrains a summary's values, and not comparable. Named here rather than left to
        #! surface one frame later as "`distance` returned a Missing", which says nothing about
        #! which quantity was absent.
        ismissing(sim_val) && throw(ArgumentError(
            "mseDistance cannot compare \"$(summaryLabel(key))\": the summary's value for it is " *
            "`missing`. A `reduce` returning a keyed value with a `missing` component gets here; " *
            "return the full value, drop the key, or return `missing` for the whole measurement " *
            "so the particle follows `on_monad_failure`."))
        (s, m) = _mseTerms(sim_val, obs_val, summaryLabel(key))
        total += s
        n += m
    end
    #! Only reachable when every named entry compared two EMPTY arrays. Refused for the same reason
    #! as an empty observation: 0/0 is not a distance, and any number returned for it would be a
    #! silent perfect score.
    n == 0 && throw(ArgumentError(
        "mseDistance compared $(length(claimed)) value(s) but computed no differences: every one " *
        "of them was empty on both sides. There is no distance to report."))
    return total / n
end

#! A scalar `observed_data` is what a one-quantity calibration is written with, and it stays legal
#! even though a summary is always a `SummaryValues` now: "exactly one entry" is the condition a bare
#! observation actually implies. Refused rather than guessed when there are several, because picking
#! one would be a silent choice of which quantity was calibrated.
#!
#! `::Any` rather than `::Real`, so a one-entry summary holding a series can be compared with a
#! series. It also has to exist for a reason of Julia's: `Base.broadcastable(::AbstractDict)` throws,
#! so a `SummaryValues` reaching the generic fallback would die inside a broadcast rather than at a
#! signature.
function mseDistance(simulated::SummaryValues, observed)
    length(simulated) == 1 || throw(ArgumentError(
        "mseDistance was given an unkeyed observation but a summary holding $(length(simulated)) " *
        "values: $(_summaryLabelListStr(simulated)). A bare observation cannot say which of them " *
        "it is for — key `observed_data` by those names instead."))
    key = only(keys(simulated))
    (total, n) = _mseTerms(simulated[key], observed, summaryLabel(key))
    n == 0 && throw(ArgumentError(
        "mseDistance computed no differences for \"$(summaryLabel(key))\": it is empty on both " *
        "sides. There is no distance to report."))
    return total / n
end

#! Keyed-vs-keyed for use OUTSIDE calibration -- a user's own `distance`, or a comparison in a
#! script. Matched by `string(k)` rather than by the key objects, because a `Dict` and a `NamedTuple`
#! naming the same quantities are the same measurement written two ways; requiring `:a` and `"a"` to
#! be told apart here made the signature stricter than the contract it serves. Observed ⊆ simulated,
#! for the same reason the `SummaryValues` method takes the observed keys as the comparison.
function mseDistance(simulated::Union{AbstractDict,NamedTuple},
                     observed::Union{AbstractDict,NamedTuple})
    sim_by_string = Dict{String,Any}(string(k) => v for (k, v) in pairs(simulated))
    obs_by_string = Dict{String,Any}(string(k) => v for (k, v) in pairs(observed))
    unmatched = [k for k in keys(obs_by_string) if !haskey(sim_by_string, k)]
    if !isempty(unmatched)
        throw(ArgumentError("""
        mseDistance was given an observed value naming $(_qoiKeyListStr(unmatched)), which the \
        simulated value does not report, so there is nothing to compare it with.
        - simulated: $(_qoiKeyListStr(keys(simulated)))
        - observed:  $(_qoiKeyListStr(keys(observed)))
        Keys are matched as strings, so a `Symbol` and a `String` naming the same quantity agree; \
        these do not. Simulated keys the observation does not name are ignored.
        """))
    end
    total = 0.0
    n = 0
    for (k, obs_val) in obs_by_string
        (s, m) = _mseTerms(sim_by_string[k], obs_val, k)
        total += s
        n += m
    end
    #! Kept as 0.0 rather than refused, unlike the `SummaryValues` methods. This one is a utility a
    #! user calls in a script, not the thing an ABC-SMC run's acceptance depends on, and two empty
    #! keyed values genuinely do have nothing to disagree about.
    n == 0 && return 0.0
    return total / n
end

mseDistance(simulated::Real, observed::Real) = Float64((simulated - observed)^2)

#! The generic fallback: two arrays, or anything else that broadcasts. It is what makes
#! `mseDistance` usable against a time series without calibration having to know that a time series
#! is what it holds. `_mseTerms` raises the comparison error, so there is nothing to add here.
function mseDistance(simulated, observed)
    (total, n) = _mseTerms(simulated, observed)
    n == 0 && return 0.0
    return total / n
end
