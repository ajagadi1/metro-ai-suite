# Design: Point-to-Point Latency Measurement for Loitering Detection with Stream Manager

Status: Draft for review. Design only, no implementation yet.

Applies to: the `loitering-detection-sm` installation (Stream Manager overlay) and the WSF
`Edge-AI-Samples` `ld` workload
(`applications.benchmarking.benchmark.platform-hero-features`).

## 1. Summary

WSF already reports pipeline throughput, stream density and pipeline latency for loitering
detection. It does not measure what happens after the pipeline detects loitering: starting and
stopping a Stream Manager (SM) recording, and the clip becoming available.

This document defines the latencies to measure on that path, where to timestamp them, which
streams and sources to test (simulated RTSP and a real AXIS P3265-LVE camera), and how the
results are reported through WSF.

Headline KPI: **clip E2E latency** and its overhead **Δ = E2E − recorded clip duration**.
Example: a 50 s clip with a 50.5 s E2E latency has Δ = 500 ms, the overhead added by the
pipeline, the REST calls and Stream Manager.

## 2. Goals and non-goals

Goals

- Measure recorder input (end of pipeline) → record-start call, record-start acknowledgement, and the same for
  record stop.
- Measure the final clip E2E latency and its Δ.
- Test with simulated RTSP streams and a real AXIS camera, at defined stream counts.
- Report results with the existing WSF KPIs (`wsf-kpi`).

Non-goals

- Changing recorder behaviour (for example replacing the 0.5 s tick poll). The benchmark may
  justify that later.
- Staging loitering events at the real camera. This only affects how many sessions a run
  collects, not the measurement design.
- Cloud upload latency. The SM → Cloud path is planned for 2027.0 (see section 6).

## 3. Application flow

See [loitering-detection-architecture.drawio.svg](../user-guide/_assets/loitering-detection-architecture.drawio.svg).

```text
Looped videos (FFmpeg) / AXIS camera
        │ RTSP
        ▼
RTSP server (MediaMTX) ── RTSP ──► Stream Manager (rolling buffer, recordings) ┈┈► Cloud (planned 2027.0)
        │ RTSP                              ▲
        ▼                                   │ REST: POST /streams, /records/start, /records/stop
DL Streamer Pipeline Server (DLSPS) ────────┘ (the "Event Recorder API" arrow = `loitering_events`)
  decode → detect → track → analytics (dwell time per zone) → ... → loitering_events → ...
        ├──► MQTT broker ──► Grafana ──► Nginx ──► User
        └──► WebRTC (MediaMTX) ──► User
```

### Design principle: independent of how the recorder is built

The pipeline element that starts and stops Stream Manager recordings is called `loitering_events`.
It is today a `gvapython` element (`plugins/python/loitering_events.py`). This document calls it
"the recorder" for short.
`gvapython` is expected to be deprecated and replaced by GStreamer Python bindings, and the
pipeline in DLSPS may change in other ways. The measurement design therefore depends only on
two stable interfaces, not on the element type:

- **Recorder input:** the moment a detection result with a loitering object is handed to the
  recorder (T2). This is the point the requested "end of pipeline" latency starts from. It is
  not strictly the pipeline output: in the CPU pipelines the recorder is followed by a queue, a
  FPS counter and the `appsink`, so the frame leaves the pipeline slightly later (in the GPU and
  NPU pipelines the `appsink` follows directly). We use the recorder input because it is the
  point where the recording logic receives its data, and it is the same whatever the elements
  after it are. It is also not the real-world moment the person started loitering. That moment
  is T0, earlier by the pipeline latency (P3), and the dwell-time threshold comparison is
  currently done by the recorder itself.
  If the true pipeline output is needed, take a timestamp at the `appsink` with a pad probe and
  report the difference as an extra metric.
- **Stream Manager REST API:** `POST /records/start`, `POST /records/stop` and the responses.
  These do not change with the pipeline.

Everything between those two points (threading, polling interval, HTTP client) is recorder
behaviour. It is measured, but it is not assumed. Timestamps are taken inside the recorder next
to those two interfaces, so they move with the recorder when it is rewritten. Stream Manager
side values (T6, S4, clip duration) and the existing pipeline latency tracer do not depend on
the recorder at all, so they stay valid and also serve as a cross-check.

