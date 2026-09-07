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
using Distributions, CSV, DataFrames, Statistics

# Fix non-calibrated parameters via a reference monad (n_replicates=0 just records the IDs).
ref = createTrial(inputs, DiscreteVariation(:config, XMLPath(["overall","max_time"]), 120.0);
                  n_replicates=0)

# Your own per-simulation measurement: reach into this simulation's output and return a number.
# Parsing raw output is the backend's job, so in practice you would call the loader your simulator
# package provides (keyed by `simulationID`); this reads a summary file the simulator wrote.
function measureTumor(sim::Simulation)
    counts = joinpath(pathToOutputFolder(sim), "final_cell_counts.csv") |> CSV.File |> DataFrame
    return Float64(only(counts[counts.cell_type .== "tumor", :count]))
end

# One `Real`-valued quantity, so `observed` is the bare value it should match. `distance` always
# receives a `SummaryValues`; a keyed QoI — or a vector of QoIs — puts several values in it, and
# `observed` is then keyed to match.
observed = 100.0

# The parameter to infer (a rate, say), addressed by its XMLPath.
xml_path = XMLPath(["cell_definitions", "cell_definition:name:tumor", "phenotype", "death", "rate"])

problem = CalibrationProblem(
    ref,                                              # base inputs + fixed parameters
    [DistributedVariation(:config, xml_path, Uniform(1e-7, 1e-4))],  # parameters to infer
    observed,                                         # observed data
    QoI("tumor", measureTumor),                       # summary statistic, per simulation
    mseDistance,                                      # distance function
)
```

The parameters can be any mix of [`DistributedVariation`](@ref), [`DiscreteVariation`](@ref), a
[`CoVariation`](@ref) of either, or [`LatentVariation`](@ref){<:Distribution} — they are converted
to the internal [`CalibrationParameter`](@ref) representation automatically. A discrete parameter
needs at least two levels; one that can never vary is rejected rather than given a particle
coordinate no proposal can move, so set such a value in the reference monad instead.

Two functions you supply:

- **`summary_statistic`** — a [`QoI`](@ref), or a vector of them (a bare function is wrapped into
  one). Each QoI's `compute` is called once per *simulation* with a [`Simulation`](@ref), and its
  replicates are combined by that QoI's `reduce` — the per-key mean by default; pass `reduce=` for
  anything else, and note it receives every replicate's value, so a step that must happen *after*
  averaging goes there. A replicate whose `compute` returned `missing` is dropped before `reduce`
  runs, unless the QoI was built with `skip_missing=false`, which hands the reducer the raw vector
  so it can see how many replicates had no value; a reducer may itself return `missing` to say the
  survivors are too few to answer with.
- **`distance`** — `(simulated, observed) -> Float64`. `simulated` is always a
  [`SummaryValues`](@ref), holding whatever each QoI's `reduce` returned: calibration is the one
  consumer that requires nothing of those values, because your `distance` is their only reader. The
  built-in [`mseDistance`](@ref) compares the summary against a keyed `observed_data` or, when the
  summary holds exactly one value, against a bare one — a number, or an array against an array;
  supply your own for anything else.

### [The keys `distance` sees](@id calibration_keys)

**Every value is named by the QoI that produced it and the key that QoI gave it.** `distance`
receives a [`SummaryValues`](@ref) keyed by those `(qoi name, key)` pairs — the same pairs the
[sink](@ref post_processing) turns into columns and [sensitivity analysis](@ref
sensitivity_analysis) into labels. So one QoI is the same quantity in all three, and two QoIs may be
keyed the same way without colliding.

Three spellings resolve, in this order:

1. `"counts"` — a `Real`-valued QoI, by its own name;
2. `"counts.tumor"` — the qualified spelling, identical to the sink column and the GSA label;
3. `"tumor"` — the bare component key, when exactly one QoI reports it.

A `Symbol` is stringified, so a `NamedTuple`-valued measurement's `(; tumor = …)` answers to
`"tumor"`. An exact `("counts", "tumor")` tuple skips resolution entirely.

```julia
counts  = QoI("counts", finalPopulationCount)          # Dict("tumor" => …, "immune" => …)
observed = Dict("tumor" => 320.0, "immune" => 102.0)   # bare keys: only one QoI reports them
problem  = CalibrationProblem(spec, observed, counts, mseDistance)
```

**When a bare key belongs to two QoIs, it is ambiguous and refused** — with the qualified labels to
choose between, rather than one of them picked silently:

```julia
# `count` and `speed`, both keyed by cell type
observed = Dict("count.tumor" => 320.0, "count.immune" => 102.0,
                "speed.tumor" => 1.4,   "speed.immune" => 0.9)
