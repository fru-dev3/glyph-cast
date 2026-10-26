# Glyph Cast

**Screen videos, cleaned up.** Record your screen on a Mac and get back a clean MP4: the voice
cleaned and leveled, the ums and dead air cut, the screen framed on a background with zooms where
you click, an intro and outro attached if you want them. Screen recording and framing plus
transcript editing, in one free Mac app.

Part of the [Glyph family](https://glyph.fru.dev) by [fru.dev](https://fru.dev): Glyph Studio,
Glyph Jot, Glyph Cast, Glyph Code. Formerly called Capture.

## Install

1. Download [Glyph-Cast.dmg](https://github.com/fru-dev3/glyph-cast/releases/latest/download/Glyph-Cast.dmg)
   and drag Glyph Cast to Applications. It is signed and notarized by Apple.
2. Install the two tools it runs, once: `brew install ffmpeg whisper-cpp`
3. Open it. macOS asks once for Screen Recording and the Microphone. If Glyph Cast is missing
   from System Settings > Privacy & Security > Screen & System Audio Recording, click + there, add
   Glyph Cast, switch it on and click Reopen in the app (it shows a banner with both steps).

The first recording downloads the models (about 180 MB) to
`~/Library/Application Support/Capture/models`: whisper base.en, the Silero voice detector,
DeepFilterNet's `deep-filter` and an RNNoise model.

Needs macOS 15 or later on Apple silicon.

## Use

1. Pick the display and microphone (the meter beside it moves when you speak) and press
   **Start recording**, or `Option-Command-R` from anywhere. A 3-2-1 countdown runs and the window
   gets out of the way. While you record, a bar at the top of the screen shows REC, the time, your
   mic live, a mic picker (switch mid-recording), Pause and Resume (`Option-Command-P`), Restart
   (the take goes to the Trash and the countdown runs again) and Stop. A thin red edge runs round
   the recorded screen. Neither the bar nor the edge is in the video, and paused time is left out.
2. Press `Option-Command-R` again (or Stop). Glyph Cast prepares the recording on its own, about a
   minute for every ten recorded:
   - lines the mic up with the video (same host clock, exact),
   - removes background noise (DeepFilterNet; RNNoise if it can't run),
   - shapes the voice (rumble cut, presence lift, de-ess, gentle compression) and levels it to
     -14 LUFS, YouTube's loudness, in two passes,
   - transcribes it with whisper, tightening each word's timing against the real silences,
   - finds filler words (um, uh, hmm; repeated words like "the the"; like, you know, I mean) and
     long pauses. Nothing is cut yet: fillers show highlighted in the transcript.
3. Clean up with the buttons above the transcript. Each is one click, and a second click undoes it:
   - **Clean up everything**: all three below at once,
   - **Remove filler words** (with a count; the arrow picks which kinds),
   - **Shorten pauses** (the arrow sets how long a pause may be, and keeps pauses while the screen
     was moving, so silent demo steps stay in),
   - **Studio Sound**: noise removed, voice shaped, leveled to -14 LUFS; the arrow's Intensity
     blends your original mic back in.

   Cuts follow the voice's loudness, not only whisper's word times (which run about 0.1 s late): a
   removed filler goes from its first sound to its last, leaving a natural 0.25 s pause. The
   waveform under the player shows what is cut in red; click it to play from there. Right-click a
   word to cut or keep it, or every "uh" at once. "Clean up new recordings automatically" in the
   inspector does all of it as soon as a recording is ready.
4. Fine-tune in the transcript if you want: click a word to play from there; Option-click a word
   to cut it or bring it back; click one word, Shift-click another, then **Cut** (or Delete) or
   **Restore**; click a pause chip (`2.4s`) to cut or keep that pause; **Reset edits** goes back to
   the automatic cut.
5. The inspector on the right is remembered for every recording after: export size (1080p,
   1440p, 4K), the background (18 wave wallpapers drawn for the app, your desktop picture, any
   image, or no frame), padding, corners, shadow, zoom on clicks and how far, click rings, and
   intro and outro clips. The preview updates as you change them.
6. **Export MP4**. The file goes to `~/Movies/Capture/Exports/<recording>.mp4` with a matching
   `.srt` of the kept words: H.264 High, 60 fps, 12 Mbps at 1080p (24 at 1440p, 45 at 4K), AAC
   192 kbps stereo.

Recordings live in `~/Movies/Capture/<date time>/`: `screen.mov` (HEVC, full Retina resolution),
`mic.caf`, `system.caf` (if you turned on system sound), `events.json` (cursor, clicks, screen
activity), `edit.json` (your cuts and cleanup switches) and `work/` (cleaned voice, original voice
for the Studio Sound blend, transcript). Nothing leaves your Mac.

The wallpapers are drawn by `scripts/make_wallpapers.py` (layered silk waves in gradients) into
`assets/wallpapers/`. Edit a palette and run it again to change them.

## Build

```sh
brew install ffmpeg whisper-cpp
./scripts/build.sh --install --run     # builds "Glyph Cast.app", signs it, copies it to /Applications, opens it
```

The bundle id is `dev.fru.capture` and the data folders keep the Capture name, so an install of
the older Capture keeps its permissions, settings and recordings.

## Test

```sh
swift build
.build/debug/Capture --selftest              # a fake recording with ums and pauses, through process + export
.build/debug/Capture --record-test 8 --speak # records the real screen and mic for 8 s, speaks a line
CAPTURE_ROOT=<folder of recordings> .build/debug/Capture --open "<recording>" --uitest <out dir> [--record-flow] [--appearance dark]
.build/release/Capture --process "<recording>" [--export-only] [--height 1080] [--out <folder>]
```

`--selftest` checks the transcript, filler kinds (um, repeats, tics), that nothing is cut until you
clean up, that fillers and a dead pause are then cut and a pause with a click is kept, -14 LUFS,
the export size and length (intro + kept + outro), the frame on its background, captions, the
Studio Sound blend and that system sound reaches the edit, and then transcribes the export to
confirm no filler is left and no real word was clipped.

`--uitest` drives the real window: it finds each control through the app's own accessibility tree
and presses it. It covers the cleanup buttons, Option-click, Shift-select + Cut, Reset, pause
chips, the waveform, wallpapers and a pixel check of the redrawn preview, toggles, the size picker,
Export, the record page and the shortcut. `--record-flow` adds the whole loop: Record button,
countdown, recording, stop, processing, editor. Screenshots of each step go to the out dir.

## How it is built

Swift, no packages. ScreenCaptureKit for screen, mic and system sound; AVFoundation to write and to
compose; Core Image for every frame; ffmpeg, deep-filter and whisper-cli as tools.

| File | What it does |
|---|---|
| `Recorder.swift` | SCStream to HEVC `screen.mov` + float `mic.caf`/`system.caf`; cursor, clicks, changed-screen area |
| `Processor.swift` | align, denoise, voice chain, loudness, transcribe, find fillers and pauses, `edit.json` |
| `Project.swift` | the files, the edit model, the cut rules, `Style` (settings) |
| `Composer.swift` | cuts into an AVComposition, the per-frame renderer (background, shadow, corners, zoom, rings), export, SRT |
| `App.swift`, `Views.swift`, `HUD.swift` | window, menu bar, record page, editor, transcript, inspector, recording bar |
| `SelfTest.swift`, `UITest.swift` | the tests above |

Not built yet: camera bubble, captions burned into the video, a re-rendered smooth cursor, a
music bed.

## Versions

- **0.1.2** (2026-10-25): name a recording: double-click its name in the list (or right-click >
  Rename), or press the pencil on the recording bar while it records. The name names the exported
  MP4. "Add intro and outro" in the Export section leaves them off when they get added later.
  Glyph Cast now shows up in System Settings > Screen & System Audio Recording on macOS 15 and later.
- **0.1.1** (2026-10-25): Capture is now Glyph Cast, in the Glyph family: new name and icon, a
  signed and notarized download. Same bundle id and folders, so settings and recordings carry over.

## License

MIT. See [LICENSE](LICENSE).
