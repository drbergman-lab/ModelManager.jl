```@meta
CurrentModule = ModelManager
```

# What ModelManager is

ModelManager.jl is the **generic, simulator-agnostic core** of a family of Julia packages
for running large agent-based modeling (ABM) campaigns. It owns everything that does not
depend on a particular simulator:

- the **trial hierarchy** ([`Simulation`](@ref), [`Monad`](@ref), [`Sampling`](@ref), [`Trial`](@ref)),
- **parameter variations** and space-filling designs,
- the **SQLite database** schema, queries, and migration framework,
- the **parallel runner** (with SLURM/HPC support),
- **global sensitivity analysis** (MOAT, Sobol', RBD-FAST), and
- **ABC-SMC calibration**.

Everything that *is* simulator-specific — how a simulation is actually launched, what a
"version" means, how input folders are compiled — is reached through a single extension
point: the [`AbstractSimulator`](@ref) interface.

## The ecosystem

```
        ┌─────────────────────────────────────────────┐
        │               ModelManager.jl               │
        │  trial hierarchy · variations · database ·  │
        │  runner · sensitivity · calibration         │
        └───────────────────────┬─────────────────────┘
                                │  AbstractSimulator interface
            ┌───────────────────┴───────────────────┐
            ▼                                       ▼
  PhysiCellModelManager                      (your backend)
       (PhysiCell)                            (MySimulator)
```

A simulator package depends on ModelManager, defines `MySimulator <: AbstractSimulator`,
implements the required interface methods, and registers its globals in `__init__`. The
package's users then call the package's own entry points; ModelManager runs underneath,
unaware of which simulator is plugged in.

This separation means a feature added here — say, a new sampling design or a calibration
kernel — is immediately available to *every* backend without any simulator-specific code.

## Who should read these docs?

- **Backend authors** building a new simulator package. Start with
  [Building a Simulator Backend](@ref building_a_simulator); the Core Concepts pages
  (beginning with [The trial hierarchy](@ref)) explain the machinery you are plugging into.
- **Advanced users** of a backend (e.g. PCMM) who want to understand the generic layer —
  how variations are stored, how the runner deduplicates work, what the database schema
  looks like. The concepts here are shared verbatim with the backend you use.
- **Contributors** to ModelManager itself.

!!! note "Examples need a simulator"
    Because ModelManager has no simulator of its own, the runnable examples in these docs
    assume a backend has been loaded and initialized (i.e. [`initializeModelManager`](@ref)
    has succeeded and a [`ModelManagerGlobals`](@ref) instance with a concrete `simulator`
    is registered). The API shown is identical regardless of which backend provides it.

## A minute-long tour

Once a backend is initialized, the generic workflow looks like this:

```julia
# 1. Describe which input folders a run uses (see Project configuration).
inputs = InputFolders(; config="default", custom_code="default")

# 2. Describe how to vary parameters (see Variations).
dv = DiscreteVariation(:config, XMLPath(["overall", "max_time"]), [60.0, 120.0, 240.0])

# 3. Build and run a trial. createTrial picks the right hierarchy level for you.
output = run(inputs, dv; n_replicates=3)
```

`run` builds the appropriate [trial hierarchy](@ref "The trial hierarchy") object, writes the
variations to the [database](@ref "The database"), and dispatches each pending simulation to
the [runner](@ref "Running simulations"). Re-running the same script is cheap: ModelManager
matches existing simulations and only runs what is missing.

From there you can layer on [space-filling designs](@ref "Space-filling designs"),
[sensitivity analysis](@ref "Sensitivity analysis"), or [calibration](@ref calibration_man) —
all built on the same three steps.
