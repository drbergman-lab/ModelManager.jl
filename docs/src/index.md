```@meta
CurrentModule = ModelManager
```

```@raw html
<p align="center"><img src="assets/logo-hero.svg" width="300" alt="ModelManager.jl"></p>
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

New here? Read [What ModelManager is](@ref overview) to understand where this package sits, then
[Installation](@ref installation). If you are building a backend, jump to
[Building a Simulator Backend](@ref building_a_simulator).

## Where do I look?

### Getting set up

| I want to… | Go to |
| --- | --- |
| Understand ModelManager's role in the ecosystem | [What ModelManager is](@ref overview) |
| Add the package as a dependency | [Installation](@ref installation) |
| Understand `Simulation` / `Monad` / `Sampling` / `Trial` | [The trial hierarchy](@ref trial_hierarchy) |
| Learn how `inputs.toml` and the `data/` directory work | [Project configuration](@ref project_configuration) |

### Running a campaign

| I want to… | Go to |
| --- | --- |
| Change parameter values across runs | [Variations](@ref variations) |
| Sweep with LHS, Sobol', or RBD designs | [Space-filling designs](@ref space_filling) |
| Run trials in parallel | [Running simulations](@ref running_simulations) |
| Run on a cluster or under SLURM | [HPC support](@ref hpc) |
| Re-run a script without redoing finished work | [Cheap re-runs](@ref cheap_reruns) |

### Getting results out

| I want to… | Go to |
| --- | --- |
| Compute and store a quantity of interest for each simulation | [Post-processing and quantities of interest](@ref post_processing) |
| See what I ran, as a table of parameters and outcomes | [Result tables](@ref result_tables) |
| Export results to CSV | [Result tables](@ref result_tables) |
| Label runs so I can find them again later | [Tagging and recovering simulations](@ref tagging) |
| Write my own SQL against the project database | [The database](@ref database) |

### Analyzing and fitting

| I want to… | Go to |
| --- | --- |
| Find out which parameters matter most | [Sensitivity analysis](@ref sensitivity_analysis) |
| Fit a model to data with ABC-SMC | [Calibration](@ref calibration_man) |
| Plot a sensitivity or calibration result | [Visualizing GSA results](@ref gsa_plots), [Visualizing calibration results](@ref abc_plots) |
| Work out why a calibration is failing or not converging | [When things go wrong](@ref calibration_troubleshooting) |

### Maintaining and extending

| I want to… | Go to |
| --- | --- |
| Delete simulations or reset the database | [Managing data](@ref managing_data) |
| Understand a schema change after upgrading | [Database upgrades](@ref database_upgrades) |
| Implement a new simulator backend | [Building a Simulator Backend](@ref building_a_simulator) |
| Look up a function's signature | the [Alphabetical index](@ref) |

## Issues

Found a bug or have a question? Please open an issue on the
[ModelManager.jl GitHub page](https://github.com/drbergman-lab/ModelManager.jl/issues).
