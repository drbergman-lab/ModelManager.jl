# Design Brief: BayesFlow — scoping decision plus a training-set export

> **Order:** 8 of 8. Requires **brief 07 Stage 1** (`ParsedVariations(::CalibrationProblem)`) and benefits from
> **brief 05** (the `observed_data` fix and the settled keyword surface) and **brief 03** (failed-simulation
> records).
>
> **This brief is a decision document with one concrete increment.** The user is explicitly in an exploratory
> phase: *"I want to know what my options are here."* So the deliverable is (1) a recommendation they can act
> on, (2) a time-boxed spike on the all-Julia route, and (3) the export path built so nothing is foreclosed.
> Do not skip straight to implementation.

## Preflight

1. Read `CLAUDE.md`: the design-brief-first workflow, the `@ref`-public-bindings-only rule, the Definition of
   Done, **"ModelManager-Specific Guidance"**, and **"Do not edit `Manifest.toml` or add dependencies without
   explicit approval."** That last rule governs this entire brief.
2. Read `docs/src/man/calibration.md` and `src/calibration/methods.jl` (the `AbstractCalibrationMethod`
   docstring at `:4-14` already anticipates new methods).
3. Per CLAUDE.md step 2: update `PRD.md` and open a dated `progress.md` entry.
4. `git branch feature/bayesflow-training-set`, then have the user check it out before you code.
5. All paths are repo-relative. Work only inside your worktree.

## Motivation and the user's actual question

BayesFlow is a Python library for amortized simulation-based Bayesian inference: train a normalizing flow on
(parameter, simulated-summary) pairs drawn from the prior, then evaluate near-instant posteriors for any new
observation. ModelManager already produces exactly the ingredients — priors reparameterized to a unit
hypercube, a simulator runner, and a user-supplied summary statistic — but **throws the summary statistics
away**, and has no way to hand a training set to Python.

The user's framing, which shapes the recommendation:

- They previously called out to pyABC, then replaced it with a hand-rolled ABC-SMC once they saw how simple
  ABC-SMC is. They do **not** expect the same to be true of BayesFlow, because of the ML side.
- Their stated main unknown: **how often BayesFlow needs to call the ABM at new points in parameter space.**
  If frequently, the bridge must be automated.
- Their latency tolerance for that bridge: **seconds, even minutes** — because ABMs are long-running.

**Two research findings answer that unknown, and they should open the brief:**

1. **Offline training on one fixed pre-simulated set is BayesFlow's own documented recommendation for
   expensive simulators.** Its workflow separates a costly training phase from cheap amortized inference, and
   for a high-cost simulator the recommended path is to run a fixed number of simulations up front and store
   them. So the export path is the *happy path*, not a compromise. Sequential/active variants (SNPE, and
   active-learning ASNPE) are what require on-demand simulation, and they are a distinct, more advanced
   regime — worth adopting only if amortized-from-a-fixed-sweep proves insufficient.
2. **Given a seconds-to-minutes latency budget, an automated bridge needs no in-process Python at all.** A
   watched request/response directory — Python writes a CSV of parameter points, ModelManager runs them and
   writes back summaries — is entirely adequate at that timescale. This decouples the "do we need to automate
   the bridge?" question from the "do we need `PythonCall` and Python in CI?" question, which were previously
   entangled. **State this explicitly for the user**; it is the most consequential finding in the brief.

## The options, and the recommendation

Verified starting point: this repository has **zero** Python interop (no hits for `PythonCall`, `PyCall`,
`pyimport`, `CondaPkg` in `src/`, `Project.toml` or `docs/`) and **zero** package extensions (no `[weakdeps]`,
no `[extensions]`, no `ext/`; all 34 deps are hard deps). `julia = "1.10"` means extensions *are* available
(1.9+), but using one here would be the first in the package's history.

**(a) Export path — MM writes a training set of (parameter, summary) pairs; the user trains in Python.**
No Julia-side Python dep, CI unchanged, everything MM contributes is simulator-agnostic. Generating the
training set *is* the expensive, MM-shaped half of the work, and the half BayesFlow cannot do.

**(b) A live bridge.** Two sub-variants, and the distinction matters given finding 2:
- **(b1) File-based handshake** — a watched request/response directory. No Python dep in MM, no CI change,
  adequate at the user's latency budget. This is the correct shape *if* on-demand simulation turns out to be
  needed.
