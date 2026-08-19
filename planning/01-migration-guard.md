# Design Brief: Guard against a mid-session package update silently skipping a database migration

> **✅ SHIPPED — merged as PR #30: "Refuse to migrate when the loaded package version differs from the installed one".** Kept for the record; the design rationale below
> explains what is now in `main`. No further work required.

> **Order:** 1 of 8 — do this first, unconditionally. It is the only queued item that is silent
> data-integrity corruption, and it is independent of every other brief.

> **⚠ Line-number anchors were verified at commit `403530e`, before PRs #30 (migration guard),
> #31 (accessor gaps) and #32 (calibration `Sampling` views + tagging) merged.** Those PRs added ~237 lines to
> `src/tags.jl`, ~370 to `src/calibration/calibration.jl`, and touched `src/classes.jl`, `src/sensitivity.jl`,
> `src/ModelManager.jl`, `src/database.jl` and `src/calibration/abc.jl`. Every **symbol** named below still
> exists; some **line numbers have shifted**. Locate each anchor by symbol name (`rg 'functionName' src/`) and
> re-verify before relying on it. `src/runner.jl` is unaffected.

## Preflight

1. Read `CLAUDE.md` — the mandatory design-brief-first workflow, `camelCase` functions / `snake_case`
   kwargs, the rule that docstrings may `@ref` **only** exported or `@compat public` bindings, and the
   Definition of Done.
2. Read `docs/src/misc/database_upgrades.md` and the "Feature: Schema Migrations" entry in `PRD.md`.
3. Per CLAUDE.md step 2: update `PRD.md` for the behavior change and open a new dated entry in
   `progress.md` to log decisions as you go.
4. `git branch feature/migration-guard`, then tell the user to `git checkout feature/migration-guard`
   before you write code.
5. All paths below are repo-relative. Work only inside your worktree.

## Motivation

Updating the simulator package mid-session does more than defer the database upgrade to the next session.
On the next `initializeModelManager`, `upgradePackage` filters milestones from the **stale loaded module**
and then stamps the version table to the **new on-disk version** anyway (`src/up.jl:85-87`), so the new
release's migration is skipped **permanently and silently** in every future session.

## Scope

- **Files affected:** `src/abstract_simulator.jl` (new hook + `@compat public`), `src/package_version.jl`
  (guard in `resolvePackageVersion`), `src/up.jl` (guard at the top of `upgradePackage`), `src/globals.jl`
  (initialization-abort helper), `docs/src/man/building_a_simulator.md`, `CLAUDE.md` §"Known Trade-offs",
  `PRD.md` §"Feature: Schema Migrations", `README.md`, `test/runtests.jl`.
- **New files:** none.
- **Breaking changes:** No new *required* interface method — the hook ships with a working default, so no
  backend changes anything. **No schema change; no `src/up.jl` migration milestone.** One behavior change:
  `initializeModelManager` now returns `false` (with an explanatory message) where it previously returned
  `true` and corrupted the version stamp.

## Does this belong in ModelManager or PCMM? — **ModelManager**

The ownership split at `src/abstract_simulator.jl:177-229` gives the backend *what* the milestones are:
`packageName` (`:188`), `dbVersionTableName` (`:199`), `upgradeMilestones` (`:210`), `upgradeToMilestone`
(`:227`). ModelManager owns *when* to migrate and *what the database claims*: the version comparison in
`resolvePackageVersion` (`src/package_version.jl:58`), the milestone filter (`src/up.jl:75`), and every
write to the version table (`src/up.jl:83`, `:86`). The bug is entirely in that second half —
`getPackageVersion` (`src/package_version.jl:12`) reads the on-disk environment while `upgradeMilestones`
dispatches on the loaded module, and **nothing reconciles the two** (`pkgversion(::Module)` does not
appear in `src/` at all). PCMM cannot fix it: it has no hook to declare "I am actually loaded at version
X", and even with one, the `pending` filter and the final stamp are ModelManager's code.

## Proposed Architecture

### The two failure modes, separated

**(a) Benign — what the user reported.** After `Pkg.update()`, the database is not upgraded until the
session restarts. This is arguably *correct*: the new code is not loaded, so migrating the schema to match
code that is not running would break the running session. Nothing to fix behaviorally — only to
communicate.

