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

    private static final List<String> ALIAS_NAMES = Arrays.asList(
        ".MainActivityDefault",
        ".MainActivityHibikiFull",
        ".MainActivityHibikiMinimal"
    );

    private static final List<String> ALIAS_KEYS = Arrays.asList(
        "default",
        "hibiki_full",
        "hibiki_minimal"
    );

    public static String getCurrentIcon(Context context) {
        PackageManager pm = context.getPackageManager();
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
