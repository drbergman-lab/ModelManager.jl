export runABC, resumeABC
using JLD2, Tables, TOML

################## Simulator-agnostic adapter ##################

"""
    _createMonadForParams(problem, latent_cdfs) → Monad

Create a Monad at the given parameter values. `latent_cdfs` maps each latent parameter name
to its CDF value (drawn by the ABC-SMC algorithm). Each `CalibrationParameter` in
`problem.parameters` converts those CDF values into concrete target `DiscreteVariation`s
via its `lv`'s maps. Uses `use_previous=true` so that exact-match reuse of existing
simulations happens transparently.
"""
function _createMonadForParams(problem::CalibrationProblem, latent_cdfs::Dict{String,Float64})
    avs = AbstractVariation[]
    for cp in problem.parameters
        lv = cp.lv
        cdfs = [latent_cdfs[name] for name in lv.latent_parameter_names]
        target_vals = variationValues(lv, cdfs)
        for (loc, tar, val, typ) in zip(lv.locations, lv.targets, target_vals, lv.types)
            push!(avs, DiscreteVariation(loc, tar, typ(val)))
        end
    end
    add_result = addVariations(GridVariation(), problem.inputs, avs, problem.reference_variation_id)
    variation_id = add_result.variation_ids[1]
    return Monad(problem.inputs, variation_id; n_replicates=problem.n_replicates, use_previous=true)
end

"""
    _simulationStatusIDs(simulation_ids) → Dict{Int,Int}

Map each of `simulation_ids` to its `status_code_id` in the `simulations` table, in one query.
Simulations absent from the table are absent from the result.
"""
function _simulationStatusIDs(simulation_ids::AbstractVector{<:Integer})
    isempty(simulation_ids) && return Dict{Int,Int}()
    df = constructSelectQuery("simulations",
                              "WHERE simulation_id IN ($(join(unique(simulation_ids), ",")))";
                              selection="simulation_id, status_code_id") |> queryToDataFrame
    return Dict{Int,Int}(Int(row.simulation_id) => Int(row.status_code_id) for row in eachrow(df))
end

"""
    _batchOutcome(sim_ids_by_monad) → (failed_simulations, failed_monads, without_success)

Classify a batch's simulations after it has run. `sim_ids_by_monad` maps each monad ID to its
simulation IDs as snapshotted *before* the batch ran — the snapshot is essential, since a monad
whose every simulation fails is deleted along with the constituent CSV that lists them.

Returns three sorted ID vectors: every simulation now marked `Failed`, every monad with at
least one such simulation, and every monad with **no** `Completed` simulation. The last is what
matters for evaluation: a monad with no successful simulation has no output for
`summary_statistic` to read, so it is rejected (or fatal) rather than handed to user code.

Every snapshotted simulation must have a row in the `simulations` table — they were listed by a
monad's constituent record moments earlier, and the runner only ever *updates* their status.
A missing row means the constituent records and the database disagree, so this errors rather than
guessing a status: silently treating an absent simulation as "not completed" would reject a
healthy particle, and as "not failed" would hide a real failure.
"""
function _batchOutcome(sim_ids_by_monad::AbstractDict{Int,<:AbstractVector{<:Integer}})
    all_sim_ids  = reduce(vcat, values(sim_ids_by_monad); init=Int[])
    statuses     = _simulationStatusIDs(all_sim_ids)
    completed_id = statusCodeID("Completed")
    failed_id    = statusCodeID("Failed")

    unknown = setdiff(all_sim_ids, keys(statuses))
    isempty(unknown) || error("""
    Calibration cannot classify this batch: simulation(s) $(_compressedIDStr(sort(unknown))) are \
    listed as constituents of monad(s) \
    $(_compressedIDStr(sort([mid for (mid, sids) in sim_ids_by_monad
                             if any(in(unknown), sids)]))) but have no row in the `simulations` \
    table.
    The constituent records and the database disagree; run \
    `ModelManager.databaseDiagnostics()` (or inspect the monads' constituent CSVs) before \
    continuing.
    """)

    failed_simulations = Int[]
    failed_monads      = Int[]
    without_success    = Int[]
    for (monad_id, sim_ids) in sim_ids_by_monad
        failed = [sid for sid in sim_ids if statuses[sid] == failed_id]
        append!(failed_simulations, failed)
        isempty(failed) || push!(failed_monads, monad_id)
        any(sid -> statuses[sid] == completed_id, sim_ids) || push!(without_success, monad_id)
    end
    return sort!(failed_simulations), sort!(failed_monads), sort!(without_success)
end

"""
    _buildEvaluateBatch(problem, calibration, max_nr_populations, run_kwargs) → Function

Build the `evaluate_batch` callback expected by `_runABCSMC`. The returned function:

1. Takes `(t::Int, proposals::Vector{Tuple{Dict{String,Float64}, Union{Nothing,Int}}})` —
   generation index and one `(latent_cdfs, known_mid)` pair per proposed particle.
   `known_mid` is an `Int` for bank/mid-generation reuses (monad already in DB) and
   `nothing` for fresh grid snaps (monad created here).
2. Creates or retrieves a `Monad` for each proposal: known-mid proposals use
   `Monad(mid; ...)` (one SELECT); nothing-mid proposals use `_createMonadForParams`
   (INSERT OR IGNORE + SELECT).
3. Records all monad IDs evaluated so far in this generation to `generations/{t}/monads.csv`
   using `compressIDs` **before** launching simulations (crash safety). The file is
   overwritten on each batch call so it always contains a single fully-compressed entry
   spanning all batches in the generation.
4. Assembles all monads into a `Sampling` and calls `run(sampling; quiet=true, run_kwargs...)`.
   When `verbosity` is `:batch` or higher a batch-start line is logged; when it is `:bar`
   a live per-simulation progress bar is rendered via the runner's `on_progress` hook.
5. Classifies the outcome (see `_batchOutcome`) and records any failed simulation and
   monad IDs to the generation's failure files (see `_recordBatchFailures`).
6. Returns a `Vector{Tuple{Union{Float64,Missing},Int}}` (distance, monad_id) in proposal order.
   A `missing` distance means the monad had no successful simulation, so no distance exists —
   distinct from any value the user's `distance` function could return.

`verbosity` is a resolved level (see `_resolveVerbosity`); a per-generation batch
counter is maintained across calls so batch milestones can be numbered within each generation.

# Monads with no successful simulation
A monad whose simulations all fail has no output for `summary_statistic` to read — and the
runner has by then deleted the emptied monad, so even `Monad(monad_id)` throws. Such monads are
detected from the database *before* any user code runs, and `on_monad_failure` decides:

- `:reject` (default) — the particle's distance is `missing`, which ABC-SMC treats as "never
  accept", and the run continues. `missing` rather than a sentinel like `Inf` so that a failed
  monad is unambiguous: `Inf` is a value a user's `distance` may legitimately return.
- `:error` — the run stops with a message pointing at the generation's failure files.

Partially failed monads (at least one success) are evaluated normally from whatever succeeded;
their failed simulations are still recorded. Re-running to "top off" the missing replicates is
deliberately not attempted.
"""
function _buildEvaluateBatch(problem::CalibrationProblem, calibration::Calibration,
                              max_nr_populations::Int, run_kwargs::NamedTuple=(;);
                              verbosity::Symbol=:generation,
                              on_monad_failure::Symbol=:reject)
    _validateEvaluationFailurePolicy(on_monad_failure)
    batch_counts       = Dict{Int,Int}()
    warned_generations = Set{Int}()

    function evaluate_batch(t::Int,
                             proposals::Vector{Tuple{Dict{String,Float64}, Union{Nothing,Int}}})
        batch_index = get(batch_counts, t, 0) + 1
        batch_counts[t] = batch_index
        _logBatchStart(verbosity, t, batch_index, length(proposals))

        monads = map(proposals) do (latent_cdfs, known_mid)
            if isnothing(known_mid)
                _createMonadForParams(problem, latent_cdfs)
            else
                Monad(known_mid; n_replicates=problem.n_replicates, use_previous=true)
            end
        end

        _appendCompressedIDs(_generationMonadsPath(calibration, t, max_nr_populations),
                             [monad.id for monad in monads])

        #! Snapshot each monad's simulation IDs *before* running: a monad whose every
        #! simulation fails is deleted along with its constituent CSV, after which its
        #! simulation IDs — the only pointer to the output folders holding the failure
        #! diagnostics — cannot be recovered.
        sim_ids_before = Dict(monad.id => simulationIDs(monad) for monad in monads)

        sampling = Sampling(monads, problem.inputs)
        #! Labels the batch so a monad can be traced back to the calibration and generation
        #! that proposed it without consulting the per-generation CSVs — which do not
        #! survive a monad deletion. Its monads match through inheritance.
        tagReserved!(sampling, ["mm:calibration" => string(calibration.id), "mm:generation" => string(t)])
        on_progress = _batchProgressCallback(verbosity, "  gen $t batch $batch_index ")
        run(sampling; quiet=true, on_progress=on_progress, run_kwargs...)

        failed_simulations, failed_monads, without_success = _batchOutcome(sim_ids_before)
        _recordBatchFailures(calibration, t, max_nr_populations, verbosity, warned_generations,
                             failed_simulations, failed_monads)
        failed_set = Set(failed_simulations)
        no_success = Set(without_success)

        return Tuple{Union{Float64,Missing},Int}[
            if monad.id in no_success
                on_monad_failure === :error &&
                    _throwNoSuccessfulSimulations(calibration, t, max_nr_populations, monad.id,
                                                  sim_ids_before[monad.id])
                (missing, monad.id)
            else
                (_evaluateParticle(problem, monad.id,
                                   count(in(failed_set), sim_ids_before[monad.id])),
                 monad.id)
            end
            for monad in monads]
    end
    return evaluate_batch
