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
    n_replicates::Integer=1, use_previous::Bool=true, tags=())
    return _createTrial(method, inputs, VariationID(inputs), avs, n_replicates, use_previous, tags)
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
                     n_replicates::Integer=1, use_previous::Bool=true, tags=())
    return _createTrial(method, reference.inputs, reference.variation_id, avs, n_replicates, use_previous, tags)
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

"""
    createTrial(Ts::AbstractVector) -> Trial

Bundle a collection of already-built trials into a single [`Trial`](@ref) so they can be
launched together — e.g. after accumulating the results of earlier `createTrial` calls in a
vector:

```julia
sims = []
push!(sims, createTrial(inputs, dv1))
push!(sims, createTrial(inputs, dv2))
run(sims)                 # launch all as one batch
```

Each element may be a `Simulation`, `Monad`, `Sampling`, or `Trial` (a `Trial` contributes its
constituent samplings). The vector may be loosely typed (`Vector{Any}`); its elements are
narrowed to [`AbstractTrial`](@ref), with a clear `ArgumentError` if any element is not one.
Already-built trials are wrapped as-is — no new replicates are added.
"""
function createTrial(Ts::AbstractVector; tags=())
    trials = _toAbstractTrialVector(Ts)
    isempty(trials) && throw(ArgumentError("createTrial received an empty collection; nothing to run."))
    samplings = AbstractSampling[]
    for T in trials
        if T isa AbstractSampling      # Simulation, Monad, or Sampling
            push!(samplings, T)
        else                           # Trial — contributes its samplings
            append!(samplings, T.samplings)
        end
    end
    #! Tag the objects we were handed, not the umbrella Trial. Inheritance *would* carry a
    #! tag on the Trial down to everything beneath it, so this is not about reachability —
    #! it is about durability. That Trial is deduplicated plumbing, and `deleteTrial(id;
    #! delete_subs=false)` removes it without touching its constituents; if it held the only
    #! copy of the tag, deleting it would silently make those simulations unfindable. A
    #! container too ephemeral to be worth labelling is too ephemeral to be a label's only
    #! home. Tagging the constituents also means `hasTag(lo, ...)` is true for the very
    #! object the caller passed in.
    refreshProvenance!()
    trial = Trial(samplings)
    if !isempty(tags)
        for T in trials
            tag!(T, tags...)
        end
    end
    return trial
end

"""
    _toAbstractTrialVector(Ts::AbstractVector) -> Vector{AbstractTrial}

Narrow a (possibly `Vector{Any}`) collection to `Vector{AbstractTrial}`, throwing an
`ArgumentError` that lists the offending indices if any element is not an [`AbstractTrial`](@ref).
"""
function _toAbstractTrialVector(Ts::AbstractVector)
    try
        return Vector{AbstractTrial}(Ts)
    catch _
        msg = "run/createTrial over a vector requires every element to be an AbstractTrial " *
              "(Simulation, Monad, Sampling, or Trial).\nThe following indices are not:"
        for (i, T) in enumerate(Ts)
            T isa AbstractTrial && continue
            msg *= "\n  - Index $i: $(typeof(T))"
        end
        throw(ArgumentError(msg))
    end
end

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
    _createTrial(method, inputs, reference_variation_id, avs, n_replicates, use_previous, tags)

Internal implementation of [`createTrial`](@ref).

Every `createTrial` overload funnels through here, so this is where the launching
script and git state are resolved — once per call rather than once per object — and
where `tags` are applied to whatever is returned.
"""
function _createTrial(method::AddVariationMethod, inputs::InputFolders, reference_variation_id::VariationID,
                      avs::Vector{<:AbstractVariation}, n_replicates::Integer, use_previous::Bool, tags=())
    #! Tags go on the returned object only; its constituents match through query-time
    #! inheritance, which is what keeps them correct when replicates are added later.
    refreshProvenance!()
    trial = _buildTrial(method, inputs, reference_variation_id, avs, n_replicates, use_previous)
    isempty(tags) || tag!(trial, tags...)
    return trial
end

function _buildTrial(method::AddVariationMethod, inputs::InputFolders, reference_variation_id::VariationID,
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
function run(method::AddVariationMethod, args...; n_replicates=1, use_previous=true, tags=(), kwargs...)
    trial = createTrial(method, args...; n_replicates=n_replicates, use_previous=use_previous, tags=tags)
    return run(trial; kwargs...)
end

run(inputs::InputFolders, args...; kwargs...) = run(GridVariation(), inputs, args...; kwargs...)

run(reference::AbstractMonad, arg1, args...; kwargs...) = run(GridVariation(), reference, arg1, args...; kwargs...)

run(output_ref::MMOutput{<:AbstractMonad}, args...; kwargs...) = run(output_ref.trial, args...; kwargs...)

"""
    run(Ts::AbstractVector; kwargs...) -> MMOutput

Bundle a collection of already-built trials into one [`Trial`](@ref) (see
[`createTrial`](@ref)`(::AbstractVector)`) and run it as a single parallelized batch. `kwargs`
are forwarded to [`run`](@ref)`(::AbstractTrial; ...)` (including `post_processor`).

```julia
sims = [createTrial(inputs, dv1), createTrial(inputs, dv2)]
run(sims)
```
"""
run(Ts::AbstractVector; tags=(), kwargs...) = run(createTrial(Ts; tags=tags); kwargs...)
