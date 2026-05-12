// Derived from the AnkiDroid API Sample

package app.hibiki.reader;

import android.app.Activity;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.KeyEvent;
import androidx.annotation.NonNull;
import android.net.Uri;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

import android.provider.Settings;
import android.content.SharedPreferences;
import android.graphics.drawable.ColorDrawable;
import androidx.core.content.FileProvider;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.InputStream;
import java.io.OutputStream;

import androidx.documentfile.provider.DocumentFile;

import com.ryanheise.audioservice.AudioServiceActivity;
import android.content.Context;
import android.content.res.Configuration;

public class MainActivity extends AudioServiceActivity {
    private static final String VOLUME_KEY_CHANNEL = "app.hibiki.reader/volume_keys";
    private static final String SAF_CHANNEL = "app.hibiki.reader/saf";
    private static final String UPDATE_CHANNEL = "app.hibiki.reader/update";
    private static final String FONTS_CHANNEL = "app.hibiki.reader/fonts";
    private static final String FLOATING_LYRIC_CHANNEL = "app.hibiki.reader/floating_lyric";
    private static final String FLOATING_DICT_CHANNEL = "app.hibiki.reader/floating_dict";
    private static final String SPLASH_CHANNEL = "app.hibiki.reader/splash";
    private static final String LIFECYCLE_CHANNEL = "app.hibiki.reader/lifecycle";
    private static final String ICON_CHANNEL = "app.hibiki.reader/icon_switch";
    private static final String SPLASH_PREFS = "hibiki_splash";
    private static final int SAF_PICK_DIR_REQUEST = 1001;
    private static MethodChannel floatingLyricChannel;
    private static MethodChannel floatingDictChannel;

    private Activity context;
    private AnkiChannelHandler ankiChannelHandler;
    private TtsChannelHandler ttsChannelHandler;
    private MethodChannel.Result pendingSafResult;
    private String pendingSafDestPath;
    private final ExecutorService ioExecutor = Executors.newFixedThreadPool(2);

    // Reader opens this gate when volume-key page turning is enabled so
    // dispatchKeyEvent swallows VOLUME_UP/DOWN and forwards them to Dart.
    private volatile boolean volumeKeyIntercept = false;
    private MethodChannel volumeKeyChannel;

    @Override
    protected void attachBaseContext(Context newBase) {
        SharedPreferences prefs = newBase.getSharedPreferences(SPLASH_PREFS, MODE_PRIVATE);
        if (prefs.contains("is_dark")) {
            boolean isDark = prefs.getBoolean("is_dark", false);
            int currentNight = newBase.getResources().getConfiguration().uiMode
                    & Configuration.UI_MODE_NIGHT_MASK;
            boolean systemDark = currentNight == Configuration.UI_MODE_NIGHT_YES;
            if (isDark != systemDark) {
                Configuration config = new Configuration(
                        newBase.getResources().getConfiguration());
                config.uiMode = (config.uiMode & ~Configuration.UI_MODE_NIGHT_MASK)
                        | (isDark ? Configuration.UI_MODE_NIGHT_YES
                                  : Configuration.UI_MODE_NIGHT_NO);
                super.attachBaseContext(newBase.createConfigurationContext(config));
                return;
            }
        }
        super.attachBaseContext(newBase);
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        SharedPreferences splashPrefs = getSharedPreferences(SPLASH_PREFS, MODE_PRIVATE);
        int bgColor = splashPrefs.getInt("bg_color", 0);
        if (bgColor != 0) {
            getWindow().setBackgroundDrawable(new ColorDrawable(bgColor));
        }
        context = MainActivity.this;
        ankiChannelHandler = new AnkiChannelHandler(context);
        ttsChannelHandler = new TtsChannelHandler(context);

        super.onCreate(savedInstanceState);
        isAppRunning = false;
    }

    @Override
    protected void onDestroy() {
        if (ttsChannelHandler != null) {
            ttsChannelHandler.destroy();
        }
        ioExecutor.shutdownNow();
        super.onDestroy();
    }