problem  = CalibrationProblem(spec, observed, [count, speed], mseDistance)   # a vector of two QoIs
```

**The observed keys are the comparison.** [`mseDistance`](@ref) walks `observed_data` and resolves
each key against the summary; components of the summary that no observed key named are simply not
compared. That is the ordinary case rather than a mistake — a simulation is always known better than
the data, so a summary reporting six cell types against an observation of two is a calibration
against two. A key the summary cannot resolve is still an error: there is no fill that turns a
naming mistake into a comparison.

Two spellings of one entry in a single `observed_data` — `"tumor"` and `"counts.tumor"` — are
refused, since that component would be compared twice and weighted double.

**A value need not be a number.** The summary holds whatever `reduce` returned, so a QoI reducing to
`Dict("tumor" => Vector{Float64})` gives `distance` one time series per cell type;
[`mseDistance`](@ref) compares each against the observed series elementwise. Its total is divided by
the number of *differences* it computed, so one array key gives exactly the mean squared error over
that array, and a 100-point series contributes 100 differences where a scalar key contributes one.
Weight them yourself if that is not what you want.

Set `n_replicates > 1` in the problem to average out stochastic noise per particle (at N×
the compute cost).

### [Comparing after averaging](@id calibration_nonlinearity)

Squaring is nonlinear, so the mean of the squared errors is not the square of the mean error. When
the quantity you want is a discrepancy-to-data score, you almost always want the replicates
*averaged first* and compared afterwards — and a per-simulation `compute` cannot do that, because it
has no access to the mean. `reduce` can, because it receives every replicate.

`reduce` may return the score by itself — nothing requires it to be shaped like the values it was
given. Carrying it as one more **key** alongside the raw counts is what earns you the other two
consumers: sensitivity analysis then asks which parameters move the score, and the sink stores a
per-simulation one for free. That is the version worked through here. `compute` reports the raw
counts plus its own per-simulation score; `reduce` averages the counts and recomputes the score from
those means. The observation the score is measured against goes in the QoI's `data` slot. Supplying
`data` is what switches both functions to a two-argument form — a QoI without it keeps one-argument
functions, so nothing about an ordinary QoI changes:

```julia
obs = Dict("tumor" => 320.0, "immune" => 102.0)   # data from experiment

myDistance(sim_data, obs_data) = sum((obs_data[ct] - sim_data[ct])^2 for ct in keys(obs_data))

function fitCompute(sim::Simulation, obs_data)
    counts = countByCellType(sim, :final)          # Dict("tumor" => …, "immune" => …)
    return merge(counts, Dict("my_dist" => myDistance(counts, obs_data)))
end

function fitReduce(per_sim, obs_data)
    means = Dict(k => mean(d[k] for d in per_sim) for k in keys(obs_data))
    return merge(means, Dict("my_dist" => myDistance(means, obs_data)))
end

fit = QoI("fit", fitCompute; reduce = fitReduce, data = obs)
problem = CalibrationProblem(spec, obs, fit, (simulated, _observed) -> simulated["fit.my_dist"])
```

One QoI now serves all three consumers: the sink stores a per-simulation `fit.my_dist` alongside
`fit.tumor`, sensitivity analysis asks which parameters move `fit.my_dist`, and the problem's own
`distance` is the trivial lookup above, because the comparison already happened where it had access
to the means. `observed_data` is still what `distance` compares against — here it is unused, since
the score already carries the comparison, but a problem that wants both can key it normally.

!!! note "Why `data=` rather than a closure"
    `sim -> …` capturing `obs` would work, and would not survive a resume. `problem.jld2` stores
    `nothing` for an anonymous `summary_statistic`, so a bare
    `resumeCalibration(Calibration(id))` refuses and demands `problem=` — and a long calibration is
    exactly the thing that gets interrupted. With `data=`, both functions stay named, and the data
    itself is serialized inside the `QoI`, so the problem restores with the observation intact.
    `data` changes the calling convention explicitly: with it, `compute(sim, data)` and
    `reduce(values, data)`; without it, one argument each. Nothing is inferred from the function's
    signature.

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

### [Perturbation kernels](@id perturbation_kernels)

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
result = runCalibration(method, problem)
```

