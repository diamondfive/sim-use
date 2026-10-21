# 011.005 — Do not replay a batch after a transient error

## Context

Round 3 of #172 resolved R172-01 through R172-05 and found R172-06.
The final-send boundary protects one Paste, not the entire batch request.
A later AX query can fail with retry-classified text after an earlier Paste
completed. The client then replays the complete batch. Error aggregation
with `--continue-on-error` can combine an ambiguous Paste result and a later
transient failure, with the same replay risk.

## Decision

- Add `daemonAllowsTransientRetry` to the executable-command protocol, with
  a default of true. The iOS batch command overrides it to false.
- Daemon dispatch maps a transient-booting failure from an opted-out command
  to the existing permanent error kind. Preserve its error message and hint.
  Stale-simulator cleanup and all other classifications remain unchanged.
- Opt out for the whole batch request, including setup, rather than add a
  mutable Paste-only side-effect latch. A batch can also have earlier taps,
  typing or partially delivered HID. It is not safe to replay those either.
  The tradeoff is that an initial boot-readiness failure also requires an
  explicit retry. Observe completed steps before retrying any failed batch.
- Do not add wire fields, error-kind values, protocol versions, partial-step
  replay, or broad message sanitization. Other commands retain their current
  retry policy. Existing transport ambiguous-execution protection is intact.

## Verification plan

1. Add a two-step fake business command that uses the real batch retry policy
   and production Paste delivery boundary through the real daemon pipeline.
   Complete the first Paste, then fail before the second with the production
   later-step error shape. Observe the failure before enabling the opt-out.
2. Include `--continue-on-error`-shaped aggregation after an ambiguous first
   Paste. Assert one business execution, one first-step action and no second
   action. Preserve underlying diagnostics in the error response.
3. Retain ordinary transient retry, stale cleanup and hints in regression
   tests. Add policy coverage for the actual parsed iOS batch command.
4. Run build, full unit tests and affected live batch checks. Save a fresh
   clipboard snapshot before any live writes and restore it conditionally.

## Outcome

- Red: before the opt-out, both multi-step cases executed twice and recorded
  `["first Paste", "first Paste", "second Paste"]`. The actual parsed batch
  policy assertion also failed. The regression built and failed on behavior.
- Green: `make build` succeeded; `make test` passed 1775 tests with zero
  failures. A focused daemon, clipboard, menu, AX, forwarding and parsing run
  passed 101 tests in 16 suites. The two-step cases now record one execution
  and only the first Paste, while retaining the later-step diagnostics.
- Policy tests also preserve ordinary commands' one transient retry, opted-out
  stale-simulator cleanup, and the original error hint.
- Live: `SIM_USE_E2E=1`, the debug binary and Xcode 27.1 runtime tools, iPhone 17
  on iOS 27.0 with Device Hub. `PasteTests/(batchPaste|replacementWithoutSelectAll)`
  passed two test functions, including both standalone/batch refusal cases
  (three cases total, 61.8 seconds). The batch completed default, replacement
  and targeted Paste steps; the refusal cases preserved the existing text.
- Saved a fresh clipboard backup for this round. The last test-owned item
  snapshot supplied the restore count and item-data guard, without another
  marker Paste. Exact restored item equality was confirmed. The original
  Gesture Presets page, display bounds, orientation, keyboard/sync preferences
  and global locale were unchanged.
- The skill floor remains 0.16.0, the existing unreleased paste feature floor.
  README, batch help, skill and batch reference describe the explicit-retry
  behavior. No wire shape, enum value or released section changed.

## Limits

The new multi-step fault regression uses synthetic action callbacks and the
production Paste boundary, actual batch policy, daemon server/dispatch/client;
it does not inject an AX failure into the production simulator batch runner.
Live happy/refusal paths passed separately. The complete host matrix,
Android/physical-device live tests, Linux builds and paid evals were not rerun.
This record captures main's checks before independent re-review of R172-06.
