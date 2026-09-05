export QoI, verifyStoredValues

"""
    QoI(name, compute; reduce=mean)

A named quantity of interest: measure something per simulation, then combine the replicates.

Three parts of ModelManager need a number out of a group of simulations — sensitivity analysis,
calibration, and the post-processing sink — and each used to ask in its own shape. A `QoI` is that
measurement written once and passed to any of them.

# Arguments
- `name`: identifies the quantity. It is the sink's column name and the key under which
  [`CalibrationProblem`](@ref) reports the value to its `distance`. It may not contain a `.`, which
  is reserved as the separator between a quantity and its components (see below).
- `compute`: called with one [`Simulation`](@ref). It may return anything `reduce` understands — a
  scalar, a vector, a `Dict` — **except** when the QoI is used as a `post_processor`, where `reduce`
  is never called and `compute`'s own return value is what gets stored.

# Keywords
- `reduce`: collapses one parameter set's *replicates*, `mean` by default. It receives the vector of
  everything `compute` returned for that set — one entry per replicate — and returns that set's
  value. It is not `Base.reduce`, and the result need not be a scalar: what it reduces is the
  replicate dimension, so returning a `Dict` of `name => value` is a reduction over replicates that
  keeps several quantities, and every consumer here understands one.

# What each consumer needs back
Neither `compute` nor `reduce` is constrained by `QoI` itself; the requirement comes from where the QoI
is used, and it does not fall on the same function in each case:

| consumer | what must be a usable value | what it must be |
|---|---|---|
| `run(::GSAMethod, ...; functions=)` | `reduce`'s return | a `Real`, or a `Dict`/`NamedTuple` of them |
| [`CalibrationProblem`](@ref)'s `summary_statistic` | `reduce`'s return | anything the problem's `distance` accepts |
| `run(...; post_processor=)` | **`compute`'s return** | a scalar `Bool`, `Integer`, `Real` or `AbstractString` |

The sink is the exception, and the reason is that it fires once per simulation: there is exactly one
value and nothing to combine, so `reduce` is never called and the freedom to return a vector does not
apply. Write richer per-simulation output to the simulation's own folder instead. Returning something a
consumer cannot use is that consumer's error to raise, and the sink's names the QoI and the offending
type.

# A `Dict` becomes several quantities, not one
Two consumers spread a keyed value rather than demanding one number, and both name the pieces the
same way — `"<qoi name>.<key>"` — so one measurement names its parts identically wherever it is used:

- **Sensitivity analysis** runs one analysis per key, labelled `"<qoi name>.<key>"` — so
  `QoI("counts", …)` reducing to `Dict("tumor" => …, "immune" => …)` gives `counts.tumor` and
  `counts.immune`. Every monad must reduce to the *same* keys; one that does not is refused, because a
  sensitivity index computed over a missing value is wrong rather than approximate. A `Vector` is not
  spread by index: only its length could be checked against the other monads', and equal length is not
  equal meaning.
- **The sink** names its columns the same way: `"<qoi name>.<key>"`. Because those names are
  persisted, an *anonymous* `compute` is refused outright when it spreads — its derived `anon_9`
  would prefix every column and vary between sessions. Name the QoI, or pass a named function.

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

# Several quantities from one measurement, named the same way in both places: GSA spreads
# `reduce`'s keys into `counts.tumor` / `counts.immune`, and the sink spreads `compute`'s keys
# into columns `counts.tumor` / `counts.immune`.
counts = QoI("counts", finalPopulationCount;
             reduce = per_sim -> Dict(k => mean(getindex.(per_sim, k)) for k in ("tumor", "immune")))
```
"""
struct QoI
    name::String
    compute::Function
    reduce::Function
    stored::Symbol
end

const _QOI_STORED_MODES = (:never, :prefer, :require)

