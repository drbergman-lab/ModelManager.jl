using KernelDensity
using RecipesBase

################## Private helpers ##################

# Return (df, weights) in the requested space for generation t.
# df contains only parameter columns (metadata stripped).
function _vizParticles(result::ABCResult, t::Int, space::Symbol)
    if space === :target
        df, w = posterior(result; generation=t)
        meta = intersect([:weight, :distance, :monad_id], Symbol.(names(df)))
        return isempty(meta) ? df : select(df, Not(meta)), w
    elseif space === :cdf
        gen = result.generations[t]
        return copy(gen.particles), gen.weights
    else
        throw(ArgumentError("Unknown space :$space; use :target or :cdf"))
    end
end

# Convert a CDF-space DataFrame to target-parameter space, stripping metadata columns.
function _cdfDFToTarget(cdf_df::DataFrame, params::Vector{CalibrationParameter})
    isempty(params) && return copy(cdf_df)
    n = nrow(cdf_df)
    dummy = GenerationResult(0, cdf_df,
                             fill(1.0 / max(n, 1), n), zeros(n), 0.0,
                             0, zeros(Int, n), 1.0, float(max(n, 1)), nothing)
    df = _buildDisplayDF(dummy, params)
    return select(df, Not([:weight, :distance, :monad_id]))
end

# Build a Dict mapping db column names → display names by reading parameters.toml from disk.
# For LVSource, maps target db columns → target_display_names (latent columns not included).
#! A discrete source writes the same two shapes as its continuous counterpart — `DiscreteSource` has
#! `db_column`/`display_name` like `DVSource`, `DiscreteCoSource` has the plural pair like `CVSource` —
#! so they share the branches. Without them a discrete parameter had no entry here at all, and the
#! disk-resident `:transition` plot silently dropped its column: the mapping is applied by renaming
#! `simulationsTable` columns, and an unrenamed one no longer matches the display names the plot
#! selects on. Only plots built from disk were affected; the in-memory mapping covered both.
function _buildDbToDisplayMappingFromTOML(toml_path::String)
    isfile(toml_path) || return Dict{String,String}()
    d = TOML.parsefile(toml_path)
    haskey(d, "parameters") || return Dict{String,String}()
    mapping = Dict{String,String}()
    for entry in d["parameters"]
        st = get(entry, "source_type", "")
        if st == "DVSource" || st == "DiscreteSource"
            mapping[entry["db_column"]] = entry["display_name"]
        elseif st == "CVSource" || st == "DiscreteCoSource"
            for (db_col, disp) in zip(entry["db_columns"], entry["display_names"])
                mapping[db_col] = disp
            end
        elseif st == "LVSource"
            for (db_col, tname) in zip(entry["db_columns"],
                                        get(entry, "target_display_names", String[]))
                mapping[db_col] = tname
            end
        end
    end
    return mapping
end

# Lazy-load rejected proposals for a disk-resident Calibration (no inverse_maps available).
function _lazyLoadRejectedFromDisk(cal::Calibration, t_next::Int, max_nr_populations::Int,
                                    accepted_monad_ids, pnames::Vector{String},
                                    mapping::Dict{String,String})
    #! Located by pattern, not rebuilt from `max_nr_populations`: a resume may have changed the
    #! padding, and the miss here is silent — it degrades to an accepted-only plot with no error.
    monads_path = _generationArtifact(joinpath(calibrationFolder(cal), "generations"),
                                      t_next, :monads)
    isnothing(monads_path) && return nothing

    all_ids      = constituentIDs(monads_path)
    accepted_set = Set(accepted_monad_ids)
    rejected_ids = [id for id in all_ids if id ∉ accepted_set]
    isempty(rejected_ids) && return nothing

    sim_df = simulationsTable(Monad.(rejected_ids); remove_constants=false, short_names=false)
    isempty(sim_df) && return nothing

    for col in names(sim_df)
        haskey(mapping, col) || continue
        rename!(sim_df, col => mapping[col])
    end

    available = intersect(pnames, names(sim_df))
    isempty(available) && return nothing
    return select(sim_df, available)
end

# Build a Dict mapping db column names → display names from CalibrationParameter metadata.
# For LVSource, maps target db columns → target_names only; latent names need inverse_maps.
function _buildDbToDisplayMapping(params::Vector{CalibrationParameter})
    mapping = Dict{String,String}()
    for cp in params
        db_cols = columnName.(cp.lv.targets)
        if cp.source isa DVSource
            mapping[db_cols[1]] = variationName(cp.source.dv)
        elseif cp.source isa CVSource
            for (db_col, v) in zip(db_cols, cp.source.cv.variations)
                mapping[db_col] = variationName(v)
            end
        else  # LVSource
            for (db_col, tname) in zip(db_cols, cp.lv.target_names)
                mapping[db_col] = tname
            end
        end
    end
    return mapping