`progress` controls console output: `:auto` (a live progress bar on a TTY, generation logs
otherwise), `:none`, `:generation`, `:batch`, or `:bar`. Particle evaluations run through the
ordinary [parallel runner](@ref running_simulations), so calibration benefits from
[`setNumberOfParallelSims`](@ref) and [HPC](@ref hpc) just like any other trial.

Simulations can and do fail mid-run; calibration treats that as an expected outcome rather than
an error. See [When things go wrong](@ref calibration_troubleshooting) for what gets recorded and
what you can control.

## The simulation bank and CDF-grid reuse

Calibration can evaluate thousands of particles, many close together in parameter space.
Setting `cdf_grid_k` on the method snaps proposals onto a dyadic grid in CDF space and reuses
previously evaluated monads within a small box (the [`ModelManager.SimulationBank`](@ref)), avoiding
redundant simulations. The grid refines each generation, so early generations are cheap and
later ones precise. See the [`ABCSMC`](@ref) docstring for the exact semantics.

Only monads with at least one simulation that is running or completed are eligible for reuse —
there is nothing to gain from snapping onto a monad whose simulations have not started, and a
monad whose simulations all failed no longer exists.

A discrete parameter is not snapped. Its levels do not line up with a dyadic grid, so snapping
would sample some levels more often than others; it still takes part in bank reuse, and repeat
parameterizations are collapsed when the monad is created, which is where its redundant work was
being removed anyway.

## Results and resuming

[`runABC`](@ref) returns an [`ABCResult`](@ref). Inspect the inferred posterior with
[`posterior`](@ref) and the run's diagnostics with [`ConvergenceSummary`](@ref):

```julia
post = posterior(result)                 # final-generation posterior
post = posterior(result; generation=3)   # a specific generation
summary = ConvergenceSummary(result)
```

Each generation records two epsilons: `max_epsilon_accepted`, the largest distance it accepted, and
`epsilon_threshold`, the cutoff it was run against. Generation 1 accepts everything, so it has no
threshold.

Calibration state is persisted (generation CSVs, the problem manifest, and `method.toml`)
under a [`Calibration`](@ref) record in the database, so an interrupted run can be resumed:

```julia
result = resumeCalibration(Calibration(calibration_id))   # no need to re-supply the problem
```

`resumeABC` is the same call under its ABC-specific name, matching `runABC` against `runCalibration`.

To change some of the saved settings and keep the rest, pass them as keywords:

```julia
result = resumeCalibration(Calibration(calibration_id); max_nr_populations=15)
```

## What a run leaves on disk

A calibration writes three files describing the run, then one folder per generation:

```
outputs/calibrations/1/
├── problem.jld2          # the CalibrationProblem, so a resume needs no re-supplied problem
├── method.toml           # the method's settings
├── parameters.toml       # display name → database column → prior, per parameter
└── generations/
    ├── 01/
    │   ├── particles.csv          # accepted particles, in target space
    │   ├── cdfs.csv               # the same particles in CDF space
    │   ├── metadata.toml          # both epsilons, ESS, acceptance rate, evaluation count
    │   ├── monads.csv             # every monad evaluated, as compressed ID ranges
    │   ├── proposals.csv          # distance and outcome for every proposal
    │   ├── failed_simulations.csv # only when a simulation failed
    │   └── failed_monads.csv      # only when a monad lost every simulation
    ├── 02/
    └── …
```

The folder name is the generation number, zero-padded to fit `max_nr_populations`. If a resume raises
that cap the existing folders are re-padded to match, so the directory stays in order; lowering it
narrows them again, but never below the width the generations already on disk require.

