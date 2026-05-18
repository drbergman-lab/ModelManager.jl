################## SimulationBank ##################

"""
    SimulationBank

Pre-built registry of existing monads whose calibrated parameters lie strictly
within the prior support `(0,1)^d` in CDF space.

Built once at calibration start by [`_buildSimulationBank`](@ref) and reused across
all generations for approximate simulation reuse (CDF-grid snapping).

# Fields
- `monad_ids::Vector{Int}`: Monad IDs of eligible entries.
- `cdf_coords::Matrix{Float64}`: `n_latent_dims × n_monads` matrix of CDF-space
  coordinates for each eligible monad (columns correspond to `monad_ids`).
- `param_names::Vector{String}`: Latent parameter names matching rows of `cdf_coords`.
- `tree::Union{Nothing,NNTree}`: KD-tree (Chebyshev metric) built from `cdf_coords`
  for O(log n) L∞ box queries. `nothing` when the bank is empty.
"""
struct SimulationBank
    monad_ids::Vector{Int}
    cdf_coords::Matrix{Float64}
    param_names::Vector{String}
    tree::Union{Nothing,NNTree}
end

"""
    SimulationBank(monad_ids, cdf_coords, param_names) → SimulationBank

Convenience constructor that automatically builds the KD-tree from `cdf_coords`.
`tree` is `nothing` when `monad_ids` is empty.
"""
function SimulationBank(monad_ids::Vector{Int}, cdf_coords::Matrix{Float64},
                         param_names::Vector{String})
    tree = isempty(monad_ids) ? nothing : KDTree(cdf_coords, Chebyshev())
    return SimulationBank(monad_ids, cdf_coords, param_names, tree)
end

