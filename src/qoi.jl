export QoI, SummaryValues, verifyStoredValues

"""
    QoI(name, compute; reduce=<per-key mean>, stored=:never, skip_missing=true, data=nothing)

A named quantity of interest: measure something per simulation, then combine the replicates.

Three parts of ModelManager need a number out of a group of simulations — sensitivity analysis,
calibration, and the post-processing sink — and each used to ask in its own shape. A `QoI` is that
measurement written once and passed to any of them.

# The contract
`compute` and `reduce` are your functions; ModelManager does not interpret their values, and each
consumer accepts what it can use. `compute` returns one simulation's value, or `missing` for none;
`reduce` receives the surviving replicate values and returns the parameter set's value, or
`missing`; `nothing` is refused on both paths.

- **The sink** sees only `compute`'s value, and requires a `Real` or a flat, non-empty
  `Dict`/`NamedTuple` of `Real`s, because each one becomes a column. A `String` is not a
  measurement — text about a simulation is a tag; see [`tag!`](@ref).
- **Sensitivity analysis** sees only `reduce`'s value, and requires the same, because each key
  becomes an analysis needing one number per monad.
- **Calibration** requires nothing of either: `reduce`'s value goes into the
  [`SummaryValues`](@ref) your `distance` receives — a `Real` under `(name, nothing)`, a keyed
  value one entry per key, anything else (a `Vector`, a `Matrix`, your own struct) whole under
  `(name, nothing)`.

**`reduce` need not return the shape it was given**, and only the *default* reducer requires the
replicates to agree about their keys. A custom `reduce` sees the replicate values exactly as
`compute` produced them and may reconcile ragged ones itself — filling an absent cell type with a
zero, say.

Two rules hold whatever the value is:

- **`compute` returns `missing` to say "no value for this simulation"** — output it could not read,
  a measurement that does not apply. Missing replicates are dropped before `reduce`, and a
  parameter set with none left is itself `missing`. `reduce` may return `missing` for the same
  reason at the parameter-set level — "too few usable replicates to answer" — and that is a
  supported answer rather than an accident. `nothing` is refused on both paths, because it is too
  easily the accidental value of a `if`/`for` block that fell through.
- **Every component is named `(qoi name, key)`, in every consumer.** A component of a keyed
  measurement belongs to the QoI that produced it, so two QoIs may both report a `tumor` without
  colliding, and a QoI may be keyed the same way as its neighbour. The sink and sensitivity
  analysis spell that pair `"<qoi name>.<key>"`; `distance` receives a [`SummaryValues`](@ref),
  which answers to `"name"`, to `"name.key"`, and to a bare `"key"` when exactly one QoI produced
  it. Only names are yours to choose: a `Real`-valued QoI is named by its `name` alone, so two
  `Real` QoIs sharing one name is the collision that is refused.

# Arguments
- `name`: identifies the quantity. It is the sink's column name and the sensitivity label. It may
  not contain a `.`, which is reserved as the separator between a quantity and its components.
- `compute`: called with one [`Simulation`](@ref) — or with `(simulation, data)` when `data` is
  supplied; returns that simulation's QoI value, or `missing`.

# Keywords
- `reduce`: collapses one parameter set's *replicates*. It receives the vector of everything
  `compute` returned for that set — one entry per replicate — and returns that set's value, or
  `missing` if it decides there is none. It is not `Base.reduce`. Its value need not be shaped like
  the values it was given: a keyed `compute` may reduce to one number, and a `Real` one to a keyed
  value, as long as the consumer you pass the QoI to accepts the result. The default is a per-key
  mean: `mean` for `Real`s, and for keyed values the mean of each key, returned in the first
  replicate's kind of container — which is the one reducer that requires every replicate to carry
  the same keys, since it averages key by key.
- `stored`: `:never` (default), `:prefer`, or `:require` — see below.
- `skip_missing`: `true` (default) drops `missing` replicates before calling `reduce`, and yields
  `missing` for the parameter set when none remain. `false` hands `reduce` the raw vector,
  `missing`s included, for a reducer that wants to see how many replicates had no value.
- `data`: anything the measurement needs besides the simulation — an observation to score against,
  a set of cell types, a time grid. **It changes the calling convention, explicitly and without
  sniffing:** when `data !== nothing`, `compute` is called as `compute(simulation, data)` and
  `reduce` as `reduce(values, data)`; otherwise both take one argument. It is serialised inside the
  `QoI` in a calibration's `problem.jld2`, so a resume needs nothing re-supplied as long as `data`
  itself is serialisable — a `Dict` of numbers is. (Restorability is decided by the two *functions*,
  which is unchanged: name them and the QoI round-trips.)

# A keyed value is several quantities, not one
A keyed value is spread by one naming rule for every consumer — each component is `(qoi name, key)`
— so one measurement names its parts identically wherever it is used. The sink and sensitivity
analysis write that pair as `"<qoi name>.<key>"`:

- **Sensitivity analysis** runs one analysis per key — so `QoI("counts", …)` reducing to
  `Dict("tumor" => …, "immune" => …)` gives `counts.tumor` and `counts.immune`. Every monad must
  reduce to the *same* keys; one that does not is refused, because a sensitivity index computed over
  a missing value is wrong rather than approximate.
- **The sink** names its columns the same way. Because those names are persisted, an *anonymous*
  `compute` is refused outright — its derived `anon_9` would prefix every column and vary between
  sessions. Name the QoI, or pass a named function.

**Calibration uses the same names, through a [`SummaryValues`](@ref).** `distance`'s first argument
is always one, for a single QoI as much as for a vector of them, and it is keyed by the same
`(qoi name, key)` pairs — so `observed_data` may be written as `"counts.tumor"`, or as the bare
`"tumor"` when only one QoI reports that key. A `Real`-valued QoI is the pair `(name, nothing)` and
answers to `"name"`. [`mseDistance`](@ref) resolves an observation's keys that way, and a scalar
`observed_data` still works against a one-entry summary. What it does *not* impose is a rule about
the values: an unkeyed value of any type is one entry under `(name, nothing)`, so a `reduce`
returning a time series per cell type reaches `distance` as one series per key.

# `reduce` is the monad-level step, not merely an average
It matters whenever the quantity involves a nonlinearity applied *after* the replicates are
combined — a discrepancy-to-data score is the common case, since averaging squared errors is not the
same number as squaring the averaged error. A per-simulation `compute` cannot do it; `reduce` can,
because it receives every replicate. `data=` is where the observation it is scored against belongs.

For calibration alone, `reduce` may return the score by itself. Put it in the returned keys
*alongside* the raw quantities when you also want sensitivity analysis on it: then one QoI serves
all three consumers at once, GSA gets a `"<name>.my_dist"` analysis, and the sink gets a
per-simulation score for free. The calibration manual works that pattern through end to end.

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

A keyed QoI is read back from its `"<name>.<key>"` columns as a `Dict` with `String` keys, whatever
key type `compute` used.

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

# One QoI, three consumers
run(MOAT(), spec; functions=[tumor])
CalibrationProblem(spec, observed, tumor, mseDistance)
run(trial; post_processor=tumor)

# Several quantities from one measurement. The default `reduce` already averages per key, so a
# keyed measurement needs no reducer of its own: GSA labels these `counts.tumor` / `counts.immune`,
# the sink writes those columns, and `distance` can ask for either spelling.
counts = QoI("counts", finalPopulationCount)

# A measurement that needs the observation it is scored against. `data` switches the calling
# convention, so both functions take it as a second argument and neither closes over it.
scoreCounts(sim, obs)      = merge(finalPopulationCount(sim), Dict("fit" => …))
scoreReduce(per_sim, obs)  = …
fit = QoI("fit", scoreCounts; reduce=scoreReduce, data=Dict("tumor" => 320.0))
```
"""
struct QoI
    name::String
    compute::Function
    reduce::Function
    stored::Symbol
    skip_missing::Bool
    #! Untyped, because it is the user's own object and nothing here interprets it: the only rule is
    #! that `nothing` means "no data", which is what selects the one-argument calling convention.
    #! Anything else is handed back to `compute`/`reduce` unexamined.
    data::Any
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
             reduce::Function=_qoiMean, stored::Symbol=:never, skip_missing::Bool=true,
             data=nothing)
    stored in _QOI_STORED_MODES || throw(ArgumentError(
        "QoI `stored` must be one of $(_QOI_STORED_MODES); got :$(stored)."))
    occursin(_QOI_LABEL_SEPARATOR, name) && throw(ArgumentError(
        "QoI names cannot contain a `.`; got \"$(name)\". The dot separates a quantity from its " *
        "components — a `Dict`-valued measurement is labelled \"$(name)\" plus `.` plus each key — " *
        "so a name carrying one would be indistinguishable from another QoI's component. Use `_`."))
    return QoI(String(name), compute, reduce, stored, skip_missing, data)
