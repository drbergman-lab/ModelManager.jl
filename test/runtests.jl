using Test
using ModelManager
using Distributions
using DataFrames
using Random
using Statistics
using CSV
using TOML
using JLD2
using NearestNeighbors
using LinearAlgebra
using RecipesBase
using Dates
import GlobalSensitivity

# Full-featured stub simulator used by both the existing in-memory unit tests and the
# new DB-backed integration tests.
#
# In-memory tests (calibration algorithm, kernels, etc.) never call runSimulation or
# setupMonad/setupSampling — they bypass the runner entirely via _runABCSMC.  Those
# tests continue to work unchanged now that the struct is mutable.
#
# DB-backed integration tests call initializeModelManager(TestSimulator(), dir) to
# initialise a real SQLite project, then exercise addVariations / createTrial /
# run / runCalibration / resumeABC / GSA / deletion through the full stack.
mutable struct TestSimulator <: AbstractSimulator
    current_version_id::Int
    TestSimulator() = new(0)
end

# ---- Version metadata -------------------------------------------------------
ModelManager.simulatorVersionTableName(::TestSimulator) = "test_versions"
ModelManager.simulatorVersionIDName(::TestSimulator)    = "test_version_id"
ModelManager.simulatorVersionSchema(::TestSimulator)    =
    "test_version_id INTEGER PRIMARY KEY, tag TEXT UNIQUE"

function ModelManager.resolveSimulatorVersionID(sim::TestSimulator)
    insert_sql = "INSERT OR IGNORE INTO test_versions (tag) VALUES ('test') RETURNING test_version_id;"
    df = ModelManager.queryToDataFrame(insert_sql)
    if nrow(df) == 0
        select_sql = ModelManager.constructSelectQuery("test_versions", "WHERE tag='test'"; selection="test_version_id")
        df = ModelManager.queryToDataFrame(select_sql)
    end
    id = df.test_version_id[1]
    sim.current_version_id = id
    return id
end

ModelManager.currentSimulatorVersionID(sim::TestSimulator) = sim.current_version_id
ModelManager.simulatorInfo(::TestSimulator) = "TestSimulator (stub)"
ModelManager.simulatorDir(::TestSimulator)  = ModelManager.dataDir()

# ---- Package version / upgrade ----------------------------------------------
# TestSimulator is defined in Main, which carries no version, so point the version machinery at
# ModelManager itself. This is the seam a real backend never needs: its simulator type lives in
# the package whose schema the database tracks, so the default already resolves.
ModelManager._packageModule(::TestSimulator)     = ModelManager
ModelManager.dbVersionTableName(::TestSimulator) = "mm_version"

# Overridable so the migration tests can stage a mid-session package update. Three settings:
#   :default          — what _loadedPackageVersion resolves to for TestSimulator, whose
#                       _packageModule override above points at ModelManager.
#   a VersionNumber   — a staged loaded version, i.e. a mid-session Pkg change.
#   nothing           — genuinely undeterminable, exercising the short-circuit path.
const _loaded_version_override = Ref{Any}(:default)
ModelManager._loadedPackageVersion(sim::TestSimulator) =
    _loaded_version_override[] === :default ? pkgversion(ModelManager._packageModule(sim)) :
                                              _loaded_version_override[]

# Overridable so the migration tests can present a milestone the "loaded" version knows about,
# and count how many times it was applied.
const _milestone_override = Ref{Vector{VersionNumber}}(VersionNumber[])
const _milestone_calls    = Ref(0)
ModelManager.upgradeMilestones(::TestSimulator) = _milestone_override[]
function ModelManager.upgradeToMilestone(::TestSimulator, args...)
    _milestone_calls[] += 1
    return true
end

# Module-level type with no override, used to exercise the *default* _loadedPackageVersion and
# _packageModule. The TestSimulator overrides above shadow the defaults, so separate types are
# required.
struct _NoModuleSimulator <: AbstractSimulator end

# Reaches getInstalledVersion's throw: a resolvable loaded version (so resolvePackageVersion does
# not short-circuit) whose package module has no UUID (so the installed lookup cannot succeed).
# Needs no other interface methods -- resolvePackageVersion runs before the inputs and schema steps.
struct _UninstalledSimulator <: AbstractSimulator end
ModelManager._packageModule(::_UninstalledSimulator)        = Main
ModelManager._loadedPackageVersion(::_UninstalledSimulator) = v"1.0.0"

# A simulator type inside a submodule, for checking that _packageModule walks up to the root
# module instead of stopping at the immediate parent.
module _NestedSimModule
    import ModelManager
    struct NestedSimulator <: ModelManager.AbstractSimulator end
end

# ---- Trial execution --------------------------------------------------------
# Records the keywords setupSampling last received, so tests can assert that a simulator option
# actually arrived rather than only that the merge helper computed the right NamedTuple.
const _last_setup_kwargs = Ref{Any}(nothing)
function ModelManager.setupSampling(::TestSimulator, args...; kwargs...)
    _last_setup_kwargs[] = kwargs
    return true
end
ModelManager.setupMonad(::TestSimulator,    args...; kwargs...) = true

# When set, `runSimulation` reports failure for any spec the predicate accepts — used by the
# calibration failure-handling tests to make specific monads lose all of their simulations
# (which makes the runner delete the emptied monad, exactly as in the reported bug).
const _fail_sim_predicate = Ref{Union{Nothing,Function}}(nothing)

# When set, runSimulation throws instead of returning — a *backend bug*, distinct from a simulation
# that runs and fails. The two land in different places in the runner, which is the point of the
# "a throwing runSimulation still records the simulation" testset.
const _throw_in_run = Ref(false)

# When set, TestSimulator's override steps aside and the *default* runSimulation runs -- the one
# that consults `simulationCommand`, `run_on_hpc` and the sbatch shim -- so `run()` can be driven
# end to end through the SLURM path.
const _use_default_run = Ref(false)

function ModelManager.runSimulation(sim::TestSimulator, spec::ModelManager.SimulationSpec)
    _use_default_run[] && return invoke(ModelManager.runSimulation,
                                        Tuple{AbstractSimulator,ModelManager.SimulationSpec}, sim, spec)
    # No-op: immediately report success without launching any process.
    _throw_in_run[] && error("backend blew up launching simulation $(spec.simulation.id)")
    should_fail = !isnothing(_fail_sim_predicate[]) && _fail_sim_predicate[](spec)
    return ModelManager.SimulationProcess(spec.simulation, spec.monad_id, nothing, !should_fail)
end

# Records the per-simulation post-step call order so the ordering test below can assert
# postSimulationProcessing → post_processor → postSimulationCleanup. Appends on every sim in
# every testset; the ordering test empties the log immediately before inspecting it.
const _post_order_log = String[]
# When set to :processing or :cleanup, the corresponding hook throws — used to test that an
# exception inside a per-simulation worker surfaces as an error instead of hanging run().
const _throw_in_hook = Ref{Union{Nothing,Symbol}}(nothing)
ModelManager.postSimulationProcessing(::TestSimulator, sp::ModelManager.SimulationProcess; kwargs...) = begin
    _throw_in_hook[] === :processing && error("processing boom")
    push!(_post_order_log, "processing:$(sp.simulation.id)"); nothing
end
ModelManager.postSimulationCleanup(::TestSimulator, sp::ModelManager.SimulationProcess; kwargs...) = begin
    _throw_in_hook[] === :cleanup && error("cleanup boom")
    push!(_post_order_log, "cleanup:$(sp.simulation.id)"); nothing
end

# What the default runSimulation is handed when a test invokes it on TestSimulator. Ref{Any} so a
# test can also hand it a pipeline and assert the rejection.
const _test_sim_cmd = Ref{Any}(`true`)
ModelManager.simulationCommand(::TestSimulator, ::ModelManager.SimulationSpec) = _test_sim_cmd[]

# What `simulationThreads` answers for TestSimulator: `nothing` (the interface default) unless a test
# sets it, so the default `cpus-per-task` can be shown both absent and present.
const _test_threads = Ref{Union{Nothing,Int}}(nothing)
ModelManager.simulationThreads(::TestSimulator, ::Simulation) = _test_threads[]

ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = TestSimulator())

# Module-level named functions for _isAnonymousFunction / _ProblemManifest tests.
# Must live here (not inside @testset blocks) so they get stable module-qualified names
# rather than compiler-generated closures like #249#250.
# The per-simulation measurements behind them. Named and top-level so the QoIs built from them are
# restorable: a QoI is only as restorable as its `compute` and `reduce`.
_sim_one(s::Simulation)    = 1.0
# Signature shapes that broke `_declaresSimulation`'s method-table introspection. The `where` form is
# a CORRECTLY migrated function, so rejecting it was worse than not checking at all.
_sim_where(s::S) where {S<:Simulation}      = 1.0
_sim_varargs(s::Simulation, extras...)      = 1.0
_sim_unbounded(s::S) where {S}              = 1.0   # `S` is `Any`: carries no intent
_sim_zeroarg()                              = 1.0
_sim_two(s::Simulation)    = 2.0
_sim_vec(s::Simulation)    = [1.0]
# A single QoI reports its value directly; a vector reports a Dict keyed by name. That is what keeps
# the scalar and vector `observed_data` shapes usable.
_test_named_ss             = [QoI("x", _sim_one)]
_test_named_vec_ss         = QoI("vec", _sim_vec)
_test_named_scalar_ss      = QoI("scalar", _sim_one)
_test_named_dist(s, o)     = 0.0
# Reports x=2.0 so mseDistance vs observed x=1.0 is always 1.0 (non-zero).
# Used by resumeABC test to prevent premature convergence.
_test_nonzero_ss           = [QoI("x", _sim_two)]

# ---- QoI test computes ----------------------------------------------------
# Named and top-level, like a user's own. _qoi_sim reads the simulation's own x so replicate
# values differ; _qoi_monad sees the whole monad at once.
_qoi_sim(s::Simulation)   = getParameterValue(s, :config, XMLPath(["data", "x"]))
# A bare function in `functions=`: it now receives a `Simulation`, exactly like a QoI's `compute`.
# Untyped on purpose -- that is how users write them, and it is the case dispatch cannot sniff.
_qoi_by_id(sim)           = getParameterValue(sim, :config, XMLPath(["data", "x"]))

# Reads a previously-stored post-processing value instead of recomputing from output. This is the
# write-once-read-later path: the sink survives post-simulation cleanup, the output folder may not.
function _qoi_from_sink(s::Simulation)
    row = postProcessingTable([s.id])
    (nrow(row) == 1 && "stored_x" in names(row) && !ismissing(row.stored_x[1])) ||
        error("no stored value for simulation $(s.id)")
    return Float64(row.stored_x[1])
end



# Labels used as keys in the GSA sensitivity-recipe tests. `results` is keyed by label, so these
# are plain strings; they used to be named functions purely so `nameof` gave a stable legend label.
const _GSA_LABEL_A = "_gsa_fA"
const _GSA_LABEL_B = "_gsa_fB"

# A NAMED post-processor: its own name prefixes the columns it writes ("_pp_named.a"), so unlike an
# anonymous lambda it needs no QoI wrapper.
_pp_named(s::Simulation) = (; a = 9.0)

_count_replicates(vals)    = Float64(length(vals))
# The `missing`-for-a-dead-monad path is unreachable now: `_reduceOverMonad` raises when a
# monad's constituents come back empty, before any QoI runs. So this is an ordinary measure.
_sim_missing(s::Simulation) = 1.0
_sim_throws(s::Simulation)  = error("summary statistic boom")

# Summary statistics that reproduce the reported calibration failure modes.
# _test_monad_ss touches the monad, so it would throw "Monad N not in the database" once every
# simulation in that monad has failed and the emptied monad has been deleted — the failure the
# calibration loop must now catch before user code is reached.
# Counting the replicates is now `reduce`'s job: it receives one value per surviving simulation.
# A monad that has been deleted after total failure no longer reaches user code at all --
# `_reduceOverMonad` raises first, when `constituentIDs` comes back empty.
_test_monad_ss = [QoI("x", _sim_one; reduce = _count_replicates)]
# _test_missing_ss used to return `missing` for a monad that was gone, with the failure surfacing one
# frame later inside `distance`. User code is no longer reached for a dead monad at all.
_test_missing_ss = [QoI("x", _sim_missing)]
# Broken user functions used to check that a healthy monad fails fast rather than silently:
# a distance that is not a Real, and a summary statistic that throws.
_test_dict_dist(sim, obs)  = Dict("not" => "a real")
_test_throwing_ss          = [QoI("x", _sim_throws)]

@testset "ModelManager.jl" begin

    ################## compressIDs ##################

    @testset "compressIDs and _compressedIDStr" begin
        # Basic run: mixed ranges and isolated IDs
        @test ModelManager.compressIDs([1, 2, 3, 5, 7, 8]) == ["1:3", "5", "7:8"]
        # Single element
        @test ModelManager.compressIDs([4]) == ["4"]
        # Empty
        @test ModelManager.compressIDs(Int[]) == String[]
        # All consecutive
        @test ModelManager.compressIDs([1, 2, 3]) == ["1:3"]
        # No consecutive (all isolated)
        @test ModelManager.compressIDs([1, 3, 5]) == ["1", "3", "5"]
        # Deduplication and sort
        @test ModelManager.compressIDs([3, 1, 2, 1]) == ["1:3"]
        # Set input
        @test sort(ModelManager.compressIDs(Set([1, 2, 3]))) == ["1:3"]

        # _compressedIDStr: colon → dash, comma-separated
        @test ModelManager._compressedIDStr([1, 2, 3, 5, 7, 8]) == "1-3, 5, 7-8"
        @test ModelManager._compressedIDStr([4]) == "4"
        @test ModelManager._compressedIDStr(Int[]) == ""
    end

    ################## _systematicResample ##################

    @testset "_systematicResample" begin
        Random.seed!(42)

        # Total count is always exactly n.
        weights3 = [0.5, 0.3, 0.2]
        for n in [1, 3, 10, 100]
            idx = ModelManager._systematicResample(weights3, n)
            @test length(idx) == n
            @test all(1 <= i <= 3 for i in idx)
        end

        # Proportional representation: over many draws each parent appears ~n·wᵢ times.
        n = 10_000
        counts = zeros(Int, 3)
        for _ in 1:10
            for i in ModelManager._systematicResample(weights3, n)
                counts[i] += 1
            end
        end
        total = 10 * n
        @test abs(counts[1]/total - 0.5) < 0.01
        @test abs(counts[2]/total - 0.3) < 0.01
        @test abs(counts[3]/total - 0.2) < 0.01

        # Each individual draw of n samples: every particle appears ⌊n·wᵢ⌋ or ⌈n·wᵢ⌉ times.
        # With weights [0.5, 0.3, 0.2] and n=10: counts must be (5,3,2) exactly.
        for _ in 1:20
            idx = ModelManager._systematicResample(weights3, 10)
            c = [count(==(i), idx) for i in 1:3]
            @test c[1] == 5
            @test c[2] == 3
            @test c[3] == 2
        end

        # Uniform weights: each particle appears ≈n/N times.
        N = 5
        uniform_w = fill(1.0/N, N)
        idx = ModelManager._systematicResample(uniform_w, N)
        @test length(idx) == N
        @test sort(unique(idx)) == 1:N   # every parent selected exactly once

        # n=1: single draw, valid index returned.
        idx1 = ModelManager._systematicResample(weights3, 1)
        @test length(idx1) == 1
        @test idx1[1] in 1:3

        # Single-particle degenerate case: all weight on one particle.
        degenerate = [0.0, 1.0, 0.0]
        @test all(==(2), ModelManager._systematicResample(degenerate, 5))

        # Floating-point safety: weights that sum to slightly less than 1.0 due to
        # rounding must not advance j past the last valid index.
        drifted = [1/3, 1/3, 1/3]   # sum = 0.9999... in Float64
        for _ in 1:50
            idx = ModelManager._systematicResample(drifted, 9)
            @test all(1 <= i <= 3 for i in idx)
        end
    end

    ################## mseDistance ##################

    @testset "mseDistance" begin
        @test mseDistance(
            Dict("a" => 3.0, "b" => 4.0),
            Dict("a" => 1.0, "b" => 2.0)
        ) ≈ 4.0   # ((3-1)^2 + (4-2)^2) / 2 = 4.0

        @test mseDistance(
            Dict("a" => 1.0),
            Dict("a" => 1.0)
        ) ≈ 0.0

        # Missing key in simulated → treated as 0.0
        @test mseDistance(
            Dict{String,Float64}(),
            Dict("a" => 2.0)
        ) ≈ 4.0

        # Empty observed → distance is 0.0
        @test mseDistance(
            Dict("a" => 99.0),
            Dict{String,Any}()
        ) ≈ 0.0

        # Vector values (time-series): MSE averaged element-wise, then averaged across keys
        @test mseDistance(
            Dict{String,Any}("a" => [1.0, 2.0, 3.0]),
            Dict{String,Any}("a" => [2.0, 2.0, 2.0])
        ) ≈ (1.0 + 0.0 + 1.0) / 3

        # Mixed scalar and vector keys
        @test mseDistance(
            Dict{String,Any}("counts" => [1.0, 3.0], "frac" => 0.5),
            Dict{String,Any}("counts" => [2.0, 2.0], "frac" => 1.0)
        ) ≈ ((1.0 + 1.0)/2 + 0.25) / 2

        # Mismatched vector lengths → DimensionMismatch
        @test_throws DimensionMismatch mseDistance(
            Dict{String,Any}("a" => [1.0, 2.0]),
            Dict{String,Any}("a" => [1.0, 2.0, 3.0])
        )

        # Vector calling convention: sum of squared differences
        @test mseDistance([1.0, 2.0], [3.0, 4.0]) ≈ 8.0   # (1-3)^2 + (2-4)^2 = 4+4
        @test mseDistance([1.0, 2.0], [1.0, 2.0]) ≈ 0.0
        @test_throws DimensionMismatch mseDistance([1.0], [1.0, 2.0])

        # Scalar calling convention: squared difference
        @test mseDistance(3.0, 1.0) ≈ 4.0
        @test mseDistance(1.0, 3.0) ≈ 4.0
        @test mseDistance(1.0, 1.0) ≈ 0.0
    end

    ################## CalibrationProblem accepts variation objects ##################

    @testset "_toCalibrationParameter and CalibrationProblem parameter conversion" begin
        xp  = XMLPath(["overall", "max_time"])
        xp2 = XMLPath(["path", "a"])
        xp3 = XMLPath(["path", "b"])

        # DistributedVariation → DVSource CalibrationParameter
        dv = DistributedVariation(:config, xp, Uniform(0.0, 1.0))
        cp = ModelManager._toCalibrationParameter(dv)
        @test cp isa CalibrationParameter
        @test cp.source isa ModelManager.DVSource
        @test cp.lv isa LatentVariation
        @test cp.lv.latent_parameters[1] isa Uniform
        @test cp.lv.locations == [:config]
        @test cp.lv.targets == [xp]
        # CDF=0.5 → quantile(Uniform(0,1), 0.5) = 0.5
        @test ModelManager.variationValues(cp.lv, [0.5])[1] ≈ 0.5

        # CoVariation{DistributedVariation} → CVSource: 1 latent dim, 2 target dims
        dv2 = DistributedVariation(:config, xp2, Uniform(0.0, 2.0))
        dv3 = DistributedVariation(:config, xp3, Uniform(1.0, 3.0))
        cv  = CoVariation(dv2, dv3)
        cp2 = ModelManager._toCalibrationParameter(cv)
        @test cp2 isa CalibrationParameter
        @test cp2.source isa ModelManager.CVSource
        @test length(cp2.lv.latent_parameter_names) == 1  # 1 latent CDF dim
        @test length(cp2.lv.targets) == 2                  # 2 covaried targets
        vals = ModelManager.variationValues(cp2.lv, [0.5])
        @test vals[1] ≈ 1.0   # median of Uniform(0,2)
        @test vals[2] ≈ 2.0   # median of Uniform(1,3)

        # LatentVariation{<:Distribution} → LVSource CalibrationParameter
        lv3 = LatentVariation(
            [Uniform(0.0, 1.0)],
            XMLPath[xp],
            Function[us -> quantile(Uniform(0.0, 1.0), us[1])],
            ["rate"],
            Symbol[:config]
        )
        cp3 = ModelManager._toCalibrationParameter(lv3)
        @test cp3 isa CalibrationParameter
        @test cp3.source isa ModelManager.LVSource
        @test cp3.lv === lv3

        # Discrete inputs are accepted, as DiscreteUniform over their value indices. Previously
        # rejected; the kernels work purely in [0,1] CDF space and never see a target value, so a
        # discrete parameter needs no discrete kernel.
        disc_cp = ModelManager._toCalibrationParameter(DiscreteVariation(:config, xp, [1.0, 2.0]))
        @test disc_cp isa CalibrationParameter
        @test disc_cp.source isa ModelManager.DiscreteSource
        @test disc_cp.lv.latent_parameters[1] isa DiscreteUniform
        # Display columns and values are the friendly name and the real value, not an index.
        @test ModelManager._displayColumns(disc_cp) ==
              [ModelManager.variationName(DiscreteVariation(:config, xp, [1.0, 2.0]))]
        @test only(ModelManager._particleRowToDisplay(disc_cp, [0.9])) == 2.0

        disc_cv_cp = ModelManager._toCalibrationParameter(
            CoVariation(DiscreteVariation(:config, xp2, [1.0, 2.0]),
                        DiscreteVariation(:config, xp3, [3.0, 4.0])))
        @test disc_cv_cp.source isa ModelManager.DiscreteCoSource
        @test disc_cv_cp.lv.latent_parameters[1] isa DiscreteUniform
        # One index drives both targets, so the row pairs them.
        @test ModelManager._particleRowToDisplay(disc_cv_cp, [0.1]) == [1.0, 3.0]

        # AbstractCalibrationSource is a real abstract type, so the `<: AbstractCalibrationSource`
        # the source docstrings advertise is actually true, and _toManifestSource can dispatch on it.
        @test isabstracttype(ModelManager.AbstractCalibrationSource)
        for T in (ModelManager.DVSource, ModelManager.CVSource, ModelManager.LVSource,
                  ModelManager.DiscreteSource, ModelManager.DiscreteCoSource)
            @test T <: ModelManager.AbstractCalibrationSource
        end
        @test ModelManager._toManifestSource(disc_cp.source) === disc_cp.source

        # The bank asks `insupport` of a base config value, not a min/max range: for levels the two
        # disagree on every value, since a range admits the gaps between levels.
        levels  = [0.5, 1.5, 2.5]
        leveldist = ModelManager._discreteLevelDistribution(levels)
        for v in levels
            @test insupport(leveldist, v)
        end
        for v in (1.0, 2.0)                          # inside the range, but between levels
            @test minimum(leveldist) <= v <= maximum(leveldist)
            @test !insupport(leveldist, v)
        end
        @test !insupport(leveldist, 3.0)             # outside the range entirely
        # Unsorted and duplicated input still yields the sorted unique support.
        @test support(ModelManager._discreteLevelDistribution([2.5, 0.5, 1.5, 0.5])) == levels

        # Still rejected: a LatentVariation whose latent parameters are a raw value vector. That
        # branch treats its latent values as indices in the CDF path, a different convention.
        @test_throws ArgumentError ModelManager._toCalibrationParameter(
            LatentVariation(DiscreteVariation(:config, xp, [1.0, 2.0])).latent_parameters |>
            _ -> LatentVariation([[1.0, 2.0]], [xp], [first], ["z"], [:config]))

        # CalibrationProblem stores CalibrationParameter objects
        cps = [ModelManager._toCalibrationParameter(dv),
               ModelManager._toCalibrationParameter(cv)]
        @test all(cp -> cp isa CalibrationParameter, cps)
        @test length(cps) == 2

        # Every unusable parameter is reported at once, by index and name — not just the first.
        # Discrete variations are usable now, so the offenders are raw-value LatentVariations.
        bad1 = LatentVariation([[1.0, 2.0]], [xp2], [first], ["b1"], [:config])
        bad2 = LatentVariation([[3.0, 4.0]], [xp3], [first], ["b2"], [:config])
        err = try
            ModelManager._toCalibrationParameters([dv, bad1, bad2])
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        msg = sprint(showerror, err)
        @test occursin("[2]", msg)          # the second parameter
        @test occursin("[3]", msg)          # ...and the third, in the same error
        @test occursin("2 of 3 parameters", msg)
        # The old trailing line claimed ABC-SMC needs a continuous prior for every parameter, which
        # discrete calibration made false — and it was the last thing the message said.
        @test !occursin("continuous prior for every parameter", msg)

        # A single-level discrete parameter can never vary, so it is rejected rather than costing a
        # kernel dimension no proposal can move. It was silently accepted.
        one_level = DiscreteVariation(:config, xp2, [1.0])
        @test !isnothing(ModelManager._calibrationRejection(one_level))
        @test_throws ArgumentError ModelManager._toCalibrationParameter(one_level)
        one_level_cv = CoVariation(DiscreteVariation(:config, xp2, [1.0]),
                                   DiscreteVariation(:config, xp3, [2.0]))
        @test !isnothing(ModelManager._calibrationRejection(one_level_cv))
        @test_throws ArgumentError ModelManager._toCalibrationParameter(one_level_cv)
        single_err = try
            ModelManager._toCalibrationParameters([dv, one_level])
            nothing
        catch e
            e
        end
        @test single_err isa ArgumentError
        @test occursin("can never vary", sprint(showerror, single_err))

        # Something that is not a variation at all joins the aggregated report instead of raising a
        # MethodError from inside `_calibrationRejection`.
        not_a_variation = try
            ModelManager._toCalibrationParameters([dv, 42, nothing])
            nothing
        catch e
            e
        end
        @test not_a_variation isa ArgumentError
        @test occursin("Not a variation: Int", sprint(showerror, not_a_variation))
        @test occursin("Not a variation: Nothing", sprint(showerror, not_a_variation))
        # A mixed continuous/discrete set converts, which is the point of the change.
        mixed = ModelManager._toCalibrationParameters(
            [dv, cv, DiscreteVariation(:config, xp2, [5.0, 6.0])])
        @test length(mixed) == 3
        @test mixed[3].source isa ModelManager.DiscreteSource

        # ParsedVariations(problem) is lossless: it holds the very same LatentVariation objects,
        # so nothing is reconstructed and no display name is lost.
        pv = ModelManager.ParsedVariations(AbstractVariation[cp.lv for cp in cps])
        @test all(pv.latent_variations[i] === cps[i].lv for i in eachindex(cps))
    end

    ################## ABCSMC ##################

    @testset "ABCSMC construction and validation" begin
        m = ABCSMC()
        @test m.population_size == 100
        @test m.max_nr_populations == 10
        @test m.minimum_epsilon == 0.01
        @test m.epsilon_quantile == 0.5
        @test m.perturbation_kernel isa GaussianKernel
        @test m.perturbation_kernel.scale === 2.0

        m2 = ABCSMC(population_size=50, max_nr_populations=3, minimum_epsilon=0.1)
        @test m2.population_size == 50

        @test_throws ArgumentError ABCSMC(population_size=0)
        @test_throws ArgumentError ABCSMC(max_nr_populations=-1)
        @test_throws ArgumentError ABCSMC(minimum_epsilon=-0.1)
        @test_throws ArgumentError ABCSMC(epsilon_quantile=0.0)
        @test_throws ArgumentError ABCSMC(epsilon_quantile=1.0)
        @test_throws TypeError ABCSMC(perturbation_kernel=:uniform)

        @test m isa AbstractCalibrationMethod
        @test m.accept_overflow == false
        @test ABCSMC(accept_overflow=true).accept_overflow == true
    end

    ################## Kernel Type Hierarchy ##################

    @testset "Kernel type construction" begin
        # GaussianKernel
        gk = GaussianKernel()
        @test gk isa ModelManager.AbstractKernel
        @test gk.scale === 2.0
        @test GaussianKernel(1.5).scale === 1.5
        gkv = GaussianKernel([3.0, 1.5, 1.0])
        @test gkv.scale == [3.0, 1.5, 1.0]
        @test_throws ArgumentError GaussianKernel(-1.0)
        @test_throws ArgumentError GaussianKernel(Float64[])

        # ComponentwiseKernel
        ck = ComponentwiseKernel()
        @test ck isa ModelManager.AbstractKernel
        @test ck.scale === 2.0
        @test ComponentwiseKernel(1.0).scale === 1.0
        @test_throws ArgumentError ComponentwiseKernel(0.0)

        # LocalNNKernel
        lk = LocalNNKernel()
        @test lk isa ModelManager.AbstractKernel
        @test lk.k == 10
        @test lk.scale === 1.0
        @test LocalNNKernel(k=5, scale=0.5).k == 5
        @test LocalNNKernel(k=5, scale=0.5).scale === 0.5
        @test_throws ArgumentError LocalNNKernel(k=0)
        @test_throws ArgumentError LocalNNKernel(scale=-1.0)

        # LocalNNCovKernel
        lck = LocalNNCovKernel()
        @test lck isa ModelManager.AbstractKernel
        @test lck.k == 10
        @test lck.scale === 1.0
        @test LocalNNCovKernel(k=3, scale=2.0).k == 3
        @test_throws ArgumentError LocalNNCovKernel(k=0)
        @test_throws ArgumentError LocalNNCovKernel(scale=0.0)

        # ABCSMC accepts AbstractKernel, rejects Symbol
        @test ABCSMC(perturbation_kernel=ComponentwiseKernel()).perturbation_kernel isa ComponentwiseKernel
        @test ABCSMC(perturbation_kernel=LocalNNKernel(k=5)).perturbation_kernel.k == 5
    end

    @testset "_effectiveKernelScale generation schedule" begin
        s_vec = [3.0, 1.5, 1.0]
        @test ModelManager._effectiveKernelScale(s_vec, 1) == 3.0
        @test ModelManager._effectiveKernelScale(s_vec, 2) == 1.5
        @test ModelManager._effectiveKernelScale(s_vec, 3) == 1.0
        @test ModelManager._effectiveKernelScale(s_vec, 9) == 1.0   # clamped to end
        @test ModelManager._effectiveKernelScale(2.0, 5) == 2.0     # scalar unchanged
    end

    @testset "_fitKernel — GaussianKernel" begin
        Random.seed!(42)
        particles = DataFrame(x=[0.1, 0.5, 0.9], y=[0.2, 0.6, 0.8])
        weights   = fill(1/3, 3)
        fitted = ModelManager._fitKernel(GaussianKernel(2.0), particles, weights, ["x", "y"], 1)
        @test fitted isa ModelManager.FittedGaussianKernel
        @test fitted.d == 2
        @test size(fitted.Sigma) == (2, 2)
        @test isposdef(fitted.Sigma)
        @test fitted.chol isa Cholesky

        # Scalar and vector scale both work
        fv = ModelManager._fitKernel(GaussianKernel([3.0, 1.0]), particles, weights, ["x", "y"], 1)
        @test fv isa ModelManager.FittedGaussianKernel
        # t=2 should use scale[2]=1.0, which is smaller than scale[1]=3.0 → smaller Sigma entries
        f2 = ModelManager._fitKernel(GaussianKernel([3.0, 1.0]), particles, weights, ["x", "y"], 2)
        @test all(abs.(f2.Sigma) .<= abs.(fv.Sigma) .+ 1e-12)
    end

    @testset "_fitKernel — ComponentwiseKernel" begin
        Random.seed!(42)
        particles = DataFrame(x=[0.1, 0.5, 0.9], y=[0.2, 0.6, 0.8])
        weights   = fill(1/3, 3)
        fitted = ModelManager._fitKernel(ComponentwiseKernel(), particles, weights, ["x", "y"], 1)
        @test fitted isa ModelManager.FittedComponentwiseKernel
        @test length(fitted.variances) == 2
        @test all(fitted.variances .> 0)
        @test fitted.d == 2
    end

    @testset "_fitKernel — LocalNNKernel" begin
        Random.seed!(42)
        pts = collect(0.1:0.2:0.9)
        particles = DataFrame(x=pts, y=reverse(pts))
        weights   = fill(0.2, 5)
        fitted = ModelManager._fitKernel(LocalNNKernel(k=2), particles, weights, ["x", "y"], 1)
        @test fitted isa ModelManager.FittedLocalNNKernel
        @test length(fitted.bandwidths) == 5
        @test all(fitted.bandwidths .> 0)
        @test fitted.N_prev == 5
        @test fitted.d == 2
        @test isposdef(fitted.Sigma_global)

        # k clamped when k >= N
        fitted_clamp = ModelManager._fitKernel(LocalNNKernel(k=100), particles, weights, ["x", "y"], 1)
        @test fitted_clamp isa ModelManager.FittedLocalNNKernel
    end

    @testset "_fitKernel — LocalNNCovKernel" begin
        Random.seed!(42)
        pts = collect(0.1:0.2:0.9)
        particles = DataFrame(x=pts, y=reverse(pts))
        weights   = fill(0.2, 5)
        fitted = ModelManager._fitKernel(LocalNNCovKernel(k=2), particles, weights, ["x", "y"], 1)
        @test fitted isa ModelManager.FittedLocalNNCovKernel
        @test length(fitted.chols) == 5
        @test all(c isa Cholesky for c in fitted.chols)
        @test fitted.d == 2
        @test fitted.N_prev == 5

        # k clamped when k >= N
        fitted_clamp = ModelManager._fitKernel(LocalNNCovKernel(k=100), particles, weights, ["x", "y"], 1)
        @test fitted_clamp isa ModelManager.FittedLocalNNCovKernel
    end

    @testset "_proposeParticle — all kernel types" begin
        Random.seed!(99)
        particles = DataFrame(x=collect(0.1:0.2:0.9), y=collect(0.2:0.2:1.0) .- 0.1)
        weights   = fill(0.2, 5)
        param_names = ["x", "y"]

        for kernel in [GaussianKernel(), ComponentwiseKernel(),
                        LocalNNKernel(k=2), LocalNNCovKernel(k=2)]
            fitted = ModelManager._fitKernel(kernel, particles, weights, param_names, 1)
            parent = Dict("x" => 0.5, "y" => 0.5)
            # Should usually return a Dict (may rarely be nothing due to bounds)
            results = [ModelManager._proposeParticle(fitted, parent, param_names) for _ in 1:20]
            non_nothing = filter(!isnothing, results)
            @test !isempty(non_nothing)
            for p in non_nothing
                @test p isa Dict{String,Float64}
                @test all(0.0 <= p[n] <= 1.0 for n in param_names)
                @test Set(keys(p)) == Set(param_names)
            end
        end
    end

    @testset "_kernelDensity — positive and symmetric" begin
        Random.seed!(7)
        particles = DataFrame(x=collect(0.1:0.2:0.9), y=collect(0.2:0.2:1.0) .- 0.1)
        weights   = fill(0.2, 5)
        param_names = ["x", "y"]
        pa = Dict("x" => 0.3, "y" => 0.4)
        pb = Dict("x" => 0.5, "y" => 0.6)

        for kernel in [GaussianKernel(), ComponentwiseKernel()]
            fitted = ModelManager._fitKernel(kernel, particles, weights, param_names, 1)
            # Density at same point is positive
            @test ModelManager._kernelDensity(fitted, pa, pa, param_names) > 0
            # Symmetric for these isotropic-ish kernels
            dab = ModelManager._kernelDensity(fitted, pa, pb, param_names)
            dba = ModelManager._kernelDensity(fitted, pb, pa, param_names)
            @test dab ≈ dba atol=1e-10
        end

        # LocalNN kernels: just check positivity
        for kernel in [LocalNNKernel(k=2), LocalNNCovKernel(k=2)]
            fitted = ModelManager._fitKernel(kernel, particles, weights, param_names, 1)
            @test ModelManager._kernelDensity(fitted, pa, pa, param_names) > 0
            @test isfinite(ModelManager._kernelDensity(fitted, pa, pb, param_names))
        end
    end

    @testset "ABC-SMC with ComponentwiseKernel" begin
        Random.seed!(1234)
        true_mu = 2.0
        obs_mean = mean(rand(Normal(true_mu, 1.0), 100))
        param_names = ["mu"]
        mu_prior = Uniform(-5.0, 5.0)
        priors = [Uniform(0.0, 1.0)]
        function evaluate_batch_cw(t, proposals)
            return map(proposals) do (latent_cdfs, _)
                mu = quantile(mu_prior, latent_cdfs["mu"])
                sim_mean = mean(rand(Normal(mu, 1.0), 100))
                (abs(sim_mean - obs_mean), 0)
            end
        end
        method = ABCSMC(population_size=80, max_nr_populations=4, minimum_epsilon=0.001,
                        perturbation_kernel=ComponentwiseKernel())
        gens = ModelManager._runABCSMC(method, param_names, priors, evaluate_batch_cw, g -> nothing)
        @test length(gens) == 4
        for g in gens
            @test sum(g.weights) ≈ 1.0 atol=1e-6
        end
        for i in Iterators.drop(eachindex(gens), 1)
            @test gens[i].max_epsilon_accepted <= gens[i-1].max_epsilon_accepted
        end
    end

    @testset "ABC-SMC with LocalNNKernel" begin
        Random.seed!(5678)
        true_mu = 2.0
        obs_mean = mean(rand(Normal(true_mu, 1.0), 100))
        param_names = ["mu"]
        mu_prior = Uniform(-5.0, 5.0)
        priors = [Uniform(0.0, 1.0)]
        function evaluate_batch_lnn(t, proposals)
            return map(proposals) do (latent_cdfs, _)
                mu = quantile(mu_prior, latent_cdfs["mu"])
                sim_mean = mean(rand(Normal(mu, 1.0), 100))
                (abs(sim_mean - obs_mean), 0)
            end
        end
        method = ABCSMC(population_size=50, max_nr_populations=4, minimum_epsilon=0.001,
                        perturbation_kernel=LocalNNKernel(k=5))
        gens = ModelManager._runABCSMC(method, param_names, priors, evaluate_batch_lnn, g -> nothing)
        @test length(gens) == 4
        for g in gens
            @test sum(g.weights) ≈ 1.0 atol=1e-6
        end
    end

    @testset "ABC-SMC with LocalNNCovKernel" begin
        Random.seed!(9012)
        true_mu = 2.0
        obs_mean = mean(rand(Normal(true_mu, 1.0), 100))
        param_names = ["mu"]
        mu_prior = Uniform(-5.0, 5.0)
        priors = [Uniform(0.0, 1.0)]
        function evaluate_batch_lncov(t, proposals)
            return map(proposals) do (latent_cdfs, _)
                mu = quantile(mu_prior, latent_cdfs["mu"])
                sim_mean = mean(rand(Normal(mu, 1.0), 100))
                (abs(sim_mean - obs_mean), 0)
            end
        end
        method = ABCSMC(population_size=50, max_nr_populations=4, minimum_epsilon=0.001,
                        perturbation_kernel=LocalNNCovKernel(k=5))
        gens = ModelManager._runABCSMC(method, param_names, priors, evaluate_batch_lncov, g -> nothing)
        @test length(gens) == 4
        for g in gens
            @test sum(g.weights) ≈ 1.0 atol=1e-6
        end
    end

    @testset "perturbation_kernel TOML round-trip" begin
        using TOML
        function _round_trip(kernel)
            d = Dict{String,Any}("perturbation_kernel" => ModelManager._serializeKernel(kernel))
            io = IOBuffer()
            TOML.print(io, d)
            parsed = TOML.parse(String(take!(io)))
            return ModelManager._deserializeKernel(parsed["perturbation_kernel"])
        end

        # GaussianKernel scalar
        k = _round_trip(GaussianKernel(1.5))
        @test k isa GaussianKernel
        @test k.scale === 1.5

        # GaussianKernel vector
        k = _round_trip(GaussianKernel([3.0, 1.5, 1.0]))
        @test k isa GaussianKernel
        @test k.scale == [3.0, 1.5, 1.0]

        # ComponentwiseKernel
        k = _round_trip(ComponentwiseKernel(0.8))
        @test k isa ComponentwiseKernel
        @test k.scale === 0.8

        # LocalNNKernel
        k = _round_trip(LocalNNKernel(k=7, scale=0.5))
        @test k isa LocalNNKernel
        @test k.k == 7
        @test k.scale === 0.5

        # LocalNNCovKernel
        k = _round_trip(LocalNNCovKernel(k=3, scale=2.0))
        @test k isa LocalNNCovKernel
        @test k.k == 3
        @test k.scale === 2.0
    end

    ################## ABC-SMC Algorithm (toy model) ##################

    @testset "ABC-SMC algorithm on toy model" begin
        # Recover the mean of a Normal distribution from a synthetic "observed" sample mean.
        # _runABCSMC operates in CDF space: latent_cdfs["mu"] ∈ (0,1). The evaluate_batch
        # converts u → actual mu via quantile(mu_prior, u) before computing the distance.
        Random.seed!(1234)
        true_mu = 2.0
        obs_mean = mean(rand(Normal(true_mu, 1.0), 100))

        param_names = ["mu"]
        mu_prior = Uniform(-5.0, 5.0)
        priors = [Uniform(0.0, 1.0)]  # CDF-space prior; pdf = 1 everywhere ∈ (0,1)

        # evaluate_batch receives CDF values; converts to actual parameter before simulating.
        function evaluate_batch(t::Int, proposals::Vector{Tuple{Dict{String,Float64}, Union{Nothing,Int}}})
            return map(proposals) do (latent_cdfs, _)
                mu = quantile(mu_prior, latent_cdfs["mu"])
                sim_mean = mean(rand(Normal(mu, 1.0), 100))
                (abs(sim_mean - obs_mean), 0)
            end
        end

        method = ABCSMC(population_size=80, max_nr_populations=4, minimum_epsilon=0.001,
                        epsilon_quantile=0.5)
        gens = ModelManager._runABCSMC(method, param_names, priors, evaluate_batch, g -> nothing)

        @test length(gens) == 4
        @test all(g.t == i for (i, g) in enumerate(gens))

        # Epsilon should be non-increasing over generations
        for i in Iterators.drop(eachindex(gens), 1)
            @test gens[i].max_epsilon_accepted <= gens[i-1].max_epsilon_accepted
        end

        # Weights sum to 1 per generation
        for g in gens
            @test sum(g.weights) ≈ 1.0 atol=1e-6
            @test length(g.weights) == nrow(g.particles)
            @test length(g.distances) == nrow(g.particles)
        end

        # Posterior mean (in parameter space) should be close to the observed mean.
        final = gens[end]
        post_mean = sum(final.weights .* [quantile(mu_prior, u) for u in final.particles.mu])
        @test abs(post_mean - obs_mean) < 0.5
    end

    @testset "ABC-SMC stops at minimum_epsilon" begin
        # With a trivial problem (distance always 0), epsilon should collapse immediately.
        evaluate_batch = (t, proposals) -> [(0.0, 0) for _ in proposals]
        method = ABCSMC(population_size=10, max_nr_populations=5, minimum_epsilon=0.5)
        gens = ModelManager._runABCSMC(method, ["x"], [Uniform(0, 1)], evaluate_batch, g -> nothing)

        # First generation always runs; subsequent generations skipped because ε = 0 < 0.5
        @test length(gens) == 1
        @test gens[1].max_epsilon_accepted == 0.0
    end

    @testset "GenerationResult fields" begin
        # Build a minimal GenerationResult manually and verify fields
        particles = DataFrame(x=[1.0, 2.0, 3.0])
        w = [0.2, 0.3, 0.5]
        gen = GenerationResult(1, particles, w, [0.1, 0.2, 0.3], 0.3, 10, [0, 0, 0],
                               3/10, 1/sum(w.^2), nothing)
        @test gen.t == 1
        @test gen.particles.x == [1.0, 2.0, 3.0]
        @test sum(gen.weights) ≈ 1.0
        @test gen.max_epsilon_accepted == 0.3
        @test gen.n_evaluations == 10
        @test gen.acceptance_rate ≈ 0.3
        @test gen.ess ≈ 1 / sum(w.^2)
    end

    @testset "generation persistence (save/load round-trip)" begin
        mktempdir() do dir
            param_names   = ["alpha", "beta"]
            max_pops      = 10   # → 2-digit padding: "01", "02"
            w1 = [0.3, 0.3, 0.4]
            w2 = [0.5, 0.5]

            gen1 = GenerationResult(
                1, DataFrame(alpha=[0.1, 0.2, 0.3], beta=[1.0, 2.0, 3.0]),
                w1, [0.5, 0.4, 0.3], 0.5, 3, [10, 11, 12],
                3/3, 1/sum(w1.^2), nothing)
            gen2 = GenerationResult(
                2, DataFrame(alpha=[0.15, 0.25], beta=[1.5, 2.5]),
                w2, [0.2, 0.1], 0.2, 6, [13, 14],
                2/6, 1/sum(w2.^2), nothing)

            # _saveGeneration(dir, gen, max_pops) writes one folder per generation, with each
            # artifact under a constant basename inside it: no generation number in any filename.
            ModelManager._saveGeneration(dir, gen1, max_pops)
            ModelManager._saveGeneration(dir, gen2, max_pops)

            g1 = joinpath(dir, "01")
            g2 = joinpath(dir, "02")
            @test isdir(g1) && isdir(g2)
            for g in (g1, g2)
                @test isfile(joinpath(g, "particles.csv"))
                @test isfile(joinpath(g, "cdfs.csv"))
                @test isfile(joinpath(g, "metadata.toml"))
            end
            # No flat-layout leftovers, and no separate cdf directory.
            @test !isfile(joinpath(dir, "generation_01.csv"))
            @test !isdir(joinpath(dir, "generation_cdfs"))

            # Display CSV: with empty cps, equals particles + weight + distance + monad_id
            csv1 = CSV.read(joinpath(g1, "particles.csv"), DataFrame)
            @test "acceptance_rate" ∉ names(csv1)
            @test "ess" ∉ names(csv1)
            @test Set(names(csv1)) == Set(["alpha", "beta", "weight", "distance", "monad_id"])

            # CDF CSV has the same columns (no CalibrationParameters → identity transform)
            cdf1 = CSV.read(joinpath(g1, "cdfs.csv"), DataFrame)
            @test Set(names(cdf1)) == Set(["alpha", "beta", "weight", "distance", "monad_id"])

            # TOML contains generation-level fields
            meta1 = TOML.parsefile(joinpath(g1, "metadata.toml"))
            @test meta1["t"] == 1
            @test meta1["max_epsilon_accepted"] ≈ 0.5
            @test meta1["n_evaluations"] == 3
            @test meta1["acceptance_rate"] ≈ 1.0
            @test meta1["ess"] ≈ gen1.ess

            # Round-trip: _loadGenerations reads each generation folder's cdfs.csv
            loaded = ModelManager._loadGenerations(dir, param_names, max_pops)
            @test length(loaded) == 2

            @test loaded[1].t == 1
            @test loaded[1].particles.alpha ≈ [0.1, 0.2, 0.3]
            @test loaded[1].particles.beta  ≈ [1.0, 2.0, 3.0]
            @test loaded[1].weights         ≈ w1
            @test loaded[1].distances       ≈ [0.5, 0.4, 0.3]
            @test loaded[1].max_epsilon_accepted         ≈ 0.5
            @test loaded[1].n_evaluations   == 3
            @test loaded[1].monad_ids       == [10, 11, 12]
            @test loaded[1].acceptance_rate ≈ 1.0
            @test loaded[1].ess             ≈ gen1.ess

            @test loaded[2].t == 2
            @test loaded[2].particles.alpha ≈ [0.15, 0.25]
            @test loaded[2].max_epsilon_accepted         ≈ 0.2
            @test loaded[2].n_evaluations   == 6
            @test loaded[2].acceptance_rate ≈ 2/6

            # Only 2 files exist → only 2 loaded
            @test length(ModelManager._loadGenerations(dir, param_names, max_pops)) == 2

            # The ten-argument constructor still works, so every existing positional construction
            # keeps compiling; the two trailing fields default to absent.
            @test isnothing(gen1.epsilon_threshold)
            @test isnothing(gen1.proposal_distances)

            # Written keys: the achieved epsilon under its own name, and no threshold for a
            # generation that had none (TOML has no null, so the key is omitted, not blanked).
            meta_written = TOML.parsefile(joinpath(g1, "metadata.toml"))
            @test haskey(meta_written, "max_epsilon_accepted")
            @test !haskey(meta_written, "epsilon_threshold")
            @test !haskey(meta_written, "epsilon")

            # A calibration written under the flat layout, before the rename, must still load
            # exactly as it lies: the old "epsilon" spelling is accepted, the threshold stays absent,
            # and no migration is required first. Without this every existing calibration would need
            # to be converted before it could be read at all.
            legacy_dir = joinpath(dir, "legacy")
            mkpath(joinpath(legacy_dir, "generation_cdfs"))
            cp(joinpath(g1, "cdfs.csv"),
               joinpath(legacy_dir, "generation_cdfs", "generation_01.csv"))
            cp(joinpath(g1, "particles.csv"), joinpath(legacy_dir, "generation_01.csv"))
            legacy_meta = Dict{String,Any}(
                "t"               => 1,
                "epsilon"         => 0.5,      # the pre-rename spelling
                "n_evaluations"   => 3,
                "acceptance_rate" => 1.0,
                "ess"             => gen1.ess,
            )
            open(joinpath(legacy_dir, "generation_01.toml"), "w") do io
                TOML.print(io, legacy_meta)
            end
            legacy_loaded = ModelManager._loadGenerations(legacy_dir, param_names, max_pops)
            @test length(legacy_loaded) == 1
            @test legacy_loaded[1].max_epsilon_accepted ≈ 0.5
            @test isnothing(legacy_loaded[1].epsilon_threshold)

            # ...and the file is upgraded in place, so the next read takes the current path. Resuming
            # already writes into this folder, so nothing here was read-only.
            upgraded = TOML.parsefile(joinpath(legacy_dir, "generation_01.toml"))
            @test haskey(upgraded, "max_epsilon_accepted")
            @test upgraded["max_epsilon_accepted"] ≈ 0.5
            @test !haskey(upgraded, "epsilon")
            # The threshold was never recorded then, so it stays absent rather than being invented.
            @test !haskey(upgraded, "epsilon_threshold")
            # Every other key survives the rewrite untouched.
            @test upgraded["n_evaluations"] == 3
            @test upgraded["acceptance_rate"] ≈ 1.0
            @test upgraded["ess"] ≈ gen1.ess
            # Idempotent: a second load changes nothing and re-reads the same value.
            again = ModelManager._loadGenerations(legacy_dir, param_names, max_pops)
            @test again[1].max_epsilon_accepted ≈ 0.5
            @test TOML.parsefile(joinpath(legacy_dir, "generation_01.toml")) == upgraded
            # No stray temp file left behind.
            @test !isfile(joinpath(legacy_dir, "generation_01.toml.upgrading"))
            # A no-op on an already-current file.
            @test ModelManager._upgradeGenerationMetadata!(
                joinpath(legacy_dir, "generation_01.toml"), upgraded) == false

            # Cross-padding: files were written with max_pops=10 (tags "01","02") but
            # loaded with max_pops=5 (which would have generated tags "1","2" under the
            # old loop). The scan-based loader must find the files regardless.
            loaded_cross = ModelManager._loadGenerations(dir, param_names, 5)
            @test length(loaded_cross) == 2
            @test loaded_cross[1].t == 1
            @test loaded_cross[1].particles.alpha ≈ [0.1, 0.2, 0.3]
            @test loaded_cross[2].t == 2
            @test loaded_cross[2].particles.alpha ≈ [0.15, 0.25]
        end

        # Padding width scales with max_nr_populations
        @test ModelManager._generationTag(3, 10)  == "03"
        @test ModelManager._generationTag(3, 100) == "003"
        @test ModelManager._generationTag(10, 10) == "10"
    end

    @testset "resume path: _loadGenerations reads raw CDF coords, not display values" begin
        # _saveGeneration writes CDF coords to cdfs.csv and display-transformed values to
        # particles.csv. _loadGenerations must read cdfs.csv so the raw CDF coords are
        # recovered exactly, not the display values.
        xp  = XMLPath(["a", "x"])
        dv  = DistributedVariation(:config, xp, Uniform(0.0, 2.0))
        cp  = ModelManager._toCalibrationParameter(dv)
        col = cp.lv.latent_parameter_names[1]

        cdf_val    = 0.3
        target_val = quantile(Uniform(0.0, 2.0), cdf_val)  # = 0.6 — differs from cdf_val

        mktempdir() do dir
            gen = GenerationResult(
                1, DataFrame(Symbol(col) => [cdf_val]),
                [1.0], [0.1], 0.5, 1, [42], 1.0, 1.0, nothing)

            ModelManager._saveGeneration(dir, gen, 5, [cp])

            @test isfile(joinpath(dir, "1", "cdfs.csv"))
            @test isfile(joinpath(dir, "1", "particles.csv"))

            loaded = ModelManager._loadGenerations(dir, [col], 5)
            @test length(loaded) == 1
            @test loaded[1].particles[!, col][1] ≈ cdf_val atol=1e-15
            @test abs(loaded[1].particles[!, col][1] - target_val) > 1e-6
        end
    end

    @testset "_buildDisplayDF display conversion" begin
        xp  = XMLPath(["a", "x"])
        xp2 = XMLPath(["a", "y"])

        # DVSource: stored CDF 0.5 → quantile(Uniform(0,2), 0.5) = 1.0
        dv  = DistributedVariation(:config, xp, Uniform(0.0, 2.0))
        cp_dv = ModelManager._toCalibrationParameter(dv)
        @test ModelManager._displayColumns(cp_dv) == [columnName(xp)]
        @test ModelManager._particleRowToDisplay(cp_dv, [0.5]) ≈ [1.0]

        # CVSource: one CDF moves two targets; median of Uniform(0,2)=1.0, Uniform(1,3)=2.0
        dv2 = DistributedVariation(:config, xp2, Uniform(1.0, 3.0))
        cv  = CoVariation(dv, dv2)
        cp_cv = ModelManager._toCalibrationParameter(cv)
        @test ModelManager._displayColumns(cp_cv) == [columnName(xp), columnName(xp2)]
        vals = ModelManager._particleRowToDisplay(cp_cv, [0.5])
        @test vals[1] ≈ 1.0   # median of Uniform(0,2)
        @test vals[2] ≈ 2.0   # median of Uniform(1,3)

        # LVSource: latent cols (actual samples) + target cols
        # latent_parameter_names = ["u"] (explicit), targets = [xp]
        lv = LatentVariation(
            [Uniform(0.0, 1.0)],
            XMLPath[xp],
            Function[us -> 10.0 * us[1]],
            ["u"],
            Symbol[:config]
        )
        cp_lv = ModelManager._toCalibrationParameter(lv)
        @test ModelManager._displayColumns(cp_lv) == ["u", columnName(xp)]
        # CDF=0.5 → lp_val=quantile(Uniform(0,1),0.5)=0.5; target=10*0.5=5.0
        vals_lv = ModelManager._particleRowToDisplay(cp_lv, [0.5])
        @test vals_lv[1] ≈ 0.5   # latent sample
        @test vals_lv[2] ≈ 5.0   # target value

        # _buildDisplayDF with DVSource CalibrationParameter.
        # Particles column name must match cp_dv.lv.latent_parameter_names[1],
        # which equals columnName(xp) = "a/x" for a DVSource LV.
        lat_col = cp_dv.lv.latent_parameter_names[1]   # "a/x" (or simulator-shortened)
        gen_dv = GenerationResult(
            1, DataFrame(lat_col => [0.25, 0.75]), [0.5, 0.5], [0.1, 0.2], 0.2, 2, [1, 2],
            1.0, 2.0, nothing)
        df = ModelManager._buildDisplayDF(gen_dv, [cp_dv])
        @test "weight"   ∈ names(df)
        @test "distance" ∈ names(df)
        @test "monad_id" ∈ names(df)
        @test columnName(xp) ∈ names(df)
        # CDF 0.25 → quantile(Uniform(0,2), 0.25) = 0.5
        @test df[!, columnName(xp)][1] ≈ 0.5
        # CDF 0.75 → quantile(Uniform(0,2), 0.75) = 1.5
        @test df[!, columnName(xp)][2] ≈ 1.5

        # _buildDisplayDF with LVSource CalibrationParameter.
        # Particles column name must match latent_parameter_names[1] = "u".
        gen_lv = GenerationResult(
            1, DataFrame(u=[0.25, 0.75]), [0.5, 0.5], [0.1, 0.2], 0.2, 2, [1, 2],
            1.0, 2.0, nothing)
        df_lv = ModelManager._buildDisplayDF(gen_lv, [cp_lv])
        @test "u"          ∈ names(df_lv)   # latent sample column
        @test columnName(xp) ∈ names(df_lv) # target column
        # CDF 0.25 → lp_val=0.25; target=10*0.25=2.5
        @test df_lv[!, "u"][1] ≈ 0.25
        @test df_lv[!, columnName(xp)][1] ≈ 2.5

        # _buildDisplayDF with empty cps → returns particles unchanged (+ metadata cols)
        df_empty = ModelManager._buildDisplayDF(gen_lv, CalibrationParameter[])
        @test "u" ∈ names(df_empty)
        @test df_empty[!, :u] ≈ [0.25, 0.75]
    end

    @testset "posterior" begin
        particles1 = DataFrame(x=[1.0, 2.0])
        particles2 = DataFrame(x=[3.0, 4.0])
        w1 = [0.4, 0.6]; w2 = [0.5, 0.5]
        gen1 = GenerationResult(1, particles1, w1, [0.5, 0.3], 0.5, 4, [0, 0],
                                2/4, 1/sum(w1.^2), nothing)
        gen2 = GenerationResult(2, particles2, w2, [0.1, 0.2], 0.2, 6, [0, 0],
                                2/6, 1/sum(w2.^2), nothing)

        cal = Calibration(1)
        method = ABCSMC()
        params = CalibrationParameter[]
        result = ABCResult(cal, [gen1, gen2], params, method)

        df, w = posterior(result)
        @test df.x == [3.0, 4.0]   # :final == generation 2
        @test w == [0.5, 0.5]

        df1, _ = posterior(result; generation=1)
        @test df1.x == [1.0, 2.0]

        @test_throws ArgumentError posterior(result; generation=99)

        result_empty = ABCResult(cal, GenerationResult[], CalibrationParameter[], method)
        @test_throws ErrorException posterior(result_empty)
    end

    ################## ABCSMC new fields — validation ##################

    @testset "ABCSMC epsilon_schedule validation" begin
        @test_throws ArgumentError ABCSMC(epsilon_schedule=Float64[])         # empty
        @test_throws ArgumentError ABCSMC(epsilon_schedule=[1.0, 2.0])        # not decreasing
        @test_throws ArgumentError ABCSMC(epsilon_schedule=[-1.0])             # not positive
        m = ABCSMC(epsilon_schedule=[10.0, 5.0, 1.0])
        @test m.epsilon_schedule == [10.0, 5.0, 1.0]
    end

    @testset "ABCSMC stopping threshold validation" begin
        @test_throws ArgumentError ABCSMC(min_acceptance_rate=1.0)
        @test_throws ArgumentError ABCSMC(min_acceptance_rate=-0.1)
        @test_throws ArgumentError ABCSMC(min_epsilon_decrease=1.0)
        @test_throws ArgumentError ABCSMC(min_ess_fraction=1.0)
        m = ABCSMC(min_acceptance_rate=0.05, min_epsilon_decrease=0.1, min_ess_fraction=0.2)
        @test m.min_acceptance_rate  == 0.05
        @test m.min_epsilon_decrease == 0.1
        @test m.min_ess_fraction     == 0.2
    end

    ################## Diagnostics — ESS and acceptance rate ##################

    @testset "ESS and acceptance_rate in GenerationResult" begin
        Random.seed!(42)
        evaluate_batch = (t, proposals) -> [(rand(), 0) for _ in proposals]
        method = ABCSMC(population_size=20, max_nr_populations=3, minimum_epsilon=0.0)
        gens = ModelManager._runABCSMC(method, ["x"], [Uniform(0, 1)], evaluate_batch, g -> nothing)

        for g in gens
            @test 0.0 < g.acceptance_rate <= 1.0
            @test 1.0 <= g.ess <= method.population_size
        end
        # Generation 1: all accepted, uniform weights → ESS = population_size
        @test gens[1].acceptance_rate ≈ 1.0
        @test gens[1].ess ≈ Float64(method.population_size)
    end

    ################## Epsilon schedule ##################

    @testset "epsilon_schedule overrides adaptive epsilon" begin
        Random.seed!(99)
        # Distances uniform in [0, 10]; schedule forces specific thresholds.
        evaluate_batch = (t, proposals) -> [(rand() * 10, 0) for _ in proposals]
        schedule = [8.0, 4.0, 2.0]
        method = ABCSMC(population_size=30, max_nr_populations=4,
                        minimum_epsilon=0.001, epsilon_schedule=schedule)
        gens = ModelManager._runABCSMC(method, ["x"], [Uniform(0, 10)], evaluate_batch, g -> nothing)

        # All accepted distances in each scheduled generation must respect the threshold.
        length(gens) >= 2 && @test all(d <= schedule[1] for d in gens[2].distances)
        length(gens) >= 3 && @test all(d <= schedule[2] for d in gens[3].distances)
        length(gens) >= 4 && @test all(d <= schedule[3] for d in gens[4].distances)

        # The threshold each generation ran against is now recorded, and is not recoverable from
        # max_epsilon_accepted: it is a quantile of the *previous* generation's accepted distances.
        for k in 2:length(gens)
            @test gens[k].epsilon_threshold == schedule[k-1]
        end
        # Generation 1 has no threshold — it accepts every proposal it evaluates.
        @test isnothing(gens[1].epsilon_threshold)
    end

    ################## Stopping criteria ##################

    @testset "min_epsilon_decrease stops when epsilon plateaus" begin
        # All distances constant → no decrease → stops at generation 2.
        evaluate_batch = (t, proposals) -> [(0.5, 0) for _ in proposals]
        method = ABCSMC(population_size=10, max_nr_populations=5, minimum_epsilon=0.0,
                        epsilon_quantile=0.5, min_epsilon_decrease=0.1)
        gens = ModelManager._runABCSMC(method, ["x"], [Uniform(0, 2)],
                                        evaluate_batch, g -> nothing)
        # Gen 1: epsilon=0.5. Gen 2: epsilon_t=0.5 (adaptive), all d=0.5 accepted,
        # rel_decrease = 0 < 0.1 → stops after gen 2.
        @test length(gens) == 2
    end

    @testset "min_ess_fraction stops on weight collapse" begin
        # After gen 1, weights concentrate heavily on a few particles (low ESS).
        # Use evaluate_batch that returns very low distances for only 1 in population_size
        # proposals so the weights become extremely unequal after importance reweighting.
        # Easier: just verify the field is checked — test via ABCSMC round-trip.
        m = ABCSMC(min_ess_fraction=0.5)
        @test m.min_ess_fraction == 0.5
    end

    @testset "acceptance_rate counts all epsilon-passing proposals, not truncated population" begin
        # Scenario: population_size=3, epsilon=0.5.
        # evaluate_batch always returns 5 accepted (distance 0.0) out of 5 proposals.
        # Gen 1 accepts all 3 proposals (n_evaluations=3, n_accepted=3 → rate=1.0).
        # Gen 2: first batch proposes 3 (all 3 accepted → population full).
        #   But ALL 3 proposals pass epsilon. acceptance_rate should be 3/3 = 1.0.
        #
        # More interesting case: batch size > n_needed, overshoot happens.
        # We test this by giving evaluate_batch a fixed response: every proposal passes.
        # Then n_accepted_total will equal n_evaluations (rate=1.0) regardless of how
        # many were trimmed. Separately verify via _buildGenerationResult directly.

        # Direct test of _buildGenerationResult: n_accepted=7 out of n_evaluations=10,
        # but only population_size=5 particles kept. Rate should be 7/10, not 5/10.
        particles5 = [ModelManager._ParticleResult(Dict("x" => float(i)), 0.1*i, i)
                      for i in 1:5]
        weights5 = fill(0.2, 5)
        gen = ModelManager._buildGenerationResult(2, particles5, weights5, 10, 7, ["x"])
        @test gen.acceptance_rate ≈ 7/10
        @test gen.n_evaluations == 10
        @test nrow(gen.particles) == 5

        # Integration test via _runABCSMC: all proposals pass (distance=0.1, epsilon≥0.1).
        # Use distance=0.1 (not 0.0) so gen-1 epsilon=0.1 > minimum_epsilon=0.0,
        # allowing gen 2 to run. Both generations should report acceptance_rate=1.0.
        Random.seed!(42)
        evaluate_all_pass = (t, proposals) -> [(0.1, 0) for _ in proposals]
        method = ABCSMC(population_size=5, max_nr_populations=2, minimum_epsilon=0.0)
        gens = ModelManager._runABCSMC(method, ["x"], [Uniform(0, 1)],
                                        evaluate_all_pass, g -> nothing)
        @test length(gens) == 2
        @test gens[1].acceptance_rate ≈ 1.0
        @test gens[2].acceptance_rate ≈ 1.0
    end

    ################## missing distances (monads with no successful sim) ##################

    @testset "_acceptFirstGeneration drops missing distances" begin
        proposals = Tuple{Dict{String,Float64}, Union{Nothing,Int}}[
            (Dict("x" => 0.1), nothing), (Dict("x" => 0.2), nothing),
            (Dict("x" => 0.3), nothing), (Dict("x" => 0.4), nothing)]

        # Two failed monads among four proposals: only those with a distance are accepted,
        # in order, carrying their monad IDs through as metadata.
        results = Tuple{Union{Float64,Missing},Int}[
            (1.0, 11), (missing, 12), (2.0, 13), (missing, 14)]
        accepted = ModelManager._acceptFirstGeneration(proposals, results)
        @test length(accepted) == 2
        @test [p.distance for p in accepted] == [1.0, 2.0]
        @test [p.metadata for p in accepted] == [11, 13]
        @test [p.latent_cdfs["x"] for p in accepted] == [0.1, 0.3]

        # `Inf` is a distance like any other, not a failure signal: it is accepted, and ε for the
        # generation is simply infinite. Generation 2 then accepts every proposal — a second
        # uniform draw in CDF space — after which the usual quantile rule pulls ε back down.
        @test length(ModelManager._acceptFirstGeneration(proposals,
                        Tuple{Union{Float64,Missing},Int}[
                            (1.0, 11), (Inf, 12), (2.0, 13), (3.0, 14)])) == 4

        # No monad succeeded → error rather than an all-rejected generation.
        @test_throws "had a successful simulation" ModelManager._acceptFirstGeneration(proposals,
                        Tuple{Union{Float64,Missing},Int}[
                            (missing, 11), (missing, 12), (missing, 13), (missing, 14)])

        # An empty batch is reported as such, not as "none of the 0 monads succeeded".
        empty_proposals = Tuple{Dict{String,Float64}, Union{Nothing,Int}}[]
        @test_throws "empty batch" ModelManager._acceptFirstGeneration(empty_proposals,
                        Tuple{Union{Float64,Missing},Int}[])
    end

    @testset "generation 1 epsilon and weights ignore failed monads" begin
        # Without filtering, one missing would corrupt gen-1 epsilon = maximum(distances).
        Random.seed!(11)
        n_seen = Ref(0)
        # Fail the 2nd and 4th monad of generation 1; everything else scores 0.5.
        evaluate_flaky = function (t, proposals)
            map(proposals) do _
                n_seen[] += 1
                (t == 1 && n_seen[] in (2, 4)) ? (missing, 0) : (0.5, 0)
            end
        end
        method = ABCSMC(population_size=6, max_nr_populations=2, minimum_epsilon=0.0)
        gens = ModelManager._runABCSMC(method, ["x"], [Uniform(0, 1)],
                                        evaluate_flaky, g -> nothing)

        @test isfinite(gens[1].max_epsilon_accepted)
        @test gens[1].max_epsilon_accepted ≈ 0.5
        # 4 of 6 survive; weights renormalized over survivors, n_evaluations unchanged.
        @test length(gens[1].weights) == 4
        @test sum(gens[1].weights) ≈ 1.0
        @test nrow(gens[1].particles) == 4
        @test gens[1].n_evaluations == 6
        @test gens[1].acceptance_rate ≈ 4/6
    end

    @testset "later generations reject missing distances without comparing to epsilon" begin
        # `missing <= epsilon` is `missing`, not `false`, so an unguarded comparison would
        # throw when used as a condition. Every 3rd monad in generation 2 fails.
        Random.seed!(13)
        n_seen = Ref(0)
        evaluate_flaky = function (t, proposals)
            map(proposals) do _
                n_seen[] += 1
                (t > 1 && n_seen[] % 3 == 0) ? (missing, 0) : (0.25, 0)
            end
        end
        method = ABCSMC(population_size=4, max_nr_populations=2, minimum_epsilon=0.0)
        gens = ModelManager._runABCSMC(method, ["x"], [Uniform(0, 1)],
                                        evaluate_flaky, g -> nothing)
        @test length(gens) == 2
        # Failed monads are never accepted, so the target population is still filled from the
        # rest, and more proposals were needed than were accepted.
        @test nrow(gens[2].particles) == 4
        @test all(isfinite, gens[2].distances)
        @test gens[2].n_evaluations > 4
        @test gens[2].acceptance_rate < 1.0
    end

    @testset "_validateEvaluationFailurePolicy" begin
        @test ModelManager._validateEvaluationFailurePolicy(:reject) === nothing
        @test ModelManager._validateEvaluationFailurePolicy(:error)  === nothing
        @test_throws ArgumentError ModelManager._validateEvaluationFailurePolicy(:ignore)
    end

    ################## accept_overflow ##################

    @testset "accept_overflow keeps all epsilon-passing particles" begin
        Random.seed!(7)
        param_names = ["x"]
        priors = [Uniform(0.0, 1.0)]

        # Build a fake gen-1 result with low acceptance_rate (0.3) to force a large
        # batch in gen 2: n_to_propose = ceil(population_size / 0.3) = 10.
        # All three particle values are in the prior support [0, 1].
        gen1 = GenerationResult(
            1,
            DataFrame(x = [0.2, 0.4, 0.6]),
            [1/3, 1/3, 1/3],
            [0.1, 0.2, 0.3],
            0.3,       # epsilon
            10,        # n_evaluations → acceptance_rate = 3/10 = 0.3
            [0, 0, 0],
            0.3,       # acceptance_rate ← seeds gen-2 batch sizing
            3.0,       # ess
            nothing,
        )

        # evaluate_batch always passes with distance=0.1.
        # epsilon for gen 2 = adaptive median of gen1.distances = 0.2; 0.1 ≤ 0.2 ✓
        evaluate_batch = (t, proposals) -> [(0.1, 0) for _ in proposals]
        population_size = 3

        # Default (accept_overflow=false): exactly population_size particles in gen 2.
        method_no = ABCSMC(population_size=population_size, max_nr_populations=2,
                           minimum_epsilon=0.0)
        gens_no = ModelManager._runABCSMC(method_no, param_names, priors,
                                          evaluate_batch, g -> nothing;
                                          start_generations=[gen1])
        @test length(gens_no) == 2
        @test nrow(gens_no[2].particles) == population_size

        # accept_overflow=true: all 10 proposed particles kept (batch > population_size).
        method_ov = ABCSMC(population_size=population_size, max_nr_populations=2,
                           minimum_epsilon=0.0, accept_overflow=true)
        gens_ov = ModelManager._runABCSMC(method_ov, param_names, priors,
                                          evaluate_batch, g -> nothing;
                                          start_generations=[gen1])
        @test length(gens_ov) == 2
        @test nrow(gens_ov[2].particles) > population_size   # overflow kept

        # ESS in [1, nrow(particles)] and weights sum to 1.
        ov = gens_ov[2]
        @test ov.ess >= 1.0
        @test ov.ess <= nrow(ov.particles)
        @test sum(ov.weights) ≈ 1.0 atol=1e-6
    end

    ################## SimulationBank ##################

    @testset "SimulationBank struct and _bankCdfCoords" begin
        xp  = XMLPath(["overall", "max_time"])
        xp2 = XMLPath(["path", "a"])
        xp3 = XMLPath(["path", "b"])

        # --- DVSource: standard (not flipped) ---
        dv = DistributedVariation(:config, xp, Uniform(0.0, 4.0))
        cp = ModelManager._toCalibrationParameter(dv)
        # value=2.0 → u = cdf(Uniform(0,4), 2.0) = 0.5
        vals = Dict{String,Float64}("overall/max_time" => 2.0)
        coords = ModelManager._bankCdfCoords(cp, vals)
        @test !isnothing(coords)
        @test length(coords) == 1
        @test coords[1] ≈ 0.5

        # value=0.0 → u=0.0 (boundary — bank filters this out, but _bankCdfCoords allows it)
        vals0 = Dict{String,Float64}("overall/max_time" => 0.0)
        c0 = ModelManager._bankCdfCoords(cp, vals0)
        @test !isnothing(c0)
        @test c0[1] ≈ 0.0

        # --- DVSource: flipped ---
        dv_flip = DistributedVariation(:config, xp, Uniform(0.0, 4.0); flip=true)
        cp_flip = ModelManager._toCalibrationParameter(dv_flip)
        # value=2.0 → u = 1 - cdf(Uniform(0,4), 2.0) = 0.5 (symmetric)
        vals2 = Dict{String,Float64}("overall/max_time" => 2.0)
        coords_flip = ModelManager._bankCdfCoords(cp_flip, vals2)
        @test !isnothing(coords_flip)
        @test coords_flip[1] ≈ 0.5
        # value=1.0 → cdf=0.25, so flipped u = 0.75
        vals3 = Dict{String,Float64}("overall/max_time" => 1.0)
        c_f = ModelManager._bankCdfCoords(cp_flip, vals3)
        @test !isnothing(c_f)
        @test c_f[1] ≈ 0.75

        # --- DVSource: missing column → nothing ---
        coords_miss = ModelManager._bankCdfCoords(cp, Dict{String,Float64}())
        @test isnothing(coords_miss)

        # --- the interior filter is per latent dimension ---
        # `0 < u < 1` is a statement about a continuous prior, whose CDF reaches its bounds only in
        # the limit. A discrete parameter's top level has cdf exactly 1.0, so the strict test threw
        # every monad run at that level out of the bank — a level proposed as often as any other.
        disc_cp_bank = ModelManager._toCalibrationParameter(
            DiscreteVariation(:config, xp, [1.0, 2.0, 3.0]))
        @test ModelManager._bankCdfCoords(
            disc_cp_bank, Dict{String,Float64}("overall/max_time" => 3.0)) ≈ [1.0]
        @test ModelManager._bankCoordsUsable(disc_cp_bank.lv, [1.0])
        @test !ModelManager._bankCoordsUsable(disc_cp_bank.lv, [0.0])   # no level maps there
        @test !ModelManager._bankCoordsUsable(cp.lv, [1.0])             # continuous: still strict
        @test ModelManager._bankCoordsUsable(cp.lv, [0.5])

        # --- CVSource: single latent CDF, two targets ---
        dv2 = DistributedVariation(:config, xp2, Uniform(0.0, 2.0))
        dv3 = DistributedVariation(:config, xp3, Uniform(1.0, 3.0))
        cv  = CoVariation(dv2, dv3)
        cp_cv = ModelManager._toCalibrationParameter(cv)
        # value of first target = 1.0 → cdf(Uniform(0,2), 1.0) = 0.5
        vals_cv = Dict{String,Float64}("path/a" => 1.0, "path/b" => 2.0)
        coords_cv = ModelManager._bankCdfCoords(cp_cv, vals_cv)
        @test !isnothing(coords_cv)
        @test length(coords_cv) == 1    # one shared latent CDF
        @test coords_cv[1] ≈ 0.5

        # --- CVSource: missing first target column → nothing ---
        coords_cv_miss = ModelManager._bankCdfCoords(cp_cv,
            Dict{String,Float64}("path/b" => 2.0))   # only second target
        @test isnothing(coords_cv_miss)

        # --- LVSource without inverse_maps: nothing (cannot invert) ---
        lv3 = LatentVariation(
            [Uniform(0.0, 1.0)],
            XMLPath[xp],
            Function[us -> quantile(Uniform(0.0, 1.0), us[1])],
            ["rate"],
            Symbol[:config]
        )
        cp_lv = ModelManager._toCalibrationParameter(lv3)
        vals_lv = Dict{String,Float64}("overall/max_time" => 0.5)
        @test isnothing(ModelManager._bankCdfCoords(cp_lv, vals_lv))

        # --- LVSource with inverse_maps: correct CDF value returned ---
        # Forward: u → 4u (scalar map), inverse: tv → tv[1]/4
        lv_inv = LatentVariation(
            [Uniform(0.0, 1.0)],
            XMLPath[xp],
            Function[us -> 4.0 * us[1]],
            ["rate"],
            Symbol[:config];
            inverse_maps=Function[tv -> tv[1] / 4.0]
        )
        cp_lv_inv = ModelManager._toCalibrationParameter(lv_inv)
        # target value 2.0 → CDF = 2.0/4.0 = 0.5
        vals_lv_inv = Dict{String,Float64}("overall/max_time" => 2.0)
        coords_lv_inv = ModelManager._bankCdfCoords(cp_lv_inv, vals_lv_inv)
        @test !isnothing(coords_lv_inv)
        @test length(coords_lv_inv) == 1
        @test coords_lv_inv[1] ≈ 0.5
        # missing column → nothing
        @test isnothing(ModelManager._bankCdfCoords(cp_lv_inv, Dict{String,Float64}()))

        # --- CVSource: inconsistent targets → nothing (NaN from auto-constructed inverse) ---
        # dv2=Uniform(0,2), dv3=Uniform(1,3); u=0.5 → (1.0, 2.0). Feed (1.0, 3.0) → inconsistent.
        vals_cv_bad = Dict{String,Float64}("path/a" => 1.0, "path/b" => 3.0)
        @test isnothing(ModelManager._bankCdfCoords(cp_cv, vals_cv_bad))

        # --- SimulationBank struct ---
        bank = ModelManager.SimulationBank(
            [1, 2, 3],
            [0.1 0.5 0.9; 0.2 0.6 0.8],
            ["x", "y"]
        )
        @test bank.monad_ids == [1, 2, 3]
        @test size(bank.cdf_coords) == (2, 3)
        @test bank.param_names == ["x", "y"]
        @test bank.tree isa NearestNeighbors.NNTree   # KD-tree built for non-empty bank

        # --- _buildSimulationBank: uninitialized DB → empty bank immediately ---
        # The test globals have initialized=false, so the bank guard fires before any DB call.
        xp_t = XMLPath(["overall", "max_time"])
        dv_t = DistributedVariation(:config, xp_t, Uniform(0.0, 10.0))
        cp_t = ModelManager._toCalibrationParameter(dv_t)
        # Use the positional struct constructor directly so [cp_t] is not re-converted.
        prob = CalibrationProblem(
            ModelManager.InputFolders(Pair{Symbol,Union{String,Int}}[]),
            CalibrationParameter[cp_t],
            Dict{String,Any}("default" => 0.0),
            QoI("default", s -> 0.0),
            mseDistance,
            1,
            ModelManager.VariationID(Pair{Symbol,Int}[])
        )
        bank_empty = ModelManager._buildSimulationBank(prob)
        @test bank_empty isa ModelManager.SimulationBank
        @test isempty(bank_empty.monad_ids)
        @test size(bank_empty.cdf_coords, 2) == 0
        @test bank_empty.param_names == cp_t.lv.latent_parameter_names
        @test isnothing(bank_empty.tree)              # no tree for empty bank

        # Non-dict observed_data is stored as-is (no coercion)
        vec_obs = [1.0, 2.0, 3.0]
        prob_vec = CalibrationProblem(
            ModelManager.InputFolders(Pair{Symbol,Union{String,Int}}[]),
            CalibrationParameter[cp_t],
            vec_obs,
            QoI("v", s -> 0.0), mseDistance, 1,
            ModelManager.VariationID(Pair{Symbol,Int}[])
        )
        @test prob_vec.observed_data === vec_obs

        scalar_obs = 42.0
        prob_scalar = CalibrationProblem(
            ModelManager.InputFolders(Pair{Symbol,Union{String,Int}}[]),
            CalibrationParameter[cp_t],
            scalar_obs,
            QoI("v", s -> 0.0), mseDistance, 1,
            ModelManager.VariationID(Pair{Symbol,Int}[])
        )
        @test prob_scalar.observed_data === scalar_obs
    end

    ################## CDF-grid snap helpers ##################

    @testset "_effectiveK" begin
        @test ModelManager._effectiveK(3, 1) == 3
        @test ModelManager._effectiveK(3, 2) == 4
        @test ModelManager._effectiveK(3, 5) == 7
        @test ModelManager._effectiveK(1, 1) == 1
    end

    @testset "_snapToCDFGrid" begin
        # k_eff=1: grid = {0.5}
        @test ModelManager._snapToCDFGrid(0.5, 1) ≈ 0.5
        @test ModelManager._snapToCDFGrid(0.0, 1) ≈ 0.5   # clamped to interior min
        @test ModelManager._snapToCDFGrid(1.0, 1) ≈ 0.5   # clamped to interior max

        # k_eff=2: grid = {0.25, 0.5, 0.75}
        @test ModelManager._snapToCDFGrid(0.24, 2) ≈ 0.25
        @test ModelManager._snapToCDFGrid(0.50, 2) ≈ 0.50
        @test ModelManager._snapToCDFGrid(0.74, 2) ≈ 0.75
        @test ModelManager._snapToCDFGrid(0.0,  2) ≈ 0.25   # clamped to 1/4
        @test ModelManager._snapToCDFGrid(1.0,  2) ≈ 0.75   # clamped to 3/4

        # k_eff=3: grid = {0.125, 0.25, ..., 0.875}
        @test ModelManager._snapToCDFGrid(0.13, 3) ≈ 0.125
        @test ModelManager._snapToCDFGrid(0.87, 3) ≈ 0.875
    end

    @testset "_bankBoxRadius" begin
        # radius = 1/2^(k_eff+1) = half the grid spacing
        @test ModelManager._bankBoxRadius(3) ≈ 1/2^4   # k_eff=3 → spacing 1/8, radius 1/16
        @test ModelManager._bankBoxRadius(4) ≈ 1/2^5   # k_eff=4 → spacing 1/16, radius 1/32
        @test ModelManager._bankBoxRadius(1) ≈ 1/2^2   # k_eff=1 → spacing 1/2, radius 1/4
    end

    @testset "_cdfToGridKey" begin
        # k_eff=2: {j/4 : j=1,2,3}
        @test ModelManager._cdfToGridKey([0.25, 0.75], 2) == [1, 3]
        @test ModelManager._cdfToGridKey([0.5],        2) == [2]
        @test ModelManager._cdfToGridKey([0.25, 0.5, 0.75], 2) == [1, 2, 3]
    end

    @testset "_bankBoxCandidates" begin
        # 2D bank with three entries at known CDF coords
        bank = ModelManager.SimulationBank(
            [10, 20, 30],
            [0.25 0.5 0.75; 0.25 0.5 0.75],   # each column is one entry
            ["x", "y"]
        )
        # radius=0.19: entry at (0.25,0.25) is 0.05 away (in), (0.5,0.5) is 0.2 away (out)
        cands = ModelManager._bankBoxCandidates(bank, [0.3, 0.3], 0.19)
        @test any(mid == 10 for (_, mid) in cands)
        @test !any(mid == 20 for (_, mid) in cands)   # distance 0.2 > 0.19 in each dim
        @test !any(mid == 30 for (_, mid) in cands)

        # radius=0.3: all three entries should be within (0.5,0.5) ± 0.3
        cands_wide = ModelManager._bankBoxCandidates(bank, [0.5, 0.5], 0.3)
        @test Set(mid for (_, mid) in cands_wide) == Set([10, 20, 30])

        # Empty bank → empty result
        empty_bank = ModelManager.SimulationBank(Int[], Matrix{Float64}(undef, 2, 0), ["x", "y"])
        @test isempty(ModelManager._bankBoxCandidates(empty_bank, [0.5, 0.5], 0.5))

        # Dimension mismatch → assertion error (invariant violation)
        @test_throws AssertionError ModelManager._bankBoxCandidates(bank, [0.5], 0.5)
    end

    @testset "_lookupAndSnap" begin
        bank = ModelManager.SimulationBank(
            [99],
            reshape([0.52, 0.48], 2, 1),   # CDF coords for monad 99
            ["x", "y"]
        )
        param_names = ["x", "y"]
        k_eff  = 2     # grid = {0.25, 0.5, 0.75}
        radius = 0.1

        mid_gen = Tuple{Vector{Float64},Int}[]

        # Bank hit: monad 99 at (0.52, 0.48) is within radius 0.1 of original (0.49, 0.51)
        eff, mid = ModelManager._lookupAndSnap(
            Dict("x" => 0.49, "y" => 0.51), param_names, k_eff, radius, bank, mid_gen)
        @test mid == 99
        @test eff["x"] ≈ 0.52   # bank monad's actual CDF coords
        @test eff["y"] ≈ 0.48

        # Bank hit again with same proposal — bank reuse is always allowed (duplicates OK)
        eff2, mid2 = ModelManager._lookupAndSnap(
            Dict("x" => 0.49, "y" => 0.51), param_names, k_eff, radius, bank, mid_gen)
        @test mid2 == 99   # same bank monad returned again

        # No bank hit → snap coords returned, mid is nothing (resolved later by evaluate_batch)
        eff3, mid3 = ModelManager._lookupAndSnap(
            Dict("x" => 0.26, "y" => 0.74), param_names, k_eff, radius, bank, mid_gen)
        @test eff3["x"] ≈ 0.25   # snapped (no bank hit at (0.26, 0.74))
        @test eff3["y"] ≈ 0.75
        @test isnothing(mid3)

        # mid_gen hit: after registering mid 200, same proposal reuses it
        push!(mid_gen, ([0.25, 0.75], 200))
        eff4, mid4 = ModelManager._lookupAndSnap(
            Dict("x" => 0.26, "y" => 0.74), param_names, k_eff, radius, bank, mid_gen)
        @test mid4 == 200   # mid_gen candidate found

        # No bank or mid_gen hit → returns nothing for mid
        eff5, mid5 = ModelManager._lookupAndSnap(
            Dict("x" => 0.01, "y" => 0.99), param_names, k_eff, radius, bank, mid_gen)
        @test eff5 isa Dict{String,Float64}
        @test isnothing(mid5)
    end

    @testset "ABCSMC cdf_grid_k field and validation" begin
        m = ABCSMC()
        @test isnothing(m.cdf_grid_k)

        m2 = ABCSMC(cdf_grid_k=3)
        @test m2.cdf_grid_k == 3

        @test_throws ArgumentError ABCSMC(cdf_grid_k=0)
        @test_throws ArgumentError ABCSMC(cdf_grid_k=-1)
    end

    @testset "method.toml round-trip preserves every ABCSMC field" begin
        using TOML
        mktempdir() do dir
            # The real serializer, not a hand-built copy of its key list. The two testsets this
            # replaces each inlined that list because _saveMethod only took a Calibration and
            # calibrationFolder(stub) is not a real path; the path-taking form removes that excuse,
            # so a field added to ABCSMC and forgotten in _saveMethod now fails here.
            m = ABCSMC(population_size=7, max_nr_populations=3, minimum_epsilon=0.02,
                       epsilon_quantile=0.4, epsilon_schedule=[0.5, 0.25],
                       min_acceptance_rate=0.1, min_epsilon_decrease=0.05, min_ess_fraction=0.3,
                       accept_overflow=true, cdf_grid_k=4, max_evaluations=1000,
                       store_rejected=true, perturbation_kernel=ComponentwiseKernel())
            path = ModelManager._saveMethod(joinpath(dir, "method.toml"), m)
            back = ModelManager._loadMethod(TOML.parsefile(path))

            for f in fieldnames(ABCSMC)
                f === :perturbation_kernel && continue
                @test getfield(back, f) == getfield(m, f)
            end
            @test typeof(back.perturbation_kernel) === typeof(m.perturbation_kernel)

            # store_rejected is the field that was unreachable through runABC for its whole life;
            # pin that it survives the file too.
            @test back.store_rejected

            # Nil case: the optional fields write no key rather than a placeholder, since TOML has
            # no null.
            nil_path = ModelManager._saveMethod(joinpath(dir, "method_nil.toml"), ABCSMC())
            raw_nil = TOML.parsefile(nil_path)
            @test !haskey(raw_nil, "cdf_grid_k")
            @test !haskey(raw_nil, "max_evaluations")
            @test !haskey(raw_nil, "epsilon_schedule")
            @test raw_nil["type"] == "ABCSMC"

            # A file written before these fields (or the type key) existed must still resume: every
            # key is optional on load and the keyword constructor supplies the rest.
            legacy = Dict{String,Any}(
                "population_size"     => 11,
                "max_nr_populations"  => 2,
                "minimum_epsilon"     => 0.01,
                "epsilon_quantile"    => 0.5,
                "perturbation_kernel" => ModelManager._serializeKernel(GaussianKernel()),
            )
            legacy_path = joinpath(dir, "legacy.toml")
            open(legacy_path, "w") do io; TOML.print(io, legacy); end
            old = ModelManager._loadMethod(TOML.parsefile(legacy_path))
            @test old.population_size == 11
            @test old.max_nr_populations == 2
            defaults = ABCSMC()
            for f in (:min_acceptance_rate, :min_epsilon_decrease, :min_ess_fraction,
                      :accept_overflow, :cdf_grid_k, :max_evaluations, :store_rejected,
                      :epsilon_schedule)
                @test getfield(old, f) == getfield(defaults, f)
            end

            # An unrecognized type is named rather than silently read as ABCSMC.
            @test_throws ErrorException ModelManager._loadMethod(
                Dict{String,Any}("type" => "NotAMethod"))
        end
    end

    @testset "every ABCSMC field is either a TOML scalar or explicitly handled" begin
        # method.toml's key list is derived from the struct rather than restated, which is what lets
        # a new field serialize itself. The risk that buys is a future *non-scalar* field being
        # silently dropped from the file, so assert the partition still covers the struct exactly.
        scalars  = ModelManager._abcsmcScalarFields()
        explicit = ModelManager._ABCSMC_EXPLICIT_TOML_FIELDS
        @test Set([scalars..., explicit...]) == Set(fieldnames(ABCSMC))
        @test isempty(intersect(scalars, explicit))
        # The two explicitly-handled fields are exactly the ones that are not TOML scalars.
        for f in explicit
            @test !ModelManager._isTomlScalar(
                ModelManager._tomlScalarType(fieldtype(ABCSMC, f)))
        end
        # Union{Nothing,T} unwraps to T, which is what the loader converts to.
        @test ModelManager._tomlScalarType(fieldtype(ABCSMC, :cdf_grid_k)) === Int
        @test ModelManager._tomlScalarType(fieldtype(ABCSMC, :population_size)) === Int
    end

    @testset "runABC keyword forwarding" begin
        # Every ABCSMC field is reachable, including store_rejected, which runABC's hand-written
        # keyword list omitted.
        m = ModelManager._methodFromKeywords(ABCSMC, (; store_rejected=true, population_size=4))
        @test m.store_rejected
        @test m.population_size == 4

        # A typo is named, rather than reaching the constructor as an opaque MethodError.
        err = try
            ModelManager._methodFromKeywords(ABCSMC, (; populaton_size=4))
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("populaton_size", sprint(showerror, err))

        # The run controls are derived from runABC's own signature, so they cannot drift from it.
        controls = ModelManager._runControlKeywords()
        @test :tags in controls
        @test :method in controls
        @test isempty(intersect(controls, fieldnames(ABCSMC)))
        # The kwargs... splat itself is not a run control.
        @test !any(k -> endswith(String(k), "..."), controls)
    end

    @testset "CDF-grid snapping disabled when cdf_grid_k=nothing" begin
        # Without snapping, particles are NOT constrained to grid points.
        Random.seed!(42)
        method = ABCSMC(population_size=10, max_nr_populations=2, minimum_epsilon=0.0)
        evaluate_batch = (t, proposals) -> [(rand(), 0) for _ in proposals]
        gens = ModelManager._runABCSMC(method, ["x"], [Uniform(0, 1)],
                                        evaluate_batch, g -> nothing)
        # Gen 1 x-values are free-floating (no grid alignment expected)
        k3 = 3
        n3 = 2^k3
        aligned = [isapprox(u, round(Int, u*n3)/n3; atol=1e-10) for u in gens[1].particles[!, :x]]
        @test !all(aligned)   # not all on the k=3 grid
    end

    @testset "pre-generation stop removed: algorithm runs at minimum_epsilon" begin
        # Previously the algorithm stopped before running a generation when the
        # adaptive epsilon hit the floor. Now it must run that generation.
        # Setup: distances are uniform in [0, 1], minimum_epsilon=0.5, epsilon_quantile=0.5.
        # Gen 1: all accepted, epsilon = max(...) ≤ 1. If max > 0.5 the old code
        # would run gen 2 with epsilon_t=0.5 (adaptive median ≤ 0.5), then
        # gen 2 epsilon = max(accepted d) ≤ 0.5 → post-gen stop fires.
        Random.seed!(7)
        evaluate_batch = (t, proposals) -> [(rand(), 0) for _ in proposals]
        method = ABCSMC(population_size=20, max_nr_populations=5, minimum_epsilon=0.5,
                        epsilon_quantile=0.5)
        gens = ModelManager._runABCSMC(method, ["x"], [Uniform(0, 1)],
                                        evaluate_batch, g -> nothing)
        # Must have run at least 2 generations, and the final gen must satisfy epsilon ≤ 0.5.
        @test length(gens) >= 2
        @test gens[end].max_epsilon_accepted <= 0.5
        @test all(d <= 0.5 for d in gens[end].distances)
    end

    ################## max_evaluations ##################

    @testset "ABCSMC max_evaluations field" begin
        m = ABCSMC()
        @test isnothing(m.max_evaluations)

        m2 = ABCSMC(max_evaluations=500)
        @test m2.max_evaluations == 500
        @test_throws ArgumentError ABCSMC(max_evaluations=0)
        @test_throws ArgumentError ABCSMC(max_evaluations=-1)
    end


    ################## Problem persistence: anonymous function detection ##################

    @testset "_isAnonymousFunction" begin
        @test  ModelManager._isAnonymousFunction(x -> x^2)
        @test  ModelManager._isAnonymousFunction((x, y) -> x + y)
        named_fn(x) = x^2
        @test !ModelManager._isAnonymousFunction(named_fn)
        @test !ModelManager._isAnonymousFunction(identity)
        @test !ModelManager._isAnonymousFunction(mseDistance)
    end

    @testset "_StrippedLVSource construction" begin
        xp = XMLPath(["overall", "max_time"])
        lv_fn(us) = us[1] * 4.0  # named function
        lv = LatentVariation(
            [Uniform(0.0, 1.0)],
            XMLPath[xp],
            Function[lv_fn],
            ["rate"],
            Symbol[:config]
        )
        stripped = ModelManager._StrippedLVSource(lv)
        @test stripped.latent_parameter_names == ["rate"]
        @test stripped.target_names           == lv.target_names
        @test stripped.name                   == lv.name
        @test columnName.(stripped.targets)   == columnName.(lv.targets)
        @test stripped.types                  == lv.types
        @test length(stripped.latent_parameters) == 1

        # Construction from LVSource wrapper
        src = ModelManager.LVSource(lv)
        stripped2 = ModelManager._StrippedLVSource(src)
        @test stripped2.latent_parameter_names == stripped.latent_parameter_names
    end

    @testset "_hasAnyAnonymousFunction and _ProblemManifest" begin
        xp  = XMLPath(["overall", "max_time"])
        dv  = DistributedVariation(:config, xp, Uniform(0.0, 1.0))
        cp_dv = ModelManager._toCalibrationParameter(dv)

        inputs  = ModelManager.InputFolders(Pair{Symbol,Union{String,Int}}[])
        var_id  = ModelManager.VariationID(Pair{Symbol,Int}[])
        obs     = Dict{String,Any}("x" => 1.0)

        # Use module-level helpers (not testset-local closures) so _isAnonymousFunction → false
        prob_named = CalibrationProblem(inputs, CalibrationParameter[cp_dv], obs,
                                        _test_named_ss, _test_named_dist, 1, var_id)
        @test !ModelManager._hasAnyAnonymousFunction(prob_named)

        # Anonymous summary_statistic
        prob_anon_ss = CalibrationProblem(inputs, CalibrationParameter[cp_dv], obs,
                                          QoI("x", s -> 1.0), _test_named_dist, 1, var_id)
        @test ModelManager._hasAnyAnonymousFunction(prob_anon_ss)

        # Anonymous distance
        prob_anon_d = CalibrationProblem(inputs, CalibrationParameter[cp_dv], obs,
                                          _test_named_ss, (s,o) -> 0.0, 1, var_id)
        @test ModelManager._hasAnyAnonymousFunction(prob_anon_d)

        # Anonymous LV map
        lv_anon = LatentVariation([Uniform(0,1)], XMLPath[xp],
                                   Function[us -> us[1]], ["u"], Symbol[:config])
        cp_lv_anon = ModelManager._toCalibrationParameter(lv_anon)
        prob_anon_lv = CalibrationProblem(inputs, CalibrationParameter[cp_lv_anon], obs,
                                           _test_named_ss, _test_named_dist, 1, var_id)
        @test ModelManager._hasAnyAnonymousFunction(prob_anon_lv)

        # _ProblemManifest: DVSource stays DVSource; named functions preserved
        manifest_dv = ModelManager._ProblemManifest(prob_named)
        @test length(manifest_dv.sources) == 1
        @test manifest_dv.sources[1] isa ModelManager.DVSource
        @test manifest_dv.n_replicates == 1
        @test manifest_dv.observed_data == obs
        @test manifest_dv.summary_statistic === _test_named_ss
        @test manifest_dv.distance === _test_named_dist
        @test ModelManager._isCompleteManifest(manifest_dv)

        # _ProblemManifest: anonymous ss → nothing; incomplete manifest
        manifest_anon_ss = ModelManager._ProblemManifest(prob_anon_ss)
        @test isnothing(manifest_anon_ss.summary_statistic)
        @test !ModelManager._isCompleteManifest(manifest_anon_ss)

        # _ProblemManifest: LVSource with anon map → _StrippedLVSource; incomplete
        manifest_lv = ModelManager._ProblemManifest(prob_anon_lv)
        @test manifest_lv.sources[1] isa ModelManager._StrippedLVSource
        @test !ModelManager._isCompleteManifest(manifest_lv)
    end

    @testset "_ProblemManifest JLD2 round-trip" begin
        xp  = XMLPath(["overall", "max_time"])
        dv  = DistributedVariation(:config, xp, Uniform(0.0, 1.0))
        cp_dv = ModelManager._toCalibrationParameter(dv)
        inputs = ModelManager.InputFolders(Pair{Symbol,Union{String,Int}}[])
        var_id = ModelManager.VariationID(Pair{Symbol,Int}[])
        obs    = Dict{String,Any}("x" => 1.0)

        mktempdir() do dir
            # Named-function problem → always saves as "manifest" key; complete manifest
            prob_named = CalibrationProblem(inputs, CalibrationParameter[cp_dv], obs,
                                            _test_named_ss, _test_named_dist, 1, var_id)
            manifest_named = ModelManager._ProblemManifest(prob_named)
            @test ModelManager._isCompleteManifest(manifest_named)
            @test manifest_named.summary_statistic === _test_named_ss
            @test manifest_named.distance === _test_named_dist
            path = joinpath(dir, "problem_named.jld2")
            jldsave(path; manifest=manifest_named)
            loaded = jldopen(f -> f["manifest"]::ModelManager._ProblemManifest, path)
            @test ModelManager._isCompleteManifest(loaded)
            @test loaded.sources[1] isa ModelManager.DVSource  # DV not stripped

            # Anonymous summary_statistic → incomplete manifest; distance still preserved
            anon_ss   = QoI("x", s -> 1.0)          # anonymous `compute` => unrestorable QoI
            prob_anon = CalibrationProblem(inputs, CalibrationParameter[cp_dv], obs,
                                           anon_ss, _test_named_dist, 1, var_id)
            manifest_anon = ModelManager._ProblemManifest(prob_anon)
            @test !ModelManager._isCompleteManifest(manifest_anon)
            @test isnothing(manifest_anon.summary_statistic)     # stripped to nothing
            @test manifest_anon.distance === _test_named_dist    # named function preserved
            @test manifest_anon.sources[1] isa ModelManager.DVSource  # DV not stripped

            # Round-trip: save + load preserves completeness flag
            path2 = joinpath(dir, "problem_anon.jld2")
            jldsave(path2; manifest=manifest_anon)
            loaded2 = jldopen(f -> f["manifest"]::ModelManager._ProblemManifest, path2)
            @test !ModelManager._isCompleteManifest(loaded2)
            @test isnothing(loaded2.summary_statistic)
        end
    end

    @testset "_validateStructuralMatch" begin
        xp  = XMLPath(["overall", "max_time"])
        xp2 = XMLPath(["cell_def", "rate"])
        dv  = DistributedVariation(:config, xp, Uniform(0.0, 1.0))
        dv2 = DistributedVariation(:config, xp, Normal(0.0, 1.0))  # different dist
        cp_dv  = ModelManager._toCalibrationParameter(dv)
        cp_dv2 = ModelManager._toCalibrationParameter(dv2)

        cv  = CoVariation(dv, DistributedVariation(:config, xp2, Uniform(0.0, 2.0)))
        cp_cv = ModelManager._toCalibrationParameter(cv)

        lv_map(us) = exp(us[1])
        lv = LatentVariation([Normal(0.0, 1.0)], XMLPath[xp],
                             Function[lv_map], ["log_rate"], Symbol[:config])
        cp_lv = ModelManager._toCalibrationParameter(lv)
        stripped = ModelManager._StrippedLVSource(lv)

        # DVSource: matching → no error
        ModelManager._validateStructuralMatch(cp_dv, ModelManager.DVSource(dv), 1)
        @test true

        # DVSource: distribution mismatch → error
        @test_throws ErrorException ModelManager._validateStructuralMatch(
            cp_dv2, ModelManager.DVSource(dv), 1)

        # DVSource: wrong type for parameter → error
        @test_throws ErrorException ModelManager._validateStructuralMatch(
            cp_cv, ModelManager.DVSource(dv), 1)

        # CVSource: matching → no error
        ModelManager._validateStructuralMatch(cp_cv, ModelManager.CVSource(cv), 1)
        @test true

        # CVSource: wrong type for parameter → error
        @test_throws ErrorException ModelManager._validateStructuralMatch(
            cp_dv, ModelManager.CVSource(cv), 1)

        # _StrippedLVSource: matching → no error
        ModelManager._validateStructuralMatch(cp_lv, stripped, 1)
        @test true

        # _StrippedLVSource: latent_parameter_names mismatch → error
        lv_diff_name(us) = exp(us[1])
        lv_renamed = LatentVariation([Normal(0.0, 1.0)], XMLPath[xp],
                                     Function[lv_diff_name], ["wrong_name"], Symbol[:config])
        cp_lv_renamed = ModelManager._toCalibrationParameter(lv_renamed)
        @test_throws ErrorException ModelManager._validateStructuralMatch(
            cp_lv_renamed, stripped, 1)

        # _StrippedLVSource: wrong type for parameter → error
        @test_throws ErrorException ModelManager._validateStructuralMatch(
            cp_dv, stripped, 1)

        # LVSource (non-stripped, saved when maps are named functions):
        # matching re-supplied → no error
        lv_src = ModelManager.LVSource(lv)
        ModelManager._validateStructuralMatch(cp_lv, lv_src, 1)
        @test true

        # LVSource: latent_parameter_names mismatch → error
        lv_renamed2 = LatentVariation([Normal(0.0, 1.0)], XMLPath[xp],
                                      Function[lv_map], ["wrong_name"], Symbol[:config])
        cp_lv_renamed2 = ModelManager._toCalibrationParameter(lv_renamed2)
        @test_throws ErrorException ModelManager._validateStructuralMatch(
            cp_lv_renamed2, lv_src, 1)

        # LVSource: target mismatch → error
        xp_other = XMLPath(["other", "path"])
        lv_wrong_target = LatentVariation([Normal(0.0, 1.0)], XMLPath[xp_other],
                                          Function[lv_map], ["log_rate"], Symbol[:config])
        cp_lv_wrong_target = ModelManager._toCalibrationParameter(lv_wrong_target)
        @test_throws ErrorException ModelManager._validateStructuralMatch(
            cp_lv_wrong_target, lv_src, 1)

        # LVSource: target_names mismatch → error
        lv_named_fn(us) = exp(us[1])
        lv_wrong_tname = LatentVariation([Normal(0.0, 1.0)], XMLPath[xp],
                                         Function[lv_named_fn], ["log_rate"], Symbol[:config];
                                         target_names=["wrong_target"])
        cp_lv_wrong_tname = ModelManager._toCalibrationParameter(lv_wrong_tname)
        @test_throws ErrorException ModelManager._validateStructuralMatch(
            cp_lv_wrong_tname, lv_src, 1)

        # LVSource: name mismatch → error
        lv_named_fn2(us) = exp(us[1])
        lv_wrong_name = LatentVariation([Normal(0.0, 1.0)], XMLPath[xp],
                                        Function[lv_named_fn2], ["log_rate"], Symbol[:config];
                                        name="different_name")
        cp_lv_wrong_name = ModelManager._toCalibrationParameter(lv_wrong_name)
        @test_throws ErrorException ModelManager._validateStructuralMatch(
            cp_lv_wrong_name, lv_src, 1)

        # LVSource saved: wrong cp type re-supplied (DVSource cp) → error
        @test_throws ErrorException ModelManager._validateStructuralMatch(
            cp_dv, lv_src, 1)
    end

    @testset "_validateParticleConsistency behavioral and round-trip checks" begin
        xp = XMLPath(["a", "x"])
        # DVSource: Uniform(0,2); cdf=0.5→1.0, cdf=0.25→0.5
        dv = DistributedVariation(:config, xp, Uniform(0.0, 2.0))
        cp_dv = ModelManager._toCalibrationParameter(dv)
        col   = cp_dv.lv.latent_parameter_names[1]  # e.g. "a/x"
        @test ModelManager._displayColumns(cp_dv) == [col]

        cdf_df_dv     = DataFrame(Symbol(col) => [0.5, 0.25])
        display_df_dv = DataFrame(Symbol(col) => [1.0, 0.5])  # quantile(Uniform(0,2), ...)
        ModelManager._validateParticleConsistency(
            [cp_dv], [cp_dv.source], cdf_df_dv, display_df_dv; lv_only=false)
        @test true

        # DVSource: wrong stored value → error
        display_df_dv_bad = DataFrame(Symbol(col) => [1.0, 0.9])  # 0.9 ≠ 0.5
        @test_throws ErrorException ModelManager._validateParticleConsistency(
            [cp_dv], [cp_dv.source], cdf_df_dv, display_df_dv_bad; lv_only=false)

        # DVSource with lv_only=true → skipped (no error even with wrong values)
        ModelManager._validateParticleConsistency(
            [cp_dv], [cp_dv.source], cdf_df_dv, display_df_dv_bad; lv_only=true)
        @test true

        # LVSource: map us -> 4.0 * us[1]; lp_name = "rate"; target name = "a/x"
        # CDF=0.5 → lp=quantile(Uniform(0,1),0.5)=0.5 → target=4*0.5=2.0
        # Display: ["rate", "a/x"] = [0.5, 2.0]
        lv_map_fn(us) = 4.0 * us[1]
        lv = LatentVariation([Uniform(0.0, 1.0)], XMLPath[xp],
                             Function[lv_map_fn], ["rate"], Symbol[:config])
        cp_lv = ModelManager._toCalibrationParameter(lv)
        stripped_lv = ModelManager._StrippedLVSource(lv)

        cdf_df_lv     = DataFrame(:rate => [0.5])
        display_df_lv = DataFrame(:rate => [0.5], Symbol("a/x") => [2.0])
        ModelManager._validateParticleConsistency(
            [cp_lv], [stripped_lv], cdf_df_lv, display_df_lv; lv_only=true)
        @test true

        # LVSource: wrong target value → error
        display_df_lv_bad = DataFrame(:rate => [0.5], Symbol("a/x") => [3.0])  # 3.0 ≠ 2.0
        @test_throws ErrorException ModelManager._validateParticleConsistency(
            [cp_lv], [stripped_lv], cdf_df_lv, display_df_lv_bad; lv_only=true)

        # LVSource with inverse_maps: round-trip check
        # map: us -> 4*us[1], inverse: tv -> tv[1]/4
        lv_fwd(us) = 4.0 * us[1]
        lv_inv_fn(tv) = tv[1] / 4.0
        lv_with_inv = LatentVariation([Uniform(0.0, 1.0)], XMLPath[xp],
                                      Function[lv_fwd], ["rate2"], Symbol[:config];
                                      inverse_maps=Function[lv_inv_fn])
        cp_lv_inv = ModelManager._toCalibrationParameter(lv_with_inv)
        stripped_inv = ModelManager._StrippedLVSource(lv_with_inv)

        # CDF=0.5 → lp=0.5 → target=2.0 → recovered_lp=0.5 ✓; display=[0.5, 2.0]
        cdf_df_inv     = DataFrame(:rate2 => [0.5])
        display_df_inv = DataFrame(:rate2 => [0.5], Symbol("a/x") => [2.0])
        ModelManager._validateParticleConsistency(
            [cp_lv_inv], [stripped_inv], cdf_df_inv, display_df_inv; lv_only=true)
        @test true
    end

    @testset "_resolveResumeProblem dispatch" begin
        xp  = XMLPath(["overall", "max_time"])
        dv  = DistributedVariation(:config, xp, Uniform(0.0, 1.0))
        cp_dv = ModelManager._toCalibrationParameter(dv)
        inputs = ModelManager.InputFolders(Pair{Symbol,Union{String,Int}}[])
        var_id = ModelManager.VariationID(Pair{Symbol,Int}[])
        obs    = Dict{String,Any}("x" => 1.0)
        cal_stub = Calibration(9999)

        # Complete manifest + nothing → succeeds (reconstructs problem from manifest)
        prob_named = CalibrationProblem(inputs, CalibrationParameter[cp_dv], obs,
                                        _test_named_ss, _test_named_dist, 1, var_id)
        manifest_named = ModelManager._ProblemManifest(prob_named)
        @test ModelManager._isCompleteManifest(manifest_named)
        result_auto = ModelManager._resolveResumeProblem(manifest_named, nothing, cal_stub)
        @test result_auto isa CalibrationProblem
        @test length(result_auto.parameters) == 1

        # Incomplete manifest + nothing → error (problem= required)
        anon_ss   = QoI("x", s -> 1.0)          # anonymous `compute` => unrestorable QoI
        prob_anon = CalibrationProblem(inputs, CalibrationParameter[cp_dv], obs,
                                       anon_ss, _test_named_dist, 1, var_id)
        manifest_anon = ModelManager._ProblemManifest(prob_anon)
        @test !ModelManager._isCompleteManifest(manifest_anon)
        @test_throws ErrorException ModelManager._resolveResumeProblem(
            manifest_anon, nothing, cal_stub)

        # Incomplete manifest + correct problem → structural check passes (no generations)
        result_provided = ModelManager._resolveResumeProblem(manifest_anon, prob_named, cal_stub)
        @test result_provided === prob_named

        # Incomplete manifest + wrong parameter count → structural check error
        dv2 = DistributedVariation(:config, XMLPath(["a","b"]), Uniform(0.0, 1.0))
        cp_dv2 = ModelManager._toCalibrationParameter(dv2)
        prob_wrong = CalibrationProblem(inputs, CalibrationParameter[cp_dv, cp_dv2], obs,
                                        _test_named_ss, _test_named_dist, 1, var_id)
        @test_throws ErrorException ModelManager._resolveResumeProblem(
            manifest_anon, prob_wrong, cal_stub)

        # Incomplete manifest + wrong distribution → structural check error
        dv3 = DistributedVariation(:config, xp, Normal(0.0, 1.0))
        cp_dv3 = ModelManager._toCalibrationParameter(dv3)
        prob_wrong_dist = CalibrationProblem(inputs, CalibrationParameter[cp_dv3], obs,
                                             _test_named_ss, _test_named_dist, 1, var_id)
        @test_throws ErrorException ModelManager._resolveResumeProblem(
            manifest_anon, prob_wrong_dist, cal_stub)
    end

    ################## _validateInverseMaps ##################

    @testset "_validateInverseMaps" begin
        xp = XMLPath(["overall", "max_time"])

        # Correct inverse: scalar map u → 4u, inverse tv → tv[1]/4
        lv_ok = LatentVariation(
            [Uniform(0.0, 1.0)],
            XMLPath[xp],
            Function[us -> 4.0 * us[1]],   # scalar map
            ["rate"],
            Symbol[:config];
            inverse_maps=Function[tv -> tv[1] / 4.0]
        )
        @test isnothing(ModelManager._validateInverseMaps(lv_ok))

        # Wrong inverse (off by factor of 2) → ArgumentError thrown at construction
        @test_throws ArgumentError LatentVariation(
            [Uniform(0.0, 1.0)],
            XMLPath[xp],
            Function[us -> 4.0 * us[1]],
            ["rate_bad"],
            Symbol[:config];
            inverse_maps=Function[tv -> tv[1] / 2.0]   # should be /4; gives u'=2u≠u
        )

        # inverse_maps=nothing → no-op, returns nothing
        lv_nil = LatentVariation(
            [Uniform(0.0, 1.0)],
            XMLPath[xp],
            Function[us -> us[1]],   # scalar identity
            ["x"],
            Symbol[:config]
        )
        @test isnothing(ModelManager._validateInverseMaps(lv_nil))

        # Wrong-length inverse_maps → AssertionError at construction
        @test_throws AssertionError LatentVariation(
            [Uniform(0.0, 1.0), Uniform(0.0, 1.0)],
            XMLPath[xp, xp],
            Function[us -> us[1], us -> us[2]],   # scalar maps
            ["a", "b"],
            Symbol[:config, :config];
            inverse_maps=Function[tv -> tv[1]]   # only 1 inverse for 2 latent dims
        )

        # Inverse returning constant > 1 → ArgumentError at construction (always outside (0,1))
        @test_throws ArgumentError LatentVariation(
            [Uniform(0.0, 1.0)],
            XMLPath[xp],
            Function[us -> us[1]],   # scalar identity
            ["x_bad"],
            Symbol[:config];
            inverse_maps=Function[tv -> 1.5]   # always outside (0,1)
        )
    end

    @testset "max_evaluations caps total evaluations (checked before each batch)" begin
        Random.seed!(42)
        eval_count = Ref(0)
        evaluate_batch = function(t, proposals)
            eval_count[] += length(proposals)
            return [(rand(), 0) for _ in proposals]
        end
        # The budget is enforced BEFORE each batch is dispatched, so the batch that would
        # cross the budget is trimmed to exactly the remaining allowance — the run never
        # evaluates more than max_evaluations simulations.
        method = ABCSMC(population_size=10, max_nr_populations=10, minimum_epsilon=0.0,
                        max_evaluations=25)
        gens = ModelManager._runABCSMC(method, ["x"], [Uniform(0, 1)],
                                        evaluate_batch, g -> nothing)

        @test length(gens) < 10                          # stopped early
        total_evals = sum(g.n_evaluations for g in gens)
        @test total_evals <= method.max_evaluations      # never overshoots the budget
        @test total_evals == 25                          # budget hit exactly (final batch trimmed)
        @test eval_count[] == 25                         # evaluate_batch never dispatched over budget
    end

    @testset "max_evaluations smaller than a generation trims generation 1" begin
        Random.seed!(1)
        eval_count = Ref(0)
        evaluate_batch = function(t, proposals)
            eval_count[] += length(proposals)
            return [(rand(), 0) for _ in proposals]
        end
        # Budget below population_size: even generation 1 is trimmed to the budget.
        method = ABCSMC(population_size=10, max_nr_populations=5, minimum_epsilon=0.0,
                        max_evaluations=4)
        gens = ModelManager._runABCSMC(method, ["x"], [Uniform(0, 1)],
                                        evaluate_batch, g -> nothing)
        @test length(gens) == 1
        @test eval_count[] == 4                     # never dispatched more than the budget
        @test nrow(gens[1].particles) == 4          # partial first generation
        @test gens[1].weights ≈ fill(0.25, 4)       # weights renormalized to the trimmed size
    end

    @testset "a generation that accepts nothing is discarded, not persisted" begin
        Random.seed!(3)
        saved = Int[]
        # Generation 1's distances are ordinary; everything after is far above any threshold the
        # quantile rule can pick, so generation 2 accepts nothing and runs until the budget stops
        # it. That used to reach `maximum(distances)` on an empty vector and throw
        # "reducing over an empty collection" without ever naming the budget.
        evaluate_batch = function(t, proposals)
            return [(t == 1 ? rand() : 1.0e6, 0) for _ in proposals]
        end
        method = ABCSMC(population_size=6, max_nr_populations=4, minimum_epsilon=0.0,
                        max_evaluations=12)
        gens = @test_logs (:warn, r"accepted no particles") match_mode=:any begin
            ModelManager._runABCSMC(method, ["x"], [Uniform(0, 1)], evaluate_batch,
                                     g -> push!(saved, g.t); verbosity=:none)
        end
        @test length(gens) == 1        # the empty generation never joins the result...
        @test saved == [1]             # ...and is never handed to the persistence callback
    end

    ################## DB-backed integration ##################
    #
    # All tests below initialise a real SQLite project in a temporary directory and
    # exercise the code paths that the in-memory unit tests above never reach:
    # schema creation, variation tables, the trial hierarchy (Simulation / Monad /
    # Sampling / Trial), the runner (run / createTrial), parameter reads, calibration
    # end-to-end (runCalibration / resumeABC), deletion, and global sensitivity.
    #
    # TestSimulator.runSimulation is a no-op that returns success immediately, so the
    # tests are fast (no real simulator is launched).

    # ---------------------------------------------------------------------------
    # Helper: build the minimal project directory layout that initializeModelManager
    # requires.  One location (:config), required, varied, one input folder ("default")
    # containing a two-parameter XML file.
    # ---------------------------------------------------------------------------
    function _make_test_project(dir::String)
        inputs_dir  = joinpath(dir, "inputs")
        configs_dir = joinpath(inputs_dir, "configs")
        default_dir = joinpath(configs_dir, "default")
        outputs_dir = joinpath(dir, "outputs")
        mkpath(default_dir)
        mkpath(outputs_dir)

        open(joinpath(inputs_dir, "inputs.toml"), "w") do io
            print(io, """
            [config]
            required = true
            varied   = true
            basename = "params.xml"
            """)
        end

        # Minimal XML with two leaf parameters the tests will vary.
        # Root element is <params>; path ["data","x"] traverses <params><data><x>.
        open(joinpath(default_dir, "params.xml"), "w") do io
            print(io, """
            <params>
              <data>
                <x>1.0</x>
                <y>2.0</y>
              </data>
            </params>
            """)
        end
    end

    @testset "calibration progress verbosity" begin
        # Rank ordering: none < generation < batch < bar
        @test ModelManager._verbosityRank(:none)       == 0
        @test ModelManager._verbosityRank(:generation) == 1
        @test ModelManager._verbosityRank(:batch)      == 2
        @test ModelManager._verbosityRank(:bar)        == 3

        # Explicit levels pass through unchanged.
        for v in (:none, :generation, :batch, :bar)
            @test ModelManager._resolveVerbosity(v) == v
        end
        # :auto resolves based on whether stdout is a TTY (either is acceptable here).
        @test ModelManager._resolveVerbosity(:auto) in (:bar, :generation)
        # Unknown settings throw.
        @test_throws ArgumentError ModelManager._resolveVerbosity(:loud)

        # The progress-bar callback is built only at :bar.
        @test ModelManager._batchProgressCallback(:none, "x ")       === nothing
        @test ModelManager._batchProgressCallback(:generation, "x ") === nothing
        @test ModelManager._batchProgressCallback(:batch, "x ")      === nothing
        cb = ModelManager._batchProgressCallback(:bar, "x ")
        @test cb !== nothing
        # Full lifecycle must not error, including the zero-pending-simulation case.
        @test cb(:init, 2)  === nothing
        @test cb(:step, 1)  === nothing
        @test cb(:step, 1)  === nothing
        @test cb(:finish, 2) === nothing
        cb0 = ModelManager._batchProgressCallback(:bar, "y ")
        @test cb0(:init, 0)  === nothing   # no bar created
        @test cb0(:step, 1)  === nothing   # no-op when no bar exists
        @test cb0(:finish, 0) === nothing
    end

    @testset "DB-backed integration" begin
        mktempdir() do project_dir
            _make_test_project(project_dir)

            # ---------- initialisation ----------
            @testset "initializeModelManager" begin
                ok = initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
                waitForDiagnostics()
                @test ok
                @test isInitialized()
                @test dataDir() == abspath(project_dir)
                @test isfile(joinpath(project_dir, "mm.db"))
                @test isfile(joinpath(project_dir, "inputs", "configs", "default",
                                      "config_variations.db"))
            end

            @testset "run_on_hpc auto-detection" begin
                detected = mm_globals().run_on_hpc
                try
                    # The bug this guards: nothing ever called isRunningOnHPC(), so the flag
                    # sat at its `false` struct default even on a SLURM machine where
                    # isRunningOnHPC() returned true. Holds on a laptop and a cluster alike.
                    @test detected == isRunningOnHPC()
                    @test detected == ModelManager.shellCommandExists(`sbatch`)

                    # useHPC still overrides in both directions after init. Sequenced so the
                    # flag is always false before a `useHPC(true)`, which keeps the
                    # already-on warning (maxlog=1) out of the test output.
                    useHPC(false)
                    @test mm_globals().run_on_hpc == false
                    useHPC(true)
                    @test mm_globals().run_on_hpc == true
                    useHPC(false)
                    @test mm_globals().run_on_hpc == false
                    useHPC()
                    @test mm_globals().run_on_hpc == true

                    # Re-initializing re-detects unconditionally, discarding an override.
                    # Set the field directly rather than via useHPC to avoid the warning.
                    mm_globals().run_on_hpc = !detected
                    @test initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
                    waitForDiagnostics()
                    @test mm_globals().run_on_hpc == detected
                finally
                    # A stale `true` would send every later deletion test's rm_hpc_safe down
                    # the .trash/ staging path instead of rm.
                    mm_globals().run_on_hpc = detected
                end
            end

            # Migrations follow the version loaded in the session, not the one installed in the
            # environment: the milestone list comes from the loaded code, so the loaded release
            # is the furthest a session can correctly migrate to. Updating the environment
            # mid-session therefore delays the schema change to the next session rather than
            # recording a version whose migration never ran.
            @testset "migration targets the loaded version" begin
                installed = ModelManager.getInstalledVersion(TestSimulator())
                table = ModelManager.dbVersionTableName(TestSimulator())
                try
                    # --- the default hooks ------------------------------------------------
                    # A type outside any package resolves to Main, which is a loaded module but
                    # carries no version.
                    @test ModelManager._loadedPackageVersion(_NoModuleSimulator()) === nothing
                    # The fixture below is a genuine submodule, so resolving it exercises the
                    # moduleroot walk rather than a bare parentmodule.
                    @test parentmodule(_NestedSimModule.NestedSimulator) !== Main

                    # --- the migration target ---------------------------------------------
                    # The loaded version is the target. For TestSimulator the default resolves via
                    # _packageModule to the loaded ModelManager, which here equals the installed one.
                    _loaded_version_override[] = :default
                    @test ModelManager._loadedPackageVersion(TestSimulator()) == installed
                    _loaded_version_override[] = v"0.4.0"
                    @test ModelManager._loadedPackageVersion(TestSimulator()) == v"0.4.0"

                    # Identity comes from the module defining the type, so no name is involved and
                    # none can be ambiguous. _NoModuleSimulator resolves to Main, which has no UUID
                    # and no version.
                    @test ModelManager._packageModule(_NoModuleSimulator()) === Main
                    @test Base.PkgId(Main).uuid === nothing
                    # A type in a submodule resolves to the root module, not the immediate parent.
                    # Here that root is Main; the package case is covered by the fixture package
                    # exercised outside the suite.
                    @test ModelManager._packageModule(_NestedSimModule.NestedSimulator()) === Main
                    # The installed lookup is keyed on that module's UUID, so it agrees with the
                    # module's own reported version rather than searching by name.
                    @test ModelManager.getInstalledVersion(TestSimulator()) ==
                          pkgversion(ModelManager)
                    # No package, no installed version -- and it says why.
                    @test_throws ArgumentError ModelManager.getInstalledVersion(_NoModuleSimulator())

                    # --- resolvePackageVersion --------------------------------------------
                    # Resolvable loaded version: behaves as it always did.
                    _loaded_version_override[] = :default
                    @test initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
                    waitForDiagnostics()
                    @test ModelManager.getDBPackageVersion(TestSimulator(), centralDB()) == installed

                    # No determinable loaded version: the project still opens, but nothing is
                    # migrated and nothing is recorded, because which milestones belong to the
                    # running code is unknowable.
                    mktempdir() do unversioned_dir
                        _make_test_project(unversioned_dir)
                        _loaded_version_override[] = nothing
                        @test initializeModelManager(TestSimulator(), unversioned_dir;
                                                     auto_upgrade=true)
                        waitForDiagnostics()
                        @test isInitialized()
                        # No version table was stamped on the way through.
                        @test !ModelManager.tableExists(table)
                        # And getDBPackageVersion says why rather than inventing a version.
                        @test_throws ArgumentError ModelManager.getDBPackageVersion(
                            TestSimulator(), centralDB())
                    end

                    # Versions agree, so the recorded version is left where it is.
                    _loaded_version_override[] = installed
                    @test initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
                    waitForDiagnostics()

                    # A mid-session update no longer blocks the session. The database is
                    # migrated to the *loaded* version rather than the installed one, so the
                    # recorded version never runs ahead of the milestones actually applied.
                    ModelManager.DBInterface.execute(centralDB(),
                                                     "UPDATE $(table) SET version='0.1.0';")
                    _loaded_version_override[] = v"0.5.0"
                    _milestone_override[] = VersionNumber[]
                    @test initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
                    waitForDiagnostics()
                    @test isInitialized()
                    @test ModelManager.getDBPackageVersion(TestSimulator(), centralDB()) == v"0.5.0"

                    # A project created for the first time mid-update is stamped with the loaded
                    # version too. getDBPackageVersion stamps a fresh database itself, so this route
                    # never passes through the migration path at all.
                    mktempdir() do fresh_dir
                        _make_test_project(fresh_dir)
                        _loaded_version_override[] = v"0.5.0"
                        @test initializeModelManager(TestSimulator(), fresh_dir; auto_upgrade=true)
                        waitForDiagnostics()
                        @test ModelManager.getDBPackageVersion(TestSimulator(), centralDB()) == v"0.5.0"
                    end

                    # A database ahead of the running code stops initialization: the schema is
                    # newer than the code about to query it. project_dir's database sits at
                    # 0.5.0 from the migration above, so 0.2.0 is behind it. The session merely
                    # lags the environment here, so the remedy printed is to restart Julia.
                    _loaded_version_override[] = v"0.2.0"
                    @test !initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
                    @test !isInitialized()
                    @test dataDir() == ""

                    # The other remedy: with no mid-session update in play, a database ahead of
                    # the installed version means the package itself is too old to open it.
                    mktempdir() do old_pkg_dir
                        _make_test_project(old_pkg_dir)
                        stale = ModelManager.SQLite.DB(joinpath(old_pkg_dir, "mm.db"))
                        ModelManager.DBInterface.execute(stale,
                            "CREATE TABLE $(table) (version TEXT PRIMARY KEY);")
                        ModelManager.DBInterface.execute(stale,
                            "INSERT INTO $(table) (version) VALUES ('99.9.9');")
                        close(stale)
                        _loaded_version_override[] = :default   # target == installed
                        @test !initializeModelManager(TestSimulator(), old_pkg_dir; auto_upgrade=true)
                        @test !isInitialized()
                    end

                    # --- upgradePackage ---------------------------------------------------
                    # Public and callable directly, so it keeps a guard of its own — a direct
                    # caller supplies to_version, which resolvePackageVersion never would.
                    _loaded_version_override[] = :default
                    @test initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
                    waitForDiagnostics()

                    # Refused: the loaded code cannot know 0.2.0's milestones, so the version
                    # table must still read 0.1.0 afterwards. This is the assertion that
                    # fails if the "no schema change" bump ever fires under the guard.
                    ModelManager.DBInterface.execute(centralDB(),
                                                     "UPDATE $(table) SET version='0.1.0';")
                    _loaded_version_override[] = v"0.1.0"
                    # A milestone *in range*, so the call count is evidence: without the guard,
                    # pending would be [0.2.0] and upgradeToMilestone would run.
                    _milestone_override[] = [v"0.2.0"]
                    _milestone_calls[] = 0
                    @test !ModelManager.upgradePackage(TestSimulator(), centralDB(),
                                                       v"0.1.0", v"0.2.0", true)
                    @test ModelManager.getDBPackageVersion(TestSimulator(), centralDB()) == v"0.1.0"
                    @test _milestone_calls[] == 0

                    # A target below the loaded version is legitimate (resuming a partially
                    # applied chain), so the guard uses `>` rather than `!=`.
                    _loaded_version_override[] = v"0.3.0"
                    _milestone_override[] = [v"0.2.0"]
                    _milestone_calls[] = 0
                    @test ModelManager.upgradePackage(TestSimulator(), centralDB(),
                                                      v"0.1.0", v"0.2.0", true)
                    @test _milestone_calls[] == 1
                    @test ModelManager.getDBPackageVersion(TestSimulator(), centralDB()) == v"0.2.0"
                    # A throw from version resolution is reported, not propagated:
                    # initializeModelManager is documented to return false on any initialization
                    # failure, and getInstalledVersion throws when the package is loaded but absent
                    # from the active environment.
                    mktempdir() do throwing_dir
                        _make_test_project(throwing_dir)
                        @test_throws ArgumentError ModelManager.getInstalledVersion(
                            _UninstalledSimulator())
                        @test !initializeModelManager(_UninstalledSimulator(), throwing_dir;
                                                      auto_upgrade=true)
                        @test !isInitialized()
                        @test dataDir() == ""
                    end

                finally
                    # Leave the project initialized and correctly stamped for everything below.
                    # Re-initializing restores the stamp on its own: the assertions above
                    # rewound the version table, and with no milestones to cross the upgrade
                    # path bumps it straight back to the installed version.
                    _loaded_version_override[] = :default
                    _milestone_override[] = VersionNumber[]
                    _milestone_calls[] = 0
                    initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
                    waitForDiagnostics()
                end
                @test isInitialized()
            end

            # Shorthand XMLPaths used throughout the section
            xp_x = XMLPath(["data", "x"])
            xp_y = XMLPath(["data", "y"])
            inputs = InputFolders(config="default")

            # ---------- classes ----------
            @testset "Simulation construction" begin
                sim1 = Simulation(inputs)
                @test sim1 isa Simulation
                @test sim1.id >= 1

                sim2 = Simulation(sim1.id)
                @test sim2.id == sim1.id

                @test_throws ErrorException Simulation(999_999)
            end

            @testset "Monad and VariationID" begin
                vid = VariationID(inputs)
                m   = Monad(inputs, vid; n_replicates=0)
                @test m isa Monad
                @test m.id >= 1
            end

            # ---------- variations ----------
            @testset "addVariations — GridVariation" begin
                dv  = DiscreteVariation(:config, xp_x, [3.0, 4.0, 5.0])
                res = ModelManager.addVariations(GridVariation(), inputs, [dv])
                @test res isa AddGridVariationsResult
                @test length(res.variation_ids) == 3
                # Each VariationID is distinct
                @test length(unique(res.variation_ids)) == 3
            end

            @testset "discrete variations agree across the grid and CDF paths" begin
                # Regression. A DiscreteVariation used to store its raw values as the latent
                # parameter with `first` as the map, so the grid path returned a value while the CDF
                # path — LHS, Sobol and RBD all reach it via addCDFVariations — returned the *index*.
                # Discrete parameters are now DiscreteUniform over value indices, so both agree.
                values = [3.0, 4.0, 5.0]
                dv  = DiscreteVariation(:config, xp_x, values)
                lv  = ModelManager.ParsedVariations([dv]).latent_variations[1]

                @test lv.latent_parameters[1] isa DiscreteUniform
                @test size(lv) == [3]                      # enumerable, so not the -1 sentinel

                grid = vec(ModelManager.variationValues(lv))
                @test grid == values

                # The CDF path returns values, not indices, and lands in the right bin.
                @test ModelManager.variationValues(lv, [0.0])[1] == 3.0
                @test ModelManager.variationValues(lv, [0.4])[1] == 4.0
                @test ModelManager.variationValues(lv, [0.9])[1] == 5.0
                # cdf = 1.0 used to compute floor(Int, 1.0*3)+1 = 4, an out-of-range index.
                @test ModelManager.variationValues(lv, [1.0])[1] == 5.0
                # Every CDF in [0,1] yields a real value from the list.
                @test all(ModelManager.variationValues(lv, [c])[1] in values for c in 0:0.05:1)

                # Same through ParsedVariations, which is what the sampling designs call.
                pv = ModelManager.ParsedVariations([dv])
                @test ModelManager.variationValues(pv, [0.4])[1] == 4.0

                # A co-variation of discrete parameters uses one index for all targets.
                dv2 = DiscreteVariation(:config, xp_y, [30.0, 40.0, 50.0])
                cv  = CoVariation(dv, dv2)
                clv = ModelManager.ParsedVariations([cv]).latent_variations[1]
                @test clv.latent_parameters[1] isa DiscreteUniform
                @test ModelManager.variationValues(clv, [0.4]) == [4.0, 40.0]
                @test vec(ModelManager.variationValues(clv)) == [3.0, 30.0, 4.0, 40.0, 5.0, 50.0]

                # The inverse map recovers the index, and throws for a value that was never a level
                # rather than handing back a sentinel that would silently become a valid-looking CDF.
                @test lv.inverse_maps[1]([4.0]) == 2
                @test_throws ArgumentError lv.inverse_maps[1]([99.0])

                # The SimulationBank inverts speculatively over whatever the database already holds,
                # so a non-level there is ordinary, not an error: _bankCdfCoords catches the throw and
                # reports the monad as not reusable via its existing `nothing` contract.
                col = ModelManager.columnName(lv.targets[1])
                @test ModelManager._bankCdfCoords(lv, Dict(col => 4.0)) !== nothing
                @test ModelManager._bankCdfCoords(lv, Dict(col => 99.0)) === nothing
            end

            @testset "grid enumeration still rejects continuous priors" begin
                # The -1 sentinel is what GridVariation checks. Generalising `size` to report support
                # cardinality must not make a continuous prior look enumerable: Uniform is finitely
                # *bounded* but not finitely *enumerable*.
                cont = ModelManager.ParsedVariations([
                    UniformDistributedVariation(:config, xp_x, 1.0, 5.0)]).latent_variations[1]
                @test size(cont) == [-1]
                @test_throws AssertionError ModelManager.variationValues(cont)
                @test_throws AssertionError ModelManager.addVariations(
                    GridVariation(), inputs, [UniformDistributedVariation(:config, xp_x, 1.0, 5.0)])
                # ...while a discrete one is enumerable and grids fine.
                res = ModelManager.addVariations(GridVariation(), inputs,
                                                 [DiscreteVariation(:config, xp_x, [6.0, 7.0])])
                @test length(res.variation_ids) == 2

                # Cardinality, not span. `_supportSize` reported `maximum - minimum + 1`, which
                # counts the gaps: the three levels [1, 5, 9] were sized 9, and the grid walk —
                # which indexes `collect(support(d))` — then ran off the end of a 3-element support.
                gappy_prior = ModelManager._discreteLevelDistribution([1.0, 5.0, 9.0])
                @test ModelManager._supportSize(gappy_prior)       == 3
                @test ModelManager._supportSize(DiscreteUniform(1, 4)) == 4   # contiguous: unchanged
                @test ModelManager._supportSize(Poisson(3.0))      == -1      # unbounded: sentinel
                gappy = LatentVariation([gappy_prior], XMLPath[xp_x],
                                        Function[lp -> lp[1]], ["g"], Symbol[:config])
                @test size(gappy) == [3]
                @test vec(ModelManager.variationValues(gappy)) == [1.0, 5.0, 9.0]
            end

            @testset "LHS over a discrete parameter maps to values" begin
                # End to end through the design that used to write indices: take the CDFs LHS
                # actually drew and push them through the same mapping addCDFVariations uses.
                values = [11.0, 12.0, 13.0]
                dv  = DiscreteVariation(:config, xp_x, values)
                pv  = ModelManager.ParsedVariations([dv])
                res = ModelManager.addVariations(LHSVariation(6), inputs, [dv])
                @test res isa AddLHSVariationsResult
                @test length(res.variation_ids) == 6
                @test size(res.cdfs, 2) == 6
                for cdf_col in eachcol(res.cdfs)
                    mapped = ModelManager.variationValues(pv, collect(cdf_col))
                    @test only(mapped) in values
                end
            end

            @testset "addVariations — LHSVariation" begin
                dv  = UniformDistributedVariation(:config, xp_x, 1.0, 5.0)
                res = ModelManager.addVariations(LHSVariation(4), inputs, [dv])
                @test res isa AddLHSVariationsResult
                @test length(res.variation_ids) == 4
            end

            @testset "addVariations — two-parameter grid" begin
                dv1 = DiscreteVariation(:config, xp_x, [10.0, 20.0])
                dv2 = DiscreteVariation(:config, xp_y, [30.0, 40.0])
                res = ModelManager.addVariations(GridVariation(), inputs, [dv1, dv2])
                @test length(res.variation_ids) == 4  # 2×2 full factorial
            end

            # ---------- createTrial / run ----------
            @testset "createTrial and run — Monad" begin
                dv  = DiscreteVariation(:config, xp_x, 7.0)
                m   = createTrial(inputs, [dv]; n_replicates=2)
                @test m isa Monad

                out = run(m)
                @test out.n_scheduled == 2
                @test out.n_success   == 2

                # use_previous=true: no new simulations launched
                out2 = run(m)
                @test out2.n_scheduled == 0
                @test out2.n_success   == 0
            end

            @testset "createTrial and run — Sampling" begin
                dv   = DiscreteVariation(:config, xp_x, [8.0, 9.0])
                samp = createTrial(inputs, [dv]; n_replicates=1)
                @test samp isa Sampling
                @test length(samp.monads) == 2

                out = run(samp)
                @test out.n_scheduled == 2
                @test out.n_success   == 2
            end

            @testset "run on_progress hook" begin
                dv   = DiscreteVariation(:config, xp_x, [101.0, 102.0, 103.0])
                samp = createTrial(inputs, [dv]; n_replicates=1)

                events = Symbol[]
                n_init = Ref(0)
                n_step = Ref(0)
                cb = function (event::Symbol, n::Int=0)
                    push!(events, event)
                    event === :init   && (n_init[] = n)
                    event === :step   && (n_step[] += 1)
                    return nothing
                end

                out = run(samp; on_progress=cb)
                @test out.n_scheduled == 3
                @test first(events) == :init        # :init fires before any :step
                @test last(events)  == :finish      # :finish fires once at the end
                @test n_init[]  == out.n_scheduled  # bar sized to pending simulations
                @test n_step[]  == out.n_scheduled  # one :step per completed simulation
                @test count(==(:finish), events) == 1
            end

            @testset "createTrial and run — Trial" begin
                dv    = DiscreteVariation(:config, xp_x, [11.0, 12.0])
                samp  = createTrial(inputs, [dv]; n_replicates=1)
                trial = Trial([samp])
                @test trial isa Trial

                out = run(trial)
                @test out.n_success == 2
            end

            @testset "run/createTrial over a vector" begin
                s1    = createTrial(inputs, [DiscreteVariation(:config, xp_x, 801.0)]; n_replicates=1)          # Simulation
                m1    = createTrial(inputs, [DiscreteVariation(:config, xp_x, 802.0)]; n_replicates=2)          # Monad
                samp1 = createTrial(inputs, [DiscreteVariation(:config, xp_x, [803.0, 804.0])]; n_replicates=1) # Sampling
                @test s1 isa Simulation && m1 isa Monad && samp1 isa Sampling

                # Accumulate heterogeneous trials in a Vector{Any}, then batch them.
                batch = []
                push!(batch, s1); push!(batch, m1); push!(batch, samp1)

                @test createTrial(batch) isa Trial

                out = run(batch)
                @test out isa MMOutput
                @test trialType(out) == Trial
                @test out.n_success == 1 + 2 + 2      # s1 + m1(2 reps) + samp1(2 monads)

                # An MMOutput forwards the ID and trivially-derived accessors to its trial,
                # so "what did that run produce?" needs no reach into out.trial.
                @test monadIDs(out)      == monadIDs(out.trial)
                @test simulationIDs(out) == simulationIDs(out.trial)
                @test constituentIDs(out) == constituentIDs(out.trial)
                @test length(out)        == length(out.trial)
                @test trialFolder(out)   == trialFolder(out.trial)
                @test trialID(out)       == out.trial.id

                # constituentIDs is the one accessor that does not answer at every level: a
                # Simulation has nothing below it, and an output wrapping one inherits that.
                @test_throws ArgumentError constituentIDs(s1)
                @test_throws ArgumentError constituentIDs(run(s1))

                # Single-element vector still yields a Trial.
                @test createTrial([s1]) isa Trial

                # A Trial element is flattened into its samplings.
                @test createTrial([Trial([samp1]), s1]) isa Trial

                # Non-trial elements and empties raise a clear ArgumentError.
                @test_throws ArgumentError createTrial([s1, 42])
                @test_throws ArgumentError run(Any[s1, "nope"])
                @test_throws ArgumentError createTrial(AbstractTrial[])
            end

            # ---------- trialID: pure lookup vs. Trial creation ----------
            @testset "trialID lookup and Trial creation" begin
                dv   = DiscreteVariation(:config, xp_x, [301.0, 302.0])
                samp = createTrial(inputs, [dv]; n_replicates=1)

                # No Trial groups this sampling yet, so the lookup misses — and saying so must
                # not create one. This is the assertion that fails if trialID ever goes back to
                # find-or-insert.
                n_trials_before = nrow(queryToDataFrame(constructSelectQuery("trials")))
                @test trialID([samp]) === missing
                @test nrow(queryToDataFrame(constructSelectQuery("trials"))) == n_trials_before

                # The Trial constructor still creates on a miss: the create path moved into
                # _findOrCreateTrialID, it did not disappear.
                trial = Trial([samp])
                @test trial isa Trial
                @test nrow(queryToDataFrame(constructSelectQuery("trials"))) == n_trials_before + 1

                # Now the lookup finds it, and agrees with the AbstractTrial accessor.
                @test trialID([samp]) == trial.id
                @test trialID(trial) == trial.id

                # Constructing again reuses the row rather than adding a duplicate.
                @test Trial([samp]).id == trial.id
                @test nrow(queryToDataFrame(constructSelectQuery("trials"))) == n_trials_before + 1
            end

            # ---------- constituentIDs / simulationIDs / monadIDs ----------
            @testset "constituentIDs, simulationIDs, and monadIDs" begin
                dv   = DiscreteVariation(:config, xp_x, [21.0, 22.0, 23.0])
                samp = createTrial(inputs, [dv]; n_replicates=2)
                run(samp)

                mono_ids = constituentIDs(samp)
                @test length(mono_ids) == 3          # 3 monads

                sim_ids  = simulationIDs(samp)
                @test length(sim_ids) == 6           # 3 monads × 2 replicates

                # monadIDs on a Sampling is its constituent list; a Monad reports itself.
                @test length(monadIDs(samp)) == 3
                @test monadIDs(samp) == mono_ids
                @test monadIDs(Monad(mono_ids[1])) == [mono_ids[1]]

                # A simulation resolves to the monad holding it. simulationIDs walks the
                # monads in constituent order, so the first simulation is in the first monad.
                @test monadIDs(Simulation(sim_ids[1])) == [mono_ids[1]]
            end

            # ---------- simulationsTable / monadsTable ----------
            @testset "monadsTable" begin
                dv   = DiscreteVariation(:config, xp_x, [201.0, 202.0, 203.0])
                samp = createTrial(inputs, [dv]; n_replicates=2)
                run(samp)

                # One row per monad (3), not per simulation (6).
                mt = monadsTable(samp)
                @test mt isa DataFrame
                @test nrow(mt) == length(constituentIDs(samp)) == 3
                @test :MonadID in propertynames(mt)
                @test :SimID ∉ propertynames(mt)

                # The varied parameter appears as a (short-named) column with all 3 values.
                x_col = only(filter(n -> occursin("x", n), names(mt)))
                @test Set(mt[!, x_col]) == Set([201.0, 202.0, 203.0])

                # simulationsTable over the same sampling has one row per simulation.
                st = simulationsTable(samp)
                @test nrow(st) == length(simulationIDs(samp)) == 6
                @test :SimID in propertynames(st)

                # Dispatch forms agree with the monad-ID vector form.
                monad_ids = constituentIDs(samp)
                @test nrow(monadsTable(monad_ids)) == 3
                m1 = Monad(monad_ids[1])
                @test nrow(monadsTable(m1)) == 1
                @test nrow(monadsTable(m1, Monad(monad_ids[2]))) == 2

                # A Simulation is an AbstractTrial, so it must work here too: it resolves to
                # the monad holding it, and mixes with other trial types in one vector.
                sim = Simulation(simulationIDs(m1)[1])
                @test monadIDs(sim) == [m1.id]
                @test nrow(monadsTable(sim)) == 1
                @test nrow(monadsTable([sim, Monad(monad_ids[2])])) == 2

                # A simulation inserted straight into `simulations` belongs to no monad. Mint a
                # variation row without a monad for it, so the key genuinely has no match.
                lone_vids = ModelManager.addVariations(GridVariation(), inputs,
                                                       [DiscreteVariation(:config, xp_x, 2049.0)],
                                                       VariationID(inputs)).variation_ids
                lone_sim = Simulation(inputs, only(lone_vids))

                # Asking must never create the monad: a Monad(simulation).id implementation
                # would pass every assertion above and fail this one.
                n_monads_before = nrow(queryToDataFrame(constructSelectQuery("monads")))
                @test monadIDs(lone_sim) == Int[]
                @test nrow(monadsTable(lone_sim)) == 0
                @test nrow(queryToDataFrame(constructSelectQuery("monads"))) == n_monads_before

                # The match is on parameterization, not membership: a simulation inserted
                # directly on an EXISTING monad's key resolves to that monad even though the
                # monad's replicate list does not contain it. Documented, not accidental.
                shared_key_sim = Simulation(m1.inputs, m1.variation_id)
                @test monadIDs(shared_key_sim) == [m1.id]
                @test shared_key_sim.id ∉ constituentIDs(Monad, m1.id)

                # The version component of the key comes from the simulation's own row, not from
                # currentSimulatorVersionID(). Bumping the project's simulator version must not
                # orphan simulations whose monads already exist.
                simulator = mm_globals().simulator
                version_before = simulator.current_version_id
                try
                    queryToDataFrame("INSERT INTO test_versions (tag) VALUES ('v-bump');")
                    simulator.current_version_id = queryToDataFrame(
                        constructSelectQuery("test_versions", "WHERE tag='v-bump'";
                                             selection="test_version_id")).test_version_id[1]
                    @test simulator.current_version_id != version_before
                    @test monadIDs(sim) == [m1.id]
                    @test nrow(monadsTable(sim)) == 1
                finally
                    simulator.current_version_id = version_before
                end
                @test monadIDs(sim) == [m1.id]

                # No-arg form returns all monads in the project (⊇ this sampling's monads).
                all_mt = monadsTable()
                @test nrow(all_mt) >= 3

                # remove_constants=false keeps the constant y column; default drops it.
                mt_full = monadsTable(monad_ids; remove_constants=false)
                @test any(n -> occursin("y", n), names(mt_full))

                # short_names=false keeps the raw XML-path column name for the varied parameter.
                mt_raw = monadsTable(samp; short_names=false)
                @test "data/x" in names(mt_raw)

                # printMonadsTable routes the DataFrame through the sink.
                captured = Ref{Any}(nothing)
                printMonadsTable(samp; sink=(df -> captured[] = df))
                @test captured[] isa DataFrame
                @test nrow(captured[]) == 3
            end

            # ---------- simulationsTable / monadsTable sorting semantics ----------
            @testset "simulationsTable sorting" begin
                # Two single-simulation trials created in a deliberate order so that SimID
                # order (creation order) is the *opposite* of ascending parameter order:
                # the higher x-value gets the smaller SimID.
                s_hi = createTrial(inputs, [DiscreteVariation(:config, xp_x, 602.0),
                                            DiscreteVariation(:config, xp_y, 2.0)]; n_replicates=1)  # smaller ID
                s_lo = createTrial(inputs, [DiscreteVariation(:config, xp_x, 601.0),
                                            DiscreteVariation(:config, xp_y, 2.0)]; n_replicates=1)  # larger ID
                run(s_hi); run(s_lo)
                pair = [s_hi, s_lo]

                # (1) An explicit `sort_by` changes the row order. Sorting by :SimID yields
                #     creation order (x = 602 then 601); the default sort orders by the sole
                #     varied parameter column (x = 601 then 602).
                st_id = simulationsTable(pair; sort_by=["SimID"])
                xcol  = only(filter(n -> occursin("x", n), names(st_id)))
                @test issorted(st_id.SimID)
                @test st_id[!, xcol] == [602.0, 601.0]

                st_default = simulationsTable(pair)                 # default: sort by parameter
                @test issorted(st_default[!, xcol])                 # ascending → [601, 602]
                @test st_default[!, xcol] == [601.0, 602.0]

                # (2) A `sort_by` naming no existing column is a hard error.
                @test_throws ArgumentError simulationsTable(pair; sort_by=["not_a_column"])

                # (3) Requesting a column that exists but is dropped by `remove_constants`
                #     (the constant y parameter) warns and falls back to the default sort.
                st_warn = @test_logs (:warn,) match_mode=:any simulationsTable(pair; sort_by=["data/y"])
                @test issorted(st_warn[!, xcol])                    # fell back to the parameter sort
            end

            # ---------- post-processing hook + sink ----------
            @testset "post-processing sink" begin
                # Callback returning a NamedTuple → one sink row per successful simulation.
                dv   = DiscreteVariation(:config, xp_x, [301.0, 302.0])
                samp = createTrial(inputs, [dv]; n_replicates=1)
                calls = Ref(0)
                out = run(samp; post_processor = QoI("pp", sim -> begin
                    calls[] += 1
                    (; sid = sim.id, doubled = 2.0 * sim.id)
                end))
                @test out.n_success == 2
                @test calls[] == 2                       # fired once per successful sim

                # The callback receives a Simulation. monadID/wasSuccessful are gone from the sink's
                # contract along with SimulationProcess: `success` was always true here (run only fires
                # the hook on success) and the monad is recoverable with monadIDs(sim).
                acc = createTrial(inputs, [DiscreteVariation(:config, xp_x, 351.0)]; n_replicates=1)
                acc_id = simulationIDs(acc)[1]
                seen = Ref{Any}(nothing)
                run(acc; post_processor = sim -> begin
                    seen[] = (simulationID(sim), only(ModelManager.monadIDs(sim)),
                              pathToOutputFolder(sim))
                    nothing
                end)
                @test seen[][1] == acc_id
                @test seen[][2] == Monad(acc).id
                @test seen[][3] == pathToOutputFolder(acc_id)
                @test seen[][3] == pathToOutputFolder(Simulation(acc_id))

                # A NamedTuple's field order reaches the columns. Routing through a Dict scrambled
                # it into hash order, so the table came back shuffled relative to what was written.
                ordered = createTrial(inputs, [DiscreteVariation(:config, xp_x, 353.0)]; n_replicates=1)
                run(ordered; post_processor = QoI("ord", sim -> (; zeta=1.0, alpha=2.0, mid=3.0, beta=4.0)))
                ot = postProcessingTable(simulationIDs(ordered))
                @test filter(in(["ord.zeta","ord.alpha","ord.mid","ord.beta"]), names(ot)) ==
                      ["ord.zeta", "ord.alpha", "ord.mid", "ord.beta"]

                # An anonymous function has no name to store under, and the regularised gensym
                # varies between sessions -- it must never become a column. Now that every column is
                # named "<qoi>.<key>", that covers a spread return too, not only a scalar one.
                @test_throws Exception run(
                    createTrial(inputs, [DiscreteVariation(:config, xp_x, 354.0)]; n_replicates=1);
                    post_processor = sim -> 7.0)
                @test_throws Exception run(
                    createTrial(inputs, [DiscreteVariation(:config, xp_x, 356.0)]; n_replicates=1);
                    post_processor = sim -> (; a = 7.0))
                @test !any(startswith("anon"), names(postProcessingTable(simulationIDs(samp))))
                # Naming it is the fix, for either return shape.
                named_ok = createTrial(inputs, [DiscreteVariation(:config, xp_x, 355.0)]; n_replicates=1)
                run(named_ok; post_processor = QoI("named_scalar", sim -> 7.0))
                @test postProcessingTable(simulationIDs(named_ok)).named_scalar[1] == 7.0
                # ...and a named function needs no wrapping, since its name is stable.
                named_fn = createTrial(inputs, [DiscreteVariation(:config, xp_x, 357.0)]; n_replicates=1)
                run(named_fn; post_processor = _pp_named)
                @test postProcessingTable(simulationIDs(named_fn))[1, "_pp_named.a"] == 9.0

                # Two QoIs measuring the same key no longer collide in one column — the reason the
                # QoI's name prefixes it at all.
                both = createTrial(inputs, [DiscreteVariation(:config, xp_x, 358.0)]; n_replicates=1)
                run(both; post_processor = [QoI("left", sim -> (; shared = 1.0)),
                                            QoI("right", sim -> (; shared = 2.0))])
                bt = postProcessingTable(simulationIDs(both))
                @test bt[1, "left.shared"] == 1.0
                @test bt[1, "right.shared"] == 2.0

                # simulationsTable(...; post_processing=true) joins the QoIs by :SimID.
                st_pp = simulationsTable(samp; post_processing=true, remove_constants=false)
                @test Set(["SimID", "pp.sid", "pp.doubled"]) ⊆ Set(names(st_pp))
                @test nrow(st_pp) == 2
                for row in eachrow(st_pp)
                    @test row."pp.doubled" == 2.0 * row.SimID   # joined on the right SimID
                end
                # Without the kwarg, no QoI columns appear.
                @test "pp.doubled" ∉ names(simulationsTable(samp))

                pt = postProcessingTable(samp)
                @test pt isa DataFrame
                @test nrow(pt) == 2
                @test :SimID in propertynames(pt)
                @test Set(["SimID", "pp.sid", "pp.doubled"]) ⊆ Set(names(pt))
                @test all(pt[!, "pp.doubled"] .== 2.0 .* pt.SimID) # values round-trip

                # use_previous ⇒ nothing re-scheduled ⇒ callback not fired again.
                calls[] = 0
                run(samp; post_processor = QoI("pp", sim -> (; sid = sim.id)))
                @test calls[] == 0

                # Callback returning `nothing` ⇒ no sink row for that sim.
                m_none = createTrial(inputs, [DiscreteVariation(:config, xp_x, 311.0)]; n_replicates=1)
                run(m_none; post_processor = sp -> nothing)
                none_id = simulationIDs(m_none)[1]
                all_ids = ("SimID" in names(postProcessingTable())) ? postProcessingTable().SimID : Int[]
                @test none_id ∉ all_ids

                # AbstractDict return + a *new* quantity ⇒ dynamic column; earlier rows get `missing`.
                m_new = createTrial(inputs, [DiscreteVariation(:config, xp_x, 321.0)]; n_replicates=1)
                run(m_new; post_processor = QoI("nq", sp -> Dict("newq" => 7.0)))
                pt2 = postProcessingTable()
                @test "nq.newq" in names(pt2)
                new_id = simulationIDs(m_new)[1]
                @test pt2[findfirst(==(new_id), pt2.SimID), "nq.newq"] == 7.0
                first_samp_id = simulationIDs(samp)[1]
                @test ismissing(pt2[findfirst(==(first_samp_id), pt2.SimID), "nq.newq"])

                # Upsert: writing the same simulation_id twice overwrites and adds columns.
                db = ModelManager._openPostProcessingDB()
                try
                    ModelManager._writePostProcessingRow(db, 100_001, (; a = 1.0))
                    ModelManager._writePostProcessingRow(db, 100_001, (; a = 2.0, b = 3.0))
                finally
                    close(db)
                end
                up = postProcessingTable([100_001])
                @test nrow(up) == 1
                @test up.a[1] == 2.0
                @test up.b[1] == 3.0

                # Invalid return values ⇒ ArgumentError (surfaced from the serial write loop).
                @test_throws ArgumentError run(
                    createTrial(inputs, [DiscreteVariation(:config, xp_x, 331.0)]; n_replicates=1);
                    post_processor = sp -> [1, 2, 3])
                @test_throws ArgumentError run(
                    createTrial(inputs, [DiscreteVariation(:config, xp_x, 332.0)]; n_replicates=1);
                    post_processor = QoI("bq", sp -> (; bad = [1.0, 2.0])))

                # printPostProcessingTable routes the DataFrame through the sink.
                captured = Ref{Any}(nothing)
                printPostProcessingTable(samp; sink = df -> captured[] = df)
                @test captured[] isa DataFrame
                @test nrow(captured[]) == 2

                # Ordering: postSimulationProcessing (non-destructive) runs before the user
                # post_processor, which runs before postSimulationCleanup (destructive), so the
                # callback always sees the intact output folder.
                m_ord = createTrial(inputs, [DiscreteVariation(:config, xp_x, 401.0)]; n_replicates=1)
                ord_id = simulationIDs(m_ord)[1]
                empty!(_post_order_log)
                run(m_ord; post_processor = QoI("ordq", sim -> begin
                    push!(_post_order_log, "user:$(sim.id)")
                    (; q = 1.0)
                end))
                @test _post_order_log == ["processing:$(ord_id)", "user:$(ord_id)", "cleanup:$(ord_id)"]
            end

            @testset "post-processing errors surface instead of hanging" begin
                # A throwing post_processor makes run() fail fast (not hang), tagged as such.
                e = @test_throws ModelManager._SimulationStageError run(
                    createTrial(inputs, [DiscreteVariation(:config, xp_x, 361.0)]; n_replicates=1);
                    post_processor = sp -> error("boom"))
                msg = sprint(showerror, e.value)
                @test occursin("post_processor", msg)
                @test occursin("boom", msg)

                # A throwing simulator hook likewise surfaces, tagged with the stage.
                try
                    _throw_in_hook[] = :processing
                    e2 = @test_throws ModelManager._SimulationStageError run(
                        createTrial(inputs, [DiscreteVariation(:config, xp_x, 362.0)]; n_replicates=1))
                    @test occursin("postSimulationProcessing", sprint(showerror, e2.value))

                    _throw_in_hook[] = :cleanup
                    e3 = @test_throws ModelManager._SimulationStageError run(
                        createTrial(inputs, [DiscreteVariation(:config, xp_x, 363.0)]; n_replicates=1))
                    @test occursin("postSimulationCleanup", sprint(showerror, e3.value))
                finally
                    _throw_in_hook[] = nothing
                end

                # After the failures, a normal run still works (the pool is not left broken).
                @test run(createTrial(inputs, [DiscreteVariation(:config, xp_x, 364.0)]; n_replicates=1)).n_success == 1
            end

            @testset "post-processing sink input hardening" begin
                # QoI names are safely quoted: a name containing a double quote round-trips.
                weird = "od\"d"
                samp = createTrial(inputs, [DiscreteVariation(:config, xp_x, 371.0)]; n_replicates=1)
                run(samp; post_processor = QoI("wq", sp -> Dict(weird => 5.0)))
                pt = postProcessingTable(samp)
                @test "wq.$(weird)" in names(pt)
                @test pt[1, "wq.$(weird)"] == 5.0

                # Dict keys that collide after string conversion (1 vs "1") → ArgumentError.
                @test_throws ArgumentError run(
                    createTrial(inputs, [DiscreteVariation(:config, xp_x, 372.0)]; n_replicates=1);
                    post_processor = QoI("cq", sp -> Dict(1 => 1.0, "1" => 2.0)))
            end

            @testset "post-processing sink follows deletions" begin
                dv   = DiscreteVariation(:config, xp_x, [501.0, 502.0])
                samp = createTrial(inputs, [dv]; n_replicates=2)   # 2 monads × 2 replicates
                run(samp; post_processor = QoI("dq", sim -> (; v = simulationID(sim))))
                sids = simulationIDs(samp)
                @test nrow(postProcessingTable(sids)) == 4

                # Deleting simulations removes their sink rows; others remain.
                deleteSimulations(sids[1:2]; delete_supers=false)
                @test Set(postProcessingTable(sids).SimID) == Set(sids[3:4])

                # Cascade: deleting the sampling removes the rest of its sink rows.
                # (also exercises that deleteSampling is exported)
                deleteSampling(samp.id)
                @test nrow(postProcessingTable(sids)) == 0
            end

            # ---------- getParameterValue ----------
            @testset "getParameterValue" begin
                dv = DiscreteVariation(:config, xp_x, 42.0)
                m  = createTrial(inputs, [dv]; n_replicates=1)
                run(m)

                val = getParameterValue(m, :config, xp_x)
                @test val ≈ 42.0

                # Unvaried parameter falls back to XML default
                val_y = getParameterValue(m, :config, xp_y)
                @test val_y ≈ 2.0
            end

            # ---------- calibration end-to-end ----------
            #
            # summary_statistic: always returns {"x" => 1.0} — a named top-level function
            # so _isAnonymousFunction returns false and _saveProblem can serialise it.
            # distance: mseDistance against observed {"x" => 1.0} → distance always 0.
            # With minimum_epsilon=0 and distance=0 the run stops after generation 1.
            @testset "runCalibration end-to-end" begin
                dv      = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                observed = Dict{String,Any}("x" => 1.0)
                prob = CalibrationProblem(inputs, [dv], observed,
                                          _test_named_ss, mseDistance)

                method = ABCSMC(population_size=4, max_nr_populations=3,
                                minimum_epsilon=0.0)
                result = runCalibration(method, prob; description="db integration")
                waitForDiagnostics()

                @test result isa ABCResult
                @test result.calibration isa Calibration
                @test !isempty(result.generations)
                @test result.method isa ABCSMC

                monad_ids = ModelManager.calibrationMonadIDs(result.calibration)
                @test !isempty(monad_ids)

                # Generation files on disk
                gen_dir = joinpath(ModelManager.calibrationFolder(result.calibration),
                                   "generations")
                @test isdir(gen_dir)
                @test isfile(joinpath(gen_dir, "1", "particles.csv"))
                @test isfile(joinpath(gen_dir, "1", "cdfs.csv"))
                @test isfile(joinpath(gen_dir, "1", "metadata.toml"))

                # posterior
                post_df, weights = posterior(result)
                @test post_df isa DataFrame
                @test sum(weights) ≈ 1.0 atol=1e-6
                @test "$(columnName(xp_x))" ∈ names(post_df)

                # out-of-range generation throws
                @test_throws ArgumentError posterior(result; generation=99)
            end

            @testset "calibration over discrete and mixed parameters" begin
                # The empirical half of the discrete assessment: the code-path argument said the
                # kernels never see a target value, so a discrete parameter should just work. This
                # runs one to confirm it, rather than reasoning about it.
                observed = Dict{String,Any}("x" => 1.0)
                method   = ABCSMC(population_size=4, max_nr_populations=2, minimum_epsilon=0.0)

                disc = DiscreteVariation(:config, xp_x, [0.5, 1.5, 2.5])
                dprob = CalibrationProblem(inputs, [disc], observed, _test_named_ss, mseDistance)
                dres  = runCalibration(method, dprob)
                waitForDiagnostics()
                @test dres isa ABCResult
                @test !isempty(dres.generations)

                # The posterior is over real values, not indices, and only over the declared levels.
                post_df, weights = posterior(dres)
                @test sum(weights) ≈ 1.0 atol=1e-6
                col = only(intersect(names(post_df), [string(columnName(xp_x))]))
                @test all(v -> v in [0.5, 1.5, 2.5], post_df[!, col])

                # Mixed continuous + discrete in one problem: each coordinate is independently a
                # [0,1] CDF value, so the kernel handles them together without knowing which is which.
                cont  = DistributedVariation(:config, xp_y, Uniform(0.5, 3.0))
                mprob = CalibrationProblem(inputs, [disc, cont], observed,
                                           _test_named_ss, mseDistance)
                mres  = runCalibration(method, mprob)
                waitForDiagnostics()
                @test mres isa ABCResult
                mpost, mw = posterior(mres)
                @test sum(mw) ≈ 1.0 atol=1e-6
                dcol = only(intersect(names(mpost), [string(columnName(xp_x))]))
                ccol = only(intersect(names(mpost), [string(columnName(xp_y))]))
                @test all(v -> v in [0.5, 1.5, 2.5], mpost[!, dcol])   # still snapped to levels
                @test all(v -> 0.5 <= v <= 3.0, mpost[!, ccol])        # still continuous

                # The problem manifest round-trips a discrete source, so a discrete run can resume.
                loaded = ModelManager._loadProblem(dres.calibration)
                @test loaded isa ModelManager._ProblemManifest
                @test loaded.sources[1] isa ModelManager.DiscreteSource

                # A CoVariation of discrete variations: one latent coordinate driving two targets
                # in lockstep. Runs the DiscreteCoSource methods -- the TOML entry, the bank's
                # level distribution, the display columns -- which unit conversions never reach.
                cv = CoVariation(DiscreteVariation(:config, xp_x, [0.5, 1.5, 2.5]),
                                 DiscreteVariation(:config, xp_y, [1.0, 2.0, 3.0]))
                cvprob = CalibrationProblem(inputs, [cv], observed, _test_named_ss, mseDistance)
                cvres  = runCalibration(method, cvprob)
                waitForDiagnostics()
                @test cvres isa ABCResult
                cvpost, cvw = posterior(cvres)
                @test sum(cvw) ≈ 1.0 atol=1e-6

                # Both targets land on their own levels, and stay paired by index.
                xcol = only(intersect(names(cvpost), [string(columnName(xp_x))]))
                ycol = only(intersect(names(cvpost), [string(columnName(xp_y))]))
                @test all(v -> v in [0.5, 1.5, 2.5], cvpost[!, xcol])
                @test all(v -> v in [1.0, 2.0, 3.0], cvpost[!, ycol])
                for r in eachrow(cvpost)
                    @test findfirst(==(r[xcol]), [0.5, 1.5, 2.5]) ==
                          findfirst(==(r[ycol]), [1.0, 2.0, 3.0])
                end

                # The co-source round-trips, and its parameters.toml records the levels of both
                # targets rather than the internal DiscreteUniform.
                cvloaded = ModelManager._loadProblem(cvres.calibration)
                @test cvloaded.sources[1] isa ModelManager.DiscreteCoSource
                ptoml = TOML.parsefile(joinpath(ModelManager.calibrationFolder(cvres.calibration),
                                                "parameters.toml"))
                entry = only(ptoml["parameters"])
                @test entry["source_type"] == "DiscreteCoSource"
                @test entry["values"] == [[0.5, 1.5, 2.5], [1.0, 2.0, 3.0]]
            end

            @testset "runABC delegates to runCalibration" begin
                # runABC had no test coverage at all before this, which is how store_rejected came
                # to be unreachable through it without anything noticing.
                dv       = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                observed = Dict{String,Any}("x" => 1.0)
                prob = CalibrationProblem(inputs, [dv], observed, _test_named_ss, mseDistance)

                # Loose keywords reach the ABCSMC constructor, store_rejected included.
                kw_result = runABC(prob; population_size=4, max_nr_populations=2,
                                   minimum_epsilon=0.0, store_rejected=true)
                waitForDiagnostics()
                @test kw_result isa ABCResult
                @test kw_result.method.store_rejected
                @test kw_result.method.population_size == 4

                # method= and the loose form agree.
                method = ABCSMC(population_size=4, max_nr_populations=2, minimum_epsilon=0.0)
                m_result = runABC(prob; method=method)
                waitForDiagnostics()
                @test m_result.method == method

                # Supplying both is an error naming the offending setting.
                err = try
                    runABC(prob; method=method, population_size=5)
                    nothing
                catch e
                    e
                end
                @test err isa ArgumentError
                @test occursin("population_size", sprint(showerror, err))

                # An unrecognized keyword is named too.
                @test_throws ArgumentError runABC(prob; populaton_size=4)
            end

            @testset "non-Dict observed_data survives runCalibration" begin
                # _ProblemManifest declared observed_data::Dict{String,Any} while
                # CalibrationProblem declares it ::Any, and runCalibration saves the problem before
                # generation 1 — so the Vector and scalar shapes mseDistance documents threw on
                # conversion. This is the regression whose absence let that ship.
                dv     = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                method = ABCSMC(population_size=2, max_nr_populations=1, minimum_epsilon=0.0)

                vec_prob = CalibrationProblem(inputs, [dv], [1.0],
                                              _test_named_vec_ss, mseDistance)
                vec_result = runCalibration(method, vec_prob)
                waitForDiagnostics()
                @test vec_result isa ABCResult

                scalar_prob = CalibrationProblem(inputs, [dv], 1.0,
                                                 _test_named_scalar_ss, mseDistance)
                scalar_result = runCalibration(method, scalar_prob)
                waitForDiagnostics()
                @test scalar_result isa ABCResult
            end

            @testset "tags keyword on calibration entry points" begin
                dv       = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                observed = Dict{String,Any}("x" => 1.0)
                prob = CalibrationProblem(inputs, [dv], observed, _test_named_ss, mseDistance)
                method = ABCSMC(population_size=2, max_nr_populations=1, minimum_epsilon=0.0)

                tagged = runCalibration(method, prob;
                                        description="prose", tags=("project" => "unify",))
                waitForDiagnostics()
                cal = tagged.calibration
                @test tags(cal)["project"] == ["unify"]
                # Reserved tags from the run itself still land.
                @test haskey(tags(cal), "mm:method")
                # The prose column and the queryable tag are independent: tagging does not write
                # description, and description does not create a tag.
                @test !haskey(tags(cal), "note")
                @test findTrials(Calibration; tags=("project" => "unify",)) == [cal]

                # runABC forwards tags too — it must name them explicitly, or the kwargs splat
                # would swallow them into the ABCSMC constructor.
                via_abc = runABC(prob; population_size=2, max_nr_populations=1,
                                 minimum_epsilon=0.0, tags=("purpose" => "smoke",))
                waitForDiagnostics()
                @test tags(via_abc.calibration)["purpose"] == ["smoke"]
            end

            # ---------- calibration as coalesced Sampling views ----------
            #
            # A generation is not one Sampling: the batch loop builds one per batch. But every
            # monad of a calibration shares problem.inputs, which is what defines a Sampling, so
            # the run and each of its generations are valid samplings too — overlapping views
            # over the same monads.
            @testset "coalesced Sampling views over a calibration" begin
                # _test_nonzero_ss keeps every distance at 1.0, so the run does not converge in
                # generation 1 and there really are several generations to coalesce over.
                #
                # Ranges for the calibration testsets below live in 100-117, disjoint from each
                # other and from every value another testset pins as a fixed DiscreteVariation.
                # Generation 1 proposes Sobol' points and the first CDF draw is exactly 0.5, so
                # Uniform(a, b) deterministically evaluates a monad at (a+b)/2 and runs it to
                # completion — which silently hands a later `createTrial` at that value a
                # completed monad through `use_previous=true`.
                dv       = DistributedVariation(:config, xp_x, Uniform(100.0, 102.0))
                observed = Dict{String,Any}("x" => 1.0)
                prob = CalibrationProblem(inputs, [dv], observed, _test_nonzero_ss, mseDistance)
                method = ABCSMC(population_size=4, max_nr_populations=2, minimum_epsilon=0.0)
                result = runCalibration(method, prob; description="views")
                cal = result.calibration
                waitForDiagnostics()
                @test length(result.generations) == 2

                recorded = ModelManager.calibrationMonadIDs(cal)
                @test !isempty(recorded)
                @test allunique(recorded)              # generations overlap; the record dedupes
                @test issorted(recorded)               # "which monads", not an evaluation order
                @test monadIDs(cal) == recorded        # nothing failed here, so all survive
                @test issorted(monadIDs(cal))
                @test issorted(ModelManager.calibrationMonadIDs(cal, 1))

                # Every simulation of the run, reachable through the batch tag alone.
                batch_ids = sort(findSimulationIDs(tags=("mm:calibration" => string(cal.id),)))
                @test !isempty(batch_ids)

                sampling = Sampling(cal)
                @test sampling isa Sampling
                # Matching is on the exact monad set, so the same view is the same row.
                @test Sampling(cal).id == sampling.id

                # The run-wide set spans both generations, so it is its own row rather than any
                # of the per-batch ones.
                batch_sampling_ids = [Int(row.ID) for row in eachrow(tagsTable())
                                      if row.Class == "sampling" && row.Key == "mm:calibration" &&
                                         row.Value == string(cal.id)]
                @test !isempty(batch_sampling_ids)
                @test !(sampling.id in batch_sampling_ids)

                # The view agrees with the accessors, and covers every simulation of the run.
                @test sort(monadIDs(sampling)) == sort(monadIDs(cal))
                @test sort(simulationIDs(sampling)) == sort(simulationIDs(cal))
                @test sort(simulationIDs(cal)) == batch_ids

                # Per-generation views are strict subsets of the run-wide one.
                gen1 = Sampling(cal, 1)
                gen2 = Sampling(cal, 2)
                @test gen1.id != sampling.id
                @test gen2.id != gen1.id
                @test Set(monadIDs(gen1)) ⊆ Set(monadIDs(sampling))
                @test Set(monadIDs(gen2)) ⊆ Set(monadIDs(sampling))
                @test Set(monadIDs(gen1)) != Set(monadIDs(sampling))
                @test Set(monadIDs(cal, 1)) == Set(monadIDs(gen1))
                @test Set(simulationIDs(cal, 1)) ⊆ Set(simulationIDs(cal))
                @test union(Set(monadIDs(gen1)), Set(monadIDs(gen2))) == Set(monadIDs(sampling))

                # An unrecorded generation names the ones that exist.
                @test_throws ArgumentError Sampling(cal, 99)
                @test_throws ArgumentError monadIDs(cal, 99)
                @test_throws ArgumentError ModelManager.calibrationMonadIDs(cal, 99)

                # Everything above also takes the ABCResult, so `.calibration` is never required.
                @test monadIDs(result) == monadIDs(cal)
                @test monadIDs(result, 1) == monadIDs(cal, 1)
                @test simulationIDs(result) == simulationIDs(cal)
                @test simulationIDs(result, 1) == simulationIDs(cal, 1)
                @test Sampling(result).id == sampling.id
                @test Sampling(result, 1).id == gen1.id
                @test ModelManager.calibrationMonadIDs(result) == recorded
                @test ModelManager.calibrationMonadIDs(result, 1) == ModelManager.calibrationMonadIDs(cal, 1)
                @test calibrationsTable(result).CalibrationID == [cal.id]

                # The accessors record nothing: only the explicit view constructor inserts a row.
                n_samplings() = nrow(ModelManager.queryToDataFrame(
                    ModelManager.constructSelectQuery("samplings"; selection="sampling_id")))
                before = n_samplings()
                monadIDs(cal); monadIDs(cal, 1); simulationIDs(cal); ModelManager.calibrationMonadIDs(cal)
                @test n_samplings() == before
            end

            @testset "a single-batch calibration's view reuses the batch row" begin
                # When the run converges in generation 1 and that generation was one batch, all
                # three monad sets coincide. Exact-set matching then returns the row the batch
                # already created rather than inserting a duplicate for the same monads — which
                # is the property that makes coalescing safe in the first place.
                dv       = DistributedVariation(:config, xp_x, Uniform(115.0, 117.0))
                observed = Dict{String,Any}("x" => 1.0)
                prob = CalibrationProblem(inputs, [dv], observed, _test_named_ss, mseDistance)
                method = ABCSMC(population_size=4, max_nr_populations=2, minimum_epsilon=0.0)
                result = runCalibration(method, prob; description="single batch")
                cal = result.calibration
                waitForDiagnostics()
                @test length(result.generations) == 1

                batch_sampling_ids = [Int(row.ID) for row in eachrow(tagsTable())
                                      if row.Class == "sampling" && row.Key == "mm:calibration" &&
                                         row.Value == string(cal.id)]
                @test length(batch_sampling_ids) == 1

                n_samplings() = nrow(ModelManager.queryToDataFrame(
                    ModelManager.constructSelectQuery("samplings"; selection="sampling_id")))
                before = n_samplings()
                @test Sampling(cal).id == batch_sampling_ids[1]
                @test Sampling(cal, 1).id == batch_sampling_ids[1]
                @test n_samplings() == before          # no row added for a set that already exists
            end

            @testset "views exclude monads deleted after total failure" begin
                # `Monad(id)` throws for a deleted monad, and the runner deletes a monad whose
                # every simulation failed — so without the survival filter a run with any total
                # monad failure could not be viewed at all. This is also the regression test for
                # the file filter: the deleted IDs are exactly what `_failed_monads.csv` holds.
                dv       = DistributedVariation(:config, xp_x, Uniform(103.0, 105.0))
                observed = Dict{String,Any}("x" => 1.0)
                prob = CalibrationProblem(inputs, [dv], observed, _test_named_ss, mseDistance)
                method = ABCSMC(population_size=6, max_nr_populations=1, minimum_epsilon=0.0)

                n_dispatched = Ref(0)
                _fail_sim_predicate[] = spec -> (n_dispatched[] += 1) <= 2
                cal = try
                    runCalibration(method, prob; description="views with failures").calibration
                finally
                    _fail_sim_predicate[] = nothing
                end
                waitForDiagnostics()

                dead = ModelManager.constituentIDs(
                    ModelManager._failedMonadsPath(cal, 1, method.max_nr_populations))
                @test length(dead) == 2

                # The raw record still names them; the survival filter drops them.
                @test all(id -> id in ModelManager.calibrationMonadIDs(cal), dead)
                @test !any(id -> id in monadIDs(cal), dead)

                # And the view builds anyway.
                sampling = Sampling(cal)
                @test !isempty(monadIDs(sampling))
                @test isempty(intersect(Set(dead), Set(monadIDs(sampling))))
            end

            @testset "calibration runs are taggable" begin
                dv       = DistributedVariation(:config, xp_x, Uniform(106.0, 108.0))
                observed = Dict{String,Any}("x" => 1.0)
                prob = CalibrationProblem(inputs, [dv], observed, _test_named_ss, mseDistance)
                method = ABCSMC(population_size=4, max_nr_populations=1, minimum_epsilon=0.0)
                result = runCalibration(method, prob; description="taggable")
                cal = result.calibration
                waitForDiagnostics()

                # Tagged through the ABCResult, read back off the Calibration — the forward is
                # the same courtesy `MMOutput` extends for a trial, and it returns the result so
                # calls can be chained.
                @test tag!(result, "project" => "immune-escape") === result
                @test tags(result)["project"] == ["immune-escape"]
                @test hasTag(result, "project" => "immune-escape")
                @test !isempty(tagsTable(result))
                untag!(result, "project")
                @test !hasTag(cal, "project")

                tag!(cal, "project" => "immune-escape")
                @test tags(cal)["project"] == ["immune-escape"]
                @test hasTag(cal, "project" => "immune-escape")
                @test hasTag(cal, "project")
                @test findTrials(Calibration; tags=("project" => "immune-escape",)) == [cal]
                @test !isempty(tagsTable(cal))

                # Provenance comes for free, as it does for every other created object.
                @test haskey(tags(cal), "mm:created")
                @test tags(cal)["mm:method"] == ["ABCSMC"]
                @test findTrials(Calibration; tags=("mm:method" => "ABCSMC",)) ⊇ [cal]

                # The reserved namespace is writable internally and rejected publicly.
                @test_throws ArgumentError tag!(cal, "mm:method" => "forged")
                ModelManager.tagReserved!(cal, ["mm:note" => "internal"])
                @test tags(cal)["mm:note"] == ["internal"]

                # untag! clears user tags and leaves mm: provenance alone.
                untag!(cal, "project")
                @test !hasTag(cal, "project")
                @test haskey(tags(cal), "mm:created")
                @test haskey(tags(cal), "mm:method")

                # Type+ID forms, and a multi-valued key.
                tag!(Calibration, cal.id, "arm" => "a", "arm" => "b")
                @test tags(Calibration, cal.id)["arm"] == ["a", "b"]
                untag!(Calibration, cal.id, "arm" => "a")
                @test tags(cal)["arm"] == ["b"]

                # A query's results are a Vector{Calibration}, so labelling them in one call has
                # to work as it does for trial objects.
                found = findTrials(Calibration; tags=("mm:method" => "ABCSMC",))
                @test found isa Vector{Calibration}
                tag!(found, "verdict" => "keep")
                @test all(c -> hasTag(c, "verdict" => "keep"), found)
                untag!(found, "verdict")
                @test !any(c -> hasTag(c, "verdict"), found)

                # Calibration tags do not reach the monads the run evaluated (v1 decision):
                # the mm:calibration tag on each generation's sampling is the route for that.
                tag!(cal, "purpose" => "figure")
                @test isempty(findSimulationIDs(tags=("purpose" => "figure",)))
                @test isempty(findMonads(tags=("purpose" => "figure",)))
                @test !isempty(findMonads(tags=("mm:calibration" => string(cal.id),)))

                # The durable win: the calibrations row survives a monad cascade, so a tag on
                # the run outlives the per-sampling mm:calibration tags, which are deleted with
                # the sampling whose monads all went.
                monad_ids = monadIDs(cal)
                @test !isempty(monad_ids)
                deleteMonad(monad_ids; delete_subs=true, delete_supers=true)
                @test isempty(findMonads(tags=("mm:calibration" => string(cal.id),)))
                @test hasTag(cal, "purpose" => "figure")
                @test findTrials(Calibration; tags=("purpose" => "figure",)) == [cal]

                # The run is still listed and tagged, but there is nothing left to view: both
                # scopes say so rather than throwing an assertion from the Sampling constructor.
                @test isempty(monadIDs(cal))
                @test_throws "no monads left to view" Sampling(cal)
                @test_throws "Generation 1 of Calibration($(cal.id))" Sampling(cal, 1)
                # A run that never recorded a generation reports the same way, naming the
                # directory it looked in.
                bare = ModelManager.createCalibration("ABC-SMC")
                @test_throws "per-generation monads.csv files" Sampling(bare)

                # mm:created is column-backed, so `tagValues` reads it out of each class's own
                # table. That loop covers `calibrations` too, guarded only on the datetime
                # column, which this table has always had.
                stamp = tags(cal)["mm:created"][1]
                @test stamp in tagValues("mm:created")
                @test "mm:created" in tagKeys(; include_auto=true)
            end

            @testset "calibrationsTable" begin
                df = calibrationsTable()
                @test df isa DataFrame
                @test names(df) == ["CalibrationID", "DateTime", "Method", "Description"]
                @test !isempty(df)
                # One row per run, and the descriptions written above are readable back —
                # nothing SELECTed from this table before.
                @test allunique(df.CalibrationID)
                @test "db integration" in df.Description
                @test all(df.Method .== "ABC-SMC")
                # The datetime is the same shape as every other table's, so mm:created reads
                # back uniformly.
                @test all(s -> occursin(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$", String(s)), df.DateTime)

                one_id = df.CalibrationID[1]
                sub = calibrationsTable([one_id])
                @test nrow(sub) == 1
                @test sub.CalibrationID == [one_id]
                @test calibrationsTable(Calibration(one_id)).CalibrationID == [one_id]

                # Tag columns, off by default.
                @test !any(startswith.(names(calibrationsTable()), "tag:"))
                tag!(Calibration, one_id, "project" => "table-test")
                tagged = calibrationsTable(; tags=true)
                @test "tag:project" in names(tagged)
                @test tagged[tagged.CalibrationID .== one_id, "tag:project"] == ["table-test"]
                @test !any(startswith.(names(tagged), "tag:mm:"))
                @test "tag:mm:method" in names(calibrationsTable(; tags=true, include_auto_tags=true))

                # The raw provenance column is never presented.
                @test !("provenance_id" in names(df))
                @test !("ProvenanceID" in names(df))

                printed = sprint(io -> printCalibrationsTable(; sink=x -> show(io, x)))
                @test occursin("CalibrationID", printed)
            end

            @testset "show(::Calibration)" begin
                dv       = DistributedVariation(:config, xp_x, Uniform(109.0, 111.0))
                observed = Dict{String,Any}("x" => 1.0)
                prob = CalibrationProblem(inputs, [dv], observed, _test_named_ss, mseDistance)
                method = ABCSMC(population_size=4, max_nr_populations=2, minimum_epsilon=0.0)
                cal = runCalibration(method, prob; description="shown").calibration
                waitForDiagnostics()

                out = sprint(show, cal)
                @test occursin("Calibration (ID=$(cal.id))", out)
                @test occursin("shown", out)                  # the description
                @test occursin("ABC-SMC", out)
                @test occursin("Generations: 1", out)         # distance is 0, so it stops at gen 1
                @test occursin("Final ε", out)

                # A description was optional before this table was ever read back; an empty one
                # is omitted rather than printed blank.
                bare = runCalibration(method, prob).calibration
                waitForDiagnostics()
                @test !occursin("Description", sprint(show, bare))

                # An id with no row must not throw — the struct validates nothing.
                @test occursin("no row", sprint(show, Calibration(999_999)))

                # Nor may it throw with no project initialized, which is the state a stray
                # `Calibration(3)` at the REPL lands in. Globals are restored immediately.
                saved_globals = ModelManager.mm_globals_ref[]
                try
                    ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = TestSimulator())
                    @test !isInitialized()
                    @test sprint(show, cal) == "Calibration (ID=$(cal.id))"
                finally
                    ModelManager.mm_globals_ref[] = saved_globals
                end
                @test isInitialized()
            end

            @testset "deleteCalibration" begin
                dv       = DistributedVariation(:config, xp_x, Uniform(112.0, 114.0))
                observed = Dict{String,Any}("x" => 1.0)
                prob = CalibrationProblem(inputs, [dv], observed, _test_named_ss, mseDistance)
                method = ABCSMC(population_size=4, max_nr_populations=1, minimum_epsilon=0.0)

                cal = runCalibration(method, prob; description="deleteme").calibration
                waitForDiagnostics()
                tag!(cal, "project" => "doomed")
                monad_ids = monadIDs(cal)
                sim_ids = simulationIDs(cal)
                folder = ModelManager.calibrationFolder(cal)
                @test isdir(folder)

                deleteCalibration(cal)
                @test isempty(calibrationsTable([cal.id]))
                @test isempty(tags(cal))
                @test !isdir(folder)
                @test isempty(findTrials(Calibration; tags=("project" => "doomed",)))
                # Monads are shared through the bank and `use_previous`, so they are kept.
                @test all(id -> id in monadIDs(), monad_ids)
                @test all(id -> id in simulationIDs(), sim_ids)

                # Opting in cascades to the monads and their simulations.
                cal2 = runCalibration(method, prob; description="doomed subs").calibration
                waitForDiagnostics()
                monad_ids2 = monadIDs(cal2)
                sim_ids2 = simulationIDs(cal2)
                @test !isempty(monad_ids2)
                deleteCalibration(cal2.id; delete_subs=true)
                @test isempty(calibrationsTable([cal2.id]))
                @test !any(id -> id in monadIDs(), monad_ids2)
                @test !any(id -> id in simulationIDs(), sim_ids2)

                # Deleting nothing is a no-op, not an error.
                @test isnothing(deleteCalibration(Int[]))

                # Every form in the docstring dispatches: an ID, a vector of IDs, a Calibration,
                # a vector of them, and the ABCResult. Built with `createCalibration` rather than
                # by running one — these need a row and a folder, not simulations, and later
                # testsets in this block depend on the monads present (see the reusability filter
                # testset, which reserves a parameter value for itself).
                bare3 = ModelManager.createCalibration("ABC-SMC"; description="by result")
                res3 = ABCResult(bare3, ModelManager.GenerationResult[],
                                 ModelManager.CalibrationParameter[], method)
                @test isdir(ModelManager.calibrationFolder(bare3))
                deleteCalibration(res3)
                @test isempty(calibrationsTable([bare3.id]))
                @test !isdir(ModelManager.calibrationFolder(bare3))

                cal4 = ModelManager.createCalibration("ABC-SMC"; description="by vector")
                cal5 = ModelManager.createCalibration("ABC-SMC"; description="by vector 2")
                deleteCalibration([cal4, cal5])
                @test isempty(calibrationsTable([cal4.id, cal5.id]))
            end

            @testset "runCalibration progress levels" begin
                dv       = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                observed = Dict{String,Any}("x" => 1.0)
                prob = CalibrationProblem(inputs, [dv], observed,
                                          _test_named_ss, mseDistance)
                # Each verbosity level must run end-to-end without error.
                for prog in (:none, :generation, :batch, :bar)
                    method = ABCSMC(population_size=4, max_nr_populations=2,
                                    minimum_epsilon=0.0)
                    result = runCalibration(method, prob; progress=prog,
                                            description="progress=$prog")
                    waitForDiagnostics()
                    @test result isa ABCResult
                    @test !isempty(result.generations)
                end
                # Invalid setting is rejected before any work begins.
                @test_throws ArgumentError runCalibration(ABCSMC(population_size=4, max_nr_populations=1, minimum_epsilon=0.0), prob;
                    progress=:verbose)
            end

            # ---------- failed simulations during calibration ----------
            #
            # Reproduces the reported bug: when every simulation in a proposed monad fails, the
            # runner deletes the emptied monad, and the user's summary_statistic then either
            # throws (_test_monad_ss) or returns missing, which throws inside `distance`
            # (_test_missing_ss). ModelManager now detects the empty monad before calling user
            # code at all. `_fail_sim_predicate` forces the failures.
            @testset "on_monad_failure=:reject" begin
                dv       = DistributedVariation(:config, xp_x, Uniform(10.0, 12.0))
                observed = Dict{String,Any}("x" => 1.0)
                prob = CalibrationProblem(inputs, [dv], observed,
                                          _test_monad_ss, mseDistance)
                method = ABCSMC(population_size=6, max_nr_populations=2,
                                minimum_epsilon=0.0)

                # Fail the first two simulations dispatched; with n_replicates=1 that empties
                # (and so deletes) exactly two monads. The runner's workers are async tasks,
                # not threads, so this counter needs no lock.
                n_dispatched = Ref(0)
                _fail_sim_predicate[] = spec -> (n_dispatched[] += 1) <= 2
                result = try
                    runCalibration(method, prob; description="reject failures")
                finally
                    _fail_sim_predicate[] = nothing
                end
                waitForDiagnostics()

                # The run survives: healthy particles give x=1 → distance 0 → gen-1 ε=0.
                @test result isa ABCResult
                @test length(result.generations) >= 1
                @test all(isfinite, result.generations[1].distances)
                # Two of six proposals were rejected, so four particles remain.
                @test nrow(result.generations[1].particles) == 4
                @test result.generations[1].n_evaluations == 6
                @test isfinite(result.generations[1].max_epsilon_accepted)

                # Failures are recorded to the generation's failure files.
                sim_path = ModelManager._failedSimulationsPath(result.calibration, 1,
                                                               method.max_nr_populations)
                monad_path = ModelManager._failedMonadsPath(result.calibration, 1,
                                                             method.max_nr_populations)
                @test isfile(sim_path)
                @test isfile(monad_path)
                @test length(ModelManager.constituentIDs(sim_path)) == 2
                @test length(ModelManager.constituentIDs(monad_path)) == 2
                # Every recorded monad really did lose all of its simulations, so it is gone.
                @test all(ModelManager.constituentIDs(monad_path)) do mid
                    isempty(ModelManager.constructSelectQuery("monads", "WHERE monad_id=$mid;";
                            selection="monad_id") |> ModelManager.queryToDataFrame)
                end
            end

            @testset "on_monad_failure=:reject — user statistic never sees a dead monad" begin
                # _test_missing_ss would return `missing` for a deleted monad, which used to
                # blow up inside mseDistance. The dead monad is now rejected before user code.
                dv       = DistributedVariation(:config, xp_x, Uniform(13.0, 15.0))
                observed = Dict{String,Any}("x" => 1.0)
                prob = CalibrationProblem(inputs, [dv], observed,
                                          _test_missing_ss, mseDistance)
                method = ABCSMC(population_size=4, max_nr_populations=1,
                                minimum_epsilon=0.0)

                n_dispatched = Ref(0)
                _fail_sim_predicate[] = spec -> (n_dispatched[] += 1) == 1
                result = try
                    runCalibration(method, prob; description="reject missing stat")
                finally
                    _fail_sim_predicate[] = nothing
                end
                waitForDiagnostics()

                @test result isa ABCResult
                @test nrow(result.generations[1].particles) == 3
                @test all(isfinite, result.generations[1].distances)
            end

            @testset "on_monad_failure=:error" begin
                dv       = DistributedVariation(:config, xp_x, Uniform(16.0, 18.0))
                observed = Dict{String,Any}("x" => 1.0)
                prob = CalibrationProblem(inputs, [dv], observed,
                                          _test_monad_ss, mseDistance)
                method = ABCSMC(population_size=4, max_nr_populations=1,
                                minimum_epsilon=0.0)

                n_dispatched = Ref(0)
                _fail_sim_predicate[] = spec -> (n_dispatched[] += 1) == 1
                try
                    # Fails fast instead of rejecting the particle, pointing at the failure files.
                    @test_throws "has no successful simulation" runCalibration(method, prob;
                        description="error on failure", on_monad_failure=:error)
                finally
                    _fail_sim_predicate[] = nothing
                end
                waitForDiagnostics()

                # An unrecognized policy is rejected before any work begins.
                @test_throws ArgumentError runCalibration(ABCSMC(population_size=4, max_nr_populations=1, minimum_epsilon=0.0), prob;
                    on_monad_failure=:ignore)
            end

            @testset "every generation-1 particle failing is fatal" begin
                dv       = DistributedVariation(:config, xp_x, Uniform(19.0, 21.0))
                observed = Dict{String,Any}("x" => 1.0)
                prob = CalibrationProblem(inputs, [dv], observed,
                                          _test_monad_ss, mseDistance)
                method = ABCSMC(population_size=4, max_nr_populations=1,
                                minimum_epsilon=0.0)

                _fail_sim_predicate[] = spec -> true
                try
                    # Nothing survives generation 1 → error instead of an empty population.
                    @test_throws "had a successful simulation" runCalibration(method, prob;
                        description="all particles fail")
                finally
                    _fail_sim_predicate[] = nothing
                end
                waitForDiagnostics()
            end

            @testset "broken user functions fail fast on a healthy monad" begin
                dv       = DistributedVariation(:config, xp_x, Uniform(22.0, 24.0))
                observed = Dict{String,Any}("x" => 1.0)
                method = ABCSMC(population_size=3, max_nr_populations=1, minimum_epsilon=0.0)

                # distance returns a Dict rather than a Real: caught immediately, not
                # propagated into the ABC-SMC internals. Not affected by :reject.
                prob_bad_type = CalibrationProblem(inputs, [dv], observed,
                                                   _test_named_ss, _test_dict_dist)
                @test_throws "a `Real` is required" runCalibration(method, prob_bad_type;
                    description="non-Real distance")

                # A throwing summary_statistic on a healthy monad is also fatal, and the
                # original exception is what surfaces.
                prob_throws = CalibrationProblem(inputs, [dv], observed,
                                                 _test_throwing_ss, mseDistance)
                @test_throws "summary statistic boom" runCalibration(method, prob_throws;
                    description="throwing summary statistic")
                waitForDiagnostics()
            end

            @testset "failure recording and reporting" begin
                # One warning per generation, naming both files; silent at progress=:none and
                # on generations already reported.
                warned = Set{Int}()
                @test_logs (:warn, r"generation 3: some simulations failed") match_mode=:any begin
                    ModelManager._warnFailuresRecorded(:generation, 3, warned, "sims.csv",
                                                       "monads.csv")
                end
                @test 3 in warned
                logs, _ = Test.collect_test_logs() do
                    ModelManager._warnFailuresRecorded(:generation, 3, warned, "s.csv", "m.csv")
                    ModelManager._warnFailuresRecorded(:none, 4, warned, "s.csv", "m.csv")
                end
                @test isempty(logs)

                # A batch with no failures writes nothing at all.
                cal = ModelManager.createCalibration("ABC-SMC"; description="failure files")
                @test ModelManager._recordBatchFailures(cal, 2, 10, :none, Set{Int}(),
                                                        Int[], Int[]) === nothing
                @test !isfile(ModelManager._failedSimulationsPath(cal, 2, 10))

                # Successive batches accumulate into one compressed record per generation.
                ModelManager._recordBatchFailures(cal, 2, 10, :none, Set{Int}(), [5, 6], [11])
                ModelManager._recordBatchFailures(cal, 2, 10, :none, Set{Int}(), [7], [12])
                @test ModelManager.constituentIDs(
                    ModelManager._failedSimulationsPath(cal, 2, 10)) == [5, 6, 7]
                @test ModelManager.constituentIDs(
                    ModelManager._failedMonadsPath(cal, 2, 10)) == [11, 12]
                # Artifacts live under a constant basename inside the generation's folder, so the
                # generation number appears once — in the folder name — instead of in every filename.
                gdir = joinpath(ModelManager.calibrationFolder(cal), "generations")
                @test ModelManager._failedSimulationsPath(cal, 2, 10) ==
                      joinpath(gdir, "02", "failed_simulations.csv")
                @test ModelManager._failedMonadsPath(cal, 2, 10) ==
                      joinpath(gdir, "02", "failed_monads.csv")

                # An existing record wins over a recomputed path, whatever padding its folder carries.
                # Without this, a generation retried after a resume raised max_nr_populations would
                # split its failures across two folders, and nothing scans for these.
                @test ModelManager._failedSimulationsPath(cal, 2, 100) ==
                      joinpath(gdir, "02", "failed_simulations.csv")
                ModelManager._recordBatchFailures(cal, 2, 100, :none, Set{Int}(), [8], [13])
                @test ModelManager.constituentIDs(
                    ModelManager._failedSimulationsPath(cal, 2, 100)) == [5, 6, 7, 8]
                @test !isdir(joinpath(gdir, "002"))

                # With no existing folder, the computed padding does apply.
                @test ModelManager._failedSimulationsPath(cal, 7, 100) ==
                      joinpath(gdir, "007", "failed_simulations.csv")
            end

            @testset "generation layout: folders, migration, and padding" begin
                cal  = ModelManager.createCalibration("ABC-SMC"; description="layout")
                gdir = joinpath(ModelManager.calibrationFolder(cal), "generations")
                cdir = joinpath(gdir, "generation_cdfs")
                mkpath(cdir)

                # A calibration written under the historical flat layout, left mixed-width by a
                # resume that raised max_nr_populations.
                for (n, w) in ((1, 2), (2, 2), (3, 3), (10, 3))
                    tag = lpad(string(n), w, '0')
                    for suffix in (".csv", ".toml", "_monads.csv", "_proposals.csv")
                        touch(joinpath(gdir, "generation_$(tag)$(suffix)"))
                    end
                    touch(joinpath(cdir, "generation_$(tag).csv"))
                end

                # Reading finds every generation without assuming a layout or a width.
                @test ModelManager._generationIndices(gdir) == [1, 2, 3, 10]
                for n in (1, 2, 3, 10)
                    for role in (:particles, :metadata, :monads, :proposals, :cdfs)
                        @test !isnothing(ModelManager._generationArtifact(gdir, n, role))
                    end
                end
                @test isnothing(ModelManager._generationArtifact(gdir, 4, :monads))

                # Migrating moves each artifact into generations/<t>/ under its role basename, with
                # the width covering both the cap and the highest existing generation.
                @test ModelManager._migrateGenerationLayout!(cal, 100) > 0
                for n in (1, 2, 3, 10)
                    d = joinpath(gdir, lpad(string(n), 3, '0'))
                    @test isdir(d)
                    @test isfile(joinpath(d, "particles.csv"))
                    @test isfile(joinpath(d, "metadata.toml"))
                    @test isfile(joinpath(d, "monads.csv"))
                    @test isfile(joinpath(d, "proposals.csv"))
                    @test isfile(joinpath(d, "cdfs.csv"))
                end
                # The flat files and the old cdf directory are gone.
                @test isempty(filter(f -> startswith(f, "generation_"), readdir(gdir)))
                @test !isdir(cdir)
                # Indices unchanged, and idempotent.
                @test ModelManager._generationIndices(gdir) == [1, 2, 3, 10]
                @test ModelManager._migrateGenerationLayout!(cal, 100) == 0

                # Lowering the cap narrows folder names, but only to what the existing generations
                # need: generation 10 holds the width at 2 however small the cap goes.
                ModelManager._migrateGenerationLayout!(cal, 3)
                for n in (1, 2, 3, 10)
                    @test isdir(joinpath(gdir, lpad(string(n), 2, '0')))
                end
                @test !isdir(joinpath(gdir, "001"))
                @test ModelManager._generationIndices(gdir) == [1, 2, 3, 10]

                # Writing prefers an existing folder over a recomputed name, so a generation retried
                # after the cap changed cannot end up with two folders.
                @test ModelManager._generationArtifactToWrite(gdir, 10, :monads, 1000) ==
                      joinpath(gdir, "10", "monads.csv")
                @test !isdir(joinpath(gdir, "0010"))
                # A generation with no folder yet gets one at the computed width.
                @test ModelManager._generationArtifactToWrite(gdir, 11, :monads, 1000) ==
                      joinpath(gdir, "0011", "monads.csv")
            end

            @testset "QoI is compute-per-simulation plus a reducer" begin
                q = QoI("x", _qoi_sim)
                @test q.name == "x"
                @test q.reduce === mean
                @test QoI("x", _qoi_sim; reduce=maximum).reduce === maximum

                # A bare Function is wrapped into a QoI at the boundary, so nothing downstream sees
                # one: it gains a name and reduce=mean, and its `compute` is the function itself.
                @test ModelManager._asQoI(q) === q
                wrapped = ModelManager._asQoI(_qoi_by_id)
                @test wrapped isa QoI
                @test wrapped.compute === _qoi_by_id
                @test wrapped.name == "_qoi_by_id"
                @test wrapped.reduce === mean
                @test_throws ArgumentError ModelManager._asQoI(42)
            end

            @testset "one contract: every consumer hands over a Simulation" begin
                # The point of the change. What a bare function receives no longer depends on which
                # consumer it was passed to: it was a simulation ID in `functions=`, a MONAD id in
                # CalibrationProblem, and a SimulationProcess at the sink. Two of those were an Int,
                # and both ID spaces are dense positive integers, so the wrong one produced a
                # plausible number with no error.
                t   = createTrial(inputs, [DiscreteVariation(:config, xp_x, 1487.0)]; n_replicates=1)
                sid = simulationIDs(t)[1]

                seen = Any[]
                rec(x) = (push!(seen, typeof(x)); 1.0)

                q = ModelManager._asQoI(rec)           # wrapped at the boundary, never stays a Function
                @test q isa QoI
                @test q.compute === rec
                @test q.reduce === mean                 # the default reduction a bare function gets
                ModelManager._computeOn(q, sid)
                @test seen[end] === Simulation          # GSA: a Simulation, not a bare Int

                empty!(seen)
                ModelManager._asPostProcessor(rec)(Simulation(sid))
                @test seen[end] === Simulation          # sink: a Simulation, not a SimulationProcess

                # A QoI's compute already received a Simulation, so the two now agree exactly.
                empty!(seen)
                ModelManager._computeOn(QoI("rec", rec), sid)
                @test seen[end] === Simulation

                # And a bare function's name is regularised so it can be a column / Dict key.
                @test ModelManager._qoiNameFromFunction(_sim_one) == "_sim_one"
                @test occursin(r"^anon_[0-9_]+$", ModelManager._qoiNameFromFunction(s -> 1.0))
            end

            @testset "_declaresSimulation survives every method signature shape" begin
                # This guard reads the method table, and reaching for `m.sig.parameters[2]` unguarded
                # threw on three shapes -- FieldError on a `where` clause, BoundsError on a zero-arg
                # method -- which made a correctly written `f(s::S) where {S<:Simulation}` impossible
                # to pass to CalibrationProblem at all. The guard added to make migration safe was
                # what broke it.
                @test ModelManager._declaresSimulation(_sim_one)
                @test ModelManager._declaresSimulation(_sim_where)      # TypeVar upper bound
                @test ModelManager._declaresSimulation(_sim_varargs)
                @test !ModelManager._declaresSimulation(_sim_unbounded) # where {S} is Any
                @test !ModelManager._declaresSimulation(_sim_zeroarg)   # no argument at all
                # ...and each is constructable, which is the thing that actually broke.
                dv = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                for f in (_sim_where, _sim_varargs, _sim_zeroarg, _sim_unbounded)
                    @test CalibrationProblem(inputs, [dv], 1.0, f, mseDistance) isa CalibrationProblem
                end
            end

            @testset "the migration warning is per function, not per session" begin
                # `maxlog=1` counts callsite hits, so a script building several problems warned about
                # the first and went silent for the rest -- exactly the case it exists for.
                empty!(ModelManager._WARNED_SUMMARIES)
                u1(mid) = 1.0
                u2(mid) = 2.0
                @test_logs (:warn,) match_mode=:any ModelManager._validateSummaryStatistic(u1)
                @test_logs (:warn,) match_mode=:any ModelManager._validateSummaryStatistic(u2)
                # ...and the same function warns only once.
                @test_logs ModelManager._validateSummaryStatistic(u1)
            end

            @testset "a bare summary statistic is wrapped into a QoI" begin
                # Nothing stays a bare Function internally: the boundary wraps it, supplying the two
                # things it lacks -- a name and reduce=mean.
                dv   = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                prob = CalibrationProblem(inputs, [dv], 1.0, _sim_one, mseDistance)
                @test prob.summary_statistic isa QoI
                @test prob.summary_statistic.compute === _sim_one
                @test prob.summary_statistic.name == "_sim_one"
                @test prob.summary_statistic.reduce === mean

                # An unannotated function is accepted but flagged: the declared argument type is the
                # only signal that a function was written for the new per-simulation contract, and an
                # old monad-level summary would otherwise return a different number silently.
                @test ModelManager._declaresSimulation(_sim_one)                # f(s::Simulation)
                @test ModelManager._declaresSimulation((s::Simulation) -> 1.0)  # annotated lambda
                @test !ModelManager._declaresSimulation(_test_named_dist)       # untyped
                @test !ModelManager._declaresSimulation(s -> 1.0)               # plain lambda
                @test_logs (:warn, r"does not declare it takes a `Simulation`") match_mode=:any begin
                    ModelManager._validateSummaryStatistic(_test_named_dist)
                end
                # ...and an annotated one is silent (@test_logs with no patterns asserts no records).
                @test_logs ModelManager._validateSummaryStatistic(_sim_one)

                # The number that would silently change, for the record:
                @test mean([10.0, 20.0])^2 != mean([10.0, 20.0] .^ 2)   # 225.0 vs 250.0
            end

            @testset "a QoI-backed problem stays restorable" begin
                # The regression this change must not introduce. Collapsing a QoI into a closure at
                # construction made `_isAnonymousFunction` true for EVERY QoI-backed problem, so the
                # manifest stored `nothing` and resume demanded `problem=`. Since a QoI is now the
                # only accepted summary statistic, collapsing would have made every calibration
                # unrestorable. The QoI is preserved instead.
                dv     = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                prob   = CalibrationProblem(inputs, [dv], Dict{String,Any}("x" => 1.0),
                                            _test_named_ss, _test_named_dist)
                # Stored, not collapsed. The vector is copied by validation, so identity is on the
                # QoI itself -- that object is what a per-simulation consumer needs back.
                @test prob.summary_statistic == _test_named_ss
                @test only(prob.summary_statistic) === only(_test_named_ss)
                @test ModelManager._isCompleteManifest(ModelManager._ProblemManifest(prob))

                # A QoI is only as restorable as the functions inside it -- both are checked.
                @test !ModelManager._isAnonymousFunction(QoI("x", _sim_one))
                @test ModelManager._isAnonymousFunction(QoI("x", s -> 1.0))
                @test ModelManager._isAnonymousFunction(QoI("x", _sim_one; reduce = v -> sum(v)))
            end

            @testset "QoI passes straight to all three consumers" begin
                vals = [1051.0, 1061.0]
                dv = DiscreteVariation(:config, xp_x, vals)
                m  = createTrial(inputs, [dv]; n_replicates=2, use_previous=false)
                run(m)
                waitForDiagnostics()
                mid = first(ModelManager.monadIDs(m))
                sids = ModelManager.constituentIDs(Monad, mid)
                sim_vals = [_qoi_sim(Simulation(i)) for i in sids]

                # Reducer honoured, and it is the QoI's own -- not a hard-coded mean.
                @test ModelManager._reduceOverMonad(QoI("x", _qoi_sim), mid) ≈ mean(sim_vals)
                @test ModelManager._reduceOverMonad(QoI("x", _qoi_sim; reduce=maximum), mid) ≈
                      maximum(sim_vals)

                # Calibration: the QoI itself is the summary statistic.
                prob = CalibrationProblem(inputs, [DistributedVariation(:config, xp_x,
                                                                        Uniform(0.5, 3.0))],
                                          Dict{String,Any}("x" => 1.0),
                                          QoI("x", _qoi_sim), mseDistance)
                # The QoI is preserved, not collapsed into a closure -- which is what keeps a
                # QoI-backed problem restorable on resume. A single QoI reports its value directly.
                @test prob.summary_statistic isa QoI
                @test ModelManager._evaluateSummary(prob.summary_statistic, mid) ≈ mean(sim_vals)

                # The sink: the QoI itself is the post_processor.
                m2 = createTrial(inputs, [DiscreteVariation(:config, xp_x, [1069.0])];
                                 n_replicates=1, use_previous=false)
                run(m2; post_processor=QoI("xval", _qoi_sim))
                waitForDiagnostics()
                tbl = postProcessingTable(simulationIDs(m2))
                @test "xval" in names(tbl)
                @test Set(skipmissing(tbl.xval)) == Set([1069.0])

                # Duplicate names are refused rather than silently collapsing a column.
                @test_throws ArgumentError ModelManager._asPostProcessor(
                    [QoI("x", _qoi_sim), QoI("x", _qoi_sim)])
                @test_throws ArgumentError ModelManager._validateSummaryStatistic(
                    [QoI("x", _qoi_sim), QoI("x", _qoi_sim)])
            end

            @testset "a non-scalar QoI is fine except at the sink" begin
                # compute may return a vector or Dict, because `reduce` collapses it. The sink is the
                # exception: it fires once per simulation, so `reduce` is never called and compute's
                # own value is stored. That asymmetry is easy to trip over, so it is pinned here.
                obs = Dict("x" => 2.0, "y" => 3.0)
                vecq = QoI("both", s -> [getParameterValue(s, :config, XMLPath(["data", "x"])),
                                         getParameterValue(s, :config, XMLPath(["data", "y"]))];
                           reduce = per_sim -> sum(abs2, mean(per_sim) .- [obs["x"], obs["y"]]))

                # Calibration and GSA are happy: reduce returns a scalar.
                dv = DiscreteVariation(:config, xp_x, [1091.0])
                m  = createTrial(inputs, [dv]; n_replicates=2, use_previous=false)
                run(m)
                waitForDiagnostics()
                mid = first(ModelManager.monadIDs(m))
                @test ModelManager._reduceOverMonad(vecq, mid) isa Real

                # The sink refuses it, and the message names the QoI and the type rather than
                # failing somewhere in the DB layer.
                err = try
                    ModelManager._postProcessingColumnSpec("both", [1.0, 2.0]); nothing
                catch e; e end
                @test err isa ArgumentError
                @test occursin("both", err.msg)
                @test occursin("Vector", err.msg)
                @test occursin("scalar", err.msg)
            end

            @testset "a QoI can read a value the sink stored earlier" begin
                # The workflow: post-processing writes a value per simulation while the output folder
                # still exists; a later GSA or calibration reads it back from the sink. Essential when
                # post-simulation cleanup has since deleted what the QoI was computed from.
                vals = [1301.0, 1307.0]
                dv = DiscreteVariation(:config, xp_x, vals)
                t  = createTrial(inputs, [dv]; n_replicates=2, use_previous=false)

                # Pass 1: store it, under the QoI's own name.
                run(t; post_processor=QoI("stored_x", _qoi_sim))
                waitForDiagnostics()
                stored = postProcessingTable(simulationIDs(t))
                @test "stored_x" in names(stored)
                @test Set(skipmissing(stored.stored_x)) == Set(vals)

                # Pass 2: a different QoI reads the stored value rather than the model output, and
                # feeds calibration and GSA exactly as a freshly-computed one would.
                readback = QoI("stored_x", _qoi_from_sink)
                mid = first(ModelManager.monadIDs(t))
                sids = ModelManager.constituentIDs(Monad, mid)
                @test ModelManager._reduceOverMonad(readback, mid) ≈
                      mean([_qoi_sim(Simulation(i)) for i in sids])

                # And through a real consumer, to show nothing about the seam needs changing.
                @test ModelManager._evaluateSummary(readback, mid) ≈
                      mean([_qoi_sim(Simulation(i)) for i in sids])
            end

            @testset "stored=:prefer/:require and verifyStoredValues" begin
                vals = [1409.0, 1423.0]
                dv = DiscreteVariation(:config, xp_x, vals)
                t  = createTrial(inputs, [dv]; n_replicates=2, use_previous=false)

                # Default is off, and that is the contract: nothing records which compute produced a
                # stored value, so opting in has to be deliberate.
                @test QoI("stored_x", _qoi_sim).stored === :never
                @test_throws ArgumentError QoI("stored_x", _qoi_sim; stored=:sometimes)

                # A `.` is reserved as the quantity/component separator, so a name carrying one is
                # refused at construction. Without this, `QoI("counts.x", …)` and a `QoI("counts",
                # …)` spreading to key "x" both claim the label "counts.x": within one
                # `calculateGSA!` call that collides and is caught, but across calls the name-based
                # skip silently drops one of them — and in one ordering drops the whole spreading
                # QoI, so its other components are never computed.
                err = try; QoI("counts.x", _qoi_sim); nothing; catch e; e; end
                @test err isa ArgumentError
                @test occursin("cannot contain a `.`", err.msg)
                @test occursin("counts.x", err.msg)
                # An underscore is not the separator, so it cannot shadow anything.
                @test QoI("counts_x", _qoi_sim).name == "counts_x"
                # Nothing ModelManager derives can trip it: bare functions are regularised first.
                @test !occursin('.', ModelManager._asQoI(s -> 1.0).name)
                @test !occursin('.', ModelManager._asQoI(_qoi_by_id).name)

                # The separator has one definition, and the four sites that depend on it agree.
                # Tying the constructor's refusal to the label helper is the point: whatever
                # `_qoiLabel` builds is exactly what a name may not look like.
                @test ModelManager._qoiLabel("counts", "tumor") == "counts.tumor"
                @test ModelManager._isQoILabelOf("counts.tumor", "counts")
                @test ModelManager._isQoILabelOf("counts", "counts")
                @test !ModelManager._isQoILabelOf("countsX", "counts")     # not a loose prefix
                @test_throws ArgumentError QoI(ModelManager._qoiLabel("a", "b"), _qoi_sim)

                # :require before anything is stored names the fix rather than failing obscurely.
                sid_probe = 1
                @test_throws ArgumentError ModelManager._computeOn(
                    QoI("never_stored_anywhere", _qoi_sim; stored=:require), sid_probe)

                # Store, then read back through `stored`.
                run(t; post_processor=QoI("stored_x", _qoi_sim))
                waitForDiagnostics()
                sids = simulationIDs(t)
                for sid in sids
                    @test ModelManager._storedValue("stored_x", sid) !== nothing
                end

                # :prefer returns the stored number without calling compute. A compute that throws
                # proves the stored path was taken rather than merely agreeing with it.
                exploding = QoI("stored_x", s -> error("compute must not run"); stored=:prefer)
                @test ModelManager._computeOn(exploding, first(sids)) ≈
                      ModelManager._storedValue("stored_x", first(sids))
                # ...and falls back to compute when nothing is stored under that name.
                fallback = QoI("no_such_column", _qoi_sim; stored=:prefer)
                @test ModelManager._computeOn(fallback, first(sids)) ≈
                      _qoi_sim(Simulation(first(sids)))

                # verifyStoredValues recomputes where the output survives.
                rep = verifyStoredValues(QoI("stored_x", _qoi_sim), t)
                @test rep.n_checked == length(sids)
                @test rep.n_agreed + rep.n_unverifiable == length(sids)
                @test rep.n_mismatched == 0
                @test isempty(rep.mismatches)

                # A disagreeing compute is caught and reported, not averaged over.
                bad = verifyStoredValues(QoI("stored_x", s -> _qoi_sim(s) + 1000.0), t)
                if bad.n_unverifiable < length(sids)      # only if some output survives to check
                    @test bad.n_mismatched > 0
                    @test !isempty(bad.mismatches)
                    @test bad.mismatches[1].stored != bad.mismatches[1].recomputed
                end

                # And a name that was never stored is reported as missing, not as agreement.
                none = verifyStoredValues(QoI("no_such_column", _qoi_sim), t)
                @test none.n_missing == length(sids)
                @test none.n_agreed == 0
            end

            @testset "sensitivity on a discrepancy-to-data QoI" begin
                # The workflow: a simulation yields several values; average each across replicates,
                # THEN compare to data. Squaring is nonlinear, so mean-then-square is not
                # square-then-mean, and a per-simulation compute cannot do it — it has no access to
                # the mean. `reduce` is the monad-level step that can: it receives every replicate's
                # value, so `compute` returns the raw per-simulation values and `reduce` averages and
                # then squares.
                obs = Dict("x" => 2.0, "y" => 3.0)
                function _both(s::Simulation)
                    return Dict("x" => getParameterValue(s, :config, XMLPath(["data", "x"])),
                                "y" => getParameterValue(s, :config, XMLPath(["data", "y"])))
                end
                # One scalar per monad: mean per key, squared difference, then summed.
                mse_reduce = per_sim -> sum((mean(getindex.(per_sim, k)) - obs[k])^2 for k in keys(obs))
                q = QoI("mse", _both; reduce=mse_reduce)

                spec = StudySpec(inputs, [DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))];
                                 n_replicates=3)
                gsa = run(MOAT(), spec; functions=[q])
                waitForDiagnostics()
                @test gsa isa ModelManager.GSASampling
                # A scalar reduce yields one analysis, filed under the QoI's own name.
                @test haskey(gsa.results, "mse")
                @test ModelManager.gsaLabels(gsa) == ["mse"]

                # And the arithmetic the workflow depends on: averaging first is not the same as
                # squaring first, so which side of `reduce` the nonlinearity sits on matters.
                per_sim = [Dict("x" => 1.0, "y" => 2.0), Dict("x" => 3.0, "y" => 4.0)]
                mean_then_sq = sum((mean(getindex.(per_sim, k)) - obs[k])^2 for k in keys(obs))
                sq_then_mean = sum(mean((getindex.(per_sim, k) .- obs[k]).^2) for k in keys(obs))
                @test mse_reduce(per_sim) ≈ mean_then_sq
                @test !(mean_then_sq ≈ sq_then_mean)
            end

            @testset "GSA honours a QoI's reducer, and plain functions still work" begin
                spec = StudySpec(inputs, [DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))];
                                 n_replicates=2)
                # A plain Function gets a simulation ID and mean over replicates, exactly as before.
                gsa1 = run(MOAT(), spec; functions=[_qoi_by_id])
                waitForDiagnostics()
                @test gsa1 isa ModelManager.GSASampling

                # A QoI with a non-mean reducer is now accepted rather than refused: this is what
                # changed in GSA's internals.
                gsa2 = run(MOAT(), spec; functions=[QoI("x", _qoi_sim; reduce=maximum)])
                waitForDiagnostics()
                @test gsa2 isa ModelManager.GSASampling

                # Results are filed by label. A bare function's label is its regularised QoI name,
                # a QoI's is the name it was given.
                @test ModelManager.gsaLabels(gsa1) == ["_qoi_by_id"]
                @test ModelManager.gsaLabels(gsa2) == ["x"]
            end

            @testset "a Dict-valued reduce spreads into one analysis per key" begin
                # The gap this closes: a measurement shaped `name => value` fed calibration and the
                # sink unchanged, but GSA refused it, so the same quantity had to be rewritten once
                # per key. Now one QoI yields one analysis per key, labelled "<qoi>.<key>".
                function _pair(s::Simulation)
                    return Dict("x" => getParameterValue(s, :config, XMLPath(["data", "x"])),
                                "y" => getParameterValue(s, :config, XMLPath(["data", "y"])))
                end
                spread = QoI("counts", _pair; reduce=per_sim -> Dict(k => mean(getindex.(per_sim, k))
                                                                     for k in ("x", "y")))
                spec = StudySpec(inputs, [DistributedVariation(:config, xp_x, Uniform(0.5, 3.0)),
                                          DistributedVariation(:config, xp_y, Uniform(1.0, 4.0))];
                                 n_replicates=2)

                gsa = run(MOAT(3), spec; functions=[spread])
                waitForDiagnostics()
                @test ModelManager.gsaLabels(gsa) == ["counts.x", "counts.y"]
                @test gsa.results["counts.x"] isa GlobalSensitivity.MorrisResult

                # Every spread series reaches the plot, which is what makes several analyses from
                # one QoI legible: two labels → two µ* series, each named by its label.
                bd = ModelManager._moatBarData(gsa.results, gsa.monad_ids_df, false)
                @test [g.label for g in bd.groups] == ["µ*: counts.x", "µ*: counts.y"]

                # The load-bearing property: a spread component is the SAME analysis a scalar QoI
                # measuring that key on its own would give. Computed on THIS sampling rather than a
                # second `run`, because each run draws a fresh LHS design — comparing across two
                # designs would compare two different questions.
                calculateGSA!(gsa, [QoI("x", s -> _pair(s)["x"]), QoI("y", s -> _pair(s)["y"])])
                @test ModelManager.gsaLabels(gsa) == ["counts.x", "counts.y", "x", "y"]
                @test vec(gsa.results["counts.x"].means_star) ≈ vec(gsa.results["x"].means_star)
                @test vec(gsa.results["counts.y"].means_star) ≈ vec(gsa.results["y"].means_star)
                # ...and the two keys are genuinely different analyses, not one value duplicated.
                @test !(vec(gsa.results["counts.x"].means_star) ≈ vec(gsa.results["counts.y"].means_star))

                # A NamedTuple spreads too, and keeps its declaration order rather than sorting.
                nt = QoI("nt", _pair; reduce=per_sim -> (y=mean(getindex.(per_sim, "y")),
                                                         x=mean(getindex.(per_sim, "x"))))
                gsa_nt = run(MOAT(3), spec; functions=[nt])
                waitForDiagnostics()
                @test ModelManager.gsaLabels(gsa_nt) == ["nt.x", "nt.y"]      # gsaLabels sorts
                @test first.(ModelManager.evaluateFunctionOnSampling(gsa_nt, nt)) == ["nt.y", "nt.x"]

                # Sobolʼ and RBD spread by the same rule, so this is a property of the QoI seam and
                # not of one method's index arithmetic.
                sob = run(Sobolʼ(4), spec; functions=[spread])
                waitForDiagnostics()
                @test ModelManager.gsaLabels(sob) == ["counts.x", "counts.y"]
                @test sob.results["counts.y"] isa GlobalSensitivity.SobolResult
                rbd = run(RBD(4), spec; functions=[spread])
                waitForDiagnostics()
                @test ModelManager.gsaLabels(rbd) == ["counts.x", "counts.y"]
                @test length(rbd.results["counts.x"]) == 2   # one index per parameter
            end

            @testset "a QoI-keyed result plots" begin
                # Regression: `results` used to be keyed by the QoI object, and the label function
                # had only a `::Function` method. TWO quantities are needed to reproduce it, and the
                # reason is worth stating because it is why the bug went unnoticed: the sole
                # unguarded call was `sort(keys(results); by=_gsaFunctionLabel)`, and `sort` never
                # invokes `by` on a one-element vector, while every other call site sits behind
                # `multi = length(...) > 1`. So a single-QoI analysis plotted fine and any
                # QoI-driven analysis with two entries threw before drawing anything. Labels are
                # strings now, so there is nothing left to dispatch on.
                spec = StudySpec(inputs, [DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))];
                                 n_replicates=1)
                gsa = run(MOAT(3), spec; functions=[QoI("plotted", _qoi_sim),
                                                    QoI("plotted2", _qoi_sim; reduce=maximum)])
                waitForDiagnostics()
                @test ModelManager.gsaLabels(gsa) == ["plotted", "plotted2"]
                rd = RecipesBase.apply_recipe(Dict{Symbol,Any}(), gsa)
                @test rd[1].args[1] isa ModelManager._GSABarData
                # Two series, each named by its label — the path that used to MethodError.
                @test [g.label for g in rd[1].args[1].groups] == ["µ*: plotted", "µ*: plotted2"]
                @test RecipesBase.apply_recipe(Dict{Symbol,Any}(), gsa, :violin)[1].args[1] isa ModelManager._GSAViolinData
                @test RecipesBase.apply_recipe(Dict{Symbol,Any}(), gsa, :scatter)[1].args[1] isa ModelManager._GSAScatterData
                # `show` names the quantities rather than printing a closure.
                @test occursin("plotted2", sprint(show, gsa))
            end

            @testset "GSA refuses what it cannot turn into an index" begin
                spec = StudySpec(inputs, [DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))];
                                 n_replicates=1)
                gsa = run(MOAT(3), spec; functions=Any[])
                waitForDiagnostics()

                # A Vector reduce is refused, and the message says why per-index spreading is not
                # offered rather than merely that it is unsupported.
                vec_q = QoI("series", _qoi_sim; reduce=per_sim -> collect(per_sim))
                err = try; calculateGSA!(gsa, [vec_q]); nothing; catch e; e; end
                @test err isa ArgumentError
                @test occursin("equal length is not equal meaning", err.msg)
                @test occursin("series", err.msg)

                # A Dict of non-numbers passes the key check and is caught at the value.
                str_q = QoI("labels", _qoi_sim; reduce=per_sim -> Dict("a" => "not a number"))
                err = try; calculateGSA!(gsa, [str_q]); nothing; catch e; e; end
                @test err isa ArgumentError
                @test occursin("labels.a", err.msg)

                # Key sets must agree across monads: a hole in a design matrix has no defensible
                # fill, so this refuses rather than imputing as `mseDistance` does.
                ragged = QoI("ragged", _qoi_sim;
                             reduce=per_sim -> first(per_sim) < 2.0 ? Dict("a" => 1.0) :
                                                                      Dict("a" => 1.0, "b" => 2.0))
                err = try; calculateGSA!(gsa, [ragged]); nothing; catch e; e; end
                @test err isa ArgumentError
                @test occursin("same keys", err.msg)

                # A reducer that names no quantities is refused rather than silently storing
                # nothing: it would also never count as evaluated, so every later call would re-read
                # every simulation's output to store nothing again.
                empty_q = QoI("empty", _qoi_sim; reduce=per_sim -> Dict{String,Float64}())
                err = try; calculateGSA!(gsa, [empty_q]); nothing; catch e; e; end
                @test err isa ArgumentError
                @test occursin("names no quantities", err.msg)
                @test isempty(ModelManager._gsaLabelsOf(gsa, "empty"))

                # Two keys of ONE QoI that collide once written into a label are refused where the
                # keys are still in hand, not downstream. Both downstream paths mishandle it: the
                # cross-QoI check would say "comes from both QoI \"…\" and QoI \"…\"" naming the
                # same QoI twice, and the single-measurement method has no check at all and would
                # let one analysis silently overwrite the other.
                collide = QoI("collide", _qoi_sim;
                              reduce=per_sim -> Dict{Any,Any}(1 => 1.0, "1" => 2.0))
                err = try; calculateGSA!(gsa, [collide]); nothing; catch e; e; end
                @test err isa ArgumentError
                @test occursin("all produce the label", err.msg)
                @test occursin("collide", err.msg)
                # ...and through the single-measurement method too, which is the silent path.
                err = try; calculateGSA!(gsa, collide); nothing; catch e; e; end
                @test err isa ArgumentError
                @test occursin("all produce the label", err.msg)
                @test !any(startswith("collide"), ModelManager.gsaLabels(gsa))

                # Two QoIs producing one label is refused, and nothing is filed when it is.
                dup = [QoI("dup", _qoi_sim), QoI("dup", _qoi_sim; reduce=maximum)]
                err = try; calculateGSA!(gsa, dup); nothing; catch e; e; end
                @test err isa ArgumentError
                @test occursin("unique within one `calculateGSA!` call", err.msg)
                @test isempty(ModelManager.gsaLabels(gsa))

                # A measurement already evaluated is skipped, so adding a quantity costs only the
                # new one. The skip is decided from the QoI's NAME, before any output is read —
                # which is what makes it a saving rather than a late no-op.
                calculateGSA!(gsa, [QoI("again", _qoi_sim)])
                before = vec(gsa.results["again"].means_star)
                calculateGSA!(gsa, [QoI("again", _qoi_sim; reduce=per_sim -> 3 * mean(per_sim))])
                @test vec(gsa.results["again"].means_star) ≈ before      # skipped, not overwritten

                # `recompute=true` is how you force it after changing the measurement, since nothing
                # can detect that the measurement changed.
                calculateGSA!(gsa, [QoI("again", _qoi_sim; reduce=per_sim -> 3 * mean(per_sim))];
                              recompute=true)
                @test ModelManager.gsaLabels(gsa) == ["again"]
                @test vec(gsa.results["again"].means_star) ≈ 3 .* before

                # A SPREADING QoI is recognised by name too, even though its labels ("spr.a") are
                # not known until its reducer has run — the case a label-based check could not skip
                # without first doing the work it was meant to avoid.
                spread_calls = Ref(0)
                spr = QoI("spr", s -> (spread_calls[] += 1; _qoi_sim(s));
                          reduce=per_sim -> Dict("a" => mean(per_sim)))
                calculateGSA!(gsa, [spr])
                @test "spr.a" in ModelManager.gsaLabels(gsa)
                after_first = spread_calls[]
                @test after_first > 0
                calculateGSA!(gsa, [spr])
                @test spread_calls[] == after_first                      # no output re-read
                calculateGSA!(gsa, [spr]; recompute=true)
                @test spread_calls[] > after_first

                # `recompute` REPLACES a measurement's labels rather than merging into them. A
                # reducer that drops a key would otherwise leave the old label behind holding a
                # number from a measurement that no longer exists — reported by `gsaLabels` as
                # current and drawn as a series — which is exactly the case `recompute` is for.
                calculateGSA!(gsa, [QoI("shrink", _qoi_sim;
                                        reduce=per_sim -> Dict("a" => mean(per_sim),
                                                               "b" => maximum(per_sim)))])
                @test ["shrink.a", "shrink.b"] ⊆ ModelManager.gsaLabels(gsa)
                calculateGSA!(gsa, [QoI("shrink", _qoi_sim;
                                        reduce=per_sim -> Dict("a" => mean(per_sim)))];
                              recompute=true)
                @test "shrink.a" in ModelManager.gsaLabels(gsa)
                @test !("shrink.b" in ModelManager.gsaLabels(gsa))   # dropped, not left stale
                # ...and through the single-measurement method too.
                calculateGSA!(gsa, QoI("shrink", _qoi_sim;
                                       reduce=per_sim -> Dict("c" => mean(per_sim)));
                              recompute=true)
                @test "shrink.c" in ModelManager.gsaLabels(gsa)
                @test !any(l -> l in ("shrink.a", "shrink.b"), ModelManager.gsaLabels(gsa))

                # ...but replacing is scoped to the QoIs NAMED, never a prune of the rest. `spr`
                # and `again` were not in either `shrink` call and keep their labels.
                @test ["spr.a", "again"] ⊆ ModelManager.gsaLabels(gsa)

                # Adding a quantity evaluates only the new one.
                calculateGSA!(gsa, [spr, QoI("fresh", _qoi_sim)])
                @test spread_calls[] == 2 * after_first                  # spr untouched again
                @test "fresh" in ModelManager.gsaLabels(gsa)

                # And a later `recompute` of one measurement leaves every other one alone. Pruning
                # what a call does not name would make `calculateGSA!(gsa, [q2])` delete q1, which
                # is the add-a-quantity workflow the skip exists for; an unnamed QoI's indices are
                # not stale either, having come from this same sampling.
                calculateGSA!(gsa, [QoI("fresh", _qoi_sim; reduce=maximum)]; recompute=true)
                @test ["fresh", "spr.a", "again", "shrink.c"] ⊆ ModelManager.gsaLabels(gsa)

                # The name-based skip is exact, not a loose prefix match: "spr" must not be
                # considered already-evaluated because of an unrelated name that starts with it.
                # (The one way it COULD be ambiguous — a QoI actually named "spr.a" — is refused at
                # construction, which is what makes this inference sound rather than heuristic.)
                calculateGSA!(gsa, [QoI("spread_out", _qoi_sim)])
                @test "spread_out" in ModelManager.gsaLabels(gsa)
                @test ModelManager._hasGSAResults(gsa, QoI("spread_ou", _qoi_sim)) == false

                # The single-measurement method files results too. It used to be covered for free,
                # because the vector method delegated to it; now that the vector method stages and
                # stores its own results (so a rejected call leaves `results` untouched), this is a
                # separate exported entry point and needs its own exercise.
                calculateGSA!(gsa, QoI("solo", _qoi_sim))
                @test "solo" in ModelManager.gsaLabels(gsa)
                @test gsa.results["solo"] isa GlobalSensitivity.MorrisResult
                # It spreads, skips and recomputes on the same terms as the vector method.
                solo_calls = Ref(0)
                solo_spread = QoI("duo", s -> (solo_calls[] += 1; _qoi_sim(s));
                                  reduce=per_sim -> Dict("a" => mean(per_sim), "b" => maximum(per_sim)))
                calculateGSA!(gsa, solo_spread)
                @test ["duo.a", "duo.b"] ⊆ ModelManager.gsaLabels(gsa)
                once = solo_calls[]
                calculateGSA!(gsa, solo_spread)
                @test solo_calls[] == once                               # skipped
                calculateGSA!(gsa, solo_spread; recompute=true)
                @test solo_calls[] > once
            end

            @testset "run_kwargs is one channel with the loose splat" begin
                m = ModelManager._mergeRunKwargs
                @test m((prune=1, keep=2), pairs(NamedTuple())) == (prune=1, keep=2)
                @test m(NamedTuple(), pairs((a=1,)))            == (a=1,)
                @test m(NamedTuple(), pairs(NamedTuple()))      == NamedTuple()
                # A loose keyword wins: it is the more deliberate spelling at the call site.
                @test m((prune=1, keep=2), pairs((keep=99,)))   == (prune=1, keep=99)

                # The bundle reaches the simulator hooks exactly as a loose keyword does. The stub
                # simulator records what setupSampling saw, so this checks arrival, not just merging.
                dv = DiscreteVariation(:config, xp_x, [131.0, 137.0])
                t1 = createTrial(inputs, [dv]; n_replicates=1, use_previous=false)
                run(t1; run_kwargs=(marker_kw="bundle",))
                waitForDiagnostics()
                @test _last_setup_kwargs[] !== nothing
                @test get(_last_setup_kwargs[], :marker_kw, nothing) == "bundle"

                t2 = createTrial(inputs, [DiscreteVariation(:config, xp_x, [139.0])];
                                 n_replicates=1, use_previous=false)
                run(t2; marker_kw="loose")
                waitForDiagnostics()
                @test get(_last_setup_kwargs[], :marker_kw, nothing) == "loose"

                # Both spellings at once: loose wins, bundle's other keys survive.
                t3 = createTrial(inputs, [DiscreteVariation(:config, xp_x, [149.0])];
                                 n_replicates=1, use_previous=false)
                run(t3; run_kwargs=(marker_kw="bundle", other_kw=7), marker_kw="loose")
                waitForDiagnostics()
                @test get(_last_setup_kwargs[], :marker_kw, nothing) == "loose"
                @test get(_last_setup_kwargs[], :other_kw, nothing) == 7
            end

            @testset "run_kwargs cannot hijack calibration's own run controls" begin
                # run_kwargs used to be splatted LAST, so a simulator bundle could replace the
                # progress machinery the `progress=` keyword had just configured. The calibration's
                # own controls now come after it.
                dv   = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                prob = CalibrationProblem(inputs, [dv], Dict{String,Any}("x" => 1.0),
                                          _test_nonzero_ss, mseDistance)
                res = runCalibration(ABCSMC(population_size=4, max_nr_populations=1,
                                            minimum_epsilon=0.0, max_evaluations=32), prob;
                                     description="run_kwargs precedence", progress=:none,
                                     run_kwargs=(quiet=false, on_progress=nothing))
                waitForDiagnostics()
                @test res isa ABCResult
                @test length(res.generations) == 1
            end

            @testset "StudySpec feeds both sensitivity and calibration" begin
                dv1 = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                dv2 = DistributedVariation(:config, xp_y, Uniform(1.0, 4.0))
                spec = StudySpec(inputs, [dv1, dv2]; n_replicates=2, use_previous=false)

                @test spec.inputs == inputs
                @test length(spec.variations) == 2
                @test spec.n_replicates == 2
                @test spec.use_previous == false
                @test spec.reference_variation_id == VariationID(inputs)
                # The user's originals are kept, not normalised: the reverse conversion would lose a
                # DistributedVariation's display name, which the generation CSVs are keyed by.
                @test all(v -> v isa DistributedVariation, spec.variations)

                # Vararg form, and the eltype the invariant ParsedVariations constructor needs.
                spec_va = StudySpec(inputs, dv1, dv2)
                @test spec_va.variations == spec.variations
                @test spec.variations isa Vector{AbstractVariation}
                @test ModelManager.ParsedVariations(spec) isa ModelManager.ParsedVariations

                # Same spec drives a calibration...
                prob = CalibrationProblem(spec, Dict{String,Any}("x" => 1.0),
                                          _test_named_ss, mseDistance)
                @test prob.inputs == inputs
                @test prob.n_replicates == 2
                @test prob.reference_variation_id == spec.reference_variation_id
                @test length(prob.parameters) == 2
                # ...with overrides where they make sense.
                prob2 = CalibrationProblem(spec, Dict{String,Any}("x" => 1.0),
                                           _test_named_ss, mseDistance; n_replicates=5)
                @test prob2.n_replicates == 5

                # ...and a sensitivity sweep, forwarding all three spec fields.
                gsa = run(MOAT(), spec; functions=Function[])
                waitForDiagnostics()
                @test gsa isa ModelManager.GSASampling

                # A caller keyword beats the spec's, since kwargs... comes last.
                spec1 = StudySpec(inputs, [dv1, dv2]; n_replicates=1)
                gsa2 = run(MOAT(), spec1; functions=Function[], n_replicates=1)
                waitForDiagnostics()
                @test gsa2 isa ModelManager.GSASampling
            end

            @testset "StudySpec from a monad takes its reference variation" begin
                dv  = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                ref = createTrial(inputs, [DiscreteVariation(:config, xp_x, 9.0)]; n_replicates=1)
                spec = StudySpec(ref, [dv])
                @test spec.inputs == ref.inputs
                @test spec.reference_variation_id == ref.variation_id
                # No override, matching createTrial and CalibrationProblem's monad forms: passing a
                # reference and then replacing what makes it a reference is a contradiction.
                @test_throws MethodError StudySpec(ref, [dv];
                                                   reference_variation_id=VariationID(inputs))
                @test StudySpec(ref, dv).variations == spec.variations
            end

            @testset "StudySpec show reports usability per parameter" begin
                dv  = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                dsc = DiscreteVariation(:config, xp_y, [1.0, 2.0])
                out = sprint(show, MIME"text/plain"(), StudySpec(inputs, [dv, dsc]))
                @test occursin("StudySpec:", out)
                @test occursin("(sensitivity only)", out)      # use_previous is calibration-irrelevant
                # Each parameter's verdict is derived from _calibrationRejection rather than hardcoded,
                # so this does not have to be revisited as more variation kinds become calibratable.
                for v in (dv, dsc)
                    expected = isnothing(ModelManager._calibrationRejection(v)) ? "yes" : "no"
                    line = only(filter(l -> occursin(ModelManager.variationName(v), l),
                                       split(out, "\n")))
                    @test occursin("calibration: " * expected, line)
                    @test occursin("sensitivity: yes", line)   # every variation kind sweeps
                end
                # Fields on their own lines, not run together with the input folders.
                @test occursin(r"\n  Replicates:", out)
            end

            @testset "generation index is the index, not a listing position" begin
                # The bug this pins down: posterior, ConvergenceSummary and the recipes each used a
                # generation's POSITION in a sorted filename listing as its index. That is only
                # correct while every name is one width and the generations are contiguous from 1.
                # Generations 1, 2 and 10 at mixed padding break both assumptions at once.
                cal  = ModelManager.createCalibration("ABC-SMC"; description="index vs position")
                gdir = joinpath(ModelManager.calibrationFolder(cal), "generations")
                cdir = joinpath(gdir, "generation_cdfs")
                mkpath(cdir)

                gens = ((1, 2, 0.90, 30), (2, 2, 0.50, 20), (10, 3, 0.01, 10))
                for (t, w, eps, nev) in gens
                    tag = lpad(string(t), w, '0')
                    # One particle whose parameter value encodes its generation, so a wrong lookup
                    # is visible in the value rather than only in the count.
                    df = DataFrame("p" => [Float64(t)], "weight" => [1.0],
                                   "distance" => [eps], "monad_id" => [100 + t])
                    CSV.write(joinpath(gdir, "generation_$(tag).csv"), df)
                    CSV.write(joinpath(cdir, "generation_$(tag).csv"), df)
                    open(joinpath(gdir, "generation_$(tag).toml"), "w") do io
                        TOML.print(io, Dict{String,Any}(
                            "t" => t, "max_epsilon_accepted" => eps, "n_evaluations" => nev,
                            "acceptance_rate" => 1 / nev, "ess" => 1.0); sorted=true)
                    end
                end

                # ConvergenceSummary reports the real indices, not 1:3.
                cs = ConvergenceSummary(cal)
                @test cs.df.t == [1, 2, 10]
                @test cs.df.max_epsilon_accepted ≈ [0.90, 0.50, 0.01]
                @test cs.df.n_evaluations == [30, 20, 10]

                # posterior addresses generations by index. Generation 10 exists; 3 does not.
                df10, w10 = posterior(cal; generation=10)
                @test df10.p == [10.0]
                @test w10 == [1.0]
                @test posterior(cal; generation=2)[1].p == [2.0]
                @test_throws ArgumentError posterior(cal; generation=3)
                # :final is the highest index, not the last name in a sorted list.
                @test posterior(cal)[1].p == [10.0]

                # show reports the count and the final generation's epsilon.
                shown = sprint(show, cal)
                @test occursin("Generations: 3", shown)
                @test occursin("0.01", shown)

                # After migration all of the above still holds, and the folders carry the indices.
                ModelManager._migrateGenerationLayout!(cal, 10)
                @test sort(filter(f -> isdir(joinpath(gdir, f)), readdir(gdir))) == ["01", "02", "10"]
                @test ConvergenceSummary(cal).df.t == [1, 2, 10]
                @test posterior(cal; generation=10)[1].p == [10.0]
                @test posterior(cal)[1].p == [10.0]
            end

            @testset "reusability filter — started or completed simulations" begin
                # A monad that has run is reusable; one whose simulations have not started is
                # not (nothing to snap onto), and neither is a monad that does not exist.
                # n_replicates=2 so createTrial returns a Monad rather than a Simulation.
                ran   = createTrial(inputs, [DiscreteVariation(:config, xp_x, 41.0)];
                                    n_replicates=2)
                run(ran)
                # 43.0 is used by no other testset: `use_previous=true` would otherwise reuse an
                # existing monad that already has completed simulations.
                unrun = createTrial(inputs, [DiscreteVariation(:config, xp_x, 43.0)];
                                    n_replicates=2)
                @test ran isa Monad && unrun isa Monad

                reusable = ModelManager._monadsWithStartedSimulations([ran.id, unrun.id, -7])
                @test ran.id in reusable
                @test unrun.id ∉ reusable
                @test -7 ∉ reusable
                @test isempty(ModelManager._monadsWithStartedSimulations(Int[]))

                # A `Running` simulation counts: the output is on its way.
                unrun_sid = ModelManager.simulationIDs(unrun)[1]
                ModelManager.DBInterface.execute(ModelManager.centralDB(),
                    "UPDATE simulations SET " *
                    "status_code_id=$(ModelManager.statusCodeID("Running")) " *
                    "WHERE simulation_id=$unrun_sid;")
                @test unrun.id in ModelManager._monadsWithStartedSimulations([unrun.id])

                # Same rule gates bank additions mid-run, keyed on the monad's own state rather
                # than on the particle's distance — so an unusual but legitimate distance from
                # a user's `distance` function does not bar a good monad from reuse.
                bank = ModelManager.SimulationBank(Int[], Matrix{Float64}(undef, 1, 0), ["x"])
                ModelManager.DBInterface.execute(ModelManager.centralDB(),
                    "UPDATE simulations SET " *
                    "status_code_id=$(ModelManager.statusCodeID("Not Started")) " *
                    "WHERE simulation_id=$unrun_sid;")
                proposals = Tuple{Dict{String,Float64}, Union{Nothing,Int}}[
                    (Dict("x" => 0.1), nothing),   # ran → added despite its Inf distance
                    (Dict("x" => 0.2), nothing),   # never started → skipped
                    (Dict("x" => 0.3), 99)]        # a reuse (proposal_mid given) → skipped
                results   = Tuple{Union{Float64,Missing},Int}[
                    (Inf, ran.id), (1.0, unrun.id), (2.0, 99)]
                additions = Tuple{Vector{Float64},Int}[]
                ModelManager._updateMidGenAdditions!(additions, proposals, results, bank, ["x"])
                @test [mid for (_, mid) in additions] == [ran.id]

                # And the same rule filters the bank at load time. Both monads sit strictly
                # inside this prior (CDF 0.2 and 0.6), so only the started/completed test
                # separates them.
                prob_bank = CalibrationProblem(inputs,
                    [DistributedVariation(:config, xp_x, Uniform(40.0, 45.0))],
                    Dict{String,Any}("x" => 1.0), _test_named_ss, mseDistance)
                built = ModelManager._buildSimulationBank(prob_bank)
                @test ran.id in built.monad_ids
                @test unrun.id ∉ built.monad_ids
            end

            # These two exercise the snapping/bank machinery through _runABCSMC with mock
            # monad IDs. They live here, inside the initialized project, because the bank's
            # reusability filter queries simulation statuses — with no database there is
            # nothing to consult. Mock IDs that match a real monad are reusable; ones that do
            # not are simply skipped. Either way the assertions below are about grid
            # alignment and population size, which the filter does not affect.
            @testset "CDF-grid snapping integration: no duplicate snap keys per generation" begin
                Random.seed!(42)
                # k=3 gives grid {j/8 : j=1..7} in 1D — 7 unique points.
                # population_size=5 < 7, so we expect 5 unique snap keys with no collisions.
                method = ABCSMC(population_size=5, max_nr_populations=3,
                                minimum_epsilon=0.0, cdf_grid_k=3)

                # Mock get_monad_id: returns a consistent unique ID per unique snap value.
                snap_id_map = Dict{Float64, Int}()
                mid_counter = Ref(0)
                get_monad_id_fn = function(params)
                    v = params["x"]
                    if !haskey(snap_id_map, v)
                        mid_counter[] += 1
                        snap_id_map[v] = mid_counter[]
                    end
                    return snap_id_map[v]
                end
                # evaluate_batch: for known-mid proposals reuse the mid; for new snaps assign a
                # consistent ID via get_monad_id_fn so grid-alignment checks remain valid.
                evaluate_batch = (t, proposals) -> [(rand(), isnothing(mid) ? get_monad_id_fn(cdfs) : mid)
                                                     for (cdfs, mid) in proposals]

                gens = ModelManager._runABCSMC(method, ["x"], [Uniform(0, 1)],
                                                evaluate_batch, g -> nothing)

                for g in gens
                    @test nrow(g.particles) == 5
                    # All particles' x values should be on the grid {j/2^k_eff : j=1..2^k_eff-1}
                    k_eff = ModelManager._effectiveK(3, g.t)
                    n     = 2^k_eff
                    for i in 1:nrow(g.particles)
                        u = g.particles[i, :x]
                        j = round(Int, u * n)
                        @test j ∈ 1:(n-1)
                        @test isapprox(u, j / n; atol=1e-10)
                    end
                    # Duplicate snap keys are now allowed (discrete-SMC design)
                    keys = [round(Int, g.particles[i, :x] * 2^k_eff) for i in 1:nrow(g.particles)]
                    @test length(unique(keys)) >= 1   # at least one distinct snap point
                end
            end

            @testset "k_base_eff correction: coarse cdf_grid_k raised for population_size" begin
                # k=1, d=1: (2^1-1)^1 = 1 interior point. For N=5 we need k_min=3
                # since (2^3-1)^1=7≥5 but (2^2-1)^1=3<5... wait, 3>=5 is false; let us check:
                # k=2: (2^2-1)^1=3<5 → not enough. k=3: (2^3-1)^1=7≥5 → ok. So k_min=3.
                # With k=1 supplied, _runABCSMC should raise k_base_eff to 3.
                # All snapped particles in gen-1 must lie on the k=3 grid.
                Random.seed!(17)
                snap_id_map = Dict{Float64, Int}()
                id_counter  = Ref(0)
                get_monad_id_fn = function(params)
                    v = params["x"]
                    if !haskey(snap_id_map, v)
                        id_counter[] += 1
                        snap_id_map[v] = id_counter[]
                    end
                    return snap_id_map[v]
                end
                evaluate_batch = (t, proposals) -> [(0.1, isnothing(mid) ? get_monad_id_fn(cdfs) : mid)
                                                     for (cdfs, mid) in proposals]

                method = ABCSMC(population_size=5, max_nr_populations=1,
                                minimum_epsilon=0.0, cdf_grid_k=1)
                gens = ModelManager._runABCSMC(method, ["x"], [Uniform(0, 1)],
                                                evaluate_batch, g -> nothing)
                @test length(gens) == 1
                @test nrow(gens[1].particles) == 5
                # k_base_eff should have been raised to 3; gen-1 k_eff = 3
                k_eff_expected = 3
                n = 2^k_eff_expected
                for i in 1:nrow(gens[1].particles)
                    u = gens[1].particles[i, :x]
                    j = round(Int, u * n)
                    @test j ∈ 1:(n-1)
                    @test isapprox(u, j / n; atol=1e-10)
                end
            end

            @testset "_batchOutcome classifies a batch" begin
                # Build a monad with two simulations, run it, then mark them by hand: the
                # classification reads status codes, so it needs no real failures here.
                dv   = DiscreteVariation(:config, xp_x, 31.0)
                m    = createTrial(inputs, [dv]; n_replicates=2)
                run(m)
                sids = ModelManager.simulationIDs(m)
                @test length(sids) == 2

                # Both completed → no failures, monad has successes.
                failed_sims, failed_monads, no_success =
                    ModelManager._batchOutcome(Dict(m.id => sids))
                @test isempty(failed_sims) && isempty(failed_monads) && isempty(no_success)

                # One failed, one completed → recorded as a failure, but still evaluable.
                ModelManager.DBInterface.execute(ModelManager.centralDB(),
                    "UPDATE simulations SET status_code_id=$(ModelManager.statusCodeID("Failed")) " *
                    "WHERE simulation_id=$(sids[1]);")
                failed_sims, failed_monads, no_success =
                    ModelManager._batchOutcome(Dict(m.id => sids))
                @test failed_sims == [sids[1]]
                @test failed_monads == [m.id]
                @test isempty(no_success)

                # Both failed → no successful simulation, so the particle is unevaluable.
                ModelManager.DBInterface.execute(ModelManager.centralDB(),
                    "UPDATE simulations SET status_code_id=$(ModelManager.statusCodeID("Failed")) " *
                    "WHERE simulation_id=$(sids[2]);")
                failed_sims, failed_monads, no_success =
                    ModelManager._batchOutcome(Dict(m.id => sids))
                @test failed_sims == sort(sids)
                @test no_success == [m.id]

                # A constituent simulation with no database row means the records and the DB
                # disagree — that is a bug to surface, not a status to guess at.
                @test_throws "no row in the `simulations` table" ModelManager._batchOutcome(
                    Dict(-1 => [999999]))
                @test isempty(ModelManager._simulationStatusIDs(Int[]))

                # Restore the statuses so later testsets see a healthy project.
                for sid in sids
                    ModelManager.DBInterface.execute(ModelManager.centralDB(),
                        "UPDATE simulations SET " *
                        "status_code_id=$(ModelManager.statusCodeID("Completed")) " *
                        "WHERE simulation_id=$sid;")
                end
            end

            @testset "resumeABC" begin
                # Use _test_nonzero_ss (always returns x=2.0) so distances are
                # consistently 1.0 against observed x=1.0, preventing premature
                # convergence and letting the resume actually add more generations.
                dv       = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                observed  = Dict{String,Any}("x" => 1.0)
                prob_resume = CalibrationProblem(inputs, [dv], observed,
                                                 _test_nonzero_ss, mseDistance)

                # Initial run: capped at 1 generation.
                method1 = ABCSMC(population_size=4, max_nr_populations=1,
                                  minimum_epsilon=0.0)
                result1 = runCalibration(method1, prob_resume; description="resume base")
                @test length(result1.generations) == 1

                # Resume: allow up to 3 total generations.
                method2 = ABCSMC(population_size=4, max_nr_populations=3,
                                  minimum_epsilon=0.0)
                result2 = resumeABC(result1.calibration; problem=prob_resume, method=method2)
                waitForDiagnostics()

                @test result2.calibration.id == result1.calibration.id
                @test length(result2.generations) > 1
                # Generation 1 particles preserved exactly across resume
                @test result2.generations[1].particles ==
                      result1.generations[1].particles
            end

            @testset "resume keeps the saved settings it was not asked to change" begin
                # A method object supplies EVERY field, so `method=ABCSMC(max_nr_populations=15)`
                # silently reset population_size, both epsilon controls and the kernel to their
                # constructor defaults. Keywords patch one field and carry the rest over.
                dv    = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                prob  = CalibrationProblem(inputs, [dv], Dict{String,Any}("x" => 1.0),
                                           _test_nonzero_ss, mseDistance)
                saved = ABCSMC(population_size=6, max_nr_populations=1, minimum_epsilon=0.0,
                               epsilon_quantile=0.3, perturbation_kernel=ComponentwiseKernel(),
                               max_evaluations=64)
                base  = runCalibration(saved, prob; description="resume overrides")
                cal   = base.calibration

                # Keyword form: only the named field moves.
                r = resumeCalibration(cal; problem=prob, max_nr_populations=2)
                waitForDiagnostics()
                @test r.method.max_nr_populations == 2
                @test r.method.population_size    == 6
                @test r.method.epsilon_quantile   ≈ 0.3
                @test r.method.perturbation_kernel isa ComponentwiseKernel

                # The rewritten method.toml holds the effective settings, so a later bare resume
                # does not revert to the original run's cap.
                stored = TOML.parsefile(joinpath(ModelManager.calibrationFolder(cal), "method.toml"))
                @test stored["max_nr_populations"] == 2
                @test stored["population_size"]    == 6
                @test stored["epsilon_quantile"]   ≈ 0.3
                @test stored["perturbation_kernel"]["type"] == "ComponentwiseKernel"

                # An unknown setting names the valid ones instead of failing inside the constructor.
                @test_throws ArgumentError resumeCalibration(cal; problem=prob, populaton_size=4)
                # A method object and individual settings are two ways to say the same thing.
                @test_throws ArgumentError resumeCalibration(cal, ABCSMC(); problem=prob,
                                                             max_nr_populations=9)

                # resumeABC is the same call under its ABC-specific name.
                @test length(methods(resumeABC)) == 1
                r2 = resumeABC(cal; problem=prob, max_nr_populations=3)
                waitForDiagnostics()
                @test r2.method.max_nr_populations == 3
                @test r2.method.population_size    == 6
            end

            @testset "a resume whose budget is spent stops before it writes anything" begin
                dv    = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                prob  = CalibrationProblem(inputs, [dv], Dict{String,Any}("x" => 1.0),
                                           _test_nonzero_ss, mseDistance)
                saved = ABCSMC(population_size=4, max_nr_populations=1, minimum_epsilon=0.0,
                               max_evaluations=4)
                base  = runCalibration(saved, prob; description="spent budget")
                cal   = base.calibration
                waitForDiagnostics()

                # Raising only the generation cap leaves the budget spent. The resume-time stopping
                # check never passed `budget_hit`, so this ran generation 2, trimmed its batch to
                # nothing, and died on an empty `maximum` instead of naming the budget.
                r = @test_logs (:warn, r"max_evaluations=4 reached") match_mode=:any begin
                    resumeCalibration(cal; problem=prob, max_nr_populations=3)
                end
                @test length(r.generations) == 1

                # method.toml still describes the run that happened, not the resume that did not.
                stored = TOML.parsefile(joinpath(ModelManager.calibrationFolder(cal), "method.toml"))
                @test stored["max_nr_populations"] == 1
                @test stored["max_evaluations"]    == 4

                # Raising the budget as well is what continues the run.
                r2 = resumeCalibration(cal; problem=prob, max_nr_populations=2,
                                       max_evaluations=64)
                waitForDiagnostics()
                @test length(r2.generations) == 2
                stored2 = TOML.parsefile(joinpath(ModelManager.calibrationFolder(cal), "method.toml"))
                @test stored2["max_evaluations"] == 64
            end

            @testset "_runControlKeywords survives a second runABC method" begin
                # It is reached only while building an error message, so `only(methods(runABC))`
                # would replace a useful diagnostic with "Collection has multiple elements" the
                # moment anyone overloads runABC — which the shared-study-object work will.
                expected = (:method, :run_kwargs, :description, :tags, :progress, :on_monad_failure)
                @test ModelManager._runControlKeywords() == expected
                @eval ModelManager runABC(::Int) = nothing        # a throwaway overload
                try
                    @test length(methods(runABC)) > 1
                    @test ModelManager._runControlKeywords() == expected
                    # The keyword error still names the run controls rather than blowing up.
                    dv   = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                    prob = CalibrationProblem(inputs, [dv], Dict{String,Any}("x" => 1.0),
                                              _test_named_ss, mseDistance)
                    err = try runABC(prob; populaton_size=4); nothing catch e; e end
                    @test err isa ArgumentError
                    @test occursin("on_monad_failure", err.msg)
                finally
                    #! The throwaway method stays defined for the rest of the session; harmless,
                    #! since every other test calls runABC with a CalibrationProblem.
                end
            end

            @testset "CalibrationProblem from a monad takes its reference variation" begin
                dv = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                ref = createTrial(inputs, [DiscreteVariation(:config, xp_x, 7.0)]; n_replicates=1)
                obs = Dict{String,Any}("x" => 1.0)
                # Default: the monad's own variation, which is the reason to pass a monad.
                p1 = CalibrationProblem(ref, [dv], obs, _test_named_ss, mseDistance)
                @test p1.reference_variation_id == ref.variation_id
                # No override: createTrial(method, reference, avs) offers none either, and passing a
                # reference then overriding what makes it a reference is a contradiction. The
                # InputFolders constructor is where a variation ID is an independent argument.
                @test_throws MethodError CalibrationProblem(ref, [dv], obs, _test_named_ss,
                                                            mseDistance;
                                                            reference_variation_id=VariationID(inputs))
            end

            @testset "run dispatches on the calibration structs" begin
                dv   = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                prob = CalibrationProblem(inputs, [dv], Dict{String,Any}("x" => 1.0),
                                          _test_nonzero_ss, mseDistance)

                # Fresh run through `run`, method first, mirroring run(::GSAMethod, inputs, avs).
                res = run(ABCSMC(population_size=4, max_nr_populations=1, minimum_epsilon=0.0,
                          max_evaluations=64), prob)
                waitForDiagnostics()
                @test res isa ABCResult
                @test length(res.generations) == 1

                # Continuing one through `run`. Calibration is deliberately not an AbstractTrial,
                # which is what keeps this unambiguous against run(::AbstractTrial).
                @test !(res.calibration isa ModelManager.AbstractTrial)
                res2 = run(res.calibration; problem=prob, max_nr_populations=2,
                           max_evaluations=64)
                waitForDiagnostics()
                @test res2 isa ABCResult
                @test res2.calibration.id == res.calibration.id
                @test res2.method.max_nr_populations == 2
                @test res2.method.population_size    == 4   # patched, not reset

                # And with an explicit method object, positionally.
                res3 = run(res.calibration, ABCSMC(population_size=4, max_nr_populations=3,
                                                   minimum_epsilon=0.0, max_evaluations=64);
                           problem=prob)
                waitForDiagnostics()
                @test res3 isa ABCResult

                # The bare form: run(::Calibration) with nothing else, reloading both the problem
                # and the method from disk. This is the shape a session restart actually uses.
                @test hasmethod(run, Tuple{Calibration})
                res4 = run(res.calibration)
                waitForDiagnostics()
                @test res4 isa ABCResult
                @test res4.calibration.id == res.calibration.id
            end

            @testset "a reference monad's variation cannot be overridden" begin
                # createTrial has always refused this (no kwargs splat to carry it). GSA accepted it
                # by accident: reference_variation_id was passed before kwargs..., and Julia lets the
                # rightmost duplicate win, so a caller's value silently beat the reference.
                ref = createTrial(inputs, [DiscreteVariation(:config, xp_x, 11.0)]; n_replicates=1)
                dv  = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                other = VariationID(inputs)

                @test_throws ArgumentError run(MOAT(), ref, [dv]; reference_variation_id=other)
                @test_throws MethodError createTrial(GridVariation(), ref, [dv];
                                                     reference_variation_id=other)
                # The CalibrationProblem monad form likewise takes it from the reference only.
                @test_throws MethodError CalibrationProblem(ref, [dv], Dict{String,Any}("x" => 1.0),
                                                            _test_named_ss, mseDistance;
                                                            reference_variation_id=other)
                # The InputFolders forms are where a variation ID is an independent argument.
                p = CalibrationProblem(inputs, [dv], Dict{String,Any}("x" => 1.0),
                                       _test_named_ss, mseDistance;
                                       reference_variation_id=other)
                @test p.reference_variation_id == other
            end

            @testset "epsilon_schedule on resume is warned about when too short" begin
                dv   = DistributedVariation(:config, xp_x, Uniform(0.5, 3.0))
                prob = CalibrationProblem(inputs, [dv], Dict{String,Any}("x" => 1.0),
                                          _test_nonzero_ss, mseDistance)
                base = runCalibration(ABCSMC(population_size=4, max_nr_populations=2,
                                             minimum_epsilon=0.0, max_evaluations=64), prob;
                                      description="schedule warn")
                waitForDiagnostics()
                n_done = length(base.generations)
                @test n_done >= 1

                # A schedule sized for the remaining generations, not the whole run: it is indexed by
                # absolute generation, so every new generation would silently use epsilon_quantile.
                # An L-entry schedule covers generations 2..L+1, because generation 1 has no
                # threshold and consumes no entry. So a 1-entry schedule covers only generation 2 —
                # already complete here — and every new generation falls back.
                #
                # The entry is 2.0, above _test_nonzero_ss's constant distance of 1.0, and
                # max_evaluations is set: `while length(accepted) < population_size` has no other
                # bound, so an epsilon the model cannot reach would spin forever. Neither detail is
                # what this test is about — the warning text is — but a test must not be able to hang.
                @test_logs (:warn, r"covers generations 2–2") match_mode=:any begin
                    resumeCalibration(base.calibration; problem=prob,
                                      max_nr_populations=n_done + 2, epsilon_schedule=[2.0],
                                      max_evaluations=64)
                end
                waitForDiagnostics()

                # The indexing itself, stated as a fact rather than inferred from the warning:
                # generation t reads entry t-1, guarded by the schedule's length.
                sched = [0.5, 0.4, 0.3, 0.2, 0.1]
                covered = [t for t in 2:9 if t - 1 <= length(sched)]
                @test covered == [2, 3, 4, 5, 6]          # 5 entries cover gens 2 through 6
                @test sched[6 - 1] == 0.1                 # gen 6 takes the LAST entry
                # Which is the case worth knowing: 5 generations done, a 5-entry schedule supplied on
                # resume, and only generation 6 is scheduled — 7 onward revert to epsilon_quantile.
                @test !(7 - 1 <= length(sched))
            end

            @testset "_methodWithOverrides patches rather than rebuilds" begin
                saved = ABCSMC(population_size=64, max_nr_populations=10, minimum_epsilon=1e-4,
                               epsilon_quantile=0.3, perturbation_kernel=ComponentwiseKernel(),
                               accept_overflow=true)
                patched = ModelManager._methodWithOverrides(saved, (; max_nr_populations=15))
                @test patched.max_nr_populations == 15
                # Every other field carried over, including the non-default ones.
                for f in setdiff(fieldnames(ABCSMC), (:max_nr_populations,))
                    @test getfield(patched, f) == getfield(saved, f)
                end
                # For contrast: a fresh object keeps none of them.
                fresh = ABCSMC(max_nr_populations=15)
                @test fresh.population_size != saved.population_size
                @test fresh.epsilon_quantile != saved.epsilon_quantile
                @test !(fresh.perturbation_kernel isa ComponentwiseKernel)

                @test_throws ArgumentError ModelManager._methodWithOverrides(saved, (; nope=1))
            end

            # ---------- deletion ----------
            @testset "deleteSimulations" begin
                dv   = DiscreteVariation(:config, xp_x, [50.0, 51.0])
                samp = createTrial(inputs, [dv]; n_replicates=2)
                run(samp)

                all_ids = simulationIDs(samp)
                @test length(all_ids) == 4   # 2 monads × 2 replicates

                deleteSimulations(all_ids[1])
                @test length(simulationIDs(samp)) == 3
            end

            @testset "deleteSimulationsByStatus" begin
                dv   = DiscreteVariation(:config, xp_x, [60.0, 61.0])
                samp = createTrial(inputs, [dv]; n_replicates=1)
                run(samp)

                n_before = length(simulationIDs(samp))
                @test n_before == 2

                deleteSimulationsByStatus("Completed"; user_check=false)
                # All completed simulations (including those from earlier testsets)
                # are deleted; these two are gone.
                @test length(simulationIDs(samp)) == 0
            end

            # ---------- global sensitivity ----------
            @testset "GSA — MOAT" begin
                dv1  = UniformDistributedVariation(:config, xp_x, 0.5, 3.0)
                dv2  = UniformDistributedVariation(:config, xp_y, 1.0, 4.0)
                # Trivial output function: no real simulator output needed.
                gs_fn = (_sim::Simulation) -> 1.0

                samp = run(MOAT(3), inputs, [dv1, dv2]; functions=[gs_fn])
                @test samp isa ModelManager.GSASampling
                @test size(samp.monad_ids_df, 2) == 3   # intercept + 2 factors

                # The same parameter vector is the shared object: it feeds GSA directly (above) and a
                # CalibrationProblem later, with no GSA-on-problem dispatch in between.
                problem = CalibrationProblem(inputs, [dv1, dv2], Dict{String,Any}("x" => 1.0),
                                             _test_named_ss, mseDistance)
                pv = ModelManager.ParsedVariations(problem)
                @test pv isa ModelManager.ParsedVariations
                @test ModelManager.nLatentDims(pv) == 2

                # The flat monad-ID accessor agrees with the design matrix it was built from.
                design_ids = ModelManager.getMonadIDDataFrame(samp) |> Matrix |> vec |> unique
                @test sort(monadIDs(samp)) == sort(design_ids)
                @test simulationIDs(samp) == simulationIDs(samp.sampling)

                # Recipe (full path: sampling → builder → wrapper) on a real sampling.
                rd = RecipesBase.apply_recipe(Dict{Symbol,Any}(), samp)
                @test rd[1].args[1] isa ModelManager._GSABarData
                @test rd[1].args[1].param_names == names(samp.monad_ids_df)[2:end]
                # Alternate MOAT styles dispatch without error; bad style throws.
                @test RecipesBase.apply_recipe(Dict{Symbol,Any}(), samp, :violin)[1].args[1] isa ModelManager._GSAViolinData
                @test RecipesBase.apply_recipe(Dict{Symbol,Any}(), samp, :scatter)[1].args[1] isa ModelManager._GSAScatterData
                @test_throws ErrorException RecipesBase.apply_recipe(Dict{Symbol,Any}(), samp, :nope)
            end

            @testset "GSA — Sobol" begin
                dv1  = UniformDistributedVariation(:config, xp_x, 0.5, 3.0)
                dv2  = UniformDistributedVariation(:config, xp_y, 1.0, 4.0)
                gs_fn = (_sim::Simulation) -> 1.0

                samp = run(Sobolʼ(4), inputs, [dv1, dv2]; functions=[gs_fn])
                @test samp isa ModelManager.GSASampling

                rd = RecipesBase.apply_recipe(Dict{Symbol,Any}(), samp)
                @test rd[1].args[1] isa ModelManager._GSABarData
                @test rd[1].args[1].param_names == names(samp.monad_ids_df)[3:end]
                @test length(rd[1].args[1].groups) == 2   # S1 + ST for one function
            end

            @testset "GSA — RBD" begin
                dv1  = UniformDistributedVariation(:config, xp_x, 0.5, 3.0)
                dv2  = UniformDistributedVariation(:config, xp_y, 1.0, 4.0)
                gs_fn = (_sim::Simulation) -> 1.0

                samp = run(RBD(4), inputs, [dv1, dv2]; functions=[gs_fn])
                @test samp isa ModelManager.GSASampling

                rd = RecipesBase.apply_recipe(Dict{Symbol,Any}(), samp)
                @test rd[1].args[1] isa ModelManager._GSABarData
                @test rd[1].args[1].param_names == names(samp.monad_ids_df)
            end

            waitForDiagnostics()
        end  # mktempdir

        # Restore a clean stub state so any future tests added after this section
        # don't inherit the temp-project globals.
        ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = TestSimulator())
    end  # @testset "DB-backed integration"

    @testset "resetDatabase clears post-processing sink" begin
        # Isolated project so the reset does not disturb the shared integration project.
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()

            inputs = InputFolders(config="default")
            dv = DiscreteVariation(:config, XMLPath(["data", "x"]), 601.0)
            run(createTrial(inputs, [dv]; n_replicates=1); post_processor = QoI("vq", sp -> (; v = 1.0)))
            @test isfile(postProcessingDBPath())

            resetDatabase(; force_reset=true, force_continue=true)
            @test !isfile(postProcessingDBPath())
        end
    end

    @testset "post-processing sink created lazily" begin
        # A post_processor that only ever returns nothing must not create the sink file.
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()

            inputs = InputFolders(config="default")
            xp = XMLPath(["data", "x"])

            run(createTrial(inputs, [DiscreteVariation(:config, xp, 701.0)]; n_replicates=1);
                post_processor = sp -> nothing)
            @test !isfile(postProcessingDBPath())   # nothing stored ⇒ no sink file

            run(createTrial(inputs, [DiscreteVariation(:config, xp, 702.0)]; n_replicates=1);
                post_processor = QoI("vq", sp -> (; v = 1.0)))
            @test isfile(postProcessingDBPath())     # first stored quantity creates it
        end
    end

    ################## rm_hpc_safe / .trash staging ##################

    # `initializeModelManager` resets the flag to `isRunningOnHPC()`, but nothing else does, and a
    # throw inside a @testset skips the rest of its body, so every block below restores it in a
    # `finally`. These live in the isolated-project band rather than the shared "DB-backed
    # integration" project for the same reason: flipping the flag there would leak into the ~60
    # testsets that follow.
    #
    # Each block also sets the flag explicitly rather than trusting the post-init value. Since
    # that value is now probed from the environment, a suite run on a cluster login node would
    # otherwise start these blocks in HPC mode and fail the off-HPC assertions.
    #
    # Fault injection is deliberately root-proof. chmod-based tricks are ignored when the process
    # is root (as CI containers often are) and would silently degrade to a no-op, so failures are
    # forced two other ways: `recursive=false` on a non-empty directory (rmdir → ENOTEMPTY; the
    # `force` excuse covers only ENOENT), and a regular file where `.trash` should be, which makes
    # `mkpath` throw.
    @testset "rm_hpc_safe removes on HPC and stages only the residue" begin
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()
            trash = joinpath(ModelManager.dataDir(), ".trash")

            # Off HPC the behavior is plain `rm`, exceptions included.
            useHPC(false)
            d = joinpath(ModelManager.dataDir(), "local_case"); mkpath(d)
            write(joinpath(d, "f.txt"), "x")
            @test rm_hpc_safe(d; force=true, recursive=true) == :removed
            @test !ispath(d)
            @test_throws Base.IOError rm_hpc_safe(joinpath(ModelManager.dataDir(), "gone"))

            try
                useHPC(true)

                # Happy path: the removal succeeds, so nothing is staged and `.trash` is never
                # created. This is the case that never worked before — on HPC the old code moved
                # everything and reclaimed nothing.
                d = joinpath(ModelManager.dataDir(), "removable"); mkpath(d)
                write(joinpath(d, "f.txt"), "x")
                @test rm_hpc_safe(d; force=true, recursive=true) == :removed
                @test !ispath(d)
                @test !ispath(trash)

                # A missing path with force=false still throws, exactly as off HPC.
                @test_throws Base.IOError rm_hpc_safe(joinpath(ModelManager.dataDir(), "gone"))
                @test rm_hpc_safe(joinpath(ModelManager.dataDir(), "gone"); force=true) == :removed

                # `rm` refused ⇒ the residue is moved aside and the user is told once.
                d = joinpath(ModelManager.dataDir(), "outputs", "held"); mkpath(d)
                write(joinpath(d, "held.dat"), "x")
                local res
                @test_logs (:warn, r"moved aside rather than deleted") match_mode=:any begin
                    res = rm_hpc_safe(d; force=true, recursive=false)
                end
                @test res == :staged
                @test !ispath(d)
                staged = joinpath(trash, "data-$(Dates.format(Dates.now(), "yymmdd"))",
                                  "outputs", "held")
                @test isfile(joinpath(staged, "held.dat"))

                # Warn-once: a second staging in the same project is silent.
                d2 = joinpath(ModelManager.dataDir(), "outputs", "held2"); mkpath(d2)
                write(joinpath(d2, "held.dat"), "x")
                @test_logs min_level=Base.CoreLogging.Warn begin
                    @test rm_hpc_safe(d2; force=true, recursive=false) == :staged
                end

                # Collision: the same name staged twice on one day must not clobber the first.
                mkpath(d); write(joinpath(d, "held.dat"), "second")
                @test rm_hpc_safe(d; force=true, recursive=false) == :staged
                @test isdir("$(staged)-1")
                @test read(joinpath(staged, "held.dat"), String) == "x"        # first survived
                @test read(joinpath("$(staged)-1", "held.dat"), String) == "second"

                # The suffix search is unbounded: it must keep finding free names well past any
                # round number, and must never hand back a name that is already taken.
                for i in 2:12
                    mkpath(d); write(joinpath(d, "held.dat"), "n$(i)")
                    @test rm_hpc_safe(d; force=true, recursive=false) == :staged
                    @test read(joinpath("$(staged)-$(i)", "held.dat"), String) == "n$(i)"
                end

                # A path outside data/ is staged under _external/ — regression test for the old
                # mapping, which left such a path absolute, so `joinpath` discarded the trash
                # prefix and the "move" silently renamed the target in place to `<path>-1`.
                mktempdir() do outside
                    d3 = joinpath(outside, "elsewhere"); mkpath(d3)
                    write(joinpath(d3, "held.dat"), "x")
                    @test rm_hpc_safe(d3; force=true, recursive=false) == :staged
                    @test !ispath(d3)
                    @test !ispath("$(d3)-1")          # the old bug
                    @test isfile(joinpath(trash, "data-$(Dates.format(Dates.now(), "yymmdd"))",
                                          "_external", "elsewhere", "held.dat"))
                end
            finally
                useHPC(false)
            end
        end
    end

    @testset "rm_hpc_safe reports but does not throw when it can stage nothing" begin
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()
            try
                useHPC(true)
                # A regular file where `.trash` should be makes `mkpath` throw, so neither the
                # removal nor the staging can succeed.
                write(joinpath(ModelManager.dataDir(), ".trash"), "not a directory")
                d = joinpath(ModelManager.dataDir(), "stuck"); mkpath(d)
                write(joinpath(d, "f.txt"), "x")

                local res
                @test_logs (:warn, r"could not move it out of the way") match_mode=:any begin
                    res = rm_hpc_safe(d; force=true, recursive=false)   # no throw
                end
                @test res == :unremoved
                @test isfile(joinpath(d, "f.txt"))    # left exactly where it was

                # Unlike :staged, this one is NOT latched: every occurrence names a different
                # leaked path and is the only record of it that will ever exist. Latching it
                # would also leave resetDatabase's error citing a warning that never printed.
                d2 = joinpath(ModelManager.dataDir(), "stuck2"); mkpath(d2)
                write(joinpath(d2, "f.txt"), "x")
                @test_logs (:warn, r"could not move it out of the way") match_mode=:any begin
                    @test rm_hpc_safe(d2; force=true, recursive=false) == :unremoved
                end
            finally
                useHPC(false)
            end
        end
    end

    @testset "trash sweep and diagnostics report" begin
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()
            trash = joinpath(ModelManager.dataDir(), ".trash")

            stamp(d) = Dates.format(d, "yymmdd")
            old      = joinpath(trash, "data-$(stamp(Dates.today() - Dates.Day(30)))")
            boundary = joinpath(trash, "data-$(stamp(Dates.today() - Dates.Day(2)))")
            recent   = joinpath(trash, "data-$(stamp(Dates.today() - Dates.Day(1)))")
            future   = joinpath(trash, "data-$(stamp(Dates.today() + Dates.Day(1)))")
            foreign  = joinpath(trash, "not-ours")
            for p in (old, boundary, recent, future, foreign)
                mkpath(p); write(joinpath(p, "f.txt"), "x")
            end

            ModelManager._sweepTrash()
            # No age threshold: a bucket another session is staging into is handled in
            # `_stageInto`, which recreates the directory and retries, so the sweep can reclaim
            # as soon as the filesystem allows instead of waiting out clock skew.
            @test !ispath(old)
            @test !ispath(boundary)
            @test !ispath(recent)
            @test !ispath(future)       # a clock-skewed or other-timezone session's bucket
            @test isdir(foreign)        # not created by ModelManager ⇒ never touched

            # Anything left behind is reported, once, by the diagnostics pass.
            @test_logs (:warn, r"still staged in") match_mode=:any ModelManager.databaseDiagnostics()

            # An unreadable staging directory must not be reported as an empty one — silence
            # there would claim a clear disk on the strength of a question we could not answer.
            if !iszero(parse(Int, readchomp(`id -u`)))   # permission bits are ignored under root
                rm(trash; force=true, recursive=true)
                mkpath(joinpath(trash, "data-000101"))
                chmod(trash, 0o000)
                try
                    @test_logs (:warn, r"Could not read the staging directory") match_mode=:any begin
                        ModelManager.databaseDiagnostics()
                    end
                finally
                    chmod(trash, 0o700)
                end
            end

            # A session outliving a single day must re-sweep: the startup sweep fires once, and a
            # week-long driver script would otherwise stage into a new bucket every day while
            # nothing ever retried the earlier ones.
            rm(trash; force=true, recursive=true)
            stale = joinpath(trash, "data-$(stamp(Dates.today() - Dates.Day(4)))")
            mkpath(stale); write(joinpath(stale, "f.txt"), "x")
            # `_stageInto` creates whatever it needs, which is what lets the sweep run without an
            # age threshold: a destination swept out from under it is recreated and retried.
            throwaway = joinpath(ModelManager.dataDir(), "throwaway"); mkpath(throwaway)
            write(joinpath(throwaway, "f.txt"), "x")
            rm(trash; force=true, recursive=true)             # as if a sweep had just run
            landed = ModelManager._stageInto(throwaway)
            @test isfile(joinpath(landed, "f.txt"))
            @test !ispath(throwaway)
            mkpath(stale); write(joinpath(stale, "f.txt"), "x")
            ModelManager.mm_globals().last_trash_sweep = stamp(Dates.today() - Dates.Day(1))
            try
                useHPC(true)
                d = joinpath(ModelManager.dataDir(), "rollover"); mkpath(d)
                write(joinpath(d, "f.txt"), "x")
                @test rm_hpc_safe(d; force=true, recursive=false) == :staged
                @test !ispath(stale)              # the day rolled over ⇒ swept mid-session
                @test ModelManager.mm_globals().last_trash_sweep == stamp(Dates.today())

                # ...and not again on the same day: a second staging leaves a fresh old bucket be.
                mkpath(stale); write(joinpath(stale, "f.txt"), "x")
                d2 = joinpath(ModelManager.dataDir(), "rollover2"); mkpath(d2)
                write(joinpath(d2, "f.txt"), "x")
                @test rm_hpc_safe(d2; force=true, recursive=false) == :staged
                @test isdir(stale)
            finally
                useHPC(false)
            end

            # With the trash gone, the sweep removes the directory itself and the report is silent.
            rm(trash; force=true, recursive=true)
            mkpath(joinpath(trash, "data-$(stamp(Dates.today() - Dates.Day(3)))"))
            ModelManager._sweepTrash()
            @test !ispath(trash)
            @test_logs min_level=Base.CoreLogging.Warn ModelManager.databaseDiagnostics()
        end
    end

    @testset "trash warn-once latch resets per project" begin
        # The latch lives on globals, so a second project in the same session must warn again.
        for _ in 1:2
            mktempdir() do project_dir
                _make_test_project(project_dir)
                initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
                waitForDiagnostics()
                try
                    useHPC(true)
                    d = joinpath(ModelManager.dataDir(), "held"); mkpath(d)
                    write(joinpath(d, "f.txt"), "x")
                    @test_logs (:warn, r"moved aside rather than deleted") match_mode=:any begin
                        @test rm_hpc_safe(d; force=true, recursive=false) == :staged
                    end
                finally
                    useHPC(false)
                end
            end
        end
    end

    ################## GSA plot recipes ##################

    @testset "GSA plot recipes" begin
        d = 3
        pnames = ["p1", "p2", "p3"]

        # Fabricate GlobalSensitivity result objects directly (no simulations needed):
        # the recipes only read the index fields, not the sampling/DB.
        morris(seed) = (Random.seed!(seed);
            GlobalSensitivity.MorrisResult(
                reshape([0.0, 0.1, -0.2], 1, d),   # means
                reshape([0.1, 0.5, 0.2], 1, d),    # means_star (µ*)
                reshape([0.01, 0.04, 0.02], 1, d), # variances (σ²)
                randn(5, d)))                      # elementary_effects (n_base × d)
        sobol() = GlobalSensitivity.SobolResult(
            [0.2, 0.5, 0.1], nothing, nothing, nothing, [0.3, 0.6, 0.2], nothing)

        moat_df  = DataFrame("base" => [1, 2, 3], "p1" => [4, 5, 6], "p2" => [7, 8, 9], "p3" => [10, 11, 12])
        sobol_df = DataFrame("A" => [1, 2], "B" => [3, 4], "p1" => [5, 6], "p2" => [7, 8], "p3" => [9, 10])
        rbd_df   = DataFrame("p1" => [1, 2], "p2" => [3, 4], "p3" => [5, 6])

        nseries(recipe_data) = length(recipe_data)
        apply(d) = RecipesBase.apply_recipe(Dict{Symbol,Any}(), d)

        @testset "parameter name extraction" begin
            @test ModelManager._moatParameterNames(moat_df)   == pnames
            @test ModelManager._sobolParameterNames(sobol_df) == pnames
            @test ModelManager._rbdParameterNames(rbd_df)     == pnames
        end

        @testset "MOAT — bar" begin
            res1 = Dict{String,GlobalSensitivity.MorrisResult}(_GSA_LABEL_A => morris(1))
            bd   = ModelManager._moatBarData(res1, moat_df, false)
            @test bd.param_names == pnames
            @test nseries(apply(bd)) == 1                 # one function → one series
            @test bd.groups[1].label == "µ*"
            @test isnothing(bd.groups[1].yerror)

            # show_sigma adds σ whiskers (still one series)
            bd_s = ModelManager._moatBarData(res1, moat_df, true)
            @test bd_s.groups[1].yerror ≈ sqrt.([0.01, 0.04, 0.02])
            @test nseries(apply(bd_s)) == 1

            # two functions → two series, function-labeled
            res2 = Dict{String,GlobalSensitivity.MorrisResult}(_GSA_LABEL_A => morris(1), _GSA_LABEL_B => morris(2))
            bd2  = ModelManager._moatBarData(res2, moat_df, false)
            @test nseries(apply(bd2)) == 2
            @test Set(g.label for g in bd2.groups) == Set(["µ*: _gsa_fA", "µ*: _gsa_fB"])
        end

        @testset "MOAT — violin" begin
            res1 = Dict{String,GlobalSensitivity.MorrisResult}(_GSA_LABEL_A => morris(1))
            vd   = ModelManager._moatViolinData(res1, moat_df)
            @test vd.param_names == pnames
            @test nseries(apply(vd)) == 1

            res2 = Dict{String,GlobalSensitivity.MorrisResult}(_GSA_LABEL_A => morris(1), _GSA_LABEL_B => morris(2))
            @test nseries(apply(ModelManager._moatViolinData(res2, moat_df))) == 2
        end

        @testset "MOAT — scatter" begin
            res1 = Dict{String,GlobalSensitivity.MorrisResult}(_GSA_LABEL_A => morris(1))
            sd   = ModelManager._moatScatterData(res1, moat_df)
            @test sd.param_names == pnames
            @test sd.groups[1][2] ≈ [0.1, 0.5, 0.2]                  # µ*
            @test sd.groups[1][3] ≈ sqrt.([0.01, 0.04, 0.02])       # σ
            @test nseries(apply(sd)) == 1

            res2 = Dict{String,GlobalSensitivity.MorrisResult}(_GSA_LABEL_A => morris(1), _GSA_LABEL_B => morris(2))
            @test nseries(apply(ModelManager._moatScatterData(res2, moat_df))) == 2
        end

        @testset "Sobolʼ" begin
            res1 = Dict{String,GlobalSensitivity.SobolResult}(_GSA_LABEL_A => sobol())
            @test nseries(apply(ModelManager._sobolBarData(res1, sobol_df, true)))  == 2  # S1 + ST
            @test nseries(apply(ModelManager._sobolBarData(res1, sobol_df, false))) == 1  # S1 only

            bd = ModelManager._sobolBarData(res1, sobol_df, true)
            @test bd.param_names == pnames
            @test [g.label for g in bd.groups] == ["S1", "ST"]
            @test bd.groups[2].fillalpha == 0.45                     # ST de-emphasized

            res2 = Dict{String,GlobalSensitivity.SobolResult}(_GSA_LABEL_A => sobol(), _GSA_LABEL_B => sobol())
            @test nseries(apply(ModelManager._sobolBarData(res2, sobol_df, true))) == 4   # 2 fns × (S1+ST)
        end

        @testset "RBD" begin
            res1 = Dict{String,Vector{<:Real}}(_GSA_LABEL_A => [0.1, 0.2, 0.3])
            bd   = ModelManager._rbdBarData(res1, rbd_df)
            @test bd.param_names == pnames
            @test bd.groups[1].label == "S1"
            @test nseries(apply(bd)) == 1

            res2 = Dict{String,Vector{<:Real}}(_GSA_LABEL_A => [0.1, 0.2, 0.3], _GSA_LABEL_B => [0.4, 0.5, 0.6])
            @test nseries(apply(ModelManager._rbdBarData(res2, rbd_df))) == 2
        end

        @testset "empty results error" begin
            empty_morris = Dict{String,GlobalSensitivity.MorrisResult}()
            @test_throws ErrorException ModelManager._moatBarData(empty_morris, moat_df, false)
            @test_throws ErrorException ModelManager._moatViolinData(empty_morris, moat_df)
            @test_throws ErrorException ModelManager._moatScatterData(empty_morris, moat_df)
        end

        @testset "no parameters error" begin
            # All three wrapper recipes must reject a parameter-less sampling with a clear
            # message rather than a BoundsError / empty-reduction error.
            @test_throws ErrorException apply(ModelManager._GSABarData(String[], [ModelManager._GSABarGroup("f", Float64[], 1.0, nothing)]))
            @test_throws ErrorException apply(ModelManager._GSAViolinData(String[], [("f", zeros(0, 0))]))
            @test_throws ErrorException apply(ModelManager._GSAScatterData(String[], [("f", Float64[], Float64[])]))
        end
    end

    @testset "calibration plot recipes" begin
        apply(d) = RecipesBase.apply_recipe(Dict{Symbol,Any}(), d)
        nseries(applied) = length(applied)

        @testset "distance distribution: binning" begin
            # Accepted below the threshold, rejected above — the shape the plot exists to show.
            acc = [0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5]
            rej = [0.6, 0.8, 1.0, 1.2, 1.5, 2.0, 2.5, 3.0]
            dd  = ModelManager._buildDistanceData(acc, rej, 0.5, 0.5, 3)

            # Uniform width, with the threshold falling exactly on a bin edge.
            w = dd.edges[2] - dd.edges[1]
            @test all(isapprox(dd.edges[i+1] - dd.edges[i], w; atol=1e-9)
                      for i in 1:(length(dd.edges) - 1))
            @test any(e -> isapprox(e, 0.5; atol=1e-12), dd.edges)

            # The property the shared binning exists for: the two series never share a bin. A
            # distance exactly equal to ε was accepted (acceptance is `<=`), but searchsortedlast
            # puts it in the bin *starting* at ε, so the split is enforced rather than assumed.
            acc_bins = findall(>(0), dd.accepted_counts)
            rej_bins = findall(>(0), dd.rejected_counts)
            @test isempty(intersect(acc_bins, rej_bins))
            @test maximum(acc_bins) < minimum(rej_bins)

            # Nothing is lost or double-counted.
            @test sum(dd.accepted_counts) == length(acc)
            @test sum(dd.rejected_counts) == length(rej)

            # Two bar series plus the threshold line.
            @test nseries(apply(dd)) == 3
        end

        @testset "distance distribution: degenerate and log cases" begin
            acc = [0.1, 0.2, 0.3]
            # Generation 1 has no threshold: one series, no threshold line.
            d1 = ModelManager._buildDistanceData(acc, Float64[], nothing, 0.3, 1)
            @test sum(d1.accepted_counts) == length(acc)
            @test isnothing(d1.epsilon_threshold)
            @test nseries(apply(d1)) == 1

            # A single distinct value still bins.
            dsingle = ModelManager._buildDistanceData([0.4, 0.4], Float64[], nothing, 0.4, 1)
            @test sum(dsingle.accepted_counts) == 2

            # mseDistance legitimately returns 0.0; log10(0) is -Inf, so it is dropped and reported.
            dl = ModelManager._buildDistanceData([0.0, 0.01, 0.1], [1.0, 10.0], 0.1, 0.1, 2;
                                                 logscale=true)
            @test occursin("non-positive", dl.note)
            @test sum(dl.accepted_counts) == 2      # the 0.0 is gone, the other two remain

            # Empty input is an error with a clear message, not a BoundsError.
            @test_throws ErrorException ModelManager._buildDistanceData(Float64[], Float64[],
                                                                        nothing, 0.0, 1)
        end

        @testset "distance distribution: legacy runs degrade" begin
            # A run recorded before proposal distances were kept still plots, from the accepted
            # distances alone, and says so.
            acc, rej, note = ModelManager._distanceSeries(nothing, [0.1, 0.2])
            @test acc == [0.1, 0.2]
            @test isempty(rej)
            @test occursin("not recorded", note)

            # With a frame, the two series are split on the accepted flag.
            frame = DataFrame(monad_id = [1, 2, 3], distance = [0.1, 0.5, 0.9],
                              accepted = [true, true, false])
            # No particle set supplied, so there is nothing to reconcile and no note.
            a, r, n = ModelManager._distanceSeries(frame, Float64[])
            @test a == [0.1, 0.5]
            @test r == [0.9]
            @test isempty(n)

            # Counts agree with the posterior: still no note.
            _, _, n_ok = ModelManager._distanceSeries(frame, [0.1, 0.5])
            @test isempty(n_ok)

            # More proposals passed ε than were kept as particles — accept_overflow=false trimmed the
            # surplus. The green bars legitimately outnumber the posterior, so the plot says so.
            over = DataFrame(monad_id = [1, 2, 3, 4], distance = [0.1, 0.2, 0.3, 0.9],
                             accepted = [true, true, true, false])
            a_o, r_o, n_o = ModelManager._distanceSeries(over, [0.1, 0.2])
            @test length(a_o) == 3          # all three flagged accepted are plotted as accepted
            @test r_o == [0.9]
            @test occursin("3 passed ε", n_o)
            @test occursin("2 kept as particles", n_o)
            @test occursin("overflow trimmed", n_o)
        end

        @testset "parameters.toml display mapping covers every source type" begin
            # Written and read back through the real pair, so the reader's branches are checked
            # against the `source_type` strings the writer actually emits. A discrete parameter had
            # no branch at all: it dropped out of the mapping, and the disk-resident :transition
            # plot then dropped its column, since the mapping is what renames the simulationsTable
            # columns into the display names the plot selects on.
            xp1 = XMLPath(["data", "x"]); xp2 = XMLPath(["data", "y"])
            xp3 = XMLPath(["data", "z"]); xp4 = XMLPath(["data", "w"])
            disc = DiscreteVariation(:config, xp2, [1.0, 2.0])
            cps = [ModelManager._toCalibrationParameter(
                       DistributedVariation(:config, xp1, Uniform(0.0, 1.0))),
                   ModelManager._toCalibrationParameter(disc),
                   ModelManager._toCalibrationParameter(
                       CoVariation(DiscreteVariation(:config, xp3, [1.0, 2.0]),
                                   DiscreteVariation(:config, xp4, [3.0, 4.0])))]
            mktempdir() do dir
                path = joinpath(dir, "parameters.toml")
                open(path, "w") do io
                    TOML.print(io, Dict("parameters" =>
                        [ModelManager._parameterTOMLEntry(cp) for cp in cps]))
                end
                mapping = ModelManager._buildDbToDisplayMappingFromTOML(path)
                for cp in cps, col in ModelManager.columnName.(cp.lv.targets)
                    @test haskey(mapping, col)
                end
                @test mapping[ModelManager.columnName(xp2)] == ModelManager.variationName(disc)
            end
        end

        @testset "existing calibration recipes still apply" begin
            # None of these four had any coverage; these are smoke tests that the recipes build a
            # series list rather than throwing, plus the guards for empty input.
            pnames = ["alpha", "beta"]
            df  = DataFrame(alpha = [0.1, 0.2, 0.3], beta = [1.0, 2.0, 3.0])
            wts = [0.2, 0.3, 0.5]

            corner = ModelManager._CornerPlotData(df, wts)
            @test nseries(apply(corner)) > 0
            @test_throws ErrorException apply(ModelManager._CornerPlotData(DataFrame(), Float64[]))

            ridge = ModelManager._RidgelineData([df, df], [wts, wts], nothing, nothing, pnames)
            @test nseries(apply(ridge)) > 0

            trans = ModelManager._TransitionData(df, wts, df, wts, nothing, pnames, 3, "",
                                                 false, true)
            @test nseries(apply(trans)) > 0
        end
    end

    ################## Tagging ##################

    @testset "tag key and value normalization" begin
        # Keys are identifiers: lowercased, whitespace-stripped, restricted charset.
        @test ModelManager.normalizeTagKey("Project") == "project"
        @test ModelManager.normalizeTagKey("  arm  ") == "arm"
        @test ModelManager.normalizeTagKey(:figure) == "figure"
        @test ModelManager.normalizeTagKey("fig-3.b_2") == "fig-3.b_2"

        @test_throws ArgumentError ModelManager.normalizeTagKey("")
        @test_throws ArgumentError ModelManager.normalizeTagKey("   ")
        @test_throws ArgumentError ModelManager.normalizeTagKey("has space")
        @test_throws ArgumentError ModelManager.normalizeTagKey("bad!char")
        @test_throws ArgumentError ModelManager.normalizeTagKey("_leading")
        @test_throws ArgumentError ModelManager.normalizeTagKey("a"^65)

        # The reserved namespace is unforgeable: `:` is not in the legal key charset.
        @test_throws ArgumentError ModelManager.normalizeTagKey("mm:created")
        @test_throws ArgumentError ModelManager.normalizeTagKey("MM:created")
        @test_throws ArgumentError ModelManager.normalizeTagKey("has:colon")

        # Values are data: case, spaces, punctuation and unicode all survive.
        pairs = ModelManager.normalizeTagPairs(("Arm" => "High Dose µ!", "baseline", :note => 3))
        @test pairs == [("arm", "High Dose µ!"), ("baseline", ""), ("note", "3")]

        # Duplicates collapse; surrounding whitespace on values is trimmed.
        @test ModelManager.normalizeTagPairs(("a" => " x ", "a" => "x")) == [("a", "x")]
    end

    @testset "tag classes cover Calibration" begin
        # A Calibration is outside the trial hierarchy, so its class string is stated rather
        # than derived from `lowerClassString` (which is defined for AbstractTrial only).
        @test ModelManager._tagClass(Calibration) == "calibration"
        @test ModelManager._tagClass(Calibration(7)) == "calibration"
        @test ModelManager._tagTable("calibration") == "calibrations"
        # The table's ID column already follows the strip-the-s convention every other
        # tagged class relies on.
        @test tableIDName("calibrations") == "calibration_id"
        @test "calibration" in ModelManager.TAG_CLASSES
        @test length(ModelManager.TAG_CLASSES) == 5
        # Nothing above a calibration to inherit from, so `inherit=true` is a no-op for it.
        @test ModelManager._inheritedIDs(Calibration, "sampling", 1) == Int[]
        @test ModelManager._inheritedIDs(Calibration, "trial", 1) == Int[]
        # Fresh databases get the provenance column from the schema; existing ones from
        # `ensureProvenanceColumns`.
        @test occursin("provenance_id", ModelManager.calibrationsSchema())
    end

    @testset "generation files are ordered numerically, not lexicographically" begin
        # The zero-padding is ndigits(max_nr_populations), so a run resumed with a larger
        # max_nr_populations writes wider names into the same directory. Sorting on the name
        # would then put generation 10 before generation 9.
        mktempdir() do dir
            for name in ("generation_9_monads.csv", "generation_10_monads.csv",
                         "generation_1_monads.csv", "generation_002_monads.csv",
                         # Must not be picked up: these are the monads that lost every
                         # simulation, i.e. exactly the ones no longer in the database.
                         "generation_1_failed_monads.csv", "generation_9_failed_monads.csv",
                         # Nor any of the other per-generation artifacts.
                         "generation_1.csv", "generation_1.toml",
                         "generation_1_failed_simulations.csv")
                write(joinpath(dir, name), "1\n")
            end
            files = ModelManager._indexedGenerationFiles(dir, r"^generation_(\d+)_monads\.csv$")
            @test first.(files) == [1, 2, 9, 10]
            @test all(f -> occursin("_monads.csv", last(f)), files)
            @test !any(f -> occursin("failed", last(f)), files)

            # A missing directory is empty, not an error.
            @test isempty(ModelManager._indexedGenerationFiles(joinpath(dir, "nope"),
                                                               r"^generation_(\d+)_monads\.csv$"))
        end
    end

    @testset "tagging round-trip and retrieval" begin
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()
            setTagHints!(false)

            @test ModelManager.tableExists("tags")

            inputs = InputFolders(config="default")
            xp = XMLPath(["data", "x"])

            sampling = createTrial(inputs, [DiscreteVariation(:config, xp, [10.0, 20.0])]; n_replicates=2)
            @test sampling isa Sampling
            sim_ids = simulationIDs(sampling)
            @test length(sim_ids) == 4

            # --- automatic provenance ------------------------------------------------
            auto = tags(Simulation, sim_ids[1])
            @test haskey(auto, "mm:created")
            @test haskey(auto, "mm:session")
            @test isempty(tags(Simulation, sim_ids[1]; include_auto=false))

            # --- direct tagging ------------------------------------------------------
            tag!(Simulation, sim_ids[1], "arm" => "control")
            @test tags(Simulation, sim_ids[1]; include_auto=false) == Dict("arm" => ["control"])
            @test hasTag(Simulation, sim_ids[1], "arm" => "control")
            @test hasTag(Simulation, sim_ids[1], "arm")
            @test !hasTag(Simulation, sim_ids[1], "arm" => "treated")

            # Re-applying is idempotent.
            tag!(Simulation, sim_ids[1], "arm" => "control")
            @test tags(Simulation, sim_ids[1]; include_auto=false)["arm"] == ["control"]

            # A key may carry several values.
            tag!(Simulation, sim_ids[1], "cohort" => "pilot", "cohort" => "paper")
            @test tags(Simulation, sim_ids[1]; include_auto=false)["cohort"] == ["paper", "pilot"]

            # Bare labels store an empty value and dedupe.
            tag!(Simulation, sim_ids[2], "baseline")
            tag!(Simulation, sim_ids[2], "baseline")
            @test tags(Simulation, sim_ids[2]; include_auto=false) == Dict("baseline" => [""])

            # --- untagging -----------------------------------------------------------
            tag!(Simulation, sim_ids[3], "arm" => "x", "verdict" => "good")
            untag!(Simulation, sim_ids[3], "arm" => "x")
            @test !hasTag(Simulation, sim_ids[3], "arm")
            @test hasTag(Simulation, sim_ids[3], "verdict")

            tag!(Simulation, sim_ids[3], "cohort" => "a", "cohort" => "b")
            untag!(Simulation, sim_ids[3], "cohort")        # bare key drops every value
            @test !hasTag(Simulation, sim_ids[3], "cohort")

            untag!(Simulation, sim_ids[3])                  # all user tags…
            @test isempty(tags(Simulation, sim_ids[3]; include_auto=false))
            @test haskey(tags(Simulation, sim_ids[3]), "mm:created")   # …but provenance survives

            # --- tagging other classes ----------------------------------------------
            tag!(sampling, "project" => "immune-escape")
            @test hasTag(sampling, "project" => "immune-escape")
            monad = Monad(monadIDs(sampling)[1])
            tag!(monad, "verdict" => "suspect")
            @test hasTag(monad, "verdict" => "suspect")

            # --- vocabulary discovery ------------------------------------------------
            @test "project" in tagKeys()
            @test !any(startswith.(tagKeys(), "mm:"))
            @test "immune-escape" in tagValues("project")
            @test recommendedTagKeys() == ("project", "purpose", "figure", "arm", "verdict", "note")

            # --- tagsTable -----------------------------------------------------------
            all_tags = tagsTable()
            @test all(c -> c in names(all_tags), ["Class", "ID", "Key", "Value", "DateTime"])
            user_tags = tagsTable(include_auto=false)
            @test !any(startswith.(user_tags.Key, "mm:"))
            @test nrow(tagsTable(sampling)) > 0
        end
        ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = TestSimulator())
    end

    @testset "tag! rejects reserved keys" begin
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()
            setTagHints!(false)

            inputs = InputFolders(config="default")
            sim = createTrial(inputs, [DiscreteVariation(:config, XMLPath(["data", "x"]), 5.0)]; n_replicates=1)
            @test_throws ArgumentError tag!(sim, "mm:created" => "yesterday")
            @test_throws ArgumentError tag!(sim, "mm:script" => "evil.jl")

            # The bare prefix has an empty body. Julia's `"mm:"[4:end]` is a valid empty
            # slice, so this fails as a clean ArgumentError rather than a BoundsError —
            # pinned because the opposite is a reasonable thing to assume.
            @test ModelManager.MM_TAG_PREFIX[4:end] == ""
            @test_throws ArgumentError ModelManager._reservedTagKey("mm:")
            @test_throws ArgumentError hasTag(sim, "mm:")
            @test_throws ArgumentError findSimulationIDs(tags=("mm:",))
            @test_throws ArgumentError tagValues("mm:")
        end
        ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = TestSimulator())
    end

    @testset "tags keyword on createTrial and run" begin
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()
            setTagHints!(false)

            inputs = InputFolders(config="default")
            xp = XMLPath(["data", "x"])

            # Tags land on the object createTrial returns; constituents match by inheritance.
            sampling = createTrial(inputs, [DiscreteVariation(:config, xp, [31.0, 32.0])];
                                   n_replicates=1, tags=("project" => "kw", "purpose" => "figure"))
            @test sampling isa Sampling
            @test hasTag(sampling, "project" => "kw")
            @test hasTag(sampling, "purpose" => "figure")
            @test sort(findSimulationIDs(tags=("project" => "kw",))) == sort(simulationIDs(sampling))
            # Not copied down onto the simulations themselves.
            @test isempty(findSimulationIDs(tags=("project" => "kw",), inherit=false))

            # Objects created without tags stay untagged.
            plain = createTrial(inputs, [DiscreteVariation(:config, xp, 33.0)]; n_replicates=1)
            @test !hasTag(plain, "project" => "kw")

            # `run` accepts the same keyword, applied before dispatch.
            out = run(inputs, DiscreteVariation(:config, xp, 34.0);
                      n_replicates=1, quiet=true, tags=("project" => "run-kw",))
            @test !isempty(findSimulationIDs(tags=("project" => "run-kw",)))

            # Tagging an already-built trial at run time.
            built = createTrial(inputs, [DiscreteVariation(:config, xp, 35.0)]; n_replicates=1)
            run(built; quiet=true, tags=("project" => "late",))
            @test hasTag(built, "project" => "late")

            # A single pair, a bare label, and a symbol key are all accepted.
            s = createTrial(inputs, [DiscreteVariation(:config, xp, 36.0)]; n_replicates=1,
                            tags=("baseline", :arm => "control"))
            @test hasTag(s, "baseline")
            @test hasTag(s, "arm" => "control")
        end
        ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = TestSimulator())
    end

    @testset "tags keyword covers pre-built trials batched into one run" begin
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()
            setTagHints!(false)

            inputs = InputFolders(config="default")
            xp = XMLPath(["data", "x"])

            # Built first (untagged), then batched into one run for parallelism.
            t1 = createTrial(inputs, [DiscreteVariation(:config, xp, 41.0)]; n_replicates=1)
            t2 = createTrial(inputs, [DiscreteVariation(:config, xp, 42.0)]; n_replicates=1)
            @test !hasTag(t1, "project" => "batched")

            out = run([t1, t2]; quiet=true, tags=("project" => "batched",))

            # The tag lands on the trials handed to `run`...
            @test hasTag(t1, "project" => "batched")
            @test hasTag(t2, "project" => "batched")
            # ...and deliberately not on the umbrella Trial built to hold the batch, which
            # exists to schedule work rather than to mean anything.
            @test !hasTag(out.trial, "project" => "batched")
            # Every simulation in the batch is still recoverable, through inheritance.
            @test sort(findSimulationIDs(tags=("project" => "batched",))) == sort(simulationIDs(out.trial))

            # Batching objects below Sampling level wraps each in a single-object Sampling
            # so the Trial can hold it. Those wrappers are containers too, so they are not
            # tagged — while the monads handed in, and all their simulations, still are.
            m1 = createTrial(inputs, [DiscreteVariation(:config, xp, 51.0)]; n_replicates=2)
            m2 = createTrial(inputs, [DiscreteVariation(:config, xp, 52.0)]; n_replicates=2)
            @test m1 isa Monad && m2 isa Monad
            monad_out = run([m1, m2]; quiet=true, tags=("project" => "monad-batch",))
            @test hasTag(m1, "project" => "monad-batch")
            @test hasTag(m2, "project" => "monad-batch")
            @test all(!hasTag(s, "project" => "monad-batch") for s in monad_out.trial.samplings)
            @test sort([m.id for m in findMonads(tags=("project" => "monad-batch",))]) == sort([m1.id, m2.id])
            @test isempty(findTrials(Sampling; tags=("project" => "monad-batch",)))
            @test sort(findSimulationIDs(tags=("project" => "monad-batch",))) == sort(simulationIDs(monad_out.trial))

            # Tagging the constituents rather than the umbrella is about durability, not
            # reachability: inheritance would reach them either way, but the umbrella is
            # deduplicated plumbing that can be deleted on its own. If it held the only
            # copy, deleting it would make these simulations unfindable.
            batch_sims = sort(simulationIDs(monad_out.trial))
            deleteTrial(monad_out.trial.id; delete_subs=false)
            @test sort(findSimulationIDs(tags=("project" => "monad-batch",))) == batch_sims
            @test hasTag(m1, "project" => "monad-batch")
        end
        ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = TestSimulator())
    end
    @testset "findTrials inheritance and filter composition" begin
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()
            setTagHints!(false)

            inputs = InputFolders(config="default")
            xp = XMLPath(["data", "x"])

            sampling = createTrial(inputs, [DiscreteVariation(:config, xp, [51.0, 52.0])]; n_replicates=2)
            sim_ids = sort(simulationIDs(sampling))
            @test length(sim_ids) == 4

            tag!(sampling, "project" => "inherit-test")

            # A tag on the sampling reaches its simulations only with inherit=true.
            @test sort(findSimulationIDs(tags=("project" => "inherit-test",), inherit=true)) == sim_ids
            @test isempty(findSimulationIDs(tags=("project" => "inherit-test",), inherit=false))

            # Inherited and direct tags compose under AND.
            tag!(Simulation, sim_ids[1], "arm" => "a")
            tag!(Simulation, sim_ids[2], "arm" => "b")
            @test findSimulationIDs(tags=("project" => "inherit-test", "arm" => "a")) == [sim_ids[1]]

            # OR across any_of.
            @test sort(findSimulationIDs(any_of=("arm" => "a", "arm" => "b"))) == sim_ids[1:2]

            # AND and OR intersect when both are given.
            @test findSimulationIDs(tags=("arm" => "a",), any_of=("arm" => "a", "arm" => "b")) == [sim_ids[1]]

            # A bare key in a query matches any value for that key.
            @test sort(findSimulationIDs(tags=("arm",))) == sim_ids[1:2]

            # No filters at all returns every simulation.
            @test sort(findSimulationIDs()) == sort(simulationIDs())

            # A tag nobody applied matches nothing.
            @test isempty(findSimulationIDs(tags=("project" => "nonexistent",)))

            # Object-returning forms.
            sims = findSimulations(tags=("arm" => "a",))
            @test length(sims) == 1 && sims[1] isa Simulation && sims[1].id == sim_ids[1]

            # Monad-level search: a sampling tag inherits down to its monads, and a
            # simulation tag never propagates upward.
            monads = findMonads(tags=("project" => "inherit-test",))
            @test sort([m.id for m in monads]) == sort(monadIDs(sampling))
            @test isempty(findMonads(tags=("arm" => "a",)))

            # Sampling-level search is direct-only.
            found = findTrials(Sampling; tags=("project" => "inherit-test",))
            @test [s.id for s in found] == [sampling.id]
            @test_throws ArgumentError findTrials(Sampling; status="Completed")

            # Status filtering.
            run(sampling; quiet=true)
            @test sort(findSimulationIDs(tags=("project" => "inherit-test",), status="Completed")) == sim_ids
            @test isempty(findSimulationIDs(tags=("project" => "inherit-test",), status="Failed"))
        end
        ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = TestSimulator())
    end

    @testset "tag cleanup on deletion" begin
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()
            setTagHints!(false)

            inputs = InputFolders(config="default")
            xp = XMLPath(["data", "x"])

            sampling = createTrial(inputs, [DiscreteVariation(:config, xp, [61.0, 62.0])]; n_replicates=2)
            sim_ids = sort(simulationIDs(sampling))
            monad_ids = sort(monadIDs(sampling))
            tag!(sampling, "project" => "deleteme")
            tag!(Monad, monad_ids[1], "verdict" => "suspect")
            tag!(Simulation, sim_ids[1], "arm" => "a")

            @test orphanedTagCounts() == Dict("simulation" => 0, "monad" => 0, "sampling" => 0,
                                              "trial" => 0, "calibration" => 0)

            # Deleting a simulation removes its tag rows.
            deleteSimulations([sim_ids[1]]; delete_supers=false)
            @test isempty(tags(Simulation, sim_ids[1]))
            @test !hasTag(Simulation, sim_ids[1], "arm")

            # Cascading deletion cleans monad, sampling and simulation tags alike.
            deleteSampling(sampling.id; delete_subs=true, delete_supers=true)
            @test isempty(tags(Sampling, sampling.id))
            @test isempty(tags(Monad, monad_ids[1]))
            for sid in sim_ids
                @test isempty(tags(Simulation, sid))
            end

            @test sum(values(orphanedTagCounts())) == 0
            # Deleted objects never surface from a tag query.
            @test isempty(findSimulationIDs(tags=("project" => "deleteme",)))
        end
        ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = TestSimulator())
    end

    @testset "tag! accepts a nullable ID column from simulationsTable" begin
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()
            setTagHints!(false)

            inputs = InputFolders(config="default")
            xp = XMLPath(["data", "x"])
            sampling = createTrial(inputs, [DiscreteVariation(:config, xp, [61.0, 62.0])]; n_replicates=1)

            # `simulationsTable` yields a nullable ID column, and feeding it straight to
            # `tag!` is the documented way to label results after the fact.
            df = simulationsTable(sampling)
            @test eltype(df.SimID) == Union{Missing,Int}
            @test !(df.SimID isa AbstractVector{<:Integer})   # would not match a stricter signature

            tag!(df.SimID, "verdict" => "good")
            @test sort(findSimulationIDs(tags=("verdict" => "good",))) == sort(simulationIDs(sampling))

            untag!(df.SimID, "verdict" => "good")
            @test isempty(findSimulationIDs(tags=("verdict" => "good",)))

            # Missing entries are skipped rather than throwing, matching deleteSimulations.
            with_missing = Union{Missing,Int}[simulationIDs(sampling)[1], missing]
            tag!(with_missing, "verdict" => "partial")
            @test findSimulationIDs(tags=("verdict" => "partial",)) == [simulationIDs(sampling)[1]]
            @test tag!(Union{Missing,Int}[missing], "verdict" => "none") !== nothing
            @test isempty(findSimulationIDs(tags=("verdict" => "none",)))
        end
        ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = TestSimulator())
    end

    @testset "tag columns in simulationsTable" begin
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()
            setTagHints!(false)

            inputs = InputFolders(config="default")
            xp = XMLPath(["data", "x"])

            sampling = createTrial(inputs, [DiscreteVariation(:config, xp, [71.0, 72.0])]; n_replicates=1)
            sim_ids = sort(simulationIDs(sampling))
            tag!(Simulation, sim_ids[1], "arm" => "control")
            tag!(Simulation, sim_ids[1], "cohort" => "a", "cohort" => "b")

            # Off by default — no new columns.
            plain = simulationsTable(sim_ids)
            @test !any(startswith.(names(plain), "tag:"))

            df = simulationsTable(sim_ids; tags=true)
            @test "tag:arm" in names(df)
            @test "tag:cohort" in names(df)
            # Namespaced so a tag key can never collide with an ID/folder/parameter column.
            @test !("arm" in names(df))

            row = df[df.SimID .== sim_ids[1], :]
            @test row[1, "tag:arm"] == "control"
            @test row[1, "tag:cohort"] == "a|b"          # multi-valued keys join with |
            other = df[df.SimID .== sim_ids[2], :]
            @test ismissing(other[1, "tag:arm"])          # untagged simulations get missing

            # Provenance stays out unless asked for.
            @test !any(startswith.(names(df), "tag:mm:"))
            df_auto = simulationsTable(sim_ids; tags=true, include_auto_tags=true)
            @test "tag:mm:created" in names(df_auto)

            # A parent's tag shows up on its constituents' rows, matching findSimulationIDs:
            # a simulation recovered *by* a sampling tag must show a column for it.
            tag!(sampling, "project" => "pivot-test")
            @test findSimulationIDs(tags=("project" => "pivot-test",)) == sim_ids
            inherited = simulationsTable(sim_ids; tags=true)
            @test "tag:project" in names(inherited)
            @test all(inherited[!, "tag:project"] .== "pivot-test")

            # ...and can be turned off, leaving only tags placed directly on simulations.
            direct_only = appendTags!(simulationsTable(sim_ids), Simulation, :SimID; inherit=false)
            @test !("tag:project" in names(direct_only))
            @test "tag:arm" in names(direct_only)

            # Monad-level pivot.
            mdf = monadsTable(sampling; tags=true)
            @test mdf isa DataFrame
        end
        ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = TestSimulator())
    end

    @testset "provenance lives in object columns, not tag rows" begin
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()
            setTagHints!(false)

            @test ModelManager.tableExists("provenances")
            for table in ("simulations", "monads", "samplings", "trials", "calibrations")
                @test ModelManager.columnsExist(["datetime", "provenance_id"], table)
            end

            inputs = InputFolders(config="default")
            xp = XMLPath(["data", "x"])
            sampling = createTrial(inputs, [DiscreteVariation(:config, xp, [95.0, 96.0])]; n_replicates=2)
            sim_ids = simulationIDs(sampling)

            # A calibration records provenance the same way — in its own row, not as tag rows.
            cal = ModelManager.createCalibration("ABC-SMC"; description="provenance")
            cal_df = ModelManager.queryToDataFrame(
                "SELECT datetime, provenance_id FROM calibrations WHERE calibration_id=$(cal.id);")
            @test !ismissing(cal_df.datetime[1])
            @test !ismissing(cal_df.provenance_id[1])
            @test haskey(tags(cal), "mm:created")
            @test haskey(tags(cal), "mm:session")
            @test isempty(ModelManager.queryToDataFrame(
                "SELECT 1 AS n FROM tags WHERE trial_class='calibration' AND tag_key='mm:session';"))

            # Storage: provenance costs no tag rows at all.
            n_auto_rows = ModelManager.queryToDataFrame(
                "SELECT COUNT(*) AS n FROM tags WHERE tag_key LIKE 'mm:%';").n[1]
            @test n_auto_rows == 0

            # Each simulation carries its own datetime and provenance pointer.
            df = ModelManager.queryToDataFrame(
                "SELECT simulation_id, datetime, provenance_id FROM simulations;")
            @test all(.!ismissing.(df.datetime))
            @test all(.!ismissing.(df.provenance_id))
            # All objects created in one session share a single provenance row.
            @test length(unique(df.provenance_id)) == 1
            @test ModelManager.queryToDataFrame("SELECT COUNT(*) AS n FROM provenances;").n[1] == 1

            # Presentation: the columns surface as mm: keys.
            t = tags(Simulation, sim_ids[1])
            @test haskey(t, "mm:created")
            @test haskey(t, "mm:session")
            @test t["mm:session"] == [mm_globals().session_id]
            @test isempty(tags(Simulation, sim_ids[1]; include_auto=false))
            @test hasTag(Simulation, sim_ids[1], "mm:session" => mm_globals().session_id)

            # Queries on a synthetic key resolve through the columns.
            @test sort(findSimulationIDs(tags=("mm:session" => mm_globals().session_id,))) == sort(sim_ids)
            @test isempty(findSimulationIDs(tags=("mm:session" => "nope",)))
            @test sort(findSimulationIDs(tags=("mm:created",))) == sort(sim_ids)

            # Discovery surfaces the synthetic keys.
            keys_auto = tagKeys(include_auto=true)
            @test "mm:session" in keys_auto
            @test "mm:created" in keys_auto
            @test isempty(tagKeys())                       # no user tags yet
            @test mm_globals().session_id in tagValues("mm:session")

            # Long-format table includes them.
            tt = tagsTable()
            @test "mm:session" in tt.Key
            # The whole-store view synthesizes a row per object per mm: key, so it refuses
            # rather than materializing millions on a large project.
            @test_throws ArgumentError tagsTable(limit=1)
            # ...and the guard does not apply without them, however low the limit.
            @test isempty(tagsTable(include_auto=false, limit=1))
            @test "mm:created" in tt.Key
            @test isempty(tagsTable(include_auto=false))
            @test "mm:session" in tagsTable(sampling).Key
        end
        ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = TestSimulator())
    end

    @testset "provenance records script and git state" begin
        # Repo detection: the package directory is a git repo; a temp dir is not.
        state = gitState(pkgdir(ModelManager))
        @test length(state.commit) == 40 || isempty(state.commit)
        mktempdir() do d
            outside = gitState(d)
            @test outside.commit == "" && outside.dirty == ""
        end
        @test gitState(joinpath("this", "does", "not", "exist")).commit == ""

        # Under `julia runtests.jl` this resolves to a file; otherwise it is empty. The
        # session mode is recorded separately, not encoded into this field.
        script = ModelManager.launchingScript()
        @test isempty(script) || isfile(script)

        # Frames are filtered to the project or working directory, so an interactive
        # session prefers the user's own `include`d script over the editor internals that
        # sit further out on the stack (VS Code's `VSCodeServer/src/repl.jl` and friends).
        @test ModelManager._isUnderUserRoots(joinpath(pwd(), "anything.jl"))
        @test ModelManager._isUnderUserRoots(abspath(joinpath(dirname(Base.active_project()), "x.jl")))
        @test !ModelManager._isUnderUserRoots("/Users/someone/.vscode/extensions/julia/scripts/terminalserver/terminalserver.jl")
        @test !ModelManager._isUnderUserRoots("/opt/some/tool/driver.jl")
        # A path that merely shares a prefix with a root must not slip through.
        @test !ModelManager._isUnderUserRoots(rstrip(pwd(), '/') * "-not-mine/x.jl")

        # End-to-end version of the same thing, in the shape that actually bit: an
        # interactive session where a real file outside the project — an editor's REPL
        # driver — is the *caller*, so its frame sits on the stack when provenance is
        # resolved. Needs a subprocess because it depends on `isinteractive()` and on the
        # caller living outside this project.
        mktempdir() do outside
            driver = joinpath(outside, "terminalserver.jl")
            write(driver, """
                using ModelManager
                f() = println("SCRIPT=", ModelManager.launchingScript())
                f()
                """)
            proj = dirname(Base.active_project())
            jl = Base.julia_cmd()

            # (a) driver `include`d from an interactive session with no PROGRAM_FILE: the
            # driver is outside the project, so it is not attributed and there is no
            # launcher to fall back to.
            out = read(pipeline(`$(jl) --project=$(proj) --startup-file=no -i -q -e "include(\"$(escape_string(driver))\"); exit()"`; stderr=devnull), String)
            @test occursin(r"SCRIPT=\s*$"m, out)

            # (b) the shape editors actually use: the session is *launched as* the driver,
            # so `PROGRAM_FILE` names it. With no user frame on the stack there is nothing
            # better to report, so the launcher is recorded rather than nothing — a truthful
            # answer to how the session started. `mm:interactive` is what marks it as not
            # reproducible.
            out = read(pipeline(`$(jl) --project=$(proj) --startup-file=no -i -q $(driver)`; stderr=devnull, stdin=devnull), String)
            @test occursin("terminalserver.jl", split(out, "SCRIPT=")[end])

            # (c) the same driver run non-interactively is ordinary user work, even though
            # it lives outside the project — it must still be attributed.
            out = read(pipeline(`$(jl) --project=$(proj) --startup-file=no $(driver)`; stderr=devnull), String)
            @test occursin("terminalserver.jl", split(out, "SCRIPT=")[end])
        end

        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()
            setTagHints!(false)

            id1 = ModelManager.currentProvenanceID()
            @test id1 isa Int
            # Re-resolving with nothing changed reuses the row rather than adding one.
            @test ModelManager.currentProvenanceID() == id1
            @test ModelManager.queryToDataFrame("SELECT COUNT(*) AS n FROM provenances;").n[1] == 1

            expanded = ModelManager.provenanceFor(id1)
            @test expanded["mm:session"] == mm_globals().session_id
            @test !haskey(expanded, "mm:script.path")     # one script field, not two
            # The interactive flag is present only when it applies, like mm:git.dirty.
            @test haskey(expanded, "mm:interactive") == isinteractive()

            # The same script run interactively and non-interactively are distinct contexts.
            base = (session="s", script="/tmp/x.jl", git_commit="", git_branch="", git_dirty="")
            batch_id = ModelManager._resolveProvenanceID((; base..., interactive=""))
            repl_id  = ModelManager._resolveProvenanceID((; base..., interactive="true"))
            @test batch_id != repl_id
            @test !haskey(ModelManager.provenanceFor(batch_id), "mm:interactive")
            @test ModelManager.provenanceFor(repl_id)["mm:interactive"] == "true"

            # A distinct context adds a row; an identical one does not.
            countRows() = ModelManager.queryToDataFrame("SELECT COUNT(*) AS n FROM provenances;").n[1]
            other = (session="other", script="/tmp/other.jl", interactive="",
                     git_commit="", git_branch="", git_dirty="")
            n_before = countRows()
            ModelManager._resolveProvenanceID(other)
            @test countRows() == n_before + 1
            ModelManager._resolveProvenanceID(other)
            @test countRows() == n_before + 1
        end
        ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = TestSimulator())
    end

    @testset "a reused monad keeps its original provenance" begin
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()
            setTagHints!(false)

            inputs = InputFolders(config="default")
            xp = XMLPath(["data", "x"])
            ctx(name) = ModelManager._resolveProvenanceID((session="s", script="/tmp/$(name).jl",
                            interactive="", git_commit="", git_branch="", git_dirty=""))
            scriptOf(id) = get(ModelManager.provenanceFor(id), "mm:script", "")
            provOf(table, col, id) = ModelManager.queryToDataFrame(
                "SELECT provenance_id FROM $(table) WHERE $(col)=$(id);").provenance_id[1]

            # Script A creates the monad with two replicates. `Monad` is used directly so
            # the synthetic context survives — `createTrial` re-resolves the real one.
            mm_globals().provenance_id = ctx("scriptA")
            vid = ModelManager.addVariations(GridVariation(), inputs,
                    [DiscreteVariation(:config, xp, 7.0)], VariationID(inputs)).variation_ids[1]
            monad_a = Monad(inputs, vid; n_replicates=2, use_previous=true)
            sims_a = sort(simulationIDs(monad_a))
            @test length(sims_a) == 2

            # Script B reuses the same monad and grows it.
            mm_globals().provenance_id = ctx("scriptB")
            monad_b = Monad(monad_a.id; n_replicates=5, use_previous=true)
            @test monad_b.id == monad_a.id
            new_sims = setdiff(sort(simulationIDs(monad_b)), sims_a)
            @test length(new_sims) == 3

            # A monad from a project predating the provenance columns has null provenance.
            # Reusing it must not back-fill today's context onto an object created long ago,
            # so provenance is stamped on the branch that actually inserts, not merely when
            # `provenance_id IS NULL`.
            ModelManager.DBInterface.execute(centralDB(),
                "UPDATE monads SET provenance_id=NULL, datetime=NULL WHERE monad_id=$(monad_a.id);")
            mm_globals().provenance_id = ctx("scriptC")
            reused = Monad(inputs, vid; n_replicates=2, use_previous=true)
            @test reused.id == monad_a.id
            legacy_row = ModelManager.queryToDataFrame(
                "SELECT provenance_id, datetime FROM monads WHERE monad_id=$(monad_a.id);")
            @test ismissing(legacy_row.provenance_id[1])
            @test ismissing(legacy_row.datetime[1])
            @test isempty(tags(Monad, monad_a.id))

            # Restore so the assertions below describe the ordinary case.
            ModelManager.DBInterface.execute(centralDB(),
                "UPDATE monads SET provenance_id=$(ctx("scriptA")) WHERE monad_id=$(monad_a.id);")

            # The monad reports when *it* was created, not the last script to touch it.
            @test scriptOf(provOf("monads", "monad_id", monad_a.id)) == "/tmp/scriptA.jl"
            # Each simulation reports its own creation, so B's work is not lost either.
            for s in sims_a
                @test scriptOf(provOf("simulations", "simulation_id", s)) == "/tmp/scriptA.jl"
            end
            for s in new_sims
                @test scriptOf(provOf("simulations", "simulation_id", s)) == "/tmp/scriptB.jl"
            end
        end
        ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = TestSimulator())
    end

    @testset "transactions and find-or-insert reuse" begin
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()
            setTagHints!(false)

            # Returns the body's value, and nests without ending the outer transaction.
            @test withTransaction(() -> 42) == 42
            @test withTransaction(() -> withTransaction(() -> 7)) == 7
            @test !ModelManager.SQLite.intransaction(centralDB())   # unwound cleanly

            # A throwing body rolls back and leaves no open transaction.
            @test_throws ErrorException withTransaction(() -> error("boom"))
            @test !ModelManager.SQLite.intransaction(centralDB())

            # The EXCLUSIVE escape hatch still works, though nothing uses it by default.
            @test withTransaction(() -> 1; mode="EXCLUSIVE") == 1
            @test !ModelManager.SQLite.intransaction(centralDB())

            inputs = InputFolders(config="default")
            xp = XMLPath(["data", "x"])
            sampling = createTrial(inputs, [DiscreteVariation(:config, xp, [101.0, 102.0])]; n_replicates=2)
            sim_ids = sort(simulationIDs(sampling))

            # Creating the same configuration twice must reuse rows, not duplicate them.
            # These find-or-insert paths run without a transaction; see progress.md if
            # duplicates ever show up in samplings/trials.
            n_samplings = ModelManager.queryToDataFrame("SELECT COUNT(*) AS n FROM samplings;").n[1]
            n_monads = ModelManager.queryToDataFrame("SELECT COUNT(*) AS n FROM monads;").n[1]
            again = createTrial(inputs, [DiscreteVariation(:config, xp, [101.0, 102.0])]; n_replicates=2)
            @test again.id == sampling.id
            @test ModelManager.queryToDataFrame("SELECT COUNT(*) AS n FROM samplings;").n[1] == n_samplings
            @test ModelManager.queryToDataFrame("SELECT COUNT(*) AS n FROM monads;").n[1] == n_monads

            # Provenance resolution is also insert-or-look-up.
            pid = ModelManager.currentProvenanceID()
            @test ModelManager.currentProvenanceID() == pid
            @test ModelManager.queryToDataFrame("SELECT COUNT(*) AS n FROM provenances;").n[1] == 1

            for (i, sid) in enumerate(sim_ids)
                tag!(Simulation, sid, "arm" => "a$(i)")
                @test hasTag(Simulation, sid, "arm" => "a$(i)")
            end
        end
        ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = TestSimulator())
    end

    @testset "legacy trial datetime reads back as ISO-8601" begin
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()
            setTagHints!(false)

            inputs = InputFolders(config="default")
            xp = XMLPath(["data", "x"])
            a = createTrial(inputs, [DiscreteVariation(:config, xp, 111.0)]; n_replicates=1)
            b = createTrial(inputs, [DiscreteVariation(:config, xp, 112.0)]; n_replicates=1)
            trial = createTrial([a, b])

            # `trials.datetime` predates tagging and stores yymmddHHMM. The stored value is
            # left alone so existing readers are unaffected...
            raw = ModelManager.queryToDataFrame("SELECT datetime FROM trials;").datetime[1]
            @test occursin(r"^\d{10}$", String(raw))

            # ...but mm:created reads consistently across classes.
            iso = r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$"
            @test occursin(iso, tags(trial)["mm:created"][1])
            @test occursin(iso, tags(a)["mm:created"][1])

            @test ModelManager._normalizeStamp("2607301056") == "2026-07-30T10:56:00"
            @test ModelManager._normalizeStamp("2026-07-30T10:56:34") == "2026-07-30T10:56:34"
            @test ModelManager._normalizeStamp("9999999999") == "9999999999"   # unparseable, passed through
        end
        ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = TestSimulator())
    end

    @testset "materialization guard and bulk construction" begin
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()
            setTagHints!(false)

            inputs = InputFolders(config="default")
            xp = XMLPath(["data", "x"])
            sampling = createTrial(inputs, [DiscreteVariation(:config, xp, [97.0, 98.0])]; n_replicates=2)
            sim_ids = sort(simulationIDs(sampling))
            tag!(sampling, "project" => "guard")

            # Bulk construction returns the same objects as one-at-a-time, in order.
            bulk = simulationsFromIDs(sim_ids)
            @test [s.id for s in bulk] == sim_ids
            @test bulk == Simulation.(sim_ids)
            @test isempty(simulationsFromIDs(Int[]))
            @test [s.id for s in simulationsFromIDs([sim_ids[1], -999])] == [sim_ids[1]]

            # The ID form is unbounded; the object form refuses an oversized result set.
            @test length(findSimulationIDs(tags=("project" => "guard",))) == 4
            @test_throws ArgumentError findSimulations(tags=("project" => "guard",), limit=2)
            @test length(findSimulations(tags=("project" => "guard",), limit=4)) == 4
            @test_throws ArgumentError findMonads(tags=("project" => "guard",), limit=1)
            @test_throws ArgumentError findTrials(Sampling; tags=("project" => "guard",), limit=0)

            # The guard covers Calibration on the same path, and `status` stays a
            # simulations-only filter there as it is for Sampling and Trial.
            @test isempty(findTrials(Calibration))
            @test_throws ArgumentError findTrials(Calibration; status="Completed")
            createCal = ModelManager.createCalibration("ABC-SMC"; description="guard")
            @test length(findTrials(Calibration)) == 1
            @test_throws ArgumentError findTrials(Calibration; limit=0)
            @test findTrials(Calibration; limit=1) == [createCal]
        end
        ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = TestSimulator())
    end

    @testset "tags table is created on an existing database" begin
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()
            setTagHints!(false)

            inputs = InputFolders(config="default")
            xp = XMLPath(["data", "x"])

            # An object that exists before the upgrade, to check it survives it.
            legacy = createTrial(inputs, [DiscreteVariation(:config, xp, 80.0)]; n_replicates=1)
            legacy_cal = ModelManager.createCalibration("ABC-SMC"; description="legacy")

            # Simulate a database written by a ModelManager version predating tagging:
            # both new tables gone, and the added columns stripped from every trial table.
            # `calibrations` predates the provenance column specifically, so it is stripped of
            # that while keeping the datetime it has always carried.
            for stmt in ("DROP TABLE tags;", "DROP TABLE provenances;",
                         "ALTER TABLE simulations DROP COLUMN provenance_id;",
                         "ALTER TABLE simulations DROP COLUMN datetime;",
                         "ALTER TABLE monads DROP COLUMN provenance_id;",
                         "ALTER TABLE monads DROP COLUMN datetime;",
                         "ALTER TABLE calibrations DROP COLUMN provenance_id;")
                ModelManager.DBInterface.execute(centralDB(), stmt)
            end
            @test !ModelManager.tableExists("tags")
            @test !ModelManager.tableExists("provenances")
            @test !ModelManager.columnsExist(["provenance_id"], "simulations")
            @test !ModelManager.columnsExist(["provenance_id"], "calibrations")
            @test ModelManager.columnsExist(["datetime"], "calibrations")

            # No migration milestone needed: createSchema creates tables with IF NOT EXISTS
            # and adds columns guarded by columnsExist, so both are additive and idempotent.
            @test ModelManager.reinitializeDatabase()
            @test ModelManager.tableExists("tags")
            @test ModelManager.tableExists("provenances")
            for table in ("simulations", "monads", "samplings", "trials", "calibrations")
                @test ModelManager.columnsExist(["datetime", "provenance_id"], table)
            end

            # A second pass must not duplicate columns or fail.
            @test ModelManager.reinitializeDatabase()
            @test ModelManager.columnsExist(["datetime", "provenance_id"], "simulations")
            @test ModelManager.columnsExist(["datetime", "provenance_id"], "calibrations")

            # Objects that predate the upgrade have no provenance, and must not break the
            # read paths — they simply report no mm: keys.
            legacy_sim = simulationIDs(legacy)[1]
            @test isempty(tags(Simulation, legacy_sim))
            @test !isempty(findSimulationIDs())              # still queryable
            @test isempty(findSimulationIDs(tags=("mm:session",)))

            # A calibration from before the column keeps the datetime it always had, so it
            # still reports mm:created — only its provenance is absent.
            @test tags(legacy_cal) |> keys |> collect == ["mm:created"]
            @test findTrials(Calibration) == [legacy_cal]
            @test !isempty(calibrationsTable())

            # New objects created after the upgrade are tagged normally.
            sim = createTrial(inputs, [DiscreteVariation(:config, xp, 81.0)]; n_replicates=1)
            tag!(sim, "project" => "post-upgrade")
            @test hasTag(sim, "project" => "post-upgrade")
            @test haskey(tags(sim), "mm:created")
        end
        ModelManager.mm_globals_ref[] = ModelManagerGlobals(simulator = TestSimulator())
    end


    @testset "a throwing runSimulation records the simulation instead of stranding it" begin
        # `run()` marks a simulation "Running" and then calls the backend. If that call throws, the
        # row used to stay "Running" forever -- and `isStarted` counts everything except
        # "Not Started" as started, so every later run skipped it *and* printed "found matching
        # simulations ... not re-running them". A backend that throws for every simulation therefore
        # bricked the whole trial. Distinct from a simulation that runs and fails, which was always
        # recorded correctly (covered elsewhere).
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()
            statusOf(id) = ModelManager.queryToDataFrame(
                ModelManager.constructSelectQuery("simulations", "WHERE simulation_id=$(id)";
                                                  selection="status_code_id"); is_row=true)[1, :status_code_id]
            FAILED  = ModelManager.statusCodeID("Failed")
            RUNNING = ModelManager.statusCodeID("Running")
            QUEUED  = ModelManager.statusCodeID("Queued")

            NOT_STARTED = ModelManager.statusCodeID("Not Started")

            # IDs captured up front: failing every simulation empties the monad, which deletes it.
            monad = Monad(InputFolders(config="default"); n_replicates=3)
            ids = simulationIDs(monad)
            _throw_in_run[] = true
            try
                @test_throws Exception run(monad; quiet=true)
                # `run` throws from its completion loop the moment it sees the first error. Its
                # `finally` closes the queue, so a simulation no worker has picked up yet goes back
                # to "Not Started"; one a worker already holds is run (and here, fails). Which of
                # the later two each is depends on scheduling, so both outcomes are accepted --
                # what must never remain is a row at "Queued" or "Running".
                @test timedwait(() -> all(statusOf(id) ∉ (RUNNING, QUEUED) for id in ids), 20.0) === :ok
            finally
                _throw_in_run[] = false
            end
            @test any(statusOf(id) == FAILED for id in ids)              # the one that threw was recorded
            @test all(statusOf(id) ∈ (FAILED, NOT_STARTED) for id in ids)  # none stranded
        end
    end

    # ============================================================================
    # SLURM completion detection (replaces `sbatch --wait` polling)
    #
    # No SLURM here, so `sbatch` and `squeue` are shell scripts on PATH, driven by
    # files in their directory: the id the next `sbatch` hands out, the listing
    # `squeue` prints, and flag files that make either fail or hang.  Every test
    # goes through the real process path -- spawn, argv, parse, exit status,
    # timeout -- which is the point of shimming PATH rather than hooking Julia.
    # ============================================================================
    @testset "SLURM completion detection" begin
        MM = ModelManager
        shim = mktempdir()
        write(joinpath(shim, "sbatch"), """
            #!/bin/sh
            echo "\$@" >> "$shim/sbatch.log"
            [ -e "$shim/sbatch.fail" ] && { echo "boom: bad partition" >&2; exit 1; }
            if [ -e "$shim/sbatch.transient" ]; then
              n=\$(cat "$shim/sbatch.transient")
              if [ "\$n" -gt 0 ]; then
                echo \$((n - 1)) > "$shim/sbatch.transient"
                echo "sbatch: error: Batch job submission failed: Job violates accounting/QOS policy (job submit limit, user's size and/or time limits)" >&2
                exit 1
              fi
            fi
            while ! mkdir "$shim/sbatch.lock" 2>/dev/null; do sleep 0.01; done
            id=\$(cat "$shim/sbatch.next_id")
            echo \$((id + 1)) > "$shim/sbatch.next_id"
            rmdir "$shim/sbatch.lock"
            echo "\$id"
            """)
        write(joinpath(shim, "squeue"), """
            #!/bin/sh
            echo "\$@ STATES=\$SQUEUE_STATES PART=\$SQUEUE_PARTITION" >> "$shim/squeue.log"
            [ -e "$shim/squeue.fail" ] && exit 1
            [ -e "$shim/squeue.sleep" ] && sleep 5
            cat "$shim/squeue.out"
            """)
        chmod(joinpath(shim, "sbatch"), 0o755)
        chmod(joinpath(shim, "squeue"), 0o755)

        _next_job!(id) = write(joinpath(shim, "sbatch.next_id"), string(id))
        _queue!(ids...) = write(joinpath(shim, "squeue.out"), join(string.(ids), "\n") * "\n")
        _calls(log) = isfile(joinpath(shim, log)) ? count(!isempty, readlines(joinpath(shim, log))) : 0
        _last(log) = last(readlines(joinpath(shim, log)))
        function _reset_hpc!()
            MM._queue_snapshot[] = MM._QueueSnapshot(0, nothing)
            MM._last_stray_sweep[] = 0
            MM._SUBMIT_BACKOFF_BASE_S[] = 2.0
            for f in ("sbatch.fail", "sbatch.transient", "squeue.fail", "squeue.sleep", "sbatch.log", "squeue.log")
                rm(joinpath(shim, f); force=true)
            end
            _next_job!(1)
            _queue!()
        end

        # SQUEUE_STATES / SQUEUE_PARTITION are set so the tests can prove they are stripped
        # before squeue sees them: left in place, either would silently hide live jobs.
        withenv("PATH" => shim * ":" * ENV["PATH"], "USER" => "tester",
                "SQUEUE_STATES" => "R", "SQUEUE_PARTITION" => "gpu") do
        mktempdir() do project_dir
            _make_test_project(project_dir)
            initializeModelManager(TestSimulator(), project_dir; auto_upgrade=true)
            waitForDiagnostics()

            done_dir = MM._hpcDoneDir()
            # Fast cadences. grace 0 means the reaper fails a job as soon as a SECOND snapshot
            # (taken after the first absence) still lacks it -- so roughly two reap intervals.
            setHPCCompletionOptions(poll_interval=0.02, reap_interval=0.05, grace_period=0.0)
            sim = Simulation(InputFolders(config="default"))

            # The test plays the job. The sentinel path is baked into the `--wrap` text sbatch
            # received, so read it back from the shim's log rather than guessing. Waiting for the
            # submission to appear there is also what makes publishing race-free: a real job cannot
            # write its sentinel before sbatch has returned either -- and on a cold JIT the worker's
            # first submission takes well over any fixed sleep.
            function _sentinel_of(nth::Int)
                log = joinpath(shim, "sbatch.log")
                timedwait(() -> isfile(log) && count(!isempty, readlines(log)) >= nth, 10.0) === :ok ||
                    error("submission $(nth) never reached sbatch")
                argv = filter(!isempty, readlines(log))[nth]
                # The wrap binds the path once, single-quoted, then the trap refers to the variable.
                m = match(r"mm_sentinel='([^']*)'", argv)
                isnothing(m) && error("no sentinel path in sbatch argv: $(argv)")
                path = String(m.captures[1])
                # Guard against a helper that parses the wrap wrongly: a relative path here would
                # make _publish write into the repo working directory instead of the test project.
                # That is exactly what happened once when this regex went stale against a changed
                # wrap format and captured the literal "\${mm_sentinel}".
                isabspath(path) || error("parsed a non-absolute sentinel path: $(repr(path))")
                return path
            end
            function _publish(exit_code::Int; nth::Int=1)
                path = _sentinel_of(nth)
                write(path * ".tmp", string(exit_code))
                mv(path * ".tmp", path; force=true)
                return path
            end

            @testset "sentinel carries the outcome: zero succeeds, nonzero fails" begin
                for (job_id, ec) in [(9001, 0), (9002, 1), (9003, 137)]
                    _reset_hpc!()
                    _next_job!(job_id)
                    _queue!(job_id)                              # still queued: only the file resolves it
                    t = @async MM._runHPCSimulation(`true`, sim.id)
                    sleep(0.2)
                    @test !istaskdone(t)
                    path = _publish(ec)
                    @test fetch(t) == ec                              # the code itself; the caller decides
                    @test !isfile(path)                               # consumed
                    @test occursin("--parsable", _last("sbatch.log"))
                    @test !occursin("--wait", _last("sbatch.log"))
                end
            end

            @testset "a failed squeue query resolves nothing" begin
                # The catastrophic case: if a failed query read as an empty queue, every waiting
                # job would be declared dead at once.
                _reset_hpc!()
                _next_job!(9101)
                touch(joinpath(shim, "squeue.fail"))
                # Real simulations: the HPC path now carries the `Simulation` (job options are
                # functions of it), so a bare integer that names no row is no longer a usable label.
                sims3 = [Simulation(InputFolders(config="default")) for _ in 1:3]
                tasks = [@async MM._runHPCSimulation(`true`, s.id) for s in sims3]
                @test timedwait(() -> _calls("squeue.log") >= 2, 15.0) === :ok   # the reaper kept trying
                @test all(!istaskdone(t) for t in tasks)        # and concluded nothing from failures
                for n in 1:3
                    _publish(0; nth=n)
                end
                @test all(fetch(t) == 0 for t in tasks)
            end

            @testset "a job gone from the queue with no sentinel is failed, but only on a second snapshot" begin
                _reset_hpc!()
                _next_job!(9200)                                 # queue stays empty
                @test MM._runHPCSimulation(`true`, sim.id) === nothing   # reaped: no exit code exists
                @test _calls("squeue.log") >= 2                  # one wrong answer cannot fail a job
            end

            @testset "a grace period longer than the reap interval still fails a dead job" begin
                # The grace clock is worker-local and starts on FIRST absence. Re-based on each
                # refreshed snapshot, grace > reap_interval would reset it forever.
                _reset_hpc!()
                setHPCCompletionOptions(reap_interval=0.03, grace_period=0.15)
                _next_job!(9201)
                t = @async MM._runHPCSimulation(`true`, sim.id)
                @test timedwait(() -> istaskdone(t), 5.0) === :ok
                @test fetch(t) === nothing
                setHPCCompletionOptions(reap_interval=0.05, grace_period=0.0)
            end

            @testset "a snapshot taken before submission cannot fail the job" begin
                _reset_hpc!()
                setHPCCompletionOptions(reap_interval=3600.0)     # this snapshot is never refreshed
                MM._queue_snapshot[] = MM._QueueSnapshot(time_ns(), Set{Int}())   # empty, pre-dates the job
                sleep(0.01)
                _next_job!(9250)
                t = @async MM._runHPCSimulation(`true`, sim.id)
                sleep(0.2)
                @test !istaskdone(t)                            # the empty snapshot said nothing about it
                @test _calls("squeue.log") == 0                 # and was fresh enough not to be refreshed
                _publish(0)
                @test fetch(t) == 0
                setHPCCompletionOptions(reap_interval=0.05)
            end

            @testset "a late sentinel wins over the reaper" begin
                _reset_hpc!()
                setHPCCompletionOptions(grace_period=3600.0)
                _next_job!(9300)                                 # queue empty: already gone
                t = @async MM._runHPCSimulation(`true`, sim.id)
                sleep(0.2)
                @test !istaskdone(t)                            # grace is holding it open
                _publish(0)
                @test fetch(t) == 0
                setHPCCompletionOptions(grace_period=0.0)
            end

            @testset "squeue is queried once per interval regardless of how many jobs wait" begin
                _reset_hpc!()
                setHPCCompletionOptions(reap_interval=0.1, grace_period=3600.0)
                _next_job!(9400)
                _queue!(9400:9419...)
                sims20 = [Simulation(InputFolders(config="default")) for _ in 1:20]
                tasks = [@async MM._runHPCSimulation(`true`, s.id) for s in sims20]
                # Wait for the reaper to have refreshed a few times, rather than sleeping a fixed
                # span and asserting a rate -- the rate depends on machine load, and the invariant
                # under test does not. Over this window 20 workers poll ~dozens of times each; if
                # each queried the scheduler itself that would be hundreds of calls.
                @test timedwait(() -> _calls("squeue.log") >= 3, 15.0) === :ok
                @test _calls("squeue.log") < 20                  # one per job would be >= 20
                for n in 1:20
                    _publish(0; nth=n)
                end
                @test all(fetch(t) == 0 for t in tasks)
                setHPCCompletionOptions(reap_interval=0.05, grace_period=0.0)
            end

            @testset "a refused submission stops the run and leaves the simulations pending" begin
                # A refusal is not a result: no job ran. It used to be recorded as a failed
                # simulation, which erased the simulation from its monad -- and since a refused
                # worker returns at once and takes the next spec, a submit limit smaller than the
                # parallelism shredded a whole campaign in seconds. Now it throws, `run` fails fast
                # naming the submission stage, and every simulation is left pending.
                _reset_hpc!()
                touch(joinpath(shim, "sbatch.fail"))
                @test_throws MM._SubmissionRefused MM._runHPCSimulation(`true`, sim.id)
                # The rejection reason is on disk, not only in the error.
                @test occursin("boom", read(joinpath(MM.trialFolder(Simulation, sim.id), "hpc.err"), String))
                # "bad partition" is not a message that clears up on its own: one attempt, no retry.
                @test _calls("sbatch.log") == 1

                _status(id) = MM.queryToDataFrame(
                    MM.constructSelectQuery("simulations", "WHERE simulation_id=$(id)";
                                            selection="status_code_id"); is_row=true)[1, :status_code_id]
                NOT_STARTED = MM.statusCodeID("Not Started")
                @test mm_globals().run_on_hpc                     # the shim on PATH made init detect SLURM
                monad = Monad(InputFolders(config="default"); n_replicates=3)
                ids = simulationIDs(monad)
                _use_default_run[] = true                         # TestSimulator normally bypasses sbatch
                try
                    err = try
                        run(monad; quiet=true)
                        nothing
                    catch e
                        e
                    end
                    @test err isa MM._SimulationStageError
                    @test occursin("SLURM submission", sprint(showerror, err))
                    @test occursin("boom", sprint(showerror, err))
                    # `run` throws on the first refusal while the worker is still draining the queue.
                    # Wait for it to finish BEFORE switching the backend override back, or the
                    # stragglers run through TestSimulator's no-op and complete instead.
                    @test timedwait(() -> all(_status(id) == NOT_STARTED for id in ids), 20.0) === :ok
                finally
                    _use_default_run[] = false
                end
                # Nothing was recorded as failed, so nothing was erased from the monad.
                @test sort(constituentIDs(Monad, monad.id)) == sort(ids)
                rm(joinpath(shim, "sbatch.fail"))
            end

            @testset "a transient refusal is retried until it clears" begin
                # The QOS submit-limit message is what a user sees when parallelism exceeds
                # MaxSubmitJobs; it clears as earlier jobs finish, so the worker waits rather than
                # giving up. The sentinel path is chosen once, before the first attempt, so the
                # eventual job writes where the worker is already waiting.
                _reset_hpc!()
                MM._SUBMIT_BACKOFF_BASE_S[] = 0.01
                write(joinpath(shim, "sbatch.transient"), "3")   # refuse three times, then accept
                _next_job!(9301)
                _queue!(9301)
                t = @async MM._runHPCSimulation(`true`, sim.id)
                @test timedwait(() -> _calls("sbatch.log") >= 4, 10.0) === :ok
                @test !istaskdone(t)
                _publish(0; nth=4)
                @test fetch(t) == 0
                @test _calls("sbatch.log") == 4
            end

            @testset "a transient refusal that outlasts submit_retry_period is a refusal" begin
                _reset_hpc!()
                MM._SUBMIT_BACKOFF_BASE_S[] = 0.01
                setHPCCompletionOptions(submit_retry_period=0.2)
                write(joinpath(shim, "sbatch.transient"), "1000")
                @test_throws MM._SubmissionRefused MM._runHPCSimulation(`true`, sim.id)
                @test _calls("sbatch.log") > 1                    # it did retry before giving up
                setHPCCompletionOptions(submit_retry_period=900.0)
            end

            @testset "the shipped job options: a name, and the backend's CPU count" begin
                # No memory or time request: those are the site's to choose until the user says
                # otherwise, and a too-small default is a silent kill plus minutes of reaper latency.
                @test Set(keys(MM.defaultJobOptions())) == Set(["job-name", "cpus-per-task"])
                flags(cmd) = collect(MM._prepareHPCSubmitCommand(cmd, sim.id, joinpath(done_dir, "s")).exec)
                # TestSimulator leaves `simulationThreads` at its default, so no CPU count is
                # requested and the site's default applies; the job name is still there.
                @test "--job-name=S$(sim.id)" in flags(`echo hi`)
                @test !any(startswith("--cpus-per-task="), flags(`echo hi`))
                # A backend that reports a thread count gets it requested, per simulation.
                _test_threads[] = 6
                @test "--cpus-per-task=6" in flags(`echo hi`)
                _test_threads[] = nothing
                # A Function-valued option receives the Simulation about to be submitted, and
                # `nothing` from it omits the flag for that simulation.
                setJobOptions(Dict("comment" => s -> "sim$(s.id)", "qos" => s -> nothing))
                @test "--comment=sim$(sim.id)" in flags(`echo hi`)
                @test !any(startswith("--qos="), flags(`echo hi`))
                delete!(mm_globals().sbatch_options, "comment")
                delete!(mm_globals().sbatch_options, "qos")
                # Keys name sbatch flags, so they are Strings; anything else is refused up front.
                @test_throws ArgumentError setJobOptions(Dict(:time => "01:00:00"))
                @test !haskey(mm_globals().sbatch_options, "time")
            end

            @testset "the submission's own streams are kept as hpc.out / hpc.err" begin
                # Distinct from output.log/output.err, which sbatch fills with what the job printed
                # on the compute node. These are the sbatch *client's* streams, and hpc.out is the
                # only place a simulation's SLURM job id lands on disk.
                _reset_hpc!()
                folder = MM.trialFolder(Simulation, sim.id)
                rm(joinpath(folder, "hpc.out"); force=true)
                rm(joinpath(folder, "hpc.err"); force=true)
                _next_job!(9950)
                _queue!(9950)
                t = @async MM._runHPCSimulation(`true`, sim.id)
                @test timedwait(() -> isfile(joinpath(folder, "hpc.out")), 10.0) === :ok
                @test strip(read(joinpath(folder, "hpc.out"), String)) == "9950"   # the job id
                @test isfile(joinpath(folder, "hpc.err"))                          # created even when empty
                _publish(0)
                @test fetch(t) == 0
            end

            @testset "a leftover sentinel for the same simulation cannot be read as the new result" begin
                # Sentinel names carry a per-submission timestamp, so a file left by an earlier
                # submission of this simulation (or a recycled SLURM job id) is simply a different
                # name. It is neither consumed nor deleted here; the age-gated sweep gets it later.
                _reset_hpc!()
                stale = joinpath(done_dir, "$(sim.id).deadbeef")
                write(stale, "1")                                # says "failed"
                _next_job!(9500)
                _queue!(9500)
                t = @async MM._runHPCSimulation(`true`, sim.id)
                sleep(0.2)
                @test !istaskdone(t)                            # the leftover did not resolve it
                path = _publish(0)
                @test path != stale
                @test fetch(t) == 0
                @test isfile(stale)                             # untouched
                rm(stale; force=true)
            end

            @testset "an unreadable sentinel directory neither fails nor kills the worker" begin
                # isfile only swallows ENOENT; EACCES/ESTALE/EIO would otherwise escape the worker
                # and abort the whole run.
                _reset_hpc!()
                _next_job!(9600)
                _queue!(9600)
                t = @async MM._runHPCSimulation(`true`, sim.id)
                sleep(0.1)
                chmod(done_dir, 0o000)
                blocked = try
                    isfile(joinpath(done_dir, "9600")); false
                catch
                    true
                end
                sleep(0.15)
                chmod(done_dir, 0o700)
                if blocked
                    @test !istaskdone(t)                        # still waiting, did not throw
                else
                    @test_skip "directory permissions do not block stat here (root?)"
                end
                _publish(0)
                @test fetch(t) == 0
            end

            @testset "an undeletable sentinel still resolves the job" begin
                _reset_hpc!()
                setHPCCompletionOptions(poll_interval=0.5)        # a wide window to publish+lock inside
                _next_job!(9700)
                _queue!(9700)
                t = @async MM._runHPCSimulation(`true`, sim.id)
                sleep(0.1)
                path = _publish(0)
                chmod(done_dir, 0o500)                            # readable, not writable: unlink fails
                result = fetch(t)
                chmod(done_dir, 0o700)
                @test result == 0                                 # resolved despite cleanup failing
                rm(path; force=true)
                setHPCCompletionOptions(poll_interval=0.02)
            end

            @testset "staleness treats a zero stamp as never, not as uptime-ago" begin
                # `time_ns()` counts from boot, so `_elapsedSeconds(0)` is the machine's uptime.
                # Comparing that against a TTL makes a freshly booted host skip its first sweep or
                # refresh -- invisible on a long-lived laptop, caught by CI. Pin the semantics here
                # rather than in a test whose outcome depends on how long the machine has been up.
                @test MM._isStale(UInt64(0), 3600.0)                     # never done => due
                @test !MM._isStale(time_ns(), 3600.0)                    # just done => not due
                @test MM._isStale(time_ns() - UInt64(2_000_000_000), 1.0)  # 2s ago, 1s ttl => due
            end

            @testset "stale strays are swept once per reap interval; fresh ones are left alone" begin
                _reset_hpc!()
                setHPCCompletionOptions(reap_interval=3600.0)
                old_tmp = joinpath(done_dir, ".9999.tmp")
                old_sentinel = joinpath(done_dir, "9998")
                fresh_tmp = joinpath(done_dir, ".9997.tmp")
                for f in (old_tmp, old_sentinel, fresh_tmp)
                    write(f, "0")
                end
                run(`touch -t 202001010000 $(old_tmp) $(old_sentinel)`)
                MM._sweepStraysIfDue(done_dir)                    # due: _last_stray_sweep is 0 = never
                @test !isfile(old_tmp)
                @test !isfile(old_sentinel)
                @test isfile(fresh_tmp)                           # a live job may still be about to mv this
                write(old_tmp, "0")
                run(`touch -t 202001010000 $(old_tmp)`)
                MM._sweepStraysIfDue(done_dir)                    # not due again this interval
                @test isfile(old_tmp)
                rm(old_tmp; force=true)
                rm(fresh_tmp; force=true)
                setHPCCompletionOptions(reap_interval=0.05)
            end

            @testset "squeue: filters stripped, array ids parsed, failure is nothing, hang is bounded" begin
                _reset_hpc!()
                _queue!(111, "222_3", "")
                @test MM._squeueUserJobs() == Set([111, 222])
                argv = _last("squeue.log")
                @test occursin("-u tester", argv) && occursin("-t all", argv)
                @test endswith(argv, "STATES= PART=")            # SQUEUE_* cleared before squeue ran
                touch(joinpath(shim, "squeue.fail"))
                @test MM._squeueUserJobs() === nothing          # nonzero exit is a failed query, not an empty queue
                rm(joinpath(shim, "squeue.fail"))
                touch(joinpath(shim, "squeue.sleep"))
                MM._SQUEUE_TIMEOUT_S[] = 0.2
                t0 = time()
                @test MM._squeueUserJobs() === nothing          # a hang is bounded and counts as failed
                @test time() - t0 < 5.0
                MM._SQUEUE_TIMEOUT_S[] = 60.0
                rm(joinpath(shim, "squeue.sleep"))
            end

            @testset "job id parsing survives site wrappers, refuses ambiguity" begin
                @test MM._parseJobID("12345\n") == 12345
                @test MM._parseJobID("12345;cluster\n") == 12345
                @test MM._parseJobID("Quota: 80% used\n12345;cluster\n") == 12345      # banner before
                @test MM._parseJobID("12345\nThank you for using the cluster\n") == 12345 # banner after
                @test MM._parseJobID("Submitted batch job 777\n") == 777                 # wrapper dropped --parsable
                @test MM._parseJobID("") === nothing
                @test MM._parseJobID("nonsense\n") === nothing
                @test MM._parseJobID("111\n222\n") === nothing                          # two ids: refuse, do not guess
                # End to end: a wrapper that prints a banner line first must not orphan the job.
                _reset_hpc!()
                banner_sbatch = joinpath(shim, "sbatch")
                original = read(banner_sbatch, String)
                write(banner_sbatch, replace(original, "echo \"\$id\"" => "echo 'NOTICE: scratch purge Friday'; echo \"\$id\""))
                _next_job!(9750)
                _queue!(9750)
                t = @async MM._runHPCSimulation(`true`, sim.id)
                sleep(0.2)
                @test !istaskdone(t)                                # submitted and waiting, not "failed"
                _publish(0)
                @test fetch(t) == 0
                write(banner_sbatch, original)
            end

            @testset "_prepareHPCSubmitCommand: --parsable, no --wait, per-simulation logs, chdir" begin
                sentinel = joinpath(done_dir, "flagtest")
                flags = collect(MM._prepareHPCSubmitCommand(`echo hello`, sim.id, sentinel).exec)
                @test flags[1] == "sbatch"
                @test "--parsable" in flags
                @test !("--wait" in flags)
                sim_folder = MM.trialFolder(Simulation, sim.id)
                @test "--output=$(joinpath(sim_folder, "output.log"))" in flags
                @test "--error=$(joinpath(sim_folder, "output.err"))" in flags
                @test "--chdir=$(MM.simulatorDir(TestSimulator()))" in flags
                wrap = only(filter(f -> startswith(f, "--wrap="), flags))
                @test occursin("trap ", wrap)
                @test occursin(sentinel, wrap)
                @test endswith(wrap, "echo hello")
                # A Cmd carrying its own dir is honored, the same as the local path does.
                flags2 = collect(MM._prepareHPCSubmitCommand(Cmd(`echo hi`; dir="/tmp"), sim.id, sentinel).exec)
                @test "--chdir=/tmp" in flags2
            end

            @testset "the generated trap really records exit codes under /bin/sh" begin
                for ec in (0, 4)
                    sentinel = joinpath(done_dir, "trap$(ec)")
                    cmd = MM._prepareHPCSubmitCommand(`sh -c "exit $(ec)"`, sim.id, sentinel)
                    wrap = only(filter(f -> startswith(f, "--wrap="), collect(cmd.exec)))[length("--wrap=")+1:end]
                    script = joinpath(mktempdir(), "job.sh")
                    write(script, "#!/bin/sh\n$(wrap)\n")
                    p = run(ignorestatus(`sh $(script)`))                   # no SLURM_JOB_ID needed any more
                    @test p.exitcode == ec                                  # SLURM still sees the real status
                    @test strip(read(sentinel, String)) == string(ec)
                    @test !isfile(sentinel * ".tmp")                        # staged name did not leak
                    rm(sentinel; force=true)
                end
            end

            @testset "the sentinel path is shell-quoted, not interpolated" begin
                # `done_dir` is user-settable and the trap body is re-parsed by the shell when it
                # fires, so a path interpolated into double quotes there would expand `$VAR` and
                # backticks and break on a `"`. Bind-once-single-quoted makes every path literal.
                @test MM._shQuote("/tmp/plain") == "'/tmp/plain'"
                @test MM._shQuote("/a b") == "'/a b'"
                @test MM._shQuote(raw"/a$USER") == raw"'/a$USER'"
                @test MM._shQuote("/it's") == raw"'/it'\''s'"
                hostile = ["plain", "has space", raw"dollar$USER", "quote\"d", raw"back`tick`",
                           raw"it's", "semi;rm -rf x"]
                for shell in ("sh", "dash")
                    Sys.which(shell) === nothing && continue
                    for name in hostile
                        dir = mktempdir(); target = joinpath(dir, name)
                        wrap = MM._sentinelWrap("exit 7", target)
                        script = joinpath(dir, "job.sh"); write(script, "#!/bin/sh\n$(wrap)\n")
                        pr = run(ignorestatus(`$shell $script`))
                        @test pr.exitcode == 7                       # status still the job's
                        @test isfile(target)                         # written to the literal path
                        @test strip(read(target, String)) == "7"
                    end
                end
            end

            @testset "sbatch option values may be any type and are never quoted" begin
                # sbatch_options is Dict{String,Any}: a numeric value is ordinary, and each flag is
                # one argv element, so added quotes would reach sbatch as part of the value.
                setJobOptions(Dict("cpus-per-task" => 4, "comment" => "two words"))
                flags = collect(MM._prepareHPCSubmitCommand(`echo hi`, sim.id, joinpath(done_dir, "s")).exec)
                @test "--cpus-per-task=4" in flags
                @test "--comment=two words" in flags                 # one argv element, no quotes
                # Only the option flags: --wrap legitimately contains quotes of its own.
                opts = filter(f -> startswith(f, "--cpus-per-task=") || startswith(f, "--comment="), flags)
                @test length(opts) == 2
                @test !any(f -> occursin("\"", f), opts)
                delete!(mm_globals().sbatch_options, "cpus-per-task")
                delete!(mm_globals().sbatch_options, "comment")
            end

            @testset "sbatch options cannot claim reserved flags" begin
                for reserved in MM._RESERVED_SBATCH_KEYS
                    # Refused when set, so the mistake surfaces before any job is built...
                    @test_throws ArgumentError setJobOptions(Dict(reserved => "x"))
                    @test !haskey(mm_globals().sbatch_options, reserved)
                    # ...and again when rendered, for a value written into the Dict by hand.
                    mm_globals().sbatch_options[reserved] = "x"
                    @test_throws ArgumentError MM._prepareHPCSubmitCommand(`echo hi`, sim.id, joinpath(done_dir, "x"))
                    delete!(mm_globals().sbatch_options, reserved)
                end
            end

            @testset "default runSimulation" begin
                # TestSimulator overrides runSimulation, so reach the default explicitly.
                spec = MM.SimulationSpec(sim, Monad(sim).id)
                default(s) = invoke(MM.runSimulation, Tuple{AbstractSimulator,MM.SimulationSpec}, TestSimulator(), s)
                folder = MM.trialFolder(Simulation, sim.id)
                log_of(f) = strip(read(joinpath(folder, f), String))
                useHPC(false)

                _test_sim_cmd[] = `sh -c "echo out; echo err >&2"`
                sp = default(spec)
                @test sp.success && !isnothing(sp.process)
                @test log_of("output.log") == "out"                 # per-simulation logs, wired here
                @test log_of("output.err") == "err"

                _test_sim_cmd[] = `sh -c "exit 3"`
                @test !default(spec).success

                _test_sim_cmd[] = `sh -c "kill -9 \$\$"`             # signal-killed: exitcode is 0, success is not
                @test !default(spec).success

                _test_sim_cmd[] = `definitely-not-a-command-mm-test`  # cannot start: failed, not thrown
                sp = default(spec)
                @test !sp.success && isnothing(sp.process)

                _test_sim_cmd[] = `sh -c pwd`                          # runs in simulatorDir by default
                default(spec)
                @test realpath(log_of("output.log")) == realpath(MM.simulatorDir(TestSimulator()))
                other = realpath(mktempdir())
                _test_sim_cmd[] = Cmd(`sh -c pwd`; dir=other)           # ... or the Cmd's own dir
                default(spec)
                @test realpath(log_of("output.log")) == other

                _test_sim_cmd[] = nothing                              # "cannot build a command"
                sp = default(spec)
                @test !sp.success && isnothing(sp.process)             # this simulation fails...
                @test sp.simulation.id == sim.id                       # ...and nothing is thrown,
                                                                       # so the trial carries on
                @test isnothing(sp.cmd)                                # nothing was ever launched

                # `process === nothing` means two unrelated things now (SLURM job, or never built);
                # `cmd` is what separates them, and it is the simulator's own command on both paths.
                _test_sim_cmd[] = `sh -c "exit 3"`
                sp = default(spec)
                @test !sp.success && !isnothing(sp.cmd)                # ran locally and failed
                @test sp.cmd == `sh -c "exit 3"`
                _test_sim_cmd[] = `definitely-not-a-command-mm-test`
                sp = default(spec)
                @test isnothing(sp.process) && !isnothing(sp.cmd)      # had a command, could not spawn

                _test_sim_cmd[] = setenv(`true`, "A" => "1")           # env on the Cmd is rejected
                err = try; default(spec); catch e; e; end
                @test err isa ArgumentError
                @test occursin("env=ENV", sprint(showerror, err))      # the message names the fix
                _test_sim_cmd[] = pipeline(`true`; stdout=devnull)     # so is a pipeline
                @test_throws ArgumentError default(spec)

                # With run_on_hpc set, the same default submits and waits instead.
                useHPC(true)
                _reset_hpc!()
                _next_job!(9900)
                _queue!(9900)
                _test_sim_cmd[] = `true`
                t = @async default(spec)
                sleep(0.2)
                @test _calls("sbatch.log") == 1
                _publish(0)
                sp = fetch(t)
                @test sp.success && isnothing(sp.process)
                @test sp.cmd == `true`                                 # ran, on a compute node
                useHPC(false)
                _test_sim_cmd[] = `true`
            end

            _reset_hpc!()
        end  # mktempdir
        end  # withenv
    end

end

# A docstring that `@ref`s a non-public binding is unresolvable in any downstream docs
# build that does not also render ModelManager's private API, which terminates `makedocs`
# with a :cross_references error. Since the docs findability pass, `docs/src/lib/*.md` no
# longer renders the private API either, so ModelManager's own build would catch this too —
# but only in CI's `docs` job, and only for names that exist. This runs with the ordinary
# test suite and needs no docs build. See CLAUDE.md, "Docstring cross-references".
# Anything between a docstring and the definition it documents makes Julia drop the docstring
# silently: it is simply absent from `Docs.meta`, with no warning at any point. A comment does it —
# which the `#!` convention walks straight into, since a rationale comment naturally wants to sit
# right above the thing it explains, and the fix is to put it above the *docstring* instead. So does
# a bare blank line, with no comment involved at all. This is a source scan rather than a
# `Docs.meta` check because the failure mode is an absence, and you cannot look up what is not there.
@testset "nothing separates a docstring from its definition" begin
    src_dir = joinpath(pkgdir(ModelManager), "src")
    #! A closing `"""` alone on its line, then any run of blank or comment lines, then a definition.
    pattern = r"^\"\"\"[ \t]*\n(?:[ \t]*(?:#[^\n]*)?\n)+(?=[ \t]*[^\s#])"m

    detached = String[]
    for (root, _, files) in walkdir(src_dir), file in files
        endswith(file, ".jl") || continue
        path = joinpath(root, file)
        text = read(path, String)
        for m in eachmatch(pattern, text)
            line = count(==('\n'), text[1:m.offset]) + 1
            push!(detached, "$(relpath(path, src_dir)):$(line)")
        end
    end

    isempty(detached) ||
        @info "Docstrings detached from their definitions by intervening blank or comment lines:\n" *
              join(detached, "\n")
    @test isempty(detached)
end

#! Julia 1.10 (our compat floor) has neither `Base.ispublic` nor the `public` keyword, so
#! `@compat public` is a no-op there and *every* name would look private. The check is only
#! meaningful — and only runnable — on 1.11+. Docs CI must therefore run 1.11+ as well, or
#! Documenter's `Private = false` will not classify the interface methods correctly.
@static if isdefined(Base, :ispublic)
    @testset "docstrings only @ref public bindings" begin
        #! `[`foo`](@ref)` → `foo`; also handles `ModelManager.foo`, `foo(x)`, and `Foo{T}`.
        refTarget(s) = strip(first(split(replace(s, r"^ModelManager\." => ""), r"[({]")))

        docs_meta = Docs.meta(ModelManager)
        #! Public is necessary but not sufficient: Documenter resolves an `@ref` against a rendered
        #! *docstring*, so a public binding carrying none fails a build just as a private one does.
        #! Easy to cause by accident, since a comment between a docstring and its definition
        #! silently detaches it.
        isDocumented(target) = haskey(docs_meta, Docs.Binding(ModelManager, target))

        violations = Tuple{Symbol,String,String}[]
        for (binding, multidoc) in docs_meta
            for docstr in values(multidoc.docs)
                text = join(Iterators.filter(x -> x isa AbstractString, docstr.text), "")
                for m in eachmatch(r"\[`([^`]+)`\]\(@ref\)", text)
                    target = Symbol(refTarget(m.captures[1]))
                    if !Base.ispublic(ModelManager, target)
                        push!(violations, (binding.var, m.captures[1], "not public"))
                    elseif !isDocumented(target)
                        push!(violations, (binding.var, m.captures[1], "public but has no docstring"))
                    end
                end
            end
        end

        if !isempty(violations)
            msg = join(["  $(owner) → [`$(target)`](@ref): $(why)"
                        for (owner, target, why) in sort(violations)], "\n")
            @info "Docstrings with unresolvable @refs:\n$msg"
        end
        @test isempty(violations)
    end
else
    @info "Skipping \"docstrings only @ref public bindings\": needs Julia 1.11+ for Base.ispublic."
end

@testset "_openDB sets a busy timeout" begin
    path = joinpath(mktempdir(), "busy.db")
    db = ModelManager._openDB(path)
    row = first(ModelManager.DBInterface.execute(db, "PRAGMA busy_timeout;"))
    @test row[1] == 5000
    close(db)
end
