```@meta
CurrentModule = ModelManager
```

# Sensitivity analysis

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
- `functions` — output functions of the form `monad_id -> Real`. Each defines one scalar
  output whose sensitivity to the inputs is computed.

`run` builds the appropriate sampling design, runs the simulations, evaluates your output
functions, and returns a [`GSASampling`](@ref) result holding the sensitivity indices.

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

- [`calculateGSA!`](@ref) — (re)compute indices for a set of output functions.
- [`getMonadIDDataFrame`](@ref) — the monad-ID design matrix used.
- [`simulationIDs`](@ref) — the simulations that were run.
- [`methodString`](@ref) — a label for the method/design.

Because GSA is built on the same [space-filling designs](@ref "Space-filling designs") and the
same [runner](@ref "Running simulations"), its simulations are deduplicated and reused like any
other trial. See the [Sensitivity analysis](@ref) API reference for full details.

## Visualizing

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
