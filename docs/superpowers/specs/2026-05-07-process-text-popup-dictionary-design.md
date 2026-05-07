# PROCESS_TEXT Popup Dictionary Design

## Goal

When the user selects text in another Android app and chooses Hibiki from the
system text action menu, Hibiki should show a compact dictionary popup instead
of switching to the full-screen dictionary page. The popup must preserve the
existing dictionary behavior: WebView rendering, media interception, audio,
recursive lookup, Anki mining hooks, theme settings, collapsed dictionaries,
search history, and dictionary history.

## Core Decision

Use a second Flutter engine for the popup Activity.

The popup will not share the main Activity's Flutter engine or AppModel. Sharing
one engine would avoid duplicate initialization, but one Flutter engine can only
attach to one FlutterView at a time. The selected direction is to keep the main
Activity and popup Activity isolated: each Activity owns its own Flutter engine
and its own AppModel instance.

This is heavier, but it keeps the window model honest and avoids stealing the
main Activity's renderer. It also avoids rebuilding the popup in native Android,
which would duplicate the active `DictionaryPopupWebView` / `popup.html`
contract and lose behavior.

## Existing Facts

- `ACTION_PROCESS_TEXT` is currently declared on `MainActivity` (AndroidManifest
  line 63).
- `main.dart` receives `android.intent.action.PROCESS_TEXT` (line 256) and calls
  `appModel.openRecursiveDictionarySearch(searchTerm: data, killOnPop: true)`.
- `RecursiveDictionaryPage` currently exits external lookups through
  `appModel.shutdown()` (line 94), which closes the database and calls
  `FlutterExitApp.exitApp()` — killing the entire OS process.
- `DictionaryPopupWebView` is the active dictionary rendering path. It injects
  lookup JSON, dictionary styles, popup settings, audio sources, collapsed
  dictionary names, and JavaScript handlers into `assets/popup/popup.html`.
- `DictionaryPopupWebView` depends on AppModel for user settings and service
  access. A native WebView implementation would need to re-create too much of
  this behavior.
- `MainActivity` extends `AudioServiceActivity` (not `FlutterActivity`
  directly). All custom MethodChannels (Anki, TTS, SAF, volume keys, floating
  lyric, fonts, update, splash) are registered in
  `MainActivity.configureFlutterEngine()` (line 360).
- The database is Drift/SQLite. `_openDb()` (database.dart line 11) uses
  `NativeDatabase.createInBackground(file)` — does not enable WAL by default.
- `HoshiDicts` Dart wrapper uses static fields (`_instance`, `_bindings`) that
  are per-isolate. Each Flutter engine runs its own isolate, so Dart-level
  statics are naturally isolated. The C-level `create()` allocates an
  independent handle, but process-global C state (mmap, caches) has not been
  verified under concurrent dual-engine access.

## Android Architecture

### Manifest Declaration

Move `ACTION_PROCESS_TEXT` from `MainActivity` to a new `PopupDictActivity`.
Remove the PROCESS_TEXT intent filter from `MainActivity` to avoid duplicate
Hibiki entries in the system text action menu.

```xml
<activity
    android:name=".PopupDictActivity"
    android:theme="@style/PopupDictTheme"
    android:taskAffinity="app.hibiki.reader.popup"
    android:excludeFromRecents="true"
    android:autoRemoveFromRecents="true"
    android:launchMode="singleTop"
    android:exported="true"
    android:hardwareAccelerated="true"
    android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
    android:windowSoftInputMode="adjustResize">
    <intent-filter>
        <action android:name="android.intent.action.PROCESS_TEXT" />
        <data android:mimeType="text/plain" />
        <category android:name="android.intent.category.DEFAULT" />
    </intent-filter>
</activity>
```

Key attributes:

- `taskAffinity="app.hibiki.reader.popup"` — separate task from the main app.
  Without this, the popup would stack on top of the main Hibiki task and pull it
  to the foreground.
