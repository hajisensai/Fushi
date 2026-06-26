package app.hibiki.reader;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Build;

import androidx.core.content.pm.ShortcutInfoCompat;
import androidx.core.content.pm.ShortcutManagerCompat;
import androidx.core.graphics.drawable.IconCompat;

import java.util.Arrays;
import java.util.List;

public class IconSwitchHelper {

    private static final String PACKAGE_NAME = "app.hibiki.reader";

    // 当前对外提供的两套预设（default + full）。第三档 hibiki_minimal 与 default
    // 映射同一张图（重复选项），已从 UI/选择列表去重移除（TODO-868）。
    private static final List<String> ALIAS_NAMES = Arrays.asList(
        ".MainActivityDefault",
        ".MainActivityHibikiFull"
    );

    private static final List<String> ALIAS_KEYS = Arrays.asList(
        "default",
        "hibiki_full"
    );

    // 已退役的「简约」alias：不再作为可选项，但 manifest 仍声明它，以免老用户
    // （当前 launcher 指向此 alias、且 default alias 已被禁用）在升级后 launcher
    // 图标消失。getCurrentIcon 会把这类老用户安全迁回 default alias（图标字节相同，
    // 无视觉变化）。
    private static final String RETIRED_MINIMAL_ALIAS = ".MainActivityHibikiMinimal";

    public static String getCurrentIcon(Context context) {
        PackageManager pm = context.getPackageManager();

        // 老用户迁移：若退役的「简约」alias 当前启用，把它迁回 default alias
        // （两者图标字节相同，无视觉变化），消除去重后残留的孤立启用态。
        migrateRetiredMinimalIfEnabled(context, pm);

        for (int i = 0; i < ALIAS_NAMES.size(); i++) {
            ComponentName cn = new ComponentName(PACKAGE_NAME, PACKAGE_NAME + ALIAS_NAMES.get(i));
            int state = pm.getComponentEnabledSetting(cn);
            if (state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                || (state == PackageManager.COMPONENT_ENABLED_STATE_DEFAULT && i == 0)) {
                return ALIAS_KEYS.get(i);
            }
        }
        return "default";
    }

    /// 若退役的 hibiki_minimal alias 当前为启用态，先启用 default alias 再禁用它，
    /// 把老用户的启动器入口迁回 default（图标相同）。先启用后禁用，避免出现零
    /// LAUNCHER 入口的瞬态。已迁移过（minimal 非启用）则为 no-op。
    private static void migrateRetiredMinimalIfEnabled(Context context, PackageManager pm) {
        ComponentName minimal = new ComponentName(PACKAGE_NAME, PACKAGE_NAME + RETIRED_MINIMAL_ALIAS);
        int minimalState = pm.getComponentEnabledSetting(minimal);
        if (minimalState != PackageManager.COMPONENT_ENABLED_STATE_ENABLED) {
            return;
        }
        ComponentName def = new ComponentName(PACKAGE_NAME, PACKAGE_NAME + ALIAS_NAMES.get(0));
        pm.setComponentEnabledSetting(def,
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP);
        pm.setComponentEnabledSetting(minimal,
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP);
    }

    public static boolean switchPresetIcon(Context context, String targetKey) {
        int targetIndex = ALIAS_KEYS.indexOf(targetKey);
        if (targetIndex < 0) return false;

        String currentKey = getCurrentIcon(context);
        if (currentKey.equals(targetKey)) return true;

        int currentIndex = ALIAS_KEYS.indexOf(currentKey);
        PackageManager pm = context.getPackageManager();

        // Enable new alias FIRST, then disable old — avoids zero-LAUNCHER catastrophe
        ComponentName newAlias = new ComponentName(PACKAGE_NAME, PACKAGE_NAME + ALIAS_NAMES.get(targetIndex));
        pm.setComponentEnabledSetting(newAlias,
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP);

        if (currentIndex >= 0) {
            ComponentName oldAlias = new ComponentName(PACKAGE_NAME, PACKAGE_NAME + ALIAS_NAMES.get(currentIndex));
            pm.setComponentEnabledSetting(oldAlias,
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP);
        }

        return true;
    }

    public static boolean isCustomShortcutSupported(Context context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false;
        return ShortcutManagerCompat.isRequestPinShortcutSupported(context);
    }

    public static boolean createCustomShortcut(Context context, byte[] imageBytes) {
        if (!isCustomShortcutSupported(context)) return false;

        Bitmap original = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.length);
        if (original == null) return false;

        int size = Math.min(original.getWidth(), original.getHeight());
        int x = (original.getWidth() - size) / 2;
        int y = (original.getHeight() - size) / 2;
        Bitmap cropped = Bitmap.createBitmap(original, x, y, size, size);

        Bitmap scaled = Bitmap.createScaledBitmap(cropped, 512, 512, true);
        if (cropped != original) cropped.recycle();
        original.recycle();

        IconCompat icon = IconCompat.createWithAdaptiveBitmap(scaled);

        Intent launchIntent = new Intent(Intent.ACTION_MAIN)
            .setClass(context, MainActivity.class)
            .addCategory(Intent.CATEGORY_LAUNCHER);

        ShortcutInfoCompat shortcut = new ShortcutInfoCompat.Builder(context, "hibiki_custom_icon")
            .setShortLabel("Hibiki")
            .setIcon(icon)
            .setIntent(launchIntent)
            .build();

        boolean result = ShortcutManagerCompat.requestPinShortcut(context, shortcut, null);
        scaled.recycle();
        return result;
    }
}
