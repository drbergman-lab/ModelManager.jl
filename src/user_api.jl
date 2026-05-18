import Base.run

export createTrial, run

"""
    createTrial([method=GridVariation()], inputs::InputFolders, avs::Vector{<:AbstractVariation}=AbstractVariation[];
                n_replicates::Integer=1, use_previous::Bool=true)

Return an `AbstractTrial` (`Simulation`, `Monad`, or `Sampling`) from the given inputs and variations.

The `method` controls how the variation space is sampled (default: `GridVariation()`).
Other options: [`LHSVariation`](@ref), [`SobolVariation`](@ref), [`RBDVariation`](@ref).

# Alternate forms (all accept an optional leading `method` argument)
```julia
createTrial(inputs, av::AbstractVariation; ...)            # single variation
createTrial(reference::AbstractMonad, avs; ...)            # start from a reference monad
createTrial(output_ref::MMOutput{<:AbstractMonad}, avs; ...)
```
"""
function createTrial(method::AddVariationMethod, inputs::InputFolders, avs::Vector{<:AbstractVariation}=AbstractVariation[];
    n_replicates::Integer=1, use_previous::Bool=true)
    return _createTrial(method, inputs, VariationID(inputs), avs, n_replicates, use_previous)
end

function createTrial(method::AddVariationMethod, inputs::InputFolders, avs::Vararg{AbstractVariation}; kwargs...)
    return createTrial(method, inputs, [avs...]; kwargs...)
end

function createTrial(method::AddVariationMethod, inputs::InputFolders, avs::Vector; kwargs...)
    avs = convertToAbstractVariationVector(avs)
    return createTrial(method, inputs, avs; kwargs...)
end

createTrial(method::AddVariationMethod, inputs::InputFolders, avs::Vararg; kwargs...) = createTrial(method, inputs, [avs...]; kwargs...)

createTrial(inputs::InputFolders, args...; kwargs...) = createTrial(GridVariation(), inputs, args...; kwargs...)

function createTrial(method::AddVariationMethod, reference::AbstractMonad, avs::Vector{<:AbstractVariation}=AbstractVariation[];
                     n_replicates::Integer=1, use_previous::Bool=true)
    return _createTrial(method, reference.inputs, reference.variation_id, avs, n_replicates, use_previous)
end

function createTrial(method::AddVariationMethod, reference::AbstractMonad, avs::Vararg{AbstractVariation}; kwargs...)
    return createTrial(method, reference, [avs...]; kwargs...)
end

function createTrial(method::AddVariationMethod, reference::AbstractMonad, avs::Vector; kwargs...)
    avs = convertToAbstractVariationVector(avs)
    return createTrial(method, reference, avs; kwargs...)
end

createTrial(method::AddVariationMethod, reference::AbstractMonad, avs::Vararg; kwargs...) = createTrial(method, reference, [avs...]; kwargs...)

createTrial(reference::AbstractMonad, args...; kwargs...) = createTrial(GridVariation(), reference, args...; kwargs...)

createTrial(output_ref::MMOutput{<:AbstractMonad}, args...; kwargs...) = createTrial(output_ref.trial, args...; kwargs...)

function convertToAbstractVariationVector(avs::Vector)
    try
        return Vector{AbstractVariation}(avs)
    catch _
        msg = "Variations must be a subtype of AbstractVariation.\nThe following indices are not:"
        for (i, av) in enumerate(avs)
            if av isa AbstractVariation
                continue
            end
            msg *= "\n  - Index $i: $(typeof(av))"
        end
        throw(ArgumentError(msg))
    end
end

"""
    _createTrial(method, inputs, reference_variation_id, avs, n_replicates, use_previous)

Internal implementation of [`createTrial`](@ref).
"""
function _createTrial(method::AddVariationMethod, inputs::InputFolders, reference_variation_id::VariationID,
                      avs::Vector{<:AbstractVariation}, n_replicates::Integer, use_previous::Bool)

    add_variations_result = addVariations(method, inputs, avs, reference_variation_id)
    variation_ids = add_variations_result.variation_ids
    if length(variation_ids) == 1
        variation_ids = variation_ids[1]
        monad = Monad(inputs, variation_ids; n_replicates=n_replicates, use_previous=use_previous)
        if n_replicates != 1
            return monad
        end
        return Simulation(simulationIDs(monad)[end])
    else
        location_variation_ids = [loc => [variation_id[loc] for variation_id in variation_ids] for loc in projectLocations().varied] |>
            Dict{Symbol,Union{Integer,AbstractArray{<:Integer}}}

        return Sampling(inputs, location_variation_ids;
            n_replicates=n_replicates,
            use_previous=use_previous
        )
    end
end

"""
    run([method=GridVariation()], inputs_or_ref, avs...; kwargs...)

Create a trial from `inputs_or_ref` and `avs`, then run it. `kwargs` are forwarded to
[`run`](@ref)`(::AbstractTrial; ...)`, which passes them through to
`prepareTrialHierarchy` and the simulator hooks.
"""
function run(method::AddVariationMethod, args...; n_replicates=1, use_previous=true, kwargs...)
    trial = createTrial(method, args...; n_replicates=n_replicates, use_previous=use_previous)
    return run(trial; kwargs...)
end

run(inputs::InputFolders, args...; kwargs...) = run(GridVariation(), inputs, args...; kwargs...)

run(reference::AbstractMonad, arg1, args...; kwargs...) = run(GridVariation(), reference, arg1, args...; kwargs...)

run(output_ref::MMOutput{<:AbstractMonad}, args...; kwargs...) = run(output_ref.trial, args...; kwargs...)
