# progress.md — ModelManager.jl Session Journal

> **Purpose:** Session-level decisions, rejected approaches, and open questions.
> Unlike [PRD.md](PRD.md) (specification) and [README.md](README.md) (completion status), this file captures the *reasoning* behind decisions — things that would otherwise exist only in ended chat history.

---

## Session: mid-session package update silently skipped migrations (2026-08-17)

### The bug
Two sources of truth for "what version is this?", never reconciled. `getPackageVersion`
(`src/package_version.jl:12`) reads the **on-disk environment** via `Pkg`, while
`upgradeMilestones`/`upgradeToMilestone` dispatch on the **loaded module**. `pkgversion(::Module)`
appeared nowhere in `src/`.

The benign half is what was reported: after `Pkg.update()`, the DB is not upgraded until restart.
That is arguably correct — the new code is not loaded, so migrating to match it would break the
running session.

The serious half is that the benign half only holds if nothing calls `initializeModelManager`
again. When it does (opening a second project, or re-running an init cell — a tested flow):

1. `getPackageVersion` → **new** version, from the manifest.
2. `getDBPackageVersion` → **old** version, from the version table.
3. `resolvePackageVersion` falls through to `upgradePackage(sim, db, old, new, auto_upgrade)`.
4. `upgradeMilestones(sim)` comes from the **stale loaded module**, so it lacks the new release's
   milestone; `pending` is empty and the loop body never runs.
5. `success` is therefore still at its initialized `true`, and `isempty(pending)` is `true`, so
   `src/up.jl:85-87` fires as a "no schema change" bump and stamps `version='<new>'`.
6. Every later session short-circuits on `pkg_version == db_version` (`src/package_version.jl:72`).
   The migration is skipped **permanently and silently**.

The subtlety worth remembering: `success == true` does **not** mean a migration ran. It means
nothing in `pending` failed, and an empty `pending` satisfies that trivially. Afterwards a skipped
migration and a release that genuinely needed none leave byte-identical database state.

There is a second route with **no re-init at all**: create a new project directory after the
update, in the same session. `getDBPackageVersion` is not a pure read — on a database with no
version table it creates one and stamps `getPackageVersion(sim)` (`:41-44`) — so the new version
lands in a database whose schema `createSchema` then builds from the old loaded code. This is why
the guard sits *above* the `getDBPackageVersion` call rather than merely above the comparison; the
ordering is load-bearing and has its own test (the fresh-project case asserting no version table
was written).

### Why this is a ModelManager fix, not a PCMM one
The ownership split at `src/abstract_simulator.jl` gives the backend *what* the milestones are
(`packageName`, `dbVersionTableName`, `upgradeMilestones`, `upgradeToMilestone`). ModelManager owns
*when* to migrate and *what the database claims*: the comparison in `resolvePackageVersion`, the
milestone filter, and every write to the version table. The bug is entirely in that second half.
PCMM has no hook to declare "I am actually loaded at version X", and even given one, the filter and
the stamp are ModelManager's code.

