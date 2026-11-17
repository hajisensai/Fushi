package app.fushi.reader;

import android.app.Activity;
import android.app.PendingIntent;
import android.app.PictureInPictureParams;
import android.app.RemoteAction;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.graphics.drawable.Icon;
import android.os.Build;
import android.util.Rational;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;
import androidx.core.content.ContextCompat;

import java.util.Collections;

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
 *   <li><b>小窗上的按钮是 app 给的</b>：系统只在 app 通过
 *       {@link PictureInPictureParams.Builder#setActions} 交了 {@link RemoteAction}
 *       （或有活动的 MediaSession）时才在 PiP 窗口上画播放控件，否则只有
 *       「展开 / 关闭」。这里交一个播放 / 暂停键：点击经 {@link PendingIntent} 发一条
 *       **只发给本包**的广播，由本类动态注册的**不导出**接收器收下、转成
 *       {@code onAction} 回程给 Dart。图标跟播放态走，所以播放态一变 Dart 就调
 *       {@code update} 让这里 {@code setPictureInPictureParams} 一次。</li>
 * </ol>
 */
public final class PictureInPictureChannelHandler {
    private static final String METHOD_IS_SUPPORTED = "isSupported";
    private static final String METHOD_ENTER = "enter";
    private static final String METHOD_UPDATE = "update";
    private static final String METHOD_IS_ACTIVE = "isActive";
    /** Dart 侧接收方向的方法名（原生 → Dart）。 */
    private static final String METHOD_ON_CHANGED = "onChanged";
    /** Dart 侧接收方向：用户点了 PiP 窗口上的动作键，参数是动作的 wire 名。 */
    private static final String METHOD_ON_ACTION = "onAction";
    private static final String ARG_ASPECT_RATIO = "aspectRatio";
    private static final String ARG_PLAYING = "playing";
    private static final String ARG_PLAY_PAUSE_LABEL = "playPauseLabel";
    /** Dart 侧 {@code PictureInPictureAction.playPause} 的枚举名。 */
    private static final String ACTION_WIRE_PLAY_PAUSE = "playPause";
    /**
     * 播放 / 暂停广播的 action 后缀；完整 action 是「包名 + 后缀」，这样并排安装的
     * 调试版 / 正式版（包名不同）不会互相收到对方的按键。
     */
    private static final String BROADCAST_PLAY_PAUSE_SUFFIX = ".action.PIP_PLAY_PAUSE";
    private static final int REQUEST_PLAY_PAUSE = 1;

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

    /** PiP 窗口动作键的接收器；非空 = 已注册（{@link #destroy()} 里注销）。 */
    @Nullable
    private BroadcastReceiver actionReceiver;

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
                    result.success(enter(
                            call.argument(ARG_ASPECT_RATIO),
                            call.argument(ARG_PLAYING),
                            call.argument(ARG_PLAY_PAUSE_LABEL)));
                    return;
                case METHOD_UPDATE:
                    update(
                            call.argument(ARG_ASPECT_RATIO),
                            call.argument(ARG_PLAYING),
                            call.argument(ARG_PLAY_PAUSE_LABEL));
                    result.success(null);
                    return;
                case METHOD_IS_ACTIVE:
                    result.success(isActive());
                    return;
                default:
                    result.notImplemented();
            }
        });
        channel = created;
        registerActionReceiver();
    }

    /**
     * 注册 PiP 动作键的接收器（幂等）。
     *
     * <p>{@link ContextCompat#RECEIVER_NOT_EXPORTED}：只收本 app 自己（含系统代本
     * app 触发的 {@link PendingIntent}）发来的广播；Android 14 起动态注册的接收器
     * 不声明导出性会直接抛 SecurityException。接收器默认在主线程回调，正好是
     * {@link MethodChannel#invokeMethod} 要求的线程。
     */
    private void registerActionReceiver() {
        if (actionReceiver != null) {
            return;
        }
        final BroadcastReceiver receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                final MethodChannel current = channel;
                if (current == null || intent == null
                        || !playPauseBroadcastAction().equals(intent.getAction())) {
                    return;
                }
                current.invokeMethod(METHOD_ON_ACTION, ACTION_WIRE_PLAY_PAUSE);
            }
        };
        ContextCompat.registerReceiver(
                activity,
                receiver,
                new IntentFilter(playPauseBroadcastAction()),
                ContextCompat.RECEIVER_NOT_EXPORTED);
        actionReceiver = receiver;
    }

    @NonNull
    private String playPauseBroadcastAction() {
        return activity.getPackageName() + BROADCAST_PLAY_PAUSE_SUFFIX;
    }

    /** MainActivity 的 onDestroy 调用：断开 handler 并置空，防止对死引擎 invoke。 */
    public void destroy() {
        if (actionReceiver != null) {
            activity.unregisterReceiver(actionReceiver);
            actionReceiver = null;
        }
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
    private boolean enter(
            @Nullable Object rawAspectRatio,
            @Nullable Boolean playing,
            @Nullable String playPauseLabel) {
        // 版本门在这里**再写一遍**（isSupported 里已经有一份）：不是冗余，而是
        // 给 lint 的流分析一个它看得见的守卫——否则 PictureInPictureParams（API 26）
        // 会被报 NewApi，而它看不穿跨方法调用。
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !isSupported()) {
            return false;
        }
        try {
            return activity.enterPictureInPictureMode(
                    buildParams(rawAspectRatio, playing, playPauseLabel));
        } catch (Throwable error) {
            android.util.Log.w("fushi-pip", "enterPictureInPictureMode failed", error);
            return false;
        }
    }

    /**
     * 已在 PiP 里时刷新窗口参数（播放态变了换按钮图标、换集后换窗口比例）。
     *
     * <p>{@code rawAspectRatio} 为 null 表示 Dart 侧还不知道新比例：此时不带比例，
     * 系统对没设的字段保持原值（{@code setPictureInPictureParams} 只合并已设字段）。
     * 异常与 {@link #enter} 同理一律吞掉。
     */
    private void update(
            @Nullable Object rawAspectRatio,
            @Nullable Boolean playing,
            @Nullable String playPauseLabel) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !isSupported()) {
            return;
        }
        try {
            activity.setPictureInPictureParams(
                    buildParams(rawAspectRatio, playing, playPauseLabel));
        } catch (Throwable error) {
            android.util.Log.w("fushi-pip", "setPictureInPictureParams failed", error);
        }
    }

    /**
     * 组装 PiP 参数。{@code rawAspectRatio} 为 null 时不设比例（仅 {@link #update}
     * 会这样传；{@link #enter} 的 Dart 侧恒带比例）；{@code playing} 为 null 表示
     * 调用方不要动作键：窗口上只留系统的「展开 / 关闭」，之前交过的键一并撤掉。
     */
    @RequiresApi(Build.VERSION_CODES.O)
    @NonNull
    private PictureInPictureParams buildParams(
            @Nullable Object rawAspectRatio,
            @Nullable Boolean playing,
            @Nullable String playPauseLabel) {
        final PictureInPictureParams.Builder builder = new PictureInPictureParams.Builder();
        if (rawAspectRatio != null) {
            builder.setAspectRatio(toRational(asDouble(rawAspectRatio)));
        }
        // 动作键每次都**显式**设：{@code setPictureInPictureParams} 只合并已设字段，
        // 不设 = 沿用 Activity 上一次留下的那组键。Dart 侧没有可操作的播放器时
        // （换集加载中 / 加载失败 / 原盘菜单）传的是 playing == null，此时必须交一个
        // 空列表把键撤掉——否则它留在窗口上、点了没人接。
        // 设备可以把 PiP 动作键上限配成 0（getMaxNumPictureInPictureActions），那时
        // 多交会被系统截断并打警告日志，同样交空列表。
        if (playing != null && activity.getMaxNumPictureInPictureActions() >= 1) {
            builder.setActions(Collections.singletonList(
                    buildPlayPauseAction(playing, playPauseLabel)));
        } else {
            builder.setActions(Collections.<RemoteAction>emptyList());
        }
        return builder.build();
    }

    @RequiresApi(Build.VERSION_CODES.O)
    @NonNull
    private RemoteAction buildPlayPauseAction(boolean playing, @Nullable String label) {
        // setPackage：显式限定收件方为本包，配合不导出的接收器，别的 app 既发不进来
        // 也收不到。FLAG_IMMUTABLE：Android 12 起 PendingIntent 必须声明可变性，这条
        // 广播不带任何需要系统回填的内容。FLAG_UPDATE_CURRENT：同一 requestCode 复用
        // 同一个 PendingIntent，不随每次播放态翻转堆新的。
        final Intent intent = new Intent(playPauseBroadcastAction())
                .setPackage(activity.getPackageName());
        final PendingIntent pendingIntent = PendingIntent.getBroadcast(
                activity,
                REQUEST_PLAY_PAUSE,
                intent,
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        // 正在播 → 按下去是暂停，画暂停图标；反之画播放图标。
        final Icon icon = Icon.createWithResource(
                activity, playing ? R.drawable.ic_pip_pause : R.drawable.ic_pip_play);
        final String title = label == null ? "" : label;
        return new RemoteAction(icon, title, title, pendingIntent);
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
