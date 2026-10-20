# 011 — Simulator paste: Action log

> Updated 2026-10-20: Review found gaps in post-send error handling, missing
> Select All, existing-menu matching and localization. The implementation and
> verification below describe `5f0a30c`. See [review hardening](003-review-hardening.md)
> for the corrections and their separate verification.

## Status

Implementation and local validation are complete on the branch. Review and
merge are pending. This change does not publish or install a release.

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-10-20 | Identified rejected legacy snapshots under CoreDevice ownership; verified CoreDevice staging separately from native delivery | [Investigation](000-investigation.md), [source review](source-review.md) |
| 2026-10-20 | Approved implementation, host validation and pull request; recorded delivery and safety decisions before the changes | [Implementation plan](001-implementation-plan.md) |
| 2026-10-20 | Added verified staging, native edit-menu delivery and shared batch execution | This change |

## Outcome

- `SimulatorPasteboard` tries simctl and accepts its readback only when guest
  CoreDevice ownership is confirmed inactive. Otherwise it uses CoreDevice.
  Both backends must return the exact UTF-8 bytes. Timeout and cancellation
  are final. Unexpected clipboard bytes never enter errors or logs.
- `PasteboardProcess` passes text on stdin, not in xcrun arguments. It polls
  stdin, stdout and stderr together, limits captured output, and terminates
  the child on timeout, cancellation or I/O failure. Early input closure is
  not successful staging. Descendant-held pipes cannot cause an unbounded
  wait after the tool exits.
- `PasteboardLock` holds a private, validated host-user lock across staging,
  verification, delivery and menu dismissal. Per-device daemons cooperate;
  external clipboard writers remain outside this lock.
- Default paste opens the focused control's menu with USB Application usage
  101. It does not long-press the field or move its caret/selection.
  Explicit `--via-menu` retains ID/coordinate targeting. Both paths use the
  native Paste action, with a real 50 ms down/up hold and a stable-menu gate.
- Replacement collapses an existing selection, invokes native Select All,
  then uses fresh Paste geometry. It does not repeat a long-press after
  selection. Empty-field replacement is included in the live tests.
- Matching excludes existing app controls, including identified controls
  that move during layout. Disabled, zero-size and non-menu roles cannot
  supply the Paste target. Clipboard bytes and item geometry are verified
  again immediately before the final action. Paste itself is never retried.
- Batch paste is one host-action barrier that reuses the active HID session
  and the standalone implementation. It supports menu targeting. Batch
  stdin still belongs to the batch and cannot supply one paste step.
- README, command help and bundled skill now describe the supported native
  path instead of obsolete Cmd+V/hardware-keyboard restrictions. Android
  ACTION_PASTE and physical-iOS capability restrictions remain unchanged.
  No daemon/bridge wire or success JSON change is required. The skill floor
  remains the same unreleased 0.16.0 version.

Key files:

- `Sources/iOSSimBackend/Sim/SimulatorPasteboard.swift`
- `Sources/iOSSimBackend/Sim/PasteboardProcess.swift`
- `Sources/iOSSimBackend/Sim/PasteboardLock.swift`
- `Sources/iOSSimBackend/A11y/PasteEditMenu.swift`
- `Sources/iOSSimBackend/Verbs/IOSSimPasteCommand.swift`
- `Sources/iOSSimBackend/Batch/Command+BatchConvertible.swift`
- `Sources/iOSSimBackend/Batch/BatchStepParser.swift`
- `Tests/SimulatorPasteboardTests.swift`, `Tests/PasteEditMenuTests.swift`
- `Tests/PasteTests.swift`, `Tests/BatchPasteStepTests.swift`
- `Playgrounds/iOS/SimUsePlayground/Views/PasteTestView.swift`

## Verification

### Build and unit tests

- `make build` passed.
- `make test`: **1758 passed**, no failures; coverage **70.78694014231897%**.
- Focused backend, real-process, menu, duration, lock and batch tests:
  **37 passed in six suites**.
- The moving same-label app-control regression failed before the identity
  fix and passed after it.
- The full parallel suite exposed timing assumptions in subprocess tests.
  Cancellation now waits for a child-start marker and checks that its PID
  exited. Timeout/output/input-closure tests assert the exact failure, not
  an unrelated caller scheduling deadline. Production timeouts were not
  increased to make the tests pass.

### Live host coverage

All paste tests use only Playground and synthetic input. The 14-test suite
checks default and namespaced Unicode, empty/populated replacement, ID and
coordinate targeting, file/stdin with final LF, **104,019-byte actual field
insertion**, middle caret, prior selection, repeated replacement, batch and
no-focus/same-label refusal. It has no software-keyboard skip or append
exemption. The large field must match exact UTF-8 bytes.

