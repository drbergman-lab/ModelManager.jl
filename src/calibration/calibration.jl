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

#! Addressing by *role* rather than by filename is what lets one set of call sites serve both the
#! historical flat layout and the current per-generation folders. Under the flat layout a generation's
#! artifacts were siblings distinguished by a filename prefix (`generation_05_monads.csv`); now they
#! are constants inside `generations/05/`. Only `_flatGenerationArtifact` still knows the old names.
"""
    _GENERATION_ARTIFACTS

The per-generation artifacts, keyed by role, with the basename each takes inside a generation folder.
"""
const _GENERATION_ARTIFACTS = (
    particles          = "particles.csv",
    cdfs               = "cdfs.csv",
    metadata           = "metadata.toml",
    monads             = "monads.csv",
    proposals          = "proposals.csv",
    failed_simulations = "failed_simulations.csv",
    failed_monads      = "failed_monads.csv",
)

"""
    _generationSubdir(gen_dir, t) → String or nothing

The folder holding generation `t`'s artifacts, whatever zero-padding its name carries.
"""
function _generationSubdir(gen_dir::AbstractString, t::Int)
    isdir(gen_dir) || return nothing
    for name in readdir(gen_dir)
        occursin(r"^\d+$", name) || continue
        parse(Int, name) == t && isdir(joinpath(gen_dir, name)) && return joinpath(gen_dir, name)
    end
    return nothing
end

#! Kept solely so a calibration written before the folder layout stays readable. There is no migration
#! channel for on-disk calibration artifacts — `upgradeMilestones` covers database rows — so old runs
#! are read in place rather than being required to migrate before they can be plotted.
"""
    _flatGenerationArtifact(gen_dir, t, role) → String or nothing

Locate generation `t`'s `role` artifact under the historical flat layout, at any padding width.
"""
function _flatGenerationArtifact(gen_dir::AbstractString, t::Int, role::Symbol)
    role === :cdfs      && return _findGenerationFile(joinpath(gen_dir, "generation_cdfs"), t, ".csv")
    role === :particles && return _findGenerationFile(gen_dir, t, ".csv")
    role === :metadata  && return _findGenerationFile(gen_dir, t, ".toml")
    return _findGenerationFile(gen_dir, t, "_" * _GENERATION_ARTIFACTS[role])
end

"""
    _generationArtifact(gen_dir, t, role) → String or nothing

Resolve generation `t`'s `role` artifact for **reading**: the folder layout first, then the historical
flat layout. `nothing` if neither holds it.
"""
function _generationArtifact(gen_dir::AbstractString, t::Int, role::Symbol)
    d = _generationSubdir(gen_dir, t)
    if !isnothing(d)
        p = joinpath(d, _GENERATION_ARTIFACTS[role])
        isfile(p) && return p
    end
    return _flatGenerationArtifact(gen_dir, t, role)
end

#! An existing artifact wins, in either layout. Appenders (`monads`, the two failure records) must land
#! in the file that is already there: a generation retried after a resume changed `max_nr_populations`
#! would otherwise start a second record under a different name and split one generation's history in
#! two, and nothing scans for those files to notice.
"""
    _generationArtifactToWrite(gen_dir, t, role, max_nr_populations) → String

Resolve generation `t`'s `role` artifact for **writing**, creating its folder if needed.
"""
function _generationArtifactToWrite(gen_dir::AbstractString, t::Int, role::Symbol,
                                    max_nr_populations::Int)
    existing = _generationArtifact(gen_dir, t, role)
    isnothing(existing) || return existing
    d = joinpath(gen_dir, _generationTag(t, max_nr_populations))
    mkpath(d)
    return joinpath(d, _GENERATION_ARTIFACTS[role])
end

"""
    _generationFolderToWrite(gen_dir, t, max_nr_populations) → String

Generation `t`'s folder, created if absent. An existing folder wins whatever padding its name carries.
"""
function _generationFolderToWrite(gen_dir::AbstractString, t::Int, max_nr_populations::Int)
    existing = _generationSubdir(gen_dir, t)
    isnothing(existing) || return existing
    d = joinpath(gen_dir, _generationTag(t, max_nr_populations))
    mkpath(d)
    return d
end