- `excludeFromRecents="true"` + `autoRemoveFromRecents="true"` — popup does not
  appear as a separate entry in the recent apps list.
- `launchMode="singleTop"` — consecutive PROCESS_TEXT invocations while the
  popup is visible deliver via `onNewIntent()` instead of creating a new
  Activity instance.
- `exported="true"` — required for system text action menu visibility.

Implementation must verify task isolation with actual `adb shell am start`
invocations and `adb shell dumpsys activity activities` to confirm the popup
creates its own task and does not merge into the main Hibiki task.

### PopupDictActivity Base Class and Dart Entry Point

`PopupDictActivity` extends `FlutterActivity`, not `AudioServiceActivity`.

Word audio playback goes through the TTS MethodChannel
(`TextToSpeech`/`MediaPlayer`), which does not require `AudioServiceActivity`.
The `audio_service` base class is only needed for background media playback
(audiobook), which the popup does not use.

`PopupDictActivity` must override `getDartEntrypointFunctionName()` to return
`"popupMain"`. Without this, FlutterActivity defaults to `main()` and the popup
engine would run the full main app shell instead of the popup shell.

```java
public class PopupDictActivity extends FlutterActivity {
    @NonNull
    @Override
    public String getDartEntrypointFunctionName() {
        return "popupMain";
    }
}
```

### Popup Theme

Add `PopupDictTheme` to `styles.xml`:

- No title bar.
- Translucent dimmed background.
- Floating/dialog window behavior.
- Does not force fullscreen.
- Outside-touch finishes the Activity.

Window size: width `min(screen × 0.92, 520dp)`, height `min(screen × 0.70,
640dp)`, centered vertically (slight upward bias), not draggable. First version
uses fixed values; dynamic adjustment deferred.

### MethodChannel Strategy

Separate Flutter plugin auto-registration from custom channel registration.

**Plugin auto-registration**: `super.configureFlutterEngine(engine)` calls
`GeneratedPluginRegistrant.registerWith(engine)`. All Flutter plugins
(flutter_inappwebview, audio_session, etc.) are registered automatically. No
action needed beyond calling `super`.

**Custom channel registration**: Extract from the monolithic
`MainActivity.configureFlutterEngine()` into modular helpers.

Required for popup v1:

- `AnkiChannelHandler.register(activity, engine)` — Anki mining, duplicate
  check, model management.
- `TtsChannelHandler.register(activity, engine)` — TTS synthesis, MediaPlayer
  playback, local audio DB.
- `PopupLifecycleHandler.register(activity, engine)` — new channel
  `app.hibiki.reader/popup`. Popup-only.

**Not registered in popup v1**: volume keys, SAF, update, splash, floating
lyric, fonts (`FontsChannelHandler`). If popup initialization code paths
accidentally touch these channels, guard with `try/catch` or conditional
checks — do not register unused channels. If a failing popup font rendering
path proves fonts channel is needed, add `FontsChannelHandler` as a targeted
fix.

Each handler module takes its Activity/engine dependencies as constructor
parameters. `MainActivity` and `PopupDictActivity` each call the modules they
need in their respective `configureFlutterEngine()`.

### Popup MethodChannel

New channel: `app.hibiki.reader/popup`.

Dart → Java methods:

- `getInitialProcessText` — Dart calls Java once at engine startup to retrieve
  the `PROCESS_TEXT` extra from the launching intent. Returns the selected text
  string.
- `finishPopup` — Dart requests the Activity to `finish()`. Must only be called
  **after** `await appModel.closeForPopup()` completes on the Dart side (see
  Popup Close Sequence below). Does not call `FlutterExitApp.exitApp()`. Does
  not kill the process.

Java → Dart methods:

- `onNewProcessText` — Java calls `popupChannel.invokeMethod("onNewProcessText",
  text)` from `onNewIntent()` when a new PROCESS_TEXT arrives while the popup is
  already showing. Dart receives it via `setMethodCallHandler` on the same
  `app.hibiki.reader/popup` channel. No separate EventChannel.

