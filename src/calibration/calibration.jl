include("progress.jl")
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
    #! Same `T`-separated format as every other table, so `mm:created` reads back in one shape
    #! across all classes; `_normalizeStamp` special-cases only the legacy `trials` format.
    dt = Dates.format(now(), "yyyy-mm-ddTHH:MM:SS")
    result = DBInterface.execute(centralDB(),
        """
        INSERT INTO calibrations (datetime, description, method)
        VALUES (:dt, :desc, :method)
        RETURNING calibration_id;
        """,
        (; dt=dt, desc=description, method=method)
    ) |> DataFrame
    calibration_id = result.calibration_id[1]
    applyCreationTags(Calibration, calibration_id)
    mkpath(calibrationFolder(calibration_id))
    return Calibration(calibration_id)
end

################## Generation records ##################

"""
    _indexedGenerationFiles(dir, pattern) → Vector{Tuple{Int,String}}

Return `(generation index, full path)` for every file in `dir` whose name matches `pattern`,
sorted by the index captured from the name.

`pattern` must capture the generation number as its first group. Sorting on that number rather
than on the name matters because the zero-padding is `ndigits(max_nr_populations)`: a run resumed
with a larger `max_nr_populations` writes wider names, and `generation_10_…` sorts before
`generation_9_…` lexicographically.
"""
function _indexedGenerationFiles(dir::AbstractString, pattern::Regex)
    isdir(dir) || return Tuple{Int,String}[]
    out = Tuple{Int,String}[]
    for name in readdir(dir)
        m = match(pattern, name)
        isnothing(m) && continue
        push!(out, (parse(Int, m.captures[1]), joinpath(dir, name)))
    end
    sort!(out; by=first)
    return out
end

"""
    _findGenerationFile(dir, t, suffix) → String or nothing

Locate generation `t`'s file ending in `suffix` inside `dir`, whatever zero-padding its name carries.
`nothing` if it is absent.
"""
#! The single-generation counterpart to `_indexedGenerationFiles`, and it exists for the same reason:
#! reading must never assume a padding width. `_generationTag` takes that width from
#! `max_nr_populations`, which a resume is free to change, so a name computed *now* need not match the
#! name written *then* — `generation_05_monads.csv` from a run capped at 10 is looked for as
#! `generation_005_monads.csv` once the cap is raised to 100, and the two entry points disagree in
#! opposite directions (`ABCResult` carries the live cap, `method.toml` keeps the original, and resume
#! never rewrites it). Writing may pick a width; reading may not assume one.
function _findGenerationFile(dir::AbstractString, t::Int, suffix::String)
    pat  = Regex("^generation_(\\d+)" * replace(suffix, "." => "\\.") * "\$")
    hits = _indexedGenerationFiles(dir, pat)
    idx  = findfirst(h -> first(h) == t, hits)
    return isnothing(idx) ? nothing : last(hits[idx])
end

"""
    _normalizeGenerationPadding!(calibration, max_nr_populations) → Int

Re-pad every generation filename to one consistent width, returning how many files were renamed.

The width is `ndigits(max(max_nr_populations, highest existing generation))`, so it is wide enough for
the run's cap *and* for anything already written.
"""
#! Cosmetic, not load-bearing: every reader locates generation files by pattern and orders them by the
#! parsed index, so mixed widths are already read correctly. This exists so the directory stays
#! browsable after a resume changes the cap, and it is why the width takes the max of the two rather
#! than just `ndigits(max_nr_populations)`:
#!
#!   - Raising the cap (10 → 100) widens everything to 3. Consistent.
#!   - Lowering it (100 → 10) narrows back to 2, but only down to what the existing generations need —
#!     11 completed generations hold the width at 2 no matter how small the cap goes.
#!   - Asking for fewer generations than already exist changes nothing here; that case is a no-op run,
#!     and `_runABCSMC` warns about it separately.
#!
#! A failed rename is logged and skipped rather than aborting the resume: the files are still readable
#! at whatever width they carry, so a half-normalized directory costs nothing but tidiness.
function _normalizeGenerationPadding!(calibration::Calibration, max_nr_populations::Int)
    gen_dir = joinpath(calibrationFolder(calibration), "generations")
    isdir(gen_dir) || return 0
    #! Matches `generation_<digits><anything>`, which covers all six per-generation artifacts at once.
    #! The `generation_cdfs` directory does not match — `cdfs` is not digits — so it is never renamed.
    pat     = r"^generation_(\d+)(.*)$"
    highest = 0
    for name in readdir(gen_dir)
        m = match(pat, name)
        isnothing(m) || (highest = max(highest, parse(Int, m.captures[1])))
    end
    width   = ndigits(max(max_nr_populations, highest, 1))
    renamed = 0
    for d in (gen_dir, joinpath(gen_dir, "generation_cdfs"))
        isdir(d) || continue
        for name in readdir(d)
            m = match(pat, name)
            isnothing(m) && continue
            new_name = "generation_" * lpad(string(parse(Int, m.captures[1])), width, '0') *
                       m.captures[2]
            new_name == name && continue
            try
                mv(joinpath(d, name), joinpath(d, new_name))
                renamed += 1
            catch e
                @warn "Could not re-pad $(name) to width $(width); leaving it as it is." exception=e
            end
        end
    end
    return renamed
