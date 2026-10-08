# Focused puzzle release

The pre-change implementation is preserved on `archive/before-focused-puzzles-2026-10-07`.
Collection/reward presentation files are removed from the target. Existing saved ownership,
shards, equipment and pending rewards remain untouched; the live scene uses the original set.
Unsupported active sessions move to `suspendedModeSession` without an attempt or score charge.

The two active families are checkmate and short improvement (forced material gain, accepting
checkmate as a better result). Free-play six-turn improvement and all other modes are paused.
The two families alternate; the initial family is randomly selected. This preserves the prior
no-consecutive-same-type requirement. Each shape from 4×4 through 8×8 has probability 1/25.
Boards beyond 8×8 are outside the existing chess representation and are not introduced.

A frozen `FocusedPuzzleSelection` is drawn before skill-based ranking. Reviews, compositions,
and prepared handoffs must match it. Failed certification retains the draw instead of sampling
an easier shape. Ability, tags and current score continue to select difficulty within that shape.
The last three puzzle/position/source identities remain excluded. No proof/search budget changed.
The prover verifies every submitted candidate against every defense, accepting alternate
continuations and reporting budget exhaustion as unknown rather than a mistake.

Validation: `scripts/run_focused_regressions.py`; UI tests
`testFocusedPuzzlesHideCollectionAndRewards` and `testContinuousPuzzlesAcrossEveryShape`.

Verified on 2026-10-07:
- 301,562 selector/migration assertions, including 100,000 shape draws and all
  50 shape/family combinations at four skill levels.
- 273,072 native/independent checks, 26,207 certified symmetry variants, 128
  independent Python AND/OR proofs and 1,146 alternate continuation branches.
- 15,031 candidate-move comparisons, including 39 positions with alternative
  winning routes. Budget exhaustion remains ungraded.
- Simulator completion/transition/input checks on all 25 shapes and explicit
  absence of collection/reward UI, including a saved pending reward fixture.
- Signed iPhone Release build and strict code-signature verification.
- Three additional UI regressions passed: info-button hit testing, per-puzzle
  hearts/penalties, and family/recency preservation across skips and relaunch.
