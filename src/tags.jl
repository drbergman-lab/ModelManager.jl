using Dates
using DataFrames
using LibGit2
using Random: randstring

export tag!, untag!, tags, hasTag
export findTrials, findSimulations, findSimulationIDs, findMonads
export tagsTable, printTagsTable, tagKeys, tagValues, recommendedTagKeys
export setTagHints!, gitState, appendTags!, orphanedTagCounts

########################################################
############   Constants and schema   ##################
########################################################

#! Enforced for free by the key charset: `:` is not a legal character in a user key,
#! so no separate reserved-word check is needed.
"""
    MM_TAG_PREFIX

Prefix marking a tag as ModelManager-generated rather than a user assertion.
Keys in this namespace cannot be written through [`tag!`](@ref).
"""
const MM_TAG_PREFIX = "mm:"

const MAX_TAG_KEY_LENGTH = 64

#! Keys are identifiers (they become column headers, CSV headers, filter tokens),
#! so they are restricted; values are data and stay free-form.
const TAG_KEY_BODY_REGEX = r"^[a-z0-9][a-z0-9_.-]*$"

const RECOMMENDED_TAG_KEYS = ("project", "purpose", "figure", "arm", "verdict", "note")

const TAG_CLASSES = ("simulation", "monad", "sampling", "trial")

const MM_CREATED_KEY = "mm:created"

#! Provenance is kept out of the `tags` table on purpose. That table is
#! entity-attribute-value — one row per fact — so recording five session-invariant facts
#! on every object would cost five rows plus their index entries, ~1 KB per object
#! (measured). Objects instead carry a `provenance_id` column, and these keys are
#! synthesized on read so the public API is unchanged.
"""
    PROVENANCE_COLUMNS

Mapping from the `mm:` keys a user queries with to the `provenances` column each
is stored in.
"""
const PROVENANCE_COLUMNS = (
    "mm:session"     => "session",
    "mm:script"      => "script",
    "mm:interactive" => "interactive",
    "mm:git"         => "git_commit",
    "mm:git.branch"  => "git_branch",
    "mm:git.dirty"   => "git_dirty",
)

"""
    MAX_MATERIALIZED_TRIALS

Result-set size above which the object-returning finders refuse to build objects.

A tag on a parent matches everything beneath it, so a query can select far more
than intended. Raise the ceiling per call with the `limit` keyword.
"""
const MAX_MATERIALIZED_TRIALS = 10_000

_provenanceColumn(key::AbstractString) = get(Dict(PROVENANCE_COLUMNS), key, nothing)
_isSyntheticKey(key::AbstractString) = key == MM_CREATED_KEY || !isnothing(_provenanceColumn(key))

"""
    tagsSchema()

Return the SQL schema string for the `tags` table.

Each row asserts one key/value pair about one trial object. `trial_class` is the
lowercased type name (`"simulation"`, `"monad"`, `"sampling"`, `"trial"`) and
`trial_id` is that object's primary key. The `UNIQUE` constraint spans the value
as well as the key, so a single object may carry several values for one key.
"""
function tagsSchema()
    #! `tag_value` defaults to `''` rather than `NULL`: SQLite treats `NULL`s as distinct in a
    #! `UNIQUE` constraint, which would silently permit duplicate bare labels.
    return """
    tag_id INTEGER PRIMARY KEY,
    trial_class TEXT NOT NULL,
    trial_id INTEGER NOT NULL,
    tag_key TEXT NOT NULL,
    tag_value TEXT NOT NULL DEFAULT '',
    datetime TEXT,
    UNIQUE (trial_class, trial_id, tag_key, tag_value)
    """
end

"""
    provenancesSchema()

Return the SQL schema string for the `provenances` table.

One row per distinct creation context: session, launching script, session mode, and
git state.
"""
function provenancesSchema()
    #! Every column is `NOT NULL DEFAULT ''` so the `UNIQUE` constraint dedupes: SQLite treats
    #! `NULL`s as distinct, which would mint a fresh row on every insert.
    return """
    provenance_id INTEGER PRIMARY KEY,
    session TEXT NOT NULL DEFAULT '',
    script TEXT NOT NULL DEFAULT '',
    interactive TEXT NOT NULL DEFAULT '',
    git_commit TEXT NOT NULL DEFAULT '',
    git_branch TEXT NOT NULL DEFAULT '',
    git_dirty TEXT NOT NULL DEFAULT '',
    datetime TEXT,
    UNIQUE (session, script, interactive, git_commit, git_branch, git_dirty)
    """
end

"""
    createTagIndices(; db::SQLite.DB=centralDB())

Create the lookup indices for the `tags` table.
"""
function createTagIndices(; db::SQLite.DB=centralDB())
    #! The `UNIQUE` constraint already indexes `(trial_class, trial_id, …)`, which serves
    #! "what tags does this object have?". This is the reverse direction, which `findTrials`
    #! queries: "which objects carry this tag?".
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS idx_tags_lookup ON tags (tag_key, tag_value);")
    return nothing
end

"""
    ensureProvenanceColumns(; db::SQLite.DB=centralDB())

Add the `datetime` and `provenance_id` columns to the trial tables when missing.

Run from `createSchema`, so an existing project gains the columns on its
next `initializeModelManager`. No migration milestone is required, and a simulator
package needs to implement nothing.
"""
function ensureProvenanceColumns(; db::SQLite.DB=centralDB())
    for T in (Simulation, Monad, Sampling, Trial)
        table = "$(lowerClassString(T))s"
        tableExists(table; db=db) || continue
        columns = tableColumns(table; db=db)
        #! `trials` has carried a datetime since before tagging; leave that column alone.
        columnsExist(["datetime"], columns) ||
            SQLite.execute(db, "ALTER TABLE $(table) ADD COLUMN datetime TEXT;")
        columnsExist(["provenance_id"], columns) ||
            SQLite.execute(db, "ALTER TABLE $(table) ADD COLUMN provenance_id INTEGER;")
    end
    return nothing
end

########################################################
############   Key / value normalization   #############
########################################################

function _validateTagKeyBody(body::AbstractString, original)
    if isempty(body)
        throw(ArgumentError("Tag key must not be empty."))
    end
    if length(body) > MAX_TAG_KEY_LENGTH
        throw(ArgumentError("Tag key $(repr(original)) is $(length(body)) characters; the maximum is $(MAX_TAG_KEY_LENGTH)."))
    end
    if !occursin(TAG_KEY_BODY_REGEX, body)
        throw(ArgumentError("""
        Invalid tag key $(repr(original)).
        Tag keys may contain only lowercase letters, digits, `_`, `.`, and `-`, and must begin with a letter or digit.
        (Keys are lowercased automatically. The `$(MM_TAG_PREFIX)` namespace is reserved for ModelManager-generated tags.)
        Recommended keys: $(join(RECOMMENDED_TAG_KEYS, ", ")).
        """))
    end
    return String(body)
end

