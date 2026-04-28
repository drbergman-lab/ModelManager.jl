include("methods.jl")
include("parameters.jl")
include("problem.jl")
include("distance.jl")
include("bank.jl")
include("abc_smc.jl")
include("abc.jl")

################## Folder Helpers ##################

"""
    calibrationsDir()

Return the path to the top-level calibrations output directory:
`data/outputs/calibrations/`.
"""
calibrationsDir() = joinpath(dataDir(), "outputs", "calibrations")

"""
    calibrationFolder(calibration_id::Int)

Return the path to the output folder for a given calibration run.
"""
calibrationFolder(calibration_id::Int) = joinpath(calibrationsDir(), string(calibration_id))
calibrationFolder(calibration::Calibration) = calibrationFolder(calibration.id)

################## Database Operations ##################

"""
    createCalibration(method::String; description::String="") → Calibration

Insert a new row into the `calibrations` table and create the output folder.
Returns the resulting [`Calibration`](@ref) object.
"""
function createCalibration(method::String; description::String="")
    dt = Dates.format(now(), "yyyy-mm-dd HH:MM:SS")
    result = DBInterface.execute(centralDB(),
        """
        INSERT INTO calibrations (datetime, description, method)
        VALUES (:dt, :desc, :method)
        RETURNING calibration_id;
        """,
        (; dt=dt, desc=description, method=method)
    ) |> DataFrame
    calibration_id = result.calibration_id[1]
    mkpath(calibrationFolder(calibration_id))
    return Calibration(calibration_id)
end

"""
    calibrationMonadIDs(calibration::Calibration) → Vector{Int}

Return all monad IDs evaluated during this calibration run, aggregated across all
per-generation monad files (`generation_*_monads.csv`) in evaluation order.
"""
function calibrationMonadIDs(calibration::Calibration)
    gen_dir = joinpath(calibrationFolder(calibration), "generations")
    !isdir(gen_dir) && return Int[]
    paths = sort(filter(f -> endswith(f, "_monads.csv"), readdir(gen_dir; join=true)))
    return reduce(vcat, (constituentIDs(p) for p in paths); init=Int[])
end