end

"""
    _generationMonadFiles(calibration) → Vector{Tuple{Int,String}}

Return `(generation, path)` for each `generations/generation_{NNN}_monads.csv`, in generation
order.

The pattern is anchored rather than an `endswith` test so it cannot also match
`generation_{NNN}_failed_monads.csv`, whose contents are the monads that lost every simulation —
precisely the ones the database no longer holds.
"""
_generationMonadFiles(calibration::Calibration) =
    _indexedGenerationFiles(joinpath(calibrationFolder(calibration), "generations"),
                            r"^generation_(\d+)_monads\.csv$")

"""
    calibrationMonadIDs(calibration::Calibration[, generation::Integer]) → Vector{Int}
    calibrationMonadIDs(result::ABCResult[, generation::Integer]) → Vector{Int}

Sorted monad IDs recorded for a calibration run, read from
`generations/generation_{NNN}_monads.csv`.

These are the IDs the run *evaluated*, so one whose monad has since been deleted is still listed;
`monadIDs(calibration)` returns the surviving subset.
"""
function calibrationMonadIDs(calibration::Calibration)
    files = _generationMonadFiles(calibration)
    ids = reduce(vcat, (constituentIDs(path) for (_, path) in files); init=Int[])
    #! Generations overlap — a monad reused from the bank is recorded in each one that evaluated it
    #! — so this dedupes. Sorted rather than grouped by generation: the aggregate answers "which
    #! monads", and grouping would only imply an evaluation order the storage format cannot carry
    #! (`compressIDs` sorts as it writes). Ask `calibrationMonadIDs(cal, t)` for one generation.
    return sort!(unique!(ids))
end

function calibrationMonadIDs(calibration::Calibration, generation::Integer)
    files = _generationMonadFiles(calibration)
    index = findfirst(f -> first(f) == generation, files)
    if isnothing(index)
        recorded = isempty(files) ? "none" : join(first.(files), ", ")
        throw(ArgumentError("""
        Calibration($(calibration.id)) has no monad record for generation $(generation).
        Recorded generations: $(recorded).
        """))
    end
    return sort!(unique!(constituentIDs(last(files[index]))))
end

#! Drops IDs with no `monads` row, in one query rather than one per ID. Necessary because
#! `Monad(id)` throws for a deleted monad, and a monad that lost every simulation is deleted by the
#! runner — so a run with any total monad failure would otherwise not be viewable at all.
function _survivingMonadIDs(monad_ids::AbstractVector{<:Integer})
    isempty(monad_ids) && return Int[]
    existing = Set(monadIDs())
    return Int[id for id in monad_ids if id in existing]
end

