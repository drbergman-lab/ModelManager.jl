# Imported as a qualified module (not `using ... : next!`) because `Sobol.next!` is also
# in scope in this package — pulling ProgressMeter's `next!` into the namespace would
# shadow the SobolSeq iterator used by `_runFirstGeneration`.
import ProgressMeter

################## Calibration Progress Reporting ##################
#
# Console feedback for long-running calibration. Three verbosity tiers stack on
# top of `:none`:
#
#   :none        — completely silent.
#   :generation  — one line when each generation starts and finishes.
#   :batch       — the above plus one line per evaluation batch.
#   :bar         — the above plus a live per-simulation progress bar (ProgressMeter)
#                  spanning each batch's pending simulations.
#
# `:auto` (the default) resolves to `:bar` on an interactive TTY and `:generation`
# otherwise, so SLURM/redirected logs get clean textual milestones instead of
# carriage-return bar spam.
#
# The bar is driven by the generic `on_progress` hook on `run` (see runner.jl):
# `run` emits `:init`/`:step`/`:finish` events; the renderer here turns them into a
# ProgressMeter bar. This keeps the runner framework-agnostic.

const _CALIBRATION_VERBOSITY_LEVELS = (:none, :generation, :batch, :bar)

# Integer rank used to gate which milestones print. Higher tiers include all lower ones.
_verbosityRank(v::Symbol) = something(findfirst(==(v), _CALIBRATION_VERBOSITY_LEVELS), 1) - 1

"""
    _resolveVerbosity(progress::Symbol) → Symbol

Resolve a user-supplied `progress` setting to a concrete verbosity level. `:auto`
becomes `:bar` when `stdout` is an interactive terminal and `:generation` otherwise.
Any of `:none`, `:generation`, `:batch`, `:bar` pass through unchanged. Throws an
`ArgumentError` on an unrecognized value.
"""
function _resolveVerbosity(progress::Symbol)
    progress === :auto && return (stdout isa Base.TTY) ? :bar : :generation
    progress in _CALIBRATION_VERBOSITY_LEVELS || throw(ArgumentError(
        "Unknown progress setting :$progress. " *
        "Expected one of :auto, :none, :generation, :batch, :bar."))
    return progress
end

"""
    _logGenerationStart(verbosity, t, epsilon, population_size)

Emit the generation-start milestone when `verbosity` is `:generation` or higher.
`epsilon` is the target acceptance threshold for generations `t > 1`, or `nothing`
for generation 1 (prior sampling, no threshold yet).
"""
function _logGenerationStart(verbosity::Symbol, t::Int, epsilon::Union{Nothing,Float64},
                             population_size::Int)
    _verbosityRank(verbosity) >= _verbosityRank(:generation) || return nothing
    if isnothing(epsilon)
        @info "ABC-SMC generation $t starting: sampling $population_size particles from the prior…"
    else
        @info "ABC-SMC generation $t starting: " *
              "target ε=$(round(epsilon; digits=6)), population_size=$population_size"
    end
    return nothing
end

"""
    _logBatchStart(verbosity, t, batch_index, n_proposals)

Emit the batch-start milestone when `verbosity` is `:batch` or higher.
"""
function _logBatchStart(verbosity::Symbol, t::Int, batch_index::Int, n_proposals::Int)
    _verbosityRank(verbosity) >= _verbosityRank(:batch) || return nothing
    @info "ABC-SMC generation $t · batch $batch_index: " *
          "evaluating $n_proposals proposal$(n_proposals == 1 ? "" : "s")…"
    return nothing
end

################## Evaluation-Failure Reporting ##################
#
# A proposed particle can fail to produce a distance: every simulation in its monad may
# fail (the runner then deletes the emptied monad, so the user's `summary_statistic`
# throws or returns `missing`), or the user's own `summary_statistic`/`distance` may
# raise for a monad that is otherwise intact. Under `on_evaluation_failure=:reject` the
# particle is assigned `Inf` and the run continues; these helpers report it.
#
# Warnings are throttled to the first `_MAX_REJECTION_WARNINGS` per generation — a large
# population with a systematically broken region would otherwise bury the log — and the
# per-generation total is reported once the generation completes.

const _MAX_REJECTION_WARNINGS = 5

