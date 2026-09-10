export CalibrationProblem, Calibration, GenerationResult, ABCResult, posterior, samplePosterior,
       ConvergenceSummary

#! Repeated in `abc_smc.jl` rather than hoisted: this file is included first, and `samplePosterior`
#! needs the same four names for its kernel covariance.
using LinearAlgebra: Symmetric, I, Diagonal, cholesky

################## CalibrationProblem ##################

"""
    CalibrationProblem

Defines a full calibration problem: model inputs, parameters to infer, observed data,
and how to compare simulated to observed output.

# Fields
- `inputs::InputFolders`: Base model configuration shared across all calibration runs.
- `parameters::Vector{CalibrationParameter}`: Parameters to calibrate, stored as
  [`CalibrationParameter`](@ref) objects that track both the original user-supplied
  variation and the derived `LatentVariation` used internally. Pass any combination of
  `DistributedVariation`, `CoVariation{DistributedVariation}`, or
  `LatentVariation{<:Distribution}` to the constructors — conversion is automatic.
- `observed_data`: Observed summary statistic in whatever form the `distance` function
  expects as its second argument.
- `summary_statistic`: a [`QoI`](@ref), a vector of them, or a plain function — ideally one that
  **declares it takes a [`Simulation`](@ref)**, `f(s::Simulation)` or `(s::Simulation) -> …`, since
  one that does not is warned about. In every case the
  measurement is made once per *simulation* and the replicates are combined by `reduce` (`mean` for a
  plain function; a `QoI` is how you choose otherwise, and its `reduce` receives every replicate's
  value, so a step that must happen *after* averaging goes there). A single QoI or a plain function
  reports its value directly; a vector of QoIs reports a `Dict` keyed by QoI name.

  The annotation matters because the previous contract called a bare function once per *monad* and
  let it aggregate however it liked. An unannotated argument is ambiguous between the two, and
  reinterpreting one silently would change results without raising. It is warned about rather than
  refused, since refusing every unannotated function would also reject `sim -> measure(sim)`, the
  natural way to write a new-contract lambda. The warning is transitional and goes in v0.10.
- `distance::Function`: `(simulated, observed) → Float64`. `simulated` is the return value
  of `summary_statistic`; `observed` is `observed_data`.
  Built-in: [`mseDistance`](@ref) — handles `Dict`, `Vector`, and scalar inputs.
- `n_replicates::Int`: Number of replicate simulations to run per proposed particle
  (default 1). Values > 1 reduce stochastic noise in each particle evaluation at the cost
  of N× more compute.
- `reference_variation_id::VariationID`: Base variation ID establishing fixed parameter
  values that apply to every particle evaluation. Obtain from a reference monad:
  `createTrial(inputs, fixed_dvs...; n_replicates=0).variation_id`.

# Examples
```julia
# Short run for testing — set max_time via a reference
ref = createTrial(inputs, DiscreteVariation(["overall","max_time"], 12.0); n_replicates=0)

# Your own per-simulation measurement: reach into this simulation's output and return a number.
# Parsing raw output is the backend's job, so in practice you would call the loader your simulator
# package provides (keyed by `simulationID`); this reads a summary file the simulator wrote.
function countDefaultCells(sim::Simulation)
    counts = joinpath(pathToOutputFolder(sim), "final_cell_counts.csv") |> CSV.File |> DataFrame
    return Float64(only(counts[counts.cell_type .== "default", :count]))
end

# A vector of QoIs reports a `Dict` keyed by QoI name, so `observed` is keyed the same way.
observed = Dict("default" => 100.0)
problem = CalibrationProblem(
    ref,
    [DistributedVariation(:config, xml_path, Uniform(1e-7, 1e-4))],
    observed,
    [QoI("default", countDefaultCells)],
    mseDistance
)

# Covaried parameters — one latent CDF draw moves both targets together
problem2 = CalibrationProblem(
    ref,
    [CoVariation(dv_birth_rate, dv_death_rate)],
    observed,
    summary_fn,
    mseDistance
)
```
"""
struct CalibrationProblem
    inputs::InputFolders
    parameters::Vector{CalibrationParameter}
    observed_data::Any
    summary_statistic::Union{QoI,Vector{QoI}}
    distance::Function
    n_replicates::Int
    reference_variation_id::VariationID
end

function CalibrationProblem(inputs::InputFolders, parameters::AbstractVector,
                             observed_data,
                             summary_statistic, distance;
                             n_replicates::Int=1,
                             reference_variation_id::VariationID=VariationID(inputs))
    cps = _toCalibrationParameters(parameters)
    return CalibrationProblem(inputs, cps, observed_data,
                              _validateSummaryStatistic(summary_statistic), distance,
                              n_replicates, reference_variation_id)
