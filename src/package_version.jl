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

#! Getting from a package *name* to its loaded module needs the module registry, because
#! `packageName` yields a string. `Base.loaded_modules` is semi-internal Base API — a
#! `Dict{PkgId,Module}` — and is the only route available. Used by the `loadedPackageVersion`
#! default to resolve a simulator that is not itself defined in a versioned package.
function _loadedModuleNamed(name::AbstractString)
    for (pkgid, mod) in Base.loaded_modules
        pkgid.name == name && return mod
    end
    return nothing
end

########################################################
############      Version diagnostics       ############
########################################################

#! Three versions are in play throughout this file, and every name below uses them consistently:
#!   installed  — recorded in the active environment's manifest (`getInstalledVersion`)
#!   loaded     — running in this session (`loadedPackageVersion`); the migration target
#!   db_version — recorded in the project database (`getDBPackageVersion`)
#! Messages are emitted here rather than at their call sites so the level and the phrasing cannot
#! drift apart, as they did when these were `println`s spread across two files.
#! Every case below is caused by changing versions with `Pkg` mid-session, so each says so —
#! without it the user has no way to connect the message to what they did.
#! `continueMilestoneUpgrade` is the deliberate exception: a `readline` follows it, and a prompt
#! cannot go through a logger.

#! `maxlog=1`: the loaded version is fixed at load time, so this cannot change within a session.
#! Says nothing about which of the two is newer, because the caller only establishes that they
#! differ — a mid-session `Pkg` change can move the environment in either direction.
_warnLoadedDiffersFromInstalled(name, installed, loaded) = @warn """
    $(name) $(installed) is installed but $(loaded) is loaded here, because the environment
    changed with Pkg after the package was loaded. The database will be migrated to $(loaded),
    matching the code that is running. Restart Julia to load $(installed).
    """ maxlog=1

_warnLoadedBehindDatabase(name, loaded, installed, db_version) = @warn """
    The database is at $(db_version) but only $(name) $(loaded) is loaded here, because the
    environment changed with Pkg after the package was loaded. Restart Julia to load
    $(installed) before opening this project.
    """

_errorInstalledBehindDatabase(name, installed, db_version) = @error """
    The database is at $(db_version) but $(name) $(installed) is installed. Upgrade $(name) to
    $(db_version) or higher before opening this project.
    """

_warnUnversionedSimulator(sim_type, name) = @warn """
    $(sim_type) is not defined in a versioned package, and no loaded package named $(name) was
    found, so the schema version cannot be determined. Opening the project without migrating it
    and without recording a version. If this database was created by a versioned build, its schema
    may not match the code now running — define loadedPackageVersion(::$(sim_type)) to restore
    version tracking.
    """ maxlog=1

_errorTargetBeyondLoaded(name, target, loaded) = @error """
    Cannot migrate the database to $(target): $(name) $(loaded) is loaded here. The schema
    milestones come from the loaded code, so $(target)'s are unavailable to apply. Restart
    Julia with $(target) loaded, then migrate.
    """

"""
    getDBPackageVersion(sim::AbstractSimulator, db::SQLite.DB)::VersionNumber

Return the package version recorded in `db` under [`dbVersionTableName`](@ref)`(sim)`.

If the table does not exist it is created and stamped with the version this session is
running, which is the version whose code builds the schema. Throws if that version cannot be
determined, since there is then nothing to record.

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
    #! The loaded version, since that is the code building this database's schema.
    version = loadedPackageVersion(sim)
    isnothing(version) && throw(ArgumentError(
        "Cannot record a version for $(nameof(typeof(sim))): it is not defined in a versioned " *
        "package and no loaded package named $(packageName(sim)) was found. Define " *
        "loadedPackageVersion(::$(nameof(typeof(sim)))) to record one."
    ))
    DBInterface.execute(db, "CREATE TABLE $(table) (version TEXT PRIMARY KEY);")
    DBInterface.execute(db, "INSERT INTO $(table) (version) VALUES ('$(version)');")
    return version
end

"""
    resolvePackageVersion(sim::AbstractSimulator, db::SQLite.DB; auto_upgrade::Bool=false)::Bool

Compare the version recorded in `db` with [`loadedPackageVersion`](@ref) and upgrade to it if
needed. Returns `true` when the database is ready to use, `false` when it is not.

Migrations target the loaded version because [`upgradeMilestones`](@ref) comes from the loaded
code. When it cannot be determined at all, the project opens unmigrated and untracked, with a
warning — there is no way to tell which milestones belong to the running code.

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
    name   = packageName(sim)
    loaded = loadedPackageVersion(sim)

    #! No loaded version means there is nothing to migrate *with*: which milestones belong to the
    #! running code is unknowable. Open the project anyway rather than blocking, so a simulator
    #! prototyped in a script still works — it simply gets no version tracking. Returning before
    #! `getDBPackageVersion` also keeps it from stamping a version table it cannot fill.
    if isnothing(loaded)
        _warnUnversionedSimulator(nameof(typeof(sim)), name)
        return true
    end

    installed = getInstalledVersion(sim)
    loaded != installed && _warnLoadedDiffersFromInstalled(name, installed, loaded)

    db_version = getDBPackageVersion(sim, db)

    if loaded < db_version
        #! Which remedy applies turns on whether restarting would help: a session running older
        #! code than the environment holds already has a new enough package installed, so telling
        #! it to upgrade would send the user in circles.
        if loaded < installed
            _warnLoadedBehindDatabase(name, loaded, installed, db_version)
        else
            _errorInstalledBehindDatabase(name, installed, db_version)
        end
        return false
    end

    loaded == db_version && return true

    return upgradePackage(sim, db, db_version, loaded, auto_upgrade)
end