end

"""
    _evaluateParticle(problem, monad_id, n_failed_simulations) → Float64

Compute one particle's distance by calling the user's `summary_statistic` and `distance` on a
monad that has at least one successful simulation.

Both calls are user code, so both are guarded — but neither failure is recoverable: the monad
*does* have output, so an exception (or a `distance` return value that is not a `Real`) is a
fault in the user's functions, not a simulation failure. Either way the run stops with the monad
ID named, rather than propagating a `missing`/`nothing` into the ABC-SMC internals where it
surfaces much later as an unrelated `MethodError`. `n_failed_simulations` is reported when
non-zero, since a partially failed monad is the likeliest reason otherwise-correct user code
trips here.
"""
function _evaluateParticle(problem::CalibrationProblem, monad_id::Int, n_failed_simulations::Int)
    partial_note = n_failed_simulations == 0 ? "" :
        "\nNote that $n_failed_simulations of this monad's simulations failed, so any output " *
        "they would have produced is missing."
    distance = try
        simulated = problem.summary_statistic(monad_id)
        problem.distance(simulated, problem.observed_data)
    catch
        @error """
        Calibration failed while evaluating monad $monad_id: `summary_statistic` or `distance` \
        raised. This monad has at least one successful simulation, so the fault is in those \
        functions rather than in the simulations.$partial_note
        """
        rethrow()
    end
    distance isa Real || error("""
    Calibration failed while evaluating monad $monad_id: `distance` returned a \
    $(typeof(distance)), but a `Real` is required.$partial_note
    """)
    return Float64(distance)
end

"""
    _validateEvaluationFailurePolicy(policy::Symbol)

Throw an `ArgumentError` unless `policy` is `:reject` or `:error`. Called before any work
begins so a typo fails immediately rather than on the first failed particle.
"""
function _validateEvaluationFailurePolicy(policy::Symbol)
    policy in (:reject, :error) || throw(ArgumentError(
        "Unknown on_monad_failure setting :$policy. Expected :reject or :error."))
    return nothing
end

"""
    _throwNoSuccessfulSimulations(calibration, t, max_nr_populations, monad_id, sim_ids)

Stop the run because monad `monad_id` has no successful simulation, under
`on_monad_failure=:error`. Points at the generation's failure files and at the simulations'
own output folders, which survive even when their monad does not.
"""
function _throwNoSuccessfulSimulations(calibration::Calibration, t::Int, max_nr_populations::Int,
                                       monad_id::Int, sim_ids::AbstractVector{<:Integer})
    folders = isempty(sim_ids) ? "" :
        "\nSimulation output folders:\n" *
        join(["  - $(trialFolder(Simulation, sid))" for sid in sim_ids], "\n")
    error("""
    Calibration stopped: monad $monad_id has no successful simulation, so there is no output for \
    `summary_statistic` to read.
    Failed simulation and monad IDs for generation $t are recorded in
      - $(_failedSimulationsPath(calibration, t, max_nr_populations))
      - $(_failedMonadsPath(calibration, t, max_nr_populations))$folders
    Pass `on_monad_failure=:reject` to reject such particles and continue the run instead.
    """)
end

################## Public API ##################

"""
    _latentNamesAndPriors(cps) → (Vector{String}, Vector)

Flatten the latent parameter names and their priors across all calibration parameters, in order.
"""
_latentNamesAndPriors(cps::Vector{CalibrationParameter}) =
    (vcat([cp.lv.latent_parameter_names for cp in cps]...),
     vcat([cp.lv.latent_parameters      for cp in cps]...))

#! The half that a fresh run and a resume share verbatim. They differ only in what comes *before* —
#! one creates the calibration and writes the run-level files, the other loads them back and decides
#! whether there is anything left to do — so everything from the bank onward lives here once. Keeping
#! it in both was how the two drifted on `max_nr_populations` handling in the first place.
"""
    _executeCalibration(problem, calibration, method, run_kwargs; kwargs...) → ABCResult

Build the bank, batch evaluator and generation callback, run the SMC loop, and wrap the result.
"""
function _executeCalibration(problem::CalibrationProblem, calibration::Calibration,
                             method::ABCSMC, run_kwargs::NamedTuple;
                             verbosity::Symbol,
                             on_monad_failure::Symbol,
                             start_generations::Vector{GenerationResult}=GenerationResult[])
    cps = problem.parameters
    param_names, priors = _latentNamesAndPriors(cps)

    bank           = _buildSimulationBank(problem)
    evaluate_batch = _buildEvaluateBatch(problem, calibration, method.max_nr_populations,
                                         run_kwargs; verbosity=verbosity,
                                         on_monad_failure=on_monad_failure)
    on_generation  = gen -> _saveGeneration(calibration, gen, method.max_nr_populations, cps)

    generations = _runABCSMC(method, param_names, priors, evaluate_batch, on_generation;
                             bank=bank, start_generations=start_generations,
                             verbosity=verbosity)
    return ABCResult(calibration, generations, cps, method)
end

"""
    runCalibration(problem::CalibrationProblem, method::ABCSMC; description="") → ABCResult

Run ABC-SMC calibration. See [`ABCSMC`](@ref) for method settings.

The full `CalibrationProblem` is serialized to `problem.jld2` enabling
`resumeABC(Calibration(id))` with no further arguments. Per-generation results are
saved in two forms:
- `generations/{t}/particles.csv`: human-readable target parameter values.
- `generations/{t}/cdfs.csv`: raw CDF coordinates for exact resume.

# Arguments
- `run_kwargs::NamedTuple=(;)`: forwarded to each `run(sampling; quiet=true, ...)` call.
- `description::String=""`: stored in the `calibrations` DB row.
- `progress::Symbol=:auto`: console-feedback verbosity. One of `:auto`, `:none`,
  `:generation`, `:batch`, `:bar`. `:auto` resolves to `:bar` on an interactive terminal
  and `:generation` otherwise.
- `on_monad_failure::Symbol=:reject`: what to do when a proposed monad has no successful
  simulation, so no distance can be computed for it. `:reject` records the distance as `missing`,
  which ABC-SMC never accepts, and continues; `:error` stops the run. Either way the failed
  simulation and monad IDs are recorded per generation in
  `generations/{t}/failed_simulations.csv` and
  `generations/{t}/failed_monads.csv`.

# Examples
```julia
method = ABCSMC(population_size=200, max_nr_populations=5)
result = runCalibration(problem, method)
df, weights = posterior(result)
```
"""
function runCalibration(problem::CalibrationProblem, method::ABCSMC;
                        description::String="", tags=(), run_kwargs::NamedTuple=(;),
                        progress::Symbol=:auto,
                        on_monad_failure::Symbol=:reject)
    #! Both controls are validated before `createCalibration`, so a typo cannot leave behind a stray
    #! DB row and output folder for a run that never starts.
    verbosity = _resolveVerbosity(progress)
    _validateEvaluationFailurePolicy(on_monad_failure)
    refreshProvenance!()
    calibration = createCalibration("ABC-SMC"; description=description)
    #! Applied before anything is dispatched, so the labels survive an interrupted run and the
    #! calibration is queryable by tag while its simulations are still in flight — the same
    #! reasoning, and the same order, as `run`'s `tags=` keyword.
    tag!(calibration, tags...)
    #! Labels the run itself, mirroring what a sensitivity sweep puts on its sampling. The value is
    #! the method *type*, as it is there, so `findTrials(Calibration; tags=("mm:method" => ...))`
    #! reads the same way across both; the `calibrations.method` column keeps its own
    #! human-facing spelling.
    tagReserved!(calibration, ["mm:method" => string(nameof(typeof(method)))])
    _saveMethod(calibration, method)
    _saveProblem(calibration, problem)
    _writeParametersTOML(calibration, problem.parameters)

    return _executeCalibration(problem, calibration, method, run_kwargs;
                               verbosity=verbosity, on_monad_failure=on_monad_failure)
end

