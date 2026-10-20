# 011 — Device Hub paste: Investigation

| | |
| --- | --- |
| **Status** | Investigation complete; implementation locally verified — see [action log](002-action.md) |
| **Anchor date** | 2026-10-20 |
| **Related** | #153; [010 display routing](../010-display-routing/000-plan.md); [001 HID lifecycle](../001-daemon-and-hid-lifecycle/001-dtuhidd-short-lived-clients.md) |

> Updated 2026-10-20: Implementation was authorized after this investigation.
> The constraints, baseline code and cleanup below describe the completed
> investigation, not the later implementation. See the
> [implementation plan](001-implementation-plan.md) for the decisions and the
> [action log](002-action.md) for the implementation and verified results.

## Goal

Find a reliable paste path with Device Hub open. Compare Simulator.app and
Device Hub, inspect upstream idb, AXe and related tools, and test both a
stable solution and practical workarounds. Do not treat successful command
exit as proof of delivered text.

## Constraints

- Use the Playground and synthetic text, not signed-in applications.
- Preserve the host pasteboard without printing its contents. Restore
  experimental clipboard data only if no external writer has replaced it.
  Restore changed settings after experiments.
- Record initial device/app/display state. Avoid simulator reboots and
  quitting Device Hub where they would shut down unrelated devices.
- Do not commit, push, publish or replace the installed binary as part of
  this investigation. Implementation experiments must remain reversible.

## Existing evidence

Issue #153 reports that `simctl pbcopy` succeeds with Device Hub open, but
`simctl pbpaste` returns the host pasteboard instead. Both Cmd+V and edit-menu
paste fail. Earlier work did not isolate the synchronization mechanism.
`IOSSimPasteCommand` writes through `simctl pbcopy`, then sends keyboard HID
or opens the iOS edit menu. It does not read the pasteboard back.

## Hypotheses

1. Device Hub uses a host-backed pasteboard proxy rather than Simulator.app's
   guest pasteboard sync. A host write or a bridge-specific API may be needed.
2. Device Hub and Simulator.app have different synchronization settings;
   disabling the appropriate per-device setting may restore guest writes.
3. Pasteboard delivery and keyboard delivery are independent failures.
   Even with correct clipboard data, Cmd+V may be dropped in soft-keyboard
   mode; the edit-menu path must be verified separately.

## Verification plan

- Capture host and guest pasteboard observations using synthetic markers.
- Compare API/code paths in idb, AXe, other tools and Apple's installed
  frameworks. Record source URLs and exact symbols.
- Test synchronization settings, host writes, guest writes and available
  pasteboard APIs without exposing existing clipboard data.
- Check actual field content, Unicode, repeated operations and recovery.
- Document limitations, side effects and concurrency risks of workarounds.

## Evidence

### Environment and scope

Device Hub from Xcode 27.1 was running. Both existing booted simulators were
used: iPhone 17 and Duo. Both actual-input checks used only the Playground
`paste-test` screen. No simulator was rebooted, folded or rotated.

The selected Xcode 26.6, 27.0 and 27.1 installations all resolved to the same
installed CoreDevice 651.13.5 and CoreSimulator 1174.9.2. This does **not**
establish that each original Xcode release shipped the pasteboard commands.
Use capability detection, not an inferred Xcode-version requirement.

### Simulator.app and Device Hub use different stacks

- Simulator.app has `DeviceCoordinator` / `SimPasteboardPlus` integration and
  the `PasteboardAutomaticSync` preference in `com.apple.iphonesimulator`.
  That preference was already false on this host.
- Device Hub uses CoreDevice's `PasteboardProtocol`, with a separate
  `DevicePreferences/<UDID>/pasteboardSyncEnabled` preference in
  `com.apple.dt.Devices`. DeviceKit exports
  `DevicesDefaults.pasteboardSyncEnabledByDevice`.
- SimPasteboardPlus has a `coredevice-coordination` logger and a monitor for
  `com.apple.coredevice.pasteboard.active`.
- The guest notification state was `1`. During a failing `simctl pbcopy`,
  **the guest CoreSimulatorBridge itself** logged:

  ```text
  Ignoring snapshot for com.apple.UIKit.pboard.general: the CoreDevice pasteboard stack is in use
  ```

This is direct evidence of deliberate rejection by the legacy stack. It is
not just an inference from reading the host's value after a failed write.

### Experiment results