end

# Lazy-load rejected proposals for generation t_next in target-parameter space.
function _lazyLoadRejected(result::ABCResult, t_next::Int)
    #! By pattern, not from `result.method.max_nr_populations`. That is the *in-memory* cap, which a
    #! `method=` override on resume can have raised above the one the existing files were named under
    #! — and `method.toml` is never rewritten, so the two genuinely disagree.
    monads_path = _generationArtifact(joinpath(calibrationFolder(result.calibration), "generations"),
                                      t_next, :monads)
    isnothing(monads_path) && return nothing

    all_ids      = constituentIDs(monads_path)
    accepted_set = Set(result.generations[t_next].monad_ids)
    rejected_ids = [id for id in all_ids if id ∉ accepted_set]
    isempty(rejected_ids) && return nothing

    sim_df = simulationsTable(Monad.(rejected_ids); remove_constants=false, short_names=false)
    isempty(sim_df) && return nothing

    # Rename db column names → display names using parameter metadata
    mapping = _buildDbToDisplayMapping(result.parameters)
    for col in names(sim_df)
        haskey(mapping, col) || continue
        rename!(sim_df, col => mapping[col])
    end

    # For LVSource with inverse_maps, reconstruct latent parameter columns from target values
    for cp in result.parameters
        cp.source isa LVSource || continue
        lv = cp.lv
        isnothing(lv.inverse_maps) && continue
        target_cols = lv.target_names
        all(c -> c in names(sim_df), target_cols) || continue
        for (lp_name, inv_map) in zip(lv.latent_parameter_names, lv.inverse_maps)
            sim_df[!, lp_name] = [inv_map([sim_df[r, c] for c in target_cols])
                                   for r in 1:nrow(sim_df)]
        end
    end

    ref_cols = names(_targetParams(result))
    available = intersect(ref_cols, names(sim_df))
    isempty(available) && return nothing
    return select(sim_df, available)
end

# Get rejected proposals in the requested space; returns (df_or_nothing, note_string).
function _getRejected(result::ABCResult, t_next::Int, space::Symbol)
    gen_next = result.generations[t_next]

    if !isnothing(gen_next.rejected_proposals)
        rej = gen_next.rejected_proposals
        if space === :cdf
            return rej, ""
        else
            return _cdfDFToTarget(rej, result.parameters), ""
        end
    end

    space === :cdf && return nothing, " (set store_rejected=true for CDF-space rejected proposals)"

    df = _lazyLoadRejected(result, t_next)
    isnothing(df) && return nothing, " (rejected proposals unavailable)"
    return df, ""
end

# Aggregate rows of df by exact match; return (unique_df, aggregated_values).
# When weights is nothing, aggregated value = count; else = sum of weights.
function _aggregateRows(df::DataFrame, weights::Union{Nothing,AbstractVector{<:Real}})
    isempty(df) && return df, Float64[]
    col_names = names(df)
    row_keys  = [join([repr(df[r, c]) for c in col_names], "\x00") for r in 1:nrow(df)]
    seen      = Dict{String,Int}()
    order     = String[]
    agg       = Dict{String,Float64}()
    for (r, k) in enumerate(row_keys)
        if !haskey(seen, k)
            seen[k] = r
            push!(order, k)
            agg[k] = isnothing(weights) ? 1.0 : Float64(weights[r])
        else
            agg[k] += isnothing(weights) ? 1.0 : Float64(weights[r])
        end
    end
    unique_df = df[[seen[k] for k in order], :]
    agg_vals  = [agg[k] for k in order]
    return unique_df, agg_vals
end

# Map an aggregated value to a marker size relative to a reference value.
_markerSize(val, ref; base=8.0, minsize=2.0) = max(base * sqrt(val / max(ref, 1e-12)), minsize)

################## Internal plot-data wrappers ##################

# Used so that both ABCResult and Calibration can funnel into the same corner-plot recipe.
struct _CornerPlotData
    df::DataFrame
    weights::Vector{Float64}
end

################## Pairs / corner plot ##################

