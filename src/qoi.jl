export QoI

"""
    QoI(name, compute; reduce=mean)

A named quantity of interest: measure something per simulation, then combine the replicates.

Three parts of ModelManager need a number out of a group of simulations — sensitivity analysis,
calibration, and the post-processing sink — and each used to ask in its own shape. A `QoI` is that
measurement written once and passed to any of them.

# Arguments
- `name`: identifies the quantity. It is the sink's column name and the key under which
  [`CalibrationProblem`](@ref) reports the value to its `distance`.
- `compute`: called with one [`Simulation`](@ref). It may return anything `reduce` understands.

# Keywords
- `reduce`: combines one parameter set's replicate values into a single value, `mean` by default.
  It receives the vector of everything `compute` returned for that set.

# What each consumer needs back
`reduce`'s return type is constrained by where the QoI is used, not by `QoI` itself: sensitivity
analysis needs a `Real`, the post-processing sink stores a `Bool`, `Integer`, `Real` or
`AbstractString`, and calibration only needs something its `distance` accepts. Returning something a
given consumer cannot use is that consumer's error to raise.

Because `reduce` sees every replicate's value, a measurement that needs the replicates *jointly*
rather than as summarised numbers is expressed by having `compute` return the raw material — a time
series, say — and letting `reduce` do the pooled work.

# Examples
```julia
tumor = QoI("tumor", s -> finalPopulationCount(s)["tumor"])

# A different way of combining replicates
QoI("tumor_median", s -> finalPopulationCount(s)["tumor"]; reduce=median)

# Spread across replicates, rather than their centre
QoI("spread", s -> finalPopulationCount(s)["tumor"]; reduce=std)

# Pooling the replicates instead of reducing per-simulation numbers
QoI("slope", timeSeries; reduce=series -> fitSlope(reduce(vcat, series)))

# One QoI, three consumers
run(MOAT(), spec; functions=[tumor])
CalibrationProblem(spec, observed, tumor, mseDistance)
run(trial; post_processor=tumor)
```
"""
struct QoI
    name::String
    compute::Function
    reduce::Function
end

QoI(name::AbstractString, compute::Function; reduce::Function=mean) =
    QoI(String(name), compute, reduce)

qoiName(q::QoI) = q.name

#! Every consumer reaches a simulation by ID, so this is the one place that turns an ID into the object
#! a user's `compute` expects. Keeping it in one function is what lets `compute` be written against
#! `Simulation` rather than against whatever each consumer happens to pass.
_computeOn(q::QoI, sim_id::Integer) = q.compute(Simulation(Int(sim_id)))

"""
    _reduceOverMonad(q, monad_id) → value

Apply `q` to every simulation of `monad_id` and combine the results with `q.reduce`.
"""
function _reduceOverMonad(q, monad_id::Integer)
    f, red = _qoiEvaluator(q)
    sim_ids = constituentIDs(Monad, Int(monad_id))
    isempty(sim_ids) && throw(ArgumentError(
        "Monad $(monad_id) has no simulations, so QoI \"$(qoiName(q))\" cannot be evaluated on it."))
    return red([f(sid) for sid in sim_ids])
end

#! A bare `Function` keeps its existing contract exactly: it is called with a simulation *ID* and its
#! replicates are averaged. Only a `QoI`'s `compute` receives a `Simulation`. Wrapping a plain function
#! into a `QoI` would silently change what it is handed, breaking every `functions=[f]` already written.
#!
#! Both collapse to the same pair — a per-simulation-ID callable and a reducer — so a consumer written
#! against that pair supports both without branching.
"""
    _qoiEvaluator(q) → (sim_id -> value, reduce)

Reduce a `QoI` or a plain `Function` to the pair every consumer needs: something callable with a
simulation ID, and the reducer for its replicates.
"""
_qoiEvaluator(q::QoI)      = (sid -> _computeOn(q, sid), q.reduce)
_qoiEvaluator(f::Function) = (sid -> f(sid), mean)
_qoiEvaluator(x) = throw(ArgumentError(
    "Expected a QoI or a Function; got $(typeof(x))."))

qoiName(f::Function) = string(nameof(f))

#! The three consumers differ in what they are handed and what they must return, so each gets its own
#! adapter — but all of them go through `_qoiEvaluator`, so a `QoI` and a plain `Function` behave the
#! same way everywhere. The adapters are internal: a user passes the `QoI` itself.
"""
    _asSummaryStatistic(x) → Function

Adapt a `QoI`, a vector of them, or an existing summary-statistic function for
[`CalibrationProblem`](@ref), which calls it with a monad ID.
"""
_asSummaryStatistic(f::Function) = f

_asSummaryStatistic(q::QoI) = _asSummaryStatistic([q])

function _asSummaryStatistic(qs::AbstractVector{QoI})
    isempty(qs) && throw(ArgumentError("A summary statistic needs at least one QoI."))
    names = qoiName.(qs)
    length(unique(names)) == length(names) || throw(ArgumentError(
        "QoI names must be unique within one summary statistic; got $(names)."))
    return (monad_id::Integer) -> Dict{String,Any}(
        q.name => _reduceOverMonad(q, monad_id) for q in qs)
end

#! No reducer here, and none possible: the hook fires once per simulation, so there is exactly one
#! value and nothing to combine. A QoI's `reduce` is simply unused by the sink.
"""
    _asPostProcessor(x) → Function

Adapt a `QoI`, a vector of them, or an existing post-processor for `run`'s `post_processor`, which
calls it once per simulation with a `SimulationProcess`.
"""
_asPostProcessor(f::Function) = f

_asPostProcessor(q::QoI) = _asPostProcessor([q])

function _asPostProcessor(qs::AbstractVector{QoI})
    isempty(qs) && throw(ArgumentError("A post-processor needs at least one QoI."))
    names = qoiName.(qs)
    length(unique(names)) == length(names) || throw(ArgumentError(
        "QoI names must be unique within one post-processor; got $(names)."))
    return function (sp::SimulationProcess)
        sid = simulationID(sp)
        return Dict{String,Any}(q.name => _computeOn(q, sid) for q in qs)
    end
end