"""
    normalizeTagKey(key) -> String

Normalize and validate a user-supplied tag key: strip surrounding whitespace,
lowercase it, and check it against the legal character set.

Throws an `ArgumentError` for an empty key, an over-long key, a key containing
illegal characters, or any key in the reserved `mm:` namespace.
"""
function normalizeTagKey(key)
    k = lowercase(strip(string(key)))
    if startswith(k, MM_TAG_PREFIX)
        throw(ArgumentError("The `$(MM_TAG_PREFIX)` prefix is reserved for ModelManager-generated tags; got $(repr(key))."))
    end
    return _validateTagKeyBody(k, key)
end

#! Internal-only path for the framework's own tags.
function _reservedTagKey(key::AbstractString)
    k = lowercase(strip(key))
    @assert startswith(k, MM_TAG_PREFIX) "Reserved tag keys must start with `$(MM_TAG_PREFIX)`. Got $(repr(key))."
    _validateTagKeyBody(k[(length(MM_TAG_PREFIX)+1):end], key)
    return k
end

#! Leading/trailing whitespace is stripped from values too: it is invisible in any
#! printout and would otherwise produce duplicate-looking tags. Internal whitespace,
#! case, punctuation, and unicode are all preserved.
_normalizeTagValue(value) = String(strip(string(value)))

_tagPair(p::Pair) = (normalizeTagKey(first(p)), _normalizeTagValue(last(p)))
_tagPair(key::AbstractString) = (normalizeTagKey(key), "")
_tagPair(key::Symbol) = (normalizeTagKey(key), "")

"""
    normalizeTagPairs(ps) -> Vector{Tuple{String,String}}

Normalize a collection of tag specifications into `(key, value)` string tuples.

Each element may be a `Pair` (`"arm" => "high_dose"`, `:arm => 3`) or a bare key
(`"baseline"`, `:baseline`), which is stored with an empty value. Duplicates are
removed while preserving order.
"""
function normalizeTagPairs(ps)
    out = Tuple{String,String}[]
    for p in ps
        pair = _tagPair(p)
        pair in out || push!(out, pair)
    end
    return out
end

normalizeTagPairs(ps...) = normalizeTagPairs(ps)

########################################################
############   Class helpers   #########################
########################################################

_tagClass(::Type{T}) where {T<:AbstractTrial} = lowerClassString(T)
_tagClass(T::AbstractTrial) = lowerClassString(T)
_tagTable(class::AbstractString) = "$(class)s"

#! Framework bookkeeping must never take down a run — an uninitialized project or a
#! database predating the provenance columns are both survivable.
function _quietly(f::Function)
    return try
        f()
    catch e
        @debug "Tag provenance step failed: $(e)"
        nothing
    end
end

########################################################
############   Writing tags   ##########################
########################################################

function _insertTagRows(class::AbstractString, ids, pairs::Vector{Tuple{String,String}})
    (isempty(ids) || isempty(pairs)) && return 0
    assertInitialized()
    stamp = Dates.format(now(), "yyyy-mm-ddTHH:MM:SS")
    stmt = SQLite.Stmt(centralDB(), """
        INSERT OR IGNORE INTO tags (trial_class, trial_id, tag_key, tag_value, datetime)
        VALUES (?, ?, ?, ?, ?);
        """)
    n = 0
    #! Batching, not exclusivity: these inserts are idempotent and read nothing. One
    #! transaction instead of N keeps a large retroactive `tag!` from paying N commits.
    withTransaction() do
        for id in ids, (k, v) in pairs
            DBInterface.execute(stmt, (class, Int(id), k, v, stamp))
            n += 1
        end
    end
    return n
end

"""
    tag!(target, tags...)

Attach one or more tags to a trial object (or to many at once) and return `target`.

Each tag is a `Pair` such as `"arm" => "high_dose"`, or a bare key such as
`"baseline"` which is stored with an empty value. Keys are lowercased and must
match `[a-z0-9][a-z0-9_.-]*`; values are stored as given (with surrounding
whitespace trimmed). Re-applying an existing tag is a no-op, and a single key may
carry several values.

A tag placed on a `Monad`, `Sampling`, or `Trial` is stored once, on that object —
it is not copied onto its constituent simulations. [`findTrials`](@ref) expands
the hierarchy at query time instead, so the answer stays correct when replicates
are added later.

# Accepted targets
```julia
tag!(simulation, "arm" => "high_dose")        # any AbstractTrial
tag!(Simulation, 42, "verdict" => "suspect")  # type + id
tag!(Simulation, [1, 2, 3], "project" => "x") # type + ids
tag!([sim_a, sim_b], "project" => "x")        # vector of objects
tag!([1, 2, 3], "project" => "x")             # bare ids are interpreted as simulations
tag!(df.SimID, "project" => "x")              # a column straight out of `simulationsTable`
tag!(output, "project" => "x")                # an MMOutput from `run`
```

# Returns
The `target`, so calls can be chained or piped.

# Example
```julia
sampling = createTrial(inputs, variations)
tag!(sampling, "project" => "immune-escape", "purpose" => "figure", "figure" => "3b")

# Retroactive curation: label what you found interesting after looking at results.
tag!(findSimulationIDs(tags = ("project" => "immune-escape",)), "verdict" => "good")
```

See also [`untag!`](@ref), [`tags`](@ref), [`findTrials`](@ref).
"""
function tag!(::Type{T}, ids::AbstractVector{<:Union{Integer,Missing}}, ps...) where {T<:AbstractTrial}
    _insertTagRows(_tagClass(T), collect(skipmissing(ids)), normalizeTagPairs(ps))
    #! `Union{Integer,Missing}` rather than `Integer`: a column pulled out of
    #! `simulationsTable` is `Vector{Union{Missing,Int64}}`, and feeding one straight to
    #! `tag!` is the documented way to label results after the fact. `deleteSimulations`
    #! accommodates the same thing the same way.
    return ids
end

tag!(::Type{T}, id::Integer, ps...) where {T<:AbstractTrial} = (tag!(T, [id], ps...); id)

function tag!(target::AbstractTrial, ps...)
    _insertTagRows(_tagClass(target), [target.id], normalizeTagPairs(ps))
    return target
end

function tag!(targets::AbstractVector{<:AbstractTrial}, ps...)
    pairs = normalizeTagPairs(ps)
    for target in targets
        _insertTagRows(_tagClass(target), [target.id], pairs)
    end
    return targets
end

#! A bare vector of integers is by far most often a column of simulation IDs
#! (e.g. `simulationsTable().SimID`), so that is the documented interpretation.
tag!(ids::AbstractVector{<:Union{Integer,Missing}}, ps...) = tag!(Simulation, ids, ps...)

tag!(output::MMOutput, ps...) = (tag!(output.trial, ps...); output)

"""
    tagReserved!(target, pairs)

Attach ModelManager-generated `mm:` tags to `target`.

The internal counterpart to [`tag!`](@ref): it accepts the reserved namespace the
public function rejects, so framework entry points (sensitivity analyses,
calibrations) can label what they produce. Only the object handed back to the user
is tagged; its constituents pick the tags up through the usual query-time
inheritance.
"""
function tagReserved!(target::AbstractTrial, pairs)
    normalized = Tuple{String,String}[(_reservedTagKey(string(k)), _normalizeTagValue(v)) for (k, v) in pairs]
    _quietly(() -> _insertTagRows(_tagClass(target), [target.id], normalized))
    return nothing
