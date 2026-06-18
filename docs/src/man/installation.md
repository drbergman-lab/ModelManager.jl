```@meta
CurrentModule = ModelManager
```

# Installation

ModelManager.jl is the base layer of a simulator ecosystem. How you install it depends on
whether you are *using* a backend or *building* one.

## Using a backend

If you just want to run simulations, you do not install ModelManager directly — you install
a simulator package that depends on it, such as
[PhysiCellModelManager.jl](https://github.com/drbergman-lab/PhysiCellModelManager.jl).
Installing that package pulls in ModelManager automatically. Follow that package's own
installation instructions.

## Building a backend

If you are developing a new simulator package on top of ModelManager:

### 1. Add the registry

ModelManager and its sibling packages are published in the BergmanLabRegistry. Add it once:

```julia-repl
pkg> registry add https://github.com/drbergman-lab/BergmanLabRegistry
```

### 2. Add ModelManager as a dependency

From within your package's environment:

```julia-repl
pkg> add ModelManager
```

### 3. Define your simulator and register globals

```julia
using ModelManager

mutable struct MySimulator <: AbstractSimulator
    dir::String
    # ...simulator-specific fields
end

function __init__()
    ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = MySimulator("/path"))
end
```

Then implement the required interface methods and call [`initializeModelManager`](@ref) from
your package's own initialization entry point. The full walkthrough is in
[Building a Simulator Backend](@ref building_a_simulator).

## Julia version and environment

ModelManager targets a recent stable Julia release; see the `[compat]` section of
`Project.toml` for the supported range. As always, work inside a project environment rather
than the global one:

```sh
julia --project=.
```

## Contributing to ModelManager itself

Clone the repository and develop it in a fresh environment:

```julia-repl
pkg> dev https://github.com/drbergman-lab/ModelManager.jl
```

Run the test suite with:

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
```
