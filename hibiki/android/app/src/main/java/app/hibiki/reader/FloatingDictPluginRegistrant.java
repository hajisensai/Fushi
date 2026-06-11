package app.hibiki.reader;

import androidx.annotation.NonNull;
import io.flutter.Log;
import io.flutter.embedding.engine.FlutterEngine;

final class FloatingDictPluginRegistrant {
    private static final String TAG = "FloatingDictPluginReg";

    private FloatingDictPluginRegistrant() {}

    static void registerWith(@NonNull FlutterEngine flutterEngine) {
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
    }
}
