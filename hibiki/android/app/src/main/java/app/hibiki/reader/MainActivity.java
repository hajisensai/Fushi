// Derived from the AnkiDroid API Sample

package app.hibiki.reader;

import android.app.Activity;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.KeyEvent;
import androidx.annotation.NonNull;
import android.net.Uri;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

import android.provider.Settings;
import android.media.AudioAttributes;
import android.media.MediaPlayer;
import android.speech.tts.TextToSpeech;
import java.util.Locale;

import com.ichi2.anki.FlashCardsContract;
import com.ichi2.anki.api.AddContentApi;
import android.content.ContentValues;
import android.content.SharedPreferences;
import android.graphics.drawable.ColorDrawable;
import androidx.core.content.FileProvider;
import android.content.ContentResolver;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.HashMap;
import java.util.Map;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import android.provider.DocumentsContract;
import android.database.Cursor;
import androidx.documentfile.provider.DocumentFile;

import com.ichi2.anki.api.NoteInfo;
import com.ryanheise.audioservice.AudioServiceActivity;
import android.content.Context;
import android.content.res.Configuration;
import android.database.sqlite.SQLiteDatabase;

public class MainActivity extends AudioServiceActivity {
    private static final String ANKIDROID_CHANNEL = "app.hibiki.reader/anki";
    private static final String VOLUME_KEY_CHANNEL = "app.hibiki.reader/volume_keys";
    private static final String SAF_CHANNEL = "app.hibiki.reader/saf";
    private static final String TTS_CHANNEL = "app.hibiki.reader/tts";
    private static final String UPDATE_CHANNEL = "app.hibiki.reader/update";
    private static final String FONTS_CHANNEL = "app.hibiki.reader/fonts";
    private static final String FLOATING_LYRIC_CHANNEL = "app.hibiki.reader/floating_lyric";
    private static final String SPLASH_CHANNEL = "app.hibiki.reader/splash";
    private static final String SPLASH_PREFS = "hibiki_splash";
    private static final int AD_PERM_REQUEST = 0;
    private static final int SAF_PICK_DIR_REQUEST = 1001;
    private static MethodChannel floatingLyricChannel;

    private Activity context;
    private AnkiDroidHelper mAnkiDroid;
    private MethodChannel.Result pendingSafResult;
    private String pendingSafDestPath;
    private TextToSpeech tts;
    private boolean ttsReady = false;
    private MediaPlayer mediaPlayer;
    private SQLiteDatabase localAudioDb;
    private String localAudioDbPath;

    // Reader opens this gate when volume-key page turning is enabled so
    // dispatchKeyEvent swallows VOLUME_UP/DOWN and forwards them to Dart.
    private volatile boolean volumeKeyIntercept = false;
    private MethodChannel volumeKeyChannel;

    @Override
    protected void attachBaseContext(Context newBase) {
        SharedPreferences prefs = newBase.getSharedPreferences(SPLASH_PREFS, MODE_PRIVATE);
        if (prefs.contains("is_dark")) {
            boolean isDark = prefs.getBoolean("is_dark", false);
            int currentNight = newBase.getResources().getConfiguration().uiMode
                    & Configuration.UI_MODE_NIGHT_MASK;
            boolean systemDark = currentNight == Configuration.UI_MODE_NIGHT_YES;
            if (isDark != systemDark) {
                Configuration config = new Configuration(
                        newBase.getResources().getConfiguration());
                config.uiMode = (config.uiMode & ~Configuration.UI_MODE_NIGHT_MASK)
                        | (isDark ? Configuration.UI_MODE_NIGHT_YES
                                  : Configuration.UI_MODE_NIGHT_NO);
                super.attachBaseContext(newBase.createConfigurationContext(config));
                return;
            }
        }
        super.attachBaseContext(newBase);
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        SharedPreferences splashPrefs = getSharedPreferences(SPLASH_PREFS, MODE_PRIVATE);
        int bgColor = splashPrefs.getInt("bg_color", 0);
        if (bgColor != 0) {
            getWindow().setBackgroundDrawable(new ColorDrawable(bgColor));
        }
        super.onCreate(savedInstanceState);
        isAppRunning = false;
        
        context = MainActivity.this;
        // Create the example data
        mAnkiDroid = new AnkiDroidHelper(context);

        tts = new TextToSpeech(context, status -> {
            if (status == TextToSpeech.SUCCESS) {
                int langResult = tts.setLanguage(Locale.JAPAN);
                ttsReady = (langResult != TextToSpeech.LANG_MISSING_DATA
                        && langResult != TextToSpeech.LANG_NOT_SUPPORTED);
            }
        });
    }
    