#! The separator is reserved so that a label can be read backwards. Every name a spread quantity
#! produces is `"<qoi name>.<key>"`, and sensitivity analysis decides whether a QoI has already been
#! evaluated by testing exactly that shape against its name -- before reading any output, which is
#! what makes the check a saving rather than a late no-op. Allow a `.` inside a name and the shape is
#! ambiguous: `QoI("counts.x", …)` alongside a `QoI("counts", …)` that spreads to `x` gives two
#! different QoIs a claim on the label `counts.x`. Within one call that collides and is refused, but
#! across calls it silently skips -- either the second QoI (leaving the first's value under its
#! label) or, worse, the whole spreading QoI, so a legitimate `counts.y` is never computed.
#!
#! Refused at construction rather than inferred later because provenance cannot be recovered from a
#! label once it exists. `_qoiNameFromFunction` already regularises to `[A-Za-z_][A-Za-z0-9_]*`, so
#! nothing ModelManager derives can trip this -- only a name a user chose.
function QoI(name::AbstractString, compute::Function;
             reduce::Function=mean, stored::Symbol=:never)
    stored in _QOI_STORED_MODES || throw(ArgumentError(
        "QoI `stored` must be one of $(_QOI_STORED_MODES); got :$(stored)."))
    occursin('.', name) && throw(ArgumentError(
        "QoI names cannot contain a `.`; got \"$(name)\". The dot separates a quantity from its " *
        "components — a `Dict`-valued measurement is labelled \"$(name)\" plus `.` plus each key — " *
        "so a name carrying one would be indistinguishable from another QoI's component. Use `_`."))
    return QoI(String(name), compute, reduce, stored)
end

qoiName(q::QoI) = q.name

#! `compute` is always handed a `Simulation`. The ID method exists only because the stored-value
#! lookup needs just an ID, so a `stored=:prefer`/`:require` hit answers without a database round trip
#! to build the object; on a miss it constructs one and delegates.
function _computeOn(q::QoI, sim_id::Integer)
    sid = Int(sim_id)
    v = _storedLookup(q, sid)
    isnothing(v) || return v
    return q.compute(Simulation(sid))
end

function _computeOn(q::QoI, sim::Simulation)
    v = _storedLookup(q, sim.id)
    isnothing(v) || return v
    return q.compute(sim)
end

#! `nothing` means "no stored value, compute it".
function _storedLookup(q::QoI, sid::Int)
    q.stored === :never && return nothing
    v = _storedValue(q.name, sid)
    isnothing(v) || return v
    q.stored === :require && throw(ArgumentError(
        "QoI \"$(q.name)\" is `stored=:require` but simulation $(sid) has no stored value for " *
        "it. Run the trial with `post_processor` writing \"$(q.name)\" first, or use " *
        "`stored=:prefer` to fall back to computing it."))
    return nothing
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
# `n_mismatched == 0` alone is NOT a pass: it is also what you get when every simulation was
# skipped. Require that something was actually compared.
report.n_agreed > 0 || error("nothing was verified: \$(report.n_missing) had no stored value " *
                             "and \$(report.n_unverifiable) had no output folder to recompute from")
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
function _reduceOverMonad(x, monad_id::Integer)
    q = _asQoI(x)
    sim_ids = constituentIDs(Monad, Int(monad_id))
    isempty(sim_ids) && throw(ArgumentError(
        "Monad $(monad_id) has no simulations, so QoI \"$(q.name)\" cannot be evaluated on it."))
    #! One query for the whole monad, as `simulationsFromIDs`' own docstring asks. Building them one
    #! at a time is the N+1 pattern that docstring warns against, and this path now runs for every
    #! replicate of every particle. It skips missing IDs rather than throwing, so that is checked.
    sims = simulationsFromIDs(sim_ids)
    length(sims) == length(sim_ids) || throw(ArgumentError(
        "Monad $(monad_id) lists $(length(sim_ids)) simulations but only $(length(sims)) are in the " *
        "database, so QoI \"$(q.name)\" cannot be evaluated on it."))
    return q.reduce([_computeOn(q, sim) for sim in sims])
end