end

#! No `reference_variation_id` keyword, deliberately. `createTrial(method, reference::AbstractMonad,
#! avs; ...)` — the closest and most-used analogue — takes the variation from the reference and offers
#! no override, and nothing internal constructs this form at all. Passing a reference and then
#! overriding the thing that makes it a reference is a contradiction, not a convenience; the
#! `InputFolders` constructor is where a variation ID is genuinely an independent argument.
function CalibrationProblem(ref::AbstractMonad, parameters::AbstractVector,
                             observed_data,
                             summary_statistic, distance; n_replicates::Int=1)
    cps = _toCalibrationParameters(parameters)
    return CalibrationProblem(ref.inputs, cps, observed_data,
                              _validateSummaryStatistic(summary_statistic), distance,
                              n_replicates, ref.variation_id)
end

#! `use_previous` is deliberately dropped: calibration reuses through the `SimulationBank`, not the
#! runner's matching, so there is nothing here for it to mean. Named in the `StudySpec` docstring and
#! marked "(sensitivity only)" by its `show`, so the omission is visible rather than silent.
"""
    CalibrationProblem(spec::StudySpec, observed_data, summary_statistic, distance; kwargs...)

Build a problem from a [`StudySpec`](@ref), taking its inputs, parameters, reference variation and
replicate count. `n_replicates` and `reference_variation_id` may be overridden.
"""
function CalibrationProblem(spec::StudySpec, observed_data, summary_statistic, distance;
                            n_replicates::Integer=spec.n_replicates,
                            reference_variation_id::VariationID=spec.reference_variation_id)
    return CalibrationProblem(spec.inputs, spec.variations, observed_data,
                              summary_statistic, distance;
                              n_replicates=Int(n_replicates),
                              reference_variation_id=reference_variation_id)
end

#! Defined here rather than beside `ParsedVariations` in `variations.jl`: that file is included
#! before `calibration/problem.jl`, so a method signature naming `CalibrationProblem` there would be
#! an `UndefVarError` at definition time.
"""
    ParsedVariations(problem::CalibrationProblem) → ParsedVariations

Reinterpret a calibration problem's parameters as a sensitivity-analysis variation set.

This is lossless: both workflows normalize user variations through the same `LatentVariation`
factories, and the problem retains each parameter's latent variation, so nothing is reconstructed.
The reverse direction is *not* lossless and is deliberately not provided — routing a
[`DistributedVariation`](@ref) through `LatentVariation` and back loses the friendly display name
its generation CSVs are keyed by.

# Examples
```julia
problem = CalibrationProblem(inputs, [dv1, dv2], observed, summarize, mseDistance)
pv = ParsedVariations(problem)
```
"""
ParsedVariations(problem::CalibrationProblem) =
    ParsedVariations(AbstractVariation[cp.lv for cp in problem.parameters])

#! Deliberately no `run(::GSAMethod, ::CalibrationProblem)`. Sensitivity analysis normally comes
#! *before* calibration, so dispatching a GSA method on the heavier object inverts the usual order and
#! would ask a user who only wants a screening run to invent `observed_data`, a `summary_statistic` and
#! a `distance` first. The shared object is the vector of variations, which both entry points already
#! accept: build `priors` once, pass it to `run(method, inputs, priors; functions=...)`, and pass the
#! same vector to `CalibrationProblem` later.

################## Calibration ##################

"""
    Calibration

Represents a calibration run tracked in the database.

Created automatically by [`runABC`](@ref). The associated output folder at
`data/outputs/calibrations/{id}/` contains:
- `generations/{t}/monads.csv`: monad IDs evaluated per generation (written
  before each batch for crash safety).
- `generations/{t}/failed_simulations.csv` and
  `generations/{t}/failed_monads.csv`: IDs of simulations that failed in that
  generation and of the monads they belong to. Written only when something failed.
- `generations/{t}/particles.csv`: human-readable per-generation results — target
  parameter values (and latent parameter samples for user-supplied `LatentVariation`s),
  weights, distances, and monad IDs.
- `generations/{t}/metadata.toml`: generation-level metadata (epsilon,
  acceptance_rate, ess, n_evaluations).
- `generations/{t}/cdfs.csv`: raw CDF coordinates for each accepted particle;
  used by [`resumeABC`](@ref) to reconstruct the internal particle state exactly.
- `method.toml`: serialized ABC-SMC settings (used by [`resumeABC`](@ref)).
- `problem.jld2`: full serialized [`CalibrationProblem`](@ref); enables
  `resumeABC(Calibration(id))` with no further arguments.
- `parameters.toml`: human-readable mapping from display column names
  (used in `generations/` CSVs) to database column names, with prior strings.

# Fields
- `id::Int`: Unique ID, matched to the `calibrations` table in the database.
"""
struct Calibration
    id::Int