Calibrations written by an earlier version stored the same artifacts as flat files
(`generation_01.csv`, `generation_01_monads.csv`, and a `generation_cdfs/` subdirectory). Those are
read as they are — nothing needs converting before you can plot or inspect a run — and are moved into
the folder layout the first time the run is resumed.

## Finding your runs again

Every calibration in the project is listed by [`calibrationsTable`](@ref) — when it ran, which
method, and how it was labelled:

```julia
calibrationsTable()
printCalibrationsTable(; tags = true)
```

A [`Calibration`](@ref) also prints its own summary, including how many generations completed and
the largest distance the last one accepted:

```julia
julia> Calibration(3)
Calibration (ID=3):
  Created:     2026-08-17T10:22:31
  Method:      ABC-SMC
  Description: dose-response fit
  Generations:  4
  Max ε accepted: 0.031
```

Label runs with [tags](@ref tagging) rather than the `description=` keyword. Tags are queryable,
hold several values per key, and can be applied retroactively — you rarely know what a run was
*for* until you have looked at it — whereas `description` is a single free-text column that nothing
can search. It is still written and still displayed, so older runs keep what they recorded.

```julia
tag!(result, "project" => "immune-escape", "purpose" => "figure")

findTrials(Calibration; tags = ("project" => "immune-escape",))
findTrials(Calibration; tags = ("mm:method" => "ABCSMC",))
```

`tag!` and the accessors below take the [`ABCResult`](@ref) that [`runABC`](@ref) returns, so
`result.calibration` is never needed — the same courtesy [`MMOutput`](@ref) extends for a trial.

## Working with a run's simulations

The monads a run evaluated are addressable as [`Sampling`](@ref) views — over the whole run, or
over one generation:

```julia
sampling = Sampling(result)       # every monad the run evaluated
gen3     = Sampling(result, 3)    # just generation 3

simulationsTable(sampling; tags = true)
run(gen3; n_replicates = 5)                   # top up the replicates of one generation
```

This is worth a word of explanation, because a calibration is not a level of the trial hierarchy.
It evaluates monads in batches, and each batch already becomes a `Sampling` while the run
proceeds — a generation is generally several of them. But a `Sampling` is defined by its monads
sharing input folders, and every monad of a calibration is built from the same
[`CalibrationProblem`](@ref) inputs, so the run and each of its generations are valid samplings
too. They are overlapping *views* over one set of monads rather than a chain of containers, which
is why a calibration is addressable this way without being part of the hierarchy itself.

To read the IDs without recording anything, use the accessors:

```julia
monadIDs(result)         # every surviving monad, sorted
monadIDs(result, 3)      # one generation's
simulationIDs(result)    # every simulation of the run
```

A monad that lost every one of its simulations was deleted when it emptied, so it is absent from
all of these — the views describe what the run actually produced.

!!! note "Views of a run still in progress"
    A sampling is identified by its exact set of monads. Building the run-wide view part-way
    through a calibration therefore records a row for the monads evaluated *so far*, and the
    finished run — a different set — gets a row of its own. Build views once the run is done. The
    accessors above read without recording anything, so they are safe at any time.

## Deleting a run

[`deleteCalibration`](@ref) removes the record and its folder, keeping the simulations:

```julia
deleteCalibration(result)                           # bookkeeping only
deleteCalibration(3; delete_subs = true)            # and the monads no one else uses
```

The monads are kept by default because they are not the run's private property: the simulation
bank reuses monads across runs, and a monad the calibration snapped onto may have been created by
ordinary exploration long beforehand. For the same reason `delete_subs = true` deletes only the
monads nothing else points at — see [Managing data](@ref managing_data). Note that deleting a run
discards its posterior — the generation CSVs, the serialized problem, and the method settings all
live in the folder.

## [Visualizing calibration results](@id abc_plots)