"""
    monadIDs(calibration::Calibration[, generation::Integer])
    monadIDs(result::ABCResult[, generation::Integer])

Sorted IDs of the monads a calibration run evaluated, or those of one generation.

Monads deleted after losing every simulation are excluded, so this is what the run actually
produced. It only reads; [`Sampling`](@ref) is what makes a view addressable.

# Examples
```julia
result = runABC(problem)
monadIDs(result)        # every surviving monad
monadIDs(result, 3)     # just generation 3
```
"""
monadIDs(calibration::Calibration) = _survivingMonadIDs(calibrationMonadIDs(calibration))
monadIDs(calibration::Calibration, generation::Integer) =
    _survivingMonadIDs(calibrationMonadIDs(calibration, generation))

"""
    simulationIDs(calibration::Calibration[, generation::Integer])
    simulationIDs(result::ABCResult[, generation::Integer])

IDs of every simulation a calibration run produced, or one generation's.

Equal to `simulationIDs(Sampling(calibration))`, but records nothing.

# Examples
```julia
simulationsTable(simulationIDs(result))
```
"""
simulationIDs(calibration::Calibration) =
    reduce(vcat, (constituentIDs(Monad, id) for id in monadIDs(calibration)); init=Int[])

simulationIDs(calibration::Calibration, generation::Integer) =
    reduce(vcat, (constituentIDs(Monad, id) for id in monadIDs(calibration, generation)); init=Int[])

################## Coalesced Sampling views ##################

"""
    Sampling(calibration::Calibration[, generation::Integer])
    Sampling(result::ABCResult[, generation::Integer])

A [`Sampling`](@ref) over the monads a calibration run evaluated — all of them, or one
generation's — so a run can go anywhere a trial can.

Monads deleted after losing every simulation are excluded. A sampling is identified by its exact
monad set, so the same view always resolves to the same database row; when that set happens to be
one batch's, the view *is* that batch's sampling.

See [Calibration](@ref calibration_man) for why a run has views rather than a place in the
hierarchy.

!!! note "A run still in progress"
    The view covers the monads evaluated *so far*, and recording it pins that partial set — the
    finished run has a different one, so it gets its own row. Mid-run, prefer
    [`monadIDs`](@ref)/[`simulationIDs`](@ref), which record nothing.

# Examples
```julia
result = runABC(problem)

simulationsTable(Sampling(result); tags = true)
run(Sampling(result, 3); n_replicates = 5)      # top up one generation's replicates
```
"""
function Sampling(calibration::Calibration)
    monad_ids = monadIDs(calibration)
    isempty(monad_ids) && error(_noViewableMonadsMessage(calibration, nothing))
    return _coalescedSampling(monad_ids)
end

function Sampling(calibration::Calibration, generation::Integer)
    monad_ids = monadIDs(calibration, generation)
    isempty(monad_ids) && error(_noViewableMonadsMessage(calibration, generation))
    return _coalescedSampling(monad_ids)
end

#! `inputs` is taken from the first monad rather than loaded from `problem.jld2`: every monad of a
#! calibration is built from `problem.inputs`, and the `Sampling` inner constructor asserts they
#! all agree, so the cheap route is also the checked one.
function _coalescedSampling(monad_ids::AbstractVector{<:Integer})
    monads = Monad.(monad_ids)
    return Sampling(monads, monads[1].inputs)
end

function _noViewableMonadsMessage(calibration::Calibration, generation::Union{Nothing,Integer})
    scope = isnothing(generation) ? "Calibration($(calibration.id))" :
            "Generation $(generation) of Calibration($(calibration.id))"
    return """
    $(scope) has no monads left to view.
    Either the run recorded none — check that $(joinpath(calibrationFolder(calibration), "generations")) \
    holds generation_{NNN}_monads.csv files — or every monad it evaluated has since been deleted.
    """
end

################## ABCResult forwarding ##################

#! `runABC` hands back an `ABCResult`, so the run-level surface accepts one directly rather than
#! making every caller reach for `.calibration` — the same courtesy `MMOutput` already extends for
#! a trial. Kept as explicit forwards instead of an `AbstractMMOutput` supertype: the three result
#! wrappers in the package name their payload differently (`MMOutput.trial`,
#! `GSASampling.sampling`, `ABCResult.calibration`), so unifying them needs a `resultTarget`
#! accessor for the forwards to be written against, not just a shared supertype. See progress.md.
Sampling(result::ABCResult) = Sampling(result.calibration)
Sampling(result::ABCResult, generation::Integer) = Sampling(result.calibration, generation)

