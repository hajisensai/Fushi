# PROCESS_TEXT Popup Dictionary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a compact floating dictionary popup when the user selects text in another Android app and taps Hibiki, instead of switching to the full-screen app.

**Architecture:** Second Flutter engine in a dialog-themed `PopupDictActivity` with its own `AppModel` instance. Reuses existing `DictionaryPopupWebView` / `popup.html` for full-fidelity rendering. Custom MethodChannel (`app.hibiki.reader/popup`) for intent data and lifecycle. Database uses WAL for concurrent access safety.

**Tech Stack:** Flutter 3.41.6, Dart, Java (Android), Drift/SQLite, HoshiDicts C++ FFI, InAppWebView

**Spec:** `docs/superpowers/specs/2026-05-07-process-text-popup-dictionary-design.md`

---

## File Map

### New Files

| File | Responsibility |
|------|---------------|
| `android/app/src/main/java/app/hibiki/reader/PopupDictActivity.java` | Popup Activity: dialog theme, second Flutter engine, popup MethodChannel, `getDartEntrypointFunctionName` → `"popupMain"` |
| `android/app/src/main/java/app/hibiki/reader/AnkiChannelHandler.java` | Extracted Anki MethodChannel handler (mining, duplicate check, models, decks, media) |
| `android/app/src/main/java/app/hibiki/reader/TtsChannelHandler.java` | Extracted TTS MethodChannel handler (speak, playUrl, playFile, localAudioDb, extractAudioSegment) |
| `lib/src/utils/misc/popup_channel.dart` | Dart-side popup MethodChannel: `getInitialProcessText`, `finishPopup`, `onNewProcessText` listener |
| `lib/popup_main.dart` | `@pragma('vm:entry-point') void popupMain()` — popup engine entry point |
| `lib/src/pages/implementations/popup_dictionary_page.dart` | Compact popup dictionary page reusing `DictionaryPopupWebView` |

### Modified Files

| File | Change |
|------|--------|
| `lib/src/database/database.dart` | Add WAL pragma in `setup` callback |
| `lib/src/models/app_model.dart` | Add `initialiseForDictionaryPopup()`, `closeForPopup()`, `moveToBack()` |
| `lib/src/pages/implementations/recursive_dictionary_page.dart` | Change `killOnPop` from `shutdown()` to `moveToBack()` |
| `android/app/src/main/java/app/hibiki/reader/MainActivity.java` | Replace inline Anki/TTS handlers with extracted classes; remove PROCESS_TEXT intent filter |
| `android/app/src/main/AndroidManifest.xml` | Add `PopupDictActivity`; remove PROCESS_TEXT from `MainActivity` |
| `android/app/src/main/res/values/styles.xml` | Add `PopupDictTheme` |

All paths below are relative to `hibiki/hibiki/`.

---

### Task 1: Enable WAL in Database

**Files:**
- Modify: `lib/src/database/database.dart:11-16`

- [ ] **Step 1: Add WAL setup callback**

In `lib/src/database/database.dart`, replace the `_openDb` function:

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

- [ ] **Step 2: Verify**

Run: `cd hibiki/hibiki && flutter analyze lib/src/database/database.dart`
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
cd hibiki/hibiki
git add lib/src/database/database.dart
git commit -m "feat(db): enable WAL journal mode for concurrent access safety"
```

---

### Task 2: AppModel Lifecycle Changes

**Files:**
- Modify: `lib/src/models/app_model.dart:3207-3212`
- Modify: `lib/src/pages/implementations/recursive_dictionary_page.dart:92-96`

- [ ] **Step 1: Add `closeForPopup()` and `moveToBack()` to AppModel**

In `lib/src/models/app_model.dart`, after the existing `shutdown()` method (line 3212), add:

```dart
  /// Close database and dispose HoshiDicts for popup engine teardown.
  /// Does NOT call FlutterExitApp — both engines share the same OS process.
  Future<void> closeForPopup() async {
    databaseCloseNotifier.notifyListeners();
    await _database.close();
    HoshiDicts.disposeInstance();
  }

  /// Move the app task to the background without killing the process.
  /// Used by killOnPop path instead of shutdown().
  Future<void> moveToBack() async {
    try {
      await SystemNavigator.pop();
    } catch (_) {}
  }
```

Note: `SystemNavigator.pop()` calls `moveTaskToBack(true)` on Android. The `flutter/services.dart` import is already present (line 17).

Also add the `HoshiDicts.disposeInstance()` static method. In
`lib/src/dictionary/hoshidicts.dart`, after the existing `rebuild` method, add:

```dart
  static void disposeInstance() {
    _instance?.dispose();
    _instance = null;
  }
```

- [ ] **Step 2: Change killOnPop path in RecursiveDictionaryPage**

In `lib/src/pages/implementations/recursive_dictionary_page.dart`, replace the
two `appModel.shutdown()` calls (lines 94 and 213) with `appModel.moveToBack()`:

Line 92-96 — change `onPopInvokedWithResult`:
```dart
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && widget.killOnPop) {
            appModel.moveToBack();
          }
        },
```

Line 211-214 — change back button:
```dart
                onTap: () async {
                  if (widget.killOnPop) {
                    appModel.moveToBack();
                  } else {
                    Navigator.pop(context);
                  }
                },
```

- [ ] **Step 3: Verify**

Run: `cd hibiki/hibiki && flutter analyze lib/src/models/app_model.dart lib/src/pages/implementations/recursive_dictionary_page.dart lib/src/dictionary/hoshidicts.dart`
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
cd hibiki/hibiki
git add lib/src/models/app_model.dart lib/src/pages/implementations/recursive_dictionary_page.dart lib/src/dictionary/hoshidicts.dart
git commit -m "feat(lifecycle): replace shutdown/exitApp with moveToBack and closeForPopup

killOnPop path now moves task to background instead of killing the process.
closeForPopup() added for popup engine teardown without process exit."
```

---

### Task 3: Extract AnkiChannelHandler

**Files:**
- Create: `android/app/src/main/java/app/hibiki/reader/AnkiChannelHandler.java`
- Modify: `android/app/src/main/java/app/hibiki/reader/MainActivity.java`

- [ ] **Step 1: Create AnkiChannelHandler.java**

