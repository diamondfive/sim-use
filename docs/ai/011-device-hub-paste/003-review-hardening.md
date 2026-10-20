# 011.003 — Review hardening

> Updated 2026-10-20: Round 2 found that menu presence and dismissal did
> not require the action-group evidence used by matching. See
> [004-menu-presence-proof.md](004-menu-presence-proof.md) for R172-05.

## Context

Review round 1 of #172 found four safety and compatibility gaps at `5f0a30c`.
This amendment records the decisions before implementation. The prior live
measurements remain valid for that revision, not proof of these changes.

## Decisions

| Finding | Decision | Reason |
| --- | --- | --- |
| R172-01: AX errors after Paste can trigger daemon retry | Put the final send and completion check behind one error boundary. Return a fixed ambiguity message without the underlying error text. Test the boundary through daemon dispatch/client for standalone and batch-shaped requests. | The legacy daemon classifier uses message substrings. Wrapping while retaining the original message is not sufficient. Even a failed HID send can have partial effects. No wire change is needed. |
| R172-02: absent Select All can append | Require Select All unless a pre-menu snapshot proves that exactly one editing text-entry control has an explicitly empty AX value. Decode the existing `traits` field for this internal check. Missing, secure, ambiguous or nonempty values are not proof. | An absent action is not evidence that the field is empty. This preserves ordinary empty-field replacement without guessing from menu labels. |
| R172-03: existing menus erase the app baseline | Restrict typed Menu/MenuItem actions to their subtrees. For newer modal trees, require a full-screen anonymous backdrop and one anonymous action group whose Paste and Select All targets have no app identifiers. Retain non-menu controls as the baseline when reusing that menu. | Live checks showed that Escape does not dismiss a selected-range menu. Do not add a default touch or arrow that can change the caret/range. Replacement and explicit retargeting may collapse the range before capturing a fresh baseline, since these modes intentionally change it. |
| R172-04: translated actions are incomplete | Cover the Paste and Select All translations in installed UIKit runtime resources, including Russian and Portuguese and existing label variants. Keep exact label matching and menu/baseline checks. | Guessing by position or fuzzy labels can activate an unrelated action. The former list also omitted the native Japanese and German Select All labels. |

## Verification plan

1. Add failing no-device regression tests for each finding before fixes.
2. Test the production final-send boundary through the real daemon server,
   dispatch and client. Assert one execution and one Paste action after an
   injected retry-classified AX error, including batch-shaped requests.
3. Test empty/nonempty/unknown/secure/ambiguous editing fields and typed
   menu hierarchies with app decoys and no native Paste.
4. Run `make build`, `make test`, and affected focused tests.
5. Coordinate any live clipboard or locale mutation with the user. Do not
   disrupt active simulators or claim the old matrix verifies this revision.

## Initial verification

- The user approved a single-writer clipboard window for live Playground
  checks. Save all host clipboard item data without printing it. Restore only
  when the current clipboard still matches the experiment-owned checkpoint.
- `make build` passed. The first full suite found a scheduling-dependent
  test timeout in menu dismissal. The test now uses an injected monotonic
  clock and sleep; production timeouts are unchanged. The next `make test`
  passed 1767 tests with no failures.
- The first focused regression run failed on all four findings before the
  fixes. The initial green run passed 35 tests in seven suites, including
  the production send boundary through the real daemon dispatch/client.
- All Paste and Select All translations from installed iOS 18.1, 18.6,
  26.5 and 27.0 UIKit resource tables are present in the matcher.

## Live corrections

- The first focused live suite passed normal,
  targeted, caret, selection and batch cases. The existing-menu case failed
  because Escape did not close the selected-range menu. The restricted
  control refused replacement as intended, but its menu hid the AX echo.
  Read its field only after a confirmed backdrop tap outside all action
  frames closes that menu; Right and Escape alone did not do so.
- A manual center-touch experiment hit Search Web, which occupied the
  screen center in the expanded menu. The delayed system-browser launch
  invalidated that experiment. Arbitrary backdrop coordinates are rejected.
  For replacement and explicit retargeting only, find a point outside every
  AX control frame before closing a modal menu. Normal paste sends no
  dismissal touch and preserves its range by reusing the scoped menu.
- The native group can contain system identifiers, including `dd-search-web`.
  Only Paste and Select All targets must have no app identifier. Tests cover
  this captured shape and a dismissal point that avoids Search Web.

## Verification outcome

- Final `make build`: passed. Final `make test`: **1770 passed**, no
  failures; coverage **70.89995814148179%**.
- `swift test --filter 'PasteEditMenuTests|DaemonClientInvokeErrorRoutingTests|AccessibilityElementTests'`:
  **38 tests passed in seven suites**. This includes partial-send and
  post-send AX errors through the real daemon server, dispatch and client,
  with one execution and one Paste action for standalone/batch-shaped requests.
- Final live filter: `PasteTests/(replacePaste|replacePasteViaMenu|replacementWithoutSelectAll|existingMenuWithDecoy|batchPaste|insertionAtCaret|replacesSelection)`:
  **7 tests passed** on iPhone 17 / iOS 27.0 with Device Hub 27.1 running.
  Clipboard ownership was 1 (CoreDevice). The restricted native control
  passed both standalone and batch cases: empty replacement succeeded;
  populated replacement refused, and its actual field remained unchanged.
  The existing-menu test preserved the selected range and did not activate
  the app's same-label Paste button.
- A private per-process locale driver confirmed actual native `Вставить`
  and `Colar` labels before testing Russian and Portuguese. Empty,
  populated and batch replacement each passed for both languages. The
  generated fixture declared those localizations, and launch arguments
  selected each language only for the Playground process. The normal
  fixture was reinstalled afterward. No global locale setting changed.
- The original Playground Gesture Presets screen, foreground package,
  display bounds and orientation were restored. Full host clipboard item
  data was restored only after exact experiment-checkpoint and change-count
  equality. Restoration then confirmed exact item data equality. Private
  snapshots and captures remain under ignored `.build/review-172/`.
- `git diff --check`: passed. No release, tag, installed CLI replacement,
  simulator reboot, host switch or display-state change was performed.

## Boundaries

- A control that hides or overrides its AX value can be refused for empty
  replacement. It can still use ordinary paste; replacement must not append.
- This round did not rerun the full Simulator.app/Device Hub host matrix,
  Android live tests, or paid agent evals. Mixed app/menu synthetic trees
  and post-Paste AX faults have no-device coverage; no live AX fault was
  injected. Earlier host-matrix results describe the original revision.
