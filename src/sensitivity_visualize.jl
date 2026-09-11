using RecipesBase

################## Shared helpers ##################

# Labels in sorted order so plots are reproducible across runs (a Dict's iteration order is
# otherwise unspecified). The keys of a results dict ARE the labels, so there is nothing to derive;
# `gsaLabels` says the same thing for a whole sampling.
_gsaLabels(results::AbstractDict) = sort(collect(keys(results)))

# Parameter (latent dimension) names for each GSA sampling type, in the same column
# order as the corresponding index vectors. The leading bookkeeping columns differ:
# MOAT prepends "base"; Sobolʼ prepends "A" and "B"; RBD has none.
_moatParameterNames(monad_ids_df::DataFrame)  = names(monad_ids_df)[2:end]
_sobolParameterNames(monad_ids_df::DataFrame) = names(monad_ids_df)[3:end]
_rbdParameterNames(monad_ids_df::DataFrame)   = names(monad_ids_df)

const _NO_FUNCTIONS_MSG =
    "No sensitivity quantities calculated. Run the GSA with `functions=[...]` (or call `calculateGSA!`) first."

################## Parameter selection (shared with the calibration recipes) ##################

#! Delegated to DataFrames' column-selector machinery rather than hand-rolled: `parameters` then
#! accepts exactly what `select` does — a name, a vector of names (honoured in the order given, which
#! is how panels are reordered), positions, a `Regex`, `Not(...)` — and one vocabulary serves every
#! recipe in the package. The frame is a header only; nothing is copied.
"""
    _selectParameters(available::Vector{String}, parameters) → Vector{String}

Resolve a recipe's `parameters` keyword against the names it could draw. `nothing` keeps them all;
anything else is a DataFrames column selector over `available`. An unknown name is an `ArgumentError`
that also lists what was available.
"""
_selectParameters(available::Vector{String}, ::Nothing) = available
function _selectParameters(available::Vector{String}, parameters)
    header   = DataFrame([name => Float64[] for name in available]...)
    selected = try
        names(header, parameters)
    catch e
        e isa ArgumentError || rethrow()
        throw(ArgumentError("Cannot resolve `parameters = $(repr(parameters))`: $(e.msg). " *
                            "Available parameters: $(available)."))
    end
    isempty(selected) && throw(ArgumentError(
        "`parameters = $(repr(parameters))` selects no parameters. Available: $(available)."))
    return selected
end

# Positions of `selected` within `available`, for slicing index vectors alongside the names.
_parameterIndices(available::Vector{String}, selected::Vector{String}) =
    Int[findfirst(==(s), available) for s in selected]

const _PARAMETERS_KW_DOC = """
`parameters` restricts and orders the parameters shown: a name, a vector of names (drawn in that
order), positions, a `Regex`, or `Not(...)` over the x-axis names, which are the columns of the
sampling's `monad_ids_df` after the method's bookkeeping columns. The default draws all of them."""

################## Bar recipe (shared) ##################

# One bar series: legend label, per-parameter values, fill opacity, and optional ±error
# (rendered as whiskers via `yerror`). `yerror === nothing` means no whiskers.
struct _GSABarGroup
    label::String
    values::Vector{Float64}
    fillalpha::Float64
    yerror::Union{Nothing,Vector{Float64}}
end

# Grouped bar chart of sensitivity indices: x-axis = parameters, one bar series per group.
struct _GSABarData
    param_names::Vector{String}
    groups::Vector{_GSABarGroup}
end

@recipe function f(d::_GSABarData)
    n = length(d.param_names)
    n == 0 && error("No parameters to plot.")
    isempty(d.groups) && error(_NO_FUNCTIONS_MSG)

    seriestype := :bar
    xticks     := (1:n, d.param_names)
    xlabel     --> "parameter"
    ylabel     --> "sensitivity index"
    legend     --> :outertopright

    for g in d.groups
        @series begin
            label     := g.label
            fillalpha := g.fillalpha
            isnothing(g.yerror) || (yerror := g.yerror)
            g.values
        end
    end
end

################## Violin recipe (MOAT) ##################

# Distribution of elementary effects per parameter; one violin series per function.
struct _GSAViolinData
    param_names::Vector{String}
    groups::Vector{Tuple{String,Matrix{Float64}}}   # (label, n_base × n_param effects)
end

@recipe function f(d::_GSAViolinData)
    n = length(d.param_names)
    n == 0 && error("No parameters to plot.")
    isempty(d.groups) && error(_NO_FUNCTIONS_MSG)

    seriestype := :violin
    xticks     := (1:n, d.param_names)
    xlabel     --> "parameter"
    ylabel     --> "elementary effect"
    legend     --> :outertopright

    for (label, effects) in d.groups
        nb = size(effects, 1)
        # Column-major `vec` walks parameter 1's rows, then parameter 2's, … which
        # matches the repeated x positions below.
        xs = reduce(vcat, [fill(p, nb) for p in 1:n])
        @series begin
            label := label
            xs, vec(effects)
        end
    end