"""
    runABC(problem::CalibrationProblem; method=nothing, kwargs...) → ABCResult

Run ABC-SMC calibration on `problem`, a convenience wrapper over
[`runCalibration`](@ref).

Method settings may be given either as a ready-made [`ABCSMC`](@ref) via `method=`, or as loose
keyword arguments naming its fields — but not both. The loose form forwards to the `ABCSMC`
constructor, so every field it accepts is accepted here, with the same defaults.

# Arguments
- `problem::CalibrationProblem`: the model, parameters, observed data and distance to calibrate.

# Keywords
- `method::Union{Nothing,ABCSMC}=nothing`: the method to run. When `nothing`, one is built from the
  remaining keyword arguments.
- any field of [`ABCSMC`](@ref) — `population_size`, `max_nr_populations`, `minimum_epsilon`,
  `epsilon_quantile`, `perturbation_kernel`, `epsilon_schedule`, `min_acceptance_rate`,
  `min_epsilon_decrease`, `min_ess_fraction`, `accept_overflow`, `cdf_grid_k`, `max_evaluations`,
  `store_rejected` — forwarded to its constructor. See [`ABCSMC`](@ref) for the meaning and default
  of each. An unrecognized keyword raises an `ArgumentError` naming it.
- `description::String=""`: free-text prose stored in the `calibrations` DB row and shown by
  `calibrationsTable`. For labels you intend to search on, prefer `tags`.
- `tags=()`: `key => value` pairs applied to the calibration before any simulation is dispatched, so
  they survive an interrupted run. Queryable with `findTrials(Calibration; tags=...)`.
- `run_kwargs::NamedTuple=(;)`: forwarded to each `run(sampling; ...)` call.
- `progress::Symbol=:auto`: console-feedback verbosity (`:auto`, `:none`, `:generation`, `:batch`,
  `:bar`). `:auto` shows a live progress bar on an interactive terminal and per-generation
  milestones otherwise.
- `on_monad_failure::Symbol=:reject`: what to do when a proposed monad has no successful simulation.
  `:reject` records its distance as `missing` (so the particle is never accepted) and continues;
  `:error` stops the run. Failed simulation and monad IDs are recorded per generation either way, in
  `generations/{t}/failed_simulations.csv` and
  `generations/{t}/failed_monads.csv`.

# Returns
An [`ABCResult`](@ref) holding the calibration, its generations, the parameters and the method.

# Examples
```julia
# Loose keywords
result = runABC(problem; population_size=200, max_nr_populations=5)
df, weights = posterior(result)
println("Posterior mean: ", sum(df[!, "overall/max_time"] .* weights))

# Or a ready-made method, plus labels to find the run again
result = runABC(problem; method=ABCSMC(population_size=200, store_rejected=true),
                tags=("project" => "immune-escape",))

# Resume after a crash
result2 = resumeCalibration(result.calibration)
```
"""
function runABC(problem::CalibrationProblem;
                method::Union{Nothing,ABCSMC}=nothing,
                run_kwargs::NamedTuple=(;),
                description::String="",
                tags=(),
                progress::Symbol=:auto,
                on_monad_failure::Symbol=:reject,
                kwargs...)
    resolved = if isnothing(method)
        _methodFromKeywords(ABCSMC, kwargs)
    else
        isempty(kwargs) || throw(ArgumentError(
            "runABC received both `method=` and method setting(s) " *
            "$(join(keys(kwargs), ", ")). Pass one or the other, not both."))
        method
    end
    return runCalibration(problem, resolved; description=description, tags=tags,
                          run_kwargs=run_kwargs, progress=progress,
                          on_monad_failure=on_monad_failure)
end

#! Derived from `runABC`'s own signature rather than restated: the run controls are exactly its
#! declared keywords that are not `ABCSMC` fields. Adding a run control therefore needs no edit
#! here, and the two can never drift apart. Used only to build the error message below — the guard
#! itself is a `setdiff` against `fieldnames(ABCSMC)`, which was always dynamic.
function _runControlKeywords()
    #! `which`, not `only(methods(...))`. The latter throws "Collection has multiple elements" the
    #! moment `runABC` gains a second method — and it is reached only while *building an error
    #! message*, so the useful diagnostic would be replaced by a confusing one. Naming the
    #! problem-taking method explicitly is stable however many overloads are added later.
    declared = Base.kwarg_decl(which(runABC, Tuple{CalibrationProblem}))
    return Tuple(k for k in declared
                 if !(k in fieldnames(ABCSMC)) && !endswith(String(k), "..."))
end

#! Every method default lives in the `ABCSMC` keyword constructor and nowhere else, so a new field
#! becomes reachable through `runABC` with no edit here. The `setdiff` is what keeps a typo from
#! becoming an opaque `MethodError` inside the constructor.
function _methodFromKeywords(::Type{ABCSMC}, kwargs)
    unknown = setdiff(keys(kwargs), fieldnames(ABCSMC))
    isempty(unknown) || throw(ArgumentError("""
    runABC received unrecognized keyword argument(s): $(join(unknown, ", ")).
    Method settings are the fields of `ABCSMC`: $(join(fieldnames(ABCSMC), ", ")).
    Run controls are: $(join(_runControlKeywords(), ", ")).
    """))
    return ABCSMC(; kwargs...)
end

#! On resume the *saved* method is the base and a keyword patches one field of it. `_methodFromKeywords`
#! cannot serve here: it builds a fresh `ABCSMC`, so every field the caller did not name would revert
#! to a constructor default rather than keeping what the run actually used — which is exactly the trap
#! `method=ABCSMC(max_nr_populations=15)` fell into, silently resetting population size, kernel and
#! both epsilon controls.
"""
    _methodWithOverrides(m::ABCSMC, kwargs) → ABCSMC

Copy of `m` with the fields named in `kwargs` replaced and every other field carried over.
"""
function _methodWithOverrides(m::ABCSMC, kwargs)
    unknown = setdiff(keys(kwargs), fieldnames(ABCSMC))
    isempty(unknown) || throw(ArgumentError("""
    Unrecognized method setting(s) on resume: $(join(unknown, ", ")).
    Method settings are the fields of `ABCSMC`: $(join(fieldnames(ABCSMC), ", ")).
    """))
    return ABCSMC(; (f => get(kwargs, f, getfield(m, f)) for f in fieldnames(ABCSMC))...)
end

#! Resuming with different settings makes `method.toml` wrong about the run it describes, and the next
#! resume would silently revert to it. Rewriting is the honest option — the same reasoning as upgrading
#! a generation TOML on read — and the caller reports which keys moved so the change is never silent.
"""
    _persistEffectiveMethod(calibration, m) → Vector{String}

Write `m` to `method.toml` if it differs from what is stored, returning the names of the keys that
changed (empty when nothing did).
"""
function _persistEffectiveMethod(calibration::Calibration, m::ABCSMC)
    path = joinpath(calibrationFolder(calibration), "method.toml")
    changed = String[]
    if isfile(path)
        stored = TOML.parsefile(path)
        wanted = _methodDict(m)
        for k in union(keys(stored), keys(wanted))
            isequal(get(stored, k, nothing), get(wanted, k, nothing)) || push!(changed, k)
        end
        isempty(changed) && return changed
    end
    _saveMethod(calibration, m)
    return changed
end

################## Method Persistence ##################

# ── Kernel serialization ─────────────────────────────────────────────────────

_serializeKernel(k::GaussianKernel) =
    Dict{String,Any}("type" => "GaussianKernel", "scale" => k.scale)
_serializeKernel(k::ComponentwiseKernel) =
    Dict{String,Any}("type" => "ComponentwiseKernel", "scale" => k.scale)
_serializeKernel(k::LocalNNKernel) =
    Dict{String,Any}("type" => "LocalNNKernel", "k" => k.k, "scale" => k.scale)
_serializeKernel(k::LocalNNCovKernel) =
    Dict{String,Any}("type" => "LocalNNCovKernel", "k" => k.k, "scale" => k.scale)

_toKernelScale(s::AbstractVector) = Float64.(s)
_toKernelScale(s) = Float64(s)

function _deserializeKernel(d)
    type = d["type"]
    if type == "GaussianKernel"
        return GaussianKernel(_toKernelScale(d["scale"]))
    elseif type == "ComponentwiseKernel"
        return ComponentwiseKernel(_toKernelScale(d["scale"]))
    elseif type == "LocalNNKernel"
        return LocalNNKernel(k=Int(d["k"]), scale=Float64(d["scale"]))
    elseif type == "LocalNNCovKernel"
        return LocalNNCovKernel(k=Int(d["k"]), scale=Float64(d["scale"]))
    else
        error("Unknown perturbation_kernel type in method.toml: \"$type\"")
    end
end

#! `method.toml`'s scalar keys are derived from `ABCSMC` itself, so adding a field means touching
#! only the struct and its keyword constructor — the serializers pick it up automatically. That
#! matters because the alternative already failed once: `store_rejected` was added to the struct,
#! the constructor and the serializer, but missed in `runABC`'s hand-written keyword list, and was
#! unreachable for its whole life.
#!
#! `perturbation_kernel` and `epsilon_schedule` exclude themselves by type — a kernel struct and a
#! vector are not TOML scalars — and are handled explicitly below. The
#! "every ABCSMC field is either a TOML scalar or explicitly handled" testset asserts that partition
#! still covers the struct, so a future non-scalar field cannot be silently dropped from the file.
_tomlScalarType(::Type{T}) where {T} = T
_tomlScalarType(::Type{Union{Nothing,T}}) where {T} = T

_isTomlScalar(::Type{<:Union{Real,AbstractString}}) = true
_isTomlScalar(::Type) = false

const _ABCSMC_EXPLICIT_TOML_FIELDS = (:perturbation_kernel, :epsilon_schedule)

_abcsmcScalarFields() =
    Tuple(f for f in fieldnames(ABCSMC) if _isTomlScalar(_tomlScalarType(fieldtype(ABCSMC, f))))

"""
    _saveMethod(calibration::Calibration, method::ABCSMC)
    _saveMethod(path::String, method::ABCSMC)

Save the calibration method's settings to `method.toml` for resume support.

The `path` form exists so tests can round-trip the real serializer in a temporary directory rather
than reimplementing the key list.
"""
function _methodDict(method::ABCSMC)
    d = Dict{String,Any}("type" => "ABCSMC",
                         "perturbation_kernel" => _serializeKernel(method.perturbation_kernel))
    for name in _abcsmcScalarFields()
        value = getfield(method, name)
        #! TOML has no null: omit the key rather than inventing a placeholder, and let the keyword
        #! constructor re-supply the default on load.
        isnothing(value) || (d[string(name)] = value)
    end
    isnothing(method.epsilon_schedule) || (d["epsilon_schedule"] = method.epsilon_schedule)
    return d
end

function _saveMethod(path::String, method::ABCSMC)
    open(path, "w") do io
        TOML.print(io, _methodDict(method); sorted=true)
    end
    return path
end

_saveMethod(calibration::Calibration, method::ABCSMC) =
    _saveMethod(joinpath(calibrationFolder(calibration), "method.toml"), method)

################## Problem Persistence ##################

# ── _ProblemManifest ─────────────────────────────────────────────────────────

