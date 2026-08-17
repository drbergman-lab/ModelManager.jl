# Design Brief: Shared study objects — build once, use for sensitivity and calibration

> **Order:** 7 of 8. **Stage 1 requires nothing; Stages 2–4 require brief 05** (it settles the keyword
> surface these must match). Do not run Stage 4 beside brief 05 — direct collision on `runCalibration`'s
> signature.
>
> **This brief is staged across multiple sessions.** Stage 1 is independently valuable and non-breaking, and
> it is a hard prerequisite for brief 08. Do Stage 1, hand back, then continue.

## Preflight

1. Read `CLAUDE.md`: the design-brief-first workflow, the `@ref`-public-bindings-only rule with its
   `@compat public` guidance, the Definition of Done, and **"ModelManager-Specific Guidance"** — the QoI seam
   in Stage 3 must stay simulator-agnostic.
2. Read `docs/src/man/sensitivity_analysis.md`, `docs/src/man/calibration.md`, `docs/src/man/variations.md`,
   `docs/src/man/post_processing.md`.
3. Read the `progress.md` entry brief 05 left recording its **argument-order decision** — this brief must
   match it.
4. Per CLAUDE.md step 2: update `PRD.md` and open a dated `progress.md` entry per stage.
5. `git branch feature/shared-study-objects`, then have the user check it out before you code.
6. All paths are repo-relative. Work only inside your worktree.

## Motivation

A user who has defined the parameters, base model, replicate count and quantity of interest for a calibration
must redefine all four to run a sensitivity analysis on the same model, and vice versa. The two APIs already
agree on almost everything underneath — both normalize user variations through the *same* `LatentVariation`
factory methods, and both carry `InputFolders`, a reference `VariationID`, `n_replicates` and `use_previous` —
but expose those facts through incompatible surfaces.

**The user's target API**, which this brief works toward (note `inputs` stays first):

```julia
out = runSensitivity(inputs, priors, ...; ...)
data = ...
out = runABC(inputs, priors, data, ...; ...)
```

...with the calibration side able to reuse one of the sensitivity output functions directly as its summary
statistic.

## Scope

- **Files affected:** `src/sensitivity.jl`, `src/variations.jl`, `src/calibration/problem.jl`,
  `src/calibration/parameters.jl`, `src/ModelManager.jl`, `src/runner.jl` (docstring only), `test/runtests.jl`,
  `docs/src/man/sensitivity_analysis.md`, `docs/src/man/calibration.md`, `docs/src/man/post_processing.md`,
  `docs/make.jl`
- **New files:** `src/study.jl` (Stage 2), `src/qoi.jl` (Stage 3), `docs/src/lib/study.md`,
  `docs/src/lib/qoi.md`
- **Breaking changes:** none for Stages 1–3 (all additive). Stage 4 only. `Project.toml:3` is `0.8.4`,
  pre-1.0, so a `0.9.0` bump legitimately carries breakage — but Stage 4 is optional and separable.
- **DB schema:** no change anywhere. The post-processing sink already grows columns idempotently via
  `ALTER TABLE … ADD COLUMN` inside `_writePostProcessingRow` (`src/database.jl:1279-1283`), so Stage 3 needs
  no `src/up.jl` migration.

## The load-bearing design conclusion

GSA normalizes to `ParsedVariations{T<:LatentVariation}` (`src/variations.jl:779-796`); calibration normalizes
to `Vector{CalibrationParameter}` (`src/calibration/parameters.jl:62-65`). Both are built from the *same*
factories: `LatentVariation(dv::DistributedVariation)` (`src/variations.jl:640-649`) and
`LatentVariation(cv::CoVariation{DistributedVariation})` (`:661-682`).

The GSA direction is **one line today**, no new machinery: `LatentVariation <: AbstractVariation`
(`:491`), `ParsedVariations`'s only constructor takes `Vector{<:AbstractVariation}` and applies
`LatentVariation.(avs)` (`:783-784`), and `LatentVariation(lv::LatentVariation) = lv` is the identity (`:684`):

```julia
ParsedVariations(problem::CalibrationProblem) = ParsedVariations([cp.lv for cp in problem.parameters])
```

