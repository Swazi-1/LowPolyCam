# LowPolyCam README

<p align="center">
  <img src="LowPolyCam/Assets.xcassets/AppIcon.appiconset/icon-180.png" width="120" alt="LowPolyCam icon">
</p>

<h1 align="center">LowPolyCam</h1>

<p align="center">
  <b>A lightweight iOS camera app built for long recordings, low storage use, and flexible shooting.</b><br>
  Built and tested on iPhone 7 with iOS 15.8.x and newer iPhones.
</p>

---

## 📸 Overview

**LowPolyCam** is built for recording and capturing photos without quickly filling your iPhone.

Choose your resolution, quality, frame rate, format, and camera mode, then start shooting.

Simple, lightweight, and designed for long sessions.

---

## ✨ Features

### 📸 Photo Mode

**Dedicated Photo Mode** — Quickly switch from recording to capturing photos.<br>
**Unmirrored Selfies** — Save front-camera selfies without mirroring.<br>
**Flash Control** — Choose whether the flash fires when capturing photos.<br>
**Tap to Focus** — Quickly focus by tapping anywhere on the viewfinder.<br>
**Camera Zoom** — Use the available zoom levels supported by your iPhone.<br>
**Save to Photos** — Photos are saved directly to your camera roll.

### 🎥 Camera & Recording

**Resolutions:** 4K, 1080p, 720p, 480p, 320p, 144p<br>
**Frame Rates:** 24, 30, 60 fps<br>
**Modes:** Video, Photo, and Slo-Mo<br>
**Quality:** High, Medium, Low, Data Saver<br>
**Codecs:** HEVC or H.264<br>
**Zoom:** 0.5×, 1×, 2×, 5×<br>
**File Splitting:** 1 hour, 4 hours, or one continuous file<br>
**Save To:** Photos or Files<br>
**Live Stats:** Optional live dropped-frame and Mbps information while recording<br>
**HD Live Preview:** The live preview stays high quality even when recording at 720p or lower<br>
**True Low Resolutions:** 144p, 320p, and 480p settings now record at their actual selected resolutions

### 🐌 Slow-Mo

**High-FPS Recording** — Supports the slow-motion frame rates available on your iPhone.<br>
**240 FPS Support** — Optimized for much more accurate 240 FPS recording on supported hardware.<br>
**Reliable High-FPS Capture** — Improved frame handling and recording stability for Slow-Mo.

### 🛠 Pro Tools

**Exposure** — −2.0 to +2.0 EV<br>
**White Balance** — Auto, Sunny, Warm, Cool, Golden<br>
**Horizon Level** — Gyroscope-based level with haptic feedback<br>
**Hardware Shutter** — Volume buttons can start and stop recording<br>
**Double-Tap Flip** — Double-tap the viewfinder to switch cameras<br>
**Haptic Feedback** — Toggle haptic feedback on or off

### 📊 Live Recording Stats

Enable **Live Stats** in Settings to display useful recording information inside the recording info box:

* Dropped frames
* Live Mbps / bitrate

### 🔋 Battery & Performance

**Auto-Dim** — Automatically turns the screen black after 10 seconds while filming.<br>
**Moon Button** — Manually turns the screen black while recording.<br>
**Longevity Mode** — Reduces unnecessary power and processing use during long sessions.<br>
**Performance Profile** — Adjusts performance based on device hardware, thermal state, and Longevity Mode.<br>
**Low-Space Protection** — Stops recording below **300 MB** of free space.

### 🛡 Recovery

**4-Second Fragments** — Recordings are saved in small fragments to reduce data loss.<br>
**Automatic Recovery** — Interrupted recordings are detected and recovered when the app opens.<br>
**Camera Recovery** — Camera session problems can be detected and recovered when possible.

### 🎨 Themes

**Dial Lavender** — Soft lavender interface.<br>
**Button Gold** — Warm gold interface.<br>
**Record Red** — Classic recording-focused red interface.<br>
**Coral** — New coral-colored interface.

