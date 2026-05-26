# 2026-05-26 Project Review

## Round 1 - ReaderHibiki audiobook load timeout

### Scope

- `packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart`
- `hibiki/test/media/audiobook/audiobook_controller_seek_test.dart`
- User-reported stack: `ReaderHibiki.loadAudiobook` timing out in `AudiobookPlayerController.load()`.

### Findings

#### HBK-AUDIT-001

- severity: high
- status: fixed
- files:
  - `packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart`
  - `hibiki/test/media/audiobook/audiobook_controller_seek_test.dart`
- root cause: `AudiobookPlayerController.load()` called `AudioPlayer.setAudioSource()` with just_audio's default `preload: true`, so opening the reader synchronously waited for platform media loading/duration discovery. Multi-file books made this worse by probing every file with a separate `AudioPlayer.setFilePath()` before the actual playlist was installed.
- impact: one slow, large, or stuck audio file could block `_initBook()` through `_resolveAudioSlot()` for 60 seconds and surface as `ReaderHibiki.loadAudiobook TimeoutException`.
- fix: install audio sources with `preload: false`, remove multi-file duration probes, and map cue seeks with just_audio's real data model: playlist `audioFileIndex` plus file-local `startMs`, not invented global offsets.
- verification: `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test test\media\audiobook\audiobook_controller_seek_test.dart` passed. New fake-platform regression tests cover single-file load, multi-file load, and cue seeking before platform duration is known.

### Next Scope

- If a device reproduction sample is available, verify opening the affected ReaderHibiki book on an emulator and then pressing play to confirm deferred loading starts playback normally.
