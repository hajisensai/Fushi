package app.fushi.reader;

import android.content.Context;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.io.File;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/**
 * {@code app.fushi.reader/cross_app_audio}：跨应用语音缓存（拍板 oqk37s3QFL）的 Dart 入口。
 * 主引擎与查词窗引擎（{@code :popup} 进程）都注册；采集状态 / 快照经
 * {@link CrossAppAudioProvider} 走跨进程 RPC，所以两边调法一样。
 *
 * <ul>
 *   <li>{@code isSupported} → bool（Android 10+）；</li>
 *   <li>{@code status} → bool（是否在录）；</li>
 *   <li>{@code start} {@code {labels}} → {@code {running, error?}}：弹授权流程，等到服务真的
 *       录起来 / 被拒才回（只在主引擎用）；</li>
 *   <li>{@code stop} → void；</li>
 *   <li>{@code snapshot} {@code {backMs}} → {@code {path, sampleRate, channels,
 *       bitsPerSample}} 或 null；</li>
 *   <li>{@code encodeAac} {@code {pcm, sampleRate, channels, outputPath}} → bool。</li>
 * </ul>
 *
 * 主引擎还会收到 {@code onState} {@code {running}}：服务在别处被停（通知栏「停止」、系统
 * 收回共享）时设置页据此刷新。
 */
final class CrossAppAudioChannel {
    private static final String TAG = "CrossAppAudioChannel";
    static final String CHANNEL = "app.fushi.reader/cross_app_audio";
    private static final int AAC_BIT_RATE = 64_000;

    private static final ExecutorService ENCODER = Executors.newSingleThreadExecutor();
    /** status / stop / snapshot 的跨进程 RPC（BUG-4791）；与编码分开，快照不排在编码后面。 */
    private static final ExecutorService PROVIDER_IO = Executors.newSingleThreadExecutor();
    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    /** 主引擎的通道（推 onState 用）；查词窗进程里为 null。主线程读写。 */
    @Nullable private static MethodChannel mainChannel;
    /** 还没回的 start 调用。主线程读写。 */
    @Nullable private static MethodChannel.Result pendingStart;

    private CrossAppAudioChannel() {}

