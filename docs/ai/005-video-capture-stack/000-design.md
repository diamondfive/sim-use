# 005 — Video capture stack (record-video and stream-video): Design

| | |
| --- | --- |
| **Status** | Implemented (0.12.0 – 0.15.0) |
| **Anchor date** | 2026-07-17 (#52 opened) |
| **Primary PRs** | #52 (by @subdiox), #70, #79, #80, #81, #84 (by @kws0210), #85 (by @EuanTop), #100 (by @kws0210, carried by #101), #101, #133, #136, #138 |
| **Related** | issues #78, #83, #132, #134, #135; [003-e2e-confidence-suite](../003-e2e-confidence-suite/000-design.md); [006-xcode27-support](../006-xcode27-support/000-investigation.md) (the idb bump that gave iOS its native recorder) |

> Backfilled on 2026-10-14 from the PR descriptions, the code, `CHANGELOG.md`
> (0.12.0 – 0.15.0) and the maintainer's review notes. It is a retrospective
> reconstruction, not a plan written before the work. Numbers are quoted from
> the PR or CHANGELOG that states them.

## Background

Before #52, `record-video` polled screenshots and re-encoded every frame. It
was capped near 8–10 fps (#52). `stream-video` on iOS had no native format:
`mjpeg` / `raw` / `ffmpeg` were a screenshot-per-frame loop, and `bgra` sent
raw pixels — about 4 fps (#133). Agents and humans need two things from a
device screen: a file that QuickTime, Finder and a GIF transcoder can open,
and a live preview that stays in sync with the device.

## Goals

- Capture the encoder's own H.264 on both platforms, without a host-side
  re-encode.
- One pipeline per platform for both verbs, so `record-video` and
  `stream-video` cannot drift apart on how the picture is encoded.
- A live stream that a standard player paces correctly: `ffplay -f mpegts -i -`
  on both platforms.
- A stream that can always be stopped: Ctrl-C ends it even when the consumer
  stopped reading.

### Non-goals

- A broadcast-grade transport stream (see the PCR decision below).
- Re-encode or transcode during capture. GIF is a post-stop step.
- Video capture on Linux (no AVFoundation; see
  [008-linux-android-build](../008-linux-android-build/000-design.md)).

## Design

### Module boundary

`Sources/SimUseVideo/` (#79) holds the platform-neutral host-side plumbing and
must stay FB*-free: `AnnexBStreamParser`, `H264MuxingPipeline` (with the
`H264AccessUnitSink` protocol), `H264PassthroughRecorder`, `MPEGTSMuxer`,
`MPEGTSStreamWriter`, `StdoutStreamSink`, `GIFTranscoder`, `RecordingFormat`
(`RecordingOutputPlan`), `VideoRecordingOptions`, `VideoOutputFile`, and
`VideoCommandSupport` (`H264StreamRecorder`, `VideoFrameUtilities`,
`RecordingFinishWatchdog`). Anything that needs FBSimulatorControl lives in
`Sources/iOSSimBackend/`; anything adb-shaped lives in `Sources/AndroidBackend/`.

### Pipelines

| Verb | Platform | Source | Path to the sink |
| --- | --- | --- | --- |
| `record-video` | iOS | `FBVideoStream`, `transport: .annexB` | `AnnexBPipelineConsumer` → `H264MuxingPipeline` → `H264PassthroughRecorder` → MP4 |
| `record-video` | Android | `adb screenrecord --output-format=h264` (fallback: `screencap` loop) | `H264MuxingPipeline` → `H264PassthroughRecorder` → MP4 |
| `stream-video --format h264` | iOS | `FBVideoStream`, `transport: .mpegts` | `StdoutStreamConsumer` → `StdoutStreamSink` → stdout |
| `stream-video --format h264` | Android | `adb screenrecord --output-format=h264` | `H264MuxingPipeline` → `MPEGTSStreamWriter` (`MPEGTSMuxer`) → `StdoutStreamSink` → stdout |
| `stream-video` `mjpeg`/`raw`/`ffmpeg` | both | screenshot / `screencap` loop | stdout (deprecated on iOS) |
| `stream-video --format bgra` | iOS | raw pixels | stdout |

Both iOS verbs build one `FBVideoStreamConfiguration.h264Capture(fps:quality:scale:transport:)`
(`Sources/iOSSimBackend/Util/H264CaptureConfiguration.swift`). They share the
encoder settings and differ only in the transport and the sink.

GIF (`--format gif`, or a `.gif` output name) is a transcode after stop, run by
`RecordingOutputPlan` for every surface. A failed transcode keeps the
intermediate MP4. `--gif-markers` adds START/END cards.

## Alternatives & decisions

| Decision | Options considered | Chosen because | PR |
| --- | --- | --- | --- |
| Capture the device encoder's H.264 and mux it as passthrough | Keep the screenshot loop; re-encode on the host | Native capture reached ~50–60 fps under motion on Android against ~7–8 before (#52). No re-encode cost | #52, #70 |
| iOS record-video uses the shared `H264MuxingPipeline`, not idb's in-process file writer | idb's writer; idb's live fragmented MP4 | idb's live fMP4 has no `sidx`/`mfra`, so AVFoundation reads it as 0 frames, 0.000 s: unplayable in QuickTime and untranscodable to GIF. A regular MP4 from Annex B is | #133 |
| Frame timestamps from host arrival time | The encoder's sample clock | Annex B carries no container timing. Measured jitter rose from ~3 ms to ~6–7 ms stddev, far inside a 33 ms frame at 30 fps, with no dropped or reordered frames | #133 |
| A separate `SimUseVideo` target, FB*-free | Keep the plumbing in `iOSSimBackend/Util` | Android code needed the muxer, and only the executable could see both backends. A neutral layer keeps the dependency graph one-way | #79 |
| Carry h264 streams in MPEG-TS on both platforms | Bare Annex B; fragmented MP4 | Annex B has no PTS: ffprobe reads it as 25 fps whatever the rate, and the lag grows without bound (578 KB queued at 20 s, 1376 KB at 30 s; 0 KB with TS). fMP4 via AVAssetWriter cuts fragments on keyframes, which `screenrecord` emits too rarely (an 8 s capture became one 15 MB fragment at stop) | #136 |
| Android stream PTS = host arrival time, timeline advance clamped to 0.2 s per picture, discontinuity flag on the resuming picture | A wall-clock timeline with the clock sampled through idle stretches | ffplay holds a picture for a duration derived from the next PTS, so a wall-clock gap keeps the stale picture on screen. Measured: the clamp recovers in 0.45 s / 0.51 s after 10 s / 30 s idle; the wall-clock variant had not recovered after 30 s. Cost: PCR repetition exceeds 100 ms on a still screen. `record-video` keeps real elapsed time | #136 (`MPEGTSStreamWriter.maxFrameGap`) |
| Re-announce PAT/PMT every 100 ms, with no PCR in the tables | No re-announcement; repeat the last PCR | A consumer that joins mid-stream needs the tables, a still screen sends no picture, and the write is how a closed pipe is noticed. Repeating the old PCR made ffmpeg report every later picture as corrupt | #136 |
| `StdoutStreamSink`: `poll(POLLOUT)` plus writes of at most `PIPE_BUF`, descriptor flags never changed; EPIPE ends the stream with exit 0 | Blocking `write(2)` (idb's `FBFileWriter_Sync`); `O_NONBLOCK` on fd 1 | A blocking write hung Ctrl-C when the consumer stalled. `O_NONBLOCK` lives on the shared open file description, so it leaked to the terminal or to stderr under `2>&1` | #138 |
| iOS `stream-video --format h264` defaults to 30 fps; the screenshot formats keep 10 | One default of 10 for all formats | The native stream has no reason to throttle; the screenshot loop cannot go much faster (`IOSSimStreamVideoCommand.effectiveFPS`) | #138 |
| Deprecate `mjpeg`/`raw`/`ffmpeg` on iOS only; keep them on Android without a warning | Remove them on both; add a `screencap` fallback to Android `stream-video` first (#134 plan) | On a simulator h264 is strictly better (144 frames / 1.33 MB against 24 / 11.2 MB for mjpeg over 6 s). `screenrecord` is unavailable on some Android devices, and a fallback cannot keep a stream's container stable (MPEG-TS has no MJPEG stream type). A unit test pins the asymmetry | #138 |
| `stream-video` rejects `--json` | Append the envelope after the stream | stdout carries the video bytes; an envelope corrupts the stream | #80 |
| GIF is a post-stop transcode; sampling capped at 50 fps | A fourth capture path | No capture pipeline exposes decoded frames in-process. The GIF centisecond delay floor makes faster pacing dishonest | #84 |
| `GIFTranscoderTests` run `.serialized` | Default parallelism | Three or more concurrent VideoToolbox encode sessions deadlock the virtualized GitHub macOS runners | #101 |
| JPEG scaling through `CGContext`/`CGImageDestination` | `NSImage.lockFocus()` | The AppKit path rendered through the Retina backing scale, so `--scale 0.5` did not give the requested pixel size | #85 |
| Documented preview: `ffplay -f mpegts -probesize 32768 -i -` | `-probesize 32 -fflags nobuffer`; add `-analyzeduration 0` | 32 bytes cannot identify the codec and `nobuffer` starves the probe. `-analyzeduration 0` selects ffmpeg's default window, measured as no change | #136, #138 |

## Operational notes

- `screenrecord` is variable-frame-rate. It produces frames only while
  SurfaceFlinger composites, so run the Android emulator headless
  (`-no-window`) for video work; the measurements are in `AGENTS.md`.
- A still Android screen sends no picture at all, so ffplay opens only after
  the device moves. iOS is constant-frame-rate and opens at once.

## Open questions

- #52 records a cold-start zero-frames edge case found in review that did not
  reproduce against the current idb. Not verified since.
- The PCR-repetition deviation is measured only against ffplay. Other
  consumers may schedule pictures differently.
- No Android E2E covers a stalled consumer: a still screen never fills the
  pipe. The sink unit tests and the iOS E2E cover the mechanism.
- #136's description says the tables repeat every 0.5 s; the merged code and
  `CHANGELOG.md` (0.15.0) say 100 ms. The code is the current state.

## Amendments

(append `- Updated YYYY-MM-DD: ... — see [00N-topic.md](00N-topic.md)` lines here)
