package app.fushi.reader;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.media.projection.MediaProjectionConfig;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.Map;

/**
 * 跨应用语音缓存（拍板 oqk37s3QFL）的授权宿主：透明 Activity，先要录音权限
 * （AudioPlaybackCapture 要求 RECORD_AUDIO），再弹系统的屏幕共享确认框，用户同意后把
 * 授权交给 {@link CrossAppAudioService} 并立刻结束。
 *
 * <p>任何一步被拒 / 取消：经 {@link CrossAppAudioChannel#completeStart} 把原因还给
 * Dart（{@code denied}），不弹提示。
 */
public class CrossAppAudioRequestActivity extends Activity {
    private static final String TAG = "CrossAppAudioRequest";
    private static final int REQUEST_PERMISSION = 0xA0D1;
    private static final int REQUEST_CAPTURE = 0xA0D2;
    private static final String STATE_STARTED = "started";

    static final String EXTRA_LABELS = "labels";

    /** 本实例是否还欠 Dart 一个结果。 */
    private boolean owesResult = false;

    static void launch(@NonNull Context context, @Nullable Map<String, String> labels) {
        Intent intent = new Intent(context, CrossAppAudioRequestActivity.class);
        intent.putExtra(EXTRA_LABELS, ScreenCaptureRequestActivity.toBundle(labels));
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION);
        context.startActivity(intent);
    }

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        owesResult = true;
        if (savedInstanceState != null && savedInstanceState.getBoolean(STATE_STARTED)) {
            // 进程内重建（旋转等）：权限框 / 确认框已经弹过，等回调即可。
            return;
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            finishWith("unsupported");
            return;
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] {Manifest.permission.RECORD_AUDIO},
                    REQUEST_PERMISSION);
            return;
        }
        requestProjection();
    }

    @Override
    protected void onSaveInstanceState(@NonNull Bundle outState) {
        super.onSaveInstanceState(outState);
        outState.putBoolean(STATE_STARTED, true);
    }

    @Override
    public void onRequestPermissionsResult(
            int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode != REQUEST_PERMISSION) return;
        if (grantResults.length == 0 || grantResults[0] != PackageManager.PERMISSION_GRANTED) {
            finishWith("denied");
            return;
        }
        requestProjection();
    }

    private void requestProjection() {
        MediaProjectionManager mpm = getSystemService(MediaProjectionManager.class);
        if (mpm == null) {
            finishWith("start_failed");
            return;
        }
        Intent consent;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // Android 14 的确认框允许只共享「单个 app」；录游戏声音要整机播放，直接要默认
            // 显示器，免得用户误选成某个 app 后换游戏就录不到。
            consent = mpm.createScreenCaptureIntent(
                    MediaProjectionConfig.createConfigForDefaultDisplay());
        } else {
            consent = mpm.createScreenCaptureIntent();
        }
        try {
            startActivityForResult(consent, REQUEST_CAPTURE);
        } catch (RuntimeException e) {
            Log.w(TAG, "screen capture consent could not be shown", e);
            finishWith("start_failed");
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, @Nullable Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQUEST_CAPTURE) return;
        if (resultCode != RESULT_OK || data == null) {
            finishWith("denied");
            return;
        }
        Intent svc = new Intent(this, CrossAppAudioService.class);
        svc.putExtra(CrossAppAudioService.EXTRA_RESULT_CODE, resultCode);
        svc.putExtra(CrossAppAudioService.EXTRA_RESULT_DATA, data);
        svc.putExtra(CrossAppAudioService.EXTRA_LABELS, getIntent().getBundleExtra(EXTRA_LABELS));
        try {
            // 本 Activity 此刻在前台，满足前台服务的启动豁免。
            startForegroundService(svc);
        } catch (RuntimeException e) {
            Log.w(TAG, "CrossAppAudioService could not be started", e);
            finishWith("start_failed");
            return;
        }
        // 结果由服务的状态回调（CrossAppAudioChannel 的 StateListener）给出。
        owesResult = false;
        finishQuietly();
    }

    @Override
    protected void onDestroy() {
        // 没拿到结果就被销毁（系统回收、从最近任务划掉、被别的方式打断）：别让 Dart 一直等。
        // 只有配置变更重建才接着等；判据不能用 isFinishing()——非 finishing 的销毁之后
        // Activity 未必重建，pendingStart 会永远挂着（BUG-4792）。
        if (CrossAppAudioPolicy.releasesPendingStartOnDestroy(
                owesResult, isChangingConfigurations())) {
            owesResult = false;
            CrossAppAudioChannel.completeStart(false, "denied");
        }
        super.onDestroy();
    }

    private void finishWith(@NonNull String error) {
        owesResult = false;
        CrossAppAudioChannel.completeStart(false, error);
        finishQuietly();
    }

    private void finishQuietly() {
        finish();
        overridePendingTransition(0, 0);
    }
}
