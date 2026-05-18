export CalibrationProblem, Calibration, GenerationResult, ABCResult, posterior, ConvergenceSummary

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
- `summary_statistic::Function`: `(monad_id::Int) → T` for any `T` accepted by `distance`
  as its first argument. Called once per proposed particle. The user controls how to
  aggregate over `simulationIDs(Monad, monad_id)` (e.g. averaging, taking a single
  replicate).
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

observed = Dict("default" => 100.0)
problem = CalibrationProblem(
    ref,
    [DistributedVariation(:config, xml_path, Uniform(1e-7, 1e-4))],
    observed,
    monad_id -> endpointPopulationCounts(monad_id),
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
    summary_statistic::Function
    distance::Function
    n_replicates::Int
    reference_variation_id::VariationID
end

function CalibrationProblem(inputs::InputFolders, parameters::AbstractVector,
                             observed_data,
                             summary_statistic, distance;
                             n_replicates::Int=1,
                             reference_variation_id::VariationID=VariationID(inputs))
    cps = CalibrationParameter[_toCalibrationParameter(av) for av in parameters]
    return CalibrationProblem(inputs, cps, observed_data,
                              summary_statistic, distance, n_replicates, reference_variation_id)
end

function CalibrationProblem(ref::AbstractMonad, parameters::AbstractVector,
                             observed_data,
                             summary_statistic, distance; n_replicates::Int=1)
    cps = CalibrationParameter[_toCalibrationParameter(av) for av in parameters]
    return CalibrationProblem(ref.inputs, cps, observed_data,
                              summary_statistic, distance, n_replicates, ref.variation_id)
end

################## Calibration ##################

"""
    Calibration

Represents a calibration run tracked in the database.

Created automatically by [`runABC`](@ref). The associated output folder at
`data/outputs/calibrations/{id}/` contains:
- `generations/generation_{NNN}_monads.csv`: monad IDs evaluated per generation (written
  before each batch for crash safety).
- `generations/generation_{NNN}.csv`: human-readable per-generation results — target
  parameter values (and latent parameter samples for user-supplied `LatentVariation`s),
  weights, distances, and monad IDs.
- `generations/generation_{NNN}.toml`: generation-level metadata (epsilon,
  acceptance_rate, ess, n_evaluations).
- `generations/generation_cdfs/generation_{NNN}.csv`: raw CDF coordinates for each accepted particle;
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
- `epsilon::Float64`: Maximum distance among accepted particles (≤ the threshold used).
- `n_evaluations::Int`: Total proposals evaluated, including rejected ones.
- `monad_ids::Vector{Int}`: Monad IDs for each accepted particle.
- `acceptance_rate::Float64`: Fraction of proposals that passed the epsilon threshold
  (`n_accepted_total / n_evaluations`). When `accept_overflow=false`, this equals
  `length(distances) / n_evaluations`; when `accept_overflow=true`, it may be slightly
  higher because overflow particles are counted but `n_evaluations` includes the full batch.
- `ess::Float64`: Effective sample size, `1 / Σwᵢ²`. Equals `population_size` when
  weights are uniform (generation 1) and decreases as weights concentrate.
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
    epsilon::Float64
    n_evaluations::Int
    monad_ids::Vector{Int}
    acceptance_rate::Float64
    ess::Float64
    rejected_proposals::Union{Nothing,DataFrame}
end

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

# Examples
```julia
result = runABC(problem)
df, weights = posterior(result)                # final generation, target-value format
df, weights = posterior(result; generation=2)  # specific generation
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
    isempty(result.generations) && error("No generations in ABCResult — calibration may not have completed.")
    t = generation === :final ? length(result.generations) : Int(generation)
    1 <= t <= length(result.generations) || throw(ArgumentError(
        "Generation $t is out of range [1, $(length(result.generations))]."
    ))
    gen = result.generations[t]
    display_df = _buildDisplayDF(gen, result.parameters)
    return display_df, gen.weights
end

"""
    posterior(calibration::Calibration; generation::Union{Int,Symbol}=:final)

Extract posterior samples directly from disk for a completed calibration run.

Reads the human-readable `generations/generation_{NNN}.csv` file for the requested
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
    gen_dir = joinpath(calibrationFolder(calibration), "generations")
    isdir(gen_dir) || error(
        "No generations directory found for Calibration($(calibration.id)). " *
        "Has the calibration been run?")

    # All generation_NNN.csv files (exclude _monads files)
    all_names = readdir(gen_dir)
    csv_names = sort(filter(f -> occursin(r"^generation_\d+\.csv$", f), all_names))
    isempty(csv_names) && error(
        "No completed generations found for Calibration($(calibration.id)).")

    t = generation === :final ? length(csv_names) : Int(generation)
    1 <= t <= length(csv_names) || throw(ArgumentError(
        "Generation $t is out of range [1, $(length(csv_names))]."))

    df = CSV.read(joinpath(gen_dir, csv_names[t]), DataFrame)
    weights    = df[!, :weight]
    display_df = select(df, Not([:weight, :distance, :monad_id]))
    return display_df, weights
end

################## ConvergenceSummary ##################

"""
    ConvergenceSummary(result::ABCResult)
    ConvergenceSummary(cal::Calibration)

Per-generation convergence table for an ABC-SMC run. Supports
`plot(ConvergenceSummary(result))` via the RecipesBase recipe in `visualize.jl`,
and behaves like a DataFrame for property access (`cs.epsilon`, etc.).

# Columns
- `t`: Generation index.
- `epsilon`: Maximum accepted distance.
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
        epsilon         = [g.epsilon                 for g in result.generations],
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
    toml_files = sort(filter(f -> occursin(r"^generation_\d+\.toml$", f), readdir(gen_dir)))
    isempty(toml_files) && error("No generation metadata found for Calibration($(cal.id)).")

    ts = Int[]; epsilons = Float64[]; acceptance_rates = Float64[]
    n_accepteds = Int[]; esss = Float64[]; ess_fractions = Float64[]
    n_evaluationss = Int[]

    for (t, fname) in enumerate(toml_files)
        d = TOML.parsefile(joinpath(gen_dir, fname))
        csv_path = joinpath(gen_dir, replace(fname, ".toml" => ".csv"))
        n_acc = isfile(csv_path) ?
                nrow(CSV.read(csv_path, DataFrame; select=[:weight])) :
                round(Int, d["acceptance_rate"] * d["n_evaluations"])
        push!(ts, t); push!(epsilons, d["epsilon"])
        push!(acceptance_rates, d["acceptance_rate"]); push!(n_accepteds, n_acc)
        push!(esss, d["ess"]); push!(ess_fractions, d["ess"] / n_acc)
        push!(n_evaluationss, d["n_evaluations"])
    end
    df = DataFrame(t=ts, epsilon=epsilons, acceptance_rate=acceptance_rates,
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
