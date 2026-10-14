# 002.001 — Gesture presets and the `--coordinate-space` contract

| | |
| --- | --- |
| **Dates** | 2026-07-28 (#73, #74), 2026-09-16 (#144) |
| **Refs** | issue #66, #73, #74, #144 (by @iXerol), issue #142 |
| **Shipped in** | #73 and #74 in 0.12.0, #144 in 0.15.0 |

> Backfilled on 2026-10-14 from the PR descriptions and the code.

## Context

The self-calibration in [000-design.md](000-design.md) covered AX-derived
coordinates only: selector and alias taps, `paste --via-menu` and `ui`. Issue
#66 found that the directional gesture presets and the explicit coordinates of
`swipe` / `touch` skipped it. On a rotated iPad the emitted stroke was 90° off:
a landscape `gesture scroll-up` did not scroll, and a native horizontal swipe
scrolled the page vertically. The presets also computed on a hardcoded 390×844
portrait canvas, which is wrong on an iPad even in portrait.

## Change

| PR | What |
| --- | --- |
| #73 | Directional presets (`scroll-*`, `swipe-from-*-edge`) compute in calibrated visual space. `GestureOrientationMapping` (`Sources/iOSSimBackend/A11y/GestureOrientationMapping.swift`) resolves the canvas (explicit `--screen-width/height`, then the calibrated UI size, then 390×844 as the last fallback) and maps the stroke with `hidStroke`. `AccessibilityFetcher.fetchOrientationCalibration` fetches the tree and runs up to 3 hit-test probes, without the collapsed-children recovery walk. A batch shares one calibration across its steps. |
| #74 | `swipe` and `touch` accept `--coordinate-space native\|ui` for explicit coordinates. `ui` calibrates per command (per run in a batch, through `BatchContext.uiSpaceCalibration`). |
| #144 | `tap` accepts the same flag for `-x/-y` / `--point`. Aliases and selectors reject it. |

## Decisions

| Decision | Options considered | Chosen because | PR |
| --- | --- | --- | --- |
| Presets are visual-direction semantics and always calibrate | keep them raw | `scroll-up` names what the user sees; a raw preset on a rotated device is a bug, not a contract | #73 |
| Explicit coordinates keep device-native portrait as the default | switch the default to ui space | The native default is the documented contract from #34; changing it breaks existing scripts | #74 |
| `ui` space is opt-in through a flag | detect rotation on every raw command and warn | Rotation detection costs an AX fetch per command; the native default must stay zero-cost, so it has no rotation advisory | #74 |
| `touch --coordinate-space ui` requires the atomic `--down --up` form | allow split touches | The two halves of a split touch can straddle a rotation and calibrate into different spaces | #74 |
| Android accepts the flag and ignores it | reject it on Android | Bridge coordinates are display space and rotate with the UI already; the cross-platform surface stays the same | #74, #144 |
| `tap --coordinate-space` with an alias or selector is an error | accept it as a no-op | Aliases and selectors are already resolved in ui space; a silent no-op hides a mistake. `--frame` set the same precedent on `tap` | #144 |
| A calibration failure falls back to native dispatch with an `orientation_calibration_fallback` advisory | fail the command | The command still does what the native contract promises, and the advisory makes the fallback visible | #73, #74 |

## Out of scope

- Pinch and rotate presets stay in raw space. Orientation-aware multi-touch
  needs every interpolated sample mapped along the arc.
- A batch `gesture pinch` step emitted only finger 1 at the time of #73. That
  was a separate, older batch fault.

## Open questions

- During #66 the `ui` header once flipped from `landscape-right` to
  `landscape-left` across a scroll on the same device orientation, on a
  symmetric test page. It was seen twice and is not explained.
