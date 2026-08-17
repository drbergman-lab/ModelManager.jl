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
to the running package version:

- versions match → nothing to do;
- the database is older → [`upgradePackage`](@ref) runs the migration chain;
- with `auto_upgrade=false` (the default), the backend may prompt before applying large or
  destructive changes.

## Updating the package mid-session

Migrations are driven by the version of the backend **loaded into the running Julia session**,
not by whatever is installed in the environment. The two come apart if you update the
environment — `Pkg.update()`, `Pkg.add`, editing a `develop`ed package's `version` — while a
session is already running: the session keeps executing the code it loaded at startup, but the
environment now advertises the new version.

Opening or migrating a project in that state is refused, with a message naming both versions.
**Restart Julia and initialize again.** `Revise` does not help here; it revises method bodies,
not the version a session recorded when it loaded the package.

Refusing is the conservative choice because the alternative is worse than a delayed upgrade.
The list of schema milestones comes from the loaded code, so it cannot describe a release that
code predates. Migrating anyway would find no work to do, record the database as being at the
new version, and thereby mark that release's schema changes as applied — after which the
version comparison above matches, and the changes are skipped for the life of the database.

The refusal covers both entry points: [`resolvePackageVersion`](@ref), which every
[`initializeModelManager`](@ref) passes through, and [`upgradePackage`](@ref) when called
directly. A backend reports its loaded version through
[`loadedPackageVersion`](@ref), which is also the hook to override in the rare layout where
the default cannot determine it.

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
