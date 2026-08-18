# CLAUDE.md — ModelManager.jl

## About the User
Assistant professor working on computational modeling of cancer-immune interactions, mechanistic modeling, and agent-based modeling frameworks.

## Key Documents — Read These First

| Document | Purpose |
|----------|---------|
| [README.md](README.md) | Project overview + **Implementation Status** (what is built, what remains) |
| [PRD.md](PRD.md) | Behavioral specification for every feature — acceptance criteria and edge cases |
| [progress.md](progress.md) | Session journal: decisions made, approaches rejected, open questions |

Start any feature session by reading the relevant PRD entry and the Implementation Status section of `README.md`.

## Project Overview
ModelManager.jl is a simulator-agnostic Julia package providing the generic ABM infrastructure used by [PhysiCellModelManager.jl](https://github.com/drbergman-lab/PhysiCellModelManager.jl) and future simulator packages. It provides:
- `AbstractSimulator` interface for simulator backends
- Trial hierarchy: `Simulation`, `Monad`, `Sampling`, `Trial`
- Parameter variation management (discrete, distributed, LHS, Sobol, RBD)
- SQLite database schema and migration framework
- Parallel simulation runner with HPC (SLURM) support
- Global sensitivity analysis (MOAT, Sobol', RBD-FAST)

**Key directories:**
- `src/` — Core logic; all generic infrastructure lives here

## Relationship to PCMM
ModelManager is the base package. PhysiCellModelManager.jl (PCMM) depends on it and implements the `AbstractSimulator` interface via `PhysiCellSimulator`. When working in this repo, do **not** modify PCMM files — treat the `AbstractSimulator` interface as the boundary.

## Scope
All work must remain strictly inside this repository folder (`~/.julia/dev/ModelManager/`).
Do **not** access or edit files outside this repo.

## Worktree Sessions

When Claude Code launches a session inside a git worktree (primary working directory ends with `.claude/worktrees/<name>`), **all file reads and writes must use paths rooted at the worktree, not the main repo root.** The main repo may appear as an "Additional working directory" in the environment block — ignore it for file edits; it is listed only so `julia --project=.` and `git` commands can resolve the package, not as a write target.

**Concretely:** if the worktree is at `~/.julia/dev/ModelManager/.claude/worktrees/foo`, edit `~/.julia/dev/ModelManager/.claude/worktrees/foo/src/calibration/abc.jl`, NOT `~/.julia/dev/ModelManager/src/calibration/abc.jl`.

**Pitfall — resumed sessions:** When a session is resumed from a compacted summary, the summary may cite main-repo paths from prior reads. Discard those paths and re-derive the correct worktree-rooted path before making any edits. Always confirm with `git -C <worktree> status` that your changes appear in the worktree, not the main repo.

## Git Workflow — Division of Responsibilities

> **Environment note:** The restrictions in this section are specific to **Cowork** (Claude desktop app), which runs shell commands in a sandboxed Linux environment that blocks `unlink` on `.git/` files. If you are using **Claude Code** (the CLI tool), it runs directly on your machine with your own filesystem permissions and has no such restriction — Claude Code can freely run `git add`, `git commit`, `git checkout`, and any other git operation exactly as you would from your terminal. The conservative rules below can be dropped entirely when using Claude Code.

**The Cowork sandbox blocks `unlink` on files inside `.git/`**, even for the owning process. This means every git command that writes to HEAD or the index (`git commit`, `git checkout`, `git add`) leaves an orphaned lock file (`HEAD.lock`, `index.lock`) that requires manual cleanup from the user's terminal. There is no way to avoid this from inside the sandbox.

Therefore the workflow is:

**Claude's git responsibilities (read-only + ref creation):**
- `git log`, `git status`, `git diff`, `git show` — freely
- `git branch feature/<desc>` — safe: writes only a ref file, not HEAD or the index

**User's git responsibilities (run from your own terminal):**
- `git checkout feature/<desc>` — after Claude creates the branch with `git branch`
- `git add` and `git commit` — Claude will provide the exact command to copy-paste
- Any operation that requires switching branches

When a feature is ready to commit, Claude will output the full command:
```
git add -A && git commit -m "<message>"
```
for the user to run, rather than running it from the sandbox.

### Branching Rules
- Never modify `main` directly.
- Default base branch is `main` unless the user specifies another base.
- Claude creates the branch ref with `git branch feature/<desc>` (pointing at current HEAD).
- User runs `git checkout feature/<desc>` from their terminal to switch.
- **Never use `git checkout -b feature/<desc> <base>` when `<base>` differs from the current HEAD.** That form forces git to update both the index and working-tree files atomically; if the filesystem blocks the unlinking step, the index is left stranded at `<base>` while HEAD stays on the old branch, producing a severely dirty repo state.

## Local Julia Environment
Always use the project environment:
- `julia --project=.`
Preferred test command:
- `julia --project=. -e 'using Pkg; Pkg.test()'`

## Allowed / Cautioned Commands
Allowed:
- `ls`, `cat`, `rg`/`grep`, build commands, test commands
- `git branch`, `git diff`, `git log`, `git status`, `git show`

Cautioned:
- `rm` — use only within the repo; can create `claude-temp/` for scratch space
- `mv` — can use within the repo so files remain tracked
- `sudo`, global package installs — ask for user input before running
- Any command writing outside this repo's root

## Prohibited
- **Never read from or write to any file inside the `.git/` directory**, including index files, refs, or objects. This includes using the Read, Write, Edit, or Bash tools to touch anything under `.git/` directly. All git state must be modified exclusively through git CLI commands.
- **Never run `git add`, `git commit`, or `git checkout`** from the sandbox. These write to HEAD or the index and leave lock files that require manual user cleanup. Instead, output the command for the user to run in their terminal.

## Naming Conventions

- **Functions:** `camelCase` (e.g., `addVariations`, `createTrial`, `runSensitivitySampling`)
- **Types / Structs:** `PascalCase` (e.g., `InputFolders`, `DiscreteVariation`, `ModelManagerGlobals`)
- **Constants / globals:** `snake_case` for internal module globals (e.g., `mm_globals_ref`); `SCREAMING_SNAKE_CASE` for environment variables
- **Files:** `snake_case.jl` for source files
- **Interface methods:** defined as bare `function foo end` stubs in `abstract_simulator.jl`; concrete implementations live in the simulator package. Unexported but declared `@compat public` — see [Docstring Cross-References](#docstring-cross-references)
- **Exported vs internal:** public API is exported from the relevant `src/*.jl` file; internal helpers are prefixed with `_`

## Docstring Length

**Rule: spend words only on what a reader cannot infer from the signature. Everything else is
noise, and a wrong example is worse than no example.**

Most accessors need one to three sentences and nothing else. Do **not** reach for
`# Arguments` / `# Returns` / `# Examples` by default — that structure is for functions with a real
keyword surface or a genuinely non-obvious contract (`run`, `createTrial`, `simulationsTable`,
`runABC`), not for `trialID` or `trialType`.

What earns length:

- a return value the signature does not imply — `trialID(::Vector{Sampling})` gives `missing` and
  never creates a row;
- a distinction a reader will otherwise get wrong — `monadIDs(::Simulation)` matches on
  *parameterization*, not membership, so it resolves to a monad that may not list that simulation;
- keyword arguments, and which of several methods a keyword applies to.

What does not: restating the argument list in prose, naming the return type when it is already in
the signature, or an example that only shows the obvious call.

**Verify every example against actual dispatch before writing it.** A `trialType` docstring once
claimed `createTrial(inputs, dv; n_replicates=1)` yields a `Simulation` and `[dv1, dv2]` yields a
`Sampling`. Both are wrong: the trial type follows from how many *values* the variations carry, so
one `DiscreteVariation` over three values is a `Sampling` at any replicate count. An example that
teaches the wrong mental model does more damage than the omission it was filling.

The same rule governs `docs/src/man/*.md`: a manual page describes how the code behaves, never
which cases the current change happened to touch. If a list of "cases worth knowing about" is
really an inventory of your diff, delete it — the substance belongs in the docstring and the
reasoning in `progress.md`.

## Docstring Cross-References

**Rule: a docstring may only `[`link`](@ref)` to a *public* binding — one that is either
`export`ed or declared with `@compat public`. Never `@ref` an internal.**

ModelManager's docstrings are rendered in *downstream* docs builds (PhysiCellModelManager
and future simulator packages), not just its own. A downstream build renders only
ModelManager's public API, so an `@ref` pointing at a private binding cannot be resolved
there and terminates `makedocs` with a `:cross_references` error:

```
Error: Cannot resolve @ref for md"[`_buildEvaluateBatch`](@ref)" in docs/src/lib/calibration.md.
- No docstring found in doc for binding `ModelManager._buildEvaluateBatch`.
```

**This used to be invisible locally.** Every `docs/src/lib/*.md` page once carried both a
`Private = false` and a `Public = false` `@autodocs` block, so locally *everything* was
rendered, *every* `@ref` resolved, and the failure appeared only downstream. As of the docs
findability pass, the `Public = false` blocks are gone — private docstrings are no longer
rendered on ModelManager's own site — so an `@ref` to an internal now breaks `makedocs` here
too. (They were removed for a different reason: 86 underscore-prefixed entries were 16% of
the search index and were outranking the prose pages that explain the features.)

Do not rely on the docs build as the guard. It only runs in CI's `docs` job, and it does not
cover a docstring whose `@ref` happens to point at a *nonexistent* name. The guard is the
`"docstrings only @ref public bindings"` testset in `test/runtests.jl`, which walks
`Docs.meta(ModelManager)` and checks each `@ref` target with `Base.ispublic`. It runs with
the normal test suite, needs no docs build, and is the thing that will actually catch you.

Note the testset scans **docstrings only** — `@ref`s written in `docs/src/**/*.md` manual
pages are outside its loop. A manual page that `@ref`s an internal is caught by the docs
build now, but was not before.

### Writing a new docstring

- Referring to an internal? Use a plain code span — `` `_buildSimulationBank` `` — not a link.
  Readers who need it are reading the source anyway.
- Never leave a dangling `See `_someInternal`.` — a pointer the reader cannot follow is worse
  than no pointer. State the substance inline instead. (When `runCalibration` said
  "See [`_buildEvaluateBatch`](@ref)" for where failures are recorded, the fix was to name the
  actual files, `generations/generation_{NNN}_failed_simulations.csv`.)
- Never document an exported function's arguments *only* on a private function it delegates to.

### When to declare something public instead

If a name is genuinely part of the API but deliberately unexported, declare it rather than
delinking. `@compat public foo` (Compat is already a dep; a no-op on the Julia 1.10 floor, a
real `public` on 1.11+, which Documenter's `Private = false` honors). Add a `#!` comment saying
why. This is correct for:

- **`AbstractSimulator` interface methods** — a simulator package implements
  `ModelManager.runSimulation`, it never calls an exported one, but these are the documented
  contract in "Building a Simulator Backend". Declared in `src/abstract_simulator.jl`, plus
  `postVariationXMLProcessing` in `src/xml_utilities.jl`.
- **Types appearing in public signatures** — `SimulationSpec`, `SimulationProcess`,
  `GSASampling` (the return type of the exported `run(::GSAMethod, ...)`).
- **The documentation home for an exported wrapper's keywords** — `simulationsTableFromQuery`
  and `monadsTableFromQuery` carry the full keyword docs for `simulationsTable`/`monadsTable`.

**Julia version floor.** `Base.ispublic` and the `public` keyword are both 1.11+, while
`Project.toml` declares `julia = "1.10"` and CI's matrix includes `lts`. The guard test is
therefore wrapped in `@static if isdefined(Base, :ispublic)` — on 1.10 `@compat public` is inert,
so every declared name would look private and the test would report false violations. For the
same reason the **docs job must run Julia 1.11+** (it uses `version: '1'`); on `lts`, Documenter's
`Private = false` would silently drop every interface method from the public API section.

Two further cautions. Julia **errors** if you declare an already-exported name public, so check first
(`postInitDisplay` and `centralDBFileName` are exported and must stay out of those blocks).
And `public` is an API commitment — default to delinking. Do not promote a name just to keep
a hyperlink alive: `addVariationRows` looked like an interface method because two stale docs
described it as `addVariationRows(sim::MySimulator, ...)`, but it takes no simulator argument
and is internal. Verify against the actual signature.

## Required Workflow for Any Change
1. Generate a **design brief** in the assistant response **before any code changes**.
2. Wait for human approval.
   1. Update the PRD.md to include new feature or changes.
   2. Open a new entry in the progress.md and start logging the design process, decisions, and open questions there.
3. Run `git branch feature/<desc>` to create the branch ref, then tell the user to run `git checkout feature/<desc>` from their terminal before implementation begins.
4. Implement in the feature branch only.
5. Update [README.md](README.md) Implementation Status when a feature is complete.
6. Trim the PRD.md and progress.md to reflect the final implementation before merging.
7. When done, output the ready-to-run commit command for the user to copy-paste into their terminal.

**Design brief template:**
```
# Design Brief: [Feature/Refactor Name]

## Motivation
[1-2 sentences: Why is this change needed? What problem does it solve?]

## Scope
- **Files affected:** `src/module1.jl`, `src/module2.jl`
- **New files:** `src/new_file.jl` (if applicable)
- **Breaking changes:** Yes/No — [describe if yes]

## Proposed Architecture
[2-3 paragraphs or a simple diagram showing the change]
- Current: [brief description]
- Proposed: [brief description]
- Key decisions: [why this approach over alternatives]

## Testing Strategy
- Unit tests for: [list what gets tested]
- Integration tests: [if applicable]

## Estimated Effort
- Lines of code: ~[estimate]
- Risk level: Low / Medium / High
- Dependencies: [any external changes needed first?]
```

## Definition of Done

A feature is complete when **all** of the following are true:

1. **Tests pass:** `julia --project=. -e 'using Pkg; Pkg.test()'` runs green.
2. **Docstrings written:** Every exported function has a docstring. Length is earned by
   non-obvious content, not owed by default — see [Docstring Length](#docstring-length).
3. **README updated:** Implementation Status section marks the feature as complete.
4. **PRD reflects reality:** If implementation deviated from the PRD, update the PRD entry.
5. **No regressions:** Full test suite has no new failures.

## ModelManager-Specific Guidance
ModelManager is **simulator-agnostic** infrastructure. Therefore:
- No PhysiCell-specific logic belongs here — it goes in PCMM.
- All simulator-specific behavior must be reached through `AbstractSimulator` dispatch.
- When adding a new extension point, add a stub to `abstract_simulator.jl` with a default (no-op or error) implementation.
- If a function signature changes, update `up.jl` with a migration if it affects database schema.

## Integration Essentials
- Module entrypoint: `src/ModelManager.jl` (update includes when adding/moving files).
- Extension points for simulators: `src/abstract_simulator.jl`.
- Database changes must update both `src/database.jl` and `src/up.jl`.

## Julia Environment Rules
- Always run Julia with `--project=.`
- Do not edit `Manifest.toml` or add dependencies without explicit approval.

## Known Trade-offs

Deliberate decisions whose symptoms would otherwise look like bugs. Check here before "fixing" one.

- **Concurrent trial creation is unsupported** — in one session or across sessions. Two Julia sessions cannot corrupt the SQLite file (SQLite serializes writers), but `Sampling(monads, inputs)` and `_findOrCreateTrialID(samplings)` in `src/classes.jl` scan for a matching row before inserting, with no `UNIQUE` constraint to fall back on, so each could insert a duplicate. They also race on the constituent-ID CSVs, which no database lock covers. (`_findOrCreateTrialID` is reached only through the `Trial(Ss)` constructor; the exported `trialID(samplings)` is a pure lookup and never inserts.)
  **If duplicate or inconsistent rows show up in `samplings` or `trials`, that is the cause.** The fix is to wrap those two find-or-insert blocks in `withTransaction(mode="EXCLUSIVE")` — `withTransaction`'s `mode` keyword exists for exactly this — and to set `PRAGMA busy_timeout`, without which the losing session fails immediately with `"database is locked"` instead of waiting. For `trials`, the block to wrap is `_findOrCreateTrialID`, which must hold the transaction across both the `trialID` lookup and the insert.

  Setting that pragma has a trap worth reading before you try. `busy_timeout` lives in the connection handle, not the database file: it is not shared between connections to the same file and does not survive a close. ModelManager opens the central connection in **two** places — `initializeModelManager` (`src/globals.jl`) and `initializeDatabase` (`src/database.jl`) — and the second one **closes and reopens** the first, because `initializeModelManager` calls `initializeDatabase` right after opening. Set the pragma only in `initializeModelManager` and it is silently discarded a few lines later, with no error. Apply it through a single `openCentralDB(path)` wrapper used at both sites so it cannot be missed. The three other `SQLite.DB(...)` calls in `src/database.jl` are separate connections to separate files (per-location variations, the post-processing sink) and would each need their own.

  See `progress.md` for the measurements behind why this is off by default.

## To-dos
When setting you off on a task, check this list and assess if any of these should be done first.
- Wire the `post_processor` QoI builders (e.g. `populationCountQoI`) into sensitivity analysis and calibration workflows, so a builder's output can feed `run(::GSAMethod, ...)`/`CalibrationProblem` directly instead of only landing in the post-processing sink. Not yet done — these builders currently only target `run(...; post_processor=...)`.
- Preserve failed-simulation artifacts for post-hoc inspection. When a simulation fails, `simulationFailed` erases it from its monad's constituent list and — if it was the monad's last simulation — deletes the monad row, folder, and constituent CSV (`src/runner.jl`). The simulation's own output folder survives, but nothing records *which* variation/spec it came from or which monad it belonged to, so a failed parameter set cannot be reproduced afterwards. Proposal: a `data/outputs/failed/` area (or a per-simulation manifest) capturing the variation IDs, target parameter values, and a pointer to the simulation's output folder for every failed simulation. Worth doing at the runner level for all failed sims, not just calibration. Motivated by calibration rejections (see the `on_monad_failure` handling in `src/calibration/abc.jl`), where the per-generation failure files record simulation and monad IDs but nothing ties a failed simulation back to the variation it came from once its monad is deleted.
