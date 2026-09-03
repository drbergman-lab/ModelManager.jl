export QoI, verifyStoredValues

"""
    QoI(name, compute; reduce=mean)

A named quantity of interest: measure something per simulation, then combine the replicates.

Three parts of ModelManager need a number out of a group of simulations — sensitivity analysis,
calibration, and the post-processing sink — and each used to ask in its own shape. A `QoI` is that
measurement written once and passed to any of them.

# Arguments
- `name`: identifies the quantity. It is the sink's column name and the key under which
  [`CalibrationProblem`](@ref) reports the value to its `distance`.
- `compute`: called with one [`Simulation`](@ref). It may return anything `reduce` understands — a
  scalar, a vector, a `Dict` — **except** when the QoI is used as a `post_processor`, where `reduce`
  is never called and `compute`'s own return value is what gets stored.

# Keywords
- `reduce`: combines one parameter set's replicate values into a single value, `mean` by default.
  It receives the vector of everything `compute` returned for that set.

# What each consumer needs back
Neither `compute` nor `reduce` is constrained by `QoI` itself; the requirement comes from where the QoI
is used, and it does not fall on the same function in each case:

| consumer | what must be a usable value | what it must be |
|---|---|---|
| `run(::GSAMethod, ...; functions=)` | `reduce`'s return | a `Real` (the sensitivity indices need `Float64`) |
| [`CalibrationProblem`](@ref)'s `summary_statistic` | `reduce`'s return | anything the problem's `distance` accepts |
| `run(...; post_processor=)` | **`compute`'s return** | a scalar `Bool`, `Integer`, `Real` or `AbstractString` |

The sink is the exception, and the reason is that it fires once per simulation: there is exactly one
value and nothing to combine, so `reduce` is never called and the freedom to return a vector does not
apply. Write richer per-simulation output to the simulation's own folder instead. Returning something a
consumer cannot use is that consumer's error to raise, and the sink's names the QoI and the offending
type.

Because `reduce` sees every replicate's value, a measurement that needs the replicates *jointly*
rather than as summarised numbers is expressed by having `compute` return the raw material — a time
series, say — and letting `reduce` do the pooled work.

# `reduce` is the monad-level step, not merely an average
This matters whenever the quantity involves a nonlinearity applied *after* the replicates are
combined. Sensitivity analysis on a discrepancy-to-data score is the common case: you want each
measured value averaged across replicates and *then* compared to data, because averaging squared
errors is not the same number as squaring the averaged error. A per-simulation `compute` cannot do it —
it has no access to the mean — but `reduce` can, because it receives every replicate:

```julia
observed = Dict("tumor" => 2.0, "immune" => 3.0)

QoI("mse", endpointCounts;
    reduce = per_sim -> sum((mean(getindex.(per_sim, k)) - observed[k])^2 for k in keys(observed)))
```

`compute` returns each simulation's raw values, and `reduce` averages per quantity, takes the squared
differences, and sums them into the one number sensitivity analysis needs. Reporting spread alongside
the mean is a second `QoI` over the same `compute`, with `reduce` comparing `std` to the observed
spread instead.

# Reading a value the sink stored earlier
Post-processing runs while a simulation's output folder still exists; post-simulation cleanup may then
delete what the quantity was computed from. A `QoI` whose `compute` reads the sink instead of the output
folder therefore still works afterwards, and needs nothing new — the sink is keyed by simulation ID and
by the QoI's own `name`:

```julia
tumor = QoI("tumor", s -> finalPopulationCount(s)["tumor"])
run(trial; post_processor=tumor)                      # stores it while the output exists

stored = QoI("tumor", s -> postProcessingTable([s.id]).tumor[1])
run(MOAT(), spec; functions=[stored])                 # reads it back, output folder or not
```

`stored` automates the lookup, and **defaults to `:never`**:

```julia
QoI("tumor", computeFromOutput; stored=:prefer)    # stored value if present, else compute
QoI("tumor", computeFromOutput; stored=:require)   # stored value or an error
```

It defaults off because **nothing records which `compute` produced a stored value, and no fingerprint
can**: redefining a function's body in place leaves both `hash` and `nameof` unchanged, so a changed
`compute` is undetectable, while two textually identical anonymous functions hash differently, so an
unchanged one is equally unrecognisable. The sink stores no provenance either.

What is robust is recomputation. [`verifyStoredValues`](@ref) recomputes where a simulation's output
survives and reports agreements, mismatches, and how many could not be checked because the output is
gone — which is precisely the case `stored` exists for. Run it before trusting stored values for
anything that matters.

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
    stored::Symbol
end

const _QOI_STORED_MODES = (:never, :prefer, :require)

function QoI(name::AbstractString, compute::Function;
             reduce::Function=mean, stored::Symbol=:never)
    stored in _QOI_STORED_MODES || throw(ArgumentError(
        "QoI `stored` must be one of $(_QOI_STORED_MODES); got :$(stored)."))
    return QoI(String(name), compute, reduce, stored)
end

qoiName(q::QoI) = q.name

#! Every consumer reaches a simulation by ID, so this is the one place that turns an ID into the object
#! a user's `compute` expects. Keeping it in one function is what lets `compute` be written against
#! `Simulation` rather than against whatever each consumer happens to pass.
_computeOn(q::QoI, sim::Simulation) = _computeOn(q, sim.id, sim)

_computeOn(q::QoI, sim_id::Integer) = _computeOn(q, Int(sim_id), nothing)

#! `sim` is the already-constructed `Simulation` when a caller has one (the post-processing sink
#! does), and `nothing` when only an ID is in hand. Splitting it this way keeps the stored-value
#! lookup, which needs only the ID, ahead of any database round trip to build the object.
function _computeOn(q::QoI, sid::Int, sim::Union{Nothing,Simulation})
    if q.stored !== :never
        v = _storedValue(q.name, sid)
        isnothing(v) || return v
        q.stored === :require && throw(ArgumentError(
            "QoI \"$(q.name)\" is `stored=:require` but simulation $(sid) has no stored value for " *
            "it. Run the trial with `post_processor` writing \"$(q.name)\" first, or use " *
            "`stored=:prefer` to fall back to computing it."))
    end
    return q.compute(isnothing(sim) ? Simulation(sid) : sim)
end

"""
    _storedValue(name, sim_id) → Float64 or nothing