end

"""
    untag!(target, tags...)

Remove tags from a trial object (or from many at once) and return `target`.

Each argument may be a full `key => value` pair, which removes exactly that pair,
or a bare key, which removes every value stored under that key. Removing a tag
that is not present is a no-op.

Calling `untag!(target)` with no tags removes all *user* tags from the target.
ModelManager's own `mm:` tags are never removed by `untag!` — delete the object
itself if you need them gone.

# Example
```julia
untag!(sim, "verdict" => "suspect")   # drop one specific pair
untag!(sim, "verdict")                # drop every verdict value
untag!(sim)                           # drop all user tags, keep mm: provenance
```

See also [`tag!`](@ref).
"""
function untag!(::Type{T}, ids::AbstractVector{<:Union{Integer,Missing}}, ps...) where {T<:AbstractTrial}
    assertInitialized()
    present = collect(skipmissing(ids))
    isempty(present) && return ids
    class = _tagClass(T)
    id_list = join(Int.(present), ",")
    if isempty(ps)
        DBInterface.execute(centralDB(),
            "DELETE FROM tags WHERE trial_class='$(class)' AND trial_id IN ($(id_list)) AND tag_key NOT LIKE '$(MM_TAG_PREFIX)%';")
        return ids
    end
    for p in ps
        if p isa Pair
            k, v = _tagPair(p)
            stmt = "DELETE FROM tags WHERE trial_class=? AND trial_id IN ($(id_list)) AND tag_key=? AND tag_value=?;"
            DBInterface.execute(SQLite.Stmt(centralDB(), stmt), (class, k, v))
        else
            k = normalizeTagKey(p)
            stmt = "DELETE FROM tags WHERE trial_class=? AND trial_id IN ($(id_list)) AND tag_key=?;"
            DBInterface.execute(SQLite.Stmt(centralDB(), stmt), (class, k))
        end
    end
    return ids
end

untag!(::Type{T}, id::Integer, ps...) where {T<:AbstractTrial} = (untag!(T, [id], ps...); id)
untag!(target::AbstractTrial, ps...) = (untag!(typeof(target), [target.id], ps...); target)
untag!(ids::AbstractVector{<:Union{Integer,Missing}}, ps...) = untag!(Simulation, ids, ps...)

function untag!(targets::AbstractVector{<:AbstractTrial}, ps...)
    for target in targets
        untag!(typeof(target), [target.id], ps...)
    end
    return targets
end

########################################################
############   Provenance   ############################
########################################################

const _PKG_SOURCE_DIR = @__DIR__

function _sessionID()
    g = mm_globals()
    if isempty(g.session_id)
        g.session_id = randstring(['a':'f'; '0':'9'], 12)
    end
    return g.session_id
end

"""
    gitState(dir) -> NamedTuple

Return `(commit, branch, dirty)` for the repository containing `dir`, or empty
strings when `dir` is not inside a git repository.

`dirty` is `"true"` when the working tree has uncommitted changes and `""`
otherwise — a commit hash alone is a false promise of reproducibility if the tree
was modified.

# Example
```julia
gitState(pwd())
# (commit = "8e196deb...", branch = "main", dirty = "")
```
"""
function gitState(dir::AbstractString)
    empty_state = (commit="", branch="", dirty="")
    isdir(dir) || return empty_state
    return try
        repo = LibGit2.GitRepoExt(dir)
        try
            commit = string(LibGit2.head_oid(repo))
            branch = try
                String(LibGit2.headname(repo))
            catch
                ""
            end
            (commit=commit, branch=branch, dirty=LibGit2.isdirty(repo) ? "true" : "")
        finally
            close(repo)
        end
    catch
        empty_state
    end
end

"""
    launchingScript() -> String

Return the absolute path of the script that launched or is driving this session,
or `""` when there is neither.

A session that `include`s several scripts in turn attributes each one to the
objects it created. Whether that happened inside an interactive session is
recorded separately, as `mm:interactive`.

In an interactive session a script `include`d from the project takes precedence;
failing that, the session's launcher is recorded. That launcher may belong to an
editor — VS Code starts Julia as `julia .../terminalserver.jl` — so treat
`mm:script` from an interactive session as "how this session started", not "what
produced this result". `mm:interactive` marks exactly that distinction.

# Example
```julia
launchingScript()
# "/Users/you/study/fig3_sweep.jl"
```
"""
function launchingScript()
    program = ""
    if !isempty(PROGRAM_FILE)
        candidate = abspath(PROGRAM_FILE)
        isfile(candidate) && (program = candidate)
    end
    #! Non-interactive: `PROGRAM_FILE` is the script being run, and is authoritative.
    !isinteractive() && !isempty(program) && return program
    #! Interactive: `PROGRAM_FILE` is whatever opened the prompt — an editor launches its
    #! REPL as `julia .../terminalserver.jl` — so prefer a frame from the user's own code,
    #! which is what an `include`d script produces. Fall back to the launcher below rather
    #! than recording nothing: it is a truthful answer to how the session started, and it
    #! identifies the front-end. `mm:interactive` is the flag that says not to trust either
    #! for reproduction.
    for frame in stacktrace()
        file = String(frame.file)
        isempty(file) && continue
        p = try
            abspath(file)
        catch
            continue
        end
        startswith(p, _PKG_SOURCE_DIR) && continue
        occursin(joinpath("share", "julia"), p) && continue
        #! Rejects every pseudo-file a front-end can put in a frame — `REPL[3]`, IJulia's
        #! `In[3]`, Pluto cell ids — without sniffing for any of them by name.
        isfile(p) || continue
        #! ...but a real file is not enough. In an interactive session the outermost frame
        #! is whatever drives the REPL — VS Code's `terminalserver.jl`, for instance — which
        #! is a real file that has nothing to do with the user's work. Requiring the frame
        #! to live under the project or working directory keeps genuine `include`d scripts
        #! and drops tooling, without maintaining a denylist of every front-end.
        _isUnderUserRoots(p) || continue
        return p
    end
    return program
end

#! Positive test rather than a denylist: user scripts live in the project they are running,
#! editor and depot machinery does not.
function _isUnderUserRoots(path::AbstractString)
    roots = String[]
    project = Base.active_project()
    isnothing(project) || push!(roots, dirname(abspath(project)))
    try
        push!(roots, pwd())
    catch
    end
    return any(r -> path == r || startswith(path, rstrip(r, '/') * "/"), roots)
end

function _resolveProvenanceID(fields)
    columns = ("session", "script", "interactive", "git_commit", "git_branch", "git_dirty")
    values = (fields.session, fields.script, fields.interactive,
              fields.git_commit, fields.git_branch, fields.git_dirty)
    stamp = Dates.format(now(), "yyyy-mm-ddTHH:MM:SS")
    insert_stmt = SQLite.Stmt(centralDB(), """
        INSERT OR IGNORE INTO provenances ($(join(columns, ", ")), datetime)
        VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING provenance_id;
        """)
    #! No transaction needed. `UNIQUE` makes the insert idempotent, so a losing racer
    #! finds the winner's row; and nothing ever deletes from `provenances`, so the row
    #! cannot vanish between the two statements.
    df = DataFrame(DBInterface.execute(insert_stmt, (values..., stamp)))
    isempty(df) || return Int(df.provenance_id[1])
    where_clause = join(["$(c) = ?" for c in columns], " AND ")
    df = stmtToDataFrame("SELECT provenance_id FROM provenances WHERE $(where_clause);", values)
    return Int(df.provenance_id[1])
