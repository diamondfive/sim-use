# 007 — Physical iOS device backend: Design

| | |
| --- | --- |
| **Status** | Implemented (experimental surface), shipped in 0.14.0 |
| **Anchor date** | 2026-08-10 |
| **Primary PRs** | #93 (by @subdiox), #99 (carries #93 with its authorship), #114, #117, #118, #122, #123, #126 |
| **Related** | issues #98, #115, #120, #121, #124 |

> Backfilled on 2026-10-14 from the PR descriptions, the issues, the code,
> `CHANGELOG.md` (0.14.0) and the maintainer's notes. It is a retrospective
> reconstruction, not a plan written before the work.

## Background

sim-use drove simulators and Android devices, but not a physical iPhone or
iPad. The other tools for real iOS devices (Appium, Maestro and similar) use an
XCUITest runner. That needs a runner app, code signing with the user's team,
and a mounted Developer Disk Image. For sim-use, that setup would remove the
"install it and go" property on the platform where setup friction is worst.

## Goals

- Read the foreground app's accessibility hierarchy and activate elements on a
  USB-attached, unlocked iPhone or iPad, with nothing installed on the device.
- Make the physical device a first-class target: listed by `sim-use devices`,
  reachable through the top-level verbs, with the same `--json` envelope.
- Say clearly what the channel cannot do, instead of a faked parity.

### Non-goals

- Coordinate input: coordinate `tap`, `swipe`, `gesture`, `multi-touch`. The
  channel serves no element geometry.
- Distribution, Ad Hoc, TestFlight, App Store and system apps. Only
  development-signed apps (`get-task-allow=true`) expose a usable hierarchy.
