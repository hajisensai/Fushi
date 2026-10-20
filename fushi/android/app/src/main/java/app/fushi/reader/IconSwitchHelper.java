package app.fushi.reader;

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

    private static final String PACKAGE_NAME = "app.fushi.reader";

    // 唯一对外预设：default（兔子图标，薰衣草底 squircle）。「立绘」与「透明 wordmark」
    // 两档已下线，图标资源随之删除。
    private static final List<String> ALIAS_NAMES = Arrays.asList(
        ".MainActivityDefault"
    );

    private static final List<String> ALIAS_KEYS = Arrays.asList(
        "default"
    );

    // 已退役的 alias：不再作为可选项，但 manifest 仍声明它们，以免老用户（当前启动器
    // 指向其中之一、且 default alias 已被禁用）在升级后 launcher 图标消失
    // （zero-LAUNCHER）。getCurrentIcon 会把这类老用户安全迁回 default alias。
    private static final List<String> RETIRED_ALIASES = Arrays.asList(
        ".MainActivityFushiMinimal",
        ".MainActivityFushiTransparent",
        ".MainActivityFushiFull"
    );

    public static String getCurrentIcon(Context context) {
        PackageManager pm = context.getPackageManager();

        // 老用户迁移：若任一退役 alias 当前启用，把它迁回 default alias。
        migrateRetiredAliasesIfEnabled(pm);

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

    /// 把仍处于启用态的退役 alias 迁回 default alias。
    ///
    /// 先启用 default 再逐个禁用退役 alias，避免出现零 LAUNCHER 入口的瞬态。退役档的
    /// 图标资源已删除、manifest 里也已改指向 default 的图标，所以迁移不会改变观感；
    /// 没有启用态的退役 alias 时为 no-op。
    private static void migrateRetiredAliasesIfEnabled(PackageManager pm) {
        boolean anyEnabled = false;
        for (String alias : RETIRED_ALIASES) {
            ComponentName cn = new ComponentName(PACKAGE_NAME, PACKAGE_NAME + alias);
            if (pm.getComponentEnabledSetting(cn) == PackageManager.COMPONENT_ENABLED_STATE_ENABLED) {
                anyEnabled = true;
                break;
            }
        }
        if (!anyEnabled) {
            return;
        }

        ComponentName fallback = new ComponentName(PACKAGE_NAME, PACKAGE_NAME + ALIAS_NAMES.get(0));
        pm.setComponentEnabledSetting(fallback,
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP);

        for (String alias : RETIRED_ALIASES) {
            ComponentName cn = new ComponentName(PACKAGE_NAME, PACKAGE_NAME + alias);
            if (pm.getComponentEnabledSetting(cn) == PackageManager.COMPONENT_ENABLED_STATE_ENABLED) {
                pm.setComponentEnabledSetting(cn,
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP);
            }
        }
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

    /// 快捷方式图标的边长（像素）。
    static final int SHORTCUT_ICON_PX = 512;

    /// 解码采样率：在短边仍不小于 [targetPx] 的前提下取最大的 2 的幂。
    ///
    /// 只拿 512px 的图标，没必要把用户挑的整张原图按全分辨率解码进内存
    /// （BUG-3601）；纯函数，便于脱离 Android 框架单测。
    static int iconDecodeSampleSize(int width, int height, int targetPx) {
        int shortEdge = Math.min(width, height);
        int sample = 1;
        if (targetPx <= 0) return sample;
        while (shortEdge / (sample * 2) >= targetPx) {
            sample *= 2;
        }
        return sample;
    }

    public static boolean createCustomShortcut(Context context, byte[] imageBytes) {
        if (!isCustomShortcutSupported(context)) return false;
        if (imageBytes == null || imageBytes.length == 0) return false;

        // 先只读尺寸，再按目标边长降采样解码（BUG-3601）：此前直接全分辨率
        // decodeByteArray，大图在低内存机型上整段管线峰值过高。
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.length, bounds);
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return false;
        BitmapFactory.Options decode = new BitmapFactory.Options();
        decode.inSampleSize = iconDecodeSampleSize(bounds.outWidth, bounds.outHeight, SHORTCUT_ICON_PX);
        Bitmap original = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.length, decode);
        if (original == null) return false;

        int size = Math.min(original.getWidth(), original.getHeight());
        int x = (original.getWidth() - size) / 2;
        int y = (original.getHeight() - size) / 2;
        Bitmap cropped = Bitmap.createBitmap(original, x, y, size, size);

        Bitmap scaled = Bitmap.createScaledBitmap(cropped, SHORTCUT_ICON_PX, SHORTCUT_ICON_PX, true);
        // createBitmap / createScaledBitmap 在无需变换时（已是正方形 / 已是 512px）
        // 直接返回入参本身。只能回收与 scaled 不是同一对象的中间图，否则会把要交给
        // 启动器的那张图一起回收掉（BUG-3601）。
        if (cropped != original && cropped != scaled) cropped.recycle();
        if (original != scaled) original.recycle();

        IconCompat icon = IconCompat.createWithAdaptiveBitmap(scaled);

        Intent launchIntent = new Intent(Intent.ACTION_MAIN)
            .setClass(context, MainActivity.class)
            .addCategory(Intent.CATEGORY_LAUNCHER);

        // 快捷方式 id 是改名前的历史值：已固定到桌面的快捷方式按 id 认领，改 id 会让旧快捷方式
        // 无法再被本 app 更新 / 停用，故冻结不改。
        ShortcutInfoCompat shortcut = new ShortcutInfoCompat.Builder(context, "hibiki_custom_icon")
            .setShortLabel("Fushi")
            .setIcon(icon)
            .setIntent(launchIntent)
            .build();

        boolean result = ShortcutManagerCompat.requestPinShortcut(context, shortcut, null);
        scaled.recycle();
        return result;
    }
}