end

################## GenerationResult ##################

"""
    GenerationResult

Result of a single ABC-SMC generation.

# Fields
- `t::Int`: Generation index (1-based).
- `particles::DataFrame`: One row per accepted particle; columns are **latent CDF
  coordinates** (internal representation used by the ABC-SMC algorithm).
- `weights::Vector{Float64}`: Normalized importance weights (sum to 1).
- `distances::Vector{Float64}`: Distance for each accepted particle.
- `max_epsilon_accepted::Float64`: The largest distance this generation accepted. Never exceeds
  `epsilon_threshold`, and is what the stopping criteria compare against.
- `n_evaluations::Int`: Total proposals evaluated, including rejected ones.
- `monad_ids::Vector{Int}`: Monad IDs for each accepted particle.
- `acceptance_rate::Float64`: Fraction of proposals that passed the epsilon threshold
  (`n_accepted_total / n_evaluations`). When `accept_overflow=false`, this equals
  `length(distances) / n_evaluations`; when `accept_overflow=true`, it may be slightly
  higher because overflow particles are counted but `n_evaluations` includes the full batch.
- `ess::Float64`: Effective sample size, `1 / Σwᵢ²`. Equals `population_size` when
  weights are uniform (generation 1) and decreases as weights concentrate.
- `epsilon_threshold::Union{Nothing,Float64}`: The cutoff this generation was run against —
  `epsilon_schedule[t-1]` if one was supplied, otherwise
  `max(minimum_epsilon, quantile(previous_distances, epsilon_quantile))`. `nothing` for generation 1,
  which accepts every proposal it evaluates, and for generations recorded before this was stored.
  Distinct from `max_epsilon_accepted`: at the default `epsilon_quantile` of `0.5` the threshold is a
  *median* of the previous generation's distances while `max_epsilon_accepted` is a *maximum* of this
  one's, so the two coincide only when `epsilon_quantile == 1.0`.
- `proposal_distances::Union{Nothing,DataFrame}`: Reserved for the per-generation distance of every
  evaluated proposal, accepted or not. Currently always `nothing` — nothing populates it yet.
- `rejected_proposals::Union{Nothing,DataFrame}`: CDF-coordinate DataFrame of all
  rejected proposals in this generation (same column names as `particles`). Populated
  only when `ABCSMC(store_rejected=true)`; always `nothing` for generation 1 (all Sobol
  proposals are accepted) and always `nothing` on resume. Used by the `:transition`
  visualization recipe; see also the lazy disk fallback in `_lazyLoadRejected`.
"""
struct GenerationResult
    t::Int
    particles::DataFrame
    weights::Vector{Float64}
    distances::Vector{Float64}
    max_epsilon_accepted::Float64
    n_evaluations::Int
    monad_ids::Vector{Int}
    acceptance_rate::Float64
    ess::Float64
    rejected_proposals::Union{Nothing,DataFrame}
    epsilon_threshold::Union{Nothing,Float64}
    proposal_distances::Union{Nothing,DataFrame}
end

#! The two trailing fields are named rather than positional. Twelve positional arguments ending in
#! three `nothing`s is hard to read, and — unlike a compatibility shim — this is not something to
#! deprecate later: it is how the type is meant to be constructed. Both are genuinely absent for a
#! generation loaded from a run that predates them, so `nothing` is the right default rather than a
#! placeholder.
GenerationResult(t, particles, weights, distances, max_epsilon_accepted, n_evaluations,
                 monad_ids, acceptance_rate, ess, rejected_proposals;
                 epsilon_threshold=nothing, proposal_distances=nothing) =
    GenerationResult(t, particles, weights, distances, max_epsilon_accepted, n_evaluations,
                     monad_ids, acceptance_rate, ess, rejected_proposals,
                     epsilon_threshold, proposal_distances)

################## ABCResult ##################