"""
    _ProblemManifest

Serializable representation of a [`CalibrationProblem`](@ref). Always written to
`problem.jld2` by `_saveProblem` — the full `CalibrationProblem` is never serialized
directly (DVSource/CVSource closures would get session-specific compiler names that break
across Julia sessions).

Named `summary_statistic` and `distance` functions are stored directly (JLD2 saves the
function name); anonymous ones become `nothing`. Named LVSource map functions are stored
directly inside their `LVSource`; anonymous ones become `_StrippedLVSource`.
DVSource and CVSource are always stored as-is (their closures are never serialized — maps
are always reconstructed from source data at load time via `_manifestToProblem`).

At resume time:
- Complete manifest (no `nothing` fields, no `_StrippedLVSource`): `_manifestToProblem`
  reconstructs the `CalibrationProblem` automatically.
- Incomplete manifest: user must re-supply the full problem via `problem=` in
  [`resumeABC`](@ref).
"""
struct _ProblemManifest
    inputs::InputFolders
    sources::Vector{Any}       # DVSource | CVSource | LVSource | _StrippedLVSource
    #! Untyped to match `CalibrationProblem.observed_data`: `mseDistance` accepts a `Dict`, a
    #! `Vector` or a scalar, and `_saveProblem` runs before generation 1, so a narrower type here
    #! rejects two of the three documented shapes before a run can start.
    observed_data::Any
    n_replicates::Int
    reference_variation_id::VariationID
    summary_statistic          # named Function or nothing (anonymous/not restorable)
    distance                   # named Function or nothing (anonymous/not restorable)
end

_toManifestSource(src::DVSource) = src
_toManifestSource(src::CVSource) = src
function _toManifestSource(src::LVSource)
    lv = src.lv
    has_anon = any(_isAnonymousFunction, lv.maps) ||
               (!isnothing(lv.inverse_maps) && any(_isAnonymousFunction, lv.inverse_maps))
    has_anon ? _StrippedLVSource(src) : src
end

function _ProblemManifest(problem::CalibrationProblem)
    ss      = _isAnonymousFunction(problem.summary_statistic) ? nothing : problem.summary_statistic
    dist    = _isAnonymousFunction(problem.distance)          ? nothing : problem.distance
    sources = Any[_toManifestSource(cp.source) for cp in problem.parameters]
    return _ProblemManifest(problem.inputs, sources, problem.observed_data,
                            problem.n_replicates, problem.reference_variation_id,
                            ss, dist)
end

"""
    _isCompleteManifest(manifest::_ProblemManifest) → Bool

Return `true` when `manifest` can be reconstructed into a full `CalibrationProblem`
without re-supplying the original problem — i.e. neither `summary_statistic` nor
`distance` is `nothing`, and no source is a `_StrippedLVSource`.
"""
function _isCompleteManifest(manifest::_ProblemManifest)
    isnothing(manifest.summary_statistic) && return false
    isnothing(manifest.distance)          && return false
    any(s -> s isa _StrippedLVSource, manifest.sources) && return false
    return true
end

_sourceToCalibrationParameter(src::DVSource) = CalibrationParameter(src, LatentVariation(src.dv))
_sourceToCalibrationParameter(src::CVSource) = CalibrationParameter(src, LatentVariation(src.cv))
_sourceToCalibrationParameter(src::LVSource) = CalibrationParameter(src, src.lv)
function _sourceToCalibrationParameter(src::_StrippedLVSource)
    error("Cannot reconstruct CalibrationProblem from _StrippedLVSource " *
          "(\"$(src.name)\"). Re-supply the original problem via `problem=`.")
end

"""
    _manifestToProblem(manifest::_ProblemManifest) → CalibrationProblem

Reconstruct a [`CalibrationProblem`](@ref) from a complete manifest. DVSource and CVSource
maps are always regenerated from their distribution data (avoiding any reliance on
session-specific closure names). LVSource functions are used as stored.

Errors if any source is a `_StrippedLVSource` (use `_isCompleteManifest` first).
"""
function _manifestToProblem(manifest::_ProblemManifest)
    cps = CalibrationParameter[_sourceToCalibrationParameter(src)
                                for src in manifest.sources]
    return CalibrationProblem(manifest.inputs, cps, manifest.observed_data,
                              manifest.summary_statistic, manifest.distance,
                              manifest.n_replicates, manifest.reference_variation_id)
end

# ── Anonymous-function detection ─────────────────────────────────────────────

function _hasAnyAnonymousFunction(problem::CalibrationProblem)
    _isAnonymousFunction(problem.summary_statistic) && return true
    _isAnonymousFunction(problem.distance) && return true
    for cp in problem.parameters
        cp.source isa LVSource || continue
        any(_isAnonymousFunction, cp.lv.maps) && return true
        !isnothing(cp.lv.inverse_maps) &&
            any(_isAnonymousFunction, cp.lv.inverse_maps) && return true
    end
    return false
end

function _anonymousFunctionFields(problem::CalibrationProblem)
    fields = String[]
    _isAnonymousFunction(problem.summary_statistic) && push!(fields, "summary_statistic")
    _isAnonymousFunction(problem.distance) && push!(fields, "distance")
    for cp in problem.parameters
        cp.source isa LVSource || continue
        lv = cp.lv
        any(_isAnonymousFunction, lv.maps) &&
            push!(fields, "LVSource(\"$(lv.name)\").maps")
        !isnothing(lv.inverse_maps) && any(_isAnonymousFunction, lv.inverse_maps) &&
            push!(fields, "LVSource(\"$(lv.name)\").inverse_maps")
    end
    return fields
end

function _anonymousFunctionFields(manifest::_ProblemManifest)
    fields = String[]
    isnothing(manifest.summary_statistic) && push!(fields, "summary_statistic")
    isnothing(manifest.distance)          && push!(fields, "distance")
    for s in manifest.sources
        s isa _StrippedLVSource && push!(fields, "LVSource(\"$(s.name)\").maps")
    end
    return fields
end

# ── Save / Load ───────────────────────────────────────────────────────────────

"""
    _saveProblem(calibration::Calibration, problem::CalibrationProblem)

Serialize the `CalibrationProblem` to `problem.jld2` as a `_ProblemManifest`.

Always saves the manifest format — never the full `CalibrationProblem` directly — to
avoid relying on session-specific compiler names for DVSource/CVSource closures.

Named `summary_statistic`, `distance`, and `LatentVariation` map functions are preserved
in the manifest (JLD2 stores them by name). Anonymous ones become `nothing` /
`_StrippedLVSource`, and a `@warn` is emitted instructing the user to re-supply the
problem at resume time.
"""
function _saveProblem(calibration::Calibration, problem::CalibrationProblem)
    path     = joinpath(calibrationFolder(calibration), "problem.jld2")
    manifest = _ProblemManifest(problem)
    if !_isCompleteManifest(manifest)
        anon = _anonymousFunctionFields(manifest)
        @warn """
        CalibrationProblem contains anonymous functions that cannot be restored across Julia sessions.
        Saving a partial manifest (non-function fields only) to problem.jld2.
        When resuming, pass the original problem via `problem=`:

            resumeABC(Calibration($(calibration.id)); problem=my_problem)

        Anonymous fields detected: $(join(anon, ", "))

        Tip: define functions with `function name(...) end` (or top-level named functions)
        instead of anonymous lambdas to enable fully automatic resume.
        """
    end
    jldsave(path; manifest=manifest)
end

"""
    _loadProblem(calibration::Calibration) → _ProblemManifest

Load `problem.jld2` and return a `_ProblemManifest`.
"""
function _loadProblem(calibration::Calibration)
    path = joinpath(calibrationFolder(calibration), "problem.jld2")
    isfile(path) || error(
        "Cannot resume: $path not found. " *
        "The problem.jld2 file is written automatically by runABC/runCalibration.")
    return jldopen(path) do f
        haskey(f, "manifest") || error(
            "Unrecognized problem.jld2 format in $path. " *
            "Re-run with the original problem to regenerate.")
        f["manifest"]::_ProblemManifest
    end
end

"""
    _writeParametersTOML(calibration::Calibration, cps::Vector{CalibrationParameter})

Write `parameters.toml` to the calibration output folder. This file provides a
human-readable mapping from the display column names used in `generations/{t}/particles.csv`
to the underlying database column names (XML paths), along with the prior distributions.

Complements `problem.jld2` (the machine-readable full serialization) for quick inspection
without loading Julia.

Each entry in the `[[parameters]]` array has a `source_type` field (`"DVSource"`,
`"CVSource"`, or `"LVSource"`) and source-specific fields:

- `DVSource`: `display_name`, `db_column`, `prior`
- `CVSource`: `covariation_name`, `display_names`, `db_columns`, `priors`
- `LVSource`: `lv_name`, `latent_display_names`, `latent_priors`,
  `target_display_names`, `db_columns`
"""
function _writeParametersTOML(calibration::Calibration, cps::Vector{CalibrationParameter})
    path = joinpath(calibrationFolder(calibration), "parameters.toml")
    entries = Dict{String,Any}[]
    for cp in cps
        push!(entries, _parameterTOMLEntry(cp))
    end
    open(path, "w") do io
        println(io, "# Display name → database column mapping for calibration $(calibration.id).")
        println(io, "# Display names are used in generations/{t}/particles.csv.")
        println(io, "# Database columns are the full XML paths stored in the variations tables.")
        println(io)
        TOML.print(io, Dict{String,Any}("parameters" => entries))
    end
end

_parameterTOMLEntry(cp::CalibrationParameter) = _parameterTOMLEntry(cp.source, cp.lv)

