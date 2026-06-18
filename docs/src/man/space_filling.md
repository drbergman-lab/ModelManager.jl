```@meta
CurrentModule = ModelManager
```

# Space-filling designs

When you attach several [variations](@ref Variations) to a trial, the **sampling method**
decides *which combinations* of values are actually run. The default enumerates every
combination; the space-filling designs sample the parameter space more efficiently for
high-dimensional sweeps. The method is the optional first argument to [`createTrial`](@ref)
and [`run`](@ref).

All four methods are subtypes of [`AddVariationMethod`](@ref).

## GridVariation (default)

[`GridVariation`](@ref) takes the full factorial grid — every combination of every discrete
variation's values. With three variations of 3, 4, and 2 values that is 3 × 4 × 2 = 24 monads.

```julia
run(GridVariation(), inputs, dv1, dv2)   # or just: run(inputs, dv1, dv2)
```

Grids are exhaustive and exact, but the count grows multiplicatively — use a space-filling
design when the dimension is high.

## LHSVariation

[`LHSVariation`](@ref) draws a Latin Hypercube Sample of size `n`: each parameter's range is
split into `n` equal-probability bins and sampled so every bin is used exactly once. Good
coverage with far fewer points than a grid.

```julia
run(LHSVariation(100), inputs, dist1, dist2)
run(LHSVariation(100; add_noise=true, orthogonalize=true), inputs, dist1, dist2)
```

- `add_noise` — jitter within each bin instead of using bin centers.
- `orthogonalize` — use an orthogonal LHS for better space coverage (on by default).

## SobolVariation

[`SobolVariation`](@ref) uses a Sobol low-discrepancy quasi-random sequence — deterministic,
highly uniform coverage that is the basis for Sobol' sensitivity analysis.

```julia
run(SobolVariation(128), inputs, dist1, dist2)
run(SobolVariation(; pow2=7), inputs, dist1, dist2)   # n = 2^7 = 128
```

`n_matrices`, `randomization`, `skip_start`, and `include_one` control the sequence; the
`pow2` keyword is a convenience for power-of-two sample sizes.

## RBDVariation

[`RBDVariation`](@ref) builds a Random Balance Design, used by RBD-FAST sensitivity analysis.
With the default Sobol-based construction, `n` must be within one of a power of two.

```julia
run(RBDVariation(128), inputs, dist1, dist2)
run(RBDVariation(100; use_sobol=false), inputs, dist1, dist2)   # random-sequence variant
```

## Choosing a design

| Method | Best for | Notes |
| --- | --- | --- |
| [`GridVariation`](@ref) | Small, exhaustive sweeps over discrete values | Count grows multiplicatively |
| [`LHSVariation`](@ref) | General-purpose sampling of continuous ranges | Even 1-D coverage of each parameter |
| [`SobolVariation`](@ref) | Variance-based [Sobol' sensitivity](@ref "Sensitivity analysis") | Deterministic, low discrepancy |
| [`RBDVariation`](@ref) | [RBD-FAST sensitivity](@ref "Sensitivity analysis") | `n` near a power of two (Sobol mode) |

The space-filling methods pair naturally with [`DistributedVariation`](@ref)s, since they
sample distributions rather than enumerate fixed values. For analyses built directly on these
designs, see [Sensitivity analysis](@ref). For the result types
([`AddVariationsResult`](@ref) and its subtypes) and `orthogonalLHS`, see the
[Variations](@ref) API reference.
