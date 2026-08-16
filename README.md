<p align="center"> <img src="LowPolyCam/Assets.xcassets/AppIcon.appiconset/icon-180.png" width="120" alt="LowPolyCam icon"> </p>

A simple camera app made for long recordings without filling your iPhone.

Open the app, choose your settings, and tap record. One continuous video, as long as you need.

Built and tested on iPhone 7 with iOS 15.8.x.

Settings
Resolution: 1080p, 720p, 480p, 320p, 144p
Frame rate: 24, 30, 60 fps
Quality: High, Medium, Low, Ultra Low
Format: HEVC or H.264
Save to: Photos or Files

The app uses the camera's real supported formats instead of guessing.

The front camera has fewer options on iPhone 7. Unsupported settings are disabled automatically.

Storage
Approximate space per hour
Resolution	High	Medium	Low	Ultra Low
1080p	2054 MB	1012 MB	464 MB	191 MB
720p	1154 MB	562 MB	284 MB	123 MB
480p	569 MB	292 MB	149 MB	69 MB
320p	344 MB	179 MB	95 MB	47 MB
144p	141 MB	76 MB	46 MB	29 MB

720p Ultra Low: about 123 MB/hour.

That is roughly 130 hours with 16 GB free.

The app also shows the estimated MB/hour and remaining recording time.

iOS limitations

Some things are controlled by iOS:

Recording stops when the app leaves the screen.
The screen must stay on while recording.
Long recordings can make the iPhone warm and may cause throttling.

The moon button turns the screen brightness down while recording.

Long recordings
Recordings are saved as one continuous file.
The file is written in small fragments, so most of a recording can be recovered after a crash or power loss.
The app automatically looks for interrupted recordings when it starts.
Recording stops when less than 300 MB of storage is available.
HEVC is used by default to save space.
Lower quality settings use longer keyframe intervals to reduce file size.

Files saved through Files are stored in:

On My iPhone › LowPolyCam

Building

You need macOS + Xcode, or you can use GitHub Actions.

GitHub Actions
Push the project to GitHub.
Open Actions.
Run Build unsigned IPA.
Download LowPolyCam-unsigned-ipa.

You can then sign the IPA on Windows with Sideloadly or AltStore Classic.

A free Apple ID signature lasts 7 days. A paid developer account lasts 1 year.

Mac
brew install xcodegen
xcodegen generate
open LowPolyCam.xcodeproj

Then select your Apple Developer Team and build the app.

Main settings in the code
Setting	File
Video bitrates	Settings.swift
FPS multiplier	Settings.swift
300 MB storage limit	CameraRecorder.swift
4-second file fragments	CameraRecorder.swift
App colors	Theme.swift
Not included
Dashcam loop recording — footage is never deleted automatically.
Clip browser — Photos and Files already handle this.