Recorder behaviour that shapes the latencies in the current implementation (it may differ after
a rewrite, and the measured values show what the new version does):

- The result handler runs on the streaming thread for each frame that has a loitering object.
  The first result at or above the loitering threshold defines "recorder input".
- A per-camera tick thread (every 0.5 s) decides to start or stop and makes the blocking REST
  calls. It also polls `GET /streams` every 10 s (every 2 s while the stream is not ready).
- A start asks SM for `pre_event_duration` (5 s by default) from its rolling buffer (30 s by
  default), so the clip begins before the call is made.
- A stop happens `STOP_GRACE_SEC` (3 s) after the last loiterer. `MAX_SESSION_SEC` (300 s)
  splits long sessions into segments.
- HTTP calls use `urllib`: a new TCP connection per call, no keep-alive.

## 4. Timestamp model

In-process deltas use a monotonic clock. Cross-container values use the host wall clock, which
all containers share. Camera time depends on NTP and RTCP.

| TS | Point | Captured by |
|----|-------|-------------|
| T0 | Capture time of the frame where dwell crosses the threshold | RTP/NTP reference of the frame (feasibility to confirm) |
| T1 | Frame enters DLSPS (`rtspsrc`) | GStreamer latency tracer |
| T2 | Recorder input: first loitering result (dwell ≥ threshold) reaches the recorder | recorder |
| T3 | Recorder decides to start (picks the loiterer up) | recorder |
| T4 | `POST /records/start` sent | recorder |
| T5 | Start acknowledgement received | recorder |
| T6 | Recording confirmed live in SM (optional) | SM probe |
| S0 | Last row with a loiterer | recorder |
| S1 | Stop decided (about S0 + grace + up to one tick) | recorder |
| S2 | `POST /records/stop` sent | recorder |
| S3 | Stop acknowledgement received | recorder |
| S4 | Clip finalized and listable (`GET /records/<id>`) | SM probe |

```text
Start: T0 → T1 → T2 → T3 → T4 → T5 (→ T6)
Stop:  S0 → (grace) → S1 → S2 → S3 → S4
```

## 5. Metrics

### 5.1 Existing WSF metrics (re-run with the SM overlay on)

| ID | Metric |
|----|--------|
| P1 | Pipeline throughput |
| P2 | Stream density |
| P3 | Pipeline latency (`rtspsrc` → `destination`) |

The re-run shows the cost of recording on density.

### 5.2 Requested metrics

| ID | Metric | Definition | Notes |
|----|--------|------------|-------|
| R1 | Recorder input → record-start call | T4 − T2 | R1a = T3 − T2 (recorder's own wait before deciding, up to 0.5 s with today's tick poll); R1b = T4 − T3 (includes a blocking `GET /streams` when due) |
| R2 | Record-start acknowledgement | T5 − T4 | REST round trip including SM processing |
| R3 | Record-stop path | R3a = S2 − S1; R3b = S3 − S2; R3c = (S2 − S0) − `STOP_GRACE_SEC` | R3c removes the configured grace, because it is configuration, not performance |

### 5.3 Proposed additional metrics

| ID | Metric | Definition / purpose |
|----|--------|----------------------|
| A1 | Arm latency | T5 − T2 (= R1 + R2). A1' = T5 − T0 includes camera and ingest (event → armed) |
| A2 | Buffer headroom | `SM_BUFFER_LENGTH` − `PRE_EVENT_SEC` − A1'. While it is positive, start latency loses no footage. Also count `history_unavailable` fallbacks |
| A3 | Pre-roll alignment error | Actual clip start − requested `start_ts` (keyframe snap, about one GOP) |
| A4 | Stop → ready | S4 − S3 (SM finalize time) |
| A5 | Stream register / recovery | `POST /streams` → state `buffering` |
| A6 | `GET /streams` round trip | It delays the tick when it runs |
| A7 | Segment continuity | Gap or overlap at the `MAX_SESSION_SEC` split |
| A8 | Reliability counters | Start/stop failures, retries, 5 s back-off, 429 `capacity_exhausted`, 507 `storage_full` |
| A9 | SM resources | CPU, RSS, `/dev/shm`, disk write rate versus stream count |
| A10 | Side paths (optional) | Frame → MQTT → Grafana alert latency; WebRTC glass-to-glass |

