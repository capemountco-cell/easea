# Easea for iOS and macOS

Film it messy, post it clean. Easea records or imports talking-to-camera videos and makes the
first cut automatically: it keeps the last good take of each line and removes false starts,
filler words and dead air. Then you refine the cut, add captions and text, and save to Photos.

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

Everything runs on the device. There are no server costs, and videos are never uploaded.

1. **Audio**: each clip's audio is extracted (`AudioAnalyzer.extractAudio`) and its loudness is
   measured in 10 ms windows.
2. **Transcript**: Apple's Speech framework transcribes on-device with word timings (`Transcriber`).
3. **Decisions** (`EaseaCore/AutoCutEngine`, pure Swift and unit-tested):
   - Filler words (um, uh, …) are dropped.
   - Words are grouped into phrases. If a phrase is followed shortly by another phrase that
     starts the same way, the earlier one is a failed take and is removed. This works across
     takes, so pausing the recording and saying the line again just works.
   - Restarts inside a phrase ("so today I'm, so today I'm going to…") are removed.
   - Pauses longer than the "longest pause kept" setting are cut. Edges are tightened with the
     loudness data.
   - Clips with no speech fall back to loudness, so b-roll with sound isn't lost.
4. **Captions** are built from the words, a few words at a time. They are anchored to source
   time, so they stay in sync when you trim or reorder clips.
5. **Render**: `VideoRenderer` builds an `AVComposition` (rotation, optional audio overlap with
   crossfades). On export, captions and text are burned in with Core Animation.

Transcripts are saved with the project, so **Re-cut** with new settings is instant.

## Code layout

```
apple/
  project.yml                 XcodeGen spec (one multiplatform target)
  Packages/EaseaCore/         Edit engine: models, AutoCutEngine, captions, timeline edits, tests
  Easea/
    App/                      App entry, tabs, deep-link router
    Models/Project.swift      Project, caption style, text overlays, export settings
    Services/                 Camera, transcription, audio analysis, pipeline, queue,
                              renderer, exporter, storage, notifications
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
- **Smarter cuts with an LLM.** Send the word-timed transcript (not the video) to a model such
  as Claude to flag rambling, tangents and the best take when the takes differ. Return the
  word ranges to drop, and feed them into the same `EditDecisionList`. Call the model from a
  backend so no API key ships in the app.
- **SpeechAnalyzer** (iOS 26 / macOS 26) for better long-form transcription. `Transcriber`
  only needs to return the same `[Word]`.
- Drag-to-trim handles and pinch-to-zoom on the timeline. Word-level highlight captions.
- App icon, onboarding, StoreKit subscription, and an App Store listing.