**(b) Serious — the headline.** (a) is benign only if nothing calls `initializeModelManager` again. When it
does — opening a second project, or re-running an init cell, a supported and tested flow
(`test/runtests.jl:2131-2136`):

1. `getPackageVersion(sim)` (`src/package_version.jl:12`) returns the **new** version from the manifest.
2. `getDBPackageVersion` (`:35`) returns the **old** version from the version table.
3. `resolvePackageVersion` falls through `:63-70` and `:72` to `upgradePackage(sim, db, old, new, auto_upgrade)`.
4. `upgradeMilestones(sim)` (`src/up.jl:73`) dispatches on the **stale loaded module**, which lacks the new
   release's milestone, so `pending` (`:75`) omits it and the loop at `:78-84` does nothing.
5. `:85-87` fires — `success && (isempty(pending) || to_version > last(pending))` — and stamps
   `version='<new>'`. **The database now claims the new version with its migration never applied.**
6. Every future session: `pkg_version == db_version` short-circuits at `src/package_version.jl:72`. The
   migration is skipped forever, silently.

The same corruption occurs **without any re-init** in one common case: create a *new* project directory
after the update, in the same session. `getDBPackageVersion` on a fresh database stamps
`getPackageVersion(sim)` — the new version — into a database whose schema `createSchema` then builds from
the *old* loaded code (`src/package_version.jl:41-44`, then `src/database.jl:91`).

### Mechanism — three parts, all in ModelManager

**1. A hook for the loaded version.** In `src/abstract_simulator.jl`, in the "Database upgrade interface"
section after `packageName` (`:190`):

```julia
loadedPackageVersion(sim::AbstractSimulator)::Union{Nothing,VersionNumber} =
    pkgversion(parentmodule(typeof(sim)))
```

A *working default*, in the style of `getInputFolderDescription` (`:297`) rather than the `error(...)`
stubs at `:188`/`:199`, so every existing backend keeps working untouched. `Base.pkgversion(::Module)`
exists since Julia 1.9, inside the declared `julia = "1.10"` floor. `parentmodule(typeof(sim))` resolves
to `PhysiCellModelManager` for `PhysiCellSimulator`.

**The `Nothing` in the return type is load-bearing.** `pkgversion` returns `nothing` for a module not
imported from a versioned package — exactly the case for `TestSimulator`, defined in `Main`
(`test/runtests.jl:26-29`) while declaring `packageName = "ModelManager"` (`:54`). The guard must treat
`nothing` as "cannot tell — do not block", or the entire test suite fails to initialize.

Append `loadedPackageVersion` to the `@compat public` block at `:326-331` with a `#!` note that it is the
documented backend contract for an unusual module layout (a type defined in a submodule or a package
extension).

**2. Refuse in `resolvePackageVersion`** (`src/package_version.jl:58`), before any comparison:

```julia
loaded = loadedPackageVersion(sim)
pkg_version = getPackageVersion(sim)
if !isnothing(loaded) && loaded != pkg_version
    println("""…"""); return false
end
```

**Refusal (`return false`), not a warning, not a throw.** A warning is insufficient — the whole point is
that continuing writes a wrong version stamp. A throw would be inconsistent: `initializeModelManager` is
documented to return `false` rather than throw (`src/globals.jl:191-193`), and the sibling "database is
newer than the package" branch already prints and returns `false` (`src/package_version.jl:63-70`).
Returning `false` reuses the existing clean-abort path with no new plumbing and no half-initialized state.

The message must name both versions and prescribe the action. Note it follows the doc rule below —
it states the consequence, not this repo's history:

> `PhysiCellModelManager 1.4.0 is installed in this environment but 1.3.2 is loaded in this session — the
> environment was updated after the package was loaded. Restart Julia and re-run initializeModelManager
> before opening this project. Upgrading the database now would stamp it as 1.4.0 without applying 1.4.0's
> schema changes, and the migration would then be skipped in every future session.`