- **(b2) In-process `PythonCall`/`CondaPkg`** — puts a Python + PyTorch/TensorFlow toolchain on the critical
  path of `Pkg.test()`: the CI matrix would need a Python install, a `CondaPkg.toml`, and a multi-hundred-MB
  solve on every Julia version including `lts`. Maintenance cost is the BayesFlow API surface, which moves
  independently of this package. Even gated behind a weakdep, the *test* burden does not go away — an
  untested extension is a broken extension. **Only justified if sub-second round trips are needed, which the
  user has said they are not.**

**(c) A pure-Julia normalizing-flow backend.** The user is intrigued but only if an existing package does the
work. **This is more viable than the "research project" verdict it would have got a year ago** — see the spike
below.

**(d) Scope it out and document only.** Documenting a format nobody produces is worse than nothing.

**Recommendation: (a) as the concrete increment, plus a time-boxed spike on (c), with (b1) documented as the
escalation path if on-demand simulation proves necessary.** (a) is the largest value-per-risk step, it is
fully testable in existing CI, and it forces the design of the retain-the-summary-statistic seam that *every*
other option also needs. (b2) is explicitly not recommended.

### The spike on the all-Julia route — and what it does *not* commit us to

**To be clear for the user: the spike commits nothing.** It is a time-boxed evaluation whose deliverable is a
written recommendation, and the export format below is designed **consumer-agnostic** — Python BayesFlow,
`NeuralEstimators.jl` and `InvertibleNetworks.jl` can all read the same files. Only if the spike concludes a
Julia package is genuinely adequate would a follow-on brief design against it. Adding either package as a
dependency needs the user's explicit approval per CLAUDE.md.

Two candidates exist and both are real, not toys:

- **`NeuralEstimators.jl`** — explicitly supports neural posterior estimators (NPEs) for simulation-based
  inference, i.e. the same task as BayesFlow.
- **`InvertibleNetworks.jl`** — conditional normalizing flows (`NetworkConditionalGlow`,
  `NetworkConditionalHINT`), memory-efficient by exploiting invertibility, with a track record in amortized
  Bayesian posterior sampling.

Spike deliverable (target: one session, no dependency added to `Project.toml`): in a scratch environment,
train one of them on a small exported training set and report — does it produce a usable posterior, how much
code did it take, what is the AD/training-loop burden, and is the API stable enough to depend on? The answer
decides whether an all-Julia route replaces the Python bridge entirely, which would make the on-demand
refinement loop trivial (no bridge at all).

### Where this belongs

The **export path** touches only `CalibrationProblem`, the variation machinery, the runner, and CSV/TOML — all
simulator-agnostic, all already in ModelManager. It belongs here.

A **live Python bridge does not.** CLAUDE.md's simulator-agnosticism rule is about simulator backends, but the
same logic applies to inference backends, and the repo already has the right precedent: `RecipesBase` is a hard
dep while the plotting backend is the user's problem. A `ModelManagerBayesFlow.jl` — or a ModelManager
extension on `PythonCall` — implementing a documented `AbstractCalibrationMethod` is the correct home. It does
**not** belong in PCMM, which is PhysiCell-specific.

## Proposed Architecture — the first increment

### It is a sweep, not an ABC run

Because `LatentVariation(dv::DistributedVariation)` sets `latent_parameters = [Uniform(0,1)]` and folds the
prior into the forward map as a `quantile` call (`src/variations.jl:640-649`), **a space-filling design over
the unit hypercube *is* a design over the prior.** So
`addVariations(LHSVariation(n), inputs, pv, ref_vid)` (`src/variations.jl:1081-1087`) →
`variationsToMonads(inputs, variation_ids)` (`src/sensitivity.jl:492-495`) → `Sampling` → `run` is the entire
generation pipeline — exactly what `runSensitivitySampling` already does.

**Do not implement it as an `AbstractCalibrationMethod`.** `runCalibration(problem, method)`'s contract is to
return something a user calls `posterior` on; a training-set generator returns no posterior. Shoehorning it in
would force premature generification of `_saveMethod`/`_loadMethod` and leave `posterior(::Calibration)`
(`src/calibration/problem.jl:253`) pointing at a folder with no `generation_001.csv`. Instead:

```julia
exportTrainingSet(problem::CalibrationProblem;
                  n::Int,
                  design::AddVariationMethod = LHSVariation(n; add_noise=true),
                  description::String = "",
                  run_kwargs::NamedTuple = (;),
                  progress::Symbol = :auto,
                  on_monad_failure::Symbol = :reject) -> TrainingSet
```