"""
    plot(result::ABCResult; generation=:final, space=:target)
    plot(cal::Calibration; generation=:final, space=:target)

Corner plot of an ABC-SMC posterior generation. Diagonal panels show weighted 1D KDE
marginals; off-diagonal lower-triangle panels show weighted 2D KDE contours overlaid
with a weighted scatter (opacity ∝ weight).

`generation` is an integer index (1-based) or `:final` (default).
`space=:target` (default) shows biological-unit parameter values;
`space=:cdf` shows ABC internal CDF coordinates.
"""
@recipe function f(cpd::_CornerPlotData)
    df      = cpd.df
    weights = cpd.weights
    param_names = names(df)
    d = length(param_names)
    d == 0 && error("No parameters to plot.")

    layout := (d, d)
    legend := false

    for i in 1:d
        for j in 1:d
            sp = (i - 1) * d + j
            xi = Float64.(df[!, param_names[i]])
            xj = Float64.(df[!, param_names[j]])

            if i == j
                k = kde(xi; weights=weights)
                @series begin
                    subplot    := sp
                    seriestype := :path
                    xlabel     := param_names[j]
                    ylabel     := i == 1 ? "density" : ""
                    collect(k.x), k.density
                end

            elseif i > j
                k2 = kde((xj, xi); weights=weights)
                @series begin
                    subplot    := sp
                    seriestype := :contourf
                    xlabel     := param_names[j]
                    ylabel     := param_names[i]
                    collect(k2.x), collect(k2.y), k2.density'
                end
                alpha_vals = clamp.(weights .* length(weights), 0.05, 1.0)
                @series begin
                    subplot          := sp
                    seriestype       := :scatter
                    markeralpha      := alpha_vals
                    markersize       := 3
                    markerstrokewidth := 0
                    xj, xi
                end
            end
            # upper triangle: no series emitted → blank panel
        end
    end
end

@recipe function f(result::ABCResult; generation=:final, space=:target)
    isempty(result.generations) && error("No generations in ABCResult.")
    t = generation === :final ? length(result.generations) : Int(generation)
    df, w = _vizParticles(result, t, space)
    _CornerPlotData(df, w)
end

@recipe function f(cal::Calibration; generation=:final, space=:target)
    if space === :target
        df, w = posterior(cal; generation=generation)
    else
        gen_dir = joinpath(calibrationFolder(cal), "generations")
        indices = _generationIndices(gen_dir)
        isempty(indices) && error("No CDF generation files for Calibration($(cal.id)).")
        t = generation === :final ? last(indices) : Int(generation)
        t in indices || throw(ArgumentError(
            "Generation $t not found for Calibration($(cal.id)). Available: $(indices)."))
        cdf_path = _generationArtifact(gen_dir, t, :cdfs)
        isnothing(cdf_path) && error(
            "Generation $t of Calibration($(cal.id)) has no CDF file.")
        df_cdf  = CSV.read(cdf_path, DataFrame)
        weights_col = hasproperty(df_cdf, :weight) ? df_cdf[!, :weight] :
                      fill(1.0 / nrow(df_cdf), nrow(df_cdf))
        df = select(df_cdf, Not(intersect([:weight, :distance, :monad_id], Symbol.(names(df_cdf)))))
        w  = Float64.(weights_col)
    end
    _CornerPlotData(df, w)
end

################## Posterior narrowing / ridgeline plot ##################

struct _RidgelineData
    dfs::Vector{DataFrame}
    weights_list::Vector{Vector{Float64}}
    prior_df::Union{Nothing,DataFrame}
    prior_weights::Union{Nothing,Vector{Float64}}
    param_names::Vector{String}
end

@recipe function f(rd::_RidgelineData)
    dfs         = rd.dfs
    wts         = rd.weights_list
    param_names = rd.param_names
    d = length(param_names)
    T = length(dfs)
    d == 0 && error("No parameters to plot.")
    T == 0 && error("No generations to plot.")

    has_prior = !isnothing(rd.prior_df)
    # Build ordered list of (df, wts, label) — prior first, then generations 1..T
    all_dfs    = has_prior ? [rd.prior_df; dfs]                      : dfs
    all_wts    = has_prior ? [[rd.prior_weights]; wts]               : wts
    all_labels = has_prior ? [0; collect(1:T)]                       : collect(1:T)
    R = length(all_dfs)

    layout := (1, d)
    legend := false

    offset_factor = 0.35   # <1 → ridges overlap noticeably

    for j in 1:d
        panel_kdes = [kde(Float64.(all_dfs[r][!, param_names[j]]); weights=all_wts[r]) for r in 1:R]
        max_dens   = maximum(maximum(k.density) for k in panel_kdes)
        scale      = max_dens > 0 ? max_dens : 1.0

        offsets       = [(r - 1) * scale * offset_factor for r in 1:R]
        tick_positions = offsets
        tick_labels    = string.(all_labels)

        for r in 1:R
            gen_num   = all_labels[r]
            alpha_val = gen_num == 0 ? 0.4 :
                        0.3 + 0.7 * (gen_num - 1) / max(T - 1, 1)
            k = panel_kdes[r]
            @series begin
                subplot    := j
                seriestype := :path
                fillrange  := offsets[r]
                fillalpha  := alpha_val * 0.4
                linealpha  := alpha_val
                xlabel     := param_names[j]
                ylabel     := j == 1 ? "generation" : ""
                yticks     := (tick_positions, tick_labels)
                collect(k.x), k.density .+ offsets[r]
            end
        end
    end
