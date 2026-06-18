```@meta
CurrentModule = ModelManager
```

# Variations

A **variation** describes how to change one or more model parameters away from their base
value. Variations are the unit of parameterization in ModelManager: you attach them to a set
of [`InputFolders`](@ref), and the framework expands them into [monads](@ref "The trial hierarchy"),
records them in the per-folder variations databases, and assigns each combination a
[`VariationID`](@ref).

## Targeting a parameter: XMLPath

Parameters live in XML input files, addressed by an [`XMLPath`](@ref) — the sequence of tags
(and optional attributes) leading to the element to change. You construct an `XMLPath` from a
vector of strings and pass that object (not the bare vector) to a variation constructor:

```julia
xp = XMLPath(["overall", "max_time"])            # <overall><max_time>…
xp = XMLPath(["cell_definitions", "cell_definition:name:tumor", "phenotype", "cycle", "rate"])
```

Path elements of the form `tag:attribute:value` select an element by an attribute, and the
`custom` forms address custom data. ModelManager only locates the element; how the value is
written into the file is the backend's concern.

!!! note "Pass an `XMLPath`, not a raw vector"
    ModelManager's constructors require an [`XMLPath`](@ref) object rather than accepting a
    bare `Vector{String}`. Keeping the path type explicit means the core is not hard-wired to
    XML — a different input format could supply its own path type. A backend may add
    convenience constructors that take a plain vector if it wants that ergonomics.

!!! note "location is explicit"
    Every variation needs a `location` (the [project location](@ref "Project configuration") the
    target lives in, e.g. `:config`). ModelManager requires it explicitly. Backends often add
    convenience constructors that infer the location from the path — but at this layer you
    pass it yourself.

## Elementary variations

An [`ElementaryVariation`](@ref) varies a single target. There are two kinds.

### DiscreteVariation

[`DiscreteVariation`](@ref) enumerates a fixed list of values:

```julia
# Three explicit values.
dv = DiscreteVariation(:config, XMLPath(["overall", "max_time"]), [60.0, 120.0, 240.0])

# A single value (e.g. to pin a parameter) — pass a scalar.
fixed = DiscreteVariation(:config, XMLPath(["overall", "max_time"]), 120.0)
```

When sampled on a grid, each value becomes one monad.

### DistributedVariation

[`DistributedVariation`](@ref) draws from a probability distribution (from
[Distributions.jl](https://juliastats.org/Distributions.jl/)). It is the form used by
sensitivity analysis and calibration, where parameters are sampled rather than enumerated:

```julia
using Distributions
dist = DistributedVariation(:config, XMLPath(["overall", "max_time"]), Uniform(60.0, 240.0))
```

Two convenience constructors cover the common cases:

```julia
UniformDistributedVariation(:config, XMLPath(["overall", "max_time"]), 60.0, 240.0)
NormalDistributedVariation(:config, XMLPath(["overall", "max_time"]), 120.0, 30.0; lb=0.0)
```

Pass `flip=true` to invert the distribution (use the inverse-CDF of `1-x`).

## Covarying parameters: CoVariation

A [`CoVariation`](@ref) ties several elementary variations together so they move **as one** —
a single draw (or grid index) sets all of them. Use it when parameters are physically coupled
or when you want to reduce dimensionality. All constituents must be the same kind (all
discrete or all distributed):

```julia
# Distributed: one CDF draw moves both targets.
cv = CoVariation(
    DistributedVariation(:config, XMLPath(["cell","birth_rate"]), Uniform(0.01, 0.05)),
    DistributedVariation(:config, XMLPath(["cell","death_rate"]), Uniform(0.001, 0.01)),
)

# Discrete: paired value lists of equal length.
cv = CoVariation(
    DiscreteVariation(:config, XMLPath(["cell","birth_rate"]), [0.01, 0.03, 0.05]),
    DiscreteVariation(:config, XMLPath(["cell","death_rate"]), [0.001, 0.005, 0.01]),
)
```

## Reparameterizing: LatentVariation

A [`LatentVariation`](@ref) introduces *latent* parameters and maps them to one or more
target parameters through arbitrary functions. This lets you sample in a more natural or
lower-dimensional space than the raw XML parameters. Each latent dimension is either a fixed
vector of values or a distribution; `maps` turn the latent vector into target values:

```julia
# Sample a single latent "log rate"; the target is exp(log_rate).
lv = LatentVariation(
    [Normal(-7, 1)],                 # latent parameter(s)
    [XMLPath(["cell", "rate"])],     # target(s)
    [lp -> exp(lp[1])],              # map: latent → target value(s)
    ["log_rate"],                    # latent parameter name(s)
    [:config];                       # target location(s)
    inverse_maps = [tv -> log(tv[1])],
)
```

When you provide `inverse_maps` (required for distribution-based latents used in calibration),
the constructor runs a round-trip check ([`_validateInverseMaps`](@ref)) to confirm they are
consistent with the forward maps.

## Applying variations

You normally hand variations to [`createTrial`](@ref) / [`run`](@ref), which call
[`addVariations`](@ref) for you (see [The trial hierarchy](@ref) and [Running simulations](@ref)):

```julia
output = run(inputs, dv1, dv2; n_replicates=3)
```

`addVariations` writes the variation rows into each varied location's variations database and
returns the resulting [`VariationID`](@ref)s. How those combinations are generated — full
grid versus a space-filling design — is controlled by the *method* argument, covered next in
[Space-filling designs](@ref).

See the [Variations](@ref) API reference for every type and helper.
