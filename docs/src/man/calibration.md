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

Simulations can and do fail mid-run; calibration treats that as an expected outcome rather than
an error. See [When things go wrong](@ref calibration_troubleshooting) for what gets recorded and
what you can control.

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

## [When things go wrong](@id calibration_troubleshooting)

A calibration run is long, unattended, and made of thousands of simulations, so this section
covers what happens when part of it fails — and which failures stop the run rather than being
absorbed.

### Failed simulations

Every generation's failures are recorded in the calibration folder, next to the monad record:

```
generations/generation_{NNN}_failed_simulations.csv   # simulation IDs that failed
generations/generation_{NNN}_failed_monads.csv        # monads with ≥1 failed simulation
```

Both use the same compressed-ID format as `generation_{NNN}_monads.csv` (read them back with
`ModelManager.constituentIDs(path)`). You get **one warning per generation** pointing at these
files, not one per failure — a population of hundreds proposed against a broken parameter region
would otherwise bury the log. The files are only written when something failed.

A failed simulation's own output folder survives even when its monad does not, so
`data/outputs/simulations/{id}/` is where to look for the cause.

What happens to the particle depends on how much of its monad survived:

| Monad state | Behavior |
| --- | --- |
| At least one simulation completed | Evaluated normally from whatever succeeded. Calibration does **not** re-run to replace lost replicates, so with `n_replicates > 1` a particle may be summarized from fewer than you asked for. |
| No simulation completed | No output exists for `summary_statistic` to read, and the runner has deleted the emptied monad — so the particle is handled by `on_monad_failure` below, without your functions being called at all. |

### `on_monad_failure`

```julia
result = runABC(problem; on_monad_failure=:reject)   # default
result = runABC(problem; on_monad_failure=:error)    # stop at the first one
```

- **`:reject`** records the particle's distance as `missing` — no distance exists — so ABC-SMC
  never accepts it and the run continues.
- **`:error`** stops the run, naming the monad, both failure files, and the output folders of its
  failed simulations. Use it when you want the first failure to be diagnosable rather than
  survivable.

Rejected particles are not replaced, so a generation can hold fewer than `population_size`
particles. Generation 1 proposes exactly `population_size` and keeps those whose monads produced
output, renormalizing the weights over the survivors; later generations keep proposing until the
population is filled and simply never accept a failed monad. A whole later generation of failures
therefore keeps proposing until `max_evaluations` is reached rather than aborting — one bad monad
never ends a run.

### Bugs in your `summary_statistic` or `distance`

For a monad that *does* have output, your two functions are expected to work. If either raises, or
`distance` returns something that is not a `Real`, the run stops immediately with the monad ID
named — regardless of `on_monad_failure`, which governs simulation failures rather than bugs in
your own code. When the monad had some failed replicates, the message says how many, since that is
the likeliest reason otherwise-correct code trips.

### Error messages

| Message | Cause | What to do |
| --- | --- | --- |
| `monad N has no successful simulation` | `on_monad_failure=:error` and every simulation in a proposed monad failed. | Read the failure files and the simulations' `output` folders. Switch to `:reject` to let the run continue past these. |
| `none of the N proposed monads had a successful simulation` | Nothing survived generation 1. | The model or its fixed parameters are broken for the whole prior — not sampling noise. Check that a single simulation at a reference parameter set runs at all. |
| ``Calibration failed while evaluating monad N: `summary_statistic` or `distance` raised`` | Your function threw on a monad that has output. | The original exception and backtrace follow the message. |
| ``distance returned a T, but a `Real` is required`` | `distance` returned a `Dict`, `missing`, `nothing`, … | Return a real number. If you are guarding against missing output yourself, you no longer need to — see the table above. |
| `simulation(s) X … have no row in the simulations table` | A monad's constituent record and the database disagree. | Run `ModelManager.databaseDiagnostics()`. This indicates corrupted bookkeeping, not a failed simulation. |
| `Cannot resume Calibration(N): problem.jld2 contains only a partial manifest` | The original problem used anonymous functions, which JLD2 cannot serialize. | Pass the original problem: `resumeABC(cal; problem=my_problem)`. Define `summary_statistic`/`distance` as named functions to avoid it next time. |

### The run isn't converging

Nothing failed, but the posterior is not tightening. [`ConvergenceSummary`](@ref) and
`plot(result; plot_type=:convergence)` show ε, acceptance rate, and ESS per generation; the
ridgeline plot shows whether successive posteriors are actually narrowing (stagnant adjacent
curves are the ABC-SMC analog of a flat MCMC chain).

- **Acceptance rate collapsing** — ε is tightening faster than the model can follow. Raise
  `epsilon_quantile` toward 1, or supply a gentler `epsilon_schedule`. Set `min_acceptance_rate`
  to stop automatically instead of grinding.
- **ESS far below `population_size`** — a few particles carry all the weight. Try a different
  [perturbation kernel](@ref "Perturbation kernels") (`ComponentwiseKernel` in higher dimensions,
  `LocalNNCovKernel` for anisotropic posteriors) and set `min_ess_fraction`.
- **ε stops decreasing** — you are at the noise floor of the model or the summary statistic.
  Raise `n_replicates`, or set `min_epsilon_decrease` to stop there.
- **`ε = +inf` in a generation's TOML** — your `distance` returned `Inf` for the worst generation-1
  particle, so that generation's threshold accepts everything. The run self-corrects: the next
  generation is effectively a second prior draw, after which the quantile rule pulls ε back to a
  finite value. Cap your distance if you would rather not spend a generation on it.
- **Cost is the problem, not fit** — `max_evaluations` caps total particle evaluations, and
  `cdf_grid_k` reuses nearby monads instead of re-simulating them.

See the [Calibration](@ref calibration_lib) API reference for every type, kernel, and helper.