Create `android/app/src/main/java/app/hibiki/reader/AnkiChannelHandler.java`:

```java
package app.hibiki.reader;

import android.app.Activity;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Intent;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;
import androidx.core.content.FileProvider;

import com.ichi2.anki.FlashCardsContract;
import com.ichi2.anki.api.AddContentApi;

import java.io.File;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class AnkiChannelHandler {
    private static final String CHANNEL = "app.hibiki.reader/anki";
    private static final int AD_PERM_REQUEST = 0;

    private final Activity activity;
    private final AnkiDroidHelper ankiDroid;

    public AnkiChannelHandler(Activity activity) {
        this.activity = activity;
        this.ankiDroid = new AnkiDroidHelper(activity);
    }

    public void register(@NonNull FlutterEngine engine) {
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), CHANNEL)
            .setMethodCallHandler((call, result) -> {
                final String model = call.argument("model");
                final String deck = call.argument("deck");
                final String key = call.argument("key");
                final String reading = call.argument("reading");
                final ArrayList<Integer> readingFieldIndices = call.argument("readingFieldIndices");
                final ArrayList<String> fields = call.argument("fields");
                final ArrayList<String> tags = call.argument("tags");
                final ArrayList<String> models = call.argument("models");
                final String filename = call.argument("filename");
                final String preferredName = call.argument("preferredName");
                final String mimeType = call.argument("mimeType");
                final AddContentApi api = new AddContentApi(activity);

                switch (call.method) {
                    case "addNote":
                        addNote(model, deck, fields, tags);
                        result.success("Added note");
                        break;
                    case "checkForDuplicates":
                        if (ankiDroid.shouldRequestPermission()) {
                            result.success(false);
                            return;
                        } else {
                            new Handler(Looper.getMainLooper()).post(() ->
                                result.success(checkForDuplicates(models, key, reading, readingFieldIndices)));
                        }
                        break;
                    case "getDecks":
                        if (requirePermission(result)) {
                            result.success(api.getDeckList());
                        }
                        break;
                    case "getModelList":
                        if (requirePermission(result)) {
                            result.success(api.getModelList());
                        }
                        break;
                    case "getFieldList":
                        if (requirePermission(result)) {
                            Long mid = ankiDroid.findModelIdByName(model, 1);
                            if (mid == null) {
                                result.error("MODEL_NOT_FOUND",
                                    "Note type not found: " + model, null);
                            } else {
                                result.success(Arrays.asList(api.getFieldList(mid)));
                            }
                        }
                        break;
                    case "addDefaultModel":
                        addDefaultModel();
                        break;
                    case "requestAnkidroidPermissions":
                        if (ankiDroid.shouldRequestPermission()) {
                            ankiDroid.requestPermission(activity, AD_PERM_REQUEST);
                        }
                        result.success(true);
                        break;
                    case "addFileToMedia":
                        File file = new File(filename);
                        Uri fileUri = FileProvider.getUriForFile(
                            activity, BuildConfig.APPLICATION_ID + ".provider", file);
                        activity.grantUriPermission("com.ichi2.anki", fileUri,
                            Intent.FLAG_GRANT_READ_URI_PERMISSION);
                        ContentValues contentValues = new ContentValues();
                        contentValues.put(FlashCardsContract.AnkiMedia.FILE_URI,
                            fileUri.toString());
                        contentValues.put(FlashCardsContract.AnkiMedia.PREFERRED_NAME,
                            preferredName);
                        ContentResolver contentResolver = activity.getContentResolver();
                        Uri returnUri = contentResolver.insert(
                            FlashCardsContract.AnkiMedia.CONTENT_URI, contentValues);
                        result.success(
                            new File(returnUri.getPath()).toString().substring(1));
                        break;
                    default:
                        result.notImplemented();
                }
            });
    }

    private boolean requirePermission(MethodChannel.Result result) {
        if (ankiDroid.shouldRequestPermission()) {
            ankiDroid.requestPermission(activity, AD_PERM_REQUEST);
            result.error("PERMISSION", "AnkiDroid permission required", null);
            return false;
        }
        return true;
    }

    private void addNote(String model, String deck,
                         ArrayList<String> fields, ArrayList<String> tags) {
        final AddContentApi api = new AddContentApi(activity);
        Long deckId = ankiDroid.findDeckIdByName(deck);
        if (deckId == null) {
            deckId = api.addNewDeck(deck);
        }
        Long modelId = ankiDroid.findModelIdByName(model, fields.size());
        if (modelId == null) {
            modelId = api.addNewBasicModel(model);
        }
        Set<String> tagSet = new HashSet<>(tags);
        String[] fieldsArray = fields.toArray(new String[0]);
        api.addNote(modelId, deckId, fieldsArray, tagSet);
    }

    private boolean checkForDuplicates(ArrayList<String> models, String key,
                                       String reading,
                                       ArrayList<Integer> readingFieldIndices) {
        for (String model : models) {
            Long mid = ankiDroid.findModelIdByName(model, 1);
            if (mid == null) continue;
            List<com.ichi2.anki.api.NoteInfo> notes = ankiDroid.findDuplicateNotes(mid, key);
            if (notes != null && !notes.isEmpty()) {
                if (reading == null || reading.isEmpty() || readingFieldIndices == null) {
                    return true;
                }
                for (com.ichi2.anki.api.NoteInfo note : notes) {
                    String[] noteFields = note.getFields();
                    for (int idx : readingFieldIndices) {
                        if (idx < noteFields.length &&
                            noteFields[idx].contains(reading)) {
                            return true;
                        }
                    }
                }
            }
        }
        return false;
    }

    private void addDefaultModel() {
        final AddContentApi api = new AddContentApi(activity);
        long modelId;
        if (modelExists("Lapis")) {
            modelId = ankiDroid.findModelIdByName("Lapis", 17);
        } else {
            modelId = api.addNewCustomModel("Lapis",
                new String[] {
                    "Expression", "Reading", "Meaning", "Notes", "Context",
                    "Context Translation", "Term Reading", "Term Audio",
                    "Term Frequency", "Sentence Audio", "Image",
                    "Pitch Accent", "Furigana", "Expanded Meaning",
                    "Collapsed Meaning", "Pitch Accent Image", "Tags"
                },
                "{{Expression}}", "{{Meaning}}"
            );
        }
        Long deckId = ankiDroid.findDeckIdByName("Lapis");
        if (deckId == null) {
            api.addNewDeck("Lapis");
        }
    }

    private boolean modelExists(String name) {
        return ankiDroid.findModelIdByName(name, 1) != null;
    }
}
```

