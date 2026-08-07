// Derived from the AnkiDroid API Sample

package app.fushi.reader;

import android.app.Activity;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.media.AudioManager;
import android.database.Cursor;
import android.provider.DocumentsContract;
import android.provider.MediaStore;
import android.provider.OpenableColumns;
import android.view.KeyEvent;
import android.view.WindowManager;
import androidx.annotation.NonNull;
import android.net.Uri;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.FlutterShellArgs;
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

import app.fushi.reader.constants.ChannelNames;
import app.fushi.reader.constants.FloatingColors;
import app.fushi.reader.constants.PreferenceKeys;

import androidx.documentfile.provider.DocumentFile;

import com.ryanheise.audioservice.AudioServiceActivity;
import android.content.Context;
import android.content.res.Configuration;
import app.fushi.reader.mihon.MihonChannelHandler;

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
    // Native SAF pickers that RESOLVE the picked content URI to a real
    // filesystem path (no copy). Distinct from the copy-based 1001 so
    // onActivityResult routes them to path resolution instead of a tree copy.
    private static final int SAF_PICK_REAL_DIR_REQUEST = 1003;
    private static final int SAF_PICK_REAL_FILE_REQUEST = 1004;
    private static MethodChannel floatingLyricChannel;
    private static MethodChannel floatingDictChannel;

    private Activity context;
    private AnkiChannelHandler ankiChannelHandler;
    private TtsChannelHandler ttsChannelHandler;
    private MihonChannelHandler mihonChannelHandler;
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
        mihonChannelHandler = new MihonChannelHandler(getApplication());

        super.onCreate(savedInstanceState);

        disableSystemFocusHighlight();
        // 阅读器主窗口请求系统最高刷新率（收敛到共享 HighRefreshRate，与查词弹窗
        // PopupDictFlutterActivity / 悬浮窗共用同一实现，见 HighRefreshRate.java）。
        HighRefreshRate.applyToActivity(this);
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

    // BUG-438/TODO-889: a gamepad connect/disconnect is a keyboard/navigation
    // configuration change. This Activity declares both keyboard AND navigation in
    // android:configChanges (the navigation flag is essential: a gamepad is a
    // navigation input device, so without it CONFIG_NAVIGATION changes recreate the
    // Activity instead of calling onConfigurationChanged, re-exposing the system
    // focus frame and a load spinner). With them declared Flutter keeps the Activity
    // alive and onConfigurationChanged fires instead of a recreate; re-apply the
    // system focus-highlight suppression here too, because the framework can reset
    // defaultFocusHighlightEnabled when input config changes.
    @Override
    public void onConfigurationChanged(@NonNull Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        disableSystemFocusHighlight();
    }

    @Override
    protected void onDestroy() {
        if (ttsChannelHandler != null) {
            ttsChannelHandler.destroy();
        }
        if (mihonChannelHandler != null) {
            mihonChannelHandler.destroy();
            mihonChannelHandler = null;
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
        if (requestCode == SAF_PICK_REAL_DIR_REQUEST
                || requestCode == SAF_PICK_REAL_FILE_REQUEST) {
            if (pendingSafResult == null) return;
            final MethodChannel.Result safResult = pendingSafResult;
            pendingSafResult = null;
            if (resultCode != Activity.RESULT_OK || data == null
                    || data.getData() == null) {
                safResult.success(null); // user cancelled
                return;
            }
            final Uri pickedUri = data.getData();
            final boolean isTree = requestCode == SAF_PICK_REAL_DIR_REQUEST;
            ioExecutor.execute(() -> {
                String resolved = resolveSafRealPath(pickedUri, isTree);
                // Files: if no real path (true cloud DocumentsProvider), copy to
                // cache so the pick still works — matches the no-permission
                // file_picker escape hatch (dangles on cache clear, but rare).
                // Folders: no fallback (dart:io cannot read a cloud tree anyway).
                if (resolved == null && !isTree) {
                    resolved = copyUriToCache(pickedUri);
                }
                final String realPath = resolved;
                // null = user picked a folder we cannot map, or a copy failure.
                new Handler(Looper.getMainLooper()).post(() ->
                    safResult.success(realPath));
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
        // BUG-438/TODO-889: re-apply the system focus-highlight suppression on
        // resume. disableSystemFocusHighlight() runs once in onCreate. With
        // navigation now in android:configChanges a gamepad plug/unplug is kept
        // alive (onConfigurationChanged), but onResume is still a belt-and-braces
        // path for skins that re-attach the decorView and reset
        // defaultFocusHighlightEnabled back to true, re-exposing the system focus
        // rectangle over Hibiki own focus ring. Re-applying here (and in
        // onConfigurationChanged) keeps it killed.
        disableSystemFocusHighlight();
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

    // TODO-1232: choose the rendering backend before the Flutter engine is
    // created. A command-line "--enable-impeller=false" takes precedence over the
    // AndroidManifest EnableImpeller default at engine init (see FlutterEngineFlags
    // docs), so appending it here flips the backend for THIS launch only -- no
    // rebuild, no adb. This runs at engine start, before any Dart code, so the
    // resolution below is the AUTHORITATIVE decision; RenderBackendService in Dart
    // only mirrors it for the settings toggle + diagnostics.
    @Override
    public FlutterShellArgs getFlutterShellArgs() {
        FlutterShellArgs args = super.getFlutterShellArgs();
        if (isImpellerDisabledPref()) {
            args.add(FlutterShellArgs.ARG_DISABLE_IMPELLER);
        }
        return args;
    }

    // TODO-1232: the effective "disable Impeller (use Skia)" decision for THIS
    // launch. Android DEFAULTS TO IMPELLER (never-set -> false) so the majority
    // keeps Impeller's smoother rendering / no Skia first-frame shader jank.
    // Impeller silently fails to composite media_kit's external SurfaceProducer
    // video texture on a FEW Android GPUs (e.g. Mali-G76 / Android 11, BUG-597),
    // leaving video black while decode + texture handshake are fully green -- those
    // devices degrade via the discoverable one-tap "switch to Skia + restart" entry
    // in the player settings sheet (writes this pref = true, then restarts), rather
    // than flipping every Android user to Skia. An EXPLICIT user choice overrides
    // this default in either direction (explicit > platform default); only the
    // never-set case falls back to Impeller. Mirrors
    // RenderBackendService.resolveImpellerDisabled(storedPref, isAndroid: true).
    private boolean isImpellerDisabledPref() {
        Boolean raw = getImpellerDisabledRawPref();
        return raw != null ? raw : false;
    }

    // TODO-1232: raw persisted intent as a tri-state -- null when the user has
    // never touched the render-backend switch, else the stored boolean. Kept
    // separate from isImpellerDisabledPref() so the "render" channel can hand Dart
    // the same tri-state (RenderBackendService resolves the platform default),
    // keeping the toggle/diagnostics mirror in lock-step with the engine-start
    // decision above.
    private Boolean getImpellerDisabledRawPref() {
        SharedPreferences prefs =
                getSharedPreferences(PreferenceKeys.FILE_RENDER, MODE_PRIVATE);
        if (!prefs.contains(PreferenceKeys.RENDER_IMPELLER_DISABLED)) {
            return null;
        }
        return prefs.getBoolean(PreferenceKeys.RENDER_IMPELLER_DISABLED, false);
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        FloatingDictService.initEngineGroup(getApplicationContext());
        SelectionActionChannel.registerWith(flutterEngine, this);
        MigrationChannelHandler.registerWith(flutterEngine, getApplicationContext());

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
        mihonChannelHandler.register(flutterEngine);

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
                    case "pickRealDirectory": {
                        // Native SAF folder picker; onActivityResult resolves the
                        // tree URI to a real absolute path (no copy).
                        if (pendingSafResult != null) {
                            result.error("BUSY",
                                "A SAF pick is already in progress", null);
                            return;
                        }
                        pendingSafResult = result;
                        Intent dirIntent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
                        try {
                            startActivityForResult(dirIntent, SAF_PICK_REAL_DIR_REQUEST);
                        } catch (Exception e) {
                            // No DocumentsUI: reset so the channel is not stuck BUSY.
                            pendingSafResult = null;
                            result.error("NO_PICKER", e.getMessage(), null);
                        }
                        break;
                    }
                    case "pickRealFile": {
                        // Native SAF file picker; onActivityResult resolves the
                        // document URI to a real absolute path (no copy).
                        if (pendingSafResult != null) {
                            result.error("BUSY",
                                "A SAF pick is already in progress", null);
                            return;
                        }
                        pendingSafResult = result;
                        Intent fileIntent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
                        fileIntent.addCategory(Intent.CATEGORY_OPENABLE);
                        fileIntent.setType("*/*");
                        try {
                            startActivityForResult(fileIntent, SAF_PICK_REAL_FILE_REQUEST);
                        } catch (Exception e) {
                            // No DocumentsUI: reset so the channel is not stuck BUSY.
                            pendingSafResult = null;
                            result.error("NO_PICKER", e.getMessage(), null);
                        }
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
                        // TODO-708 P4: 多行上下文块内当前行区间。缺字段回退 -1/0 = 无行标记
                        // （N=0 单行或旧 payload），退化为无中间行明暗（never-break userspace）。
                        Number lineStart = call.argument("currentLineStart");
                        Number lineLength = call.argument("currentLineLength");
                        int curStart = lineStart != null ? lineStart.intValue() : -1;
                        int curLen = lineLength != null ? lineLength.intValue() : 0;
                        // BUG-400/TODO-711: persist the line unconditionally so a
                        // service that has not yet finished onCreate (startForegroundService
                        // returns before onCreate; Dart pushes the current cue right after
                        // show) still renders the current line on its first frame via
                        // readInitialState — instead of dropping it and showing blank
                        // until the next cue. Mirrors persistFloatingLyricOptions.
                        persistFloatingLyricText(text, curStart, curLen);
                        FloatingLyricService svc = FloatingLyricService.getInstance();
                        if (svc != null && text != null) {
                            svc.updateLyricText(text, curStart, curLen);
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
                        // TODO-708 P2: 圆角半径 / 窗宽（dp，0=平台默认）。旧 payload 缺字段回退 0。
                        Number cornerRadius = call.argument("cornerRadius");
                        Number windowWidth = call.argument("windowWidth");
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
                                    activeColor != null ? activeColor.intValue() : FloatingColors.LYRIC_ACTIVE,
                                    cornerRadius != null ? cornerRadius.intValue() : 0,
                                    windowWidth != null ? windowWidth.intValue() : 0);
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

        // TODO-1232 A3: render-backend experiment toggle. Dart writes the flag
        // here; MainActivity.getFlutterShellArgs reads it at the NEXT launch to
        // decide whether to disable Impeller (Skia fallback). Persisted to a
        // native prefs file this app owns so it is readable pre-engine.
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(),
                ChannelNames.RENDER)
            .setMethodCallHandler((call, result) -> {
                switch (call.method) {
                    case "isImpellerDisabled":
                        // TODO-1232: return the RAW tri-state (null = never set);
                        // Dart applies the platform default so the toggle and the
                        // engine-start decision (getFlutterShellArgs ->
                        // isImpellerDisabledPref) agree on "unset -> Skia on Android".
                        result.success(getImpellerDisabledRawPref());
                        break;
                    case "setImpellerDisabled": {
                        final Object arg = call.arguments;
                        if (!(arg instanceof Boolean)) {
                            result.error("INVALID_ARG",
                                "setImpellerDisabled requires a boolean", null);
                            break;
                        }
                        getSharedPreferences(PreferenceKeys.FILE_RENDER, MODE_PRIVATE)
                                .edit()
                                .putBoolean(PreferenceKeys.RENDER_IMPELLER_DISABLED,
                                        (Boolean) arg)
                                .apply();
                        result.success(null);
                        break;
                    }
                    default:
                        result.notImplemented();
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
        // TODO-708 P2: 圆角半径 / 窗宽（dp，0=平台默认）。启动服务前落盘，让 readInitialState 首帧即应用。
        putIntIfNumber(editor, PreferenceKeys.LYRIC_CORNER_RADIUS, args.get("cornerRadius"));
        putIntIfNumber(editor, PreferenceKeys.LYRIC_WIDTH, args.get("windowWidth"));
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

    private void persistFloatingLyricText(String text, int currentLineStart, int currentLineLength) {
        getSharedPreferences(PreferenceKeys.FILE_FLOATING_LYRIC, MODE_PRIVATE)
                .edit()
                .putString(PreferenceKeys.LYRIC_CURRENT_TEXT, text != null ? text : "")
                .putInt(PreferenceKeys.LYRIC_CURRENT_LINE_START, currentLineStart)
                .putInt(PreferenceKeys.LYRIC_CURRENT_LINE_LENGTH, currentLineLength)
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

    // Resolve a SAF tree/document content URI to a real filesystem absolute path
    // (no copy). The app holds MANAGE_EXTERNAL_STORAGE, so once we recover the
    // real path dart:io can read it and the whole downstream stays real-path
    // based. Covers the common DocumentsUI entry points so "pick from Recent /
    // Videos / Downloads" does not silently fail:
    //   - externalstorage (逐级浏览设备目录/SD 卡): volumeId:relative
    //   - downloads with a raw: docId: the real path is embedded
    //   - media provider (Recent / 视频集): resolve via MediaStore _data
    //   - generic: best-effort _data column on the picked URI
    // Returns null only for providers with no real path (true cloud); the caller
    // then cancels (folder) or copies to cache (file).
    private String resolveSafRealPath(Uri uri, boolean isTree) {
        try {
            final String authority = uri.getAuthority();
            if ("com.android.externalstorage.documents".equals(authority)) {
                final String docId = isTree
                    ? DocumentsContract.getTreeDocumentId(uri)
                    : DocumentsContract.getDocumentId(uri);
                final String path = externalStorageDocIdToPath(docId);
                if (path != null) return path;
            }
            // A folder pick only ever yields a tree URI; non-externalstorage
            // trees are cloud DocumentsProviders with no readable real path.
            if (isTree) return null;

            if ("com.android.providers.downloads.documents".equals(authority)) {
                final String docId = DocumentsContract.getDocumentId(uri);
                if (docId != null && docId.startsWith("raw:")) {
                    final File raw = new File(docId.substring(4));
                    if (raw.exists()) return raw.getAbsolutePath();
                }
            }
            if ("com.android.providers.media.documents".equals(authority)) {
                final String path = mediaDocIdToPath(DocumentsContract.getDocumentId(uri));
                if (path != null) return path;
            }
            // Best-effort: some providers expose the legacy _data column directly.
            final String data = queryDataColumn(uri, null, null);
            if (data != null && new File(data).exists()) return data;
            return null;
        } catch (Exception e) {
            return null;
        }
    }

    // externalstorage docId "volumeId:relative" -> real absolute path.
    private String externalStorageDocIdToPath(String docId) {
        if (docId == null) return null;
        final int sep = docId.indexOf(':');
        if (sep < 0) return null;
        final String volumeId = docId.substring(0, sep);
        final String relative = docId.substring(sep + 1);
        final String root = resolveVolumeRoot(volumeId);
        if (root == null) return null;
        final File target = relative.isEmpty() ? new File(root) : new File(root, relative);
        return target.exists() ? target.getAbsolutePath() : null;
    }

    // externalstorage volume id -> real mount root. "primary" is internal
    // storage; other ids are physical SD cards under /storage/<id> (used only
    // when present). Both are readable via dart:io under MANAGE_EXTERNAL_STORAGE.
    private String resolveVolumeRoot(String volumeId) {
        if ("primary".equalsIgnoreCase(volumeId) || "home".equalsIgnoreCase(volumeId)) {
            return Environment.getExternalStorageDirectory().getAbsolutePath();
        }
        final File volumeRoot = new File("/storage/" + volumeId);
        return volumeRoot.exists() ? volumeRoot.getAbsolutePath() : null;
    }

    // media provider docId ("video:123" / "image:123" / "audio:123") -> real
    // path via the matching MediaStore collection's _data column.
    private String mediaDocIdToPath(String docId) {
        if (docId == null) return null;
        final int sep = docId.indexOf(':');
        if (sep < 0) return null;
        final String type = docId.substring(0, sep);
        final String id = docId.substring(sep + 1);
        final Uri contentUri;
        if ("video".equals(type)) {
            contentUri = MediaStore.Video.Media.EXTERNAL_CONTENT_URI;
        } else if ("image".equals(type)) {
            contentUri = MediaStore.Images.Media.EXTERNAL_CONTENT_URI;
        } else if ("audio".equals(type)) {
            contentUri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI;
        } else {
            return null;
        }
        final String path = queryDataColumn(contentUri, "_id=?", new String[]{id});
        return (path != null && new File(path).exists()) ? path : null;
    }

    // Read the legacy _data column for a content URI (readable under all-files
    // access). Returns null if the column is absent/empty or the query fails.
    private String queryDataColumn(Uri uri, String selection, String[] args) {
        try (Cursor cursor = getContentResolver()
                .query(uri, new String[]{"_data"}, selection, args, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                final int idx = cursor.getColumnIndex("_data");
                if (idx >= 0) {
                    final String data = cursor.getString(idx);
                    if (data != null && !data.isEmpty()) return data;
                }
            }
        } catch (Exception e) {
            // fall through
        }
        return null;
    }

    // Last-resort copy of a picked file content URI into app cache, returning the
    // cache path. Used only when the URI has no real filesystem path (true cloud
    // DocumentsProvider) — same escape hatch as the no-permission file_picker
    // path (dangles on cache clear, but the pick still works).
    private String copyUriToCache(Uri uri) {
        try {
            String name = queryDisplayName(uri);
            if (name == null || name.isEmpty()) {
                name = "saf_pick_" + SystemClock.uptimeMillis();
            }
            final File cacheDir = new File(getCacheDir(), "saf_pick");
            cacheDir.mkdirs();
            final File dest = new File(cacheDir, name);
            try (InputStream in = getContentResolver().openInputStream(uri);
                 OutputStream out = new FileOutputStream(dest)) {
                if (in == null) return null;
                byte[] buf = new byte[8192];
                int len;
                while ((len = in.read(buf)) > 0) {
                    out.write(buf, 0, len);
                }
            }
            return dest.getAbsolutePath();
        } catch (Exception e) {
            return null;
        }
    }

    // Display name for a content URI (falls back to null when unavailable).
    private String queryDisplayName(Uri uri) {
        try (Cursor cursor = getContentResolver().query(
                uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                final int idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (idx >= 0) return cursor.getString(idx);
            }
        } catch (Exception e) {
            // fall through
        }
        return null;
    }
}
