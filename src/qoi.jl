export QoI, verifyStoredValues

"""
    QoI(name, compute; reduce=<per-key mean>, stored=:never, skip_missing=true)

A named quantity of interest: measure something per simulation, then combine the replicates.

Three parts of ModelManager need a number out of a group of simulations — sensitivity analysis,
calibration, and the post-processing sink — and each used to ask in its own shape. A `QoI` is that
measurement written once and passed to any of them.

# The contract
**A QoI value is a `Real`, or a flat `Dict`/`NamedTuple` whose values are all `Real`.** That is what
`compute` returns for one simulation and what `reduce` returns for one parameter set, and it is the
same rule in every consumer — no `Vector`, no nested keyed value, no struct, and no `String` (text
about a simulation is a tag, not a measurement; see [`tag!`](@ref)). A value that breaks the rule is
refused with the QoI's name and the offending type.

Three consequences worth stating outright:

- **`reduce` keeps the shape it is given.** A `Real` per simulation reduces to a `Real`; a keyed
  value reduces to the same keys. So a sink column and a sensitivity label named `"counts.tumor"`
  are the same quantity at two granularities, rather than two things sharing a name.
- **`compute` returns `missing` to say "no value for this simulation"** — output it could not read,
  a measurement that does not apply. Missing replicates are dropped before `reduce`, and a
  parameter set with none left is itself `missing`. `nothing` is refused, because it is too easily
  the accidental value of a `if`/`for` block that fell through.
- **Keys belong to whoever wrote them.** Sink columns and sensitivity labels are namespaced
  `"<qoi name>.<key>"`, since those are flat namespaces shared by every QoI in a project.
  Calibration is not: `distance` sees the keys `compute`/`reduce` produced, unprefixed, because
  calibration is the one consumer where you also supply the matching half (`observed_data`).

# Arguments
- `name`: identifies the quantity. It is the sink's column name and the sensitivity label. It may
  not contain a `.`, which is reserved as the separator between a quantity and its components.
- `compute`: called with one [`Simulation`](@ref); returns that simulation's QoI value, or
  `missing`.

# Keywords
- `reduce`: collapses one parameter set's *replicates*. It receives the vector of everything
  `compute` returned for that set — one entry per replicate — and returns that set's value. It is
  not `Base.reduce`. The default is a per-key mean: `mean` for `Real`s, and for keyed values the
  mean of each key, in the same kind of container, requiring every replicate to carry the same keys.
- `stored`: `:never` (default), `:prefer`, or `:require` — see below.
- `skip_missing`: `true` (default) drops `missing` replicates before calling `reduce`, and yields
  `missing` for the parameter set when none remain. `false` hands `reduce` the raw vector,
  `missing`s included, for a reducer that wants to see how many replicates had no value.

# A keyed value is several quantities, not one
Both flat namespaces spread a keyed value the same way, `"<qoi name>.<key>"`, so one measurement
names its parts identically wherever it is used:

- **Sensitivity analysis** runs one analysis per key — so `QoI("counts", …)` reducing to
  `Dict("tumor" => …, "immune" => …)` gives `counts.tumor` and `counts.immune`. Every monad must
  reduce to the *same* keys; one that does not is refused, because a sensitivity index computed over
  a missing value is wrong rather than approximate.
- **The sink** names its columns the same way. Because those names are persisted, an *anonymous*
  `compute` is refused outright — its derived `anon_9` would prefix every column and vary between
  sessions. Name the QoI, or pass a named function.

**Calibration flattens instead.** A single QoI hands `distance` its value unwrapped, and a
`Vector{QoI}` hands over one `Dict{String,Float64}` merging every member's keys — a `Real`-valued
QoI under its own name, a keyed one under its keys as written. Two QoIs claiming one key is refused,
naming both. So the rule there is one sentence: the keys `distance` sees are the keys your
`compute`/`reduce` produced.

# `reduce` is the monad-level step, not merely an average
It matters whenever the quantity involves a nonlinearity applied *after* the replicates are
combined — a discrepancy-to-data score is the common case, since averaging squared errors is not the
same number as squaring the averaged error. A per-simulation `compute` cannot do it; `reduce` can,
because it receives every replicate. Put the score in the returned keys alongside the raw
quantities and one QoI serves all three consumers at once; the calibration manual works the pattern
through end to end.

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

# One QoI, three consumers
run(MOAT(), spec; functions=[tumor])
CalibrationProblem(spec, observed, tumor, mseDistance)
run(trial; post_processor=tumor)

# Several quantities from one measurement. The default `reduce` already averages per key, so a
# keyed measurement needs no reducer of its own: GSA labels these `counts.tumor` / `counts.immune`,
# the sink writes those columns, and `distance` sees `"tumor"` / `"immune"`.
counts = QoI("counts", finalPopulationCount)
```
"""
struct QoI
    name::String
    compute::Function
    reduce::Function
    stored::Symbol
    skip_missing::Bool
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
             reduce::Function=_qoiMean, stored::Symbol=:never, skip_missing::Bool=true)
    stored in _QOI_STORED_MODES || throw(ArgumentError(
        "QoI `stored` must be one of $(_QOI_STORED_MODES); got :$(stored)."))
    occursin(_QOI_LABEL_SEPARATOR, name) && throw(ArgumentError(
        "QoI names cannot contain a `.`; got \"$(name)\". The dot separates a quantity from its " *
        "components — a `Dict`-valued measurement is labelled \"$(name)\" plus `.` plus each key — " *
        "so a name carrying one would be indistinguishable from another QoI's component. Use `_`."))
    return QoI(String(name), compute, reduce, stored, skip_missing)