function _parameterTOMLEntry(s::DVSource, lv::LatentVariation)
    return Dict{String,Any}(
        "source_type"  => "DVSource",
        "display_name" => variationName(s.dv),
        "db_column"    => columnName(lv.targets[1]),
        "prior"        => _distString(s.dv.distribution),
    )
end

function _parameterTOMLEntry(s::CVSource, lv::LatentVariation)
    return Dict{String,Any}(
        "source_type"       => "CVSource",
        "covariation_name"  => variationName(s.cv),
        "display_names"     => [variationName(v) for v in s.cv.variations],
        "db_columns"        => [columnName(variationTarget(v)) for v in s.cv.variations],
        "priors"            => [_distString(v.distribution) for v in s.cv.variations],
    )
end

function _parameterTOMLEntry(::LVSource, lv::LatentVariation)
    return Dict{String,Any}(
        "source_type"           => "LVSource",
        "lv_name"               => variationName(lv),
        "latent_display_names"  => lv.latent_parameter_names,
        "latent_priors"         => [_distString(d) for d in lv.latent_parameters],
        "target_display_names"  => lv.target_names,
        "db_columns"            => [columnName(t) for t in lv.targets],
    )
end

################## Resume — validation helpers ##################

#! Ordered by index, never by name — `_generationIndices` parses it, so mixed padding widths and both
#! layouts order alike. Sorting the names instead would put `generation_006.csv` before
#! `generation_05.csv` and answer generation 5 for a run that reached 10.
"""
    _findLastGenerationCSVs(calibration) → Union{Nothing, Tuple{String,String}}

Return `(cdf_csv_path, display_csv_path)` for the last saved generation, or `nothing`
if no generations have been written yet.
"""
function _findLastGenerationCSVs(calibration::Calibration)
    gen_dir = joinpath(calibrationFolder(calibration), "generations")
    indices = _generationIndices(gen_dir)
    isempty(indices) && return nothing
    t = last(indices)
    cdf_path     = _generationArtifact(gen_dir, t, :cdfs)
    display_path = _generationArtifact(gen_dir, t, :particles)
    (isnothing(cdf_path) || isnothing(display_path)) && return nothing
    return cdf_path, display_path
end

"""
    _validateStructuralMatch(cp, src, i)

Verify that `CalibrationParameter` `cp` (from the re-supplied problem) is structurally
consistent with saved source `src`. Throws an informative error on mismatch.
"""
function _validateStructuralMatch(cp::CalibrationParameter, src, i::Int)
    if src isa DVSource
        cp.source isa DVSource || error(
            "Parameter $i type mismatch: saved DVSource, re-supplied $(typeof(cp.source)).")
        dv_new, dv_saved = cp.source.dv, src.dv
        dv_new.location  == dv_saved.location  || error(
            "Parameter $i (DVSource) location mismatch: " *
            "saved :$(dv_saved.location), re-supplied :$(dv_new.location).")
        columnName(dv_new.target) == columnName(dv_saved.target) || error(
            "Parameter $i (DVSource) target mismatch: " *
            "saved \"$(columnName(dv_saved.target))\", re-supplied \"$(columnName(dv_new.target))\".")
        dv_new.distribution == dv_saved.distribution || error(
            "Parameter $i (DVSource) distribution mismatch: " *
            "saved $(dv_saved.distribution), re-supplied $(dv_new.distribution).")
        dv_new.flip == dv_saved.flip || error(
            "Parameter $i (DVSource) flip mismatch.")

    elseif src isa CVSource
        cp.source isa CVSource || error(
            "Parameter $i type mismatch: saved CVSource, re-supplied $(typeof(cp.source)).")
        cv_new, cv_saved = cp.source.cv, src.cv
        length(cv_new.variations) == length(cv_saved.variations) || error(
            "Parameter $i (CVSource) length mismatch.")
        for (k, (v1, v2)) in enumerate(zip(cv_new.variations, cv_saved.variations))
            v1.location == v2.location || error(
                "Parameter $i (CVSource) variation $k location mismatch.")
            columnName(v1.target) == columnName(v2.target) || error(
                "Parameter $i (CVSource) variation $k target mismatch.")
            v1.distribution == v2.distribution || error(
                "Parameter $i (CVSource) variation $k distribution mismatch.")
            v1.flip == v2.flip || error(
                "Parameter $i (CVSource) variation $k flip mismatch.")
        end

    elseif src isa _StrippedLVSource
        cp.source isa LVSource || error(
            "Parameter $i type mismatch: saved LVSource (stripped), re-supplied $(typeof(cp.source)).")
        lv = cp.lv
        lv.latent_parameter_names == src.latent_parameter_names || error(
            "Parameter $i (LVSource \"$(src.name)\") latent_parameter_names mismatch: " *
            "saved $(src.latent_parameter_names), re-supplied $(lv.latent_parameter_names).")
        columnName.(lv.targets) == columnName.(src.targets) || error(
            "Parameter $i (LVSource \"$(src.name)\") targets mismatch.")
        lv.target_names == src.target_names || error(
            "Parameter $i (LVSource \"$(src.name)\") target_names mismatch.")
        lv.name == src.name || error(
            "Parameter $i LV name mismatch: saved \"$(src.name)\", re-supplied \"$(lv.name)\".")

    elseif src isa LVSource
        cp.source isa LVSource || error(
            "Parameter $i type mismatch: saved LVSource, re-supplied $(typeof(cp.source)).")
        lv_new, lv_saved = cp.lv, src.lv
        lv_new.latent_parameter_names == lv_saved.latent_parameter_names || error(
            "Parameter $i (LVSource \"$(lv_saved.name)\") latent_parameter_names mismatch: " *
            "saved $(lv_saved.latent_parameter_names), re-supplied $(lv_new.latent_parameter_names).")
        columnName.(lv_new.targets) == columnName.(lv_saved.targets) || error(
            "Parameter $i (LVSource \"$(lv_saved.name)\") targets mismatch.")
        lv_new.target_names == lv_saved.target_names || error(
            "Parameter $i (LVSource \"$(lv_saved.name)\") target_names mismatch.")
        lv_new.name == lv_saved.name || error(
            "Parameter $i LV name mismatch: saved \"$(lv_saved.name)\", re-supplied \"$(lv_new.name)\".")

    else
        error("Unexpected saved source type at parameter $i: $(typeof(src)).")
    end
end

"""
    _validateParticleConsistency(cps, src_list, cdf_df, display_df; rtol=1e-6)

For each `CalibrationParameter` in `cps`:
- Applies `_particleRowToDisplay` to every row of `cdf_df` and compares against the
  corresponding display columns in `display_df`.  Used to confirm that the re-supplied
  (or JLD2-loaded) maps reproduce the values that were recorded during the original run.
- For `LVSource` parameters with `inverse_maps`, also runs a round-trip check:
  CDF → latent values → target values → recovered latent values.

Only runs for parameters whose saved source is `_StrippedLVSource` OR `LVSource`
(i.e. only for LV parameters); DV/CV parameters are skipped because their maps are
deterministically reconstructed from the distribution data and cannot silently change.

When called from `_validateResumedProblem` (user re-supplied all parameters), DV/CV
parameters are also validated to catch accidental wrong-problem re-passing.
"""
function _validateParticleConsistency(cps::Vector{CalibrationParameter}, src_list,
                                      cdf_df::DataFrame, display_df::DataFrame;
                                      rtol::Real=1e-6, lv_only::Bool=false)
    N = nrow(cdf_df)
    N == 0 && return nothing

    for (i, (cp, src)) in enumerate(zip(cps, src_list))
        lv_only && !(src isa _StrippedLVSource || src isa LVSource) && continue

        lp_names  = cp.lv.latent_parameter_names
        disp_cols = _displayColumns(cp)

        for col in lp_names
            col in names(cdf_df) || error(
                "CDF CSV missing column '$col' for parameter $i. " *
                "The re-supplied parameter has different latent_parameter_names than the saved run.")
        end
        for col in disp_cols
            col in names(display_df) || error(
                "Display CSV missing column '$col' for parameter $i. " *
                "The re-supplied parameter has different display names than the saved run.")
        end

        for row in 1:N
            cdf_vals = Float64[cdf_df[row, name] for name in lp_names]
            expected  = _particleRowToDisplay(cp, cdf_vals)
            for (j, col) in enumerate(disp_cols)
                stored = Float64(display_df[row, col])
                isapprox(expected[j], stored; rtol=rtol) || error(
                    "Map mismatch for parameter $i (\"$(variationName(cp.lv))\"), " *
                    "column \"$(col)\", particle $(row): re-supplied map gives $(expected[j]), " *
                    "stored value is $(stored). " *
                    "The maps in the re-supplied problem are not consistent with the saved run.")
            end

            # Round-trip check for LVSource with inverse_maps.
            if cp.source isa LVSource && !isnothing(cp.lv.inverse_maps)
                lv = cp.lv
                lp_vals     = [quantile(d, u) for (d, u) in zip(lv.latent_parameters, cdf_vals)]
                target_vals = Float64[fn(lp_vals) for fn in lv.maps]
                recovered   = [inv_map(target_vals) for inv_map in lv.inverse_maps]
                for (k, (lp, rec)) in enumerate(zip(lp_vals, recovered))
                    isapprox(lp, rec; rtol=rtol) || error(
                        "inverse_maps round-trip failure for parameter $i " *
                        "(\"$(variationName(cp.lv))\"), latent dim $k, particle $(row): " *
                        "forward gives $(lp), inverse recovers $(rec).")
                end
            end
        end
    end
end

