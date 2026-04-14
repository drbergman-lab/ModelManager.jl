# ModelManager.jl Copilot Instructions

## Repository Overview

**ModelManager.jl** is the simulator-agnostic base package that provides the common infrastructure used by simulator-specific packages such as PhysiCellModelManager.jl. It owns the generic logic for trial construction, parameter variation management, sensitivity analysis, database bookkeeping, migration support, and local/HPC execution orchestration.

This repository is **not** the place for simulator-specific logic. Anything tied to a concrete simulator must remain behind the `AbstractSimulator` interface and be implemented in the downstream simulator package.

**Languages**: Julia
**Target Runtime**: Julia 1.10+
**Key Dependencies**: SQLite, DataFrames, Distributions, GlobalSensitivity, QuasiMonteCarlo

## Build and Validation Process

### Environment Setup (Always Required)
```bash
# 1. Ensure the required registries are available
julia -e 'import Pkg; Pkg.Registry.add("General"); Pkg.Registry.add(Pkg.RegistrySpec(url="https://github.com/drbergman-lab/BergmanLabRegistry.git"))'

# 2. Activate and instantiate the project environment
julia -e 'import Pkg; Pkg.activate("."); Pkg.instantiate()'
```

### Testing
```bash
# Preferred full-package test command
julia --project=. -e 'using Pkg; Pkg.test()'
```

### Known Setup Issues
- BergmanLabRegistry must be available before dependency resolution will succeed.
- If package resolution or precompilation fails, rerun `Pkg.instantiate()` after confirming the registries are installed.
- Do not assume any PhysiCell, C++, or external simulator toolchain is required in this repository unless the specific task explicitly involves downstream integration work.

## Project Architecture and Layout

### Core Source Files
```text
src/
├── ModelManager.jl            # Module entrypoint, includes, exports
├── abstract_simulator.jl      # Interface boundary for simulator packages
├── classes.jl                 # Trial hierarchy and related data structures
├── database.jl                # Generic SQLite schema and query utilities
├── deletion.jl                # Deletion/reset operations
├── globals.jl                 # ModelManagerGlobals and global accessors
├── hpc.jl                     # SLURM/HPC helpers
├── package_version.jl         # Package version helpers
├── project_configuration.jl   # Project locations and inputs.toml handling
├── recorder.jl                # Output/result recording helpers
├── runner.jl                  # Simulation execution orchestration
├── sensitivity.jl             # MOAT, Sobol', and RBD support
├── up.jl                      # Migration framework
├── user_api.jl                # User-facing convenience API
├── utilities.jl              # Shared utilities
└── variations.jl             # Variation types and sampling machinery
```

### Key Architectural Components
- **AbstractSimulator boundary**: all simulator-specific behavior is dispatched through methods declared in `abstract_simulator.jl`.
- **Global state**: `ModelManagerGlobals` holds generic package state and must be initialized by the downstream simulator package.
- **Trial hierarchy**: `Trial > Sampling > Monad > Simulation` organizes simulation studies.
- **Variation system**: discrete, distributed, co-varied, latent, and space-filling designs are handled generically here.
- **Database layer**: SQLite tracks provenance, deduplicates work, and supports migration across package versions.
- **Runner/HPC layer**: local parallel execution and SLURM-oriented helpers live here, but without simulator-specific runtime assumptions.

### Repository-Level Guidance
- `README.md` contains the project overview and implementation status.
- `PRD.md` is the behavioral specification for the package.
- `progress.md` is the running design log for in-flight work.
- `.github/workflows/` contains CI, CompatHelper, and TagBot automation.

## Scope Boundaries

### What belongs here
- Generic simulation-management abstractions
- Shared database and migration infrastructure
- Generic variation and sensitivity-analysis logic
- Simulator extension points via `AbstractSimulator`

### What does not belong here
- PhysiCell-specific compilation or runtime behavior
- XML conventions, file layouts, or executables that only make sense for one simulator
- Downstream package initialization details beyond the abstract interface contract

When changing behavior, prefer moving simulator-specific work out of ModelManager rather than adding new package-level special cases here.

## Validation and CI Expectations

### GitHub Actions Coverage
- CI runs on Ubuntu and macOS.
- Julia versions include LTS, stable `1`, and `pre`.
- CI adds both `General` and `BergmanLabRegistry` before building and testing.
- The package test command is the source of truth for validation unless the task is explicitly narrower.

### Pre-commit Validation Steps
1. Confirm registry setup and instantiate the environment.
2. Run `julia --project=. -e 'using Pkg; Pkg.test()'` when the change could affect package behavior.
3. Keep changes simulator-agnostic and verify they do not cross the `AbstractSimulator` boundary.
4. Update `README.md`, `PRD.md`, or `progress.md` when the change alters implementation status, intended behavior, or design history.

## Working Rules for This Repo

1. Treat ModelManager as the base layer used by downstream simulator packages.
2. Do not add PhysiCell-specific logic here.
3. Keep changes inside this repository only.
4. Prefer minimal, targeted changes that preserve the public interface unless the task explicitly requires an API change.
5. Use `julia --project=.` for Julia commands.
6. Do not edit `Manifest.toml` or add dependencies without explicit approval.

## Quick Development Workflow

1. Read `README.md` and the relevant section of `PRD.md` before making behavioral changes.
2. Check `progress.md` for active design context if the task is part of ongoing feature work.
3. Implement generic infrastructure changes in `src/` and keep simulator-specific behavior behind interface dispatch.
4. Validate with `Pkg.test()` when appropriate.
5. Update status/specification documents when the implementation meaningfully changes.

**Use these instructions as the default mental model for this repository: ModelManager.jl is generic infrastructure, and simulator packages are the integration layer.**