end

"""
    currentProvenanceID() -> Int

Resolve the current creation context — session, launching script, session mode, and
git state — to a `provenances` row and return its ID.

Called on entry to `createTrial` and `run`, so the recorded commit and dirty flag
reflect the working tree as of that call.

# Example
```julia
currentProvenanceID()
```
"""
function currentProvenanceID()
    script = launchingScript()
    git = isempty(script) ? (commit="", branch="", dirty="") : gitState(dirname(script))
    #! An interactive session is a reproducibility caveat of the same kind as a dirty
    #! working tree: the script ran, but so did whatever was typed around it, and that
    #! state is not recoverable. Recorded alongside the script rather than replacing it.
    return _resolveProvenanceID((session=_sessionID(), script=script,
                                 interactive=isinteractive() ? "true" : "",
                                 git_commit=git.commit, git_branch=git.branch, git_dirty=git.dirty))
end

"""
    provenanceFor(provenance_id) -> Dict{String,String}

Expand a `provenance_id` into the `mm:` keys it stands for, omitting any whose
stored column is empty.

# Example
```julia
provenanceFor(1)
# Dict("mm:session" => "d4e4a178fd33", "mm:script" => "/Users/you/study/fig3_sweep.jl")
```
"""
function provenanceFor(provenance_id::Integer)
    out = Dict{String,String}()
    tableExists("provenances") || return out
    df = stmtToDataFrame("SELECT * FROM provenances WHERE provenance_id = ?;", (Int(provenance_id),))
    isempty(df) && return out
    for (key, column) in PROVENANCE_COLUMNS
        hasproperty(df, Symbol(column)) || continue
        value = df[1, Symbol(column)]
        (ismissing(value) || isempty(String(value))) && continue
        out[key] = String(value)
    end
    return out
end

#! provenance_ids whose `column` matches `value` (or is simply non-empty when `value` is
#! `nothing`). `script` also matches on basename so a query can name `fig3_sweep.jl`
#! rather than its absolute path.
function _provenanceIDsMatching(column::AbstractString, value::Union{Nothing,AbstractString})
    tableExists("provenances") || return Int[]
    df = if isnothing(value)
        queryToDataFrame("SELECT provenance_id FROM provenances WHERE $(column) != '';")
    elseif column == "script"
        stmtToDataFrame("SELECT provenance_id FROM provenances WHERE script = ? OR script LIKE '%/' || ?;",
                        (String(value), String(value)))
    else
        stmtToDataFrame("SELECT provenance_id FROM provenances WHERE $(column) = ?;", (String(value),))
    end
    return Int.(df.provenance_id)
end

########################################################
############   Automatic application   #################
########################################################

"""
    applyCreationTags(T, id)

Record creation time and provenance on a newly created trial object.

Called from the four object constructors immediately after the database row is
inserted. An object that already carries provenance keeps it, so a `Monad` picking
up replicates in a later session still reports when it was originally created.
"""
function applyCreationTags(::Type{T}, id::Integer) where {T<:AbstractTrial}
    _quietly() do
        table = _tagTable(_tagClass(T))
        columnsExist(["provenance_id", "datetime"], table) || return nothing
        #! Objects can also be built by calling a constructor directly, bypassing the
        #! createTrial/run entry points that normally resolve this.
        isnothing(mm_globals().provenance_id) && refreshProvenance!()
        stamp = Dates.format(now(), "yyyy-mm-ddTHH:MM:SS")
        stmt = SQLite.Stmt(centralDB(), """
            UPDATE $(table) SET datetime = COALESCE(datetime, ?), provenance_id = ?
            WHERE $(tableIDName(table)) = ? AND provenance_id IS NULL;
            """)
        DBInterface.execute(stmt, (stamp, mm_globals().provenance_id, Int(id)))
    end
    _maybeShowTagHint()
    return nothing
end

"""
    refreshProvenance!()

Resolve the current creation context and cache its ID for the constructors to
stamp onto new objects. Called on entry to `createTrial` and `run`.
"""
function refreshProvenance!()
    _quietly() do
        mm_globals().provenance_id = currentProvenanceID()
    end
    return nothing
end

########################################################
############   Reading tags   ##########################
########################################################

#! `trials.datetime` predates tagging and holds `yymmddHHMM`. Normalized on read so
#! `mm:created` reads the same across all four classes; the stored value is left alone,
#! since rewriting it would break anyone already reading that column.
function _normalizeStamp(raw)
    s = String(raw)
    occursin(r"^\d{10}$", s) || return s
    return try
        parts = (parse(Int, s[1:2]) + 2000, parse(Int, s[3:4]), parse(Int, s[5:6]),
                 parse(Int, s[7:8]), parse(Int, s[9:10]))
        Dates.format(DateTime(parts...), "yyyy-mm-ddTHH:MM:SS")
    catch
        s
    end
end

#! Creation time and provenance live in the object's own row, so they are read from
#! there and presented as `mm:` keys.
function _syntheticTags(class::AbstractString, id::Integer)
    out = Dict{String,String}()
    table = _tagTable(class)
    (tableExists(table) && columnsExist(["provenance_id", "datetime"], table)) || return out
    df = stmtToDataFrame("SELECT datetime, provenance_id FROM $(table) WHERE $(tableIDName(table)) = ?;",
                         (Int(id),))
    isempty(df) && return out
    stamp = df.datetime[1]
    ismissing(stamp) || isempty(String(stamp)) || (out[MM_CREATED_KEY] = _normalizeStamp(stamp))
    pid = df.provenance_id[1]
    ismissing(pid) || merge!(out, provenanceFor(Int(pid)))
    return out
end

"""
    tags(target; include_auto::Bool=true) -> Dict{String,Vector{String}}

Return the tags attached directly to a trial object, as a mapping from key to the
sorted list of values stored under that key.

Only tags placed on this exact object are returned; tags inherited from a parent
`Sampling` or `Trial` are not, since inheritance is resolved at query time by
[`findTrials`](@ref). Pass `include_auto=false` to omit the `mm:` keys
ModelManager records itself.

# Example
```julia
tags(sim)
# Dict("mm:created" => ["2026-07-29T14:02:11"], "arm" => ["high_dose"])

tags(sim; include_auto=false)
# Dict("arm" => ["high_dose"])
```
"""
function tags(::Type{T}, id::Integer; include_auto::Bool=true) where {T<:AbstractTrial}
    assertInitialized()
    class = _tagClass(T)
    out = Dict{String,Vector{String}}()
    if include_auto
        for (k, v) in _syntheticTags(class, id)
            out[k] = [v]
        end
    end
    df = stmtToDataFrame("SELECT tag_key, tag_value FROM tags WHERE trial_class=? AND trial_id=?;",
                         (class, Int(id)))
    for row in eachrow(df)
        k = String(row.tag_key)
        (!include_auto && startswith(k, MM_TAG_PREFIX)) && continue
        push!(get!(out, k, String[]), String(row.tag_value))
    end
    for v in values(out)
        sort!(v)
    end
    return out
