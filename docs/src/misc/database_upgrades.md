```@meta
CurrentModule = ModelManager
```

# Database upgrades

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
