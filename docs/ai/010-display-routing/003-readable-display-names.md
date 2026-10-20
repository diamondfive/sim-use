# 010.003 — Readable iPhone Duo display names

## Status

Planned before implementation on 2026-10-20. Implemented in #170;
verification is complete. Review rounds are tracked in the PR.
This amendment follows the display-routing plan.
Number 002 is reserved by the separate side-bar overflow fix in #169.

## Context

CoreDevice reports the iPhone Duo displays as `LCD` and `LCD-1`. These
names identify screens but do not explain their roles. The default `ui`,
`ios fold` and `ios rotate` text currently uses those names. A user or an
agent must know that the primary panel is the cover and the other panel
is the inner screen.

The system supplies display type, primary status, active status and
rotation. It does not supply `inner` or `cover` labels. The existing
`hingeAngle` result is the requested angle, not a measured angle. This
change must not infer a fully open or closed hinge from an active screen.

## Approved output

```text
Posture: inner display active; portrait-upside-down
Posture: cover display active; portrait
App: LINE Dev  669x951  (portrait-upside-down, inner display)
App: LINE Dev  466x678  (cover display)
```

The fold action prefix stays as before. Rotate feedback uses the same
screen names. Normal single-screen headers and Resize Mode naming stay
unchanged. Raw JSON names, ids, field presence and schema stay unchanged;
the human-readable `outline` string in JSON follows the new text header.

## Design

- Add one presentation-only naming helper under `Sources/iOSSimBackend/Sim/`.
- Read the stable CoreSimulator device type identifier, not the editable
  simulator name. Only `com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`
  is eligible for inner/cover aliases.
- Require exactly two integrated displays with exactly one primary, and
  distinct display ids and unique ids. Primary means cover only in this
  verified Duo layout; the other integrated display is inner.
- Match displays by identity and primary status, never by `LCD` names or
  fixed numeric ids. Unknown models, unavailable or ambiguous topology,
  and virtual displays keep their existing names.
- Use existing simulator lookup and cached topology. Do not add a motion
  probe or a new device discovery subprocess for naming.
- Keep presentation strings outside public JSON business fields. Fold
  and rotate carry an optional `_displayLabel` in `PostureReport.Display`
  only on the internal daemon response. The daemon encoder sets a typed
  user-info key; the public JSON encoder does not. Decoding accepts the
  optional field, so text aliases survive the daemon round trip and are
  stripped when the client re-encodes `--json` output. Old daemon data
  remains readable and falls back to the existing generic text.
- Add the cover tag only when the observed active integrated screen is
  the cover. Do not turn a missing active signal into a cover claim.

## Decisions

| Decision | Alternative | Reason |
| --- | --- | --- |
| Duo device type plus validated topology | Parse `LCD-1`; hard-code id 3; label all non-primary displays inner | Names and ids are addressing data, not roles. Other models and virtual displays need a safe fallback. |
| Display aliases only | Read hinge motion | Owner selected the naming-only change; no new sensor or transport work. |
| Keep JSON schema and raw addressing fields | Add a role field or add `display` on the main screen | This is a text improvement, not a structured-data contract change. |
| Separate presentation from routing | Change routing enum cases or primary-display behavior | Names must not change input, calibration or capture behavior. |
| Optional daemon-only display label | Exclude the label from all encoding | `format` runs in the client after decoding. A memory-only label would silently disappear in normal daemon mode. The additive field is backward compatible and never reaches public JSON. |
| Compare point hits with the current device's tree | Keep fixed iPhone 17 coordinates and button metadata | The Duo exposes the same `BackButton` id as an unnamed side-bar `GenericElement`. The old binary reproduces the same eight failures. Dynamic comparison keeps identity and geometry checks without assuming one device layout. |

## Verification plan

- Add failing unit tests for renamed/re-numbered displays, both panels,
  unknown models, malformed topology, missing active signal, Resize Mode,
  single-screen output and JSON encoding.
