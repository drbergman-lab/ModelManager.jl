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
    _buildEvaluateBatch(problem, calibration, max_nr_populations, run_kwargs) → Function

Build the `evaluate_batch` callback expected by `_runABCSMC`. The returned function:

1. Takes `(t::Int, proposals::Vector{Tuple{Dict{String,Float64}, Union{Nothing,Int}}})` —
   generation index and one `(latent_cdfs, known_mid)` pair per proposed particle.
   `known_mid` is an `Int` for bank/mid-generation reuses (monad already in DB) and
   `nothing` for fresh grid snaps (monad created here).
2. Creates or retrieves a `Monad` for each proposal: known-mid proposals use
   `Monad(mid; ...)` (one SELECT); nothing-mid proposals use `_createMonadForParams`
   (INSERT OR IGNORE + SELECT).
3. Records all monad IDs evaluated so far in this generation to `generation_{NNN}_monads.csv`
   using `compressIDs` **before** launching simulations (crash safety). The file is
   overwritten on each batch call so it always contains a single fully-compressed entry
   spanning all batches in the generation.
4. Assembles all monads into a `Sampling` and calls `run(sampling; quiet=true, run_kwargs...)`.
   When `verbosity` is `:batch` or higher a batch-start line is logged; when it is `:bar`
   a live per-simulation progress bar is rendered via the runner's `on_progress` hook.
5. Returns a `Vector{Tuple{Float64,Int}}` (distance, monad_id) in proposal order.

`verbosity` is a resolved level (see [`_resolveVerbosity`](@ref)); a per-generation batch
counter is maintained across calls so batch milestones can be numbered within each generation.
"""
function _buildEvaluateBatch(problem::CalibrationProblem, calibration::Calibration,
                              max_nr_populations::Int, run_kwargs::NamedTuple=(;);
                              verbosity::Symbol=:generation)
    batch_counts = Dict{Int,Int}()
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

        monad_path = _generationMonadsPath(calibration, t, max_nr_populations)
        mkpath(dirname(monad_path))
        prior_ids = constituentIDs(monad_path)
        new_ids   = [monad.id for monad in monads]
        CSV.write(monad_path, Tables.table(compressIDs(vcat(prior_ids, new_ids))); header=false)

        sampling = Sampling(monads, problem.inputs)
        on_progress = _batchProgressCallback(verbosity, "  gen $t batch $batch_index ")
        run(sampling; quiet=true, on_progress=on_progress, run_kwargs...)

        results = map(monads) do monad
            simulated = problem.summary_statistic(monad.id)
            distance = problem.distance(simulated, problem.observed_data)
            (Float64(distance), monad.id)
        end

        return results
    end
    return evaluate_batch
end

################## Public API ##################

"""
    runCalibration(problem::CalibrationProblem, method::ABCSMC; description="") → ABCResult

Run ABC-SMC calibration. See [`ABCSMC`](@ref) for method settings.

The full `CalibrationProblem` is serialized to `problem.jld2` enabling
`resumeABC(Calibration(id))` with no further arguments. Per-generation results are
saved in two forms:
- `generations/generation_{t}.csv`: human-readable target parameter values.
- `generations/generation_cdfs/generation_{t}.csv`: raw CDF coordinates for exact resume.

# Arguments
- `run_kwargs::NamedTuple=(;)`: forwarded to each `run(sampling; quiet=true, ...)` call.
- `description::String=""`: stored in the `calibrations` DB row.
- `progress::Symbol=:auto`: console-feedback verbosity. One of `:auto`, `:none`,
  `:generation`, `:batch`, `:bar`. `:auto` resolves to `:bar` on an interactive terminal
  and `:generation` otherwise. See [`_resolveVerbosity`](@ref).