end

qoiName(q::QoI) = q.name

#! The calling convention is chosen by `data !== nothing` and by nothing else -- no `applicable`, no
#! method-table sniffing. Both alternatives are wrong in the same direction: a `compute` that
#! accidentally accepts two arguments (a `(sim, x=default)` form, or an untyped `f(a, b)` the user
#! meant for something else) would be called with the data it was never written for, and the failure
#! would surface as an arithmetic error deep inside the user's own function rather than as a
#! signature mismatch at the call site. Declaring `data` is the whole opt-in.
"""
    _callCompute(q, sim) → value

Call `q.compute` under the convention `q.data` selects: `compute(sim)`, or `compute(sim, q.data)`.
"""
_callCompute(q::QoI, sim::Simulation) =
    isnothing(q.data) ? q.compute(sim) : q.compute(sim, q.data)

"""
    _callReduce(q, values) → value

Call `q.reduce` under the convention `q.data` selects: `reduce(values)`, or `reduce(values, q.data)`.
"""
_callReduce(q::QoI, values) =
    isnothing(q.data) ? q.reduce(values) : q.reduce(values, q.data)

function _computeOn(q::QoI, sim::Simulation)
    v = _storedLookup(q, sim.id)
    isnothing(v) || return v
    return _callCompute(q, sim)
end

#! `nothing` means "no stored value, compute it".
function _storedLookup(q::QoI, sid::Int)
    q.stored === :never && return nothing
    v = _storedValue(q.name, sid)
    isnothing(v) || return v
    q.stored === :require && throw(ArgumentError(
        "QoI \"$(q.name)\" is `stored=:require` but simulation $(sid) has no stored value for " *
        "it. Run the trial with `post_processor` writing \"$(q.name)\" first, or use " *
        "`stored=:prefer` to fall back to computing it. A keyed QoI's columns are " *
        "\"$(q.name)$(_QOI_LABEL_SEPARATOR)<key>\", one per key, so it is those that must have " *
        "been written."))
    return nothing
end

"""
    _storedValue(name, sim_id) → value or nothing

The post-processing sink's value for `name` on `sim_id`, or `nothing` if it was never stored. A
scalar comes back as the sink holds it. A value a `QoI` wrote is a `Float64`, since `_keyedEntries`
converts every component on the way in; a column written by another route may hold an `Int64`, a
`String`, or a `Bool`, which the sink stores as INTEGER and reads back as `0`/`1`. A keyed value,
which the sink spread into `"<name>.<key>"` columns, comes back as a `Dict{String,Any}` over those
keys -- with `String` keys, since that is all a column name can carry.
"""
function _storedValue(name::AbstractString, sim_id::Int)
    tbl = postProcessingTable([sim_id])
    nrow(tbl) == 1 || return nothing
    cols = names(tbl)
    if name in cols
        v = tbl[1, name]
        return ismissing(v) ? nothing : v
    end
    #! Read back the way the sink wrote it: `_postProcess` spreads a keyed compute into one column
    #! per key, so the value is reassembled from every column this name owns.
    prefix = name * _QOI_LABEL_SEPARATOR
    spread = filter(c -> startswith(c, prefix), cols)
    isempty(spread) && return nothing
    d = Dict{String,Any}(String(chop(c; head=length(prefix), tail=0)) => tbl[1, c]
                         for c in spread if !ismissing(tbl[1, c]))
    return isempty(d) ? nothing : d
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
*unverifiable* when its output folder is gone -- exactly the situation `stored` exists for — or when
`compute` returns `missing`/`nothing` for it: the value may be perfectly good, but nothing here can
confirm it. The recomputation uses the QoI's own calling convention, so a `data`-carrying `compute`
is called with its data. Numbers are compared with `isapprox` at `rtol`. A keyed value is compared
key by key; the sink stores keys as `String`s, so a `NamedTuple`-keyed `compute` is compared against
its stringified keys. Anything else is compared with `isequal`.

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
    mismatches = NamedTuple{(:simulation_id, :stored, :recomputed),Tuple{Int,Any,Any}}[]
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
        fresh = _callCompute(q, Simulation(Int(sid)))
        if isnothing(fresh) || ismissing(fresh)
            n_unverifiable += 1
            continue
        end
        if _storedAgrees(v, fresh; rtol=rtol)
            n_agreed += 1
        else
            n_mismatched += 1
            push!(mismatches, (simulation_id = Int(sid), stored = v, recomputed = fresh))
        end
    end
    return (; n_checked = length(sids), n_agreed, n_mismatched, n_unverifiable, n_missing, mismatches)
end

"""
    _storedAgrees(stored, fresh; rtol) → Bool

Whether a value read back from the sink matches a freshly computed one: `isapprox` for numbers, key
by key for a keyed value (the sink's keys are `String`s, so the fresh keys are compared as strings),
`isequal` for anything else.
"""
_storedAgrees(stored::Real, fresh::Real; rtol) = isapprox(stored, fresh; rtol=rtol)
function _storedAgrees(stored::AbstractDict, fresh; rtol)
    (fresh isa AbstractDict || fresh isa NamedTuple) || return false
    fresh_by_string = Dict{String,Any}(string(k) => v for (k, v) in pairs(fresh))
    Set(keys(fresh_by_string)) == Set(keys(stored)) || return false
    return all(_storedAgrees(stored[k], fresh_by_string[k]; rtol=rtol) for k in keys(stored))
