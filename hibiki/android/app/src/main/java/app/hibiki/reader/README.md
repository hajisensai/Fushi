# Android Native Code

## Language Convention

This directory contains both Java and Kotlin files. The split is historical:

- **Java (13 files + 4 constant classes):** Original activities, services, and
  channel handlers. All new Java code should match the existing style.
- **Kotlin (3 files):** `PopupDictActivity.kt`, `PopupDbReader.kt`, and
  `HoshiBridge.kt` — the standalone popup dictionary process and its JNI bridge.

**Convention for new files:** Use Kotlin. Java files are not being migrated
proactively — migration only happens when a file needs significant rework for
other reasons.

## Constant Classes (`constants/`)

Shared constants are centralized here. Each has a Dart or Drift counterpart that
MUST stay in sync:

- `ChannelNames.java` — MethodChannel name constants. Dart counterpart:
  `lib/src/utils/misc/channel_constants.dart` (`HibikiChannels`).
- `FloatingColors.java` — ARGB color values for the floating overlay services.
- `NotificationIds.java` — Foreground-service notification + channel IDs.
- `PreferenceKeys.java` — SharedPreferences key strings.

## Architecture

- `MainActivity.java` — Main Flutter activity; registers all MethodChannels.
- `BaseFloatingService.java` — Abstract base for floating overlay windows.
  - `FloatingDictService.java` — Clipboard dictionary overlay (free drag).
  - `FloatingLyricService.java` — Audiobook lyric overlay (vertical drag, lockable).
- `FloatingDictTile.java` — Quick-settings tile that toggles the dict overlay.
- `FloatingDictPluginRegistrant.java` — Registers plugins for the floating engine.
- `DictAccessibilityService.java` — Accessibility-based text lookup.
- `PopupDictActivity.kt` — Standalone popup dictionary (`:popup` process, no
  Flutter engine).
- `PopupDbReader.kt` — Read-only SQLite access to the Drift DB from `:popup`.
  Mirrors the Drift schema; guarded by `EXPECTED_SCHEMA_VERSION`.
- `HoshiBridge.kt` — JNI bridge to the hoshidicts C++ library.
- `TtsChannelHandler.java` — TTS + audio extraction channel.
- `AnkiChannelHandler.java` + `AnkiDroidHelper.java` — AnkiDroid API bridge.
- `AacAdtsCueAudioRewriter.java` — Rewrites AAC/ADTS cue audio for playback.
- `HibikiFileProvider.java` — FileProvider for sharing exported files.
- `IconSwitchHelper.java` — Runtime launcher-icon alias switching.

## Cross-Language Sync Points

When changing any of the following, update both sides in the same change:

| Native (this dir)        | Dart / Drift counterpart                         |
|--------------------------|--------------------------------------------------|
| `ChannelNames.java`      | `channel_constants.dart` (`HibikiChannels`)      |
| `PopupDbReader.kt` queries | Drift tables in `packages/hibiki_core/.../tables.dart` |
| `PopupDbReader.EXPECTED_SCHEMA_VERSION` | `HibikiDatabase.schemaVersion` in `database.dart` |
