# 010.002 — Side-bar detection with overflowing content frames

> Updated 2026-10-20: [004-remove-wide-content-gate.md](004-remove-wide-content-gate.md) removes the adjacent wide-content requirement retained here. The full-height content-pane rule is unchanged.

## Context

On 2026-10-20, the local 0.16.0 build on main `88a4c23` did not put the
LINE tab items in `Trailing` on the iPhone Duo cover display. The tabs were
vertical at x=396 on a 466x678 interface. The captured `ui --json` tree has
a full-height content `Group` at (0,0 382x678). Its children include a
button at (221,200 294x30), and horizontal service items up to x=523.
The accessibility frames extend beyond their content pane.

`OutlineFormatter` flattens the tree before `OutlineSideBars` checks it.
The parent bounds are lost: overflowing children both cross the proposed
bar boundary and appear to be members of the bar column. The crossing
check rejects the bar, so the five tabs fall back to the y bands.

## Decision

Keep the tree ancestry needed for side-bar evidence. Infer horizontal
content bounds only from a wide, full-height grouping ancestor aligned
with a screen edge. Use these bounds for side-bar detection and membership,
not for printed frames, hit targets, list detection or raw accessibility
output. A child entirely outside those bounds is not side-bar evidence.

Do not treat every `Group` as a clipping view: the AX tree does not expose
`clipsToBounds`, and small grouping frames do not prove a viewport. Keep
the existing anchor, vertical-stack, wide-content and crossing checks.
The rule must work on both leading and trailing edges without app ids or
device tables.

## Alternatives

| Option | Result |
| --- | --- |
| Remove the crossing check | Reject: ordinary iPhone rows and profile forms could become side bars (S4-003, S4-004). |
| Clip all descendants to every parent | Reject: AX grouping does not guarantee visual clipping; it also changes outline coordinates and selector behavior. |
| Bound only side-bar evidence by full-height content panes | Chosen: retain the narrow geometry rule and leave public frames unchanged. |

## Verification plan

- Store the captured tree in `Tests/Fixtures/outline-side-bars/`, with
  personal labels and process ids removed but geometry and ancestry intact.
- First reproduce the failure in `Tests/OutlineSideBarTests.swift`.
- Assert all five tab identifiers form one trailing region. Overflowing
  service items must not join that region; printed frames stay unchanged.
- Cover leading panes, nested grouping and small groups that do not prove
  clipping. Retain the existing real-device and false-positive fixtures.
- Run `make build`, `make test`, and read the live Duo screen with the
  changed binary. Record actual results below after implementation.

## Outcome

Implemented in `OutlineFormatter.swift` and `OutlineSideBars.swift`. The
formatter carries qualifying content-pane ancestors through flattening.
The detector intersects child frames with those horizontal bounds for
side-bar evidence and membership only. The pane must span the full screen
height, cover at least half the screen width, be narrower than the screen
and align with its leading or trailing edge.

Verification on 2026-10-20:

- The captured-tree regression failed before the production change: all
  five tab identifiers fell outside `Trailing` (eight assertion failures).
- `swift test --filter OutlineSideBarTests`: 21 tests passed, including
  leading/trailing nested panes, non-pane ancestors, and existing iPhone,
  iPad, Playground and Settings fixtures.
- `make build`: passed.
- `make test`: 1709 tests passed, no failures.
- Live read with `SIM_USE_NO_DAEMON=1 .build/debug/sim-use ui --device <Duo>
  --json --no-raw`: all five tabs plus the clock and Wi-Fi item were in
  `Trailing`, starting at x=396. No navigation or touch input was sent.

The regression fixture keeps all 36 captured nodes, frames and parent-child
relationships. Labels, text values and process ids are sanitized. Output
frame preservation, entry count and monotonic alias order are asserted.

## Limits

AX does not prove that a parent clips its children. This is a narrow pane
inference, not a general visibility model. Short or inset groups and
non-grouping ancestors do not bound side-bar evidence. Content outside an
inferred pane stays in the outline with its original frame; removing such
entries or changing their hit targets is outside this fix.