## Dart Architecture

### Entry Point

Use a dedicated Dart entry point, not a route branch in `main()`:

```dart
@pragma('vm:entry-point')
void popupMain() {
  // Popup-specific initialization and app shell.
}
```

The main app does not contain popup-mode conditionals. `popupMain` runs its own
minimal app shell.

### Popup Initialization: `initialiseForDictionaryPopup()`

The popup does NOT run the full `AppModel.initialise()`. Add a new method
`AppModel.initialiseForDictionaryPopup()` that performs only the subset needed
for dictionary lookup and rendering.

**Precondition**: TTS MethodChannel must be registered before this method runs,
because local audio DB setup (line 1116) calls
`TtsChannel.instance.setLocalAudioDb()`.

**Initialization steps** (in order):

1. `PackageInfo.fromPlatform()` + `AndroidDeviceInfo`.
2. Resolve directories (`getApplicationSupportDirectory()`,
   `getApplicationDocumentsDirectory()`).
3. Open Drift database: `HibikiDatabase(dbDirectory)`.
4. Load all preferences into `_prefCache`.
5. Load dictionary metadata into `_dictionariesCache`.
6. `_rebuildDictPathsCache()` → `HoshiDicts.initializeTyped()`.
7. Locale, target language, language formats initialization.
8. Dictionary format/enhancement registration.
9. Local audio DB setup (depends on TTS channel being ready).
10. Theme/popup/dictionary appearance settings.
11. Anki-related settings (deck, model, field mappings) for mining support.

**Skipped** (not needed for popup):

- Media source initialization.
- TTU WebView server warmup.
- WebView pre-warming.
- License injection.
- Quick actions setup.
- Update check.
- Audio service / reader-specific initialization.
- Media items cache.

### Shared Initialization Helpers

Extract from `main.dart` only what is needed to avoid duplication:

- A guarded startup wrapper (error handling, logger setup).
- AppModel creation and provider setup.

Do not rewrite the entire startup system. `main()` keeps its current structure;
`popupMain()` calls the shared helpers then diverges into the popup app shell.

## Popup Dictionary UI

Create a compact popup dictionary page rather than using the full
`RecursiveDictionaryPage` unchanged.

The popup page should reuse:

- `appModel.searchDictionary(...)`
- `DictionaryPopupWebView`
- existing popup JavaScript handlers
- current theme and dictionary settings

The popup page should differ from the full page:

- Minimal chrome: search bar + close button, no full navigation shell.
- Close button calls `finishPopup` via the popup channel (not
  `appModel.shutdown()`).
- Recursive lookup replaces the current query in-place or pushes a compact
  nested view inside the popup window.
- Anki mining and audio behavior remain wired through AppModel and the
  registered MethodChannels.

The first implementation can use `RecursiveDictionaryPage` with an explicit
popup presentation mode if that produces less duplication. If conditionals start
spreading through the full-screen page, create a dedicated popup page and
extract shared search/result widgets.

## Data Flow

1. User selects text in another app.
2. Android launches `PopupDictActivity` via `ACTION_PROCESS_TEXT`.
3. `PopupDictActivity.configureFlutterEngine()` registers plugins (auto) +
   custom channels (Anki, TTS, PopupLifecycle). Fonts channel not registered
   in v1.
4. Flutter engine starts `popupMain()` entry point.
5. Dart calls `getInitialProcessText` on the popup channel to get the selected
   text.
6. `AppModel.initialiseForDictionaryPopup()` runs (DB, prefs, dictionaries,
   HoshiDicts, theme, Anki settings).
7. Popup page calls `appModel.searchDictionary(...)`.
8. `AppModel` uses its own initialized `HoshiDicts` instance.
9. Result is rendered by `DictionaryPopupWebView`.
10. WebView media requests are resolved by `HoshiDicts.instance.getMediaFile`.
11. WebView audio/mining/duplicate handlers call Dart/native channels registered
    on the popup engine.