end
_storedAgrees(stored, fresh; rtol) = isequal(stored, fresh)

#! The STORABLE/ANALYSABLE shape, checked by the two consumers that need it and by nobody else: the
#! sink on `compute`'s value (each component becomes a column) and sensitivity analysis on
#! `reduce`'s (each component becomes an analysis needing one number per monad). It is deliberately
#! NOT applied at the `_reduceOverMonad` seam any more. Enforcing it there made it the contract for
#! consumers that do not need it -- calibration hands whatever `reduce` returned to the user's own
#! `distance`, which is the reader that decides what it can use -- and refused a struct-valued
#! `compute` before the `reduce` written to turn it into something storable had run.
"""
    _qoiValueShape(q, value, source) → keys or nothing

The keys `value` carries, or `nothing` when it is a single `Real`. Throws an `ArgumentError` naming
`q`, `source` and the offending type when `value` is not storable or analysable — a `Real`, or a
flat `Dict`/`NamedTuple` of them with at least one key. `Dict` keys come back sorted; a `NamedTuple`
keeps its declaration order, which the user chose.
"""
function _qoiValueShape(q::QoI, value, source::AbstractString)
    value isa Real && return nothing
    ks = if value isa NamedTuple
        collect(keys(value))
    elseif value isa AbstractDict
        sort(collect(keys(value)); by=string)
    else
        _throwQoIValue(q, value, source)
    end
    #! Refused for BOTH of this function's callers rather than in each of them, because the two
    #! disagreed about it: the sink stored nothing and said nothing while sensitivity analysis
    #! refused. A keyed value with no keys is not "no components" -- it is a measurement that named
    #! nothing, which neither a column nor an index can be made of. Calibration is the consumer
    #! that does not come through here, and there an empty keyed value contributes no entries.
    isempty(ks) && throw(ArgumentError(
        "QoI \"$(q.name)\": a keyed value with no keys names no quantity, so there is nothing to " *
        "store, label or compare. $(source) gave an empty $(typeof(value)). Return a `Real`, or a " *
        "`Dict`/`NamedTuple` with at least one key."))
    for k in ks
        v = value[k]
        v isa Real || throw(ArgumentError(
            "QoI \"$(q.name)\": every component of a keyed measurement must be a `Real`, since it " *
            "becomes a column, a label or a term in a distance. \"$(_qoiLabel(q.name, k))\" from " *
            "$(source) is a $(typeof(v))."))
    end
    return ks
end

#! A value that is `missing` is a supported answer from `_reduceOverMonad` -- every replicate said
#! `missing`, or `reduce` did -- and calibration handles it before it could get here (the particle is
#! rejected). Sensitivity analysis cannot: there is no defensible number for that cell of the design
#! matrix. Given its own method so the message says what happened rather than "gave a Missing", and
#! naming BOTH causes, because this code cannot tell which one it was and guessing sent users to look
#! at simulations that were perfectly healthy. `source` comes from the caller, as it does for every
#! other shape refusal, so the wrapper that used to hard-code "`reduce` on monad N" is gone.
_qoiValueShape(q::QoI, ::Missing, source::AbstractString) = throw(ArgumentError(
    "QoI \"$(q.name)\": $(source) has no value: every replicate's `compute` returned `missing`, " *
    "or its `reduce` did. There is nothing to store or label, and a sensitivity index needs a " *
    "value from every monad in the design. Check why that monad produced no value, or exclude " *
    "the quantity from this analysis."))

#! The message names WHOSE rule this is, because it is no longer everyone's: the sink and sensitivity
#! analysis need a number per column and a number per monad, and calibration needs neither. A user
#! who reads "a value must be a `Real`" without that qualification goes and rewrites a `compute` that
#! their `distance` would have taken unchanged. Both consumers are named rather than the one that
#! raised, because `_keyedEntries` serves both and cannot tell them apart; `source` says which
#! function produced the value, which is the half that actually locates the mistake.
#!
#! The `Vector` case is called out because it is the one a reader will reach for, and for the sink
#! and GSA the refusal is a "not yet", not a "never": a vector is perfectly reasonable to reason
#! about when you wrote it. Keys are what those two are built on first because they make the
#! alignment explicit -- a component has a name that can be a column or a label, and two monads can
#! be checked for the same components without anyone deciding what an index means. Supporting
#! vectors means settling how one is labelled at the sink and in GSA and matched across monads; none
#! of that is decided, and the message should not pretend the case is closed.
"""
    _throwQoIValue(q, value, source)

Raise the `ArgumentError` for a value the sink and sensitivity analysis cannot use, with advice
keyed to what was given.
"""
function _throwQoIValue(q::QoI, value, source::AbstractString)
    advice = if value isa AbstractArray
        "A `Vector` cannot be stored or analysed for now, because the keys make the alignment " *
        "explicit — a component has a name that can be a column or a label, and two " *
        "parameter sets can be checked for the same components without anyone having to decide " *
        "what an index means. Return a `Dict` whose keys name the components, or reduce to the " *
        "single number you want."
    elseif value isa AbstractString
        "A measurement is a number; to label a simulation with text, tag it instead."
    else
        "Return a `Real`, or a `Dict`/`NamedTuple` naming each component."
    end
    throw(ArgumentError(
        "QoI \"$(q.name)\": the post-processing sink and sensitivity analysis need a `Real`, or a " *
        "flat `Dict`/`NamedTuple` of `Real`s — each component becomes a column, or an analysis " *
        "needing one number per parameter set. $(source) gave a $(typeof(value)). " * advice *
        " Calibration asks for none of this: a `distance` receives whatever `reduce` returned."))
end

#! Printed with `repr` of the RAW keys, never `string.(...)`, because the comparison that produced
#! the message is by stringified key set: a `Dict("a" => …)` next to an `(a = …,)` differs only in
#! key TYPE, and a message that stringifies both sides asserts two identical lists are different.
#! Sorted by the string form only so the order is deterministic.
"""
    _qoiKeyListStr(ks) → String

How a set of raw keys reads in an error message: `repr` of each, so `:a` and `"a"` are visibly
different, sorted by their string form.
"""
_qoiKeyListStr(ks) = "[" * join(repr.(sort(collect(ks); by=string)), ", ") * "]"