monadIDs(result::ABCResult) = monadIDs(result.calibration)
monadIDs(result::ABCResult, generation::Integer) = monadIDs(result.calibration, generation)

simulationIDs(result::ABCResult) = simulationIDs(result.calibration)
simulationIDs(result::ABCResult, generation::Integer) = simulationIDs(result.calibration, generation)

calibrationMonadIDs(result::ABCResult) = calibrationMonadIDs(result.calibration)
calibrationMonadIDs(result::ABCResult, generation::Integer) =
    calibrationMonadIDs(result.calibration, generation)

################## Read path ##################

"""
    calibrationsTable(; tags=false, include_auto_tags=false)
    calibrationsTable(target...; kwargs...)

One row per calibration run: `CalibrationID`, `DateTime`, `Method`, `Description`.

`target` may be a vector of calibration IDs, one or more [`Calibration`](@ref)s, a vector of them,
or the [`ABCResult`](@ref) [`runABC`](@ref) returns. Omitted, every run in the project.

Per-generation convergence numbers are [`ConvergenceSummary`](@ref); the parameters themselves
[`posterior`](@ref).

# Keyword Arguments
- `tags::Bool`: append one `tag:<key>` column per tag key in use (see [`appendTags!`](@ref)).
  Only tags on the run itself appear — a calibration contains no simulations to inherit from.
- `include_auto_tags::Bool`: also pivot the `mm:` provenance keys. Requires `tags=true`.

# Examples
```julia
calibrationsTable()
calibrationsTable(; tags = true)      # what each run was for
calibrationsTable([1, 2, 3])
```
"""
function calibrationsTable(calibration_ids::AbstractVector{<:Integer}; kwargs...)
    assertInitialized()
    query = constructSelectQuery("calibrations", "WHERE calibration_id IN ($(join(Int.(calibration_ids), ",")));")
    return _calibrationsTableFromQuery(query; kwargs...)
end

function calibrationsTable(; kwargs...)
    assertInitialized()
    return _calibrationsTableFromQuery(constructSelectQuery("calibrations"); kwargs...)
end

calibrationsTable(calibrations::AbstractVector{Calibration}; kwargs...) =
    calibrationsTable([calibration.id for calibration in calibrations]; kwargs...)

calibrationsTable(calibration::Calibration, calibrations::Vararg{Calibration}; kwargs...) =
    calibrationsTable([calibration; calibrations...]; kwargs...)

calibrationsTable(result::ABCResult; kwargs...) = calibrationsTable([result.calibration]; kwargs...)

function _calibrationsTableFromQuery(query::String; tags::Bool=false, include_auto_tags::Bool=false)
    df = queryToDataFrame(query)
    #! Built rather than renamed when the result is empty: a query returning no rows need not carry
    #! the column set, and a caller matching on names should not have to special-case that.
    if isempty(df)
        return DataFrame(CalibrationID=Int[], DateTime=String[], Method=String[], Description=String[])
    end
    #! `provenance_id` is dropped on purpose: provenance is presented as `mm:` tag keys, never as
    #! the raw row id.
    select!(df, [:calibration_id, :datetime, :method, :description])
    rename!(df, :calibration_id => :CalibrationID, :datetime => :DateTime,
                :method => :Method, :description => :Description)
    sort!(df, :CalibrationID)
    tags && appendTags!(df, Calibration, :CalibrationID; include_auto=include_auto_tags)
    return df
end

"""
    printCalibrationsTable(args...; sink=println, kwargs...)

Print [`calibrationsTable`](@ref). `sink` receives the DataFrame (default `println`, or e.g.
`CSV.write("calibrations.csv")`).
"""
function printCalibrationsTable(args...; sink=println, kwargs...)
    assertInitialized()
    calibrationsTable(args...; kwargs...) |> sink
end