end

################## Convergence trace ##################

@recipe function f(cs::ConvergenceSummary)
    df = cs.df
    layout := (3, 1)
    legend := false
    link   := :x

    @series begin
        subplot    := 1
        seriestype := :path
        ylabel     := "max epsilon accepted"
        df.t, df.max_epsilon_accepted
    end
    @series begin
        subplot    := 2
        seriestype := :path
        ylabel     := "acceptance rate"
        df.t, df.acceptance_rate
    end
    @series begin
        subplot    := 3
        seriestype := :path
        xlabel     := "generation"
        ylabel     := "ESS fraction"
        df.t, df.ess_fraction
    end
end

################## Generation transition plot ##################

struct _TransitionData
    kde_df::DataFrame
    kde_weights::Vector{Float64}
    acc_df::DataFrame
    acc_weights::Vector{Float64}
    rej_df::Union{Nothing,DataFrame}
    param_names::Vector{String}
    pop_size::Int
    note::String
    show_particles::Bool
    aggregate_duplicates::Bool
end

@recipe function f(td::_TransitionData)
    kde_df    = td.kde_df
    kde_w     = td.kde_weights
    acc_df    = td.acc_df
    acc_w     = td.acc_weights
    rej_df    = td.rej_df
    pnames    = td.param_names
    d         = length(pnames)
    d == 0 && error("No parameters to plot.")

    w_ref = 1.0 / td.pop_size
    layout := (d, d)
    legend := false

    isempty(td.note) || (plot_title := "Generation transition" * td.note)

    for i in 1:d
        for j in 1:d
            sp  = (i - 1) * d + j
            kdei = Float64.(kde_df[!, pnames[i]])
            kdej = Float64.(kde_df[!, pnames[j]])

            if i == j
                # Diagonal: 1D KDE + stacked strip chart
                k = kde(kdei; weights=kde_w)
                @series begin
                    subplot    := sp
                    seriestype := :path
                    xlabel     := pnames[j]
                    collect(k.x), k.density
                end

                if td.show_particles
                    @series begin
                        subplot          := sp
                        seriestype       := :scatter
                        markersize       := 2
                        markerstrokewidth := 0
                        markercolor      := :grey
                        markeralpha      := 0.5
                        kdei, zeros(length(kdei))
                    end
                end

                # Accepted strip (ticks above zero line)
                acci = Float64.(acc_df[!, pnames[i]])
                if td.aggregate_duplicates
                    adf, avals = _aggregateRows(DataFrame(x=acci), acc_w)
                    for (xi, h) in zip(adf.x, avals)
                        @series begin
                            subplot          := sp
                            seriestype       := :path
                            linecolor        := :green
                            linealpha        := 0.8
                            linewidth        := 2 + 4 * h / max(w_ref * length(acci), 1e-12)
                            [xi, xi], [-0.05 * maximum(k.density), 0.0]
                        end
                    end
                else
                    @series begin
                        subplot          := sp
                        seriestype       := :scatter
                        markersize       := 3
                        markerstrokewidth := 0
                        markercolor      := :green
                        markeralpha      := 0.5
                        acci, fill(-0.025 * maximum(k.density), length(acci))
                    end
                end

                # Rejected strip (ticks below zero line)
                if !isnothing(rej_df) && pnames[i] ∈ names(rej_df)
                    reji = Float64.(rej_df[!, pnames[i]])
                    if td.aggregate_duplicates
                        rdf, rcounts = _aggregateRows(DataFrame(x=reji), nothing)
                        for (xi, cnt) in zip(rdf.x, rcounts)
                            @series begin
                                subplot          := sp
                                seriestype       := :path
                                linecolor        := :red
                                linealpha        := 0.7
                                linewidth        := 1 + 3 * cnt / max(length(reji), 1)
                                [xi, xi], [0.0, -0.05 * maximum(k.density)]
                            end
                        end
                    else
                        @series begin
                            subplot          := sp
                            seriestype       := :scatter
                            markersize       := 3
                            markerstrokewidth := 0
                            markercolor      := :red
                            markeralpha      := 0.4
                            reji, fill(-0.05 * maximum(k.density), length(reji))
                        end
                    end
                end

            elseif i > j
                # Off-diagonal lower triangle: 2D KDE contour + proposal scatter
                k2 = kde((kdej, kdei); weights=kde_w)
                @series begin
                    subplot    := sp
                    seriestype := :contourf
                    xlabel     := pnames[j]
                    ylabel     := pnames[i]
                    collect(k2.x), collect(k2.y), k2.density'
                end

                if td.show_particles
                    @series begin
                        subplot          := sp
                        seriestype       := :scatter
                        markersize       := 2
                        markerstrokewidth := 0
                        markercolor      := :grey
                        markeralpha      := 0.4
                        kdej, kdei
                    end
                end

                # Rejected bubbles
                if !isnothing(rej_df) && pnames[i] ∈ names(rej_df) && pnames[j] ∈ names(rej_df)
                    rejj = Float64.(rej_df[!, pnames[j]])
                    reji = Float64.(rej_df[!, pnames[i]])
                    n_rej = length(reji)
                    if td.aggregate_duplicates
                        rdf, rcounts = _aggregateRows(DataFrame(x=rejj, y=reji), nothing)
                        ref_cnt = max(maximum(rcounts) * w_ref, w_ref)
                        msizes  = [_markerSize(cnt * w_ref, ref_cnt; base=8.0) for cnt in rcounts]
                        @series begin
                            subplot          := sp
                            seriestype       := :scatter
                            markersize       := msizes
                            markerstrokewidth := 1
                            markercolor      := :red
                            markeralpha      := 0.5
                            rdf.x, rdf.y
                        end
                    else
                        @series begin
                            subplot          := sp
                            seriestype       := :scatter
                            markersize       := 4
                            markerstrokewidth := 0
                            markercolor      := :red
                            markeralpha      := 0.3
                            rejj, reji
                        end
                    end
                end

                # Accepted bubbles
                accj = Float64.(acc_df[!, pnames[j]])
                acci = Float64.(acc_df[!, pnames[i]])
                if td.aggregate_duplicates
                    adf, avals = _aggregateRows(DataFrame(x=accj, y=acci), acc_w)
                    ref_agg = max(maximum(avals), w_ref)
                    msizes = [_markerSize(v, ref_agg) for v in avals]
                    @series begin
                        subplot          := sp
                        seriestype       := :scatter
                        markersize       := msizes
                        markerstrokewidth := 1
                        markercolor      := :green
                        markeralpha      := 0.7
                        adf.x, adf.y
                    end
                else
                    alpha_acc = clamp.(acc_w .* length(acc_w), 0.05, 1.0)
                    @series begin
                        subplot          := sp
                        seriestype       := :scatter
                        markersize       := 4
                        markerstrokewidth := 0
                        markercolor      := :green
                        markeralpha      := alpha_acc
                        accj, acci
                    end
                end
            end
            # upper triangle: blank
        end
    end
