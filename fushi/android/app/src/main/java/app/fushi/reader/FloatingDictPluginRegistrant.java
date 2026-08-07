package app.fushi.reader;

import android.content.Context;

import androidx.annotation.NonNull;
import io.flutter.Log;
import io.flutter.embedding.engine.FlutterEngine;

final class FloatingDictPluginRegistrant {
    private static final String TAG = "FloatingDictPluginReg";

    private FloatingDictPluginRegistrant() {}

    static void registerWith(@NonNull FlutterEngine flutterEngine, @NonNull Context context) {
        // BUG-865：副 FlutterEngine（popupMain）上的制卡走 AnkiRepository 的
        // `app.fushi.reader/anki` MethodChannel。该 channel 原先只在 MainActivity 的主
        // engine 注册，副 engine 未注册 → app 外查词面（剪贴板/悬浮/选区弹窗）制卡时
        // invokeMethod('addNote') 抛 MissingPluginException，toast 显示「导出卡片失败：
        // AnkiDroid: unexpected error: MissingPluginException(...)」。这里用
        // applicationContext（activity=null）补注册：ContentProvider 制卡是进程+权限
        // 作用域，Context 足够；权限弹窗须在主 app 完成（见 AnkiChannelHandler）。
        try {
            new AnkiChannelHandler(context, null).register(flutterEngine);
        } catch (Exception e) {
            Log.e(TAG, "Error registering anki channel", e);
        }
        try {
            flutterEngine.getPlugins().add(
                new dev.fluttercommunity.plus.device_info.DeviceInfoPlusPlugin());
        } catch (Exception e) {
            Log.e(TAG, "Error registering plugin device_info_plus", e);
        }
        try {
            flutterEngine.getPlugins().add(
                new io.flutter.plugins.flutter_plugin_android_lifecycle.FlutterAndroidLifecyclePlugin());
        } catch (Exception e) {
            Log.e(TAG, "Error registering plugin flutter_plugin_android_lifecycle", e);
        }
        try {
            flutterEngine.getPlugins().add(
                new dev.fluttercommunity.plus.packageinfo.PackageInfoPlugin());
        } catch (Exception e) {
            Log.e(TAG, "Error registering plugin package_info_plus", e);
        }
        try {
            flutterEngine.getPlugins().add(
                new io.flutter.plugins.pathprovider.PathProviderPlugin());
        } catch (Exception e) {
            Log.e(TAG, "Error registering plugin path_provider_android", e);
        }
        try {
            flutterEngine.getPlugins().add(
                new io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin());
        } catch (Exception e) {
            Log.e(TAG, "Error registering plugin shared_preferences_android", e);
        }
        try {
            flutterEngine.getPlugins().add(new com.tekartik.sqflite.SqflitePlugin());
        } catch (Exception e) {
            Log.e(TAG, "Error registering plugin sqflite", e);
        }
        try {
            flutterEngine.getPlugins().add(
                new eu.simonbinder.sqlite3_flutter_libs.Sqlite3FlutterLibsPlugin());
        } catch (Exception e) {
            Log.e(TAG, "Error registering plugin sqlite3_flutter_libs", e);
        }
        try {
            flutterEngine.getPlugins().add(
                new io.github.ponnamkarthik.toast.fluttertoast.FlutterToastPlugin());
        } catch (Exception e) {
            Log.e(TAG, "Error registering plugin fluttertoast", e);
        }
        try {
            flutterEngine.getPlugins().add(
                new com.pichillilorenzo.flutter_inappwebview_android.InAppWebViewFlutterPlugin());
        } catch (Exception e) {
            Log.e(TAG, "Error registering plugin flutter_inappwebview_android", e);
        }
        try {
            flutterEngine.getPlugins().add(
                new io.flutter.plugins.urllauncher.UrlLauncherPlugin());
        } catch (Exception e) {
            Log.e(TAG, "Error registering plugin url_launcher_android", e);
        }
        try {
            flutterEngine.getPlugins().add(
                new dev.fluttercommunity.plus.share.SharePlusPlugin());
        } catch (Exception e) {
            Log.e(TAG, "Error registering plugin share_plus", e);
        }
    }
}