end

tags(target::AbstractTrial; kwargs...) = tags(typeof(target), target.id; kwargs...)

"""
    hasTag(target, tag) -> Bool

Return `true` if `target` carries `tag` directly.

`tag` may be a `key => value` pair (exact match) or a bare key (any value).

# Example
```julia
hasTag(sim, "arm" => "high_dose")
hasTag(sim, "arm")
```
"""
function hasTag(::Type{T}, id::Integer, tag) where {T<:AbstractTrial}
    d = tags(T, id)
    if tag isa Pair
        key = string(first(tag))
        k = startswith(lowercase(strip(key)), MM_TAG_PREFIX) ? _reservedTagKey(key) : normalizeTagKey(key)
        return haskey(d, k) && _normalizeTagValue(last(tag)) in d[k]
    end
    key = string(tag)
    k = startswith(lowercase(strip(key)), MM_TAG_PREFIX) ? _reservedTagKey(key) : normalizeTagKey(key)
    return haskey(d, k)
end

hasTag(target::AbstractTrial, tag) = hasTag(typeof(target), target.id, tag)

"""
    tagsTable(; include_auto::Bool=true) -> DataFrame
    tagsTable(target; include_auto::Bool=true) -> DataFrame

Return the tag store as a long-format `DataFrame` with columns `Class`, `ID`,
`Key`, `Value`, and `DateTime`.

With no argument the whole store is returned; with a trial object (or a type and
ID) only that object's rows are. Pass `include_auto=false` to omit `mm:` keys.

# Example
```julia
tagsTable()                       # everything
tagsTable(sampling)               # one object
tagsTable(include_auto = false)   # only what a human asserted
```
"""
function tagsTable(; include_auto::Bool=true, limit::Integer=MAX_MATERIALIZED_TRIALS)
    assertInitialized()
    condition = include_auto ? "" : "WHERE tag_key NOT LIKE '$(MM_TAG_PREFIX)%'"
    df = queryToDataFrame("SELECT trial_class, trial_id, tag_key, tag_value, datetime FROM tags $(condition);")
    rename!(df, :trial_class => :Class, :trial_id => :ID, :tag_key => :Key, :tag_value => :Value, :datetime => :DateTime)
    if include_auto
        #! Provenance lives in columns, so the whole-store view has to synthesize a row per
        #! object per `mm:` key — several million on a large project. Refuse rather than
        #! spend the memory; a single object's table and `include_auto=false` are unbounded.
        n_objects = sum(_countTaggableObjects(class) for class in TAG_CLASSES; init=0)
        _assertMaterializable(n_objects, limit, "objects to expand provenance for")
        synthetic = _syntheticTagRows()
        isempty(synthetic) || append!(df, synthetic, promote=true)
    end
    sort!(df, [:Class, :ID, :Key, :Value])
    return df
end

function tagsTable(::Type{T}, id::Integer; include_auto::Bool=true) where {T<:AbstractTrial}
    assertInitialized()
    class = _tagClass(T)
    extra = include_auto ? "" : " AND tag_key NOT LIKE '$(MM_TAG_PREFIX)%'"
    df = stmtToDataFrame(
        "SELECT trial_class, trial_id, tag_key, tag_value, datetime FROM tags WHERE trial_class=? AND trial_id=?$(extra);",
        (class, Int(id)))
    rename!(df, :trial_class => :Class, :trial_id => :ID, :tag_key => :Key, :tag_value => :Value, :datetime => :DateTime)
    if include_auto
        synthetic = _syntheticTags(class, id)
        stamp = get(synthetic, MM_CREATED_KEY, missing)
        for (k, v) in synthetic
            push!(df, (Class=class, ID=Int(id), Key=k, Value=v, DateTime=stamp); promote=true)
        end
    end
    sort!(df, [:Key, :Value])
    return df
end

tagsTable(target::AbstractTrial; kwargs...) = tagsTable(typeof(target), target.id; kwargs...)

function _countTaggableObjects(class::AbstractString)
    table = _tagTable(class)
    (tableExists(table) && columnsExist(["provenance_id", "datetime"], table)) || return 0
    return queryToDataFrame("SELECT COUNT(*) AS n FROM $(table) WHERE provenance_id IS NOT NULL OR datetime IS NOT NULL;").n[1]
end

#! The whole-store view of the column-backed `mm:` keys.
function _syntheticTagRows()
    rows = NamedTuple[]
    provenance_cache = Dict{Int,Dict{String,String}}()
    for class in TAG_CLASSES
        table = _tagTable(class)
        (tableExists(table) && columnsExist(["provenance_id", "datetime"], table)) || continue
        df = queryToDataFrame("SELECT $(tableIDName(table)) AS id, datetime, provenance_id FROM $(table);")
        for row in eachrow(df)
            stamp = row.datetime
            has_stamp = !ismissing(stamp) && !isempty(String(stamp))
            normalized = has_stamp ? _normalizeStamp(stamp) : missing
            has_stamp && push!(rows, (Class=class, ID=Int(row.id), Key=MM_CREATED_KEY,
                                      Value=normalized, DateTime=normalized))
            ismissing(row.provenance_id) && continue
            pid = Int(row.provenance_id)
            expanded = get!(() -> provenanceFor(pid), provenance_cache, pid)
            for (k, v) in expanded
                push!(rows, (Class=class, ID=Int(row.id), Key=k, Value=v, DateTime=normalized))
            end
        end
    end
    return DataFrame(rows)
end

"""
    printTagsTable(args...; sink=println, kwargs...)

Print the table produced by [`tagsTable`](@ref).

# Example
```julia
printTagsTable(include_auto = false)
```
"""
function printTagsTable(args...; sink=println, kwargs...)
    sink(tagsTable(args...; kwargs...))
    return nothing
end

"""
    tagKeys(; include_auto::Bool=false) -> Vector{String}

Return the sorted list of tag keys currently in use.

This is the cheap way to discover the vocabulary you have actually been using and
to spot typos (`"cohort"` alongside `"chohort"`). ModelManager's own `mm:` keys
are omitted by default.

# Example
```julia
tagKeys()
# ["arm", "figure", "project", "purpose"]
```
"""
function tagKeys(; include_auto::Bool=false)
    assertInitialized()
    condition = include_auto ? "" : "WHERE tag_key NOT LIKE '$(MM_TAG_PREFIX)%'"
    df = queryToDataFrame("SELECT DISTINCT tag_key FROM tags $(condition) ORDER BY tag_key;")
    keys = String.(df.tag_key)
    include_auto || return keys
    isempty(_objectsWithSyntheticKey(MM_CREATED_KEY, nothing)) || push!(keys, MM_CREATED_KEY)
    for (key, column) in PROVENANCE_COLUMNS
        isempty(_provenanceIDsMatching(column, nothing)) || push!(keys, key)
    end
    return sort!(unique!(keys))
end