#! Not `mean` itself, because `mean` cannot combine two `Dict`s: a keyed measurement -- the natural
#! shape for "counts per cell type" -- would otherwise need a hand-rolled reducer before it could be
#! used at all, and a bare keyed function died inside `Statistics.mean` naming no QoI.
#!
#! Requiring the replicates to agree about their keys is THIS reducer's rule and nobody else's. It
#! used to be enforced at the seam, before any `reduce` ran, which meant a reducer written to
#! reconcile ragged replicates -- filling an absent cell type with a zero -- never saw them.
#!
#! Averaged through a STRINGIFIED view of each replicate, so a `Dict("a" => …)` replicate sits
#! beside an `(a = …,)` one: they name the same quantity in two containers. Indexing `v[k]` with the
#! first replicate's own key -- `"a"` into a `NamedTuple`, `:a` into a `Dict` -- died instead. The
#! container kind and the key objects of the FIRST replicate are what come back out, so the reduced
#! value is shaped like the values that made it.
#!
#! The per-key `mean` is guarded because the components are NOT required to be `Real`: a
#! `Dict(key => Vector)` averaging elementwise is an ordinary time-series measurement, and the
#! failure to report well is the nested keyed value, which used to be refused at the seam with a
#! labelled message and would otherwise die here as a bare `MethodError` naming neither the QoI nor
#! the key.
"""
    _qoiMean(values) → value

The default `reduce`: `mean` for `Real`s, and the per-key mean for keyed values, returned in the
first replicate's kind of container and under its own keys. Every replicate must carry the same
keys, compared as strings so a `Dict` and a `NamedTuple` naming the same quantities agree — a rule
of this reducer, which a custom `reduce` is free not to share. Components need not be `Real`; they
need only be averageable, so a `Dict` of `Vector`s averages elementwise. Any `missing` among
`values` makes the result `missing`, matching `mean`.
"""
function _qoiMean(values)
    isempty(values) && throw(ArgumentError(
        "The default `reduce` was given no replicate values to average."))
    any(ismissing, values) && return missing
    v1 = first(values)
    v1 isa Real && return mean(values)
    (v1 isa NamedTuple || v1 isa AbstractDict) || throw(ArgumentError(
        "The default `reduce` averages a `Real` or a flat `Dict`/`NamedTuple` of them; got a " *
        "$(typeof(v1)). Pass `reduce=` a function that combines this measurement's replicates."))
    by_string = [Dict{String,Any}(string(k) => vv for (k, vv) in pairs(v)) for v in values]
    ks = collect(keys(v1))
    reference = Set(string.(ks))
    for (v, d) in zip(values, by_string)
        Set(keys(d)) == reference || throw(ArgumentError(
            "The default `reduce` averages per key, so every replicate must carry the same keys; " *
            "got $(_qoiKeyListStr(keys(v1))) and $(_qoiKeyListStr(keys(v))). That is this " *
            "reducer's rule, not the QoI contract's: pass `reduce=` a function of your own to " *
            "reconcile ragged replicates — emitting the full key set with a zero for the absent " *
            "component is the usual answer."))
    end
    means = [_qoiMeanOfKey(k, [d[string(k)] for d in by_string]) for k in ks]
    return v1 isa NamedTuple ? NamedTuple{Tuple(ks)}(Tuple(means)) : Dict(zip(ks, means))
end

"""
    _qoiMeanOfKey(k, components) → value

The mean of one key's components across replicates, raising an `ArgumentError` naming the key and
the component type when they cannot be averaged.
"""
function _qoiMeanOfKey(k, components)
    try
        return mean(components)
    catch
        throw(ArgumentError(
            "The default `reduce` averages each key across the replicates, and key $(repr(k)) " *
            "holds a $(typeof(first(components))), which `mean` cannot combine — a nested " *
            "`Dict`/`NamedTuple` is the usual way to get here. Flatten the measurement, or pass " *
            "`reduce=` a function that knows how to combine it."))
    end
end

#! `collect(skipmissing(...))` rather than a `filter`, so the element type NARROWS: a
#! `Vector{Union{Missing,Float64}}` with its missings dropped becomes a `Vector{Float64}`, which is
#! what a reducer written for numbers expects. `filter(!ismissing, v)` keeps the union in the element
#! type and pushes the `Missing` into every downstream signature.
"""
    _reduceOverMonad(q, monad_id) → value or missing

Apply `q` to every simulation of `monad_id` and combine the results with `q.reduce`.

`missing` two ways, and they are the same answer at two levels: when `q.skip_missing` and no
simulation produced a value, so `reduce` is never called; and when `reduce` itself returns
`missing`, which is how a reducer says the replicates it did get are not enough to answer with.

Nothing here interprets the values themselves: `nothing` is refused on both paths, and everything
else is handed on for the consumer to accept or refuse. The sink and sensitivity analysis apply
their own rule to the value they read; calibration applies none.
"""
function _reduceOverMonad(x, monad_id::Integer)
    q = _asQoI(x)
    sim_ids = constituentIDs(Monad, Int(monad_id))
    isempty(sim_ids) && throw(ArgumentError(
        "Monad $(monad_id) has no simulations, so QoI \"$(q.name)\" cannot be evaluated on it."))
    #! `simulationsFromIDs` rather than `Simulation.(sim_ids)` because it is the BATCHED constructor:
    #! one `SELECT ... WHERE simulation_id IN (...)` for the whole monad, where the broadcast form
    #! runs one query per ID -- the N+1 pattern that function's own docstring warns against. This
    #! path runs for every replicate of every particle of every generation, so the difference is a
    #! query count proportional to the run rather than to the generation. The trade is that it SKIPS
    #! an ID with no row instead of throwing, which is why the length check follows it.
    sims = simulationsFromIDs(sim_ids)
    length(sims) == length(sim_ids) || throw(ArgumentError(
        "Monad $(monad_id) lists $(length(sim_ids)) simulations but only $(length(sims)) are in the " *
        "database, so QoI \"$(q.name)\" cannot be evaluated on it."))
    values = [_computeOn(q, sim) for sim in sims]
    for (sim, v) in zip(sims, values)
        isnothing(v) && throw(ArgumentError(
            "QoI \"$(q.name)\": `compute` returned `nothing` for simulation $(sim.id). Return " *
            "`missing` to say this simulation produced no value — `nothing` is what a function " *
            "returns by accident, so it is not accepted as one."))
    end
    kept = q.skip_missing ? collect(skipmissing(values)) : values
    isempty(kept) && return missing
    #! `reduce`'s value is returned unexamined. Checking it here made one rule out of three
    #! consumers' needs: the sink never sees it at all, sensitivity analysis has its own check in
    #! `evaluateFunctionOnSampling` (each key must become an index), and calibration hands it to the
    #! user's `distance`, which is the only reader that knows what it can use. The rule also refused
    #! a `compute` whose value was never meant to leave `reduce` -- a struct read from output, turned
    #! into a keyed series by the reducer -- because a shape check on the way IN has to interpret the
    #! input too.
    return _callReduce(q, kept)
end


#! The separator between a quantity and its components lives in ONE place, because four sites have to
#! agree on it: the `QoI` constructor refuses it inside a name, the sink writes it into a column name,
#! sensitivity analysis writes it into a label, and `_isQoILabelOf` reads it back out. Spelling it in
#! four string literals is how they drift apart.
const _QOI_LABEL_SEPARATOR = "."

