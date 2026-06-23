package app.hibiki.reader;

import android.app.Activity;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.media.AudioAttributes;
import android.media.MediaMetadataRetriever;
import android.media.MediaPlayer;
import android.os.Handler;
import android.os.Looper;
import android.speech.tts.TextToSpeech;

import androidx.annotation.NonNull;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

import app.hibiki.reader.constants.ChannelNames;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

public class TtsChannelHandler {
    private static final String CHANNEL = ChannelNames.TTS;

    private final Activity activity;
    private TextToSpeech tts;
    private boolean ttsReady = false;
    // 复用单个 MediaPlayer 实例（reset() 重置而非 new）以省去每次 new 的分配 +
    // 状态机重建开销（TODO-744）。所有 play/stop 入口都跑在 method-channel 的
    // 主线程上，天然串行，无需额外锁。
    private MediaPlayer mediaPlayer;
    // 每次 play/stop 自增；prepareAsync/completion/error 回调对比提交时的世代，
    // 让被后续播放/停止取代的旧回调直接 bail，不误动已复用的 player。
    private int playGeneration = 0;
    private final List<SQLiteDatabase> localAudioDbs = new ArrayList<>();
    private final List<String> localAudioDbPaths = new ArrayList<>();
    // 与 localAudioDbs 同 index 对齐：每库启用子来源的优先级序（首=最高）。
    // 空 list = 该库不限制（全启用、DB 自然序），兼容无配置的旧库。
    private final List<List<String>> localAudioDbOrders = new ArrayList<>();
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
                    case "listLocalAudioSources":
                        handleListLocalAudioSources(call, result);
                        break;
                    case "extractLocalAudio":
                        handleExtractLocalAudio(call, result);
                        break;
                    case "extractAudioSegment":
                        handleExtractAudioSegment(call, result);
                        break;
                    case "extractEmbeddedCover":
                        handleExtractEmbeddedCover(call, result);
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
            closeAllAudioDbsLocked();
        }
        ioExecutor.shutdownNow();
        // 让在途回调失效后再释放唯一实例（最终拆除，不再复用）。
        playGeneration++;
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
        // Guard against double-invocation: the listener callback runs on a TTS
        // background thread, and synthesizeToFile may fail synchronously below.
        // Without this guard, both paths could call result.success().
        final AtomicBoolean resultSent = new AtomicBoolean(false);
        final Handler mainHandler = new Handler(Looper.getMainLooper());
        tts.setOnUtteranceProgressListener(new android.speech.tts.UtteranceProgressListener() {
            @Override public void onStart(String utteranceId) {}
            @Override public void onDone(String utteranceId) {
                tts.setOnUtteranceProgressListener(null);
                if (resultSent.compareAndSet(false, true)) {
                    mainHandler.post(() -> result.success(outputPath));
                }
            }
            @Override public void onError(String utteranceId) {
                tts.setOnUtteranceProgressListener(null);
                if (resultSent.compareAndSet(false, true)) {
                    mainHandler.post(() -> result.success(null));
                }
            }
        });
        File outFile = new File(outputPath);
        int r = tts.synthesizeToFile(text, null, outFile, "hibiki_tts_file");
        if (r != TextToSpeech.SUCCESS) {
            tts.setOnUtteranceProgressListener(null);
            if (resultSent.compareAndSet(false, true)) {
                result.success(null);
            }
        }
    }

    private void handleStop(MethodChannel.Result result) {
        if (ttsReady) tts.stop();
        // 让任何在途的 prepareAsync/completion 回调失效，再 reset() 回 Idle 复用，
        // 不 release（实例留到 destroy 才释放）。
        playGeneration++;
        if (mediaPlayer != null) {
            try {
                mediaPlayer.reset();
            } catch (IllegalStateException e) {
                android.util.Log.w("hibiki-audio", "stop reset failed", e);
            }
        }
        result.success(true);
    }

    private void handlePlayUrl(MethodCall call, MethodChannel.Result result) {
        String url = call.argument("url");
        startPlayback(url, readVolume(call), true, "playUrl", result);
    }

    private void handlePlayFile(MethodCall call, MethodChannel.Result result) {
        String filePath = call.argument("path");
        startPlayback(filePath, readVolume(call), false, "playFile", result);
    }

    /// 复用单个 MediaPlayer：reset() 回 Idle 而非 new + release，状态机走
    /// reset→setDataSource→prepare(Async)→start。每次自增 playGeneration，回调
    /// 比对世代后才动 player，使被后续播放/停止取代的旧回调直接 bail（TODO-744）。
    /// [async] = true 用 prepareAsync（远程 URL），false 用同步 prepare（本地文件）。
    private void startPlayback(String dataSource, float volume, boolean async,
                               String tag, MethodChannel.Result result) {
        if (dataSource == null || dataSource.isEmpty()) {
            result.success(false);
            return;
        }
        final int generation = ++playGeneration;
        try {
            MediaPlayer mp = ensureMediaPlayer();
            // Idle 状态（new / reset 后）：可安全设置 attributes / dataSource。
            mp.reset();
            mp.setAudioAttributes(
                new AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .build());
            mp.setDataSource(dataSource);
            mp.setVolume(volume, volume);
            mp.setOnPreparedListener(p -> {
                // 被取代则不要 start（player 可能已被下一次播放重置）。
                if (generation != playGeneration) return;
                try {
                    p.start();
                } catch (IllegalStateException e) {
                    android.util.Log.w("hibiki-audio", tag + " start failed", e);
                }
            });
            // 播完不 release，reset() 回 Idle 留待下次复用（仅当世代未变）。
            mp.setOnCompletionListener(p -> {
                if (generation != playGeneration) return;
                resetMediaPlayerQuietly();
            });
            mp.setOnErrorListener((p, what, extra) -> {
                // 出错后 player 进入 Error 态，必须 reset() 才能再次复用。
                if (generation == playGeneration) {
                    resetMediaPlayerQuietly();
                }
                return true;
            });
            if (async) {
                mp.prepareAsync();
            } else {
                mp.prepare();
                // 同步 prepare 返回即 Prepared，回调不会触发，这里直接 start。
                if (generation == playGeneration) mp.start();
            }
            result.success(true);
        } catch (Exception e) {
            android.util.Log.w("hibiki-audio", tag + " failed", e);
            // 失败后把 player 拉回干净的 Idle 态，避免污染下次复用。
            resetMediaPlayerQuietly();
            result.success(false);
        }
    }

    /// 懒创建唯一的 MediaPlayer 实例（仅在主线程调用）。
    private MediaPlayer ensureMediaPlayer() {
        if (mediaPlayer == null) {
            mediaPlayer = new MediaPlayer();
        }
        return mediaPlayer;
    }

    /// 把 player 重置回 Idle，吞掉任何 IllegalState（实例保留以供复用）。
    private void resetMediaPlayerQuietly() {
        if (mediaPlayer == null) return;
        try {
            mediaPlayer.reset();
        } catch (IllegalStateException e) {
            android.util.Log.w("hibiki-audio", "reset failed", e);
        }
    }

    private float readVolume(MethodCall call) {
        Number raw = call.argument("volume");
        if (raw == null) return 1.0f;
        return Math.max(0.0f, Math.min(1.0f, raw.floatValue()));
    }

    private void handleSetLocalAudioDb(MethodCall call, MethodChannel.Result result) {
        List<String> dbPaths = call.argument("paths");
        if (dbPaths == null) dbPaths = new ArrayList<>();
        final List<String> paths = dbPaths;

        // path -> 启用子来源优先级序。来自 'dbConfigs'；缺省空表示该库不限制。
        final Map<String, List<String>> orderByPath = new HashMap<>();
        List<Map<String, Object>> dbConfigs = call.argument("dbConfigs");
        if (dbConfigs != null) {
            for (Map<String, Object> cfg : dbConfigs) {
                if (cfg == null) continue;
                Object p = cfg.get("path");
                Object o = cfg.get("order");
                if (!(p instanceof String)) continue;
                List<String> order = new ArrayList<>();
                if (o instanceof List) {
                    for (Object s : (List<?>) o) {
                        if (s instanceof String) order.add((String) s);
                    }
                }
                orderByPath.put((String) p, order);
            }
        }

        dbSetupExecutor.execute(() -> {
            synchronized (dbLock) {
                closeAllAudioDbsLocked();

                for (String dbPath : paths) {
                    if (dbPath == null || dbPath.isEmpty()) continue;
                    try {
                        File dbFile = new File(dbPath);
                        if (!dbFile.exists()) {
                            android.util.Log.w("hibiki-audio",
                                "DB not found, skipping: " + dbPath);
                            continue;
                        }
                        SQLiteDatabase db = SQLiteDatabase.openDatabase(
                            dbPath, null,
                            SQLiteDatabase.OPEN_READWRITE
                                | SQLiteDatabase.NO_LOCALIZED_COLLATORS);
                        db.enableWriteAheadLogging();
                        localAudioDbPaths.add(dbPath);
                        localAudioDbs.add(db);
                        // 开库成功后再记 order，保证与 localAudioDbs 的 index 对齐。
                        List<String> order = orderByPath.get(dbPath);
                        localAudioDbOrders.add(order != null ? order : new ArrayList<>());
                    } catch (Exception e) {
                        android.util.Log.e("hibiki-audio",
                            "Failed to open DB: " + dbPath, e);
                    }
                }

                final List<SQLiteDatabase> snapshot = new ArrayList<>(localAudioDbs);
                indexFuture = ioExecutor.submit(() -> {
                    for (SQLiteDatabase db : snapshot) {
                        try {
                            if (db.isOpen()) {
                                db.execSQL(
                                    "CREATE INDEX IF NOT EXISTS idx_entries_expr_read ON entries(expression, reading)");
                                db.execSQL(
                                    "CREATE INDEX IF NOT EXISTS idx_android_file_source ON android(file, source)");
                            }
                        } catch (Exception e) {
                            android.util.Log.w("hibiki-audio",
                                "Index creation skipped", e);
                        }
                    }
                });
                activity.runOnUiThread(() -> result.success(true));
            }
        });
    }

    private void handleQueryLocalAudio(MethodCall call, MethodChannel.Result result) {
        String expression = call.argument("expression");
        String reading = call.argument("reading");
        Integer dbIndexArg = call.argument("dbIndex");
        if (localAudioDbs.isEmpty() || expression == null) {
            result.success(null);
            return;
        }
        ioExecutor.execute(() -> {
            synchronized (dbLock) {
                int start = (dbIndexArg != null) ? dbIndexArg : 0;
                int end = (dbIndexArg != null) ? dbIndexArg + 1 : localAudioDbs.size();
                for (int i = start; i < end && i < localAudioDbs.size(); i++) {
                    if (i < 0) continue;
                    SQLiteDatabase db = localAudioDbs.get(i);
                    if (db == null || !db.isOpen()) continue;
                    List<String> order = (i < localAudioDbOrders.size())
                        ? localAudioDbOrders.get(i) : null;
                    Cursor cursor = null;
                    try {
                        // order 为空走快路径（LIMIT 1）；非空要取全部候选行再按序挑。
                        boolean ordered = order != null && !order.isEmpty();
                        String limit = ordered ? "" : " LIMIT 1";
                        cursor = db.rawQuery(
                            "SELECT file, source FROM entries WHERE expression = ? AND reading = ?" + limit,
                            new String[]{expression, reading != null ? reading : ""});
                        if (cursor == null || !cursor.moveToFirst()) {
                            if (cursor != null) cursor.close();
                            cursor = db.rawQuery(
                                "SELECT file, source FROM entries WHERE expression = ?" + limit,
                                new String[]{expression});
                        }
                        String[] picked = pickByOrder(cursor, order);
                        if (picked != null) {
                            final int dbIndex = i;
                            Map<String, Object> info = new HashMap<>();
                            info.put("file", picked[0]);
                            info.put("source", picked[1]);
                            info.put("dbIndex", dbIndex);
                            new Handler(Looper.getMainLooper()).post(
                                () -> result.success(info));
                            return;
                        }
                    } catch (Exception e) {
                        android.util.Log.w("hibiki-audio",
                            "queryLocalAudio failed on DB " + i, e);
                    } finally {
                        if (cursor != null) cursor.close();
                    }
                }
                new Handler(Looper.getMainLooper()).post(() -> result.success(null));
            }
        });
    }

    /// 从候选行里按 [order] 选 source 优先级最高（rank 最小且 >=0）的一行。
    /// order 为空 → 返回首行（兼容无配置旧库）；全被过滤掉 → null。
    /// 返回 {file, source}。
    private static String[] pickByOrder(Cursor cursor, List<String> order) {
        if (cursor == null || !cursor.moveToFirst()) return null;
        if (order == null || order.isEmpty()) {
            return new String[]{cursor.getString(0), cursor.getString(1)};
        }
        String[] best = null;
        int bestRank = Integer.MAX_VALUE;
        do {
            String source = cursor.getString(1);
            int rank = order.indexOf(source);
            if (rank < 0) continue; // 禁用 / 未列入 → 跳过
            if (rank < bestRank) {
                bestRank = rank;
                best = new String[]{cursor.getString(0), source};
            }
        } while (cursor.moveToNext());
        return best;
    }

    /// 枚举一个本地音频库内全部子来源（SELECT DISTINCT source）。
    /// 用独立 read-only 连接，避开与播放查询共享 db 的锁竞争 / 并发关闭。
    private void handleListLocalAudioSources(MethodCall call, MethodChannel.Result result) {
        String path = call.argument("path");
        if (path == null || path.isEmpty()) {
            result.success(new ArrayList<String>());
            return;
        }
        ioExecutor.execute(() -> {
            List<String> sources = new ArrayList<>();
            SQLiteDatabase db = null;
            try {
                File f = new File(path);
                if (f.exists()) {
                    db = SQLiteDatabase.openDatabase(path, null,
                        SQLiteDatabase.OPEN_READONLY
                            | SQLiteDatabase.NO_LOCALIZED_COLLATORS);
                    try (Cursor c = db.rawQuery(
                            "SELECT DISTINCT source FROM entries", null)) {
                        while (c != null && c.moveToNext()) {
                            String s = c.getString(0);
                            if (s != null) sources.add(s);
                        }
                    }
                }
            } catch (Exception e) {
                android.util.Log.w("hibiki-audio",
                    "listLocalAudioSources failed: " + path, e);
            } finally {
                if (db != null && db.isOpen()) db.close();
            }
            final List<String> out = sources;
            new Handler(Looper.getMainLooper()).post(() -> result.success(out));
        });
    }

    private void handleExtractLocalAudio(MethodCall call, MethodChannel.Result result) {
        String fileArg = call.argument("file");
        String sourceArg = call.argument("source");
        Integer dbIndexArg = call.argument("dbIndex");
        if (localAudioDbs.isEmpty() || fileArg == null || sourceArg == null) {
            result.success(null);
            return;
        }
        final int dbIndex = (dbIndexArg != null) ? dbIndexArg : 0;
        final File cacheDir = activity.getCacheDir();
        ioExecutor.execute(() -> {
            synchronized (dbLock) {
                if (dbIndex < 0 || dbIndex >= localAudioDbs.size()) {
                    new Handler(Looper.getMainLooper()).post(() -> result.success(null));
                    return;
                }
                SQLiteDatabase db = localAudioDbs.get(dbIndex);
                if (db == null || !db.isOpen()) {
                    new Handler(Looper.getMainLooper()).post(() -> result.success(null));
                    return;
                }
                // 输出文件名 = (file,source) 的稳定 hash + 扩展名，与 blob 字节一一对应。
                // 已存在即同一字节，跳过查库 + 读 blob + 写盘（TODO-744：去重复写盘延迟）。
                String ext = fileArg.endsWith(".opus") ? ".opus" : ".mp3";
                File tempFile = new File(
                    cacheDir,
                    "local_audio_" + localAudioCacheKey(fileArg, sourceArg) + ext);
                if (tempFile.exists()) {
                    new Handler(Looper.getMainLooper()).post(() ->
                        result.success(tempFile.getAbsolutePath()));
                    return;
                }
                try (Cursor audioCursor = db.rawQuery(
                        "SELECT data FROM android WHERE file = ? AND source = ? LIMIT 1",
                        new String[]{fileArg, sourceArg})) {
                    if (audioCursor != null && audioCursor.moveToFirst()) {
                        byte[] audioData = audioCursor.getBlob(0);
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

    private static String localAudioCacheKey(String file, String source) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] bytes = digest.digest((source + "\n" + file)
                .getBytes(StandardCharsets.UTF_8));
            String hex = bytesToHex(bytes);
            return hex.substring(0, Math.min(16, hex.length()));
        } catch (Exception e) {
            return Integer.toHexString((source + "\n" + file).hashCode());
        }
    }

    private static String bytesToHex(byte[] bytes) {
        StringBuilder builder = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            builder.append(String.format("%02x", b & 0xff));
        }
        return builder.toString();
    }

    @androidx.annotation.OptIn(markerClass = androidx.media3.common.util.UnstableApi.class)
    private void handleExtractAudioSegment(MethodCall call, MethodChannel.Result result) {
        String inputPath = call.argument("inputPath");
        Number startMsN = call.argument("startMs");
        Number endMsN = call.argument("endMs");
        String outputPath = call.argument("outputPath");
        if (inputPath == null || outputPath == null || startMsN == null || endMsN == null) {
            result.error("INVALID_ARGS", "Missing required arguments", null);
            return;
        }
        long startMs = Math.max(startMsN.longValue(), 0L);
        long endMs = Math.max(endMsN.longValue(), startMs + 1);

        final File transformerTmp = new File(outputPath + ".tmp.m4a");

        android.os.HandlerThread exportThread = new android.os.HandlerThread("HibikiAudioExport");
        exportThread.start();
        android.os.Handler exportHandler = new android.os.Handler(exportThread.getLooper());

        final java.util.concurrent.CountDownLatch done = new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.atomic.AtomicBoolean completed = new java.util.concurrent.atomic.AtomicBoolean(false);
        final java.util.concurrent.atomic.AtomicReference<Throwable> failure = new java.util.concurrent.atomic.AtomicReference<>(null);

        exportHandler.post(() -> {
            try {
                androidx.media3.transformer.Transformer transformer =
                    new androidx.media3.transformer.Transformer.Builder(activity.getApplicationContext())
                        .setLooper(exportThread.getLooper())
                        .setAudioMimeType(androidx.media3.common.MimeTypes.AUDIO_AAC)
                        .setMuxerFactory(new androidx.media3.transformer.FrameworkMuxer.Factory())
                        .addListener(new androidx.media3.transformer.Transformer.Listener() {
                            @Override
                            public void onCompleted(
                                    androidx.media3.transformer.Composition composition,
                                    androidx.media3.transformer.ExportResult exportResult) {
                                completed.set(true);
                                done.countDown();
                            }
                            @Override
                            public void onError(
                                    androidx.media3.transformer.Composition composition,
                                    androidx.media3.transformer.ExportResult exportResult,
                                    androidx.media3.transformer.ExportException exportException) {
                                failure.set(exportException);
                                done.countDown();
                            }
                        })
                        .build();

                androidx.media3.common.MediaItem mediaItem =
                    new androidx.media3.common.MediaItem.Builder()
                        .setUri(android.net.Uri.fromFile(new File(inputPath)))
                        .setClippingConfiguration(
                            new androidx.media3.common.MediaItem.ClippingConfiguration.Builder()
                                .setStartPositionMs(startMs)
                                .setEndPositionMs(endMs)
                                .build())
                        .build();

                androidx.media3.transformer.EditedMediaItem editedItem =
                    new androidx.media3.transformer.EditedMediaItem.Builder(mediaItem)
                        .setRemoveVideo(true)
                        .build();

                transformer.start(editedItem, transformerTmp.getAbsolutePath());
            } catch (Exception e) {
                failure.set(e);
                done.countDown();
            }
        });

        ioExecutor.execute(() -> {
            try {
                boolean finished = done.await(30, java.util.concurrent.TimeUnit.SECONDS);
                exportThread.quitSafely();

                if (!finished || !completed.get() || failure.get() != null) {
                    Throwable err = failure.get();
                    android.util.Log.e("hibiki-audio", "Transformer export failed",
                        err != null ? err : new Exception("timeout"));
                    transformerTmp.delete();
                    new File(outputPath).delete();
                    new Handler(Looper.getMainLooper()).post(() ->
                        result.error("EXTRACT_ERROR",
                            err != null ? err.getMessage() : "Export timeout", null));
                    return;
                }

                File outputFile = new File(outputPath);
                if (!AacAdtsCueAudioRewriter.rewrite(transformerTmp, outputFile)) {
                    android.util.Log.e("hibiki-audio", "ADTS rewrite failed for " + transformerTmp.getAbsolutePath());
                    transformerTmp.delete();
                    outputFile.delete();
                    new Handler(Looper.getMainLooper()).post(() ->
                        result.error("REWRITE_ERROR", "ADTS rewrite failed", null));
                    return;
                }
                transformerTmp.delete();

                new Handler(Looper.getMainLooper()).post(() -> result.success(outputPath));
            } catch (Exception e) {
                exportThread.quitSafely();
                android.util.Log.e("hibiki-audio", "extractAudioSegment failed", e);
                transformerTmp.delete();
                new Handler(Looper.getMainLooper()).post(() ->
                    result.error("EXTRACT_ERROR", e.getMessage(), null));
            }
        });
    }

    private void handleExtractEmbeddedCover(MethodCall call, MethodChannel.Result result) {
        String audioPath = call.argument("audioPath");
        String outputPath = call.argument("outputPath");
        if (audioPath == null || outputPath == null) {
            result.success(null);
            return;
        }
        ioExecutor.execute(() -> {
            try {
                MediaMetadataRetriever retriever = new MediaMetadataRetriever();
                try {
                    retriever.setDataSource(audioPath);
                    byte[] art = retriever.getEmbeddedPicture();
                    if (art == null || art.length == 0) {
                        new Handler(Looper.getMainLooper()).post(() -> result.success(null));
                        return;
                    }
                    File outFile = new File(outputPath);
                    try (FileOutputStream fos = new FileOutputStream(outFile)) {
                        fos.write(art);
                    }
                    new Handler(Looper.getMainLooper()).post(() -> result.success(outputPath));
                } finally {
                    retriever.release();
                }
            } catch (Exception e) {
                android.util.Log.w("hibiki-audio", "extractEmbeddedCover failed", e);
                new Handler(Looper.getMainLooper()).post(() -> result.success(null));
            }
        });
    }

    private void closeAllAudioDbsLocked() {
        if (indexFuture != null) {
            try {
                indexFuture.get(10, TimeUnit.SECONDS);
            } catch (Exception ignored) {}
            indexFuture = null;
        }
        for (SQLiteDatabase db : localAudioDbs) {
            if (db != null && db.isOpen()) {
                db.close();
            }
        }
        localAudioDbs.clear();
        localAudioDbPaths.clear();
        localAudioDbOrders.clear();
    }
}