12. If user selects text again while popup is open, `onNewIntent()` pushes
    `onNewProcessText` to Dart, which updates the query.
13. User taps outside or presses close → Dart `await appModel.closeForPopup()`
    (DB close, HoshiDicts dispose) → Dart calls `finishPopup` →
    `PopupDictActivity.finish()` → user returns to source app.

## Lifecycle Rules

The popup engine owns its own AppModel and database connection. Closing the
popup must close only popup state.

Rules:

- Popup close must **never** call `FlutterExitApp.exitApp()`. Both engines share
  the same OS process; `exitApp()` would kill the main app.
- Main Activity state must not be mutated by popup close.
- If the main app is already running, both AppModel instances coexist. This must
  be tested explicitly.

### Popup Close Sequence

The primary close path is Dart-initiated. Dart must finish async cleanup before
requesting the native Activity finish. `Activity.onDestroy()` serves only as a
safety net, not the main path.

```
User taps close / outside
  → Dart: await appModel.closeForPopup()
      → close Drift database connection
      → dispose HoshiDicts handle
  → Dart: invoke "finishPopup" on popup channel
  → Java: PopupDictActivity.finish()
```

`AppModel.closeForPopup()` is a new method. It closes the database and disposes
HoshiDicts but does **not** call `FlutterExitApp.exitApp()`. It is distinct from
`shutdown()` which kills the process.

As a safety net, `PopupDictActivity.onDestroy()` should also attempt to close
the database if the Dart-side close did not complete (e.g. process kill by the
OS). But the designed path is always: Dart cleanup first, then native finish.

### Existing `killOnPop` Path

`RecursiveDictionaryPage` (line 94) calls `appModel.shutdown()` which calls
`FlutterExitApp.exitApp()`. This kills the process even for SEND/WEB_SEARCH
intents.

Change: replace `shutdown()` in the `killOnPop` path with
`moveTaskToBack(true)` (via method channel to Java). Do **not** close the
database — the AppModel and engine remain alive in the background. Closing the
DB while the engine is still running would leave an initialized AppModel with a
dead database connection, which will crash on any subsequent DB access if the
user returns to the app. The main app stays alive in the background for faster
re-entry. This change applies to the existing full-screen path regardless of
the popup feature.

Only the popup engine closes its own DB — and only on engine destruction (when
`PopupDictActivity` is finished and the engine is torn down), not on
`moveTaskToBack`.

### Engine Lifecycle

First version: destroy engine on Activity finish. No caching.

Rationale: caching keeps DB and HoshiDicts handles alive longer, increasing the
window for concurrent-access issues. Prove correctness first; if cold startup
is unacceptable after measurement, add `FlutterEngineCache` with an idle timeout
(e.g. 5 minutes) in a follow-up.

## Database

### WAL Mode

Enable WAL in `_openDb()` (database.dart) for all connections:

```dart
LazyDatabase _openDb(String dbDirectory) {
  return LazyDatabase(() async {
    final file = File(p.join(dbDirectory, 'hibiki.db'));
    return NativeDatabase.createInBackground(
      file,
      setup: (db) {
        db.execute('PRAGMA journal_mode=WAL');
      },
    );
  });
}
```