end

################## Dispatch recipes ##################


################## Distance distribution ##################

#! `only` throws on an empty collection; this returns `nothing` so callers can decide.
only_or_nothing(v) = length(v) == 1 ? first(v) : nothing

#! One generation's TOML metadata, or an empty Dict when it is missing.
function _calibrationGenerationMeta(cal::Calibration, t::Int)
    gen_dir = joinpath(calibrationFolder(cal), "generations")
    path    = _generationArtifact(gen_dir, t, :metadata)
    isnothing(path) && return Dict{String,Any}()
    return TOML.parsefile(path)
end

"""
    _DistanceData

Binned proposal distances for one generation, split at the acceptance threshold.
"""
struct _DistanceData
    edges::Vector{Float64}
    accepted_counts::Vector{Float64}
    rejected_counts::Vector{Float64}
    epsilon_threshold::Union{Nothing,Float64}
    max_epsilon_accepted::Float64
    t::Int
    logscale::Bool
    note::String
end

#! Binning happens here rather than in the backend. Two `:histogram` series would each pick their own
#! bins, and because the rejected distances extend well to the right of the accepted ones the two
#! would not line up — which is the whole point of the plot. Computing shared edges also lets the
#! threshold land exactly *on* an edge: acceptance is `distance <= ε`, so the two sets are disjoint
#! except in whichever bin straddles ε, and putting ε on a boundary makes them occupy disjoint bins.
#! Plain overlaid `:bar` series then render correctly on any backend, with no `bar_position := :stack`
#! (a Plots-level attribute a backend-agnostic recipe should not require).
function _buildDistanceData(accepted::Vector{Float64}, rejected::Vector{Float64},
                            epsilon_threshold::Union{Nothing,Float64},
                            max_epsilon_accepted::Float64, t::Int;
                            logscale::Bool=false, note::String="")
    vals = vcat(accepted, rejected)
    isempty(vals) && error("No proposal distances to plot for generation $t.")

    acc, rej, thr, extra = accepted, rejected, epsilon_threshold, note
    if logscale
        #! `mseDistance` legitimately returns 0.0 on a perfect match, and log10(0) is -Inf. Drop
        #! non-positive distances and say how many rather than failing the plot.
        n_before = length(accepted) + length(rejected)
        acc = log10.(filter(>(0.0), accepted))
        rej = log10.(filter(>(0.0), rejected))
        n_dropped = n_before - length(acc) - length(rej)
        n_dropped > 0 && (extra *= " ($(n_dropped) non-positive distance$(n_dropped == 1 ? "" : "s") omitted)")
        thr = isnothing(epsilon_threshold) || epsilon_threshold <= 0 ? nothing : log10(epsilon_threshold)
        vals = vcat(acc, rej)
        isempty(vals) && error("No positive proposal distances to plot on a log scale for generation $t.")
    end

    lo, hi = extrema(vals)
    nbins  = clamp(round(Int, sqrt(length(vals))), 10, 50)
    #! A single distinct value has no range to bin; widen it so the bar is visible.
    hi <= lo && (lo -= 0.5; hi += 0.5)
    w = (hi - lo) / nbins

    edges = if isnothing(thr) || !(lo < thr < hi)
        collect(range(lo, hi; length = nbins + 1))
    else
        #! Uniform width, ε exactly on an edge, covering [lo, hi].
        k_left  = max(ceil(Int, (thr - lo) / w), 1)
        k_right = max(ceil(Int, (hi - thr) / w), 1)
        collect(thr .+ w .* (-k_left:k_right))
    end

    nb = length(edges) - 1
    acc_counts = zeros(Float64, nb)
    rej_counts = zeros(Float64, nb)

    #! Acceptance is `distance <= ε`, so a distance exactly *equal* to ε was accepted — but
    #! `searchsortedlast` puts it in the bin that *starts* at ε, which is the first rejected bin.
    #! Constraining each series to its own side of the threshold edge makes the two provably disjoint
    #! instead of almost disjoint, which is the whole point of putting ε on an edge.
    split = isnothing(thr) ? nothing : searchsortedlast(edges, thr)
    for x in acc
        i = clamp(searchsortedlast(edges, x), 1, nb)
        isnothing(split) || (i = min(i, max(split - 1, 1)))
        acc_counts[i] += 1
    end
    for x in rej
        i = clamp(searchsortedlast(edges, x), 1, nb)
        isnothing(split) || (i = max(i, min(split, nb)))
        rej_counts[i] += 1
    end
    return _DistanceData(edges, acc_counts, rej_counts, thr, max_epsilon_accepted, t,
                         logscale, extra)
