using Pkg, SQLite

"""
    getInstalledVersion(sim::AbstractSimulator)::VersionNumber

Return the version of `sim`'s package as installed in the active environment — what
`Pkg.status` prints, and what `Pkg.update` changes.

Not necessarily the version running: migrations target the version loaded in this session, and
the two differ when the environment changes while a session is open.

The package is identified by the module defining `typeof(sim)`, and looked up by its UUID. If
that package is the active project (i.e. running tests from within it), `Pkg.project().version`
is returned directly; otherwise it is read from the environment's dependencies.

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
    #! Keyed on the UUID rather than the name, which is what makes this exact: two loaded packages
    #! can share a name, and a name scan would take whichever match it reached first.
    #! Two contexts, and neither covers the other: running from the package's own project it is
    #! not among its own dependencies but is `Pkg.project()`; under `Pkg.test()` the temp
    #! environment has no project name at all and the package appears as a dependency.
    proj = Pkg.project()
    proj.uuid == uuid && return proj.version
    deps = Pkg.dependencies()
    haskey(deps, uuid) || throw(ArgumentError(
        "$(nameof(mod)) ($(uuid)) is not installed in the active environment."
    ))
    return deps[uuid].version
end

#! The package whose version the database tracks: the one defining the simulator type. That is not
#! a choice a backend gets to make — `upgradeMilestones` and `upgradeToMilestone` dispatch on the
#! simulator type, so the code owning the schema is the code defining that type, and its version is
#! the schema version. Taking the module directly, rather than looking a name up in
#! `Base.loaded_modules`, means no name can be ambiguous and no Base registry internals are needed.
#! `moduleroot` so that a type defined in a submodule reports its package.
#! Overridable in principle but not part of the interface: the test suite points its stub simulator
#! at ModelManager, which is the only reason it is a function rather than inlined.
_packageModule(sim::AbstractSimulator) = Base.moduleroot(parentmodule(typeof(sim)))

#! `nothing` when the defining module belongs to no versioned package — a simulator written in a
#! script or at the REPL. Read from the loaded module, never from the environment: substituting the
#! installed version for the running one is the conflation this machinery exists to avoid.
_loadedPackageVersion(sim::AbstractSimulator) = pkgversion(_packageModule(sim))

########################################################
############      Version diagnostics       ############
########################################################

#! Three versions are in play throughout this file, and every name below uses them consistently:
#!   installed  — recorded in the active environment's manifest (`getInstalledVersion`)
#!   loaded     — running in this session (`_loadedPackageVersion`); the migration target
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
