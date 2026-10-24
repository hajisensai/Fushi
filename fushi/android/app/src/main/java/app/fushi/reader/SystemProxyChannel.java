package app.fushi.reader;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.ProxyInfo;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.HashMap;
import java.util.Map;

import app.fushi.reader.constants.ChannelNames;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/**
 * 读 Android 系统代理（Wi-Fi「代理：手动 / 自动配置」、全局 HTTP 代理）给 Dart 侧
 * {@code app_proxy.dart} 的自动模式用。
 *
 * <p>为什么要这条通道：Android 把系统代理交给 {@link ConnectivityManager#getDefaultProxy()}
 * 与 JVM 系统属性 {@code http.proxyHost}，WebView / OkHttp 都认它；Dart {@code HttpClient}
 * 不认。没有它，WebView 里能打开 YouTube，同一台设备上 Dart 侧的 YouTube 解析却一路
 * 直连超时（报「无法获取视频流」）。
 *
 * <p>每次调用都现读（不缓存）：系统代理随当前默认网络变化，Dart 侧按有效期刷新。
 * 主 engine 与 :popup 副 engine 都注册（Dart 侧每个 entry point 都会装配出站代理）。
 */
public final class SystemProxyChannel {
    private static final String METHOD_GET_HTTP_PROXY = "getHttpProxy";

    private SystemProxyChannel() {
    }

    public static void registerWith(@NonNull FlutterEngine flutterEngine,
                                    @NonNull Context context) {
        final Context appContext = context.getApplicationContext();
        new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(),
                ChannelNames.SYSTEM_PROXY)
            .setMethodCallHandler((call, result) -> {
                if (!METHOD_GET_HTTP_PROXY.equals(call.method)) {
                    result.notImplemented();
                    return;
                }
                result.success(readHttpProxy(appContext));
            });
    }

    /** 无代理返回 null；有则 {host, port, exclusionList}。 */
    @Nullable
    static Map<String, Object> readHttpProxy(@NonNull Context context) {
        final ConnectivityManager cm =
                (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
        ProxyInfo info = null;
        if (cm != null) {
            try {
                info = cm.getDefaultProxy();
            } catch (RuntimeException ignored) {
                // 个别 ROM 在网络切换瞬间抛：退到 JVM 系统属性。
            }
        }
        String host = null;
        int port = -1;
        String exclusion = null;
        if (info != null && info.getHost() != null && !info.getHost().isEmpty()) {
            host = info.getHost();
            port = info.getPort();
            final String[] excl = info.getExclusionList();
            if (excl != null && excl.length > 0) exclusion = String.join(",", excl);
        } else {
            host = System.getProperty("http.proxyHost");
            final String p = System.getProperty("http.proxyPort");
            try {
                port = p == null ? -1 : Integer.parseInt(p.trim());
            } catch (NumberFormatException ignored) {
                port = -1;
            }
            exclusion = System.getProperty("http.nonProxyHosts");
        }
        if (host == null || host.isEmpty() || port <= 0) return null;
        final Map<String, Object> map = new HashMap<>();
        map.put("host", host);
        map.put("port", port);
        if (exclusion != null) map.put("exclusionList", exclusion);
        return map;
    }
}
