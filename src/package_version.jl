using Pkg, SQLite

"""
    getInstalledVersion(sim::AbstractSimulator)::VersionNumber

Return the version of `sim`'s package as installed in the active environment — what
`Pkg.status` prints, and what `Pkg.update` changes.

Not necessarily the version running: migrations target the version loaded in this session, and
the two differ when the environment changes while a session is open.

The package is the one defining `typeof(sim)`.

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
    mod  = _packageModule(sim)
    uuid = Base.PkgId(mod).uuid
    #! `Main`, `Base` and `Core` are the only loaded modules without a UUID, so this is the
    #! simulator-defined-at-the-REPL case: there is no package to ask about.
    isnothing(uuid) && throw(ArgumentError(
        "$(nameof(typeof(sim))) is not defined in a package, so it has no installed version. " *
        "Define it inside the package whose schema the database tracks."
    ))
    #! Keyed on the UUID, not the name: two loaded packages can share a name.
    #! Two contexts, and neither covers the other: from the package's own project it is `Pkg.project()`
    #! and absent from its own dependencies; under `Pkg.test()` it is a dependency of a temp
    #! environment whose own uuid is `nothing`.
    proj = Pkg.project()
    proj.uuid == uuid && return proj.version
    deps = Pkg.dependencies()
    haskey(deps, uuid) || throw(ArgumentError(
        "$(nameof(mod)) ($(uuid)) is not installed in the active environment."
    ))
    return deps[uuid].version
end

#! Not a choice a backend gets to make: `upgradeMilestones` and `upgradeToMilestone` dispatch on the
#! simulator type, so the code owning the schema is the code defining that type. `moduleroot` so a
#! type in a submodule reports its package. A function rather than inlined only so the test suite can
#! point its stub simulator at ModelManager.
_packageModule(sim::AbstractSimulator) = Base.moduleroot(parentmodule(typeof(sim)))

#! `nothing` when that module belongs to no versioned package — a simulator written in a script or
#! at the REPL. Deliberately no fallback to the installed version.
_loadedPackageVersion(sim::AbstractSimulator) = pkgversion(_packageModule(sim))

########################################################
############      Version diagnostics       ############
########################################################

#! Three versions are in play throughout this file, and every name below uses them consistently:
#!   installed  — recorded in the active environment's manifest (`getInstalledVersion`)
#!   loaded     — running in this session (`_loadedPackageVersion`); the migration target
#!   db_version — recorded in the project database (`getDBPackageVersion`)
#! Emitted here rather than at the call sites so the level and the phrasing stay consistent.
#! Where a mid-session `Pkg` change is the cause, the message says so — otherwise the user has no
#! way to connect it to what they did.
#! `continueMilestoneUpgrade` is the deliberate exception: a `readline` follows it, and a prompt
#! cannot go through a logger.

#! `maxlog=1`: the loaded version is fixed at load time, so this cannot change within a session.
#! Says nothing about which of the two is newer, because the caller only establishes that they
#! differ — a mid-session `Pkg` change can move the environment in either direction.
_warnLoadedDiffersFromInstalled(name, installed, loaded) = @warn """
    $(name) $(installed) is installed but $(loaded) is loaded here, because the environment
    changed with Pkg after the package was loaded. Migrations target $(loaded), matching the code
    that is running. Restart Julia to load $(installed).
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

_warnUnversionedSimulator(sim_type) = @warn """
    $(sim_type) is not defined in a versioned package, so the schema version cannot be determined.
    Opening the project without migrating it and without recording a version. If this database was
    created by a versioned build, its schema may not match the code now running. Defining
    $(sim_type) inside the package whose schema the database tracks restores version tracking.
    """ maxlog=1

_errorTargetBeyondLoaded(name, target, loaded) = @error """
    Cannot migrate the database to $(target): $(name) $(loaded) is loaded here. The schema
    milestones come from the loaded code, so $(target)'s are unavailable to apply. Restart
    Julia with $(target) loaded, then migrate.
    """

"""
    getDBPackageVersion(sim::AbstractSimulator, db::SQLite.DB)::VersionNumber

Return the package version recorded in `db` under [`dbVersionTableName`](@ref)`(sim)`.

If the table does not exist it is created and stamped with the version this session is running.
Throws if that version cannot be determined.

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
    version = _loadedPackageVersion(sim)
    isnothing(version) && throw(ArgumentError(
        "Cannot record a version for $(nameof(typeof(sim))): it is not defined in a versioned " *
        "package, so there is no version to record. Define it inside the package whose schema " *
        "the database tracks."
    ))
    DBInterface.execute(db, "CREATE TABLE $(table) (version TEXT PRIMARY KEY);")
    DBInterface.execute(db, "INSERT INTO $(table) (version) VALUES ('$(version)');")
    return version
end

"""
    resolvePackageVersion(sim::AbstractSimulator, db::SQLite.DB; auto_upgrade::Bool=false)::Bool

Compare the version recorded in `db` with the version loaded in this session and upgrade to it
if needed. Returns `true` when the database is ready to use, `false` when it is not.

When no loaded version can be determined, the project opens unmigrated and untracked, with a
warning.

# Arguments
- `sim::AbstractSimulator`: the active simulator backend.
- `db::SQLite.DB`: the project database.

# Keywords
- `auto_upgrade::Bool=false`: apply migrations without prompting.

# Returns
`true` if the database is at the loaded version, already or after a successful migration, and
also when no loaded version can be determined; `false` if the database is ahead of the loaded
version, or a migration failed.

# Example
```julia
ModelManager.resolvePackageVersion(simulator(), centralDB(); auto_upgrade=true)
```
"""
function resolvePackageVersion(sim::AbstractSimulator, db::SQLite.DB;
                               auto_upgrade::Bool=false)::Bool
    name   = nameof(_packageModule(sim))
    loaded = _loadedPackageVersion(sim)

    #! No loaded version means there is nothing to migrate *with*: which milestones belong to the
    #! running code is unknowable. Open the project anyway rather than blocking, so a simulator
    #! prototyped in a script still works — it simply gets no version tracking. Returning before
    #! `getDBPackageVersion` also keeps it from stamping a version table it cannot fill.
    if isnothing(loaded)
        _warnUnversionedSimulator(nameof(typeof(sim)))
        return true
    end

    installed = getInstalledVersion(sim)
    loaded != installed && _warnLoadedDiffersFromInstalled(name, installed, loaded)

    db_version = getDBPackageVersion(sim, db)

    if loaded < db_version
        #! A session behind the environment must restart before anything else; telling it to
        #! upgrade would send the user in circles. Restarting may not be sufficient — `installed`
        #! can also be below `db_version` — in which case the next session reports that instead.
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
