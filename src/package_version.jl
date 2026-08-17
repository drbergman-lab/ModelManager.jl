using Pkg, SQLite

"""
    getPackageVersion(sim::AbstractSimulator)::VersionNumber

Return the version of the package that owns `sim` as **installed in the active
environment**, by querying `Pkg`.

This is what the environment's manifest records — what `Pkg.status` prints, and what
`Pkg.update` or `Pkg.add` changes. It is not necessarily the version running: see
[`loadedPackageVersion`](@ref) for the version this session actually loaded, which is what
migrations are driven by.

If the current project IS that package (i.e. running tests from within the package
itself), `Pkg.project().version` is returned directly. Otherwise, the loaded
dependency list is searched by [`packageName`](@ref).
"""
function getPackageVersion(sim::AbstractSimulator)::VersionNumber
    name = packageName(sim)
    proj = Pkg.project()
    if proj.name == name
        return proj.version
    end
    deps = Pkg.dependencies()
    uuid = findfirst(dep -> dep.name == name, deps)
    isnothing(uuid) && throw(ArgumentError(
        "$(name) is not a loaded dependency. How are you running this?"
    ))
    return deps[uuid].version
end

#! The version a migration may target is the one whose code is *running*, not the one the
#! environment advertises: `upgradeMilestones` dispatches on the loaded module, so the loaded
#! version is the furthest point whose schema changes are knowable here. Recording anything
#! beyond it would mark migrations as applied that this session has no way to apply, and the
#! version comparison in `resolvePackageVersion` would then skip them forever.
#! A `nothing` from `loadedPackageVersion` means the loaded version cannot be determined, in
#! which case the environment's version is the best estimate available.
function _migrationTargetVersion(sim::AbstractSimulator)::VersionNumber
    loaded = loadedPackageVersion(sim)
    return isnothing(loaded) ? getPackageVersion(sim) : loaded
end

"""
    getDBPackageVersion(sim::AbstractSimulator, db::SQLite.DB)::VersionNumber

Return the package version recorded in `db` under [`dbVersionTableName`](@ref)`(sim)`.

If the table does not yet exist it is created and stamped with the version this session is
running — [`loadedPackageVersion`](@ref), falling back to [`getPackageVersion`](@ref) when
that cannot be determined. This handles fresh databases, and databases that pre-date the
versioning system.
"""
function getDBPackageVersion(sim::AbstractSimulator, db::SQLite.DB)::VersionNumber
    table = dbVersionTableName(sim)
    if tableExists(table; db=db)
        return queryToDataFrame("SELECT * FROM $(table);"; db=db) |> x -> VersionNumber(x.version[1])
    end
    #! The loaded version rather than the installed one: the schema about to be built for this
    #! database comes from the loaded code, so that is what the database contains.
    version = _migrationTargetVersion(sim)
    DBInterface.execute(db, "CREATE TABLE IF NOT EXISTS $(table) (version TEXT PRIMARY KEY);")
    DBInterface.execute(db, "INSERT INTO $(table) (version) VALUES ('$(version)');")
    return version
end

"""
    resolvePackageVersion(sim::AbstractSimulator, db::SQLite.DB; auto_upgrade::Bool=false)::Bool

Compare the version recorded in `db` with the version of the package **loaded in this
session** ([`loadedPackageVersion`](@ref)) and upgrade if needed.

The loaded version is the target because the migration chain is built from the loaded
code: [`upgradeMilestones`](@ref) can only describe schema changes belonging to the release
this session is running. Migrating no further than that keeps the recorded version and the
applied migrations in step. When the loaded version cannot be determined, the version
installed in the environment ([`getPackageVersion`](@ref)) is used instead.

- If the installed version differs from the loaded one — the environment was changed while
  this session was running — warns, then migrates to the loaded version regardless. Restart
  Julia to pick up the installed version and migrate the rest of the way.
- If the database is *newer* than the loaded version, prints an explanation and returns
  `false`.
- If the versions match, returns `true` immediately.
- If the loaded version is *newer*, calls `upgradePackage` and returns its result.
"""
function resolvePackageVersion(sim::AbstractSimulator, db::SQLite.DB;
                               auto_upgrade::Bool=false)::Bool
    name      = packageName(sim)
    installed = getPackageVersion(sim)
    target    = _migrationTargetVersion(sim)

    #! `maxlog=1` because the condition cannot change within a session — the loaded version is
    #! fixed at load time — so one notice per session is the right cardinality even if several
    #! projects are opened.
    if target != installed
        @warn """
        $(name) $(installed) is installed in this environment but $(target) is loaded in this session.
        The database will be migrated to $(target), matching the code that is running.
        Restart Julia to load $(installed) and migrate the rest of the way.
        """ maxlog=1
    end

    db_version = getDBPackageVersion(sim, db)

    if target < db_version
        #! Two different remedies, and printing the wrong one sends the user in circles: when the
        #! session simply lags the environment, the package is already new enough and restarting
        #! is what fixes it.
        if target < installed
            println("""
            The database version is $(db_version) but only $(name) $(target) is loaded in this session.
            Restart Julia to load the installed version ($(installed)) before opening this project.
            """)
        else
            println("""
            The $(name) version is $(target) but the database version is $(db_version).
            Upgrade your $(name) version to $(db_version) or higher before opening this project.
            """)
        end
        return false
    end

    target == db_version && return true

    return upgradePackage(sim, db, db_version, target, auto_upgrade)
end
