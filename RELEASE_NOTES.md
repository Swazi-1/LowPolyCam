# LowPolyCam 1.0.0

Tested on an iPhone 7, iOS 15.8.x — including a full record → freeze the phone
until it powers off → recover the clip on next launch test, which came back clean.

## New

- **App renamed to LowPolyCam**, with a new icon and a matching visual theme
  throughout — the record button, camera flip, torch, and gear icons are now
  faceted lens shapes in the icon's slate/mint/violet/amber palette instead of
  plain circles.
- **1080p** added alongside 720p/480p/320p/144p.
- **Selectable frame rate** — 24, 30, or 60 fps, matched against a capture format
  the camera actually supports rather than assumed.
- **HEVC vs H.264** is now a proper choice in Settings instead of a toggle.
- **Save to Photos or Files**, your choice, remembered between launches.
- **One continuous recording**, however long it runs — no more automatic 10-minute
  file splits.
- **Survives a dead battery.** If the phone loses power mid-recording, everything
  filmed up to that point is recovered automatically the next time the app opens,
  and delivered to Photos/Files with a notice. Confirmed working with an actual
  freeze-to-shutoff test.
- **The front camera's real limits are respected.** On this phone it tops out at
  30 fps with no 1080p mode - Settings now greys those options out with a lock icon
  and explains why, and switching to the front camera auto-corrects anything it
  can't do instead of silently failing.
- A live dropped-frame counter appears next to the recording timer if any frames
  are ever actually lost, instead of that only being visible after the fact.

## Fixed

- **Selfie video was sometimes upside down.** An earlier orientation fix was
  itself the bug - it applied a rotation based on a value that hadn't settled yet,
  so it worked inconsistently. Removed the hand-rolled rotation entirely and let
  the system's own orientation handling do it, which is also just more correct.
- **Selfie video mismatched the mirrored preview.** The recording now mirrors on
  the front camera to match what you were looking at while filming.
- **Stopping a selfie recording sometimes took several taps.** A backlog of
  frames could build up ahead of the "close the file" instruction; stop now cuts
  the line instead of waiting behind it.
- **The record button's tap target was much smaller than it looked** - only the
  visible ring and small stop square actually registered a tap, not the button's
  full circle. Fixed without changing how the button looks.
- **The app switcher sometimes showed an old icon.** All required icon sizes are
  now shipped explicitly instead of relying on Xcode to generate them.
- **An instant crash on hitting record**, caused by handing the video encoder a
  settings dictionary with a key it didn't actually support.
- **Screen brightness could get stuck at zero** if you left the app while its
  screen-dimming mode was active.

## Under the hood

- Frame delivery no longer discards a frame just because it arrived a few
  milliseconds late, and runs at a higher scheduling priority - together these
  close most of the gap between this app's real frame rate and the built-in
  Camera app's at demanding settings like 1080p60.
- The video-settings crash from an earlier build led to a full audit of every
  place a settings dictionary is handed to AVFoundation; each is now validated
  before use instead of assumed correct.