The reverse direction is possible (`_toCalibrationParameter(lv::LatentVariation{<:Distribution})` exists at
`src/calibration/parameters.jl:89`) but **lossy**: a `DistributedVariation` routed through `LatentVariation`
and back becomes an `LVSource`, not a `DVSource`, so `_displayColumns` (`:129`) emits latent-parameter names
plus raw target columns instead of the friendly `variationName(dv)` — the generation CSVs and `posterior()`
output change shape.

**Therefore the shared object must retain the user's *original* variations, not a derived normalized form.**
Each consumer derives its own internal representation losslessly. That single decision determines the whole
architecture.

## Stage 1 — Conversions, better rejection reporting, and the doc fix

Independently valuable, non-breaking, one session. **Hard prerequisite for brief 08.**

1. `ParsedVariations(problem::CalibrationProblem)` as above.
2. `run(method::GSAMethod, problem::CalibrationProblem; functions=Function[], kwargs...)` — the "I already
   have a problem, now show me which parameters matter" shortcut, beside the existing three forms at
   `src/sensitivity.jl:66`, `:73`, `:77`.
3. **Fix the mis-documented GSA `functions` granularity.** `docs/src/man/sensitivity_analysis.md:20` says
   "`functions` — output functions of the form `monad_id -> Real`". The reality at
   `src/sensitivity.jl:481-483` is `f(simulation_id)` for each simulation in the monad, averaged with `mean`.
   The internal docstring at `:471` is correct; the manual is wrong. This directly sabotages anyone trying to
   share a QoI between the workflows, since calibration's `summary_statistic` genuinely *is* `monad_id -> T`.
   **Highest value-per-character change in the brief.** While there, state that replicate aggregation is
   library-owned (`mean`) for GSA and user-owned for calibration.
4. **All-offenders rejection reporting.** `_toCalibrationParameter` is called inside a comprehension
   (`src/calibration/problem.jl:72`, `:80`), so it throws on the *first* offender, names only its type, and
   never says which parameter it was. A user with eight variations, two of them discrete, learns about one per
   run. Add an internal `_calibrationRejection(av) -> Union{Nothing,String}` returning the reason or
   `nothing`, reusing the three existing messages; make the throwing methods one-liners over it so the direct-call
   error text pinned by `test/runtests.jl:311-315` is preserved; and have all `CalibrationProblem`
   constructors collect **every** rejection into one `ArgumentError` listing each offender by
   `variationName(av)` and index with its reason.

## Stage 1b — Discrete parameters: assess, then converge

The user's instruction is explicit: **converge on both study types accepting the same variation types**, and
the direction is decided by what the existing structures support.

> "If the structures are there to move the calibration into discrete parameters, then let's do that. If a full
> rework of handling discrete in sensitivity is helpful, we should retreat first to just continuous and then
> build it correctly towards both discrete and continuous."

**So the first job is an assessment, not a design.** Do not simply keep the three rejections at
`src/calibration/parameters.jl:93-110` — that is the status quo the user is asking to move off.

What exists in favor of moving calibration *forward* to discrete:

- `LatentVariation` already has a **discrete branch** taking `Vector{<:Real}` latent parameters
  (`src/variations.jl:502`), and `LatentVariation(dv::DiscreteVariation)` exists at `:628-637`.
  `_toCalibrationParameter` simply refuses it (`src/calibration/parameters.jl:93-110`).
- `cdf_grid_k` snapping already maps continuous CDF coordinates onto a **fixed grid** — structurally the same
  CDF→index mapping a discrete parameter needs. A discrete parameter is a grid whose points are given rather
  than derived.

What blocks it, and what the assessment must answer:

- **The perturbation kernels assume a continuous coordinate.** `GaussianKernel`, `ComponentwiseKernel`,
  `LocalNNKernel`, `LocalNNCovKernel` (`src/calibration/methods.jl:31-117`) fit a covariance and propose in
  ℝᵈ, and the importance weights need a proposal *density* evaluated at the proposed point. A discrete
  coordinate needs a categorical or random-walk proposal with a matching pmf. **Scope this concretely: how
  many of the four kernels need a discrete counterpart, and can `AbstractKernel`'s existing
  fit/propose/density interface (`src/calibration/abc_smc.jl:29-57`) express one without changing its
  signature?**
- **`inverse_maps`.** The discrete `LatentVariation` has none, which silently disables the `SimulationBank`
  (`src/calibration/bank.jl:92-99`, an `@info` at run time only). For a discrete parameter the inverse is a
  value→index lookup, which is trivially constructible — check whether `_validateInverseMaps`
  (`src/variations.jl:589-625`) accepts a step-function round trip.
