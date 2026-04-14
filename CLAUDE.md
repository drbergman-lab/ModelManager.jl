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
ModelManager.jl is a simulator-agnostic Julia package providing the generic ABM infrastructure used by [PhysiCellModelManager.jl](https://github.com/drbergman-lab/PhysiCellModelManager.jl) and future simulator packages (e.g. BergiCell). It provides:
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

## Branching Rules
- Never modify `main` directly.
- Default base branch is `main` unless the user specifies another base.
- For any task, create a feature branch:
```
git checkout -b feature/<desc> <base-branch>
```

## Local Julia Environment
Always use the project environment:
- `julia --project=.`
Preferred test command:
- `julia --project=. -e 'using Pkg; Pkg.test()'`

## Allowed / Cautioned Commands
Allowed:
- `ls`, `cat`, `rg`/`grep`, build commands, test commands
- `git` commands committing to the feature branch you are developing on

Cautioned:
- `rm` — use only within the repo; can create `claude-temp/` for scratch space
- `mv` — can use within the repo so files remain tracked
- `sudo`, global package installs — ask for user input before running
- Any command writing outside this repo's root

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
3. Create a feature branch off the chosen base branch.
4. Implement in the feature branch only.
5. The user will inspect diffs manually before merging.
6. Update [README.md](README.md) Implementation Status when a feature is complete.
7. Trim the PRD.md and progress.md to reflect the final implementation before merging.

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