end

@recipe function f(dd::_DistanceData)
    mids = [(dd.edges[i] + dd.edges[i+1]) / 2 for i in 1:(length(dd.edges) - 1)]
    step = length(dd.edges) > 1 ? dd.edges[2] - dd.edges[1] : 1.0

    legend --> :topright
    xlabel --> (dd.logscale ? "log10(distance)" : "distance")
    ylabel --> "proposals"
    title  --> "Generation $(dd.t) proposal distances$(dd.note)"

    if any(>(0), dd.accepted_counts)
        @series begin
            seriestype := :bar
            bar_width  := step
            linewidth  := 0
            fillcolor  := :seagreen
            label      := "passed ε ($(Int(sum(dd.accepted_counts))))"
            mids, dd.accepted_counts
        end
    end
    if any(>(0), dd.rejected_counts)
        @series begin
            seriestype := :bar
            bar_width  := step
            linewidth  := 0
            fillcolor  := :indianred
            label      := "rejected ($(Int(sum(dd.rejected_counts))))"
            mids, dd.rejected_counts
        end
    end
    if !isnothing(dd.epsilon_threshold)
        #! `:path`, not `:vline` — `sensitivity_visualize.jl` keeps to `:bar`/`:scatter`/`:path` so a
        #! recipe does not require a particular backend's series types.
        @series begin
            seriestype := :path
            linestyle  := :dash
            linewidth  := 2
            linecolor  := :black
            label      := "threshold"
            top = maximum(vcat(dd.accepted_counts, dd.rejected_counts); init=1.0)
            [dd.epsilon_threshold, dd.epsilon_threshold], [0.0, top]
        end
    end
end

#! Splits one generation's proposal frame into the two series. Falls back to the accepted distances
#! alone for a run recorded before proposal distances were kept — a degraded plot beats an error, and
#! the note says which one you are looking at.
function _distanceSeries(proposal_distances::Union{Nothing,DataFrame},
                         accepted_distances::Vector{Float64})
    if isnothing(proposal_distances) || nrow(proposal_distances) == 0
        return Float64.(accepted_distances), Float64[],
               " — rejected distances were not recorded for this run"
    end
    acc = Float64.(proposal_distances[proposal_distances.accepted, :distance])
    rej = Float64.(proposal_distances[.!proposal_distances.accepted, :distance])
    #! `accepted` means "passed ε", which is not the same as "kept as a particle": with
    #! `accept_overflow=false` a batch can overshoot `population_size`, and the surplus passed ε but
    #! was trimmed. The green bars are therefore the honest picture of the *acceptance process*, and
    #! can outnumber the posterior. Say so on the plot rather than leaving the reader to reconcile
    #! the legend against a particle count the figure never shows.
    #! `n_kept == 0` means the caller did not supply a particle set to compare against, not that a
    #! generation kept nothing — so there is nothing to reconcile and no note to write.
    n_kept = length(accepted_distances)
    note = (n_kept > 0 && length(acc) > n_kept) ?
        " — $(length(acc)) passed ε, $(n_kept) kept as particles (overflow trimmed)" : ""
    return acc, rej, note