The post-processing sink's value for `name` on `sim_id`, or `nothing` if it was never stored.
"""
function _storedValue(name::AbstractString, sim_id::Int)
    tbl = postProcessingTable([sim_id])
    nrow(tbl) == 1 || return nothing
    name in names(tbl) || return nothing
    v = tbl[1, name]
    return ismissing(v) ? nothing : Float64(v)
end

#! There is no way to check that a stored value came from *this* `compute`, and that is the whole
#! reason `stored` defaults to `:never`. Verified rather than assumed: after redefining a function's
#! body in place, both `hash` and `nameof` are unchanged, so a changed `compute` is undetectable; and
#! two textually identical anonymous functions hash *differently*, so an unchanged one is equally
#! unrecognisable. A fingerprint fails in both directions. The sink stores no provenance either — the
#! table is `simulation_id` plus one column per name.
#!
#! What *is* robust is recomputation: where a simulation's output survives, the stored value can be
#! checked against a fresh one, which is ground truth rather than a proxy for it. Where the output is
#! gone the answer is honestly "unverifiable", not a guess.
"""
    verifyStoredValues(q::QoI, T; rtol=1e-8, limit=nothing) → NamedTuple

Check a `QoI`'s stored values against freshly computed ones, for the simulations of `T`.

Returns `(; n_checked, n_agreed, n_mismatched, n_unverifiable, n_missing, mismatches)`. A simulation is
*unverifiable* when its output folder is gone, which is exactly the situation `stored` exists for — the
value may be perfectly good, but nothing here can confirm it.

Use this before trusting `stored=:prefer` or `stored=:require` on results you care about. Nothing about
a stored value records which `compute` produced it, so recomputation is the only real check.

# Example
```julia
report = verifyStoredValues(tumor, my_sampling)
report.n_mismatched == 0 || error("stored values disagree with a fresh computation")
```
"""
function verifyStoredValues(q::QoI, T::AbstractTrial; rtol::Real=1e-8,
                            limit::Union{Nothing,Integer}=nothing)
    sids = simulationIDs(T)
    isnothing(limit) || (sids = sids[1:min(length(sids), Int(limit))])
    n_agreed = 0; n_mismatched = 0; n_unverifiable = 0; n_missing = 0
    mismatches = NamedTuple{(:simulation_id, :stored, :recomputed),Tuple{Int,Float64,Float64}}[]
    for sid in sids
        v = _storedValue(q.name, Int(sid))
        if isnothing(v)
            n_missing += 1
            continue
        end
        if !isdir(pathToOutputFolder(Int(sid)))
            n_unverifiable += 1
            continue
        end
        fresh = Float64(q.compute(Simulation(Int(sid))))
        if isapprox(v, fresh; rtol=rtol)
            n_agreed += 1
        else
            n_mismatched += 1
            push!(mismatches, (simulation_id = Int(sid), stored = v, recomputed = fresh))
        end
    end
    return (; n_checked = length(sids), n_agreed, n_mismatched, n_unverifiable, n_missing, mismatches)
end

"""
    _reduceOverMonad(q, monad_id) → value

