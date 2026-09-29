package app.fushi.reader;

import android.app.ActivityOptions;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;

import androidx.annotation.NonNull;

/**
 * 从后台前台服务（悬浮字幕条 / 悬浮球 / 截屏 OCR 选取层）拉起 Activity 的唯一实现。
 *
 * <p>这些入口恰恰是在 Fushi 自己**不在前台**时使用的，所以裸 {@link Context#startActivity}
 * 是一次「后台启动 Activity」。API 29 起默认拦截；API 34（targetSdk 34+）不再让 app
 * 静默继承自己的后台启动特权；API 35 把 SYSTEM_ALERT_WINDOW 豁免收窄到「已授权且当前
 * 有可见悬浮窗」。严格的 OEM ROM 上裸启动会被直接丢弃，用户侧就是「点了没反应」。
 *
 * <p>API 34+ 走自有 {@link PendingIntent} 并带
 * {@link ActivityOptions#MODE_BACKGROUND_ACTIVITY_START_ALLOWED}——这是文档化的显式
 * 放行（我们持有 SYSTEM_ALERT_WINDOW 且悬浮窗可见）。低版本直接启动（其悬浮窗豁免宽）。
 * 任何失败回退到直接启动，再回退到把 Fushi 带回前台，保证一次点击绝不静默丢失；每个
 * 分支都打日志便于真机定位走的是哪条。
 *
 * <p>这是对不可控的平台限制（后台 Activity 启动策略）的边界兼容层，不是症状补丁。
 * 最早是 FloatingLyricService 私有的一份（TODO-1268），悬浮球 / 截屏 OCR 复用时抽到这里，
 * 三处共用。契约由 Dart 侧源码守卫 floating_lyric_android_tap_lookup_guard_test 钉住。
 */
final class BackgroundActivityLauncher {
    private static final String TAG = "BgActivityLauncher";

    private BackgroundActivityLauncher() {}

    /** 启动 {@code intent}（自动补 NEW_TASK）；全部失败时把 Fushi 带回前台。 */
    static void start(@NonNull Context context, @NonNull Intent intent) {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        if (sendAllowingBackgroundStart(context, intent)) return;
        try {
            context.startActivity(intent);
        } catch (RuntimeException e) {
            Log.w(TAG, "startActivity rejected (background-activity-launch blocked); "
                    + "foregrounding Fushi", e);
            bringAppToFront(context);
        }
    }

    /** 把 Fushi 主界面带回前台（同样走后台启动放行）。 */
    static void bringAppToFront(@NonNull Context context) {
        Intent intent = context.getPackageManager()
                .getLaunchIntentForPackage(context.getPackageName());
        if (intent == null) return;
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                | Intent.FLAG_ACTIVITY_SINGLE_TOP
                | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        if (sendAllowingBackgroundStart(context, intent)) return;
        try {
            context.startActivity(intent);
        } catch (RuntimeException e) {
            Log.w(TAG, "bringAppToFront rejected", e);
        }
    }

    private static boolean sendAllowingBackgroundStart(
            @NonNull Context context, @NonNull Intent intent) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return false;
        try {
            PendingIntent pending = PendingIntent.getActivity(
                    context, 0, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
            ActivityOptions options = ActivityOptions.makeBasic();
            options.setPendingIntentBackgroundActivityStartMode(
                    ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED);
            Bundle optionsBundle = options.toBundle();
            pending.send(context, 0, null, null, null, null, optionsBundle);
            return true;
        } catch (PendingIntent.CanceledException | RuntimeException e) {
            Log.w(TAG, "PendingIntent send failed; falling back to direct startActivity", e);
            return false;
        }
    }
}
