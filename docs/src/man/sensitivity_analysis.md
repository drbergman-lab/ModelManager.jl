```@meta
CurrentModule = ModelManager
```

# [Sensitivity analysis](@id sensitivity_analysis)

Global sensitivity analysis (GSA) asks how much each input parameter contributes to the
variability of a model output. ModelManager provides three generic GSA methods that work with
any backend: Morris one-at-a-time screening, Sobol' variance decomposition, and RBD-FAST.

All three are subtypes of [`GSAMethod`](@ref) and share one entry point — [`run`](@ref):

```julia
run(method, inputs, variations; functions = [f1, f2, ...])
```

- `inputs` — the base [`InputFolders`](@ref) (or a reference monad).
- `variations` — the parameters to analyze, as [`DistributedVariation`](@ref)s (or
  [`CoVariation`](@ref)s), so each can be sampled across its range.
- `functions` — output functions of the form `simulation -> Real`, or [`QoI`](@ref)s. Each is called
  once per *simulation* with a [`Simulation`](@ref), and the values are combined over a monad's
  replicates by the default per-key mean — pass a `QoI` with `reduce=` to choose another.

`run` builds the appropriate sampling design, runs the simulations, evaluates your output
functions, and returns a [`GSASampling`](@ref) result holding the sensitivity indices.

## One measurement, several quantities

An entry of `functions` need not define a single output. If a `QoI`'s value is a `Dict` or
`NamedTuple` instead of a number, each key becomes its own sensitivity analysis, labelled
`"<qoi name>.<key>"`:

```julia
counts = QoI("counts", finalPopulationCount)    # Dict("tumor" => …, "immune" => …)

gsa = run(MOAT(15), inputs, dists; functions=[counts])
ModelManager.gsaLabels(gsa)     # ["counts.immune", "counts.tumor"]
gsa.results["counts.tumor"]
```

The default `reduce` already averages a keyed value per key, so a keyed measurement needs no
reducer of its own. This is what lets the same measurement feed all three consumers: the sink stores
`counts.tumor` per simulation, sensitivity analysis reports `counts.tumor` per parameter set, and
calibration compares the key `"tumor"` — the same quantity at three granularities rather than three
things sharing a name.

What a `QoI` may hand back is one rule everywhere — a `Real`, or a flat `Dict`/`NamedTuple` of
`Real`s — and `reduce` keeps the shape it was given. Two constraints follow from what a sensitivity
index needs on top of that:

- **Every monad must produce the same keys.** Each key's indices are computed over a value from every
  monad in the design, so a monad missing one leaves a hole, and there is no fill that makes the
  answer merely approximate rather than wrong. A mismatch is refused, naming both key sets.
- **A monad whose value is `missing` is refused too** — every one of its replicates declined to
  produce a value, and a sensitivity index has no cell to put that in. Calibration can absorb a
  `missing` (the particle is rejected); an index cannot.

A `Vector` is not a QoI value at all, and the reason is the same one: only its length could be
checked against the other monads', and equal length is not equal meaning — two series sampled at
different times have the same length and different contents. Return a `Dict` whose keys name the
components; you know what they mean, and the framework does not.

!!! note "A score computed after averaging"
    Sensitivity analysis on a discrepancy-to-data score is the case where the order matters:
    averaging squared errors is not the same number as squaring the averaged error, and a
    per-simulation `compute` has no access to the mean. Because `reduce` must keep its shape, the
    score travels as one more *key* rather than as the whole return — `compute` reports the raw
    quantities plus its own per-simulation score, and `reduce` averages the raw quantities and
    recomputes the score from those means. The analysis is then `"<name>.my_dist"` alongside
    `"<name>.tumor"`, and the sink gets a per-simulation score for free. The
    [Calibration](@ref calibration_man) page works the pattern through end to end.

A QoI's `name` may not contain a `.`, since that is the separator: reserving it is what lets a label
be read back to the QoI that produced it, and so what lets [`calculateGSA!`](@ref) decide from a name
alone whether that measurement has already been evaluated.

## MOAT — Morris screening