end

qoiName(q::QoI) = q.name

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

#! The one place the QoI value contract is decided, so every consumer refuses the same things for the
#! same reason. `compute`'s value is checked here on its way into `reduce` and on its way into the
#! sink; `reduce`'s value is checked on its way out. Sensitivity analysis keeps a second, narrower
#! check per component (`_qoiComponentValue`), because a sensitivity index has no room for a value
#! this one would let through by mistake.
"""
    _qoiValueShape(q, value, source) → keys or nothing

The keys `value` carries, or `nothing` when it is a single `Real`. Throws an `ArgumentError` naming
`q`, `source` and the offending type when `value` is not a QoI value — a `Real`, or a flat
`Dict`/`NamedTuple` of them. `Dict` keys come back sorted; a `NamedTuple` keeps its declaration
order, which the user chose.
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
    for k in ks
        v = value[k]
        v isa Real || throw(ArgumentError(
            "QoI \"$(q.name)\": every component of a keyed measurement must be a `Real`, since it " *
            "becomes a column, a label or a term in a distance. \"$(_qoiLabel(q.name, k))\" from " *
            "$(source) is a $(typeof(v))."))
    end
    return ks
end

#! The `Vector` case is called out because it is the one a reader will reach for, and because the
#! obvious accommodation -- spreading by index into `q_1`, `q_2` -- is not safe. Two monads' vectors
#! can only be checked for equal LENGTH, and equal length is not alignment: series sampled at
#! different times, or one run that stopped early, produce same-length vectors whose entries mean
#! different things, and the indices would come out confident and wrong. A `Dict` cannot: its keys
#! are the alignment, supplied by the person who knows what they mean.
"""
    _throwQoIValue(q, value, source)

Raise the `ArgumentError` for a value that is not a QoI value, with advice keyed to what was given.
"""
function _throwQoIValue(q::QoI, value, source::AbstractString)
    advice = if value isa AbstractArray
        "A `Vector` is not spread by index: only its length can be checked against the other " *
        "monads', and equal length is not equal meaning — two series sampled at different times " *
        "have the same length and different contents. Return a `Dict` whose keys name the " *
        "components, or reduce to the single number you want."
    elseif value isa AbstractString
        "A measurement is a number; to label a simulation with text, tag it instead."
    else
        "Return a `Real`, or a `Dict`/`NamedTuple` naming each component."
    end
    throw(ArgumentError(
        "QoI \"$(q.name)\": a value must be a `Real`, or a flat `Dict`/`NamedTuple` of `Real`s. " *
        "$(source) gave a $(typeof(value)). " * advice))
end

#! Compared as SETS rather than as the ordered vectors used for labels, so a reducer is free to hand
#! its keys back in whatever order it likes, and STRINGIFIED, so `Dict("a" => …)` reduced to
#! `(a = …,)` counts as the same key set -- the contract is about which quantities come out, not
#! which container carries them. Sensitivity analysis compares its per-monad keys unstringified for a
#! different reason: there a `Dict` on one monad and a `NamedTuple` on another means one reducer is
#! doing two things.
"""
    _qoiShapesAgree(a, b) → Bool