- **Mixed continuous/discrete particles** — whether the kernel machinery can carry a per-coordinate proposal
  type, or whether it assumes one kernel for the whole vector.

**Apply the user's rule with the answer.** If the kernel work is a bounded addition (a discrete kernel plus a
per-coordinate dispatch), do it and remove the rejections. If it turns into a rework of the kernel hierarchy,
**retreat first**: restrict *sensitivity* to continuous variations too, so both sides agree, and record the
plan to build toward both afterward. Either way the outcome is that the same `priors` vector is valid input to
both — which is the actual requirement.

Report the assessment in `progress.md` before writing code, and surface it to the user; the two paths differ
enough in size that they should see the finding.

## Stage 2 — `StudySpec` and the shared entry-point shape

```julia
struct StudySpec
    inputs::InputFolders
    variations::Vector{AbstractVariation}      # the USER's originals — deliberately not normalized
    reference_variation_id::VariationID
    n_replicates::Int
    use_previous::Bool
end

StudySpec(inputs::InputFolders, variations::AbstractVector;
          reference_variation_id::VariationID=VariationID(inputs),
          n_replicates::Int=1, use_previous::Bool=true)

StudySpec(ref::AbstractMonad, variations::AbstractVector; n_replicates::Int=1, use_previous::Bool=true)
    # unpacks ref.inputs and ref.variation_id, mirroring src/sensitivity.jl:73
    # and CalibrationProblem(ref, ...) at src/calibration/problem.jl:78
```

Derivations, both lossless because the originals are retained:
`ParsedVariations(spec) = ParsedVariations(spec.variations)` and
`[_toCalibrationParameter(av) for av in spec.variations]`.

New entry points, all additive:

- `run(method::GSAMethod, spec::StudySpec; functions=Function[], kwargs...)` — forwards
  `reference_variation_id`, `n_replicates`, `use_previous` into the keywords that already exist at
  `src/sensitivity.jl:177-180`.
- `CalibrationProblem(spec::StudySpec, observed_data, summary_statistic, distance)` — a third constructor
  beside `:68` and `:78`. Note it fixes the asymmetry brief 05 also touches: the `InputFolders` constructor
  has a `reference_variation_id` kwarg and the `AbstractMonad` one does not.

**The user's target argument order.** Their sketch is `runSensitivity(inputs, priors, …)` /
`runABC(inputs, priors, data, …)`, i.e. `(inputs, priors)` as a shared positional prefix. Reconcile it with
brief 05, which keeps `runABC(problem::CalibrationProblem)` canonical and deferred the `run`-symmetry question
here. **Recommended resolution — additive convenience methods, canonical forms unchanged:**

- add `runABC(inputs::InputFolders, priors::AbstractVector, observed_data, summary_statistic, distance; method=nothing, kwargs...)`
  which builds the `CalibrationProblem` internally and delegates to brief 05's `runABC(problem; …)`;
- add a named `runSensitivity(inputs::InputFolders, priors::AbstractVector; method::GSAMethod=MOAT(), functions=Function[], kwargs...)`
  wrapping `run(::GSAMethod, …)`, so the two read symmetrically;
- and accept the same `(spec, …)` forms for both.

Multiple dispatch makes these coexist with the problem-taking methods; nothing is removed. **Confirm the
naming against brief 05's recorded decision before implementing** — if brief 05 concluded differently about
`run` versus named entry points, follow that and note the divergence.

**What stays separate, explicitly:** `observed_data`, `distance` and `summary_statistic` stay on
`CalibrationProblem`; `functions` stays on the GSA entry point; `ABCSMC`'s epsilon/kernel/population settings
stay on the method. `StudySpec` is deliberately *only* the model-and-parameters bundle. **Do not add an
`observed_data` field "for later"** — a sensitivity study has none, and an optional field half the consumers
ignore is how these abstractions rot.

**Export it.** Unlike `GSASampling` (`@compat public`, because users only receive one), a user *constructs* a
`StudySpec` by name — CLAUDE.md's criterion for exporting. Export from `src/ModelManager.jl` near the
`MOAT, Sobolʼ, …` line (`:52`). Naming is an open question: `SimulationSpec` already exists and is public, so
avoid `ModelSpec`/`Spec` collisions in the user's mental model.

