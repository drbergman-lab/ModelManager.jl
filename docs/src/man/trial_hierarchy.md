```@meta
CurrentModule = ModelManager
```

# [The trial hierarchy](@id trial_hierarchy)

Every run that ModelManager organizes is described by one of four nested types. They form a
strict containment hierarchy, from a single execution up to an arbitrary collection:

| Type | What it is | Shares |
| --- | --- | --- |
| [`Simulation`](@ref) | One run of the model | — |
| [`Monad`](@ref) | A group of identical-up-to-randomness simulations | same inputs **and** variation |
| [`Sampling`](@ref) | A group of monads | same inputs, differing variations |
| [`Trial`](@ref) | A group of samplings | (arbitrary) |

The abstract supertypes capture what each level guarantees:

```
AbstractTrial
└── AbstractSampling          # all constituent sims share input folders
    └── AbstractMonad         # all constituent sims also share variation IDs
        ├── Simulation
        └── Monad
    └── Sampling
└── Trial
```

- [`AbstractSampling`](@ref) — all associated simulations share the same [`InputFolders`](@ref);
  only their variations differ.
- [`AbstractMonad`](@ref) — all associated simulations share **both** input folders **and**
  variation IDs (they differ only in their random seed). [`Simulation`](@ref) and
  [`Monad`](@ref) are both monads.

This is why a `Simulation` *is an* `AbstractMonad`: a single simulation trivially satisfies
"all constituents share inputs and variation."

## Replicates and deduplication

Stochastic models need replicates. A [`Monad`](@ref) is exactly that: a set of simulations
with one fixed parameterization, differing only by random seed. The `n_replicates` keyword
controls how many it holds, and `use_previous` controls whether already-completed replicates
count toward that target:

```julia
# A monad targeting 5 replicates; reuse any that already exist.
monad = Monad(inputs, variation_id; n_replicates=5, use_previous=true)
```

Because monads are keyed in the database by `(simulator version, input folders, variation
IDs)`, constructing "the same" monad twice returns the **same** database row. This is the
mechanism behind ModelManager's cheap re-runs: asking for a parameterization that has
already been simulated does not launch new work.

## InputFolders

A [`Simulation`](@ref), [`Monad`](@ref), or [`Sampling`](@ref) does not store parameter
files directly — it references **input folders** by location. [`InputFolders`](@ref)
consolidates that reference. Which locations exist (and which are required or varied) is
defined by the project's `inputs.toml` (see [Project configuration](@ref project_configuration)).

```julia
# Keyword form — omitted locations default to "" (unused).
inputs = InputFolders(; config="default", custom_code="default")

# Positional form — required locations in alphabetical order, optional ones as kwargs.
inputs = InputFolders("default", "default"; ic_cell="cells_in_disc")
```

Each entry is an [`InputFolder`](@ref) recording the location, the database row ID, the
folder name, its primary file (`basename`), and whether it is required or varied.

## VariationID

A [`VariationID`](@ref) records, for each *varied* location, which variation row is in
effect. By convention:

- `0` — the base (unvaried) file,
- `-1` — the location is not in use,
- a positive integer — a specific variation row in that location's variations database.

You rarely construct a `VariationID` by hand; [`addVariations`](@ref) and
[`createTrial`](@ref) produce them as a side effect of registering variations
(see [Variations](@ref variations)).

## Building trials in practice

You almost never call these constructors directly. The [User API](@ref) —
[`createTrial`](@ref) and [`run`](@ref) — picks the right level for you based on how many
parameter combinations your variations produce:

- one combination, `n_replicates == 1` → a [`Simulation`](@ref)
- one combination, `n_replicates > 1` → a [`Monad`](@ref)
- many combinations → a [`Sampling`](@ref)

```julia
# One value, one replicate → Simulation
sim = createTrial(inputs, DiscreteVariation(:config, XMLPath(["overall","max_time"]), 120.0))

# One value, several replicates → Monad
monad = createTrial(inputs, DiscreteVariation(:config, XMLPath(["overall","max_time"]), 120.0);
                    n_replicates=5)

# Several values → Sampling (one monad per value)
sampling = createTrial(inputs, DiscreteVariation(:config, XMLPath(["overall","max_time"]), [60.0, 120.0, 240.0]))
```

You can also start from an existing reference monad to inherit its fixed parameters:

```julia
new_trial = createTrial(reference_monad, more_variations...)
```

## Asking what a trial contains

| Function | Returns | Levels |
| --- | --- | --- |
| [`simulationIDs`](@ref) | every simulation the trial covers | all |
| [`monadIDs`](@ref) | every monad the trial covers | all |
| [`constituentIDs`](@ref) | only the level immediately below | all but `Simulation` |
| [`trialID`](@ref) | the object's own database ID | all |
| [`trialType`](@ref) | its concrete type | all |

`simulationIDs` and `monadIDs` descend as far as the hierarchy goes, so
`simulationIDs(trial)` reaches the individual runs while `constituentIDs(trial)` stops at that
trial's samplings. Each also takes an array of trials, concatenating the results.
`constituentIDs` is the one exception to "works at every level": a [`Simulation`](@ref) has
nothing below it, so it throws rather than returning an empty list.

All five accept the [`MMOutput`](@ref) that [`run`](@ref) hands back, forwarding to the trial it
wraps, so a result can be queried without unpacking it. So do `length` and
[`trialFolder`](@ref):

```julia
out = run(sampling)
monadIDs(out)                  # identical to monadIDs(sampling)
length(out)                    # how many simulations the trial holds
trialType(out)                 # Sampling
```

Two cases are worth knowing about:

- **A simulation's monad is looked up, never created.** `monadIDs(simulation)` finds the monad
  whose simulator version, input folders and variation IDs match the simulation's. Asking does not
  bring a monad into being, so it is safe against a database you do not want to modify. Note that
  this matches on *parameterization*, not on membership: a simulation built with
  `Simulation(inputs, variation_id)` or `Simulation(monad)` resolves to the monad sharing its
  parameters without appearing in that monad's replicate list — [`run`](@ref) is what adds it
  there. The result is `Int[]` only when no monad shares the parameterization at all.
- **`trialID` over a vector of samplings is also a lookup.** `trialID(samplings)` reports which
  [`Trial`](@ref) groups exactly those samplings, in any order, and `missing` when no trial
  does. Call `Trial(samplings)` to create one.

Once you have a trial, hand it to [`run`](@ref) to execute it — see
[Running simulations](@ref running_simulations). For the constructor-level details, see the
[Trial hierarchy](@ref) API reference.