- [ ] **Step 2: Update MainActivity to use AnkiChannelHandler**

In `MainActivity.java`, in `onCreate()` (after line 129), add:
```java
        ankiChannelHandler = new AnkiChannelHandler(context);
```

Add the field declaration near line 78:
```java
    private AnkiChannelHandler ankiChannelHandler;
```

In `configureFlutterEngine()`, replace the entire Anki channel block (lines
375–468) with:
```java
        ankiChannelHandler.register(flutterEngine);
```

Remove the now-unused methods from MainActivity: `addNote`, `checkForDuplicates`,
`requireAnkiPermission`, `addDefaultModel`, `modelExists`, and the
`mAnkiDroid` field. Keep the `AD_PERM_REQUEST` constant only if still referenced
by `onActivityResult`; if not, remove it too.

- [ ] **Step 3: Verify build**

Run: `cd hibiki/hibiki && flutter analyze && cd android && ./gradlew assembleDebug`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
cd hibiki/hibiki
git add android/app/src/main/java/app/hibiki/reader/AnkiChannelHandler.java android/app/src/main/java/app/hibiki/reader/MainActivity.java
git commit -m "refactor(android): extract AnkiChannelHandler from MainActivity

Modular handler class that can be registered by any Activity's
configureFlutterEngine(). Preparation for PopupDictActivity."
```

---

### Task 4: Extract TtsChannelHandler

**Files:**
- Create: `android/app/src/main/java/app/hibiki/reader/TtsChannelHandler.java`
- Modify: `android/app/src/main/java/app/hibiki/reader/MainActivity.java`

- [ ] **Step 1: Create TtsChannelHandler.java**

Create `android/app/src/main/java/app/hibiki/reader/TtsChannelHandler.java`:

```java
package app.hibiki.reader;

import android.app.Activity;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.media.AudioAttributes;
import android.media.MediaPlayer;
import android.os.Handler;
import android.os.Looper;
import android.speech.tts.TextToSpeech;

import androidx.annotation.NonNull;

