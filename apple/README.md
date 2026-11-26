# Easea for iOS and macOS

Film it messy, post it clean. Easea records or imports talking-to-camera videos and makes the
first cut automatically with Claude: it keeps the last good take of each line and removes false starts,
filler, rambling and dead air. Then you refine the cut, add captions and text, and save to Photos.

One SwiftUI codebase runs on iPhone, iPad and Mac (iOS 17+, macOS 14+).

## Run it

You need a Mac with Xcode 16 or later.

```sh
brew install xcodegen
cd apple
xcodegen generate        # creates Easea.xcodeproj from project.yml
open Easea.xcodeproj
```

In Xcode, choose your team under **Signing & Capabilities**, pick an iPhone or "My Mac" and run.
Use a real device for recording; the simulator has no camera, but importing works there.

Run the engine's unit tests without the app:

```sh
cd apple/Packages/EaseaCore && swift test
```

## How the automatic cut works

Claude makes the editing decisions. Everything else happens on the device, and **video never
leaves the phone**.

1. **Audio** (on device): each clip's audio is extracted (`AudioAnalyzer`) and its loudness is
   measured in 10 ms windows.
2. **Transcript** (on device): Apple's Speech framework transcribes the audio with word timings
   (`Transcriber`).
3. **Claude decides what to cut** (`ClaudeEditor` → `POST /api/cut-plan` in the Lovable web app,
   [`src/lib/cut-planner/`](../src/lib/cut-planner)): the word-timed transcript goes to the web app, which asks Claude (`claude-opus-5-5`) for a cut plan.
   The plan marks:
   - retakes (the last good take of each line is kept, even across clips);
   - false starts, stumbles and off-camera talk ("okay, one more time");
   - filler words and rambling, depending on the Pace setting (Tight / Natural / Relaxed).

   It also suggests a title and fixes misheard words, such as brand names, in the captions.
   The Anthropic API key lives only in Lovable's secrets.
4. **Clips** (`EaseaCore/AutoCutEngine`): the kept words become clips. Pauses are tightened
   using the loudness data. Clips with no speech fall back to loudness, so b-roll with sound
   isn't lost.
5. **Captions** are built from the corrected words. They are anchored to source time, so they
   stay in sync when you trim or reorder clips.
6. **Render**: `VideoRenderer` builds an `AVComposition` (rotation, optional audio overlap with
   crossfades). On export, captions and text are burned in with Core Animation.

**Fallback:** if Claude is turned off, not set up, or unreachable, the on-device rule-based
editor (retakes by matching phrases, fillers, pauses) makes the cut, and the cut is marked
"Edited by On-device". Transcripts and Claude's plan are saved with the project:
"Rebuild with current settings" is instant, and "Ask Claude to re-edit" sends only the
transcript again.

### Set up Claude

1. In Lovable, add the secret `ANTHROPIC_API_KEY` (`CLAUDE_API_KEY` also works). Optionally add
   `EASEA_APP_TOKEN` (any long random string) so only your app can call the endpoint.
2. Merge this branch into `main` and publish in Lovable, so `/api/cut-plan` goes live.
3. In the app, open **You → AI editor** and enter your published Lovable URL (and the token,
   if you set one). Or set `AppConfig` in `Easea/Services/ClaudeEditor.swift` so builds ship
   with them.

## Get an IPA for sideloading

The **iOS build** GitHub Actions workflow (`.github/workflows/ios.yml`) builds an unsigned
`Easea.ipa` on a macOS runner every time `apple/` changes. Download it from the run's
**Artifacts** section, then open it in Sideloadly, which signs it with your Apple ID.

## Code layout

```
apple/
  project.yml                 XcodeGen spec (one multiplatform target)
  Packages/EaseaCore/         Edit engine: models, Claude cut plans, AutoCutEngine, captions, timeline edits, tests
  Easea/
    App/                      App entry, tabs, deep-link router
    Models/Project.swift      Project, caption style, text overlays, export settings
    Services/                 Camera, transcription, audio analysis, Claude client, pipeline,
                              queue, renderer, exporter, storage, notifications
    Views/Create/             Camera with 60s/3m/10m limits and takes; import; batch of up to 10
    Views/Cuts/               Library by folder, cutting progress, "time saved" card, multi-save
    Views/Editor/             Preview, timeline (split/trim/delete/reorder/undo), captions, text, export
```

## Status

This is a first working version. It hasn't been compiled yet: the code was written in a Linux
environment with no Swift toolchain. Expect a short round of compiler fixes on the first build.

## Roadmap

- **Keep cutting after the app closes.** iOS currently gives the app a short background window
  (`beginBackgroundTask`). For long batches, either adopt `BGContinuedProcessingTask` (iOS 26)
  or upload to a server that does the cut and sends a push notification. With a server, the
  device can be locked for the whole batch.
- **Per-video notes for Claude** ("keep the joke at the end"). `/api/cut-plan` already accepts an
  `instructions` field.
- **User accounts and App Attest** on `/api/cut-plan`, before a public launch.
- **SpeechAnalyzer** (iOS 26 / macOS 26) for better long-form transcription. `Transcriber`
  only needs to return the same `[Word]`.
- Drag-to-trim handles and pinch-to-zoom on the timeline. Word-level highlight captions.
- App icon, onboarding, StoreKit subscription, and an App Store listing.