# Examples
```julia
method = ABCSMC(population_size=200, max_nr_populations=5)
result = runCalibration(problem, method)
df, weights = posterior(result)
```
"""
function runCalibration(problem::CalibrationProblem, method::ABCSMC;
                        description::String="", run_kwargs::NamedTuple=(;),
                        progress::Symbol=:auto)
    verbosity = _resolveVerbosity(progress)
    calibration = createCalibration("ABC-SMC"; description=description)
    _saveMethod(calibration, method)
    _saveProblem(calibration, problem)
    _writeParametersTOML(calibration, problem.parameters)

    param_names = vcat([cp.lv.latent_parameter_names for cp in problem.parameters]...)
    priors      = vcat([cp.lv.latent_parameters      for cp in problem.parameters]...)
    cps         = problem.parameters

    bank           = _buildSimulationBank(problem)
    evaluate_batch = _buildEvaluateBatch(problem, calibration, method.max_nr_populations,
                                         run_kwargs; verbosity=verbosity)
    on_generation  = gen -> _saveGeneration(calibration, gen, method.max_nr_populations, cps)

    generations = _runABCSMC(method, param_names, priors, evaluate_batch, on_generation;
                              bank=bank, verbosity=verbosity)

    return ABCResult(calibration, generations, problem.parameters, method)
end

"""
    runABC(problem::CalibrationProblem; kwargs...) → ABCResult

Run ABC-SMC parameter calibration. Convenience wrapper that constructs an [`ABCSMC`](@ref)
method from keyword arguments and delegates to [`runCalibration`](@ref).

The full `CalibrationProblem` is serialized to `problem.jld2`, enabling
`resumeABC(Calibration(id))` with no further arguments after a crash or session restart.

# Keyword Arguments
- `population_size::Int=100`, `max_nr_populations::Int=10`, `minimum_epsilon::Float64=0.01`,
  `epsilon_quantile::Float64=0.5`, `perturbation_kernel::AbstractKernel=GaussianKernel()`
- `epsilon_schedule::Union{Nothing,Vector{Float64}}=nothing`: explicit decreasing thresholds.
- `min_acceptance_rate::Float64=0.0`, `min_epsilon_decrease::Float64=0.0`,
  `min_ess_fraction::Float64=0.0`: early stopping thresholds.
- `accept_overflow::Bool=false`: when `true`, keep all epsilon-passing particles per batch
  (population_size becomes a minimum, not an exact target).
- `cdf_grid_k::Union{Nothing,Int}=nothing`: base CDF-grid resolution for simulation bank
  snapping. When set, proposals are snapped to a dyadic grid of resolution `2^k` in CDF
  space, tightening by one level each generation. If a `SimulationBank` has compatible
  existing monads, they are reused in preference to running new simulations; an empty
  bank is silently skipped and snapping proceeds normally.
- `max_evaluations::Union{Nothing,Int}=nothing`: maximum total evaluated particles across
  the entire run. Enforced *before* each batch is dispatched — a batch that would exceed the
  budget is trimmed to the remaining allowance, so the run never evaluates more than
  `max_evaluations` simulations — then the run stops (the final generation may have fewer than
  `population_size` accepted particles).
- `run_kwargs::NamedTuple=(;)`: forwarded to each `run(sampling; ...)` call.
- `description::String=""`: stored in the `calibrations` DB row.
- `progress::Symbol=:auto`: console-feedback verbosity (`:auto`, `:none`, `:generation`,
  `:batch`, `:bar`). `:auto` shows a live progress bar on an interactive terminal and
  per-generation milestones otherwise.

# Examples
```julia
result = runABC(problem; population_size=200, max_nr_populations=5)
df, weights = posterior(result)
println("Posterior mean: ", sum(df[!, "overall/max_time"] .* weights))

# Resume after crash
result2 = resumeABC(result.calibration)
```
"""
function runABC(problem::CalibrationProblem;
                population_size::Int=100, max_nr_populations::Int=10,
                minimum_epsilon::Float64=0.01, epsilon_quantile::Float64=0.5,
                perturbation_kernel::AbstractKernel=GaussianKernel(),
                epsilon_schedule::Union{Nothing,Vector{Float64}}=nothing,
                min_acceptance_rate::Float64=0.0,
                min_epsilon_decrease::Float64=0.0,
                min_ess_fraction::Float64=0.0,
                accept_overflow::Bool=false,
                cdf_grid_k::Union{Nothing,Int}=nothing,
                max_evaluations::Union{Nothing,Int}=nothing,
                run_kwargs::NamedTuple=(;),
                description::String="",
                progress::Symbol=:auto)
    method = ABCSMC(; population_size=population_size,
                      max_nr_populations=max_nr_populations,
                      minimum_epsilon=minimum_epsilon,
                      epsilon_quantile=epsilon_quantile,
                      perturbation_kernel=perturbation_kernel,
                      epsilon_schedule=epsilon_schedule,
                      min_acceptance_rate=min_acceptance_rate,
                      min_epsilon_decrease=min_epsilon_decrease,
                      min_ess_fraction=min_ess_fraction,
                      accept_overflow=accept_overflow,
                      cdf_grid_k=cdf_grid_k,
                      max_evaluations=max_evaluations)
    return runCalibration(problem, method; description=description, run_kwargs=run_kwargs,
                          progress=progress)
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

"""
    _saveMethod(calibration::Calibration, method::ABCSMC)

