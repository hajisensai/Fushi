// Derived from the AnkiDroid API Sample

package app.hibiki.reader;

import android.app.Activity;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.media.AudioManager;
import android.view.KeyEvent;
import android.view.WindowManager;
import androidx.annotation.NonNull;
import android.net.Uri;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

import android.provider.Settings;
import android.content.SharedPreferences;
import android.graphics.drawable.ColorDrawable;
import androidx.core.content.FileProvider;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import app.hibiki.reader.constants.ChannelNames;
import app.hibiki.reader.constants.FloatingColors;
import app.hibiki.reader.constants.PreferenceKeys;

import androidx.documentfile.provider.DocumentFile;

import com.ryanheise.audioservice.AudioServiceActivity;
import android.content.Context;
import android.content.res.Configuration;

public class MainActivity extends AudioServiceActivity {
    private static final String VOLUME_KEY_CHANNEL = ChannelNames.VOLUME_KEYS;
    private static final String SAF_CHANNEL = ChannelNames.SAF;
    private static final String UPDATE_CHANNEL = ChannelNames.UPDATE;
    private static final String FONTS_CHANNEL = ChannelNames.FONTS;
    private static final String FLOATING_LYRIC_CHANNEL = ChannelNames.FLOATING_LYRIC;
    private static final String FLOATING_DICT_CHANNEL = ChannelNames.FLOATING_DICT;
    private static final String SPLASH_CHANNEL = ChannelNames.SPLASH;
    private static final String LIFECYCLE_CHANNEL = ChannelNames.LIFECYCLE;
    private static final String ICON_CHANNEL = ChannelNames.ICON_SWITCH;
    private static final String SCREEN_BRIGHTNESS_CHANNEL = ChannelNames.SCREEN_BRIGHTNESS;
    private static final String SPLASH_PREFS = PreferenceKeys.FILE_SPLASH;
    private static final int SAF_PICK_DIR_REQUEST = 1001;
    // BUG-427/TODO-852: install-permission gate result code. Distinct from
    // SAF_PICK_DIR_REQUEST so onActivityResult can tell the two flows apart.
    private static final int INSTALL_PERMISSION_REQUEST = 1002;
    private static MethodChannel floatingLyricChannel;
    private static MethodChannel floatingDictChannel;

    private Activity context;
    private AnkiChannelHandler ankiChannelHandler;
    private TtsChannelHandler ttsChannelHandler;
    private MethodChannel.Result pendingSafResult;
    private String pendingSafDestPath;
    // BUG-427/TODO-852: when API 26+ has no install permission we route the
    // user to the system "install unknown apps" setting with
    // startActivityForResult and stash the in-flight MethodChannel.Result +
    // the already-validated cache-dir APK path here, so onActivityResult /
    // onResume can resume the install once permission is granted instead of
    // tearing the download session down and forcing a re-download.
    private MethodChannel.Result pendingInstallResult;
    private String pendingInstallApkPath;
    private final ExecutorService ioExecutor = Executors.newFixedThreadPool(2);

    // Reader opens this gate when volume-key page turning is enabled so
    // dispatchKeyEvent swallows VOLUME_UP/DOWN and forwards them to Dart.
    private volatile boolean volumeKeyIntercept = false;
    private MethodChannel volumeKeyChannel;

