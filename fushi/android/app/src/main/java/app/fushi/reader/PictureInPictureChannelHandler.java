package app.fushi.reader;

import android.app.Activity;
import android.app.PictureInPictureParams;
import android.content.pm.PackageManager;
import android.os.Build;
import android.util.Rational;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import app.fushi.reader.constants.ChannelNames;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/**
 * 系统画中画（Picture-in-Picture）的 Android 侧实现。
 *
 * <p>Dart 侧的唯一门面是 {@code lib/src/platform/mobile/android_picture_in_picture.dart}，
 * 方法名 / 参数名是跨语言契约的一部分，改这里必须同步改那边。
 *
 * <p><b>三条真实陷阱，都写在代码里：</b>
 *
 * <ol>
 *   <li><b>版本门</b>：{@code enterPictureInPictureMode(PictureInPictureParams)} 与
 *       {@link PictureInPictureParams} 本身都是 API 26（O）才有的，而本 app 的
 *       minSdk 是 24。所以 {@code isSupported} 必须同时问版本和
 *       {@link PackageManager#FEATURE_PICTURE_IN_PICTURE}——后者不是多余的：
 *       电视 / 部分定制 ROM 会在系统里整块关掉 PiP，光看版本号会在真机上
 *       直接吃一个 IllegalStateException。这里**不用** {@code setAutoEnterEnabled}
 *       （API 31），本次只做显式进入。</li>
 *   <li><b>宽高比钳制</b>：系统只接受 {@code [1/2.39, 2.39]} 区间内的比例，越界
 *       时 {@code enterPictureInPictureMode} 抛 IllegalArgumentException。视频的
 *       真实比例（竖屏短视频、超宽银幕片源）很容易越界，所以送进
 *       {@link Rational} 之前必须先钳制。</li>
 *   <li><b>Activity 生命周期</b>：进入 / 退出 PiP 会触发配置变更。
 *       {@code AndroidManifest.xml} 里 MainActivity 的 {@code android:configChanges}
 *       已经含 {@code orientation|screenSize|smallestScreenSize|screenLayout}
 *       四项，Activity 因此不会被重建、播放不会断。另外 Activity 销毁后再往
 *       Dart 侧 invoke 是野指针语义，{@link #destroy()} 会把 channel 置空，
 *       之后的 {@link #notifyModeChanged(boolean)} 退化成安全 no-op。</li>
 * </ol>
 */
public final class PictureInPictureChannelHandler {
    private static final String METHOD_IS_SUPPORTED = "isSupported";
    private static final String METHOD_ENTER = "enter";
    private static final String METHOD_IS_ACTIVE = "isActive";
    /** Dart 侧接收方向的方法名（原生 → Dart）。 */
    private static final String METHOD_ON_CHANGED = "onChanged";
    private static final String ARG_ASPECT_RATIO = "aspectRatio";

    /**
     * 宽高比用「定点分母 10000」的有理数表达。
     *
     * <p>为什么不直接 {@code Math.round(ratio * 10000)} 了事：系统那侧的判据是
     * {@code rational.toFloat() < 1f/2.39f || > 2.39f} 就抛。区间**下端**恰好卡在
     * 四舍五入的刀口上——1/2.39 = 0.4184100…，round 到 4 位小数是 0.4184，而
     * 0.4184 &lt; 0.41841，于是「已经钳制过」的比例照样抛异常。所以分子这里
     * 各向**区间内侧**让一格：4185/10000 = 0.4185 ≥ 1/2.39，
     * 23899/10000 = 2.3899 ≤ 2.39。
     */
    private static final int ASPECT_DENOMINATOR = 10000;
    private static final int MIN_ASPECT_NUMERATOR = 4185;
    private static final int MAX_ASPECT_NUMERATOR = 23899;
    /** Dart 侧传不出可用比例时的兜底（16:9）。 */
    private static final double DEFAULT_ASPECT_RATIO = 16.0 / 9.0;

    @NonNull
    private final Activity activity;

    /** Activity 销毁后置空，后续 invoke 全部退化成 no-op（见类注释第 3 条）。 */
    @Nullable
    private MethodChannel channel;

    public PictureInPictureChannelHandler(@NonNull Activity activity) {
        this.activity = activity;
    }