- Run `make build` and `make test`.
- Update README, bundled skill guidance and the Unreleased changelog.
- Open a PR and run the requested Prowl review loop. Main owns all edits;
  the reviewer must not drive simulators while E2E work is active.
- On the two already booted simulators: check single-screen output and
  Duo cover/inner headers, posture query, rotation feedback and raw JSON.
  Use the Playground fixture for basic tap/type/scroll checks, not the
  user's signed-in app. Do not reboot devices or run the environment
  matrix. Restore the Duo's starting active screen and foreground app.

## Outcome

- `SimulatorDisplayNames` is the shared role-to-label policy. The live
  CoreSimulator device type was verified as
  `com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`.
- `AccessibilityFetcher` passes the presentation tag to the outline;
  `RoutingDisplay` and its encoded `info` stay unchanged.
- `PostureReport.Display` carries the optional daemon-only label. Fold
  queries resolve the simulator type without opening a HID session;
  fold/rotate actions reuse the simulator from their existing session.
- Added nine unit tests in `Tests/DisplayNamesTests.swift`, including the
  production daemon response encoder and public-JSON byte equality.
  `FoldTests` checks cover and inner headers, text feedback, half-open
  reporting and public field absence on the live Duo.
- TDD: the new suite first failed to compile against the missing naming
  helper and report input, then passed after implementation.
- `make build`: passed. Initial `make test`: 1715 passed, 0 failed.
  Final `make test`, after the live cover case and point-test correction:
  1716 passed, 0 failed.
- Live read-only check: Duo text named the inner display while structured
  data retained `name: LCD-1`, `id: 3`. The iPhone 17 header stayed
  unchanged.
- Review round 1 at `b5865a6`: no material findings. The reviewer also
  identified the failed generic point-query test in the E2E evidence.
- Initial E2E selection: iPhone 17 passed all five filters; Duo passed 11
  of 12. Only `DescribeUITests/describeUIAtPoint` failed. Its eight
  assertions expected a labeled `Button` at `{{16, 62}, {44, 44}}`; the
  Duo returned the correct `BackButton` id as an unnamed `GenericElement`
  at `{{884, 129}, {38, 38}}`. Running the unchanged test with the
  installed, pre-naming 0.16.0 dev binary (including #169) reproduced all
  eight failures.
  The test now compares label, type, role and frame with the just-fetched
  element, while retaining the explicit id, role-description and leaf
  checks. Product routing code did not change to address this failure.
- Final basic E2E rerun: iPhone 17 passed all five selected filters; Duo
  passed all twelve. Both include describe-ui, point queries, tap, type,
  scroll and screenshot. Duo also covers fold round trip, half-open
  reporting, cover/inner read paths and text names, inner tap/type/swipe,
  and all four inner-screen rotations. This was a basic selection, not
  the full E2E suite or host-environment matrix.
- Restored each simulator's original foreground app, interface orientation
  and active display. Verified all three against the saved starting UI
  metadata. Exact hinge angle was not measured or claimed.
- The skill compatibility floor stays at 0.16.0: these are presentation
  aliases in the same unreleased version; guidance also accepts legacy
  display names and does not depend on a new command or field.

### Reproduce the basic selection

Set `SIMULATOR_UDID` to the booted target and resolve `SIM_USE_TEST_BINARY`
before starting Swift tests. The Playground must already be installed.

```bash
export SIM_USE_TEST_BINARY="$(swift build --show-bin-path)/sim-use"
scripts/test-runner.sh --tests-only \
  DescribeUITests TapTests/basicTap TypeTests/basicTextTyping \
  GestureTests/scrollUpGesture ScreenshotTests/screenshotToFile
```

For the Duo, the same invocation also included these filters:
`FoldTests/foldRoundTrip`, `FoldTests/halfOpen`,
`FoldTests/coverDisplayReadPaths`, `FoldTests/innerDisplayReadPaths`,
`FoldTests/innerDisplayInput`, `FoldTests/innerDisplaySwipe`, and
`FoldTests/rotateInnerDisplay`.
