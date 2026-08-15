<p align="center">
  <img src="LowPolyCam/Assets.xcassets/AppIcon.appiconset/icon-180.png" width="120" alt="LowPolyCam icon">
</p>

# LowPolyCam

A camera app built around one idea: **film for as long as you want without filling
the phone**. Open it, you're in the camera. Tap the gear, pick a resolution, a
quality, a frame rate. Tap the red button, it films - one continuous file, however
long that turns out to be. That's the whole app.

Built and tested end-to-end on an **iPhone 7, iOS 15.8.x**.

---

## The settings

**Resolution** — 1080p · 720p · 480p · 320p · 144p
**Frame rate** — 24 · 30 · 60 fps, matched against what the active camera can
actually do
**Quality** — High · Medium · Low · Ultra low
**Video format** — HEVC (smaller files) or H.264 (plays everywhere)
**Save to** — Photos or Files

The sensor only runs bigger than 720p when 1080p is actually selected — every
smaller export is produced by downscaling a 720p capture, so picking a low tier
doesn't just shrink the file, it keeps the camera itself cheap to run. Frame rate is
applied by searching the device's own capture formats for one that genuinely
supports the chosen rate and locking to it directly, rather than trusting a generic
preset to guess right.

**The front camera can do less than the back one** — on the iPhone 7 it tops out at
30 fps and has no 1080p mode. Settings shows a banner when you're on the front
camera and greys out whatever it can't do, with a lock icon, rather than letting you
pick something that silently fails. Flipping to the front camera while an
unsupported setting is selected switches it automatically and tells you why.

### What an hour costs (HEVC, 30 fps, with sound)

| | High | Medium | Low | **Ultra low** |
|---|---|---|---|---|
| 1080p | 2054 MB | 1012 MB | 464 MB | 191 MB |
| 720p | 1154 MB | 562 MB | 284 MB | **123 MB** |
| 480p | 569 MB | 292 MB | 149 MB | 69 MB |
| 320p | 344 MB | 179 MB | 95 MB | 47 MB |
| 144p | 141 MB | 76 MB | 46 MB | 29 MB |

So 720p on Ultra low is about **123 MB per hour** — roughly 130 hours on 16 GB free.
144p Ultra low stretches that past 500 hours. Switching to 60 fps costs roughly 60%
more than the numbers above (each frame gets a smaller slice of the same picture
quality otherwise); 24 fps costs about 15% less.

The app shows the live MB/hour and hours-remaining on the camera screen and in
Settings, so you see the trade before you start filming, not after.

---

## Three things iOS will not let this app do

Limits of the platform, not the code:

1. **It cannot film in the background.** iOS shuts the camera down the instant an
   app leaves the screen - there's no entitlement for a normal app that changes
   this. The screen has to stay on. The app closes the file cleanly the moment it
   happens rather than losing anything.
2. **The screen has to stay on**, which is the real battery cost on a phone this
   old, more than the encoding itself. While filming, the moon button blacks the
   screen out and drops brightness to zero. Tap to wake it.
3. **It will get warm.** Sustained encoding on an A10 heats the phone and iOS will
   throttle it eventually. Lower resolutions and frame rates help.

---

## Surviving long recordings

- **One file, not chopped into pieces.** A recording is a single continuous file
  for however long it runs, the same way the built-in Camera app behaves.
- **Survives a dead battery.** The file is written a few seconds at a time
  (fragmented), so if the phone dies or iOS kills the app mid-recording, everything
  up to that point is still a valid, playable video - not a corrupted one. The next
  time the app opens, it finds the interrupted file and delivers it to Photos or
  Files automatically, with a "Recovered the recording that was cut short" notice.
  Tested by freezing a phone mid-recording until it powered off.
- **Stops at 300 MB free**, checked continuously through the whole recording, not
  just at the start - instead of running the phone completely out of space.
- **HEVC by default** — the same picture as H.264 in roughly half the space,
  encoded in hardware on the A10. Switch to H.264 in Settings if a particular player
  refuses HEVC files.
- **Longer gaps between keyframes** at lower quality tiers (up to 10s on Ultra low),
  which does a lot of the work behind the low numbers above.

Clips saved to **Files** land in **On My iPhone › LowPolyCam** as `.mov`. Want
`.mp4`? ffmpeg remuxes without re-encoding:

```bash
ffmpeg -i LowPolyCam_2026-08-15_14-30-00.mov -c copy -tag:v hvc1 out.mp4
```

---

## Building it — you need a Mac, or GitHub's

iOS apps only compile on macOS with Xcode - nothing on Windows or Linux can produce
the binary. Two ways around that:

### Option A — no Mac, GitHub Actions builds it for free

The repo already contains everything needed for this.

1. Push this folder to a GitHub repo (public repos get unlimited free macOS build
   minutes; private ones burn quota 10x faster on macOS runners).
2. **Actions** tab → **Build unsigned IPA** → **Run workflow** (or just push - it
   triggers automatically).
3. When it finishes, open the run → **Artifacts** → download
   **LowPolyCam-unsigned-ipa**, then unzip it to get `LowPolyCam-unsigned.ipa`.

That's an unsigned `.ipa`. Sign and install it from Windows with **Sideloadly** or
**AltStore Classic** (AltStore PAL is the EU/iOS 17.4+ one - not this).

> A **free** Apple ID signature expires after **7 days** and needs re-signing.
> AltStore Classic does this automatically over Wi-Fi as long as AltServer is
> running on the PC - worth it for an app you want running daily. A paid developer
> account ($99/yr) stretches that to a year.

### Option B — you have a Mac

```bash
brew install xcodegen
xcodegen generate
open LowPolyCam.xcodeproj
```

Set your team under Signing & Capabilities, plug in the phone, hit Run.

---

## The knobs worth turning

| What | Where |
|---|---|
| The bitrate table (all the numbers above) | `LowPolyCam/Settings.swift` → `Encoder.videoKbps` |
| How much extra a higher frame rate costs | `LowPolyCam/Settings.swift` → `Encoder.fpsMultiplier` |
| Space kept free (300 MB) | `LowPolyCam/CameraRecorder.swift` → `reserveBytes` |
| How often the file is flushed to disk (4s) | `LowPolyCam/CameraRecorder.swift` → `fragmentSeconds` - shorter loses less to a sudden power-off, at the cost of a bit more disk activity |
| The app's colour palette | `LowPolyCam/Theme.swift` |

---

## Not built, on purpose

- **Dashcam loop** (delete the oldest footage when full) — nobody asked for it, and
  it would delete your footage on its own. Straightforward to add if wanted.
- **A clip browser** — the Files and Photos apps already do this properly.