Whether two shapes from `_qoiValueShape` describe the same quantity: both `Real`, or both keyed by
the same key set.
"""
_qoiShapesAgree(a, b) =
    isnothing(a) ? isnothing(b) : (!isnothing(b) && Set(string.(a)) == Set(string.(b)))

"""
    _qoiShapeStr(shape) → String

How a shape reads in an error message.
"""
_qoiShapeStr(shape) = isnothing(shape) ? "a `Real`" : "keys $(repr(sort(string.(shape))))"

#! Not `mean` itself, because `mean` cannot combine two `Dict`s: a keyed measurement -- the natural
#! shape for "counts per cell type" -- would otherwise need a hand-rolled reducer before it could be
#! used at all, and a bare keyed function died inside `Statistics.mean` naming no QoI.
"""
    _qoiMean(values) → value

The default `reduce`: `mean` for `Real`s, and the per-key mean for keyed values, returned in the same
kind of container. Every replicate must carry the same keys. Any `missing` among `values` makes the
result `missing`, matching `mean`.
"""
function _qoiMean(values)
    isempty(values) && throw(ArgumentError(
        "The default `reduce` was given no replicate values to average."))
    any(ismissing, values) && return missing
    v1 = first(values)
    v1 isa Real && return mean(values)
    (v1 isa NamedTuple || v1 isa AbstractDict) || throw(ArgumentError(
        "The default `reduce` averages a `Real` or a flat `Dict`/`NamedTuple` of them; got a " *
        "$(typeof(v1))."))
    ks = v1 isa NamedTuple ? collect(keys(v1)) : sort(collect(keys(v1)); by=string)
    for v in values
        Set(keys(v)) == Set(ks) || throw(ArgumentError(
            "The default `reduce` averages per key, so every replicate must carry the same keys; " *
            "got $(repr(sort(string.(collect(keys(v1)))))) and " *
            "$(repr(sort(string.(collect(keys(v))))))."))
    end
    means = [mean(v[k] for v in values) for k in ks]
    return v1 isa NamedTuple ? NamedTuple{Tuple(ks)}(Tuple(means)) : Dict(zip(ks, means))
end

#! Replicate agreement is enforced HERE rather than inside the default reducer, even though it is the
#! default reducer's requirement, for two reasons: this is the only place that knows which QoI is
#! being evaluated, and the shape check below is undefined without it -- "keyed in, the same keys
#! out" has no referent when the replicates disagree about what the keys are.
"""
    _qoiInputShape(q, values, monad_id) → shape

The shape every non-`missing` entry of `values` shares, or `missing` when they are all `missing`.
Throws when two replicates disagree.
"""
function _qoiInputShape(q::QoI, values, monad_id::Integer)
    shape = missing
    for v in values
        ismissing(v) && continue
        s = _qoiValueShape(q, v, "`compute` on a simulation of monad $(monad_id)")
        if ismissing(shape)
            shape = s
        else
            _qoiShapesAgree(shape, s) || throw(ArgumentError(
                "QoI \"$(q.name)\": every replicate of a parameter set must produce the same " *
                "keys, since `reduce` combines them key by key. Monad $(monad_id) gave " *
                "$(_qoiShapeStr(shape)) and $(_qoiShapeStr(s))."))
        end
    end
    return shape
end

#! `collect(skipmissing(...))` rather than a `filter`, so the element type NARROWS: a
#! `Vector{Union{Missing,Float64}}` with its missings dropped becomes a `Vector{Float64}`, which is
#! what a reducer written for numbers expects. `filter(!ismissing, v)` keeps the union in the element
#! type and pushes the `Missing` into every downstream signature.
"""
    _reduceOverMonad(q, monad_id) → value or missing

Apply `q` to every simulation of `monad_id` and combine the results with `q.reduce`.

