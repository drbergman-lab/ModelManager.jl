# Writes test/fixtures/problem_pre_0.12.jld2: a `problem.jld2` as ModelManager v0.11 saved it, with a
# hand-built `LatentVariation` (named maps) in an `LVSource` -- the struct before `flips` existed.
# Run against v0.11.0 (commit 6fa85103), not the current source:
#   git worktree add --detach /tmp/mm011 6fa85103
#   julia --project=/tmp/mm011 test/fixtures/make_problem_pre_0.12.jl test/fixtures/problem_pre_0.12.jld2
using ModelManager, Distributions, JLD2
const MM = ModelManager

# No simulator is initialised here: name the targets explicitly and bypass the constructors that
# consult the project's input locations. Loading needs none of that to be meaningful.
MM.shortVariationName(::Symbol, s::String) = s
_new(T, args...) = ccall(:jl_new_structv, Any, (Any, Ptr{Any}, UInt32), T, Any[args...], length(args))

lv = LatentVariation([Uniform(0.0, 1.0), truncated(Normal(0.75, 0.75); lower=0, upper=5)],
                     [MM.XMLPath(["overall", "max_time"]), MM.XMLPath(["overall", "dt_diffusion"])],
                     Function[first, sum], ["start", "gap"], [:config, :config];
                     target_names=["max_time", "dt_diffusion"], name="pre_0.12_lv")
manifest = MM._ProblemManifest(_new(MM.InputFolders, (;)), Any[MM.LVSource(lv)],
                               Dict{String,Any}("x" => 1.0), 2, MM.VariationID(Pair{Symbol,Int}[]),
                               nothing, nothing)
@assert pkgversion(MM) == v"0.11.0" && !hasfield(LatentVariation, :flips)
jldsave(ARGS[1]; manifest=manifest)