Save the ABCSMC settings to `method.toml` for resume support.
"""
function _saveMethod(calibration::Calibration, method::ABCSMC)
    path = joinpath(calibrationFolder(calibration), "method.toml")
    d = Dict{String,Any}(
        "population_size"     => method.population_size,
        "max_nr_populations"  => method.max_nr_populations,
        "minimum_epsilon"     => method.minimum_epsilon,
        "epsilon_quantile"    => method.epsilon_quantile,
        "perturbation_kernel" => _serializeKernel(method.perturbation_kernel),
        "min_acceptance_rate" => method.min_acceptance_rate,
        "min_epsilon_decrease"=> method.min_epsilon_decrease,
        "min_ess_fraction"    => method.min_ess_fraction,
        "accept_overflow"     => method.accept_overflow,
    )
    if !isnothing(method.epsilon_schedule)
        d["epsilon_schedule"] = method.epsilon_schedule
    end
    if !isnothing(method.cdf_grid_k)
        d["cdf_grid_k"] = method.cdf_grid_k
    end
    if !isnothing(method.max_evaluations)
        d["max_evaluations"] = method.max_evaluations
    end
    if method.store_rejected
        d["store_rejected"] = true
    end
    open(path, "w") do io
        TOML.print(io, d)
    end
end

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
directly inside their `LVSource`; anonymous ones become [`_StrippedLVSource`](@ref).
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
    observed_data::Dict{String,Any}
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

Serialize the `CalibrationProblem` to `problem.jld2` as a [`_ProblemManifest`](@ref).

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

Load `problem.jld2` and return a [`_ProblemManifest`](@ref).
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
human-readable mapping from the display column names used in `generations/generation_NNN.csv`
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
        println(io, "# Display names are used in generations/generation_NNN.csv.")
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

"""
    _findLastGenerationCSVs(calibration) → Union{Nothing, Tuple{String,String}}

Return `(cdf_csv_path, display_csv_path)` for the last saved generation, or `nothing`
if no generations have been written yet.
"""
function _findLastGenerationCSVs(calibration::Calibration)
    gen_dir = joinpath(calibrationFolder(calibration), "generations")
    cdf_dir = joinpath(gen_dir, "generation_cdfs")
    (isdir(gen_dir) && isdir(cdf_dir)) || return nothing
    cdf_files = sort(filter(f -> occursin(r"^generation_\d+\.csv$", f), readdir(cdf_dir)))
    isempty(cdf_files) && return nothing
    last = cdf_files[end]
    cdf_path     = joinpath(cdf_dir, last)
    display_path = joinpath(gen_dir, last)
    isfile(display_path) || return nothing
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
    resumeABC(calibration::Calibration;
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
- `method`: Override the saved ABCSMC settings. If `nothing`, loads from `method.toml`.
- `run_kwargs`: Forwarded to each `run(sampling; ...)` call.
- `progress`: Console-feedback verbosity (`:auto`, `:none`, `:generation`, `:batch`, `:bar`);
  same semantics as in [`runABC`](@ref).

# Examples
```julia
# Session restart — only calibration ID needed (all named functions)
result = resumeABC(Calibration(42))

# Re-supply the problem when anonymous functions were used
result = resumeABC(Calibration(42); problem=my_problem)

# Override max generations on resume
result = resumeABC(Calibration(42); method=ABCSMC(max_nr_populations=15))
```
"""
function resumeABC(calibration::Calibration;
                   problem::Union{Nothing,CalibrationProblem}=nothing,
                   method::Union{Nothing,ABCSMC}=nothing,
                   run_kwargs::NamedTuple=(;),
                   progress::Symbol=:auto)
    verbosity = _resolveVerbosity(progress)
    manifest = _loadProblem(calibration)
    active_problem = _resolveResumeProblem(manifest, problem, calibration)

    m = isnothing(method) ? _loadMethod(calibration) : method

    cps         = active_problem.parameters
    param_names = vcat([cp.lv.latent_parameter_names for cp in cps]...)
    priors      = vcat([cp.lv.latent_parameters      for cp in cps]...)

    start_generations = _loadGenerations(calibration, param_names, m.max_nr_populations)

    if !isempty(start_generations)
        stop_reason = _stoppingReason(m, start_generations)
        if !isnothing(stop_reason)
            _verbosityRank(verbosity) >= _verbosityRank(:generation) &&
                @info "ABC-SMC (resume): $stop_reason — no new generations needed."
            return ABCResult(calibration, start_generations, active_problem.parameters, m)
        end
    end

    bank           = _buildSimulationBank(active_problem)
    evaluate_batch = _buildEvaluateBatch(active_problem, calibration, m.max_nr_populations,
                                         run_kwargs; verbosity=verbosity)
    on_generation  = gen -> _saveGeneration(calibration, gen, m.max_nr_populations, cps)

    generations = _runABCSMC(m, param_names, priors, evaluate_batch, on_generation;
                              bank=bank, start_generations=start_generations, verbosity=verbosity)

    return ABCResult(calibration, generations, active_problem.parameters, m)
