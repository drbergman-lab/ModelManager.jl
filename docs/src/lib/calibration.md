```@meta
CollapsedDocStrings = true
```

# [Calibration](@id calibration_lib)

Approximate Bayesian Computation (ABC-SMC) calibration: problem definition, methods,
perturbation kernels, the simulation bank, distance functions, progress reporting, and
posterior visualization. See the [Calibration](@ref calibration_man) manual page for a
narrative walkthrough.

The calibration code lives under `src/calibration/`; this page collects the docstrings
from every file in that subdirectory.

## Public API
```@autodocs
Modules = [ModelManager]
Pages = ["calibration.jl", "problem.jl", "parameters.jl", "methods.jl", "abc.jl", "abc_smc.jl", "bank.jl", "distance.jl", "progress.jl", "visualize.jl"]
Private = false
```

## Private API
```@autodocs
Modules = [ModelManager]
Pages = ["calibration.jl", "problem.jl", "parameters.jl", "methods.jl", "abc.jl", "abc_smc.jl", "bank.jl", "distance.jl", "progress.jl", "visualize.jl"]
Public = false
```