"""
    ABCResult

Holds the result of an ABC-SMC calibration run.

# Fields
- `calibration::Calibration`: The calibration record (DB entry + folder).
- `generations::Vector{GenerationResult}`: Results per SMC generation, in order.
  Each `GenerationResult.particles` stores raw latent CDF coordinates.
- `parameters::Vector{CalibrationParameter}`: The calibrated parameters (same as stored
  in the [`CalibrationProblem`](@ref)), used to convert CDF coordinates to interpretable
  target values in [`posterior`](@ref).
- `method::ABCSMC`: The settings used for this run.

The run-level accessors take an `ABCResult` directly, so reaching for `.calibration` is optional:
[`Sampling`](@ref), [`monadIDs`](@ref), [`simulationIDs`](@ref), [`tag!`](@ref), [`untag!`](@ref),
[`tags`](@ref), [`hasTag`](@ref), [`tagsTable`](@ref), [`calibrationsTable`](@ref) and
[`deleteCalibration`](@ref) all forward to it.

# Examples
```julia
result = runABC(problem)
df, weights = posterior(result)                # final generation, target-value format
df, weights = posterior(result; generation=2)  # specific generation

tag!(result, "project" => "immune-escape")     # same as tag!(result.calibration, ...)
simulationsTable(Sampling(result))
```
"""
struct ABCResult
    calibration::Calibration
    generations::Vector{GenerationResult}
    parameters::Vector{CalibrationParameter}
    method::ABCSMC
end

################## posterior ##################

"""
    posterior(result::ABCResult; generation::Union{Int,Symbol}=:final)

Extract posterior samples from an [`ABCResult`](@ref).

Converts the internal CDF-coordinate particles to **target-parameter space** using the
stored [`CalibrationParameter`](@ref) objects. For `DVSource` / `CVSource` parameters the
columns are the actual calibrated parameter values; for `LVSource` parameters the latent
parameter samples are prepended.

# Returns
- `df::DataFrame`: One row per particle; columns are target parameter names. For
  `LVSource` parameters (user-supplied `LatentVariation`), the latent parameter samples
  are included as well.
- `weights::Vector{Float64}`: Importance weights (sum to 1).

# Arguments
- `generation`: Integer generation index (1-based) or `:final` for the last generation.

# Examples
```julia
result = runABC(problem)
df, weights = posterior(result)                # final generation
df, weights = posterior(result; generation=1)  # first generation
println("Posterior mean: ", sum(df[!, "overall/max_time"] .* weights))
```
"""
function posterior(result::ABCResult; generation::Union{Int,Symbol}=:final)
    t = _resolveGeneration(result, generation)
    gen = result.generations[t]
    display_df = _buildDisplayDF(gen, result.parameters)
    return display_df, gen.weights
end

"""
    _resolveGeneration(result::ABCResult, generation) → Int

Turn a `generation` keyword into a validated 1-based index into `result.generations`.

Shared by `posterior` and `samplePosterior` so the `:final` convention and the range error cannot
drift between them.
"""
function _resolveGeneration(result::ABCResult, generation::Union{Int,Symbol})
    isempty(result.generations) && error("No generations in ABCResult — calibration may not have completed.")
    t = generation === :final ? length(result.generations) : Int(generation)
    1 <= t <= length(result.generations) || throw(ArgumentError(
        "Generation $t is out of range [1, $(length(result.generations))]."
    ))
    return t
end

"""
    posterior(calibration::Calibration; generation::Union{Int,Symbol}=:final)

Extract posterior samples directly from disk for a completed calibration run.

Reads the human-readable `generations/{t}/particles.csv` file for the requested
generation. Returns only the parameter columns (strips `weight`, `distance`, `monad_id`).

Useful when you have only the calibration ID (e.g. after a session restart) and don't
have an in-memory [`ABCResult`](@ref).

# Returns
- `df::DataFrame`: One row per particle; columns are target parameter names.
- `weights::Vector{Float64}`: Importance weights (sum to 1).

# Examples
```julia
# Retrieve results after a session restart
df, weights = posterior(Calibration(42))
df, weights = posterior(Calibration(42); generation=3)
```
"""
function posterior(calibration::Calibration; generation::Union{Int,Symbol}=:final)
    display_df, weights, _ = _readGenerationParticles(calibration, generation)
    return display_df, weights
end

