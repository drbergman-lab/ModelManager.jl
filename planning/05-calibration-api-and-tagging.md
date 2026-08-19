# Design Brief: Unify the calibration entry points, and settle `description` vs tagging

> **Order:** 5 of 8. **Requires brief 04 to have landed** (it provides `AbstractTaggable`, so
> `tag!(calibration, …)` works and `Calibration` is a tag class).
>
> **Gate for briefs 06–08** — it settles the keyword surface they must match. Brief 06 touches disjoint
> regions of `abc.jl` (`~:1096-1328` and `visualize.jl`) from this brief's entrypoint section (`~:265-403`)
> and serializer section (`~:436-469`, `~:1071-1094`), so **05 ∥ 06 is the one safe parallel pair** — at
> worst a trivial merge.

> **⚠ Line-number anchors were verified at commit `403530e`, before PRs #30 (migration guard),
> #31 (accessor gaps) and #32 (calibration `Sampling` views + tagging) merged.** Those PRs added ~237 lines to
> `src/tags.jl`, ~370 to `src/calibration/calibration.jl`, and touched `src/classes.jl`, `src/sensitivity.jl`,
> `src/ModelManager.jl`, `src/database.jl` and `src/calibration/abc.jl`. Every **symbol** named below still
> exists; some **line numbers have shifted**. Locate each anchor by symbol name (`rg 'functionName' src/`) and
> re-verify before relying on it. `src/runner.jl` is unaffected.

## Preflight

1. Read `CLAUDE.md`: the design-brief-first workflow, `camelCase` functions / `snake_case` kwargs, the
   `@ref`-public-bindings-only rule, and the Definition of Done.
2. Read `docs/src/man/calibration.md` and the calibration entry in `README.md`'s Implementation Status.
3. Per CLAUDE.md step 2: update `PRD.md` and open a dated `progress.md` entry.
4. `git branch feature/unify-calibration-api`, then have the user check it out before you code.
5. All paths are repo-relative. Work only inside your worktree.

## Motivation

The four calibration entry points — `runABC`, `runCalibration`, `resumeABC`, `ABCSMC` — disagree on shape,
and the disagreement has already produced defects: `ABCSMC(store_rejected=true)` is unreachable through
`runABC`; the 13 method defaults are written out in **five** places (three in `src/`, twice more inlined in
tests); `resumeABC` and `runCalibration` each carry a verbatim copy of the same six-step setup; and the
manual documents a `runABC(problem; method=method)` call that throws. Separately,
`_ProblemManifest.observed_data::Dict{String,Any}` (`src/calibration/abc.jl:498`) makes `runCalibration`
**crash** for the `Vector`/scalar `observed_data` that `mseDistance` documents as supported.

And `description` — the second half of this brief — is write-only dead weight: inserted at
`src/calibration/calibration.jl:36-49` and never read, with no `SELECT` against the `calibrations` table
anywhere in `src/`.

## Scope

- **Files affected:**
  - `src/calibration/abc.jl` — `runCalibration` (`:298-323`), `runABC` (`:373-403`), `resumeABC` (`:1026-1064`),
    `_saveMethod` (`:441-469`), `_loadMethod` (`:1071-1094`), `_ProblemManifest` (`:495-503`), new
    `_prepareCalibrationRun` / `_executeCalibrationRun` / `_resolveRunControls` / `_methodFromKeywords`
  - `src/calibration/methods.jl` — `ABCSMC` docstring (`:132-215`); the keyword constructor (`:232-285`)
    becomes the sole source of defaults
  - `src/calibration/problem.jl` — the `AbstractMonad` constructor's missing `reference_variation_id` kwarg
  - `src/calibration/calibration.jl` — `calibrationMonadIDs` (if brief 04 has not already fixed it)
  - `src/ModelManager.jl` — export manifest
  - `docs/src/man/calibration.md:107`, `PRD.md`, `README.md`, `test/runtests.jl`
- **New files:** none.
- **Breaking changes:** one deprecation (`resumeABC` → `resumeCalibration`) with a `depwarn` shim. No schema
  change, no `up.jl` milestone.

## Proposed Architecture

### The unified surface

One rule, written into the manual: **required inputs are positional; overrides and run controls are keyword.**