"""
    _warnParticleRejected(verbosity, t, n_rejected, monad_id, sim_ids, monad_deleted, err)

Warn that a particle was rejected because its evaluation raised. `n_rejected` is the
running count of rejections in generation `t` **including this one**; warnings are
suppressed past `_MAX_REJECTION_WARNINGS`. `sim_ids` are the monad's simulation IDs as
snapshotted *before* the batch ran (they are unrecoverable afterwards if the monad was
deleted). `monad_deleted` selects the diagnosis: a vanished monad means every simulation
failed, whereas an intact monad points at the user's `summary_statistic`/`distance` or at
missing simulation output. Silent when `verbosity` is `:none`.
"""
function _warnParticleRejected(verbosity::Symbol, t::Int, n_rejected::Int, monad_id::Int,
                               sim_ids::AbstractVector{<:Integer}, monad_deleted::Bool,
                               err)
    _verbosityRank(verbosity) >= _verbosityRank(:generation) || return nothing
    n_rejected > _MAX_REJECTION_WARNINGS && return nothing

    diagnosis = if monad_deleted
        folders = join(["  - $(trialFolder(Simulation, sid))" for sid in sim_ids], "\n")
        """
        Monad $monad_id is no longer in the database: all $(length(sim_ids)) of its \
        simulations failed, so the emptied monad was deleted. Check the simulation output \
        folders for the cause:
        $folders
        """
    else
        """
        Monad $monad_id is still in the database, so this is not a wholesale simulation \
        failure. Either some of its simulations produced no usable output, or \
        `summary_statistic`/`distance` has a bug. Re-run with \
        `on_evaluation_failure=:error` to get the full backtrace.
        """
    end

    throttle_note = n_rejected == _MAX_REJECTION_WARNINGS ?
        "\nFurther rejection warnings for generation $t are suppressed; " *
        "the total is reported when the generation finishes." : ""

    @warn """
    ABC-SMC generation $t: rejecting a particle (distance = Inf) — evaluating monad \
    $monad_id raised.
    $diagnosis
    Cause: $(sprint(showerror, err))$throttle_note
    """
    return nothing
end

"""
    _logGenerationRejections(verbosity, t, n_rejected)

Report the total number of particles rejected due to failed evaluation in generation `t`.
No output when `n_rejected` is zero or `verbosity` is `:none`.
"""
function _logGenerationRejections(verbosity::Symbol, t::Int, n_rejected::Int)
    n_rejected > 0 || return nothing
    _verbosityRank(verbosity) >= _verbosityRank(:generation) || return nothing
    @warn "ABC-SMC generation $t: $n_rejected particle$(n_rejected == 1 ? "" : "s") " *
          "rejected because their evaluation failed (distance set to Inf)."
    return nothing
end

"""
    _warnBatchSimulationFailures(verbosity, t, batch_index, n_success, n_scheduled)

Warn when a batch's `run` completed fewer simulations than it scheduled. Calibration runs
each batch with `quiet=true`, which suppresses the runner's own low-success notice, so
without this the first sign of trouble is a failed particle evaluation (or none at all,
when a monad retains enough successful replicates). Silent when `verbosity` is `:none`.
"""
function _warnBatchSimulationFailures(verbosity::Symbol, t::Int, batch_index::Int,
                                      n_success::Int, n_scheduled::Int)
    n_success < n_scheduled || return nothing
    _verbosityRank(verbosity) >= _verbosityRank(:generation) || return nothing
    @warn "ABC-SMC generation $t · batch $batch_index: only $n_success of $n_scheduled " *
          "scheduled simulations completed successfully. Check the failed simulations' " *
          "output folders under $(joinpath(dataDir(), "outputs", "simulations"))."
    return nothing
end

"""
    _batchProgressCallback(verbosity, desc) → Union{Nothing,Function}

Build the `on_progress` callback passed to `run` for a single evaluation batch.

Returns `nothing` unless `verbosity` is `:bar`, in which case it returns a closure that
lazily constructs a `ProgressMeter.Progress` on the `:init` event (sized to the
batch's pending simulation count), advances it on each `:step`, and finalizes it on
`:finish`. `desc` labels the bar (e.g. `"  gen 2 batch 1 "`).

When a batch has zero pending simulations (all monads reused), no bar is created.
"""
function _batchProgressCallback(verbosity::Symbol, desc::AbstractString)
    verbosity === :bar || return nothing
    bar = Ref{Union{Nothing,ProgressMeter.Progress}}(nothing)
    return function (event::Symbol, n::Int=0)
        if event === :init
            n > 0 && (bar[] = ProgressMeter.Progress(n; desc=desc, dt=0.5, showspeed=true))
        elseif event === :step
            isnothing(bar[]) || ProgressMeter.next!(bar[])
        elseif event === :finish
            isnothing(bar[]) || ProgressMeter.finish!(bar[])
        end
        return nothing
    end
end