import java.io.File;
import java.io.FileOutputStream;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class TtsChannelHandler {
    private static final String CHANNEL = "app.hibiki.reader/tts";

    private final Activity activity;
    private TextToSpeech tts;
    private boolean ttsReady = false;
    private MediaPlayer mediaPlayer;
    private volatile SQLiteDatabase localAudioDb;
    private String localAudioDbPath;
    private final Object dbLock = new Object();
    private final ExecutorService ioExecutor = Executors.newFixedThreadPool(2);
    private final ExecutorService dbSetupExecutor = Executors.newSingleThreadExecutor();
    private volatile java.util.concurrent.Future<?> indexFuture;

    public TtsChannelHandler(Activity activity) {
        this.activity = activity;
        tts = new TextToSpeech(activity, status -> {
            if (status == TextToSpeech.SUCCESS) {
                int langResult = tts.setLanguage(Locale.JAPAN);
                ttsReady = (langResult != TextToSpeech.LANG_MISSING_DATA
                        && langResult != TextToSpeech.LANG_NOT_SUPPORTED);
            }
        });
    }

    public void register(@NonNull FlutterEngine engine) {
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), CHANNEL)
            .setMethodCallHandler((call, result) -> {
                switch (call.method) {
                    case "speak":
                        handleSpeak(call, result);
                        break;
                    case "ttsToFile":
                        handleTtsToFile(call, result);
                        break;
                    case "stop":
                        handleStop(result);
                        break;
                    case "playUrl":
                        handlePlayUrl(call, result);
                        break;
                    case "playFile":
                        handlePlayFile(call, result);
                        break;
                    case "setLocalAudioDb":
                        handleSetLocalAudioDb(call, result);
                        break;
                    case "queryLocalAudio":
                        handleQueryLocalAudio(call, result);
                        break;
                    case "extractLocalAudio":
                        handleExtractLocalAudio(call, result);
                        break;
                    case "extractAudioSegment":
                        handleExtractAudioSegment(call, result);
                        break;
                    default:
                        result.notImplemented();
                }
            });
    }

    public void destroy() {
        if (tts != null) {
            tts.stop();
            tts.shutdown();
        }
        if (mediaPlayer != null) {
            mediaPlayer.release();
            mediaPlayer = null;
        }
        synchronized (dbLock) {
            closeAudioDbLocked();
        }
        ioExecutor.shutdownNow();
        dbSetupExecutor.shutdownNow();
    }

    private void handleSpeak(MethodChannel.MethodCall call, MethodChannel.Result result) {
        String text = call.argument("text");
        String locale = call.argument("locale");
        if (text == null || text.isEmpty() || !ttsReady) {
            result.success(false);
            return;
        }
        if (locale != null && !locale.isEmpty()) {
            String[] parts = locale.split("-");
            Locale loc = parts.length >= 2 ? new Locale(parts[0], parts[1]) : new Locale(parts[0]);
            tts.setLanguage(loc);
        }
        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "hibiki_lookup");
        result.success(true);
    }

    private void handleTtsToFile(MethodChannel.MethodCall call, MethodChannel.Result result) {
        String text = call.argument("text");
        String locale = call.argument("locale");
        String outputPath = call.argument("outputPath");
        if (text == null || text.isEmpty() || outputPath == null || !ttsReady) {
            result.success(null);
            return;
        }
        if (locale != null && !locale.isEmpty()) {
            String[] parts = locale.split("-");
            Locale loc = parts.length >= 2 ? new Locale(parts[0], parts[1]) : new Locale(parts[0]);
            tts.setLanguage(loc);
        }
        tts.setOnUtteranceProgressListener(new android.speech.tts.UtteranceProgressListener() {
            @Override public void onStart(String utteranceId) {}
            @Override public void onDone(String utteranceId) {
                tts.setOnUtteranceProgressListener(null);
                new Handler(Looper.getMainLooper()).post(() -> result.success(outputPath));
            }
            @Override public void onError(String utteranceId) {
                tts.setOnUtteranceProgressListener(null);
                new Handler(Looper.getMainLooper()).post(() -> result.success(null));
            }
        });
        File outFile = new File(outputPath);
        int r = tts.synthesizeToFile(text, null, outFile, "hibiki_tts_file");
        if (r != TextToSpeech.SUCCESS) {
            tts.setOnUtteranceProgressListener(null);
            result.success(null);
        }
    }

    private void handleStop(MethodChannel.Result result) {
        if (ttsReady) tts.stop();
        if (mediaPlayer != null) {
            mediaPlayer.stop();
            mediaPlayer.release();
            mediaPlayer = null;
        }
        result.success(true);
    }

    private void handlePlayUrl(MethodChannel.MethodCall call, MethodChannel.Result result) {
        String url = call.argument("url");
        if (url == null || url.isEmpty()) {
            result.success(false);
            return;
        }
        releaseMediaPlayer();
        try {
            mediaPlayer = new MediaPlayer();
            mediaPlayer.setAudioAttributes(
                new AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .build());
            mediaPlayer.setDataSource(url);
            mediaPlayer.setOnPreparedListener(mp -> mp.start());
            mediaPlayer.setOnCompletionListener(mp -> { mp.release(); mediaPlayer = null; });
            mediaPlayer.setOnErrorListener((mp, what, extra) -> { mp.release(); mediaPlayer = null; return true; });
            mediaPlayer.prepareAsync();
            result.success(true);
        } catch (Exception e) {
            android.util.Log.w("hibiki-audio", "playUrl failed", e);
            result.success(false);
        }
    }

    private void handlePlayFile(MethodChannel.MethodCall call, MethodChannel.Result result) {
        String filePath = call.argument("path");
        if (filePath == null || filePath.isEmpty()) {
            result.success(false);
            return;
        }
        releaseMediaPlayer();
        try {
            mediaPlayer = new MediaPlayer();
            mediaPlayer.setAudioAttributes(
                new AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .build());
            mediaPlayer.setDataSource(filePath);
            mediaPlayer.setOnPreparedListener(mp -> mp.start());
            mediaPlayer.setOnCompletionListener(mp -> { mp.release(); mediaPlayer = null; });
            mediaPlayer.setOnErrorListener((mp, what, extra) -> { mp.release(); mediaPlayer = null; return true; });
            mediaPlayer.prepare();
            result.success(true);
        } catch (Exception e) {
            android.util.Log.w("hibiki-audio", "playFile failed", e);
            result.success(false);
        }
    }

    private void handleSetLocalAudioDb(MethodChannel.MethodCall call, MethodChannel.Result result) {
        String dbPath = call.argument("path");
        dbSetupExecutor.execute(() -> {
            synchronized (dbLock) {
                closeAudioDbLocked();
                localAudioDbPath = dbPath;
                if (dbPath != null && !dbPath.isEmpty()) {
                    try {
                        File dbFile = new File(dbPath);
                        if (dbFile.exists()) {
                            localAudioDb = SQLiteDatabase.openDatabase(
                                dbPath, null,
                                SQLiteDatabase.OPEN_READWRITE | SQLiteDatabase.NO_LOCALIZED_COLLATORS);
                            if (!localAudioDb.enableWriteAheadLogging()) {
                                android.util.Log.w("hibiki-audio",
                                    "WAL mode failed, queries may block");
                            }
                            final SQLiteDatabase db = localAudioDb;
                            indexFuture = ioExecutor.submit(() -> {
                                try {
                                    if (db.isOpen()) {
                                        db.execSQL("CREATE INDEX IF NOT EXISTS idx_entries_expr_read ON entries(expression, reading)");
                                        db.execSQL("CREATE INDEX IF NOT EXISTS idx_android_file_source ON android(file, source)");
                                    }
                                } catch (Exception e) {
                                    android.util.Log.w("hibiki-audio", "Index creation skipped", e);
                                }
                            });
                            activity.runOnUiThread(() -> result.success(true));
                        } else {
                            activity.runOnUiThread(() -> result.success(false));
                        }
                    } catch (Exception e) {
                        android.util.Log.e("hibiki-audio", "Failed to open local audio db", e);
                        activity.runOnUiThread(() -> result.success(false));
                    }
                } else {
                    activity.runOnUiThread(() -> result.success(true));
                }
            }
        });
    }

    private void handleQueryLocalAudio(MethodChannel.MethodCall call, MethodChannel.Result result) {
        String expression = call.argument("expression");
        String reading = call.argument("reading");
        if (localAudioDb == null || expression == null) {
            result.success(null);
            return;
        }
        ioExecutor.execute(() -> {
            synchronized (dbLock) {
                SQLiteDatabase db = localAudioDb;
                if (db == null || !db.isOpen()) {
                    new Handler(Looper.getMainLooper()).post(() -> result.success(null));
                    return;
                }
                Cursor cursor = null;
                try {
                    cursor = db.rawQuery(
                        "SELECT file, source FROM entries WHERE expression = ? AND reading = ? LIMIT 1",
                        new String[]{expression, reading != null ? reading : ""});
                    if (cursor == null || !cursor.moveToFirst()) {
                        if (cursor != null) cursor.close();
                        cursor = db.rawQuery(
                            "SELECT file, source FROM entries WHERE expression = ? LIMIT 1",
                            new String[]{expression});
                    }
                    if (cursor != null && cursor.moveToFirst()) {
                        String file = cursor.getString(0);
                        String source = cursor.getString(1);
                        Map<String, String> info = new HashMap<>();
                        info.put("file", file);
                        info.put("source", source);
                        new Handler(Looper.getMainLooper()).post(() -> result.success(info));
                    } else {
                        new Handler(Looper.getMainLooper()).post(() -> result.success(null));
                    }
                } catch (Exception e) {
                    android.util.Log.w("hibiki-audio", "queryLocalAudio failed", e);
                    new Handler(Looper.getMainLooper()).post(() -> result.success(null));
                } finally {
                    if (cursor != null) cursor.close();
                }
            }
        });
    }

    private void handleExtractLocalAudio(MethodChannel.MethodCall call, MethodChannel.Result result) {
        String fileArg = call.argument("file");
        String sourceArg = call.argument("source");
        if (localAudioDb == null || fileArg == null || sourceArg == null) {
            result.success(null);
            return;
        }
        final File cacheDir = activity.getCacheDir();
        ioExecutor.execute(() -> {
            synchronized (dbLock) {
                SQLiteDatabase db = localAudioDb;
                if (db == null || !db.isOpen()) {
                    new Handler(Looper.getMainLooper()).post(() -> result.success(null));
                    return;
                }
                try (Cursor audioCursor = db.rawQuery(
                        "SELECT data FROM android WHERE file = ? AND source = ? LIMIT 1",
                        new String[]{fileArg, sourceArg})) {
                    if (audioCursor != null && audioCursor.moveToFirst()) {
                        byte[] audioData = audioCursor.getBlob(0);
                        String ext = fileArg.endsWith(".opus") ? ".opus" : ".mp3";
                        File tempFile = new File(cacheDir, "local_audio" + ext);
                        try (FileOutputStream fos = new FileOutputStream(tempFile)) {
                            fos.write(audioData);
                        }
                        new Handler(Looper.getMainLooper()).post(() ->
                            result.success(tempFile.getAbsolutePath()));
                    } else {
                        new Handler(Looper.getMainLooper()).post(() -> result.success(null));
                    }
                } catch (Exception e) {
                    android.util.Log.w("hibiki-audio", "extractLocalAudio failed", e);
                    new Handler(Looper.getMainLooper()).post(() -> result.success(null));
                }
            }
        });
    }

    private void handleExtractAudioSegment(MethodChannel.MethodCall call, MethodChannel.Result result) {
        String inputPath = call.argument("inputPath");
        Number startMsN = call.argument("startMs");
        Number endMsN = call.argument("endMs");
        String outputPath = call.argument("outputPath");
        if (inputPath == null || outputPath == null || startMsN == null || endMsN == null) {
            result.error("INVALID_ARGS", "Missing required arguments", null);
            return;
        }
        long startUs = startMsN.longValue() * 1000L;
        long endUs = endMsN.longValue() * 1000L;
        ioExecutor.execute(() -> {
            android.media.MediaExtractor extractor = null;
            android.media.MediaMuxer muxer = null;
            try {
                extractor = new android.media.MediaExtractor();
                extractor.setDataSource(inputPath);
                int audioTrack = -1;
                for (int i = 0; i < extractor.getTrackCount(); i++) {
                    android.media.MediaFormat fmt = extractor.getTrackFormat(i);
                    String m = fmt.getString(android.media.MediaFormat.KEY_MIME);
                    if (m != null && m.startsWith("audio/")) { audioTrack = i; break; }
                }
                if (audioTrack < 0) {
                    new Handler(Looper.getMainLooper()).post(() ->
                        result.error("NO_AUDIO", "No audio track found", null));
                    return;
                }
                extractor.selectTrack(audioTrack);
                android.media.MediaFormat trackFormat = extractor.getTrackFormat(audioTrack);
                muxer = new android.media.MediaMuxer(
                    outputPath, android.media.MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
                int outTrack = muxer.addTrack(trackFormat);
                muxer.start();
                extractor.seekTo(startUs, android.media.MediaExtractor.SEEK_TO_CLOSEST_SYNC);
                java.nio.ByteBuffer buffer = java.nio.ByteBuffer.allocate(1024 * 1024);
                android.media.MediaCodec.BufferInfo info = new android.media.MediaCodec.BufferInfo();
                while (true) {
                    int sampleSize = extractor.readSampleData(buffer, 0);
                    if (sampleSize < 0) break;
                    long sampleTime = extractor.getSampleTime();
                    if (sampleTime > endUs) break;
                    if (sampleTime >= startUs) {
                        info.offset = 0;
                        info.size = sampleSize;
                        info.presentationTimeUs = sampleTime - startUs;
                        info.flags = extractor.getSampleFlags();
                        muxer.writeSampleData(outTrack, buffer, info);
                    }
                    extractor.advance();
                }
                muxer.stop();
                new Handler(Looper.getMainLooper()).post(() -> result.success(outputPath));
            } catch (Exception e) {
                android.util.Log.e("hibiki-audio", "extractAudioSegment failed", e);
                new Handler(Looper.getMainLooper()).post(() ->
                    result.error("EXTRACT_ERROR", e.getMessage(), null));
            } finally {
                if (muxer != null) { try { muxer.release(); } catch (Exception ignored) {} }
                if (extractor != null) { extractor.release(); }
            }
        });
    }

    private void releaseMediaPlayer() {
        if (mediaPlayer != null) {
            mediaPlayer.stop();
            mediaPlayer.release();
            mediaPlayer = null;
        }
    }

    private void closeAudioDbLocked() {
        if (localAudioDb != null && localAudioDb.isOpen()) {
            localAudioDb.close();
        }
        localAudioDb = null;
    }
}
```

- [ ] **Step 2: Update MainActivity to use TtsChannelHandler**

In `MainActivity.java`:

Add field near other fields:
```java
    private TtsChannelHandler ttsChannelHandler;