    public void register(@NonNull FlutterEngine engine) {
        final MethodChannel created = new MethodChannel(
                engine.getDartExecutor().getBinaryMessenger(),
                ChannelNames.PICTURE_IN_PICTURE);
        created.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case METHOD_IS_SUPPORTED:
                    result.success(isSupported());
                    return;
                case METHOD_ENTER:
                    result.success(enter(call.argument(ARG_ASPECT_RATIO)));
                    return;
                case METHOD_IS_ACTIVE:
                    result.success(isActive());
                    return;
                default:
                    result.notImplemented();
            }
        });
        channel = created;
    }

    /** MainActivity 的 onDestroy 调用：断开 handler 并置空，防止对死引擎 invoke。 */
    public void destroy() {
        if (channel != null) {
            channel.setMethodCallHandler(null);
            channel = null;
        }
    }

    /**
     * MainActivity 的 {@code onPictureInPictureModeChanged} 回调转发到 Dart。
     *
     * <p>这条回程是必需的：用户从 PiP 小窗的关闭 / 还原按钮退出时不经过我们的
     * {@code enter}，Dart 侧只有收到这条才知道自己已经不在 PiP 里了。
     */
    public void notifyModeChanged(boolean inPictureInPicture) {
        final MethodChannel current = channel;
        if (current == null) {
            return;
        }
        current.invokeMethod(METHOD_ON_CHANGED, inPictureInPicture);
    }

    /**
     * 本机能否进 PiP。
     *
     * <p>版本门（API 26）**和**系统特性开关都要问，理由见类注释第 1 条。
     */
    private boolean isSupported() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return false;
        }
        final PackageManager packageManager = activity.getPackageManager();
        return packageManager != null
                && packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE);
    }

    /** 当前是否已在 PiP 中。{@code isInPictureInPictureMode()} 自 API 24 起可用。 */
    private boolean isActive() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            return false;
        }
        try {
            return activity.isInPictureInPictureMode();
        } catch (Throwable error) {
            return false;
        }
    }

    /**
     * 显式进入 PiP，返回是否真的进去了。
     *
     * <p>任何异常一律吞掉并返回 false：进小窗是锦上添花的交互，为它崩掉整个
     * 播放进程（甚至整个 app）是不可接受的。真实的抛点有三处——版本不够、
     * 系统关了 PiP、比例越界；前两者被上面的门挡住，第三者被钳制挡住，
     * 这个 catch 是兜底而不是主路径。
     */
    private boolean enter(@Nullable Object rawAspectRatio) {
        // 版本门在这里**再写一遍**（isSupported 里已经有一份）：不是冗余，而是
        // 给 lint 的流分析一个它看得见的守卫——否则 PictureInPictureParams（API 26）
        // 会被报 NewApi，而它看不穿跨方法调用。
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !isSupported()) {
            return false;
        }
        try {
            final Rational aspectRatio = toRational(asDouble(rawAspectRatio));
            final PictureInPictureParams params = new PictureInPictureParams.Builder()
                    .setAspectRatio(aspectRatio)
                    .build();
            return activity.enterPictureInPictureMode(params);
        } catch (Throwable error) {
            android.util.Log.w("fushi-pip", "enterPictureInPictureMode failed", error);
            return false;
        }
    }

    private static double asDouble(@Nullable Object raw) {
        if (raw instanceof Number) {
            return ((Number) raw).doubleValue();
        }
        return DEFAULT_ASPECT_RATIO;
    }

    /**
     * 宽高比 → 系统一定接受的 {@link Rational}。
     *
     * <p>非有限值 / 非正值退回 16:9；其余钳进 {@code [1/2.39, 2.39]}。Dart 侧的
     * {@code clampPictureInPictureAspectRatio} 已经钳过一遍，这里是**第二道**——
     * 原生侧不假设调用方守规矩，而且 Dart 的钳制结果落在区间端点时还需要这里的
     * 定点让格（见 {@link #MIN_ASPECT_NUMERATOR} 注释）。
     */
    @NonNull
    static Rational toRational(double aspectRatio) {
        double value = aspectRatio;
        if (Double.isNaN(value) || Double.isInfinite(value) || value <= 0) {
            value = DEFAULT_ASPECT_RATIO;
        }
        long numerator = Math.round(value * ASPECT_DENOMINATOR);
        if (numerator < MIN_ASPECT_NUMERATOR) {
            numerator = MIN_ASPECT_NUMERATOR;
        } else if (numerator > MAX_ASPECT_NUMERATOR) {
            numerator = MAX_ASPECT_NUMERATOR;
        }
        return new Rational((int) numerator, ASPECT_DENOMINATOR);
    }
}