    private boolean deckExists(String deck) {
        Long deckId = mAnkiDroid.findDeckIdByName(deck);
        return (deckId != null);
    }

    private boolean modelExists(String model) {
        Long deckId = mAnkiDroid.findModelIdByName(model, 8);
        return (deckId != null);
    }

    private static boolean isAppRunning;

    public static boolean getIsAppRunning() {
        return isAppRunning;
    }

    public static void notifyFloatingLyricEvent(String method, Map<String, Object> arguments) {
        if (floatingLyricChannel == null) return;
        new Handler(Looper.getMainLooper()).post(() -> {
            floatingLyricChannel.invokeMethod(method, arguments);
        });
    }

    public void addDefaultModel() {
        final AddContentApi api = new AddContentApi(context);

        long modelId;
        if (modelExists("hibiki Kinomoto")) {
            modelId = mAnkiDroid.findModelIdByName("hibiki Kinomoto", 17);
        } else {
            modelId = api.addNewCustomModel("hibiki Kinomoto",
                new String[] {
                    "Term", 
                    "Reading",
                    "Furigana",
                    "Sentence",
                    "Cloze Before",
                    "Cloze Inside",
                    "Cloze After",
                    "Meaning",
                    "Expanded Meaning",
                    "Collapsed Meaning",
                    "Notes",
                    "Context",
                    "Frequency",
                    "Pitch Accent",
                    "Image",
                    "Term Audio",
                    "Sentence Audio",
                },
                new String[] {
                    "hibiki Kinomoto"
                },
                new String[] {
                    "<div id=\"word\">{{Term}}</div>"
                },
                new String[] {
                    "<div id=\"word\">{{#Furigana}}{{furigana:Furigana}}{{/Furigana}}{{^Furigana}}{{Term}}{{/Furigana}}</div>{{#Pitch Accent}}{{Pitch Accent}}{{/Pitch Accent}}\n{{#Image}}<div class=\"image\">{{Image}}</div>{{/Image}}\n{{#Term Audio}}{{Term Audio}}{{/Term Audio}}{{#Sentence Audio}}{{Sentence Audio}}{{/Sentence Audio}}\n<div id=\"sentence\">{{#Cloze Inside}}{{Cloze Before}}<span class=\"cloze\">{{Cloze Inside}}</span>{{Cloze After}}{{/Cloze Inside}}{{^Cloze Inside}}{{Sentence}}{{/Cloze Inside}}</div>\n{{#Meaning}}<p><small>{{Meaning}}</small></p>{{/Meaning}}\n{{#Expanded Meaning}}<p><small>{{Expanded Meaning}}</small></p>{{/Expanded Meaning}}{{#Collapsed Meaning}}<details><summary></summary><p><small>{{Collapsed Meaning}}</small></p></details><br>\n{{/Collapsed Meaning}}"
                },
                ".card {\n  font-family: \"Helvetica Neue\", Arial, sans-serif;\n  font-size: 16px;\n  text-align: center;\n  color: #333333;\n  background-color: #F6F6F6;\n  border-radius: 12px;\n  box-shadow: 0 6px 12px rgba(0, 0, 0, 0.2);\n  padding: 24px;\n  margin: 12px;\n  border: 1px solid #D9D9D9;\n}\n\n#word {\n  font-size: 30px;\n  font-weight: bold;\n  margin-bottom: 16px;\n}\n\n.details-summary {\n  cursor: pointer;\n  font-size: 16px;\n  text-shadow: 1px 1px #ffffff;\n  display: flex;\n  justify-content: space-between;\n  align-items: center;\n  margin-bottom: 16px;\n}\n\n.details-summary:hover {\n  color: #6495ED;\n}\n\n.details-summary:hover .arrow {\n  transform: translateX(4px);\n}\n\n.arrow {\n  fill: #777777;\n  transition: transform 0.2s ease-in-out;\n  margin-right: 8px;\n}\n\n.image img {\n  max-width: 100%;\n  height: 150px;\n  border-radius: 12px;\n  box-shadow: 0 6px 12px rgba(0, 0, 0, 0.2);\n  margin-top: 8px;\n  transition: height 0.2s ease-in-out;\n}\n\n.image:hover img {\n  height: auto;\n}\n\n.furigana {\n  font-size: 22px;\n  font-weight: bold;\n  line-height: 1.4;\n  margin-bottom: 16px;\n  text-shadow: 1px 1px #ffffff;\n}\n\n.meaning {\n  font-size: 18px;\n  line-height: 1.6;\n  margin-bottom: 16px;\n  text-shadow: 1px 1px #ffffff;\n}\n\n.cloze {\n  font-weight: 900\n}\n\n#sentence {\n  font-size: 20px;\n  line-height: 1.6;\n  margin-top: 16px;\n} \n\n.pitch {\n  border-top: solid red 2px;\n  padding-top: 1px;\n}\n\n.pitch_end {\n  border-color: red;\n  border-right: solid red 2px;\n  border-top: solid red 2px;  \n  line-height: 1px;\n  margin-right: 1px;\n  padding-right: 1px;\n  padding-top:1px;\n}",
                    null,
                    null
                    );
        }
    }