    private static boolean isAppRunning;

    public static boolean getIsAppRunning() {
        return isAppRunning;
    }

    public static void notifyFloatingLyricEvent(String method, Map<String, Object> arguments) {
        if (floatingLyricChannel == null) return;
        new Handler(Looper.getMainLooper()).post(() -> {
            floatingLyricChannel.invokeMethod(method, arguments);
        });
    }


    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        if (volumeKeyIntercept) {
            int code = event.getKeyCode();
            if (code == KeyEvent.KEYCODE_VOLUME_UP || code == KeyEvent.KEYCODE_VOLUME_DOWN) {
                if (event.getAction() == KeyEvent.ACTION_DOWN && volumeKeyChannel != null) {
                    final String method = code == KeyEvent.KEYCODE_VOLUME_UP
                            ? "onVolumeUp"
                            : "onVolumeDown";
                    new Handler(Looper.getMainLooper()).post(() -> {
                        volumeKeyChannel.invokeMethod(method, null);
                    });
                }
                return true;
            }
        }
        return super.dispatchKeyEvent(event);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == SAF_PICK_DIR_REQUEST) {
            if (pendingSafResult == null) return;
            final MethodChannel.Result safResult = pendingSafResult;
            final String destPath = pendingSafDestPath;
            pendingSafResult = null;
            pendingSafDestPath = null;
            if (resultCode != Activity.RESULT_OK || data == null || data.getData() == null) {
                safResult.success(null);
                return;
            }
            Uri treeUri = data.getData();
            ioExecutor.execute(() -> {
                try {
                    DocumentFile dir = DocumentFile.fromTreeUri(context, treeUri);
                    if (dir == null || !dir.exists()) {
                        new Handler(Looper.getMainLooper()).post(() ->
                            safResult.error("NOT_FOUND", "Directory not found", null));
                        return;
                    }
                    File destDir = new File(destPath);
                    if (destDir.exists()) deleteRecursive(destDir);
                    destDir.mkdirs();
                    copyDocumentTree(dir, destDir);
                    new Handler(Looper.getMainLooper()).post(() ->
                        safResult.success(destPath));
                } catch (Exception e) {
                    new Handler(Looper.getMainLooper()).post(() ->
                        safResult.error("SAF_ERROR", e.getMessage(), null));
                }
            });
        }
    }

    private static boolean isAccessibilityServiceEnabled(Context context,
            Class<?> serviceClass) {
        String prefString = android.provider.Settings.Secure.getString(
                context.getContentResolver(),
                android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
        if (prefString == null) return false;
        String flatName = context.getPackageName() + "/"
                + serviceClass.getName();
        return prefString.contains(flatName);
    }

    private void deleteRecursive(File f) {
        if (f.isDirectory()) {
            File[] children = f.listFiles();
            if (children != null) {
                for (File child : children) deleteRecursive(child);
            }
        }
        f.delete();
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        FloatingDictService.initEngineGroup(getApplicationContext());

        volumeKeyChannel = new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(), VOLUME_KEY_CHANNEL);
        volumeKeyChannel.setMethodCallHandler((call, result) -> {
            if ("setInterceptEnabled".equals(call.method)) {
                Object arg = call.arguments;
                volumeKeyIntercept = arg instanceof Boolean && (Boolean) arg;
                result.success(null);
            } else {
                result.notImplemented();
            }
        });

        ankiChannelHandler.register(flutterEngine);
        ttsChannelHandler.register(flutterEngine);

        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), SAF_CHANNEL)
            .setMethodCallHandler((call, result) -> {
                switch (call.method) {
                    case "pickAndCopyDirectory": {
                        String destPath = call.argument("destPath");
                        if (destPath == null) {
                            result.error("INVALID_ARG", "destPath required", null);
                            return;
                        }
                        pendingSafResult = result;
                        pendingSafDestPath = destPath;
                        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
                        startActivityForResult(intent, SAF_PICK_DIR_REQUEST);
                        break;
                    }
                    default:
                        result.notImplemented();
                }
            });

        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), UPDATE_CHANNEL)
            .setMethodCallHandler((call, result) -> {
                if ("installApk".equals(call.method)) {
                    String path = call.argument("path");
                    if (path == null || path.isEmpty()) {
                        result.error("INVALID_PATH", "APK path is null", null);
                        return;
                    }
                    try {
                        File apkFile = new File(path);
                        Uri apkUri = FileProvider.getUriForFile(
                                context,
                                BuildConfig.APPLICATION_ID + ".provider",
                                apkFile);
                        Intent intent = new Intent(Intent.ACTION_VIEW);
                        intent.setDataAndType(apkUri, "application/vnd.android.package-archive");
                        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                        context.startActivity(intent);
                        result.success(true);
                    } catch (Exception e) {
                        result.error("INSTALL_ERROR", e.getMessage(), null);
                    }
                } else {
                    result.notImplemented();
                }
            });

        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), SPLASH_CHANNEL)
            .setMethodCallHandler((call, result) -> {
                SharedPreferences prefs = getSharedPreferences(SPLASH_PREFS, MODE_PRIVATE);
                switch (call.method) {
                    case "setSplashColor": {
                        Map<String, Object> args = (Map<String, Object>) call.arguments;
                        Number colorNumber = (Number) args.get("color");
                        int color = colorNumber.intValue();
                        boolean isDark = (boolean) args.get("isDark");
                        prefs.edit()
                             .putInt("bg_color", color)
                             .putBoolean("is_dark", isDark)
                             .apply();
                        getWindow().setBackgroundDrawable(new ColorDrawable(color));
                        result.success(null);
                        break;
                    }
                    case "getSplashColor": {
                        int color = prefs.getInt("bg_color", 0);
                        result.success(color);
                        break;
                    }
                    default:
                        result.notImplemented();
                }
            });

        floatingLyricChannel = new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(), FLOATING_LYRIC_CHANNEL);
        floatingLyricChannel.setMethodCallHandler((call, result) -> {
                switch (call.method) {
                    case "show": {
                        if (!Settings.canDrawOverlays(context)) {
                            Intent intent = new Intent(
                                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    Uri.parse("package:" + getPackageName()));
                            startActivity(intent);
                            result.success(false);
                            return;
                        }
                        Intent svc = new Intent(context, FloatingLyricService.class);
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(svc);
                        } else {
                            startService(svc);
                        }
                        result.success(true);
                        break;
                    }
                    case "hide": {
                        stopService(new Intent(context, FloatingLyricService.class));
                        result.success(true);
                        break;
                    }
                    case "updateText": {
                        String text = call.argument("text");
                        FloatingLyricService svc = FloatingLyricService.getInstance();
                        if (svc != null && text != null) {
                            svc.updateLyricText(text);
                        }
                        result.success(null);
                        break;
                    }
                    case "updateStyle": {
                        Number size = call.argument("fontSize");
                        Number color = call.argument("textColor");
                        Number bg = call.argument("bgColor");
                        Number buttonTextColor = call.argument("buttonTextColor");
                        Number buttonBgColor = call.argument("buttonBgColor");
                        Number highlightColor = call.argument("highlightColor");
                        Number activeColor = call.argument("activeColor");
                        FloatingLyricService svc = FloatingLyricService.getInstance();
                        if (svc != null) {
                            svc.updateStyle(
                                    size != null ? size.floatValue() : 16f,
                                    color != null ? color.intValue() : 0xFFFFFFFF,
                                    bg != null ? bg.intValue() : 0xCC000000,
                                    buttonTextColor != null ? buttonTextColor.intValue() : 0xFFFFFFFF,
                                    buttonBgColor != null ? buttonBgColor.intValue() : 0x33000000,
                                    highlightColor != null ? highlightColor.intValue() : 0x80FFD54F,
                                    activeColor != null ? activeColor.intValue() : 0xFFFFD54F);
                        }
                        result.success(null);
                        break;
                    }
                    case "highlight": {
                        Number start = call.argument("start");
                        Number length = call.argument("length");
                        FloatingLyricService svc = FloatingLyricService.getInstance();
                        if (svc != null) {
                            svc.updateHighlight(
                                    start != null ? start.intValue() : -1,
                                    length != null ? length.intValue() : 0);
                        }
                        result.success(null);
                        break;
                    }
                    case "updateLabels": {
                        Object labels = call.arguments;
                        FloatingLyricService svc = FloatingLyricService.getInstance();
                        if (svc != null && labels instanceof Map) {
                            svc.updateLabels((Map<String, Object>) labels);
                        }
                        result.success(null);
                        break;
                    }
                    case "setLocked": {
                        Boolean locked = call.argument("locked");
                        FloatingLyricService svc = FloatingLyricService.getInstance();
                        if (svc != null) {
                            svc.setLocked(locked != null && locked);
                        }
                        result.success(null);
                        break;
                    }
                    case "setPlaybackState": {
                        Boolean playing = call.argument("playing");
                        FloatingLyricService svc = FloatingLyricService.getInstance();
                        if (svc != null) {
                            svc.setPlaybackState(playing != null && playing);
                        }
                        result.success(null);
                        break;
                    }
                    case "isShowing": {
                        result.success(FloatingLyricService.getInstance() != null);
                        break;
                    }
                    case "canDrawOverlays": {
                        result.success(Settings.canDrawOverlays(context));
                        break;
                    }
                    default:
                        result.notImplemented();
                }
            });

        floatingDictChannel = new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(), FLOATING_DICT_CHANNEL);
        floatingDictChannel.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "show": {
                    if (!Settings.canDrawOverlays(context)) {
                        Intent intent = new Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:" + getPackageName()));
                        startActivity(intent);
                        result.success(false);
                        return;
                    }
                    Intent svc = new Intent(context, FloatingDictService.class);
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(svc);
                    } else {
                        startService(svc);
                    }
                    result.success(true);
                    break;
                }
                case "hide": {
                    stopService(new Intent(context, FloatingDictService.class));
                    result.success(true);
                    break;
                }
                case "isShowing": {
                    result.success(FloatingDictService.getInstance() != null);
                    break;
                }
                case "canDrawOverlays": {
                    result.success(Settings.canDrawOverlays(context));
                    break;
                }
                case "openAccessibilitySettings": {
                    Intent accIntent = new Intent(
                            android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS);
                    accIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    startActivity(accIntent);
                    result.success(null);
                    break;
                }
                case "isAccessibilityEnabled": {
                    result.success(isAccessibilityServiceEnabled(context,
                            DictAccessibilityService.class));
                    break;
                }
                default:
                    result.notImplemented();
            }
        });

        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), FONTS_CHANNEL)
            .setMethodCallHandler((call, result) -> {
                if ("listSystemFonts".equals(call.method)) {
                    ioExecutor.execute(() -> {
                        TreeSet<String> families = new TreeSet<>(String.CASE_INSENSITIVE_ORDER);
                        // 1) 解析 /system/etc/fonts.xml
                        try {
                            File xml = new File("/system/etc/fonts.xml");
                            if (xml.exists()) {
                                try (BufferedReader reader = new BufferedReader(
                                        new InputStreamReader(new FileInputStream(xml)))) {
                                    StringBuilder sb = new StringBuilder();
                                    String line;
                                    while ((line = reader.readLine()) != null) {
                                        sb.append(line);
                                    }
                                    Pattern p = Pattern.compile("<family\\s+name=\"([^\"]+)\"");
                                    Matcher m = p.matcher(sb.toString());
                                    while (m.find()) {
                                        families.add(m.group(1));
                                    }
                                }
                            }
                        } catch (Exception e) {
                            android.util.Log.w("hibiki-fonts", "Failed to parse fonts.xml", e);
                        }
                        // 2) 扫描 /system/fonts/ 目录
                        try {
                            File dir = new File("/system/fonts");
                            if (dir.exists() && dir.isDirectory()) {
                                File[] files = dir.listFiles();
                                if (files != null) {
                                    for (File f : files) {
                                        String name = f.getName();
                                        if (name.endsWith(".ttf") || name.endsWith(".otf") || name.endsWith(".ttc")) {
                                            String base = name.replaceAll("\\.(ttf|otf|ttc)$", "");
                                            base = base.replaceAll("-(Regular|Bold|Italic|BoldItalic|Light|Medium|Thin|Black|SemiBold|ExtraBold|ExtraLight)$", "");
                                            families.add(base);
                                        }
                                    }
                                }
                            }
                        } catch (Exception e) {
                            android.util.Log.w("hibiki-fonts", "Failed to scan /system/fonts", e);
                        }
                        List<String> sorted = new ArrayList<>(families);
                        android.util.Log.d("hibiki-fonts", "Found " + sorted.size() + " fonts: " + sorted.subList(0, Math.min(5, sorted.size())));
                        new Handler(Looper.getMainLooper()).post(() -> result.success(sorted));
                    });
                } else {
                    result.notImplemented();
                }
            });

        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), LIFECYCLE_CHANNEL)
            .setMethodCallHandler((call, result) -> {
                if ("moveTaskToBack".equals(call.method)) {
                    moveTaskToBack(true);
                    result.success(null);
                } else {
                    result.notImplemented();
                }
            });

        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), ICON_CHANNEL)
            .setMethodCallHandler((call, result) -> {
                switch (call.method) {
                    case "getCurrentIcon":
                        result.success(IconSwitchHelper.getCurrentIcon(this));
                        break;
                    case "switchPresetIcon": {
                        String alias = call.argument("alias");
                        boolean ok = IconSwitchHelper.switchPresetIcon(this, alias);
                        result.success(ok);
                        break;
                    }
                    case "createCustomShortcut": {
                        byte[] imageBytes = call.argument("imageBytes");
                        boolean ok = IconSwitchHelper.createCustomShortcut(this, imageBytes);
                        result.success(ok);
                        break;
                    }
                    case "isCustomShortcutSupported":
                        result.success(IconSwitchHelper.isCustomShortcutSupported(this));
                        break;
                    default:
                        result.notImplemented();
                        break;
                }
            });
    }

    private void copyDocumentTree(DocumentFile srcDir, File destDir) throws Exception {
        for (DocumentFile child : srcDir.listFiles()) {
            String name = child.getName();
            if (name == null) continue;
            if (child.isDirectory()) {
                File subDir = new File(destDir, name);
                subDir.mkdirs();
                copyDocumentTree(child, subDir);
            } else {
                long size = child.length();
                if (size > 50 * 1024 * 1024) {
                    // Large file: create a symlink-like proxy by opening a
                    // FileDescriptor and hard-linking via /proc/self/fd.
                    try {
                        android.os.ParcelFileDescriptor pfd =
                            getContentResolver().openFileDescriptor(child.getUri(), "r");
                        if (pfd != null) {
                            String fdPath = "/proc/self/fd/" + pfd.getFd();
                            File destFile = new File(destDir, name);
                            // Copy via fd path which bypasses SAF permission issues
                            try (InputStream in = new java.io.FileInputStream(fdPath);
                                 OutputStream out = new FileOutputStream(destFile)) {
                                byte[] buf = new byte[65536];
                                int len;
                                while ((len = in.read(buf)) > 0) {
                                    out.write(buf, 0, len);
                                }
                            }
                            pfd.close();
                        }
                    } catch (Exception e) {
                        // Fallback: copy via ContentResolver stream
                        copyFile(child, new File(destDir, name));
                    }
                } else {
                    copyFile(child, new File(destDir, name));
                }
            }
        }
    }

    private void copyFile(DocumentFile src, File dest) throws Exception {
        try (InputStream in = getContentResolver().openInputStream(src.getUri());
             OutputStream out = new FileOutputStream(dest)) {
            if (in == null) return;
            byte[] buf = new byte[8192];
            int len;
            while ((len = in.read(buf)) > 0) {
                out.write(buf, 0, len);
            }
        }
    }
}