| Function | Shape | Role |
|---|---|---|
| `ABCSMC(; …13 kwargs)` | keyword-only | the single source of truth for every method default |
| `runCalibration(problem, method; description, tags, run_kwargs, progress, on_monad_failure)` | 2 positional | canonical entry point; the concrete method of the `function runCalibration end` stub at `src/calibration/methods.jl:290` |
| `runABC(problem; method=nothing, kwargs...)` | 1 positional | thin convenience wrapper; names no defaults |
| `resumeCalibration(calibration; problem, method, tags, run_kwargs, progress, on_monad_failure)` | 1 positional | method-agnostic resume; dispatches on the loaded method |

**`runABC` survives and gains `method::ABCSMC`.** The docs at `docs/src/man/calibration.md:107` already
advertise `runABC(problem; method=method)` — that is evidence about what users expect, and making it true is
cheaper than deleting it from three docstrings, the manual and two README lines.

```julia
function runABC(problem::CalibrationProblem;
                method::Union{Nothing,ABCSMC}=nothing,
                run_kwargs::NamedTuple=(;), description::String="", tags=(),
                progress::Symbol=:auto, on_monad_failure::Symbol=:reject,
                kwargs...)
    resolved = if isnothing(method)
        _methodFromKeywords(ABCSMC, kwargs)
    else
        isempty(kwargs) || throw(ArgumentError(
            "runABC received both `method=` and method setting(s) " *
            "$(join(keys(kwargs), ", ")). Pass one or the other, not both."))
        method
    end
    return runCalibration(problem, resolved; description=description, tags=tags,
                          run_kwargs=run_kwargs, progress=progress,
                          on_monad_failure=on_monad_failure)
end
```

This removes the second copy of the defaults, makes `store_rejected` reachable, and makes every *future*
`ABCSMC` field reachable through `runABC` with no edit. Guard the keyword split so a typo does not become an
opaque `MethodError`:

```julia
#! Not ABCSMC fields — named explicitly above so the kwargs... splat cannot swallow
#! them into ABCSMC(; ...). Extend this tuple, not the splat, for a new run control.
const _RUN_CONTROL_KEYWORDS = (:method, :run_kwargs, :description, :tags, :progress, :on_monad_failure)

function _methodFromKeywords(::Type{ABCSMC}, kwargs)
    unknown = setdiff(keys(kwargs), fieldnames(ABCSMC))
    isempty(unknown) || throw(ArgumentError("""
    runABC received unrecognized keyword argument(s): $(join(unknown, ", ")).
    Method settings are the fields of `ABCSMC`: $(join(fieldnames(ABCSMC), ", ")).
    Run controls are: $(join(_RUN_CONTROL_KEYWORDS, ", ")).
    """))
    return ABCSMC(; kwargs...)
end
```

⚠ **`tags` must be named explicitly** in `runABC`'s signature and listed in `_RUN_CONTROL_KEYWORDS`, or the
splat swallows it into `ABCSMC(; …)` and throws. This is why brief 04 comes first and this brief owns the
`tags=` keyword.

### Killing the triplication — five sites, not three

Beyond the keyword constructor, `runABC`'s signature, and `_loadMethod`'s `get(d, key, default)` reads, the
field list is inlined **twice more in the test suite**: `test/runtests.jl:1451-1467` and `:1543-1573` each
hand-build the `method.toml` dict because `_saveMethod` takes a `Calibration` and needs a real
`calibrationFolder`. Those tests verify a *copy* of the serializer, not the serializer. Fix all five with one
table plus a path-taking split:

```julia
#! Single source of truth for method.toml's scalar keys. Adding an ABCSMC field means
#! touching exactly three places: the struct, the keyword constructor, and this tuple.
const _ABCSMC_TOML_SCALARS = (
    :population_size      => Int,     :max_nr_populations   => Int,
    :minimum_epsilon      => Float64, :epsilon_quantile     => Float64,
    :min_acceptance_rate  => Float64, :min_epsilon_decrease => Float64,
    :min_ess_fraction     => Float64, :accept_overflow      => Bool,
    :cdf_grid_k           => Int,     :max_evaluations      => Int,
    :store_rejected       => Bool,
)

function _saveMethod(path::String, method::ABCSMC)
    d = Dict{String,Any}("type" => "ABCSMC",
                         "perturbation_kernel" => _serializeKernel(method.perturbation_kernel))
    for (name, _) in _ABCSMC_TOML_SCALARS
        v = getfield(method, name)
        isnothing(v) || (d[string(name)] = v)     # TOML has no null: omit, don't write
    end
    isnothing(method.epsilon_schedule) || (d["epsilon_schedule"] = method.epsilon_schedule)
    open(path, "w") do io; TOML.print(io, d); end
    return path
end
_saveMethod(cal::Calibration, m::ABCSMC) =
    _saveMethod(joinpath(calibrationFolder(cal), "method.toml"), m)

function _loadMethod(::Type{ABCSMC}, d::AbstractDict)
    kw = Dict{Symbol,Any}()
    for (name, T) in _ABCSMC_TOML_SCALARS
        haskey(d, string(name)) && (kw[name] = convert(T, d[string(name)]))
    end
    haskey(d, "epsilon_schedule") && (kw[:epsilon_schedule] = Float64.(d["epsilon_schedule"]))
    haskey(d, "perturbation_kernel") &&
        (kw[:perturbation_kernel] = _deserializeKernel(d["perturbation_kernel"]))
    return ABCSMC(; kw...)     # the keyword constructor supplies every omitted default
end
```

`_loadMethod(cal)` then reads the file, dispatches on `get(d, "type", "ABCSMC")`, and errors with the known
type names on an unrecognized value. **The `"type"` key is new and defaults to `"ABCSMC"` when absent, so
every existing `method.toml` still loads.** It is also what makes `resumeCalibration` method-agnostic, and it
gives the write-only `calibrations.method` column a queryable mirror.

### One shared pre-flight

`_resolveVerbosity` + `_validateEvaluationFailurePolicy` appear verbatim at `abc.jl:302-303` and `:1032-1033`,
and a third time inside `_buildEvaluateBatch` (`:138`); `param_names`/`priors` extraction is verbatim at
`:309-310` and `:1040-1041`; the bank/evaluate/`on_generation` trio is verbatim at `:313-320` and `:1054-1061`.

```julia
_resolveRunControls(progress, on_monad_failure) =
    (_validateEvaluationFailurePolicy(on_monad_failure); _resolveVerbosity(progress))

struct _CalibrationRunPlan
    calibration::Calibration
    problem::CalibrationProblem
    method::ABCSMC
    param_names::Vector{String}
    priors::Vector{<:Distribution}   # built once per run; abstract eltype is not a hot path
    bank::SimulationBank
    evaluate_batch::Function
    on_generation::Function
    verbosity::Symbol
end

function _prepareCalibrationRun(calibration, problem, method, run_kwargs,
                                verbosity, on_monad_failure) → _CalibrationRunPlan

function _executeCalibrationRun(plan;
        start_generations::Vector{GenerationResult}=GenerationResult[]) → ABCResult
```

`runCalibration`'s body becomes ~8 lines and `resumeCalibration`'s ~14. **Keep the guard inside
`_buildEvaluateBatch`** with a `#!` comment saying it is the consumer-side assertion for a private function,
and that the front door validates before `createCalibration` so a typo cannot leave a stray DB row and folder
— otherwise a future reader will "de-duplicate" it away.

### Naming: `runCalibration` vs `run(method, problem)`

*For* `run`: `Base.run` is already imported and overloaded (`src/runner.jl:1`, `src/user_api.jl:1`, and
`run(::GSAMethod, …)` at `src/sensitivity.jl:66-79`), so `run(ABCSMC(), problem)` would mirror
`run(MOAT(), inputs, avs)`.

*Against:* (i) GSA has one entry point, calibration has two — `run` would need a sibling `run(::Calibration)`
for resume, which reads as "run that trial" and becomes a genuine dispatch hazard now that brief 04 has put
`Calibration` under `AbstractTaggable`; (ii) the repo's own GSA precedent is *named dispatch stub plus thin
`run` sugar* — `runSensitivitySampling` (`src/sensitivity.jl:174`) is the stub, `run` is three lines on top —
and calibration's stub already exists at `methods.jl:290`; (iii) adding a second spelling of one operation is
the opposite of unification.