"""
    tagValues(key) -> Vector{String}

Return the sorted list of distinct values stored under `key`.

# Example
```julia
tagValues("arm")
# ["anti_pd1", "control"]
```
"""
function tagValues(key)
    assertInitialized()
    k = startswith(lowercase(strip(string(key))), MM_TAG_PREFIX) ?
        _reservedTagKey(string(key)) : normalizeTagKey(key)
    column = _provenanceColumn(k)
    if !isnothing(column)
        df = queryToDataFrame("SELECT DISTINCT $(column) AS v FROM provenances WHERE $(column) != '' ORDER BY $(column);")
        return String.(df.v)
    end
    if k == MM_CREATED_KEY
        out = String[]
        for class in TAG_CLASSES
            table = _tagTable(class)
            (tableExists(table) && columnsExist(["datetime"], table)) || continue
            df = queryToDataFrame("SELECT DISTINCT datetime FROM $(table) WHERE datetime IS NOT NULL;")
            append!(out, _normalizeStamp.(skipmissing(df.datetime)))
        end
        return sort!(unique!(out))
    end
    df = stmtToDataFrame("SELECT DISTINCT tag_value FROM tags WHERE tag_key=? ORDER BY tag_value;", (k,))
    return String.(df.tag_value)
end

"""
    recommendedTagKeys() -> NTuple{6,String}

Return the small vocabulary of tag keys ModelManager suggests as a starting point:
`project`, `purpose`, `figure`, `arm`, `verdict`, `note`.

These are recommendations only — any key matching the rules in [`tag!`](@ref) is
accepted. A shared vocabulary mostly helps so that scripts written months apart
remain mutually searchable.

# Example
```julia
recommendedTagKeys()
# ("project", "purpose", "figure", "arm", "verdict", "note")
```
"""
recommendedTagKeys() = RECOMMENDED_TAG_KEYS

########################################################
############   Hints   #################################
########################################################

"""
    setTagHints!(on::Bool)

Enable or disable the one-time-per-session hint shown when trials are created
without any user tags. Returns the new setting.

ModelManager also honors the `MODELMANAGER_TAG_HINTS` environment variable, so the
hints can be silenced without changing code — the better option in a job script.

# Example
```julia
setTagHints!(false)
```
```sh
MODELMANAGER_TAG_HINTS=0 julia scripts/GenerateData.jl
```
"""
function setTagHints!(on::Bool)
    mm_globals().tag_hints = on
    return on
end

function _tagHintsEnabled()
    get(ENV, "MODELMANAGER_TAG_HINTS", "1") == "0" && return false
    return mm_globals().tag_hints
end

function _maybeShowTagHint()
    g = mm_globals()
    (g.tag_hint_shown || !_tagHintsEnabled()) && return nothing
    g.tag_hint_shown = true
    captured = Dict(MM_CREATED_KEY => Dates.format(now(), "yyyy-mm-ddTHH:MM:SS"))
    isnothing(g.provenance_id) || merge!(captured, _quietly(() -> provenanceFor(g.provenance_id)) |> x -> isnothing(x) ? Dict{String,String}() : x)
    @info """
    ModelManager recorded this trial's provenance automatically:
        $(join(["$(k)=$(v)" for (k, v) in sort(collect(captured))], ", "))
    Add your own tags to make these easier to recover later:
        createTrial(inputs, variations; tags = ("project" => "...", "arm" => "..."))
        run(trial; tags = ("project" => "...",))
        tag!(sim, "verdict" => "good")          # or retroactively, after looking at results
    Recommended keys: $(join(RECOMMENDED_TAG_KEYS, ", ")).
    Silence with `setTagHints!(false)`, or set MODELMANAGER_TAG_HINTS=0 in your environment.
    """
    return nothing
end

########################################################
############   Retrieval   #############################
########################################################

#! Objects whose column-backed `mm:` key matches, across all four classes.
function _objectsWithSyntheticKey(k::AbstractString, v::Union{Nothing,AbstractString})
    rows = NamedTuple{(:trial_class, :trial_id),Tuple{String,Int}}[]
    column = _provenanceColumn(k)
    pids = isnothing(column) ? Int[] : _provenanceIDsMatching(column, v)
    (isnothing(column) || !isempty(pids)) || return DataFrame(trial_class=String[], trial_id=Int[])
    for class in TAG_CLASSES
        table = _tagTable(class)
        (tableExists(table) && columnsExist(["provenance_id", "datetime"], table)) || continue
        df = if !isnothing(column)
            queryToDataFrame("SELECT $(tableIDName(table)) AS id FROM $(table) WHERE provenance_id IN ($(join(pids, ",")));")
        elseif isnothing(v)
            queryToDataFrame("SELECT $(tableIDName(table)) AS id FROM $(table) WHERE datetime IS NOT NULL;")
        else
            stmtToDataFrame("SELECT $(tableIDName(table)) AS id FROM $(table) WHERE datetime = ?;", (String(v),))
        end
        for row in eachrow(df)
            push!(rows, (trial_class=class, trial_id=Int(row.id)))
        end
    end
    return DataFrame(rows)
end

function _taggedObjects(k::AbstractString, v::Union{Nothing,AbstractString})
    _isSyntheticKey(k) && return _objectsWithSyntheticKey(k, v)
    if isnothing(v)
        return stmtToDataFrame("SELECT trial_class, trial_id FROM tags WHERE tag_key=?;", (k,))
    end
    return stmtToDataFrame("SELECT trial_class, trial_id FROM tags WHERE tag_key=? AND tag_value=?;", (k, v))
end

function _filterToKeyValue(filter)
    if filter isa Pair
        key = string(first(filter))
        k = startswith(lowercase(strip(key)), MM_TAG_PREFIX) ? _reservedTagKey(key) : normalizeTagKey(key)
        return (k, _normalizeTagValue(last(filter)))
    end
    key = string(filter)
    k = startswith(lowercase(strip(key)), MM_TAG_PREFIX) ? _reservedTagKey(key) : normalizeTagKey(key)
    #! A bare key in a *query* means "has this key with any value", whereas a bare
    #! key in `tag!` writes an empty value. Both are the natural reading in context.
    return (k, nothing)
end

function _simulationIDsMatching(filter, inherit::Bool)
    k, v = _filterToKeyValue(filter)
    df = _taggedObjects(k, v)
    out = Set{Int}()
    for row in eachrow(df)
        class = String(row.trial_class)
        id = Int(row.trial_id)
        if class == "simulation"
            push!(out, id)
        elseif inherit
            if class == "monad"
                union!(out, constituentIDs(Monad, id))
            elseif class == "sampling"
                union!(out, samplingSimulationIDs(id))
            elseif class == "trial"
                union!(out, trialSimulationIDs(id))
            end
        end
    end
    return out
end

function _monadIDsMatching(filter, inherit::Bool)
    k, v = _filterToKeyValue(filter)
    df = _taggedObjects(k, v)
    out = Set{Int}()
    for row in eachrow(df)
        class = String(row.trial_class)
        id = Int(row.trial_id)
        if class == "monad"
            push!(out, id)
        elseif inherit
            if class == "sampling"
                union!(out, constituentIDs(Sampling, id))
            elseif class == "trial"
                for s in constituentIDs(Trial, id)
                    union!(out, constituentIDs(Sampling, s))
                end
            end
        end
    end
    return out
