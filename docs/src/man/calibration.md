```@meta
CurrentModule = ModelManager
```

# [Calibration](@id calibration_man)

Calibration infers model parameters from data: given an observed summary statistic, find the
parameter distributions that make the model reproduce it. ModelManager implements
**Approximate Bayesian Computation — Sequential Monte Carlo (ABC-SMC)**, a likelihood-free
method that works for any simulator because it only needs to *run* the model and *compare*
its output to data.

The workflow has three pieces: define a [`CalibrationProblem`](@ref), choose a method
([`ABCSMC`](@ref)), and run it with [`runABC`](@ref) (or [`runCalibration`](@ref)).

## Defining the problem

A [`CalibrationProblem`](@ref) bundles the model, the parameters to infer, the data, and how
to compare:

```julia
using Distributions

# Fix non-calibrated parameters via a reference monad (n_replicates=0 just records the IDs).
ref = createTrial(inputs, DiscreteVariation(:config, XMLPath(["overall","max_time"]), 120.0);
                  n_replicates=0)

observed = Dict("default" => 100.0)

# The parameter to infer (a rate, say), addressed by its XMLPath.
xml_path = XMLPath(["cell_definitions", "cell_definition:name:tumor", "phenotype", "death", "rate"])

problem = CalibrationProblem(
    ref,                                              # base inputs + fixed parameters
    [DistributedVariation(:config, xml_path, Uniform(1e-7, 1e-4))],  # parameters to infer
    observed,                                         # observed data
    monad_id -> summarize(monad_id),                 # summary statistic
    mseDistance,                                      # distance function
)
```

The parameters can be any mix of [`DistributedVariation`](@ref),
[`CoVariation`](@ref){[`DistributedVariation`](@ref)}, or
[`LatentVariation`](@ref){<:Distribution} — they are converted to the internal
[`CalibrationParameter`](@ref) representation automatically.

Two functions you supply:

- **`summary_statistic`** — `monad_id -> T`. Called once per proposed particle; you decide how
  to aggregate over the monad's replicate simulations (average, pick one, etc.).
- **`distance`** — `(simulated, observed) -> Float64`. The built-in [`mseDistance`](@ref)
  handles `Dict`, `Vector`, and scalar inputs; supply your own for anything else.

Set `n_replicates > 1` in the problem to average out stochastic noise per particle (at N×
the compute cost).

## Choosing the method

[`ABCSMC`](@ref) controls the SMC run. The defaults are reasonable; the most common knobs:

```julia
method = ABCSMC(
    population_size  = 200,    # accepted particles per generation
    max_nr_populations = 15,   # max SMC generations
    minimum_epsilon  = 0.005,  # stop when accepted distance reaches this floor
)
```

Each generation accepts the `population_size` best particles, then tightens the acceptance
threshold (epsilon) toward `minimum_epsilon`. By default the next threshold is the median of
accepted distances (`epsilon_quantile`); you can instead supply an explicit
`epsilon_schedule`.

### Stopping criteria

Beyond `minimum_epsilon` and `max_nr_populations`, you can stop early when the run stops
making progress:

- `min_acceptance_rate` — stop when accepted/proposed drops below this.
- `min_epsilon_decrease` — stop when epsilon's relative decrease per generation is too small.
- `min_ess_fraction` — stop when the effective sample size falls below this fraction of
  `population_size`.
- `max_evaluations` — a hard cap on total particle evaluations across the whole run. It is
  checked *before* each batch is dispatched: a batch that would exceed the budget is trimmed to
  the remaining allowance, so the run never evaluates more than `max_evaluations` simulations
  (the final generation may hold fewer than `population_size` particles).

### Perturbation kernels

Between generations, resampled particles are perturbed by a kernel. Choose one based on how
the posterior is shaped:

| Kernel | Behavior |
| --- | --- |
| [`GaussianKernel`](@ref) | Global multivariate Gaussian (twice the weighted covariance). Default. |
| [`ComponentwiseKernel`](@ref) | Independent per-parameter perturbation. |
| [`LocalNNKernel`](@ref) | Local scale from each particle's `k` nearest neighbors. |
| [`LocalNNCovKernel`](@ref) | Local covariance from `k` nearest neighbors. |

```julia
method = ABCSMC(population_size=200, perturbation_kernel=LocalNNKernel(k=15))
```

## Running

```julia
result = runABC(problem; method=method, progress=:auto)
# or equivalently
result = runCalibration(problem, method)
```

