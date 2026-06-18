```@meta
CurrentModule = ModelManager
```

```@raw html
<p align="center"><img src="assets/logo-hero.svg" width="240" alt="ModelManager.jl"></p>
```

# ModelManager.jl

[ModelManager.jl](https://github.com/drbergman-lab/ModelManager.jl) is simulator-agnostic
infrastructure for managing agent-based modeling (ABM) campaigns in Julia. It provides the
generic base layer — a trial hierarchy, parameter variations, an SQLite database, a parallel
runner, global sensitivity analysis, and ABC-SMC calibration — that simulator-specific packages
build on by implementing the [`AbstractSimulator`](@ref) interface.

ModelManager is not used directly to run a particular simulator. Instead, a backend such as
[PhysiCellModelManager.jl](https://github.com/drbergman-lab/PhysiCellModelManager.jl) (PCMM)
implements `AbstractSimulator` and exposes the user-facing workflow. ModelManager supplies
everything underneath.

New here? Read [What ModelManager is](@ref) to understand where this package sits, then
[Installation](@ref). If you are building a backend, jump to
[Building a Simulator Backend](@ref building_a_simulator).

## Where do I look?

| I want to… | Go to |
| --- | --- |
| Understand ModelManager's role in the ecosystem | [What ModelManager is](@ref) |
| Add the package as a dependency | [Installation](@ref) |
| Understand `Simulation` / `Monad` / `Sampling` / `Trial` | [The trial hierarchy](@ref) |
| Learn how `inputs.toml` and the `data/` directory work | [Project configuration](@ref) |
| Understand the database schema and run queries | [The database](@ref) |
| Run trials in parallel or on a cluster | [Running simulations](@ref), [HPC support](@ref) |
| Change parameter values across runs | [Variations](@ref) |
| Sweep with LHS, Sobol, or RBD designs | [Space-filling designs](@ref) |
| Run a global sensitivity analysis | [Sensitivity analysis](@ref) |
| Calibrate a model to data with ABC-SMC | [Calibration](@ref calibration_man) |
| Implement a new simulator backend | [Building a Simulator Backend](@ref building_a_simulator) |
| Delete simulations or reset the database | [Managing data](@ref) |
| Look up a function's signature | the [Alphabetical index](@ref) |

## Issues

Found a bug or have a question? Please open an issue on the
[ModelManager.jl GitHub page](https://github.com/drbergman-lab/ModelManager.jl/issues).
