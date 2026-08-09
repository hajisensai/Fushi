package app.fushi.reader;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.Settings;

import androidx.annotation.NonNull;

import app.fushi.reader.constants.ChannelNames;
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

    /**
     * 是否持有「所有文件访问权限」（{@code MANAGE_EXTERNAL_STORAGE}）。
     *
     * <p>迁移中转目录在公共 {@code Documents/Hibiki/migration}（有意如此：不在
     * {@code /Android/data} 下，卸载老包不会被系统清掉）。但分区存储下，**别的
     * 应用创建的非媒体文件**（.zip/.manifest.json）本包默认读不到——没有这个
     * 权限时连 683 字节的清单都会抛 {@code PathAccessException}。
     *
     * <p>Android 10 及以下没有这个概念，全靠 legacy 外部存储，恒为 true。
     */
    private static boolean hasAllFilesAccess() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return true;
        return Environment.isExternalStorageManager();
    }

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
                        case "hasAllFilesAccess": {
                            result.success(hasAllFilesAccess());
                            return;
                        }
                        case "requestAllFilesAccess": {
                            // 这个权限没有 runtime 权限那种「弹框直接给」的路径：
                            // 系统只允许跳到设置页由用户手动打开（Android 11+）。
                            // 调用方必须在 onResume 时用 hasAllFilesAccess 复查，
                            // 不得因为「跳过了设置页」就当已授权。
                            if (!hasAllFilesAccess()) {
                                Intent intent = new Intent(
                                        Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                        Uri.parse("package:" + context.getPackageName()));
                                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                                try {
                                    context.startActivity(intent);
                                } catch (Exception e) {
                                    // 个别 ROM 没有这个 per-app 页面，退回全局列表页。
                                    Intent fallback = new Intent(
                                            Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION);
                                    fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                                    context.startActivity(fallback);
                                }
                            }
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
