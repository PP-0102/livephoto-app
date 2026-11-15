# 实况下载 (LivePhotoApp)

A standalone native iOS app (Swift + SwiftUI) that downloads Xiaohongshu
Live Photos and saves them as real Live Photos to the iPhone Photos library
(long-press to play, LIVE badge). No third-party dependencies, no web page,
no Shortcut — a real app installed on the iPhone.

## What it does

1. Paste a Xiaohongshu note link
   (e.g. `https://www.xiaohongshu.com/explore/<id>?xsec_token=...`).
2. Tap **解析** (Parse). The app fetches the note page with a desktop Chrome
   User-Agent and no Referer header, reads `window.__INITIAL_STATE__`, and
   lists every Live Photo in the note (still-image thumbnail + size).
3. Tap **保存到相册** on one row, or **全部保存** for all of them. Each Live
   Photo is saved to Photos as a real Live Photo (`.photo` + `.pairedVideo`
   in one `PHAssetCreationRequest`).

## Project info

- **Bundle ID:** `com.hatoyo.livephoto`
- **Display name:** 实况下载
- **Deployment target:** iOS 15.0, iPhone portrait only
- **Language:** Swift 5, SwiftUI. Frameworks used: SwiftUI, Photos, Foundation, UIKit.
- **App icon:** a placeholder icon (coral gradient + Live Photo rings) is
  included in `Assets.xcassets/AppIcon.appiconset`. Replace it with a final
  design if desired.

## How it works (technical notes)

- The note page is fetched with `URLSession` using exactly these headers and
  **no Referer** (sending Referer makes Xiaohongshu redirect to `/login`):
  `User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36
  (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36`,
  `Accept: text/html,...`, `Accept-Language: en-us,en;q=0.5`,
  `Sec-Fetch-Mode: navigate`, `Accept-Encoding: gzip, deflate, br`.
  Cookies are kept across the redirect chain
  (xiaohongshu.com/explore -> rednote.com/discovery/item/&lt;id&gt;) via the
  shared `HTTPCookieStorage`.
- `window.__INITIAL_STATE__` is a JavaScript object literal, not JSON. It is
  sanitized before parsing: `new Set([...])` -> `[...]`, `new Map([])` -> `{}`,
  `new Date(...)` -> `null`, bare `undefined` -> `null`.
- Each Live Photo image has `livePhoto == true`, the still at
  `imageList[i].urlDefault` (WebP) and the motion clip at
  `imageList[i].stream.h264[0].masterUrl` (mp4, fallback `backupUrls[0]`).
  The stream object is keyed by codec (`{h264: [...]}`), not an array.
- The WebP still is decoded with `UIImage` and re-encoded as JPEG (quality
  0.92). The mp4 clip bytes are written to a `.mov` path. Both are saved in
  one `PHAssetCreationRequest` (`.photo` + `.pairedVideo`).
- The still/video CDN URLs in the note are `http://`; the app upgrades them
  to `https://` (and Info.plist carries an App Transport Security exception
  for `rednotecdn.com` as a fallback).

## Known limitation

The `xsec_token` inside a copied Xiaohongshu link **expires after a few
minutes**. Parse right after copying the link in the Xiaohongshu app. If
parsing fails with a login/expired-link error, copy the link again and retry.

## Build (unsigned .ipa for AltStore sideloading)

This project is built on a cloud Mac (Codemagic free tier) because it needs
Xcode. No code signing is required to compile; the IPA is built unsigned and
installed with AltStore.

### Option A — Codemagic (recommended, no Mac needed)

1. Push this folder to a Git repository (GitHub/GitLab/Bitbucket).
2. In Codemagic, add the repository and choose the **iOS App** workflow
   (or create a custom workflow from `codemagic.yaml` if one is added).
3. Xcode version: use a recent stable one (e.g. **Xcode 15.x or 16.x**).
   The project targets iOS 15.0 and Swift 5, so any Xcode 15+ works.
4. Build settings for an unsigned build:
   - Build command (or Codemagic "Xcode build" step):
     `xcodebuild -project LivePhotoApp.xcodeproj -scheme LivePhotoApp -configuration Release -destination "generic/platform=iOS" -archivePath build/LivePhotoApp.xcarchive archive CODE_SIGNING_ALLOWED=NO`
   - Then export an unsigned IPA from the archive, or use Codemagic's
     "Build unsigned IPA" option if available. The IPA is not signed with an
     Apple Developer certificate; AltStore signs it on the user's own device
     with their free Apple ID.
5. Download the `.ipa` artifact from Codemagic.

### Option B — Local Xcode (on a Mac)

```sh
cd ios-app
xcodebuild -project LivePhotoApp.xcodeproj -scheme LivePhotoApp \
  -configuration Release -destination "generic/platform=iOS" \
  -archivePath build/LivePhotoApp.xcarchive archive \
  CODE_SIGNING_ALLOWED=NO
```

Then export the `.ipa` from the archive (or use
`xcodebuild -exportArchive` with an export options plist that disables
signing), and sideload it with AltStore.

## Install with AltStore

1. Install AltStore on the iPhone (AltStore needs AltServer on a PC/Mac for
   the first install; see https://altstore.io).
2. Send the unsigned `.ipa` to the iPhone (AirDrop, Files, etc.).
3. In AltStore, tap **+** and pick the `.ipa`. AltStore signs it with the
   free Apple ID and installs it.
4. Free Apple IDs: the app must be refreshed every **7 days** (AltStore does
   this automatically when the iPhone is on the same Wi-Fi as the PC running
   AltServer). A paid Apple Developer account ($99/year) removes the 7-day
   limit and allows TestFlight/App Store distribution instead.

## Files

```
LivePhotoApp.xcodeproj/project.pbxproj   Xcode project
LivePhotoApp/LivePhotoApp.swift          @main app entry
LivePhotoApp/ContentView.swift           UI + view model (one screen)
LivePhotoApp/XiaohongshuResolver.swift   note fetch + __INITIAL_STATE__ parse
LivePhotoApp/LivePhotoSaver.swift        WebP->JPEG, mp4->mov, save to Photos
LivePhotoApp/Info.plist                 display name, photo permissions, ATS
LivePhotoApp/Assets.xcassets/           AppIcon + AccentColor
```

## Runtime uncertainty (not yet verified on a real iPhone)

The motion clip is saved by copying the mp4 bytes to a `.mov` path (the h264
stream is compatible with the QuickTime container). `PHAssetCreationRequest`
pairs `.photo` + `.pairedVideo` from one creation request into a Live Photo,
but whether Photos accepts the byte-copied `.mov` as the paired video has not
been verified on a real device yet. If the saved asset does not show the LIVE
badge, the fix is to remux the mp4 to a proper `.mov` with
`AVAssetExportSession` (passthrough preset, no re-encode) in
`LivePhotoSaver.swift` instead of the byte copy.