| Probe | Observed result |
| --- | --- |
| `simctl pbcopy`, then `pbpaste`, on both devices | Copy exited 0; readback was the host value, not the requested marker. Delays through 3 seconds did not repair it. |
| Pause Device Hub briefly, run the legacy write, resume in `finally` | Legacy write still failed. Continuous overwriting by the Hub UI process is not a sufficient explanation. |
| Native `SimPasteboardInterface` with a private NSPasteboard | Waiting for activation, holding the connection open, reseeding after activation and advancing generation counts did not change the guest clipboard. |
| CoreDevice copy and exact readback, five payloads on each device | **10/10 passed**: ASCII, Japanese/Cyrillic, combining characters, ZWJ emoji, shell metacharacters, line endings, tabs and a 94,227-byte payload. |
| CoreDevice copy followed by the existing `--via-menu --target-id paste-input-field` path | **5/5 actual field insertions on each device**. The Playground's bound content echo matched the full string, not just a command exit status. |
| CoreDevice copy followed by Cmd+V in the tested software-keyboard setup | Field stayed empty. Correct clipboard data alone does not repair keyboard delivery. |
| Host `pbcopy`, then existing menu paste | One actual Unicode field insertion passed through Hub's host-to-guest synchronization. This changes the host clipboard and depends on sharing. |
| Write marker A to iPhone 17, then marker B to Duo | After the second write, **both devices read B**. Per-device addressing does not provide clipboard isolation while sharing is enabled. |

The CoreDevice CLI commands are:

```bash
printf '%s' "$TEXT" |
  xcrun devicectl device pasteboard copy --device "$UDID" --timeout 8 --quiet

xcrun devicectl device pasteboard paste --device "$UDID" --timeout 8 --quiet
```

`copy` reads UTF-8 bytes from stdin. `paste --quiet` returned the exact bytes,
including a final newline. The smallest accepted CLI timeout is 5 seconds.
The large-payload result is a clipboard round trip, **not** a large field
insertion test.

The menu experiments pre-seeded through CoreDevice, then ran the **unchanged
installed** sim-use command. Its intervening `simctl pbcopy` remained a no-op
on this stack. This verifies the combined workaround, not a repaired sim-use
implementation. An iPhone screenshot also confirmed visible field content;
a black Duo screenshot was not used as visual evidence.

### What the synchronization-setting experiment establishes

The initial nested `defaults -dict-add` value `0` was an NSString, not a
Boolean. It was not accepted as a valid test of disabling synchronization.
The preference was then written and verified as an actual Boolean false.
The running Hub still had an active CoreDevice pasteboard stack, propagated
host changes and rejected legacy writes.

**It is not established that Hub applied this external preference change
live.** No actual UI-toggle or restart experiment was performed. Do not
conclude that the real UI switch is ineffective, or recommend editing
preferences as a verified repair. Quitting Hub could shut down other devices,
and host Accessibility permission was not available for a UI-toggle test.

### Upstream comparison

See [source-review.md](source-review.md) for pinned source links.

- **idb / AXe:** HID key maps are not a general Unicode paste solution. AXe's
  registered commands have no paste command. Finding private pasteboard
  headers in idb does not establish a working clipboard implementation.
- **Appium coresim / OpenDeviceHub:** native `SimPasteboardInterface` clients,
  including persistent/delegate-driven clients. They use the same legacy
  stack that the local native probe could not make work while CoreDevice was
  active. These tools themselves were not run.
- **WebDriverAgent / Maestro:** code inside an iOS runner can write
  `UIPasteboard.general`; Maestro then uses a guest Paste action. Maestro also
  has XCTest text-event synthesis. These avoid the host legacy bridge, but
  need a runner and were not tested locally in this investigation.
- **serve-sim #174:** independent report of silent `simctl pbcopy` failure and
  a working CoreDevice copy/readback plus guest Paste prototype. It also does
  not establish automatic Cmd+V delivery.
- **openchamber #7:** corroborating legacy-bridge reliability problems on
  iOS 27, with readback and fallback discussion. Not proof of a portable fix.

## Root cause and decision

### Root cause

On the tested setup, **CoreDevice owns clipboard handling and
CoreSimulatorBridge rejects legacy pasteboard snapshots**. sim-use currently
uses the rejected `simctl pbcopy` path and does not verify it. Consequently it
can paste stale host text while reporting success.

There is a second, independent boundary: Cmd+V did not insert text in the
current software-keyboard setup, even after correct clipboard staging.
A clipboard fix must not be described as a universal keyboard-delivery fix.
The separate DTUHID client-lifetime fix in entry 001 remains valid.

### Recommended implementation (2026-10-20; not implemented here)

1. Add a verified iOS pasteboard writer. Use CoreDevice copy/readback when the
   installed tool and target support it; retain a verified legacy path for
   older environments. Base selection on capability and classified failures,
   not the Hub process name or guessed Xcode-version boundaries.
2. Send input via a subprocess argument array and stdin, not interpolated
   shell text. Drain readback concurrently with process execution, bound its
   size and duration, and handle at least the tested 94 KB without a pipe
   deadlock. Reuse existing subprocess patterns where they fit; the current
   JSON-oriented `DevicectlQuery` is not a raw text pasteboard reader.