When a plotting backend is loaded, [RecipesBase](https://github.com/JuliaPlots/RecipesBase.jl)
recipes turn an [`ABCResult`](@ref) or [`Calibration`](@ref) into standard diagnostics:

```julia
using Plots
plot(result)                          # pairwise posterior — the default, no style needed
plot(result, :ridgeline)              # posterior narrowing across generations
plot(result, :transition)             # accepted vs. rejected proposals for one generation
plot(result, :distances)              # proposal-distance histogram, accepted tail highlighted
plot(ConvergenceSummary(result))      # epsilon / acceptance / ESS over generations
```

The style is a **positional** argument, and any of these also works on a `Calibration` loaded from
the database, so you can plot a finished run without re-running it:

```julia
plot(Calibration(42), :distances; generation=3)
```

### Proposal distances

`:distances` bins the proposals a generation measured a distance for and colours the accepted ones
separately, so you can see how much of the proposal distribution is landing inside the threshold:

```julia
plot(result, :distances)                    # final generation
plot(result, :distances; generation=2)      # a specific one
plot(result, :distances; logscale=true)     # squared-error distances often span decades
```

The threshold is drawn as a dashed line and falls exactly on a bin boundary, so the accepted and
rejected bars never share a bin. A shrinking accepted fraction across generations is the sampler
working; an accepted fraction that collapses toward zero means the threshold is tightening faster
than the proposals can follow.

Two kinds of proposal are left out, both counted in the title rather than drawn: one whose monad had
no successful simulation, which has no distance at all, and one whose distance is not finite, which
has no bin — `Inf` is a perfectly ordinary thing for a `distance` to return for a hopeless parameter
set. Generation 1 accepts everything it evaluates, so it has no threshold line. Runs recorded before
proposal distances were kept still plot, from the accepted distances alone, and say so in the title.

## [When things go wrong](@id calibration_troubleshooting)

A calibration run is long, unattended, and made of thousands of simulations, so this section
covers what happens when part of it fails — and which failures stop the run rather than being
absorbed.

### Failed simulations

Every generation's failures are recorded in the calibration folder, next to the monad record:

```
generations/{t}/failed_simulations.csv   # simulation IDs that failed
generations/{t}/failed_monads.csv        # monads with ≥1 failed simulation
```

Both use the same compressed-ID format as `monads.csv` (read them back with
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
| The measurement has no value for it — every replicate's `compute` returned `missing`, or a QoI's `reduce` did | The monad has output but nothing to compare, which is the same position: the particle is handled by `on_monad_failure` too, rather than reported as a bug in your functions. Nothing failed here, so no failure file is written; those monads are named in a warning of their own, once per generation. |

### `on_monad_failure`

```julia
result = runABC(problem; on_monad_failure=:reject)   # default
result = runABC(problem; on_monad_failure=:error)    # stop at the first one
```

- **`:reject`** records the particle's distance as `missing` — no distance exists — so ABC-SMC
  never accepts it and the run continues.
- **`:error`** stops the run, naming what there is to name for that cause: for a monad with no
  successful simulation, the monad, both failure files, and the output folders of its failed
  simulations; for a monad whose summary has no value, the monad and the QoI that had none for it,
  since nothing failed and so no file was written. Use it when you want the first failure to be
  diagnosable rather than survivable.

Both cover the two ways a particle can fail to yield a distance: a monad with no successful
simulation, and a monad whose summary statistic has no value.

Rejected particles are not replaced, so a generation can hold fewer than `population_size`
particles. Generation 1 proposes exactly `population_size` and keeps those that produced a distance,
renormalizing the weights over the survivors; later generations keep proposing until the
population is filled and simply never accept a failed monad. A whole later generation of failures
therefore keeps proposing until `max_evaluations` is reached rather than aborting — one bad monad
never ends a run.

### Bugs in your `summary_statistic` or `distance`

For a monad that *does* have output, your two functions are expected to work. If either raises, or
`distance` returns something that is not a `Real`, the run stops immediately with the monad ID and
**which of the two raised** — regardless of `on_monad_failure`, which governs missing results rather
than bugs in your own code. When the monad had some failed replicates, the message says how many,
since that is the likeliest reason otherwise-correct code trips.

A `compute` returning `missing` is **not** in this category — it is the supported way to say "no
value for this simulation", and it follows `on_monad_failure`. `nothing` is refused outright, with a
message asking for `missing`, because it is what a function returns when a block falls through.

### Error messages

| Message | Cause | What to do |
| --- | --- | --- |
| `monad N has no successful simulation` | `on_monad_failure=:error` and every simulation in a proposed monad failed. | Read the failure files and the simulations' `output` folders. Switch to `:reject` to let the run continue past these. |
| `none of the N proposed monads produced a distance` | Nothing survived generation 1. | The model or its fixed parameters are broken for the whole prior, or the measurement returned `missing` everywhere — not sampling noise. Check that a single simulation at a reference parameter set runs, and that your `compute` returns a value for it. |
| ``Calibration failed while evaluating monad N: `summary_statistic` raised`` (or ``` `distance` raised ```) | One of your two functions threw on a monad that has output. The message names which. | The original exception and backtrace follow the message. A `summary_statistic` failure is in a `compute` or a `reduce`; a `distance` failure is usually a key mismatch against `observed_data`. |
| ``distance returned a T, but a `Real` is required`` | `distance` returned a `Dict`, `missing`, `nothing`, … | Return a real number. If you are guarding against missing output yourself, you no longer need to — see the table above. |
| ``The summary statistic has no value named "k"`` | `observed_data` names a quantity the measurement does not produce. | The message lists the labels that do exist. Key the observation by those — see [The keys `distance` sees](@ref calibration_keys). An absent key used to be imputed as zero, which was a defensible reading ("nothing to report") but let a naming mistake run to completion; it is refused now. |
| ``"k" is a component key of more than one QoI`` | Two QoIs report the same key, so the bare spelling names two values. | Use the qualified `"<qoi>.<key>"` spelling the message offers, or a `("qoi", "key")` tuple. |
| ``mseDistance was given two observed keys that name one value`` | `observed_data` spells one component two ways — `"tumor"` and `"counts.tumor"`, say. | Keep one spelling; the other would be compared twice and weighted double. |
| ``mseDistance cannot compare a T with a U`` | The summary's value and the observation cannot be subtracted — two arrays of different lengths, most often, and the message gives both. | Match the shapes, or supply your own `distance`. |
| ``the post-processing sink and sensitivity analysis need a `Real`…`` | A `compute` returned something the sink cannot store, or a `reduce` something GSA cannot make an index of. | Only those two consumers require this — calibration takes whatever `reduce` returns. Return a number or a flat keyed value if you want the QoI to serve all three. |
| ``the default `reduce` averages per key, so every replicate must carry the same keys`` | Two replicates of one parameter set reported different keys. | That is the *default* reducer's rule. Pass `reduce=` a function of your own to reconcile them — usually by emitting the full key set with a zero for the absent component. |
| `simulation(s) X … have no row in the simulations table` | A monad's constituent record and the database disagree. | Run `ModelManager.databaseDiagnostics()`. This indicates corrupted bookkeeping, not a failed simulation. |
| `Cannot resume Calibration(N): problem.jld2 contains only a partial manifest` | The original problem used lambdas or closures — a named function defined *inside* another function counts — which JLD2 cannot restore by name. | Pass the original problem: `resumeCalibration(cal; problem=my_problem)`. Define `summary_statistic`/`distance` at the top level of a file or module to avoid it next time. |
| `The saved problem in … could not be read back` | The file holds a closure this session cannot name (saved by a version that did not detect it). | `include` the file that defines your functions before resuming, or pass `problem=`, which is then used without being checked against the saved one. |

### The run isn't converging

Nothing failed, but the posterior is not tightening. [`ConvergenceSummary`](@ref) and
`plot(ConvergenceSummary(result))` shows ε, acceptance rate, and ESS per generation; the
ridgeline plot shows whether successive posteriors are actually narrowing (stagnant adjacent
curves are the ABC-SMC analog of a flat MCMC chain).

- **Acceptance rate collapsing** — ε is tightening faster than the model can follow. Raise
  `epsilon_quantile` toward 1, or supply a gentler `epsilon_schedule`. Set `min_acceptance_rate`
  to stop automatically instead of grinding.
- **ESS far below `population_size`** — a few particles carry all the weight. Try a different
  [perturbation kernel](@ref perturbation_kernels) (`ComponentwiseKernel` in higher dimensions,
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