**What the user should do: restart Julia.** `Revise` is *not* relevant — it revises method bodies, not the
version recorded at load time, so `pkgversion` still reports the old version and the condition persists. A
`Pkg.develop`ed package whose `Project.toml` `version` is edited mid-session also trips this guard
(correctly), so the message must say "restart", not "downgrade". An automatic re-check later in the session
is the wrong fix: the code needed to run the migration still is not loaded.

**3. Guard `upgradePackage` too** (`src/up.jl:69`). It is `@compat public` (`:94`), so a user or backend can
call it directly and bypass `resolvePackageVersion`. At the top:

```julia
loaded = loadedPackageVersion(sim)
if !isnothing(loaded) && to_version > loaded
    println("…refusing to migrate to <to_version>, which is not the loaded version <loaded>…")
    return false
end
```

`>`, not `!=`: `to_version < loaded` is legitimate (resuming a partially applied chain, or an explicit
older target). Leave the stamp at `:85-87` unchanged — it is correct once the target version's code is
loaded.

**Recovery for an already-corrupted database.** This fix cannot detect a database mis-stamped in an earlier
session; nothing records which migrations actually ran. Say so plainly in the docs and give the manual path:
`UPDATE <dbVersionTableName(sim)> SET version='<last known good>'`, then re-run
`initializeModelManager(...; auto_upgrade=true)`. A `migrations_applied` audit table is the durable
long-term fix and is **out of scope** (open question below).

### Also fix the `initialized`-not-reset bug — yes, here

`initializeModelManager` (`src/globals.jl:203`) never sets `initialized = false` on entry, and none of its
three early-`false` paths (`:229-234`, `:235-240`, `:242-247`) do either. A failed re-init after a
successful one therefore leaves `isInitialized() == true` with `data_dir == ""` and a fresh in-memory
`SQLite.DB()`, so every later query silently hits an empty database. (`reinitializeDatabase` does it
correctly, `src/database.jl:31-38`.)

**Include it here**, clearly labelled as a separate concern with its own test, because this brief makes it
strictly more reachable: the new guard adds a *fourth* early-`false` path whose whole purpose is to fire on
a re-init after a previously successful init — the exact scenario where `initialized` goes stale.

Preferred shape (removes the bug class, not one instance): factor the four lines repeated at `:230-233`,
`:236-239`, `:243-246` into

```julia
function _abortInitialization()
    close(centralDB()); mm_globals().db = SQLite.DB()
    mm_globals().data_dir = ""; mm_globals().initialized = false
    return false
end
```

and additionally clear `initialized` at entry alongside the other per-project resets (`:212-219`). The new
guard path then inherits correctness for free.

### Second-order `currentSimulatorVersionID()` staleness — document, do not fix

`createSchema` re-resolves `simulator().current_version_id` on every `initializeDatabase()`
(`src/database.jl:96`), and that ID is embedded in `Simulation`/`Monad` INSERTs (`src/classes.jl:305`,
`:399`) and matched by `Sampling`'s find-or-insert (`:527`, `:552`), so a mid-session change makes
previously-created objects stop matching lookups and can mint duplicate samplings.

It does **not** apply to this brief's scenario: `resolveSimulatorVersionID` is keyed on the *simulator's
own* version tag, which tracks the simulator build (the PhysiCell version), not the manager package. It can
move when a user re-inits with a different simulator build in one session — a distinct, pre-existing,
backend-driven scenario. Add it as a CLAUDE.md §"Known Trade-offs" entry rather than fixing it here; it
interacts with the concurrency trade-off already documented there.

### Summary

- **Current:** the on-disk version drives migration decisions while the loaded module supplies the milestone
  list; a disagreement stamps the database forward without migrating it.
- **Proposed:** ModelManager asks the backend which version is actually *loaded*, refuses to initialize or
  migrate when that disagrees with the installed version, and never leaves `initialized` stale after
  refusing.
- **Key decisions:** ModelManager-side fix with an optional defaulted hook; refuse rather than warn, because
  continuing corrupts the stamp; `nothing` from the hook means "cannot tell, proceed"; guard both
  `resolvePackageVersion` and the public `upgradePackage`.

## Testing Strategy

