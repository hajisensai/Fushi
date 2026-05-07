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
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
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
    private volatile Future<?> indexFuture;

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
        dbSetupExecutor.shutdown();
        try {
            dbSetupExecutor.awaitTermination(12, TimeUnit.SECONDS);
        } catch (InterruptedException ignored) {}
        synchronized (dbLock) {
            closeAudioDbLocked();
        }
        ioExecutor.shutdownNow();
        if (mediaPlayer != null) {
            mediaPlayer.release();
            mediaPlayer = null;
        }
        if (tts != null) {
            tts.shutdown();
            tts = null;
        }
    }

    private void handleSpeak(MethodCall call, MethodChannel.Result result) {
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

    private void handleTtsToFile(MethodCall call, MethodChannel.Result result) {
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

    private void handlePlayUrl(MethodCall call, MethodChannel.Result result) {
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

    private void handlePlayFile(MethodCall call, MethodChannel.Result result) {
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

    private void handleSetLocalAudioDb(MethodCall call, MethodChannel.Result result) {
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
                                    "WAL mode failed, queries may block during index creation");
                            }
                            final SQLiteDatabase db = localAudioDb;
                            indexFuture = ioExecutor.submit(() -> {
                                try {
                                    if (db.isOpen()) {
                                        db.execSQL(
                                            "CREATE INDEX IF NOT EXISTS idx_entries_expr_read ON entries(expression, reading)");
                                        db.execSQL(
                                            "CREATE INDEX IF NOT EXISTS idx_android_file_source ON android(file, source)");
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

    private void handleQueryLocalAudio(MethodCall call, MethodChannel.Result result) {
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

    private void handleExtractLocalAudio(MethodCall call, MethodChannel.Result result) {
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

    private void handleExtractAudioSegment(MethodCall call, MethodChannel.Result result) {
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
        if (indexFuture != null) {
            try {
                indexFuture.get(10, TimeUnit.SECONDS);
            } catch (Exception ignored) {}
            indexFuture = null;
        }
        if (localAudioDb != null) {
            localAudioDb.close();
            localAudioDb = null;
        }
    }
}