"""
    _resolveDiskGeneration(calibration, generation) → (gen_dir, t)

Locate a calibration's `generations/` directory and resolve `generation` to an index that is
actually present on disk.

`:final` is the highest recorded generation, not the last entry of a listing: names are addressed by
the index inside them, so a missing generation or a changed padding width cannot shift the answer.
"""
function _resolveDiskGeneration(calibration::Calibration, generation::Union{Int,Symbol})
    gen_dir = joinpath(calibrationFolder(calibration), "generations")
    isdir(gen_dir) || error(
        "No generations directory found for Calibration($(calibration.id)). " *
        "Has the calibration been run?")

    indices = _generationIndices(gen_dir)
    isempty(indices) && error(
        "No completed generations found for Calibration($(calibration.id)).")

    t = generation === :final ? last(indices) : Int(generation)
    t in indices || throw(ArgumentError(
        "Generation $t not found for Calibration($(calibration.id)). Available: $(indices)."))
    return gen_dir, t
end

"""
    _readGenerationParticles(calibration, generation) → (display_df, weights, monad_ids)

Read one generation's `particles.csv`, splitting the parameter columns from the three bookkeeping
ones (`weight`, `distance`, `monad_id`).

The single disk reader behind both `posterior(::Calibration)` and `samplePosterior(::Calibration)`.
"""
function _readGenerationParticles(calibration::Calibration, generation::Union{Int,Symbol})
    gen_dir, t = _resolveDiskGeneration(calibration, generation)
    csv_path = _generationArtifact(gen_dir, t, :particles)
    isnothing(csv_path) && error(
        "Generation $t of Calibration($(calibration.id)) has no particle file.")

    df = CSV.read(csv_path, DataFrame)
    weights    = df[!, :weight]
    monad_ids  = df[!, :monad_id]
    display_df = select(df, Not([:weight, :distance, :monad_id]))
    return display_df, weights, monad_ids
end

################## samplePosterior ##################

"""
    samplePosterior(result::ABCResult, n::Int; generation=:final, smooth=false, rng=Random.default_rng())
    samplePosterior(calibration::Calibration, n::Int; generation=:final, smooth=false, rng=Random.default_rng())

Draw `n` parameter sets from a generation's posterior, as a `DataFrame` of display columns.

By default each draw is one of the accepted particles, resampled i.i.d. with probability equal to
its importance weight; the frame therefore carries a `monad_id` column, so a posterior predictive
check can read the monad's existing outputs instead of simulating again. With `smooth=true` the
weighted particles become a Gaussian kernel density estimate and the draws are new parameter sets
between them, so there is no `monad_id`. Either way the frame holds [`posterior`](@ref)'s parameter
columns and not its `weight`/`distance` ones — a draw's own weight is `1/n`.

The kernel is fitted in CDF space, which is what keeps a draw inside every prior's support, respects
a log-scaled prior, and lands a discrete parameter on one of its levels: the bandwidth is Scott's
rule with the effective sample size in place of `N`, applied to the weighted particle covariance
(`h² Σ_w`, `h = ESS^(-1/(d+4))`), a draw straying outside `[0, 1]` is reflected back rather than
rejected, and the result is mapped through the prior quantiles exactly as [`posterior`](@ref) maps a
particle. Note the bandwidth is *not* the run's `perturbation_kernel` scale, which is deliberately
over-dispersed for proposals.

`generation` is an integer index or `:final`, as in [`posterior`](@ref).

Sampling a [`Calibration`](@ref) reads from disk. Plain mode needs only the generation's
`particles.csv`; smoothed mode additionally rebuilds the parameters from `problem.jld2`, so it fails
for a run whose `LatentVariation` carried anonymous maps — those are not serializable, and the error
names [`resumeABC`](@ref)`(cal; problem=my_problem)`, which returns an [`ABCResult`](@ref) for a
finished run without re-running it, as the way to get them back.

# Examples
```julia
result = runABC(problem)

draws = samplePosterior(result, 200)                    # existing particles, with monad_id
new_points = samplePosterior(result, 200; smooth=true)  # new parameter sets, no monad_id
samplePosterior(Calibration(42), 50; generation=2)
```
"""
function samplePosterior(result::ABCResult, n::Int; generation::Union{Int,Symbol}=:final,
                         smooth::Bool=false, rng::AbstractRNG=Random.default_rng())
    _assertDrawCount(n)
    t   = _resolveGeneration(result, generation)
    gen = result.generations[t]

    if !smooth
        display_df, weights = posterior(result; generation=t)
        return _plainPosteriorDraws(rng, display_df, weights, gen.monad_ids, n)
    end

    cps         = result.parameters
    param_names = _cdfColumnNames(cps, names(gen.particles))
    X           = Matrix{Float64}(gen.particles[!, param_names])
    Y           = _smoothedCDFDraws(rng, X, Vector{Float64}(gen.weights), n)
    return _cdfDrawsToDisplay(Y, cps, param_names)