    @Override
    protected void attachBaseContext(Context newBase) {
        SharedPreferences prefs = newBase.getSharedPreferences(SPLASH_PREFS, MODE_PRIVATE);
        if (prefs.contains(PreferenceKeys.SPLASH_IS_DARK)) {
            boolean isDark = prefs.getBoolean(PreferenceKeys.SPLASH_IS_DARK, false);
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
        int bgColor = splashPrefs.getInt(PreferenceKeys.SPLASH_BG_COLOR, 0);
        if (bgColor != 0) {
            getWindow().setBackgroundDrawable(new ColorDrawable(bgColor));
        }
        context = MainActivity.this;
        ankiChannelHandler = new AnkiChannelHandler(context);
        ttsChannelHandler = new TtsChannelHandler(context);

        super.onCreate(savedInstanceState);

        disableSystemFocusHighlight();
    }

    // BUG-195: On API 26+ every View defaults to defaultFocusHighlightEnabled=true,
    // so when touch mode is exited the framework draws a system focus rectangle on
    // the currently focused View -- including the FlutterView host that hosts the
    // whole UI. On some skins (Samsung OneUI 6.5) that system frame overlaps Hibiki's
    // own keyboard/gamepad focus ring drawn in Flutter (see hibiki_focus_ring.dart),
    // giving a double highlight. We disable only the Android system default highlight
    // here; the Flutter self-drawn focus ring and focus navigation are untouched.
    // Done in code on the decorView (rather than only a theme attribute) because the
    // FlutterSurfaceView host is created programmatically inside super.onCreate, so a
    // direct setDefaultFocusHighlightEnabled(false) on the window's view hierarchy is
    // the deterministic place to kill it.
    private void disableSystemFocusHighlight() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.view.View decorView = getWindow().getDecorView();
            if (decorView != null) {
                decorView.setDefaultFocusHighlightEnabled(false);
            }
        }
    }

    @Override
    protected void onDestroy() {
        if (ttsChannelHandler != null) {
            ttsChannelHandler.destroy();
        }
        // HBK-AUDIT-057: the static floating-service channels are bound to this
        // engine's messenger; clear their handlers and null them so stale
        // notify*() calls after teardown become safe no-ops instead of
        // targeting a dead FlutterEngine.
        if (floatingLyricChannel != null) {
            floatingLyricChannel.setMethodCallHandler(null);
            floatingLyricChannel = null;
        }
        if (floatingDictChannel != null) {
            floatingDictChannel.setMethodCallHandler(null);
            floatingDictChannel = null;
        }
        ioExecutor.shutdownNow();
        super.onDestroy();
    }

    // HBK-AUDIT-057: capture the static channel into a final local before
    // posting; the posted lambda must not re-read the field, which onDestroy
    // may null in between (TOCTOU NPE). invokeMethod on a detached channel is a
    // benign no-op.
    public static void notifyFloatingLyricEvent(String method, Map<String, Object> arguments) {
        final MethodChannel ch = floatingLyricChannel;
        if (ch == null) return;
        new Handler(Looper.getMainLooper()).post(() -> ch.invokeMethod(method, arguments));
    }

    public static void notifyFloatingDictEvent(String method, Object arguments) {
        final MethodChannel ch = floatingDictChannel;
        if (ch == null) return;
        new Handler(Looper.getMainLooper()).post(() -> ch.invokeMethod(method, arguments));
    }

    public static void notifyFloatingDictAnki(String word, String reading, String meaning) {
        final MethodChannel ch = floatingDictChannel;
        if (ch == null) return;
        java.util.HashMap<String, Object> args = new java.util.HashMap<>();
        args.put("word", word);
        args.put("reading", reading);
        args.put("meaning", meaning);
        new Handler(Looper.getMainLooper()).post(() -> ch.invokeMethod("ankiExport", args));
    }

    // TODO-112 / BUG-196: volume keys must NEVER reach the FlutterView key
    // pipeline. super.dispatchKeyEvent() forwards the event to the view hierarchy
    // (including FlutterView) BEFORE Activity.onKeyDown adjusts the volume, so the
    // raw VOLUME_UP/DOWN leaked into Flutter and flipped FocusManager's highlight
    // mode to "traditional" -> a stray focus ring appeared on the reading content
    // even when volume-key page turning was OFF and the user only ever touched the
    // screen. We intercept volume keys here for BOTH states and never call super
    // for them:
    //   * intercept ON  (page turning): forward the key-down to Dart, swallow it
    //     (no volume change), exactly as before.
    //   * intercept OFF (default): adjust the system volume ourselves with
    //     adjustSuggestedStreamVolume(USE_DEFAULT_STREAM_TYPE, FLAG_SHOW_UI) — the
    //     standard "behave like the hardware volume key" API (picks the active
    //     stream, shows the volume slider) — so the buttons still work normally,
    //     but the event no longer pollutes Flutter's focus highlight mode.
    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        int code = event.getKeyCode();
        if (code == KeyEvent.KEYCODE_VOLUME_UP || code == KeyEvent.KEYCODE_VOLUME_DOWN) {
            if (event.getAction() != KeyEvent.ACTION_DOWN) {
                // Consume the UP edge too so it never reaches FlutterView either;
                // the DOWN edge already did the work below.
                return true;
            }
            if (volumeKeyIntercept) {
                if (volumeKeyChannel != null) {
                    final String method = code == KeyEvent.KEYCODE_VOLUME_UP
                            ? "onVolumeUp"
                            : "onVolumeDown";
                    new Handler(Looper.getMainLooper()).post(() -> {
                        volumeKeyChannel.invokeMethod(method, null);
                    });
                }
                return true;
            }
            adjustSystemVolume(code == KeyEvent.KEYCODE_VOLUME_UP);
            return true;
        }
        return super.dispatchKeyEvent(event);
    }

    // Mirror the OS hardware-volume-key behaviour without routing the key through
    // FlutterView. USE_DEFAULT_STREAM_TYPE lets the framework pick the active
    // audio stream (music while playing, ring otherwise) and FLAG_SHOW_UI shows
    // the standard volume slider, so the user sees no difference from the default.
    private void adjustSystemVolume(boolean raise) {
        AudioManager audioManager =
                (AudioManager) getSystemService(Context.AUDIO_SERVICE);
        if (audioManager == null) return;
        int direction = raise
                ? AudioManager.ADJUST_RAISE
                : AudioManager.ADJUST_LOWER;
        audioManager.adjustSuggestedStreamVolume(
                direction,
                AudioManager.USE_DEFAULT_STREAM_TYPE,
                AudioManager.FLAG_SHOW_UI);
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
            return;
        }
        if (requestCode == INSTALL_PERMISSION_REQUEST) {
            // BUG-427/TODO-852: returning from the "install unknown apps"
            // setting. resultCode is usually RESULT_CANCELED here (the settings
            // page does not setResult), so we re-check canRequestPackageInstalls
            // rather than trust resultCode. On success we resume the install
            // with the stashed, already-cache-dir-validated APK path — the
            // updater never re-downloads (HBK-AUDIT-058).
            resumePendingInstall();
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        // BUG-427/TODO-852: belt-and-braces for OEMs whose settings page does
        // not deliver onActivityResult after the permission grant. If a pending
        // install is still parked and the permission is now granted, resume it
        // here. resumePendingInstall is a no-op when nothing is parked, and only
        // proceeds when canRequestPackageInstalls is true, so a benign onResume
        // (e.g. permission still off) leaves the pending result intact for the
        // user to grant later — it never double-fires the MethodChannel.Result.
        if (pendingInstallResult != null
                && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                && context.getPackageManager().canRequestPackageInstalls()) {
            resumePendingInstall();
        }
    }

    // BUG-427/TODO-852: finalize a parked install-permission request exactly
    // once. Clears the stashed fields up front so it can never re-enter, then
    // decides the single terminal outcome for the in-flight Result:
    //   * permission still not granted -> INSTALL_PERMISSION_REQUIRED (Dart
    //     keeps the apk and offers a manual retry);
    //   * stashed path lost -> INSTALL_ERROR;
    //   * otherwise resume the install with the already-validated cache-dir apk.
    private void resumePendingInstall() {
        final MethodChannel.Result installResult = pendingInstallResult;
        final String apkPath = pendingInstallApkPath;
        pendingInstallResult = null;
        pendingInstallApkPath = null;
        if (installResult == null) return;
        boolean granted = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                && context.getPackageManager().canRequestPackageInstalls();
        if (!granted) {
            installResult.error("INSTALL_PERMISSION_REQUIRED",
                "Enable installing unknown apps for Hibiki, then retry", null);
            return;
        }
        if (apkPath == null || apkPath.isEmpty()) {
            installResult.error("INSTALL_ERROR",
                "Pending install APK path was lost", null);
            return;
        }
        launchApkInstaller(new File(apkPath), installResult);
    }

    // BUG-427/TODO-852: the actual FileProvider + ACTION_VIEW install launch,
    // shared by the permission-already-granted path and the resume path so the
    // intent construction lives in exactly one place (no copy drift). Reports
    // the terminal outcome on the supplied Result.
    private void launchApkInstaller(File apkFile, MethodChannel.Result result) {
        try {
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
                        // Only one SAF picker can be pending at a time because
                        // startActivityForResult uses a single request code.
                        // Reject concurrent requests to avoid silently dropping
                        // the previous caller's result.
                        if (pendingSafResult != null) {
                            result.error("BUSY",
                                "A SAF directory pick is already in progress", null);
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
                    // BUG-427/TODO-852: a previous install is still parked
                    // waiting on the permission grant. Finalize it first so a
                    // stuck/abandoned pending result can never permanently lock
                    // out the install feature (its Result is resolved here, the
                    // fields cleared, before we start the new request).
                    if (pendingInstallResult != null) {
                        resumePendingInstall();
                    }
                    try {
                        File apkFile = new File(path);
                        // HBK-AUDIT-058: only install an APK that lives in our
                        // own cache dir (the updater downloads there); never
                        // trust an arbitrary caller-supplied path. And ensure we
                        // may request installs, routing the user to the system
                        // setting otherwise instead of silently failing.
                        String apkCanon = apkFile.getCanonicalPath();
                        String cacheCanon = context.getCacheDir().getCanonicalPath();
                        if (!apkCanon.startsWith(cacheCanon + File.separator)) {
                            result.error("INVALID_PATH",
                                "APK is not in the app cache directory", null);
                            return;
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                                && !context.getPackageManager()
                                        .canRequestPackageInstalls()) {
                            // BUG-427/TODO-852: route to the setting with
                            // startActivityForResult (NOT startActivity, and NOT
                            // FLAG_ACTIVITY_NEW_TASK — a new task detaches the
                            // result callback so onActivityResult never fires).
                            // Launch the setting first; only stash the in-flight
                            // Result + already-validated cache-dir path AFTER the
                            // launch succeeds, then return immediately. This keeps
                            // the return path isolated from the catch below: if
                            // startActivityForResult throws, nothing is parked and
                            // the catch resolves the Result once with INSTALL_ERROR
                            // — the same Result is never resolved twice. The parked
                            // Result is resolved later by resumePendingInstall().
                            Intent settings = new Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:" + context.getPackageName()));
                            startActivityForResult(
                                settings, INSTALL_PERMISSION_REQUEST);
                            pendingInstallResult = result;
                            pendingInstallApkPath = apkCanon;
                            return;
                        }
                        launchApkInstaller(apkFile, result);
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
                        Object rawArgs = call.arguments;
                        if (!(rawArgs instanceof Map)) {
                            result.error("INVALID_ARG",
                                "setSplashColor requires a Map argument", null);
                            break;
                        }
                        Map<?, ?> args = (Map<?, ?>) rawArgs;
                        Object colorObj = args.get("color");
                        Object isDarkObj = args.get("isDark");
                        if (!(colorObj instanceof Number) || !(isDarkObj instanceof Boolean)) {
                            result.error("INVALID_ARG",
                                "color (Number) and isDark (Boolean) are required", null);
                            break;
                        }
                        int color = ((Number) colorObj).intValue();
                        boolean isDark = (Boolean) isDarkObj;
                        prefs.edit()
                             .putInt(PreferenceKeys.SPLASH_BG_COLOR, color)
                             .putBoolean(PreferenceKeys.SPLASH_IS_DARK, isDark)
                             .apply();
                        getWindow().setBackgroundDrawable(new ColorDrawable(color));
                        result.success(null);
                        break;
                    }
                    case "getSplashColor": {
                        int color = prefs.getInt(PreferenceKeys.SPLASH_BG_COLOR, 0);
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
                        persistFloatingLyricOptions(call.arguments);
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
                        // BUG-400/TODO-711: persist the line unconditionally so a
                        // service that has not yet finished onCreate (startForegroundService
                        // returns before onCreate; Dart pushes the current cue right after
                        // show) still renders the current line on its first frame via
                        // readInitialState — instead of dropping it and showing blank
                        // until the next cue. Mirrors persistFloatingLyricOptions.
                        persistFloatingLyricText(text);
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
                        persistFloatingLyricOptions(call.arguments);
                        if (svc != null) {
                            svc.updateStyle(
                                    size != null ? size.floatValue() : 16f,
                                    color != null ? color.intValue() : FloatingColors.LYRIC_TEXT,
                                    bg != null ? bg.intValue() : FloatingColors.LYRIC_BACKGROUND,
                                    buttonTextColor != null ? buttonTextColor.intValue() : FloatingColors.LYRIC_BUTTON_TEXT,
                                    buttonBgColor != null ? buttonBgColor.intValue() : FloatingColors.LYRIC_BUTTON_BG,
                                    highlightColor != null ? highlightColor.intValue() : FloatingColors.LYRIC_HIGHLIGHT,
                                    activeColor != null ? activeColor.intValue() : FloatingColors.LYRIC_ACTIVE);
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
                        persistFloatingLyricLocked(locked != null && locked);
                        FloatingLyricService svc = FloatingLyricService.getInstance();
                        if (svc != null) {
                            svc.setLocked(locked != null && locked);
                        }
                        result.success(null);
                        break;
                    }
                    case "setClickLookupEnabled": {
                        Boolean enabled = call.argument("enabled");
                        boolean value = enabled == null || enabled;
                        persistFloatingLyricClickLookup(value);
                        FloatingLyricService svc = FloatingLyricService.getInstance();
                        if (svc != null) {
                            svc.setClickLookupEnabled(value);
                        }
                        result.success(null);
                        break;
                    }
                    case "setPlaybackState": {
                        Boolean playing = call.argument("playing");
                        // BUG-400/TODO-711: replay playback state on startup too, so the
                        // play/pause icon is correct on the overlay's first frame.
                        persistFloatingLyricPlaying(playing != null && playing);
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
                case "setClipboardMonitoring": {
                    Object enabledObj = call.arguments;
                    boolean enabled = enabledObj instanceof Boolean && (Boolean) enabledObj;
                    FloatingDictService svc = FloatingDictService.getInstance();
                    if (svc != null) {
                        svc.setClipboardMonitoring(enabled);
                    }
                    result.success(null);
                    break;
                }
                case "setSearchText": {
                    Object textObj = call.arguments;
                    FloatingDictService svc = FloatingDictService.getInstance();
                    if (svc != null && textObj instanceof String) {
                        svc.setSearchText(((String) textObj).trim());
                    }
                    result.success(null);
                    break;
                }
                case "searchResult": {
                    Object jsonObj = call.arguments;
                    String json = jsonObj instanceof String ? (String) jsonObj : null;
                    FloatingDictService svc = FloatingDictService.getInstance();
                    if (svc != null) {
                        svc.onSearchResult(json);
                    }
                    result.success(null);
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

        // TODO-057: window-level screen brightness for the video player's
        // left-half vertical drag. We set THIS WINDOW's brightness override
        // (WindowManager.LayoutParams.screenBrightness in 0..1); it never
        // touches the system Settings value and is dropped automatically when
        // the window goes away. restoreBrightness sets it back to
        // BRIGHTNESS_OVERRIDE_NONE (-1) so the display follows the system again.
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(),
                SCREEN_BRIGHTNESS_CHANNEL)
            .setMethodCallHandler((call, result) -> {
                switch (call.method) {
                    case "getBrightness": {
                        runOnUiThread(() -> {
                            float b = getWindow().getAttributes().screenBrightness;
                            if (b < 0f) {
                                // No override set yet: report the current system
                                // brightness (0..255 -> 0..1) so the drag starts
                                // from what the user actually sees.
                                try {
                                    int sys = Settings.System.getInt(
                                            getContentResolver(),
                                            Settings.System.SCREEN_BRIGHTNESS, 128);
                                    b = sys / 255f;
                                } catch (Exception e) {
                                    b = 0.5f;
                                }
                            }
                            result.success((double) b);
                        });
                        break;
                    }
                    case "setBrightness": {
                        final Object arg = call.arguments;
                        if (!(arg instanceof Number)) {
                            result.error("INVALID_ARG",
                                "setBrightness requires a number 0..1", null);
                            break;
                        }
                        final float value = Math.max(0f,
                                Math.min(1f, ((Number) arg).floatValue()));
                        runOnUiThread(() -> {
                            WindowManager.LayoutParams lp = getWindow().getAttributes();
                            lp.screenBrightness = value;
                            getWindow().setAttributes(lp);
                            result.success(null);
                        });
                        break;
                    }
                    case "restoreBrightness": {
                        runOnUiThread(() -> {
                            WindowManager.LayoutParams lp = getWindow().getAttributes();
                            lp.screenBrightness =
                                    WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE;
                            getWindow().setAttributes(lp);
                            result.success(null);
                        });
                        break;
                    }
                    default:
                        result.notImplemented();
                        break;
                }
            });
    }

    private void persistFloatingLyricOptions(Object rawArgs) {
        if (!(rawArgs instanceof Map)) return;
        Map<?, ?> args = (Map<?, ?>) rawArgs;
        SharedPreferences.Editor editor =
                getSharedPreferences(PreferenceKeys.FILE_FLOATING_LYRIC, MODE_PRIVATE)
                        .edit();
        putFloatIfNumber(editor, PreferenceKeys.LYRIC_FONT_SIZE, args.get("fontSize"));
        putIntIfNumber(editor, PreferenceKeys.LYRIC_TEXT_COLOR, args.get("textColor"));
        putIntIfNumber(editor, PreferenceKeys.LYRIC_BG_COLOR, args.get("bgColor"));
        putIntIfNumber(
                editor, PreferenceKeys.LYRIC_BUTTON_TEXT_COLOR, args.get("buttonTextColor"));
        putIntIfNumber(editor, PreferenceKeys.LYRIC_BUTTON_BG_COLOR, args.get("buttonBgColor"));
        putIntIfNumber(editor, PreferenceKeys.LYRIC_HIGHLIGHT_COLOR, args.get("highlightColor"));
        putIntIfNumber(editor, PreferenceKeys.LYRIC_ACTIVE_COLOR, args.get("activeColor"));
        putBooleanIfBoolean(editor, PreferenceKeys.LYRIC_LOCKED, args.get("locked"));
        putBooleanIfBoolean(
                editor,
                PreferenceKeys.LYRIC_CLICK_LOOKUP_ENABLED,
                args.get("clickLookupEnabled"));
        editor.apply();
    }

    private void persistFloatingLyricLocked(boolean locked) {
        getSharedPreferences(PreferenceKeys.FILE_FLOATING_LYRIC, MODE_PRIVATE)
                .edit()
                .putBoolean(PreferenceKeys.LYRIC_LOCKED, locked)
                .apply();
    }

    private void persistFloatingLyricClickLookup(boolean enabled) {
        getSharedPreferences(PreferenceKeys.FILE_FLOATING_LYRIC, MODE_PRIVATE)
                .edit()
                .putBoolean(PreferenceKeys.LYRIC_CLICK_LOOKUP_ENABLED, enabled)
                .apply();
    }

    private void persistFloatingLyricText(String text) {
        getSharedPreferences(PreferenceKeys.FILE_FLOATING_LYRIC, MODE_PRIVATE)
                .edit()
                .putString(PreferenceKeys.LYRIC_CURRENT_TEXT, text != null ? text : "")
                .apply();
    }

    private void persistFloatingLyricPlaying(boolean playing) {
        getSharedPreferences(PreferenceKeys.FILE_FLOATING_LYRIC, MODE_PRIVATE)
                .edit()
                .putBoolean(PreferenceKeys.LYRIC_PLAYING, playing)
                .apply();
    }

    private static void putFloatIfNumber(
            SharedPreferences.Editor editor, String key, Object value) {
        if (value instanceof Number) {
            editor.putFloat(key, ((Number) value).floatValue());
        }
    }

    private static void putIntIfNumber(
            SharedPreferences.Editor editor, String key, Object value) {
        if (value instanceof Number) {
            editor.putInt(key, ((Number) value).intValue());
        }
    }

    private static void putBooleanIfBoolean(
            SharedPreferences.Editor editor, String key, Object value) {
        if (value instanceof Boolean) {
            editor.putBoolean(key, (Boolean) value);
        }
    }

    private void copyDocumentTree(DocumentFile srcDir, File destDir) throws Exception {
        final String destCanon = destDir.getCanonicalPath();
        for (DocumentFile child : srcDir.listFiles()) {
            String name = child.getName();
            if (name == null) continue;
            // HBK-AUDIT-015: a hostile/odd document name ('../x', 'a/b') could
            // escape destDir (zip-slip). Reject path separators and dot names,
            // and verify the resolved target stays under destDir.
            if (name.contains("/") || name.contains("\\")
                    || name.equals("..") || name.equals(".")) {
                continue;
            }
            File target = new File(destDir, name);
            if (!target.getCanonicalPath().startsWith(destCanon + File.separator)) {
                continue;
            }
            if (child.isDirectory()) {
                target.mkdirs();
                copyDocumentTree(child, target);
            } else {
                // HBK-AUDIT-015: removed the >50MB "/proc/self/fd symlink"
                // special case — it copied the same bytes as the stream path
                // (no hard-link, no SAF bypass) and silently swallowed errors.
                // Always stream via ContentResolver.
                copyFile(child, target);
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