**`Base.show(io, ::MIME"text/plain", spec::StudySpec)` as the whole reporting surface** — one line per
parameter with name, kind, and a sensitivity/calibration usability mark. No new public validation function:
this costs zero API commitment and is discoverable by typing the variable at the REPL, which is how people
actually check. Follow the `printInputFolders`/`printVariationID` style (`src/classes.jl:355-360`). Also
surface the near-invisible cliff: an `LVSource`-shaped parameter with `inverse_maps === nothing` is *accepted*
by calibration but silently disables the `SimulationBank` — mark it
"calibration: yes (bank disabled — supply `inverse_maps`)".

## Stage 3 — The QoI seam

This is the first bullet of CLAUDE.md's "## To-dos". **Critical scoping fact: `populationCountQoI` does not
exist in this repository.** A full-worktree search finds exactly one occurrence — the to-do line itself.
`progress.md:911` records the deliberate decision that PhysiCell summary statistics stay in PCMM
(`endpointPopulationCounts`, `endpointPopulationFractions`, `meanPopulationTimeSeries`), and
`src/calibration/problem.jl:44` mentions one only inside a docstring example. **So this is about designing the
MM-side seam, not moving PCMM code**, and it must stay simulator-agnostic.

Three impedance mismatches:

| | post-processor | GSA `functions` | calibration `summary_statistic` |
|---|---|---|---|
| keyed by | name (many per sim) | — (one scalar) | — (one aggregate) |
| granularity | simulation | simulation (library averages to monad) | monad (user averages) |
| lives in | the sink DB | in-memory closure | in-memory closure |

### ⚠ The dispatch collision, and why the level must be explicit

Passing objects instead of IDs is the right argument surface — self-documenting, and it matches the runner
handing `post_processor` a `SimulationProcess` rather than an ID (`src/runner.jl:464`). It also enables
exactly the composition the user described: PCMM defines `finalPopulationCount(::Simulation)` and a user
writes `myfn(s::Simulation) = finalPopulationCount(s)["tumor"]`.

**But it does not disambiguate granularity.** `Simulation` and `Monad` are *both* `<: AbstractMonad`
(`src/classes.jl:273`, `:384`), so a user's `myfn(M::AbstractMonad)` is callable at either level and dispatch
cannot recover which they meant. Worse, that signature is often *legitimately* level-agnostic — a PCMM
accessor on `AbstractMonad` that averages replicates itself is reasonable — so it cannot simply be rejected.

**Therefore the level is declared, never inferred.** The resolving type carries a name (mismatch 1), a level
and a reducer (mismatch 2), and both a producer and a sink reader (mismatch 3):

```julia
struct QoI
    name::String        # sink column name; must satisfy the sink's scalar contract
    compute::Function   # (::SimulationProcess) -> Real | Bool | String  — supplied by the simulator package
    level::Symbol       # :simulation | :monad — declared, so nothing is inferred from dispatch
    reduce::Function    # (::AbstractVector) -> Any                      — default `mean`
end
```

A `hasmethod` probe may resolve the unambiguous cases for ergonomics, but when a supplied function has a
method on `AbstractMonad` and no level is given, **raise a named error**. Silently reading a monad as a
simulation is the one failure mode that must be impossible.

Adapters, in a new `src/qoi.jl` included after `src/database.jl` and before `src/sensitivity.jl` (it needs
`SimulationProcess`, `postProcessingTable`, `constituentIDs`):

- `postProcessor(qs::AbstractVector{QoI}) -> Function` — returns `sp -> Dict(q.name => q.compute(sp) for q in qs)`,
  exactly the `AbstractDict` of `name => scalar` that `_normalizePostProcessingQoI` accepts
  (`src/database.jl:1224-1246`). Validate `allunique(name)` up front rather than letting the duplicate check
  at `:1240-1246` fire mid-run.
- `summaryStatistic(qs::AbstractVector{QoI}) -> Function` — returns `monad_id -> Dict{String,Any}`, as one
  batched `postProcessingTable(constituentIDs(Monad, monad_id))` followed by `q.reduce` per column. `Dict` is
  precisely what `mseDistance` already handles, so
  `CalibrationProblem(spec, observed, summaryStatistic(qs), mseDistance)` works with no other changes.