#! One contract, and one internal representation. A user may hand any consumer a bare `Function`; it
#! is wrapped into a `QoI` here, at the boundary, so nothing downstream branches on which it was
#! given. The wrapper supplies the two things a bare function lacks: a name, and `reduce = mean`.
#!
#! Before this, a bare `Function` meant three different things -- a simulation *ID* in `functions=`, a
#! *monad* ID in `CalibrationProblem`, and a `SimulationProcess` at the sink. Two were an `Int`, and
#! both ID spaces are dense positive integers, so handing a calibration summary to `functions=`
#! measured the wrong entity and returned a plausible number with no error anywhere.
"""
    _asQoI(x) → QoI

Wrap `x` as a [`QoI`](@ref) if it is not one already. A bare `Function` becomes
`QoI(name, f; reduce=mean)`, with `name` derived from the function; a `QoI` passes through untouched.
"""
_asQoI(q::QoI) = q
_asQoI(f::Function) = QoI(_qoiNameFromFunction(f), f)
_asQoI(x) = throw(ArgumentError("Expected a QoI or a Function; got $(typeof(x))."))

#! Anonymous functions are named `"#3"` / `"#3#4"` -- distinct per function (measured, so fine as
#! identities) but not valid identifiers, and this name becomes a sink column name and a `Dict` key.
#! So regularise rather than reject: `#3#4` becomes `anon_3_4`.
"""
    _qoiNameFromFunction(f) → String

A name for a bare function, usable as a database column and a `Dict` key. Named functions keep their
own name; anonymous ones get a regularised `anon_…` form.
"""
function _qoiNameFromFunction(f::Function)
    raw = string(nameof(f))
    occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", raw) && return raw
    return "anon" * replace(raw, r"[^A-Za-z0-9_]+" => "_")
end

qoiName(f::Function) = string(nameof(f))

#! The three consumers differ in what they are handed and what they must return, so each gets its own
#! adapter — but all of them go through `_asQoI` first, so nothing downstream ever sees a bare
#! `Function`. The adapters are internal: a user passes the `QoI` or the function itself.
#! Calibration is the one consumer whose GRANULARITY changed: a bare function used to be called once
#! per *monad* and aggregate the replicates itself. Reinterpreting such a function per-simulation and
#! averaging is a different number for any post-aggregation nonlinearity -- squaring the mean of
#! [10, 20] gives 225, the mean of the squares gives 250 -- and nothing raises.
#!
#! Nor can `distance` be relied on to catch it. `mseDistance(::Dict, ::Dict)` is deliberately
#! permissive about key mismatches: it warns once (`maxlog=1`) and computes anyway, treating absent
#! keys as zero. So the wrong number flows through to a converged, wrong posterior.
#!
#! The distinguishing signal is the DECLARED argument type. A function written for the new contract
#! says so -- `f(s::Simulation)`, or an annotated lambda `(s::Simulation) -> ...` -- while every
#! old-contract function is either untyped (`f(mid)`, declared `Any`) or annotated `::Int`. That is
#! checkable, so it is checked, at construction, before any simulation runs.
#!
#! This is not the dispatch-*sniffing* that was rejected. Sniffing tried to adapt all three old
#! contracts by guessing which one a function wanted; for an untyped argument `hasmethod` answers
#! `true` for every candidate, so it would have silently picked one. Here an ambiguous signature is
#! refused rather than guessed at, which is the whole difference.
"""
    _declaresSimulation(f) → Bool

Whether `f` has a method whose first argument is declared to accept a [`Simulation`](@ref) --
`Simulation` itself or a supertype of it, but not `Any`. An untyped argument carries no intent, so it
does not count.
"""
function _declaresSimulation(f::Function)
    for m in methods(f)
        #! `m.sig` is a `UnionAll` for any method with a `where` clause, and indexing its `.parameters`
        #! throws. A method can also have no argument at all, or a `Vararg` in first position -- so
        #! every step here is guarded. Reaching for `parameters[2]` unguarded made a CORRECTLY migrated
        #! `f(s::S) where {S<:Simulation}` unconstructable, which is the opposite of this guard's job.
        sig = Base.unwrap_unionall(m.sig)
        sig isa DataType || continue
        length(sig.parameters) >= 2 || continue
        T = sig.parameters[2]
        #! A `where` parameter arrives as a `TypeVar`, whose upper bound is the declared constraint:
        #! `f(s::S) where {S<:Simulation}` has `S.ub === Simulation`. Without this the guard reads the
        #! TypeVar itself, decides it is not a type, and rejects a correctly written function.
        T isa TypeVar && (T = T.ub)
        T = Base.unwrap_unionall(T)
        T isa Type || continue
        T !== Any && Simulation <: T && return true
    end
    return false