The entire interface adapts to the selected theme.

---

## ⚙️ Settings

LowPolyCam uses **mode-specific settings** so only settings that actually affect the current mode are shown.

**Photo Mode** → Photo settings only<br>
**Video Mode** → Video settings only<br>
**Slow-Mo** → Slow-Mo settings only

Other improvements include:

**Quick Presets** — Access presets from their own dedicated Settings menu.<br>
**Settings Info Box** — Quickly see selected settings at a glance.<br>
**Good to Know** — Useful information without taking up much screen space.<br>
**Cleaner Settings System** — Settings use a centralized storage system for safer saving and loading.

---

## 🎬 Recorded Clips

**Recorded Clips** — Browse saved recordings inside the app.<br>
**Delete All** — Remove all recorded clips at once.<br>
**Delete Older Than 3 Days** — Remove clips that are more than 3 days old.<br>
**Improved Clip Handling** — Better handling of recorded and recovered video segments.

---

## 💾 Storage

Approximate storage usage with **HEVC at 30 fps**:

| Resolution |       High |    Medium |       Low |    Data Saver |
| ---------- | ---------: | --------: | --------: | ------------: |
| **4K**     | ~10.8 GB/h | ~5.4 GB/h | ~2.7 GB/h |     ~810 MB/h |
| **1080p**  |  ~3.6 GB/h | ~1.8 GB/h | ~900 MB/h |     ~180 MB/h |
| **720p**   |  ~1.8 GB/h | ~900 MB/h | ~450 MB/h | **~123 MB/h** |
| **480p**   |  ~900 MB/h | ~450 MB/h | ~225 MB/h |      ~69 MB/h |
| **320p**   |  ~450 MB/h | ~225 MB/h | ~115 MB/h |      ~47 MB/h |
| **144p**   |  ~180 MB/h |  ~90 MB/h |  ~45 MB/h |      ~29 MB/h |

> 💡 **720p Data Saver uses about 123 MB/hour**, allowing roughly **130 hours** of recording with 16 GB of free storage.

Actual file sizes can vary depending on frame rate, scene complexity, codec, and bitrate settings.

---

## 📱 iOS Notes

**Screen Must Stay On** — iOS does not allow normal apps to record from the background.<br>
**Auto-Dim / Moon Button** — Use either option to turn the screen black while recording.<br>
**Older iPhones** — Some resolutions, frame rates, camera lenses, or features may not be available.<br>
**Automatic Compatibility** — Unsupported options are automatically disabled.<br>
**iOS 15 Support** — LowPolyCam is designed to remain compatible with iOS 15 and newer supported devices.

---

## 🔨 Build & Sideload

### GitHub Actions — No Mac Required

1. Push or fork the repository.
2. Open **Actions**.
3. Select **Build unsigned IPA**.
4. Click **Run workflow**.
5. Download the `LowPolyCam-unsigned-ipa` artifact.
6. Sideload the IPA using **AltStore, Sideloadly,** or **TrollStore**.

### macOS + Xcode

Install XcodeGen:

```bash
brew install xcodegen
xcodegen generate
open LowPolyCam.xcodeproj
```

Then select your Apple Developer Team in Xcode and build the app.

---

## 📱 Tested On

**iPhone 7 — iOS 15.8.x**

Also designed to adapt to newer iPhones and their available camera hardware.

---

## 🆕 Latest Release

### LowPolyCam v3.2.0

v3.2.0 is a major **foundation and performance update** focused on:

* More accurate high-FPS recording
* Major 240 FPS Slow-Mo improvements
* Live Recording Stats
* True 144p / 320p / 480p recording
* HD live preview at all recording resolutions
* Better Pro Tools
* Improved Longevity Mode
* Better Settings
* Cleaner and more modular code
* Lower unnecessary processing and improved performance
* Many camera, recording, and UI fixes