### 5.4 Final E2E latency (headline)

```text
E2E    = t_saved − clip_media_start      t_saved = S4 (or S3 if the clip is ready on the ack)
D_clip = clip_media_end − clip_media_start
Δ      = E2E − D_clip = t_saved − clip_media_end
```

- `clip_media_start` is the capture time of the first clip frame, including the pre-roll.
  `D_clip` comes from the SM recording start/end, cross-checked with `ffprobe`.
- Δ is the time from the last recorded frame to the clip being saved: SM ingest lag
  (camera/MediaMTX → SM buffer) + stop REST call (R3b) + finalize (A4).
- The grace period and the pre-roll are inside `D_clip`, so they do not inflate Δ. Start-side
  latency does not enter Δ because the pre-roll is back-filled from the buffer. It is covered
  by A1 and A2.
- Example: `D_clip` = 50 s and E2E = 50.5 s give Δ = 500 ms.
- The event-anchored value (`t_saved − T0`) comes from the same data: loiter time beyond the
  threshold + grace + Δ. It is derived, not a headline.

### 5.5 Cold start (optional, secondary)

Cold start is the time from starting a pipeline until the system can record: DLSPS pipeline
POST → SM stream in `buffering` (A5). Until then a loitering event cannot be recorded, or has no
pre-roll. The same path applies when a failed stream is re-registered. Report it as one number.
It can be dropped without affecting the headline KPI.

## 6. Cloud path (planned for 2027.0)

The architecture diagram shows a dashed SM → Cloud link for storing clips off-site. It is
planned for **2027.0**. Intended benefits: off-site retention of evidence, remote access, and
freeing edge storage. The feature does not exist yet, so this section is a plan that is ready
to execute once it ships. Nothing here blocks the first measurement phase.

### 6.1 What happens after the clip is saved

```text
Clip saved in SM ──► upload queued ──► upload started ──► upload finished ──► object visible in cloud
   t_saved                              C0                   C1                   C2
```

`t_saved` is the same point as in section 5.4 (S4, or S3 if the clip is ready on the stop
acknowledgement). C0, C1 and C2 are new:

| TS | Point | Captured by |
|----|-------|-------------|
| C0 | Upload of this clip starts | SM event/log, or first request seen at the cloud endpoint |
| C1 | Upload finished (SM reports success) | SM event/log or REST status |
| C2 | Object is visible and readable in the cloud store | cloud-side poll (list/get on the object) |

The upload runs inside Stream Manager, so it is outside the recorder. Like the rest of the
design, the measurement depends on observable interfaces only (SM status/events and the cloud
store), not on how the upload is implemented.

### 6.2 Metrics

| ID | Metric | Definition |
|----|--------|------------|
| Cl1 | Saved → upload start | C0 − `t_saved` (queueing delay) |
| Cl2 | Upload duration and throughput | C1 − C0; clip MB ÷ duration |
| Cl3 | Saved → visible in cloud | C2 − `t_saved` |
| Cl4 | Cloud E2E and Δ_cloud | `E2E_cloud = C2 − clip_media_start`; `Δ_cloud = E2E_cloud − D_clip` (Δ_cloud = Δ + Cl3) |
| Cl5 | Resilience | Behaviour during WAN loss: retries, time to recover, no clip lost or duplicated |
| Cl6 | Interference | R1–R3, P1 and A9 with upload on versus off, at the same stream count |
| Cl7 | Upload backlog | Number and size of queued clips over a run; does it drain between events? |

Cl4 is the headline for the cloud path and is read the same way as the local E2E: compare it
with the clip duration.

### 6.3 Test conditions

The upload time depends mostly on clip size and the network. Cloud runs use the same sources
and stream counts as section 7 and add these variables:

| Variable | Values |
|----------|--------|
| Clip size | Short event clip (about 10–15 s) and long clip (about 60 s). At 1280×720, 30 fps, about 2–4 Mbps, a clip is roughly 3–30 MB |
| Network (uplink to the cloud) | LAN-like (no limit), 50 Mbps / 30 ms, 10 Mbps / 80 ms, 2 % packet loss |
| Concurrency | Events finishing at the same time on 1, 4, ... max cameras (worst case: all at once) |
| Upload | Off (baseline) and on |