"""
    _buildSimulationBank(problem::CalibrationProblem) → SimulationBank

Query the database for all existing monads compatible with `problem` whose calibrated
parameters lie strictly within `(0,1)^d` in CDF space.

**Terminology used below:**
- *Parameter*: a user-supplied `CalibrationParameter` target (may or may not have a
  column in the variation DB yet).
- *Column*: a parameter that already has a column in the variation DB.

**Compatibility criteria for each monad:**

1. All location folder IDs match `problem.inputs`.
2. For every varied location with no calibrated parameters, the variation ID exactly
   matches `problem.reference_variation_id[loc]`.
3. For each calibrated location, the variation row must pass:
   - **Non-calibrated columns** must exactly match the reference variation row value.
   - **Calibrated columns** (parameters that already have a column in the DB): the row
     value must lie in `[minimum(dist), maximum(dist)]` of the prior.
   - **Calibrated parameters without a column yet** (never varied before): the base value
     is read from the config file via [`getColumnDefaults`](@ref). Because no variation
     row can give a different value, any failure to read or parse the value, or a value
     outside the prior support, means no monad anywhere is usable — an empty bank is
     returned immediately. If the value is within the support, all candidate variation IDs
     inherit that base value for CDF computation.
   - **`CVSource` joint consistency**: the latent CDF recovered from the first target must
     forward-map back to all other targets within relative tolerance 1e-8. Monads that do
     not lie on the co-variation curve are excluded.
4. All CDF coordinates are strictly in `(0, 1)`.

`LVSource` parameters without `inverse_maps` disable the bank (returns empty, informational
log emitted). `LVSource` parameters with `inverse_maps` are supported: target-space bounds
checks are skipped for their columns (Phase 2) and Phase 3 CDF inversion filters via `0 < u < 1`.

Returns a [`SimulationBank`](@ref) with zero columns when no compatible monads exist.
"""
function _buildSimulationBank(problem::CalibrationProblem)
    cps     = problem.parameters
    inputs  = problem.inputs
    ref_vid = problem.reference_variation_id

    param_names = vcat([cp.lv.latent_parameter_names for cp in cps]...)
    n_dims = length(param_names)

    empty_bank = SimulationBank(Int[], Matrix{Float64}(undef, n_dims, 0), param_names)

    isInitialized() || return empty_bank

    # LVSource without inverse maps → bank disabled.
    lv_no_inv = [cp for cp in cps if cp.source isa LVSource && isnothing(cp.lv.inverse_maps)]
    if !isempty(lv_no_inv)
        names = join([cp.lv.name for cp in lv_no_inv], ", ")
        @info "SimulationBank: LVSource parameter(s) \"$names\" have no inverse maps; " *
              "bank disabled. Supply `inverse_maps` when constructing LatentVariation to enable."
        return empty_bank
    end

    # loc → [(col_name, xml_path, cp)] for each calibrated location.
    calib_at_loc = Dict{Symbol, Vector{Tuple{String, XMLPath, CalibrationParameter}}}()
    for cp in cps
        for (loc, target) in zip(cp.lv.locations, cp.lv.targets)
            push!(get!(calib_at_loc, loc, Tuple{String, XMLPath, CalibrationParameter}[]),
                  (columnName(target), target, cp))
        end
    end
    calibrated_locs = keys(calib_at_loc)

    # ── Phase 1: central DB query ────────────────────────────────────────────
    where_parts = String[
        "$(simulatorVersionIDName()) = $(currentSimulatorVersionID())",
    ]
    for loc in projectLocations().all
        push!(where_parts, "$(locationIDName(loc)) = $(inputs[loc].id)")
    end
    for loc in projectLocations().varied
        loc ∈ calibrated_locs && continue
        push!(where_parts, "$(locationVariationIDName(loc)) = $(ref_vid[loc])")
    end
    where_clause = "WHERE " * join(where_parts, " AND ")

    df = queryToDataFrame(constructSelectQuery("monads", where_clause))
    isempty(df) && return empty_bank

    # ── Phase 2: per-location variation filtering ────────────────────────────
    # loc_vid_to_targets[loc][vid] = Dict{col_name => Float64 value}
    loc_vid_to_targets = Dict{Symbol, Dict{Int, Dict{String, Float64}}}()

    for loc in calibrated_locs
        vid_col    = locationVariationIDName(loc)
        table      = locationVariationsTableName(loc)
        db         = locationVariationsDatabase(loc, inputs[loc].id)
        db isa SQLite.DB || continue
        folder_id  = inputs[loc].id

        # All columns currently in the variation table (excluding ID and par_key).
        all_db_cols    = filter(c -> c != vid_col && c != "par_key",
                                String.(tableColumns(table; db=db)))
        all_db_col_set = Set{String}(all_db_cols)

        # Separate calibrated parameters into those with / without a DB column.
        loc_params       = calib_at_loc[loc]   # [(col_name, xml_path, cp)]
        params_with_col  = [(col, xp, cp) for (col, xp, cp) in loc_params if col ∈ all_db_col_set]
        params_no_col    = [(col, xp, cp) for (col, xp, cp) in loc_params if col ∉ all_db_col_set]

        # Non-calibrated columns: DB columns not targeted by any calibrated parameter.
        calib_col_set  = Set{String}(col for (col, _, _) in loc_params)
        non_calib_cols = filter(∉(calib_col_set), all_db_cols)

        # ── Calibrated parameters with no DB column yet ──────────────────────
        # Every monad in the DB has the base config value for this parameter (the column
        # doesn't exist so no variation row can differ). We must be able to read and
        # interpret that value for every no-column parameter — without it we cannot compute
        # CDF coordinates for any monad. Any failure (unreadable config, unparseable value,
        # or value outside the prior support) means no monad anywhere is usable: return
        # the empty bank immediately.
        base_missing_vals = Dict{String, Float64}()  # col → base value (fed into CDF)
        for (col, xp, cp) in params_no_col
            defaults_str = try
                getColumnDefaults(loc, folder_id, XMLPath[xp])
            catch
                @info "SimulationBank: could not read base config value for calibrated " *
                      "parameter \"$col\" (no DB column). CDF coordinates cannot be " *
                      "computed for any monad. Returning empty bank."
                return empty_bank
            end
            if isempty(defaults_str) || isnothing(tryparse(Float64, defaults_str[1]))
                @info "SimulationBank: base config value for calibrated parameter " *
                      "\"$col\" (no DB column) is missing or non-numeric. Returning empty bank."
                return empty_bank
            end
            v = parse(Float64, defaults_str[1])

            if cp.source isa LVSource
                # No target-space distribution for LVSource; accept base value without
                # bounds check. Phase 3 CDF inversion excludes the monad if u ∉ (0,1).
                base_missing_vals[col] = v
                continue
            end

            dist = _bankColDistribution(cp, col)
            if isnothing(dist)
                @warn "SimulationBank: could not retrieve prior distribution for " *
                      "calibrated parameter \"$col\" (no DB column). This should not " *
                      "happen — please report this as a bug. Returning empty bank."
                return empty_bank
            end
            if !(minimum(dist) ≤ v ≤ maximum(dist))
                @info "SimulationBank: calibrated parameter \"$col\" has no DB column; " *
                      "its base config value $v lies outside the prior support " *
                      "[$(minimum(dist)), $(maximum(dist))]. No existing monad can have " *
                      "a compatible value for this parameter. Returning empty bank."
                return empty_bank
            end
            base_missing_vals[col] = v
        end

        # ── Candidate variation IDs from the central-DB result ────────────────
        candidate_vids = unique!([v for v in df[!, vid_col]
                                  if !ismissing(v) && v != -1])
        isempty(candidate_vids) && return empty_bank

        # Batch-query: include the reference vid (needed for eff_ref) and all candidates.
        all_query_vids = unique!(sort([ref_vid[loc], candidate_vids...]))
        isempty(all_db_cols) && (loc_vid_to_targets[loc] = Dict(v => base_missing_vals
                                                                 for v in candidate_vids);
                                  continue)

        col_select = join(["\"$c\"" for c in all_db_cols], ", ")
        vid_list   = join(all_query_vids, ", ")
        var_df     = queryToDataFrame(
            "SELECT $vid_col, $col_select FROM $table WHERE $vid_col IN ($vid_list)";
            db=db)

        # Build raw_rows: vid → Dict{col => raw value (may be missing)}.
        raw_rows = Dict{Int, Dict{String, Any}}()
        for row in eachrow(var_df)
            vid = Int(row[Symbol(vid_col)])
            raw_rows[vid] = Dict{String, Any}(
                col => row[Symbol(col)] for col in all_db_cols)
        end

        # Effective reference values for non-calibrated columns.
        ref_row = get(raw_rows, ref_vid[loc], Dict{String, Any}())
        eff_ref = Dict{String, Any}(col => ref_row[col] for col in non_calib_cols)

        # Support bounds for calibrated columns (those in the DB).
        # LVSource columns have no target-space distribution — skip bounds; Phase 3 filters via CDF.
        calib_col_bounds = Dict{String, Tuple{Float64, Float64}}()
        for (col, _, cp) in params_with_col
            cp.source isa LVSource && continue
            dist = _bankColDistribution(cp, col)
            if isnothing(dist)
                @warn "SimulationBank: could not retrieve prior distribution for " *
                      "calibrated parameter \"$col\" (DB column exists). This should not " *
                      "happen — please report this as a bug. Returning empty bank."
                return empty_bank
            end
            calib_col_bounds[col] = (Float64(minimum(dist)), Float64(maximum(dist)))
        end

        # ── Filter each candidate variation ID ────────────────────────────────
        vid_to_targets = Dict{Int, Dict{String, Float64}}()
        for vid in candidate_vids
            row_dict = get(raw_rows, vid, Dict{String, Any}())
            valid = true

            # Non-calibrated columns must exactly match reference values.
            if any(col -> row_dict[col] != eff_ref[col], non_calib_cols)
                continue
            end

            # Calibrated columns: apply prior support bounds where available.
            # LVSource columns have no bounds entry → accept any value; Phase 3 filters.
            targets = copy(base_missing_vals)   # seed with base values for no-column params
            for (col, _, _) in params_with_col
                v_f = Float64(row_dict[col])
                if haskey(calib_col_bounds, col)
                    lb, ub = calib_col_bounds[col]
                    !(lb ≤ v_f ≤ ub) && (valid = false; break)
                end
                targets[col] = v_f
            end
            valid || continue

            vid_to_targets[vid] = targets
        end

        loc_vid_to_targets[loc] = vid_to_targets
    end

    # ── Phase 3: CDF computation and interior filter ────────────────────────
    valid_monad_ids = Int[]
    valid_cdf_cols  = Vector{Vector{Float64}}()

    for row in eachrow(df)
        monad_id = row[:monad_id]
        ok = true

        all_targets = Dict{String, Float64}()
        for loc in calibrated_locs
            vid_col = locationVariationIDName(loc)
            vid_raw = row[Symbol(vid_col)]
            (ismissing(vid_raw) || vid_raw == -1) && (ok = false; break)
            loc_map = get(loc_vid_to_targets, loc, nothing)
            (isnothing(loc_map) || !haskey(loc_map, vid_raw)) && (ok = false; break)
            merge!(all_targets, loc_map[vid_raw])
        end
        ok || continue

        cdf_coords = Float64[]
        for cp in cps
            coords = _bankCdfCoords(cp, all_targets)
            if isnothing(coords) || any(u -> !(0 < u < 1), coords)
                ok = false; break
            end
            append!(cdf_coords, coords)
        end
        ok || continue

        push!(valid_monad_ids, monad_id)
        push!(valid_cdf_cols, cdf_coords)
    end

    n_valid = length(valid_monad_ids)
    cdf_mat = n_valid > 0 ?
        reduce(hcat, valid_cdf_cols) :
        Matrix{Float64}(undef, n_dims, 0)

    return SimulationBank(valid_monad_ids, cdf_mat, param_names)