"""
    _qoiLabel(name, key) → String

The name one component of a keyed measurement is stored under: `"<name>.<key>"`. The sink uses it for
a column, sensitivity analysis for a label.
"""
_qoiLabel(name::AbstractString, key) = string(name, _QOI_LABEL_SEPARATOR, key)

"""
    _isQoILabelOf(label, name) → Bool

Whether `label` is one that a QoI called `name` produces — its name, or its name and a key.
"""
_isQoILabelOf(label::AbstractString, name::AbstractString) =
    label == name || startswith(label, name * _QOI_LABEL_SEPARATOR)

#! ONE key space for every consumer, and the pair is what makes it one: a component belongs to the
#! QoI that produced it, so `count` and `speed` may both be keyed by cell type, and two QoIs may even
#! share a name as long as their component keys are disjoint. The alternative -- calibration keying
#! `distance`'s argument by the user's bare component names -- made a QoI used for calibration
#! narrower than the same QoI used for the sink or GSA, and forbade exactly the pairing above.
#!
#! `String` rather than the raw key object on both halves. The component key is `string(k)` of
#! whatever `compute`/`reduce` produced, because that is the only form a sink column, a GSA label and
#! a hand-written `observed_data` can all spell; `nothing` in that slot is the `Real`-valued case,
#! distinguishing "no components" from "a component that happens to be named `\"\"`".
const _SummaryKey = Tuple{String,Union{Nothing,String}}

#! `Any` rather than `Float64`, and that one word is what makes calibration free of the value rule
#! the other two consumers need. A `Float64` element type forced every `reduce` to produce numbers
#! before `distance` -- the reader that decides -- had seen anything, so a time series could not be
#! calibrated against a time series even though `mseDistance` compares two of them perfectly well.
"""
    SummaryValues

The value a [`CalibrationProblem`](@ref)'s `summary_statistic` has for one parameter set: what
`distance` receives as its first argument.

An `AbstractDict` keyed by `(qoi name, component key)` pairs — the same pair the post-processing
sink turns into a column and sensitivity analysis into a label — where the component key is
`nothing` for a `Real`-valued [`QoI`](@ref). Iteration is in insertion order (QoIs in the order you
listed them, components in the order `compute`/`reduce` produced them), so messages and any
`collect` are deterministic.

**The values are whatever `reduce` returned**, not numbers: a `Real` sits under `(name, nothing)`, a
keyed value contributes one entry per key, and anything else — a `Vector`, a `Matrix`, your own
struct — is held whole under `(name, nothing)`. Calibration is the one consumer that constrains
nothing, because your `distance` is the only reader and it knows what it can use. An empty keyed
value contributes no entries at all.

# Three spellings, resolved in this order
Indexing accepts a `String` (or a `Symbol`, which is stringified) and tries, in order:

1. **`"name"`** — a `Real`-valued QoI called `name`;
2. **`"name.key"`** — split at the *first* `.`, since a QoI name cannot contain one. This is the
   spelling the sink and sensitivity analysis use, so an `observed_data` written from a sink column
   needs no translation;
3. **`"key"`** — a bare component key, matched against every QoI's components. It resolves only
   when exactly one QoI produced that key; **several is an `ArgumentError`** listing the qualified
   labels to choose between, and none is an `ArgumentError` listing the labels that exist.

A `Tuple` key — `("counts", "tumor")`, or `("tumor", nothing)` for a `Real`-valued QoI — is looked
up exactly, with no resolution. `haskey` mirrors `getindex`: it is `true` only when the lookup
resolves to exactly one entry, so an ambiguous bare key is `false` rather than throwing.

# Example
```julia
# A summary of QoI("counts", …) → Dict("tumor" => …) and QoI("speed", …) → Dict("tumor" => …)
s["counts.tumor"]           # qualified — always unambiguous
s[("counts", "tumor")]      # the same entry, exactly
s["tumor"]                  # ArgumentError: "counts.tumor" or "speed.tumor"?
```
"""
struct SummaryValues <: AbstractDict{_SummaryKey,Any}
    values::Dict{_SummaryKey,Any}
    #! Insertion order is kept alongside the `Dict` rather than by reaching for an ordered-dictionary
    #! package: ModelManager has no OrderedCollections dependency and a deterministic iteration order
    #! is not worth acquiring one. The vector is written only by `_insertSummary!`, which refuses a
    #! repeat, so the two halves cannot drift.
    order::Vector{_SummaryKey}
end

SummaryValues() = SummaryValues(Dict{_SummaryKey,Any}(), _SummaryKey[])

"""
    _insertSummary!(s::SummaryValues, key, value)

Append one entry, keeping insertion order. The caller has already refused a repeated key, so this
asserts rather than reporting.
"""
function _insertSummary!(s::SummaryValues, key::_SummaryKey, value)
    @assert !haskey(s.values, key) "duplicate summary key $(key) reached _insertSummary!"
    push!(s.order, key)
    s.values[key] = value
    return s
end

Base.length(s::SummaryValues) = length(s.order)
Base.keys(s::SummaryValues) = s.order
Base.values(s::SummaryValues) = [s.values[k] for k in s.order]

function Base.iterate(s::SummaryValues, i::Int=1)
    i > length(s.order) && return nothing
    k = s.order[i]
    return (k => s.values[k], i + 1)
end

"""
    summaryLabel(key) → String

The one name a `(qoi name, component key)` pair goes by outside a [`SummaryValues`](@ref): the QoI's
name alone for a `Real`-valued QoI, and `"<name>.<key>"` otherwise. It is the post-processing sink's
column name and the sensitivity-analysis label, which is why it has a single definition.
"""
summaryLabel(key::_SummaryKey) =
    isnothing(key[2]) ? key[1] : _qoiLabel(key[1], key[2])

"""
    _resolveSummaryKey(s, k) → Vector{_SummaryKey}

The entries of `s` that the spelling `k` names: empty when nothing matches, one when it resolves,
several when a bare component key belongs to more than one QoI. The resolution order is the one
[`SummaryValues`](@ref) documents.
"""
function _resolveSummaryKey(s::SummaryValues, k::AbstractString)
    scalar = (String(k), nothing)
    haskey(s.values, scalar) && return [scalar]
    #! The FIRST separator, not the last and not a split into every part: a QoI name cannot contain
    #! a `.` (the constructor refuses it), but a component key can, so `"counts.a.b"` is
    #! unambiguously the QoI `counts` and the key `a.b`.
    i = findfirst(==(only(_QOI_LABEL_SEPARATOR)), k)
    if !isnothing(i)
        qualified = (String(SubString(k, 1, prevind(k, i))), String(SubString(k, nextind(k, i))))
        haskey(s.values, qualified) && return [qualified]
    end
    return [key for key in s.order if key[2] == k]
end

