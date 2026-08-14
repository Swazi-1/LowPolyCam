# Getting LowBitCam onto a freshly flashed iPhone 7

No Mac needed. GitHub's build machines compile it, your PC signs it, the phone runs it.

Rough time: 45–60 minutes the first time, mostly downloads and waiting.

---

## Before you start

**Expect the first build to fail.** This code has never been through a compiler.
Step 1 will probably come back with Swift errors. That is normal — copy the log out
and they get fixed, then you push again. Budget for one or two rounds.

**About the Apple ID.** Signing needs an Apple ID, and you type it into a
third-party tool. A free throwaway Apple ID works fine and keeps your main one out
of it. The ID you sign with does **not** have to be the one signed in on the phone.

---

## Step 1 — Build the .ipa on GitHub

1. Go to **github.com** → **New repository**. Name it `LowBitCam`.
   Do **not** tick "Add a README" — the folder already has one.
   - Public repo = unlimited free Mac build minutes.
   - Private repo works too, but Mac minutes count 10x against the free 2000/month
     (so ~40 builds a month). Either is fine.

2. Push the folder. In PowerShell:

```powershell
cd "C:\Users\swazi\Documents\LowBitCam"; git init; git add .; git commit -m "LowBitCam"; git branch -M main; git remote add origin https://github.com/YOURNAME/LowBitCam.git; git push -u origin main
```

   A browser window will pop up to log into GitHub the first time.

3. The push starts the build by itself. Open the **Actions** tab and watch
   **Build unsigned IPA**. Takes about 5 minutes.

   - **Green tick** → carry on to step 4.
   - **Red X** → click the run, open the `Build (no signing)` step, copy out the
     lines with `error:` in them. That is what needs fixing.

4. Open the finished run, scroll to **Artifacts** at the bottom, download
   **LowBitCam-unsigned-ipa**. It arrives as a `.zip` — **unzip it** to get the
   actual `LowBitCam-unsigned.ipa`. Put it somewhere easy, like your Desktop.

---

## Step 2 — Get the phone ready

1. Finish the setup assistant all the way to the home screen. Sideloading cannot
   happen while the phone is still in setup.
2. Connect it to **Wi-Fi**. Needed later — the phone phones home to Apple to verify
   the signature, and without internet you get "Unable to Verify App".
3. Set a passcode if you want one, and know it.
4. Check free space: **Settings → General → iPhone Storage**.
5. Plug into the PC with a Lightning cable — a **data** cable, not a charge-only one.
6. Unlock the phone. Tap **Trust This Computer**, enter the passcode.

---

## Step 3 — Get the PC ready

Install both of these from **apple.com**, not from the Microsoft Store. The Store
versions are sandboxed and the signing tools cannot talk to them. This is the single
most common reason people get stuck.

1. **iTunes** — apple.com/itunes → the Windows download link.
2. **iCloud for Windows** — from Apple's site, same deal.

Reboot after installing. Open iTunes once and confirm it sees the iPhone.

---

## Step 4 — Install it

Two ways. Pick one.

### 4A — AltStore Classic (recommended: renews itself)

A free Apple ID signature dies after 7 days. AltStore renews it over Wi-Fi on its
own, which matters for an app you want running daily.

Make sure it is **AltStore Classic**. AltStore PAL is the EU/iOS 17.4+ one and will
not work here.

1. **altstore.io** → download AltStore Classic for Windows → run the installer.
2. Start **AltServer**. It sits in the system tray, bottom-right — you may have to
   click the `^` arrow to see it.
3. Phone plugged in and unlocked.
4. Right-click the AltServer tray icon → **Install AltStore** → pick your iPhone.
5. Enter the Apple ID and password. Enter the 2FA code if it asks.
6. AltStore appears on the phone's home screen.
7. On the phone: **Settings → General → VPN & Device Management** → tap the entry
   under *Developer App* → **Trust**.
8. Open **AltStore** on the phone once, so it settles.
9. Now install ours: hold **Shift** and click the AltServer tray icon → a
   **Sideload .ipa** option appears → pick the iPhone → choose
   `LowBitCam-unsigned.ipa`.

   *Or:* put the `.ipa` into the phone's Files app, then in AltStore go
   **My Apps → +** (top left) → pick the file.

10. **LowBitCam** lands on the home screen.

### 4B — Sideloadly (quicker, but manual every 7 days)

1. **sideloadly.io** → download → install.
2. Phone plugged in and unlocked. Sideloadly should show it at the top.
3. Drag `LowBitCam-unsigned.ipa` onto the Sideloadly window.
4. Type in the Apple ID. Click **Start**. Enter the password and 2FA code when asked.
5. Wait for "Done".
6. On the phone: **Settings → General → VPN & Device Management** → tap the entry
   under *Developer App* → **Trust**.

---

## Step 5 — First run

1. Tap **LowBitCam**. If it says "Untrusted Developer", you missed the Trust step
   above. If it says "Unable to Verify App", the phone is not on the internet.
2. Allow **camera**.
3. Allow **microphone** (or say no and switch sound off in the app's settings).
4. Tap the **gear** → Resolution **720p**, Quality **Ultra low**.
5. Check the top-right: it should read about **123 MB / hour** and show how many
   hours fit in your free space.
6. Tap the red button. Film for a minute. Tap it again.
7. Open the **Files** app → **On My iPhone → LowBitCam**. The clip should be there.
   Play it. Check it is the right way up and the sound works.

---

## Step 6 — Keeping it alive

A free Apple ID signature lasts **7 days**. After that the app refuses to open
until it is re-signed. Nothing is lost — your recordings stay put.

- **AltStore:** leave AltServer running on the PC. When the phone is on the same
  Wi-Fi it renews on its own. To force it: open AltStore → **My Apps** →
  **Refresh All**. Do this at least once a week.
- **Sideloadly:** repeat step 4B every 7 days.
- A paid Apple Developer account ($99/year) stretches this to a year.

**Free account limits:** 3 sideloaded apps at a time (AltStore itself counts as
one). This app needs no special entitlements, so nothing else here trips the free
account up.

---

## When it goes wrong

| What you see | What it means |
|---|---|
| Actions run is red | Compile errors. Open `Build (no signing)`, copy the `error:` lines. |
| Tool cannot see the iPhone | iTunes/iCloud came from the Microsoft Store. Uninstall, reinstall from apple.com, reboot. |
| "Trust This Computer" never appears | Charge-only cable. Use a data cable. |
| "Untrusted Developer" | Step 4, the Trust step in VPN & Device Management. |
| "Unable to Verify App" | Phone has no internet. Get it on Wi-Fi and reopen the app. |
| App just closes after a week | Signature expired. Refresh in AltStore, or redo Sideloadly. |
| Video sideways | The rotation metadata is wrong — a one-line fix in `CameraRecorder.swift`, `transform(forInterface:)`. |
| Recording stops on its own | Expected if you left the app. iOS shuts the camera down in the background. |
