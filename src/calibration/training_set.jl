export exportTrainingSet, TrainingSet

"""
    TrainingSet

What [`exportTrainingSet`](@ref) produced: where it is, how big it is, and which columns are which.

# Fields
- `calibration`: the [`Calibration`](@ref) whose folder holds the export, so the run is queryable and
  deletable like any other.
- `path`: the `training_set/` directory.
- `n_rows`: parameter sets with at least one successful simulation, i.e. rows written.
- `n_failed`: parameter sets that produced no usable summary and were left out.
- `column_groups`: which CSV columns are latent coordinates, which are interpretable parameter values,
  and which are summary statistics.
"""
struct TrainingSet
    calibration::Calibration
    path::String
    n_rows::Int
    n_failed::Int
    column_groups::NamedTuple{(:latent, :parameters, :summaries),
                              Tuple{Vector{String},Vector{String},Vector{String}}}
end

function Base.show(io::IO, ts::TrainingSet)
    println(io, "TrainingSet (Calibration ID=$(ts.calibration.id)):")
    println(io, "  Path:       ", ts.path)
    println(io, "  Rows:       ", ts.n_rows, ts.n_failed > 0 ? "  ($(ts.n_failed) failed, omitted)" : "")
    println(io, "  Latent:     ", join(ts.column_groups.latent, ", "))
    println(io, "  Parameters: ", join(ts.column_groups.parameters, ", "))
    print(io,   "  Summaries:  ", join(ts.column_groups.summaries, ", "))
end

#! A summary statistic is whatever the user's function returns, and the training set needs flat named
#! numbers. Dict keys are sorted so the column order is deterministic across runs — otherwise two
#! exports of the same problem could disagree on column order and a consumer reading by position would
#! silently mismatch.
"""
    _flattenSummary(x, base="value") → Vector{Pair{String,Float64}}

Flatten a summary-statistic value into named `Float64` columns.
"""
_flattenSummary(x::Real, base::AbstractString="value") = [String(base) => Float64(x)]
_flattenSummary(x::Bool, base::AbstractString="value") = [String(base) => Float64(x)]

function _flattenSummary(x::AbstractDict, base::AbstractString="value")
    out = Pair{String,Float64}[]
    for k in sort(collect(keys(x)); by=string)
        append!(out, _flattenSummary(x[k], "$(base).$(k)"))
    end
    return out
end

function _flattenSummary(x::AbstractVector, base::AbstractString="value")
    out = Pair{String,Float64}[]
    for (i, v) in enumerate(x)
        append!(out, _flattenSummary(v, "$(base).$(i)"))
    end
    return out
end

function _flattenSummary(x::NamedTuple, base::AbstractString="value")
    out = Pair{String,Float64}[]
    for k in keys(x)
        append!(out, _flattenSummary(getfield(x, k), "$(base).$(k)"))
    end
    return out
end

_flattenSummary(x, base::AbstractString="value") = throw(ArgumentError(
    "A summary statistic must flatten to numbers for a training set; got $(typeof(x)) at \"$(base)\". " *
    "Supported: Real, Bool, AbstractDict, AbstractVector and NamedTuple of those."))