end

"""
    _loadMethod(calibration::Calibration) → ABCSMC

Load saved ABCSMC settings from `method.toml`.
"""
function _loadMethod(calibration::Calibration)
    path = joinpath(calibrationFolder(calibration), "method.toml")
    isfile(path) || error("Cannot resume: $path not found. Pass `method=ABCSMC(...)` explicitly.")
    d = TOML.parsefile(path)
    epsilon_schedule  = haskey(d, "epsilon_schedule") ?
        Float64.(d["epsilon_schedule"]) : nothing
    cdf_grid_k        = haskey(d, "cdf_grid_k")        ? Int(d["cdf_grid_k"])        : nothing
    max_evaluations   = haskey(d, "max_evaluations")   ? Int(d["max_evaluations"])   : nothing
    return ABCSMC(
        population_size      = Int(d["population_size"]),
        max_nr_populations   = Int(d["max_nr_populations"]),
        minimum_epsilon      = Float64(d["minimum_epsilon"]),
        epsilon_quantile     = Float64(d["epsilon_quantile"]),
        perturbation_kernel  = _deserializeKernel(d["perturbation_kernel"]),
        epsilon_schedule     = epsilon_schedule,
        min_acceptance_rate  = Float64(get(d, "min_acceptance_rate",  0.0)),
        min_epsilon_decrease = Float64(get(d, "min_epsilon_decrease", 0.0)),
        min_ess_fraction     = Float64(get(d, "min_ess_fraction",     0.0)),
        accept_overflow      = Bool(get(d, "accept_overflow",         false)),
        cdf_grid_k           = cdf_grid_k,
        max_evaluations      = max_evaluations,
        store_rejected       = Bool(get(d, "store_rejected",          false)),
    )
end

################## Generation Persistence ##################

"""
    _generationTag(t, max_nr_populations) → String

Zero-padded generation index string, e.g. `"03"` for t=3, max=10 or `"003"` for max=100.
"""
_generationTag(t::Int, max_nr_populations::Int) =
    lpad(string(t), ndigits(max_nr_populations), '0')

"""
    _generationMonadsPath(calibration, t, max_nr_populations) → String

Path to the monad-ID record for generation `t`: `generations/generation_{NNN}_monads.csv`.
"""
function _generationMonadsPath(calibration::Calibration, t::Int, max_nr_populations::Int)
    tag = _generationTag(t, max_nr_populations)
    return joinpath(calibrationFolder(calibration), "generations", "generation_$(tag)_monads.csv")
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
- `generations/generation_{NNN}.csv`: human-readable display format.
- `generations/generation_cdfs/generation_{NNN}.csv`: raw CDF coordinates for resume.
- `generations/generation_{NNN}.toml`: generation-level metadata.