### The fix, after review reshaped it
The first implementation compared the loaded version against the installed one and **refused** to
initialize on a mismatch. Review (PR #30) replaced that with the better fix: **use the loaded
version as the migration target.**

The reasoning is that the installed version was never a legitimate target in the first place.
`upgradeMilestones` *is* the loaded code, so the loaded release is the furthest point whose schema
changes a session can actually apply. Targeting it makes the corruption **unrepresentable** rather
than detected — the recorded version and the applied migrations now come from the same source — and
it drops the refusal, so a mid-session update no longer blocks the session at all. The database is
migrated to the schema the running code expects; the next session, loading the new version, applies
the remainder. Self-healing, and verified as such (Scenario C below).

`getPackageVersion` survives only as the `nothing` fallback and as input to the warning.

**Why the refusal was worse than it looked.** For a backend whose simulator type lives in a
different package than `packageName` names, `loaded != installed` holds on *every* session, not just
after an update — so the refusal would have bricked that backend permanently rather than failing
safe. The retargeting has a real residual risk there (a wrong `loaded` number becomes a wrong stamp)
but the `@warn` names both versions on every init, and the fix is the override the hook exists for.
The earlier framing of this as "the one property the old design had" was wrong and was withdrawn.

### Decisions
- **Migrate to the loaded version; never refuse for a version mismatch.** See above.
- **`@warn`, `maxlog=1`.** The condition cannot change within a session — the loaded version is
  fixed at load time — so one notice per session is the right cardinality even across several
  projects. `maxlog=1` matches the `useHPC` already-on warning.
- **`nothing` means "cannot determine" → use the installed version.** `pkgversion` returns `nothing`
  for a module not imported from a versioned package, which is exactly `TestSimulator`, defined in
  `Main` while declaring `packageName = "ModelManager"`. Hence the unit test on a module-less type
  (`_NoModuleSimulator`), needed because the `TestSimulator` override shadows the default.
- **`getDBPackageVersion` stamps the target, not the installed version.** This is the load-bearing
  half: it stamps a database that has no version table, so it is the *only* code on the
  new-project-mid-session path. Mutation testing confirmed it — with the retargeting reverted, the
  re-init path was still caught by `upgradePackage`'s guard, but the fresh-project path corrupted.
- **`upgradePackage` keeps its own guard, refusing rather than clamping.** Unreachable from
  `resolvePackageVersion` now, so it exists for direct callers (it is `@compat public`), where
  `to_version` is whatever was passed. Clamping to the loaded version would silently migrate
  somewhere other than asked, which is the worse surprise. `>` not `!=`, since a target below the
  loaded version is legitimate (resuming a partly-applied chain).
- **Split the "database is newer" remedy.** Restart Julia when the session merely lags the
  environment; upgrade the package otherwise. Printing "upgrade your package" to someone whose
  package is already new enough sends them in circles.
- **Working default, not an `error` stub.** `loadedPackageVersion` follows
  `getInputFolderDescription`, so no existing backend has to change anything. Declared
  `@compat public` because overriding it is the documented contract for an unusual package layout.
- **Hook named `loadedPackageVersion`**, matching `abstract_simulator.jl` (nothing there carries a
  `get` prefix except the legacy `getInputFolderDescription`), over `getLoadedPackageVersion`,
  which would have matched call-site symmetry with `getPackageVersion`/`getDBPackageVersion`.
- **A submodule needs no override.** Measured, not assumed: `pkgversion` resolves through
  `Base.moduleroot`, so `pkgversion(Pkg.Types) == pkgversion(Pkg)`. The first draft's docstring
  claimed otherwise and was corrected. (`DataFrames.PrettyTables` returning its own version is not a
  counterexample — that is a re-exported separate package, which is the actual override case.)
- **No escape-hatch keyword.** An `allow_version_mismatch=true` was considered while the design
  still refused. The reshape moots it: there is nothing left to escape from.

### Rejected: do the check in `__init__`
Proposed during review — detect in `__init__` that the version increased, drop the current state,
and tell the user to restart. It cannot work, for reasons of timing rather than style:

1. `__init__` runs once, at module load, **before the discrepancy exists**. The sequence is: load at
   1.3.2 → `Pkg.update()` → user acts. Changing the manifest reloads nothing, so `__init__` never
   re-fires.
2. "Already initialized" cannot be true there: `mm_globals_ref[]` is `nothing` until a backend
   registers globals, so there is no project, no `data_dir`, and no DB to drop.
3. The version that matters is not ModelManager's but the **backend's** (`packageName(sim)`), and
   ModelManager's `__init__` does not know which backend will load. The backend's own `__init__` has
   the same t0 problem.

`resolvePackageVersion` is the earliest point in a session where both a simulator and a database
exist, so it is not a compromise location — it is the only one.

The half of the proposal that *was* right is "drop the current state", which is the
`_abortInitialization` change below. What did not survive review was "if they run it anyway, that's
on them": that reasoning holds when the cost lands on the session the user chose to break, but here
the artifact is a mis-stamped **file** that outlives the session, skips the migration forever, and
does so for anyone else sharing the project directory. The user cannot consent on the file's behalf.

### Rejected: a `migrations_applied` audit table
The only way to *detect* an already-corrupted database, since nothing records which migrations
actually ran. Dropped, deliberately, with the reasoning corrected mid-discussion:

- The argument first offered for dropping it — that the corrupted set is probably empty depending on
  release history — was **wrong**, and was withdrawn. There is no observable event "when users began
  updating mid-session". Release history bounds whether corruption was *possible*; whether any
  session actually hit load-at-A → update-to-B → re-init is unrecorded and unknowable, and the
  resulting database is byte-identical to a clean one. The set's size is not small, it is unknown.
- The honest remaining argument *for* the table is a hole the guard does not close: a milestone added
  to `upgradeMilestones` **below** a version some database has already recorded is skipped forever,
  with no mid-session update involved at all, because `pkg_version == db_version` short-circuits
  before `upgradePackage` is ever called. Shared root cause with the original bug — version equality
  is treated as proof of schema state.
- Resolution (user's call): rely on backend discipline rather than build the table, on the grounds
  that the main downstream backend is the same author's. **Revisit and build the audit table if a
  release ever ships a schema change without its milestone.** The assumption this now rests on is
  written into `docs/src/misc/database_upgrades.md` as a warning admonition, so it lives where a
  backend author reads it rather than only here.

### Also fixed: `initialized` was never reset
Separate pre-existing bug, folded in because this change makes it strictly more reachable — the new
guard is a fourth early-`false` path that fires *precisely* on a re-init after a previous success,
the exact scenario where the flag went stale.

`initializeModelManager` never set `initialized = false` on entry, and none of its early-`false`
paths did either. A failed re-init after a successful one left `isInitialized() == true` with
`data_dir == ""` and a fresh in-memory `SQLite.DB()`, so every later query silently read an empty
database. (`reinitializeDatabase` had always done it correctly.)

Fixed by factoring all four abort blocks into `_abortInitialization()` and clearing `initialized` at
entry — removing the bug class rather than one instance. Four sites, not the three originally
scoped: the `catch` around opening the database cleared `data_dir` but left `db` pointing at the
previous project's connection and `initialized` stale. Closing the previous connection there is
correct, since that project is being abandoned either way.

Verified safe to clear at entry: nothing on the path to `initializeDatabase` consults
`isInitialized()`. `createSchema` cannot depend on it, since on a *first* init the flag is already
`false` while it runs. The `assertInitialized` callers are all in query/deletion/tag code, and
`databaseDiagnostics` runs `@async` only after init succeeds — behind the `waitForDiagnostics()` at
entry.

### Not fixed: `currentSimulatorVersionID()` staleness
`createSchema` re-resolves `simulator().current_version_id` on every `initializeDatabase()`, and that
ID is embedded in `Simulation`/`Monad` INSERTs and matched by `Sampling`'s find-or-insert, so a
mid-session change makes previously-created objects stop matching lookups and can mint duplicate
samplings. It does **not** apply to this session's scenario: `resolveSimulatorVersionID` is keyed on
the simulator's own version tag, which tracks the simulator build, not the manager package. Distinct,
pre-existing, backend-driven. Left alone by explicit decision — no fix and no Known Trade-offs entry.

### Second review round (PR #30)
Mostly a verbosity pass — the docs and docstrings were over-explaining behavior the reviewer
considered self-evident once the design was right ("I get that having to fix this undermines this
argument; but now that we have the right thing in place, it is obvious this is correct"). Cut the
"why the loaded version" justification, the installed-vs-loaded table, and most of the
`loadedPackageVersion` docstring. Worth remembering as a general pull: the rationale that felt
necessary while the bug was live reads as padding once the fix is in. It lives here instead.

Substantive changes from that round:

- **`packageName` gained a default** — `string(nameof(Base.moduleroot(parentmodule(typeof(sim)))))`
  — so it is no longer a required `error` stub. Uses `moduleroot`, not a bare `parentmodule`, for
  two reasons: a type in a submodule should report its package, and it must name the *same* package
  whose version `loadedPackageVersion` reports (`pkgversion` resolves through `moduleroot` too). If
  those two disagreed, the mismatch warning would compare unrelated packages.
  This makes the "$name is not an installed dependency" error newly reachable — the default names
  `Main` for a REPL-defined type — so that message now points at overriding `packageName`.
- **Diagnostic names normalized** to one vocabulary — `installed` / `loaded` / `db_version` — after
  the reviewer could not map the function names onto the checks ("Does `target` = `Session`? Does
  `installed` = `Database`?"). The local `target` became `loaded` for the same reason.
  `_warnLoadedBehindInstalled` was also simply wrong: its caller only establishes that the two
  differ, and a mid-session `Pkg` change can move the environment in either direction, so it is now
  `_warnLoadedDiffersFromInstalled`.
- **`getPackageVersion` → `getInstalledVersion`.** Exported, so this is breaking; the old name is
  gone rather than deprecated, on the grounds that the package is pre-1.0. PCMM must be checked for
  callers.
- **All version diagnostics funnelled** into one block in `src/package_version.jl` with consistent
  levels, replacing `println`s scattered across `resolvePackageVersion` and `upgradePackage`.
  `@warn` for the two recoverable-by-restart cases, `@error` for the two unsupported ones,
  `@info` for progress. `continueMilestoneUpgrade` stays a `println` — a `readline` follows it, and
  a prompt cannot go through a logger.
- **Dropped a redundant `IF NOT EXISTS`** in `getDBPackageVersion`, which only runs in the branch
  where `tableExists` already returned false.
- **The installed-version fallback was replaced, not kept** (third review round). The reviewer's
  framing landed it: put the fallback inside `loadedPackageVersion` itself, resolving
  `packageName` and reading the version from the *loaded* module registry
  (`Base.loaded_modules`) rather than from the environment. Both routes now report a loaded
  version, so the substitution being objected to is gone rather than merely defended, and
  `_migrationTargetVersion` disappeared with it — which also answers their earlier "why do we need
  this?" about that helper. When neither route finds a version, `resolvePackageVersion` warns and
  returns `true` without migrating: nothing to migrate *with*, so the project opens untracked
  rather than being blocked. `getDBPackageVersion` throws in that state instead of inventing a
  version, and is unreachable from the init path because the short-circuit returns first.
  The test harness needed a three-way sentinel as a result — `:default` (resolve normally), a
  `VersionNumber` (staged mid-session change), and `nothing` (genuinely undeterminable) — because
  `nothing` had previously meant "inert" and now means "short-circuit".
- Earlier in the same discussion, the fallback **was** defended and kept: The reviewer twice proposed removing it ("if there is
  no loaded version, how are we even here??"). The answer is that `nothing` does not mean "not
  loaded" — `pkgversion` returns it for a module that is loaded but not *from a versioned package*,
  which is a REPL- or script-defined simulator, and `TestSimulator` in `Main`. Removing the fallback
  would refuse those. Collapsing the interface further (dropping `packageName`, deriving the name
  from `moduleroot`, requiring simulator types to live in packages) was considered and deferred: it
  is a breaking interface change needing a coordinated PCMM edit, unrelated to this bug.

### The `@ref` guard test had a blind spot, now closed
Giving `packageName` a one-line definition broke the docs build, and the existing
`"docstrings only @ref public bindings"` testset passed anyway. Two things combined:

1. A `#!` comment placed between a docstring and a **one-line** definition silently prevents the
   docstring from attaching. No error, no warning; `Docs.meta` simply has no entry.
2. The guard only asked whether an `@ref` target is *public*. `packageName` is public — it just had
   no docstring left to link to. Documenter resolves `@ref` against a rendered docstring, so a
   public-but-undocumented binding fails a build exactly as a private one does.

The testset now checks both, reporting `"not public"` and `"public but has no docstring"`
separately. Verified by re-introducing the detaching comment: it flags
`getInstalledVersion → packageName`. This is the same gap CLAUDE.md already noted for `@ref`s to
*nonexistent* names, and the fix covers that case too.

The `#!` comment on `packageName` now sits above its docstring, with a note saying why it must stay
there.

### Fourth review round: `packageName` became the authority
The reviewer asked why `packageName` did not overrule, given it already defaults to
`parentmodule(typeof(sim))`. It should, and the previous ordering was a live bug rather than a
style preference. `loadedPackageVersion` tried `pkgversion(parentmodule(typeof(sim)))` *first* and
only fell back to the named package, so a backend overriding only `packageName` got the two
versions from two different packages.

Demonstrated with a purpose-built package (type in `NestTest` v7.7.7, `packageName` returning
`"ModelManager"` v0.8.4): `loadedPackageVersion` reported **7.7.7** while `getInstalledVersion`
reported **0.8.4**. That warns spuriously on every session *and* aims the migration at a version
belonging to an unrelated package — it would have stamped the database 7.7.7. Resolving through
`packageName` gives 0.8.4 from both.

`packageName` is now the single place deciding which package is version-checked; both version
functions resolve through it, so overriding it moves them together. Overriding
`loadedPackageVersion` is now rarely needed and documented as such.

### `loadedPackageVersion` became internal
Asked what a backend would actually override it *for*, and none of the cases I had documented
survived. Enumerated:

| Scenario | Default yields | Real fix |
| --- | --- | --- |
| Named package not loaded | `nothing` | Fix `packageName` — the backend's own declaration |
| Named package has no `version` in Project.toml | `nothing` (measured) | Add one; milestones *are* versions |
| Simulator defined in a script/REPL | `nothing` | Untracked is the honest state |
| Schema version decoupled from package version | package version | Overriding *breaks* it — `getInstalledVersion` still reports the real version, so the mismatch warning fires forever |

The last row is the general argument: any override returning something other than the named
package's real loaded version breaks the installed-vs-loaded comparison everything here rests on,
so the function is not safely overridable. Renamed `_loadedPackageVersion`, dropped from
`@compat public`, and moved out of `abstract_simulator.jl` into `package_version.jl` with the rest
of the version machinery. Free to do because it had never shipped; `packageName` is now the single
interface method for redirecting which package gets version-checked.

Also fixed while checking this: a `PkgId` is `(uuid, name)`, so two loaded packages can share a
name, and `_loadedModuleNamed` was returning whichever `Dict` iteration reached first. An
ambiguous name now resolves to `nothing` — reporting an unrelated package's version is the exact
failure this machinery exists to prevent, so a guess is worse than admitting ignorance. Not
directly unit-tested: loading two same-named packages in one session is not something a test can
readily construct.

### Identity moved from a package *name* to the defining *module*
Asked whether the accepted collision hole could come from submodules or user-defined modules, and
whether the UUID would be hard. Measured first, because the premise mattered:

- **Submodules are not in `Base.loaded_modules`.** 269 entries, every one a `require`d package
  except `Main`/`Base`/`Core`. `Pkg.Types` is absent; `module UserDefined end` in `Main` is absent.
  (`"PrettyTables"` does appear, but as a separate package DataFrames depends on, not a submodule.)
  So the hole needed two distinct packages sharing a name — real, but far narrower than feared.
- The UUID turned out to be *less* code, not more, because the name search was unnecessary:
  `Base.PkgId(mod)` gives `(name, uuid)` exactly, `pkgversion(mod)` gives the loaded version with no
  registry scan, and `Pkg` can be keyed on the UUID.

I proposed a new `packageModule` hook to carry the redirect. The reviewer rejected the premise
instead: it is "a bit crazy to have the simulator defined in one package whose version is not tied
to the version of the package that runs the database." That is right, and it is provable rather than
a matter of taste — `upgradeMilestones` and `upgradeToMilestone` dispatch on the simulator type, so
the code owning the schema *is* the code defining that type. Defining those methods in some other
package would be piracy. The redirect was capability nobody should want, and the fix was to delete
the notion rather than give it a better hook.

So identity is now `_packageModule(sim) = Base.moduleroot(parentmodule(typeof(sim)))`, internal and
not configurable. Consequences:

- `_loadedModuleNamed` deleted outright, and with it the `Base.loaded_modules` dependency that had
  been flagged as a Julia-upgrade risk. The name-collision hole is gone by construction — there is
  no name to collide.
- `getInstalledVersion` had the *same* latent ambiguity (`findfirst(dep -> dep.name == name)` takes
  the first match) and is now keyed on the module's UUID. Both of its context branches are needed
  and were verified: from the package's own project it is absent from `Pkg.dependencies()` but is
  `Pkg.project()`; under `Pkg.test()` the temp environment has no project name and it appears as a
  dependency.
- `packageName` survives as a derived display name for messages. PCMM's existing method still
  agrees with the derived default, so no coordinated change is needed there.
- No public API was added. The PR started out proposing a new public hook and ends having removed
  one and added none.

Residual sharp edge, accepted: `packageName` remains overridable and purely cosmetic, so a backend
could name one package in messages while the version comes from another. Documented in its
docstring; cosmetic only.

### `packageName` removed outright
Kept briefly as a derived display name, then cut: "why keep it just for a cosmetic layer?" No good
reason. Messages now interpolate `nameof(_packageModule(sim))` directly, which has the side benefit
that the name shown *cannot* disagree with the version reported — the previous arrangement let a
backend override the name while the version came from elsewhere, which was a footgun sitting in a
docstring.

**This is a required PCMM change, not a discretionary one.** PCMM defines
`ModelManager.packageName(::PhysiCellSimulator)`, and a qualified method definition on a name the
host module no longer has is a hard failure. Verified against a fixture package carrying the same
override:

```
ERROR: LoadError: UndefVarError: `packageName` not defined in `ModelManager`
```

It surfaces at precompile time, so there is no window in which it misbehaves silently. PCMM simply
deletes the method — the default is what it was returning anyway.

Interface surface across the whole PR: **one required method removed** (`packageName`), one public
name renamed (`getPackageVersion` → `getInstalledVersion`), and none added — having opened by
proposing a new public hook.

### Released as 0.9.0, not a patch
Two exported/public names disappear here — `getPackageVersion` (renamed `getInstalledVersion`) and
`packageName` — so under 0.x semver this is a minor bump, not a patch.

The bump is also what decouples this from PCMM. PCMM implements `packageName`, and a qualified
method definition on a name the host no longer has fails at precompile. With a compat bound of
`ModelManager = "0.8"` meaning `>=0.8.0, <0.9.0`, releasing 0.9.0 keeps PCMM resolving the old
version and working untouched, so its maintainer raises the bound and deletes the method together.
Releasing this as 0.8.5 would instead break PCMM the moment it resolved.

The `v0.8.4` mentions in `src/hpc.jl` and `PRD.md` are unaffected — they name the release the
`run_on_hpc` auto-detection fix shipped in, not the current version.

### Final correctness-and-terseness pass
Reviewed the whole PR across six dimensions with adversarial verification of every candidate;
45 of 49 findings survived. Most were prose that described an earlier revision — unsurprising after
five reshapes — but four were substantive:

1. **A warning promised an outcome it could not know.** `_warnLoadedDiffersFromInstalled` said "The
   database will be migrated to <loaded>", but it fires before `db_version` is read, and the very
   next branch can refuse and return `false`. A user could be told the database would be migrated
   and then told the project could not be opened. Now states the policy ("Migrations target
   <loaded>"), which is true in every branch including the fresh-database stamp.
2. **A comment asserted an invariant its branch does not establish.** The `loaded < installed`
   branch claimed the session "already has a new enough package installed", but `installed` can also
   be below `db_version` (loaded 0.1, installed 0.5, database 0.9), in which case restarting is
   necessary but not sufficient. The comment now says so.
3. **`resolvePackageVersion` could throw where the docstring promises `false`.** Verified reachable
   with a determinable loaded version, so the unversioned short-circuit does not cover it: after
   `using SQLite; Pkg.activate(mktempdir())`, `pkgversion(SQLite)` still resolves while the
   dependency lookup fails, so `getInstalledVersion` throws. The throw escaped
   `_abortInitialization`, leaving `data_dir` set and the connection open. Worse after the reshape,
   since `installed` is now used *only* to word two diagnostics — a cosmetic lookup could kill
   initialization. Fixed on the code side rather than by narrowing the docstring (the user's call):
   the call is wrapped, reported, and routed through `_abortInitialization`, matching the
   database-open failure a few lines above. The catch also covers an unparsable version table and a
   backend milestone that throws mid-migration. `println` rather than `@error` there, to match its
   sibling; the `@warn`/`@error` split belongs to the version diagnostics.
   Pinned by a test using a stub whose loaded version resolves while its package module has no UUID
   — mutating the `try` out turns that test from pass into one error plus one failure.
4. **A vacuous assertion.** `@test _milestone_calls[] == 0` after a refused `upgradePackage` was
   staged with an *empty* milestone list, so `pending` was empty whether the guard fired or not.
   Given a milestone in range it is now evidence: mutating the guard out fails three assertions
   where it previously failed two.

Also corrected: the `#!` in the `@ref` guard testset still said the detachment trap was limited to
one-line definitions, contradicting the CLAUDE.md correction made earlier in the same PR; and
CLAUDE.md's illustration of that trap was built from `packageName`, which this PR deletes.

PRD.md had two bullets in direct contradiction — one still describing the removed
installed-version fallback, four lines above the bullet describing the short-circuit that replaced
it — plus the same claim repeated as an acceptance criterion, a `upgradePackage(sim; auto_upgrade)`
signature that never existed, and two references to the removed `loadedPackageVersion`.

### The docstring-detaching comment is not limited to one-line definitions
Same trap as last round, and this time it exposed an error in what I had written into CLAUDE.md.
I had recorded that an intervening comment detaches a docstring from a **one-line** definition;
it applies to `function ... end` equally. Measured directly:

```
fA (one-line, comment between)      documented: false
fB (function...end, comment between) documented: false
fC (one-line, no comment)            documented: true
fD (function...end, no comment)      documented: true
```

CLAUDE.md now says "every definition form". Worth noting the payoff of last round's guard change:
the strengthened testset caught this on the first run, where previously it would have passed and
left the failure to CI's docs job.

### A claim corrected mid-review
The reviewer proposed a nested-module counterexample where `parentmodule(MySim)` returns the inner
module, expecting the default to break. Measured on a purpose-built package with exactly that shape:
`parentmodule` does return the inner module, but `pkgversion` resolves through `Base.moduleroot` to
the package and reports its version, so the default is correct there. The genuine override case is
narrower — the type living in a *separate package* from the one being upgraded.

### Docs note
Nearly wrote `[Database upgrades](@ref database_upgrades)` into the `initializeModelManager`
docstring. That would have been the only manual-page anchor `@ref` in any `src/` docstring, and it
would have broken **downstream** builds: PCMM renders ModelManager's docstrings but not
ModelManager's manual pages, so the anchor is unresolvable there. The `"docstrings only @ref public
bindings"` testset would not have caught it — its regex only matches backticked binding refs. Stated
the substance inline instead.

## Session: Calibration as coalesced `Sampling` views + taggable `Calibration` (2026-08-17)

Brief 4 of 8; gate for briefs 5–8, which build on the types and tagging machinery settled here.

### Why `Calibration` is not in the containment hierarchy

This was the central call, and the reason is structural rather than stylistic. **A generation is not
one `Sampling`.** The batch loop is `while length(accepted) < population_size`
(`abc_smc.jl:615`) and *each batch* constructs its own `Sampling(monads, problem.inputs)`
(`abc.jl:165`). So containment really reads batch → generation → calibration — one level deeper
than the four levels — and those groupings **overlap**: a monad belongs to its batch's sampling,
its generation, and the whole run simultaneously. A strict chain cannot express that, because a
`Sampling`'s constituents are `Monad`s and never other `Sampling`s. It is a poset, not a total
order.

Subtyping `AbstractTrial` was rejected for a second, independent reason: `run(T::AbstractTrial)`
(`runner.jl:256`) would dispatch on a `Calibration` and call `prepareTrialHierarchy` on it, and
`AbstractTrial` carries assumptions about `inputs`, `constituentIDs`, `length` and `trialFolder`
that a calibration run does not satisfy.

The GSA precedent does not transfer directly either. `GSASampling` is not an `AbstractTrial`; it
wraps exactly *one* `sampling` field and forwards `simulationIDs` to it (`sensitivity.jl:44`). A
calibration has many samplings, so there is nothing single to wrap — **until you coalesce**.
Coalescing is precisely what makes the GSA pattern applicable, and that is the whole idea of this
change.

What makes the views legal: a `Sampling` is defined by all input folders matching
(`classes.jl:505-512`), and every calibration monad is built from one `problem.inputs`. So *any*
subset of a calibration's monads is a valid sampling — the run and each generation included.

### Why the accessors do not materialize (a deviation from the brief)

The brief specified `simulationIDs(cal) = simulationIDs(Sampling(cal))`, mirroring `GSASampling`.
Implemented that way, an innocuous read would insert a row — and because sampling identity is the
*exact* monad set, doing that mid-run pins a partial set that the finished run will never reuse
(the final set differs, so it gets a second row). Split instead:

| Call | Inserts? | Returns |
|---|---|---|
| `calibrationMonadIDs(cal)` (internal) | no | the raw on-disk record, deleted monads included |
| `monadIDs(cal[, t])`, `simulationIDs(cal[, t])` | **no** | surviving monads / their simulations |
| `Sampling(cal[, t])` | yes | an addressable `Sampling` |

Now only an explicit `Sampling(...)` can mint a row. Documented rather than gated, because there
is no completion flag on the `calibrations` row and the one available heuristic — generation count
against `max_nr_populations` — misreports every run that stopped early on a convergence criterion,
i.e. the normal successful ending.

### The test that was wrong, and what it taught

Two assertions failed on the first full run, and the code was right both times. With
`minimum_epsilon=0.0` and a distance identically 0, a calibration converges in **generation 1**,
and generation 1 is a **single batch**. So the run-wide set, generation 1's set, and that batch's
set are all the same set — and exact-set find-or-insert correctly returns the row the batch already
created instead of inserting a duplicate. The brief's phrasing ("a coalesced view never collides
with a batch row") holds only when the sets differ.

That is a feature, not a collision, so both halves are now pinned: a multi-generation run (via
`_test_nonzero_ss`, which keeps every distance at 1.0 and so prevents convergence) gets its own
row distinct from every batch, and a single-batch run reuses the batch row and adds none. The
`Sampling(calibration)` docstring was corrected to say this.

### Include order: `tags.jl` moves last

`_tagClass(::Type{Calibration})` in `tags.jl` was an `UndefVarError` before this change — a method
signature is evaluated when the method is defined, and `tags.jl` loaded at `:75` while
`calibration/calibration.jl` loads at `:83`. Rather than the alternative (an `AbstractTaggable`
supertype, below), `include("tags.jl")` moved to the **bottom**.

Verified safe before moving it, not after: `tags.jl` defines no types, only constants and
functions; nothing loaded after it names those constants in a signature; every call *into* tagging
from an earlier file is inside a function body, which Julia resolves lazily (`applyCreationTags`
×4 in `classes.jl`, `deleteTagsFor` ×4 in `deletion.jl`, `refreshProvenance!` ×3,
`tagsSchema`/`createTagIndices`/`ensureProvenanceColumns` inside `createSchema`, `tagReserved!` in
`sensitivity.jl` and `abc.jl`); and `LibGit2`/`randstring`, which only `tags.jl` imports, appear
nowhere else in `src/`. Any violation of this would be a load-time error, never silent.

The position has a natural floor, which is what makes it a one-time move rather than a recurring
chore: after `calibration/visualize.jl`, every type in the package is ahead of it. Encoded as a
`#!` comment at the include site so the next person adding an `include` does not undo it.

### `AbstractTaggable` — considered, rejected, and why it may return

A capability supertype (`abstract type AbstractTaggable end`, `AbstractTrial <: AbstractTaggable`,
`Calibration <: AbstractTaggable`) would make the marginal cost of the *next* taggable type one
line instead of ~15 methods, and it names a real category instead of leaving it enumerated by hand.
Rejected for now: it widens ~21 signatures in `tags.jl`, touches `classes.jl` (the most
load-bearing file), adds a layer to the documented public type tree, and changes `AbstractTrial`'s
supertype from `Any`. At two taggable families the per-type methods are cheaper.

What kept the per-type cost honest: the private implementation cores in `tags.jl` are now keyed by
class **string** (`_tags`, `_tagsTable`, `_deleteTagRows`, `_deleteTagsFor`, `_applyCreationTags`,
`_tagReserved`, `_idsWithDirectTags`, `_appendTags!`), so the 19 `Calibration` methods are thin
delegations rather than copy-pasted bodies. If a third taggable family appears, revisit
`AbstractTaggable` — the delegation layer is exactly what it would replace.

**Every `T<:AbstractTrial` signature in `tags.jl` was left narrow.** Under Option A none are
widened; each taggable entry point instead gained a sibling `Calibration` method. Extended (19
methods): `_tagClass` ×2, `tag!` ×4 (type+ids, type+id, object, object vector), `untag!` ×4,
`tags` ×2, `hasTag` ×2, `tagsTable` ×2, `tagReserved!`, `applyCreationTags`, `deleteTagsFor`,
`appendTags!`, `findTrials`, `_inheritedIDs`. The object-*vector* forms of `tag!`/`untag!` were not
in the brief's list and are needed: `findTrials(Calibration; …)` returns a `Vector{Calibration}`,
and without them labelling a query's results in one call is a `MethodError` — a bare integer vector
cannot stand in, since that form is reserved for simulation IDs.

Three entry points were deliberately **not** extended:
`tag!(ids::AbstractVector{<:Union{Integer,Missing}})`, because a bare integer vector must keep
meaning simulation IDs; `findSimulations`/`findMonads`, because those are the inheritance-aware
finders and calibration tags do not inherit; and `trialFolder`, because `calibrationFolder` already
yields the identical `data/outputs/calibrations/{id}` path.

### Inheritance: no, for v1

Calibration-class tags do not propagate to samplings/monads/simulations.
`_inheritedIDs(::Type{Calibration}, …)` returns `Int[]`, so `inherit=true` is a no-op rather than
an error. Reasoning: `mm:calibration` on every generation's sampling (`abc.jl:169`) already gives a
working route — `findMonads(tags=("mm:calibration" => "42",))` — and real inheritance would need
the finders to traverse a new edge whose parent/child mapping lives in per-generation CSVs on disk.

The asymmetry worth knowing is durability, and it runs the other way: tag rows die with their
object, and a sampling all of whose monads were deleted is itself deleted (`deletion.jl:161`), so a
batch's `mm:calibration` tag can vanish with the work it described. The `calibrations` row is never
touched by a monad cascade. Pinned by a test that deletes every monad of a run and checks the tag
on the run survives.

### `calibrationMonadIDs` had three defects, not two

The brief named two. The third came out of reading `compressIDs`:

1. `endswith(f, "_monads.csv")` also matched `generation_{NNN}_failed_monads.csv`, folding the
   failed monads — exactly the ones the runner has deleted — into the "all monads evaluated" list.
   And `reduce(vcat, …)` did not dedupe, though a bank-reused monad is recorded in every generation
   that evaluated it. → anchored `^generation_(\d+)_monads\.csv$` plus `unique!`.
2. `sort` was lexicographic, so `generation_10` preceded `generation_9` whenever the padding
   differed between the original run and a resume with a larger `max_nr_populations` (padding is
   `ndigits(max_nr_populations)`). → sort on the number parsed out of the name.
3. **The docstring's "in evaluation order" was never true.** `_appendCompressedIDs` writes through
   `compressIDs`, which does `ids |> vec |> unique |> sort` (`recorder.jl:41`) — so each
   per-generation file is already sorted and within-generation proposal order is not recoverable
   from the format at all. The real guarantee, now documented, is generation order with ascending
   IDs inside a generation.

Brief 05 lists defects 1–2 as well; they are fixed here, so that session should not redo them.

### Known follow-up, deliberately not fixed here

The lexicographic-sort defect has **four more instances** outside this brief's scope, all of which
additionally derive the generation number from array *position* rather than from the filename, so
they mislabel generations under mixed padding rather than merely reordering them:
`posterior(::Calibration)` (`problem.jl:261`), `ConvergenceSummary(::Calibration)`
(`problem.jl:332`), and `visualize.jl:274` and `:679`. `_indexedGenerationFiles` in
`calibration/calibration.jl` is the shared fix; it takes a directory and a pattern capturing the
index. Left for its own change so this one stays reviewable.

### Smaller decisions

- **`mm:method` on the run** is the method *type* (`"ABCSMC"`), matching GSA's
  `string(nameof(typeof(method)))`, so the key reads the same way across both subsystems. The
  `calibrations.method` column keeps its own spelling (`"ABC-SMC"`); nothing reads it, and changing
  it would alter the meaning of existing rows. Stamped in `runCalibration` only, not `resumeABC` —
  the tag records what created the run.
- **The datetime format fix** (`calibration.jl:37`) was safe precisely because the column was
  write-only: nothing had ever `SELECT`ed it. `_normalizeStamp` (`tags.jl:680-690`) special-cases
  only the 10-digit legacy `trials` format, so the old space-separated spelling would have surfaced
  `mm:created` in a different shape for calibrations alone.
- **No `up.jl` milestone**, and this matters more than it looks: `upgradeMilestones` /
  `upgradeToMilestone` are `AbstractSimulator` methods, so any milestone ModelManager needs must be
  implemented by *every* downstream simulator. `provenance_id` is added by the same additive
  `ensureProvenanceColumns` mechanism the `#!` at `database.jl:142-143` describes.
- **`calibrations` already had a `datetime`**, so only `provenance_id` is added — which means a
  calibration created before this change still reports `mm:created`, synthesized from the column it
  always had, while reporting no provenance. Same graceful degradation as objects predating the
  tagging upgrade, and pinned in the same testset.
- **Placement**: everything new lives in `src/calibration/calibration.jl`, not `database.jl` /
  `deletion.jl`. A `::Calibration` argument in a signature is evaluated at definition time and both
  those files load first; splitting `deleteCalibration`'s integer methods from its `Calibration`
  method across two files would be worse than one cohesive home. The deletion lib page cross-refs it.
- **`calibrationsTable` takes no `limit`**, unlike the brief's sketch: nothing in it materializes
  objects, and neither `simulationsTable` nor `monadsTable` has one.
- **`show(::Calibration)` must never throw** — `Calibration(999999)` is constructible because the
  struct validates nothing, so an uninitialized project prints the bare id, a missing row says so,
  and a malformed generation TOML is skipped.
- `calibrationFolder` / `calibrationsDir` / `calibrationMonadIDs` stay internal. `monadIDs` and
  `simulationIDs` are the public accessors, so no name needed promoting to `@compat public` just to
  keep a docstring hyperlink alive.

### Test isolation: Sobol' determinism, not rowid reuse

A pre-existing testset (`"reusability filter — started or completed simulations"`) broke while
answering review, and the first read of it was wrong — worth recording both the wrong and the right
diagnosis, because the wrong one is the tempting one.

The symptom: a monad created *after* another came back with a *lower* ID and was reported as having
started simulations. That looks exactly like rowid reuse, and rowid reuse is real here — probed
directly: delete a monad with `delete_subs=true`, create another, and the new monad gets the deleted
one's ID *and* its simulation IDs (`monad id 1 → 1`, `sims [1,2] → [1,2]`). But that was not the
cause, and the new monad was still correctly reported as not started, because its simulation rows are
new and carry `Not Started`.

The actual cause is `Sobol'` determinism. Generation 1 proposes Sobol' points, and the first CDF draw
is exactly `0.5`, so `Uniform(a, b)` deterministically evaluates a monad at `(a+b)/2` and runs it to
completion. The testset reserves the fixed value `43.0` for a monad it needs to be *unrun* — and a
calibration testset added here used `Uniform(42.0, 44.0)`, whose midpoint is exactly `43.0`. The
completed monad was then handed straight back through `use_previous=true`, so `unrun` was not unrun.

It had been passing only by accident of ordering: the same range's earlier `delete_subs=true` call
happened to delete that monad again before the reusability testset ran. Adding two more deletion-form
cases after it removed the accident.

Fixed on the right side of the boundary — the six calibration ranges added here moved into 100–117,
disjoint from each other and from every value another testset pins as a fixed `DiscreteVariation`
(0.5, 1, 7, 31, 41, 42, 43, then nothing until 311). Two of the original six were colliding:
`Uniform(42,44)` → 43.0 (`reusability filter`) and `Uniform(30,32)` → 31.0
(`_batchOutcome classifies a batch`). The rule is now stated in a comment at the first range, since
nothing else in the file says that a *continuous* prior in a calibration test still pins an exact
parameter value.

The deletion-form cases themselves were also rebuilt to use `createCalibration` and a hand-made
`ABCResult` rather than three more real runs: they need a row and a folder, not simulations, and not
creating monads is the cheaper way to stay out of a shared project's way.

### Review follow-ups (PR #32)

**Rowid reuse is a real aliasing risk, and the exposure is narrower than the first draft of this
entry claimed.** Review asked whether `_survivingMonadIDs` could let a freshly created monad slip in
at the ID of a deleted one. It can: no MM table uses `AUTOINCREMENT`, so SQLite assigns
`max(rowid)+1` and hands back a deleted object's ID whenever that row held the maximum — verified
directly (insert 1–3, delete 3, insert → the new row is id 3, and its simulations get ids 1 and 2
back too). `AUTOINCREMENT` is the fix and is now a CLAUDE.md to-do, where the severity analysis
lives; it is a schema migration, so the milestone must be implemented by every downstream simulator,
which is why it belongs with the next migration rather than on its own.

The first draft said every durable cross-reference in the package is exposed. That is wrong, and the
correction matters because it is what makes the remaining risk tolerable. Parent constituent CSVs
*are* filtered and rewritten on deletion, and tag rows are removed at all five choke points — so the
`tags` store never carries a stale reference, which makes tag-based recovery immune to reuse and is
why the manual can go on telling users to prefer it over saved ID lists. Only two holes remain:
`deleteSimulations(ids; delete_supers=false)` returns before the parent-CSV filtering, and
calibration's per-generation monads record is never rewritten by any deletion path.

Nor can the calibration exposure reach a result, for a structural reason rather than a lucky one. A
monad is deleted only when every one of its simulations failed; such a monad's distance is `missing`;
and `missing` is dropped in generation 1 and rejected afterwards. So a deleted monad is never an
accepted particle, and the accepted-particle files that `posterior`, `ConvergenceSummary` and
`resumeABC` read cannot contain an alias-prone ID. What is exposed is the monads record: the
`Calibration` accessors added here, and `_lazyLoadRejectedFromDisk` for the `:transition` plot.
Ranked by likelihood, reuse by the next batch *in the same generation* is the common case and is
benign, since the new monad genuinely belongs to that generation; reuse in a later generation
mis-attributes one monad to the earlier generation's view while the run-wide view stays correct; and
a hole that survives the run — which needs the total failure in the final batch, since otherwise the
next batch fills it — lets a later unrelated monad join the run-wide view.

Worth recording what does *not* work, since it looks like it should: subtracting
`generation_{NNN}_failed_monads.csv` from the recorded IDs. That file holds monads with **at least
one** failed simulation, whereas the deleted set is monads with **no successful** simulation —
`_batchOutcome` computes both (`failed_monads` and `without_success`) but only the former is
persisted. Subtracting it would wrongly drop partially-failed monads that are legitimately part of
the run. A calibration-local fix means persisting `without_success` too.

**`calibrationMonadIDs` now returns sorted IDs, not generation-grouped.** Review pushed back that
the name promises "the monad IDs of this calibration", and grouping implies an ordering the storage
cannot carry anyway (`compressIDs` sorts as it writes, so within-generation order is already lost).
Sorting also removed a discrepancy this change previously had to document, since
`monadIDs(Sampling(cal))` reads back sorted from the constituent CSV — the two now simply agree.
Generation scope is what `calibrationMonadIDs(cal, t)` is for.

**The run-level surface dispatches on `ABCResult`.** Review asked why `tag!` and the accessors take
`result.calibration` rather than `result`, by analogy with `MMOutput`. They now take either:
`Sampling`, `monadIDs`, `simulationIDs`, `tag!`, `untag!`, `tags`, `hasTag`, `tagsTable`,
`calibrationsTable`, `deleteCalibration`.

Review also floated an `AbstractMMOutput` supertype. Not built, and the reason is concrete rather
than conservative: the package has three result wrappers — `MMOutput`, `GSASampling`, `ABCResult` —
and each names its payload differently (`.trial`, `.sampling`, `.calibration`). A shared supertype
alone therefore unifies nothing; the forwards would have to be written against an accessor, e.g.
`resultTarget(::MMOutput) = x.trial`, and then `monadIDs(x::AbstractMMOutput) = monadIDs(resultTarget(x))`
once. That is the shape to build if a fourth wrapper appears, and it would let the ~10 forwards per
wrapper collapse to one line each — but it touches `MMOutput` and `GSASampling`, both public, so it
belongs in its own change rather than riding along here.

**Where `description` is going.** Review asked for clarity, since the goal had been to drop the
dedicated column in favour of tags. This change deliberately does not decide it — its job was to
make the column readable so the question stops being academic — but the docs no longer steer users
toward it: `docs/src/man/calibration.md` now says to label runs with tags and explains why
(queryable, multi-valued, retroactive), noting the column is still written and still shown so older
runs keep what they recorded. `show(::Calibration)` keeps printing it, which review liked. The
recommendation for brief 05, where the API is unified: keep the column (old rows carry data, and
dropping it is a breaking change to `runABC(; description=...)`), stop documenting the keyword, and
have it write a tag so the two stop competing.

### Coverage follow-up

Codecov flagged 12 patch lines. Five were real and are now tested: both branches of
`_noViewableMonadsMessage` (a run whose monads were all deleted, and one that never recorded a
generation), and `show(::Calibration)` with no project initialized — the state a stray
`Calibration(3)` at the REPL lands in, and the one the PR body claims cannot throw.

The other six sat in `tags.jl` and were **pre-existing** untested branches that the extraction
refactor merely renumbered (`_quietly`'s `@debug` path, `launchingScript`'s frame-skip and `catch`,
the `script LIKE` provenance lookup, and the trial-level arms of `_simulationIDsMatching` /
`_monadIDsMatching` / `_inheritedIDs`). One of them was worth covering anyway rather than
explaining away: `tagValues(MM_CREATED_KEY)` is one of the five sites that iterate `TAG_CLASSES`,
it is guarded on the `datetime` column alone, and it therefore started including `calibrations` the
moment the class was added. It had never been exercised. It is now, asserting a calibration's
creation stamp reads back through it.

### Rebased onto #31 (trial-ID accessor gaps)

#31 landed first and overlapped in three ways, all resolved in the rebase rather than papered over.

**The coordination point the brief warned about did not apply.** #31 split
`trialID(::Vector{Sampling})` into a pure lookup returning `missing` plus an internal
`_findOrCreateTrialID`, with the instruction to call the latter *if* generations became `Trial`
rows. They did not — generations stay views — so nothing here calls either.

**The pure-lookup principle is now a repo convention, not a one-off.** #31 made
`trialID(::Vector{Sampling})` and `monadIDs(::Simulation)` read-only on the reasoning that an
exported accessor must never write; this change independently made `monadIDs`/`simulationIDs` on a
`Calibration` read-only so a stray read cannot pin a partial monad set. Same rule, two different
motivations, which is worth knowing before anyone "simplifies" either back into a find-or-insert.

**Three merge fixes.** The `CLAUDE.md` trade-off entry had been rewritten by #31 to name
`_findOrCreateTrialID`, so the calibration paragraph was weaved into that version rather than the
old one; `docs/src/man/trial_hierarchy.md` gained a `GSASampling` sentence that was already stale on
arrival, since #31 added `monadIDs(::GSASampling)` alongside `simulationIDs`; and PRD's concurrency
bullet auto-merged to #31's wording, which is correct as-is.

### Cost accounted for

A 10-generation run gains up to 11 coalesced sampling rows plus their constituent CSVs, on top of
one row per batch — bounded and small. Building a view is one `SELECT` per monad (`Monad(id)`), so
a 1000-monad calibration issues 1000 queries; there is no bulk monad constructor as there is for
simulations (`simulationsFromIDs`). Acceptable for a one-time view build, and the obvious follow-up
if it bites.

---

## Session: `run_on_hpc` was never auto-detected (2026-08-05)

### The bug
`mm_globals().run_on_hpc` had **exactly one writer in the entire package**: `useHPC` at
`src/hpc.jl:34`. `isRunningOnHPC()` was exported for users and otherwise dead code — nothing in
`src/` ever called it. So the field sat at its `false` struct default forever, and on a SLURM
machine you got `run_on_hpc == false` while `isRunningOnHPC() == true`.

Two docs had already specified the behavior that was missing, which is why it went unnoticed:
`src/globals.jl:24` ("`true` when `sbatch` is available (auto-detected)") and
`docs/src/man/hpc.md:13` ("`initializeModelManager` checks this at startup and stores the
result"). Neither was true. The fix makes the code match them; both files needed no edit.

Blast radius of the stale `false`, all silent:
- `postInitDisplay` printed `Running on HPC: false` on a cluster.
- `rm_hpc_safe` (`src/deletion.jl:360`) took the plain `rm` branch instead of `.trash/`
  staging — the NFS lock protection the function exists for was simply off.
- PCMM's `runSimulation` gates its `prepareHPCCommand` call on this flag
  (`src/simulator_interface.jl:40`), so no jobs were ever submitted to SLURM unless the user
  called `useHPC()` by hand — cluster runs went to a local process, writing `output.log`
  instead of `hpc.out`.

### Relationship to #26 (2026-08-03) — this reverses one of its decisions
#26 found the same discrepancy two days earlier and resolved it **the other way**: it rewrote
`src/globals.jl`'s field docstring and `docs/src/man/hpc.md` to say that ModelManager
deliberately does not probe, that `run_on_hpc` "defaults to `false` and is set only by
`useHPC`", and that a simulator package may call `useHPC(isRunningOnHPC())` on the user's
behalf. This session reverses that specific choice — the code now probes, and those two
passages are rewritten again — while keeping every other line of #26 intact.

The reason is what an audit of PCMM actually found (checked directly, not inferred):

- `useHPC` appears **only** in `test/test-scripts/HPCTests.jl` (`:8`, `:72`). No `src/` file
  calls it. The delegated call #26 described was not being made by the one backend that exists.
- `src/simulator_interface.jl:40` gates `prepareHPCCommand` on `mm_globals().run_on_hpc`, so
  the stuck `false` meant cluster runs never reached `sbatch` at all.
- `src/physicell_simulator.jl:46` **does** call `isRunningOnHPC()` — into a local, to pick
  `march_flag` (`"x86-64"` vs `"native"`), then discards it. The value #26 said a backend "may"
  supply was already in hand one line from where it was needed, and still never reached the
  global. Note this probe cannot be replaced by reading the global: `PhysiCellSimulator()` runs
  in PCMM's `__init__` to build the simulator that is *then* passed to `initializeModelManager`,
  so the global does not exist yet at that point.

Delegating detection to every backend also duplicates the decision N times and leaves
`isRunningOnHPC` dead in this package.

Worth noting that #26 and this change *compose* rather than fight: #26 built the try-then-stage
machinery and gated it on `run_on_hpc`, and this is what actually delivers it to the cluster
users it was written for. #26's own open question — that `run_on_hpc` is the wrong predicate
for "my data is on NFS" — is untouched and still open, and auto-detection sharpens it: the
staging path now switches itself on wherever `sbatch` exists.

### Decisions
**Detect just before `postInitDisplay`, not at the top of `initializeModelManager`.** The
function documents that "all mutated globals are reset to a clean state before any `false`
return", and each of its four early-return paths resets `data_dir` and `db`. Setting the flag
alongside `simulator`/`data_dir` at the top would have added a fourth global to every one of
those blocks. Placing it after the last failure path costs nothing and still precedes the only
in-init reader (the banner).

**Re-detect unconditionally on every init; no "explicit override" sticky flag.** A second
`initializeModelManager` in one session discards a prior `useHPC(false)`. Considered a latch so
an explicit override survives, rejected as a new global field for a rare case — and
`initializeModelManager` already deliberately resets other per-session state (`provenance_id`,
the tag-hint latches). The natural order (init, then override) is unaffected. Per the user:
this is rare enough that it gets no user-facing documentation at all.

**Rejected:** making `run_on_hpc` a lazily-computed `Union{Nothing,Bool}`. Changing the field
type would touch `deletion.jl`, `postInitDisplay`, and every downstream PCMM read for no gain
over a one-line eager set.

**The `@warn` in `useHPC`.** Fires only when `use && mm_globals().run_on_hpc` — i.e. turning
HPC mode on when it is already on, which is exactly the signature of a script written to work
around this bug. `maxlog=1`. Tells the reader that ≥ v0.8.4 does not need the call.

### Verification
The test suite cannot exercise the true branch on a dev machine, so the fix was checked against
a fake `sbatch` shim placed on `PATH`: without it, `run_on_hpc == false` after init; with it,
`run_on_hpc == true` (pre-fix: `false` in both cases), and the redundant-`useHPC` warning fires
as intended.

The testset asserts `mm_globals().run_on_hpc == isRunningOnHPC()` after init, which holds on a
laptop and a cluster alike and fails on neither for the wrong reason. It restores the detected
value in a `finally`: leaving a stale `true` behind would send every later deletion test's
`rm_hpc_safe` down the `.trash/` staging path instead of `rm`, silently changing what those
tests exercise. Its `useHPC` calls are also sequenced so the flag is always `false` before any
`useHPC(true)`, keeping the new warning out of the test output — asserting the warning with
`@test_logs` was rejected because `TestLogger`'s `maxlog` handling varies across the 1.10 floor.

### Files changed
- `src/globals.jl` — one-line detection before `postInitDisplay`; init docstring step list
- `src/hpc.jl` — redundant-call `@warn` in `useHPC`
- `test/runtests.jl` — `"run_on_hpc auto-detection"` testset (8 assertions, 1354 total passing)
- `PRD.md` (Global State), `README.md`, `Project.toml` → v0.8.4

---

## Session: rm_hpc_safe try-then-stage, warning, and sweep (2026-08-03)

### Goal
`rm_hpc_safe` never called `rm` on HPC — it renamed the target into `data/.trash/` and returned, and nothing ever emptied that directory. A cluster project had therefore never reclaimed a byte, and `resetDatabase` roughly *doubled* disk usage by relocating every output tree plus the central database. Users were never told.

### What was done
1. **Try the removal first.** The HPC branch now attempts `rm(path; force, recursive)` and only stages what survives. This is the change that actually frees space.
2. **Protected staging.** `mkpath`/`mv` run inside a `try`; a failure warns and returns `:unremoved` with the path left in place, rather than throwing. `rm_hpc_safe` now returns `:removed`/`:staged`/`:unremoved` (previously `nothing` off HPC and `mv`'s `String` on it).
3. **Warn once per project** for the routine `:staged` case, latched on a new `trash_staged_warning_shown::Bool` field, cleared in `initializeModelManager` alongside the tag-hint latches. `:unremoved` is not latched — see the Copilot review notes below. (The field started as a `Set{Symbol}` keyed by warning kind; once `:unremoved` stopped being latched it could only ever hold one value, so it collapsed to a `Bool` matching the two sibling tag latches.)
4. **Background sweep** in the existing diagnostics task, ahead of `databaseDiagnostics`, which gained a read-only report of whatever is left.

### Key decisions / gotchas

**A staging area on scratch cannot work, and the reason is POSIX, not Julia.** Getting bytes off filesystem A requires unlinking from A, which is exactly what the filesystem is refusing; a same-mount rename is the only operation that relocates a file *without* unlinking it. Any cross-mount destination makes `mv` a `cp` followed by `rm(src)` — and that `rm` is the refused operation. Demonstrated with an immutable child inside a writable directory: `rm` refused, the same-mount `mv` succeeded as a pure rename, and the cross-mount sequence copied 100 000 bytes and then failed the delete, leaving the original in place. Net: 0 bytes reclaimed, consumption doubled. Two exhaustive cases and no third — if the handle is still open the trailing `rm` fails; if it has closed, a plain `rm` retry would already have succeeded, so copying first is pure waste. The version that works needs no code: put `data/` on scratch.

**The residue is waiting to be retried, not relocated.** A held-open file becomes deletable once the job exits, which is what makes the startup sweep the mechanism that actually reclaims the space.

**Two days, not one, for the sweep's margin.** The bucket label comes from `now()` in whichever session created it; across the UTC-12..UTC+14 spread, a bucket a concurrent session is still staging into can be dated a day on *either* side of our local date. Skipping anything dated after `today() - Day(2)` covers a future-dated bucket for free. Note `Date("260803", "yymmdd")` parses the year as 26, not 2026 — build the `Date` from digit pairs.

**Gate the sweep on `isdir(".trash")`, not `run_on_hpc`.** `useHPC()` is usually called *after* `initializeModelManager`, and `.trash` only exists because of a prior HPC session, so gating on the flag would skip exactly the backlog we want cleared.

**`maxlog=1` cannot implement the warn-once.** It is keyed per call site for the whole session, so it never re-arms for a second project, and `Test.TestLogger` gets fresh `message_limits` per `@test_logs` block, making it indistinguishable from warn-always under test. A globals latch is the only testable option.

**Two path bugs fixed while in there**, both reachable through the public API since `rm_hpc_safe` is exported and `managing_data.md` tells users to prefer it. The old mapping `replace(path, "$(dataDir())/" => "")` hardcoded `/` and left anything outside `data/` absolute; `joinpath` discards everything before an absolute component, so `dest` came back equal to `path`, the collision loop bumped it to `<path>-1`, and the "move" **silently renamed the target in place**, reporting success. Plain `relpath` is not the fix either — it yields `../..` prefixes that escape the trash and `.` for `dataDir()` itself. Needs strict component-wise containment plus an `_external/` branch. Separately, an empty `dataDir()` made `abspath` resolve to the current working directory; caught during verification when a misconfigured scratch harness created `.trash` inside the repo worktree. Now an explicit error, surfaced as `:unremoved`.

### Rejected / considered
- **Stage first, then delete** (rename into `.trash`, `rm` the staged copy, prune empty parents). Genuinely better on interruption safety: `outputs/` is never half-deleted, so a walltime kill mid-`resetDatabase` cannot leave a DB-row-less folder that `databaseDiagnostics` reports as phantom corruption. Rejected as more machinery than the problem warranted; the IO objection raised against it does not hold, since a rename moves no bytes.
- **`emptyTrash()` / `trashPath()`.** The startup sweep covers the automatic case and the warnings name a ready-to-run `rm -rf`. A shell `rm -rf` is also better than a Julia one here — Julia's `rm` aborts its walk on the first non-`EACCES` error.
- **A silencer** (`setTrashWarnings!` or an env var). Every existing suppression knob guards an optional `@info` nudge; these are `@warn`s reporting that a requested deletion did not happen, and they fire at most once per project per session.
- **A `stat().device` cross-device guard.** Unsound: APFS volume groups report identical `st_dev` for genuinely different mounts, and `stat` on a missing path returns `device == 0`. Moot once the staging root stopped being configurable.

### Version-specific findings worth keeping
- On the **1.10 LTS and 1.11**, `rm`'s recursive walk has no per-child recovery (that arrived in 1.12) — one `EACCES` child abandons every remaining child, so staged residue can be much larger there. The docs deliberately do not promise that `rm` frees everything it can before staging.
- On **1.10/1.11** `mv` is *more* aggressive about the cross-device copy than on 1.12: `rename(src,dst;force)` ccalls `jl_fs_rename` and on any `err < 0`, with no errno inspection at all, falls back to `cp` + `rm(src)`.
- There is **no portable strict rename**: `Base.rename` is public and throwing only on 1.12; on 1.10/1.11 the same name is the silent `cp` + `rm`, and `hasmethod` cannot tell them apart.

### Copilot review on PR #26
Three comments; two were real defects, one was a false positive.

**Accepted — `resetDatabase`'s error cited a warning the latch could suppress.** It says "The warning above names the underlying filesystem error", but `:unremoved` was latched per project, so an earlier failed deletion in the same session would swallow the warning and leave the user an error with no errno anywhere in the logs. Fixed by **not latching `:unremoved` at all**. That is the better semantics on its own merits: every occurrence names a *different* leaked, untracked path, and the warning is the only record of it that will ever exist, so reporting only the first silently loses the rest. The noise argument that justified the latch applies to `:staged`, which fires once per simulation on a merely busy filesystem; reaching `:unremoved` needs both the removal *and* the rename to fail, which is a broken filesystem rather than a busy one, and then loud is proportionate.

**Accepted — `databaseDiagnostics` treated an unreadable `.trash` as an empty one.** The `catch` around `readdir` returned `String[]`, so a permissions failure produced silence, telling the user their disk was clear on the strength of a question we could not answer. Now distinguishes the two and warns that the directory exists but could not be inspected. Tested, guarded by a uid check since permission bits are ignored under root.

**Rejected — "the docstring example escapes `$`, so it prints literal text instead of interpolating."** Backwards. The `\$` in the source is what makes the *rendered* docstring contain a live `$(...)`; a bare `$` would interpolate at docstring-definition time, calling `dataDir()` at load. Verified with `@doc rm_hpc_safe`, which renders `@info "still on disk under $(joinpath(dataDir(), \".trash\"))"` — exactly the copy-pasteable code intended.

### Cluster testing: message wording, and dropping the age threshold
Run on a real cluster against PCMM. The mechanism worked; the wording did not. Fixed: "the path is out of the project tree" was simply false (`.trash` is *inside* `data/` — it is out of `outputs/` and out of the database, which is what was meant); "none of it is a backup" was editorialising and is gone; "retries" → "will retry"; and "Only the first staged path in this project is reported" used a word the reader has no reason to know, now "Suppressing further warnings about this for the rest of this session."

**The two-day age threshold is gone.** It existed so a sweep could not delete a bucket another session was staging into, which meant picking a delay long enough to cover clock skew and timezone spread — and then paying for it by leaving reclaimable space sitting for days. The concurrency problem is better solved where it happens: `_stageInto` recreates the directory and retries the move, recomputing the destination each attempt so a name another session took is not reused, and rethrowing immediately if the parent still exists (a failure recreating it cannot fix). The sweep's only guard now is a shape check, `^data-\d{6}$`, so it never touches an entry it did not create.

Its retry count of three is bounded deliberately, and the bound is the opposite call from the collision search above. There, a cap was wrong because every iteration tests a distinct path and a filesystem holds finitely many, so the check itself terminates. Here every attempt repeats the same operation, so there is no progress argument and a peer sweeping in a loop could livelock the caller; a bound is required and exhausting it merely reports `:unremoved`. Three because a sweep iterates a `readdir` snapshot and removes each entry once, so one pass can knock a staging out at most once — a second attempt covers the entire first-order race, and a third means another independent sweep hit the same window.

**One consequence, caught by the collision tests going red.** With no threshold, a mid-session sweep will reclaim residue staged seconds earlier. That is correct in production — it is trash, and on a real filesystem the residue is still held, so the sweep's `rm` fails exactly as the first one did — but it made the stamp placement wrong. `last_trash_sweep` is now set *before* the `isdir` check, not after: a `.trash` that appears later today holds only residue this session has just failed to delete, so retrying it minutes later would fail the same way. The earlier rule ("stamp only once past the checks, so a `.trash` created later still gets swept") was written for the age-threshold world and became actively harmful without it.

### Review follow-up: a session that outlives the startup sweep
The sweep fired exactly once, from `initializeModelManager`. A driver script running for a week on a cluster would sweep on day one and never again, staging into a fresh `data-YYMMDD` bucket each day while nothing retried the earlier ones — even though the jobs holding those files had long since exited and a retry would have succeeded. Worst on the 1.10/1.11 LTS, where `rm`'s walk aborts on the first `EACCES` and a bucket can hold a whole output tree rather than a few stubs.

Staging now re-sweeps when the day rolls over, keyed on a `last_trash_sweep::String` (`yymmdd`) field. At most once a day, on a path that is already exceptional, so the cost is a `readdir` of a directory with a handful of entries. The stamp is set *before* the work and only once past the `isdir` check — before, so a sweep that cannot finish is not retried on every subsequent staging; only past the check, so a `.trash` created later the same day still gets its first sweep.

The two-day window itself was left alone: it guards against a *concurrent* session writing into a bucket, which is independent of how long any one session runs. A six-day-old bucket cannot be receiving writes, since bucket names are stamped at write time.

### Review follow-up: the collision-suffix cap
The staging-destination search was `for n in 1:1_000`, which was wrong twice over. It did not fail safe: on hitting the cap it returned `"$(stem)-1000$(ext)"` *without testing it*, so the 1000th collision handed back a possibly-taken path (caught downstream only because the `mv` carries no `force`, degrading to `:unremoved`). And the cap was guarding the wrong thing — the hang it prevented came from `_existsQuietly` reading an unanswerable check as "taken", not from legitimate collisions being numerous.

Now unbounded, with a strict `ispath`/`islink` in the loop instead. Termination comes from the check: each iteration tests a distinct path and a filesystem holds finitely many, while an `EACCES` throws (verified: `ispath` under a `chmod 000` parent raises `IOError` code -13) and is reported as `:unremoved` with the real error. `_existsQuietly` is still right for the *residue* check in `_stageResidue`, where "cannot tell" should conservatively mean "something may be there" — the two call sites want opposite behavior on an unanswerable question, deliberately.

Worth noting for anyone worried about the scan being linear: a collision requires the same path to have a *failed* removal twice in the same day. Ordinary high-volume create/delete traffic returns `:removed` and never touches `.trash` at all.

### Tests added (4 new testsets, all passing)
In the isolated-project band, each restoring `useHPC(false)` in a `finally` since the flag is not reset by `initializeModelManager` and a throw skips the rest of a testset body. Fault injection is root-proof — chmod tricks are ignored under root and would silently no-op — so failures are forced by `recursive=false` on a non-empty directory (`rmdir` → `ENOTEMPTY`; `force` excuses only `ENOENT`) and by a regular file where `.trash` should be, which makes `mkpath` throw.

### Files changed
- `src/deletion.jl` — `rm_hpc_safe` rewritten; `_stageResidue`, `_trashRoot`, `_trashDestination`, `_isStrictlyUnder`, `_existsQuietly`, `_warnStagedOnce`, `_sweepTrash`, `_maybeSweepTrash`, `_trashBucketDate` added; `resetDatabase` guards the central database file against `:unremoved`.
- `src/globals.jl` — `trash_staged_warning_shown` and `last_trash_sweep` fields + docstring bullets, reset in `initializeModelManager`, sweep launched in the diagnostics task, and the false "auto-detected" claim on `run_on_hpc` corrected.
- `src/database.jl` — read-only trash report at the end of `databaseDiagnostics`.
- `test/runtests.jl` — `using Dates`; four new testsets.
- `docs/src/man/{hpc,managing_data}.md` — both described a mechanism that did not exist ("tolerates transient `unlink` failures"); rewritten, plus the same auto-detect correction in `hpc.md`.
- `PRD.md`, `README.md`.

### Open questions
- `run_on_hpc` is the wrong predicate for "my data is on NFS": a Lustre/GPFS user pays for staging machinery they do not need, and someone on an NFS-mounted lab server who never calls `useHPC()` gets bare `rm` and hits the exact failure this absorbs. Aiming it via the SLURM flag is a compromise.
- `.trash` was an accidental undo buffer on HPC — nothing was ever deleted there, so it held a recoverable copy of every output tree and of the central database before a `resetDatabase`. Never documented or relied on, but a real capability loss; belongs in release notes.

---

## Session: docs findability pass (2026-08-01)

### Goal
Users could not find things. The trigger case: **post-processing was undiscoverable.** It was
96 of 185 lines of `man/running_simulations.md` — page-sized content wearing a `##` section's
clothes — and Documenter surfaces a page's `##` headings in the sidebar only *once you are
already on that page*. Someone asking "how do I compute a quantity of interest per simulation
and store it?" would never open a page titled *Running simulations*, and no `index.md` routing
row pointed there. Three other pages linked *into* that section: a hub reachable only sideways.

Work started from a finished-but-unapplied patch (`docs-findability.patch`, base `3a5369c`)
produced out of order relative to `CLAUDE.md` § *Required Workflow*, plus a handoff note listing
four open questions. Two of the handoff's answers turned out to be wrong; see below.

### What was done
1. **Applied the patch.** New `man/post_processing.md` (retitled *Post-processing and quantities
   of interest* — the old title contained only words a user would use if they already knew the
   feature's name), `running_simulations.md` 185 → ~107 lines with a short *After each simulation*
   pointer, `index.md` routing table rewritten as five task-grouped tables, `tagging.md` given
   `@id tagging` and the `@meta CurrentModule` block it was the only man page missing.
2. **Results & Analysis sidebar group.** New `man/tables.md` (`@id result_tables`) lifts the
   analysis-table API out of `man/database.md` `## Querying`, where 12 lines had been the *only*
   narrative documentation of `simulationsTable` / `monadsTable` / `postProcessingTable`, their
   shared keywords, the `print…` variants and `sink`. `man/database.md` is now schema + raw SQL +
   diagnostics, and its `## Querying` heading finally means only SQL.
3. **Cross-reference correctness.** Five "See the *X* API reference" pointers resolved back to
   the man page itself; `@id` anchors on all man/misc H1s plus the four lib pages they should
   have pointed at; every heading-targeted `@ref` converted to anchor form.
4. **Search-index cleanup.** Deleted the 18 `Public = false` `@autodocs` blocks and the
   boilerplate `## Public API` / `## Private API` headings. 524 → **361** entries; 86 → **0**
   underscore-prefixed; 34 → **0** duplicate section rows. Title matches for "post processing"
   went 12 → 6, and the six are now the prose page plus five genuinely public functions.
5. **19 bindings declared `@compat public`, 8 delinked** — see below.

### Key decisions / gotchas

**An explicit `@id` *replaces* a heading's title slug; it does not add an alias.**
`expander_pipeline.jl:301-317` takes the id if the heading is `[…](@id x)`-wrapped and the
plain text otherwise, then slugifies exactly one of them. So adding `@id` to a page H1 breaks
every inbound bare `[Exact Title](@ref)`. Any future anchor addition must convert its inbound
links in the same commit. The docs build catches this (no `warnonly` in `make.jl`), so a green
build *is* the link check.

**Consolidating internals into one `lib/internals.md` would not have reduced search noise.**
The handoff proposed it. Documenter 1.17 pushes every section segment and every docstring into
`search_index.js` unconditionally (`HTMLWriter.jl:1806`, `:1909`); there is no `Documenter.HTML`
kwarg, no `@meta` key, and no `@autodocs` option that excludes anything from search — the only
search-related option is `search_size_threshold_warn`, which merely warns on size. Consolidation
relocates entries; it does not remove them. **Not rendering is the only lever.**

**The `Public = false` blocks were never load-bearing.** `CLAUDE.md` described them as the
reason the local build was *blind*, and the handoff read that as a dependency. The guard testset
reads `Docs.meta(ModelManager)` — the runtime docsystem table, which Documenter itself consumes
via `DocSystem.getmeta` — and never opens a file under `docs/`. Removing the blocks left it
bit-for-bit identical (verified: 1346 tests, guard included). `checkdocs=:exports` does not
care either; it only requires *exported* names to appear.

**Removing them exposed 27 bindings the manual had been documenting as API that were never
declared.** 32 broken links across 12 pages. None are `_`-prefixed, so by this repo's own
naming convention (`_` = internal) they were never internals — they sat in an undeclared middle
state that the `Public = false` blocks had been papering over. Resolved against the criteria
`CLAUDE.md` already endorses rather than "keep the hyperlink alive":
- **types/accessors in public signatures** (the existing rationale for `SimulationSpec`,
  `GSASampling`) — `GSAMethod`, `MOATSampling`, `SobolSampling`, `RBDSampling`,
  `getMonadIDDataFrame`, `methodString`, `AddVariationMethod`, `AddVariationsResult`,
  `SimulationBank`
- **backend contract** (the existing rationale for the `AbstractSimulator` interface methods) —
  `upgradePackage`, `continueMilestoneUpgrade`, `populateTableOnFeatureSubset`,
  `defaultJobOptions`
- **functions the manual tells users to call** — `recognizedStatusCodes`, `initializeDatabase`,
  `addVariations`, `databaseDiagnostics`, `buildWhereClause`, `resetFolder`
- **delinked to plain code spans** (parenthetical "(see X)" implementation notes only) —
  `compressIDs`, `recordConstituentIDs`, `sanitizePathElement`, `prepCmdForWrap`,
  `prepareHPCCommand`, `updateDatabaseOnCompletion`. `sanitizePathElement`'s sentence was
  rewritten to state the actual validation rules inline rather than leave a dead pointer.

`prepareTrialHierarchy` and `pendingSimulationSpecs` were initially promoted under the backend
-contract heading and then pulled back, on the grounds that `run` calls both internally.
`pendingSimulationSpecs` stayed pulled; `prepareTrialHierarchy` was **restored** by the PCMM
audit below. `man/running_simulations.md`'s two-phase description now names the phases without
linking to their implementations, and `building_a_simulator.md` says "during the runner's
preparation phase" instead of naming the function — that wording is fine either way and was
left alone.

### PCMM dependency audit (same session)
Audited PhysiCellModelManager at `674785d3c` for everything it reaches into ModelManager for —
qualified `ModelManager.x`, `import ModelManager: …`, and `using ModelManager: …`. **83 distinct
bindings; 33 were neither exported nor `@compat public`.** Split by where they are used:

- **16 used in PCMM's `src/` → promoted.** The XML layer a backend builds on
  (`getChildByAttribute`, `getChildByChildContent`, `retrieveElementError`, `elementIsTerminal`,
  `setSimpleContent`, `createXMLFile`, `prepareBaseFile`, `prepareVariedInputFolder`),
  `defaultLatentParameterNames`, `shortVariationName`, `validateParsBytes`, `calibrationsSchema`,
  `reinitializeDatabase`, `shellCommandExists`, `prepareHPCCommand`, and `prepareTrialHierarchy`.
  All 77 bindings PCMM's `src/` touches are now public (verified with `Base.ispublic`).
- **17 used only in PCMM's `test/` → left undeclared.** `ParsedVariations`, `calibrationFolder`,
  `calibrationMonadIDs`, `constituentType`, `createCalibration`, `createSchema`,
  `eraseSimulationIDFromConstituents`, `locationVariationsTable`, `lowerClassString`,
  `nLatentDims`, `nTargetDims`, `runAbstractTrial`, `sanitizePathElement`, `variationIDs`,
  `variationLocation`, `variationTarget`, `variationValues`. Julia does not enforce `public`, so
  `PhysiCellModelManager.ModelManager.foo(...)` works regardless; tests poking internals is not an
  API contract. `runAbstractTrial` in particular is a deprecation shim PCMM tests only to confirm
  it still warns — promoting it would document a name on its way out.

**`prepareTrialHierarchy` came back because of a docstring, not a call.** PCMM's
`src/simulator_interface.jl:28` and `:192` write `` [`ModelManager.prepareTrialHierarchy`](@ref) ``
in their own docstrings. That is the downstream `:cross_references` failure mode this repo already
guards against, just pointing the other way.

**Correction to a premise in `CLAUDE.md`.** It states "a downstream build renders only
ModelManager's public API." That is **not true of PCMM at `674785d3c`**: its `docs/make.jl` sets
`modules=[PhysiCellModelManager, ModelManager]` and its `docs/src/lib/*.md` pages carry
`Public = false` blocks for `Modules = [ModelManager]`, so it renders our private API too — which
is why `docs/src/lib/calibration.md:78` can reference `ModelManager._resolveVerbosity` and build.
Nothing in PCMM is currently broken; the promotions declare a real dependency surface rather than
repair a build. The rule still holds as written *if* PCMM ever drops those blocks, which is the
cleanup this session just did here. Worth revisiting the wording once PCMM's side is settled.

`prepareHPCCommand` and `sanitizePathElement` were both delinked to plain code spans earlier in
this session as parenthetical implementation notes. `prepareHPCCommand` is now public and could be
re-linked, but its sentence pairs it with `prepCmdForWrap`, which is not; linking one of the pair
would read worse than linking neither. Left as prose.

**The guard testset scans docstrings only.** `@ref`s in `docs/src/**/*.md` are outside its loop,
which is why `man/variations.md` could carry `[`_validateInverseMaps`](@ref)` — a manual-page ref
to a true internal — undetected. The docs build catches that class now; the testset still does
not. Anchor-form refs (`[text](@ref some_id)`) are outside its regex too.

**Deliberate small duplication kept.** `running_simulations.md` still names the three-hook order
in two sentences so the runner page reads on its own; the details live only on the
post-processing page. Do not re-expand it.

**Bookkeeping deliberately scoped.** No `PRD.md` entry and no README Implementation Status row:
`PRD.md` has never carried a documentation entry, and the June 2026 docs rework (`0b6114f`,
41 files) added a progress.md entry and no README row. One factual correction to `README.md:84`
and to the testset's leading comment, both of which asserted that ModelManager's own docs render
the private API — no longer true.

### Files changed
- `docs/make.jl` — Results & Analysis group
- `docs/src/index.md` — five task-grouped routing tables, plotting row
- `docs/src/man/post_processing.md`, `docs/src/man/tables.md` — new
- `docs/src/man/{running_simulations,database,tagging,managing_data,variations,space_filling,hpc,project_configuration,sensitivity_analysis,calibration,overview,trial_hierarchy,installation,building_a_simulator}.md`,
  `docs/src/misc/database_upgrades.md` — anchors, ref conversion, delinks
- `docs/src/lib/*.md` (18) — private blocks and boilerplate headings removed; `@id`s on four
- `src/{sensitivity,runner,database,variations,up,hpc,deletion}.jl`, `src/calibration/bank.jl` —
  `@compat public` declarations
- `CLAUDE.md`, `README.md`, `test/runtests.jl` — corrected now-false claims

### Absorbed: two stale ownership comments
Spun off as a side task, then folded back into this branch rather than landing as a separate
branch to rebase past.

- **`src/database.jl:3` deleted.** "simulationsTable and printSimulationsTable are
  simulator-specific — exported by the simulator package." Every clause was false: both are defined
  in that file (~:1028, ~:1057) and exported at `src/ModelManager.jl:39`, and none of the four
  `simulationsTable` methods takes an `AbstractSimulator`. Same trap `CLAUDE.md` documents for
  `addVariationRows`. Nothing to salvage, so the comment is gone rather than corrected.
- **`runSensitivity` does not exist and never did.** The exported GSA entry point is
  `run(::GSAMethod, ...)` (`src/sensitivity.jl:62`); the only similarly named thing is the
  unexported `runSensitivitySampling`. The phantom appeared in four places — `src/sensitivity.jl`,
  `CLAUDE.md` twice, and `progress.md` — all corrected, since the substance of each claim was right
  and only the name was wrong.

  This one is worth remembering: **this session propagated it.** The `@compat public GSASampling`
  comment already said `runSensitivity`, and expanding that block from 2 lines to 5 carried the
  error forward into longer, more authoritative-looking text. Inheriting a neighbouring comment's
  phrasing inherits its bugs.

**Neither would have been caught by the guard testset**, which reads docstrings only and checks
`Base.ispublic` — not whether a name exists. Both of these lived in `#!` comments. Nothing in the
repo validates that a name mentioned in a comment is real.

### Open questions
- **22 backticked type refs land on headings, not docstrings.** `[`LHSVariation`](@ref)` hits
  `## LHSVariation` on the same page while `[`GridVariation`](@ref)` reaches its docstring, purely
  because that heading reads `## GridVariation (default)`. Documenter's `Header` resolver (order
  1.0) precedes `Docs` (3.0). The "Choosing a design" table mixes both in adjacent rows. Clean fix
  is renaming the colliding headings to the `## Qualifier: TypeName` pattern already used on those
  same pages. Affects `space_filling.md`, `variations.md`, `trial_hierarchy.md`,
  `project_configuration.md`.
- **`## Building a backend`** (`installation.md:18-56`) duplicates steps 1–2 of
  `building_a_simulator.md`, and the registry step exists *only* there.
- **Shared-filesystem guidance duplicated** across `hpc.md:47` and `managing_data.md:66`, in two
  sidebar groups, with no cross-link.
- **`src/sensitivity_visualize.jl` is in no lib page's `Pages` list**, and `endswith` matching
  means it would land on `lib/calibration.md` (via `"visualize.jl"`) if its recipes became
  bindable. `lib/utilities.md`'s leading-slash `Pages = ["/utilities.jl"]` is the only defence
  against this class anywhere, and it is undocumented.

---

## Session: Trial tagging and feature-based recovery (2026-07-29)

### Goal
Users need to recover past simulations by *what they were for*, not by ID or parameter value. Scripts that record simulation IDs drift out of sync with the database and are the current, fragile answer.

### Framing decision that shaped everything else
The root problem is not "there is no tag table" — it is that **nothing in the schema records why a simulation exists**. Every stored fact is identity (`simulation_id`), configuration (input/variation IDs), or execution state (`status_code_id`). Intent lived only in the user's script.

That reframing produced two consequences:
1. A tag table users must remember to populate has the *same* failure mode as a script that records IDs. So the highest-value tags had to be **automatic**.
2. Front-loading tags is what users won't sustain, because at creation time you often don't know what will turn out to be interesting. So **retroactive tagging is the primary user-facing path**, not a nice-to-have — `tag!` accepts whatever a query hands back, and labeling happens at the moment of discovery.

### Design decisions

**One denormalized `tags` table, not a `tags`/`taggings` pair.** Normalizing into a vocabulary table plus a junction table buys a canonical key list, but `SELECT DISTINCT tag_key` gives that for free at this scale. Revisit only at millions of rows.

**Polymorphic `trial_class` TEXT column rather than four per-class tables.** Matches the existing generic `for T in (Simulation, Monad, Sampling, Trial)` idiom (`_snapshotMaxIDs`, `databaseDiagnostics`) and `lowerClassString`. Cost: SQLite cannot foreign-key it, so integrity rests on the deletion hooks plus `orphanedTagCounts` in diagnostics.

**Key/value, not bare labels.** A bare label cannot answer "show me every high-dose run". Bare labels remain as the degenerate case with an empty value. `tag_value` is inside the `UNIQUE` constraint, so a key can be multi-valued (one simulation in two cohorts).

**`tag_value` defaults to `''`, never `NULL`.** SQLite treats `NULL`s as distinct in a `UNIQUE` constraint, so `NULL` would have silently permitted duplicate bare labels. Non-obvious and worth remembering.

**Keys are identifiers; values are data.** Keys become DataFrame column headers, CSV headers, and potentially filter tokens, so they are lowercased, whitespace-stripped, and restricted to `[a-z0-9][a-z0-9_.-]*`. Values only ever land in cells, so they stay free-form. Lowercasing kills the invisible-duplicate bug (`"Cohort"` vs `"cohort"` are distinct under SQLite's case-sensitive `=`).

**The reserved `mm:` namespace enforces itself.** Since `:` is not in the legal key charset, `tag!` cannot write a provenance key — no separate reserved-word check exists. This fell out of the charset restriction rather than being designed in, and is the tidiest part of the schema.

**No migration needed.** `createSchema()` runs on every `initializeDatabase()` using `CREATE TABLE IF NOT EXISTS`, so a purely additive table appears on existing databases automatically. No `up.jl` change and — importantly — no new `upgradeMilestones` entry required in PCMM. Verified by a test that drops the table and reinitializes.

**Tags are stored once, on the object they are placed on; inheritance is resolved at query time.** Fanning a sampling's tag out to 200 simulation rows would go stale the moment a replicate is added to one of its monads. The cost is that inheritance cannot be a single SQL query — parent/child edges live in CSVs (`recordConstituentIDs`), not SQL — so `findSimulationIDs` expands matches through `constituentIDs`/`samplingSimulationIDs`/`trialSimulationIDs`. Only objects matching a requested filter are expanded, which keeps this cheap.

**Ambient scope reads at row-insert time, so it works around `createTrial` *and* `run`.** An earlier draft claimed `createTrial` was the only correct place; that was wrong — `run(inputs, variations)` constructs internally, so the scope is live either way. But `run([t1, t2])` (the batching-for-parallelism workflow) constructs only the umbrella `Trial`, so `run` *also* applies ambient tags to the objects it is handed. Otherwise wrapping that `run` would tag the least semantically meaningful object in the hierarchy — the batch container exists for scheduling, not meaning.

**Tags are written before dispatch, never after completion.** Consequences: a crashed run keeps its tags; failed simulations (which `simulationFailed` erases from their monad) are still labeled; and an in-flight multi-day HPC job is queryable by tag while running.

**Simulator version is deliberately not tagged.** It is already a foreign-keyed column on every `simulations`/`monads`/`samplings` row via the `simulatorVersionTableName`/`resolveSimulatorVersionID` interface, which the downstream package owns (PCMM stores the PhysiCell hash there). `mm:git` therefore means unambiguously "the user's own repo" — specifically the repo containing the calling script, since that path is already resolved for `mm:script`.

**Shelling out to `git` rather than using `LibGit2`.** `LibGit2` is a stdlib but would still need a `Project.toml` entry, and CLAUDE.md forbids adding dependencies without approval. Shelling out also respects the user's git config and worktree setup. Cached per session per directory; stderr routed to `devnull` so a non-repo directory is silent.

**Provenance is cached, not recomputed per object.** Resolving the calling script walks the stacktrace, which is far too slow to repeat for every simulation in a sweep. `PROGRAM_FILE` covers `julia script.jl` cheaply; the stacktrace walk is the REPL/`include` fallback and runs once, refreshed by `withTags` (a rare call) via `refreshTagProvenance!`.

**Pivoted tag columns are namespaced `tag:<key>`.** `simulationsTable` already generates columns from folder names, XML parameter paths, and `SimID`/`MonadID`; a tag key like `simid` would otherwise collide. The prefix also makes it visually obvious which columns are assertions versus configuration.

### Decisions made without confirmation (user was away)
- **`inherit=true` is the default for `findTrials`.** Asked but not answered before implementation began. Defaulting to inheritance makes "find everything in project X" do the obvious thing; the risk flagged earlier — a trial tag silently expanding to thousands of simulations — is mitigated by `findSimulationIDs` returning plain IDs (no per-object DB query) and by `inherit=false` being one keyword away.
- **Values have surrounding whitespace trimmed**, a small deviation from the "values preserved exactly" line in the design brief. `"high "` vs `"high"` reading as two different tags is a real footgun and the whitespace is invisible in every printout. Internal whitespace, case, and unicode are still preserved.
- **`mm:` stayed a string prefix rather than also getting a boolean column.** A column would make "only my tags" a cleaner `WHERE`, but `LIKE 'mm:%'` is adequate and the prefix is self-documenting in printed output.

### Rejected / considered
- **Copying parent tags down onto simulations** — rejected; goes stale when replicates are added later.
- **Storing computed outcomes as tags** — rejected. Outcomes belong in the existing `post_processing` sink (dynamic columns, keyed by `simulation_id`), which already works and supports numeric columns. Tags have no type and no range-query story. Recovery queries join the two on `simulation_id`.
- **Tagging only at `createTrial`** — rejected after the user pointed out that `run` legitimately operates on upstream inputs.
- **A registered tag vocabulary with allowed values per key** — deferred. `tagKeys()`/`tagValues()` give discovery, which catches typos in practice; enforcement can be added later without a schema change.
- **`LibGit2`** — rejected to avoid a `Project.toml` change (see above).

### Files changed
- `src/tags.jl` — new file: schema, key/value normalization, `tag!`/`untag!`/`tags`/`hasTag`, `withTags` + `_withReservedTags`, provenance capture, `applyCreationTags`/`applyRunTags`, `findSimulationIDs`/`findSimulations`/`findMonads`/`findTrials`, `tagsTable`/`tagKeys`/`tagValues`, `appendTags!`, hints, `deleteTagsFor`, `orphanedTagCounts`
- `src/ModelManager.jl` — `include("tags.jl")` after `database.jl`; exports
- `src/globals.jl` — `tag_scope`, `tag_provenance`, `session_id`, `tag_hints`, and two hint latches on `ModelManagerGlobals` (all defaulted, so PCMM needs no change); reset on `initializeModelManager`
- `src/database.jl` — `tags` table + index in `createSchema`; `tags`/`include_auto_tags` kwargs on `simulationsTableFromQuery`/`monadsTableFromQuery`; orphan check in `databaseDiagnostics`
- `src/classes.jl` — `applyCreationTags` at the four insert sites (Monad tags on both the INSERT and the reuse path)
- `src/user_api.jl` — `tags` kwarg on `createTrial`/`run`; `_withOptionalTags`; `createTrial(::AbstractVector)` tags constituents
- `src/runner.jl` — `applyRunTags` before dispatch
- `src/deletion.jl` — `deleteTagsFor` at the four choke points
- `src/sensitivity.jl` — `mm:method`
- `src/calibration/abc.jl` — `mm:calibration`, `mm:generation` per batch
- `test/runtests.jl` — 8 new testsets (~100 assertions)
- `docs/src/man/tagging.md` — new manual page
- `README.md`, `PRD.md` — feature documented

### Seven docstrings were silently detached

Surfaced when the docs build suddenly could not resolve `[`tag!`](@ref)`. Julia does **not** attach a docstring across an intervening comment — the `#!` blocks moved between a docstring and its definition (the earlier "put rationale in comments, not docs" pass) orphaned every one of them.

Seven cases: `MM_TAG_PREFIX`, `PROVENANCE_COLUMNS`, `tagsSchema`, `provenancesSchema`, `createTagIndices`, `tag!`, and `_createTrial`. Only `tag!` produced an error, because it is the only one cross-referenced from another page; the rest were simply absent from the rendered docs and from `?tag!` at the REPL, with nothing to indicate it.

Fixed by moving each comment inside the function body — where implementation rationale belongs anyway — and, for the two `const`s that have no body, above the docstring. A scan now confirms none remain, and a runtime check confirms every exported tagging name resolves a docstring.

Worth remembering as a general rule: a comment between a docstring and its definition breaks the attachment silently, and a green test suite will not catch it. Only an `@ref` from elsewhere, or checking `@doc` directly, will.

### VS Code REPL mis-attributed `mm:script`

Reported from a real editor session: an object created at the VS Code Julia REPL recorded

    mm:script => ".../julialang.language-julia-1.189.2/scripts/terminalserver/terminalserver.jl"

— the extension's REPL driver, not anything the user wrote. Worse than an absent script: identical for every VS Code user, and it pollutes `tagValues("mm:script")`.

`launchingScript` walked the stack for the outermost frame outside ModelManager. The existing filters reject pseudo-files (`REPL[3]`, IJulia `In[3]`, Pluto cells) via `isfile`, and stdlib via the share path — but `terminalserver.jl` is a real file in a real directory, so it passed everything. `mm:interactive` was correctly `true`; only the attribution was wrong.

Two separate causes, and the first fix addressed only one.

**Cause 1 — the stack walk.** A frame is attributed only if it lives under the active project or working directory: a positive test, not a denylist of front-ends. That is what makes an `include`d script win over the `VSCodeServer` internals sitting further out on the stack.

**Cause 2 — `PROGRAM_FILE`, the real culprit.** The first fix appeared not to work, and the initial diagnosis ("stale REPL — restart it") was **wrong**. A diagnostic dump from the live session showed it *was* running current code and the walk *was* dropping every `VSCodeServer` frame — but `launchingScript` consults `PROGRAM_FILE` before walking, and VS Code launches its REPL as `julia .../terminalserver.jl`. Julia is not wrong here: `PROGRAM_FILE` faithfully reports the script the session was launched with. It answers a different question than "what is doing this work", and the two diverge whenever a tool opens the session for you.

**Resolution (user's call).** Interactive sessions prefer a frame from the user's own code and fall back to the launcher rather than recording nothing — a launcher path is a truthful answer to how the session started and identifies the front-end, which is more useful than silence. `mm:interactive` is the flag that says not to trust either for reproduction. Final tree:

| Session | Result |
|---|---|
| not interactive, `PROGRAM_FILE` set | that script — authoritative |
| interactive, user frame on the stack | that file — an `include`d script wins |
| interactive, no user frame | the launcher (`terminalserver.jl` under VS Code) |
| interactive, no launcher either | `""` |

Verified across all five shapes; three are covered by a subprocess regression test. Note that containment could not have separated launcher from user script, because `julia /tmp/analysis.jl` is legitimate work outside the project — only interactivity distinguishes them, and only for choosing *precedence*, not for rejecting outright.

Only a real editor could have surfaced this — every prior check ran `julia script.jl`, `julia -e`, or bare `julia -i`, none of which put third-party tooling on the stack.

Two reproduction attempts were themselves wrong before one was right. The first `include`d the fake driver *before* the probe rather than *around* it, so its frame had already popped and the test passed for the wrong reason. The second nested it correctly but ran the driver via `-e "include(...)"`, which leaves `PROGRAM_FILE` empty — exercising the stack walk and never the path that was actually failing. Only passing the driver as the script argument, the way an editor does, reproduced it. The lesson is that "I reproduced it" needs the same scrutiny as "I fixed it". The regression test now spawns an interactive subprocess whose caller is a file outside the project, which is the shape that actually fails. Related discovery while building it: `Base` stack frames report bare filenames (`boot.jl`, `client.jl`), which `abspath` resolves against `pwd()` into paths that do not exist — so they are dropped by the `isfile` check, not by the stdlib path check, which never fires. The `isfile` test must therefore stay *before* the containment test, or a Base frame resolved under `pwd()` would be accepted.

### Sandbox, and the bug it found

Added `sandbox/` — a `ToySimulator` implementing `AbstractSimulator` over closed-form logistic growth, plus four numbered scripts meant to be run in *separate* sessions so recovery-without-IDs is demonstrated rather than described. Nothing spawns a subprocess, but every real code path runs against a real SQLite database.

It found a bug on first use, in the exact snippet the manual documents:

```julia
df = simulationsTable()
tag!(df[df.final_population .> 1_000, :SimID], "verdict" => "runaway_growth")   # MethodError
```

`simulationsTable` yields `SimID` as `Vector{Union{Missing,Int64}}`, which does not match `AbstractVector{<:Integer}`, so `tag!` had no applicable method. Retroactive tagging off a query result is the *primary* user-facing path for this feature — and the whole test suite missed it, because every test built ID vectors from `simulationIDs` (a clean `Vector{Int}`) rather than from a table.

`deleteSimulations` had already solved this: it takes `AbstractVector{<:Union{Integer,Missing}}` and filters. `tag!`/`untag!` now do the same. Since `Vector{Int} <: AbstractVector{<:Union{Integer,Missing}}`, one signature covers both with no ambiguity.

The lesson worth keeping: the docs example was right and the code was wrong, and no amount of reviewing either in isolation would have shown it. It took running the documented workflow against a real project.

### Copilot review on PR #23

Seven comments (four inline, three suppressed as low confidence). **Six were correct**, including one genuine bug the local test suite could not have caught.

**Provenance was back-filled onto reused objects.** `applyCreationTags` ran on the reuse branch of `Monad`, `Sampling`, and `trialID`, relying on `WHERE provenance_id IS NULL` to make it a no-op. That guard holds for objects created since this feature — but an object from a project that *predates* the provenance columns has a legitimately null `provenance_id`, so re-creating its configuration stamped today's session, script, and git state onto an object created months earlier, and `mm:created` reported today. Now stamped only on the branch that actually inserts.

Why the suite missed it: the upgrade test checked a legacy *simulation*, and simulations are never reused — every one is a fresh `INSERT`. Only monads, samplings, and trials take a reuse path, and no test combined "legacy null provenance" with "reused". Both conditions are now covered.

**Three stale PRD bullets**, all self-inflicted: one referenced `applyRunTags` and one `withTags`, functions deleted two revisions earlier, and a third read "The accessor is `tags`, not `tags`" — the blanket `trialTags` → `tags` revert regex rewrote both halves of the contrast. A reminder that a mechanical rename needs a read-through afterwards, not just a passing test suite.

**One comment was wrong.** It claimed `_reservedTagKey("mm:")` throws `BoundsError` by slicing past the end of the string. Julia's `"mm:"[4:end]` is a valid empty slice returning `""`, which flows into `_validateTagKeyBody` and raises the intended `ArgumentError`; verified across `"mm:"`, `"MM:"`, `"mm: "`, and `"mm:."`. The assumption is reasonable if you expect Python- or Rust-like slicing semantics, so the behavior is now pinned by a test rather than left to be re-litigated.

### Critic pass over the finished change

A deliberate review of the whole diff at the end, rather than trusting the incremental one. Eight issues found, all in code added this session; all fixed.

**Scale bugs in the query paths.** These would not show up in a test project and would have bitten only at the 10⁵–10⁶ sizes the design was written for:
- `findSimulationIDs` ran `Set(simulationIDs())` on every call — a full `SELECT` of every simulation id, just to intersect a handful of matches against it. Replaced with one query bounded by the match. It also folds in the `status` filter, which was a second full scan.
- `tagsTable()` (default `include_auto=true`) synthesizes one row per object per `mm:` key, so a million-simulation project would build ~5M `NamedTuple`s. Now guarded by `MAX_MATERIALIZED_TRIALS`, with the per-object form and `include_auto=false` left unbounded.
- `_maybeShowRecoveryHint` ran `COUNT(*)` with a `LIKE` over the whole `tags` table on *every* `findSimulationIDs` call, forever: it only latched when it decided to show the hint, so the common case (user has tags) never stopped probing. Now latches before deciding and uses `LIMIT 1`.
- `appendTags!` walked a parent's constituent CSVs once per tag row rather than once per parent, so a sampling with ten tags read its CSVs ten times. Memoized.

**Leftovers from the reverts.** A `let` block in `Sampling` that existed only to scope the removed transaction closure; a comment on `applyCreationTags(Monad, …)` still explaining behavior in terms of "a new ambient scope", a concept deleted two revisions earlier; and `_tagClassType`, dead since the query layer stopped mapping class strings back to types.

**Test gap.** The "no migration milestone" claim was only tested for the `tags` *table*. The `ALTER TABLE` path — the harder half — was not. Extended to drop both new tables *and* the added columns, reinitialize, assert everything returns, run it twice for idempotence, and check that objects predating the upgrade (null provenance) still read and query correctly rather than throwing.

**Definition of Done.** `appendTags!` was exported without a usage example.

Also verified rather than assumed: every concrete claim in `docs/src/man/tagging.md` was executed against a live project — basename and full-path `mm:script` matching, key lowercasing, value trimming, length and namespace rejection, multi-valued keys, bare labels, idempotent re-tagging, inheritance on and off, AND/OR composition, the `tag:` column prefix, `|`-joined multi-values, `missing` for untagged rows, and the `limit` guard. All 22 passed.

### Third revision after design review (same session)

**The accessor stays `tags`.** It was briefly renamed to `trialTags` over a masking concern and reverted on preference for the shorter name. The concern was real and is recorded so it is not rediscovered from scratch: Julia 1.12 lets a top-level assignment shadow a `using`-imported binding *silently* — verified, including after the function has already been called — so a user writing `tags = [...]` gets no error, just "objects of type Vector are not callable" from every later `tags(sim)`. The workaround if it ever bites is `ModelManager.tags(sim)`. No other export carries comparable risk: the rest are compound (`tagsTable`, `tagKeys`, `findSimulationIDs`) or end in `!`.

**`_withOptionalTags` folded into `_createTrial`.** It wrapped exactly the two call sites that immediately invoked `_createTrial`, so it was a layer with no second consumer. `_createTrial` now takes `tags`, resolves provenance, delegates construction to `_buildTrial`, and tags the result — one entry point for every `createTrial` overload.

**Provenance is first-writer-wins, deliberately.** `applyCreationTags` sets `datetime`/`provenance_id` only `WHERE provenance_id IS NULL`, so an object records the context that *created* it, not the last one to touch it. Verified end to end: script A creates a monad with 2 replicates, script B later grows it to 5 — the monad and the first two simulations keep A, the three new simulations get B. Later work is therefore not lost, it is attributed to the objects that were actually created; this only works because provenance is per-object rather than inherited from the monad (the design rejected in the second revision). Locked in by a regression test.

**Batched `run` tags the constituents, not the container — a durability choice.** Reviewed on the observation that inheritance would carry a tag on the umbrella `Trial` down to everything beneath it, making per-constituent tagging look redundant. It is not: the umbrella is deduplicated plumbing, and `deleteTrial(id; delete_subs=false)` removes it without touching its constituents. Measured both ways — with the tag on the constituents, the query still returns all four simulations after the umbrella is deleted; with it on the umbrella alone, the query returns nothing. `hasTag(lo, ...)` is also false in the umbrella case, right after the caller "tagged" `lo`. General rule: a container too ephemeral to be worth labelling is too ephemeral to be a label's only home. Both properties are now pinned by tests.

**Sensitivity labelling moved before the run.** `mm:method` was being applied to `gsa_sampling.sampling` after `runSensitivitySampling` returned — after every simulation had already finished, which loses the label on an interrupted sweep and leaves an in-flight analysis unqueryable by method. All three GSA methods shared an identical `Sampling(...)` + `run(...)` pair, so that became `buildAndRunSensitivitySampling`, which labels between the two. One call site instead of three, and the tag now lands before dispatch like every other tag in the system.

**`BEGIN EXCLUSIVE` replaces the ReentrantLock.** The lock added in the previous round was justified with a claim that turned out to be wrong: SQLite.jl's do-block `transaction(f, db)` issues a named **SAVEPOINT**, not `BEGIN`, so it nests fine and concurrent tag writes would not have thrown "cannot start a transaction within a transaction". (It also sets `PRAGMA synchronous = OFF` for the duration, which is a durability downgrade worth knowing about.) A real `BEGIN EXCLUSIVE` needs `SQLite.transaction(db, "EXCLUSIVE")` plus manual commit/rollback — the pattern `initializeDatabase` already used.

`withExclusiveTransaction` checks `SQLite.intransaction` and joins an enclosing transaction rather than nesting, so committing inside a caller's transaction can't end it early.

It was initially applied to every write, then narrowed to `Sampling`/`trialID`, and finally **removed entirely**. The full reasoning, because the end state looks like "we did nothing" and the next person should know it was a decision:

| Site | Pattern | Outcome |
|---|---|---|
| `Sampling`, `trialID` | scan, then insert; **no `UNIQUE`** | **No transaction** — see below. |
| `Monad` | `INSERT OR IGNORE` + lookup, `UNIQUE` | **No transaction.** The write comes first and is atomic; `UNIQUE` self-corrects. |
| `_resolveProvenanceID` | `INSERT OR IGNORE` + lookup, `UNIQUE` | **No transaction.** Same, and nothing ever deletes from `provenances`. |
| `_insertTagRows` | N × `INSERT OR IGNORE` | **Plain transaction**, for batching only — one commit instead of N on a large retroactive `tag!`. |

`EXCLUSIVE` earns its place only when a *read decides a subsequent write* and must still hold when that write lands, since it takes the write lock at `BEGIN` rather than at first write. A single statement is already atomic, and `INSERT OR IGNORE` against a `UNIQUE` constraint is self-correcting — the loser's lookup finds the winner's row. `samplings` and `trials` are the only identity-defining tables without such a constraint, so they were the only genuine candidates.

**Why they were dropped anyway.** Their critical section scans constituent-ID **CSV files on disk** before inserting. Holding the database write lock across that turns a microsecond window into a hundred-millisecond one, which then required a `busy_timeout` pragma (`openCentralDB`, `DB_BUSY_TIMEOUT_MS`) so a second session would wait rather than die with `"database is locked"` — verified experimentally: 0.1 s hard failure without it, 2 s wait-then-succeed with it. That is a lot of machinery, and a database lock held across file I/O, to protect a workflow we have already decided not to support. Reverting leaves the pre-existing behavior, which was working.

**If duplicate or inconsistent rows ever appear in `samplings` or `trials`, this is the answer**: wrap the find-or-insert in `withTransaction(mode="EXCLUSIVE")` in `Sampling(monads, inputs)` (`classes.jl`) and `trialID(samplings)` (`classes.jl`), and add `PRAGMA busy_timeout` where the central connection is opened. The `mode` keyword on `withTransaction` was kept precisely so this is a one-word change.

What this does and does not buy, stated plainly because the two are easy to conflate:
- **Does**: serialize against other *processes* sharing the project — concurrent HPC array jobs, a second REPL. That is the realistic hazard for this package.
- **Does not**: serialize *tasks within one session*. SQLite locks are per-connection and ModelManager shares one connection, so `BEGIN EXCLUSIVE` is invisible to sibling tasks.

Concurrent trial creation in a session therefore remains unsupported, by decision rather than oversight: `recordConstituentIDs` is read-modify-write on a CSV file, entirely outside SQLite's reach, and guarding it would mean a coarse lock across all of creation for a workflow nobody needs (creation is cheap next to simulation). Documented as a warning instead of engineered around.

### Second revision after design review (same session)

Eight further issues raised; all addressed. The first two collapsed most of the machinery built in the first revision.

**Ambient scope removed entirely — tags are a keyword argument.** The reviewer's question was simply "can't we pass the tags as a kwarg into `run` and `createTrial`?" and the answer is yes, which deletes `withTags`, `@tag`, task-local storage, `_withReservedTags`, the TTL clock, and every threading hazard along with them. `createTrial(...; tags=...)` now means "construct, then `tag!` the result", and inheritance already covers the constituents. The framework's own `mm:method`/`mm:calibration` tags work the same way via `tagReserved!` on the returned sampling. Two rounds of design were spent building a scope mechanism whose only advantage was reaching objects created inside a user's own helper function — which that helper can expose as its own `tags` kwarg.

**Provenance moved from tag rows to columns.** With a migration accepted, `simulations`/`monads`/`samplings`/`trials` each gained `datetime` and `provenance_id`. Measured cost per object across the three designs:

| Design | Bytes/object | 10⁶ sims |
|---|---|---|
| Six tag rows (v1) | 1139 | 1.14 GB |
| Two tag rows, normalized (v2) | 290 | 290 MB |
| Two columns (v3, current) | 21 | 21 MB |

The reviewer suggested a `datetimes` lookup table; that does not help, because a pointer costs about as much as the timestamp it points at. What wins is that a column in an already-existing row carries no index and no per-fact row overhead. Still no migration milestone: `ensureProvenanceColumns` `ALTER TABLE`s from `createSchema` guarded by `columnsExist`, so PCMM implements nothing.

**Terminology.** "Rows" was used throughout without ever explaining that `tags` is entity-attribute-value, so "`mm:created` costs one row per object" read as nonsense — a reader reasonably pictures a row as an object and a fact as a column. Recorded here because it is the crux of why the EAV design was expensive: each *fact* is a row plus two index entries, whereas a column is bytes in a row that already exists.

**Other fixes in this round.**
- `Simulation(::Int)` now delegates to `simulationsFromIDs`, with `_simulationFromRow` as the single place that decodes a row.
- `mm:script` and `mm:script.path` collapsed to one field. The basename is derivable, and queries match either form.
- The launching script is resolved per call rather than cached per session, so a session that `include`s several scripts attributes each correctly. Frame filtering relies on `isfile` alone rather than sniffing for `REPL[`: that rejects every front-end's pseudo-file — REPL inputs, IJulia `In[3]`, Pluto cell ids — without enumerating them. `isinteractive()` cannot substitute for this filter (it is session-level, the filter is frame-level) and must not short-circuit the walk, or an interactive session that `include`s a script would lose the attribution. With no attributable file it reports `"interactive"` or `"unknown"` from `isinteractive()`, rather than labelling every such case a REPL — `julia -e` and notebook kernels are not REPLs, and a false script attribution defeats the point of recording one.
- Git state is read at each `createTrial`/`run` call. The TTL clock added in the previous round was unnecessary once the check moved off the per-object path.
- `PROVENANCE_TTL_SECONDS` and `MAX_MATERIALIZED_TRIALS` are no longer exported. They had been exported only to satisfy a Documenter `@ref`, which is not a reason to widen the public API; the manual now states the number in prose instead.
- Docstrings audited for design rationale that belongs in `#!` comments. Users do not need to know why `tag_value` defaults to `''` rather than `NULL`, or that a basename column was considered and rejected.

### First revision after design review (same session)

Six issues raised on review; all addressed. Two were mistakes on my part.

**Corrected: the "4–6 rows per simulation" claim was wrong.** `mm:created` is *one* row per object, written once. The 4–6 was the whole provenance set (`mm:created`, `mm:session`, `mm:script`, `mm:script.path`, `mm:git`, `mm:git.dirty`) and I misattributed the total to `mm:created` alone. The correction matters because it hid the real problem: five of those six are **identical for every object in a session** and were being duplicated per simulation.

**Corrected: the storage estimate was ~5× too low.** I said "~20 MB at 10⁵ simulations". Measured (SQLite file size after `VACUUM`, 10⁵ objects, realistic values):

| Scheme | Bytes/object | 10⁵ sims | 10⁶ sims |
|---|---|---|---|
| Six provenance rows (original) | 1139 | 114 MB | 1.14 GB |
| Two rows: timestamp + pointer (now) | 290 | 29 MB | 290 MB |
| Pointer only (hypothetical) | 122 | 12 MB | 122 MB |

The original estimate counted payload only and ignored that every tag row is stored three times — the table, the `UNIQUE` index, and the `(tag_key, tag_value)` lookup index.

**Provenance is now normalized.** A `provenances` table holds one row per distinct creation context (session + script + script_path + git_commit + git_branch + git_dirty, `UNIQUE` across all six), and each object carries a single `mm:provenance => <id>` tag. The *presented* model is unchanged: the pointer is expanded back into the virtual `mm:script`/`mm:git`/… keys by `tags`, `tagsTable`, `appendTags!`, `tagKeys`, and `tagValues`, and `findTrials` translates a virtual-key filter into a provenance lookup. Every pre-existing test passed unmodified after the change, which is the evidence that the abstraction holds.

Rejected: **attaching provenance to monads and letting simulations inherit it.** Proposed as the cheapest option (~25 MB at 10⁶), but it is wrong — simulations can be added to an existing monad in a later session, which would stamp the original session's script and git commit onto simulations created months afterwards. Provenance must attach at the moment of creation, which means per object.

**Scope moved to task-local storage.** The scope stack was a field on `mm_globals()`; `Threads.@threads` over `withTags` blocks would interleave pushes and pops and mis-attribute tags. Task-local storage fixes that. It does *not* inherit into tasks spawned inside a scope, which is why the explicit keyword path matters — see below. Worth noting separately: `centralDB()` is a single shared handle, so concurrent `createTrial` may be unsound for reasons unrelated to tags; that was not investigated.

**`@tag` macro added.** When it wraps a direct `createTrial`/`run` call it rewrites to the existing `tags=` keyword — no ambient state at all, correct under any threading. Anything else falls back to a `withTags` scope, which still reaches objects created inside functions the expression calls. The macro is not merely sugar for `withTags`: the rewriting branch is the thread-safe path. Hygiene detail: the generated code is escaped into the caller's scope, so internal helpers are referenced via `GlobalRef(@__MODULE__, …)`, which survives the escape.

**Git state is now re-checked per command, not per session.** Files change constantly during a session, so a once-per-session resolution attached stale commits and dirty flags to everything created afterwards. `maybeRefreshProvenance!` runs on entry to `createTrial`/`run`/`withTags`, throttled by `PROVENANCE_TTL_SECONDS = 5`; the per-object path (`currentProvenanceID`) only reads the cache. A changed git state naturally produces a new `provenances` row via the `UNIQUE` constraint. Per-object re-checking was rejected outright — `LibGit2.isdirty` walks the working tree.

**Switched to `LibGit2`** (explicitly approved, so the CLAUDE.md no-new-dependencies rule is satisfied). `LibGit2.GitRepoExt` discovers the repo from a subdirectory and works correctly inside a git worktree, which the shell-out version also did but less directly. Also now captures the branch (`mm:git.branch`).

**Result-set guards.** `findSimulations` previously did `Simulation.(ids)`, one `SELECT` per object — a million-element result meant a million queries. Added `simulationsFromIDs` (one query) and a `MAX_MATERIALIZED_TRIALS = 10_000` guard on every object-returning finder, overridable via `limit`. The ID-returning forms stay unbounded, since a tag on a `Trial` legitimately expands to everything beneath it and IDs are cheap.

### Open questions
- **Orphaned `provenances` rows** are never cleaned up when the last object referencing them is deleted. Bounded by session count, so small, but `orphanedTagCounts` does not report them.
- **Concurrent `createTrial` is unsupported, in-session or across sessions.** Two Julia sessions cannot corrupt the SQLite file — SQLite serializes writers itself — but they can produce duplicate `samplings`/`trials` rows, and they race on the constituent-ID CSVs, which no database lock covers. See the remedy noted above if it ever surfaces.
- **Exact-value queries on `mm:created` compare the stored string**, so a `Trial` whose stored stamp is the legacy `yymmddHHMM` will not match an ISO-8601 filter even though `tags(trial)` displays ISO. Resolved by the v0.9.0 item below; range queries on the table are the better tool regardless.

- **If the `EXCLUSIVE` remedy is ever applied, the `busy_timeout` half has a trap.** The pragma is per-connection state, not a database property: measured, it is not shared with a second connection to the same file and is reset to `0` by a close/reopen. ModelManager opens the central connection twice — `initializeModelManager` and then `initializeDatabase`, which closes and reopens it — so setting the pragma at the first site is silently undone by the second. Route both through one `openCentralDB(path)` wrapper. Recorded in `CLAUDE.md` alongside the remedy itself.

### Targeted for v0.9.0 (breaking-changes release)

- **Move the `datetime` columns to INTEGER unix seconds** on `simulations`, `monads`, `samplings`, and `trials`, and normalize the legacy `trials.datetime` (`yymmddHHMM`) with them. Saves a few bytes per object and makes range queries natural, but any user code already reading `trials.datetime` as a string would break — which is why it waits for a release that permits that. Doing so also removes `_normalizeStamp` and the read-time special case it exists for.
- **Calibration generation tagging covers the ABC-SMC batch path only.** `resumeABC` goes through the same `_buildEvaluateBatch`, so it is covered, but this was not explicitly tested.
- **Should `reinitializeDatabase` be exported?** It is user-facing and documented but not in the export list; the new test had to qualify it. Pre-existing, unrelated to tagging.
- Wiring tag-based selection into the calibration/GSA entry points (e.g. seeding a `SimulationBank` from a tag query) is not done.

---

## Session: GSA sensitivity plot recipes (2026-06-17)

### Goal
The calibration result objects have `RecipesBase.jl` recipes (`src/calibration/visualize.jl`), but the GSA sampling results (`MOATSampling`, `SobolSampling`, `RBDSampling`) had none. Add bar-chart recipes mirroring SmoreGSA's `SensitivityResult` recipe, plus richer MOAT visualizations.

### Design decisions

**New file `src/sensitivity_visualize.jl`**, included after `sensitivity.jl`. Parallels `calibration/visualize.jl`. `RecipesBase` is already a direct dep, so recipes live in-package (not in an extension like SmoreGSA, which keeps Makie/Plots out of its core deps — ModelManager already committed to the in-package approach for calibration).

**Internal plot-data wrappers + builders take `(results, monad_ids_df, …)`, not the `GSASampling`.** This is the key testability decision: constructing a real `MOATSampling`/etc. requires a `Sampling` (and a live SQLite project). By having the user-facing recipe extract `m.results`/`m.monad_ids_df` and delegate to a builder (`_moatBarData`, `_sobolBarData`, …) that returns a lightweight wrapper (`_GSABarData`, `_GSAViolinData`, `_GSAScatterData`), the tests fabricate `GlobalSensitivity.MorrisResult`/`SobolResult` objects + a plain `DataFrame` and call `RecipesBase.apply_recipe` directly — no DB, no simulations. Same `_CornerPlotData` pattern as calibration.

**One series per sensitivity function**, iterated in `_gsaFunctionLabel`-sorted order (the `results` Dict order is otherwise unspecified → nondeterministic legends). Labels prefix the function name only when `length(results) > 1`, matching SmoreGSA's `multi_out` convention.

**Parameter names from `monad_ids_df` columns**, dropping the per-method bookkeeping columns: `base` (MOAT, index 1), `A`/`B` (Sobolʼ, indices 1–2), none (RBD). These align with the index-vector ordering already established in `sensitivity.jl` (`perturb_headers`/`focus_indices`).

**MOAT got three styles** (user request beyond the SmoreGSA bar-only Morris recipe), dispatched via a `style::Symbol` positional like calibration's `plot(result, :transition)`:
- `:bar` (default) — µ* bars; `show_sigma=true` adds σ = `sqrt(variances)` whiskers via the `yerror` attribute. `_GSABarGroup` carries an optional `yerror::Union{Nothing,Vector}` for this.
- `:violin` — distribution of `elementary_effects` (the full `n_base × d` matrix MorrisResult already stores) per parameter. Emits `seriestype := :violin`; resolved by the backend (StatsPlots) at plot time, so no new dep.
- `:scatter` — classic Morris µ*–σ screening plot, one point per parameter. Parameter names are placed via offset `annotations` (nudged 2% of the axis span, anchored `:left,:bottom`) rather than `series_annotations`, which centers text on the marker and overlaps it.

**Sobolʼ `show_ST=true`** overlays ST at `fillalpha=0.45` (matches SmoreGSA). RBD is first-order bars only. Both reuse the shared `_GSABarData` recipe.

### Rejected / considered
- **Three independent recipes with duplicated styling** — rejected in favor of the shared `_GSABarData` recipe so xlabel/ylabel/legend/`:bar` styling stays consistent and the bar logic is written once.
- **Putting recipes in an `ext/` extension (SmoreGSA style)** — unnecessary here since `RecipesBase` is already a hard dep and the calibration recipes set the in-package precedent.

### Files changed
- `src/sensitivity_visualize.jl` — new file: shared helpers, `_GSABarData`/`_GSAViolinData`/`_GSAScatterData` wrappers + recipes, builders, and the five user-facing `@recipe`s (MOAT bar/violin/scatter, Sobolʼ, RBD)
- `src/ModelManager.jl` — `include("sensitivity_visualize.jl")` after `sensitivity.jl`
- `test/runtests.jl` — `using RecipesBase` + `import GlobalSensitivity`; module-level `_gsa_fA`/`_gsa_fB` keys; `@testset "GSA plot recipes"` (series counts, σ whiskers, param-name extraction, empty-results errors)
- `README.md`, `PRD.md` — sensitivity visualization documented

### Open questions
- None. Violin requires a `:violin`-capable backend (StatsPlots); documented in the docstring rather than adding a dep.

---

## Session: documentation rework + logo (2026-06-17)

### Goal
Replace the monolithic single-page docs (a 16-line `index.md` with one undifferentiated `@autodocs` dump) with a structured manual + API reference, mirroring the revamped PhysiCellModelManager.jl docs, and add a project logo.

### What was done
- **Structure.** `docs/make.jl` rewritten with a `man/` (narrative manual) + `lib/` (per-source-file `@autodocs`) split, `collapselevel=1`, and `checkdocs=:exports`. Sidebar: Getting Started → Core Concepts → Varying Parameters → Uncertainty Quantification → Building a Simulator Backend → Reference → Index.
- **Manual pages** (full prose, `docs/src/man/`): overview, installation, trial hierarchy, project configuration, database, running simulations, HPC, variations, space-filling designs, sensitivity analysis, calibration, building a simulator backend, managing data; plus `misc/database_upgrades.md`. Audience is backend authors + advanced users (ModelManager has no simulator of its own), so examples assume an initialized backend.
- **API pages** (`docs/src/lib/`): one page per `src/*.jl`, `Public`/`Private` split; calibration aggregates all `src/calibration/*.jl`; alphabetical `@index` page.
- **Logo.** 3D extruded gear-disc database in Julia colors (green/red/purple) — three stacked gears as the DB discs (mechanistic-modeling motif), kin to the PCMM concentric-circle logo. `docs/src/assets/logo.svg` (mark) + `logo-hero.svg` (mark + wordmark). Generated via script (gear path + drop-extrude trick).

### Key decisions / gotchas
- **`CurrentModule = ModelManager` on every man/misc page.** Without it, `@ref`s to *non-exported* symbols (`runSimulation`, `prepareTrialHierarchy`, …) resolve against `Main` and fail; exported symbols resolved fine, which masked the issue at first.
- **Documenter `Pages` filter is a path *suffix* match.** `Pages = ["utilities.jl"]` also matched `xml_utilities.jl`, double-documenting every XML symbol ("duplicate docs" errors). Fixed by using `Pages = ["/utilities.jl"]` on `lib/utilities.md`.
- **Distinct `lib/` page titles.** Several lib titles collided with man H1s (Variations, Project configuration, HPC support, Sensitivity analysis, Database upgrades), making `@ref` ambiguous. Renamed lib pages (e.g. "Variations & designs", "Schema migrations", "HPC & SLURM", "Sensitivity analysis (GSA)"). The two "Calibration" pages use explicit `@id`s (`calibration_man`, `calibration_lib`).
- **Multi-word header refs quoted** as `@ref "Header Title"`.
- Build verified green locally (`julia --project=docs docs/make.jl`, EXIT=0). Only a size-threshold *warning* on the aggregated `lib/calibration.md` (10 source files) — under the hard limit.

### Open questions
- `lib/calibration.md` could be split if it later crosses the hard size threshold.

### Resolved in follow-ups
- Added docstrings to the four exported `Add*VariationsResult` structs (`checkdocs=:exports` doesn't flag undocumented exports, so they had rendered blank).
- De-duplicated the `runCalibration` docstring (interface stub vs. ABCSMC method).
- Renamed the "Experiments" sidebar group to "Uncertainty Quantification".
- Variation examples now wrap targets in `XMLPath(...)` — ModelManager constructors require an `XMLPath`, not a bare `Vector{String}` (keeps the core format-agnostic).

---

## Session: calibration progress reporting (2026-06-17)

### Goal
A calibration run printed nothing between the end of JIT compilation and the completion of generation 1 — a long silent window for slow simulations. Add console feedback at multiple granularities.

### Problem diagnosis
- `evaluate_batch` calls `run(sampling; quiet=true)` (`abc.jl`); `quiet=true` suppresses *all* per-simulation/per-trial output in the runner.
- The only calibration log (`@info "ABC-SMC generation t: ..."`) fires *after* a generation completes (`abc_smc.jl`).
- So all wall-time inside a generation's `run()` call is silent.

### Key Design Decisions

**Tiered verbosity, not a boolean.** `progress::Symbol` on `runABC`/`runCalibration`/`resumeABC` with stacked levels `:none < :generation < :batch < :bar`, plus `:auto`. Rejected a simple `verbose::Bool` because HPC/SLURM (redirected, non-TTY) logs want textual milestones but *not* a carriage-return progress bar. `:auto` resolves to `:bar` on a TTY and `:generation` otherwise — the right default for both interactive and batch contexts. Runtime-only; deliberately **not** persisted to `method.toml` (it's an I/O preference, not an algorithm setting, and resume should be free to choose its own).

**Generic `on_progress` hook on `run`, not calibration-aware progress in the runner.** `run` gains `on_progress::Union{Nothing,Function}=nothing` and emits `:init`/`:step`/`:finish` events from its existing single-threaded `take!(result_channel)` completion loop (which already fires once per completed sim, identically for local and `sbatch --wait` HPC). The runner learns nothing about calibration — it just emits ticks. When `on_progress === nothing` the runner is byte-for-byte unchanged, so every existing caller and test is unaffected (verified: 914 passing). Rejected putting a `ProgressMeter` directly in `run` because that would couple the simulator-agnostic runner to a calibration-rendering concern and the bar would lack generation/batch framing.

**Bar sized inside `run`, framed outside.** The bar's total = the batch's *pending* simulation count, which only `run` knows (after `pendingSimulationSpecs`). So the renderer is built in the calibration layer (with the gen/batch label as `desc`) but receives its size via the `:init` event. Zero-pending batches (all monads reused) create no bar.

**ProgressMeter imported qualified.** `using ProgressMeter: next!` shadowed `Sobol.next!`, breaking `_runFirstGeneration`'s SobolSeq iteration (caught by the test suite — `MethodError: no method matching next!(::SobolSeq)`). Switched to `import ProgressMeter` + qualified `ProgressMeter.next!`/`.Progress`/`.finish!`. Lesson: prefer qualified import for any package whose exported names (`next!`, `update!`, `finish!`) are likely to collide.

**New dependency:** ProgressMeter.jl (approved), compat relaxed to `"1"`.

### Tests added (12 new, 914 passing)
- `calibration progress verbosity` — rank ordering, `_resolveVerbosity` pass-through + `:auto` + `ArgumentError`, `_batchProgressCallback` returns `nothing` below `:bar`, full bar lifecycle including zero-pending no-op.
- `run on_progress hook` (DB-backed) — `:init` first, `:finish` last and once, init size and step count both equal `n_scheduled`.
- `runCalibration progress levels` (DB-backed) — all four explicit levels run end-to-end; invalid setting throws before any work.

### Files
- New: `src/calibration/progress.jl` (included first in `calibration.jl`).
- `src/runner.jl` — `on_progress` hook.
- `src/calibration/abc_smc.jl` — `verbosity` kwarg on `_runABCSMC`, gen-start log, gated gen-end/stop logs.
- `src/calibration/abc.jl` — `progress` kwarg threaded through `runCalibration`/`runABC`/`resumeABC`; `_buildEvaluateBatch` tracks per-gen batch index, logs batch start, passes `on_progress` to `run`.

---

## Session: feature/latent-inverse-maps — Visualization, resume robustness, LatentVariation enhancements (2026-05-17)

### Goal
Ship posterior visualization recipes, harden `resumeABC`, and extend `LatentVariation` with user-facing `target_names` and `inverse_maps` for LVSource calibration parameters.

### Key Design Decisions

**`LatentVariation.target_names` for LVSource display**
Added `target_names` field to `LatentVariation` (already existed on `DVSource`/`CVSource` auto-constructed LVs). User-supplied `LatentVariation`s can now name their target columns, which appear in display CSVs and the `parameters.toml` mapping. Persisted under `"target_display_names"` in the LVSource TOML entry.

**`inverse_maps` scope**
For `DVSource`/`CVSource`, `inverse_maps` are auto-constructed at `LatentVariation` creation (always present). For user-supplied `LatentVariation` (`LVSource`), `inverse_maps` is optional — omitting it disables simulation bank lookup for that parameter. When supplied, `_validateInverseMaps` checks round-trip accuracy at construction time. This unifies the bank-lookup path (`_bankCdfCoords`) across all source types without requiring users to implement inverses they don't need.

**`_validateStructuralMatch` for LVSource**
`resumeABC` previously crashed on `LVSource` parameters with "Unexpected saved source type". Added the `elseif src isa LVSource` branch matching on `latent_parameter_names`, target column names, `target_names`, and `lv.name`. The `_StrippedLVSource` path (anonymous functions stripped at save time) was already handled; the non-stripped path was missing.

**Scan-based `_loadGenerations`**
Changed from tag-construction loop (`generation_$(lpad(t, ndigits, '0')).csv`) to directory scan + parse. Fixes resume when `max_nr_populations` changed between the original run and `resumeABC`. Tags with any zero-padding are found correctly.

**`generation_cdfs/` as subdirectory of `generations/`**
The save side was already using `joinpath(generations_dir, "generation_cdfs")` (single-dir form). The load side (`_findLastGenerationCSVs`, `resumeABC`) was incorrectly computing `generation_cdfs/` as a sibling of `generations/`. Fixed by making both sides use `joinpath(calibrationFolder(c), "generations", "generation_cdfs")` consistently.

**Posterior visualization via RecipesBase**
Four recipes added to `visualize.jl`. All use `RecipesBase.@recipe` so they work with any Plots.jl backend without a hard dependency. Key decisions:
- `_safeKDE1D`/`_safeKDE2D` guard against zero-variance inputs (collapsed posteriors, test data) — return a synthetic spike or `nothing` rather than crashing or producing unsorted GKS output.
- Rejected proposals for the `:transition` plot are lazily loaded from disk (`generation_{t+1}_monads.csv` → subtract accepted IDs → `simulationsTable(short_names=false)`). Requires `inverse_maps` to convert display values back to CDF space for `:cdf` display; falls back gracefully to accepted-only if maps unavailable or monads file absent.
- `short_names=false` kwarg added to `simulationsTable` / `locationVariationsTable` / `appendVariations` so the transition-plot loader gets raw XML-path column names matching `parameters.toml` keys. The variation ID column is always renamed regardless of `short_names`.

**Removed: `_reconstructCDFFromDisplay` and `_loadGenerationsFromDisplay`**
Initially added as a fallback for resuming calibrations whose `generation_cdfs/` directory was missing (old code path). Removed because: (a) `generation_cdfs/` has always been written since the dual-CSV output feature shipped, so no real user is affected; (b) correct reconstruction for DVSource required `inverse_maps` (not the latent prior, which is `Uniform(0,1)` internally), making the code non-trivial and the added surface area unjustified.

### Tests added (feature/latent-inverse-maps, 818 passing)
- `_validateStructuralMatch` — 6 new LVSource (non-stripped) cases
- `generation persistence` — cross-padding test (save max_pops=10, load max_pops=5)
- `resume path` — verifies `_loadGenerations` reads raw CDF coords from `generation_cdfs/`, not display values

### Status
Branch `feature/latent-inverse-maps` is ready to merge. MM version bumped to `0.7.0`. PCMM CI is failing because `0.7.0` is not yet registered in BergmanLabRegistry — register it after merging to `main`, then re-run PCMM CI.

---

## Session: Phase 2b — Populate ModelManager with generic infrastructure (2026-04-12)

### Goal
Extract all simulator-agnostic code from PCMM into ModelManager so that future simulator packages (new Julia ABM frontends) can build on the same infrastructure without duplication.

### Key Design Decisions

**Global state cross-package pattern**
ModelManager cannot default `simulator` to `PhysiCellSimulator()` because it doesn't know about PCMM. Solution: `mm_globals_ref = Ref{Union{Nothing,ModelManagerGlobals}}(nothing)` — PCMM sets it in `__init__`. Accessing `mm_globals()` before initialization asserts and throws a descriptive error.

**`postSimulationProcessing` placement**
User requested: "pruner.jl should just be an interface for post-simulation processing. PCMM should own the pruner.jl logic and classes." Decision: ModelManager gets only a no-op stub `postSimulationProcessing(sim, proc; kwargs...)`. PCMM implements `postSimulationProcessing(::PhysiCellSimulator, proc; prune_options=PruneOptions())`.

**`run` signature generalization**
Old PCMM: `run(T; prune_options::PruneOptions=PruneOptions())`. New ModelManager: `run(T; force_recompile=false, kwargs...)` where `kwargs` forwarded to `postSimulationProcessing`. PCMM then picks up `prune_options` from `kwargs` in its implementation.

**`addVariationRows` as an interface method**
The actual DB writes for variation rows (adding columns, inserting values, handling `par_key`) are PhysiCell/XML-specific (`addColumns`, `ColumnSetup`, `setUpColumns`). ModelManager defines the interface stub `addVariationRows(sim, inputs, reference_variation_id, loc_dicts)` and PCMM implements it.

**`variationLocation` dispatch**
Old PCMM called `variationLocation(xp::XMLPath)` directly. New ModelManager dispatches on the simulator: `variationLocation(mm_globals().simulator, target)`. PCMM implements `variationLocation(::PhysiCellSimulator, xp::XMLPath)` with the PhysiCell path-prefix logic.

**`insertFolder` hooks**
Two PCMM-specific behaviors in `insertFolder`: (1) reading `metadata.xml` for a description, (2) calling `prepareBaseFile` for initial setup. Replaced with `getInputFolderDescription(sim, path)` (default `""`) and `initializeInputFolder(sim, input_folder)` (default no-op).

**`columnName` placement**
`columnName(xml_path::Vector{<:AbstractString}) = join(xml_path, "/")` is defined in PCMM's `configuration.jl`. Moved to `ModelManager/src/variations.jl` as it is a generic utility for XMLPath column naming.

**`SobolMM` alias**
PCMM uses `SobolPCMM` as an ASCII alias for `Sobolʼ`. ModelManager uses `SobolMM` as the ASCII alias instead, since `PCMM` in the name would be wrong for a generic package.

**`locationPath` overloads for `InputFolder` and `AbstractSampling`**
These overloads use types defined in `classes.jl`, which is included after `project_configuration.jl`. Moved them: `locationPath(input_folder::InputFolder)` goes to `classes.jl`; `locationPath(location, S::AbstractSampling)` also goes to `classes.jl` (right after `AbstractSampling` is defined).

**`database_utils.jl` simplification**
Original `database_utils.jl` had full implementations of `queryToDataFrame`, `tableExists`, `tableColumns`, `columnsExist`. These were needed before `globals.jl` existed (no `centralDB()` default). Now that `database.jl` provides these with `centralDB()` defaults, `database_utils.jl` is reduced to just `using SQLite, DataFrames; import SQLite.DBInterface`.

### Files Created
- `src/abstract_simulator.jl` — updated with new stubs
- `src/hpc.jl` — SLURM utilities
- `src/project_configuration.jl` — `ProjectLocations`, location path utilities
- `src/globals.jl` — `ModelManagerGlobals`, `mm_globals_ref`, zero-arg accessors
- `src/recorder.jl` — `recordConstituentIDs`, `compressIDs`
- `src/classes.jl` — full trial hierarchy + `MMOutput`
- `src/database.jl` — generic schema + DB utilities
- `src/runner.jl` — parallel runner, HPC wrapping
- `src/deletion.jl` — cascade delete, `resetDatabase`, `rm_hpc_safe`
- `src/variations.jl` — XMLPath, all variation types, space-filling designs
- `src/sensitivity.jl` — MOAT, Sobol', RBD
- `src/user_api.jl` — `createTrial`, `run` convenience overloads
- `src/ModelManager.jl` — updated includes and exports

### Open Questions
- Should `initializeModelManager` live in ModelManager (generic) or remain in PCMM? Currently in PCMM; deferred to Phase 3.
- Should `createProject` live in ModelManager? Currently in PCMM; deferred to Phase 3.
- `LatentVariation.show` in ModelManager calls `columnName(tar)` for the target display — the `shortVariationName` (PhysiCell-specific human-readable names) was intentionally dropped; verify this is acceptable.

### Next Steps (Phase 2c)
1. Update PCMM `globals.jl` to use `ModelManagerGlobals` and set `mm_globals_ref`.
2. Update PCMM to slim down files that were moved: `classes.jl`, `recorder.jl`, `hpc.jl`, `deletion.jl`.
3. Update PCMM `database.jl` — add `simulatorVersionTableName(::PhysiCellSimulator)`, fix `physicell_version_id` references.
4. Update PCMM `PhysiCellModelManager.jl` — remove moved includes, add `const PCMMOutput = MMOutput`.
5. Run full PCMM test suite and fix failures.

---

## 2026-04-25 — Flatten SimulationSpec; split setup from collection

### Context

`AbstractSimulationSpec` was introduced as a future extension point but serves no current purpose — `AbstractSimulator` is the dispatch axis. `collectPendingSimulations` conflated folder creation, simulator hook calls, and simulation enumeration into one function, making the responsibilities hard to name and test independently.

### Design decisions

**No `AbstractSimulationSpec`; `SimulationSpec.monad_id::Int`**
`SimulationSpec` is now a plain struct. `monad_id` is always a real Int — setup always precedes collection, so `ismissing` is never needed.

**`prepareTrialHierarchy` dispatches on `AbstractMonad` directly**
`Simulation <: AbstractMonad <: AbstractSampling`, so a `Simulation` or `Monad` passed directly to `prepareTrialHierarchy` calls `setupSampling(simulator, M)` + `setupMonad(simulator, M)` without creating a wrapping `Sampling` in the DB. This avoids unnecessary database rows and output folders. Rejected: `_toSampling(T::AbstractMonad)` wrapper — clean conceptually but creates DB artifacts.

**`setupSampling`/`setupMonad` stubs generalized to `AbstractSampling`/`AbstractMonad`**
`loadCustomCode(S::AbstractSampling)` and `prepareVariedInputFolder(loc, M::AbstractMonad)` already accept these abstract types in MM, so the generalization has no downstream implementation cost in PCMM.

**`pendingSimulationSpecs(simulation::Simulation)` uses `Monad(simulation)`**
`createTrial` always creates a Monad before returning a Simulation (`INSERT OR IGNORE`), so `Monad(simulation)` is always an idempotent lookup, not a creation.

**`run` unchanged in structure**
No normalization of the input `T` needed. `MMOutput{T}` preserves the original type. Existing tests pass without change.

### Files touched
- `src/runner.jl`: removed `AbstractSimulationSpec`; `SimulationSpec.monad_id::Int`; replaced `collectPendingSimulations` with `prepareTrialHierarchy` + `pendingSimulationSpecs`; simplified `run`.
- `src/abstract_simulator.jl`: updated stub comments/docstrings for `setupSampling` and `setupMonad`.

---

## 2026-04-25 — Calibration infrastructure migration from PCMM

### Goal
Migrate all framework-agnostic calibration code from PCMM into ModelManager so that any simulator package can use ABC-SMC calibration without depending on PhysiCell-specific infrastructure.

### Scope
Files moved to `src/calibration/`:
- `methods.jl` — `AbstractCalibrationMethod`, `ABCSMC` struct + validation, `runCalibration` stub
- `problem.jl` — `CalibrationParameter`, `CalibrationProblem`, `Calibration`, `GenerationResult`, `ABCResult`, `posterior`
- `distance.jl` — `mseDistance` (only; PhysiCell summary stats stayed in PCMM)
- `abc_smc.jl` — full ABC-SMC core loop: `_runABCSMC`, `_runFirstGeneration`, `_runSubsequentGeneration`, importance weighting, epsilon adaptation
- `abc.jl` — MM-specific adapter: `_createMonadForParams`, `_buildEvaluateParticle`, `runCalibration(ABCSMC)`, `runABC`, `resumeABC`, `_saveMethod`, `_loadMethod`, `_saveGeneration`, `_loadGenerations`
- `calibration.jl` — orchestrator (includes), folder helpers, DB operations

### Key Design Decisions

**`_saveGeneration` / `_loadGenerations` in `abc.jl`, not `calibration.jl`**
These are ABC-SMC-specific persistence helpers. Grouping them in `abc.jl` keeps `calibration.jl` as a generic orchestrator. Same rationale for `_saveMethod` / `_loadMethod`.

**`calibrationsSchema()` moved to MM's `database.jl`**
The `calibrations` table is now standard infrastructure, created by `createSchema()`. PCMM's `upgradeToV0_3_0` migration updated to call `ModelManager.calibrationsSchema()` so old upgrade paths still work.

**No new MM dependencies**
`Distributions`, `CSV`, `DataFrames`, `LinearAlgebra`, `Statistics` were already in `Project.toml`. Zero `Project.toml` changes needed.

**PhysiCell summary statistics stayed in PCMM**
`endpointPopulationCounts`, `endpointPopulationFractions`, `meanPopulationTimeSeries` moved into `src/analysis/standard_qois.jl` in PCMM — not into MM.

**PCMM calibration files stubbed rather than deleted**
The bash sandbox mounts the macOS filesystem via FUSE which blocks `unlink()`, making `git rm` fail. Files were overwritten with stub comments; user runs `git rm src/calibration/*.jl` from their own terminal.

---

## 2026-04-25 — Remove kwargs from `runSimulation`

### Context

PCMM's `runSimulation` and `prepareSimulationCommand` do not use any of the kwargs that `run` was passing through. Keeping `; kwargs...` on the interface created unnecessary noise and false expectations for future simulator implementors.

### Change

`runSimulation(sim, spec::SimulationSpec)` no longer accepts kwargs. The `run` function still forwards kwargs to `prepareTrialHierarchy` (→ `setupSampling` / `setupMonad`) and to `postSimulationProcessing`, which do use them. Only the `runSimulation` call site was narrowed.

### Files touched
- `src/runner.jl`: removed `; kwargs...` from the `runSimulation` call site and updated the `run` docstring
- `src/abstract_simulator.jl`: removed `; kwargs...` from the stub signature, error message, and `AbstractSimulator` docstring list
- `PRD.md`: updated `runSimulation` signature and runner behavioral description

---

### Files touched (MM) — calibration migration
- `src/calibration/calibration.jl` — new
- `src/calibration/methods.jl` — new
- `src/calibration/problem.jl` — new
- `src/calibration/distance.jl` — new
- `src/calibration/abc_smc.jl` — new
- `src/calibration/abc.jl` — new
- `src/database.jl` — added `calibrationsSchema()`, wired into `createSchema()`
- `src/ModelManager.jl` — added exports and `include("calibration/calibration.jl")`
- `test/runtests.jl` — new full test suite
- `Project.toml` — bumped version `0.4.0` → `0.5.0`

---

## 2026-04-27 — ABC-SMC parallel batch evaluation

### Goal

Replace one-by-one sequential particle evaluation in the ABC-SMC loop with batch evaluation that exploits MM's parallel Sampling runner. Each generation now schedules all its candidate simulations concurrently via a single `run(sampling)` call instead of `population_size` sequential `run(monad)` calls.

### Scope

- `src/calibration/abc_smc.jl` — core loop refactored
- `src/calibration/abc.jl` — adapter refactored

### Key Design Decisions

**`evaluate_particle` → `evaluate_batch` interface**
The framework-agnostic core (`abc_smc.jl`) previously held a callback `Dict → (Float64, Any)`. Changed to `Vector{Dict} → Vector{(Float64, Any)}`. The core proposes a whole batch, hands it to the callback, and gets results in the same order. The core remains simulator-agnostic; MM-specific wiring stays in `abc.jl`.

**Generation 1: single batch**
All `population_size` proposals are sampled upfront, passed to `evaluate_batch` once, and all accepted. `n_evaluations = population_size`.

**Generation t > 1: iterative adaptive batching**
Initial acceptance rate estimate = `population_size / prev.n_evaluations`. Each round proposes `ceil(n_needed / acceptance_rate_est)` candidates, runs them as a Sampling, accepts those below epsilon, and updates the rate estimate. Stops once `length(accepted) >= population_size`; trims any overshoot. Rationale for adaptive over fixed multiplier: a fixed 2× wastes work when acceptance rate is already high (early generations); adapting from `prev.n_evaluations` asymptotically minimizes proposals.

**Overshoot trimming**
After a batch, `accepted` may exceed `population_size`. Trimmed to exactly `population_size`. Particles within a batch are exchangeable (same proposal distribution), so truncation bias is negligible.

**Acceptance rate floor**
`acceptance_rate_est` is clamped to a minimum of `0.01` after each round to prevent degenerate batch sizes when a round yields zero acceptances.

**`_buildEvaluateBatch` in abc.jl**
Takes `Vector{Dict{String,Float64}}`, creates one Monad per proposal via `_createMonadForParams`, forms `Sampling(monads, problem.inputs)`, calls `run(sampling; quiet=true)`, appends all monad IDs to `monads.csv`, then maps over monads to compute distances. Returns `Vector{Tuple{Float64,Int}}` in proposal order.

### Open Questions
- None at this time.

### Files touched
- `src/calibration/abc_smc.jl`
- `src/calibration/abc.jl`

---

## 2026-04-29 — Remove CalibrationParameter; CalibrationProblem accepts AbstractVariation directly *(REVERTED — see 2026-04-30 redesign below)*

> **Note:** This design was implemented then fully reverted before being replaced by the 2026-04-30 `CalibrationParameter` tagged-union redesign. Kept here for rationale history only. The current codebase does **not** reflect this design.

### Goal

Align `CalibrationParameter` with the existing `LatentVariation` / `CoVariation` infrastructure so that users can calibrate any parameter that can be expressed as a variation — including covaried parameters and general multi-dimensional latent relationships — without a bespoke data structure. Then go one step further: eliminate `CalibrationParameter` as a user-visible type entirely, so users simply pass their existing variation objects (`DistributedVariation`, `CoVariation`, `LatentVariation{<:Distribution}`) to `CalibrationProblem` directly.

### Scope

- `src/variations.jl` — fix `LatentVariation` convenience constructors
- `src/calibration/problem.jl` — remove `CalibrationParameter` entirely; add `_toCalibrationVariation`; store parameters as `Vector{LatentVariation{<:Distribution}}`
- `src/calibration/abc.jl` — update `_createMonadForParams`, `param_names`/`priors` extraction
- `src/ModelManager.jl` — remove `CalibrationParameter` from exports
- `test/runtests.jl` — replace `CalibrationParameter construction` testset; fix `posterior` test

### Key Design Decisions

**`CalibrationParameter` removed entirely**
It was a single-field struct wrapping `LatentVariation{<:Distribution}` with no logic of its own. No reason to expose it. `CalibrationProblem.parameters` now stores `Vector{LatentVariation{<:Distribution}}` directly.

**`CalibrationProblem` accepts `AbstractVector{<:AbstractVariation}`**
The outer constructors call `_toCalibrationVariation(av)` on each element. The resulting `Vector{LatentVariation{<:Distribution}}` is stored in the struct. Users never interact with the stored type — they just pass their variation objects.

**`_toCalibrationVariation` validates at construction time**
Dispatches on concrete types:
- `DistributedVariation` → `LatentVariation(dv)`
- `CoVariation{DistributedVariation}` → `LatentVariation(cv)`
- `LatentVariation{<:Distribution}` → identity
- Everything else → `ArgumentError` with a helpful message

**CDF values are the particle coordinates**
ABC-SMC draws particle values from the latent priors directly. For a `DistributedVariation`-backed latent variation the prior is `Uniform(0,1)`, so the particle coordinate IS the CDF value. `variationValues(lv, cdfs)` converts those draws to concrete target values through the quantile maps. This keeps the algorithm on a bounded, well-conditioned space regardless of the underlying distribution.

**Fix `LatentVariation` convenience constructors (pre-existing bug)**
All four outer constructors (`DistributedVariation`, `DiscreteVariation`, `CoVariation{Distributed}`, `CoVariation{Discrete}`) were calling the inner constructor without the required `locations` argument — a silent `MethodError` on any call. Added `locations = [variationLocation(dv)]` / `variationLocation(cv)` to each.

**`_createMonadForParams` iterates over `LatentVariation`s directly**
For each `lv` in `problem.parameters`: extract CDF values from `params` dict by `lv.latent_parameter_names`, call `variationValues(lv, cdfs)` to get target values, build one `DiscreteVariation(loc, tar, typ(val))` per target. Supports multi-target `CoVariation` and general `LatentVariation` maps with no extra code.

**`param_names`/`priors` via `vcat`**
```julia
param_names = vcat([lv.latent_parameter_names for lv in problem.parameters]...)
priors      = vcat([lv.latent_parameters      for lv in problem.parameters]...)
```
Multi-dimensional `LatentVariation`s contribute M names and M priors; single-dim cases contribute 1. ABC-SMC core sees a flat vector of named priors regardless.

### Files touched
- `src/variations.jl` — added `locations` to all four `LatentVariation` outer constructors
- `src/calibration/problem.jl` — removed `CalibrationParameter`; added `_toCalibrationVariation`; `CalibrationProblem.parameters::Vector{LatentVariation{<:Distribution}}`; `ABCResult.parameters::Vector{LatentVariation{<:Distribution}}`; updated docstrings
- `src/calibration/abc.jl` — `_createMonadForParams` iterates over `LatentVariation`s; `param_names`/`priors` extraction updated in `runCalibration` and `resumeABC`
- `src/ModelManager.jl` — removed `CalibrationParameter` from exports
- `test/runtests.jl` — replaced `CalibrationParameter construction` testset with `_toCalibrationVariation and CalibrationProblem parameter conversion`; `posterior` test uses `LatentVariation{<:Distribution}[]`
- `PRD.md` — updated `CalibrationParameter` spec and `evaluate_batch` description

---

### Files touched (PCMM)
- `src/calibration/*.jl` — stubbed (6 files)
- `src/analysis/standard_qois.jl` — new (PhysiCell summary stats)
- `src/analysis/calibration_summaries.jl` — stubbed (renamed to `standard_qois.jl`)
- `src/analysis/analysis.jl` — added `include("standard_qois.jl")`
- `src/PhysiCellModelManager.jl` — removed calibration include and `calibrations` table creation
- `src/database.jl` — removed `calibrationsSchema()`
- `src/up.jl` — updated migration to call `ModelManager.calibrationsSchema()`
- `test/test-scripts/CalibrationTests.jl` — updated namespace qualifications

---

## 2026-04-29 — Task #17 design: CDF-grid snapping with generational refinement

### Motivation

ABC-SMC re-runs simulations for every proposal even when a nearby simulation already exists in the database. Snapping particle CDF coordinates to a dyadic grid means proposals in high-probability regions converge on a finite set of grid points. The second time a grid point is proposed, `use_previous=true` returns the existing monad at zero cost.

### Design decisions (from clarifying questions)

**k notation:** k is the exponent (not the number of divisions). Grid spacing = 1/2^k; interior grid points per dimension = 2^k − 1. With k=4 (default): 15 interior points/dim.

**Default k_start = 4.** Auto-increase at construction: find smallest k ≥ k_start such that (2^k−1)^d ≥ population_size. For population_size=200, d=2: (2^4−1)^2 = 225 ≥ 200, so k=4 suffices.

**Generation 1 sampling:** Sobol sequence of length population_size in [0,1]^d, then snap to G(k). The Sobol sequence provides quasi-random coverage of the grid without deduplication logic. If any point snaps to 0 or 1, replace from remaining valid grid points (sampling without replacement to preserve coverage).

**Generational refinement:** k_t = k_initial + (t−1). Each generation doubles the grid resolution (2^k → 2^(k+1) intervals, 2^k−1 → 2^(k+1)−1 interior points per dim). Simulation reuse is most valuable in early generations where many particles share grid points; later generations run with finer grids and more novel simulations.

**Importance weights at snapped position.** No Jacobian correction. The algorithm treats the snapped position as if it were the actual draw. Rationale: the snap introduces a small approximation (O(1/2^k) error in each dimension) that diminishes each generation as k grows. Avoids extra machinery and is consistent with the `use_previous=true` simulation reuse intent.

**Boundary/rejection:** A draw x ∈ [0,1] snaps to round(x·2^k)/2^k. If this equals 0 or 1, the particle is rejected. Every interior grid point has a catchment zone of exactly 1/2^k width, so no interior point is favored over another. Values in [0, 1/(2^(k+1))) snap to 0 → rejected; values in [(2^(k+1)−1)/2^(k+1), 1] snap to 1 → rejected.

**Interface:** Add `cdf_grid_k::Union{Nothing,Int}` to `ABCSMC` (default `nothing` → snapping disabled, backward-compatible). When set to an integer, enables snapping with k_start = that value.

### Open questions
- None. All design questions resolved. Implementation completed 2026-05-02.

---

## 2026-04-30 — CalibrationParameter refactor + dual-CSV generation persistence

### Motivation
The `generation_NNN.csv` files were storing raw CDF coordinates instead of interpretable
parameter values, making them useless for human inspection. `resumeABC` also required the
caller to re-supply the full `CalibrationProblem`, making session restarts awkward.

### Design decisions

**`CalibrationParameter` as internal tagged union.** Rather than modifying `LatentVariation`
to carry an inverse map, we introduced a new `CalibrationParameter` struct pairing:
- `source::Union{DVSource,CVSource,LVSource}` — the original user-supplied variation, for
  display-column construction and JLD2 serialization provenance
- `lv::LatentVariation{<:Distribution}` — the derived variation used by the ABC-SMC loop

`inverse_maps` in `LatentVariation` was explicitly rejected by the user.

**Dual CSV output.** Each generation now writes two CSV files:
- `generations/generation_NNN.csv` — human-readable target parameter values (DVSource/
  CVSource → actual calibrated quantity; LVSource → latent samples + target values)
- `generation_cdfs/generation_NNN.csv` — raw CDF coordinates for `resumeABC`

**JLD2 as hard dependency** for serializing the full `CalibrationProblem` to
`problem.jld2`. This enables `resumeABC(Calibration(id))` with no re-supplied problem.
Anonymous functions and closures are serialized by JLD2. Non-serializable captures are
a user concern, documented in `_saveProblem`.

**`posterior` dispatch split:**
- `posterior(result::ABCResult)` — in-memory: converts CDF particles → display format
  using `_buildDisplayDF` (handles empty params by returning particles unchanged)
- `posterior(cal::Calibration)` — reads directly from `generations/generation_NNN.csv`
  on disk; strips weight/distance/monad_id columns

**`resumeABC` signature change (breaking):** `resumeABC(calibration::Calibration)` — no
`problem` argument required. The old `resumeABC(calibration, problem, ...)` signature is
removed (no backward compat, as approved).

**`_saveGeneration` / `_loadGenerations` API:**
- `_saveGeneration(dir, gen, max_pops[, cps])` — single-dir form used in tests; writes
  display to `dir/` and CDF to `dir/generation_cdfs/`
- `_loadGenerations(dir, param_names, max_pops)` — reads from `dir/generation_cdfs/`
- High-level `_saveGeneration(calibration, ...)` uses `generations/` + `generation_cdfs/`

**`_buildDisplayDF` fallback:** When `cps` is empty (e.g. test-constructed `ABCResult`)
returns a copy of `gen.particles` unchanged, preserving backward compatibility with unit
tests that construct `GenerationResult` directly.

### Files changed
- `src/calibration/parameters.jl` (new) — `CalibrationParameter`, source types,
  `_toCalibrationParameter`, `_displayColumns`, `_particleRowToDisplay`
- `src/calibration/problem.jl` — `CalibrationProblem.parameters::Vector{CalibrationParameter}`;
  `ABCResult.parameters::Vector{CalibrationParameter}`; dual `posterior` dispatch
- `src/calibration/abc.jl` — `_buildDisplayDF`, dual-CSV `_saveGeneration`,
  `generation_cdfs`-reading `_loadGenerations`, JLD2 `_saveProblem`/`_loadProblem`,
  new `resumeABC(Calibration; ...)` signature, updated `runCalibration`
- `src/calibration/calibration.jl` — added `include("parameters.jl")`
- `Project.toml` — JLD2 added as hard dependency (UUID 033835bb, compat 0.4, 0.5)
- `test/runtests.jl` — updated to `_toCalibrationParameter`, new display-conversion
  tests, updated generation persistence tests for dual-CSV structure, `CalibrationParameter[]`

---

## Session: Fix acceptance rate overshoot bias (2026-04-30)

### Problem
`acceptance_rate = population_size / n_evaluations` undercounts accepted particles when
the final batch of a generation overshoots. Example: population_size=100, final batch
proposes 50 particles, 30 pass epsilon, but only 20 are needed to fill the population.
Old code reported 20/50 for that round, biasing the aggregate rate downward.

### Fix
Track `n_accepted_total` separately — increments for **every** proposal passing epsilon,
regardless of whether it is kept. Only the `push!` to `accepted` is gated on
`length(accepted) < population_size`. `acceptance_rate = n_accepted_total / n_evaluations`.

`n_accepted_this_round` for adaptive batch sizing also now counts all passing proposals,
so the estimate is unbiased on the last batch too (though this rarely matters since
there is no subsequent batch in that generation).

**Generation 1** is unchanged: no truncation possible (all N proposals accepted),
passes `n_accepted = N = n_evaluations` → rate = 1.0.

### Key decision
The acceptance rate should reflect the algorithm's efficiency at generating valid
particles given the current kernel and epsilon — **not** a function of the arbitrary
population size cap. Truncation is a bookkeeping artifact, not a rejection.

### Files changed
- `src/calibration/abc_smc.jl` — loop restructure, `n_accepted_total` counter,
  `_buildGenerationResult` gains `n_accepted::Int` parameter
- `test/runtests.jl` — regression test: `_buildGenerationResult` with n_accepted=7,
  n_evaluations=10, 5 kept particles → asserts rate=0.7 not 0.5; integration test
  via `_runABCSMC` with all-pass evaluate_batch

---

## 2026-05-01 — SimulationBank implementation (task #15)

### Motivation
The CDF-grid snapping algorithm (task #17) requires a pre-built registry of existing
monads whose calibrated parameters lie in the prior interior `(0,1)^d` in CDF space.
These can be reused rather than re-simulated when a proposal falls within one grid cell.

### Design decisions

**Terminology (established during review):**
- *Column* — a parameter that already has a column in the variation DB.
- *Parameter* — a user-specified `CalibrationParameter` target; may or may not have a DB column.

**`variation_id=0` as universal fallback.** This row always exists and holds the current
defaults for all columns in the variation table. Used as fallback when a candidate row has
`NULL` for a column. The reference variation ID fallback chain is: reference row value →
`variation_id=0` default → missing.

**Calibrated parameters with no DB column** (never varied before — column doesn't exist in
the table). The correct default is read from the XML config file via `getColumnDefaults`
(same logic as `addColumns`). This is not the `variation_id=0` row — the column doesn't
exist there either. If the config-file default falls outside the prior support, the entire
location is skipped (`skip_loc = true`). Otherwise, all candidate variation IDs at that
location inherit this base value for CDF computation.

**LVSource disabled.** `LVSource` parameters have no generic inverse map from target
values to latent CDF coordinates. Bank is disabled (returns empty `SimulationBank`) for
any problem containing an `LVSource` parameter. An `@info` message is emitted. Future
extension: add optional inverse maps to `LatentVariation`.

**CVSource joint consistency.** CDF coordinate u is recovered from the first target via
inversion. All other targets are forward-mapped from u and compared to their stored values
with relative tolerance 1e-8. Monads not on the co-variation curve are excluded.

**Non-calibrated column filtering.** DB columns within a calibrated location that are not
targeted by any `CalibrationParameter` must exactly match the effective reference values.
This ensures the bank only contains monads that were run with the intended background
parameters.

**Four-phase algorithm:**
1. Central DB query by simulator version, folder IDs, and reference variation IDs for
   non-calibrated varied locations.
2. Per-location variation filtering: batch-query all candidate vids + vid=0 + ref_vid;
   build effective-value maps; check non-calibrated column equality and calibrated column
   support bounds.
3. Per-monad CDF inversion: merge target maps across calibrated locations; call
   `_bankCdfCoords` per `CalibrationParameter`.
4. Interior filter: discard any monad with a CDF coordinate at exactly 0 or 1.

**`isInitialized()` guard.** Added early return when called in test context (uninitialized
DB), so unit tests for `_bankCdfCoords` and struct construction don't throw.

### Open questions
- None currently. The bank is built; it will be threaded into the proposal loop in task #17.

### Files changed
- `src/calibration/bank.jl` (new) — `SimulationBank` struct, `_buildSimulationBank`,
  `_bankColDistribution`, `_bankCdfCoords`
- `src/calibration/calibration.jl` — added `include("bank.jl")`
- `test/runtests.jl` — `@testset "SimulationBank struct and _bankCdfCoords"`: DVSource
  standard/flipped/missing/boundary, CVSource consistent/missing, LVSource, struct
  construction, `_buildSimulationBank` uninitialized-DB guard

---

## 2026-05-02 — CDF-grid snapping implementation (tasks #23–26)

### Goal
Implement the CDF-grid snapping and simulation bank lookup described in the task #17 design, including all prerequisite struct changes.

### Design decisions

**`cdf_coords` in `GenerationResult` (task #23).** Added `cdf_coords::Matrix{Float64}` (n_dims × n_particles) as a new field. This is the same data as `particles` but in matrix form, avoiding repeated DataFrame column lookups in tight loops. `_buildGenerationResult` constructs it via `reduce(hcat, [[p.params[name] for name in param_names] for p in accepted])`, preserving `param_names` order independent of DataFrame column ordering. `_loadGenerations` reconstructs it via `permutedims(Matrix{Float64}(particles[!, param_names]))`. A 9-arg backward-compatible outer constructor derives `cdf_coords` from `particles` automatically, so all existing tests (which construct `GenerationResult` with 9 positional args) continue to work unchanged.

**`cdf_grid_k` in `ABCSMC` (task #23).** Added as last field with default `nothing`. Validated ≥ 1 when set. Persisted to `method.toml` as a top-level key (omitted when `nothing`) and restored on resume via `_loadMethod`.

**Snap helpers (task #24).** Seven stateless functions in `abc_smc.jl`:
- `_effectiveK(k_base, t)` — `k_base + t - 1`
- `_snapToCDFGrid(u, k_eff)` — nearest interior grid point, boundary-clamped
- `_bankBoxRadius(k_base, t)` — `1/2^(k_base+t)`, half the grid spacing
- `_cdfToGridKey(snapped_cdf, k_eff)` — integer index vector for set membership
- `_bankBoxCandidates(bank, snapped_cdf, radius)` — L^∞ box monad lookup
- `_selectBankCandidate(bank, snapped_cdf, radius)` — first candidate or `nothing`
- `_snapAndLookup(params, param_names, k_eff, radius, bank, used_set)` — full snap+dedup+bank-resolve step; returns `(effective_params, grid_key)` or `nothing` if the snap key is already in `used_set`

**Bank reuse via proposal substitution (task #25).** When `_snapAndLookup` finds a bank candidate, it returns the bank monad's *actual* CDF coordinates (not the snapped grid point) as the effective proposal. The caller's `evaluate_batch` then calls `_createMonadForParams` with those coords; `use_previous=true` finds the existing monad without re-simulation. This keeps the `evaluate_batch` interface unchanged — no special bank-hit path needed.

**Gen 1 with snapping (task #25).** Switches from single-batch to iterative. Proposals are drawn in batches of `n_needed`. Each proposal is snapped, deduplicated within-batch (via a temporary `batch_key_set`) and against accepted particles (via `used_set`), then bank-resolved. Evaluation is batched for efficiency. Grid keys are registered to `used_set` immediately on acceptance.

**Gen t with snapping (task #25).** The existing proposal-building loop gains an `if snap_active` branch that calls `_snapAndLookup`. Proposals whose snap key is already in `used_set` are silently dropped (not counted in `n_evaluations`). Within a batch, two proposals may snap to the same unused key — only the first accepted one registers the key; the second passes epsilon but misses the `key ∉ used_set` check and is not added. Both are counted in `n_accepted_this_round` for an unbiased acceptance-rate estimate. This is rare when the grid is large relative to `population_size`.

**`used_set` type.** `Set{Vector{Int}}` — Julia's default array hash is content-based, so `[1,2]` and a separately constructed `[1,2]` hash equally and compare equal.

> **Note — this design was subsequently revised before the session ended.** See the 2026-05-02 revision entry below for the final implementation.

### Files changed (initial draft)
- `src/calibration/methods.jl` — `cdf_grid_k::Union{Nothing,Int}` field + validation
- `src/calibration/abc.jl` — `_saveMethod`/`_loadMethod` handle `cdf_grid_k`
- `src/calibration/problem.jl` — `GenerationResult` gains `cdf_coords` field + 9-arg compat constructor
- `src/calibration/abc_smc.jl` — snap helpers; `_snapAndLookup`; updated generation runners
- `test/runtests.jl` — snap helper unit tests; integration tests

---

## 2026-05-02 — KD-tree spatial index for SimulationBank

### Motivation

`_bankBoxCandidates` was doing a linear O(n_bank × n_dims) scan over all bank entries on every proposal. With banks potentially reaching tens of thousands of entries, this becomes the dominant cost. Replaced the scan with a KD-tree (Chebyshev metric) built once when the bank is constructed, reducing each query to O(log n + k).

### Design decisions

**`NearestNeighbors.jl` as the indexing backend.** Pure-Julia, maintained by a Julia core developer, no native dependencies. `KDTree` with `Chebyshev()` metric matches the existing L∞ box semantics exactly — `inrange(tree, point, radius)` returns the same set of candidates as the old loop.

**`tree::Union{Nothing,NNTree}` field on `SimulationBank`.** `nothing` when the bank is empty (no entries to index). Abstract field type is acceptable here: `SimulationBank` is not accessed in simulation hot loops.

**3-arg outer constructor preserves all call sites.** `SimulationBank(ids, coords, names)` auto-builds the tree, so every existing constructor call in tests, `_buildSimulationBank`, and the `abc_smc.jl` default argument works without modification.

**`_selectBankCandidate` removed.** Dead code — `_lookupAndSnap` already handles candidate selection inline. Its test was also removed.

### Files changed
- `Project.toml` — added `NearestNeighbors` to `[deps]` and `[compat]`
- `src/ModelManager.jl` — added `using NearestNeighbors`
- `src/calibration/bank.jl` — `SimulationBank` gains `tree` field; 3-arg outer constructor added
- `src/calibration/abc_smc.jl` — `_bankBoxCandidates` uses `inrange`; `_selectBankCandidate` deleted
- `test/runtests.jl` — added `using NearestNeighbors`; added tree field assertions; removed `_selectBankCandidate` testset

---

## 2026-05-02 — Revise CDF-grid snapping: lookup-first, monad-ID dedup, remove `cdf_coords` from `GenerationResult`

### Motivation

Three architectural issues identified during review of the initial snapping implementation:

1. **`GenerationResult.cdf_coords` is redundant.** It stores `permutedims(Matrix{Float64}(particles))` — the same data as the `particles` DataFrame in transposed matrix form. Nothing in the source code reads `gen.cdf_coords`; the matrix used for bank lookup lives on `SimulationBank.cdf_coords`. Carrying a duplicate field adds memory overhead and a maintenance burden with no benefit.

2. **`_snapAndLookup` had snap-first order.** The original function snapped θ_prop to the grid first, then looked for bank candidates near the snapped point. There is no reason to prefer this: looking near the **original** proposal first maximises reuse of existing simulations, and snapping is only needed as a fallback when no usable bank monad exists nearby.

3. **Two separate dedup structures.** Bank hits were deduplicated by monad ID (inside `_snapAndLookup`, checking `used_set` of grid keys), while fallback snaps were deduplicated by grid key vector. These are logically the same concern — "don't re-run the same simulation within a generation" — but were handled by different mechanisms. The user also pointed out that once a monad has been evaluated, re-running it is pointless regardless of acceptance: it produces the same result.

### Design decisions

**Remove `cdf_coords` from `GenerationResult`.** Struct drops from 10 to 9 fields; the redundant backward-compat constructor is also removed. `_buildGenerationResult` and `_loadGenerations` no longer build or carry it.

**Unified `used_monad_ids::Set{Int}`.** Both the bank-hit path (monad ID known before evaluation, from the bank registry) and the fallback-snap path (monad ID resolved pre-evaluation via `get_monad_id`) feed into the same `Set{Int}`. A per-batch scratch `batch_monad_ids::Set{Int}` handles within-batch dedup. After evaluation, ALL returned monad IDs — accepted or not — are added to `used_monad_ids`. This ensures the same monad is never run twice in a generation.

**`get_monad_id` resolver callback.** `_buildGetMonadID(problem)` in `abc.jl` returns a closure `params::Dict → monad_id::Int` that calls `_createMonadForParams(problem, params).id` without running simulations. `addVariations` with `GridVariation` is idempotent, so repeated calls for the same params return the same monad ID. The callback is built by `runCalibration`/`resumeABC` only when `cdf_grid_k` is set, and threaded through `_runABCSMC` → generation runners → `_lookupAndSnap`. `_runABCSMC` asserts `get_monad_id !== nothing` when `cdf_grid_k` is set.

**`_lookupAndSnap` replaces `_snapAndLookup`.** New lookup-first order: (1) search bank within radius of original θ_prop, (2) filter by `used_monad_ids` + `batch_monad_ids`, (3) if usable candidates: pick random, return `(bank_coords, bank_mid)`, (4) else snap to grid, resolve monad ID, check against sets, return `(snapped_params, snap_mid)` or `nothing`.

**`_bankBoxCandidates` docstring update.** Parameter renamed from `snapped_cdf` to `query_cdf` to reflect that the input need not be snapped — it is any CDF vector.

### Files changed
- `src/calibration/problem.jl` — removed `cdf_coords` field and compat constructor from `GenerationResult`
- `src/calibration/abc.jl` — removed `cdf_coords` matrix from `_loadGenerations`; added `_buildGetMonadID`; `runCalibration` and `resumeABC` build and pass `get_monad_id`
- `src/calibration/abc_smc.jl` — `_runABCSMC` gains `get_monad_id` kwarg + guard; generation runners switched to `used_monad_ids::Set{Int}` + `batch_monad_ids::Set{Int}`; `_snapAndLookup` replaced by `_lookupAndSnap`; `_buildGenerationResult` drops `cdf_coords`; `_bankBoxCandidates` docstring updated
- `test/runtests.jl` — removed `GenerationResult cdf_coords field` and `_buildGenerationResult populates cdf_coords` testsets; replaced `_snapAndLookup` testset with `_lookupAndSnap` (new interface, monad-ID return, `batch_monad_ids` coverage); integration test updated with consistent `get_monad_id_fn`/`evaluate_batch` mocks

---

## 2026-05-03 — CDF-grid safeguards: k_base correction, snap_retry_limit, max_evaluations

### Motivation

Three robustness gaps identified in the CDF-grid snapping implementation:

1. **Coarse k_base.** If `cdf_grid_k` is too small for the population size and parameter
   dimension, the grid has fewer interior points than `population_size`, making it impossible
   for gen-1 to fill its population. Need a pre-run correction.

2. **Stuck proposal loop.** If the grid fills up (all unused snap points exhausted within
   `used_monad_ids`), `_lookupAndSnap` will return `nothing` on every call, spinning
   forever. Need a mechanism to escape by increasing grid resolution.

3. **Unbounded evaluation cost.** No way to cap total simulations. For calibration runs
   used as budget-capped exploratory searches, the user needs a hard budget stop.

### Design decisions

**k_base correction (in `_runABCSMC`).** Computed once at run start:
`k_min = ceil(Int, log2(N^(1/d) + 1))` where N = `population_size`, d = number of
latent dimensions. This is the smallest k such that `(2^k - 1)^d ≥ N`. The effective
base is `k_base_eff = max(method.cdf_grid_k, k_min)`. An `@info` message is emitted if
the correction fires. The corrected value is passed to the generation runners as a kwarg,
never written back to the struct.

**`snap_retry_limit` (new `ABCSMC` field).** Counts consecutive `_lookupAndSnap` failures
(returning `nothing`). Resets to 0 on any success. When the count reaches the limit,
`k_eff` is incremented by 1 and the counter resets. Default: `nothing` when `cdf_grid_k`
is `nothing`; `100` otherwise. Exposed as a user-visible kwarg because 100 is a
reasonable default but the correct value is problem-dependent.

**`max_evaluations` (new `ABCSMC` field).** `budget::Ref{Int}` initialized to the sum
of `n_evaluations` from any `start_generations` (for correct resume accounting).
Incremented by `length(params_list)` after each `evaluate_batch` call. When
`budget[] >= method.max_evaluations`, `budget_hit[]` is set. The outer loop in
`_runABCSMC` checks `budget_hit[]` after each generation and breaks. Within
`_runSubsequentGeneration`, the inner while loop also breaks immediately after each
batch where `budget_hit[]` is set, so the partial generation is returned with however
many particles were accepted.

**`snap_failures` reset on success.** The counter tracks *consecutive* failures. On any
successful `_lookupAndSnap` call (returning non-nothing), it resets to 0. This means a
single stuck run of failures triggers the escape; recovery doesn't penalize future rounds.

**Helper extraction to eliminate duplicated code.** After the three safeguards were
implemented, both `_runFirstGeneration` and `_runSubsequentGeneration` contained identical
blocks for (a) tracking `snap_failures` / widening `k_eff`, and (b) incrementing the
`budget` Ref and setting `budget_hit`. These were extracted into two helpers:

- `_snapAndTrack(params, param_names, k_eff, radius, bank, used_monad_ids,
  batch_monad_ids, get_monad_id, snap_failures, snap_retry_limit)` — wraps `_lookupAndSnap`
  and the `snap_failures` / `k_eff` widening logic. Returns `(result, k_eff, radius,
  snap_failures)` as a tuple; callers rebind all four. Emits `@info` when `k_eff` is
  widened (not `@warn` — the widening is expected normal behavior, not a warning).

- `_updateBudget!(budget, budget_hit, n, max_evaluations)` — increments `budget[]` by `n`
  and sets `budget_hit[] = true` when the budget is exceeded.

**`_stoppingReason` budget integration.** The outer `_runABCSMC` loop originally had two
separate checks: `if budget_hit[] ... break end` followed by `stop_reason =
_stoppingReason(...)`. These were unified by adding a `budget_hit::Bool=false` kwarg to
`_stoppingReason`. When `budget_hit=true`, it returns `"max_evaluations=N reached"` before
checking any other criterion. The redundant explicit break was removed.

### Files changed
- `src/calibration/methods.jl` — added `snap_retry_limit::Union{Nothing,Int}` and
  `max_evaluations::Union{Nothing,Int}` fields; constructor defaults; validation
- `src/calibration/abc_smc.jl` — `_runABCSMC`: k_base_eff correction block, budget Ref
  pair, pass to runners, unified stop-check via `_stoppingReason(…; budget_hit=…)`;
  `_runFirstGeneration`: new kwargs `k_base_eff`, `budget`, `budget_hit`; snap logic via
  `_snapAndTrack`; budget via `_updateBudget!`; `_runSubsequentGeneration`: same kwargs;
  `snap_active` and `_effectiveK` use `k_base_eff`; proposal loop uses `_snapAndTrack` and
  `_updateBudget!`; new helper functions `_snapAndTrack`, `_updateBudget!` in CDF-Grid
  Snap Helpers section; `_stoppingReason` gains `budget_hit::Bool=false` kwarg
- `src/calibration/abc.jl` — `runABC`: added `snap_retry_limit` and `max_evaluations`
  kwargs; `_saveMethod`: persists both (omit when nothing); `_loadMethod`: loads both
- `test/runtests.jl` — four new testsets: fields + validation, save/load round-trip,
  k_base_eff correction integration test, max_evaluations stopping integration test

---

## Task #19 — LatentVariation inverse maps + LVSource bank support (2026-05-04)

**Goal.** Enable `SimulationBank` for calibration problems that include `LVSource` parameters by adding optional inverse maps to `LatentVariation`.

### Design decisions

**`inverse_maps` field.** `LatentVariation` gains `inverse_maps::Union{Nothing,Vector{Function}}`. Each `inv_map_i(target_vals::Vector{Float64}) → Float64` maps the full ordered vector of target values to the CDF coordinate `u_i ∈ (0,1)` for latent dimension `i`. One inverse per latent dimension.

**Auto-construction for DV/CV.** The `LatentVariation(dv::DistributedVariation)` and `LatentVariation(cv::CoVariation{DistributedVariation})` factory constructors auto-construct `inverse_maps` from `cdf(dist, ·)`. The CVSource inverse also embeds a joint-consistency check (returns `NaN` when co-variation constraint is violated), which `_bankCdfCoords` treats as `nothing`.

**Round-trip validation.** The continuous inner constructor calls `validateInverseMaps(lv)` when `inverse_maps` is non-`nothing`. This validates both directions: `u → target → u′` (checks round-trip accuracy and `u′ ∈ (0,1)`) and `u → target → u′ → target′` (checks `target′ ≈ target`). Throws `ArgumentError` on failure. Exported so users can also call it independently.

**`_bankCdfCoords` refactor.** The three per-source dispatch methods (`DVSource`, `CVSource`, `LVSource`) were removed in favour of a single `_bankCdfCoords(lv::LatentVariation, vals)` method that dispatches on `!isnothing(lv.inverse_maps)`. The top-level entry `_bankCdfCoords(cp, vals)` now delegates to `cp.lv`.

**Phase 2 LVSource bounds.** `_buildSimulationBank` Phase 2 checks source type directly (`cp.source isa LVSource`) before calling `_bankColDistribution` to avoid triggering the `@warn` bug-indicator path. LVSource columns skip support-bounds pre-filtering (no per-target distribution exists); Phase 3 CDF inversion handles exclusion via `0 < u < 1`.

**Partial enablement.** LVSource parameters without `inverse_maps` still disable the bank (informational log). Only when all LVSource parameters in a problem carry `inverse_maps` is the bank enabled.

### Files changed
- `src/variations.jl` — `LatentVariation` struct: new `inverse_maps` field; both inner constructors: `inverse_maps` keyword, validation call; new exported `validateInverseMaps`; DV/CV factory constructors: auto-constructed `inverse_maps`
- `src/calibration/bank.jl` — LVSource early-exit replaced with inverse_maps check; Phase 2 LVSource bounds skipped; `_bankCdfCoords` rewritten to use `lv.inverse_maps`; docstrings updated
- `test/runtests.jl` — updated LVSource comment; added LVSource-with-inverse, CVSource inconsistency, and `validateInverseMaps` testsets
- `PRD.md` — planned item updated to reflect implementation

---

## Task #20 — Kernel type hierarchy: `AbstractKernel` (2026-05-06)

**Goal.** Replace `perturbation_kernel::Symbol` on `ABCSMC` with a proper `AbstractKernel` type hierarchy enabling dispatch-based perturbation strategies.

### Design decisions

**`AbstractFittedKernel` parent.** User requested that all fitted structs share an abstract supertype so that `_computeWeights` and other callers can type-annotate at the `AbstractFittedKernel` level and get correct dispatch. Added alongside `AbstractKernel`.

**`LocalNNCovKernel` as a fourth type.** Original plan had only `LocalNNKernel` (global covariance shape + per-particle bandwidth scalar). User pointed out this poorly handles banana-shaped or anisotropic posteriors because the *direction* of the kernel is fixed. Added `LocalNNCovKernel` which stores N per-particle Cholesky factorizations — each particle's kernel covariance is estimated from its k nearest neighbors. Cost: N Cholesky factorizations per generation vs. 1 for `LocalNNKernel`.

**Inner constructors for validation.** `GaussianKernel` and `ComponentwiseKernel` required inner constructors with `new(...)` because Julia's dispatch prefers the auto-generated inner struct constructor over outer constructors when the argument type exactly matches the field type. Outer `GaussianKernel(-1.0)` was silently bypassing validation. `LocalNNKernel` and `LocalNNCovKernel` use positional inner constructors (no ambiguity issue with keyword outer constructors).

**No `MvNormal` in `_kernelDensity`.** `Distributions.MvNormal` doesn't accept a `Cholesky` object directly (requires `PDMats.AbstractPDMat`). All `_kernelDensity` methods use the Cholesky log-pdf formula directly: `log_det = 2Σ log(U_ii)`, `quad = dot(diff, chol \ diff)`, `return exp(-quad/2 - log_det/2 - (d/2)*log(2π))`.

**TOML subtable format.** Kernel serialized as `[perturbation_kernel]` with `type = "GaussianKernel"` etc. Legacy flat-string format (`perturbation_kernel = "gaussian"`) detected in `_deserializeKernel` and raises a descriptive `ErrorException`.

### Files changed
- `src/calibration/methods.jl` — `AbstractKernel`, 4 kernel types with inner-constructor validation, `_effectiveKernelScale`, updated `ABCSMC` struct/constructor/docstring
- `src/calibration/abc_smc.jl` — `AbstractFittedKernel`, 4 fitted structs, `_fitKernel`/`_proposeParticle`/`_kernelDensity` (4 methods each), refactored `_runSubsequentGeneration`, deleted `_buildPerturbationKernel`/`_perturbParticle`, updated `_computeWeights`
- `src/calibration/abc.jl` — `_serializeKernel`/`_deserializeKernel`/`_toKernelScale`, updated `_saveMethod`/`_loadMethod`, updated `runABC` signature
- `src/ModelManager.jl` — export `AbstractKernel, GaussianKernel, ComponentwiseKernel, LocalNNKernel, LocalNNCovKernel`
- `test/runtests.jl` — `using LinearAlgebra`, 3 updated existing tests, ~200 lines of new testsets (kernel construction, `_effectiveKernelScale`, `_fitKernel` × 4, `_proposeParticle`, `_kernelDensity`, ABC-SMC with each kernel type, TOML round-trip, legacy Symbol error)
- `PRD.md` — `LocalNNCovKernel` added, `AbstractFittedKernel` noted in private structs list
- `README.md` — kernel type hierarchy marked complete

---

## 2026-05-06 — Posterior visualization — all four recipes (task #7)

### Goal

Implement all four RecipesBase visualization recipes for `ABCResult`, plus the supporting data model (`store_rejected`, `rejected_proposals`) and `KernelDensity.jl` dependency.

### Design decisions

**`space=:cdf` not `:latent`.** The keyword is `space=:cdf` (not `:latent`) to avoid confusion with "latent parameters" — a term the codebase already uses for `LVSource`-backed parameters. `:cdf` is unambiguous: it refers to the ABC internal CDF coordinate space.

**Primary space is target-parameter.** All visualization recipes default to `space=:target` (biological units / user-facing parameter values). CDF space is diagnostic only.

**`store_rejected` is opt-in (default `false`).** Rejected proposals can be 10–50× accepted count; only needed for the transition plot. Stored as CDF coordinates in `GenerationResult.rejected_proposals` (consistent with `particles`); converted to target space at plot time via the same path as `posterior()`.

**Lazy disk fallback for rejected proposals.** When `rejected_proposals === nothing`, the `:transition` recipe loads all evaluated monad IDs from `generation_{t+1}_monads.csv`, subtracts the accepted IDs, and fetches target values via `simulationsTable`. This makes the full accepted/rejected plot available by default without requiring `store_rejected=true`, as long as the calibration folder is on disk. For `space=:cdf`, additionally requires inverse maps on all parameters (LVSource without inverse maps → skip, accepted-only).

**Duplicate encoding.** With CDF-grid snapping, many proposals share the same grid point. Default (`aggregate_duplicates=true`): group by unique position; accepted bubble area ∝ aggregate weight, rejected bubble area ∝ count × `w_ref` (where `w_ref = 1/population_size`) — same scale for direct comparison. 1D diagonal: stacked strip chart — duplicate positions stack vertically, so height = count directly.

**Recipe dispatch.** `@recipe function f(result::ABCResult)` for the pairs plot; `@recipe function f(result::ABCResult, style::Symbol)` with internal branching on `:ridgeline` and `:transition`; `@recipe function f(cs::DataFrame)` for the convergence trace. No named functions like `plot_transitions` are generated.

**`latent_params`/`target_params` generation keyword.** Both accessor functions accept `generation=:final` (default) or an integer index.

### Open questions
- None at this time.

### Files changed
- `src/calibration/methods.jl` — `store_rejected::Bool` field + keyword on `ABCSMC`; `_saveMethod`/`_loadMethod` updated
- `src/calibration/problem.jl` — `rejected_proposals` field on `GenerationResult`; `latent_params`/`target_params` accessors
- `src/calibration/abc_smc.jl` — collect rejected coords in `_runSubsequentGeneration`; `_buildGenerationResult` signature updated
- `src/calibration/visualize.jl` — new file: all four recipes + `_lazyLoadRejected` helper
- `src/ModelManager.jl` — exports + `include("calibration/visualize.jl")`
- `Project.toml` — `KernelDensity` added to `[deps]` and `[compat]`
- `PRD.md` — task #7 expanded with `:transition` recipe, `store_rejected` data model, lazy-load fallback; `space=:latent` renamed to `space=:cdf`

---

## 2026-05-18 — Relax CalibrationProblem type constraints; extend mseDistance

### Goal
Remove the `Dict{String,Any}` coercions that forced all users into dict-based summary statistics and distance functions, and extend `mseDistance` with vector and scalar calling conventions.

### Design decisions

**`observed_data::Any`.** Changed from `Dict{String,Any}` to `Any` in the `CalibrationProblem` struct. Both outer constructors drop the `Dict{String,Any}(observed_data)` coercion and store the value as-is. Constructor argument types also broadened from `Dict{String,<:Any}` to `Any`.

**No coercion in `evaluate_batch`.** The two-line dict coercion in `abc.jl`:
```julia
simulated_dict = Dict{String,Any}(String(k) => v for (k, v) in simulated)
distance = problem.distance(simulated_dict, problem.observed_data)
```
collapsed to a single line: `distance = problem.distance(simulated, problem.observed_data)`. The `distance` function is now fully responsible for interpreting both arguments.

**Three `mseDistance` methods.** Added two new methods alongside the existing dict method:
- `mseDistance(sim::Real, obs::Real)` → `(sim - obs)²` — squared difference is the trivial MSE for a single value.
- `mseDistance(sim::AbstractVector{<:Real}, obs::AbstractVector{<:Real})` → `Σ(simᵢ−obsᵢ)²` — sum of squared distances with a length guard.

The three methods are intentionally heterogeneous in their reduction: absolute error for scalars, L2 norm for vectors, mean-of-per-key-MSE for dicts. Each is the natural quantity for its input shape.

### Files changed
- `src/calibration/problem.jl` — `observed_data::Any`; both constructors broadened
- `src/calibration/abc.jl` — removed dict coercion in `evaluate_batch`
- `src/calibration/distance.jl` — two new `mseDistance` methods; docstring updated
- `test/runtests.jl` — new tests for vector/scalar `mseDistance`; `DimensionMismatch`; non-dict `observed_data` round-trip; non-dict `evaluate_batch` integration
- `PRD.md` — updated `mseDistance` spec and acceptance criteria

---

## Session: monadsTable — monad-level analysis table (2026-07-07)

### Goal
Add `monadsTable`, the monad analogue of `simulationsTable`: one row per monad and its varied parameters. First of the handoff tasks (e); read-only, no schema change.

### Design decisions

**Shared helper, not copy-paste.** Both `simulations` and `monads` tables carry the same input-ID and variation-ID columns, so the join pipeline (`addFolderNameColumns!` + `appendVariations` + constant-dropping + sort) is identical — only the primary-key column differs. Factored the body of `simulationsTableFromQuery` into a private `_variationsTableFromQuery(query, id_column, display_id_column; …)`. `simulationsTableFromQuery` and the new `monadsTableFromQuery` are thin wrappers that fix the key column (`:simulation_id` → `:SimID`, `:monad_id` → `:MonadID`) and the `sort_ignore` default. This makes drift between the two tables impossible.

**Public `simulationsTableFromQuery` signature unchanged.** It keeps its exact kwargs (including the `sort_ignore=[:SimID; …]` default) and delegates — so existing callers (`calibration/visualize.jl`) are untouched. The helper takes `sort_ignore` as a required kwarg (already resolved by the wrapper) rather than recomputing it.

**Dispatch mirrors `simulationsTable`.** `monadsTable` has the same four forms (`AbstractArray{<:AbstractTrial}`, `Vararg{AbstractTrial}`, `AbstractVector{<:Integer}`, no-arg), collecting IDs via the pre-existing `monadIDs` dispatch. No ambiguity: the integer-vector and trial-array methods have disjoint element types.

### Rejected / not done
- No `@test_throws assertInitialized()` test: not practically testable inside the DB-backed testset (globals stay initialized), and `simulationsTable` has no such test either — matched the existing convention.

### Files changed
- `src/database.jl` — extracted `_variationsTableFromQuery`; added `monadsTableFromQuery`, `monadsTable` (4 methods), `printMonadsTable`; `simulationsTableFromQuery` now delegates
- `src/ModelManager.jl` — export `monadsTable`, `printMonadsTable`
- `test/runtests.jl` — new `monadsTable` testset in DB-backed integration (row counts vs `simulationsTable`, dispatch forms, `remove_constants`/`short_names`, `printMonadsTable` sink)
- `PRD.md` — new "Analysis Tables" feature section
- `README.md` — Implementation Status: analysis tables entry

---

## Session: String variation values — considered and rejected (2026-07-07)

### Decision
Do **not** add string values to `DiscreteVariation`. Categorical/string parameters are instead handled by using a **separate config (input) folder per categorical value** — folders are already first-class in ModelManager, so the varied-parameter machinery stays numeric.

### Why (investigation findings)
Supporting strings would require Float64-locked core internals to be generalized in three layers, none of it localized to "column typing" as first assumed:
1. **Type layer** — `LatentVariation{T<:Union{Vector{<:Real},<:Distribution}}` (`src/variations.jl:491`) is numeric-only; the single-`DiscreteVariation` conversion (`:630`) uses `latent_parameters=[dv.values]` + `maps=[first]`, so `Vector{String}` fails the `T<:Real` constraint.
2. **Sampling layer** — `variationValues(lv::LatentVariation{<:Vector{<:Real}})` (`:743`) allocates `Array{Float64}`; `addVariationRow` is typed `AbstractVector{<:Real}` (`:1323`).
3. **`par_key` layer** — row-uniqueness fingerprint is `reinterpret(UInt8, Vector{Float64}(vals))` in `addVariationRow`, `addColumns`, `setUpColumns`, and `validateParsBytes` (`:1267`).

A viable path existed (index-based latent params like the `CoVariation{DiscreteVariation}` case at `:651`, length-prefixed UTF-8 bytes appended to `par_key` to avoid a migration), but the cost/risk (~150–250 LOC across core sampling internals, Medium risk) is not justified given the config-folder alternative. Note `sqliteDataType` already maps non-numeric → `"TEXT"`, so nothing about the current schema blocks the folder-based approach.

---

## Session: Per-simulation post-processing hook + QoI sink (2026-07-07)

### Goal
Handoff task b: let a user run their own code after each simulation, and optionally collect returned quantities of interest (QoIs) into a standardized, queryable store — without giving up the freedom to just compute/save/delete however they want.

### Design decisions

**Two layers: callback primitive + opt-in sink.** `run(T; post_processor=f)` calls `f(simulation_process)` once per *successful* sim, after the simulator's own `postSimulationProcessing`. The return value decides storage: `nothing` → pure side effects ("wild west"); a `NamedTuple`/`AbstractDict` of `name => scalar` → a row upserted into a single project-level sink DB; anything else → `ArgumentError`. This satisfies both the "do whatever you want" and the "standardized sink with missing entries" goals the user described.

**Single sink DB at `data/outputs/postprocessing.db`, separate from the central DB.** Table `post_processing`, PK `simulation_id`, columns grown on demand via `ALTER TABLE ADD COLUMN` (typed by value: Bool/Integer→INTEGER, Real→REAL, String→TEXT). A sim that never produced a given quantity reads back `missing`. Because it is a *separate* file created lazily on first write, there is **no `up.jl` migration and no PCMM coordination** — nothing about the central schema changes.

**Upsert semantics (user choice).** Re-writing a `simulation_id` overwrites its row (`INSERT … ON CONFLICT(simulation_id) DO UPDATE SET …`). Latest run wins; keeps one row per sim.

**Concurrency: writes funneled to the serial main loop.** The callback runs inside the per-sim worker task (`processSimulationTask`) so heavy compute parallelizes, but its return value is carried back on the result channel via a private `_PostProcessedResult(process, qoi)` wrapper, and **all sink writes happen in the single-threaded completion loop** in `run`. User code never touches the sink DB, so a `yield` inside user code cannot interleave a half-written row. `SimulationProcess` (public struct) is unchanged; only the internal channel payload widened. The sink DB handle is opened once per `run` (when `post_processor` is set) and closed in a `finally`.

**`post_processor` is an explicit `run` kwarg**, not part of `kwargs...`, so it is not forwarded to `prepareTrialHierarchy` / simulator setup hooks. `MMOutput` fields left unchanged (QoIs are read via `postProcessingTable`, not returned in `MMOutput`) — easy to add in-memory return later if wanted.

### Rejected
- Storing QoIs in the central DB (would need a schema migration + coordinated PCMM `up.jl` entry) — the separate sink file avoids all of that.
- Passing a bespoke NamedTuple to the callback instead of `SimulationProcess` — reusing `SimulationProcess` keeps it consistent with `postSimulationProcessing`.

### Files changed
- `src/runner.jl` — `post_processor` kwarg on `run`; `_PostProcessedResult`; `processSimulationTask` runs the callback (success only) and returns the wrapper; serial sink-write loop with lazy-open/`finally`-close
- `src/database.jl` — `postProcessingDBPath`, `_openPostProcessingDB`, `_postProcessingColumnSpec`, `_normalizePostProcessingQoI`, `_writePostProcessingRow` (upsert + dynamic columns), `_readPostProcessingTable`, `postProcessingTable` (4 forms), `printPostProcessingTable`
- `src/ModelManager.jl` — exports `postProcessingTable`, `printPostProcessingTable`, `postProcessingDBPath`
- `test/runtests.jl` — new "post-processing sink" testset (fires on success only; not on `use_previous`; `nothing` vs NamedTuple vs Dict; dynamic column + `missing`; direct upsert; `ArgumentError` on bad returns; `printPostProcessingTable` sink)
- `PRD.md` — new "Per-Simulation Post-Processing" feature section
- `README.md` — Implementation Status entry

### Correction: split destructive cleanup into `postSimulationCleanup` (ordering fix)

The first cut ran the simulator's `postSimulationProcessing` **before** the user `post_processor`. That is wrong for PCMM, whose `postSimulationProcessing` *prunes* (deletes) simulation output — the user callback would be handed an already-gutted folder and could compute nothing.

**Fix:** three well-defined per-simulation slots around the user hook, applied in `processSimulationTask`:
1. `postSimulationProcessing` — simulator-specific, **non-destructive**, runs **before** `post_processor` (future-proofing: a simulator can standardize/transform output that the user then reads).
2. `post_processor` — user callback (successful sims only).
3. `postSimulationCleanup` — **new** interface stub (`src/abstract_simulator.jl`, default no-op), simulator-specific **destructive** cleanup/pruning, runs **after** `post_processor`, regardless of success.

**PCMM coordination (required):** PCMM must move its pruning (and its err-file handling) from `postSimulationProcessing` into a new `postSimulationCleanup(::PhysiCellSimulator, …)`. Because `postSimulationCleanup`'s default is a no-op, an unmodified PCMM would simply stop pruning — so this is a coordinated PCMM bump. This is the one interface change task b introduces (the initial brief's "no PCMM coordination" no longer holds).

Test: TestSimulator now records `postSimulationProcessing`/`postSimulationCleanup` calls into a log; the ordering test asserts `["processing:id", "user:id", "cleanup:id"]`.

### Ergonomics: SimulationProcess accessors for `post_processor`

Added so a user callback never has to reach into `SimulationProcess` internals:
- `pathToOutputFolder(::SimulationProcess)` and `pathToOutputFolder(::Simulation)` (alongside the existing `::Int` method).
- `simulationID(sp)`, `monadID(sp)`, `wasSuccessful(sp)` accessors (exported).

**Division of labor (the design question):** ModelManager provides the generic plumbing — identify the simulation (`simulationID`) and locate its output (`pathToOutputFolder`). It deliberately does **not** parse output, because "output" is simulator-specific. Turning a simulation's folder into usable data (cells, populations, substrates, …) is the downstream package's job: e.g. PhysiCellModelManager should offer loaders keyed by `simulationID(sp)` so a user's `post_processor` becomes a one-liner. The `run` docstring states this explicitly.

### Deletion consistency for the post-processing sink

The sink (`data/outputs/postprocessing.db`) is a separate DB, so deletions of the central DB had to be taught about it:
- `_deletePostProcessingRows(simulation_ids)` (`src/database.jl`) deletes sink rows; no-op if the sink file doesn't exist yet.
- Wired into `deleteSimulations` (`src/deletion.jl`) — the **single choke point** through which every cascading deletion (`deleteMonad`/`deleteSampling`/`deleteTrial` with `delete_subs`) removes simulations, so one call covers them all.
- `resetDatabase` additionally removes the whole sink file via `rm_hpc_safe(postProcessingDBPath())`.

Tests: deleting simulations removes their rows (others remain); cascade via `deleteSampling` clears the rest; `resetDatabase` (isolated mktempdir project) removes the sink file.

Also fixed a related export gap: `deleteMonad`/`deleteSampling`/`deleteTrial`/`deleteAllSimulations` were used bare in `docs/src/man/managing_data.md` but were **not exported** (only `deleteSimulation(s)`, `deleteSimulationsByStatus`, `resetDatabase` were), so those documented calls would `UndefVarError`. Now exporting all deletion functions (in both `src/ModelManager.jl` and `src/deletion.jl`); the sink-deletion test uses bare `deleteSampling` to exercise the export.

### Convenience: `simulationsTable(...; post_processing=true)`

Since the sink and the simulations table are both keyed by `:SimID`, added a `post_processing::Bool=false` kwarg to `simulationsTable`/`simulationsTableFromQuery` that left-joins the stored quantities onto the table. Implementation: `_appendPostProcessing!(df)` (`src/database.jl`) looks up `postProcessingTable(df.SimID)` and appends one column per quantity via a `SimID→value` Dict, preserving `df` row order and filling `missing` where absent. Order-preserving Dict lookup rather than `DataFrames.leftjoin` to avoid depending on join row-order semantics. Appended columns are deliberately exempt from `remove_constants`/sorting. Simulation-level only — not added to `monadsTable` (quantities are per-simulation). Note: `df.SimID` comes back `Union{Missing,Int}` from SQLite, so it is narrowed with `Vector{Int}` before the ID query.

### Review pass — fixes before moving on

Second look over the whole post-processing change caught:
- **Lazy sink creation.** `run` was opening (creating) `postprocessing.db` whenever a `post_processor` was supplied, even one that only ever returns `nothing` — contradicting the `postProcessingDBPath` docstring. Now the sink is opened lazily on the first stored quantity, so pure side-effect callbacks never create the file. Added a test (`post-processing sink created lazily`).
- **Empty-ID guard** in `_appendPostProcessing!` (avoids `WHERE simulation_id IN ()` if `simulationsTable(...; post_processing=true)` is ever called on an empty result).
- **Docstring consistency.** `postProcessingTable` example now uses `simulationID(sp)` instead of `sp.simulation.id`; `run` kwargs bullet notes that `postSimulationCleanup` also receives kwargs (`prune_options`); removed a trailing-whitespace nit.

Final: 1011/1011 tests pass; docs build clean.

---

## Session: Batch run/createTrial over a vector (task f) (2026-07-07)

### Goal
Support the accumulate-then-launch pattern: `sims = []; push!(sims, createTrial(...)); …; run(sims)`.

### Design decisions

**Bundle into one `Trial`, not a loop.** `run(Ts::AbstractVector)` → `run(createTrial(Ts))`. `createTrial(Ts::AbstractVector)` narrows the (possibly `Vector{Any}`) collection to `Vector{AbstractTrial}` (via `_toAbstractTrialVector`, mirroring `convertToAbstractVariationVector`), collects each element's samplings, and returns a single `Trial`. One Trial = one parallel pool across *all* constituent simulations (better than sequential per-element `run`s).

**Type hierarchy made this easy.** `Simulation`/`Monad`/`Sampling` are all `<: AbstractSampling`, and `Trial(Ss::AbstractArray{<:AbstractSampling})` broadcasts `Sampling.` over them (`Sampling(::AbstractMonad)` wraps, `Sampling(::Sampling)` reloads). So the only element needing special handling is a `Trial` (which is `<: AbstractTrial` but not `AbstractSampling`) — flattened to its `.samplings`.

**Decisions:** single-element vector still returns a `Trial`-wrapped `MMOutput` (consistent, batch-oriented); pre-built trials are wrapped as-is with `n_replicates=0`/`use_previous=true` (no new replicates); empty vectors and non-`AbstractTrial` elements raise a clear `ArgumentError` listing offending indices; `MMOutput` elements are not accepted (users pass `.trial`).

**No dispatch ambiguity:** no existing `run`/`createTrial` method takes a bare `Vector` as its sole first argument.

### Files changed
- `src/user_api.jl` — `createTrial(Ts::AbstractVector)`, `_toAbstractTrialVector`, `run(Ts::AbstractVector)`
- `test/runtests.jl` — "run/createTrial over a vector" testset (heterogeneous batch, single element, Trial flattening, ArgumentError cases)
- `PRD.md` — Simulation Runner feature updated (batch spec + acceptance; also refreshed the hook wording to `postSimulationProcessing`/`postSimulationCleanup` + `post_processor`)
- `README.md` — Implementation Status entry
- `docs/src/man/running_simulations.md` — "Batching pre-built trials" section

---

## Session: Calibration evaluation budget — enforce before dispatch (task c, corrected) (2026-07-08)

### Correction
Task c was first mis-implemented as a global per-`run` "simulation budget" gate (new `simulation_budget` global, `setSimulationBudget`, `nPendingSimulations`, `force` kwarg). That was **not** the intent and was fully reverted. The budget is specifically for **calibration runs**: the existing `ABCSMC.max_evaluations`, but checked **before** sending off a batch rather than only after.

### The actual problem
`max_evaluations` already capped total evaluated particles, but `_updateBudget!` ran *after* `evaluate_batch`, so a batch was fully dispatched (simulations launched) and the run overshot the budget before `budget_hit` stopped it. The docstring even said "the current batch is fully processed."

### Fix
`_capBatchToBudget(proposals, budget, max_evaluations)` (`src/calibration/abc_smc.jl`) trims a planned batch to `max_evaluations - budget[]` **before** it is dispatched to `evaluate_batch`. Applied at all three dispatch sites: `_runFirstGeneration` (both no-snap and CDF-snap paths) and the batch loop in `_runSubsequentGeneration`. Consequences:
- The run never evaluates more than `max_evaluations` simulations (trim-to-fit — uses the budget maximally, then stops).
- Generation 1 is trimmed too when the budget is smaller than `population_size` (partial first generation, weights renormalized to the trimmed size).
- Subsequent-generation loop guards an empty trimmed batch (sets `budget_hit`, breaks) so the acceptance-rate update never divides by zero.
- `_updateBudget!` still runs after dispatch to advance `budget[]`/`budget_hit` (now by the trimmed count).

### Tests
- "max_evaluations caps total evaluations (checked before each batch)": total evaluated `== 25` and `eval_count == 25` (exactly the budget; never dispatched over).
- "max_evaluations smaller than a generation trims generation 1": budget 4 < population 10 → one partial generation of 4 particles, weights `fill(0.25, 4)`.

### Files changed
- `src/calibration/abc_smc.jl` — `_capBatchToBudget`; capping at the three dispatch sites; empty-batch guard
- `src/calibration/methods.jl`, `src/calibration/abc.jl` — `max_evaluations` docstrings updated to "before dispatch"
- `test/runtests.jl` — updated/added budget tests
- `docs/src/man/calibration.md`, `PRD.md` — before-dispatch semantics

---

## Session: PR #20 review fixes — async hang + sink hardening (2026-07-08)

Addressing Copilot review comments on PR #20 plus a reproduced-bug handoff from the PCMM side.

### Async worker hang (critical; handoff + Copilot)
**Bug:** in `run`, each simulation is processed by a bare `@async for … put!(result_channel, processSimulationTask(...))` worker. If `processSimulationTask` threw (a throwing `runSimulation`/`fetch`, a simulator hook, or the user `post_processor`), the worker died silently, the `put!` never fired, and the completion loop's `take!` blocked **forever** — a silent, indefinite hang (reproduced in PCMM: hung a test run 9+ hours, twice, from a `MethodError`). Especially dangerous now that arbitrary user code (`post_processor`) runs in this path.

**Fix (`src/runner.jl`):** a single private exception type flowing through the result channel.
- `_SimulationStageError <: Exception` — `(stage, sim_id, captured::CapturedException)` with a `Base.showerror` method that names the stage (user `post_processor` vs. which simulator hook vs. the simulation worker) and simulation, then prints the original exception + backtrace. `CapturedException` is the stock Base type for carrying an exception across tasks.
- `_runStage(stage, sim_id, thunk)` rethrows any exception from a per-simulation stage as a tagged `_SimulationStageError`; `processSimulationTask` wraps `postSimulationProcessing` → `post_processor` → `postSimulationCleanup` in it and otherwise keeps its straight-line shape (exceptions propagate as exceptions — no error-tuple plumbing).
- The worker loop's single `try/catch` puts either a `_PostProcessedResult` or the `_SimulationStageError` on the (union-typed) result channel — **the pool always delivers exactly one result per scheduled simulation.** A non-stage exception (throwing `fetch`/`runSimulation`) is wrapped as stage `:simulation`.
- The completion loop: `result isa _SimulationStageError && throw(result)`. **Fail-fast**, never hang.

First cut used Go-style `(err, value)` returns from `_runStage`, an `error::Union{Nothing,NamedTuple}` field on `_PostProcessedResult` (forcing `process` to `Union{Nothing,…}`), and a `_rethrowWorkerError` that hand-built the message — reworked on review to the exception-type design above: same guarantees, fewer mechanisms, display logic in `showerror` where Julia expects it, and `_PostProcessedResult` stays two clean fields.

Decision: fail-fast (abort) is the default; no `:skip_and_continue` policy kwarg for now (YAGNI — can layer on later). In-flight simulations may still finish; their results are discarded once `run` throws.

### Sink input hardening (Copilot)
- **SQL identifier injection:** user QoI names were interpolated raw into `ALTER TABLE … ADD COLUMN "$(name)"` / INSERT. Added `_qIdent` (wrap + double interior `"`) used for all sink identifiers; logical names still used for the `in existing` check and value binding.
- **Dict key collision:** `_normalizePostProcessingQoI` now rejects `AbstractDict`s whose keys collide after `string(k)` (e.g. `1` and `"1"`) with a clear `ArgumentError`, instead of a confusing SQLite duplicate-column error.
- **Consistency:** `printPostProcessingTable` now calls `assertInitialized()` like the other `print…Table` helpers.

### Not changed (Copilot comments resolved by drbergman)
- Error message "Real, Bool, or String": `Integer <: Real`, so it is covered — no change.
- Reject non-positive `max_evaluations`: already validated (`>= 1`) in the `ABCSMC` constructor (`methods.jl:277`); an empty gen-1 batch cannot occur — no change.

### Tests (`test/runtests.jl`)
- TestSimulator hooks gained a `_throw_in_hook` flag to simulate a throwing simulator hook.
- "post-processing errors surface instead of hanging": throwing `post_processor` and throwing `postSimulationProcessing`/`postSimulationCleanup` each make `run` throw a stage-tagged `_SimulationStageError`; a normal run still works afterward.
- "post-processing sink input hardening": a QoI name containing `"` round-trips; colliding dict keys (`1` vs `"1"`) → `ArgumentError`.

Full suite 1037/1037.

---


## Session: Handle failed simulations in calibration (2026-07-28)

### Goal
Bug handoff from a PCMM calibration run on a cluster. Two traces, same root cause:

```
[1] my_dist_fn(sim_data::Missing, data::Dict{String, Int64})   # MethodError: getindex(::Missing, ::String)
[2] my_sum_stat(m_id::Int64)                                   # ERROR: Monad 248 not in the database
```

Both die at `abc.jl`'s `simulated = problem.summary_statistic(monad.id)` / `problem.distance(...)`.
The console around trace 2 gives it away: `WARNING: Simulation 688 failed.` A simulation fails →
the runner marks it `Failed` and erases it from its monad's constituent list → the monad is now
empty → `deleteMonad` removes its row, folder, and constituent CSV. The user's summary statistic
then queries a monad that no longer exists and either throws or returns `missing` (which throws
one frame later, inside `distance`). A single bad parameter set killed a multi-day run.

### Design decisions

**Detect the unusable monad instead of catching the user's failure.** The first cut wrapped the
user's `summary_statistic`/`distance` in a `try` and inferred what had gone wrong from whether
the monad still existed. Reworked on review (drbergman): the condition that actually matters —
*this monad has no successful simulation* — is knowable from the database before user code runs,
so ask directly. That removed the tiered warning text, the `_monadExists` probe inside a `catch`,
and the guard around `Monad(known_mid)`, and made the two Copilot review findings on PR #22 moot
(a "all 0 of its simulations failed" message when no snapshot existed, and a bare `catch` that
discarded the original exception).

**`_batchOutcome` compares a pre-run snapshot against post-run status codes.** One
`_simulationStatusIDs` query per batch returns three vectors: failed simulations, monads with ≥1
failure, monads with no `Completed` simulation. The snapshot must be taken before the batch runs
— a deleted monad takes its constituent CSV with it, and that CSV is the *only* monad→simulation
mapping (the `simulations` table stores input/variation IDs, not monad membership). Status codes
rather than "which IDs disappeared from the constituent list" because that also correctly covers
a monad whose simulations never ran (setup failure leaves them `Not Started`, not erased).

**Failures are recorded per generation, warned once per generation.** Two files mirroring
`generation_{NNN}_monads.csv`: `_failed_simulations.csv` and `_failed_monads.csv`, both written
via a new `_appendCompressedIDs` (also now used for the monads record, deduplicating that logic).
This replaced the previous throttle-to-5-warnings machinery, the `rejection_counts` dict threaded
out of `_buildEvaluateBatch`, and the wrapped `on_generation` callbacks in
`runCalibration`/`resumeABC` — a population of hundreds against a broken region should write a
file and mention it once, not emit N warnings. `_buildEvaluateBatch` is back to returning just
the closure.

**No top-off re-runs for partially failed monads** (drbergman): evaluate from whatever succeeded.
Chasing the last few successes risks spinning for a long time. Designed and dropped: an
`AbstractMonadCompletion` extension point (with `FixedReplicates` now and a standard-error
criterion later) plus a runner-level `keep_failed_monads` opt-out to stop
`deleteMonad(…; delete_supers=true)` from rewriting *other* samplings' constituent lists mid-run.

**Two failure classes, two dispositions.** Simulation failure (no successful simulation) is
infrastructure: `on_monad_failure=:reject` → `Inf`, `:error` → stop, pointing at the failure
files. A `summary_statistic`/`distance` failure on a monad that *does* have output is a bug in
user code and is always fatal, including a `distance` return value that is not `<:Real`. That
non-`Real` check is what actually stops trace 1's `missing` from travelling into the ABC-SMC
internals. `_evaluateParticle` logs the monad ID (plus the count of that monad's failed
simulations when non-zero — the likeliest reason otherwise-correct code trips) and then
`rethrow()`s, so the original backtrace survives; deliberately not wrapped in a new exception.

**`missing` carries the failure, not a sentinel distance.** First two cuts used `Inf`, on the
grounds that `evaluate_batch`'s `Vector{Tuple{Float64,Int}}` contract stayed intact and
`distance <= epsilon` rejects `Inf` for free. Reworked on review (drbergman): `Inf` is a value a
user's `distance` is entitled to return, so overloading it as a control signal makes "monad
failed" and "terrible fit" indistinguishable — and it forced generation 1 to decide *acceptance*
by finiteness. The contract is now `Vector{Tuple{Union{Float64,Missing},Int}}`. The ripple was
smaller than feared: `_ParticleResult.distance` and `GenerationResult.distances` stay `Float64`
because only accepted particles reach them. The one trap is that `missing <= epsilon` is
`missing`, not `false`, which throws when used as a condition — `_runSubsequentGeneration` needs
an explicit `!ismissing(distance) &&` guard, and there is a test that would catch its removal.

**Generation 1 needed a real fix; later generations did not.** Gen 1 accepts everything and sets
`epsilon = maximum(distances)`. `_acceptFirstGeneration` drops `missing` particles, warns,
renormalizes the uniform weights over survivors, and errors when no monad succeeded.
`n_evaluations` still counts all proposals while `n_accepted` counts survivors, so the acceptance
rate stays unbiased. No backstop for an all-failed batch in later generations (considered,
rejected by drbergman): the adaptive batching loop keeps proposing under `max_evaluations`, and
throwing would let one bad monad in a small batch kill a healthy run.

**A non-finite ε is left alone** (considered, then removed at drbergman's direction). I had added
an error for it, on the theory that ε = `Inf` in gen 1 silently accepts everything thereafter.
That overstated the harm: gen 2 accepting every proposal is just a second uniform draw in CDF
space, after which the usual quantile rule pulls ε back to a finite median and the run proceeds
normally. It only matters if the run stops at gen 2. `Inf` also round-trips through TOML as
`+inf` (verified), so persistence and resume are unaffected. Erroring would have converted a
self-correcting inefficiency into a hard failure, and `Inf` is the user's `distance` function's
business. Net effect: less code than the version before it.

**One reusability rule for monad IDs, keyed on the monad's own state.** A deleted monad's ID was
being absorbed into the `SimulationBank`, from where a later generation could hand it back as a
`known_mid` — reproducing `Monad N not in the database` *inside* ModelManager. (The reported run
had `k_base_eff=nothing`, snapping off, so it never hit this, but it was live for any snapping
run.) First cut filtered on `isfinite(distance)`; reworked on review (drbergman) because using
the distance to decide bank membership conflates two things — a user's `distance` may legitimately
return `Inf` for a perfectly good monad. `_monadsWithStartedSimulations` asks the database
instead: keep monads with ≥1 simulation that is `Running` or `Completed`. Deletedness falls out
for free (`constituentIDs` reports nothing for a deleted monad, so no separate existence check),
and the same predicate now gates `_buildSimulationBank` at load time — which closes a hazard
drbergman spotted: a bank monad whose only simulation was `Not Started` could be scheduled, fail,
and be deleted *mid-generation*, leaving a later batch in that same generation holding a dangling
`known_mid`. `Running` counts as reusable (the output is on its way), matching the bank's purpose
of snapping onto nearby, already-(partly)-done work.

`_updateMidGenAdditions!` is now called only when `snap_active` — `mid_gen_additions` feeds the
bank, which is consulted only then, so the non-snapping path skips a per-batch query entirely.
This was also forced by the algorithm-level tests, which drive `_runABCSMC` with mock monad IDs
and no database; the predicate additionally treats every ID as reusable when
`isInitialized()` is false, since there are no statuses to consult.

**`_batchOutcome` throws on a constituent simulation with no database row** rather than defaulting
its status. The IDs come from a monad's constituent record moments earlier and the runner only
ever *updates* their status, so an absent row means the records and the database disagree.
Guessing either way is wrong in a specific direction: "not completed" rejects a healthy particle,
"not failed" hides a real failure. The error names the simulations, the monads that list them, and
`databaseDiagnostics()`.

**No `isInitialized()` fudge in `_monadsWithStartedSimulations`.** The first version returned "all
reusable" when uninitialized, purely so the algorithm-level tests could keep driving `_runABCSMC`
with mock monad IDs and no database. That is test scaffolding leaking into production semantics —
both call sites are only reachable inside a calibration run against a live project, so a live
database is a precondition. The two affected testsets (CDF-grid snapping integration, k_base_eff
correction) moved into the DB-backed section instead; mock IDs that happen to match a real monad
are reusable there and ones that do not are skipped, neither of which affects what they assert
(grid alignment and population size).

### Gotcha for future tests
`createTrial(inputs, [dv]; n_replicates=1)` returns a **`Simulation`**, not a `Monad` (see
`_createTrial`), so `.id` is a simulation ID — use `n_replicates=2` when a monad is wanted. And
`use_previous=true` means a `DiscreteVariation` value already used by an earlier testset silently
reuses that monad, completed simulations and all; the "never started" fixture needs a value no
other testset touches.

### Open questions
- The failed-simulation artifact store is deferred (see the `CLAUDE.md` to-do): the failure files
  give IDs, but nothing records which variation a failed simulation came from once its monad is
  deleted.

### Files changed
- `src/calibration/abc.jl` — `_simulationStatusIDs`, `_batchOutcome`, `_evaluateParticle`,
  `_validateEvaluationFailurePolicy`, `_throwNoSuccessfulSimulations`, `_failedSimulationsPath`,
  `_failedMonadsPath`, `_appendCompressedIDs`, `_recordBatchFailures`; `_buildEvaluateBatch`
  reworked; `on_monad_failure` threaded through `runCalibration`/`runABC`/`resumeABC`
- `src/calibration/progress.jl` — `_warnFailuresRecorded` (one warning per generation)
- `src/calibration/abc_smc.jl` — `_acceptFirstGeneration`; `_updateMidGenAdditions!` filters on
  reusability and is called only when snapping is active
- `src/calibration/bank.jl` — `_monadsWithStartedSimulations`; `_buildSimulationBank` Phase 4
- `src/calibration/problem.jl` — `Calibration` docstring lists the failure files
- `test/runtests.jl` — `_fail_sim_predicate` hook on TestSimulator; new testsets
- `CLAUDE.md` — to-do: preserve failed-simulation artifacts for post-hoc inspection
- `PRD.md`, `README.md`, `docs/src/man/calibration.md`

Full suite 1113/1113.

---

## Session: Portable docstring cross-references (2026-07-31)

### Goal
PCMM's docs build was failing. ModelManager docstrings `@ref` ModelManager internals; a
downstream build renders only ModelManager's *public* API, so those links cannot resolve and
`makedocs` dies with `:cross_references`.

```
Error: Cannot resolve @ref for md"[`_buildEvaluateBatch`](@ref)" in docs/src/lib/calibration.md.
- No docstring found in doc for binding `ModelManager._buildEvaluateBatch`.
```

### Why our own docs build never caught it
Every `docs/src/lib/*.md` page carries **both** a `Private = false` and a `Public = false`
`@autodocs` block, so locally everything renders and every `@ref` resolves. This class of bug
is invisible from inside this repo — which is the whole reason a test now guards it.

### Decision: the strong rule
Adopted **no docstring `@ref`s a non-public binding, anywhere** — not the narrower "public
docstrings only." The narrow rule leaves private→private links that still break in any
downstream build mirroring our page structure (PCMM mirrors `lib/calibration.md`, which is how
this surfaced). The strong rule is also trivially testable via `Base.ispublic`.

Rejected: having PCMM set `warnonly = [:cross_references]`, which hides real breakage; and
DocumenterInterLinks/`@extref`, which is the right long-term answer for *inbound* links from
PCMM to our docs but does nothing about our own docstrings being unportable.

### Scope: 310 `@ref`s, 142 unique targets, 61 non-public
Split three ways rather than deleted wholesale:

1. **Genuine internals** (~17 `_`-prefixed) → demoted to plain code spans.
2. **`AbstractSimulator` interface methods** (19 in `abstract_simulator.jl` +
   `postVariationXMLProcessing`) → declared `@compat public`. Unexported *by design* — a
   simulator implements `ModelManager.runSimulation`, never calls an exported one — but they
   are the documented contract, and `abstract_simulator.jl` had the repo's highest `@ref`
   density (31). Delinking would have gutted the one page a PCMM developer needs.
3. **Public-in-effect names** → `SimulationSpec`/`SimulationProcess` (appear in interface
   signatures), `GSASampling` (return type of exported `run(::GSAMethod, ...)`),
   `simulationsTableFromQuery`/`monadsTableFromQuery` (they carry the *entire* keyword
   documentation for the exported `simulationsTable`/`monadsTable` — delinking would have
   stranded users).

Deliberately **not** promoted, since `public` is a hard-to-reverse API commitment and delinking
costs only a hyperlink: `SimulationBank`, `ParsedVariations`, `AddVariationsResult`,
`CVSource`/`DVSource`/`LVSource`, `addVariations`, `databaseDiagnostics`.

### `addVariationRows` — a stale-docs trap
Initially promoted to public because the `AbstractSimulator` docstring *and*
`docs/src/man/building_a_simulator.md` both described it as
`addVariationRows(sim::MySimulator, inputs, ...)`. It takes no simulator argument and never
has one dispatched — one method, two internal call sites. Both docs were wrong. Reverted to
internal and **deleted both stale claims**, including the "Variation row writing" section that
told simulator authors to implement a method ModelManager never calls. Generalized into
CLAUDE.md: verify against the signature, never promote a name just to preserve a link.

### Gotchas
- Julia **errors** on declaring an already-exported name public (`cannot declare X public; it is
  already declared exported`). `postInitDisplay` and `centralDBFileName` are exported and had to
  come out of the `abstract_simulator.jl` block.
- A mechanical regex sweep produces bad prose. `See [`_buildEvaluateBatch`](@ref).` becomes
  `See `_buildEvaluateBatch`.` — a pointer the reader cannot follow. The three such sites in
  exported docstrings (`runCalibration`, `runABC`) were hand-rewritten to name the actual
  artifacts, `generations/generation_{NNN}_failed_{simulations,monads}.csv`. Script found the
  sites; the fixes were by hand.
- `@compat public` needs Compat ≥ 4.10; already a dep at 4.16. No-op on the Julia 1.10 floor,
  real `public` on 1.11+. Docs CI must therefore run 1.11+ for `Private = false` to exclude
  them correctly — it runs 1.12.

### Verification
Reproduced PCMM's failure locally with a scratch Documenter build rendering only
`Private = false` autodocs. Confirmed it errors identically with one bad ref reintroduced as a
control, and builds clean with it removed. This harness — not our own `docs/make.jl` — is what
actually tests this class of bug.

### PR #24 review — the version floor bites
Copilot raised three points; two were right.

**Real bug: the test broke the Julia 1.10 floor.** `Base.ispublic` landed in 1.11, and
`Project.toml` declares `julia = "1.10"`. CI's matrix includes `lts` (currently 1.10), so the
suite would have failed there — not hypothetically, on this PR. Guarded with
`@static if isdefined(Base, :ispublic)`, using feature detection rather than a `VERSION`
comparison. Skipping is the *correct* semantics, not a workaround: on 1.10 `@compat public` is a
no-op, so every interface method would look private and the test would report ~25 false
violations. Noted at the time that 1.10 makes `@compat public` inert and then failed to carry it
into the test — the floor needs checking in the *test*, not just the prose.

Confirmed the docs job runs `version: '1'` (1.12), so `Private = false` still classifies the
interface methods correctly. Had it run `lts`, the published docs would have silently omitted
every interface method from the public API section.

**Real bug (pre-existing): PRD hook descriptions were reversed.** `postSimulationProcessing` was
glossed "pruning, cleanup", which is `postSimulationCleanup`'s job. Source is unambiguous —
`postSimulationProcessing` is non-destructive and runs *before* the user `post_processor`;
`postSimulationCleanup` is destructive and runs *after*. Both bullets rewritten to state the
ordering and the destructive/non-destructive split, since getting this backwards would have a
simulator author delete output the user callback still needs.

**Not a bug:** claim that `split(t, ('(', '{'))` throws a `MethodError` — Julia accepts any char
collection as a delimiter, and the testset ran green. Switched to `split(..., r"[({]")` anyway
for legibility, not correctness.

### Open questions
- `prepareBaseFile` (`src/xml_utilities.jl`) is also an `AbstractSimulator`-dispatched override
  point but was left private: no docstring `@ref`s it, so promoting it would be pure API
  widening. Inconsistent with `postVariationXMLProcessing`; worth revisiting.
- Inbound links (PCMM → our docs) are still unsolved. DocumenterInterLinks with `@extref` is
  the durable fix, on PCMM's side.

### Files changed
- 12 `src/*.jl` files — 61 `@ref`s demoted to code spans
- `src/abstract_simulator.jl` — `@compat public` block (19 interface methods); removed stale
  `addVariationRows` interface bullet
- `src/xml_utilities.jl`, `src/runner.jl`, `src/sensitivity.jl`, `src/database.jl` —
  `@compat public` declarations with `#!` rationale
- `src/calibration/abc.jl` — three dangling `See …` pointers rewritten
- `test/runtests.jl` — `"docstrings only @ref public bindings"` testset
- `docs/src/man/building_a_simulator.md` — removed stale "Variation row writing" section
- `CLAUDE.md` — new "Docstring Cross-References" section

---

## Session: Trial-ID accessor symmetry; `trialID(::Vector{Sampling})` made a pure lookup (2026-08-17)

Work-plan item 2 of 8. Independent of items 1 and 3, which ran in parallel worktrees.

### Goal
`simulationIDs(out)` worked on an `MMOutput`; `monadIDs(out)` was a `MethodError`. Closing that
gap turned up the larger hole: `monadIDs(::Simulation)` did not exist at all, so
`monadsTable(simulation)` and `monadsTable([sim, monad])` threw — despite `monadsTable`
collecting IDs through `monadIDs(T)` and PRD.md promising "`AbstractTrial` objects (or arrays)".
Separately `trialID` was exported under two opposite meanings: a field read, and a
find-or-INSERT.

### The trap: `monadIDs(::Simulation)` must not go through `Monad(simulation)`
`Monad(simulation::Simulation)` **writes** — `INSERT OR IGNORE INTO monads … RETURNING
monad_id`, then `addSimulationID`, which rewrites the monad's `simulations.csv`. That is exactly
right for `pendingSimulationSpecs`, where materializing the enclosing monad is the point, and
exactly wrong for an accessor. The one-liner that looks obvious would have silently created a
row every time a user asked a question.

The read-only route exists because `simulations` and `monads` carry the same key columns and
`monadsSchema` declares `UNIQUE` over exactly that tuple, so a key match identifies at most one
monad. `simulations` has no `monad_id` column, so this is the only non-CSV-scanning route.

Rather than duplicate the key-tuple SQL, the builder was extracted from the `Monad` inner
constructor into `_monadKeyStrings(inputs, variation_id)`, now used by both the find-or-insert
constructor and the read-only `_monadIDForKey`. Pure move, no behavior change. The point is that
the accessor cannot drift from the writer: if the key ever gains a column, one edit covers both.

**Corrected a factual error in the planning brief.** The brief asserted that a `Simulation` from
`createTrial(inputs, dv; n_replicates=1)` has no monad row until `run` creates one, and proposed
documenting and testing that. It is false: `_buildTrial` takes the single-variation branch,
constructs `Monad(inputs, variation_ids; n_replicates=1)` — which inserts the monad and records
the constituent CSV — and only then returns `Simulation(simulationIDs(monad)[end])`. The genuine
`Int[]` case is a simulation from the raw `Simulation(inputs, variation_id)` constructor, which
touches `simulations` only. Had the brief's version been written into the docstring it would
have been actively misleading, and the test built on it would have failed for the wrong reason.
The test now mints a variation row via `addVariations` *without* a monad, so the key genuinely
has no match.

Returning `Int[]` rather than throwing: `monadIDs` returns a `Vector` at every other level,
`monadIDs(trial)` already used `init=Int[]`, and an empty `monadsTable` beats an error. Verified
empirically that the empty path is clean end to end — SQLite accepts `IN ()` and evaluates it
false, and `_variationsTableFromQuery` returns a 0-row frame with columns intact (the
`remove_constants` branch is guarded by `size(df,1) > 1`).

### `trialID(::Vector{Sampling})`: lookup and create split
The old method scanned `trials` and, on a miss, INSERTed a row plus `recordConstituentIDs` and
`applyCreationTags` — the exact opposite of `trialID(::AbstractTrial) = T.id`, under the same
exported name. Now a pure `SELECT` returning `missing` on no match; the insert block moved
verbatim into `_findOrCreateTrialID`, called by `Trial(Ss::AbstractArray{<:AbstractSampling})`,
its only caller. Blast radius verified: one caller, zero tests, zero `docs/`.

`missing`, not `nothing`. The planning brief argued for `nothing` on the grounds that it matches
Julia's `findfirst` convention and that this repo reserves `missing` for absent DB *data* (as in
`eraseSimulationIDFromConstituents(…; monad_id=missing)`). The user had asked for `missing`
explicitly and reaffirmed it when the brief was presented, so `missing` it is — and the
`monad_id=missing` precedent reads the same way here: a trial ID that the database does not have.

**Note for work-plan item 4.** If that brief gives each ABC generation its own `Trial` row it
needs the create half, so it must call `_findOrCreateTrialID`, not `trialID`. The exported name
no longer creates anything.

CLAUDE.md's "Known Trade-offs" and PRD.md's concurrency bullet both named `trialID(samplings)`
as one of the two unguarded find-or-insert blocks. Both updated to name `_findOrCreateTrialID`,
which is now where an `EXCLUSIVE` transaction would have to go — and it has to span the lookup
*and* the insert, which is easier to see now that they are one function.

### Why `MMOutput` stays outside `AbstractTrial`
Subtyping would collapse six forwarding one-liners into zero, and was rejected for two
independent reasons:

1. `MMOutput` has no `id` field, so `trialID(T::AbstractTrial) = T.id`, `trialFolder`,
   `lowerClassString`, and every `T.id` in `runner.jl` / `tags.jl` / `deletion.jl` would need
   guards.
2. `run(::AbstractTrial)` would start accepting an `MMOutput` and *re-running* it, colliding
   with `run(output_ref::MMOutput{<:AbstractMonad}, args...)`, whose meaning is "build a new
   trial using this as a reference." A silent semantic change to a public method.

Also `MMOutput{T}`'s type parameter is what makes `trialType(::MMOutput{T})` a compile-time
answer; that is lost under an abstract supertype.

A `trial(out)` unwrapping accessor was also rejected: `trial` cannot be exported, because users
routinely write `trial = createTrial(...)` at top level and an exported binding of that name
makes the assignment fail outright. `out.trial` is already a documented public field, so the
field *is* the accessor. `trialOf` is the safe name if a function is ever wanted.

### Scope held
Deliberately *not* done, so the stopping rule stays defensible at "ID accessors and
trivially-derived accessors on wrapper types":
- `simulationsTable` / `monadsTable` / `postProcessingTable` taking an `MMOutput`. Each is a
  4-method family with a keyword surface; ~12 new methods to save one word over
  `simulationsTable(out.trial)`.
- `untag!` / `tags` / `hasTag` on `MMOutput`. `tag!(::MMOutput, …)` exists because it returns
  `output` and chains with the `tags=` keyword; the read/remove functions have no such
  motivation, and adding them invites the same question for `tagsTable`, `findTrials`,
  `deleteSimulations`, and everything else taking an `AbstractTrial`.

### Docstrings
`trialID` and `trialType` were exported with no docstring at all — a Definition-of-Done item 2
violation that `checkdocs=:exports` cannot see, since it audits docstrings that *exist* and
those contributed no entry to `Docs.meta`. Both now documented, plus tightened umbrella
docstrings for `simulationIDs` and `monadIDs` that enumerate every method and state the
`Int[]`-for-no-monad rule. `_monadKeyStrings`, `_monadIDForKey`, and `_findOrCreateTrialID` are
internal, so they appear only as plain code spans.

### Open questions
- `monadIDs` on an array is not deduplicated: `[sim, monad]` where the simulation lives in that
  monad yields the ID twice, and `monadsTable` collapses it back to one row only because SQL
  `IN` does. Documented as-is rather than changed — `simulationIDs` has the same property and
  changing either would be a separate, wider decision.

### Files changed
- `src/classes.jl` — `_monadKeyStrings` extraction; `_monadIDForKey`; `monadIDs(::Simulation)`;
  `monadIDs`/`length`/`trialFolder` on `MMOutput`; `trialID`/`_findOrCreateTrialID` split;
  docstrings for `trialID`, `trialType`, `simulationIDs`, `monadIDs`, `trialFolder`
- `src/sensitivity.jl` — `monadIDs(::GSASampling)`
- `src/database.jl` — `monadsTable` docstring: what a bare `Simulation` yields
- `test/runtests.jl` — non-mutation tests for both accessors; `monadsTable` regression tests for
  `Simulation` and mixed vectors; `MMOutput` forwarding; MOAT design-matrix agreement
- `docs/src/man/trial_hierarchy.md` — "Asking what a trial contains" section
- `Project.toml` — `0.8.4` → `0.9.0` (breaking)
- `README.md`, `PRD.md`, `CLAUDE.md`

### Adversarial review pass — three real defects in the first cut

An adversarial review (five independent lenses, each finding handed to a verifier prompted to
refute it, then a completeness critic) filed 7 findings; 4 survived verification and the critic
added 2. Three were real and are fixed. Recording them because two are the kind of thing that
looks like a deliberate choice once it is in the tree.

**1. `monadIDs(::Simulation)` used the ambient simulator version — real bug.** `_monadKeyStrings`
was written for the *writer*, where `currentSimulatorVersionID()` is exactly right: re-creating a
parameterization under a new simulator version is deliberately a new monad row, since the version
column is part of the `monads` `UNIQUE` key. Reusing that builder for the *reader* inherited the
ambient value, so after a simulator upgrade inside a project the lookup searched for a
version-2 monad that the upgrade had not created. Reproduced directly: a monad holding
simulations `[1,2]`, then a version bump, and `monadIDs(Simulation(1))` returns `Int[]` and
`monadsTable(Simulation(1))` zero rows while `constituentIDs(Monad, 1)` still lists simulation 1
— falsifying this method's own docstring claim that a run simulation always has its monad. Worse,
if the trial were re-created post-upgrade, the accessor would return the *version-2* monad's ID,
attributing the simulation to a monad whose replicate list excludes it.

Fixed by reading the version off the simulation's own `simulations` row (`_simulationVersionID`)
and passing it in: `_monadKeyStrings` gained an optional third argument defaulting to
`currentSimulatorVersionID()`, so the writer's behavior is unchanged by construction while the
reader supplies the recorded value. Pinned by a test that bumps the project's simulator version
and asserts the monad is still found.

One reviewer argued this was not a defect, on the grounds that the runner's own
`Monad(simulation)` also resolves against the current version and so the accessor was merely
consistent. That is true but does not rescue it: `Monad(simulation)` is a writer whose job
post-upgrade *is* to mint a new monad, whereas an accessor answering "which monad holds this
simulation" must describe the recorded past. The two now legitimately differ, which is the point.

**2. The `Int[]` rule was documented wrongly in the manual and the PRD.** Both said a simulation
inserted with `Simulation(inputs, variation_id)` yields `Int[]`. It does not when a monad already
carries that key — and `Simulation(monad::Monad)` is a documented constructor that *guarantees*
the key is shared, so this is the common case, not a collision. The accessor matches on
**parameterization, not membership**: such a simulation resolves to the monad sharing its
parameters without appearing in that monad's replicate list, and a failed simulation that
`simulationFailed` removed from the list still resolves to it. The docstring had been corrected
for this during drafting; the manual page and PRD had not, so they contradicted it. All three now
state the parameterization-vs-membership distinction explicitly, because a reader who assumes
membership will misread `monadsTable(sim)`.

**3. The manual's accessor table over-promised.** It presented five accessors as answering at
every level and accepting an `MMOutput`, but `constituentIDs(::Simulation)` throws by design
(a simulation has nothing below it) and `constituentIDs` had no `MMOutput` method at all.
Resolved by adding `constituentIDs(::MMOutput)` — a one-line forward that sits squarely inside
this change's own rule of "ID accessors on wrapper types", and whose absence made the family
incoherent — and by marking the `Simulation` exception in the table rather than papering over it.

**4. The `MMOutput`/`AbstractTrial` rationale was itself wrong, and is corrected.** The original
argument (inherited from the planning brief) was that subtyping would make `run(::AbstractTrial)`
accept an `MMOutput` and re-run it, "colliding" with `run(::MMOutput{<:AbstractMonad}, args...)`.
Both halves are wrong. Julia resolves `f(::A)` vs `f(::B, args...)` with `B<:A` in favor of the
Vararg method with no ambiguity — verified — so monad-wrapping outputs would keep dispatching
exactly where they do today. And that method does not exclusively mean "build a new trial from
this reference": with no `args` it forwards to `run(output_ref.trial)` and re-runs the wrapped
monad. The decision to stay outside the hierarchy is unchanged, but it now rests on the two
reasons that actually hold — no `id` field, and `run(::AbstractTrial)` would silently begin
accepting `MMOutput{Sampling}`/`MMOutput{Trial}` where today those are a `MethodError`.

Two findings were refuted and are recorded so they are not re-litigated: that `run` deleting an
emptied monad leaves a run simulation with `Int[]` (real mechanism, but pre-existing behavior of
`simulationFailed`, not introduced here — and now covered by the membership wording), and a
duplicate of finding 2 filed against PRD.md alone.