"""
    _validateResumedProblem(provided, manifest, calibration; rtol=1e-6)

Full validation of a re-supplied `CalibrationProblem` against a saved `_ProblemManifest`.
Runs structural checks, then behavioral checks against stored particle data for all
re-supplied parameters (DV, CV, and LV alike).
"""
function _validateResumedProblem(provided::CalibrationProblem, manifest::_ProblemManifest,
                                  calibration::Calibration; rtol::Real=1e-6)
    provided.n_replicates == manifest.n_replicates || error(
        "n_replicates mismatch: saved $(manifest.n_replicates), re-supplied $(provided.n_replicates).")
    provided.reference_variation_id == manifest.reference_variation_id || error(
        "reference_variation_id mismatch: saved $(manifest.reference_variation_id), " *
        "re-supplied $(provided.reference_variation_id). Is this the same problem?")
    provided.observed_data == manifest.observed_data || error(
        "observed_data mismatch. Re-supplied problem has different observed data.")

    n_saved = length(manifest.sources)
    n_prov  = length(provided.parameters)
    n_saved == n_prov || error(
        "Parameter count mismatch: saved $n_saved, re-supplied $n_prov.")

    for (i, (cp, src)) in enumerate(zip(provided.parameters, manifest.sources))
        _validateStructuralMatch(cp, src, i)
    end

    paths = _findLastGenerationCSVs(calibration)
    isnothing(paths) && return nothing  # no generations saved yet — skip behavioral check

    cdf_df     = CSV.read(paths[1], DataFrame)
    display_df = CSV.read(paths[2], DataFrame)
    _validateParticleConsistency(provided.parameters, manifest.sources,
                                 cdf_df, display_df; rtol=rtol, lv_only=false)
    return nothing
end

"""
    _validateLVMaps(problem, calibration; rtol=1e-6)

Validate LVSource maps for a problem loaded directly from `problem.jld2` (named functions).
Because JLD2 saves only the function name (not its implementation), a user could redefine
a named function between runs; this check detects that by comparing map outputs against
stored particle data. Skipped silently when no LVSource parameters are present or when
no generations have been saved yet.
"""
function _validateLVMaps(problem::CalibrationProblem, calibration::Calibration;
                          rtol::Real=1e-6)
    any(cp -> cp.source isa LVSource, problem.parameters) || return nothing
    paths = _findLastGenerationCSVs(calibration)
    isnothing(paths) && return nothing

    cdf_df     = CSV.read(paths[1], DataFrame)
    display_df = CSV.read(paths[2], DataFrame)
    src_list   = [cp.source for cp in problem.parameters]
    _validateParticleConsistency(problem.parameters, src_list,
                                 cdf_df, display_df; rtol=rtol, lv_only=true)
    return nothing
end

# ── Multiple-dispatch resolution: (manifest, provided?) → active problem ─────

function _resolveResumeProblem(manifest::_ProblemManifest, ::Nothing,
                                calibration::Calibration)
    if !_isCompleteManifest(manifest)
        anon_fields = _anonymousFunctionFields(manifest)
        error("""
            Cannot resume Calibration($(calibration.id)): problem.jld2 contains only a partial manifest (anonymous functions were present at save time).
            Pass the original CalibrationProblem via `problem=`:

                resumeABC(Calibration($(calibration.id)); problem=my_problem)

            Anonymous fields: $(join(anon_fields, ", "))
            """)
    end
    problem = _manifestToProblem(manifest)
    _validateLVMaps(problem, calibration)
    return problem
end

function _resolveResumeProblem(manifest::_ProblemManifest, provided::CalibrationProblem,
                                calibration::Calibration)
    _validateResumedProblem(provided, manifest, calibration)
    return provided
end

################## Resume — public API ##################

"""
    resumeCalibration(calibration::Calibration, method=nothing; kwargs...)
    resumeABC(calibration::Calibration; method=nothing, kwargs...)
              problem::Union{Nothing,CalibrationProblem}=nothing,
              method::Union{Nothing,ABCSMC}=nothing,
              run_kwargs::NamedTuple=(;)) → ABCResult

Resume a stopped or crashed ABC-SMC calibration from saved generation files.

Loads ABCSMC settings from `method.toml` and the calibration problem from `problem.jld2`
(both written by the original run), then continues from the next generation.

# When `problem=` is required

If the original `CalibrationProblem` contained any **anonymous functions**
(`summary_statistic`, `distance`, or any `LatentVariation` maps / inverse_maps defined
as lambdas), JLD2 cannot serialize them and saves only a partial manifest.  In that case
`resumeABC` requires the full problem to be re-supplied:

```julia
resumeABC(Calibration(42); problem=my_problem)
```

The re-supplied problem is validated against the saved manifest:
- **Structural check**: parameter count, source types, names, targets, distributions.
- **Behavioral check** (all parameters): re-supplied maps are applied to the stored
  CDF particle data and the outputs are compared against the recorded target values.
- **Round-trip check** (LV parameters with `inverse_maps`): verifies
  `inverse_map(map(lp)) ≈ lp` on stored particles.

Even when `problem.jld2` contains a full `CalibrationProblem` (all named functions),
the behavioral and round-trip checks are re-run on any `LVSource` parameters, because
JLD2 saves only the function's *name* — if the function was redefined between runs the
new definition is used silently. Passing `problem=` in this case forces full validation.

# Arguments
- `problem`: The original `CalibrationProblem`. Required when anonymous functions were
  present at save time; optional otherwise (loads from `problem.jld2`).
- `method`: Replace the saved settings wholesale. If `nothing`, they are loaded from `method.toml`.
  To change *some* settings and keep the rest, pass them as keywords instead —
  `resumeCalibration(cal; max_nr_populations=15)` — since a method object supplies every field, so
  any field it does not name takes a constructor default rather than the value the run used.
  Passing both a method object and individual settings is an error.
- Any `ABCSMC` field may be given as a keyword; it patches the saved value for that one field.
  Whenever the effective settings differ from `method.toml`, the file is rewritten to match and the
  changed keys are reported, so a later resume does not revert to the original run's values.

# What a changed setting does to a resumed run

Nothing already on disk is recomputed — a resume only ever appends generations — so a changed setting
takes effect from the next generation onward. What that means in practice differs by field:

| Setting | Effect from the next generation |
|---|---|
| `max_nr_populations` | New total cap. It counts *all* generations, not just new ones. |
| `minimum_epsilon`, `min_acceptance_rate`, `min_epsilon_decrease`, `min_ess_fraction` | Checked after each new generation, as usual. |
| `epsilon_quantile` | Sets the next threshold from the previous generation's accepted distances. |
| `accept_overflow`, `max_evaluations`, `store_rejected` | Apply per generation; no interaction with what came before. |
| `population_size` | New generations get the new size; earlier ones keep theirs. Legal — weights are normalised per generation, so resampling from a differently-sized parent is well defined — but the run ends up with generations of different sizes. |
| `perturbation_kernel` | Refitted from the previous generation each time, so every generation stays internally consistent. The proposal simply changes from here on. |
| `cdf_grid_k` | Resolved once when the loop starts, so turning snapping on or off applies only to new generations. Earlier particles were never snapped, so bank reuse differs either side of the resume. |
| `epsilon_schedule` | **Indexed by absolute generation**, not by position within the resumed segment: generation `t` reads `epsilon_schedule[t - 1]`. A schedule supplied on resume must therefore cover the whole run. One too short for the generations already completed is warned about, and those generations fall back to the quantile rule. |

No setting is refused. A generation is the unit of change, and none of these can take effect part-way
through one — so the honest description is "from the next generation", not "immediately".
- `run_kwargs`: Forwarded to each `run(sampling; ...)` call.
- `progress`: Console-feedback verbosity (`:auto`, `:none`, `:generation`, `:batch`, `:bar`);
  same semantics as in [`runABC`](@ref).
- `on_monad_failure`: `:reject` (default) or `:error`; same semantics as in
  [`runABC`](@ref).

# Examples
```julia
# Session restart — only calibration ID needed (all named functions)
result = resumeABC(Calibration(42))

# Re-supply the problem when anonymous functions were used
result = resumeABC(Calibration(42); problem=my_problem)

# Raise the generation cap, keeping every other saved setting
result = resumeCalibration(Calibration(42); max_nr_populations=15)

# Replace the settings wholesale (every unnamed field takes its default)
result = resumeCalibration(Calibration(42), ABCSMC(population_size=64, max_nr_populations=15))
```
"""
function resumeCalibration(calibration::Calibration,
                           method::Union{Nothing,ABCSMC}=nothing;
                           problem::Union{Nothing,CalibrationProblem}=nothing,
                           run_kwargs::NamedTuple=(;),
                           progress::Symbol=:auto,
                           on_monad_failure::Symbol=:reject,
                           kwargs...)
    verbosity = _resolveVerbosity(progress)
    _validateEvaluationFailurePolicy(on_monad_failure)
    manifest = _loadProblem(calibration)
    active_problem = _resolveResumeProblem(manifest, problem, calibration)

    m = if isnothing(method)
        saved = _loadMethod(calibration)
        isempty(kwargs) ? saved : _methodWithOverrides(saved, kwargs)
    else
        #! A whole method object and individual settings are two ways to say the same thing, and
        #! silently letting one win is how `method=` came to reset every field the caller did not name.
        isempty(kwargs) || throw(ArgumentError(
            "resumeCalibration received both a method object and method setting(s) " *
            "$(join(keys(kwargs), ", ")). Pass one or the other, not both."))
        method
    end

    #! The one setting whose misalignment would otherwise be silent. `epsilon_schedule` is read as
    #! `epsilon_schedule[t - 1]` behind a length guard, so a schedule sized for the *remaining*
    #! generations rather than the whole run does not error — those generations quietly fall back to
    #! the quantile rule, and the run looks like it honoured a schedule it never saw.
    if !isnothing(m.epsilon_schedule)
        n_done = length(_generationIndices(joinpath(calibrationFolder(calibration), "generations")))
        length(m.epsilon_schedule) <= n_done && @warn "epsilon_schedule has " *
            "$(length(m.epsilon_schedule)) entries but $(n_done) generation" *
            "$(n_done == 1 ? "" : "s") already exist, and it is indexed by absolute generation " *
            "(generation t reads entry t-1). Every new generation will fall back to " *
            "epsilon_quantile. Supply a schedule covering the whole run to avoid this."
    end

    changed = _persistEffectiveMethod(calibration, m)
    isempty(changed) || @info "Updated method.toml to the settings this resume is running with: " *
                              "$(join(sort(changed), ", ")). The file described the original run, " *
                              "so a later resume would otherwise have reverted to it."

    #! Before anything reads or writes a generation file, bring the directory to the current layout:
    #! move any flat-layout generation into its own folder, and re-pad folder names if the cap changed.
    #! Readers handle both layouts at any width, so this is tidiness rather than a precondition — which
    #! is why it runs on resume (where we are already writing here) and not on a read-only plot.
    n_moved = _migrateGenerationLayout!(calibration, m.max_nr_populations)
    n_moved > 0 && @info "Reorganised $(n_moved) generation file" *
                         "$(n_moved == 1 ? "" : "s") into per-generation folders under " *
                         "generations/, padded to match max_nr_populations=$(m.max_nr_populations)."

    cps = active_problem.parameters
    param_names, _ = _latentNamesAndPriors(cps)

    start_generations = _loadGenerations(calibration, param_names, m.max_nr_populations)

    if !isempty(start_generations)
        stop_reason = _stoppingReason(m, start_generations)
        if !isnothing(stop_reason)
            _verbosityRank(verbosity) >= _verbosityRank(:generation) &&
                @info "ABC-SMC (resume): $stop_reason — no new generations needed."
            return ABCResult(calibration, start_generations, active_problem.parameters, m)
        end
    end

    return _executeCalibration(active_problem, calibration, m, run_kwargs;
                               verbosity=verbosity, on_monad_failure=on_monad_failure,
                               start_generations=start_generations)