#! A generation counts as present if *any* of its artifacts is, so an interrupted write is reported
#! rather than skipped — the caller decides what a partial generation means. Both the flat metadata and
#! the flat CDF file are considered because either can be the one that survived.
"""
    _generationIndices(gen_dir) → Vector{Int}

Every generation present under `gen_dir`, ascending, across both layouts.
"""
function _generationIndices(gen_dir::AbstractString)
    isdir(gen_dir) || return Int[]
    out = Set{Int}()
    for name in readdir(gen_dir)
        if occursin(r"^\d+$", name) && isdir(joinpath(gen_dir, name))
            push!(out, parse(Int, name))
            continue
        end
        m = match(r"^generation_(\d+)\.(?:toml|csv)$", name)
        isnothing(m) || push!(out, parse(Int, m.captures[1]))
    end
    cdf_dir = joinpath(gen_dir, "generation_cdfs")
    if isdir(cdf_dir)
        for name in readdir(cdf_dir)
            m = match(r"^generation_(\d+)\.csv$", name)
            isnothing(m) || push!(out, parse(Int, m.captures[1]))
        end
    end
    return sort!(collect(out))
end

#! The single-generation counterpart to `_indexedGenerationFiles`, and it exists for the same reason:
#! reading must never assume a padding width. `_generationTag` takes that width from
#! `max_nr_populations`, which a resume is free to change, so a name computed *now* need not match the
#! name written *then* — `generation_05_monads.csv` from a run capped at 10 is looked for as
#! `generation_005_monads.csv` once the cap is raised to 100, and the two entry points disagree in
#! opposite directions (`ABCResult` carries the live cap, `method.toml` keeps the original, and resume
#! never rewrites it). Writing may pick a width; reading may not assume one.
"""
    _findGenerationFile(dir, t, suffix) → String or nothing

Locate generation `t`'s file ending in `suffix` inside `dir`, whatever zero-padding its name carries.
`nothing` if it is absent.
"""
function _findGenerationFile(dir::AbstractString, t::Int, suffix::String)
    pat  = Regex("^generation_(\\d+)" * replace(suffix, "." => "\\.") * "\$")
    hits = _indexedGenerationFiles(dir, pat)
    idx  = findfirst(h -> first(h) == t, hits)
    return isnothing(idx) ? nothing : last(hits[idx])
end

#! Two jobs, because they are the same walk: move a flat-layout generation into its folder, and re-pad
#! folder names when the cap has changed. The width takes the max of the two so the awkward directions
#! stay answerable:
#!
#!   - Raising the cap (10 → 100) widens every folder to 3. Consistent.
#!   - Lowering it (100 → 10) narrows back, but only to what the existing generations need — 11
#!     completed generations hold the width at 2 however small the cap goes, so no folder is orphaned.
#!   - Asking for fewer generations than already exist moves nothing; that run is a no-op, and
#!     `_runABCSMC` warns about it separately.
#!
#! Reading never depends on any of this — `_generationArtifact` resolves both layouts at any width — so
#! a failed move is logged and skipped rather than aborting the resume. That is also why migration is
#! only attempted on resume: a calibration that is merely plotted is read where it lies.
"""
    _migrateGenerationLayout!(calibration, max_nr_populations) → Int

Bring a calibration's `generations/` directory to the current layout, returning how many files moved.

Each generation's artifacts end up in `generations/<t>/` under the names in `_GENERATION_ARTIFACTS`,
with `<t>` zero-padded to `ndigits(max(max_nr_populations, highest existing generation))`.
"""
function _migrateGenerationLayout!(calibration::Calibration, max_nr_populations::Int)
    gen_dir = joinpath(calibrationFolder(calibration), "generations")
    isdir(gen_dir) || return 0
    indices = _generationIndices(gen_dir)
    isempty(indices) && return 0
    width  = ndigits(max(max_nr_populations, maximum(indices), 1))
    n      = 0

    for t in indices
        target = joinpath(gen_dir, lpad(string(t), width, '0'))
        source = _generationSubdir(gen_dir, t)

        #! Folder already correct, or just needs its name re-padded.
        if !isnothing(source)
            source == target && continue
            try
                mv(source, target)
                n += 1
            catch e
                @warn "Could not re-pad generation folder $(basename(source))." exception=e
            end
            continue
        end

        #! Flat layout: move each artifact this generation actually has into the folder.
        mkpath(target)
        for role in keys(_GENERATION_ARTIFACTS)
            src = _flatGenerationArtifact(gen_dir, t, role)
            isnothing(src) && continue
            try
                mv(src, joinpath(target, _GENERATION_ARTIFACTS[role]))
                n += 1
            catch e
                @warn "Could not move $(basename(src)) into $(basename(target))." exception=e
            end
        end
    end

    #! The old cdf directory is a leftover once every generation has moved. Removed only when empty, so
    #! a partial migration leaves whatever it could not move exactly where a reader will still find it.
    cdf_dir = joinpath(gen_dir, "generation_cdfs")
    if isdir(cdf_dir) && isempty(readdir(cdf_dir))
        try
            rm(cdf_dir)
        catch e
            @warn "Could not remove the empty generation_cdfs directory." exception=e
        end
    end
    return n
