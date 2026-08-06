package app.hibiki.reader;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;

import androidx.annotation.NonNull;

import app.hibiki.reader.constants.ChannelNames;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/**
 * Hibiki→Fushi 跨包名迁移的平台能力（改名迁移计划 P1-3/P1-4）。
 *
 * <ul>
 *   <li>{@code isPackageInstalled(name)}：新包是否已装（需 manifest 里的
 *       {@code <queries>} 声明，Android 11+ 包可见性）。</li>
 *   <li>{@code launchPackage(name)}：前台拉起新包（用户点按钮触发，
 *       带 {@code source=hibiki_migration} extra）。</li>
 *   <li>{@code requestUninstall(name)}：ACTION_DELETE 弹系统卸载确认框；
 *       无静默卸载能力，用户点确认/取消由调用方事后用
 *       {@code isPackageInstalled} 复查。</li>
 *   <li>{@code setProcessTextEnabled(bool)}：启/停 PROCESS_TEXT 词典入口
 *       （PopupDictFlutterActivity 组件级禁用——系统取词菜单里真的少一项，
 *       不是只藏 UI；已迁移只读态用）。</li>
 * </ul>
 */
public final class MigrationChannelHandler {
    private MigrationChannelHandler() {}

    public static void registerWith(
            @NonNull FlutterEngine engine, @NonNull Context context) {
        new MethodChannel(
                engine.getDartExecutor().getBinaryMessenger(), ChannelNames.MIGRATION)
                .setMethodCallHandler((call, result) -> {
                    switch (call.method) {
                        case "isPackageInstalled": {
                            String name = call.argument("package");
                            if (name == null) {
                                result.error("bad_args", "package is required", null);
                                return;
                            }
                            try {
                                context.getPackageManager().getPackageInfo(name, 0);
                                result.success(true);
                            } catch (PackageManager.NameNotFoundException e) {
                                result.success(false);
                            }
                            return;
                        }
                        case "launchPackage": {
                            String name = call.argument("package");
                            if (name == null) {
                                result.error("bad_args", "package is required", null);
                                return;
                            }
                            Intent launch =
                                    context.getPackageManager().getLaunchIntentForPackage(name);
                            if (launch == null) {
                                result.success(false);
                                return;
                            }
                            launch.putExtra("source", "hibiki_migration");
                            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                            context.startActivity(launch);
                            result.success(true);
                            return;
                        }
                        case "requestUninstall": {
                            String name = call.argument("package");
                            if (name == null) {
                                result.error("bad_args", "package is required", null);
                                return;
                            }
                            Intent intent = new Intent(
                                    Intent.ACTION_DELETE, Uri.parse("package:" + name));
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                            context.startActivity(intent);
                            result.success(null);
                            return;
                        }
                        case "setProcessTextEnabled": {
                            Boolean enabled = call.argument("enabled");
                            ComponentName component = new ComponentName(
                                    context, PopupDictFlutterActivity.class);
                            context.getPackageManager().setComponentEnabledSetting(
                                    component,
                                    Boolean.TRUE.equals(enabled)
                                            ? PackageManager.COMPONENT_ENABLED_STATE_DEFAULT
                                            : PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                                    PackageManager.DONT_KILL_APP);
                            result.success(null);
                            return;
                        }
                        default:
                            result.notImplemented();
                    }
                });
    }
}