end

function _idsMatchingDirect(class::AbstractString, filter)
    k, v = _filterToKeyValue(filter)
    df = _taggedObjects(k, v)
    return Set(Int(row.trial_id) for row in eachrow(df) if String(row.trial_class) == class)
end

function _combineFilters(matcher, all_of, any_of)
    result = nothing
    if !isnothing(all_of)
        for f in all_of
            s = matcher(f)
            result = isnothing(result) ? s : intersect(result, s)
            isempty(result) && return result
        end
    end
    if !isnothing(any_of)
        u = Set{Int}()
        for f in any_of
            union!(u, matcher(f))
        end
        result = isnothing(result) ? u : intersect(result, u)
    end
    return result
end

function _assertMaterializable(n::Integer, limit::Integer, what::AbstractString)
    n <= limit && return nothing
    throw(ArgumentError("""
    This query matches $(n) $(what), above the limit of $(limit).
    Constructing that many objects is rarely what you want — with `inherit=true` a tag on a
    parent expands to every object beneath it.
    Either work with IDs (`findSimulationIDs(...)`, which feeds `simulationsTable` directly),
    narrow the query, or pass `limit=$(n)` to override.
    """))
end

"""
    findSimulationIDs(; tags=nothing, any_of=nothing, status=nothing, inherit=true) -> Vector{Int}

Return the sorted IDs of simulations matching the given tag filters.

- `tags`: a collection of filters that must **all** match (`AND`). Each filter is
  a `key => value` pair for an exact match, or a bare key meaning "has this key
  with any value".
- `any_of`: a collection of filters of which **at least one** must match (`OR`).
  Combined with `tags` by intersection when both are given.
- `status`: restrict to simulations with this status code, e.g. `"Completed"`.
- `inherit`: when `true` (the default), a tag on a `Monad`, `Sampling`, or `Trial`
  also matches its constituent simulations. Set to `false` to match only tags
  placed directly on simulations.

Results are always intersected with the simulations that actually exist, so tag
rows orphaned by an interrupted deletion never surface.

This is the ID-returning form; use it for large result sets and feed it straight
into [`simulationsTable`](@ref). [`findSimulations`](@ref) returns constructed
`Simulation` objects instead.

# Example
```julia
ids = findSimulationIDs(tags = ("project" => "immune-escape", "arm" => "control"),
                        status = "Completed")
simulationsTable(ids)
```
"""
function findSimulationIDs(; tags=nothing, any_of=nothing, status=nothing, inherit::Bool=true)
    assertInitialized()
    matcher = f -> _simulationIDsMatching(f, inherit)
    matched = _combineFilters(matcher, tags, any_of)
    #! An empty match short-circuits: `IN ()` is not valid SQL.
    if !isnothing(matched) && isempty(matched)
        return Int[]
    end
    #! One query bounded by the match, rather than pulling every simulation id to intersect
    #! a handful against. Also drops tag rows orphaned by an interrupted deletion, since a
    #! matched id that no longer exists simply fails to come back.
    conditions = String[]
    isnothing(matched) || push!(conditions, "simulation_id IN ($(join(sort!(collect(matched)), ",")))")
    isnothing(status) || push!(conditions, "status_code_id=$(statusCodeID(status))")
    where_clause = isempty(conditions) ? "" : "WHERE " * join(conditions, " AND ")
    df = queryToDataFrame("SELECT simulation_id FROM simulations $(where_clause) ORDER BY simulation_id;")
    _maybeShowRecoveryHint()
    return Int.(df.simulation_id)
end

"""
    findSimulations(; limit=MAX_MATERIALIZED_TRIALS, kwargs...) -> Vector{Simulation}

Return the `Simulation` objects matching the given tag filters.

Accepts the same keyword arguments as [`findSimulationIDs`](@ref), plus `limit`.
Objects are built in a single query, but a very large result set is still
expensive to hold — so this throws above `limit` rather than materializing it. Use
[`findSimulationIDs`](@ref) when you only need IDs.

# Example
```julia
sims = findSimulations(tags = ("figure" => "3b",))
```
"""
function findSimulations(; limit::Integer=MAX_MATERIALIZED_TRIALS, kwargs...)
    ids = findSimulationIDs(; kwargs...)
    _assertMaterializable(length(ids), limit, "simulations")
    return simulationsFromIDs(ids)
end

"""
    findMonads(; tags=nothing, any_of=nothing, inherit=true, limit=MAX_MATERIALIZED_TRIALS) -> Vector{Monad}

Return the `Monad` objects matching the given tag filters.

Behaves like [`findSimulationIDs`](@ref) one level up the hierarchy: with
`inherit=true` a tag on a `Sampling` or `Trial` matches its constituent monads.
Tags placed on individual simulations never propagate upward.

# Example
```julia
findMonads(tags = ("project" => "immune-escape",))
```
"""
function findMonads(; tags=nothing, any_of=nothing, inherit::Bool=true,
                    limit::Integer=MAX_MATERIALIZED_TRIALS)
    assertInitialized()
    matcher = f -> _monadIDsMatching(f, inherit)
    ids = _combineFilters(matcher, tags, any_of)
    existing = Set(monadIDs())
    ids = isnothing(ids) ? existing : intersect(ids, existing)
    _assertMaterializable(length(ids), limit, "monads")
    return Monad.(sort!(collect(ids)))
end

"""
    findTrials(T::Type{<:AbstractTrial}; tags=nothing, any_of=nothing, inherit=true, status=nothing, limit=MAX_MATERIALIZED_TRIALS)

Return the objects of type `T` matching the given tag filters.

`T` may be `Simulation`, `Monad`, `Sampling`, or `Trial`. For `Simulation` and
`Monad` this dispatches to [`findSimulations`](@ref) and [`findMonads`](@ref),
which support downward inheritance. For `Sampling` and `Trial` only tags placed
directly on those objects are considered, since there is nothing above them to
inherit from.

# Example
```julia
findTrials(Simulation; tags = ("project" => "immune-escape",), status = "Completed")
findTrials(Sampling;   tags = ("purpose" => "sensitivity",))
```

See also [`tag!`](@ref).
"""
findTrials(::Type{Simulation}; kwargs...) = findSimulations(; kwargs...)
findTrials(::Type{Monad}; kwargs...) = findMonads(; kwargs...)

function findTrials(::Type{T}; tags=nothing, any_of=nothing, inherit::Bool=true, status=nothing,
                    limit::Integer=MAX_MATERIALIZED_TRIALS) where {T<:AbstractTrial}
    assertInitialized()
    isnothing(status) || throw(ArgumentError("`status` filtering applies to simulations only; got $(T)."))
    class = _tagClass(T)
    matcher = f -> _idsMatchingDirect(class, f)
    ids = _combineFilters(matcher, tags, any_of)
    df = queryToDataFrame("SELECT $(tableIDName(_tagTable(class))) FROM $(_tagTable(class));")
    existing = Set(Int.(df[!, 1]))
    ids = isnothing(ids) ? existing : intersect(ids, existing)
    _assertMaterializable(length(ids), limit, "$(class)s")
    return T.(sort!(collect(ids)))