end

function samplePosterior(calibration::Calibration, n::Int; generation::Union{Int,Symbol}=:final,
                         smooth::Bool=false, rng::AbstractRNG=Random.default_rng())
    _assertDrawCount(n)

    if !smooth
        display_df, weights, monad_ids = _readGenerationParticles(calibration, generation)
        return _plainPosteriorDraws(rng, display_df, weights, monad_ids, n)
    end

    gen_dir, t = _resolveDiskGeneration(calibration, generation)
    cdf_path   = _generationArtifact(gen_dir, t, :cdfs)
    isnothing(cdf_path) && error(
        "Generation $t of Calibration($(calibration.id)) has no cdfs.csv, which smoothed sampling " *
        "needs for the particles' CDF coordinates.")

    df          = CSV.read(cdf_path, DataFrame)
    cps         = _diskCalibrationParameters(calibration)
    param_names = _cdfColumnNames(cps, names(df))
    X           = Matrix{Float64}(df[!, param_names])
    Y           = _smoothedCDFDraws(rng, X, Vector{Float64}(df[!, :weight]), n)
    return _cdfDrawsToDisplay(Y, cps, param_names)
end

_assertDrawCount(n::Int) = n >= 0 ||
    throw(ArgumentError("samplePosterior needs a non-negative number of draws; got n = $n."))

#! The three bookkeeping columns of a generation CSV. A resampled frame drops them: a draw's weight
#! is `1/n` by construction, not the particle's, so carrying the particle's `weight` along would
#! invite a second weighted average over an already-weighted sample.
const _PARTICLE_BOOKKEEPING_COLUMNS = ("weight", "distance", "monad_id")

"""
    _cdfColumnNames(cps, available) → Vector{String}

The CDF-coordinate columns to read, in latent-parameter order — or, when `cps` is empty (a
`GenerationResult` built directly, as the tests do), whichever of `available` are not bookkeeping.
"""
_cdfColumnNames(cps::Vector{CalibrationParameter}, available::Vector{String}) =
    isempty(cps) ? [c for c in available if !(c in _PARTICLE_BOOKKEEPING_COLUMNS)] :
                   first(_latentNamesAndPriors(cps))

"""
    _multinomialDraw(rng, weights, n) → Vector{Int}

Draw `n` particle indices i.i.d. with probability proportional to `weights`.

Not `_systematicResample`, which is lower variance for propagating a population but makes the draws
depend on each other and on their order — a caller handed `n` draws expects any subset of them to be
a valid sample. A zero-weight particle is never drawn.
"""
function _multinomialDraw(rng::AbstractRNG, weights::AbstractVector{<:Real}, n::Int)
    N = length(weights)
    (n > 0 && N == 0) &&
        throw(ArgumentError("Cannot draw from a generation with no particles."))
    c = cumsum(weights)
    return Int[clamp(searchsortedfirst(c, rand(rng) * c[end]), 1, N) for _ in 1:n]
end

#! `monad_id` is assigned rather than carried over from `display_df`, because only one of the two
#! entry points has it there: `posterior(::ABCResult)` returns the bookkeeping columns while
#! `posterior(::Calibration)` strips them. Taking it from the caller's vector keeps the two frames
#! identical.
"""
    _plainPosteriorDraws(rng, display_df, weights, monad_ids, n) → DataFrame

Resample `n` rows of `display_df` by `weights`, returning a fresh frame of the parameter columns
plus the drawn rows' `monad_id`.
"""
function _plainPosteriorDraws(rng::AbstractRNG, display_df::DataFrame,
                              weights::AbstractVector{<:Real},
                              monad_ids::AbstractVector{<:Integer}, n::Int)
    idx  = _multinomialDraw(rng, weights, n)
    cols = [c for c in names(display_df) if !(c in _PARTICLE_BOOKKEEPING_COLUMNS)]
    out  = display_df[idx, cols]
    out[!, :monad_id] = collect(monad_ids[idx])
    return out
end