**Recommendation: keep `runCalibration` canonical; do not add `run(::AbstractCalibrationMethod, …)` here.**
Revisit it in brief 07, where the GSA-symmetry question actually belongs — and note brief 07 targets
`runSensitivity(inputs, priors, …)` / `runABC(inputs, priors, data, …)`, so **the argument-order decision must
agree between the two briefs.** Flag whatever you settle here in `progress.md` for brief 07 to match.

### `resumeABC` → `resumeCalibration`

Method-agnostic by construction (it loads the method and dispatches), so a future BayesFlow or
`GPAcceleratedABC` resumes through the same door rather than growing a `resumeBayesFlow`. 0.8.4 is pre-1.0,
but the package has a live downstream consumer (PCMM) and an in-repo precedent (`runAbstractTrial`,
`src/runner.jl:372`), so use a shim rather than a hard rename:

```julia
"""
    resumeABC(calibration::Calibration; kwargs...)

Deprecated alias for [`resumeCalibration`](@ref).
"""
function resumeABC(calibration::Calibration; kwargs...)
    Base.depwarn("`resumeABC` is deprecated. Use `resumeCalibration` instead.",
                 :resumeABC; force=true)
    return resumeCalibration(calibration; kwargs...)
end
```

### `description` vs tagging — the answer

**Keep `description`, demote it, and make tagging the retrieval path.** `description` stays as one line of
display prose written to the DB row and surfaced by brief 04's `show`/`calibrationsTable`; `tags=` becomes the
queryable dimension. Neither is deprecated, and **neither dual-writes into the other** — there is no way to
keep two copies in sync (`untag!` can delete the tag while the column persists), and `note` is already in
`RECOMMENDED_TAG_KEYS` (`src/tags.jl:31`), so a user who wants searchable prose writes
`tags=("note" => "…")` explicitly. This mirrors what `trials.description` already is
(`src/database.jl:132-136`).

**The strongest argument for tagging is not query power, it is amendability.** "`resumeABC` cannot set or
amend a `description`" has no good fix in the column model: amending prose means an `UPDATE` on a provenance
row, which is a mutable-history smell. Tags are append-only, multi-valued and timestamped, so
`resumeCalibration(cal; tags=("verdict" => "converged",))` is the natural amend path and a run can accumulate
labels across sessions.

