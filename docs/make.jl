using Documenter, ModelManager

DocMeta.setdocmeta!(ModelManager, :DocTestSetup, :(using ModelManager); recursive=true)

makedocs(;
    modules=[ModelManager],
    authors="Daniel Bergman <danielrbergman@gmail.com> and contributors",
    sitename="ModelManager.jl",
    format=Documenter.HTML(;
        canonical="https://drbergman-lab.github.io/ModelManager.jl",
        edit_link="main",
        assets=String[],
        collapselevel=1, # collapse top-level sidebar sections by default; current page's section auto-expands
    ),
    pages=[
        "Home" => "index.md",
        "Getting Started" => Any[
            "What ModelManager is" => "man/overview.md",
            "Installation" => "man/installation.md",
        ],
        "Core Concepts" => Any[
            "The trial hierarchy" => "man/trial_hierarchy.md",
            "Project configuration" => "man/project_configuration.md",
            "The database" => "man/database.md",
            "Running simulations" => "man/running_simulations.md",
            "HPC support" => "man/hpc.md",
        ],
        "Varying Parameters" => Any[
            "Variations" => "man/variations.md",
            "Space-filling designs" => "man/space_filling.md",
        ],
        "Uncertainty Quantification" => Any[
            "Sensitivity analysis" => "man/sensitivity_analysis.md",
            "Calibration" => "man/calibration.md",
        ],
        "Building a Simulator Backend" => "man/building_a_simulator.md",
        "Reference" => Any[
            "Managing data" => "man/managing_data.md",
            "Database upgrades" => "misc/database_upgrades.md",
        ],
        # Index: the exhaustive home for docstrings, grouped by code family (not
        # mirroring the Manual). NOTE: this list is maintained by hand — when adding
        # a new docs/src/lib/*.md page, add it to a group below.
        "Index" => Any[
            "Core" => map(s -> "lib/$(s)", [
                "ModelManager.md", "globals.md", "user_api.md", "utilities.md", "classes.md",
            ]),
            "Project & inputs" => map(s -> "lib/$(s)", [
                "project_configuration.md", "variations.md", "xml_utilities.md",
            ]),
            "Running simulations" => map(s -> "lib/$(s)", [
                "runner.md", "abstract_simulator.md", "recorder.md", "hpc.md",
            ]),
            "Analysis & calibration" => map(s -> "lib/$(s)", [
                "sensitivity.md", "calibration.md",
            ]),
            "Management & maintenance" => map(s -> "lib/$(s)", [
                "database.md", "deletion.md", "up.md", "package_version.md",
            ]),
            "Alphabetical index" => "lib/index.md",
        ],
    ],
    checkdocs=:exports,
)

deploydocs(;
    repo="github.com/drbergman-lab/ModelManager.jl",
    devbranch="main",
    push_preview=true,
)