It still calls `createCalibration("training-set"; description=description)`
(`src/calibration/calibration.jl:36`) so the run gets a DB row, a `data/outputs/calibrations/{id}/` folder,
provenance, `_saveProblem` and `_writeParametersTOML` (`src/calibration/abc.jl:616`, `:672`) for free — all
already method-agnostic. `calibrationsSchema()` declares `method TEXT` as free text, so a new label needs **no
`src/up.jl` milestone**. `TrainingSet` is a thin result struct (`calibration`, `path`, `n_rows`, `n_failed`,
`column_groups`) with a `Base.show` printing the path and the row/column counts.

**Match brief 05's keyword surface** — `run_kwargs`, `progress`, `on_monad_failure` are spelled as brief 05
settled them, not as a fifth convention. Read its `progress.md` entry first.

### The seam that retains the summary statistic

`_evaluateParticle` (`src/calibration/abc.jl:209-215`) computes `problem.summary_statistic(monad_id)` into a
local named `simulated` and immediately collapses it through `problem.distance` — the raw statistic is
discarded at `:212`. It also owns two error guards that must not be duplicated: the `try/catch` distinguishing
a user-code fault from a simulation failure, and the `distance isa Real` check.

Minimal, behavior-preserving split:

- New internal `_summarizeMonad(problem, monad_id, n_failed_simulations) -> Any` containing the `try/catch`
  around `problem.summary_statistic(monad_id)`, returning the raw value.
- `_evaluateParticle` becomes `_summarizeMonad(...)` followed by the guarded `problem.distance(...)` and the
  `isa Real` check — same messages, same `partial_note` text (`:210-212`).
- The exporter calls `_summarizeMonad` and never calls `distance`. `observed_data` and `distance` are unused by
  the export (they are what the *Python* side uses) but belong in the manifest for provenance.

**This is the seam every other option also needs** — a further argument for building it now.

### File format — consumer-agnostic by design

One directory per run: `data/outputs/calibrations/{id}/training_set/`.

`training_set.csv`, one row per monad, four prefixed column groups so nothing collides:

| group | columns | source |
|---|---|---|
| latent / CDF | `cdf:<latent_parameter_name>` | the design's CDF matrix (`AddLHSVariationsResult.cdfs`, `src/variations.jl:1086`) |
| target / display | `<display_name>` | `_particleRowToDisplay` per parameter (`src/calibration/abc.jl:1189-1223`) |
| summary | `s:<flattened_name>` | `_flattenSummary(_summarizeMonad(...))` |
| bookkeeping | `monad_id`, `n_success` | `monadIDs`/`simulationIDs` + a status query |

**Export both CDF and target space.** (1) The flow should train on the latent coordinates, because those are
`Uniform(0,1)^d` by construction — the prior-standardized, bounded, well-conditioned space an NPE wants, and it
needs no prior-transform layer. (2) The user needs target space to interpret anything, and it is what
`posterior(::Calibration)` already reports (`src/calibration/problem.jl:253-274`). (3) Both are already
computed. (4) The round trip is validated by `_validateInverseMaps` (`src/variations.jl:589-625`), so the two
groups are guaranteed consistent. Cost: `d` extra float columns. Take it.

⚠ **The `CoVariation{DistributedVariation}` case:** one latent dimension drives all targets
(`src/variations.jl:661-682`), so the CDF group has **fewer** columns than the target group. The manifest must
say which target columns belong to which latent column, or the Python side cannot reconstruct the
parameterization. `_writeParametersTOML` (`src/calibration/abc.jl:672`) already writes exactly that mapping —
reference it from the manifest rather than duplicating it.

`training_set.toml` — manifest: MM version, calibration ID, `n` and the design method with its settings, the
four column-group name lists, the summary-statistic and distance function names (or `nothing` if anonymous,
mirroring `_isAnonymousFunction`), a pointer to `../parameters.toml`, and the flattened `observed_data` if it
flattens, so the Python side has the observation to condition on.

`training_set_failed.csv` — monads with no successful simulation: `monad_id` plus the `cdf:` columns.
**Excluded from the training CSV, never padded, never `missing`-filled** — a flow trained on imputed rows is
silently wrong. This is a natural consumer of brief 03's failed-simulation records; if brief 03 has landed, tie
the two together rather than re-deriving.