end

#! Kept, not deprecated: `runABC` exists, so `resumeABC` should too — the pair is the ABC-specific
#! shorthand, and `runCalibration`/`resumeCalibration` are the method-agnostic forms that read like
#! `run(::GSAMethod, ...)`. Both pairs are complete, which is the point; an asymmetric surface where
#! only one half of one pair survives would be the confusing outcome.
"""
    resumeABC(calibration::Calibration; method=nothing, kwargs...) → ABCResult

ABC-specific alias for [`resumeCalibration`](@ref); every argument has the same meaning.
"""
resumeABC(calibration::Calibration; method::Union{Nothing,ABCSMC}=nothing, kwargs...) =
    resumeCalibration(calibration, method; kwargs...)

#! `Calibration` is deliberately not an `AbstractTrial` (see the containment discussion in
#! `calibration.jl`), which is what makes `run(::Calibration)` unambiguous against `run(::AbstractTrial)`.
#! Method-first mirrors `run(::GSAMethod, inputs, avs)`, and returning an `ABCResult` mirrors that
#! method returning a `GSASampling` — a `run` that hands back an analysis object is already the
#! precedent here, not a new idea.
"""
    run(method::ABCSMC, problem::CalibrationProblem; kwargs...) → ABCResult
    run(calibration::Calibration[, method]; kwargs...) → ABCResult

Run or continue a calibration through `run`, alongside `run(::AbstractTrial)` and
`run(::GSAMethod, ...)`.

The first form starts a fresh run and is `runCalibration(problem, method)`. The second continues an
existing one and is `resumeCalibration(calibration, method)`; as there, an `ABCSMC` field passed as a
keyword patches the saved method rather than replacing it.
"""
run(method::ABCSMC, problem::CalibrationProblem; kwargs...) =
    runCalibration(problem, method; kwargs...)

run(calibration::Calibration, method::Union{Nothing,ABCSMC}=nothing; kwargs...) =
    resumeCalibration(calibration, method; kwargs...)

"""
    _loadMethod(calibration::Calibration) → AbstractCalibrationMethod

Load saved method settings from `method.toml`.

The file's `type` key selects the method. It is absent from files written before the key existed,
which are therefore read as `ABCSMC` — the only method that could have written them.
"""
function _loadMethod(calibration::Calibration)
    path = joinpath(calibrationFolder(calibration), "method.toml")
    isfile(path) || error("Cannot resume: $path not found. Pass `method=ABCSMC(...)` explicitly.")
    return _loadMethod(TOML.parsefile(path))
end

function _loadMethod(d::AbstractDict)
    type = get(d, "type", "ABCSMC")
    type == "ABCSMC" && return _loadMethod(ABCSMC, d)
    error("Unknown method type in method.toml: \"$type\". Known types: ABCSMC.")
end

#! Every key is optional and the keyword constructor supplies what is missing, so a `method.toml`
#! written before a field existed still resumes instead of throwing a `KeyError`.
function _loadMethod(::Type{ABCSMC}, d::AbstractDict)
    kw = Dict{Symbol,Any}()
    for name in _abcsmcScalarFields()
        haskey(d, string(name)) || continue
        kw[name] = convert(_tomlScalarType(fieldtype(ABCSMC, name)), d[string(name)])
    end
    haskey(d, "epsilon_schedule") && (kw[:epsilon_schedule] = Float64.(d["epsilon_schedule"]))
    haskey(d, "perturbation_kernel") &&
        (kw[:perturbation_kernel] = _deserializeKernel(d["perturbation_kernel"]))
    return ABCSMC(; kw...)
end

################## Generation Persistence ##################

"""
    _generationTag(t, max_nr_populations) → String

Zero-padded generation index string, e.g. `"03"` for t=3, max=10 or `"003"` for max=100.
"""
_generationTag(t::Int, max_nr_populations::Int) =
    lpad(string(t), ndigits(max_nr_populations), '0')

#! All four are `_generationArtifactToWrite` with the role filled in, which is where the two rules that
#! used to be repeated per builder now live: an existing artifact wins over a computed path (so an
#! appender cannot split one generation's record across two files after a resume changes the padding),
#! and the folder is created on demand.
#! One docstring each: a docstring attaches to the single expression that follows it, so one block
#! listing all four signatures would document only the first of them.
"""
    _generationProposalsPath(dir, t, max_nr_populations) → String

Path to generation `t`'s proposal-distance record, for writing.
"""
_generationProposalsPath(dir::String, t::Int, max_nr_populations::Int) =
    _generationArtifactToWrite(dir, t, :proposals, max_nr_populations)

"""
    _generationMonadsPath(calibration, t, max_nr_populations) → String

Path to generation `t`'s evaluated-monad record, for writing.
"""
_generationMonadsPath(calibration::Calibration, t::Int, max_nr_populations::Int) =
    _generationArtifactToWrite(joinpath(calibrationFolder(calibration), "generations"),
                               t, :monads, max_nr_populations)

"""
    _failedSimulationsPath(calibration, t, max_nr_populations) → String

Path to generation `t`'s failed-simulation record, for writing.
"""
_failedSimulationsPath(calibration::Calibration, t::Int, max_nr_populations::Int) =
    _generationArtifactToWrite(joinpath(calibrationFolder(calibration), "generations"),
                               t, :failed_simulations, max_nr_populations)

"""
    _failedMonadsPath(calibration, t, max_nr_populations) → String

Path to generation `t`'s failed-monad record, for writing.
"""
_failedMonadsPath(calibration::Calibration, t::Int, max_nr_populations::Int) =
    _generationArtifactToWrite(joinpath(calibrationFolder(calibration), "generations"),
                               t, :failed_monads, max_nr_populations)

"""
    _appendCompressedIDs(path, new_ids) → String

Merge `new_ids` into the compressed-ID CSV at `path` (creating it if absent) and return `path`.
Existing entries are read back with `constituentIDs`, so the file always holds a single
fully-compressed, deduplicated, sorted ID list spanning every call — the format shared by the
per-generation monad and failure records.
"""
function _appendCompressedIDs(path::String, new_ids::AbstractVector{<:Integer})
    mkpath(dirname(path))
    ids = vcat(constituentIDs(path), new_ids)
    CSV.write(path, Tables.table(compressIDs(ids)); header=false)
    return path
end

"""
    _recordBatchFailures(calibration, t, max_nr_populations, verbosity, warned_generations,
                         failed_simulations, failed_monads)

Record a batch's failed simulation IDs and the IDs of monads with at least one failed simulation
to the generation's failure files, and warn about them **once per generation** (tracked in
`warned_generations`). Later batches in the same generation add to the same files silently.

Does nothing when the batch had no failures.
"""
function _recordBatchFailures(calibration::Calibration, t::Int, max_nr_populations::Int,
                              verbosity::Symbol, warned_generations::Set{Int},
                              failed_simulations::AbstractVector{<:Integer},
                              failed_monads::AbstractVector{<:Integer})
    isempty(failed_simulations) && isempty(failed_monads) && return nothing
    sim_path   = _appendCompressedIDs(_failedSimulationsPath(calibration, t, max_nr_populations),
                                      failed_simulations)
    monad_path = _appendCompressedIDs(_failedMonadsPath(calibration, t, max_nr_populations),
                                      failed_monads)
    _warnFailuresRecorded(verbosity, t, warned_generations, sim_path, monad_path)
    return nothing
end