    /**
     * @param ownsState 主进程主引擎传 true：接管服务的状态回调并推给 Dart。
     */
    static void registerWith(@NonNull FlutterEngine engine, @NonNull Context context,
            boolean ownsState) {
        final Context app = context.getApplicationContext();
        MethodChannel channel =
                new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), CHANNEL);
        channel.setMethodCallHandler((call, result) -> {
            final String method = call.method;
            if (CrossAppAudioPolicy.callsProviderOffMain(method)) {
                // 跨进程 RPC（+ snapshot 在 Provider 端的同步写盘）不压在平台主线程上
                // （BUG-4791）。单线程执行器保证 RPC 按 Dart 发出的顺序到达 Provider。
                final Integer backMs = call.argument("backMs");
                PROVIDER_IO.execute(() -> {
                    final Object value;
                    try {
                        value = runProviderCall(app, method, backMs);
                    } catch (RuntimeException e) {
                        // 平台主线程上 Flutter 的 IncomingMethodCallHandler 会把 RuntimeException
                        // 回成 error；挪到执行器后这层兜底没了，未捕获异常会杀掉整个进程（查词窗
                        // 进程连同窗口），Dart 的 Future 也永远不完成。这里照原语义回 error。
                        Log.e(TAG, "cross-app audio " + method + " failed", e);
                        MAIN.post(() -> result.error(
                                "CROSS_APP_AUDIO_ERROR", String.valueOf(e.getMessage()), null));
                        return;
                    }
                    MAIN.post(() -> result.success(value));
                });
                return;
            }
            switch (method) {
                case "isSupported":
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q);
                    return;
                case "start":
                    start(app, call.argument("labels"), result);
                    return;
                case "encodeAac":
                    encodeAac(call.argument("pcm"), call.argument("sampleRate"),
                            call.argument("channels"), call.argument("outputPath"), result);
                    return;
                default:
                    result.notImplemented();
            }
        });
        if (ownsState) {
            mainChannel = channel;
            CrossAppAudioService.setStateListener((boolean running, @Nullable String error) -> {
                completeStart(running, error);
                MethodChannel target = mainChannel;
                if (target == null) return;
                Map<String, Object> args = new HashMap<>();
                args.put("running", running);
                target.invokeMethod("onState", args);
            });
        }
    }

    /** 主引擎销毁时调用，免得服务回调打到已死的引擎。 */
    static void unregisterMain() {
        mainChannel = null;
        CrossAppAudioService.setStateListener((boolean running, @Nullable String error) ->
                completeStart(running, error));
    }

    private static void start(@NonNull Context app, @Nullable Map<String, String> labels,
            @NonNull MethodChannel.Result result) {
        if (CrossAppAudioService.isRunning()) {
            result.success(startResult(true, null));
            return;
        }
        if (pendingStart != null) {
            result.success(startResult(false, "busy"));
            return;
        }
        pendingStart = result;
        try {
            CrossAppAudioRequestActivity.launch(app, labels);
        } catch (RuntimeException e) {
            Log.w(TAG, "could not launch the capture consent", e);
            completeStart(false, "start_failed");
        }
    }

    /** 授权流程 / 服务给出结果（主线程或任意线程）。没有等待中的 start 时什么都不做。 */
    static void completeStart(boolean running, @Nullable String error) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            MAIN.post(() -> completeStart(running, error));
            return;
        }
        MethodChannel.Result pending = pendingStart;
        pendingStart = null;
        if (pending != null) pending.success(startResult(running, error));
    }

    private static Map<String, Object> startResult(boolean running, @Nullable String error) {
        Map<String, Object> out = new HashMap<>();
        out.put("running", running);
        if (error != null) out.put("error", error);
        return out;
    }

    private static Map<String, Object> snapshotMap(@NonNull Bundle bundle) {
        Map<String, Object> out = new HashMap<>();
        out.put("path", bundle.getString("path"));
        out.put("sampleRate", bundle.getInt("sampleRate"));
        out.put("channels", bundle.getInt("channels"));
        out.put("bitsPerSample", bundle.getInt("bitsPerSample"));
        out.put("isFloat", false);
        return out;
    }

    /**
     * 后台线程上执行一次 {@link CrossAppAudioPolicy#callsProviderOffMain} 判为真的方法，
     * 返回要回给 Dart 的值。
     */
    @Nullable
    private static Object runProviderCall(@NonNull Context app, @NonNull String method,
            @Nullable Integer backMs) {
        switch (method) {
            case CrossAppAudioPolicy.METHOD_STATUS: {
                Bundle out = callProvider(app, CrossAppAudioProvider.METHOD_STATUS, null);
                return out != null && out.getBoolean("running", false);
            }
            case CrossAppAudioPolicy.METHOD_STOP:
                callProvider(app, CrossAppAudioProvider.METHOD_STOP, null);
                return null;
            case CrossAppAudioPolicy.METHOD_SNAPSHOT: {
                if (!CrossAppAudioProvider.capturingMarker(app).exists()) {
                    // 没在录：不发 RPC，免得把没在跑的主进程拉起来。
                    return null;
                }
                Bundle out = callProvider(app, CrossAppAudioProvider.METHOD_SNAPSHOT,
                        String.valueOf(backMs == null ? 0 : backMs));
                return out == null || out.getString("path") == null ? null : snapshotMap(out);
            }
            default:
                // 判定与这里的分支必须一一对应；漏一个是编程错误，不静默回 null。
                throw new IllegalStateException("not a provider call: " + method);
        }
    }

    @Nullable
    private static Bundle callProvider(@NonNull Context app, @NonNull String method,
            @Nullable String arg) {
        try {
            return app.getContentResolver().call(
                    CrossAppAudioProvider.uri(app), method, arg, null);
        } catch (RuntimeException e) {
            Log.w(TAG, "cross-app audio provider call failed: " + method, e);
            return null;
        }
    }

    private static void encodeAac(@Nullable byte[] pcm, @Nullable Integer sampleRate,
            @Nullable Integer channels, @Nullable String outputPath,
            @NonNull MethodChannel.Result result) {
        if (pcm == null || sampleRate == null || channels == null || outputPath == null) {
            result.error("bad_args", "pcm, sampleRate, channels and outputPath are required",
                    null);
            return;
        }
        ENCODER.execute(() -> {
            boolean ok = AacClipEncoder.encode(pcm, sampleRate, channels, AAC_BIT_RATE,
                    new File(outputPath));
            MAIN.post(() -> result.success(ok));
        });
    }
}
