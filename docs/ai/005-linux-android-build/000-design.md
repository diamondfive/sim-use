# 005 — Linux build (Android only): Design

| | |
| --- | --- |
| **Status** | Implemented (shipped in 0.15.0) |
| **Anchor date** | 2026-09-11 |
| **Primary PRs** | #141 (by @iopass4), #147 (continuation and hardening) |
| **Related** | [linux-guide.md](linux-guide.md) (living user guide), [002-e2e-confidence-suite](../002-e2e-confidence-suite/000-design.md) |

> Backfilled on 2026-10-14 from the PR descriptions of #141 and #147 and from the
> code. It is a retrospective reconstruction, not a plan written before the work.

## Background

The Android backend drives a device through `adb` and the bridge APK's HTTP
server. It needs none of the Apple frameworks that the iOS side uses. Agents
that run in Linux containers, in CI, and in WSL could not use sim-use at all,
because the package only built on macOS.

## Goals

- Build and test the Android half of sim-use on Linux with a Swift 6 toolchain.
- Keep the macOS build unchanged: same manifest, same behavior, same order of
  subcommands.
- Support an adb server on another host (WSL with the Windows adb, a container
  with the host adb).

### Non-goals

- iOS verbs, video capture (`record-video`, `stream-video`: AVFoundation), the
  Viewer and `init` on Linux.
- The unified cross-platform `devices` schema on Linux. There, `sim-use devices`
  is the Android listing.

## Design

- **A separate target graph.** `Package.swift` has an `#if os(Linux)` branch
  that declares only `SimUseCore`, `AndroidBackend` (without its three
  video-capture files) and the `SimUseLinux` executable
  (`Sources/SimUseLinux/SimUseLinux.swift`). The macOS manifest is in the
  `#else` branch, unchanged.
- **Portable core.** `SimUseCore` and `AndroidBackend` use conditional
  `Darwin`/`Glibc` imports and `FoundationNetworking`.
  `Sources/SimUseCore/LinuxCompat.swift` is compiled only on Linux. It gives a
  `Darwin` namespace that forwards to Glibc, so the daemon's qualified calls
  compile unchanged.
- **One daemon command.** The `daemon` command moved into `SimUseCore`. Each
  executable installs its platform hooks (root parser, backend probes) with
  `Daemon.installPlatformHooks` at launch, so the Linux executable has no second
  copy of the daemon.
- **Verbs the Linux build leaves out** print an error that names the verb and
  exit with status 64. A plain parse error would mislead the user.
- **Remote adb servers.** `adb forward` listens on the host of the adb server,
  so the bridge host comes from `ADB_SERVER_SOCKET` (`tcp:<host>:<port>`), or from
  `ANDROID_ADB_SERVER_ADDRESS` when no socket is set. `SIM_USE_BRIDGE_HOST`
  overrides both (`Sources/AndroidBackend/Bridge/BridgeConnection.swift`).
- **Connection scoping.** The cached forward, the bridge token and the daemon
  are scoped to the connection identity (adb server and bridge host). The client
  sends its identity with every business request
  (`DaemonClient.connectionIdentityProvider`). The daemon refuses a request
  from another identity before it parses the request
  (`DaemonDispatch.connectionMismatchOutcome`).
- **Install and CI.** `scripts/install-linux.sh` builds and installs the Linux
  binary. A Linux job in `.github/workflows/tests.yml` runs `swift build` and
  `swift test` for the Linux graph.

## Alternatives & decisions

- **A separate executable instead of `#if` in the macOS one.** `SimUse` imports
  the iOS backends and the FB* frameworks. Compiling them out file by file would
  spread `#if` through the macOS code. One small Linux root keeps the macOS
  sources unchanged.
- **The request-level identity gate (#147).** The `_ping` version gate restarts
  a daemon that was started for another connection, but its probe times out
  after 2 s. While client A's command runs, client B's probe times out, and B's
  request then ran in A's daemon, against A's adb server. A check on each
  request closes this gap without a stop of the busy daemon.
- **`long-press` and `app-state` on Linux.** #141 first left them out because
  their Android paths were in the macOS forwarders. Their Android
  implementation moved into `AndroidBackend`, so the flags and JSON match on
  both platforms.
- **Merge with a merge commit.** #147 carries the 20 original commits of #141.
  A squash or rebase merge would lose the contributor's commit identities.

## Amendments

(append `- Updated YYYY-MM-DD: ... — see [00N-topic.md](00N-topic.md)` lines here)