**Keep both columns.** Dropping `description`/`method` needs `ALTER TABLE … DROP COLUMN` (SQLite ≥ 3.35, and
refused when the column is indexed or referenced by a view) or the twelve-step table-rebuild dance — either
way an `up.jl` milestone **that every simulator package must implement**, to remove two harmless columns.
Disproportionate. Instead `method` becomes the queryable mirror of the method type (agreeing with the new
`method.toml` `"type"` key and brief 04's `mm:method` tag) and `description` becomes the display line. Both
finally get a reader.

**`tags=` reuses `run`'s exact path.** `run(T::AbstractTrial; …, tags=(), …)` at `src/runner.jl:256-262` does
`refreshProvenance!()` then `isempty(tags) || tag!(T, tags...)` *before* dispatching anything. Copy it
literally:

```julia
function runCalibration(problem::CalibrationProblem, method::ABCSMC;
                        description::String="", tags=(), run_kwargs::NamedTuple=(;),
                        progress::Symbol=:auto, on_monad_failure::Symbol=:reject)
    verbosity = _resolveRunControls(progress, on_monad_failure)
    refreshProvenance!()
    calibration = createCalibration("ABC-SMC"; description=description)
    #! Applied before any simulation is dispatched, so the labels survive an interrupted
    #! run and the calibration is queryable by tag while it is still going.
    isempty(tags) || tag!(calibration, tags...)
    …
```

`resumeCalibration(cal; tags=())` applies them the same way — the amend path.

### `CalibrationProblem` constructor symmetry

`src/calibration/problem.jl:78-84` gains `reference_variation_id::VariationID=ref.variation_id`. A keyword may
reference an earlier positional argument, so the default reproduces today's behavior exactly: zero breakage,
and the two constructors now accept the same keyword set.

### Latent bugs — fix both here, and say why in `progress.md`

- **The live crash.** `_ProblemManifest.observed_data::Dict{String,Any}` (`abc.jl:498`) versus
  `CalibrationProblem.observed_data::Any` (`problem.jl:61`). `_ProblemManifest(problem)` (`:514-521`) uses the
  default constructor, so a `Vector` or scalar fails to `convert` inside `_saveProblem`, which
  `runCalibration` calls unconditionally at `:306`. The 2026-05-18 `progress.md` entry relaxed the struct and
  both public constructors but missed the manifest. One-word fix (`Dict{String,Any}` → `Any`). JLD2 matches by
  field name and this is a widening, so existing `problem.jld2` files still load — no migration. While there,
  note that `_validateResumedProblem` compares `provided.observed_data == manifest.observed_data` (`:897`) and
  add a `#!` comment that this requires `==` to return a `Bool` for whatever the user stored.
- **`calibrationMonadIDs`** (`calibration.jl:57-62`) — **brief 04 should already have fixed this.** Verify
  first; if it has not landed, fix here: the `endswith(f, "_monads.csv")` filter also matches
  `generation_{NNN}_failed_monads.csv` (`abc.jl:1134-1137`), folding deleted monad IDs into the evaluated
  list, `reduce(vcat, …)` does not dedupe, and `sort` is lexicographic so `generation_10` precedes
  `generation_9` under mixed padding. Fix with `occursin(r"^generation_\d+_monads\.csv$", basename(f))`, a
  numeric sort key, and `unique!`.

### Export manifest

`CalibrationParameter` **is** already exported — `export CalibrationParameter` at
`src/calibration/parameters.jl:1` runs inside the `ModelManager` module, which is why `test/runtests.jl` uses
the bare name with only `using ModelManager`. The real defect is that the aggregate manifest at
`src/ModelManager.jl:58-63` omits it, and omits any mention of `SimulationBank` (`@compat public` at
`bank.jl:420`). Cosmetic; add them plus a comment that the per-file `export` lines are authoritative and this
block is a duplicate index.

### Docs

Fix `docs/src/man/calibration.md:107` here — this brief is what makes `method=` real, so verifying that line
is unavoidable. **Leave the `plot_type=` errors at `:158-161` and `README.md:79` to brief 06**, which rewrites
that exact code block. No overlap.

## Testing Strategy

**Unit:**
- `"ABCSMC construction and validation"` (`test/runtests.jl:329`) — add `ABCSMC().store_rejected == false`
  and `ABCSMC(store_rejected=true).store_rejected`.
- **Replace** `"cdf_grid_k save/load round-trip"` (`:1448`) and `"max_evaluations save/load round-trip"`
  (`:1540`) with one `"method.toml round-trip preserves every ABCSMC field"` that calls the real
  `_saveMethod(path, m)` / `_loadMethod(path)` inside `mktempdir()` and compares
  `getfield.(loaded, fieldnames(ABCSMC))` against an all-non-default `ABCSMC`. This deletes the two inlined
  copies of the field list and is the guard that makes the triplication unreintroducible. Keep the nil-case
  assertions (`cdf_grid_k`/`max_evaluations` keys absent) and add a **legacy case**: a `method.toml` with only
  the five original keys and no `"type"` loads to an `ABCSMC` whose other nine fields equal the defaults.
- New `"runABC keyword forwarding"` near `:329`: `_methodFromKeywords(ABCSMC, (; nope=1))` throws
  `ArgumentError` naming `nope`; `runABC(prob; method=ABCSMC(), population_size=5)` throws `ArgumentError`
  mentioning both.
- `"_ProblemManifest JLD2 round-trip"` (`:1669`) — add `Vector` and scalar `observed_data` cases.

**Integration** (inside `"DB-backed integration"`, `:2094`):
- New `"runABC delegates to runCalibration"` after `"runCalibration end-to-end"` (`:2561`). **`runABC` is
  currently called by no test at all** — grep confirms zero occurrences — so this is new coverage. Assert the
  keyword form returns an `ABCResult`; `runABC(prob; store_rejected=true, population_size=4, max_nr_populations=2)`
  yields `result.method.store_rejected == true` (direct regression); `runABC(prob; method=m)` and
  `runCalibration(prob, m)` produce equal `result.method`.
- New `"non-Dict observed_data survives runCalibration"` — the regression whose absence let the crash ship:
  `observed_data = [1.0]` with a vector-returning summary statistic and `mseDistance`, one generation,
  `population_size=2`.
- Rename `"resumeABC"` (`:2983`) → `"resumeCalibration"`, keep its assertions, and add
  `@test_deprecated resumeABC(result1.calibration; problem=prob_resume, method=method2)`.
- New `"tags keyword on calibration entry points"` as a sibling of `"tags keyword on createTrial and run"`
  (`:3621`) — covering `runCalibration`, `runABC`, and `resumeCalibration` appending to an already-tagged run,
  plus an assertion that `tag!(cal, "note" => "x")` does **not** touch the `description` column (pinning the
  no-dual-write decision).
- `"on_monad_failure=:reject"` (`:2624`) — add `ids = ModelManager.calibrationMonadIDs(cal)`;
  `@test allunique(ids)`; `@test isempty(intersect(ids, ModelManager.constituentIDs(failed_monads_path)))`.
- `"runCalibration progress levels"` (`:2596`) already covers `_resolveVerbosity` through the new front door;
  confirm it still passes.

`"docstrings only @ref public bindings"` (`:4310`) covers the new docstrings — `_prepareCalibrationRun`,
`_executeCalibrationRun`, `_CalibrationRunPlan` and `_methodFromKeywords` are internals and must appear as
plain code spans, never `@ref`.

## Estimated Effort

- **Lines of code:** ~180 removed, ~260 added in `src/` (most of the delta is `runABC`'s signature collapsing
  and the serializers becoming table-driven); ~120 net added and ~90 removed in `test/runtests.jl`; ~15 in
  docs/README.
- **Risk level:** **Medium.** `_loadMethod` is on the resume-critical path, so the legacy-`method.toml` test
  case is mandatory. Everything else is default-preserving. Two things to watch:
  `_prepareCalibrationRun`'s `priors::Vector{<:Distribution}` field is abstractly typed (fine — built once per
  run, never in a loop), and `resumeCalibration` still uses the *override* method's `max_nr_populations` for
  new generations' zero-padding, which can differ from the original run's. `_loadGenerations` tolerates that
  by rediscovering files with a regex (`abc.jl:1299-1301`); note it in `progress.md` as pre-existing and out
  of scope.
