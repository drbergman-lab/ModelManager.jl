export StudySpec

"""
    StudySpec(inputs::InputFolders, variations; kwargs...)
    StudySpec(reference::AbstractMonad, variations; kwargs...)

The model-and-parameters half of a study, built once and used for either sensitivity analysis or
calibration.

A sensitivity sweep and a calibration ask different questions of the same model varied over the same
parameters. `StudySpec` is that shared half — the input folders, the parameters, the baseline to vary
from, and how many replicates to run — so it need not be restated when the second question follows the
first.

# Arguments
- `inputs`: the model's input folders. The `reference` form takes them from a monad instead, along with
  its variation ID as the baseline.
- `variations`: a vector of `AbstractVariation`s, or several passed individually.

# Keywords
- `reference_variation_id`: the baseline to vary from. Defaults to `VariationID(inputs)`; the
  `reference` form takes it from the monad and does not accept this keyword.
- `n_replicates`: replicates per parameter set (default `1`).
- `use_previous`: reuse matching simulations that have already run (default `true`). **Sensitivity
  only** — calibration reuses through its own `SimulationBank`, so this field is ignored there.

# What it deliberately does not hold
`observed_data`, `summary_statistic` and `distance` stay on [`CalibrationProblem`](@ref), and
`functions` stays on the sensitivity entry point. A sensitivity study has no observed data, and a field
that half the consumers ignore is how a shared abstraction rots.

The user's own `variations` are kept rather than normalised, because the reverse conversion is lossy: a
`DistributedVariation`'s display name does not survive it, and the generation CSVs are keyed by that name.

# Examples
```julia
spec = StudySpec(inputs, [dv1, dv2]; n_replicates=3)

# Sensitivity, then calibration, over the same spec
gsa  = run(MOAT(), spec; functions=[finalCount])
prob = CalibrationProblem(spec, observed, summarize, mseDistance)
res  = run(ABCSMC(population_size=64), prob)

# From a monad, which supplies both the inputs and the baseline variation
spec2 = StudySpec(reference_monad, [dv1, dv2])
```
"""
struct StudySpec
    inputs::InputFolders
    #! Concrete `Vector{AbstractVariation}`, not `Vector{<:AbstractVariation}`: `ParsedVariations`'
    #! inner constructor takes an invariant `Vector`, so a narrower element type would not dispatch.
    variations::Vector{AbstractVariation}
    reference_variation_id::VariationID
    n_replicates::Int
    use_previous::Bool
end

function StudySpec(inputs::InputFolders, variations::AbstractVector;
                   reference_variation_id::VariationID=VariationID(inputs),
                   n_replicates::Integer=1, use_previous::Bool=true)
    avs = convertToAbstractVariationVector(collect(variations))
    return StudySpec(inputs, avs, reference_variation_id, Int(n_replicates), use_previous)
end

StudySpec(inputs::InputFolders, v1::AbstractVariation, vs::AbstractVariation...; kwargs...) =
    StudySpec(inputs, [v1, vs...]; kwargs...)

#! No `reference_variation_id` keyword on this form, matching
#! `createTrial(method, reference::AbstractMonad, avs; ...)` and `CalibrationProblem(::AbstractMonad, ...)`:
#! the baseline comes from the reference, which is the reason to pass one. The `InputFolders` form is
#! where a variation ID is an independent argument.
function StudySpec(reference::AbstractMonad, variations::AbstractVector;
                   n_replicates::Integer=1, use_previous::Bool=true)
    return StudySpec(reference.inputs, variations;
                     reference_variation_id=reference.variation_id,
                     n_replicates=n_replicates, use_previous=use_previous)
end

StudySpec(reference::AbstractMonad, v1::AbstractVariation, vs::AbstractVariation...; kwargs...) =
    StudySpec(reference, [v1, vs...]; kwargs...)

#! Lossless in this direction, which is why only this direction exists: the spec keeps the user's
#! originals, so normalising them on demand costs nothing and discards nothing.
ParsedVariations(spec::StudySpec) = ParsedVariations(spec.variations)

#! `show` is the whole reporting surface, deliberately — no `validateStudySpec` function. Typing the
#! variable at the REPL is how people actually check, it costs no API commitment, and the one cliff
#! worth surfacing (a latent variation without inverse maps is accepted by calibration but silently
#! disables the `SimulationBank`) has nowhere better to live.
function Base.show(io::IO, ::MIME"text/plain", spec::StudySpec)
    println(io, "StudySpec:")
    #! `printInputFolders` leaves its last line unterminated, so the next field would otherwise share
    #! it. Matching how `classes.jl` callers follow it.
    printInputFolders(io, spec.inputs, 1)
    println(io)
    println(io, "  Replicates:    ", spec.n_replicates)
    println(io, "  use_previous:  ", spec.use_previous, "  (sensitivity only)")
    println(io, "  Parameters (", length(spec.variations), "):")
    for av in spec.variations
        rejection = _calibrationRejection(av)
        calib = isnothing(rejection) ? "yes" : "no"
        note = ""
        if av isa LatentVariation && isnothing(av.inverse_maps)
            note = "  [bank disabled — supply inverse_maps]"
        end
        println(io, "    ", variationName(av), "  —  ", nameof(typeof(av)),
                "; sensitivity: yes, calibration: ", calib, note)
    end
end