#! Deliberately `LHSVariation` only, not the `Union{LHSVariation,SobolVariation}` the plan proposed.
#! Only those two carry a `cdfs` field at all, but Sobol's is `(latent, sample, design_matrix)` with
#! `variation_ids` shaped `(n, n_matrices)`: its samples are structured into the A/B/AB matrices the
#! Sobol index estimator needs, not a flat design. Flattening them into one training table mixes those
#! roles, which is a modelling decision rather than a formatting one, so it is left for whoever wants it.
"""
    exportTrainingSet(problem::CalibrationProblem; n, kwargs...) → TrainingSet

Simulate a space-filling design over `problem`'s priors and write the parameters and their summary
statistics to disk, as training data for an amortized inference method.

The export is deliberately consumer-agnostic: CSV plus a TOML manifest, the same shapes the calibration
folder already uses, readable by Python BayesFlow, `NeuralEstimators.jl` and `InvertibleNetworks.jl`
alike, and needing no new dependency here.

Offline training on one fixed pre-simulated design is the documented recommendation for expensive
simulators, so this is the intended path rather than a compromise; the sequential variants are what
need simulation on demand.

# Arguments
- `problem`: supplies the inputs, the priors to sample, the replicate count, and the
  `summary_statistic` whose output becomes the training targets. Its `distance` and `observed_data`
  are unused — a training set is not compared to anything.

# Keywords
- `n`: number of parameter sets.
- `design`: `MonteCarloVariation(n)` by default — independent prior draws, because amortized neural
  posterior estimation's objective is an expectation under the prior and its calibration diagnostics
  assume independent joint draws. `LHSVariation(n; add_noise=true)` covers the space better per
  simulation but makes those diagnostics invalid; pass it when coverage matters more.
- `granularity`: `:monad` (default) writes one row per parameter set with the replicates combined;
  `:simulation` writes one row per surviving simulation.

  **Match this to your observed data.** A network learns `q(θ|x)` for the x-distribution it was
  trained on, so the training input must be distributed like the observation it will be conditioned
  on. If your data is a single realization, use `:simulation`; if it is a mean of `m` samples, use
  `:monad` with `n_replicates == m`. Training on 10-replicate means and then conditioning on one noisy
  observation gives tight posteriors in the wrong place — overconfidence, the worst failure available.

  `:monad` is the default only because it works with any summary statistic. `:simulation` needs
  `qoi=` — a [`QoI`](@ref), or several — because a `CalibrationProblem`'s `summary_statistic` is a
  monad-level function by contract, and a QoI handed to that constructor is converted into one, so the
  QoI is not recoverable from the problem. It is the statistically better choice whenever your
  observations are single realizations.
- `qoi`: the QoI(s) to evaluate per simulation, required by `granularity=:simulation` and unused
  otherwise. At that granularity there is one value per row and nothing to combine, so a QoI's
  `reduce` is bypassed — the same asymmetry the post-processing sink has.

  Note `:simulation` rows have one row per *surviving* replicate, so a partially-failed monad
  contributes fewer. That matters if a consumer wants BayesFlow's set-valued shape
  `(n_simulations, n_observations, n_dim)`, which requires a fixed observation count per parameter
  set — check `n_success` is constant before reshaping.
- `description`, `tags`: recorded on the underlying `Calibration`, as for `runCalibration`.
- `run_kwargs`, `progress`, `on_monad_failure`: as for `runCalibration`.

# Output
`training_set/` beside `generations/`:
- `training_set.csv` — one row per parameter set: `monad_id`, `n_success` (replicates that actually
  succeeded, which is the precision of that row's summary and need not be the same for every row), then
  three prefixed groups —
  `cdf.*` (latent coordinates in `(0, 1)`), `target.*` (the same parameters as model values), and
  `summary.*` (the flattened summary statistics). The prefixes exist because a parameter's latent and
  target names are otherwise identical, and they let a consumer tell the two spaces apart unaided.
- `manifest.toml` — which columns belong to which group, plus `n`, the design, the granularity, and how
  many sets failed. It also records the mapping onto BayesFlow v2's adapter roles, whose conventional
  dictionary keys are `inference_variables` (the parameters to infer), `summary_variables` (data passed
  through a summary network) and `inference_conditions` (data passed straight to the inference network).
  Offline training there is `workflow.fit_offline(data=...)`, taking a dict of named batch-first arrays,
  which is what these columns become.

`cdf.*` is the better inference target of the two parameter groups: bounded in `(0, 1)` and comparably
scaled, where `target.*` may span orders of magnitude. Sample in latent space and push the draws back
through the prior quantile to read them in model units.

# Example
```julia
prob = CalibrationProblem(spec, observed, summarize, mseDistance)
ts   = exportTrainingSet(prob; n=2000)
```
"""
function exportTrainingSet(problem::CalibrationProblem;
                           n::Integer,
                           design::Union{LHSVariation,MonteCarloVariation}=MonteCarloVariation(Int(n)),
                           granularity::Symbol=:monad,
                           qoi::Union{Nothing,QoI,AbstractVector{QoI}}=nothing,
                           description::String="",
                           tags=(),
                           run_kwargs::NamedTuple=(;),
                           progress::Symbol=:auto,
                           on_monad_failure::Symbol=:reject)
    n > 0 || throw(ArgumentError("n must be positive; got $(n)."))
    granularity in (:simulation, :monad) || throw(ArgumentError(
        "granularity must be :simulation or :monad; got :$(granularity)."))
    #! `CalibrationProblem` converts a `QoI` to a plain monad-level function at construction, so the
    #! QoI itself is not recoverable from `problem.summary_statistic`. Per-simulation rows therefore
    #! need it passed explicitly rather than reached for through that boundary.
    granularity === :monad || !isnothing(qoi) || throw(ArgumentError(
        "granularity=:simulation needs `qoi=` — the QoI to evaluate on each simulation. A " *
        "`CalibrationProblem`'s `summary_statistic` is a monad-level function by contract (a QoI " *
        "passed to the constructor is converted to one), so it cannot be applied to a single " *
        "simulation. Pass the same QoI here, or use granularity=:monad."))
    verbosity = _resolveVerbosity(progress)
    _validateEvaluationFailurePolicy(on_monad_failure)
    refreshProvenance!()

    #! Free-text `method` column, so a training-set run needs no schema change and is visible to
    #! `calibrationsTable`, `findTrials` and `deleteCalibration` like any other run.
    calibration = createCalibration("training-set"; description=description)
    tag!(calibration, tags...)
    tagReserved!(calibration, ["mm:method" => "TrainingSet"])
    _saveProblem(calibration, problem)
    _writeParametersTOML(calibration, problem.parameters)

    cps = problem.parameters
    pv  = ParsedVariations(problem)
    result = addVariations(design, problem.inputs, pv, problem.reference_variation_id)
    cdfs = result.cdfs                      # (latent dimension, sample)
    variation_ids = result.variation_ids

    #! The design is the training input, so a coordinate outside the open unit interval would mean a
    #! prior quantile at an endpoint — an infinite parameter value for an unbounded prior. Caught here
    #! rather than as a strange row in the CSV.
    all(0 .< cdfs .< 1) || throw(ArgumentError(
        "The design produced CDF coordinates outside (0, 1), which map to prior endpoints. " *
        "This is a bug in the sampling design; please report it."))

    sampling = Sampling(problem.inputs, variation_ids;
                        n_replicates=problem.n_replicates, use_previous=true)
    monads = monadIDs(sampling)

    #! Snapshot before running: a monad whose simulations all fail is deleted along with its
    #! constituent CSV, so afterwards there is no way to ask which simulations it had.
    sim_ids_before = Dict{Int,Vector{Int}}(mid => constituentIDs(Monad, mid) for mid in monads)

    _verbosityRank(verbosity) >= _verbosityRank(:generation) &&
        @info "Training set: simulating $(length(monads)) parameter set" *
              "$(length(monads) == 1 ? "" : "s") × $(problem.n_replicates) replicate" *
              "$(problem.n_replicates == 1 ? "" : "s")."
    run(sampling; run_kwargs..., quiet=true)

    _, _, without_success = _batchOutcome(sim_ids_before)

    #! How many replicates actually succeeded, per monad — not how many were created. A summary
    #! averaged over 2 survivors is noisier than one averaged over 10, and a consumer training on
    #! these rows has to know that: the input noise level is what the network calibrates against, so
    #! unequal replicate counts across rows silently mean unequal precision. `_batchOutcome` reports
    #! which monads failed entirely but no per-monad counts, so they are computed here.
    completed_id = statusCodeID("Completed")
    all_statuses = _simulationStatusIDs(reduce(vcat, values(sim_ids_before); init=Int[]))
    n_success_by_monad = Dict{Int,Int}(
        mid => count(sid -> get(all_statuses, sid, -1) == completed_id, sids)
        for (mid, sids) in sim_ids_before)

    #! Prefixed, because the two groups otherwise collide: for a `DistributedVariation` both
    #! `latent_parameter_names` and `_displayColumns` are `[variationName(dv)]`, so an unprefixed merge
    #! silently dropped every CDF column in favour of the target value under the same key. The prefixes
    #! also tell a consumer which space a column is in without consulting the manifest.
    latent_names = ["cdf." * nm for nm in vcat([cp.lv.latent_parameter_names for cp in cps]...)]
    param_names  = ["target." * nm for nm in vcat([_displayColumns(cp) for cp in cps]...)]

    rows = NamedTuple[]
    summary_names = String[]
    n_failed = 0
    for (j, mid) in enumerate(monads)
        if mid in without_success
            n_failed += 1
            continue
        end
        #! One row per surviving simulation, or one per parameter set. The distinction is not a
        #! formatting preference: a network learns `q(θ|x)` for the x-distribution it was trained on,
        #! so the training input must be distributed like the observation it will be conditioned on.
        #! Train on 10-replicate means and feed a single noisy observation and the posteriors come out
        #! tight and wrong — overconfident, which is the worst failure mode available.
        per_sim_ids = granularity === :simulation ? _successfulSimIDs(all_statuses, sim_ids_before[mid],
                                                                     completed_id) : Int[]
        qois = isnothing(qoi) ? QoI[] : (qoi isa QoI ? QoI[qoi] : collect(qoi))
        summaries = try
            granularity === :monad ? [problem.summary_statistic(mid)] :
                                     [Dict{String,Any}(q.name => _computeOn(q, sid) for q in qois)
                                      for sid in per_sim_ids]
        catch e
            throw(ErrorException(
                "Training set: the summary statistic failed on monad $(mid) at granularity " *
                ":$(granularity). A summary that cannot be computed where simulations succeeded is a " *
                "bug in the summary function, not a sampling outcome.\n$(sprint(showerror, e))"))
        end
        flats = [_flattenSummary(sm, "summary") for sm in summaries]
        isempty(flats) && continue
        flat = first(flats)
        if isempty(summary_names)
            summary_names = first.(flat)
        elseif first.(flat) != summary_names
            throw(ArgumentError(
                "Training set: `summary_statistic` produced different column names for different " *
                "parameter sets ($(summary_names) then $(first.(flat))). Every row must share a " *
                "schema for the export to be a table."))
        end
        cdf_col = cdfs[:, j]
        disp = vcat([_particleRowToDisplay(cp, collect(cdf_col[_latentRange(cps, i)]))
                     for (i, cp) in enumerate(cps)]...)
        ids = granularity === :monad ? [0] : per_sim_ids
        for (k, fl) in enumerate(flats)
            first.(fl) == summary_names || throw(ArgumentError(
                "Training set: the summary statistic produced different column names for different " *
                "rows ($(summary_names) then $(first.(fl))). Every row must share a schema."))
            row = merge(
                (monad_id = mid, simulation_id = ids[k], n_success = n_success_by_monad[mid]),
                NamedTuple{Tuple(Symbol.(latent_names))}(Tuple(Float64.(cdf_col))),
                NamedTuple{Tuple(Symbol.(param_names))}(Tuple(Float64.(disp))),
                NamedTuple{Tuple(Symbol.(summary_names))}(Tuple(last.(fl))),
            )
            push!(rows, row)
        end
    end

    all_names = vcat(["monad_id", "n_success"], latent_names, param_names, summary_names)
    length(unique(all_names)) == length(all_names) || throw(ArgumentError(
        "Training set: duplicate column names $(all_names[nonunique(DataFrame(n=all_names), [:n])]) — " *
        "a parameter or summary name collides with another column, which would silently drop one of " *
        "them. Rename the offending variation or summary key."))

    isempty(rows) && error(
        "Training set: no parameter set produced a usable summary. All $(length(monads)) failed, " *
        "which is a broken model rather than sampling noise.")

    dir = joinpath(calibrationFolder(calibration), "training_set")
    mkpath(dir)
    csv_path = joinpath(dir, "training_set.csv")
    CSV.write(csv_path, DataFrame(rows))

    groups = (latent = latent_names, parameters = param_names, summaries = summary_names)
    open(joinpath(dir, "manifest.toml"), "w") do io
        TOML.print(io, Dict{String,Any}(
            "n_requested"   => Int(n),
            "n_rows"        => length(rows),
            "n_failed"      => n_failed,
            "n_replicates"  => problem.n_replicates,
            "granularity"   => String(granularity),
            "design"        => string(nameof(typeof(design))),
            #! The column groups map onto BayesFlow v2's adapter roles, which are the conventional
            #! dictionary keys `inference_variables`, `summary_variables` and `inference_conditions`.
            #! Recording the mapping here means a consumer does not have to infer it from prefixes.
            "bayesflow"     => Dict{String,Any}(
                "inference_variables" => latent_names,
                "summary_variables"   => summary_names,
                "note" => "cdf.* are the inference targets in latent space, bounded in (0,1) and " *
                          "comparably scaled; target.* are the same parameters in model units. " *
                          "Transform samples back through the prior quantile to read them in model " *
                          "units. Offline training is workflow.fit_offline(data=...), where data is " *
                          "a dict of named batch-first arrays.",
            ),
            "columns"       => Dict{String,Any}(
                "latent"     => latent_names,
                "parameters" => param_names,
                "summaries"  => summary_names,
            ),
        ); sorted=true)
    end

    n_failed > 0 && @warn "Training set: $(n_failed) of $(length(monads)) parameter sets produced no " *
                          "successful simulation and were omitted. Their simulations' output folders " *
                          "survive for inspection."
    return TrainingSet(calibration, dir, length(rows), n_failed, groups)
end

#! Each calibration parameter owns a contiguous slice of the latent vector, in the order the parameters
#! were given — the same flattening `_runABCSMC` relies on.
function _latentRange(cps::Vector{CalibrationParameter}, i::Int)
    start = 1
    for k in 1:(i - 1)
        start += length(cps[k].lv.latent_parameter_names)
    end
    return start:(start + length(cps[i].lv.latent_parameter_names) - 1)
end

#! The simulations that actually completed, in the monad's own order.
_successfulSimIDs(statuses::AbstractDict, sim_ids, completed_id) =
    [Int(sid) for sid in sim_ids if get(statuses, sid, -1) == completed_id]


