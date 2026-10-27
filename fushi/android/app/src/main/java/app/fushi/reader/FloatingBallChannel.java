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
 *   <li>{@code startSystemBall.tapAction}：收起态点球直接执行的动作（{@code clipboard} /
 *       {@code screen_ocr}），此时长按才展开按钮；缺省 / 空 = 点球展开。</li>
 *   <li>{@code startSystemBall.showLabels}：展开时按钮旁带文字，缺省 true；
 *       {@code startSystemBall.showOpenApp}：菜单里有「打开 Fushi」，缺省 true。</li>
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
    static final String METHOD_OPEN_AI = "openAi";
    /** 原生 → Dart：系统球「切换配置」，Fushi 已被拉到前台，请弹出配置选择。 */
    static final String METHOD_OPEN_PROFILE_SWITCH = "openProfileSwitch";
    /** 原生 → Dart：系统球「切换配置」要在球旁弹菜单，请回配置列表 {@code [{id, label, checked}]}。 */
    static final String METHOD_GET_PROFILE_MENU = "getProfileMenu";
    /** 原生 → Dart：在那个菜单里选了 {@code {id}}，请原地切过去并回一句 Toast 文案。 */
    static final String METHOD_SWITCH_PROFILE_TO = "switchProfileTo";
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
     * 系统球「查词」发生时主引擎不在（MainActivity 已销毁）：先记下，等新引擎上的 Dart
     * 装好 handler 后经 {@code takePendingOpenLookupPage} 取走。只在主线程读写。
     */
    private static boolean pendingOpenLookupPage = false;

    /** 同 {@link #pendingOpenLookupPage}，排的是系统球「拍照查词」。只在主线程读写。 */
    private static boolean pendingCameraOcr = false;

    /** 同 {@link #pendingOpenLookupPage}，排的是系统球「立即同步」。只在主线程读写。 */
    private static boolean pendingSync = false;
    /** 同 {@link #pendingOpenLookupPage}，排的是系统球「AI」。只在主线程读写。 */
    private static boolean pendingOpenAi = false;
    /** 同 {@link #pendingOpenLookupPage}，排的是系统球「切换配置」。只在主线程读写。 */
    private static boolean pendingProfileSwitch = false;
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
     * 回调一次（欠账记在 {@link ScreenCaptureRequestActivity#LATCH}；悬浮球发起的 OCR
     * 不记账——Dart 没藏球，也就不需要回调），之后（例如截到帧后选取层关闭时的收尾）
     * 都是 no-op。
     *
     * <p>主引擎通道此刻不在（MainActivity 已销毁，但 audio_service 的缓存引擎与 Dart
     * isolate 还活着、应用内球还藏着）时不能丢：记成未送达，等 {@link #onHostResumed}
     * 通道重新挂上后补发（BUG-3602）。
     */
    static void notifyScreenOcrFinished() {
        if (!ScreenCaptureRequestActivity.LATCH.finish(channel != null)) return;
        deliverScreenOcrFinished();
    }

    /**
     * Fushi 主界面回到前台（{@code MainActivity.onResume}，此时通道已在 configureFlutterEngine
     * 里挂好）：被系统丢掉的截屏发起按结束收尾，没送达的 screenOcrFinished 补发。主线程。
     */
    static void onHostResumed() {
        ScreenCaptureRequestActivity.onHostAppResumed();
        if (ScreenCaptureRequestActivity.LATCH.takeUndelivered(channel != null)) {
            deliverScreenOcrFinished();
        }
    }

    private static void deliverScreenOcrFinished() {
        MethodChannel ch = channel;
        if (ch == null) {
            ScreenCaptureRequestActivity.LATCH.onDeliveryFailed();
            return;
        }
        try {
            ch.invokeMethod(METHOD_SCREEN_OCR_FINISHED, null);
        } catch (RuntimeException e) {
            Log.w(TAG, "screenOcrFinished could not be delivered; retrying on next resume", e);
            ScreenCaptureRequestActivity.LATCH.onDeliveryFailed();
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
     * 系统球「AI」：主引擎在就直接推 {@code openAi}（Fushi 随后被拉到前台，Dart 打开
     * AI 浮层）；不在就排队，由冷启动的 Dart 经 {@code takePendingOpenAi} 来取。主线程调用。
     */
    static void requestOpenAi() {
        MethodChannel ch = channel;
        if (ch == null) {
            pendingOpenAi = true;
            return;
        }
        try {
            ch.invokeMethod(METHOD_OPEN_AI, null);
        } catch (RuntimeException e) {
            Log.w(TAG, "openAi could not be delivered; queued", e);
            pendingOpenAi = true;
        }
    }

    /** 系统球配置菜单的一项（Dart {@code getProfileMenu} 回来的）。 */
    static final class ProfileMenuItem {
        final int id;
        final String label;
        final boolean checked;

        ProfileMenuItem(int id, String label, boolean checked) {
            this.id = id;
            this.label = label;
            this.checked = checked;
        }
    }

    interface ProfileMenuCallback {
        /** Dart 回了配置列表（可能为空）。主线程。 */
        void onItems(List<ProfileMenuItem> items);

        /** 主引擎不在 / Dart 没接住：调用方退回「拉起 Fushi 再选」。主线程。 */
        void onUnavailable();
    }

    interface MessageCallback {
        void onMessage(String message);
    }

    /**
     * 系统球「切换配置」：向主引擎上的 Dart 要配置列表，好在球旁弹菜单、不拉起
     * Fushi。主引擎不在（或调用失败）走 {@link ProfileMenuCallback#onUnavailable}。
     * 主线程调用。
     */
    static void requestProfileMenu(@NonNull ProfileMenuCallback callback) {
        MethodChannel ch = channel;
        if (ch == null) {
            Log.i(TAG, "getProfileMenu: main engine not attached; falling back");
            callback.onUnavailable();
            return;
        }
        try {
            ch.invokeMethod(METHOD_GET_PROFILE_MENU, null, new MethodChannel.Result() {
                @Override
                public void success(@Nullable Object result) {
                    List<ProfileMenuItem> items = parseProfileMenu(result);
                    if (items == null) {
                        Log.w(TAG, "getProfileMenu: Dart returned no list (" + result + ")");
                        callback.onUnavailable();
                    } else {
                        callback.onItems(items);
                    }
                }

                @Override
                public void error(@NonNull String code, @Nullable String message,
                        @Nullable Object details) {
                    Log.w(TAG, "getProfileMenu failed: " + code + " " + message);
                    callback.onUnavailable();
                }

                @Override
                public void notImplemented() {
                    Log.w(TAG, "getProfileMenu: not implemented on the Dart side");
                    callback.onUnavailable();
                }
            });
        } catch (RuntimeException e) {
            Log.w(TAG, "getProfileMenu could not be delivered", e);
            callback.onUnavailable();
        }
    }

    /** {@code getProfileMenu} 的回值；不是列表（Dart 没装处理器回了 null）返回 null。 */
    @Nullable
    private static List<ProfileMenuItem> parseProfileMenu(@Nullable Object raw) {
        if (!(raw instanceof List)) return null;
        List<ProfileMenuItem> items = new ArrayList<>();
        for (Object entry : (List<?>) raw) {
            if (!(entry instanceof Map)) continue;
            Map<?, ?> map = (Map<?, ?>) entry;
            Object id = map.get("id");
            Object label = map.get("label");
            if (!(id instanceof Number) || !(label instanceof String)) continue;
            items.add(new ProfileMenuItem(
                    ((Number) id).intValue(),
                    (String) label,
                    Boolean.TRUE.equals(map.get("checked"))));
        }
        return items;
    }

    /**
     * 系统球配置菜单里选了 [profileId]：交给 Dart 原地切，把它回的一句话（成功 /
     * 失败）交给 [onMessage] 显示。主引擎此刻不在就什么也不做（菜单刚由它给出）。
     * 主线程调用。
     */
    static void switchProfileTo(int profileId, @NonNull MessageCallback onMessage) {
        MethodChannel ch = channel;
        if (ch == null) return;
        Map<String, Object> args = new HashMap<>();
        args.put("id", profileId);
        try {
            ch.invokeMethod(METHOD_SWITCH_PROFILE_TO, args, new MethodChannel.Result() {
                @Override
                public void success(@Nullable Object result) {
                    if (result instanceof String && !((String) result).isEmpty()) {
                        onMessage.onMessage((String) result);
                    }
                }

                @Override
                public void error(@NonNull String code, @Nullable String message,
                        @Nullable Object details) {
                    Log.w(TAG, "switchProfileTo failed: " + code + " " + message);
                }

                @Override
                public void notImplemented() {}
            });
        } catch (RuntimeException e) {
            Log.w(TAG, "switchProfileTo could not be delivered", e);
        }
    }

    /**
     * 系统球「切换配置」的退路（主引擎不在、没法在球旁弹菜单）：主引擎在就直接推
     * {@code openProfileSwitch}（Fushi 随后被拉到前台，Dart 弹配置选择）；不在就排队，
     * 由冷启动的 Dart 经 {@code takePendingProfileSwitch} 来取。主线程调用。
     */
    static void requestSwitchProfile() {
        MethodChannel ch = channel;
        if (ch == null) {
            pendingProfileSwitch = true;
            return;
        }
        try {
            ch.invokeMethod(METHOD_OPEN_PROFILE_SWITCH, null);
        } catch (RuntimeException e) {
            Log.w(TAG, "openProfileSwitch could not be delivered; queued", e);
            pendingProfileSwitch = true;
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
                        call.argument("ocrLanguage"),
                        call.argument("tapAction"),
                        call.argument("showLabels"),
                        call.argument("showOpenApp"));
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
            case "setScreenOcrOptions": {
                // 截屏识字的两个用户选项（保持截屏会话 / 制卡带图），见 ScreenOcrOptions。
                Boolean keep = call.argument("keepSession");
                Boolean cardImage = call.argument("cardImage");
                ScreenOcrOptions.save(app, keep != null && keep,
                        cardImage == null || cardImage);
                result.success(null);
                return;
            }
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
            case "takePendingOpenAi": {
                boolean pending = pendingOpenAi;
                pendingOpenAi = false;
                result.success(pending);
                return;
            }
            case "takePendingProfileSwitch": {
                boolean pending = pendingProfileSwitch;
                pendingProfileSwitch = false;
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
                if (started) ScreenCaptureRequestActivity.LATCH.onDartStarted();
                result.success(started);
                return;
            }
            case "captureScreen":
                // 截本 App 窗口（含 WebView），反馈截图用；与 iOS 同名同契约（PNG 字节）。
                // maxSide：输出长边上限，原生侧合成时直接缩好，不传全分辨率 PNG 过通道。
                AppWindowSnapshot.capture(context, call.argument("maxSide"), result);
                return;
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