[`MOAT`](@ref) (Morris One-At-A-Time) is a cheap screening method: it perturbs one parameter
at a time around a set of base points and measures the resulting "elementary effects." Good
for quickly ranking which parameters matter before committing to a more expensive analysis.

```julia
gsa = run(MOAT(15), inputs, [dist1, dist2, dist3]; functions=[final_count])
gsa = run(MOAT(10; add_noise=true), inputs, dists; functions=[final_count])
```

The integer is the number of base points (trajectories).

## Sobol' — variance decomposition

[`Sobolʼ`](@ref) computes variance-based first-order and total-order indices: the fraction of
output variance attributable to each parameter alone, and including all its interactions.

```julia
gsa = run(Sobolʼ(256), inputs, dists; functions=[final_count])
gsa = run(Sobolʼ(256; sobol_index_methods=(first_order=:Jansen1999, total_order=:Jansen1999)),
          inputs, dists; functions=[final_count])
```

!!! note "Typing the name"
    The type is spelled `Sobolʼ` (with a rasp/prime, `\rasp<tab>` in the Julia REPL or VS
    Code) to avoid clashing with the `Sobol` package. The ASCII alias [`SobolMM`](@ref) is
    identical if you prefer to avoid the Unicode character.

## RBD-FAST

[`RBD`](@ref) (Random Balance Design / Fourier Amplitude Sensitivity Test) estimates
first-order indices from a single design by analyzing the output's frequency content.

```julia
gsa = run(RBD(128), inputs, dists; functions=[final_count])
gsa = run(RBD(128; num_harmonics=10), inputs, dists; functions=[final_count])
```

## Working with the result

The returned [`GSASampling`](@ref) carries the underlying [`Sampling`](@ref) and the computed
indices. Helpers include:

- [`gsaLabels`](@ref) — the labels of the analyses computed, sorted. Each indexes `gsa.results`.
- [`calculateGSA!`](@ref) — compute indices for a set of output functions, filing them under their
  labels. A measurement already evaluated is skipped, so adding a quantity later costs only the new
  one. Pass `recompute=true` when the measurement itself has changed — nothing can detect that, since
  redefining a function's body in place leaves it indistinguishable from the one already evaluated.
- [`getMonadIDDataFrame`](@ref) — the monad-ID design matrix used.
- [`simulationIDs`](@ref) — the simulations that were run.
- [`methodString`](@ref) — a label for the method/design.

Indices themselves live in `gsa.results`, a `Dict` keyed by those labels — one entry per quantity,
which is one per `functions` entry unless a `QoI` spread into several.

Because GSA is built on the same [space-filling designs](@ref space_filling) and the
same [runner](@ref running_simulations), its simulations are deduplicated and reused like any
other trial. See the [Sensitivity analysis (GSA)](@ref sensitivity_lib) API reference for full details.

## [Visualizing GSA results](@id gsa_plots)

When a plotting backend is loaded, [RecipesBase](https://github.com/JuliaPlots/RecipesBase.jl)
recipes turn each sampling result into a sensitivity chart. Every recipe draws one series per
output function in the result (the series label includes the function name when more than one
function was supplied); the x-axis is the varied parameters.

```julia
using Plots

# MOAT (Morris) — three chart styles selected by a positional symbol
plot(moat)                       # :bar (default) — µ* per parameter
plot(moat; show_sigma=true)      # add σ as ±whiskers on the µ* bars
plot(moat, :scatter)             # classic µ*–σ screening scatter, points labeled
plot(moat, :violin)              # full elementary-effect distribution per parameter

# Sobol' — first-order (S1) bars, with total-order (ST) overlaid at reduced opacity
plot(sobol)                      # S1 + ST
plot(sobol; show_ST=false)       # S1 only

# RBD — first-order index bars
plot(rbd)
```

The `:violin` style needs a backend that provides the `:violin` series type (e.g.
[StatsPlots](https://github.com/JuliaPlots/StatsPlots.jl)); the others work with any
Plots- or Makie-compatible backend. See [`MOATSampling`](@ref), [`SobolSampling`](@ref),
and [`RBDSampling`](@ref) for the full recipe documentation.