`missing` when `q.skip_missing` and no simulation produced a value. Enforces the QoI value contract
on both sides of `reduce`: each simulation's value and the reduced one must be a `Real` or a flat
`Dict`/`NamedTuple` of them, and `reduce` must keep the shape it was given.
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
    values = [_computeOn(q, sim) for sim in sims]
    for (sim, v) in zip(sims, values)
        isnothing(v) && throw(ArgumentError(
            "QoI \"$(q.name)\": `compute` returned `nothing` for simulation $(sim.id). Return " *
            "`missing` to say this simulation produced no value — `nothing` is what a function " *
            "returns by accident, so it is not accepted as one."))
    end
    kept = q.skip_missing ? collect(skipmissing(values)) : values
    isempty(kept) && return missing
    shape = _qoiInputShape(q, kept, monad_id)
    reduced = q.reduce(kept)
    ismissing(reduced) && return missing
    out_shape = _qoiValueShape(q, reduced, "`reduce` on monad $(monad_id)")
    ismissing(shape) || _qoiShapesAgree(shape, out_shape) || throw(ArgumentError(
        "QoI \"$(q.name)\": `reduce` must keep the shape of the values it is given — a `Real` per " *
        "simulation reduces to a `Real`, a keyed one to the same keys. Monad $(monad_id) gave " *
        "$(_qoiShapeStr(shape)) per simulation but `reduce` returned $(_qoiShapeStr(out_shape))."))
    return reduced
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

#! A `Real` reduce is one quantity; a `Dict`/`NamedTuple` one is several, and `nothing` here is the
#! marker for the scalar case -- it distinguishes "no components" from "components, and here they
#! are", which an empty vector would not. This is the same classification `_qoiValueShape` performs,
#! kept as a separate entry point because sensitivity analysis compares the answer across monads and
#! needs the ordered keys rather than the check.
"""
    _qoiComponentKeys(q, value, monad_id) → keys or nothing

The keys `value` contributes as separate sensitivity analyses, or `nothing` when it is a single
`Real`. Throws when `value` is neither.
"""
_qoiComponentKeys(q::QoI, v, monad_id::Integer) =
    _qoiValueShape(q, v, "`reduce` on monad $(monad_id)")

#! A monad whose every replicate declined to produce a value reduces to `missing`, which is a fine
#! answer for calibration (the particle is rejected) and no answer at all for a sensitivity index:
#! there is no defensible number to put in that cell of the design matrix. Given its own method so
#! the message says what actually happened rather than "reduced to a Missing".
_qoiComponentKeys(q::QoI, ::Missing, monad_id::Integer) = throw(ArgumentError(
    "QoI \"$(q.name)\": monad $(monad_id) has no replicate that produced a value, so it reduces " *
    "to `missing` and there is nothing to place in the design matrix. A sensitivity index needs a " *
    "value from every monad in the design. Check why that monad's simulations returned `missing`, " *
    "or exclude the quantity from this analysis."))

#! Checked per label rather than only per container, because a `Dict` passing the key check can still
#! hold something that is not a number. Without this the failure is a bare `convert` MethodError with
#! no mention of the QoI, which is the error this whole path exists to avoid.
"""
    _qoiComponentValue(q, label, monad_id, v) → Float64
"""
function _qoiComponentValue(q::QoI, label::AbstractString, monad_id::Integer, v)
    v isa Real || throw(ArgumentError(
        "QoI \"$(q.name)\": \"$(label)\" must be a `Real` on every monad, since it becomes a " *
        "sensitivity index. Monad $(monad_id) gave a $(typeof(v))."))
    return Float64(v)
end

"""
    _qoiDuplicateLabelMessage(component_keys, labels) → String

The body of the error raised when two of a QoI's keys produce one label.
"""
function _qoiDuplicateLabelMessage(component_keys, labels)
    dups = unique(l for l in labels if count(==(l), labels) > 1)
    culprits = [k for (k, l) in zip(component_keys, labels) if l in dups]
    return "keys $(join(repr.(culprits), ", ")) all produce the label " *
           "$(join(repr.(dups), ", ")). Distinct keys that collide once written into a label are " *
           "not allowed — each label is its own sensitivity analysis, so one would silently " *
           "replace the other. `1` and \"1\" are one way to get here."
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

"""
    _validateSummaryStatistic(x) → QoI | Vector{QoI}

Check that `x` can serve as a [`CalibrationProblem`](@ref)'s `summary_statistic` and return it as a
`QoI` or a vector of them. Validation is eager -- at construction, not at first evaluation -- so a
duplicate QoI name is reported before any simulation runs.
"""
_validateSummaryStatistic(q::QoI) = q

function _validateSummaryStatistic(qs::AbstractVector{QoI})
    isempty(qs) && throw(ArgumentError("A summary statistic needs at least one QoI."))
    names = qoiName.(qs)
    length(unique(names)) == length(names) || throw(ArgumentError(
        "QoI names must be unique within one summary statistic; got $(names)."))
    return collect(qs)
end

_validateSummaryStatistic(f::Function) = _asQoI(f)

