package app.fushi.reader;

import android.app.Activity;
import android.util.Log;
import android.view.View;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.lang.ref.WeakReference;
import java.lang.reflect.Method;

import app.fushi.reader.constants.ChannelNames;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/**
 * 墨水屏「全刷」的厂商 EPD 通道（拍板台 oF0jVdOTIE 方案 B）。
 *
 * <p>Dart 侧唯一门面是 {@code lib/src/platform/mobile/android_eink_refresh.dart}，
 * 方法名是跨语言契约，改这里必须同步改那边。
 *
 * <p>墨水屏阅读器的系统「应用优化 / 定时全刷」常常对第三方 app 不生效，残影只能手动清。
 * 各家 EPD 控制器都是厂商在 framework 里加的私有方法，没有公开 SDK 可依赖，所以这里
 * <b>只用反射</b>探测，不引任何厂商库：
 *
 * <ol>
 *   <li><b>rockchip</b>：瑞芯微 RK35xx 新机（小米 / 多看 / 掌阅等）的系统服务
 *       {@code android.os.EinkManager}（{@code getSystemService("eink")}），
 *       {@code sendOneFullFrame()} 按系统当前清晰度档位整屏刷一次。</li>
 *   <li><b>onyx</b>：文石 BOOX（高通平台）在 {@code View} 上加的
 *       {@code refreshScreen(x, y, w, h, mode)}，mode = UPDATE_FULL | WAIT | GC16。</li>
 *   <li><b>ntx</b>：NTX 方案（Nook / Tolino / Sony 等）在 {@code View} 上加的
 *       {@code postInvalidateDelayed(delay, x, y, w, h, mode)}，mode = UPDATE_FULL | GC16。</li>
 *   <li><b>rockchip_legacy</b>：老瑞芯微 RK30xx（博阅 / 老文石等）的
 *       {@code View.requestEpdMode(View.EINK_MODE, boolean)}，传 {@code EPD_FULL}。</li>
 * </ol>
 *
 * <p>探测顺序即上表顺序（新平台在前；同一台机器同时带多套私有方法时取最新的那套），
 * 结果一次进程内缓存。探测不到任何一套时 {@code fullRefresh} 返回 false，Dart 侧退回
 * 通用的黑屏闪刷（方案 A）。探测到了但调用抛错时回 {@code error}，Dart 侧记诊断、
 * 本次同样退回闪刷。
 *
 * <p>没收的两套：RK33xx 的 {@code View.setByEinkUpdateMode(int)} 与全志 sunxi 的
 * {@code ViewRootImpl.setRefreshMode(int)} 都是「改全局刷新模式、等下一次绘制生效」的
 * 持久开关，必须与一次重绘配对再复位，漏复位会让整个 app 停在闪烁的全刷模式里；手上
 * 没有这两类机器能验证配对时序，所以不接——这两类机器上 Auto 自动走黑屏闪刷。
 */
public final class EinkRefreshChannel {
    private static final String TAG = "EinkRefresh";
    private static final String METHOD_FULL_REFRESH = "fullRefresh";

    private static final String VENDOR_ROCKCHIP = "rockchip";
    private static final String VENDOR_ONYX = "onyx";
    private static final String VENDOR_NTX = "ntx";
    private static final String VENDOR_ROCKCHIP_LEGACY = "rockchip_legacy";

    /** Onyx / NTX 共用的 mxc EPDC 波形位：UPDATE_FULL = 32，WAIT = 64，GC16 = 2。 */
    private static final int EPDC_UPDATE_FULL = 32;
    private static final int EPDC_WAIT = 64;
    private static final int EPDC_WAVEFORM_GC16 = 2;

    /**
     * Dart 侧在新页那一帧结束后才调用本通道，但 Flutter 的 raster 线程还要再把这一帧
     * 交给 SurfaceFlinger、EPD 控制器再把它排进面板队列；此刻立刻全刷，刷的可能还是
     * 旧页。250ms 是高通 / 文石平台 GC16 全刷请求的实测排队延迟（KOReader 的 Onyx
     * 控制器同值），是硬件流水线的等待，不是动画时长。
     */
    private static final long PRESENT_SETTLE_MS = 250L;

    /** null = 尚未探测；"" = 探测过，本机没有可用通道。 */
    @Nullable
    private static String vendor;

    @Nullable
    private static Method rockchipSendOneFullFrame;
    @Nullable
    private static Method onyxRefreshScreen;
    @Nullable
    private static Method ntxPostInvalidateDelayed;
    @Nullable
    private static Method legacyRequestEpdMode;
    @Nullable
    private static Object legacyFullMode;

