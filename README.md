# LowBitCam

A deliberately plain camera app for an iPhone 7 on iOS 15.8.x. Open it, you are in
the camera. Tap the gear, pick a resolution and a quality. Tap the red button, it
films. That is the whole app.

The point is filming for hours without eating the phone's storage.

---

## The two settings

**Resolution** — 720p (1280x720) · 480p (854x480) · 320p (568x320) · 144p (256x144)

**Quality** — High · Medium · Low · Ultra low

The camera itself always runs at 720p30. The resolution you pick is applied by the
encoder, so switching settings never restarts the camera.

### What an hour costs (HEVC, with sound)

| | High | Medium | Low | **Ultra low** |
|---|---|---|---|---|
| **720p** | 1154 MB | 562 MB | 284 MB | **123 MB** |
| 480p | 569 MB | 292 MB | 149 MB | 69 MB |
| 320p | 344 MB | 179 MB | 95 MB | 47 MB |
| 144p | 141 MB | 76 MB | 46 MB | 29 MB |

So 720p30 on Ultra low is about **123 MB per hour**. On 16 GB of free space that is
roughly **130 hours**. At 144p Ultra low it is about 555 hours.

The app shows the MB/hour and the hours you have left, live, on the camera screen
and in Settings — so you can see the trade before you start filming.

Turning sound off in Advanced saves another 24–64 MB per hour.

---

## Three things iOS will not let this app do

These are limits of the platform, not of the code. Better you know now:

1. **It cannot film in the background.** iOS shuts the camera down the moment an
   app leaves the screen, and there is no entitlement that changes it for a normal
   app. The app has to stay open with the screen on. It closes the file cleanly
   when you switch away rather than losing it.
2. **The screen has to stay on**, which is the real battery cost on a phone this
   old — more than the recording. While filming, the moon button blacks the screen
   out and drops brightness to zero. Tap to wake it.
3. **It will get warm.** Hours of encoding on an A10 heats the phone and iOS will
   throttle it. Lower resolutions help a lot here.

---

## What it does to survive long recordings

- **Splits into 10-minute files.** One 8-hour file that dies with the app would be
  a disaster.
- **Writes each file in 4-second fragments.** If the battery dies or iOS kills the
  app mid-clip, you lose seconds, not the clip.
- **Stops at 300 MB free** instead of filling the phone completely.
- **HEVC by default** — same picture as H.264 in roughly half the space. The A10 in
  the iPhone 7 encodes it in hardware. There is an H.264 switch if a player refuses
  the files.
- **Long gaps between keyframes** at low quality (10 s on Ultra low), which is a
  large part of why the low numbers above are as low as they are.

Clips land in **Files › On My iPhone › LowBitCam**, as `.mov`. Plug into the PC and
grab them, or AirDrop. If you want `.mp4`, ffmpeg remuxes without re-encoding:

```bash
ffmpeg -i LowBitCam_2026-08-15_14-30-00.mov -c copy -tag:v hvc1 out.mp4
```

---

## Building it — you need a Mac, or GitHub's

iOS apps only compile on macOS with Xcode. Nothing on a Windows PC can produce the
binary. Two ways around that:

### Option A — no Mac, use GitHub Actions (free)

The repo already contains everything for this.

1. Make a GitHub repo and push this folder to it.
2. Actions tab → **Build unsigned IPA** → **Run workflow**.
3. When it finishes, download the `LowBitCam-unsigned-ipa` artifact.

That gives you an unsigned `.ipa`. Sign and install it from Windows with
**Sideloadly** or **AltStore Classic** (AltStore PAL is the EU/iOS 17.4+ one — not
this). Both sign with your own Apple ID.

> With a **free** Apple ID the app stops working after **7 days** and has to be
> re-signed. AltStore Classic re-signs automatically over WiFi while AltServer runs
> on the PC — which matters a lot for an app you want running every day. A paid
> developer account ($99/yr) makes it a year.

### Option B — a Mac

```bash
brew install xcodegen
xcodegen generate
open LowBitCam.xcodeproj
```

Set your team under Signing & Capabilities, plug in the iPhone 7, hit Run.

---

## The knobs worth turning

| What | Where |
|---|---|
| The bitrate table (all the numbers above) | `LowBitCam/Settings.swift` → `Encoder.videoKbps` |
| Frame rate — **30 → 15 roughly halves every file size** | `LowBitCam/Settings.swift` → `Encoder.frameRate` |
| File length (10 min) | `LowBitCam/CameraRecorder.swift` → `segmentSeconds` |
| Space kept free (300 MB) | `LowBitCam/CameraRecorder.swift` → `reserveBytes` |

---

## Not built, on purpose

- **Dashcam loop** (delete the oldest clip when full) — you did not ask for it and
  it deletes your footage on its own. Easy to add if you want it.
- **A clip browser** — the Files app already does this properly.
- **Photos library saving** — hundreds of clips make a mess of the library and cost
  double the space while importing.
