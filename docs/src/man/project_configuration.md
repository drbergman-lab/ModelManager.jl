```@meta
CurrentModule = ModelManager
```

# Project configuration

A ModelManager project is rooted at a **data directory** (`data/`). Everything about a
project — which input categories exist, where their folders live, the database — is derived
from that directory and a single configuration file inside it: `inputs.toml`.

## The data directory

[`initializeModelManager`](@ref) takes the path to `data/` and opens the project there:

```julia
initializeModelManager(MySimulator(...), "/path/to/project/data")
```

Inside `data/` ModelManager expects:

```
data/
├── inputs/
│   ├── inputs.toml          # location configuration (see below)
│   ├── configs/             # one folder per "config" input
│   │   └── default/
│   ├── custom_codes/
│   └── ...                  # one subtree per registered location
└── <database file>          # e.g. mm.db (name set by centralDBFileName)
```

The exact set of subfolders under `inputs/` is **not** hard-coded — it is whatever
`inputs.toml` declares. The database filename defaults to `mm.db` and can be overridden by a
backend via [`centralDBFileName`](@ref).

[`dataDir`](@ref) returns the active data directory; [`pathToInputsConfig`](@ref) returns the
path to `inputs.toml`; [`locationPath`](@ref) resolves the directory for a given location.

## inputs.toml

`inputs.toml` declares the project's **locations** — the categories of input that a
simulation draws from. Each top-level table is one location:

```toml
[config]
required = true
varied = true
basename = "PhysiCell_settings.xml"

[custom_code]
required = true
varied = false

[ic_cell]
required = false
varied = ["cells.csv", "cells.xml"]
basename = ["cells.csv", "cells.xml"]
path_from_inputs = ["ics", "cells"]
```

Each location table supports these keys:

| Key | Meaning |
| --- | --- |
| `required` | Whether every simulation must supply a folder for this location. |
| `varied` | Whether the location supports parameter variations. A `Bool`, or a `Vector{Bool}` (one per basename) for multi-file locations. |
| `basename` | The primary input file(s) inside each folder. Required when `varied` is true. May be a `Vector` to allow alternative file names. |
| `path_from_inputs` | Optional relative path from `inputs/` to the location's folders. Defaults to the pluralized location name (e.g. `config` → `configs/`). Path elements are validated by [`sanitizePathElement`](@ref). |

`inputs.toml` is parsed by [`parseProjectInputsConfigurationFile`](@ref), which validates the
keys and stores the result in the project globals.

## ProjectLocations

The parsed configuration is summarized by [`ProjectLocations`](@ref), reachable via
[`projectLocations`](@ref):

```julia-repl
julia> projectLocations()
```

It exposes three tuples of location symbols:

- `all` — every registered location (alphabetically sorted),
- `required` — locations whose folder is mandatory,
- `varied` — locations that support variations.

These drive the rest of the framework: [`InputFolders`](@ref) iterates `all` to build a
canonical [`NamedTuple`](https://docs.julialang.org/en/v1/base/base/#Core.NamedTuple), the
database schema generates one ID column per location, and [`VariationID`](@ref) tracks one
entry per `varied` location.

## Location naming helpers

A family of small functions derives the database and filesystem names for a location from
its symbol. These keep the schema and folder layout consistent:

| Function | Example (`:config`) |
| --- | --- |
| [`locationTableName`](@ref) | `"configs"` |
| [`locationIDName`](@ref) | `"config_id"` |
| [`locationVariationIDName`](@ref) | `"config_variation_id"` |
| [`locationVariationsTableName`](@ref) | `"config_variations"` |
| [`locationVariationsDBName`](@ref) | `"config_variations.db"` |
| [`locationFolder`](@ref) | `"configs"` |

Backends and advanced users generally rely on these rather than hard-coding column or table
names. See the [Project configuration](@ref) API reference for the full list.
