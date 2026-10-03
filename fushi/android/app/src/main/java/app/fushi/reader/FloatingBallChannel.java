package app.fushi.reader;

import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import app.fushi.reader.constants.ChannelNames;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * {@code app.fushi.reader/floating_ball} 的 Android 端（契约见
 * docs/specs/2026-09-28-floating-ball.md「平台通道契约」）。
 *
 * <p>契约之外接受的可选参数（Dart 不传时有默认值，不破坏契约）：
 * <ul>
 *   <li>{@code startSystemBall.ocrLanguage}：系统球「截屏 OCR」用的识别语言，默认
 *       {@code ja}；</li>
 *   <li>{@code startSystemBall.labels} 额外认 {@code notification}（常驻通知标题）与
 *       {@code ocr_hint / ocr_no_text / ocr_model_unavailable / ocr_failed /
 *       ocr_notification}（截屏 OCR 的提示文案），都缺省回退英文；</li>
 *   <li>{@code startScreenOcr.labels}：同上的 OCR 文案，缺省时沿用系统球已存的 labels。</li>
 *   <li>{@code startSystemBall.icons}：按钮 id → Material Icons 码位（与应用内球同一颗
 *       IconData），{@code startSystemBall.colors}：{@code surface / onSurface / primary}
 *       的 ARGB。都用来把系统球画得和应用内球一样（BUG-2793），缺省回退首字 / 默认配色。</li>
 * </ul>
 */
final class FloatingBallChannel {
    private static final String TAG = "FloatingBallChannel";

    /** 原生 → Dart：截屏 OCR 已截到帧，或流程没截到就结束了。Dart 据此放回自己的球。 */
    static final String METHOD_SCREEN_OCR_FINISHED = "screenOcrFinished";
    /** 原生 → Dart：系统球「查词」，Fushi 已被拉到前台，请打开查词页。 */
    static final String METHOD_OPEN_LOOKUP_PAGE = "openLookupPage";
    /** 原生 → Dart：系统球「拍照查词」，Fushi 已被拉到前台，请开相机。 */
    static final String METHOD_OPEN_CAMERA_OCR = "openCameraOcr";
    /** 原生 → Dart：系统球「立即同步」，Fushi 已被拉到前台，请跑一轮同步。 */
    static final String METHOD_OPEN_SYNC = "openSync";
    /** 原生 → Dart：截屏 OCR 报模型未就绪，Fushi 已被拉到前台，请打开系统 OCR 配置。 */
    static final String METHOD_OPEN_SYSTEM_OCR_SETUP = "openSystemOcrSetup";
    /** 原生 → Dart：用户在系统球 / 常驻通知上点了关闭，请关掉「应用外」开关。 */
    static final String METHOD_SYSTEM_BALL_CLOSED_BY_USER = "systemBallClosedByUser";

    /** 主引擎上的通道；MainActivity 销毁时 {@link #detach} 置空，之后回调安全跳过。 */
    @Nullable
    private static MethodChannel channel;
    /** channel 绑定的引擎；detach 只拆自己这台，防止重建顺序颠倒时拆掉新引擎的通道。 */
    @Nullable
    private static FlutterEngine channelEngine;

    /**
     * 有一次 Dart 发起、返回了 true 的 startScreenOcr 还欠一个 screenOcrFinished。
     * 只在主线程读写。悬浮球发起的 OCR 不置位——Dart 没藏球，也就不需要回调。
     */
    private static boolean dartOcrPending = false;

    /**
     * 系统球「查词」发生时主引擎不在（MainActivity 已销毁）：先记下，等新引擎上的 Dart
     * 装好 handler 后经 {@code takePendingOpenLookupPage} 取走。只在主线程读写。
     */
    private static boolean pendingOpenLookupPage = false;

    /** 同 {@link #pendingOpenLookupPage}，排的是系统球「拍照查词」。只在主线程读写。 */
    private static boolean pendingCameraOcr = false;

    /** 同 {@link #pendingOpenLookupPage}，排的是系统球「立即同步」。只在主线程读写。 */
    private static boolean pendingSync = false;
    /** 同 {@link #pendingOpenLookupPage}，排的是「打开系统 OCR 配置」。只在主线程读写。 */
    private static boolean pendingSystemOcrSetup = false;

    private FloatingBallChannel() {}

