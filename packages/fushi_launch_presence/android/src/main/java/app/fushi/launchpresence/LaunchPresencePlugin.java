package app.fushi.launchpresence;

import android.app.Activity;
import android.app.ActivityManager;

import androidx.annotation.NonNull;

import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * BUG-4072：如实告诉 Dart 这个引擎当下有没有界面。
 *
 * <p>作为 Flutter 插件经 GeneratedPluginRegistrant 注册到<b>每个</b> FlutterEngine，包括
 * audio_service 在 {@code AudioService.onCreate} 里无 Activity 新建、直接跑 {@code main()}
 * 的那个引擎（它不经过 {@code MainActivity.configureFlutterEngine}，那里注册的通道在它上面全是
 * MissingPluginException）。
 *
 * <p>判据是 ActivityAware 的附着状态：FlutterActivity 在 {@code onCreate → delegate.onAttach}
 * 里同步把引擎附到 Activity，Dart 发来的第一条通道消息要等主线程下一轮才派发，所以带界面的
 * 冷启动问到时一定已附着；无界面引擎从未附着。
 */
public final class LaunchPresencePlugin implements FlutterPlugin, ActivityAware,
        MethodChannel.MethodCallHandler {
    static final String CHANNEL = "app.fushi.reader/launch_presence";
    static final String METHOD_QUERY = "query";

    private MethodChannel channel;

    /** 当前附着的 Activity 类名；没有附着为 null。只存名字，不持有 Activity。 */
    private String attachedActivity;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (channel != null) {
            channel.setMethodCallHandler(null);
            channel = null;
        }
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        attachedActivity = nameOf(binding.getActivity());
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        // 配置变更（旋转等）马上会重新附着，界面一直在：保留附着状态。
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        attachedActivity = nameOf(binding.getActivity());
    }

    @Override
    public void onDetachedFromActivity() {
        attachedActivity = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        if (!METHOD_QUERY.equals(call.method)) {
            result.notImplemented();
            return;
        }
        final ActivityManager.RunningAppProcessInfo info =
                new ActivityManager.RunningAppProcessInfo();
        ActivityManager.getMyMemoryState(info);
        final Map<String, Object> out = new HashMap<>();
        out.put("hasUi", attachedActivity != null);
        out.put("detail", "activity=" + (attachedActivity == null ? "none" : attachedActivity)
                + " importance=" + info.importance);
        result.success(out);
    }

    private static String nameOf(Activity activity) {
        return activity.getClass().getSimpleName();
    }
}