"""
    _summaryKeyFor(s, k) → _SummaryKey

Resolve one spelling to the single entry it names, throwing when it names none or several.
"""
function _summaryKeyFor(s::SummaryValues, k::AbstractString)
    matches = _resolveSummaryKey(s, k)
    length(matches) == 1 && return only(matches)
    #! The advice is dropped when there is nothing to advise: "It reports nothing — name one of
    #! those" is worse than saying only the fact. An empty summary means every QoI reduced to a
    #! keyed value with no keys, which is a different problem from a misspelled name.
    isempty(matches) && throw(ArgumentError(
        "The summary statistic has no value named \"$(k)\". It reports " *
        "$(_summaryLabelListStr(s))" *
        (isempty(s.order) ? "." :
         " — name one of those, either qualified (\"<qoi>.<key>\") or by its bare key when only " *
         "one QoI reports it.")))
    throw(ArgumentError(
        "\"$(k)\" is a component key of more than one QoI, so it does not name a single value: " *
        "$(join(repr.(summaryLabel.(matches)), ", ")). Two QoIs keyed the same way — a `count` and " *
        "a `speed` per cell type — are allowed and are told apart by the QoI's name, so use the " *
        "qualified spelling."))
end

_summaryKeyFor(s::SummaryValues, k::Symbol) = _summaryKeyFor(s, string(k))

#! A `Tuple` is the escape hatch from resolution: it names the entry outright, which is what a user
#! reaches for when two QoIs share a name AND a key would be ambiguous under any string spelling.
function _summaryKeyFor(s::SummaryValues, k::Tuple{Any,Any})
    key = (string(k[1]), isnothing(k[2]) ? nothing : string(k[2]))
    haskey(s.values, key) && return key
    throw(ArgumentError(
        "The summary statistic has no value keyed $(repr(key)). It reports " *
        "$(_summaryLabelListStr(s))."))
end

#! "nothing" rather than the empty string, because every caller embeds this mid-sentence: an empty
#! summary otherwise reads "It reports ." and looks like a truncated message rather than the fact
#! that the measurement named no components. A summary CAN be empty now -- a `reduce` returning an
#! empty keyed value contributes no entries, which calibration allows where the sink and GSA refuse
#! it -- so this is reachable rather than defensive.
"""
    _summaryLabelListStr(s) → String

How a summary's labels read in an error message, in insertion order; `"nothing"` when it has none.
"""
_summaryLabelListStr(s::SummaryValues) =
    isempty(s.order) ? "nothing" : join(repr.(summaryLabel.(s.order)), ", ")

Base.getindex(s::SummaryValues, k::AbstractString) = s.values[_summaryKeyFor(s, k)]
Base.getindex(s::SummaryValues, k::Symbol) = s.values[_summaryKeyFor(s, k)]
Base.getindex(s::SummaryValues, k::Tuple{Any,Any}) = s.values[_summaryKeyFor(s, k)]

Base.haskey(s::SummaryValues, k::AbstractString) = length(_resolveSummaryKey(s, k)) == 1
Base.haskey(s::SummaryValues, k::Symbol) = haskey(s, string(k))
Base.haskey(s::SummaryValues, k::Tuple{Any,Any}) =
    haskey(s.values, (string(k[1]), isnothing(k[2]) ? nothing : string(k[2])))

Base.get(s::SummaryValues, k, default) = haskey(s, k) ? s[k] : default

#! Printed by LABEL rather than by the raw tuple keys, because the label is what a user writes in
#! `observed_data` and reads off a sink column; `("counts", "tumor")` is the internal spelling and
#! shows up only when they ask for it.
#!
#! Each value is rendered under `:limit` and `:compact`, so a 10,000-point series prints as
#! `[0.0, 1.0, …]` rather than in full. A summary reaches `show` mostly from inside an error message
#! -- `_evaluateParticle` prints one per failing particle -- and now that a value may be an array of
#! any size, printing it whole would bury the message that matters in the log.
function Base.show(io::IO, s::SummaryValues)
    print(io, "SummaryValues(")
    bounded = IOContext(io, :compact => true, :limit => true)
    join(io, ["$(repr(summaryLabel(k))) => $(sprint(show, s.values[k]; context=bounded))"
              for k in s.order], ", ")
    print(io, ")")
end

Base.show(io::IO, ::MIME"text/plain", s::SummaryValues) = show(io, s)

#! How a value is NAMED has one definition; what a value may BE is each consumer's own business.
#! The naming half lives here, in `_qoiComponentLabels`, and both spreaders go through it: the sink
#! and GSA built `"<name>.<key>"` twice and calibration flattened under a third rule entirely, so
#! "what is this component called" had three answers that only agreed by inspection.
"""
    _qoiComponentLabels(q, component_keys, source) → Vector{String}

The label each key of a keyed value carries: `string(k)`, in the order given. Two keys that
stringify alike are refused here, where the raw keys are still in hand.
"""
function _qoiComponentLabels(q::QoI, component_keys, source::AbstractString)
    labels = [string(k) for k in component_keys]
    #! Refused where the RAW keys are still in hand, because afterwards only the strings survive and
    #! the message could not say which two keys collided. Every consumer needs this: the sink would
    #! get two identical column names, GSA two identical labels, and calibration two entries with one
    #! `_SummaryKey`.
    if !allunique(labels)
        dups = unique(l for l in labels if count(==(l), labels) > 1)
        culprits = [k for (k, l) in zip(component_keys, labels) if l in dups]
        throw(ArgumentError(
            "QoI \"$(q.name)\": keys $(join(repr.(culprits), ", ")) from $(source) all produce " *
            "the label $(join(repr.(_qoiLabel.(q.name, dups)), ", ")). Distinct keys that collide " *
            "once written as strings are not allowed — that label is a sink column, a sensitivity " *
            "analysis and a term in a distance, so one would silently replace the other. `1` and " *
            "\"1\" are one way to get here."))
    end
    return labels
end

#! The STRICT spreader: it produces `Float64`s and so goes through `_qoiValueShape` first. Used by
#! the sink, whose components become columns, and by GSA, whose
#! `Dict{Int,Vector{Pair{_SummaryKey,Float64}}}` depends on the element type being a number.
"""
    _keyedEntries(q, value[, source]) → Vector{Pair{_SummaryKey,Float64}}

Spread one QoI's value into its named components, for the two consumers that need numbers: a `Real`
gives the single entry `(q.name, nothing)`, and a keyed value one entry per key,
`(q.name, string(k))`, in the order `_qoiValueShape` reports. Anything else is refused.
"""
function _keyedEntries(q::QoI, value, source::AbstractString="the QoI's value")
    component_keys = _qoiValueShape(q, value, source)
    isnothing(component_keys) && return [(q.name, nothing) => Float64(value)]
    labels = _qoiComponentLabels(q, component_keys, source)
    return [(q.name, l) => Float64(value[k]) for (k, l) in zip(component_keys, labels)]
end