```

In `onCreate()`, replace the TTS/MediaPlayer init (lines 131-137) with:
```java
        ttsChannelHandler = new TtsChannelHandler(context);
```

In `configureFlutterEngine()`, replace the entire TTS channel block (lines
490–838) with:
```java
        ttsChannelHandler.register(flutterEngine);
```

In `onDestroy()` (or wherever TTS cleanup exists), call:
```java
        ttsChannelHandler.destroy();
```

Remove the now-unused fields from MainActivity: `tts`, `ttsReady`,
`mediaPlayer`, `localAudioDb`, `localAudioDbPath`, `dbLock`, `ioExecutor`,
`dbSetupExecutor`, `indexFuture`, and all the `closeAudioDbLocked`-related
methods.

- [ ] **Step 3: Verify build**

Run: `cd hibiki/hibiki && flutter analyze && cd android && ./gradlew assembleDebug`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
cd hibiki/hibiki
git add android/app/src/main/java/app/hibiki/reader/TtsChannelHandler.java android/app/src/main/java/app/hibiki/reader/MainActivity.java
git commit -m "refactor(android): extract TtsChannelHandler from MainActivity

Modular handler for TTS, MediaPlayer, and local audio DB operations.
Owns its own state and can be registered by any Activity."
```

---

### Task 5: Android Popup Infrastructure