- Wi-Fi (network-paired) devices (#98).
- Daemon routing and cross-invocation `@N` aliases (#120).

## Design

**Transport** (`Sources/iOSDeviceBackend/Transport/`). The backend talks to the
accessibility audit daemon, `com.apple.accessibility.axAuditDaemon.remoteserver`,
over usbmux lockdown. `DTXFraming.swift` and `DTXConnection.swift` implement the
DTX framing. The stream is plaintext on the raw socket: when lockdown has
started the service, the daemon closes the connection on the first encrypted
frame (#93). `DTXConnection` matches a reply to its request by both the message
identifier and `conversationIndex`, so an unsolicited device event cannot
satisfy an unrelated pending request (#99). `PooledTransport` pipelines
requests; past about 1.4x, the daemon serialises, so more in-flight requests or
more connections give no more speed (#93).

**Session** (`DeviceSession.withClient`). Each call opens a session, does the
work, and always calls `AXAuditClient.finish()`. A session that skips the
teardown leaves the device answering every element query with nothing, which
looks like a locked screen (#93, #120).

**Discovery** (`DeviceSession.connectedDevices`, `DeviceSession.resolveDevice`).
`FBDeviceSet` delivers AMDevice attachment through CFRunLoop sources on the
main queue, so discovery pumps that loop. `AttachmentQuiescence` waits until
the attached set stops changing, so several USB devices are all found (#99).
`AttachmentDiscovery` adds an `emptyGrace` bail: when no device appears within
1 s, discovery returns at once instead of after the 5 s deadline (#117).

**Selector and outline** (`Sources/iOSDeviceBackend/AXAudit/`,
`Sources/iOSDeviceBackend/Domain/`). `AXAuditValue` types the wire values, and
the `DTXInvoking` protocol makes the selector layer testable without a device.
`DeviceTreeFetcher` walks the tree and deduplicates on token, summary and role
together. On a pushed screen the root token aliases the back button, so a
token-only key dropped it (#114). The outline shows `#id`. A positional `@N`
is rejected because element handles die with the connection (#114). An empty
tree throws `AXAuditError.hierarchyUnavailable` with the entitlement
diagnostic.

**Screenshot** (`Sources/iOSDeviceBackend/Devicectl/Devicectl.swift`). The
capture runs `xcrun devicectl device capture screenshot` over CoreDevice, not
the audit channel. It captures any screen, SpringBoard included, and needs no
development signing (#118).

**Listing** (`Sources/SimUseCore/Device.swift`). `sim-use devices` adds a third
discovery side for physical devices, next to simctl and adb. `Device.Kind`
(`simulator`, `emulator`, `physical`) is a field orthogonal to `platform`,
which stays `ios` or `android` (#122).

**CLI conformance.** The `ios-device` verbs (`IOSDeviceCommand.swift`) conform
to `SimUseExecutableCommand`, so they emit the shared `{ok, data}` envelope and
carry recovery advice in `hint`: `IOSDeviceCommandError` and `DeviceSessionError`
conform to `HintProviding` (#123).

**Routing and capability model** (#126). `PlatformRouter` has a
`Platform.iOSDevice` case, so every top-level verb switch must handle it.
`ui`/`describe-ui`, `tap` (the `#<id>`, `--id` and label forms) and
`screenshot` route to the typed entry points `performUI`, `performTap` and
`performScreenshot`. The other verbs reject the target with
`TargetCapabilityError.physicalIOS`, which states why the channel cannot carry
the verb and gives the nearest alternative. The device-scoped top-level verbs
call `DeviceOptions.resolve(allowPhysical: true)`; `sim-use ios <verb>` keeps the
default and fails fast with `PhysicalIOSDeviceError`.
`SimUseExecutableCommand` runs physical targets in-process
(`PlatformRouter.looksLikePhysicalIOSDevice`), so a rejection never spawns an
idle per-device daemon.

## Alternatives & decisions

| Decision | Options considered | Chosen because | PR |
| --- | --- | --- | --- |
| Use the accessibility audit daemon | XCUITest runner (the other tools) | No runner, no signing by sim-use, no Developer Disk Image: the device only has to be unlocked | #93 |
| Plaintext DTX on the raw socket | The connection's SSL send/receive | The daemon closes the connection on encrypted frames after lockdown starts the service | #93 |
| Typed `AXAuditValue` for the wire | Hand-built dictionaries | A malformed element makes the daemon do nothing and report success; a reference client mis-nests the element token | #93 |
| Correlate replies by identifier and `conversationIndex` | Identifier only | Unsolicited events could satisfy an unrelated pending request | #99 |
| Development-signed apps only, and fail loudly | Print `0 elements`; choose the first match | Other signing gives no hierarchy; a silent empty answer misleads an agent | #99 |
| Selectors `--label` / `--label-contains` / `--element-type`, and `#id` | Device-only `tap --text` | One selector vocabulary with the simulator; `#id` is stable, a label is not | #99, #114 |
| Reject `@N` on physical devices | Cache aliases across calls | Element handles die with the connection; an alias would point at nothing | #114 |
| 1 s empty-grace bail in discovery | Always wait the 5 s deadline; a usbmux probe | Measured first sighting with a device was 0.092–0.159 s; once a device is seen the bail is off | #117 |
| Screenshot through CoreDevice `devicectl` | Audit channel (has no capture) | Any screen, no signing; about 2.8 s end to end | #118 |
| Do not ship screen recording | Expose `devicectl device capture screen-record` | The test hardware reports the capability as unsupported, so it cannot be verified | #118 |
| `kind` field orthogonal to `platform` | A third platform value | The Viewer and `--platform` contracts stay unchanged; `kind` answers "what carries it" | #122 |
| List physical devices by default | An opt-in flag | Discovery runs in parallel; the cost is about 0.55 s with a device and 1.1 s without | #122 |
| `devices --json` reuses the unified `Device` schema | An ad-hoc `ios-device` shape | One schema and one parser for every listing | #123 |
| Route through top-level verbs with per-verb capability errors | Keep a separate `ios-device` surface only; fake parity | A first-class target, but the error states what the channel cannot carry, with an alternative | #126 |
| Run physical targets in-process | Route through the per-device daemon | The daemon cannot hold the DTX session yet, and teardown ownership is a hazard; deferred to #120 | #126 |
| Docs show a verb × target capability matrix | Imply parity | Agents must never assume that a simulator verb works on a physical device | #126 |

## Open questions

- #120: hold the DTX session in the daemon. That would amortise setup and keep
  element handles alive, so `ui` then `tap @N` works. The hazards: who owns the
  mandatory `finish()`, the binary android/simulator forks in the daemon's
  liveness probe and stale-target check, and unplug or replug detection.
- #98: Wi-Fi devices. Discovery must include network-paired devices, and the
  transport must speak TLS where lockdown enforces it.
- #124: an advisory when a hierarchy read returns a suspiciously small tree
  (for example SpringBoard in the foreground). The detection must not depend on
  localised role or label text.
- #121: short device aliases (`i1`, `a2`) usable as `--device`.
- A freshly attached device can list by ECID before AMDevice publishes the
  lockdown UDID. Shape-based routing cannot recognise a bare ECID; the
  `ios-device` namespace accepts it (#122, #126).
- Screen recording on hardware that reports the capability as supported was not
  tested.

## Amendments

(append `- Updated YYYY-MM-DD: ... — see [00N-topic.md](00N-topic.md)` lines here)
