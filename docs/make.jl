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
        size_threshold=250 * 2^10, # 250KB
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/drbergman-lab/ModelManager.jl",
    devbranch="main",
    push_preview=true,
)