"""
    _buildDisplayDF(gen::GenerationResult, cps::Vector{CalibrationParameter}) → DataFrame

Build the human-readable display DataFrame for a completed generation.

For each `CalibrationParameter`, raw CDF coordinates in `gen.particles` are converted to
interpretable values via `_particleRowToDisplay`. If `cps` is empty, returns a copy of
`gen.particles` unchanged (useful for tests that build `GenerationResult` directly).

`weight`, `distance`, and `monad_id` columns are always appended.
"""
function _buildDisplayDF(gen::GenerationResult, cps::Vector{CalibrationParameter})
    if isempty(cps)
        df = copy(gen.particles)
        df[!, :weight]   = gen.weights
        df[!, :distance] = gen.distances
        df[!, :monad_id] = gen.monad_ids
        return df
    end

    N = nrow(gen.particles)
    col_names = String[]
    col_vecs  = Vector{Float64}[]

    for cp in cps
        dcols     = _displayColumns(cp)
        dcol_vecs = [Vector{Float64}(undef, N) for _ in dcols]
        for i in 1:N
            cdf_vals = Float64[gen.particles[i, n] for n in cp.lv.latent_parameter_names]
            vals     = _particleRowToDisplay(cp, cdf_vals)
            for j in eachindex(dcols)
                dcol_vecs[j][i] = vals[j]
            end
        end
        append!(col_names, dcols)
        append!(col_vecs,  dcol_vecs)
    end

    df = DataFrame()
    for (name, vec) in zip(col_names, col_vecs)
        df[!, name] = vec
    end
    df[!, :weight]   = gen.weights
    df[!, :distance] = gen.distances
    df[!, :monad_id] = gen.monad_ids
    return df
end

"""
    _saveGeneration(calibration, gen, max_nr_populations[, cps])

Save a generation result. Writes:
- `generations/{t}/particles.csv`: human-readable display format.
- `generations/{t}/cdfs.csv`: raw CDF coordinates for resume.
- `generations/{t}/metadata.toml`: generation-level metadata.

When called with the 2-directory form `_saveGeneration(dir, cdf_dir, gen, ...)`, the
caller controls both directories (used in tests).
"""
function _saveGeneration(calibration::Calibration, gen::GenerationResult,
                         max_nr_populations::Int,
                         cps::Vector{CalibrationParameter}=CalibrationParameter[])
    dir = joinpath(calibrationFolder(calibration), "generations")
    _saveGeneration(dir, gen, max_nr_populations, cps)
end

#! One directory per generation, so the artifacts are addressed by role and need no generation number
#! in their own names. The `cdf_dir` argument the flat layout needed is gone: the CDF coordinates are
#! simply `cdfs.csv` beside the rest.
function _saveGeneration(dir::String, gen::GenerationResult, max_nr_populations::Int,
                         cps::Vector{CalibrationParameter}=CalibrationParameter[])
    gdir = _generationFolderToWrite(dir, gen.t, max_nr_populations)

    # Raw CDF coordinates for resumeABC.
    cdf_df = copy(gen.particles)
    cdf_df[!, :weight]   = gen.weights
    cdf_df[!, :distance] = gen.distances
    cdf_df[!, :monad_id] = gen.monad_ids
    CSV.write(joinpath(gdir, _GENERATION_ARTIFACTS.cdfs), cdf_df)

    # Human-readable display CSV.
    CSV.write(joinpath(gdir, _GENERATION_ARTIFACTS.particles), _buildDisplayDF(gen, cps))

    #! Every evaluated proposal and whether it passed ε. Deliberately a separate file rather than
    #! extra rows in the display CSV: `posterior(::Calibration)` reads that one and strips exactly
    #! `weight`/`distance`/`monad_id`, so rejected rows there would come back as posterior samples
    #! with meaningless weights. Written unconditionally — this is three numbers per proposal on
    #! disk, unlike `store_rejected`, which holds a full CDF-coordinate frame in memory.
    isnothing(gen.proposal_distances) ||
        CSV.write(joinpath(gdir, _GENERATION_ARTIFACTS.proposals), gen.proposal_distances)

    # Generation-level TOML.
    meta = Dict{String,Any}(
        #! Two distinct quantities, and only the first used to be recorded: `max_epsilon_accepted`
        #! is the worst distance actually accepted, while `epsilon_threshold` is the cutoff the
        #! generation was run against. They coincide only when `epsilon_quantile == 1.0`.
        "t"                    => gen.t,
        "max_epsilon_accepted" => gen.max_epsilon_accepted,
        "n_evaluations"        => gen.n_evaluations,
        "acceptance_rate"      => gen.acceptance_rate,
        "ess"                  => gen.ess,
    )
    #! Omitted rather than written as a placeholder: generation 1 has no threshold, because it
    #! accepts every proposal it evaluates, and TOML has no null.
    isnothing(gen.epsilon_threshold) || (meta["epsilon_threshold"] = gen.epsilon_threshold)
    open(joinpath(gdir, _GENERATION_ARTIFACTS.metadata), "w") do io
        TOML.print(io, meta; sorted=true)
    end
end

"""
    _loadGenerations(calibration, param_names, max_nr_populations) → Vector{GenerationResult}

Load saved generation results from each generation's `cdfs.csv` (raw CDF coordinates), reconstructing
the internal particle state needed for `resumeABC`.
"""
function _loadGenerations(calibration::Calibration, param_names::Vector{String},
                          max_nr_populations::Int)
    dir = joinpath(calibrationFolder(calibration), "generations")
    _loadGenerations(dir, param_names, max_nr_populations)
end

function _loadGenerations(dir::String, param_names::Vector{String},
                          max_nr_populations::Int)
    #! Discovered, never reconstructed: `_generationIndices` reports what is on disk across both the
    #! folder layout and the historical flat one, at any padding width, and `_generationArtifact`
    #! resolves each file the same way. A generation whose CDF file is missing is skipped rather than
    #! erroring — that is an interrupted write, and the generations before it are still usable.
    indices = _generationIndices(dir)
    isempty(indices) && return GenerationResult[]

    generations = GenerationResult[]
    n_upgraded = 0
    for t in indices
        csv_path = _generationArtifact(dir, t, :cdfs)
        isnothing(csv_path) && continue

        df        = CSV.read(csv_path, DataFrame)
        weights   = df[!, :weight]
        distances = df[!, :distance]
        monad_ids = df[!, :monad_id]
        particles = select(df, param_names)

        toml_path = _generationArtifact(dir, t, :metadata)
        isnothing(toml_path) && continue
        meta = TOML.parsefile(toml_path)
        #! Older runs recorded a single `epsilon`. Read it, and upgrade the file in place so the next
        #! read takes the current path — resuming already writes into this folder, so there is nothing
        #! read-only about it here.
        _upgradeGenerationMetadata!(toml_path, meta) && (n_upgraded += 1)
        max_epsilon_accepted = Float64(get(meta, "max_epsilon_accepted",
                                           get(meta, "epsilon", NaN)))
        n_evaluations   = Int(meta["n_evaluations"])
        acceptance_rate = Float64(meta["acceptance_rate"])
        ess             = Float64(meta["ess"])

        #! `nothing` when the key is absent, which is every generation 1 and every pre-rename run.
        epsilon_threshold = haskey(meta, "epsilon_threshold") ?
            Float64(meta["epsilon_threshold"]) : nothing

        #! Absent for a run that predates the file, in which case the recipe degrades to the
        #! accepted distances it can still read from the generation CSV.
        proposals_path = _generationArtifact(dir, t, :proposals)
        proposal_distances = isnothing(proposals_path) ? nothing :
            CSV.read(proposals_path, DataFrame;
                     types=Dict(:monad_id => Int, :distance => Float64, :accepted => Bool))

        push!(generations, GenerationResult(t, particles, weights, distances,
                                            max_epsilon_accepted,
                                            n_evaluations, monad_ids, acceptance_rate, ess,
                                            nothing; epsilon_threshold=epsilon_threshold,
                                            proposal_distances=proposal_distances))
    end

    if n_upgraded > 0
        @warn """
        Upgraded $(n_upgraded) generation metadata file$(n_upgraded == 1 ? "" : "s") in $(dir) to the \
        current key names. The recorded value is preserved as `max_epsilon_accepted`, the largest \
        distance a generation accepted. `epsilon_threshold` — the cutoff a generation was run \
        against — is absent for these generations because it was not recorded when they ran.
        """ maxlog=1
    end
    return generations
end

"""
    _upgradeGenerationMetadata!(path, meta) → Bool

Rewrite one `{t}/metadata.toml` in place to the current key names, mutating `meta` to match.
Returns whether anything changed.
"""
function _upgradeGenerationMetadata!(path::String, meta::AbstractDict)
    #! Only the rename. The threshold a generation ran against genuinely was not recorded, so it is
    #! left absent rather than invented — `nothing` is the honest value, and a wrong number here would
    #! silently mislabel an acceptance boundary.
    (haskey(meta, "epsilon") && !haskey(meta, "max_epsilon_accepted")) || return false
    meta["max_epsilon_accepted"] = meta["epsilon"]
    delete!(meta, "epsilon")
    try
        #! Write-then-rename: a rename within one directory is atomic on POSIX, so an interrupted
        #! upgrade cannot leave a half-written file where a readable one used to be.
        tmp = path * ".upgrading"
        open(tmp, "w") do io
            TOML.print(io, meta; sorted=true)
        end
        mv(tmp, path; force=true)
        return true
    catch e
        #! A read-only or full filesystem must not break the resume: the in-memory `meta` is already
        #! correct, so carry on and let the next writable run upgrade the file.
        @warn "Could not upgrade $(path) to the current key names; continuing with the value read from it." exception=(e, catch_backtrace())
        return false
    end
end
