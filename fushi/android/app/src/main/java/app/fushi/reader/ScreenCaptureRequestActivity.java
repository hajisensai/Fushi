package app.fushi.reader;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.media.projection.MediaProjectionConfig;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.HashMap;
import java.util.Map;

/**
 * 截屏 OCR 第一步：透明、不进最近任务的 Activity，只负责弹系统的屏幕录制确认框。
 *
 * <p>为什么要有它：{@link MediaProjectionManager#createScreenCaptureIntent()} 只能用
 * {@code startActivityForResult} 从 Activity 发起，悬浮球服务 / Flutter 通道都不行。
 * 用户同意后把授权结果原样交给 {@link ScreenOcrService}（mediaProjection 类型前台
 * 服务——Android 14 起 getMediaProjection 必须在该类型前台服务里、且在 startForeground
 * 之后调用），然后立刻无动画 finish，好让截到的画面里没有这层窗口。
 *
 * <p>拒绝 / 取消：安静结束，把悬浮球放回来，不弹任何提示。
 */
public class ScreenCaptureRequestActivity extends Activity {
    private static final String TAG = "ScreenCaptureRequest";
    private static final int REQUEST_CAPTURE = 0x5C0C;
    private static final String STATE_REQUESTED = "requested";

    static final String EXTRA_LANGUAGE = "language";
    static final String EXTRA_LABELS = "labels";

    /** 本实例是否仍负责收尾（交给 ScreenOcrService 后即为 false）。 */
    private boolean ownsFlow = false;

    /** 整条 OCR 流程（确认框 → 截屏 → 选取层）是否在进行中；防止连点起两套。 */
    private static volatile boolean flowActive = false;

    /**
     * 发起截屏 OCR。需要悬浮窗权限（选取层是 TYPE_APPLICATION_OVERLAY）；没有权限或
     * 已有一次流程在进行时返回 false，不做任何事。
     */
    static boolean launch(
            @NonNull Context context,
            @Nullable String language,
            @Nullable Map<String, String> labels) {
        if (!Settings.canDrawOverlays(context)) return false;
        if (flowActive) return false;
        // 「进行中」与藏球放在 onCreate 里做，而不是这里：后台启动 Activity 可能被系统
        // 静默丢弃（BackgroundActivityLauncher 无法得知），在这里先上锁就会把球永久藏掉。
        Intent intent = new Intent(context, ScreenCaptureRequestActivity.class);
        intent.putExtra(EXTRA_LANGUAGE, language == null ? "" : language);
        intent.putExtra(EXTRA_LABELS, toBundle(labels));
        intent.addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION);
        BackgroundActivityLauncher.start(context, intent);
        return true;
    }

    /** 流程结束（任何出口）时调用：解锁并把悬浮球放回来。主线程。 */
    static void onFlowFinished() {
        flowActive = false;
        FloatingBallService.setCaptureHidden(false);
        // 没截到帧就结束（拒绝 / 出错 / 服务被停）时这是 Dart 唯一的回调；截到帧时
        // ScreenOcrService 已经提前回调过，这里是 no-op。
        FloatingBallChannel.notifyScreenOcrFinished();
    }

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (savedInstanceState != null && savedInstanceState.getBoolean(STATE_REQUESTED)) {
            // 进程内重建（例如旋转）：确认框已经弹过，等 onActivityResult 即可。
            ownsFlow = flowActive;
            return;
        }
        if (flowActive) {
            // 连点：上一次流程（确认框 / 截屏 / 选取层）还没结束。
            finishQuietly();
            return;
        }
        flowActive = true;
        ownsFlow = true;
        // 球先藏起来：它既不能出现在截图里，也不能盖在选取层上。确认框弹出前就藏，
        // 截屏时它早已不在合成结果里。
        FloatingBallService.setCaptureHidden(true);
        MediaProjectionManager mpm = getSystemService(MediaProjectionManager.class);
        if (mpm == null) {
            finishFlow();
            return;
        }
        Intent consent;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // Android 14 的确认框允许只共享「单个 app」；OCR 要的是用户眼前的整块屏幕，
            // 直接要默认显示器，免得用户误选成某个 app 截到的却不是当前画面。
            consent = mpm.createScreenCaptureIntent(
                    MediaProjectionConfig.createConfigForDefaultDisplay());
        } else {
            consent = mpm.createScreenCaptureIntent();
        }
        try {
            startActivityForResult(consent, REQUEST_CAPTURE);
        } catch (RuntimeException e) {
            Log.w(TAG, "screen capture consent could not be shown", e);
            finishFlow();
        }
    }

    @Override
    protected void onSaveInstanceState(@NonNull Bundle outState) {
        super.onSaveInstanceState(outState);
        outState.putBoolean(STATE_REQUESTED, true);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, @Nullable Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQUEST_CAPTURE) return;
        if (resultCode != RESULT_OK || data == null) {
            finishFlow();
            return;
        }
        Intent svc = new Intent(this, ScreenOcrService.class);
        svc.putExtra(ScreenOcrService.EXTRA_RESULT_CODE, resultCode);
        svc.putExtra(ScreenOcrService.EXTRA_RESULT_DATA, data);
        svc.putExtra(ScreenOcrService.EXTRA_LANGUAGE,
                getIntent().getStringExtra(EXTRA_LANGUAGE));
        svc.putExtra(ScreenOcrService.EXTRA_LABELS, getIntent().getBundleExtra(EXTRA_LABELS));
        try {
            // 本 Activity 此刻在前台，满足前台服务的启动豁免。
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(svc);
            } else {
                startService(svc);
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "ScreenOcrService could not be started", e);
            finishFlow();
            return;
        }
        // 流程所有权交给 ScreenOcrService，由它在选取层关闭时收尾。
        ownsFlow = false;
        finishQuietly();
    }

    @Override
    protected void onDestroy() {
        // 没拿到结果就被销毁（系统回收、确认框被别的方式打断）：不收尾的话球会被永久藏住。
        if (ownsFlow && isFinishing()) finishFlow();
        super.onDestroy();
    }

    private void finishFlow() {
        ownsFlow = false;
        onFlowFinished();
        if (!isFinishing()) finishQuietly();
    }

    private void finishQuietly() {
        finish();
        overridePendingTransition(0, 0);
    }

    static Bundle toBundle(@Nullable Map<String, String> labels) {
        Bundle bundle = new Bundle();
        if (labels == null) return bundle;
        for (Map.Entry<String, String> e : labels.entrySet()) {
            if (e.getKey() != null && e.getValue() != null) {
                bundle.putString(e.getKey(), e.getValue());
            }
        }
        return bundle;
    }

    static Map<String, String> fromBundle(@Nullable Bundle bundle) {
        Map<String, String> out = new HashMap<>();
        if (bundle == null) return out;
        for (String key : bundle.keySet()) {
            String value = bundle.getString(key);
            if (value != null) out.put(key, value);
        }
        return out;
    }
}