end

"""
    _validateSummaryStatistic(x) → Function | QoI | Vector{QoI}

Check that `x` can serve as a [`CalibrationProblem`](@ref)'s `summary_statistic` and return it
unchanged in kind. Validation is eager -- at construction, not at first evaluation -- so both a
duplicate QoI name and an unmigrated summary function are reported before any simulation runs.
"""
_validateSummaryStatistic(q::QoI) = q

function _validateSummaryStatistic(qs::AbstractVector{QoI})
    isempty(qs) && throw(ArgumentError("A summary statistic needs at least one QoI."))
    names = qoiName.(qs)
    length(unique(names)) == length(names) || throw(ArgumentError(
        "QoI names must be unique within one summary statistic; got $(names)."))
    return collect(qs)
end

#! TRANSITIONAL -- remove in v0.10. This whole apparatus exists only to warn people migrating from the
#! pre-0.9 contract, where a bare `summary_statistic` was called once per *monad* and aggregated its
#! own replicates. Once 0.9 is behind us there is nothing to disambiguate and a bare function is simply
#! a per-simulation measurement, so delete: `_declaresSimulation` (used by nothing else),
#! `_WARNED_SUMMARIES`, and the `if !_declaresSimulation(...)` block below -- leaving
#! `_validateSummaryStatistic(f::Function) = _asQoI(f)`. In the tests, that also retires the
#! "_declaresSimulation survives every method signature shape" and "the migration warning is per
#! function, not per session" testsets, and the `_sim_where` / `_sim_varargs` / `_sim_unbounded` /
#! `_sim_zeroarg` helpers they use. Tracked in CLAUDE.md's to-do list.
#!
#! Suppression is keyed on the FUNCTION, not on the log site. `maxlog=1` counts callsite hits, so a
#! script building several problems in one session warned about the first and went silent for the
#! rest -- exactly the case the warning exists for.
const _WARNED_SUMMARIES = Base.IdSet{Any}()

function _validateSummaryStatistic(f::Function)
    #! Warned, not refused. The declared argument type is the only available signal that a function was
    #! written for the new contract -- an old monad-level summary is untyped or `::Int` -- but refusing
    #! every unannotated function also rejects `sim -> measure(sim)`, the natural new-contract lambda.
    #! The risk is real: an old summary that aggregated its own replicates now returns a different
    #! number rather than an error, and `mseDistance` will not catch it (on a key mismatch it warns
    #! once and computes anyway, treating absent keys as zero).
    if !_declaresSimulation(f) && !(f in _WARNED_SUMMARIES)
        push!(_WARNED_SUMMARIES, f)
        #! Named by where it was written, not by the regularised `anon_N`: that name is an internal
        #! column identifier and means nothing to someone reading a warning.
        who = _isAnonymousFunction(f) ? "the anonymous function defined at $(functionloc(f))" :
                                        "`$(nameof(f))`"
        @warn """
            `summary_statistic` was given a function that does not declare it takes a `Simulation`.

            Measurement functions are now called once per *simulation*, and their replicates are
            combined by `reduce` (`mean` here). If $(who) was written for the previous contract --
            called once per *monad*, doing its own aggregation -- it will now return a different value
            with no error. Annotate it `(s::Simulation)` to silence this, or pass a `QoI` to choose the
            reduction.
            """
    end
    return _asQoI(f)
end

_validateSummaryStatistic(x) = throw(ArgumentError(
    "A summary statistic must be a QoI or a vector of QoIs; got $(typeof(x))."))

#! One QoI yields its value directly; several yield a `Dict` keyed by name. Keeping the single-QoI
#! case unwrapped is what preserves the scalar and vector `observed_data` shapes `mseDistance`
#! documents -- wrapping every case would make a `Dict` the only comparable shape and silently retire
#! two thirds of that function's methods.
"""
    _evaluateSummary(ss, monad_id) → value

Evaluate a [`CalibrationProblem`](@ref)'s `summary_statistic` on one monad: a single `QoI` reduces to
its own value, a vector of them to a `Dict` keyed by QoI name.
"""
_evaluateSummary(q::QoI, monad_id::Integer) = _reduceOverMonad(q, monad_id)