- A `qois::AbstractVector{QoI}=QoI[]` keyword on the GSA entry point. **Do not** implement it as a naive
  `simulation_id -> Real` closure querying the sink once per simulation — `evaluateFunctionOnSampling`
  (`src/sensitivity.jl:473-486`) memoizes per *monad* but would still issue one query per simulation on first
  touch. Exploit the ordering already present at `src/sensitivity.jl:66-71`: `runSensitivitySampling` returns
  before `sensitivityResults!` is called, so `simulationIDs(gsa_sampling)` is known by then. Merge
  `postProcessor(qois)` into the forwarded `post_processor`, run the sampling, then do **one**
  `postProcessingTable(simulationIDs(gsa_sampling))` read, build a `Dict{Int,Float64}`-backed closure per QoI,
  and hand those to `sensitivityResults!` alongside the user's `functions`. Use **named** closures, not
  anonymous, so `gsa_sampling.results` keys and plot-recipe legend labels are stable — compare the
  `_gsa_fA`/`_gsa_fB` fixtures at `test/runtests.jl:102-103`, which exist for exactly this reason.
- Clear error when the sink has no value for a requested name: name the QoI, name the first offending
  simulation, and point at `qois=` / `post_processor=`. A silent `missing` here would produce garbage
  sensitivity indices.

New docs page `docs/src/lib/qoi.md` with a `Pages = ["qoi.jl"]` autodocs block, added by hand to the
`docs/make.jl` Index list — the "Analysis & calibration" group at `docs/make.jl:59-61`; the comment at
`:48-50` notes the list is hand-maintained.

## Stage 4 — Simulator-kwargs convention (optional, breaking if it removes anything)

GSA splats untyped `kwargs...` into `run` (`src/sensitivity.jl:66`, forwarded at `:164`); calibration bundles
`run_kwargs::NamedTuple=(;)` (`src/calibration/abc.jl:299`, applied at `:171`). **Recommend additive only:**
accept `run_kwargs` on the GSA entry point alongside `kwargs...`, or `kwargs...` on `runCalibration` alongside
`run_kwargs`. A true unification that *removes* one convention is breaking; defer that past 1.0. The
redundancy is cheap; breaking `runCalibration`'s signature is not.

## Testing Strategy

**Unit** (top-level block, before `"DB-backed integration"` at `test/runtests.jl:2094`):
- Extend `"_toCalibrationParameter and CalibrationProblem parameter conversion"` (`:269`) — it already builds a
  `DVSource`/`CVSource`/`LVSource` triple at `:275-308` and asserts the discrete rejections at `:311-315`. Add:
  `ParsedVariations(problem)` produces `latent_variations` that are `===` the `cp.lv` objects (proving
  losslessness); the duplicate-`(location, XMLPath)` assertion still fires through the new path; the
  all-offenders `ArgumentError` names *both* offenders when two discrete variations are passed. **If Stage 1b
  removes the rejections, `:311-315` changes meaning — update it deliberately, do not delete it.**
- New `"StudySpec construction and derivation"`: both constructors; `ParsedVariations(spec)` and the
  `CalibrationParameter` derivation agree with the direct paths;
  `sprint(show, MIME"text/plain"(), spec)` contains each parameter name, the usability marks, and the
  `inverse_maps === nothing` bank warning.
- New `"QoI adapters"` — pure-function parts only: `postProcessor(qs)` returns a `Dict` with the right keys
  from a hand-built `SimulationProcess`; duplicate names throw; `reduce` defaults to `mean`; **a function with
  an `AbstractMonad` method and no declared level raises the named error.**

**DB-backed** (inside the `mktempdir` at `:2095`, using `xp_x`/`xp_y`/`inputs` from `:2144-2146`):
- `"GSA — MOAT"` (`:3039`) — add `run(MOAT(3), problem; functions=[gs_fn])` and `run(MOAT(3), spec; …)`,
  asserting both return a `GSASampling` with the same `size(monad_ids_df, 2)` as the existing call at `:3044`.
  Note the fixture at `:3042` is already `(_sim_id::Int) -> 1.0` — correctly per-simulation, further
  confirmation that the manual, not the code, is wrong.
- `"runCalibration end-to-end"` (`:2561`) — add a run driven by
  `CalibrationProblem(StudySpec(inputs, [dv]; n_replicates=1), observed, _test_named_ss, mseDistance)` and
  assert the same `posterior` column-name assertion as `:2588`.