Add a `Ref{Union{Nothing,VersionNumber}}` `_loaded_version_override` beside `_fail_sim_predicate`
(`test/runtests.jl:66-72`) plus `ModelManager.loadedPackageVersion(::TestSimulator) = _loaded_version_override[]`,
defaulting `nothing`; restore in `finally` as the file does at `:2639-2643`. New testset as a sibling of
"initializeModelManager" (`:2099-2109`), plus a unit-level block near the version hooks (`:54-57`).

- **Unit:** the **default** hook on a module-less type — define `struct _NoModuleSimulator <: AbstractSimulator end`
  at module level (necessary, because the `TestSimulator` override shadows the default) and assert
  `ModelManager.loadedPackageVersion(_NoModuleSimulator()) === nothing`; `nothing` override → guard no-ops →
  `initializeModelManager` returns `true` (the regression net for every existing test); override equal to
  `getPackageVersion(TestSimulator())` → `true`; override *below* it → returns `false` **and**
  `isInitialized() == false` **and** `dataDir() == ""` (one test covering both the guard and the
  `initialized`-reset fix).
- **Integration:** the corruption assertion — stamp the version table to an older version, set the override
  below the target, call `ModelManager.upgradePackage(sim, db, old, new, true)`, assert it returns `false`
  **and** `getDBPackageVersion` still reads `old` (i.e. `src/up.jl:86` did not fire). Positive path —
  override a second `Ref` so `upgradeMilestones` returns `[v]` and a call-count `Ref` on
  `upgradeToMilestone`, then assert the milestone ran once and the version table ends at `to_version`.
  Guard-does-not-break-re-init: keep `:2131-2136`'s re-init assertion green with the override at `nothing`.
- The `"docstrings only @ref public bindings"` testset (`:4310`) catches a missing
  `@compat public loadedPackageVersion` if `resolvePackageVersion`'s docstring `@ref`s it.
  `docs/src/lib/package_version.md` and `docs/src/lib/abstract_simulator.md` are `@autodocs`-driven and pick
  the hook up automatically; add a paragraph to `docs/src/man/building_a_simulator.md` on when to override.

## Estimated Effort

- **Lines of code:** ~70 in `src/` (hook ~15, two guards ~30, `_abortInitialization` ~10, docstrings/docs
  ~35), ~100 in tests.
- **Risk level:** **Low** in volume, but note the blast radius: `resolvePackageVersion` gates *every*
  `initializeModelManager`, so mishandling `nothing` breaks every project. Hence the emphasis on the
  `nothing` path and the default-hook unit test.
- **Dependencies:** none.

## Open questions for the user

1. **Hook name:** `loadedPackageVersion` (matches `abstract_simulator.jl`, where nothing carries a `get`
   prefix except the legacy `getInputFolderDescription`) or `getLoadedPackageVersion` (matches the call-site
   symmetry with `getPackageVersion`/`getDBPackageVersion`)? Default if unanswered: `loadedPackageVersion`.
2. **A `migrations_applied` audit table?** It is the only way to *detect* a database already corrupted by
   this bug, and the only way to recover automatically. Out of scope as written — plan separately?
3. **`currentSimulatorVersionID()` staleness** — document as a Known Trade-off (recommended) or fix?

## Cross-cutting rules

**Review-only comments.** The repo uses `#!` for *permanent* design-rationale comments (316 of them). Any
comment written purely so the user can follow your reasoning during review must be marked `#REVIEW:` and
removed before merge.

**Docs are for an outside reader, not a changelog.** User-facing prose explains how to use the code as it
now is. Where a "why" is needed it must be the grand-narrative why, never this repo's history:

> ✅ "Updates are delayed until the next Julia session so as not to corrupt the currently loaded session state."
> ❌ "Updates must be delayed because updating mid-session had the potential to produce incorrect session states where upgrades would never actually proceed."

The second sentence belongs in `progress.md`.

## Pre-merge checklist

- [ ] `julia --project=. -e 'using Pkg; Pkg.test()'` green.
- [ ] `rg '#REVIEW:' src/ test/` returns nothing.
- [ ] Every new exported/`@compat public` binding has a docstring with description, arguments, return value,
      and a usage example.
- [ ] Docs written outside-in per the rule above; no repo history in `docs/`.
- [ ] `README.md` Implementation Status updated; `PRD.md` matches what shipped.
- [ ] `progress.md` entry records the decisions and anything rejected.
