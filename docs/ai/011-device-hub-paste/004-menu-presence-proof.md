# 011.004 — Require positive menu evidence

> Updated 2026-10-20: Round 4 reopened R172-05. An anonymous app Copy/Paste
> toolbar also meets the action-group predicate below. A dedicated native
> dismissal control and modal provenance are now required; see
> [006-modal-menu-provenance.md](006-modal-menu-provenance.md).

## Context

Round 2 of #172 resolved R172-01 through R172-04 and found R172-05.
The modal presence and dismissal predicates accepted any anonymous Button
with the Application frame, even when there was no native menu. Preparation
for replacement or explicit retargeting could therefore tap an app's
full-screen Preview button. The same false positive could keep the final
completion check from observing that the native menu had closed.

## Decision

- Share the native modal action-group predicate between matching, presence
  and dismissal. A full-screen button alone is not menu evidence.
- Require an anonymous group of action controls with at least one known
  native editing-action label on an action control, not static text alone.
  Include native Cut/Copy translations so a
  Copy-only menu remains detectable without accepting unrelated app groups.
- Presence can retain ambiguous native groups as a reason to wait/refuse,
  but a dismissal touch requires exactly one qualifying group and backdrop.
- Preserve typed Menu/MenuItem support, system action identifiers, action
  collision checks, and the pre-invocation app baseline.
- An ordinary app snapshot must return from shared preparation without any
  dismissal callback. This helper serves both replacement and retargeting.

## Verification plan

1. Red/green synthetic snapshots: full-screen Preview plus an editing Caption
   field, with direct and grouped field layout. Assert no menu, no dismissal
   target and no dismissal callback during shared preparation.
2. Reject a generic anonymous app action group and static Copy text.
   Retain genuine Paste/Copy menus, ambiguity refusal and Search Web collision
   coverage, plus the post-Paste daemon replay tests.
3. Run `make build`, `make test` and affected live Playground replacement,
   explicit retargeting and existing-menu checks. Save the current clipboard
   again before live writes; do not reuse an earlier snapshot as the backup.
4. Record actual results below. Do not claim the full host matrix or an
   ordinary-app live fixture unless it was executed.

## Implementation and verification

- Extracted `modalActionGroups` so matching, presence and dismissal use the
  same positive action evidence. Presence recognizes ambiguous native groups
  as a reason to wait/refuse; dismissal requires a unique group. Disabled
  full-screen buttons cannot supply the backdrop.
- The new ordinary-app snapshots first failed with one dismissal callback
  and a preparation timeout. After the fix, preparation returned the app
  snapshot without invoking dismissal. Direct and grouped Caption fields
  are covered by this shared-helper regression.
- A separate red/green case rejected a generic Save caption button group.
  An additional red/green case rejected static Copy text as menu evidence.
  Genuine native actions, including localized Copy-only groups, remain valid.
- Focused regression command:
  `swift test --filter 'SimulatorPasteboardTests|PasteboardProcessTests|PasteEditMenuTests|PasteDurationValidationTests|PasteboardLockTests|BatchPasteStepParsingTests|PasteForwarderTests|DaemonClientInvokeErrorRoutingTests|AccessibilityElement'`:
  **79 tests passed in 12 suites**. Rerun with `--skip-build` after the final
  static-text refinement: **79 passed in 12 suites**.
- Final `make build`: passed. Final `make test`: **1772 passed**, no
  failures; coverage **70.77019673503558%**. This full run includes the
  strengthened static-text regression.
- Final live filter `PasteTests/(replacePaste|replacePasteViaMenu|existingMenuWithDecoy)`:
  **3 tests passed** on the same iPhone 17 / iOS 27.0 / Device Hub 27.1 target.
  This covers default replacement, explicit menu-target replacement and
  existing selected-range menu reuse with the final production predicate.
- A fresh clipboard snapshot was saved for this round. After testing,
  guarded restoration confirmed exact full clipboard item equality, and
  the Playground returned to its initial Gesture Presets screen with the
  same display bounds and orientation. Private evidence is under ignored
  `.build/review-172/r2/`.
- `git diff --check`: passed. No commit, push, PR comment, release or
  installed-binary replacement was performed in this round.

## Boundaries

- The ordinary-app full-screen-button failure is covered by deterministic
  AX snapshots of the production shared helper, not a live ordinary-app
  fixture. Both replacement and explicit retargeting call that helper;
  their genuine-menu flows were checked live.
- No new full host matrix, Android live test, locale experiment or paid
  agent eval was run.