#! `(number of generations, final epsilon)` from the on-disk metadata, or `(0, nothing)` when there
#! is none. Guarded throughout: this feeds `show`, which must never throw.
function _generationSummary(calibration::Calibration)
    files = _indexedGenerationFiles(joinpath(calibrationFolder(calibration), "generations"),
                                    r"^generation_(\d+)\.toml$")
    isempty(files) && return (0, nothing)
    epsilon = try
        #! Either spelling: "epsilon" is what pre-rename runs wrote.
        let d = TOML.parsefile(last(last(files)))
            get(d, "max_epsilon_accepted", get(d, "epsilon", nothing))
        end
    catch
        nothing
    end
    return (length(files), epsilon)
end

function Base.show(io::IO, calibration::Calibration)
    if !isInitialized()
        print(io, "Calibration (ID=$(calibration.id))")
        return
    end
    df = constructSelectQuery("calibrations", "WHERE calibration_id=$(calibration.id);") |> queryToDataFrame
    if isempty(df)
        print(io, "Calibration (ID=$(calibration.id)): no row in the calibrations table.")
        return
    end
    lines = ["Calibration (ID=$(calibration.id)):"]
    _pushField!(lines, "Created", df.datetime[1])
    _pushField!(lines, "Method", df.method[1])
    _pushField!(lines, "Description", df.description[1])
    n_generations, epsilon = _generationSummary(calibration)
    push!(lines, "  Generations: $(n_generations)")
    isnothing(epsilon) || push!(lines, "  Final ε:     $(epsilon)")
    print(io, join(lines, "\n"))
end

#! A field the database row never carried (`description` defaults to empty) is omitted rather than
#! printed blank.
function _pushField!(lines::Vector{String}, label::AbstractString, value)
    (ismissing(value) || isempty(string(value))) && return nothing
    push!(lines, "  $(rpad("$(label):", 12)) $(value)")
    return nothing
end

################## Deletion ##################

"""
    deleteCalibration(target; delete_subs=false)

Delete calibration runs: the `calibrations` database row, its tags, and its output folder.

`target` may be a calibration ID, a vector of IDs, a [`Calibration`](@ref), a vector of them, or
the [`ABCResult`](@ref) [`runABC`](@ref) returns.

`delete_subs` defaults to `false`, unlike the trial-level deleters — a run's monads are shared,
through the [`SimulationBank`](@ref) and `use_previous`, so they may predate it and outlive it.
Pass `true` to remove them and their simulations too.

Note that the folder holds the generation CSVs, the serialized problem and the method settings, so
deleting a run discards its posterior: [`posterior`](@ref) and [`resumeABC`](@ref) stop working
for it.

# Examples
```julia
deleteCalibration(result)                  # bookkeeping only
deleteCalibration(3; delete_subs = true)   # and every monad it evaluated
```
"""
function deleteCalibration(calibration_ids::AbstractVector{<:Integer}; delete_subs::Bool=false)
    assertInitialized()
    ids = Int.(calibration_ids)
    isempty(ids) && return nothing
    #! Collected before anything is removed: the per-generation CSVs inside the folder are the only
    #! record of which monads a calibration evaluated.
    monad_ids_to_delete = delete_subs ?
        unique!(reduce(vcat, (monadIDs(Calibration(id)) for id in ids); init=Int[])) : Int[]

    DBInterface.execute(centralDB(),
        "DELETE FROM calibrations WHERE calibration_id IN ($(join(ids, ",")));")
    deleteTagsFor(Calibration, ids)
    for id in ids
        rm_hpc_safe(calibrationFolder(id); force=true, recursive=true)
    end

    isempty(monad_ids_to_delete) ||
        deleteMonad(monad_ids_to_delete; delete_subs=true, delete_supers=true)
    return nothing
end

deleteCalibration(calibration_id::Integer; kwargs...) = deleteCalibration([calibration_id]; kwargs...)
deleteCalibration(calibration::Calibration; kwargs...) = deleteCalibration([calibration.id]; kwargs...)
deleteCalibration(calibrations::AbstractVector{Calibration}; kwargs...) =
    deleteCalibration([calibration.id for calibration in calibrations]; kwargs...)
deleteCalibration(result::ABCResult; kwargs...) = deleteCalibration([result.calibration.id]; kwargs...)