end

"""
    _generationMonadFiles(calibration) → Vector{Tuple{Int,String}}

Return `(generation, path)` for each generation's monad-ID record, in generation order.

Only the evaluated-monad record, never the failed-monad one — those are the monads that lost every
simulation, precisely the ones the database no longer holds. Under the folder layout the two are
distinct basenames, so there is no prefix for a loose match to catch.
"""
function _generationMonadFiles(calibration::Calibration)
    gen_dir = joinpath(calibrationFolder(calibration), "generations")
    out = Tuple{Int,String}[]
    for t in _generationIndices(gen_dir)
        p = _generationArtifact(gen_dir, t, :monads)
        isnothing(p) || push!(out, (t, p))
    end
    return out
end

"""
    calibrationMonadIDs(calibration::Calibration[, generation::Integer]) → Vector{Int}
    calibrationMonadIDs(result::ABCResult[, generation::Integer]) → Vector{Int}

Sorted monad IDs recorded for a calibration run, read from
`generations/{t}/monads.csv`.

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
    holds per-generation monads.csv files — or every monad it evaluated has since been deleted.
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
    gen_dir = joinpath(calibrationFolder(calibration), "generations")
    indices = _generationIndices(gen_dir)
    isempty(indices) && return (0, nothing)
    last_meta = _generationArtifact(gen_dir, last(indices), :metadata)
    isnothing(last_meta) && return (length(indices), nothing)
    epsilon = try
        #! Either spelling: "epsilon" is what pre-rename runs wrote.
        let d = TOML.parsefile(last_meta)
            get(d, "max_epsilon_accepted", get(d, "epsilon", nothing))
        end
    catch
        nothing
    end
    return (length(indices), epsilon)
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
    _deleteCalibrationBatchTags(ids)
    for id in ids
        rm_hpc_safe(calibrationFolder(id); force=true, recursive=true)
    end

    isempty(monad_ids_to_delete) ||
        deleteMonad(monad_ids_to_delete; delete_subs=true, delete_supers=true)
    return nothing
end

"""
    _deleteCalibrationBatchTags(ids)

Remove the `mm:calibration` / `mm:generation` tags a run left on its per-generation batch samplings.

`deleteTagsFor(Calibration, ids)` cannot: those tags sit on *sampling* rows and name the run in
their **value**, so nothing keyed on `(trial_class, trial_id)` reaches them. Left behind they
would be re-attributed rather than merely stale, because `calibration_id` is an
`INTEGER PRIMARY KEY` without `AUTOINCREMENT` and SQLite hands the deleted run's id to the next
one -- so `findMonads(tags = ("mm:calibration" => "3",))`, which `tag!`'s docstring recommends as
the route to a run's monads, would return the deleted run's monads mixed with the new run's.
"""
function _deleteCalibrationBatchTags(ids::AbstractVector{<:Integer})
    isempty(ids) && return nothing
    tableExists("tags") || return nothing
    values_sql = join(("'$(id)'" for id in ids), ",")
    #! The generation tag carries only a generation number, so it is identified by sitting on a
    #! sampling this run tagged -- collected before the calibration tags are removed.
    tagged = queryToDataFrame(
        "SELECT DISTINCT trial_class, trial_id FROM tags " *
        "WHERE tag_key='mm:calibration' AND tag_value IN ($(values_sql));")
    for row in eachrow(tagged)
        DBInterface.execute(centralDB(),
            "DELETE FROM tags WHERE tag_key='mm:generation' AND trial_class=? AND trial_id=?;",
            (row.trial_class, row.trial_id))
    end
    DBInterface.execute(centralDB(),
        "DELETE FROM tags WHERE tag_key='mm:calibration' AND tag_value IN ($(values_sql));")
    return nothing
end

deleteCalibration(calibration_id::Integer; kwargs...) = deleteCalibration([calibration_id]; kwargs...)
deleteCalibration(calibration::Calibration; kwargs...) = deleteCalibration([calibration.id]; kwargs...)
deleteCalibration(calibrations::AbstractVector{Calibration}; kwargs...) =
    deleteCalibration([calibration.id for calibration in calibrations]; kwargs...)
deleteCalibration(result::ABCResult; kwargs...) = deleteCalibration([result.calibration.id]; kwargs...)