#! The PERMISSIVE spreader, for calibration: same naming, no rule about what a value may be. A value
#! that is neither a `Real` nor keyed is one quantity under `(name, nothing)` -- the same slot a
#! `Real` gets, because it is the same fact about it: the measurement named no components.
#!
#! An empty keyed value contributes ZERO entries rather than landing whole under `(name, nothing)`.
#! It follows from the per-key rule, and the alternative is worse than it looks: routing an empty
#! `Dict` to the scalar slot would make the key space of the summary depend on the VALUE, so an
#! `observed_data` written against a full run would stop resolving on a run where one measurement
#! came back empty. The sink and GSA still refuse an empty keyed value outright.
"""
    _summaryEntries(q, value, source) → Vector{Pair{_SummaryKey,Any}}

Spread one QoI's value for calibration, imposing no rule on what it may be: a `Real` or any
unkeyed value gives the single entry `(q.name, nothing)`, and a `Dict`/`NamedTuple` one entry per
key — `NamedTuple`s in declaration order, `Dict`s sorted by `string(k)`. An empty keyed value gives
no entries.
"""
function _summaryEntries(q::QoI, value, source::AbstractString)
    component_keys = if value isa NamedTuple
        collect(keys(value))
    elseif value isa AbstractDict
        sort(collect(keys(value)); by=string)
    else
        nothing
    end
    isnothing(component_keys) && return Pair{_SummaryKey,Any}[(q.name, nothing) => value]
    labels = _qoiComponentLabels(q, component_keys, source)
    return Pair{_SummaryKey,Any}[(q.name, l) => value[k]
                                 for (k, l) in zip(component_keys, labels)]
end

#! One contract, and one internal representation. A user may hand any consumer a bare `Function`; it
#! is wrapped into a `QoI` here, at the boundary, so nothing downstream branches on which it was
#! given. The wrapper supplies the two things a bare function lacks: a name, and the default reducer.
#!
#! Before this, a bare `Function` meant three different things -- a simulation *ID* in `functions=`, a
#! *monad* ID in `CalibrationProblem`, and a `SimulationProcess` at the sink. Two were an `Int`, and
#! both ID spaces are dense positive integers, so handing a calibration summary to `functions=`
#! measured the wrong entity and returned a plausible number with no error anywhere.
"""
    _asQoI(x) → QoI

Wrap `x` as a [`QoI`](@ref) if it is not one already. A bare `Function` becomes `QoI(name, f)`, with
`name` derived from the function; a `QoI` passes through untouched.
"""
_asQoI(q::QoI) = q
_asQoI(f::Function) = QoI(_qoiNameFromFunction(f), f)
_asQoI(x) = throw(ArgumentError("Expected a QoI or a Function; got $(typeof(x))."))

#! A closure or lambda has no name another session -- or another call of the same factory -- would
#! agree on: `make("tumor")` and `make("immune")` both answer `nameof` with `:f`. So for those the
#! name comes from the type, which carries the enclosing scope (`#f#make##0`) or a counter
#! (`#3#4`), regularised into an identifier: `anon_f_make_0`, `anon_3_4`. Everything derived this way
#! starts with `anon`, which the sink refuses to store under and sensitivity analysis never uses to
#! skip work (`_isAutoNamedAnonymous`), because it identifies nothing.
"""
    _qoiNameFromFunction(f) → String

A name for a bare function, usable as a database column and a `Dict` key. A top-level named function
keeps its own name, in any alphabet; a lambda or closure gets a regularised `anon_…` form.
"""
function _qoiNameFromFunction(f::Function)
    raw = _isAnonymousFunction(f) ? string(nameof(typeof(f))) : string(nameof(f))
    occursin(r"^[\p{L}_][\p{L}\p{N}_]*$", raw) && return raw
    return "anon" * replace(raw, r"[^\p{L}\p{N}_]+" => "_")
end

"""
    _isAutoNamedAnonymous(q::QoI) → Bool

Whether `q` wraps a closure or lambda under the name ModelManager derived for it rather than one the
user chose. Such a name identifies nothing -- two closures from one factory share it -- so the sink
refuses to store under it and sensitivity analysis never treats it as already evaluated.
"""
_isAutoNamedAnonymous(q::QoI) = _isAnonymousFunction(q.compute) && q.name == _qoiNameFromFunction(q.compute)

#! No name-uniqueness check, deliberately. Two keyed QoIs sharing a name is not pathological -- a
#! `counts` measured two ways, keyed by disjoint cell types -- and the name is only half of what
#! identifies a component. What must be unique is the `_SummaryKey`, which `_evaluateSummary`
#! checks with both values in hand; a name check here would refuse the harmless case and still not
#! be the guarantee. Two `Real`-valued QoIs with one name ARE a collision, and that is exactly what
#! the `_SummaryKey` check catches, since their key is `(name, nothing)` both times.
"""
    _validateSummaryStatistic(x) → QoI | Vector{QoI}

Check that `x` can serve as a [`CalibrationProblem`](@ref)'s `summary_statistic` and return it as a
`QoI` or a vector of them. Only the shape is checked here; a collision between two members'
components is reported at the first evaluation, where the components exist.
"""
_validateSummaryStatistic(q::QoI) = q

function _validateSummaryStatistic(qs::AbstractVector{QoI})
    isempty(qs) && throw(ArgumentError("A summary statistic needs at least one QoI."))
    return collect(qs)
end

_validateSummaryStatistic(f::Function) = _asQoI(f)

_validateSummaryStatistic(x) = throw(ArgumentError(
    "A summary statistic must be a QoI or a vector of QoIs; got $(typeof(x))."))

#! ALWAYS a `SummaryValues`, for one QoI as much as for a vector and for a `Real`-valued QoI as much
#! as a keyed one. The single-QoI passthrough that used to exist -- a `Real` handed over bare -- made
#! `q` and `[q]` two different contracts for one measurement, and it is not needed to keep a scalar
#! `observed_data` working: `mseDistance(::SummaryValues, ::Real)` does that, by requiring the
#! summary to have exactly one entry, which is the condition a scalar observation actually implies.
#!
#! Returned WITH the name of the member that had no value: that name is the one thing a caller cannot
#! recover afterwards -- `missing` says only that something was absent -- and `on_monad_failure=:error`
#! has to name it. `_evaluateParticle` is the only caller and wants both, so this is one function
#! rather than a value-only wrapper that nothing in `src/` would call.
"""
    _evaluateSummary(ss, monad_id) → (SummaryValues or missing, source)

Evaluate a [`CalibrationProblem`](@ref)'s `summary_statistic` on one monad, as `distance` will see
it: a [`SummaryValues`](@ref) over every member's components, keyed by `(qoi name, component key)`,
paired with `nothing`. Values are whatever each member's `reduce` returned — nothing here requires
them to be numbers. When some member has no value for this monad the first element is `missing` and
the second is that member's name.
"""
_evaluateSummary(q::QoI, monad_id::Integer) = _evaluateSummary([q], monad_id)

