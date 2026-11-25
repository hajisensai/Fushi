package app.fushi.reader;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.LinkAddress;
import android.net.LinkProperties;
import android.net.Network;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Objects;

import app.fushi.reader.constants.ChannelNames;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.EventChannel;

/**
 * 「系统默认网络变了」事件流，给互联 P2P 隧道（iroh 端点）用：Dart 侧
 * {@code interconnect_p2p_app.dart} 收到一次事件就调一次 {@code fp2p_network_change}。
 *
 * <p>为什么要这条通道：iroh 的 netwatch 在 Android 上不做路由监视，睡眠检测一小时才轮询
 * 一次；切 Wi-Fi / 蜂窝后连接没断而路径已失效，隧道会长时间不通。
 *
 * <p>只在默认网络<b>真的</b>变化时发事件：换了一张网络（{@code onAvailable} 的句柄与上次
 * 不同）、默认网络没了（{@code onLost}）、同一张网络的接口名或地址集变了
 * （{@code onLinkPropertiesChanged}）。DNS、路由刷新不改接口与地址，不触发。注册时系统
 * 立即回调的当前网络先记下作基线，不算变化。
 */
public final class NetworkChangeChannel implements EventChannel.StreamHandler {
    private final ConnectivityManager connectivity;
    private final Handler main = new Handler(Looper.getMainLooper());

    @Nullable private EventChannel.EventSink sink;
    @Nullable private ConnectivityManager.NetworkCallback callback;
    // 以下状态只在主线程读写（回调先 post 到主线程）。
    @Nullable private Network lastNetwork;
    @Nullable private String lastLinkKey;

    private NetworkChangeChannel(@NonNull Context context) {
        connectivity = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
    }

    public static void registerWith(@NonNull FlutterEngine flutterEngine,
                                    @NonNull Context context) {
        new EventChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(),
                ChannelNames.NETWORK_CHANGE)
            .setStreamHandler(new NetworkChangeChannel(context.getApplicationContext()));
    }

    @Override
    public void onListen(Object arguments, EventChannel.EventSink events) {
        stop();
        if (connectivity == null) return;
        sink = events;
        lastNetwork = connectivity.getActiveNetwork();
        lastLinkKey = linkKey(lastNetwork == null ? null : connectivity.getLinkProperties(lastNetwork));
        final ConnectivityManager.NetworkCallback cb = new ConnectivityManager.NetworkCallback() {
            @Override
            public void onAvailable(@NonNull Network network) {
                main.post(() -> onDefaultAvailable(this, network));
            }

            @Override
            public void onLost(@NonNull Network network) {
                main.post(() -> onDefaultLost(this, network));
            }

            @Override
            public void onLinkPropertiesChanged(@NonNull Network network,
                                                @NonNull LinkProperties lp) {
                final String key = linkKey(lp);
                main.post(() -> onDefaultLinkChanged(this, network, key));
            }
        };
        callback = cb;
        connectivity.registerDefaultNetworkCallback(cb);
    }

    @Override
    public void onCancel(Object arguments) {
        stop();
    }

    private void stop() {
        final ConnectivityManager.NetworkCallback cb = callback;
        callback = null;
        sink = null;
        lastNetwork = null;
        lastLinkKey = null;
        if (cb != null && connectivity != null) {
            try {
                connectivity.unregisterNetworkCallback(cb);
            } catch (IllegalArgumentException alreadyUnregistered) {
                // 回调从没注册成功（注册时抛过）：没有要撤的。
            }
        }
    }

    private void onDefaultAvailable(ConnectivityManager.NetworkCallback from, Network network) {
        if (from != callback) return;
        if (network.equals(lastNetwork)) return;
        lastNetwork = network;
        lastLinkKey = linkKey(connectivity.getLinkProperties(network));
        emit();
    }

    private void onDefaultLost(ConnectivityManager.NetworkCallback from, Network network) {
        if (from != callback) return;
        if (!network.equals(lastNetwork)) return;
        lastNetwork = null;
        lastLinkKey = null;
        emit();
    }

    private void onDefaultLinkChanged(ConnectivityManager.NetworkCallback from,
                                      Network network, @Nullable String key) {
        if (from != callback) return;
        if (!network.equals(lastNetwork)) return;
        if (Objects.equals(key, lastLinkKey)) return;
        lastLinkKey = key;
        emit();
    }

    private void emit() {
        final EventChannel.EventSink s = sink;
        if (s != null) s.success(null);
    }

    /** 接口名 + 排序后的地址列表；DNS / 路由变化不进键。 */
    @Nullable
    static String linkKey(@Nullable LinkProperties lp) {
        if (lp == null) return null;
        final List<String> addrs = new ArrayList<>();
        for (LinkAddress a : lp.getLinkAddresses()) addrs.add(a.toString());
        Collections.sort(addrs);
        return lp.getInterfaceName() + "|" + String.join(",", addrs);
    }
}