end

function _maybeShowRecoveryHint()
    g = mm_globals()
    (g.tag_recovery_hint_shown || !_tagHintsEnabled()) && return nothing
    #! Latch before deciding, not after: once any user tag exists the hint is never shown
    #! again, and leaving the latch clear would re-run this probe on every single query.
    #! `LIMIT 1` rather than `COUNT(*)`, since only existence matters.
    g.tag_recovery_hint_shown = true
    has_user_tags = !isempty(queryToDataFrame(
        "SELECT 1 AS n FROM tags WHERE tag_key NOT LIKE '$(MM_TAG_PREFIX)%' LIMIT 1;"))
    has_user_tags && return nothing
    @info """
    No user tags are stored in this database yet — only ModelManager's automatic provenance.
    You can label simulations retroactively, which is often the easiest way to start:
        tag!(findSimulationIDs(status = "Completed"), "project" => "...")
    Recommended keys: $(join(RECOMMENDED_TAG_KEYS, ", ")).
    Silence with `setTagHints!(false)`, or set MODELMANAGER_TAG_HINTS=0 in your environment.
    """
    return nothing
end

########################################################
############   Table integration   #####################
########################################################

#! Descendants of a tagged parent, restricted to the classes that can inherit from it.
function _inheritedIDs(::Type{Simulation}, class::AbstractString, id::Int)
    class == "monad" && return constituentIDs(Monad, id)
    class == "sampling" && return samplingSimulationIDs(id)
    class == "trial" && return trialSimulationIDs(id)
    return Int[]
end

function _inheritedIDs(::Type{Monad}, class::AbstractString, id::Int)
    class == "sampling" && return constituentIDs(Sampling, id)
    class == "trial" && return reduce(vcat, (constituentIDs(Sampling, s) for s in constituentIDs(Trial, id)); init=Int[])
    return Int[]
end

_inheritedIDs(::Type{T}, ::AbstractString, ::Int) where {T<:AbstractTrial} = Int[]

"""
    appendTags!(df, T, id_column; include_auto=false, inherit=true)

Pivot the tags of the objects listed in `df[!, id_column]` into columns and append
them, returning `df`.

Column names are prefixed with `tag:` so they can never collide with the folder,
parameter, or ID columns already produced by [`simulationsTable`](@ref). A key
carrying several values on one object is rendered as its values joined by `|`.
Objects with no value for a key get `missing`.

With `inherit=true` (the default) a tag on a parent object contributes to its
constituents' columns, matching [`findSimulationIDs`](@ref) — otherwise a
simulation recovered *by* a sampling-level tag would show no column for it.

Used by `simulationsTable(...; tags = true)`; call it directly only to pivot tags
onto a table you have built yourself.

# Example
```julia
df = simulationsTable(ids)
appendTags!(df, Simulation, :SimID)                  # adds tag:<key> columns
appendTags!(df, Simulation, :SimID; inherit = false) # only tags on the simulations
```
"""
function appendTags!(df::DataFrame, ::Type{T}, id_column::Symbol;
                     include_auto::Bool=false, inherit::Bool=true) where {T<:AbstractTrial}
    (isempty(df) || !hasproperty(df, id_column)) && return df
    tableExists("tags") || return df
    ids = Int.(df[!, id_column])
    isempty(ids) && return df
    id_set = Set(ids)

    #! key => (object id => values)
    collected = Dict{String,Dict{Int,Vector{String}}}()
    function record!(key, id, value)
        by_id = get!(collected, key, Dict{Int,Vector{String}}())
        values = get!(by_id, id, String[])
        value in values || push!(values, value)
    end

    auto_condition = include_auto ? "" : " AND tag_key NOT LIKE '$(MM_TAG_PREFIX)%'"
    direct = queryToDataFrame("""
        SELECT trial_id, tag_key, tag_value FROM tags
        WHERE trial_class='$(_tagClass(T))' AND trial_id IN ($(join(ids, ",")))$(auto_condition);
        """)
    for row in eachrow(direct)
        record!(String(row.tag_key), Int(row.trial_id), String(row.tag_value))
    end

    if include_auto
        for id in ids, (k, v) in _syntheticTags(_tagClass(T), id)
            record!(k, id, v)
        end
    end

    if inherit
        #! Only user tags are expanded, which keeps this to the handful of parents a
        #! human actually labeled rather than every object in the project.
        parents = queryToDataFrame("""
            SELECT trial_class, trial_id, tag_key, tag_value FROM tags
            WHERE trial_class != '$(_tagClass(T))' AND tag_key NOT LIKE '$(MM_TAG_PREFIX)%';
            """)
        #! Keyed by the parent object, not the tag row: a sampling with ten tags would
        #! otherwise walk its constituent CSVs ten times.
        descendant_cache = Dict{Tuple{String,Int},Vector{Int}}()
        for row in eachrow(parents)
            class, pid = String(row.trial_class), Int(row.trial_id)
            descendants = get!(() -> _inheritedIDs(T, class, pid), descendant_cache, (class, pid))
            isempty(descendants) && continue
            key = String(row.tag_key)
            value = String(row.tag_value)
            for d in descendants
                d in id_set || continue
                record!(key, d, value)
            end
        end
    end

    for key in sort(collect(keys(collected)))
        by_id = collected[key]
        df[!, Symbol("tag:$(key)")] = [haskey(by_id, id) ? join(sort(by_id[id]), "|") : missing for id in ids]
    end
    return df
end

########################################################
############   Maintenance   ###########################
########################################################

"""
    deleteTagsFor(T, ids)

Remove every tag row pointing at the given objects. Called from the deletion
routines in `deletion.jl`; not part of the public API.

SQLite cannot enforce a foreign key on the polymorphic `trial_class`/`trial_id`
pair, so this is the mechanism that keeps the tag store consistent with the
central tables.
"""
function deleteTagsFor(::Type{T}, ids::AbstractVector{<:Integer}) where {T<:AbstractTrial}
    isempty(ids) && return nothing
    isInitialized() || return nothing
    tableExists("tags") || return nothing
    DBInterface.execute(centralDB(),
        "DELETE FROM tags WHERE trial_class='$(_tagClass(T))' AND trial_id IN ($(join(Int.(ids), ",")));")
    return nothing
end

"""
    orphanedTagCounts() -> Dict{String,Int}

Return, per trial class, the number of tag rows pointing at objects that no longer
exist. Used by `databaseDiagnostics`.

A healthy database returns zeros for every class. Non-zero counts mean tag rows
outlived their objects — usually an interrupted deletion.

# Example
```julia
orphanedTagCounts()
# Dict("simulation" => 0, "monad" => 0, "sampling" => 0, "trial" => 0)
```
"""
function orphanedTagCounts()
    assertInitialized()
    out = Dict{String,Int}()
    for class in TAG_CLASSES
        table = _tagTable(class)
        tableExists(table) || continue
        df = queryToDataFrame("""
            SELECT COUNT(*) AS n FROM tags
            WHERE trial_class='$(class)'
              AND trial_id NOT IN (SELECT $(tableIDName(table)) FROM $(table));
            """)
        out[class] = df.n[1]
    end
    return out
end