"""
    _smoothedCDFDraws(rng, X, w, n) → Matrix{Float64}

Draw `n` rows from a weighted Gaussian KDE over the CDF-space particles `X` (one particle per row).

Scott's factor uses the effective sample size `1/Σwᵢ²` rather than the particle count, since the
particles are weighted. A `1e-10` diagonal floor keeps the covariance factorisable when a coordinate
has collapsed onto one value, and each coordinate is reflected into `[0, 1]` rather than rejected —
rejection would thin the edges of the estimate, and there are no importance weights here to correct
for it.
"""
function _smoothedCDFDraws(rng::AbstractRNG, X::AbstractMatrix{Float64},
                           w::AbstractVector{Float64}, n::Int)
    d = size(X, 2)
    n == 0 && return Matrix{Float64}(undef, 0, d)

    mu      = vec(sum(w .* X, dims=1))
    Xc      = X .- mu'
    Sigma_w = Symmetric(Xc' * Diagonal(w) * Xc)
    ess     = 1 / sum(abs2, w)
    h2      = ess^(-2 / (d + 4))
    H       = h2 * Sigma_w + 1e-10 * I(d)
    L       = cholesky(Symmetric(Matrix(H))).L

    out = Matrix{Float64}(undef, n, d)
    for (i, j) in enumerate(_multinomialDraw(rng, w, n))
        y = X[j, :] + L * randn(rng, d)
        for k in 1:d
            out[i, k] = _reflectIntoUnit(y[k])
        end
    end
    return out
end

"""
    _reflectIntoUnit(v) → Float64

Fold `v` into `[0, 1]` by repeated reflection at both ends.
"""
function _reflectIntoUnit(v::Real)
    r = mod(v, 2.0)
    return r > 1 ? 2 - r : r
end

"""
    _cdfDrawsToDisplay(Y, cps, param_names) → DataFrame

Map each CDF-coordinate row of `Y` through the prior quantiles into display values, one group of
columns per [`CalibrationParameter`](@ref).

With `cps` empty the CDF coordinates *are* the display values, matching `_buildDisplayDF`.
"""
function _cdfDrawsToDisplay(Y::Matrix{Float64}, cps::Vector{CalibrationParameter},
                            param_names::Vector{String})
    isempty(cps) && return DataFrame(Y, param_names)

    n        = size(Y, 1)
    position = Dict(name => i for (i, name) in enumerate(param_names))
    df       = DataFrame()
    for cp in cps
        dcols = _displayColumns(cp)
        vecs  = [Vector{Float64}(undef, n) for _ in dcols]
        cdf_positions = [position[name] for name in cp.lv.latent_parameter_names]
        for i in 1:n
            vals = _particleRowToDisplay(cp, Float64[Y[i, k] for k in cdf_positions])
            for j in eachindex(dcols)
                vecs[j][i] = vals[j]
            end
        end
        for (name, vec) in zip(dcols, vecs)
            df[!, name] = vec
        end
    end
    return df
end

#! Smoothed sampling from disk needs the quantile maps, not just the CDF coordinates, so it is the
#! one read path that depends on `problem.jld2` being complete.
"""
    _diskCalibrationParameters(calibration) → Vector{CalibrationParameter}

Rebuild a run's calibration parameters from its serialized problem manifest.

Errors when a `LatentVariation` was saved with anonymous maps, which JLD2 cannot store.
"""
function _diskCalibrationParameters(calibration::Calibration)
    manifest = _loadProblem(calibration)
    if any(s -> s isa _StrippedLVSource, manifest.sources)
        error("""
            Cannot draw smoothed samples for Calibration($(calibration.id)) from disk: its LatentVariation was saved with anonymous maps, so problem.jld2 does not carry the quantile maps a smoothed draw has to pass through.
            Re-supply the problem to get an in-memory result, and sample that instead:

                samplePosterior(resumeABC(Calibration($(calibration.id)); problem=my_problem), n; smooth=true)

            On a finished run `resumeABC` returns the ABCResult without re-running anything.
            """)
    end
    return CalibrationParameter[_sourceToCalibrationParameter(s) for s in manifest.sources]
end

################## ConvergenceSummary ##################

"""
    ConvergenceSummary(result::ABCResult)
    ConvergenceSummary(cal::Calibration)

Per-generation convergence table for an ABC-SMC run. Supports
`plot(ConvergenceSummary(result))` via the RecipesBase recipe in `visualize.jl`,
and behaves like a DataFrame for property access (`cs.max_epsilon_accepted`, etc.).

# Columns
- `t`: Generation index.
- `max_epsilon_accepted`: The largest distance the generation accepted.
- `epsilon_threshold`: The cutoff it was run against; `nothing` for generation 1 and for generations
  recorded before this was stored.
- `acceptance_rate`: Fraction of proposals accepted.
- `n_accepted`: Number of accepted particles (equals `population_size` when
  `accept_overflow=false`; may be larger when `accept_overflow=true`).
- `ess`: Effective sample size (1 / Σwᵢ²).
- `ess_fraction`: `ess / n_accepted` — values near 1 mean uniform weights.
- `n_evaluations`: Total proposals evaluated (including rejected).

# Examples
```julia
cs = ConvergenceSummary(result)
cs = ConvergenceSummary(Calibration(42))
plot(cs)
```
"""
struct ConvergenceSummary
    df::DataFrame
end

Base.getproperty(cs::ConvergenceSummary, s::Symbol) =
    s === :df ? getfield(cs, :df) : getproperty(getfield(cs, :df), s)

Base.propertynames(cs::ConvergenceSummary, private::Bool=false) =
    (fieldnames(ConvergenceSummary)..., propertynames(getfield(cs, :df), private)...)

Base.show(io::IO, cs::ConvergenceSummary) = show(io, cs.df)
Base.show(io::IO, mime::MIME"text/plain", cs::ConvergenceSummary) = show(io, mime, cs.df)

function ConvergenceSummary(result::ABCResult)
    isempty(result.generations) && error("No generations in ABCResult.")
    df = DataFrame(
        t               = [g.t                       for g in result.generations],
        max_epsilon_accepted = [g.max_epsilon_accepted for g in result.generations],
        epsilon_threshold    = [g.epsilon_threshold    for g in result.generations],
        acceptance_rate = [g.acceptance_rate         for g in result.generations],
        n_accepted      = [nrow(g.particles)         for g in result.generations],
        ess             = [g.ess                     for g in result.generations],
        ess_fraction    = [g.ess / nrow(g.particles) for g in result.generations],
        n_evaluations   = [g.n_evaluations           for g in result.generations],
    )
    return ConvergenceSummary(df)
end

function ConvergenceSummary(cal::Calibration)
    gen_dir = joinpath(calibrationFolder(cal), "generations")
    isdir(gen_dir) || error("No generations directory for Calibration($(cal.id)).")
    indices = _generationIndices(gen_dir)
    isempty(indices) && error("No generation metadata found for Calibration($(cal.id)).")

    ts = Int[]; epsilons = Float64[]; acceptance_rates = Float64[]
    thresholds = Union{Nothing,Float64}[]
    n_accepteds = Int[]; esss = Float64[]; ess_fractions = Float64[]
    n_evaluationss = Int[]

    #! `t` is the generation's own index, not its position in a listing, and the particle file is
    #! resolved on its own rather than by swapping the metadata file's extension — under the folder
    #! layout `metadata.toml` and `particles.csv` share no stem, so that trick no longer applies.
    for t in indices
        toml_path = _generationArtifact(gen_dir, t, :metadata)
        isnothing(toml_path) && continue
        d = TOML.parsefile(toml_path)
        csv_path = _generationArtifact(gen_dir, t, :particles)
        n_acc = isnothing(csv_path) ?
                round(Int, d["acceptance_rate"] * d["n_evaluations"]) :
                nrow(CSV.read(csv_path, DataFrame; select=[:weight]))
        push!(ts, t)
        #! Pre-rename runs wrote this as "epsilon"; read either spelling so they still load.
        push!(epsilons, get(d, "max_epsilon_accepted", get(d, "epsilon", NaN)))
        push!(thresholds, get(d, "epsilon_threshold", nothing))
        push!(acceptance_rates, d["acceptance_rate"]); push!(n_accepteds, n_acc)
        push!(esss, d["ess"]); push!(ess_fractions, d["ess"] / n_acc)
        push!(n_evaluationss, d["n_evaluations"])
    end
    df = DataFrame(t=ts, max_epsilon_accepted=epsilons, epsilon_threshold=thresholds,
                   acceptance_rate=acceptance_rates,
                   n_accepted=n_accepteds, ess=esss, ess_fraction=ess_fractions,
                   n_evaluations=n_evaluationss)
    return ConvergenceSummary(df)
end

################## _cdfParams / _targetParams ##################

# Return accepted particles for generation t as CDF coordinates (values in [0,1]).
function _cdfParams(result::ABCResult; generation::Union{Int,Symbol}=:final)
    isempty(result.generations) && error("No generations in ABCResult.")
    t = generation === :final ? length(result.generations) : Int(generation)
    1 <= t <= length(result.generations) || throw(ArgumentError(
        "Generation $t is out of range [1, $(length(result.generations))]."))
    return copy(result.generations[t].particles)
end

# Return accepted particles for generation t in target-parameter space.
function _targetParams(result::ABCResult; generation::Union{Int,Symbol}=:final)
    df, _ = posterior(result; generation=generation)
    return df
end
