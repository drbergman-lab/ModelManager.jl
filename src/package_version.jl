using Pkg, SQLite

"""
    getPackageVersion(sim::AbstractSimulator)::VersionNumber

Return the runtime version of the package that owns `sim` by querying `Pkg`.

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

"""
    getDBPackageVersion(sim::AbstractSimulator, db::SQLite.DB)::VersionNumber

Return the package version recorded in `db` under [`dbVersionTableName`](@ref)`(sim)`.

If the table does not yet exist it is created and stamped with the current
[`getPackageVersion`](@ref) — this handles fresh databases that pre-date the
versioning system.
"""
function getDBPackageVersion(sim::AbstractSimulator, db::SQLite.DB)::VersionNumber
    table = dbVersionTableName(sim)
    if tableExists(table; db=db)
        return queryToDataFrame("SELECT * FROM $(table);"; db=db) |> x -> VersionNumber(x.version[1])
    end
    # Table doesn't exist yet — create it and stamp the current version.
    pkg_version = getPackageVersion(sim)
    DBInterface.execute(db, "CREATE TABLE IF NOT EXISTS $(table) (version TEXT PRIMARY KEY);")
    DBInterface.execute(db, "INSERT INTO $(table) (version) VALUES ('$(pkg_version)');")
    return pkg_version
end

"""
    resolvePackageVersion(sim::AbstractSimulator, db::SQLite.DB; auto_upgrade::Bool=false)::Bool

Compare the runtime package version with the version recorded in `db` and upgrade
if needed.

- If the version installed in the environment differs from the one loaded in this session,
  prints an explanation and returns `false` without reading or writing `db` (restart Julia).
- If the database is *newer* than the package, prints an error and returns `false`
  (the user must upgrade their package).
- If versions match, returns `true` immediately.
- If the package is *newer*, calls `upgradePackage` and returns its result.
"""
function resolvePackageVersion(sim::AbstractSimulator, db::SQLite.DB;
                               auto_upgrade::Bool=false)::Bool
    pkg_version = getPackageVersion(sim)

    #! Ahead of `getDBPackageVersion`, which is not a pure read: on a database with no version
    #! table it creates one and stamps `pkg_version`. Were the check to follow it, the
    #! mis-stamping this guard exists to prevent would already have happened.
    loaded_version = loadedPackageVersion(sim)
    if !isnothing(loaded_version) && loaded_version != pkg_version
        name = packageName(sim)
        println("""
        $(name) $(pkg_version) is installed in this environment but $(loaded_version) is loaded
        in this session — the environment was updated after the package was loaded.

        Restart Julia and re-run initialization before opening this project.

        Migrating the database now would record it as $(pkg_version) without applying
        $(pkg_version)'s schema changes, and those changes would then be skipped in every
        future session.
        """)
        return false
    end

    db_version  = getDBPackageVersion(sim, db)

    if pkg_version < db_version
        name = packageName(sim)
        println("""
        The $(name) version is $(pkg_version) but the database version is $(db_version).
        Upgrade your $(name) version to $(db_version) or higher before opening this project.
        """)
        return false
    end

    pkg_version == db_version && return true

    return upgradePackage(sim, db, db_version, pkg_version, auto_upgrade)
end
