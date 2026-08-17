```@meta
CurrentModule = ModelManager
```

# [Database upgrades](@id database_upgrades)

As a simulator package evolves, its database schema may need to change. ModelManager provides
a generic, milestone-based migration framework so a project database created by an older
version of a backend can be brought up to date safely. This page explains the mechanism;
backend authors implement the hooks described in
[Building a Simulator Backend](@ref building_a_simulator).

## When migrations run

Every project database records the package version it was last migrated to, in a version
table named by the backend ([`dbVersionTableName`](@ref)). During
[`initializeModelManager`](@ref), [`resolvePackageVersion`](@ref) compares that stored version
to the version of the backend **loaded into the running session**
([`loadedPackageVersion`](@ref)):

- versions match → nothing to do;
- the database is older → [`upgradePackage`](@ref) runs the migration chain;
- the database is newer → initialization stops, since the running code is behind the schema;
- with `auto_upgrade=false` (the default), the backend may prompt before applying large or
  destructive changes.

## Why the loaded version, and not the installed one

The loaded version is the one whose code is executing. Since
[`upgradeMilestones`](@ref) *is* that code, it can only describe schema changes belonging to
the release the session is running — so that release is the furthest a session can correctly
migrate a database to. Targeting it keeps the version a database records and the migrations
actually applied to it in step, by construction.

This matters when the environment changes underneath a running session — `Pkg.update()`,
`Pkg.add`, or editing a `develop`ed package's `version`. From then on the manifest advertises
one version while the session runs another. ModelManager warns, then migrates the database to
the version it is running, which is the schema that session's code expects. **Restart Julia**
to load the newer version; the next session migrates the rest of the way on its own. `Revise`
does not help, as it revises method bodies rather than the version a session recorded when it
loaded the package.

A migration target beyond the loaded version is refused outright. Nothing in
[`initializeModelManager`](@ref) asks for one, but [`upgradePackage`](@ref) is callable
directly, and there the target is whatever the caller passed.

## The milestone chain

Not every release changes the schema. A backend declares the versions that do via
[`upgradeMilestones`](@ref) — a sorted list of [`VersionNumber`](https://docs.julialang.org/en/v1/base/base/#Base.VersionNumber)s.
[`upgradePackage`](@ref) walks the milestones between the database's current version and the
target version and, for each one, calls the backend's
[`upgradeToMilestone`](@ref)`(sim, version, auto_upgrade)`.

Each `upgradeToMilestone` implementation is responsible for:

1. prompting the user (when `auto_upgrade` is `false`) before any large or destructive change;
2. making the necessary `DDL`/`DML` changes to the database;
3. **not** updating the version table — [`upgradePackage`](@ref) records the new version after
   a successful return.

Returning `false` aborts the chain, leaving the database at the last successfully applied
milestone.

!!! warning "Declare a milestone before the release ships"
    A milestone must be in [`upgradeMilestones`](@ref) by the time the release containing its
    schema change is published. Once a database records a version, the chain is only ever walked
    *forward* from there — a milestone added below a version some database has already reached
    will never be applied to that database, and nothing detects it, because the recorded version
    already satisfies the comparison above.

    If a schema change ships without its milestone, the recovery is a new milestone at a *later*
    version that brings the schema up to date idempotently, rather than backdating the one that
    was missed.

## Helpers for writing migrations

ModelManager provides utilities migrations commonly need:

- [`populateTableOnFeatureSubset`](@ref) — copy rows from a source table into a target table
  whose columns are a subset (with optional column renaming via a mapping). Useful when a
  schema change splits or narrows a table.
- [`continueMilestoneUpgrade`](@ref) — the standard prompt/continue helper for gating a
  milestone behind user confirmation when `auto_upgrade` is `false`.

## For users

You normally do not call any of this directly. When you open a project with a newer backend,
initialization detects the older schema and offers to upgrade. Pass `auto_upgrade=true` to
your backend's initialization entry point to apply migrations without prompting — appropriate
for scripts and CI, but make sure you have a backup of important project data first, since
some migrations are irreversible.

See the [Schema migrations](@ref) and [Package version](@ref) API references for the full set
of functions.
