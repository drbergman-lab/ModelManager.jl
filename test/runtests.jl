using Test
using ModelManager
using Distributions
using DataFrames
using Random
using Statistics

@testset "ModelManager.jl" begin

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
    end

    ################## CalibrationParameter ##################

    @testset "CalibrationParameter construction" begin
        p = CalibrationParameter("rate", XMLPath(["overall", "max_time"]), Uniform(0.0, 1.0))
        @test p.name == "rate"
        @test p.prior isa Uniform
        @test p.xml_path isa XMLPath

        # Vector-of-strings constructor
        p2 = CalibrationParameter("rate2", ["overall", "max_time"], Uniform(0.0, 1.0))
        @test p2.xml_path isa XMLPath
    end

    ################## ABCSMC ##################

    @testset "ABCSMC construction and validation" begin
        m = ABCSMC()
        @test m.population_size == 100
        @test m.max_nr_populations == 10
        @test m.minimum_epsilon == 0.01
        @test m.epsilon_quantile == 0.5
        @test m.perturbation_kernel === :gaussian

        m2 = ABCSMC(population_size=50, max_nr_populations=3, minimum_epsilon=0.1)
        @test m2.population_size == 50

        @test_throws ArgumentError ABCSMC(population_size=0)
        @test_throws ArgumentError ABCSMC(max_nr_populations=-1)
        @test_throws ArgumentError ABCSMC(minimum_epsilon=-0.1)
        @test_throws ArgumentError ABCSMC(epsilon_quantile=0.0)
        @test_throws ArgumentError ABCSMC(epsilon_quantile=1.0)
        @test_throws ArgumentError ABCSMC(perturbation_kernel=:uniform)

        @test m isa AbstractCalibrationMethod
    end

    ################## ABC-SMC Algorithm (toy model) ##################

    @testset "ABC-SMC algorithm on toy model" begin
        # Recover the mean of a Normal distribution from a synthetic "observed" sample mean.
        Random.seed!(1234)
        true_mu = 2.0
        obs_mean = mean(rand(Normal(true_mu, 1.0), 100))

        param_names = ["mu"]
        priors = [Uniform(-5.0, 5.0)]

        # Simple evaluate function: draw samples and compare means (no simulator needed)
        function evaluate(params::Dict{String,Float64})
            mu = params["mu"]
            sim_mean = mean(rand(Normal(mu, 1.0), 100))
            return abs(sim_mean - obs_mean), 0
        end

        method = ABCSMC(population_size=80, max_nr_populations=4, minimum_epsilon=0.001,
                        epsilon_quantile=0.5)
        gens = ModelManager._runABCSMC(method, param_names, priors, evaluate, g -> nothing)

        @test length(gens) == 4
        @test all(g.t == i for (i, g) in enumerate(gens))

        # Epsilon should be non-increasing over generations
        for i in Iterators.drop(eachindex(gens), 1)
            @test gens[i].epsilon <= gens[i-1].epsilon
        end

        # Weights sum to 1 per generation
        for g in gens
            @test sum(g.weights) ≈ 1.0 atol=1e-6
            @test length(g.weights) == nrow(g.particles)
            @test length(g.distances) == nrow(g.particles)
        end

        # Posterior mean should be close to the observed mean (weak check)
        final = gens[end]
        post_mean = sum(final.weights .* final.particles.mu)
        @test abs(post_mean - obs_mean) < 0.5
    end

    @testset "ABC-SMC stops at minimum_epsilon" begin
        # With a trivial problem (distance always 0), epsilon should collapse immediately.
        evaluate = params -> (0.0, 0)
        method = ABCSMC(population_size=10, max_nr_populations=5, minimum_epsilon=0.5)
        gens = ModelManager._runABCSMC(method, ["x"], [Uniform(0, 1)], evaluate, g -> nothing)

        # First generation always runs; subsequent generations skipped because ε = 0 < 0.5
        @test length(gens) == 1
        @test gens[1].epsilon == 0.0
    end

    @testset "GenerationResult fields" begin
        # Build a minimal GenerationResult manually and verify fields
        particles = DataFrame(x=[1.0, 2.0, 3.0])
        gen = GenerationResult(1, particles, [0.2, 0.3, 0.5], [0.1, 0.2, 0.3], 0.3, 10, [0, 0, 0])
        @test gen.t == 1
        @test gen.particles.x == [1.0, 2.0, 3.0]
        @test sum(gen.weights) ≈ 1.0
        @test gen.epsilon == 0.3
        @test gen.n_evaluations == 10
    end

    @testset "posterior" begin
        particles1 = DataFrame(x=[1.0, 2.0])
        particles2 = DataFrame(x=[3.0, 4.0])
        gen1 = GenerationResult(1, particles1, [0.4, 0.6], [0.5, 0.3], 0.5, 4, [0, 0])
        gen2 = GenerationResult(2, particles2, [0.5, 0.5], [0.1, 0.2], 0.2, 6, [0, 0])

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

        result_empty = ABCResult(cal, GenerationResult[], params, method)
        @test_throws ErrorException posterior(result_empty)
    end

end
