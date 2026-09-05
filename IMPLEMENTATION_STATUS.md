# v4 reliability implementation checkpoint (build 405)

This is a partial implementation of the approved 28-group audit, not a claim
that the complete audit plan or real-device acceptance has passed. The icon is
unchanged. Deployment remains iOS 26+, primarily iPhone 11 and newer.

## Implemented changes requiring device acceptance

- Reject unsupported sensor frame durations before AVFoundation mutations;
  the 60-to-30 fallback applies 30, not an invalid 60. Photo preview selects
  still-capable formats independently of persisted Video resolution/FPS.
- Format discovery no longer temporarily mutates activeFormat.
- Configuration completions follow format application/exposure settling and a
  matching delivered frame rather than returning before queued application.
- Immediate recording-start reservation and additional capture/flip guards.
- Audio/video appends, split rotation and finalization share one serial queue.
- Four-second stop watchdog no longer releases writer ownership. Terminal
  timeout cancels the writer and retains its file. Per-segment recovery journal.
- Photos delegate completes at didFinishCaptureFor, including terminal errors.
- Photo aspect/encoding intent is captured before asynchronous work. Photos
  import starts only after durable local storage; failed imports retain files.
- Burst progress counts saved frames; review retains bounded-size thumbnails.
- New single zoom pill with hold/drag wheel, optical-wide reset, range clamping,
  physical slow-motion lens hysteresis and videoZoomFactor observation.
- Scoped delayed focus/exposure locks, torch lock cleanup, stale input checks.
- Saved movie rotation follows capture orientation; preview reapplies rotation
  when its connection is replaced without a device change.
- Settings refresh capabilities/storage; duplicate slow-resolution update removed.
- Slow-motion quality/resolution affect bitrate; audio and existing capture
  behavior settings exposed; slow-motion split/stop controls exposed.
- Native hardware capture events replace volume KVO; shutter uses shared UI path.
- Files gallery reachable alongside Photos; library change/foreground refresh;
  bounded simultaneous exports, current-page-only autoplay and share cleanup.
- Aspect-preserving video downscale; SDR selection when supported.
- Stable mode-row placement; opaque mode transition cover; countdown invalidation;
  front-flash duplicate guard; auto-dim wake grace; deferred/bounded debug logging.
- Pure zoom regression executable runs before the unsigned app build in CI.

## Audit coverage and work still required

Original issue numbers are retained to avoid losing findings or re-auditing.
"Partial" explicitly means further implementation, not only device testing.

| Group | Area | Status / remaining implementation |
|---|---|---|
| 1 | Invalid format/FPS and Photo transitions | Fix implemented; hardware acceptance outstanding |
| 2 | Mutating capability discovery/cache | Discovery fixed; validate all cache invalidation paths |
| 3 | Authoritative camera state / concurrency | Partial: shared immutable configuration snapshot, latest-request coalescing, and fully main-actor-owned published state remain |
| 4 | Lifecycle / restore | Partial: duplicate scene start removed and paused intent guarded; interruption/reset and in-flight photo cancellation need unified generation handling |
| 5 | Recording start | Partial: reservation and actual FPS applied; explicit negotiated result/failure type and immutable full recording request remain |
| 6 | Append/finalize ownership | Serialized; queue latency, bounded delivery and split setup require profiling before acceptance |
| 7 | Finalization / recovery | Per-segment journal and ownership fixes; failed-file quarantine UX and exhaustive recovery tests remain |
| 8 | Photo terminal lifecycle | Terminal delegate fixed; operation-ID cancellation and session-reset cleanup remain |
| 9 | Burst | Counts and retained memory improved; immutable burst session and cancel/reset generation remain |
| 10 | Photo durability | Local staging implemented; persistent failed-import retry UI remains |
| 11 | Review | Photos deletion and fresh single review fixed; lazy full-resolution loading and original-file sharing remain |
| 12 | Zoom | Single control implemented; latest-value coalescing, seamless recording handoff measurement, and hardware Camera Control slider routing remain |
| 13 | AF/AE | Delayed intent checks implemented; fully independent persisted lock intents across transitions remain |
| 14 | WB/torch | Lock cleanup and fallback validation implemented; atomic WB/lens rollback still needs integration with group 3 |
| 15 | Orientation | Snapshot transform implemented; rotation coordinator capture angle and all front/rear orientation acceptance remain |
| 16 | Settings state | Live refresh fixed; separate preferred vs resolved values and per-lens restoration remain |
| 17 | Settings behavior | Audio/quality/hidden controls improved; capability-consistent stabilization and actual encoder fallback labels remain |
| 18 | Hardware capture | Native events implemented; recording-from-Photo and playback/audio-route regression tests remain |
| 19 | Galleries / thumbnail | Files reachable; timestamp-ordered last-capture reference and robust Files rename/delete failures remain |
| 20 | Photos browser | Partial: stable identifier navigation, cancelable image requests, iCloud errors/retry and async deletion selection remain |
| 21 | Framing/color | Aspect-preserving scaler and SDR selection implemented; exact photo preview viewport/crop guides remain |
| 22 | Transition UI | Partial: fresh-frame barrier and stable mode row; authoritative UI phase/animation isolation remains with group 3 |
| 23 | Countdown / flash | Partial: cancellation checks; scoped pending action and single brightness owner remain |
| 24 | Thermal / dim | Wake grace fixed; central brightness coordination and critical idle thermal policy remain |
| 25 | Naming/stats/logging | Partial: cached Photos scan and one elapsed clock; utility prewarming, timestamped thumbnail ordering and segment-scoped stats remain |
| 26 | Accessibility | Zoom actions and flexible WB sheet implemented; app-wide labels/contrast/Dynamic Type/Reduce Motion remain |
| 27 | Polish | Partial: mode/countdown haptics; all preset/theme haptics, theme propagation and flash/battery semantics remain |
| 28 | Verification | Policy executable and fail-fast CI implemented; fake-engine lifecycle/recording tests and simulator UI tests remain |

## Required device matrix

Test all six directional Video/Photo/Slow-Mo transitions; repeated same-mode
taps; rapid Video→Photo→Slow-Mo; front/rear flips; settings changes; immediate
shutter/record/zoom after transitions; background/foreground at each stage.
Include 4K60→Photo and 4K60→Slow-Mo, each supported 120/240 format, physical
ultra-wide boundaries in both directions, recording start/stop at sub-1x zoom,
pinch and pill reset, volume at 0/100%, independent AF/AE locks, all four
orientations, long split recordings, cancellation, denied/limited Photos,
iCloud-only assets, low storage and thermal pressure.

Inspect saved frame timestamps/counts and dimensions, not merely the displayed
FPS label. Do not promise ultra-wide 120/240 support unless that exact physical
lens exposes the selected resolution/FPS on the device. Check iPhone 11 safe
areas plus larger iPhones, large Dynamic Type and Reduce Motion.
