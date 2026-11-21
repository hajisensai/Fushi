package app.fushi.reader;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;

import androidx.annotation.NonNull;

import java.util.Map;

import app.fushi.reader.constants.ChannelNames;
import app.fushi.reader.constants.PreferenceKeys;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/**
 * 系统通知设置里各通知渠道显示的名字（拍板台 left3621）。
 *
 * <p>界面文案的唯一来源是 Dart 的 i18n json（17 种语言，只经 {@code i18n_sync} 改），
 * 原生不另维护一套 {@code values-xx/strings.xml}。主引擎启动时 Dart
 * （{@code android_notification_channels.dart}）把「渠道 id → 当前界面语言的名字」整表
 * 推过来：这里落进 SharedPreferences，并把<strong>已经建过的</strong>渠道就地改名
 * （同 id 再 {@code createNotificationChannel} 只会更新名字 / 描述，用户调过的重要性、
 * 静音不受影响）。各服务建渠道时经 {@link #nameFor} 取名，从没进过 app 主界面的极端
 * 情况才退回英文兜底。</p>
 *
 * <p>手机端换界面语言会重启 app，下一次主引擎启动就把新语言的整表推过来，所以不需要
 * 单独的「语言变了」回调。</p>
 */
public final class NotificationChannelNames {

    private NotificationChannelNames() {}

    static final String METHOD_SYNC = "sync";

    /** 当前界面语言下渠道 {@code channelId} 的名字；Dart 还没推过时返回 {@code fallback}。 */
    @NonNull
    public static String nameFor(@NonNull Context context, @NonNull String channelId,
            @NonNull String fallback) {
        String stored = prefs(context).getString(channelId, null);
        return stored == null || stored.isEmpty() ? fallback : stored;
    }

    /** 主引擎上注册 {@link ChannelNames#NOTIFICATION_CHANNELS}。 */
    public static void registerWith(@NonNull FlutterEngine engine, @NonNull Context context) {
        final Context appContext = context.getApplicationContext();
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(),
                ChannelNames.NOTIFICATION_CHANNELS)
                .setMethodCallHandler((call, result) -> {
                    if (!METHOD_SYNC.equals(call.method)) {
                        result.notImplemented();
                        return;
                    }
                    Object args = call.arguments;
                    if (!(args instanceof Map)) {
                        result.error("bad_args", "expected {channelId: name}", null);
                        return;
                    }
                    result.success(apply(appContext, (Map<?, ?>) args));
                });
    }

    /**
     * 落盘整表并给已存在的渠道改名，返回实际改了名的渠道数。非字符串、空的条目跳过。
     */
    static int apply(@NonNull Context context, @NonNull Map<?, ?> names) {
        SharedPreferences.Editor editor = prefs(context).edit();
        NotificationManager nm = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? context.getSystemService(NotificationManager.class)
                : null;
        int renamed = 0;
        for (Map.Entry<?, ?> e : names.entrySet()) {
            if (!(e.getKey() instanceof String) || !(e.getValue() instanceof String)) continue;
            String id = (String) e.getKey();
            String name = (String) e.getValue();
            if (id.isEmpty() || name.isEmpty()) continue;
            editor.putString(id, name);
            if (nm != null && rename(nm, id, name)) renamed++;
        }
        editor.apply();
        return renamed;
    }

    private static boolean rename(@NonNull NotificationManager nm, @NonNull String id,
            @NonNull String name) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false;
        NotificationChannel existing = nm.getNotificationChannel(id);
        if (existing == null) return false;
        CharSequence current = existing.getName();
        if (current != null && name.contentEquals(current)) return false;
        // 只换名字：沿用现有重要性与描述（系统对已存在的渠道本来也只接受名字 / 描述更新，
        // 用户在系统设置里调过的重要性、静音都保留）。
        NotificationChannel updated = new NotificationChannel(id, name, existing.getImportance());
        updated.setDescription(existing.getDescription());
        nm.createNotificationChannel(updated);
        return true;
    }

    @NonNull
    private static SharedPreferences prefs(@NonNull Context context) {
        return context.getApplicationContext().getSharedPreferences(
                PreferenceKeys.FILE_NOTIFICATION_CHANNELS, Context.MODE_PRIVATE);
    }
}