    private boolean checkForDuplicates(ArrayList<String> models, String key) {
        final AddContentApi api = new AddContentApi(context);
        for (int i = 0; i < models.size(); i++) {
            String model = models.get(i);
            Long mid = mAnkiDroid.findModelIdByName(model, 1);
            if (mid == null) {
                continue;
            }
            List<NoteInfo> notes = api.findDuplicateNotes(mid, key);
            if (!notes.isEmpty()) {
                return true;
            }
        }

        return false;
    }

    private void addNote(String model, String deck, ArrayList<String> fields, ArrayList<String> tags) {
        final AddContentApi api = new AddContentApi(context);

        long deckId;
        if (deckExists(deck)) {
            deckId = mAnkiDroid.findDeckIdByName(deck);
        } else {
            deckId = api.addNewDeck(deck);
        }

        long modelId = mAnkiDroid.findModelIdByName(model, fields.size());
       
        Set<String> allTags = new HashSet<>(Arrays.asList("Yuuna"));
        allTags.addAll(tags);

        api.addNote(modelId, deckId, fields.toArray(new String[fields.size()]), allTags);

        System.out.println("Added note via flutter_ankidroid_api");
        System.out.println("Model: " + modelId);
        System.out.println("Deck: " + deckId);
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        if (volumeKeyIntercept) {
            int code = event.getKeyCode();
            if (code == KeyEvent.KEYCODE_VOLUME_UP || code == KeyEvent.KEYCODE_VOLUME_DOWN) {
                if (event.getAction() == KeyEvent.ACTION_DOWN && volumeKeyChannel != null) {
                    final String method = code == KeyEvent.KEYCODE_VOLUME_UP
                            ? "onVolumeUp"
                            : "onVolumeDown";
                    new Handler(Looper.getMainLooper()).post(() -> {
                        volumeKeyChannel.invokeMethod(method, null);
                    });
                }
                return true;
            }
        }
        return super.dispatchKeyEvent(event);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == SAF_PICK_DIR_REQUEST) {
            if (pendingSafResult == null) return;
            final MethodChannel.Result safResult = pendingSafResult;
            final String destPath = pendingSafDestPath;
            pendingSafResult = null;
            pendingSafDestPath = null;
            if (resultCode != Activity.RESULT_OK || data == null || data.getData() == null) {
                safResult.success(null);
                return;
            }
            Uri treeUri = data.getData();
            new Thread(() -> {
                try {
                    DocumentFile dir = DocumentFile.fromTreeUri(context, treeUri);
                    if (dir == null || !dir.exists()) {
                        new Handler(Looper.getMainLooper()).post(() ->
                            safResult.error("NOT_FOUND", "Directory not found", null));
                        return;
                    }
                    File destDir = new File(destPath);
                    if (destDir.exists()) deleteRecursive(destDir);
                    destDir.mkdirs();
                    copyDocumentTree(dir, destDir);
                    new Handler(Looper.getMainLooper()).post(() ->
                        safResult.success(destPath));
                } catch (Exception e) {
                    new Handler(Looper.getMainLooper()).post(() ->
                        safResult.error("SAF_ERROR", e.getMessage(), null));
                }
            }).start();
        }
    }

    private void deleteRecursive(File f) {
        if (f.isDirectory()) {
            File[] children = f.listFiles();
            if (children != null) {
                for (File child : children) deleteRecursive(child);
            }
        }
        f.delete();
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);

        volumeKeyChannel = new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(), VOLUME_KEY_CHANNEL);
        volumeKeyChannel.setMethodCallHandler((call, result) -> {
            if ("setInterceptEnabled".equals(call.method)) {
                Object arg = call.arguments;
                volumeKeyIntercept = arg instanceof Boolean && (Boolean) arg;
                result.success(null);
            } else {
                result.notImplemented();
            }
        });

        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), ANKIDROID_CHANNEL)
            .setMethodCallHandler(
                (call, result) -> {
                    final String model = call.argument("model");
                    final String deck = call.argument("deck");
                    final String key = call.argument("key");
                    final ArrayList<String> fields = call.argument("fields"); 
                    final ArrayList<String> tags = call.argument("tags"); 
                    final ArrayList<String> models = call.argument("models"); 

                    final String filename = call.argument("filename");
                    final String preferredName = call.argument("preferredName");
                    final String mimeType = call.argument("mimeType");

                    final AddContentApi api = new AddContentApi(context);

                    switch (call.method) {
                        case "addNote":
                            addNote(model, deck, fields, tags);
                            result.success("Added note");
                            break;
                        case "checkForDuplicates":
                            if (mAnkiDroid.shouldRequestPermission()) {
                                result.success(false);
                                return;
                            } else {
                                new Handler(Looper.getMainLooper()).post(new Runnable() {
                                @Override
                                public void run() {
                                    result.success(checkForDuplicates(models, key));
                                }
                                });
                            }
                            break;
                        case "getDecks":
                            result.success(api.getDeckList());
                            break;
                        case "getModelList":
                            result.success(api.getModelList());
                            break;
                        case "getFieldList":
                            Long mid = mAnkiDroid.findModelIdByName(model, 1);
                            result.success(Arrays.asList(api.getFieldList(mid)));
                            break;
                        case "addDefaultModel":
                            addDefaultModel();
                            break;
                        case "requestAnkidroidPermissions":
                            if (mAnkiDroid.shouldRequestPermission()) {
                                mAnkiDroid.requestPermission(MainActivity.this, AD_PERM_REQUEST);
                            }
                            result.success(true);
                            break;
                        case "addFileToMedia":
                            System.out.println(filename);
                            System.out.println(preferredName);
                            System.out.println(mimeType);

                            // Workaround from KamWithK
                            // https://github.com/ankidroid/Anki-Android/issues/10335
  
                            File file = new File(filename);

                            Uri file_uri = FileProvider.getUriForFile(context, BuildConfig.APPLICATION_ID + ".provider", file);
                            context.grantUriPermission("com.ichi2.anki", file_uri, Intent.FLAG_GRANT_READ_URI_PERMISSION);

                            ContentValues contentValues = new ContentValues();
                            contentValues.put(FlashCardsContract.AnkiMedia.FILE_URI, file_uri.toString());
                            contentValues.put(FlashCardsContract.AnkiMedia.PREFERRED_NAME, preferredName);

                            ContentResolver contentResolver = context.getContentResolver();
                            Uri returnUri = contentResolver.insert(FlashCardsContract.AnkiMedia.CONTENT_URI, contentValues);

                            result.success(new File(returnUri.getPath()).toString().substring(1));

                            break;
                        default:
                            result.notImplemented();
                    }
                }
            );

        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), SAF_CHANNEL)
            .setMethodCallHandler((call, result) -> {
                switch (call.method) {
                    case "pickAndCopyDirectory": {
                        String destPath = call.argument("destPath");
                        if (destPath == null) {
                            result.error("INVALID_ARG", "destPath required", null);
                            return;
                        }
                        pendingSafResult = result;
                        pendingSafDestPath = destPath;
                        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
                        startActivityForResult(intent, SAF_PICK_DIR_REQUEST);
                        break;
                    }
                    default:
                        result.notImplemented();
                }
            });

        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), TTS_CHANNEL)
            .setMethodCallHandler((call, result) -> {
                switch (call.method) {
                    case "speak": {
                        String text = call.argument("text");
                        String locale = call.argument("locale");
                        if (text == null || text.isEmpty()) {
                            result.success(false);
                            return;
                        }
                        if (!ttsReady) {
                            result.success(false);
                            return;
                        }
                        if (locale != null && !locale.isEmpty()) {
                            String[] parts = locale.split("-");
                            Locale loc = parts.length >= 2
                                    ? new Locale(parts[0], parts[1])
                                    : new Locale(parts[0]);
                            tts.setLanguage(loc);
                        }
                        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "hibiki_lookup");
                        result.success(true);
                        break;
                    }
                    case "ttsToFile": {
                        String text = call.argument("text");
                        String locale = call.argument("locale");
                        String outputPath = call.argument("outputPath");
                        if (text == null || text.isEmpty() || outputPath == null) {
                            result.success(null);
                            return;
                        }
                        if (!ttsReady) {
                            result.success(null);
                            return;
                        }
                        if (locale != null && !locale.isEmpty()) {
                            String[] parts = locale.split("-");
                            Locale loc = parts.length >= 2
                                    ? new Locale(parts[0], parts[1])
                                    : new Locale(parts[0]);
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
                        break;
                    }
                    case "stop": {
                        if (ttsReady) tts.stop();
                        if (mediaPlayer != null) {
                            mediaPlayer.stop();
                            mediaPlayer.release();
                            mediaPlayer = null;
                        }
                        result.success(true);
                        break;
                    }
                    case "playUrl": {
                        String url = call.argument("url");
                        if (url == null || url.isEmpty()) {
                            result.success(false);
                            return;
                        }
                        if (mediaPlayer != null) {
                            mediaPlayer.stop();
                            mediaPlayer.release();
                            mediaPlayer = null;
                        }
                        try {
                            mediaPlayer = new MediaPlayer();
                            mediaPlayer.setAudioAttributes(
                                new AudioAttributes.Builder()
                                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                                    .setUsage(AudioAttributes.USAGE_MEDIA)
                                    .build()
                            );
                            mediaPlayer.setDataSource(url);
                            mediaPlayer.setOnPreparedListener(mp -> mp.start());
                            mediaPlayer.setOnCompletionListener(mp -> {
                                mp.release();
                                mediaPlayer = null;
                            });
                            mediaPlayer.setOnErrorListener((mp, what, extra) -> {
                                mp.release();
                                mediaPlayer = null;
                                return true;
                            });
                            mediaPlayer.prepareAsync();
                            result.success(true);
                        } catch (Exception e) {
                            result.success(false);
                        }
                        break;
                    }
                    case "setLocalAudioDb": {
                        String dbPath = call.argument("path");
                        if (localAudioDb != null) {
                            localAudioDb.close();
                            localAudioDb = null;
                        }
                        localAudioDbPath = dbPath;
                        if (dbPath != null && !dbPath.isEmpty()) {
                            try {
                                File dbFile = new File(dbPath);
                                if (dbFile.exists()) {
                                    localAudioDb = SQLiteDatabase.openDatabase(
                                        dbPath, null, SQLiteDatabase.OPEN_READWRITE | SQLiteDatabase.NO_LOCALIZED_COLLATORS);
                                    result.success(true);
                                    final SQLiteDatabase db = localAudioDb;
                                    new Thread(() -> {
                                        try {
                                            db.execSQL(
                                                "CREATE INDEX IF NOT EXISTS idx_entries_expr_read ON entries(expression, reading)");
                                            db.execSQL(
                                                "CREATE INDEX IF NOT EXISTS idx_android_file_source ON android(file, source)");
                                        } catch (Exception ignored) {}
                                    }).start();
                                } else {
                                    result.success(false);
                                }
                            } catch (Exception e) {
                                result.success(false);
                            }
                        } else {
                            result.success(true);
                        }
                        break;
                    }
                    case "queryLocalAudio": {
                        String expression = call.argument("expression");
                        String reading = call.argument("reading");
                        if (localAudioDb == null || expression == null) {
                            result.success(null);
                            return;
                        }
                        final SQLiteDatabase db = localAudioDb;
                        new Thread(() -> {
                            try {
                                Cursor entryCursor = db.rawQuery(
                                    "SELECT file, source FROM entries WHERE expression = ? AND reading = ? LIMIT 1",
                                    new String[]{expression, reading != null ? reading : ""});
                                if (entryCursor == null || !entryCursor.moveToFirst()) {
                                    if (entryCursor != null) entryCursor.close();
                                    entryCursor = db.rawQuery(
                                        "SELECT file, source FROM entries WHERE expression = ? LIMIT 1",
                                        new String[]{expression});
                                }
                                if (entryCursor != null && entryCursor.moveToFirst()) {
                                    String file = entryCursor.getString(0);
                                    String source = entryCursor.getString(1);
                                    entryCursor.close();
                                    Map<String, String> info = new HashMap<>();
                                    info.put("file", file);
                                    info.put("source", source);
                                    new Handler(Looper.getMainLooper()).post(() -> result.success(info));
                                } else {
                                    if (entryCursor != null) entryCursor.close();
                                    new Handler(Looper.getMainLooper()).post(() -> result.success(null));
                                }
                            } catch (Exception e) {
                                new Handler(Looper.getMainLooper()).post(() -> result.success(null));
                            }
                        }).start();
                        break;
                    }
                    case "extractLocalAudio": {
                        String fileArg = call.argument("file");
                        String sourceArg = call.argument("source");
                        if (localAudioDb == null || fileArg == null || sourceArg == null) {
                            result.success(null);
                            return;
                        }
                        final SQLiteDatabase db = localAudioDb;
                        final File cacheDir = getCacheDir();
                        new Thread(() -> {
                            try {
                                Cursor audioCursor = db.rawQuery(
                                    "SELECT data FROM android WHERE file = ? AND source = ? LIMIT 1",
                                    new String[]{fileArg, sourceArg});
                                if (audioCursor != null && audioCursor.moveToFirst()) {
                                    byte[] audioData = audioCursor.getBlob(0);
                                    audioCursor.close();
                                    String ext = fileArg.endsWith(".opus") ? ".opus" : ".mp3";
                                    File tempFile = new File(cacheDir, "local_audio" + ext);
                                    FileOutputStream fos = new FileOutputStream(tempFile);
                                    fos.write(audioData);
                                    fos.close();
                                    new Handler(Looper.getMainLooper()).post(() ->
                                        result.success(tempFile.getAbsolutePath()));
                                } else {
                                    if (audioCursor != null) audioCursor.close();
                                    new Handler(Looper.getMainLooper()).post(() -> result.success(null));
                                }
                            } catch (Exception e) {
                                new Handler(Looper.getMainLooper()).post(() -> result.success(null));
                            }
                        }).start();
                        break;
                    }
                    case "extractAudioSegment": {
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
                        new Thread(() -> {
                            try {
                                android.media.MediaExtractor extractor = new android.media.MediaExtractor();
                                extractor.setDataSource(inputPath);
                                int audioTrack = -1;
                                String mime = null;
                                for (int i = 0; i < extractor.getTrackCount(); i++) {
                                    android.media.MediaFormat fmt = extractor.getTrackFormat(i);
                                    String m = fmt.getString(android.media.MediaFormat.KEY_MIME);
                                    if (m != null && m.startsWith("audio/")) {
                                        audioTrack = i;
                                        mime = m;
                                        break;
                                    }
                                }
                                if (audioTrack < 0) {
                                    extractor.release();
                                    new Handler(Looper.getMainLooper()).post(() ->
                                        result.error("NO_AUDIO", "No audio track found", null));
                                    return;
                                }
                                extractor.selectTrack(audioTrack);
                                android.media.MediaFormat trackFormat = extractor.getTrackFormat(audioTrack);
                                android.media.MediaMuxer muxer = new android.media.MediaMuxer(
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
                                muxer.release();
                                extractor.release();
                                new Handler(Looper.getMainLooper()).post(() -> result.success(outputPath));
                            } catch (Exception e) {
                                new Handler(Looper.getMainLooper()).post(() ->
                                    result.error("EXTRACT_ERROR", e.getMessage(), null));
                            }
                        }).start();
                        break;
                    }
                    case "playFile": {
                        String filePath = call.argument("path");
                        if (filePath == null || filePath.isEmpty()) {
                            result.success(false);
                            return;
                        }
                        if (mediaPlayer != null) {
                            mediaPlayer.stop();
                            mediaPlayer.release();
                            mediaPlayer = null;
                        }
                        try {
                            mediaPlayer = new MediaPlayer();
                            mediaPlayer.setAudioAttributes(
                                new AudioAttributes.Builder()
                                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                                    .setUsage(AudioAttributes.USAGE_MEDIA)
                                    .build()
                            );
                            mediaPlayer.setDataSource(filePath);
                            mediaPlayer.setOnPreparedListener(mp -> mp.start());
                            mediaPlayer.setOnCompletionListener(mp -> {
                                mp.release();
                                mediaPlayer = null;
                            });
                            mediaPlayer.setOnErrorListener((mp, what, extra) -> {
                                mp.release();
                                mediaPlayer = null;
                                return true;
                            });
                            mediaPlayer.prepare();
                            result.success(true);
                        } catch (Exception e) {
                            result.success(false);
                        }
                        break;
                    }
                    default:
                        result.notImplemented();
                }
            });

        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), UPDATE_CHANNEL)
            .setMethodCallHandler((call, result) -> {
                if ("installApk".equals(call.method)) {
                    String path = call.argument("path");
                    if (path == null || path.isEmpty()) {
                        result.error("INVALID_PATH", "APK path is null", null);
                        return;
                    }
                    try {
                        File apkFile = new File(path);
                        Uri apkUri = FileProvider.getUriForFile(
                                context,
                                BuildConfig.APPLICATION_ID + ".provider",
                                apkFile);
                        Intent intent = new Intent(Intent.ACTION_VIEW);
                        intent.setDataAndType(apkUri, "application/vnd.android.package-archive");
                        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                        context.startActivity(intent);
                        result.success(true);
                    } catch (Exception e) {
                        result.error("INSTALL_ERROR", e.getMessage(), null);
                    }
                } else {
                    result.notImplemented();
                }
            });

        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), SPLASH_CHANNEL)
            .setMethodCallHandler((call, result) -> {
                SharedPreferences prefs = getSharedPreferences(SPLASH_PREFS, MODE_PRIVATE);
                switch (call.method) {
                    case "setSplashColor": {
                        Map<String, Object> args = (Map<String, Object>) call.arguments;
                        Number colorNumber = (Number) args.get("color");
                        int color = colorNumber.intValue();
                        boolean isDark = (boolean) args.get("isDark");
                        prefs.edit()
                             .putInt("bg_color", color)
                             .putBoolean("is_dark", isDark)
                             .apply();
                        getWindow().setBackgroundDrawable(new ColorDrawable(color));
                        result.success(null);
                        break;
                    }
                    case "getSplashColor": {
                        int color = prefs.getInt("bg_color", 0);
                        result.success(color);
                        break;
                    }
                    default:
                        result.notImplemented();
                }
            });

        floatingLyricChannel = new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(), FLOATING_LYRIC_CHANNEL);
        floatingLyricChannel.setMethodCallHandler((call, result) -> {
                switch (call.method) {
                    case "show": {
                        if (!Settings.canDrawOverlays(context)) {
                            Intent intent = new Intent(
                                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    Uri.parse("package:" + getPackageName()));
                            startActivity(intent);
                            result.success(false);
                            return;
                        }
                        Intent svc = new Intent(context, FloatingLyricService.class);
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(svc);
                        } else {
                            startService(svc);
                        }
                        result.success(true);
                        break;
                    }
                    case "hide": {
                        stopService(new Intent(context, FloatingLyricService.class));
                        result.success(true);
                        break;
                    }
                    case "updateText": {
                        String text = call.argument("text");
                        FloatingLyricService svc = FloatingLyricService.getInstance();
                        if (svc != null && text != null) {
                            svc.updateLyricText(text);
                        }
                        result.success(null);
                        break;
                    }
                    case "updateStyle": {
                        Number size = call.argument("fontSize");
                        Number color = call.argument("textColor");
                        Number bg = call.argument("bgColor");
                        Number buttonTextColor = call.argument("buttonTextColor");
                        Number buttonBgColor = call.argument("buttonBgColor");
                        Number highlightColor = call.argument("highlightColor");
                        Number activeColor = call.argument("activeColor");
                        FloatingLyricService svc = FloatingLyricService.getInstance();
                        if (svc != null) {
                            svc.updateStyle(
                                    size != null ? size.floatValue() : 16f,
                                    color != null ? color.intValue() : 0xFFFFFFFF,
                                    bg != null ? bg.intValue() : 0xCC000000,
                                    buttonTextColor != null ? buttonTextColor.intValue() : 0xFFFFFFFF,
                                    buttonBgColor != null ? buttonBgColor.intValue() : 0x33000000,
                                    highlightColor != null ? highlightColor.intValue() : 0x80FFD54F,
                                    activeColor != null ? activeColor.intValue() : 0xFFFFD54F);
                        }
                        result.success(null);
                        break;
                    }
                    case "highlight": {
                        Number start = call.argument("start");
                        Number length = call.argument("length");
                        FloatingLyricService svc = FloatingLyricService.getInstance();
                        if (svc != null) {
                            svc.updateHighlight(
                                    start != null ? start.intValue() : -1,
                                    length != null ? length.intValue() : 0);
                        }
                        result.success(null);
                        break;
                    }
                    case "updateLabels": {
                        Object labels = call.arguments;
                        FloatingLyricService svc = FloatingLyricService.getInstance();
                        if (svc != null && labels instanceof Map) {
                            svc.updateLabels((Map<String, Object>) labels);
                        }
                        result.success(null);
                        break;
                    }
                    case "setLocked": {
                        Boolean locked = call.argument("locked");
                        FloatingLyricService svc = FloatingLyricService.getInstance();
                        if (svc != null) {
                            svc.setLocked(locked != null && locked);
                        }
                        result.success(null);
                        break;
                    }
                    case "setPlaybackState": {
                        Boolean playing = call.argument("playing");
                        FloatingLyricService svc = FloatingLyricService.getInstance();
                        if (svc != null) {
                            svc.setPlaybackState(playing != null && playing);
                        }
                        result.success(null);
                        break;
                    }
                    case "isShowing": {
                        result.success(FloatingLyricService.getInstance() != null);
                        break;
                    }
                    case "canDrawOverlays": {
                        result.success(Settings.canDrawOverlays(context));
                        break;
                    }
                    default:
                        result.notImplemented();
                }
            });

        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), FONTS_CHANNEL)
            .setMethodCallHandler((call, result) -> {
                if ("listSystemFonts".equals(call.method)) {
                    new Thread(() -> {
                        TreeSet<String> families = new TreeSet<>(String.CASE_INSENSITIVE_ORDER);
                        // 1) 解析 /system/etc/fonts.xml
                        try {
                            File xml = new File("/system/etc/fonts.xml");
                            if (xml.exists()) {
                                BufferedReader reader = new BufferedReader(
                                        new InputStreamReader(new FileInputStream(xml)));
                                StringBuilder sb = new StringBuilder();
                                String line;
                                while ((line = reader.readLine()) != null) {
                                    sb.append(line);
                                }
                                reader.close();
                                Pattern p = Pattern.compile("<family\\s+name=\"([^\"]+)\"");
                                Matcher m = p.matcher(sb.toString());
                                while (m.find()) {
                                    families.add(m.group(1));
                                }
                            }
                        } catch (Exception ignored) {}
                        // 2) 扫描 /system/fonts/ 目录
                        try {
                            File dir = new File("/system/fonts");
                            if (dir.exists() && dir.isDirectory()) {
                                File[] files = dir.listFiles();
                                if (files != null) {
                                    for (File f : files) {
                                        String name = f.getName();
                                        if (name.endsWith(".ttf") || name.endsWith(".otf") || name.endsWith(".ttc")) {
                                            String base = name.replaceAll("\\.(ttf|otf|ttc)$", "");
                                            base = base.replaceAll("-(Regular|Bold|Italic|BoldItalic|Light|Medium|Thin|Black|SemiBold|ExtraBold|ExtraLight)$", "");
                                            families.add(base);
                                        }
                                    }
                                }
                            }
                        } catch (Exception ignored) {}
                        List<String> sorted = new ArrayList<>(families);
                        android.util.Log.d("hibiki-fonts", "Found " + sorted.size() + " fonts: " + sorted.subList(0, Math.min(5, sorted.size())));
                        new Handler(Looper.getMainLooper()).post(() -> result.success(sorted));
                    }).start();
                } else {
                    result.notImplemented();
                }
            });
    }

    private void copyDocumentTree(DocumentFile srcDir, File destDir) throws Exception {
        for (DocumentFile child : srcDir.listFiles()) {
            String name = child.getName();
            if (name == null) continue;
            if (child.isDirectory()) {
                File subDir = new File(destDir, name);
                subDir.mkdirs();
                copyDocumentTree(child, subDir);
            } else {
                long size = child.length();
                if (size > 50 * 1024 * 1024) {
                    // Large file: create a symlink-like proxy by opening a
                    // FileDescriptor and hard-linking via /proc/self/fd.
                    try {
                        android.os.ParcelFileDescriptor pfd =
                            getContentResolver().openFileDescriptor(child.getUri(), "r");
                        if (pfd != null) {
                            String fdPath = "/proc/self/fd/" + pfd.getFd();
                            File destFile = new File(destDir, name);
                            // Copy via fd path which bypasses SAF permission issues
                            try (InputStream in = new java.io.FileInputStream(fdPath);
                                 OutputStream out = new FileOutputStream(destFile)) {
                                byte[] buf = new byte[65536];
                                int len;
                                while ((len = in.read(buf)) > 0) {
                                    out.write(buf, 0, len);
                                }
                            }
                            pfd.close();
                        }
                    } catch (Exception e) {
                        // Fallback: copy via ContentResolver stream
                        copyFile(child, new File(destDir, name));
                    }
                } else {
                    copyFile(child, new File(destDir, name));
                }
            }
        }
    }

    private void copyFile(DocumentFile src, File dest) throws Exception {
        try (InputStream in = getContentResolver().openInputStream(src.getUri());
             OutputStream out = new FileOutputStream(dest)) {
            if (in == null) return;
            byte[] buf = new byte[8192];
            int len;
            while ((len = in.read(buf)) > 0) {
                out.write(buf, 0, len);
            }
        }
    }
}
