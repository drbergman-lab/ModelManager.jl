export QoI, sensitivityFunction, summaryStatistic, postProcessor

"""
    QoI(name, level, compute; reduce=mean)

A named quantity of interest: what to measure, and at which level of the trial hierarchy.

Three parts of ModelManager ask a user for "a number out of a simulation", and each asks in its own
shape — sensitivity analysis wants a function of a simulation ID, calibration wants a function of a
monad ID, and the post-processing sink wants a function of a `SimulationProcess`. A `QoI` is that
measurement written once; [`sensitivityFunction`](@ref), [`summaryStatistic`](@ref) and
[`postProcessor`](@ref) adapt it to each.

# Arguments
- `name`: the column name in the post-processing sink, and the key in the `Dict` that
  [`summaryStatistic`](@ref) produces.
- `level`: `Simulation` or `Monad` — the *type* `compute` accepts, given positionally.
- `compute`: `(::level) -> Real | Bool | String`.

# Keywords
- `reduce`: how replicate values combine into one per parameter set, `mean` by default. Meaningful
  only at `Simulation` level; a monad-level `compute` sees every replicate itself and reduces however
  it likes.

# Why the level is a type, not a `Symbol`
`Simulation` and `Monad` are both `AbstractMonad`s, so a `compute` written as `f(x::AbstractMonad)` is
callable at either level and dispatch cannot recover which was meant. Reading a monad as a simulation
is the one failure this seam must make impossible, so the level is **declared** rather than inferred.
Naming it as a type rather than a symbol makes the declaration typo-proof — `Simulaton` is an
`UndefVarError` where `:simulaton` would be a silent mismatch — and lets the adapters dispatch on
`QoI{Simulation}` versus `QoI{Monad}`, so an illegal pairing cannot be constructed rather than merely
being rejected.

# Examples
```julia
# A per-simulation measurement, averaged over replicates
tumor = QoI("tumor", Simulation, s -> finalPopulationCount(s)["tumor"])

# The same measurement, taking the median across replicates instead
QoI("tumor", Simulation, s -> finalPopulationCount(s)["tumor"]; reduce=median)

# A measurement that needs every replicate at once
QoI("spread", Monad, m -> std(replicateEndpoints(m)))

# One QoI, three consumers
run(MOAT(), spec; functions=[sensitivityFunction(tumor)])
CalibrationProblem(spec, observed, summaryStatistic(tumor), mseDistance)
run(trial; post_processor=postProcessor(tumor))
```
"""
struct QoI{L<:AbstractMonad}
    name::String
    compute::Function
    reduce::Function
end

#! The only constructor, so `L` can never be omitted. `hasmethod` here *verifies a declaration* rather
#! than guessing one: a `compute` defined only on `AbstractMonad` satisfies it for whichever level was
#! named, which is correct — it is genuinely callable there, and the user has said which they meant.
function QoI(name::AbstractString, ::Type{L}, compute::Function;
             reduce::Function=mean) where {L<:AbstractMonad}
    L === Simulation || L === Monad || throw(ArgumentError(
        "A QoI's level must be `Simulation` or `Monad`; got $(L). Those are the two granularities " *
        "the trial hierarchy offers a measurement."))
    hasmethod(compute, Tuple{L}) || throw(ArgumentError(
        "QoI \"$(name)\" declares level $(L), but its `compute` has no method accepting one. " *
        "Either give `compute` a `($(L),)` method or declare the level it actually takes."))
    return QoI{L}(String(name), compute, reduce)
end

qoiName(q::QoI) = q.name

#! Sensitivity analysis evaluates per simulation and averages replicates itself with a hard-coded
#! `mean` (`evaluateFunctionOnSampling`), so `q.reduce` is not consulted here and a non-`mean` reducer
#! would be quietly ignored — hence the explicit refusal below rather than a surprise.
"""
    sensitivityFunction(q::QoI) → Function

Adapt `q` for the `functions` keyword of `run(::GSAMethod, ...)`, which calls it with a simulation ID.
"""
function sensitivityFunction(q::QoI{Simulation})
    q.reduce === mean || throw(ArgumentError(
        "QoI \"$(q.name)\" carries a custom `reduce`, but sensitivity analysis averages replicates " *
        "itself with `mean` and would ignore it. Use `reduce=mean` for a sensitivity study, or " *
        "reduce inside a `Monad`-level `compute`."))
    return sim_id::Integer -> q.compute(Simulation(Int(sim_id)))
end

function sensitivityFunction(q::QoI{Monad})
    throw(ArgumentError(
        "QoI \"$(q.name)\" is `Monad`-level, but sensitivity analysis evaluates one simulation at a " *
        "time and averages the replicates itself. Express it as a `Simulation`-level QoI, or compute " *
        "it per simulation and let the library average."))
end

#! A `Simulation`-level QoI is where `reduce` finally matters: calibration compares one number per
#! parameter set, so the replicates have to collapse, and unlike sensitivity analysis nothing upstream
#! has already done it.
"""
    summaryStatistic(q::QoI) → Function
    summaryStatistic(qs) → Function

Adapt one or more `QoI`s for [`CalibrationProblem`](@ref)'s `summary_statistic`, which calls it with a
monad ID and whose result is handed to the problem's `distance`.

Returns a `Dict{String,Any}` keyed by QoI name, which is the shape [`mseDistance`](@ref) expects.
"""
summaryStatistic(q::QoI) = summaryStatistic([q])

function summaryStatistic(qs::AbstractVector{<:QoI})
    isempty(qs) && throw(ArgumentError("summaryStatistic needs at least one QoI."))
    names = qoiName.(qs)
    length(unique(names)) == length(names) || throw(ArgumentError(
        "QoI names must be unique within one summary statistic; got $(names)."))
    return function (monad_id::Integer)
        d = Dict{String,Any}()
        for q in qs
            d[q.name] = _qoiOnMonad(q, Int(monad_id))
        end
        return d
    end
end

_qoiOnMonad(q::QoI{Monad}, monad_id::Int) = q.compute(Monad(monad_id))

function _qoiOnMonad(q::QoI{Simulation}, monad_id::Int)
    sim_ids = constituentIDs(Monad, monad_id)
    isempty(sim_ids) && throw(ArgumentError(
        "Monad $(monad_id) has no simulations, so QoI \"$(q.name)\" cannot be evaluated on it."))
    return q.reduce([q.compute(Simulation(sid)) for sid in sim_ids])
end

#! `Monad`-level is unrepresentable here rather than rejected at runtime: the hook fires once per
#! simulation, so there is no monad for a monad-level `compute` to receive. The signature says so.
"""
    postProcessor(qs::QoI...) → Function

Adapt `Simulation`-level `QoI`s for `run`'s `post_processor`, which calls it once per simulation and
records the returned `name => value` pairs in the post-processing sink.
"""
postProcessor(qs::QoI{Simulation}...) = postProcessor(collect(qs))

function postProcessor(qs::AbstractVector{QoI{Simulation}})
    isempty(qs) && throw(ArgumentError("postProcessor needs at least one QoI."))
    names = qoiName.(qs)
    length(unique(names)) == length(names) || throw(ArgumentError(
        "QoI names must be unique within one post-processor; got $(names)."))
    return function (sp::SimulationProcess)
        sim = Simulation(simulationID(sp))
        return Dict{String,Any}(q.name => q.compute(sim) for q in qs)
    end
end