    static void registerWith(@NonNull FlutterEngine engine, @NonNull Context context) {
        final Context app = context.getApplicationContext();
        MethodChannel ch = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(),
                ChannelNames.FLOATING_BALL);
        ch.setMethodCallHandler((call, result) -> {
            try {
                handle(context, app, call, result);
            } catch (RuntimeException e) {
                Log.w(TAG, "floating_ball." + call.method + " failed", e);
                result.error("FLOATING_BALL_ERROR", e.getMessage(), null);
            }
        });
        channel = ch;
        channelEngine = engine;
    }

    /** MainActivity.onDestroy：通道绑在即将死掉的引擎上，解绑并置空。 */
    static void detach(@Nullable FlutterEngine engine) {
        if (engine == null || engine != channelEngine) return;
        channelEngine = null;
        if (channel != null) {
            channel.setMethodCallHandler(null);
            channel = null;
        }
    }

    /**
     * 截到帧 / 流程无截屏地结束时调用（主线程）。每次 Dart 发起的 startScreenOcr 至多
     * 回调一次：第一次调用消费掉 {@link #dartOcrPending}，之后（例如截到帧后选取层
     * 关闭时的收尾）都是 no-op。主引擎已不在就只清标记、不发送。
     */
    static void notifyScreenOcrFinished() {
        if (!dartOcrPending) return;
        dartOcrPending = false;
        MethodChannel ch = channel;
        if (ch == null) return;
        try {
            ch.invokeMethod(METHOD_SCREEN_OCR_FINISHED, null);
        } catch (RuntimeException e) {
            Log.w(TAG, "screenOcrFinished could not be delivered", e);
        }
    }

    /**
     * 系统球「查词」：主引擎在就直接推 {@code openLookupPage}（Fushi 随后被拉到前台）；
     * 不在就排队，由冷启动的 Dart 来取。主线程调用。
     */
    static void requestOpenLookupPage() {
        MethodChannel ch = channel;
        if (ch == null) {
            pendingOpenLookupPage = true;
            return;
        }
        try {
            ch.invokeMethod(METHOD_OPEN_LOOKUP_PAGE, null);
        } catch (RuntimeException e) {
            Log.w(TAG, "openLookupPage could not be delivered; queued", e);
            pendingOpenLookupPage = true;
        }
    }

    /**
     * 系统球「拍照查词」：主引擎在就直接推 {@code openCameraOcr}（Fushi 随后被拉到前台，
     * Dart 开相机）；不在就排队，由冷启动的 Dart 经 {@code takePendingCameraOcr} 来取。
     * 主线程调用。
     */
    static void requestCameraOcr() {
        MethodChannel ch = channel;
        if (ch == null) {
            pendingCameraOcr = true;
            return;
        }
        try {
            ch.invokeMethod(METHOD_OPEN_CAMERA_OCR, null);
        } catch (RuntimeException e) {
            Log.w(TAG, "openCameraOcr could not be delivered; queued", e);
            pendingCameraOcr = true;
        }
    }

    /**
     * 系统球「立即同步」：主引擎在就直接推 {@code openSync}（Fushi 随后被拉到前台，
     * Dart 跑同步）；不在就排队，由冷启动的 Dart 经 {@code takePendingSync} 来取。
     * 主线程调用。
     */
    static void requestSync() {
        MethodChannel ch = channel;
        if (ch == null) {
            pendingSync = true;
            return;
        }
        try {
            ch.invokeMethod(METHOD_OPEN_SYNC, null);
        } catch (RuntimeException e) {
            Log.w(TAG, "openSync could not be delivered; queued", e);
            pendingSync = true;
        }
    }

    /**
     * 截屏 OCR 报模型未就绪（BUG-2906）：主引擎在就直接推 {@code openSystemOcrSetup}
     * （Fushi 随后被拉到前台，Dart 弹配置）；不在就排队，由冷启动的 Dart 经
     * {@code takePendingSystemOcrSetup} 来取。主线程调用。
     */
    static void requestSystemOcrSetup() {
        MethodChannel ch = channel;
        if (ch == null) {
            pendingSystemOcrSetup = true;
            return;
        }
        try {
            ch.invokeMethod(METHOD_OPEN_SYSTEM_OCR_SETUP, null);
        } catch (RuntimeException e) {
            Log.w(TAG, "openSystemOcrSetup could not be delivered; queued", e);
            pendingSystemOcrSetup = true;
        }
    }

    /**
     * 用户关掉了系统球：主引擎在就立刻通知 Dart 关开关；不在也无妨，持久标记已由
     * {@link FloatingBallService} 落盘，Dart 下次同步开关前会取走。主线程调用。
     */
    static void notifySystemBallClosedByUser() {
        MethodChannel ch = channel;
        if (ch == null) return;
        try {
            ch.invokeMethod(METHOD_SYSTEM_BALL_CLOSED_BY_USER, null);
        } catch (RuntimeException e) {
            Log.w(TAG, "systemBallClosedByUser could not be delivered", e);
        }
    }

    private static void handle(
            @NonNull Context context,
            @NonNull Context app,
            @NonNull MethodCall call,
            @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "canDrawOverlays":
                result.success(Settings.canDrawOverlays(app));
                return;
            case "requestOverlayPermission": {
                Intent intent = new Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:" + app.getPackageName()));
                if (!(context instanceof android.app.Activity)) {
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                }
                context.startActivity(intent);
                result.success(null);
                return;
            }
            case "startSystemBall": {
                if (!Settings.canDrawOverlays(app)) {
                    result.success(false);
                    return;
                }
                FloatingBallService.saveConfig(
                        app,
                        stringList(call.argument("actions")),
                        stringMap(call.argument("labels")),
                        intMap(call.argument("icons")),
                        intMap(call.argument("colors")),
                        call.argument("ocrLanguage"));
                if (FloatingBallService.getInstance() == null) {
                    Intent svc = new Intent(app, FloatingBallService.class);
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        app.startForegroundService(svc);
                    } else {
                        app.startService(svc);
                    }
                }
                result.success(true);
                return;
            }
            case "stopSystemBall":
                app.stopService(new Intent(app, FloatingBallService.class));
                result.success(null);
                return;
            case "isSystemBallRunning":
                result.success(FloatingBallService.getInstance() != null);
                return;
            case "setAppForeground": {
                Boolean foreground = call.argument("foreground");
                FloatingBallService.setAppForeground(foreground == null || foreground);
                result.success(null);
                return;
            }
            case "openPopupLookup":
                FloatingBallService.startPopupLookup(context);
                result.success(null);
                return;
            case "takePendingOpenLookupPage": {
                boolean pending = pendingOpenLookupPage;
                pendingOpenLookupPage = false;
                result.success(pending);
                return;
            }
            case "takePendingCameraOcr": {
                boolean pending = pendingCameraOcr;
                pendingCameraOcr = false;
                result.success(pending);
                return;
            }
            case "takePendingSync": {
                boolean pending = pendingSync;
                pendingSync = false;
                result.success(pending);
                return;
            }
            case "takePendingSystemOcrSetup": {
                boolean pending = pendingSystemOcrSetup;
                pendingSystemOcrSetup = false;
                result.success(pending);
                return;
            }
            case "takeSystemBallClosedByUser":
                result.success(FloatingBallService.takeClosedByUser(app));
                return;
            case "startScreenOcr": {
                String language = call.argument("language");
                Map<String, String> labels = stringMap(call.argument("labels"));
                if (labels.isEmpty()) labels = FloatingBallService.storedLabels(app);
                boolean started = ScreenCaptureRequestActivity.launch(context, language, labels);
                if (started) dartOcrPending = true;
                result.success(started);
                return;
            }
            default:
                result.notImplemented();
        }
    }

    /** 不是列表（Dart 没传）返回 null = 缺省全开；空列表 = 只留 open_app / close。 */
    @Nullable
    private static List<String> stringList(@Nullable Object raw) {
        if (!(raw instanceof List)) return null;
        List<String> out = new ArrayList<>();
        for (Object o : (List<?>) raw) {
            if (o != null) out.add(o.toString());
        }
        return out;
    }

    /**
     * 数值表（图标码位 / ARGB 颜色）。Dart int 按大小落成 Integer 或 Long（ARGB 高位为 1
     * 时是 Long），统一按 {@link Number#intValue} 截成 32 位——ARGB 正好是 32 位。
     */
    private static Map<String, Integer> intMap(@Nullable Object raw) {
        Map<String, Integer> out = new HashMap<>();
        if (raw instanceof Map) {
            for (Map.Entry<?, ?> e : ((Map<?, ?>) raw).entrySet()) {
                if (e.getKey() != null && e.getValue() instanceof Number) {
                    out.put(e.getKey().toString(), ((Number) e.getValue()).intValue());
                }
            }
        }
        return out;
    }

    private static Map<String, String> stringMap(@Nullable Object raw) {
        Map<String, String> out = new HashMap<>();
        if (raw instanceof Map) {
            for (Map.Entry<?, ?> e : ((Map<?, ?>) raw).entrySet()) {
                if (e.getKey() != null && e.getValue() != null) {
                    out.put(e.getKey().toString(), e.getValue().toString());
                }
            }
        }
        return out;
    }
}