Apply `q` to every simulation of `monad_id` and combine the results with `q.reduce`.
"""
function _reduceOverMonad(q, monad_id::Integer)
    f, red = _qoiEvaluator(q)
    sim_ids = constituentIDs(Monad, Int(monad_id))
    isempty(sim_ids) && throw(ArgumentError(
        "Monad $(monad_id) has no simulations, so QoI \"$(qoiName(q))\" cannot be evaluated on it."))
    vals = [f(sid) for sid in sim_ids]
    #! Checked BEFORE calling `red`, not by catching around it. A try/catch filtering on MethodError
    #! cannot tell "`red` has no method for `vals`" from "`red` accepted `vals` and something one
    #! frame deeper raised" — the motivating case proves it, since `mean(::Vector{Dict})` raises on
    #! `/`, below `mean`. Catching around the call therefore reported a bug inside a user's own
    #! `reduce` as `reduce` rejecting its argument. Anything `red` raises now propagates untouched.
    if red === mean && !_meanApplicable(eltype(vals))
        throw(ArgumentError("""
        QoI "$(qoiName(q))": `compute` returned $(eltype(vals)), which the default `reduce=mean` \
        cannot average, so the $(length(vals)) replicate value(s) of monad $(monad_id) cannot be \
        combined. To report several named quantities, pass one QoI per quantity (a vector of QoIs) \
        rather than one QoI whose `compute` returns a Dict; or give this QoI a `reduce` that \
        accepts a Vector{$(eltype(vals))}."""))
    end
    return red(vals)
end

#! `mean` is `sum(vals) / length(vals)`, so it needs `+` on the element type and `/` by an `Int`.
#! A non-concrete eltype is deliberately left alone — a heterogeneous `Vector{Any}` of numbers averages
#! fine, and a false positive here would reject code that works today.
_meanApplicable(::Type{T}) where {T} =
    !isconcretetype(T) || (hasmethod(+, Tuple{T,T}) && hasmethod(/, Tuple{T,Int}))

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
#! A `CalibrationProblem` stores whatever it was handed rather than collapsing it to a function. The
#! earlier version converted a `QoI` into a monad-level closure at construction, which threw away the
#! per-simulation `compute` — so nothing downstream could evaluate the quantity on a single simulation
#! even though the user had supplied exactly the object that knows how. Reversing the direction is not
#! possible: a plain `summary_statistic` is called with a *monad ID* by contract and has no
#! per-simulation decomposition inside it, so it cannot be wrapped into a `QoI`, whose `compute`
#! receives one `Simulation`. Preserving and dispatching is what GSA's `functions=` already does.
"""
    _validateSummaryStatistic(x) → Function | QoI | Vector{QoI}

Check that `x` can serve as a [`CalibrationProblem`](@ref)'s `summary_statistic` and return it in
canonical form, unchanged in kind. Validation is eager — at construction, not at first evaluation —
so a duplicate QoI name is reported before any simulation runs.
"""
_validateSummaryStatistic(f::Function) = f

_validateSummaryStatistic(q::QoI) = q

function _validateSummaryStatistic(qs::AbstractVector{QoI})
    isempty(qs) && throw(ArgumentError("A summary statistic needs at least one QoI."))
    names = qoiName.(qs)
    length(unique(names)) == length(names) || throw(ArgumentError(
        "QoI names must be unique within one summary statistic; got $(names)."))
    return collect(qs)
end

_validateSummaryStatistic(x) = throw(ArgumentError(
    "A summary statistic must be a Function, a QoI, or a vector of QoIs; got $(typeof(x))."))

"""
    _evaluateSummary(ss, monad_id) → value

Evaluate a [`CalibrationProblem`](@ref)'s `summary_statistic` on one monad. A plain `Function` is
called with the monad ID; a `QoI` is reduced over the monad's simulations and reported under its name.
"""
_evaluateSummary(f::Function, monad_id::Integer) = f(monad_id)

_evaluateSummary(q::QoI, monad_id::Integer) =
    Dict{String,Any}(q.name => _reduceOverMonad(q, monad_id))

_evaluateSummary(qs::AbstractVector{QoI}, monad_id::Integer) =
    Dict{String,Any}(q.name => _reduceOverMonad(q, monad_id) for q in qs)

"""
    _summaryQoIs(ss) → Vector{QoI}

The QoIs behind a `summary_statistic`, or empty for a plain function. Empty means the quantity can
only be evaluated per monad.
"""
_summaryQoIs(::Function) = QoI[]
_summaryQoIs(q::QoI) = QoI[q]
_summaryQoIs(qs::AbstractVector{QoI}) = collect(qs)

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
    #! `sp` already carries the `Simulation`, so pass it through rather than re-querying it by ID:
    #! `_computeOn(q, sid)` would build a fresh one per QoI per simulation.
    return function (sp::SimulationProcess)
        return Dict{String,Any}(q.name => _computeOn(q, sp.simulation) for q in qs)
    end
end