| UI host | CLI tool selection | Runtime / device | Ownership / dtuhidd | Result |
| --- | --- | --- | --- | --- |
| Simulator.app 26.6 | Xcode 27.1 | iOS 27.0 / iPhone 17 | 0 / absent, before and after | 14/14; final no-focus cases rerun after matcher hardening |
| Simulator.app 26.6 | Xcode 26.6 | iOS 26.5 / iPhone 17 Pro | 0 / absent, before and after | 14/14; separate native field check logged simctl staging |
| Device Hub 27.1 | Xcode 27.1 | iOS 27.1 / Duo cover | 1 / present, before and after | 14/14; separate native field check logged CoreDevice staging |
| Device Hub 27.1 | Xcode 27.1 | iOS 27.0 / iPhone 17 | 1 / present, before and after | 14/14 |

Xcode 27.0/27.1 installations on this host have no Simulator.app bundle.
The classic checks therefore use the actual installed 26.6 application,
not a claimed Xcode 27 Simulator.app or only a headless Hub-closed boot.
The iOS 27.0 full classic run preceded the final pure matcher hardening;
its final ordinary/replace no-focus cases were then rerun. Later runs
include that hardening.

The first Hub Duo run overlapped external clipboard activity. It recorded
one exact-readback refusal and actual field mismatches. The run is retained
as failed evidence, not accepted or skipped. The user then paused clipboard
writes for a clean rerun without production code changes. That rerun passed
all 14 tests, including the previous failures; none was skipped or relaxed.

### Additional checks

- Runtime hardware keyboard enabled on iPhone 17: **5/5 passed**, including
  default/namespaced Unicode, replacement, explicit menu replacement and
  middle-caret insertion. The software keyboard was observed visible before
  enable and hidden after enable. The runtime flag was disabled afterward,
  and a targeted reboot restored the unchanged boot configuration.
- Keyboard/clipboard preference projections in both Simulator.app and Hub
  domains compared equal before and after that experiment.
- Duo inner display: **5/5 passed** for default paste, empty/populated
  replacement, targeted replacement, explicit coordinates and batch.
  The cover display and its rotation were restored afterward.
- Two simultaneous per-device CLI requests inserted distinct synthetic
  payloads into the two respective fields: **2/2 exact target values**.
  Both fixture fields were cleared. This tests cooperative sim-use writers,
  not isolation from arbitrary external apps.
- Affected-command smoke: **5 executed iOS cases passed**: describe-ui,
  tap, type, scroll and screenshot. The screenshot filter also matched one
  disabled Android case; it was skipped and is not counted as executed
  coverage. The private driver's total-count guard was corrected to
  distinguish that skip from the successful iOS case.
- A final native field check again logged CoreDevice staging and matched
  the exact synthetic payload before clearing the field.

### Restoration

- Both original targets are booted. The older test device is back in its
  initial shutdown state. Device Hub is open and Simulator.app is closed,
  as at the start.
- Foreground package, screen bounds and orientation match the saved
  metadata on both original targets. The iPhone Playground is back on
  Gesture Presets. Metadata was polled after cold launch; a fixed startup
  sleep was not enough to establish the final foreground state.
- The saved clipboard from the start of the user-confirmed single-writer
  window was restored with **exact item data equality**. Restoration first
  checked both `NSPasteboard.changeCount` and the full experiment-owned
  item snapshot. No older guest backup was restored over host content.
- Prior in-memory navigation/gesture history and a measured hinge angle
  are not claimed to be restored. The signed-in app was not used for input
  tests or edited; only its foreground/display metadata was checked.
- The installed binary remains 0.16.0. The original Homebrew 0.15.0 restore
  backup remains intact. Existing idb checkout changes were preserved.

## Deviations and corrections

- Clipboard staging alone did not repair delivery. AX geometry appeared
  before the native menu accepted touches. Controlled delays established
  that a two-snapshot check and a composite hold were insufficient. See the
  plan for the failed attempts and the final readiness policy.
- A single-line smart-paste probe confirmed the requested middle caret,
  while UIKit added word spaces around a bullet. Caret/selection E2E uses
  LF in a multiline control so normal native formatting is not mistaken
  for a moved caret or lost bytes.
- The initial classic-host wrapper used a nonexistent Xcode 27 app path.
  After correction, the full suite passed; a wrapper-tail parse error
  required a separate post-run transport/ownership check. Both post-run
  gates passed. This was not a sim-use command failure.
- Duo bootstatus reported a terminal data-migration warning. No reset,
  erase or user-data repair was attempted. Native Playground launch and
  actual field operations, not boot status alone, are the validation oracle.

## Open questions and boundaries

- No live Device Hub UI synchronization-toggle experiment is claimed. No
  persistent keyboard or clipboard-sync preference is changed as a fallback.
- Native editing policy, custom controls and paste permission prompts can
  still constrain an app. Default paste needs a focused editable control;
  replacement needs native Select All for nonempty content.
- Other applications, devices and pending paste prompts remain outside the
  cooperative lock. Shared clipboard use still needs a single-writer window.
- No full stock `make e2e-matrix`, Android live suite or paid agent eval is
  claimed. The host coverage above is a controlled paste-specific matrix.
- No release, tag, Homebrew update or installed-binary replacement is part
  of this change. Private captures and clipboard snapshots stay under the
  ignored `.build/` directory and are not included in the pull request.