end

################## Per-column distribution helper ##################

"""
    _bankColDistribution(cp::CalibrationParameter, col::String) → Distribution or nothing

Return the prior distribution associated with database column `col` for `cp`.

Used in [`_buildSimulationBank`](@ref) to determine the prior support bounds for
pre-filtering candidate variation rows. Returns `nothing` for `LVSource` (no
distribution over target space) or when `col` does not match any target of `cp`.
"""
_bankColDistribution(cp::CalibrationParameter, col::String) =
    _bankColDistribution(cp.source, cp.lv, col)

function _bankColDistribution(s::DVSource, lv::LatentVariation, col::String)
    columnName(lv.targets[1]) == col || return nothing
    return s.dv.distribution
end

function _bankColDistribution(s::CVSource, lv::LatentVariation, col::String)
    idx = findfirst(t -> columnName(t) == col, lv.targets)
    isnothing(idx) && return nothing
    return s.cv.variations[idx].distribution
end

_bankColDistribution(::LVSource, ::LatentVariation, ::String) = nothing

################## CDF inversion helpers ##################

"""
    _bankCdfCoords(cp::CalibrationParameter, vals::Dict{String,Float64})

Convert stored target-parameter values to latent CDF coordinates for the bank.

Returns a `Vector{Float64}` with one entry per latent dimension, or `nothing`
when conversion is not possible (missing column or `lv.inverse_maps` is `nothing`).

Dispatches to `_bankCdfCoords(lv, vals)` using the inverse maps stored on the
`LatentVariation`. For `DVSource`- and `CVSource`-backed variations, inverse maps are
auto-constructed at `LatentVariation` construction time. For `LVSource`, the user
must supply `inverse_maps` when constructing the `LatentVariation`; otherwise this
returns `nothing`.

The CVSource auto-constructed inverse map includes a joint-consistency check: if the
recovered latent parameter value `lp` does not forward-map back to all other targets within
relative tolerance 1e-8, the inverse map returns `NaN`, which is interpreted here as `nothing`.
"""
_bankCdfCoords(cp::CalibrationParameter, vals::Dict{String, Float64}) =
    _bankCdfCoords(cp.lv, vals)

function _bankCdfCoords(lv::LatentVariation, vals::Dict{String, Float64})
    isnothing(lv.inverse_maps) && return nothing
    target_vals = Float64[]
    for t in lv.targets
        col = columnName(t)
        haskey(vals, col) || return nothing
        push!(target_vals, vals[col])
    end
    lp_vals = [inv_map(target_vals) for inv_map in lv.inverse_maps]
    any(isnan, lp_vals) && return nothing   # e.g. CVSource consistency check failed
    cdfs = [cdf(d, lp) for (d, lp) in zip(lv.latent_parameters, lp_vals)]
    return cdfs
end