### Tabularizing an arbitrary summary statistic

`summary_statistic` returns `T` for any `T` the user's `distance` accepts
(`src/calibration/problem.jl:20-23`) — a scalar, `Dict`, `Vector`, `NamedTuple`, or nested combination.

`_flattenSummary(x) -> Vector{Pair{String,Float64}}`:

- `Real` / `Bool` → `["value" => Float64(x)]`
- `AbstractDict` → sorted keys for determinism; `string(k) => Float64(v)`; recurse with `"$k.$sub"`
- `AbstractVector{<:Real}` → `"1"…"n"` (or the caller's base name plus index)
- `NamedTuple` → field names, recursing
- anything else → `ArgumentError` naming the type and telling the user to return a `Dict`/`Vector`/`NamedTuple`
  of `Real`s, or to write their own file from a `post_processor`

**Raggedness must be fatal.** The first successfully summarized monad fixes the column set; any later monad
whose flattened names differ raises an error naming that monad and the symmetric difference of the name sets.
Ragged summaries are a realistic failure (a time series truncated by early extinction), and padding them would
corrupt training silently. Do not invent a nested on-disk format for pass 1 — tell the user to return a
fixed-length statistic.

Reuse note: the sink's scalar contract in `_postProcessingColumnSpec` (`src/database.jl:1208-1222`) is the same
"only scalar `Real`/`Bool`/`String`" rule and its error message is a good model — but `_flattenSummary` is a
*different* function, because it flattens containers the sink deliberately refuses.

### Design draws: a caveat to surface, not bury

NPE's loss assumes θ ~ prior, i.i.d. from the joint p(θ)p(x|θ). LHS and Sobol are low-discrepancy,
**stratified** samples of the prior, not i.i.d. In practice stratification is a variance reduction and
BayesFlow users do use space-filling designs, but it is a real assumption violation and the manual must say so.

MM's `AddVariationMethod` subtypes are `GridVariation`, `LHSVariation`, `SobolVariation`, `RBDVariation` —
there is **no plain Monte Carlo sampler**. `LHSVariation(n; add_noise=true)` (jittered LHS,
`src/variations.jl:1069-1072`) is the closest and is the right default. A true i.i.d. design is one line via
`addCDFVariations(inputs, pv, ref_vid, rand(d, n))` (`src/variations.jl:1244`), so a
`MonteCarloVariation(n) <: AddVariationMethod` would be trivial — but it is a new public type in
`src/variations.jl` and belongs to a different brief. Ship with jittered LHS, document the caveat, and flag it.

### Prerequisites for a real `AbstractCalibrationMethod` — identified, mostly deferred

Four things are hardcoded to ABC. Record them so whoever commits to option (b) or (c) knows the bill:

1. **`_saveMethod(::Calibration, ::ABCSMC)`** (`src/calibration/abc.jl:441`) → must become
   `::AbstractCalibrationMethod` writing a per-method TOML dict, plus `methodLabel(::AbstractCalibrationMethod)`
   for the `calibrations.method` column. **Brief 05 introduces the `"type"` key in `method.toml` that this
   needs** — verify it landed.
2. **`_loadMethod(::Calibration)`** (`:1071`) → must dispatch on that type tag. Also brief 05's work.
3. **`_ProblemManifest.observed_data::Dict{String,Any}`** (`:498`) vs `CalibrationProblem.observed_data::Any`
   (`problem.jl:61`) — a **live crash** for `Vector`/scalar observations, which is the *normal* case for the
   amortized-inference audience, and the exporter calls the same `_saveProblem`. **Brief 05 fixes this;
   verify, and fix here if it has not landed.**
4. **No `AbstractCalibrationResult` supertype.** `posterior` dispatches on `ABCResult`
   (`problem.jl:220`) and on `Calibration` (`:253`). The `Calibration` form is already method-agnostic — it
   globs `generation_\d+\.csv` and does `select(df, Not([:weight, :distance, :monad_id]))` (`:270-272`). **So
   the generation-CSV format is the interop contract:** any method writing a `generation_001.csv` with
   parameter columns plus all three of `weight`, `distance` and `monad_id` gets `posterior` and the
   corner/ridgeline/convergence recipes for free. An NPE method emitting posterior draws would set
   `weight = 1/N` and must still emit a `distance` column (`NaN` is fine) or the `Not([...])` select throws.
   Document the contract now; refactor into an `AbstractCalibrationResult` only when a second real method
   lands. **Note brief 06 renames the `distance`-adjacent epsilon keys but not these three columns** — confirm.

**Only (3) is in scope here, and only if brief 05 has not already done it.**

### What must NOT be attempted in the first pass

- No `PythonCall` / `CondaPkg` / `[weakdeps]` / `[extensions]` / `ext/`. Not even "just in case."
- No `NeuralPosteriorEstimation <: AbstractCalibrationMethod`.
- No import path — do not read a trained posterior back into a `Calibration` or make `posterior()` work on it.
- No sequential / multi-round NPE (needs the trained network inside the sampling loop, which needs the method
  abstraction *and* a bridge).
- No `AbstractCalibrationResult` refactor.
- No embedding-network or raw-time-series format; require flat, fixed-length summaries and fail loudly.
- No BayesFlow-specific binary layout (`.npz`, HDF5 key conventions). CSV + TOML, plus a six-line
  `pandas`/`numpy` loader snippet in the new manual page. MM has no NPZ writer, and JLD2 (a dep) is not
  readable from Python.
- No guessing at network architecture or training schedules in the docs beyond "see BayesFlow's own tutorials."

## Testing Strategy

**Unit (no DB)** — beside `"_toCalibrationParameter and CalibrationProblem parameter conversion"`
(`test/runtests.jl:269`):
- New `"_flattenSummary"`: scalar, `Dict{String,Float64}` (assert sorted, deterministic order),
  `Vector{Float64}`, `NamedTuple`, nested `Dict` of `Vector`; `@test_throws ArgumentError` for a
  non-flattenable value (a `Matrix` or a custom struct).
- New `"training-set column consistency"`: the ragged-summary check errors and names the offending monad and
  the differing keys.

**`observed_data` widening** (skip if brief 05 landed it, but assert the coverage exists):
- `"_hasAnyAnonymousFunction and _ProblemManifest"` (`:1616`) — a `_ProblemManifest` from a problem whose
  `observed_data` is a `Vector{Float64}`, and from one where it is a bare `Float64`.
- `"_ProblemManifest JLD2 round-trip"` (`:1669`) — round-trip a `Vector` and a scalar; also assert an existing
  `Dict{String,Any}` still round-trips (the backward-compatibility guarantee).

**DB-backed** (inside the `mktempdir` at `:2095`; fixtures `xp_x`, `inputs` at `:2144-2146`):
- New `"exportTrainingSet end-to-end"` after `"runCalibration end-to-end"` (`:2561`), modeled on it. Reuse the
  named fixture `_test_named_ss` (`:95`), which returns `Dict{String,Any}("x" => 1.0)` — already the right
  shape, and named so `_saveProblem` produces a complete manifest without the anonymous-function warning.
  Assert: a `calibrations` row with `method == "training-set"`; the folder contains
  `training_set/training_set.csv`, `training_set/training_set.toml`, `problem.jld2` and `parameters.toml`; the
  CSV has `n` rows and exactly the four expected column groups; every `cdf:` value is strictly in `(0,1)`; and
  the `cdf:` and display columns are consistent — recompute the target from the CDF with
  `ModelManager.variationValues(cp.lv, [cdf])` and compare.
- New `"exportTrainingSet with failed monads"`: reuse the failure injection from `"on_monad_failure=:reject"`
  (`:2624`) and `"_batchOutcome classifies a batch"` (`:2935`) to force a monad with no successful simulation;
  assert it lands in `training_set_failed.csv`, is absent from `training_set.csv`, and
  `n_rows + n_failed == n`.
- New `"exportTrainingSet and discrete parameters"`: assert the behavior matches whatever brief 07 Stage 1b
  settled — either the `ArgumentError` still fires, or discrete parameters export with a `cdf:` column derived
  from the index mapping. **Check brief 07's `progress.md` entry before writing this test.**

`"docstrings only @ref public bindings"` (`:4310`) is automatic. `exportTrainingSet` and `TrainingSet` need
docstrings with an example (Definition of Done item 2). Safe `@ref` targets: `CalibrationProblem`,
`Calibration`, `LHSVariation`, `SobolVariation`, `DistributedVariation`, `CoVariation`, `LatentVariation`,
`runABC`, `runCalibration`, `posterior`, `mseDistance`, `run`, `postProcessingTable`. **Not** linkable:
`_summarizeMonad`, `_flattenSummary`, `_evaluateParticle`, `_saveProblem`, `_writeParametersTOML`,
`_ProblemManifest`, `addCDFVariations`, `variationsToMonads`.

**⚠ Docs plumbing, easy to miss:** `docs/src/lib/calibration.md` has a hand-maintained `Pages = [...]` list;
`training_set.jl` must be added or its docstrings will not render and `checkdocs=:exports`
(`docs/make.jl:68`) **will** fail on the exported names. Add the new manual page
`docs/src/man/amortized_inference.md` to the "Uncertainty Quantification" group at `docs/make.jl:37-40`.

## Estimated Effort

- **Lines of code:** ~250 in `src/calibration/training_set.jl`, ~15 in `abc.jl` (the `_summarizeMonad` split),
  ~5 in `ModelManager.jl`; ~200 in tests; ~150 in the new manual page. Plus the spike, which produces a
  written recommendation and no production code.
- **Risk level:** **Low-Medium.** No new dependency, no schema change, no concurrency change. The real risks
  are format decisions that are expensive to change later — the column-group naming and the flattening rules.
- **Dependencies:** brief 07 Stage 1 (hard); briefs 05 and 03 (soft, both reduce work here).

## Open questions for the user

1. **Is the export-only first increment what you want**, with (b1) file-based bridge as the documented
   escalation and (b2) `PythonCall` explicitly off the table? Recommended.
2. **Should the spike on `NeuralEstimators.jl` / `InvertibleNetworks.jl` happen before or after the export
   lands?** After is cheaper — the spike needs a training set to try. Recommended: export first, spike second,
   using the exported file.
3. **`MonteCarloVariation(n) <: AddVariationMethod`?** One line over `addCDFVariations`, and it removes the
   i.i.d.-assumption caveat entirely. New public type, so it belongs to its own brief. Default if unanswered:
   ship with `LHSVariation(n; add_noise=true)` and document the caveat.
4. **Training-set format — CSV + TOML, or something Python reads faster?** CSV is inspectable, needs no new
   deps, and loads trivially with `pandas`. A 20,000-row × 500-summary-column set is ~100 MB of CSV. If you
   expect that scale routinely, the answer may be a documented conversion step rather than a different Julia
   writer — worth knowing before the format is fixed.
5. **Does `n_replicates > 1` make sense for an NPE training set?** ABC uses replicates to denoise a single
   particle's distance. For NPE, `n` distinct parameter draws with 1 replicate each generally beats `n/k` draws
   with `k` replicates, because the flow *wants* to see the simulator's stochasticity. Recommendation: respect
   the user's `n_replicates`, record `n_success` per row (the current design), and add a one-line note in the
   manual.

## Cross-cutting rules

**Review-only comments.** The repo uses `#!` for *permanent* design-rationale comments (316 of them). Any
comment written purely so the user can follow your reasoning during review must be marked `#REVIEW:` and
removed before merge.

**Docs are for an outside reader, not a changelog.** User-facing prose explains how to use the code as it now
is. Where a "why" is needed it must be the grand-narrative why, never this repo's history:

> ✅ "Updates are delayed until the next Julia session so as not to corrupt the currently loaded session state."
> ❌ "Updates must be delayed because updating mid-session had the potential to produce incorrect session states where upgrades would never actually proceed."

Applied here: the manual explains what the training set is and how to load it. It does not explain that
ModelManager once considered a `PythonCall` bridge — that belongs in `progress.md`.

## Pre-merge checklist

- [ ] `julia --project=. -e 'using Pkg; Pkg.test()'` green.
- [ ] `rg '#REVIEW:' src/ test/` returns nothing.
- [ ] `Project.toml` and `Manifest.toml` **unchanged** — no new dependency without explicit user approval.
- [ ] `training_set.jl` added to `docs/src/lib/calibration.md`'s `Pages` list, and
      `docs/src/man/amortized_inference.md` added to `docs/make.jl` — otherwise `checkdocs=:exports` fails.
- [ ] `exportTrainingSet` and `TrainingSet` have docstrings with a usage example.
- [ ] The i.i.d.-versus-stratified caveat is stated in the manual, not omitted.
- [ ] Docs written outside-in per the rule above; no repo history in `docs/`.
- [ ] `README.md` Implementation Status and `PRD.md` updated.
- [ ] `progress.md` records the option analysis, the spike's verdict, and the deferred
      `AbstractCalibrationMethod` prerequisites.