- **Without a real cloud:** use a cloud storage emulator for the chosen provider (for example
  Azurite for Azure Blob) on a separate machine or container, and shape the link with
  `tc netem` to create the network profiles above. This measures SM's behaviour independent of
  internet variability.
- **With a real cloud:** one repeat run per network-independent configuration against the real
  service, from the lab network, to confirm the emulator results. Record the region and time of
  day, because internet latency varies.
- Clock sync: C2 is observed from the cloud side. Compare it with the host clock only after
  checking the time offset between the observer and the host (NTP). The cloud's own server
  timestamp (object creation time) can be used as a cross-check.

### 6.4 Pass criteria and reporting

- Report count, p50, p90, p99 and max for Cl1–Cl4, per network profile and clip size.
- Report Cl4 against `D_clip`, as for the local E2E.
- Interference (Cl6) is reported as the change in R1–R3 and P1 with upload on, and a note
  whether the maximum stream count at 30 fps changes.
- Resilience (Cl5): the test passes if every clip arrives exactly once after the link is
  restored. The recovery time is reported.

### 6.5 What must be confirmed before this can start

- The cloud provider and protocol (possibly Azure Blob), and the SM release that ships it (2027.0).
- How SM exposes upload progress: a REST status, events or logs. This decides how C0 and C1 are
  captured. If SM exposes nothing, only C2 (cloud side) is available, so Cl1 and Cl2 are
  replaced by Cl3.
- Whether upload is automatic or configurable (for example only some clips, or a delay), and
  whether the clip is deleted locally after upload. This changes A9 and the backlog (Cl7).
- Retry and store-and-forward behaviour on WAN loss.

## 7. Test matrix

One resolution is used for every source: **1280×720 (HD), 30 fps, H.264**. The simulated
streams already use it (the VIRAT sample videos, re-encoded by the RTSP feeders with GOP 30 and
no B-frames, looped about every 100 s), and the AXIS camera is configured to match. Using the
same resolution makes simulated and real-camera numbers directly comparable.

The application ships four feeders and zones. Feeders and zones beyond four are needed for
higher stream counts (reusing the videos).

**Stream counts:** 1, 4, ... up to the maximum number of streams supported without the
per-stream frame rate dropping below 30 fps. The maximum is found by the WSF stream-density
search (with the Stream Manager overlay on). The same rule applies to the camera.

