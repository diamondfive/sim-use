# Linux (Android only)

> Living guide. The design and its decisions are in [000-design.md](000-design.md).

sim-use builds on Linux with the Android backend only. The Android backend
drives the device through `adb` plus the in-device bridge APK's HTTP server and
needs none of the Apple frameworks the iOS side is built on, so `Package.swift`
declares a separate `#if os(Linux)` target graph: `SimUseCore`,
`AndroidBackend`, and the `SimUseLinux` executable.

## What is available

The Android verbs are registered at the top level under the same names as on
macOS — `ui` / `describe-ui`, `devices`, `tap`, `type`, `paste`,
`keyboard-state`, `swipe`, `button`, `touch`, `gesture`, `multi-touch`,
`screenshot`, `long-press`, `app-state` — plus the full
`sim-use android <verb>` namespace and `sim-use daemon`. They take the same
flags as on macOS, except that `--device <serial>` is always required. The
per-device daemon works as on macOS, so warm commands keep their low latency.

Not available on Linux (running one prints an error that names the verb and
exits with status 64):

- `sim-use ios <verb>` and `sim-use ios-device <verb>`
- `record-video` / `stream-video`, at the top level and under
  `sim-use android` — host-side H.264 muxing and encoding use AVFoundation
- `viewer`
- `init` (the agent-skill installer) — copy `skills/sim-use/` into your
  client's skill directory by hand

`sim-use devices` is the Android listing (`sim-use android devices`), not the
unified cross-platform schema.

## Build and install

Requirements: a Swift 6 toolchain for Linux (<https://www.swift.org/install/linux/>)
on `PATH`, plus JDK 17–21 and an Android SDK (`compileSdk=35`) to build the
bridge APK — see `AGENTS.md`.

```bash
scripts/install-linux.sh                 # bridge APK + release build + install
scripts/install-linux.sh --skip-bridge   # reuse the APK already in Sources/AndroidBackend/Resources
```

The script installs into `$PREFIX/lib/sim-use` (default `PREFIX=~/.local`) and
symlinks `$PREFIX/bin/sim-use`. It installs two things that must stay together:
the `sim-use` binary and the `SimUse_AndroidBackend.resources` bundle holding
the bridge APK, which `Bundle.module` looks up next to the executable. Set
`SWIFT_TOOLCHAIN` to a toolchain root if `swift` is not on `PATH`.

The binary links the Swift runtime dynamically, so the toolchain it was built
with must stay installed. `--static-swift-stdlib` does not work:
`FoundationNetworking` needs a static libcurl that the toolchains do not ship.

For development, `swift build` and `swift test` work directly (the `make`
targets are macOS-only).

## Usage

```bash
adb devices
sim-use android init --device <serial>   # install the bridge APK, enable its accessibility service
sim-use ui --device <serial>
sim-use tap @5 --device <serial>
```

`--json` returns the same `{"ok": …, "data": …}` envelope as on macOS.

## Remote adb server (WSL)

`adb forward` opens its listening port on the machine that runs the **adb
server**. When `ADB_SERVER_SOCKET` points at a remote server
(`tcp:<host>:<port>`), or, with no `ADB_SERVER_SOCKET`, when
`ANDROID_ADB_SERVER_ADDRESS` names a remote host (the same precedence adb
uses), sim-use therefore talks to the bridge on that host instead of
`127.0.0.1`. Set `SIM_USE_BRIDGE_HOST` to override the host explicitly. This
applies on macOS too.

The forwarded port and bridge token that sim-use caches for a device belong
to the adb server that created them, so they are scoped to that connection
(`ADB_SERVER_SOCKET`, `ANDROID_ADB_SERVER_ADDRESS` / `ANDROID_ADB_SERVER_PORT`
and `SIM_USE_BRIDGE_HOST`). Pointing a device at another server restarts that
device's daemon and creates a fresh forward and token, and a cached forward is
reused only while `adb forward --list` still shows it for the device. If
`adb forward --list` itself fails, the command fails with that adb error and
the cached session is kept, rather than opening a second forward.

A daemon that is busy with a command from another connection cannot be
restarted at once. A command for a different connection is then refused with
a "started for a different device connection" error and is not run; retry it
after the other command finishes.

Equivalent spellings of the same server (no variables,
`ANDROID_ADB_SERVER_PORT=5037`, `ADB_SERVER_SOCKET=tcp:localhost:5037`) count
as one connection, so switching between them keeps the daemon and the
forward. When only the bridge host changes, the old forward is removed from
the adb server before a new one is opened. A forward created on a
*different* adb server stays registered there, because sim-use is no longer
talking to that server; `adb forward --list` against that server shows it,
and `adb -s <serial> forward --remove tcp:<port>` clears it.

The common case is WSL, which has no USB access: WSL's `adb` points at the
Windows host's adb server so physical devices stay visible.

1. On Windows, start the server listening on all interfaces:
   `adb kill-server` then `adb -a -P 5037 nodaemon server`. Without `-a`, the
   server — and every forward it opens — binds to Windows loopback, which WSL
   cannot reach.
2. In WSL, point `adb` and sim-use at it:
   `export ADB_SERVER_SOCKET=tcp:$(ip route show default | awk '{print $3}'):5037`
   (under WSL's default NAT networking, the default gateway is the Windows
   host).

> **Security.** `adb -a` exposes the adb server — full shell access to every
> attached device — and the forwarded bridge port on **every** interface of the
> Windows host, and the bridge speaks plain HTTP. Only do this on a trusted
> network, and restrict inbound TCP 5037 and the forwarded ports to the WSL
> virtual network in Windows Firewall.

A device reached with `adb connect <ip>:5555` through a local adb server in WSL
needs none of this: the forward is local and the bridge host stays
`127.0.0.1`.

## Containers

The per-device daemon is a child process that `sim-use` spawns and later
stops. In a container whose PID 1 does not reap children — for example
`docker run … sleep infinity` — an exited daemon stays behind as a zombie.
`kill(pid, 0)` still succeeds on a zombie, so `sim-use daemon stop` reports
`stopped=false` even though the daemon has exited. Run the container with an
init process: `docker run --init …`, or `init: true` in Compose (any init that
reaps children, such as `tini`, works).
