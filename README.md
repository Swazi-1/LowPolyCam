# LowPolyCam

SwiftUI camera app targeting iOS 26 and newer (including iOS 27).

## Build from GitHub Actions

Open **Actions**, select **Build iOS IPA**, choose **Run workflow**, and download
the `LowPolyCam-unsigned-ipa` artifact when the run finishes.

The generated IPA is unsigned. It must be signed with your own Apple developer
identity or a sideloading tool before it can be installed on an iPhone.

## Open locally on macOS

Install XcodeGen, then run:

```sh
brew install xcodegen
xcodegen generate
open LowPolyCam.xcodeproj
```
