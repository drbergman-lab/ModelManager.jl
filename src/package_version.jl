using Pkg, SQLite

"""
    getInstalledVersion(sim::AbstractSimulator)::VersionNumber

Return the version of `sim`'s package as installed in the active environment — what
`Pkg.status` prints, and what `Pkg.update` changes.

Not necessarily the version running: see [`loadedPackageVersion`](@ref), which is what
migrations target.

If the active project IS that package (i.e. running tests from within the package itself),
`Pkg.project().version` is returned directly; otherwise the dependency list is searched by
[`packageName`](@ref).

# Arguments
- `sim::AbstractSimulator`: the active simulator backend.

# Returns
The installed `VersionNumber`.

# Example
```julia
ModelManager.getInstalledVersion(simulator())
```
"""
function getInstalledVersion(sim::AbstractSimulator)::VersionNumber
    name = packageName(sim)
    proj = Pkg.project()
    if proj.name == name
        return proj.version
    end
    deps = Pkg.dependencies()
    uuid = findfirst(dep -> dep.name == name, deps)
    #! Reachable via the default `packageName`, which names the package defining the simulator
    #! type — `Main` for a type defined at the REPL. Point at the override rather than leaving
    #! the user with a bare lookup failure.
    isnothing(uuid) && throw(ArgumentError(
        "$(name) is not an installed dependency. If $(nameof(typeof(sim))) is not defined in " *
        "the package whose version the database tracks, define packageName(::$(nameof(typeof(sim))))."
    ))
    return deps[uuid].version
end

#! `upgradeMilestones` dispatches on the loaded module, so the loaded version is the furthest
#! point whose schema changes are knowable here. `nothing` means it cannot be determined.
function _migrationTargetVersion(sim::AbstractSimulator)::VersionNumber
    loaded = loadedPackageVersion(sim)
    return isnothing(loaded) ? getInstalledVersion(sim) : loaded
end

########################################################
############      Version diagnostics       ############
########################################################

#! Every version-resolution message is emitted here rather than at its call site, so the level
#! and the phrasing cannot drift apart as they did when these were `println`s spread across
#! `resolvePackageVersion` and `upgradePackage`. `continueMilestoneUpgrade` is the deliberate
#! exception: a `readline` follows it, and a prompt cannot go through a logger.
#! Every case below is caused by changing versions with `Pkg` mid-session, so each says so —
#! without it the user has no way to connect the message to what they did.

#! `maxlog=1`: the loaded version is fixed at load time, so this cannot change within a session.
_warnLoadedBehindInstalled(name, installed, loaded) = @warn """
    $(name) $(installed) is installed but $(loaded) is loaded here, because the environment
    changed with Pkg after the package was loaded. The database will be migrated to $(loaded),
    matching the code that is running. Restart Julia to load $(installed).
    """ maxlog=1

_warnSessionBehindDatabase(name, loaded, installed, db_version) = @warn """
    The database is at $(db_version) but only $(name) $(loaded) is loaded here, because the
    environment changed with Pkg after the package was loaded. Restart Julia to load
    $(installed) before opening this project.
    """

_errorDatabaseAheadOfPackage(name, installed, db_version) = @error """
    The database is at $(db_version) but $(name) $(installed) is installed. Upgrade $(name) to
    $(db_version) or higher before opening this project.
    """

_errorTargetBeyondLoaded(name, to_version, loaded) = @error """
    Cannot migrate the database to $(to_version): $(name) $(loaded) is loaded here. The schema
    milestones come from the loaded code, so $(to_version)'s are unavailable to apply. Restart
    Julia with $(to_version) loaded, then migrate.
    """

"""
    getDBPackageVersion(sim::AbstractSimulator, db::SQLite.DB)::VersionNumber

Return the package version recorded in `db` under [`dbVersionTableName`](@ref)`(sim)`.

If the table does not exist it is created and stamped with the version this session is
running, which is the version whose code builds the schema.

# Arguments
- `sim::AbstractSimulator`: the active simulator backend.
- `db::SQLite.DB`: the project database.

# Returns
The recorded `VersionNumber`.

# Example
```julia
ModelManager.getDBPackageVersion(simulator(), centralDB())
```
"""
function getDBPackageVersion(sim::AbstractSimulator, db::SQLite.DB)::VersionNumber
    table = dbVersionTableName(sim)
    if tableExists(table; db=db)
        return queryToDataFrame("SELECT * FROM $(table);"; db=db) |> x -> VersionNumber(x.version[1])
    end
    version = _migrationTargetVersion(sim)
    DBInterface.execute(db, "CREATE TABLE $(table) (version TEXT PRIMARY KEY);")
    DBInterface.execute(db, "INSERT INTO $(table) (version) VALUES ('$(version)');")
    return version
end

"""
    resolvePackageVersion(sim::AbstractSimulator, db::SQLite.DB; auto_upgrade::Bool=false)::Bool

Compare the version recorded in `db` with [`loadedPackageVersion`](@ref) and upgrade to it if
needed. Returns `true` when the database is ready to use, `false` when it is not.

Migrations target the loaded version because [`upgradeMilestones`](@ref) comes from the loaded
code. When the loaded version cannot be determined, [`getInstalledVersion`](@ref) is used.

# Arguments
- `sim::AbstractSimulator`: the active simulator backend.
- `db::SQLite.DB`: the project database.

# Keywords
- `auto_upgrade::Bool=false`: apply migrations without prompting.

# Returns
`true` if the database is at the target version (already, or after a successful migration);
`false` if the database is ahead of the loaded version, or a migration failed.

# Example
```julia
ModelManager.resolvePackageVersion(simulator(), centralDB(); auto_upgrade=true)
```
"""
function resolvePackageVersion(sim::AbstractSimulator, db::SQLite.DB;
                               auto_upgrade::Bool=false)::Bool
    name      = packageName(sim)
    installed = getInstalledVersion(sim)
    target    = _migrationTargetVersion(sim)

    target != installed && _warnLoadedBehindInstalled(name, installed, target)

    db_version = getDBPackageVersion(sim, db)

    if target < db_version
        #! Two remedies, and the wrong one sends the user in circles: a session lagging the
        #! environment already has a new enough package, so restarting is the fix, not upgrading.
        if target < installed
            _warnSessionBehindDatabase(name, target, installed, db_version)
        else
            _errorDatabaseAheadOfPackage(name, installed, db_version)
        end
        return false
    end

    target == db_version && return true

    return upgradePackage(sim, db, db_version, target, auto_upgrade)
end