**Files:**
- Create: `android/app/src/main/java/app/hibiki/reader/PopupDictActivity.java`
- Modify: `android/app/src/main/res/values/styles.xml`
- Modify: `android/app/src/main/AndroidManifest.xml`

- [ ] **Step 1: Add PopupDictTheme to styles.xml**

In `android/app/src/main/res/values/styles.xml`, before the closing
`</resources>` tag, add:

```xml
    <style name="PopupDictTheme" parent="@android:style/Theme.Translucent.NoTitleBar">
        <item name="android:windowBackground">@android:color/transparent</item>
        <item name="android:windowIsFloating">true</item>
        <item name="android:windowIsTranslucent">true</item>
        <item name="android:backgroundDimEnabled">true</item>
        <item name="android:backgroundDimAmount">0.4</item>
        <item name="android:windowCloseOnTouchOutside">true</item>
        <item name="android:windowFullscreen">false</item>
    </style>
```

- [ ] **Step 2: Create PopupDictActivity.java**

Create `android/app/src/main/java/app/hibiki/reader/PopupDictActivity.java`:

```java
package app.hibiki.reader;

import android.content.Intent;
import android.os.Bundle;
import android.util.DisplayMetrics;
import android.view.WindowManager;

import androidx.annotation.NonNull;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class PopupDictActivity extends FlutterActivity {
    private static final String POPUP_CHANNEL = "app.hibiki.reader/popup";

    private MethodChannel popupChannel;
    private AnkiChannelHandler ankiChannelHandler;
    private TtsChannelHandler ttsChannelHandler;
    private String pendingProcessText;

    @NonNull
    @Override
    public String getDartEntrypointFunctionName() {
        return "popupMain";
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        ankiChannelHandler = new AnkiChannelHandler(this);
        ttsChannelHandler = new TtsChannelHandler(this);

        pendingProcessText = extractProcessText(getIntent());
        applyPopupWindowSize();
    }

    @Override
    protected void onNewIntent(@NonNull Intent intent) {
        super.onNewIntent(intent);
        String text = extractProcessText(intent);
        if (text != null && popupChannel != null) {
            popupChannel.invokeMethod("onNewProcessText", text);
        }
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);

        ankiChannelHandler.register(flutterEngine);
        ttsChannelHandler.register(flutterEngine);

        popupChannel = new MethodChannel(
            flutterEngine.getDartExecutor().getBinaryMessenger(), POPUP_CHANNEL);
        popupChannel.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "getInitialProcessText":
                    result.success(pendingProcessText);
                    break;
                case "finishPopup":
                    result.success(null);
                    finish();
                    break;
                default:
                    result.notImplemented();
            }
        });
    }

    @Override
    protected void onDestroy() {
        if (ttsChannelHandler != null) {
            ttsChannelHandler.destroy();
        }
        super.onDestroy();
    }

    private String extractProcessText(Intent intent) {
        if (intent == null) return null;
        return intent.getStringExtra(Intent.EXTRA_PROCESS_TEXT);
    }

    private void applyPopupWindowSize() {
        DisplayMetrics dm = getResources().getDisplayMetrics();
        float density = dm.density;
        int screenWidth = dm.widthPixels;
        int screenHeight = dm.heightPixels;

        int maxWidthPx = (int) (520 * density);
        int maxHeightPx = (int) (640 * density);
        int width = Math.min((int) (screenWidth * 0.92f), maxWidthPx);
        int height = Math.min((int) (screenHeight * 0.70f), maxHeightPx);

        WindowManager.LayoutParams params = getWindow().getAttributes();
        params.width = width;
        params.height = height;
        getWindow().setAttributes(params);
    }
}
```

- [ ] **Step 3: Update AndroidManifest.xml**

In `android/app/src/main/AndroidManifest.xml`:

**Remove** the PROCESS_TEXT intent filter from `MainActivity` (lines 63-67):
```xml
            <!-- DELETE THIS BLOCK -->
            <intent-filter>
                <action android:name="android.intent.action.PROCESS_TEXT" />
                <data android:mimeType="text/plain"/>
                <category android:name="android.intent.category.DEFAULT" />
            </intent-filter>
```

**Add** PopupDictActivity before the closing `</activity>` of MainActivity (i.e.
after line 67, before the `<service>` declarations). Add it as a new
`<activity>` element:

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

- [ ] **Step 4: Verify build**

Run: `cd hibiki/hibiki/android && ./gradlew assembleDebug`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
cd hibiki/hibiki
git add android/app/src/main/java/app/hibiki/reader/PopupDictActivity.java android/app/src/main/AndroidManifest.xml android/app/src/main/res/values/styles.xml
git commit -m "feat(android): add PopupDictActivity with dialog theme

Separate task affinity, singleTop launch mode, translucent floating window.
PROCESS_TEXT intent filter moved from MainActivity to PopupDictActivity.
Registers Anki and TTS channels; popup lifecycle channel for Dart comms."
```

---

### Task 6: Dart Popup Infrastructure

**Files:**
- Create: `lib/src/utils/misc/popup_channel.dart`
- Modify: `lib/src/models/app_model.dart`
- Create: `lib/popup_main.dart`

- [ ] **Step 1: Create popup_channel.dart**

Create `lib/src/utils/misc/popup_channel.dart`:

```dart
import 'package:flutter/services.dart';

class PopupChannel {
  PopupChannel._();
  static final PopupChannel instance = PopupChannel._();

  static const _channel = MethodChannel('app.hibiki.reader/popup');

  void Function(String)? _onNewProcessText;