function _evaluateSummary(qs::AbstractVector{QoI}, monad_id::Integer)
    out = SummaryValues()
    owners = Dict{_SummaryKey,Tuple{Int,String}}()
    for (i, q) in enumerate(qs)
        v = _reduceOverMonad(q, monad_id)
        #! One member with no value makes the whole summary missing, so the particle is handled by
        #! `on_monad_failure` rather than compared on a partial key set.
        ismissing(v) && return (missing, q.name)
        #! `_summaryEntries`, not `_keyedEntries`: calibration's spreader names components the same
        #! way but imposes no rule on what they hold, so a `reduce` returning a series per cell type
        #! arrives at `distance` intact.
        for (key, value) in _summaryEntries(q, v, "`reduce` on monad $(monad_id)")
            haskey(owners, key) && _throwSummaryKeyCollision(owners[key], (i, q.name), key)
            owners[key] = (i, q.name)
            _insertSummary!(out, key, value)
        end
    end
    return (out, nothing)
end

#! Reachable only when two members share a NAME, since the QoI's name is half of every key: either
#! two `Real`-valued QoIs called the same thing, or two keyed ones called the same thing that also
#! report a key in common. Both are legitimate mistakes and neither is caught at construction --
#! keyed QoIs sharing a name with disjoint keys is supported, so the name alone proves nothing.
#! Positions are named as well as the name, because the name is by construction the same on both
#! sides and would otherwise read as a message pointing at one QoI twice.
"""
    _throwSummaryKeyCollision(owner, claimant, key)

Raise the error for two summary members that produce one `(qoi name, component key)` pair.
"""
function _throwSummaryKeyCollision(owner::Tuple{Int,String}, claimant::Tuple{Int,String},
                                   key::_SummaryKey)
    what = isnothing(key[2]) ?
        "are both `Real`-valued QoIs named \"$(key[1])\", whose only identifier is that name" :
        "are both named \"$(key[1])\" and both report the key \"$(key[2])\""
    throw(ArgumentError(
        "The summary statistic produces \"$(summaryLabel(key))\" twice: QoIs $(owner[1]) and " *
        "$(claimant[1]) $(what). Every value `distance` receives is named by its QoI and its key " *
        "together, so one would silently replace the other. Rename one of the QoIs. (Two QoIs with " *
        "one name are fine when their keys are disjoint — it is the pair that must be unique.)"))
end

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
#! Split into a validator and a plain function rather than a validator that RETURNS one. The closure
#! form put the per-simulation body somewhere no caller could name: `run` held an opaque `Function`,
#! so its keyword could not be typed, `processSimulationTask` could not say what it took, and the
#! only way to test the body was to build the closure first. Converting once in `run` and calling
#! `_postProcess(pp, sim)` per simulation keeps the same two jobs and gives both of them a name.
"""
    _PostProcessor

A validated `post_processor`: its [`QoI`](@ref)s, and for each whether its name was auto-derived from
an anonymous `compute`. That fact is decided once, here, because nothing about it changes per
simulation; whether it *matters* is decided per value, because an anonymous callback that only has
side effects and returns `missing` names nothing and is legitimate.
"""
struct _PostProcessor
    qs::Vector{QoI}
    auto_named::Vector{Bool}
end

"""
    _validatePostProcessor(x) → _PostProcessor

Validate `run`'s `post_processor`: a bare function is wrapped into a [`QoI`](@ref), a `QoI` into a
vector, a vector passes through; an empty vector is refused. Names are not required to be unique — a
collision surfaces as two identical sink columns, which the sink itself refuses.
"""
_validatePostProcessor(x) = _validatePostProcessor([_asQoI(x)])

function _validatePostProcessor(qs::AbstractVector)
    isempty(qs) && throw(ArgumentError("A post-processor needs at least one QoI."))
    qois = QoI[_asQoI(q) for q in qs]
    #! Only a name that was AUTO-DERIVED counts: `QoI("counts", sim -> …)` has an anonymous `compute`
    #! but a perfectly good name, and must not be refused.
    auto_named = [_isAutoNamedAnonymous(q) for q in qois]
    return _PostProcessor(qois, auto_named)
end

"""
    _postProcess(pp, sim) → Vector{Pair{String,Float64}} or nothing

Run every QoI of a validated `post_processor` on one simulation and return the labelled values the
sink should store, or `nothing` when there are none. Each label is `summaryLabel` of the same
`(qoi name, component key)` pair calibration and sensitivity analysis use.

Per value: `nothing` is refused, `missing` stores nothing for that simulation, and a value from a
QoI whose name was auto-derived from an anonymous `compute` is refused.
"""
function _postProcess(pp::_PostProcessor, sim::Simulation)
    #! Ordered pairs, not a `Dict`: round-tripping through one scrambled a `NamedTuple`'s field
    #! order, so the sink added its columns in hash order. Two QoIs that produce one column name
    #! still reach the sink as two separate entries, so its `allunique` check sees and rejects them.
    entries = Pair{String,Float64}[]
    for (q, auto_named) in zip(pp.qs, pp.auto_named)
        v = _computeOn(q, sim)
        #! Refused rather than treated as "store nothing", because `nothing` is what a callback
        #! returns by accident -- a trailing `if` with no `else`, a `for` loop, a `push!`. A
        #! post-processor whose only job is a side effect says so with `missing`.
        isnothing(v) && throw(ArgumentError(
            "post_processor: QoI \"$(q.name)\" returned `nothing` for simulation $(sim.id). " *
            "Return `missing` to store nothing for this simulation — including from a " *
            "callback whose only job is a side effect."))
        #! `missing` records nothing for this simulation -- how a post-processor skips one whose
        #! output it could not read.
        ismissing(v) && continue
        source = "`compute` on simulation $(sim.id)"
        component_keys = _qoiValueShape(q, v, source)
        #! A gensym must never become a persistent database column, and since EVERY column a QoI
        #! writes is named after it, that applies to a spread return as much as a scalar one: the
        #! regularised `anon_9` varies between sessions, so the same script would write a second,
        #! half-empty set of columns next time. Whether the name is auto-derived was decided once,
        #! at validation; only whether a VALUE is about to be stored under it is decided here,
        #! because an anonymous callback that only has side effects and returns `missing` names
        #! nothing and is legitimate.
        auto_named && throw(ArgumentError(
            "post_processor: an anonymous function has no stable name, and every sink column is " *
            "named after the QoI that wrote it — this $(typeof(v)) would be stored as " *
            (isnothing(component_keys) ? "\"<name>\"" : "\"<name>.<key>\" per key") *
            ". The derived name varies between sessions, so the same script would write a " *
            "second, half-empty set of columns next time. Name it — " *
            "`QoI(\"my_quantity\", f)` — or pass a named function."))
        for (key, value) in _keyedEntries(q, v, source)
            push!(entries, summaryLabel(key) => value)
        end
    end
    isempty(entries) && return nothing
    return entries
end