end

"""
    plot(result::ABCResult, style::Symbol; kwargs...)

Dispatch to specialized visualization recipes for `ABCResult`:

- `:ridgeline` — posterior narrowing plot: stacked 1D KDE curves per generation per
  parameter. `space` keyword: `:target` (default) or `:cdf`.

- `:transition` — generation transition plot: gen-t KDE overlaid with gen-(t+1) proposal
  points (accepted in green, rejected in red). Keywords:
  - `generation::Int` — which generation to show the KDE for (proposals = gen+1).
    Default: `length(result.generations) - 1` (the last complete gen→gen+1 transition).
    For `:ridgeline` and other non-transition styles the default is `length(result.generations)`.
  - `show_particles::Bool` — overlay gen-t particles beneath the KDE (default `false`).
  - `space::Symbol` — `:target` (default) or `:cdf`.
  - `aggregate_duplicates::Bool` — group coincident proposals into bubbles (default `true`).
"""
@recipe function f(result::ABCResult, style::Symbol;
                   space               = :target,
                   generation          = nothing,
                   show_particles      = false,
                   aggregate_duplicates = true,
                   logscale            = false)
    isempty(result.generations) && error("No generations in ABCResult.")
    T = length(result.generations)
    resolved_gen = if isnothing(generation)
        style === :transition ? max(T - 1, 1) : T
    else
        Int(generation)
    end

    if style === :ridgeline
        dfs = Vector{DataFrame}(undef, T)
        wts = Vector{Vector{Float64}}(undef, T)
        for t in 1:T
            dfs[t], wts[t] = _vizParticles(result, t, space)
        end
        pnames = names(dfs[1])

        # Build prior (gen 0) by sampling uniform CDF coords and converting to target space.
        prior_df  = nothing
        prior_wts = nothing
        if space === :target && !isempty(result.parameters)
            N_prior   = 500
            cdf_vals  = collect((1:N_prior) ./ (N_prior + 1))   # uniform quantiles, avoids endpoints
            cdf_names = [n for cp in result.parameters for n in cp.lv.latent_parameter_names]
            prior_cdf = DataFrame([n => cdf_vals for n in cdf_names]...)
            prior_df  = _cdfDFToTarget(prior_cdf, result.parameters)
            prior_wts = fill(1.0 / N_prior, N_prior)
        end

        _RidgelineData(dfs, wts, prior_df, prior_wts, pnames)

    elseif style === :transition
        T < 2 && error(":transition plot requires at least 2 generations.")
        t      = resolved_gen
        t_next = t + 1
        (1 <= t && t_next <= T) || throw(ArgumentError(
            "generation must be in [1, $(T-1)] for :transition, got $t"))

        kde_df, kde_w = _vizParticles(result, t, space)
        acc_df, acc_w = _vizParticles(result, t_next, space)
        rej_df, note  = _getRejected(result, t_next, space)

        pnames = names(kde_df)
        # Filter proposal DataFrames to common columns
        acc_df_filt = select(acc_df, intersect(pnames, names(acc_df)))
        rej_df_filt = isnothing(rej_df) ? nothing :
                      select(rej_df, intersect(pnames, names(rej_df)))

        _TransitionData(kde_df, kde_w, acc_df_filt, acc_w,
                        rej_df_filt, pnames,
                        result.method.population_size, note,
                        show_particles, aggregate_duplicates)

    elseif style === :distances
        gen = result.generations[resolved_gen]
        acc, rej, note = _distanceSeries(gen.proposal_distances, gen.distances)
        _buildDistanceData(acc, rej, gen.epsilon_threshold, gen.max_epsilon_accepted,
                           resolved_gen; logscale=logscale, note=note)
    else
        error("Unknown ABCResult plot style :$style. Use :ridgeline, :transition or :distances.")
    end
end