| Tier | Source | Resolution / fps | Stream count |
|------|--------|------------------|--------------|
| S1 | Simulated loops | 1280×720, 30 fps, H.264 | 1, 4, ... max supported at 30 fps |
| C1 | AXIS camera via MediaMTX relay | 1280×720, 30 fps, H.264 | 1, 4, ... max supported at 30 fps |
| C2 | AXIS camera direct to DLSPS (SM still via relay) | 1280×720, 30 fps, H.264 | 1, 4, ... max supported at 30 fps (also shows the camera's client limit) |
| C3 | 1 real camera + (N−1) simulated | 1280×720, 30 fps, H.264 | N = half of the maximum |

- Report latency at each stream count, not only at the maximum.
- Sample size: at least 30 sessions per metric for p50/p90, at least 100 for p99. A simulated
  camera produces about one session per loop (about 100 s), so low stream counts need long runs
  or a shorter `STOP_GRACE_SEC` (always report the value used).

## 8. AXIS P3265-LVE camera

From the datasheet: up to 1920×1080 (down to 160×90, so 1280×720 is supported); H.264 Baseline/Main/High, H.265 Main and
Motion JPEG; 25/30 fps with WDR (50/60 without); multiple individually configurable streams;
Zipstream; low-latency mode; RTSP, RTCP, RTP and SRTP; ONVIF Profiles S, T, G and M.

**Can it serve multiple DLSPS pipelines?** In principle yes, since RTSP supports multiple
clients. The datasheet gives no client limit. The limit is encoder load and network uplink
(a 1280×720, 30 fps stream is about 2–4 Mbps per unicast client). Measure it with C2 rather than assume it.

**Recommended topology:** camera → MediaMTX (one pull) → N pipelines + Stream Manager.
Stream Manager rejects credentials in the URL, and the camera needs authentication. A relay also
keeps the camera load constant and mirrors the shipped application.

**Camera settings:**

- A dedicated stream profile, for example
  `rtsp://<ip>/axis-media/media.amp?videocodec=h264&resolution=1280x720&fps=30`.
- A fixed GOP of 30 (Zipstream dynamic GOP off), no B-frames, about 2–4 Mbps. Stream Manager
  rejects sparse keyframes.
- NTP on the camera and the host from the same server, and RTCP sender reports enabled.

**Assumptions and pre-flight checks:** the camera is on the same LAN as the test host and
NTP-synced with it (verify, and log the clock offset per run). Zones must be redrawn for the
camera view.

**Risks:** Stream Manager may not accept the stream behind MediaMTX (RTCP sender report
forwarding). Camera/host clock skew shifts the pre-roll and any camera-time metric.

## 9. Instrumentation design

1. **Recorder:** an opt-in switch (default off, no behaviour change) writes one structured log
   line per recording session, with T2–T5, S0–S3, HTTP status, retry count and the time spent
   in any blocking `GET /streams` call. The log line format is fixed and independent of the
   implementation, so a rewritten recorder (for example on GStreamer Python bindings) emits the
   same fields and the post-processing does not change. The timestamps are taken at the two
   stable interfaces: result received (T2) and REST request/response (T4, T5, S2, S3).
2. **SM probe:** a benchmark-only helper, outside the hot path, polls `GET /records/<id>` for
   T6, S4, `D_clip` and the actual clip start. The SM REST fields for these must be confirmed.
3. **T0 and T1:** use the RTSP NTP/RTP timestamp (`add-rtp-timestamp=true` is already set in the
   pipelines). Fallback: join with the tracer's per-frame data by time window. Cross-check with
   an on-screen millisecond clock.
4. **Resources (A9):** sample SM CPU, RSS, `/dev/shm` and disk with `docker stats` or the
   existing metrics stack.

## 10. WSF integration (`Edge-AI-Samples` `ld` role)

- New tunables: `RECORDING` (installs `loitering-detection-sm`), `LATENCY_TRACE`, `SOURCE`
  (`sim` or `axis`).
- The benchmark payload (`benchmark_app_payload.json`) uses `file://` sources and has no
  `loitering-events-properties`. It must switch to RTSP sources with `camera_id` and
  `source_uri`.
- `LATENCY_FILTER="(filesrc|destination)"` assumes a file source. Change it to `rtspsrc` for
  RTSP runs.
- Collect the recorder log lines and the SM probe output in `logs.yaml`. A post-processor
  prints `latency #<metric> p50/p90/p99 (ms)` lines in the format the existing `kpi.sh`
  regex already matches.
- Add a latency section to `docs/user-guide/how-to-guides/benchmark.md`.

## 11. Methodology

- Warm up before sampling, and discard the first session per camera (cold buffer can cause
  `history_unavailable`).
- Report count, p50, p90, p99 and max per metric, together with `STOP_GRACE_SEC`,
  `PRE_EVENT_SEC`, `SM_BUFFER_LENGTH` and the codec/GOP settings.
- Expect R1a (tick poll) to dominate R1. If it does, a follow-up could wake the tick thread when
  the first loiterer appears.
- Log the camera clock offset for every real-camera run.

## 12. Risks and open questions

- The SM REST fields for recording state, actual start/end and finalize are not in this repo.
  Confirm them against the Stream Manager documentation or team.
- Frame-level T0 may not be feasible from inside the recorder, whichever mechanism it uses. The fallback only degrades A1' and the
  event-anchored value.
- The camera client limit and SM's concurrent-recording cap (`capacity_exhausted`) bound the
  stream counts.
- Cloud provider, protocol, the upload status interface and the 2027.0 timeline are not final (see section 6.5).

## 13. Decisions made

- Headline E2E is clip-anchored (Δ = E2E − clip duration). Cold start is a separate, optional
  KPI.
- Cloud upload metrics are deferred until the feature is available (2027.0).
- Staging events at the real camera is outside this design.