  void init({void Function(String)? onNewProcessText}) {
    _onNewProcessText = onNewProcessText;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNewProcessText' && _onNewProcessText != null) {
        final text = call.arguments as String?;
        if (text != null && text.trim().isNotEmpty) {
          _onNewProcessText!(text);
        }
      }
    });
  }

  Future<String?> getInitialProcessText() async {
    try {
      final result = await _channel.invokeMethod<String>('getInitialProcessText');
      return result;
    } catch (_) {
      return null;
    }
  }

  Future<void> finishPopup() async {
    try {
      await _channel.invokeMethod<void>('finishPopup');
    } catch (_) {}
  }
}
```

- [ ] **Step 2: Add `initialiseForDictionaryPopup()` to AppModel**

In `lib/src/models/app_model.dart`, after `initialise()` (after line 1217), add:

```dart
  Future<void> initialiseForDictionaryPopup() async {
    try {
      debugPrint('[Hibiki-popup] init: PackageInfo + DeviceInfo');
      _packageInfo = await PackageInfo.fromPlatform();
      _androidDeviceInfo = await DeviceInfoPlugin().androidInfo;

      debugPrint('[Hibiki-popup] init: directories');
      _temporaryDirectory = await getTemporaryDirectory();
      _appDirectory = await getApplicationDocumentsDirectory();
      _databaseDirectory = await getApplicationSupportDirectory();

      debugPrint('[Hibiki-popup] init: Drift database');
      _database = HibikiDatabase(_databaseDirectory.path);

      _prefCache.addAll(await _database.getAllPrefs());

      final dictRows = await _database.getAllDictionaryMetadata();
      _dictionariesCache = dictRows.map(_rowToDictionary).toList()
        ..sort((a, b) => a.order.compareTo(b.order));

      _searchHistoryCache.clear();
      final shRows = await _database.getAllSearchHistoryItems();
      for (final row in shRows) {
        _searchHistoryCache
            .putIfAbsent(row.historyKey, () => [])
            .add(row.searchTerm);
      }

      _dictionaryHistoryResults.clear();
      final histRows = await _database.getAllDictionaryHistory();
      for (final row in histRows) {
        try {
          _dictionaryHistoryResults
              .add(DictionarySearchResult.fromJson(row.resultJson));
        } catch (e) {
          debugPrint('[Hibiki-popup] skipping corrupted dictionary history: $e');
        }
      }

      _browserDirectory = Directory(path.join(appDirectory.path, 'browser'));
      _thumbnailsDirectory =
          Directory(path.join(appDirectory.path, 'thumbnails'));
      _dictionaryResourceDirectory =
          Directory(path.join(appDirectory.path, 'dictionaryResources'));
      _dictionaryImportWorkingDirectory = Directory(
          path.join(appDirectory.path, 'dictionaryImportWorkingDirectory'));
      _exportDirectory = await prepareFallbackHibikiDirectory();
      _alternateExportDirectory = _exportDirectory;
      _webArchiveDirectory =
          Directory(path.join(appDirectory.path, 'webArchive'));

      thumbnailsDirectory.createSync();
      dictionaryImportWorkingDirectory.createSync();
      dictionaryResourceDirectory.createSync();
      _rebuildDictPathsCache();

      if (localAudioEnabled && localAudioDbPath.isNotEmpty) {
        final storedPath = localAudioDbPath;
        final internalPath =
            path.join(_databaseDirectory.path, 'local_audio.db');
        final storedExists = await File(storedPath).exists();
        final internalExists = await File(internalPath).exists();
        if (storedExists) {
          TtsChannel.instance.setLocalAudioDb(storedPath);
        } else if (internalExists) {
          TtsChannel.instance.setLocalAudioDb(internalPath);
        }
      }

      populateLanguages();
      populateLocales();
      LocaleSettings.setLocaleRaw(appLocale.toLanguageTag());
      populateMediaTypes();
      populateMediaSources();
      populateDictionaryFormats();
      populateEnhancements();

      await targetLanguage.initialise();

      for (Field field in globalFields) {
        for (Enhancement enhancement in enhancements[field]!.values) {
          await enhancement.initialise();
        }
      }

      debugPrint('[Hibiki-popup] init: DONE');
      _isInitialised = true;
      notifyListeners();
    } catch (e, stack) {
      debugPrint('[Hibiki-popup] init FAILED: $e\n$stack');
      _initError = '$e';
      notifyListeners();
    }
  }
```

- [ ] **Step 3: Create popup_main.dart**

Create `lib/popup_main.dart`:

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/popup_dictionary_page.dart';
import 'package:hibiki/src/utils/misc/popup_channel.dart';

@pragma('vm:entry-point')
void popupMain() {
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    final container = ProviderContainer();
    final appModel = container.read(appProvider);

    final initialText = await PopupChannel.instance.getInitialProcessText();

    await appModel.initialiseForDictionaryPopup();

    runApp(
      UncontrolledProviderScope(
        container: container,
        child: PopupDictApp(initialText: initialText ?? ''),
      ),
    );
  }, (exception, stack) {
    debugPrint('[Hibiki-popup] uncaught: $exception\n$stack');
  });
}

class PopupDictApp extends ConsumerStatefulWidget {
  const PopupDictApp({required this.initialText, super.key});
  final String initialText;

  @override
  ConsumerState<PopupDictApp> createState() => _PopupDictAppState();
}

class _PopupDictAppState extends ConsumerState<PopupDictApp> {
  late String _searchTerm;

  @override
  void initState() {
    super.initState();
    _searchTerm = widget.initialText;

    PopupChannel.instance.init(
      onNewProcessText: (text) {
        setState(() {
          _searchTerm = text;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final appModel = ref.watch(appProvider);

    if (!appModel.isInitialised) {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      final isDark = brightness == Brightness.dark;
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: isDark ? ThemeData.dark() : null,
        home: Scaffold(
          backgroundColor: isDark ? const Color(0xFF121212) : Colors.white,
          body: Center(
            child: CircularProgressIndicator(
              color: isDark ? Colors.white70 : null,
            ),
          ),
        ),
      );
    }

    if (appModel.initError != null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(child: Text('Init error: ${appModel.initError}')),
        ),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appModel.overrideDictionaryTheme ??
          ThemeData(
            colorSchemeSeed: const Color(0xFF1F4959),
            brightness: appModel.isDarkMode ? Brightness.dark : Brightness.light,
          ),
      home: PopupDictionaryPage(
        key: ValueKey(_searchTerm),
        searchTerm: _searchTerm,
      ),
    );
  }
}
```

- [ ] **Step 4: Verify**

