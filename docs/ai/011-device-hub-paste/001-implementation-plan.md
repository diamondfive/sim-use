# 011.001 — Restore paste across simulator hosts

| | |
| --- | --- |
| **Status** | Implemented and locally verified; review pending |
| **Date** | 2026-10-20 |
| **Related** | #153; [investigation](000-investigation.md) |

## Authorization and goal

The user approved implementation, broad Simulator.app / Device Hub E2E,
then a signed-off commit, push and pull request. Restore the paste verb;
do not retain an obsolete iOS recommendation to abandon paste for type.
Keep Android restrictions and physical-device capability limits accurate.

## Design

- Add a verified pasteboard writer shared by standalone and batch paste.
  Try the existing simctl path and verify its exact readback. If that path
  fails or returns stale data, try CoreDevice and verify it. This behavioral
  probe supports old tools without parsing version or unsupported-error text.
  A timeout is final, not a reason for an unbounded retry. Never expose
  unexpected clipboard data in errors. Use arguments and stdin, not a shell.
- Bound subprocess duration and captured output. Drain input/output together
  so payloads larger than a pipe buffer cannot deadlock. Inject process
  execution for backend tests and exercise the real drain with local tools.
- Restore delivery semantics as well as staging. Preserve caret/selection
  behavior: a naive automatic long-press at a field's center can move the
  caret or select a word. Do not introduce that as a silent default fallback.
- Use the standard HID Application key (101) to open the focused field's
  context menu without touching the field. Tap the native Paste item. This
  keeps the caret and selection, unlike an automatic center long-press.
  Retain explicit `--via-menu` targeting for controls that need it. No new
  AX delegate, private selection API or framework change is needed.
- Fix menu replacement and remove its known-issue exemption. Empty-field
  replacement must also work. Reuse one delivery implementation in batches
  where possible; retain rejection of batch stdin, which belongs to the batch.
- Update current help, README, bundled skill, compatibility tests and
  changelog. Bump the skill floor if it starts relying on the restored default
  behavior. Keep the public success JSON shape unchanged.

## Decisions and evidence

| Decision / experiment | Outcome |
| --- | --- |
| Enable runtime hardware keyboard through SimDevice, then stage via CoreDevice and send Cmd+V | Keyboard became hidden, but the field stayed empty. Runtime connection alone is not a repair on the tested Hub setup. Returned the runtime setting to off. |
| Application key 101 | Opened the native editing menu in a fresh empty field and at a middle caret on Hub. Menu Paste inserted at the middle caret. UIKit added its normal smart-paste spaces; the caret did not move to the center of the field. |
| Replacement | Select All through the menu; if it closes, reopen with Application, not another long-press that would reset selection. Wait for the old menu to leave before using new item coordinates. |
| Native menu touch duration | On the Xcode 27.1 selection, a zero-duration tap dismissed the visible Paste menu without inserting. A 50 ms tap on the same menu inserted the staged text. Use a 50 ms hold for menu actions only, with separately flushed down/up events, matching `tap --duration`. A delay inside a composite is insufficient because DTUHID still delivers the transitions together. Keep general tap behavior unchanged. The earlier failed field tests do not establish clipboard ownership as their sole cause. |
| Partial selection before replacement | Collapse a prior selection with Right before opening the replacement menu so Select All is available, not only Cut/Copy for a selected word. If a native modal menu is already open, dismiss it first, let it close, and rebuild the app-control baseline. This is only for `--replace`; normal paste keeps its range. |
| Delivery completion barrier | Hold the cooperative clipboard lease until the clicked menu closes and remains absent for 300 ms. This gives the native action a completion barrier before a following sim-use writer or Application key. If dismissal does not complete, report that Paste was already sent and require verification before retrying; do not send Paste again. |
| Repeated invocation | A key can arrive while the previous menu is dismissing. If the initial wait times out with no Paste item, invoke Application once more. Never send a second Paste action, or retry against a visible but unsettled menu. |
| Native smart spacing | A verified middle-caret test inserted `A • B`, not `A•B`; a read-only AX probe confirmed Left moved the caret to the requested position. Use LF in the multiline control for caret/selection E2E to avoid asserting against UIKit's normal word-spacing or single-line whitespace rules. |
| Baseline app-control identity | Exclude pre-existing app controls by nonempty AX identifier even if layout moves them while a menu opens. Use label/frame equality only for unidentified controls. A regression test first reproduced the moved-decoy false match. |
| Actual classic host | Xcode 27.0/27.1 installations have no Simulator.app bundle. Use the installed Xcode 26.6 Simulator.app for the classic-host checks, with explicit runtime/tool selections. Record the UI host separately; do not claim a nonexistent Xcode 27 Simulator.app leg. |
| Menu readiness | A controlled native-coordinate test with the same 50 ms touch failed after 0, 0.25 and 0.5 s from Application, and succeeded after 0.8 s. AX items were already visible. The 50 ms hold alone did not fix production delivery. Require unchanged menu actions/geometry for 1 s, within the menu timeout, before selecting an item. |
| Batch parity | Run the same paste implementation as one host action, after pending HID is flushed. Menu paste is no longer rejected merely because it needs runtime AX polling. |
| Preserve input configuration | Do not change persistent keyboard or clipboard-sync preferences as an implicit fallback. |
| Skill floor | Keep 0.16.0: the release is still unreleased, and that floor already covers the other pending simulator behavior. The refreshed paste guidance ships in the same version, not a newer one. |
| Serialize scope | Shared clipboard operations require a host-wide cooperative lock through staging and delivery; other applications remain external writers. Verify again before delivery and fail without leaking data on mismatch. |
| Test evidence | Do not skip failed default cases as passing, or allow append as a substitute for `--replace`. Record each actual host/transport and field value. |
| Legacy readback is not sufficient ownership evidence | A failed field insertion was followed by exact simctl readback while `com.apple.coredevice.pasteboard.active` was 1. A CoreDevice write plus native menu tap inserted successfully. Validate this guest notification before trusting a legacy read: only state 0 permits that backend. Active or unverified ownership selects CoreDevice. Query only; never force notification state. |

## Verification plan

1. Red/green backend tests: supported/unsupported commands and targets,
   copy/readback errors, stale values, exact Unicode and line endings,
   subprocess timeout, oversized output and large bidirectional I/O.
2. Delivery/parser tests for focus selection, menu matching and batch parity.
   Extend the Playground paste screen with a multiline mode so actual LF,
   stdin/file payloads and large-text insertion can be checked without
   treating a single-line field's native newline normalization as data loss.
3. Build and all unit tests.
4. Focused live Playground tests on both existing devices with Hub open:
   positional/stdin/file, Unicode, insertion, strict replacement, explicit
   targets, default delivery and batch behavior. Test no-focus/error paths.
5. Controlled Simulator.app / Hub-closed and Hub-open legs, including older
   runtime/tool selections where installed. Record transport and clipboard
   ownership so a wrong environment cannot pass the matrix.
6. Broader affected E2E suites, self-review, signed-off commit, push dry-run,
   push and non-draft PR. Do not publish a release or replace the PATH binary.

## Verification outcome

See [002-action.md](002-action.md) for the observed build, unit, live host,
keyboard-mode, inner-display, concurrency and restoration results. No test
failure was accepted through a skip or an append exemption.

## Environment safety

Capture initial foreground apps and display/orientation metadata. Tests use
only Playground and synthetic text. Switching host environments can shut down
booted simulators; restore original boot/app/display state afterward. Restore
clipboard data only while it is still owned by the experiment; preserve new
external clipboard content instead of overwriting it with an old snapshot.
