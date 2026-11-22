package app.fushi.reader;

import android.app.Activity;
import android.app.KeyguardManager;
import android.content.Context;
import android.content.Intent;
import android.hardware.biometrics.BiometricManager;
import android.hardware.biometrics.BiometricPrompt;
import android.os.Build;
import android.os.CancellationSignal;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/**
 * 上锁作品的系统验证（拍板台 qiqSbvdxrk，Dart 侧 {@code media_lock_auth.dart}）：
 * 生物识别或设备锁屏密码。
 *
 * <p>只用平台 API：{@code android.hardware.biometrics.BiometricPrompt}（API 29+ 允许
 * 设备凭据兜底，30+ 用 {@code setAllowedAuthenticators}）不要求 FragmentActivity，
 * 主 Activity 不必换基类；API 24–28 走 {@code KeyguardManager} 的确认锁屏页
 * （{@link MainActivity#onActivityResult} 转回这里）。
 *
 * <p>结果约定：{@code "success"} / {@code "failed"}（取消或没通过）/
 * {@code "unavailable"}（没设锁屏）。
 */
final class DeviceOwnerAuthChannel {
    static final String CHANNEL = "app.fushi.reader/device_owner_auth";
    static final int REQUEST_CODE = 0x4A71;

    private static DeviceOwnerAuthChannel instance;

    private final Activity activity;
    private MethodChannel.Result pending;
    private CancellationSignal cancel;

    private DeviceOwnerAuthChannel(Activity activity) {
        this.activity = activity;
    }

    static void registerWith(@NonNull FlutterEngine engine, @NonNull Activity activity) {
        final DeviceOwnerAuthChannel channel = new DeviceOwnerAuthChannel(activity);
        instance = channel;
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), CHANNEL)
                .setMethodCallHandler((call, result) -> {
                    switch (call.method) {
                        case "isAvailable":
                            result.success(channel.isAvailable());
                            break;
                        case "authenticate":
                            final String reason = call.argument("reason");
                            channel.authenticate(reason == null ? "" : reason, result);
                            break;
                        default:
                            result.notImplemented();
                    }
                });
    }

    /** {@link MainActivity#onActivityResult} 转来；是本通道的请求时返回 true。 */
    static boolean onActivityResult(int requestCode, int resultCode) {
        final DeviceOwnerAuthChannel channel = instance;
        if (requestCode != REQUEST_CODE || channel == null) return false;
        channel.finish(resultCode == Activity.RESULT_OK ? "success" : "failed");
        return true;
    }

    private boolean isAvailable() {
        final KeyguardManager keyguard =
                (KeyguardManager) activity.getSystemService(Context.KEYGUARD_SERVICE);
        return keyguard != null && keyguard.isDeviceSecure();
    }

    private void finish(String outcome) {
        final MethodChannel.Result result = pending;
        pending = null;
        cancel = null;
        if (result != null) result.success(outcome);
    }

    @SuppressWarnings("deprecation")
    private void authenticate(String reason, MethodChannel.Result result) {
        if (pending != null) {
            // 上一次还没结束（重复点击）：后到的直接判失败，不顶掉前一个。
            result.success("failed");
            return;
        }
        if (!isAvailable()) {
            result.success("unavailable");
            return;
        }
        pending = result;
        final String title = reason.isEmpty() ? activity.getTitle().toString() : reason;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            final BiometricPrompt.Builder builder =
                    new BiometricPrompt.Builder(activity).setTitle(title);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                builder.setAllowedAuthenticators(
                        BiometricManager.Authenticators.BIOMETRIC_WEAK
                                | BiometricManager.Authenticators.DEVICE_CREDENTIAL);
            } else {
                builder.setDeviceCredentialAllowed(true);
            }
            cancel = new CancellationSignal();
            try {
                builder.build().authenticate(
                        cancel,
                        activity.getMainExecutor(),
                        new BiometricPrompt.AuthenticationCallback() {
                            @Override
                            public void onAuthenticationSucceeded(
                                    BiometricPrompt.AuthenticationResult r) {
                                finish("success");
                            }

                            @Override
                            public void onAuthenticationError(int code, CharSequence msg) {
                                finish("failed");
                            }
                            // onAuthenticationFailed = 这一下没认出来，系统界面还开着，
                            // 等最终结果。
                        });
            } catch (RuntimeException e) {
                pending = null;
                cancel = null;
                result.error("device_auth", e.getMessage(), null);
            }
            return;
        }
        final KeyguardManager keyguard =
                (KeyguardManager) activity.getSystemService(Context.KEYGUARD_SERVICE);
        final Intent intent = keyguard.createConfirmDeviceCredentialIntent(title, null);
        if (intent == null) {
            finish("unavailable");
            return;
        }
        activity.startActivityForResult(intent, REQUEST_CODE);
    }
}