- `"post-processing sink"` (`:2376`) — extend with
  `run(samp; post_processor=postProcessor([QoI("q", sp -> 2.0 * simulationID(sp), :simulation, mean)]))` and
  read back via `postProcessingTable`, reusing the `2.0 * row.SimID` pattern at `:2408-2410`.
- New `"QoI seam end-to-end"` after `"post-processing sink follows deletions"` (`:2524`):
  `run(MOAT(3), spec; qois=[q])` produces results keyed by a *named* function; `summaryStatistic([q])` returns
  a `Dict` `mseDistance` accepts; a QoI name absent from the sink raises the designed error naming the QoI and
  the simulation.
- If Stage 1b lands discrete calibration: a discrete-parameter ABC run producing a posterior, plus a
  kernel-density round trip on the discrete coordinate.

`"docstrings only @ref public bindings"` (`:4310`) is automatic. Safe to `@ref`: `CalibrationProblem`,
`LatentVariation`, `DistributedVariation`, `CoVariation`, `DiscreteVariation`, `InputFolders`, `VariationID`,
`run`, `MOAT`, `Sobolʼ`, `RBD`, `postProcessingTable`, `mseDistance`, `GSASampling`, `CalibrationParameter`
(exported at `src/calibration/parameters.jl:1`), `SimulationProcess` (`@compat public`). **Not** linkable:
`ParsedVariations`, `_toCalibrationParameter`, `evaluateFunctionOnSampling`, `runSensitivitySampling`. Verify
each with `Base.ispublic` before writing.

## Estimated Effort

- **Lines of code:** Stage 1 ~60 impl + ~40 test + 5 doc. Stage 1b: assessment first; ~40 lines if the inverse
  map and one discrete kernel suffice, substantially more if the kernel hierarchy needs rework. Stage 2 ~180
  impl + ~120 test + ~80 doc. Stage 3 ~220 impl + ~150 test + ~120 doc. Stage 4 ~30.
- **Risk level:** Stage 1 Low. Stage 1b **unknown until assessed** — that is the point of assessing.
  Stage 2 Medium (new public type; naming and field set are hard to change later). Stage 3 Medium (the batched
  sink read and the named-closure requirement are both easy to get subtly wrong). Stage 4 Low but breaking.
- **Dependencies:** Stage 1 none. Stages 2–4 after brief 05.

## Open questions for the user

1. **Name for the shared struct** — `StudySpec`, `ParameterStudy`, or something else? `SimulationSpec` already
   exists and is public, so `ModelSpec` risks a confusing near-collision. Recommend `StudySpec`, exported.
2. **Name for the QoI type** — `QoI`, or `QuantityOfInterest` with a `const QoI = …` alias? Reads as
   `run(...; qois=[q1, q2])` either way.
3. **Stage 1b direction** — this is the assessment's output, but flag it before implementing: progress
   calibration to discrete, or retreat sensitivity to continuous first? The user's rule decides, and the
   assessment supplies the input.

## Cross-cutting rules

**Review-only comments.** The repo uses `#!` for *permanent* design-rationale comments (316 of them). Any
comment written purely so the user can follow your reasoning during review must be marked `#REVIEW:` and
removed before merge.

**Docs are for an outside reader, not a changelog.** User-facing prose explains how to use the code as it now
is. Where a "why" is needed it must be the grand-narrative why, never this repo's history:

> ✅ "Updates are delayed until the next Julia session so as not to corrupt the currently loaded session state."
> ❌ "Updates must be delayed because updating mid-session had the potential to produce incorrect session states where upgrades would never actually proceed."

The second sentence belongs in `progress.md`.

## Pre-merge checklist (per stage)

- [ ] `julia --project=. -e 'using Pkg; Pkg.test()'` green.
- [ ] `rg '#REVIEW:' src/ test/` returns nothing.
- [ ] Argument order matches brief 05's recorded decision, or the divergence is documented.
- [ ] Every new exported/`@compat public` binding has a docstring with description, arguments, return value
      and a usage example.
- [ ] `docs/src/man/sensitivity_analysis.md:20` granularity fixed (Stage 1).
- [ ] Docs written outside-in per the rule above; no repo history in `docs/`.
- [ ] `README.md` Implementation Status and `PRD.md` updated; the CLAUDE.md QoI to-do struck once Stage 3
      lands.
- [ ] `progress.md` records the Stage 1b assessment and its verdict.
