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
- **Interface methods:** defined as bare `function foo end` stubs in `abstract_simulator.jl`; concrete implementations live in the simulator package
- **Exported vs internal:** public API is exported from the relevant `src/*.jl` file; internal helpers are prefixed with `_`

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
2. **Docstrings written:** Every exported function has a docstring with description, argument list, return value, and at least one usage example.
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

## To-dos
When setting you off on a task, check this list and assess if any of these should be done first.
- Wire the `post_processor` QoI builders (e.g. `populationCountQoI`) into sensitivity analysis and calibration workflows, so a builder's output can feed `runSensitivity`/`CalibrationProblem` directly instead of only landing in the post-processing sink. Not yet done — these builders currently only target `run(...; post_processor=...)`.
