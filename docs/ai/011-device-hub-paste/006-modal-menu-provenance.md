# 011.006 — Prove modal edit-menu provenance

## Context

Round 4 of #172 independently resolved R172-06 and reopened R172-05.
An ordinary editor can expose a full-screen Preview button, an editing
Caption field and an anonymous Copy/Paste toolbar group. The action label
and missing identifiers did not prove that the group was a native menu.
The default path could remove an app Paste action from its baseline and
select it; preparation could tap the app background as a dismissal action.

## Evidence and decision

- Existing real iOS 27 captures expose the menu group and a dedicated
  full-screen dismissal Button as siblings under the Application. The
  dismissal label is UIKit's localized `context.menu.dismiss`, not an
  arbitrary background label. The editing field is absent from this modal
  tree. These facts are independent of the action being Copy or Paste.
- Require the dedicated dismissal control and sibling topology for anonymous
  modal menus. Use exact UIKit accessibility-bundle translations from the
  installed iOS 18.1, 18.6, 26.5 and 27.0 runtimes. Do not fuzzy-match labels.
- A normal editor tree with a Preview button and Copy/Paste toolbar is not a
  native modal menu. Keep those actions in the app baseline and invoke the
  focused field's native menu normally. Never dismiss the app background.
- Refuse ambiguous modal-like trees before any preparation gesture or default
  menu reuse: multiple candidate groups/containers, conflicting visible editor
  content with a native dismissal control, or an isolated group/backdrop with
  unknown provenance. Do not use keyboard dismissal as an ambiguity fallback.
- Share the evidence between presence, matching and dismissal. Typed Menu and
  MenuItem roles remain supported. Remove the unscoped all-tree action fallback;
  a newly visible same-label app control is not native-menu evidence either.
- Do not claim an AX signature can prove an app handler's semantics. The
  native edit menu/control contract still applies. Unknown structures fail
  closed rather than guess a Paste/dismissal target.

## Verification plan

1. Add ordinary-editor Copy and Paste toolbar regressions. Use the production
   baseline expressions and preparation helper; observe false presence, app
   action selection and one unrelated dismissal callback before fixing them.
2. Retain typed/modal/localized Copy-only menus and collision tests. Cover
   ambiguous, unknown and cross-container provenance without any gesture.
3. Run build, full unit tests and focused paste/daemon suites. Validate the
   changed native modal paths live with a fresh clipboard backup; restore
   guardedly and verify the original screen/display/preferences/locale.
4. This is the fourth/final configured review round. Record that this fix
   follows the final independent review and has not received another one.

## Outcome

- Red: the ordinary Copy/Paste toolbar and unscoped-action tests built, then
  failed with 14 issues. Both toolbar variants triggered one dismissal callback;
  the Paste variant also lost its app baseline and selected the app action.
- Green: ordinary toolbar controls remain in the baseline, preparation returns
  without dismissal, and unscoped actions are refused. Additional cases cover
  unknown backdrops, cross-container evidence, visible-editor conflicts,
  multiple groups and multiple containers without a dismissal callback.
- Retained typed menus, localized Copy-only menus, existing app decoys and
  Search Web collision coverage. Nine dismissal-language cases pass. A direct
  comparison confirmed all 51 dismissal strings match the installed UIKit
  accessibility-bundle values exactly.
- `make build` succeeded. `make test` passed 1779 tests with zero failures.
  The focused clipboard/menu/AX/batch/daemon run passed 105 tests in 16 suites.
- Live on iPhone 17/iOS 27.0 with Device Hub 27.1 and the debug binary:
  `PasteTests/(basicAsciiPaste|replacePaste|replacePasteViaMenu|existingMenuWithDecoy|batchPaste|insertionAtCaret)`
  passed all six tests in 120.0 seconds. This covers default paste, empty/nonempty
  replacement, targeted replacement, middle-caret insertion, batch delivery
  and existing-menu selected-range reuse without activating the app decoy.
- A fresh round-4 clipboard backup was saved. The generic marker guard refused
  the final test's LF payload before any restore. The final field/decoy receipt,
  three exact plain-text LF aliases and valid CoreDevice sync metadata were
  checked before taking a full-item/change-count checkpoint. The guarded
  restore then confirmed exact equality with the original saved items.
  No extra marker Paste was sent. The original Gesture Presets page, display,
  orientation, keyboard/sync preferences and global locale were unchanged.
- README, skill and changelog describe fail-closed menu provenance. No command,
  wire envelope or compatibility-floor change was needed; the existing
  unreleased 0.16.0 skill floor is retained.

## Limits and review state

The ordinary-app toolbar reproduction is deterministic AX/helper coverage,
not an additional live ordinary-app fixture. The six live tests exercise the
new positive signature on genuine menus. No fresh host/keyboard/display matrix,
live AX fault injection, Android/physical-device live run, Linux build or paid
eval was performed. Earlier matrix results predate review hardening.

R172-01 through R172-04 and R172-06 were independently confirmed resolved.
The R172-05 fix above follows the final configured review, so it has not
received another independent review. Passing main's checks is not a
reviewer-confirmed clean result. No extra review round is delegated here.