When called with the 2-directory form `_saveGeneration(dir, cdf_dir, gen, ...)`, the
caller controls both directories (used in tests).
"""
function _saveGeneration(calibration::Calibration, gen::GenerationResult,
                         max_nr_populations::Int,
                         cps::Vector{CalibrationParameter}=CalibrationParameter[])
    dir = joinpath(calibrationFolder(calibration), "generations")
    _saveGeneration(dir, gen, max_nr_populations, cps)
end

# Single-dir form: cdf_dir is a "generation_cdfs" subdirectory of dir.
# Used by tests that only supply one temp directory.
function _saveGeneration(dir::String, gen::GenerationResult, max_nr_populations::Int,
                         cps::Vector{CalibrationParameter}=CalibrationParameter[])
    _saveGeneration(dir, joinpath(dir, "generation_cdfs"), gen, max_nr_populations, cps)
end

function _saveGeneration(dir::String, cdf_dir::String, gen::GenerationResult,
                         max_nr_populations::Int,
                         cps::Vector{CalibrationParameter}=CalibrationParameter[])
    mkpath(dir)
    mkpath(cdf_dir)
    tag = _generationTag(gen.t, max_nr_populations)

    # Raw CDF CSV for resumeABC.
    cdf_df = copy(gen.particles)
    cdf_df[!, :weight]   = gen.weights
    cdf_df[!, :distance] = gen.distances
    cdf_df[!, :monad_id] = gen.monad_ids
    CSV.write(joinpath(cdf_dir, "generation_$tag.csv"), cdf_df)

    # Human-readable display CSV.
    CSV.write(joinpath(dir, "generation_$tag.csv"), _buildDisplayDF(gen, cps))

    # Generation-level TOML.
    open(joinpath(dir, "generation_$tag.toml"), "w") do io
        TOML.print(io, Dict{String,Any}(
            "t"               => gen.t,
            "epsilon"         => gen.epsilon,
            "n_evaluations"   => gen.n_evaluations,
            "acceptance_rate" => gen.acceptance_rate,
            "ess"             => gen.ess,
        ))
    end
end

"""
    _loadGenerations(calibration, param_names, max_nr_populations) → Vector{GenerationResult}

Load saved generation results from `generation_cdfs/` (raw CDF coordinates), reconstructing
the internal particle state needed for `resumeABC`.
"""
function _loadGenerations(calibration::Calibration, param_names::Vector{String},
                          max_nr_populations::Int)
    dir = joinpath(calibrationFolder(calibration), "generations")
    _loadGenerations(dir, param_names, max_nr_populations)
end

function _loadGenerations(dir::String, param_names::Vector{String},
                          max_nr_populations::Int)
    cdf_dir = joinpath(dir, "generation_cdfs")
    !isdir(cdf_dir) && return GenerationResult[]

    # Discover files by scanning the directory so the tag zero-padding from the
    # original run (which may differ from the current max_nr_populations) is not assumed.
    csv_files = filter(f -> occursin(r"^generation_\d+\.csv$", f), readdir(cdf_dir))
    isempty(csv_files) && return GenerationResult[]
    sort!(csv_files, by = f -> parse(Int, match(r"\d+", f).match))

    generations = GenerationResult[]
    for csv_file in csv_files
        tag      = match(r"generation_(\d+)\.csv", csv_file).captures[1]
        t        = parse(Int, tag)
        csv_path = joinpath(cdf_dir, csv_file)

        df        = CSV.read(csv_path, DataFrame)
        weights   = df[!, :weight]
        distances = df[!, :distance]
        monad_ids = df[!, :monad_id]
        particles = select(df, param_names)

        toml_path = joinpath(dir, "generation_$tag.toml")
        meta = TOML.parsefile(toml_path)
        epsilon         = Float64(meta["epsilon"])
        n_evaluations   = Int(meta["n_evaluations"])
        acceptance_rate = Float64(meta["acceptance_rate"])
        ess             = Float64(meta["ess"])

        push!(generations, GenerationResult(t, particles, weights, distances, epsilon,
                                            n_evaluations, monad_ids, acceptance_rate, ess,
                                            nothing))
    end

    return generations
end