- **Dependencies:** brief 04 must land first. Must precede briefs 06–08.

## Open questions for the user

1. **Does anything outside this repo call `resumeABC`?** PCMM is out of scope to read from here. If nothing
   does, the `depwarn` shim could be skipped and the name simply changed at 0.8.x.
2. **Is `description` permanent, or droppable at 1.0?** Dropping it needs an `up.jl` milestone every simulator
   package must implement. Affects whether the docs call it a "supported prose field" or "legacy".
3. **`run(::AbstractCalibrationMethod, ::CalibrationProblem)` for GSA symmetry** — add now, or defer to brief
   07 (recommended)? Purely a public-surface taste call, but brief 07 needs the answer.

## Cross-cutting rules

**Review-only comments.** The repo uses `#!` for *permanent* design-rationale comments (316 of them). Any
comment written purely so the user can follow your reasoning during review must be marked `#REVIEW:` and
removed before merge.

**Docs are for an outside reader, not a changelog.** User-facing prose explains how to use the code as it now
is. Where a "why" is needed it must be the grand-narrative why, never this repo's history:

> ✅ "Updates are delayed until the next Julia session so as not to corrupt the currently loaded session state."
> ❌ "Updates must be delayed because updating mid-session had the potential to produce incorrect session states where upgrades would never actually proceed."

The second sentence belongs in `progress.md`.

## Pre-merge checklist

- [ ] `julia --project=. -e 'using Pkg; Pkg.test()'` green.
- [ ] `rg '#REVIEW:' src/ test/` returns nothing.
- [ ] A legacy `method.toml` (five keys, no `"type"`) still loads — the resume-path guard.
- [ ] Every new exported/`@compat public` binding has a docstring with description, arguments, return value
      and a usage example.
- [ ] `docs/src/man/calibration.md:107` corrected; the `plot_type=` block left for brief 06.
- [ ] Docs written outside-in per the rule above; no repo history in `docs/`.
- [ ] `README.md` Implementation Status and `PRD.md` updated.
- [ ] `progress.md` records the argument-order decision **for brief 07 to match**, and the `description`
      verdict.