WAL is a per-database persistent setting. Once enabled by any connection, all
subsequent connections (including the popup's) use WAL automatically. Setting it
in `_openDb()` is idempotent.

WAL allows concurrent readers with a single writer. Without WAL, a write from
either engine would return `SQLITE_BUSY` if the other holds a read transaction.

### Popup Write Policy

The popup should minimize non-essential writes to reduce contention:

- **Search history**: popup writes search history normally. WAL handles
  concurrency. If contention is observed in testing, add a popup-mode toggle
  as a targeted fix — do not preemptively skip.
- **Dictionary history**: same — write normally, WAL covers it.
- **Preference writes**: avoid in popup mode. Popup reads preferences but should
  not write them.
- **Essential writes**: Anki operations (if mining is triggered) go through the
  AnkiDroid API, not the Drift database, so they are not affected.

## Risks

### Double HoshiDicts (C-Level Concurrency)

Dart static fields (`_instance`, `_bindings`) are per-isolate and naturally
isolated between the two engines. No Dart-level conflict.

The C-level `create()` allocates an independent handle per caller. However,
process-global C state (shared mmap regions, memory pools, file locks on
dictionary data) has not been verified under concurrent dual-engine access. This
must be tested on device/emulator with both engines performing lookups
simultaneously.

If C-level conflicts are found, the mitigation is to serialize lookups through a
shared native lock or fall back to destroying the popup engine before the main
engine performs lookups (unlikely to be needed given the independent-handle
design).

### MethodChannel Activity Binding

Some native channel operations depend on the current Activity context. With
PopupDictActivity:

- Anki: `AddContentApi` takes an Activity context. Should work with
  PopupDictActivity, but permission prompts will appear over the popup window.
  Verify.
- TTS: `TextToSpeech` and `MediaPlayer` are context-bound. Should work.
  Verify audio output.
- Fonts: not registered in popup v1. If a popup rendering path requires system
  font listing, add `FontsChannelHandler` as a targeted fix.

### Startup Cost

Cold popup startup initializes: Flutter engine, Dart isolate,
`initialiseForDictionaryPopup()` (DB + prefs + HoshiDicts + theme), WebView for
`DictionaryPopupWebView`. Expected cold start: 2–4 seconds on mid-range
devices.

Measure cold and warm startup before optimizing. Do not add engine caching or
preload services until the basic behavior is correct and cold-start timing is
known.

## Testing Strategy

### Static Checks

- `flutter analyze` for all touched Dart files.
- Android release build with `--split-per-abi`.

### Task Isolation Verification

Before any functional testing, verify the Android task model:

```bash
# Launch popup via PROCESS_TEXT
adb shell am start -a android.intent.action.PROCESS_TEXT \
  -t text/plain \
  --es android.intent.extra.PROCESS_TEXT "テスト" \
  -n app.hibiki.reader/.PopupDictActivity

# Verify separate task
adb shell dumpsys activity activities | grep -A 5 "hibiki"
```

Confirm: popup is in task with affinity `app.hibiki.reader.popup`, main app (if
running) is in its own task, pressing back/outside from popup returns to the
source app without affecting the main Hibiki task.

### Runtime Checks on Emulator

- Fresh launch from `ACTION_PROCESS_TEXT` shows popup with dictionary result.
- Popup close returns to the source app (not to Hibiki main screen).
- Main Hibiki already running → `ACTION_PROCESS_TEXT` → popup opens in separate
  window → close popup → main Hibiki still works, reading position preserved.
- Consecutive PROCESS_TEXT while popup is open updates the query (onNewIntent
  path).
- Dictionary media images render in popup WebView.
- Word audio playback works in popup.
- Local audio query works if configured.
- Recursive lookup works inside popup (query replacement, not full-app
  navigation).
- Anki mining button either succeeds or shows the same permission behavior as
  the main app.
- `killOnPop` path in the old full-screen flow uses `moveTaskToBack` instead of
  `shutdown()`. After `moveTaskToBack`, verify the app can be resumed from
  recents without DB errors (DB must remain open).

## Non-Goals

- No native Android dictionary renderer.
- No JNI lookup bridge.
- No copying `popup.html` behavior into Java/Kotlin.
- No true `SYSTEM_ALERT_WINDOW` overlay for this feature.
- No removal of the existing full-screen recursive dictionary page.
- No engine caching in v1 (deferred to optimization phase).
- No `receive_intent` plugin dependency in popup (custom channel only).