    private EinkRefreshChannel() {}

    public static void registerWith(
            @NonNull FlutterEngine flutterEngine, @NonNull Activity activity) {
        final WeakReference<Activity> activityRef = new WeakReference<>(activity);
        new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(),
                ChannelNames.EINK_REFRESH)
            .setMethodCallHandler((call, result) -> {
                if (!METHOD_FULL_REFRESH.equals(call.method)) {
                    result.notImplemented();
                    return;
                }
                final Activity host = activityRef.get();
                if (host == null || host.isFinishing()) {
                    result.success(false);
                    return;
                }
                final String found = probe(host);
                if (found.isEmpty()) {
                    result.success(false);
                    return;
                }
                final View decor = host.getWindow().getDecorView();
                decor.postDelayed(() -> {
                    try {
                        refresh(found, host, decor);
                        result.success(true);
                    } catch (Throwable error) {
                        Log.w(TAG, "full refresh via " + found + " failed", error);
                        result.error("EINK_REFRESH_FAILED", found + ": " + error, null);
                    }
                }, PRESENT_SETTLE_MS);
            });
    }

    /** 探测本机的厂商通道（结果缓存）；没有时返回空串。 */
    @NonNull
    private static synchronized String probe(@NonNull Activity activity) {
        if (vendor != null) return vendor;
        vendor = "";
        try {
            final Class<?> einkManager = Class.forName("android.os.EinkManager");
            final Object service = activity.getSystemService("eink");
            if (service != null && einkManager.isInstance(service)) {
                rockchipSendOneFullFrame = einkManager.getDeclaredMethod("sendOneFullFrame");
                vendor = VENDOR_ROCKCHIP;
                return vendor;
            }
        } catch (ReflectiveOperationException | RuntimeException ignored) {
            // 不是 RK35xx：继续探下一套。
        }
        try {
            onyxRefreshScreen = View.class.getMethod(
                    "refreshScreen", int.class, int.class, int.class, int.class, int.class);
            vendor = VENDOR_ONYX;
            return vendor;
        } catch (ReflectiveOperationException | RuntimeException ignored) {
            // 不是文石高通平台。
        }
        try {
            ntxPostInvalidateDelayed = View.class.getMethod(
                    "postInvalidateDelayed",
                    long.class, int.class, int.class, int.class, int.class, int.class);
            vendor = VENDOR_NTX;
            return vendor;
        } catch (ReflectiveOperationException | RuntimeException ignored) {
            // 不是 NTX 方案。
        }
        try {
            final Class<?> modeEnum = Class.forName("android.view.View$EINK_MODE");
            final Object full = enumConstant(modeEnum, "EPD_FULL");
            if (full != null) {
                legacyRequestEpdMode =
                        View.class.getMethod("requestEpdMode", modeEnum, boolean.class);
                legacyFullMode = full;
                vendor = VENDOR_ROCKCHIP_LEGACY;
                return vendor;
            }
        } catch (ReflectiveOperationException | RuntimeException ignored) {
            // 不是老瑞芯微。
        }
        Log.i(TAG, "no vendor EPD controller found; Dart falls back to a black flash");
        return vendor;
    }

    @Nullable
    private static Object enumConstant(@NonNull Class<?> enumClass, @NonNull String name) {
        final Object[] constants = enumClass.getEnumConstants();
        if (constants == null) return null;
        for (Object constant : constants) {
            if (constant instanceof Enum && ((Enum<?>) constant).name().equals(name)) {
                return constant;
            }
        }
        return null;
    }

    private static void refresh(
            @NonNull String found, @NonNull Activity activity, @NonNull View decor)
            throws ReflectiveOperationException {
        final int width = decor.getWidth();
        final int height = decor.getHeight();
        switch (found) {
            case VENDOR_ROCKCHIP:
                rockchipSendOneFullFrame.invoke(activity.getSystemService("eink"));
                return;
            case VENDOR_ONYX:
                onyxRefreshScreen.invoke(
                        decor, 0, 0, width, height,
                        EPDC_UPDATE_FULL | EPDC_WAIT | EPDC_WAVEFORM_GC16);
                return;
            case VENDOR_NTX:
                ntxPostInvalidateDelayed.invoke(
                        decor, 0L, 0, 0, width, height,
                        EPDC_UPDATE_FULL | EPDC_WAVEFORM_GC16);
                return;
            case VENDOR_ROCKCHIP_LEGACY:
                legacyRequestEpdMode.invoke(decor, legacyFullMode, true);
                decor.invalidate();
                return;
            default:
                throw new IllegalStateException("unknown EPD vendor " + found);
        }
    }
}
