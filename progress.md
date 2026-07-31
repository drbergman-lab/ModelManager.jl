# progress.md — ModelManager.jl Session Journal

> **Purpose:** Session-level decisions, rejected approaches, and open questions.
> Unlike [PRD.md](PRD.md) (specification) and [README.md](README.md) (completion status), this file captures the *reasoning* behind decisions — things that would otherwise exist only in ended chat history.

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