_validateSummaryStatistic(x) = throw(ArgumentError(
    "A summary statistic must be a QoI or a vector of QoIs; got $(typeof(x))."))

#! Calibration is the one consumer that does NOT namespace a key, and the reason is that it is the
#! one consumer where the user supplies the matching half. `observed_data` is keyed by hand, so
#! prefixing would force two spellings of the same quantity -- `compute` returning "tumor" and the
#! observation having to say "counts.tumor". Sink columns and sensitivity labels are flat namespaces
#! shared by every QoI in a project and cannot drop the qualifier; a `distance`'s two arguments are
#! private to one problem and can.
#!
#! A single QoI's value passes through unwrapped, which is what keeps a scalar `observed_data`
#! comparable. A vector of them merges into ONE flat `Dict` rather than nesting: nesting produced
#! `Dict("counts" => Dict("tumor" => …))`, for which `mseDistance` has no method at all.
"""
    _evaluateSummary(ss, monad_id) → value or missing

Evaluate a [`CalibrationProblem`](@ref)'s `summary_statistic` on one monad. A single `QoI` gives its
value as it is; a vector of them gives one flat `Dict{String,Float64}` merging every member's keys —
a `Real`-valued QoI under its own name, a keyed one under its own keys. `missing` when any member has
no value for this monad.
"""
_evaluateSummary(q::QoI, monad_id::Integer) = _reduceOverMonad(q, monad_id)

function _evaluateSummary(qs::AbstractVector{QoI}, monad_id::Integer)
    out = Dict{String,Float64}()
    sources = Dict{String,String}()
    for q in qs
        v = _reduceOverMonad(q, monad_id)
        #! One member with no value makes the whole summary missing, so the particle is handled by
        #! `on_monad_failure` rather than compared on a partial key set.
        ismissing(v) && return missing
        if v isa Real
            _addSummaryEntry!(out, sources, q, q.name, v)
        else
            for (k, vv) in pairs(v)
                _addSummaryEntry!(out, sources, q, string(k), vv)
            end
        end
    end
    return out
end

"""
    _addSummaryEntry!(out, sources, q, key, value)

Record one key of a flattened summary, refusing a key two QoIs both claim.
"""
function _addSummaryEntry!(out::Dict{String,Float64}, sources::Dict{String,String},
                           q::QoI, key::AbstractString, value)
    if haskey(sources, key)
        owner = sources[key]
        detail = owner == q.name ?
            "twice from QoI \"$(q.name)\" — two of its keys read the same once written as strings, " *
            "`1` and \"1\" being one way to get there" :
            "from both QoI \"$(owner)\" and QoI \"$(q.name)\""
        throw(ArgumentError(
            "The summary statistic produces the key \"$(key)\" $(detail). `distance` receives one " *
            "flat `Dict` keyed exactly as your measurements name their components, so one value " *
            "would silently replace the other. Rename a key, or a QoI."))
    end
    sources[key] = q.name
    out[key] = Float64(value)
    return nothing
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
            component_keys = _qoiValueShape(q, v, "`compute` on simulation $(sim.id)")
            #! A gensym must never become a persistent database column, and since EVERY column a QoI
            #! writes is now named after it, that applies to a spread return as much as a scalar one:
            #! the regularised `anon_9` varies between sessions, so the same script would write a
            #! second, half-empty set of columns next time. Only a name that was AUTO-DERIVED --
            #! `QoI("counts", sim -> …)` has an anonymous `compute` but a perfectly good name, and
            #! must not be refused.
            _isAnonymousFunction(q.compute) &&
                q.name == _qoiNameFromFunction(q.compute) && throw(ArgumentError(
                "post_processor: an anonymous function has no stable name, and every sink column is " *
                "named after the QoI that wrote it — this $(typeof(v)) would be stored as " *
                (isnothing(component_keys) ? "\"<name>\"" : "\"<name>.<key>\" per key") *
                ". The derived name varies between sessions, so the same script would write a " *
                "second, half-empty set of columns next time. Name it — " *
                "`QoI(\"my_quantity\", f)` — or pass a named function."))
            if isnothing(component_keys)
                push!(entries, q.name => v)
            else
                #! Namespaced by the QoI's name, matching how sensitivity analysis labels the same
                #! spread. Two QoIs measuring "tumor" no longer land in one column.
                for k in component_keys
                    push!(entries, _qoiLabel(q.name, k) => v[k])
                end
            end
        end
        isempty(entries) && return nothing
        return entries
    end
end