3. Compare exact UTF-8 bytes before any paste action. Reject stale/mismatched
   readback. Never include the actual unexpected clipboard contents in an
   error, since they can be private host text. Do not retry a business failure
   blindly through an inactive stack.
4. Keep existing public options and menu targeting. The verified no-runner
   delivery path is `--via-menu` with a target. Treat default Cmd+V separately;
   neither a successful key-event send nor clipboard readback proves field
   insertion. Do not silently substitute US-keyboard typing for Unicode paste.
5. Document host clipboard effects and the single-writer requirement while
   Hub sharing is enabled. Do not toggle global/per-device sync settings,
   force the coordination notification state, kill clipboard services or
   overwrite the host clipboard as an implicit fallback. Per-UDID daemons do
   not serialize shared clipboard activity across devices or other apps.

Before shipping, add injected subprocess/backend tests for unsupported
capabilities, copy/readback failures, stale data, exact Unicode/newline bytes,
large I/O and timeouts. Run build/unit tests, then affected Playground paste
suites with Hub open and a separately controlled Hub-closed environment. A
real UI sync-off experiment and connected-hardware-keyboard test remain
useful follow-ups. `--replace`/Select All was not validated in this work.

### Temporary workaround for the current installed binary

On the **tested active CoreDevice stack**, stage through CoreDevice first,
then use the existing targeted menu mode:

The example below checks copy/readback status and exact bytes before calling
sim-use. It does not print unexpected clipboard data:

```bash
printf '%s' "$TEXT" | python3 -c '
import subprocess as s, sys
device, target = sys.argv[1:]
text = sys.stdin.buffer.read()
if not text:
    sys.exit("Input is empty.")
base = ["xcrun", "devicectl", "device", "pasteboard"]
options = ["--device", device, "--timeout", "8", "--quiet"]
s.run(base + ["copy"] + options, input=text, capture_output=True, check=True)
actual = s.run(base + ["paste"] + options, capture_output=True, check=True).stdout
if actual != text:
    sys.exit("Clipboard readback mismatch; paste cancelled.")
s.run(["sim-use", "paste", "--stdin", "--device", device,
       "--via-menu", "--target-id", target], input=text, check=True)
' "$UDID" "$FIELD_ID"
```

The underlying CoreDevice staging/readback plus menu composition passed 10
repeated field checks in Playground. The documented wrapper was separately
checked with subprocess mocks, not rerun live after external clipboard
activity was detected. It is not a
portable backend implementation: the old command still makes its legacy
write attempt. Shared clipboard activity from another device or app can
change the value between staging and Paste. CoreDevice copy also changed the
Mac clipboard in this setup. Do not run parallel paste operations with
sharing enabled or assume the Mac clipboard is preserved.

### Cleanup and repository state

- The complete Device Hub preference domain matches the original snapshot.
- Device Hub was resumed and remains running. No simulator reboots, rotation
  changes or folding commands were used.
- Both initial foreground apps, interface orientations and display geometry
  were restored and compared with saved metadata. The iPhone Playground was
  relaunched to its initial Gesture Presets screen; its prior in-memory
  gesture history was not restored. The signed-in app was not edited.
- The host clipboard changed externally during research. Its new content
  differed from the original snapshot. **No old clipboard backup was restored
  over that new content**, and no further host or guest clipboard writes were
  issued. This also prevents a guest restore from overwriting the new host
  content through sharing.
- Original clipboard backups and private AX captures remain only under the
  ignored `.build/paste-investigation/` directory. They must not be committed
  or quoted. Research marker contents were cleared from Playground fields.
- No production source, installed binary or framework checkout was changed.
  Existing idb checkout modifications were preserved. No commits, pushes,
  releases or full E2E runs were made as part of this investigation.

## Amendments

- Updated 2026-10-20: Implement verified staging and caret-preserving native-menu delivery — see [001-implementation-plan.md](001-implementation-plan.md).
- Updated 2026-10-20: Complete implementation, live host validation and state restoration — see [002-action.md](002-action.md).
- Updated 2026-10-20: Address review findings on replay, replacement, existing menus and localization — see [003-review-hardening.md](003-review-hardening.md).
- Updated 2026-10-20: Require positive native menu evidence before dismissal — see [004-menu-presence-proof.md](004-menu-presence-proof.md).
- Updated 2026-10-20: Prevent whole-batch replay after a later transient failure — see [005-batch-retry-policy.md](005-batch-retry-policy.md).
- Updated 2026-10-20: Require modal menu provenance after ordinary Copy/Paste toolbars reopened R172-05 — see [006-modal-menu-provenance.md](006-modal-menu-provenance.md).
