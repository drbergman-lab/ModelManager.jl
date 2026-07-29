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

################## Simulation-Failure Reporting ##################
#
# Calibration runs each batch with `quiet=true`, which suppresses the runner's own
# low-success notice, so failed simulations would otherwise pass unmentioned. Every
# generation's failed simulation IDs — and the IDs of monads with at least one failure —
# are written to the calibration folder instead, and reported here once per generation:
# a population of hundreds proposed against a broken parameter region should not emit
# hundreds of warnings.

"""
    _warnFailuresRecorded(verbosity, t, warned_generations, sim_path, monad_path)

Warn, at most once per generation, that failed simulation and monad IDs for generation `t`
have been recorded to `sim_path` and `monad_path`. Generations already reported are tracked
in `warned_generations`. Silent when `verbosity` is `:none`.
"""
function _warnFailuresRecorded(verbosity::Symbol, t::Int, warned_generations::Set{Int},
                               sim_path::AbstractString, monad_path::AbstractString)
    _verbosityRank(verbosity) >= _verbosityRank(:generation) || return nothing
    t in warned_generations && return nothing
    push!(warned_generations, t)
    @warn """
    ABC-SMC generation $t: some simulations failed. Their IDs, and the IDs of the monads \
    they belong to, are recorded in
      - $sim_path
      - $monad_path
    Later failures in this generation are added to those files without another warning. \
    Monads left with no successful simulation are rejected (distance = Inf) unless \
    `on_evaluation_failure=:error`.
    """
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
