# 010.004 — Remove the side-bar wide-content gate

Status: Implemented

## Context

On 2026-10-20, the Duo cover outline again split five vertical tabs between
`Content` and `Bottom`. The captured screen is 466x678, with tabs at x=396.
No content crosses that boundary. However, the widest content node beside
the tabs is 182 pt, below the required 233 pt (half the screen width).
The content consists of separate cards and recovered accessibility nodes.

The half-screen gate first appeared in `bc507f5`. `f44cdc9` restricted its
evidence to the bar's vertical range after a profile form was mistaken for
a bar (S4-004). `fd644e0` later restored crossing checks below the bar; those
checks independently reject both profile-form regressions. The exact 50%
threshold has no recorded platform or measurement basis.

## Decision

Remove the requirement for a single adjacent content node at least half as
wide as the screen. The owner selected removal, not a smaller threshold or
a separate native-tab semantic path. Small cards and sparse content do not
prove that an otherwise qualified side bar is absent.

Keep edge anchors, vertical stacking, horizontal-tab exclusion, the top-band
back-button check, content crossing checks, explicit-region priority and
full-height content-pane bounds. The half-screen test used to qualify a
full-height content-pane ancestor is a separate rule and stays unchanged.
Printed frames, hit targets, raw AX data and routing do not change.

The old sparse-screen negative test (a back button above a small logo) will
now accept a leading column. It pinned the removed gate, not an independent
signal that distinguishes content from chrome. Record that broader inference
explicitly rather than replace the gate with another arbitrary threshold.

## Verification plan

- Add a sanitized capture, retaining all 31 nodes, geometry, ancestry and
  native metadata, but no app identity, personal labels or process ids.
- First reproduce the missing `Trailing` region with that capture.
- Cover narrow cards on both edges and the changed sparse-column behavior.
- Keep profile-form, crossing-content, horizontal-tab, single-tab, iPhone,
  iPad and overflowing-pane regressions.
- Run focused outline tests, `make build` and `make test`.
- Read the already-booted Duo screen with the debug binary, without input,
  rotation, folding or app switching. Do not publish or install a release.

## Outcome

Removed only the adjacent-node width gate and its unused vertical-range
calculation from `OutlineSideBars.swift`. No native-tab decoding or replacement
threshold was added. Updated `OutlineSideBarTests.swift`, the unreleased
changelog and the historical records that described the removed requirement.

Verification on 2026-10-20:

- Before the production change, the captured-tree test failed with seven
  assertions: the five tabs remained in `Content` / `Bottom` and there was
  no `Trailing` region. The synthetic narrow-card and sparse-column tests
  also failed as expected.
- `swift test --enable-code-coverage --filter OutlineSideBarTests`: 24 tests
  passed, including narrow or absent content on both edges, narrow crossing
  content, both profile-form shapes and the existing captured fixtures.
- `make build`: passed.
- `make test`: 1722 tests passed, no failures.
- `SIM_USE_NO_DAEMON=1 .build/debug/sim-use ui --device <Duo> --json --no-raw`:
  all five live tabs were in `[Trailing  x>=396]`, with their original frames.
  No input, app switch, rotation or fold was sent.
- The sanitized fixture preserves all 31 nodes, parent-child relationships,
  frames, roles, traits and enabled state. Its outline keeps all 30 entries,
  the 150x147 card frame and monotonic aliases.

The PATH installation was not replaced. No release was published.
