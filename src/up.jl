using SQLite

"""
    continueMilestoneUpgrade(version::VersionNumber, auto_upgrade::Bool)

Print a warning about the schema change at `version` and prompt the user to confirm
unless `auto_upgrade` is `true`. Returns `true` if the upgrade should proceed,
`false` if the user aborted.

Call this at the top of any [`upgradeToMilestone`](@ref) implementation that makes
large or destructive changes to the database schema.
"""
function continueMilestoneUpgrade(version::VersionNumber, auto_upgrade::Bool)
    warning_msg = """
    \t- Upgrading to version $(version)...

    WARNING: Upgrading to version $(version) will change the database schema.

    ------IF ANOTHER INSTANCE OF THIS PACKAGE IS USING THIS DATABASE, PLEASE CLOSE IT BEFORE PROCEEDING.------

    Continue upgrading to version $(version)? (y/n):
    """
    println(warning_msg)
    response = auto_upgrade ? "y" : readline()
    if response != "y"
        println("Upgrade to version $(version) aborted.")
        return false
    end
    println("\t- Upgrading to version $(version)...")
    return true
end

"""
    populateTableOnFeatureSubset(db::SQLite.DB, source_table::String, target_table::String; column_mapping::Dict{String,String}=Dict{String,String}())

Populate a `target_table` with rows from `source_table`. Columns in `source_table`
that exist (possibly under a different name) in `target_table` are copied; extras are
ignored. Use `column_mapping` to rename columns during the copy
(`source_name => target_name`).
"""
function populateTableOnFeatureSubset(db::SQLite.DB, source_table::String, target_table::String;
                                      column_mapping::Dict{String,String}=Dict{String,String}())
    @assert tableExists(source_table; db=db) "Source table $(source_table) does not exist in the database."
    @assert tableExists(target_table; db=db) "Target table $(target_table) does not exist in the database."
    source_columns = tableColumns(source_table; db=db)
    target_columns = [haskey(column_mapping, c) ? column_mapping[c] : c for c in source_columns]
    @assert columnsExist(target_columns, target_table; db=db) "One or more target columns do not exist in the target table."
    insert_into_cols = "(" * join(target_columns, ",") * ")"
    select_cols = join(source_columns, ",")
    query = "INSERT INTO $(target_table) $(insert_into_cols) SELECT $(select_cols) FROM $(source_table);"
    DBInterface.execute(db, query)
end

"""
    upgradePackage(sim::AbstractSimulator, db::SQLite.DB, from_version::VersionNumber, to_version::VersionNumber, auto_upgrade::Bool)

Drive the database migration from `from_version` to `to_version` for the simulator
framework `sim`.

For each milestone `v` in [`upgradeMilestones`](@ref)`(sim)` with
`from_version < v ≤ to_version`, calls [`upgradeToMilestone`](@ref)`(sim, v, auto_upgrade)`.
After a successful milestone upgrade the version table is updated immediately so that
a partial upgrade is recoverable. If any milestone fails the chain is aborted and
`false` is returned.

After all milestones pass, if `to_version` is beyond the last milestone the version
table is stamped with `to_version` (a "no schema change" bump).

A `to_version` beyond the version loaded in this session is refused, leaving the version table
untouched. [`resolvePackageVersion`](@ref) never asks for such a target; the check applies to
direct callers.
"""
function upgradePackage(sim::AbstractSimulator, db::SQLite.DB,
                        from_version::VersionNumber, to_version::VersionNumber,
                        auto_upgrade::Bool)
    #! Unreachable from `resolvePackageVersion`, which already targets the loaded version — this
    #! guards a direct call, where `to_version` is whatever the caller passed. Refusing rather
    #! than clamping, because silently migrating somewhere other than asked is the worse surprise.
    #! `>`, not `!=`: a target *below* the loaded version is legitimate — resuming a partially
    #! applied chain, or deliberately migrating to an earlier milestone.
    loaded_version = loadedPackageVersion(sim)
    if !isnothing(loaded_version) && to_version > loaded_version
        _errorTargetBeyondLoaded(packageName(sim), to_version, loaded_version)
        return false
    end

    @info "Upgrading from version $(from_version) to $(to_version)..."
    milestones = upgradeMilestones(sim)
    @assert issorted(milestones) "Milestone versions must be sorted in ascending order. Got $(milestones)."
    pending = filter(v -> from_version < v <= to_version, milestones)
    table = dbVersionTableName(sim)
    success = true
    for milestone in pending
        success = upgradeToMilestone(sim, milestone, auto_upgrade)
        if !success
            break
        end
        DBInterface.execute(db, "UPDATE $(table) SET version='$(milestone)';")
    end
    if success && (isempty(pending) || to_version > last(pending))
        DBInterface.execute(db, "UPDATE $(table) SET version='$(to_version)';")
    end
    return success
end

#! Public despite not being exported: `upgradePackage` is the user-facing migration entry
#! point, and the other two are the helpers a backend calls when writing its own milestone.
#! See CLAUDE.md, "Docstring cross-references".
@compat public upgradePackage, continueMilestoneUpgrade, populateTableOnFeatureSubset
