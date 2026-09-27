package app.fushi.reader;

import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.util.Log;

import androidx.core.content.pm.ShortcutInfoCompat;
import androidx.core.content.pm.ShortcutManagerCompat;
import androidx.core.graphics.drawable.IconCompat;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/// 长按 app 图标弹出的动态快捷方式（Dart 门面 `lib/src/platform/app_shortcuts.dart`）。
///
/// 每条快捷方式就是一条指向 MainActivity 的 ACTION_VIEW intent，data 为
/// `fushi://shortcut/<id>`：冷启动时 `ReceiveIntent.getInitialIntent()`、热启动时
/// singleTask 的 onNewIntent 都会把它交给 Dart 的 `handleIncomingUrl`，不需要另起
/// 投递通道。列表由 Dart 按模块开关与界面语言整表下发，这里只负责换图标并替换。
public final class AppShortcutsHelper {
    private static final String TAG = "AppShortcuts";

    private AppShortcutsHelper() {}

    public static void setShortcuts(Context context, List<Map<String, String>> items) {
        List<ShortcutInfoCompat> shortcuts = new ArrayList<>();
        int max = ShortcutManagerCompat.getMaxShortcutCountPerActivity(context);
        for (Map<String, String> item : items) {
            if (shortcuts.size() >= max) break;
            String id = item.get("id");
            String title = item.get("title");
            String url = item.get("url");
            if (id == null || title == null || url == null) continue;
            Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(url))
                .setClass(context, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            shortcuts.add(new ShortcutInfoCompat.Builder(context, id)
                .setShortLabel(title)
                .setLongLabel(title)
                .setIcon(IconCompat.createWithResource(context, iconFor(id)))
                .setIntent(intent)
                .setRank(shortcuts.size())
                .build());
        }
        try {
            ShortcutManagerCompat.setDynamicShortcuts(context, shortcuts);
        } catch (RuntimeException e) {
            // 系统限流（后台频繁更新）或启动器不支持时只丢图标菜单，不影响 app。
            Log.w(TAG, "setDynamicShortcuts failed", e);
        }
    }

    private static int iconFor(String id) {
        switch (id) {
            case "lookup":
                return R.drawable.ic_shortcut_lookup;
            case "books":
                return R.drawable.ic_shortcut_books;
            case "manga":
                return R.drawable.ic_shortcut_manga;
            case "video":
                return R.drawable.ic_shortcut_video;
            case "games":
                return R.drawable.ic_shortcut_games;
            case "settings":
            default:
                return R.drawable.ic_shortcut_settings;
        }
    }
}
