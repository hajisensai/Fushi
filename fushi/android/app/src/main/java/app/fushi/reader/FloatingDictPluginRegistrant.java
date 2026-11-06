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
        // BUG-3663：本地音频库（发音）查询走 `app.fushi.reader/tts` 的 queryLocalAudio。
        // 该 channel 原先同样只在 MainActivity 的主 engine 注册：app 外查词里
        // TtsChannel.queryLocalAudio 抛 MissingPluginException 被吞成 null，配了本地
        // 音频库的用户点 ♪ 只得到「暂无发音」，而 app 内同一个词有发音。:popup 进程里
        // 这个 engine 被缓存到进程结束，handler 随它常驻（库句柄由 Dart 侧
        // setLocalAudioDb 绑定，进程退出时随进程释放）。
        try {
            new TtsChannelHandler(context).register(flutterEngine);
        } catch (Exception e) {
            Log.e(TAG, "Error registering tts channel", e);
        }
        // 出站代理自动模式读系统代理（SystemProxyChannel）：副 engine 的查词发音 / 网络
        // 词典同样要走 Wi-Fi 代理，缺这条 channel 时 Dart 侧退化为直连。
        try {
            SystemProxyChannel.registerWith(flutterEngine, context);
        } catch (Exception e) {
            Log.e(TAG, "Error registering system proxy channel", e);
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
