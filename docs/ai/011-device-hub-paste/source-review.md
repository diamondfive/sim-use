# Device Hub paste — source review

Reviewed on 2026-10-20. Source inspection is not a live test of each tool.
The local Apple-framework and Playground experiments are recorded in
[000-investigation.md](000-investigation.md).

## Upstream implementations

| Project / source | Relevant behavior | Applicability |
| --- | --- | --- |
| [idb HID text conversion](https://github.com/facebook/idb/blob/5394fad473835a0babe8db2a3bb7772d578eee23/idb/common/hid.py) | `text_to_events` expands characters through `KEY_MAP` and rejects unmapped characters. | Not general Unicode input. The local checkout also has `PrivateHeaders/SimPasteboardPlus/SimPasteboardInterface.h`; a header is not an implemented clipboard command. |
| [AXe Type](https://github.com/cameroncooke/AXe/blob/30f4bfa9bc81817906a60fadedbc913d7314b7e1/Sources/AXe/Commands/Type.swift), [command registration](https://github.com/cameroncooke/AXe/blob/30f4bfa9bc81817906a60fadedbc913d7314b7e1/Sources/AXe/main.swift) | HID typing, with an explicit US-keyboard limitation. No Paste command is registered. | No reusable Unicode clipboard solution in this path. |
| [Appium coresim native pasteboard bridge](https://github.com/appium/appium-ios/blob/765353af76ac525797f6573f35d089bffd92cac6/packages/coresim/src/native/sim_pasteboard.mm) | Loads the private `SimPasteboardInterface`; uses an isolated NSPasteboard and delegate/semaphore synchronization. | A more careful native implementation of the legacy stack, not CoreDevice ownership negotiation. The local native probe exercised the same interface family. |
| [OpenDeviceHub PasteboardBridge](https://github.com/Mastersam07/OpenDeviceHub/blob/e50f07f1f4480cb14d57f192df7bf598ca26e708/engine/Sources/OpenDeviceHubEngine/Adapter/PasteboardBridge.swift) | Holds one `SimPasteboardInterface` connection per shown device; documents automatic host-to-guest syncing and explicit guest-to-host pulls. | Useful lifecycle comparison. Its Xcode 27 observations do not establish behavior with Apple's Device Hub pasteboard stack active. |
| [WebDriverAgent FBPasteboard](https://github.com/appium/WebDriverAgent/blob/3d6a4e03cdd673e540289c610f7e189f8ffea434/WebDriverAgentLib/Utilities/FBPasteboard.m) | Writes the guest `UIPasteboard.generalPasteboard` from inside the iOS runner. | Avoids the host legacy snapshot interface, but requires a runner. Not tested locally here. |
| [Maestro XCUIElement extensions](https://github.com/mobile-dev-inc/Maestro/blob/028c18b9ce7441c117f161da4dfe8007e46fa61d/maestro-ios-xctest-runner/maestro-driver-iosUITests/Routes/Extensions/XCUIElement+Extensions.swift) | Sets `UIPasteboard.general.string` inside the runner and uses the guest Paste menu. | Supports separating clipboard staging from UI delivery. Not a drop-in host CLI implementation. |
| [Maestro TextInputHelper](https://github.com/mobile-dev-inc/Maestro/blob/028c18b9ce7441c117f161da4dfe8007e46fa61d/maestro-ios-xctest-runner/maestro-driver-iosUITests/Routes/Helpers/TextInputHelper.swift) | XCTest text-event synthesis. | A different input channel, not a repair for `simctl pbcopy`; adds a runner dependency. |

## Corroborating reports

- [sim-use #153](https://github.com/lycorp-jp/sim-use/issues/153): the project
  failure being investigated; command success did not establish clipboard
  delivery.
- [serve-sim #174](https://github.com/EvanBacon/serve-sim/issues/174): reports
  silent `simctl pbcopy` failure on an iOS 27 simulator. A CoreDevice
  copy/readback prototype plus guest Paste delivered exact Unicode bytes.
  Automatic Cmd+V was not established. This is corroboration, not proof of
  general SDK/runtime support.
- [openchamber #7](https://github.com/bemany/openchamber-ios-simulator/issues/7):
  reports iOS 27 legacy clipboard-bridge problems and discusses readback,
  typing fallback and a guest helper. The local finding does not rely on
  those suggested remedies.

## Installed Apple components

No private Apple binaries or clipboard captures are copied into this record.

| Component | Evidence inspected |
| --- | --- |
| Simulator.app / SimulatorKit | `DeviceCoordinator`, `SimPasteboardInterface`, `PasteboardAutomaticSync` preference references. |
| DeviceHub.app / DeviceKit | CoreDevice `PasteboardProtocol`; `DevicesDefaults.pasteboardSyncEnabledByDevice`; the separate `com.apple.dt.Devices` preference domain. |
| SimPasteboardPlus | `coredevice-coordination` logger, `com.apple.coredevice.pasteboard.active` monitor and the explicit ignore-snapshot diagnostic. |
| CoreSimulatorBridge in the running guest | The ignore-snapshot diagnostic was captured during a real failing legacy write. This is the strongest local evidence for ownership gating. |
| `xcrun devicectl device pasteboard` | Installed help exposes copy, paste, inspection, monitoring and synchronization operations. Copy/paste were tested directly. |

A private Swift ABI integration is not needed for the verified CoreDevice
path. The installed, signed `devicectl` already provides the transport.
The production implementation adds capability/ownership checks, exact
readback, bounded I/O and failure handling; see the
[implementation action log](002-action.md).