end

################## Scatter recipe (MOAT µ*–σ) ##################

# Classic Morris screening plot: µ* (x) vs σ (y), one point per parameter.
struct _GSAScatterData
    param_names::Vector{String}
    groups::Vector{Tuple{String,Vector{Float64},Vector{Float64}}}   # (label, µ*, σ)
end

# Axis span used to scale label offsets; falls back to a sane value for a single point.
_annotationSpan(v) = (s = maximum(v) - minimum(v); s == 0 ? max(maximum(abs, v), 1.0) : s)

@recipe function f(d::_GSAScatterData)
    length(d.param_names) == 0 && error("No parameters to plot.")
    isempty(d.groups) && error(_NO_FUNCTIONS_MSG)

    seriestype := :scatter
    xlabel     --> "µ*"
    ylabel     --> "σ"
    legend     --> :outertopright

    # Label the first series only; offset each label up and to the right of its marker
    # (anchored at its lower-left corner) so the text never sits on top of the point.
    mu1, sg1 = d.groups[1][2], d.groups[1][3]
    dx = 0.02 * _annotationSpan(mu1)
    dy = 0.02 * _annotationSpan(sg1)

    for (k, (label, mu, sigma)) in enumerate(d.groups)
        @series begin
            label := label
            if k == 1
                annotations := [(mu[i] + dx, sigma[i] + dy, (d.param_names[i], 8, :left, :bottom))
                                for i in eachindex(mu)]
            end
            mu, sigma
        end
    end
end

################## MOAT data builders ##################

# Build a grouped bar chart of Morris µ* (mean absolute elementary effect); when
# `show_sigma` is true, overlay σ (std of the signed effects) as ±whiskers.
function _moatBarData(results::AbstractDict, monad_ids_df::DataFrame, show_sigma::Bool;
                      parameters=nothing)
    isempty(results) && error(_NO_FUNCTIONS_MSG)
    all_names = _moatParameterNames(monad_ids_df)
    pnames    = _selectParameters(all_names, parameters)
    idx       = _parameterIndices(all_names, pnames)
    labels = _gsaLabels(results)
    multi  = length(labels) > 1
    groups = _GSABarGroup[]
    for name in labels
        res   = results[name]
        mu    = Float64.(vec(res.means_star))[idx]
        yerr  = show_sigma ? sqrt.(Float64.(vec(res.variances)))[idx] : nothing
        label = multi ? "µ*: $(name)" : "µ*"
        push!(groups, _GSABarGroup(label, mu, 1.0, yerr))
    end
    return _GSABarData(pnames, groups)
end

function _moatViolinData(results::AbstractDict, monad_ids_df::DataFrame; parameters=nothing)
    isempty(results) && error(_NO_FUNCTIONS_MSG)
    all_names = _moatParameterNames(monad_ids_df)
    pnames    = _selectParameters(all_names, parameters)
    idx       = _parameterIndices(all_names, pnames)
    labels = _gsaLabels(results)
    multi  = length(labels) > 1
    groups = Tuple{String,Matrix{Float64}}[]
    for name in labels
        res   = results[name]
        label = multi ? name : "elementary effects"
        push!(groups, (label, Float64.(res.elementary_effects)[:, idx]))
    end
    return _GSAViolinData(pnames, groups)
end

function _moatScatterData(results::AbstractDict, monad_ids_df::DataFrame; parameters=nothing)
    isempty(results) && error(_NO_FUNCTIONS_MSG)
    all_names = _moatParameterNames(monad_ids_df)
    pnames    = _selectParameters(all_names, parameters)
    idx       = _parameterIndices(all_names, pnames)
    labels = _gsaLabels(results)
    multi  = length(labels) > 1
    groups = Tuple{String,Vector{Float64},Vector{Float64}}[]
    for name in labels
        res   = results[name]
        mu    = Float64.(vec(res.means_star))[idx]
        sigma = sqrt.(Float64.(vec(res.variances)))[idx]
        label = multi ? name : "parameters"
        push!(groups, (label, mu, sigma))
    end
    return _GSAScatterData(pnames, groups)
end

################## MOAT recipes ##################