"""
    plot(cal::Calibration, style::Symbol; kwargs...)

Dispatch to specialized visualization recipes for a disk-resident `Calibration`:

- `:ridgeline` — posterior narrowing plot loaded from generation CSVs on disk.
  No prior (gen 0) is shown since the problem definition cannot always be recovered from disk.

- `:transition` — generation transition plot. Keywords:
  - `generation::Int` — which generation to use as the KDE base (proposals = gen+1).
    Defaults to the penultimate completed generation.
  - `show_particles::Bool` — overlay gen-t particles beneath the KDE (default `false`).
  - `aggregate_duplicates::Bool` — group coincident proposals into bubbles (default `true`).
"""
@recipe function f(cal::Calibration, style::Symbol;
                   generation           = nothing,
                   show_particles       = false,
                   aggregate_duplicates = true,
                   logscale             = false)
    gen_dir = joinpath(calibrationFolder(cal), "generations")
    isdir(gen_dir) || error("No generations directory for Calibration($(cal.id)).")
    #! Generations are addressed by index throughout, so both layouts and any padding width behave
    #! alike, and `t` never means "position in a sorted listing".
    indices = _generationIndices(gen_dir)
    isempty(indices) && error("No completed generations for Calibration($(cal.id)).")

    # Helper: read generation t's display-format particles; return (param_df, weights, raw_df).
    function _readGenCSV(t::Int)
        path = _generationArtifact(gen_dir, t, :particles)
        isnothing(path) && error(
            "Generation $t of Calibration($(cal.id)) has no particle file.")
        raw = CSV.read(path, DataFrame)
        w   = hasproperty(raw, :weight) ? Float64.(raw[!, :weight]) :
              fill(1.0 / nrow(raw), nrow(raw))
        df  = select(raw, Not(intersect([:weight, :distance, :monad_id],
                                        Symbol.(names(raw)))))
        return df, w, raw
    end

    if style === :ridgeline
        dfs = Vector{DataFrame}()
        wts = Vector{Vector{Float64}}()
        for t in indices
            df, w, _ = _readGenCSV(t)
            push!(dfs, df)
            push!(wts, w)
        end
        pnames = names(dfs[1])
        _RidgelineData(dfs, wts, nothing, nothing, pnames)

    elseif style === :transition
        T = last(indices)
        t = isnothing(generation) ? max(T - 1, 1) : Int(generation)
        t_next = t + 1
        (t in indices && t_next in indices) || throw(ArgumentError(
            "generation must be one with a successor; got $t, available $(indices)"))

        kde_df, kde_w, _        = _readGenCSV(t)
        acc_df, acc_w, acc_raw  = _readGenCSV(t_next)

        pnames = names(kde_df)

        # Accepted monad IDs for rejected-proposal detection
        accepted_monad_ids = hasproperty(acc_raw, :monad_id) ?
                             acc_raw[!, :monad_id] : Int[]

        # Load method settings for population_size / max_nr_populations
        method_toml = joinpath(calibrationFolder(cal), "method.toml")
        pop_size, max_nr_pop = if isfile(method_toml)
            d = TOML.parsefile(method_toml)
            Int(d["population_size"]), Int(d["max_nr_populations"])
        else
            length(accepted_monad_ids), T
        end

        # Attempt to load rejected proposals via simulationsTable + TOML mapping
        params_toml = joinpath(calibrationFolder(cal), "parameters.toml")
        mapping     = _buildDbToDisplayMappingFromTOML(params_toml)
        rej_df = _lazyLoadRejectedFromDisk(cal, t_next, max_nr_pop,
                                            accepted_monad_ids, pnames, mapping)
        note = isnothing(rej_df) ? " (rejected proposals unavailable)" : ""

        acc_df_filt = select(acc_df, intersect(pnames, names(acc_df)))
        rej_df_filt = isnothing(rej_df) ? nothing :
                      let common = intersect(pnames, names(rej_df))
                          isempty(common) ? nothing : select(rej_df, common)
                      end

        _TransitionData(kde_df, kde_w, acc_df_filt, acc_w,
                        rej_df_filt, pnames,
                        pop_size, note,
                        show_particles, aggregate_duplicates)
    elseif style === :distances
        t = isnothing(generation) ? last(indices) : Int(generation)
        t in indices || error("No generation $(t) for Calibration($(cal.id)).")
        prop_path = _generationArtifact(gen_dir, t, :proposals)
        prop_df = isnothing(prop_path) ? nothing :
            CSV.read(prop_path, DataFrame;
                     types=Dict(:monad_id => Int, :distance => Float64, :accepted => Bool))
        _, _, raw = _readGenCSV(t)
        acc_dists = hasproperty(raw, :distance) ? Float64.(raw[!, :distance]) : Float64[]
        meta = _calibrationGenerationMeta(cal, t)
        acc, rej, note = _distanceSeries(prop_df, acc_dists)
        _buildDistanceData(acc, rej, get(meta, "epsilon_threshold", nothing),
                           Float64(get(meta, "max_epsilon_accepted",
                                       get(meta, "epsilon", NaN))),
                           t; logscale=logscale, note=note)
    else
        error("Unknown Calibration plot style :$style. Use :ridgeline, :transition or :distances.")
    end
end