_evaluateSummary(qs::AbstractVector{QoI}, monad_id::Integer) =
    Dict{String,Any}(q.name => _reduceOverMonad(q, monad_id) for q in qs)


#! No reducer here, and none possible: the hook fires once per simulation, so there is exactly one
#! value and nothing to combine. A QoI's `reduce` is simply unused by the sink.
#!
#! A `compute` returning a `NamedTuple` or a `Dict` contributes one column per key, named
#! `"<qoi name>.<key>"` -- the same rule sensitivity analysis uses for a spread `reduce`, so one
#! measurement names its parts the same way wherever it is consumed. This is what lets a QoI discover
#! its column set from the simulation's own output at run time, and it is why two QoIs that both
#! measure "tumor" no longer collide in a single column.
#!
#! It also means an anonymous `compute` can no longer write columns at all, since its derived name
#! would prefix every one of them. That capability was deliberately given up: namespacing is worth
#! more than the convenience of an unnamed lambda, and naming the QoI is a one-word fix.
"""
    _asPostProcessor(x) → Function

Adapt a `QoI`, a vector of them, or a bare function for `run`'s `post_processor`. The adapted function
is called once per simulation with a [`Simulation`](@ref).
"""
_asPostProcessor(x) = _asPostProcessor([_asQoI(x)])

function _asPostProcessor(qs::AbstractVector{QoI})
    isempty(qs) && throw(ArgumentError("A post-processor needs at least one QoI."))
    names = qoiName.(qs)
    length(unique(names)) == length(names) || throw(ArgumentError(
        "QoI names must be unique within one post-processor; got $(names)."))
    return function (sim::Simulation)
        #! Ordered pairs, not a `Dict`: round-tripping through one scrambled a `NamedTuple`'s field
        #! order, so the sink added its columns in hash order. Distinct keys that collide once
        #! stringified (`1` and `"1"`) still reach the sink as two separate entries, so its
        #! `allunique` check still sees and rejects them.
        entries = Pair{Any,Any}[]
        for q in qs
            v = _computeOn(q, sim)
            #! `nothing`/`missing` records nothing for this simulation -- how a post-processor skips
            #! one whose output it could not read.
            (isnothing(v) || ismissing(v)) && continue
            spreads = v isa NamedTuple || v isa AbstractDict
            #! A gensym must never become a persistent database column, and since EVERY column a QoI
            #! writes is now named after it, that applies to a spread return as much as a scalar one:
            #! the regularised `anon_9` varies between sessions, so the same script would write a
            #! second, half-empty set of columns next time.
            #!
            #! One narrowing. Only values the sink would actually store: a return it rejects anyway
            #! (a bare `Vector`, say) keeps flowing to its own error, which is raised outside the
            #! per-simulation stage and so stays an `ArgumentError` at the call site. And only a name
            #! that was AUTO-DERIVED -- `QoI("counts", sim -> …)` has an anonymous `compute` but a
            #! perfectly good name, and must not be refused.
            (spreads || v isa Union{Bool,Integer,Real,AbstractString}) &&
                _isAnonymousFunction(q.compute) &&
                q.name == _qoiNameFromFunction(q.compute) && throw(ArgumentError(
                "post_processor: an anonymous function has no stable name, and every sink column is " *
                "named after the QoI that wrote it — this $(typeof(v)) would be stored as " *
                (spreads ? "\"<name>.<key>\" per key" : "\"<name>\"") * ". The derived name " *
                "varies between sessions, so the same script would write a second, half-empty set " *
                "of columns next time. Name it — `QoI(\"my_quantity\", f)` — or pass a named " *
                "function."))
            if spreads
                #! Namespaced by the QoI's name, matching how sensitivity analysis labels the same
                #! spread. Two QoIs measuring "tumor" no longer land in one column.
                for (k, vv) in pairs(v)
                    push!(entries, "$(q.name).$(k)" => vv)
                end
            else
                push!(entries, q.name => v)
            end
        end
        isempty(entries) && return nothing
        return entries
    end
end