`progress` controls console output: `:auto` (a live progress bar on a TTY, generation logs
otherwise), `:none`, `:generation`, `:batch`, or `:bar`. Particle evaluations run through the
ordinary [parallel runner](@ref "Running simulations"), so calibration benefits from
[`setNumberOfParallelSims`](@ref) and [HPC](@ref "HPC support") just like any other trial.

### When simulations fail

Simulators do fail on parameter values drawn from the tails of a prior, so calibration treats
this as expected rather than exceptional.

Every generation's failures are recorded in the calibration folder, alongside the monad record:

```
generations/generation_{NNN}_failed_simulations.csv   # simulation IDs that failed
generations/generation_{NNN}_failed_monads.csv        # monads with at least one failure
```

Both use the same compressed-ID format as `generation_{NNN}_monads.csv`, and you get one warning
per generation pointing at them — not one per failure.

A monad that keeps at least one successful simulation is evaluated normally, from whatever
succeeded; calibration does not re-run to replace the lost replicates. A monad whose simulations
*all* fail has no output for `summary_statistic` to read at all — the runner deletes the emptied
monad, so even `Monad(monad_id)` would throw — so `on_evaluation_failure` decides what to do:

```julia
result = runABC(problem; on_evaluation_failure=:reject)   # default
result = runABC(problem; on_evaluation_failure=:error)    # stop on the first one
```

- `:reject` records the particle's distance as `missing` — no distance exists — so ABC-SMC never
  accepts it and the run continues. `missing` rather than a sentinel like `Inf`, which is a value
  your own `distance` function is entitled to return.
- `:error` stops the run, naming the monad, the two failure files, and the output folders of its
  failed simulations (those survive even though their monad does not).

A later generation in which every particle fails keeps proposing until `max_evaluations` is
reached, so one bad monad never ends a run. Generation 1 is the exception — it has no acceptance
threshold, so if no monad there succeeds the run errors out rather than continuing with an empty
population.

One consequence of ε being the largest accepted distance: if your `distance` returns `Inf` or
`NaN` for any generation-1 particle, ε itself would be non-finite and every later proposal would
pass `distance <= ε` regardless of fit. Rather than degenerate silently, the run stops and says
so — have `distance` return a finite value (capped, if need be) across the prior support.

### Your functions must produce a real distance

For a monad that *does* have output, `summary_statistic` and `distance` are expected to work. If
either raises, or `distance` returns something that is not a `Real`, the run stops immediately
with the monad ID named — regardless of `on_evaluation_failure`, which governs simulation
failures rather than bugs in your own functions. This is deliberate: a `missing` returned from a
summary statistic used to travel a long way into the ABC-SMC internals before surfacing as an
unrelated `MethodError`.

## The simulation bank and CDF-grid reuse

Calibration can evaluate thousands of particles, many close together in parameter space.
Setting `cdf_grid_k` on the method snaps proposals onto a dyadic grid in CDF space and reuses
previously evaluated monads within a small box (the [`SimulationBank`](@ref)), avoiding
redundant simulations. The grid refines each generation, so early generations are cheap and
later ones precise. See the [`ABCSMC`](@ref) docstring for the exact semantics.

Only monads with at least one simulation that is running or completed are eligible for reuse —
there is nothing to gain from snapping onto a monad whose simulations have not started, and a
monad whose simulations all failed no longer exists.

## Results and resuming

[`runABC`](@ref) returns an [`ABCResult`](@ref). Inspect the inferred posterior with
[`posterior`](@ref) and the run's diagnostics with [`ConvergenceSummary`](@ref):

```julia
post = posterior(result)                 # final-generation posterior
post = posterior(result; generation=3)   # a specific generation
summary = ConvergenceSummary(result)
```

Calibration state is persisted (generation CSVs, the problem manifest, and `method.toml`)
under a [`Calibration`](@ref) record in the database, so an interrupted run can be resumed:

```julia
result = resumeABC(Calibration(calibration_id))   # no need to re-supply the problem
```

## Visualizing

When a plotting backend is loaded, [RecipesBase](https://github.com/JuliaPlots/RecipesBase.jl)
recipes turn an [`ABCResult`](@ref) or [`Calibration`](@ref) into standard diagnostics:

```julia
using Plots
plot(result; plot_type=:corner)        # pairwise posterior
plot(result; plot_type=:ridgeline)     # posterior narrowing across generations
plot(result; plot_type=:convergence)   # epsilon / acceptance / ESS over generations
plot(result; plot_type=:transition)    # accepted vs. rejected proposals per generation
```

See the [Calibration](@ref calibration_lib) API reference for every type, kernel, and helper.