Run: `cd hibiki/hibiki && flutter analyze lib/popup_main.dart lib/src/utils/misc/popup_channel.dart lib/src/models/app_model.dart`
Expected: No issues found (there will be an error about PopupDictionaryPage not existing yet — that's expected and will be fixed in Task 7).

- [ ] **Step 5: Commit**

```bash
cd hibiki/hibiki
git add lib/popup_main.dart lib/src/utils/misc/popup_channel.dart lib/src/models/app_model.dart
git commit -m "feat(popup): add Dart popup infrastructure

- popup_channel.dart: MethodChannel for intent data and lifecycle
- initialiseForDictionaryPopup(): lightweight AppModel init subset
- popup_main.dart: dedicated entry point for popup Flutter engine"
```

---

### Task 7: Popup Dictionary Page

**Files:**
- Create: `lib/src/pages/implementations/popup_dictionary_page.dart`

- [ ] **Step 1: Create popup_dictionary_page.dart**

Create `lib/src/pages/implementations/popup_dictionary_page.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/utils/misc/popup_channel.dart';
import 'package:hibiki/utils.dart';

class PopupDictionaryPage extends BasePage {
  const PopupDictionaryPage({
    required this.searchTerm,
    super.key,
  });

  final String searchTerm;

  @override
  BasePageState<PopupDictionaryPage> createState() =>
      _PopupDictionaryPageState();
}

class _PopupDictionaryPageState extends BasePageState<PopupDictionaryPage> {
  DictionarySearchResult? _result;
  bool _isSearching = false;
  late String _currentQuery;

  @override
  void initState() {
    super.initState();
    _currentQuery = widget.searchTerm;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _search(_currentQuery);
    });
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;

    setState(() {
      _isSearching = true;
      _currentQuery = query;
    });

    try {
      _result = await appModel.searchDictionary(
        searchTerm: query,
        searchWithWildcards: true,
        overrideMaximumTerms: appModel.maximumTerms,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
    }

    if (_result != null && _result!.entries.isNotEmpty) {
      appModel.addToSearchHistory(
        historyKey: 'DictionaryMediaType',
        searchTerm: query,
      );
      appModel.addToDictionaryHistory(result: _result!);
    }
  }

  Future<void> _close() async {
    await appModel.closeForPopup();
    await PopupChannel.instance.finishPopup();
  }

  @override
  Widget build(BuildContext context) {
    Color? backgroundColor = theme.colorScheme.surface;
    if (appModel.overrideDictionaryColor != null) {
      final dictTheme = appModel.overrideDictionaryTheme ?? theme;
      if (dictTheme.brightness == Brightness.dark) {
        backgroundColor =
            JidoujishoColor.lighten(appModel.overrideDictionaryColor!, 0.025);
      } else {
        backgroundColor =
            JidoujishoColor.darken(appModel.overrideDictionaryColor!, 0.025);
      }
    }

    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    Color? headerBg = appModel.isDarkMode
        ? const Color.fromARGB(255, 30, 30, 30)
        : const Color.fromARGB(255, 229, 229, 229);
    if (appModel.overrideDictionaryColor != null) {
      final dictTheme = appModel.overrideDictionaryTheme ?? theme;
      if (dictTheme.brightness == Brightness.dark) {
        headerBg =
            JidoujishoColor.lighten(appModel.overrideDictionaryColor!, 0.05);
      } else {
        headerBg =
            JidoujishoColor.darken(appModel.overrideDictionaryColor!, 0.05);
      }
    }

    return Material(
      color: headerBg,
      child: SizedBox(
        height: kToolbarHeight,
        child: Row(
          children: [
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _currentQuery,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: _close,
              tooltip: t.back,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isSearching && _result == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_result == null || _result!.entries.isEmpty) {
      return Center(
        child: JidoujishoPlaceholderMessage(
          icon: Icons.search_off,
          message: t.no_search_results,
        ),
      );
    }

    return DictionaryPopupWebView(
      key: ValueKey(_result),
      result: _result!,
      onTextSelected: (text) {
        _search(text);
      },
    );
  }

  @override
  void onSearch(String searchTerm, {String? sentence = ''}) async {
    _search(searchTerm);
  }
}
```

- [ ] **Step 2: Verify full analyze**

Run: `cd hibiki/hibiki && flutter analyze`
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
cd hibiki/hibiki
git add lib/src/pages/implementations/popup_dictionary_page.dart
git commit -m "feat(popup): add compact PopupDictionaryPage

Minimal chrome with close button. Reuses DictionaryPopupWebView for
full-fidelity rendering including audio, mining, and recursive lookup."
```

---

### Task 8: Build and Verify

**Files:** None (verification only)

- [ ] **Step 1: Full flutter analyze**

Run: `cd hibiki/hibiki && flutter analyze`
Expected: No issues found.

- [ ] **Step 2: Build release APK**

Run: `cd hibiki/hibiki && flutter build apk --release --split-per-abi`
Expected: Build succeeds, arm64 APK is produced.

- [ ] **Step 3: Install and test on emulator**

Install: `adb install build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`

Test plan:

```bash
# Test 1: Fresh popup launch
adb shell am start -a android.intent.action.PROCESS_TEXT \
  -t text/plain \
  --es android.intent.extra.PROCESS_TEXT "食べる" \
  -n app.hibiki.reader/.PopupDictActivity

# Test 2: Verify task isolation
adb shell dumpsys activity activities | grep -A 5 "hibiki"
# Confirm: popup is in task with affinity app.hibiki.reader.popup

# Test 3: Consecutive PROCESS_TEXT while popup is open
adb shell am start -a android.intent.action.PROCESS_TEXT \
  -t text/plain \
  --es android.intent.extra.PROCESS_TEXT "飲む" \
  -n app.hibiki.reader/.PopupDictActivity
# Confirm: query updates to 飲む without creating new popup
```

Manual checks on device/emulator:
- [ ] Popup appears as floating window, not full screen
- [ ] Tapping outside dismisses popup
- [ ] Close button dismisses popup
- [ ] Dictionary results render correctly (definitions, readings, frequency)
- [ ] Recursive lookup works (tap a word in the definition)
- [ ] Audio playback works
- [ ] After popup close, user returns to source app
- [ ] Main Hibiki app still works after popup use
- [ ] Main Hibiki running → open popup → close popup → main app state preserved
- [ ] Old killOnPop path (SEND/WEB_SEARCH) uses moveToBack instead of exit

- [ ] **Step 4: Commit version bump if everything passes**

Only if all checks pass — bump version number per project convention.
