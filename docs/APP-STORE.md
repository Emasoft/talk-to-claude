# Publishing **Talk to Claude** to the App Store

Everything you need to take this repo from source to a live App Store listing.
Work top‑to‑bottom; the checklist at the end is the short version.

> **Read this first — the #1 review risk.** Talk to Claude is a *companion app*:
> it does nothing on its own. It needs **your Mac** running `server/voice_server.py`
> on **your Tailscale network**, with a `claude` CLI in tmux. An App Store
> reviewer **cannot** reproduce that. Apps that can't be exercised by review
> are frequently rejected under **Guideline 2.1 (App Completeness)**. See
> [Review risks](#review-risks--how-to-clear-them) before you submit — this is
> the thing most likely to bounce the build, not anything technical in the app.

---

## App identity (already configured)

| Field | Value | Where it's set |
|-------|-------|----------------|
| Display name | **Talk to Claude** | `Info.plist` → `CFBundleDisplayName` |
| Bundle ID | `com.emasoft.talktoclaude` | `ios/project.rb` → `PRODUCT_BUNDLE_IDENTIFIER` |
| Marketing version | `1.0` | `ios/project.rb` → `MARKETING_VERSION` |
| Build number | `1` | `ios/project.rb` → `CURRENT_PROJECT_VERSION` |
| Team | `P2V8DD7FNW` (Emasoft / Gaetano Sabetta) | `ios/project.rb` → `DEVELOPMENT_TEAM` |
| Deployment target | iOS 17.0 | `ios/project.rb` |
| Devices | Universal (iPhone + iPad) | `TARGETED_DEVICE_FAMILY = 1,2` |

Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `ios/project.rb` for each
new submission, then re‑run `ruby ios/project.rb` (every App Store upload needs a
build number not previously used for that version).

---

## One‑time setup in App Store Connect

1. Sign in to [App Store Connect](https://appstoreconnect.apple.com) with the
   Apple ID that owns team `P2V8DD7FNW`.
2. **My Apps → ➕ → New App**
   - Platform: **iOS**
   - Name: **Talk to Claude** (must be globally unique on the Store; if taken,
     try "Talk to Claude — Voice" and set the in‑app display name separately)
   - Primary language: **English (U.S.)**
   - Bundle ID: select `com.emasoft.talktoclaude` (register it first under
     [Certificates, IDs & Profiles → Identifiers](https://developer.apple.com/account/resources/identifiers/list)
     if it isn't in the dropdown)
   - SKU: any stable string, e.g. `talktoclaude-001`
3. Create the bundle ID identifier if needed — no special capabilities are
   required (the app uses only mic + networking, which need no entitlement).

---

## Pricing — Free

In App Store Connect → your app → **Pricing and Availability**, set the price to
**Free**. Do **not** configure any in-app purchases or subscriptions — the app is
free with no paid tiers, now and always. Confirm the **In-App Purchases** section
is empty before submitting, and select **all territories** for worldwide
availability.

## Listing metadata (ready to paste)

All within Apple's character limits.

**Name** (≤30): `Talk to Claude`

**Subtitle** (≤30): `Dictate to Claude, hands-free`

**Promotional text** (≤170):
```
Speak instead of type. Talk to Claude streams your voice to your own Mac,
transcribes it locally with Whisper, and types it straight into your Claude CLI.
```

**Description** (≤4000):
```
Talk to Claude turns your iPhone or iPad into a hands-free microphone for a
Claude Code (claude CLI) session running on your Mac.

You speak; your Mac listens. Audio is streamed over your private Tailscale
network to a small server you run yourself, transcribed locally with OpenAI
Whisper, converted from speech into real keystrokes, and typed into the claude
session running in tmux. Nothing is sent to any third party — the whole path
stays inside your own network.

WHY
• Dictate long prompts without touching the keyboard.
• Drive a terminal coding session from across the room.
• An accessible way to work with Claude when typing is hard.

HOW IT WORKS
• Your Mac runs the open-source companion server (included in the project).
• Your iPhone/iPad connects to it over Tailscale (WireGuard-encrypted).
• Speech is transcribed on YOUR Mac with Whisper — not in the cloud.
• A rich spoken-command grammar turns words into symbols, newlines, code
  fences, bullet/numbered lists, capitals, spelling mode, and inline edits
  (delete / replace / undo / redo) — all before you "send".

PRIVACY
• No accounts. No analytics. No tracking. No ads.
• Your voice never leaves your own network — it goes only to the Mac you set up.
• The microphone is used solely to capture what you choose to dictate.

REQUIREMENTS
• A Mac on your Tailscale network running the included companion server
  (Python, free, open source).
• Tailscale installed on both devices.
• A claude CLI session running in tmux on that Mac.

This is a companion app for a setup you host yourself. It is not a standalone
chatbot and does not include Claude — it talks to the Claude CLI you already run.
```

**Keywords** (≤100, comma‑separated, no spaces after commas):
```
voice,dictation,claude,whisper,terminal,tmux,ssh,coding,hands-free,accessibility,tailscale,mac,developer
```

**Category:** Primary **Developer Tools**, Secondary **Productivity**
**Age rating:** 4+ (no objectionable content)
**Copyright:** `© 2026 Gaetano Sabetta`
**Support URL:** a public page you control (e.g. the GitHub repo's README). **Required** — fill before submitting.
**Marketing URL:** optional (repo or landing page).
**Privacy Policy URL:** **Required.** Host [`PRIVACY.md`](../PRIVACY.md) somewhere public (GitHub Pages, a Gist, or your site) and paste the URL.

---

## App Privacy "nutrition label" (Data Collection section)

In App Store Connect → your app → **App Privacy**, answer the questionnaire.
For Talk to Claude the honest answer is **"Data Not Collected"**:

- The developer collects **no** data.
- Microphone audio is captured and streamed **only to the user's own Mac** on
  their own network; it is not sent to the developer or any third party, and is
  not used for tracking.
- No analytics, no ads, no identifiers, no contact info, no location.

Select **"Data Not Collected"** for every category. (You still declare the
microphone *usage* via `NSMicrophoneUsageDescription`, which is separate from
data collection.)

---

## Screenshots (required to submit)

App Store Connect requires screenshots for at least:
- **6.7"/6.9" iPhone** (e.g. 1290 × 2796 portrait) — required
- **iPad 13"** (2064 × 2752 portrait) — required because the app is universal

Capture from the Simulator or a device (`⌘S` in Simulator, or the device
screenshot). Good shots: the main mic screen with a live transcript, the
command cheat‑sheet grid, the Settings page, and the Command self‑test summary.
PNG or JPEG, no alpha, no rounded corners (Apple adds them).

---

## App icon

Already wired in. The 1024×1024 marketing icon lives at
`ios/TalkToClaude/Assets.xcassets/AppIcon.appiconset/icon-1024.png` and is
generated reproducibly:

```bash
uv run --with pillow python ios/appicon.py
```

Replace it with your own art any time — keep the filename, keep it
**1024×1024, opaque, no alpha** (Apple rejects icons with an alpha channel).

---

## Archive & upload

### Option A — Xcode Organizer (simplest)

```bash
ruby ios/project.rb
open ios/TalkToClaude.xcodeproj
```

In Xcode: select **Any iOS Device (arm64)** as the destination →
**Product → Archive** → when the Organizer opens, **Distribute App →
App Store Connect → Upload**. Automatic signing (team `P2V8DD7FNW`) handles the
certificate + provisioning profile.

### Option B — command line

```bash
# 1. Archive
xcodebuild -project ios/TalkToClaude.xcodeproj -scheme TalkToClaude \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/TalkToClaude.xcarchive \
  -allowProvisioningUpdates archive

# 2. Export for the App Store (create ios/ExportOptions.plist first — see below)
xcodebuild -exportArchive \
  -archivePath build/TalkToClaude.xcarchive \
  -exportOptionsPlist ios/ExportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates

# 3. Upload (Apple ID + an app-specific password from appleid.apple.com)
xcrun altool --upload-app -f build/export/TalkToClaude.ipa -t ios \
  --apple-id YOUR_APPLE_ID --password "@keychain:AC_PASSWORD"
# (or use Apple's Transporter.app — drag the .ipa in)
```

Minimal `ios/ExportOptions.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>            <string>app-store-connect</string>
  <key>teamID</key>            <string>P2V8DD7FNW</string>
  <key>destination</key>       <string>export</string>
  <key>signingStyle</key>      <string>automatic</string>
</dict>
</plist>
```

After upload, the build appears in App Store Connect → **TestFlight** in
5–30 min (after processing). Use TestFlight to test on your own devices before
submitting for review.

---

## Review risks & how to clear them

1. **Reviewer can't run the Mac server (Guideline 2.1).** This is the big one.
   Mitigate by giving Apple everything they need in **App Review Information →
   Notes**:
   - Explain it's a companion app for a self‑hosted Mac server (open source).
   - Attach (or link) a **demo video** showing the full flow end‑to‑end.
   - Tell them what they'll see *without* a server: the UI, the command cheat
     sheet, and Settings all render; the mic button shows a clear
     "can't reach Mac" state. Make sure that failure state is graceful, not a
     crash or a dead screen.
   - **Strongly consider a built‑in offline demo mode** (a toggle that feeds a
     canned transcript so the UI is fully demonstrable without any server). This
     is the single most effective way to de‑risk review for a companion app.

2. **`NSAllowsArbitraryLoads = true` (ATS exception).** The app talks plaintext
   HTTP/WebSocket to the Mac (the transport is encrypted by Tailscale/WireGuard,
   but ATS doesn't know that). Apple may ask why. In the review notes, state:
   *"The app connects only to a user‑provided server on the user's private
   Tailscale (WireGuard) network; the link is end‑to‑end encrypted by Tailscale.
   Arbitrary loads are required because the destination is a user‑entered
   private IP, not a public TLS host."* Cleaner long‑term: scope the exception
   to `NSAllowsLocalNetworking` instead of `NSAllowsArbitraryLoads`.

3. **Unused `NSSpeechRecognitionUsageDescription`.** The app does **not** link
   Apple's Speech framework (transcription runs on the Mac via Whisper). Declaring
   a permission you don't use can draw review questions. Recommend **removing**
   `NSSpeechRecognitionUsageDescription` from `Info.plist` unless/until the app
   actually uses on‑device `SFSpeechRecognizer`.

4. **Local Network prompt.** First connection triggers the iOS local‑network
   permission dialog; `NSLocalNetworkUsageDescription` is already set. Fine —
   just be aware the reviewer will see it.

5. **Public default token.** The baked default bearer token
   (`mMfRuOWn9rGWskJOnI4HkrTwReVtblyg`) is committed and therefore public. That's
   acceptable as a first‑run default the user changes, but mention in the listing
   / onboarding that users must set their own token (already covered in the app's
   Settings and the README Security section).

---

## Pre‑submission checklist

```
□ Bundle ID com.emasoft.talktoclaude registered in Developer portal
□ App record created in App Store Connect (name available)
□ Price set to Free; NO in-app purchases / subscriptions; all territories selected
□ MARKETING_VERSION / CURRENT_PROJECT_VERSION bumped (unique build number)
□ App icon present (1024×1024, opaque)            ✅ done — ios/appicon.py
□ Listing metadata pasted (name/subtitle/desc/keywords/category/age)
□ Support URL + Privacy Policy URL filled in (both REQUIRED)
□ App Privacy = "Data Not Collected" for all categories
□ Screenshots uploaded (6.7" iPhone + 13" iPad minimum)
□ Release build archived & uploaded; appears in TestFlight
□ Tested via TestFlight on a real device
□ App Review notes written (companion-app explanation + demo video + ATS note)
□ (Recommended) offline demo mode OR demo video so review can exercise the app
□ (Recommended) removed unused NSSpeechRecognitionUsageDescription
□ Submit for Review
```