"""
    plot(m::MOATSampling; show_sigma=false)
    plot(m::MOATSampling, style::Symbol; show_sigma=false)

Visualize a Morris One-At-A-Time (MOAT) sensitivity analysis. One series is emitted per
sensitivity quantity calculated on the sampling — see [`gsaLabels`](@ref), which is one per
`functions=` entry unless a [`QoI`](@ref) spread into several. The series label includes the
quantity's own label when more than one is present.

`style` selects the chart:

- `:bar` (default) — grouped bar chart of µ* (mean absolute elementary effect) per
  parameter. Set `show_sigma=true` to overlay σ (standard deviation of the signed
  elementary effects) as ±whiskers.
- `:violin` — violin plot of the full elementary-effect distribution per parameter.
  Requires a backend providing the `:violin` series type (e.g. `StatsPlots`).
- `:scatter` — classic Morris screening plot of µ* (x) versus σ (y), one point per
  parameter, annotated with parameter names.

$_PARAMETERS_KW_DOC

# Examples
```julia
using Plots
plot(moat_sampling)                       # µ* bar chart
plot(moat_sampling; show_sigma=true)      # µ* bars with σ whiskers
plot(moat_sampling, :scatter)             # µ*–σ screening plot
plot(moat_sampling; parameters=["k_on", "k_off"])   # two parameters, in this order

using StatsPlots
plot(moat_sampling, :violin)              # elementary-effect distributions
```
"""
@recipe function f(m::MOATSampling)
    show_sigma = pop!(plotattributes, :show_sigma, false)
    parameters = pop!(plotattributes, :parameters, nothing)
    _moatBarData(m.results, m.monad_ids_df, show_sigma; parameters=parameters)
end

@recipe function f(m::MOATSampling, style::Symbol)
    show_sigma = pop!(plotattributes, :show_sigma, false)
    parameters = pop!(plotattributes, :parameters, nothing)
    if style === :bar
        _moatBarData(m.results, m.monad_ids_df, show_sigma; parameters=parameters)
    elseif style === :violin
        _moatViolinData(m.results, m.monad_ids_df; parameters=parameters)
    elseif style === :scatter
        _moatScatterData(m.results, m.monad_ids_df; parameters=parameters)
    else
        error("Unknown MOATSampling plot style :$style. Use :bar, :violin, or :scatter.")
    end
end

################## Sobolʼ recipe ##################

function _sobolBarData(results::AbstractDict, monad_ids_df::DataFrame, show_ST::Bool;
                       parameters=nothing)
    isempty(results) && error(_NO_FUNCTIONS_MSG)
    all_names = _sobolParameterNames(monad_ids_df)
    pnames    = _selectParameters(all_names, parameters)
    idx       = _parameterIndices(all_names, pnames)
    labels = _gsaLabels(results)
    multi  = length(labels) > 1
    groups = _GSABarGroup[]
    for name in labels
        res = results[name]
        push!(groups, _GSABarGroup(multi ? "S1: $(name)" : "S1",
                                   Float64.(res.S1)[idx], 1.0, nothing))
        if show_ST && !isnothing(res.ST)
            push!(groups, _GSABarGroup(multi ? "ST: $(name)" : "ST",
                                       Float64.(res.ST)[idx], 0.45, nothing))
        end
    end
    return _GSABarData(pnames, groups)
end

"""
    plot(s::SobolSampling; show_ST=true)

Grouped bar chart of Sobolʼ sensitivity indices. For each sensitivity quantity (see
[`gsaLabels`](@ref)), the first-order index `S1` is shown per parameter; when `show_ST=true`
(default) the total-order index `ST` is overlaid at reduced opacity. Labels include the
quantity's own label when more than one is present.

$_PARAMETERS_KW_DOC

# Examples
```julia
using Plots
plot(sobol_sampling)                 # S1 + ST
plot(sobol_sampling; show_ST=false)  # S1 only
plot(sobol_sampling; parameters=r"^k_")   # only the rate constants
```
"""
@recipe function f(s::SobolSampling)
    show_ST    = pop!(plotattributes, :show_ST, true)
    parameters = pop!(plotattributes, :parameters, nothing)
    _sobolBarData(s.results, s.monad_ids_df, show_ST; parameters=parameters)
end

################## RBD recipe ##################

function _rbdBarData(results::AbstractDict, monad_ids_df::DataFrame; parameters=nothing)
    isempty(results) && error(_NO_FUNCTIONS_MSG)
    all_names = _rbdParameterNames(monad_ids_df)
    pnames    = _selectParameters(all_names, parameters)
    idx       = _parameterIndices(all_names, pnames)
    labels = _gsaLabels(results)
    multi  = length(labels) > 1
    groups = _GSABarGroup[]
    for name in labels
        label = multi ? "S1: $(name)" : "S1"
        push!(groups, _GSABarGroup(label, Float64.(results[name])[idx], 1.0, nothing))
    end
    return _GSABarData(pnames, groups)
end

"""
    plot(r::RBDSampling)

Grouped bar chart of Random Balance Design (RBD) first-order sensitivity indices, one
bar series per sensitivity quantity (see [`gsaLabels`](@ref); labels include the quantity's
own label when more than one is present).

$_PARAMETERS_KW_DOC

# Example
```julia
using Plots
plot(rbd_sampling)
plot(rbd_sampling; parameters=Not("dt"))   # everything but the time step
```
"""
@recipe function f(r::RBDSampling)
    parameters = pop!(plotattributes, :parameters, nothing)
    _rbdBarData(r.results, r.monad_ids_df; parameters=parameters)
end
