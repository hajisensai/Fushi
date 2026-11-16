package app.fushi.reader;

import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.content.UriPermission;
import android.content.pm.PackageManager;
import android.content.pm.PathPermission;
import android.content.pm.PermissionInfo;
import android.content.pm.ProviderInfo;
import android.database.Cursor;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.provider.OpenableColumns;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import app.fushi.reader.constants.ChannelNames;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/**
 * 「用其他应用打开」/「分享到 Fushi」收进来的书 / 漫画文件（拍板台 oeJzVRQ9p1）。
 *
 * <p>manifest 给 {@code MainActivity} 挂了文档 MIME 的 {@code VIEW}（content://）与
 * {@code SEND}（{@code EXTRA_STREAM}）过滤器。对方给的是一个只在本 Activity 存活期间
 * 有读授权的 {@code content://} URI，Dart 读不了它，所以这里在收到 intent 的当下用
 * {@link ContentResolver} 把字节复制进 {@code cacheDir/open_with/<uuid>/}，再把
 * 「缓存路径 + 原文件名 + MIME」交给 Dart（{@code lib/src/media/import/android_open_with.dart}），
 * Dart 走桌面 open-with 同一条 {@code LibraryCtlImporter} 入库 → 打开阅读器的路径。
 *
 * <p><b>一次性消费由原生持有</b>：{@code receive_intent} 会在配置变化重挂 Activity 时
 * 把同一个启动 intent 再发一遍，从最近任务重新进入时 {@code getIntent()} 也还是当初那个
 * VIEW，靠 Dart 侧按 URI 去重会把「用户在 QQ 里又点了一次同一个文件」也吞掉。所以只在
 * {@code onCreate}（非重建）和 {@code onNewIntent} 收一次，复制好的结果放进队列，Dart
 * 用 {@code takeIncomingDocuments} 取走即清空。
 *
 * <p>只收 {@code content://}：Android 7+ 跨应用传 {@code file://} 会被系统拦下，留着它
 * 反而让别的 app 能指使 Fushi 读自己的私有文件。{@code content://} 也只在「Fushi 除了对方的
 * URI grant 外读不到」时才读（自家 provider、Fushi 凭自身特权权限能读的 exported provider 一律
 * 拒），见 {@link OpenWithUriPolicy}（BUG-4752）。
 */
public final class OpenWithChannel {
    private static final String METHOD_TAKE = "takeIncomingDocuments";
    private static final String METHOD_AVAILABLE = "incomingDocumentsAvailable";
    private static final String CACHE_DIR = "open_with";
    private static final String COPY_NAME = "incoming";

    private static final ExecutorService EXECUTOR = Executors.newSingleThreadExecutor();
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final List<Map<String, Object>> READY = new ArrayList<>();
    private static boolean sweptStaleCopies;
    @Nullable private static MethodChannel channel;

    private OpenWithChannel() {
    }

    public static void registerWith(@NonNull FlutterEngine engine, @NonNull Context context) {
        final Context app = context.getApplicationContext();
        final MethodChannel ch = new MethodChannel(
                engine.getDartExecutor().getBinaryMessenger(), ChannelNames.OPEN_WITH);
        ch.setMethodCallHandler((call, result) -> {
            if (METHOD_TAKE.equals(call.method)) {
                final List<Map<String, Object>> taken;
                synchronized (READY) {
                    taken = new ArrayList<>(READY);
                    READY.clear();
                }
                result.success(taken);
            } else {
                result.notImplemented();
            }
        });
        channel = ch;
        if (!sweptStaleCopies) {
            sweptStaleCopies = true;
            // 上个进程没来得及导入（被杀、导入失败）留下的副本。单线程执行器保证它排在
            // 本进程任何一次复制之前。
            EXECUTOR.execute(() -> deleteRecursively(new File(app.getCacheDir(), CACHE_DIR)));
        }
    }

    /** {@code configureFlutterEngine} 的引擎被销毁时断开，避免向死引擎发消息。 */
    public static void detach() {
        channel = null;
    }

    /**
     * 收一个 intent：是文档 VIEW / SEND 就异步复制进缓存并通知 Dart，否则什么都不做。
     * 从最近任务重新进入（{@link Intent#FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY}）的旧 intent 不收。
     */
    public static void offer(@NonNull Context context, @Nullable Intent intent) {
        if (intent == null) return;
        if ((intent.getFlags() & Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return;
        final Uri uri = documentUri(intent);
        if (uri == null) return;
        final Context app = context.getApplicationContext();
        final String intentType = intent.getType();
        EXECUTOR.execute(() -> {
            // 访问判定要查 PackageManager / ContentResolver（binder），放后台线程。
            if (!mayReadOnBehalfOfSender(app, uri)) return;
            final Map<String, Object> copied = copyToCache(app, uri, intentType);
            if (copied == null) return;
            synchronized (READY) {
                READY.add(copied);
            }
            MAIN.post(() -> {
                final MethodChannel ch = channel;
                if (ch != null) ch.invokeMethod(METHOD_AVAILABLE, null);
            });
        });
    }

    @Nullable
    private static Uri documentUri(@NonNull Intent intent) {
        final String action = intent.getAction();
        final Uri uri;
        if (Intent.ACTION_VIEW.equals(action)) {
            uri = intent.getData();
        } else if (Intent.ACTION_SEND.equals(action)) {
            uri = streamExtra(intent);
        } else {
            return null;
        }
        if (uri == null || !ContentResolver.SCHEME_CONTENT.equals(uri.getScheme())) return null;
        return uri;
    }

    @SuppressWarnings("deprecation")
    @Nullable
    private static Uri streamExtra(@NonNull Intent intent) {
        try {
            final Object stream = intent.getParcelableExtra(Intent.EXTRA_STREAM);
            return stream instanceof Uri ? (Uri) stream : null;
        } catch (RuntimeException e) {
            // 发送方塞了反序列化不了的 extra（BadParcelableException 等）。
            return null;
        }
    }

    /**
     * 能否替发起方读这个 URI：只在 Fushi 除了对方的 URI grant 外读不到它时才读，防止
     * confused deputy（BUG-4752）。判据与威胁模型见 {@link OpenWithUriPolicy}，这里只取事实。
     */
    private static boolean mayReadOnBehalfOfSender(@NonNull Context app, @NonNull Uri uri) {
        final OpenWithUriPolicy.Verdict verdict;
        try {
            verdict = OpenWithUriPolicy.decide(
                    app.getPackageName(),
                    OpenWithUriPolicy.bareAuthority(uri.getAuthority()),
                    providerFacts(app, uri),
                    selfHasPersistedGrant(app, uri),
                    permission -> selfHoldsPrivileged(app, permission));
        } catch (RuntimeException e) {
            // PackageManager / ContentResolver 查询本身出错：判不了就不读。
            android.util.Log.w("fushi-open-with", "access check failed, refusing " + uri + ": " + e);
            return false;
        }
        if (verdict == OpenWithUriPolicy.Verdict.ALLOW) return true;
        android.util.Log.w("fushi-open-with", "refused " + uri + ": " + verdict);
        return false;
    }

    @Nullable
    private static OpenWithUriPolicy.ProviderFacts providerFacts(
            @NonNull Context app, @NonNull Uri uri) {
        final String bare = OpenWithUriPolicy.bareAuthority(uri.getAuthority());
        if (bare == null) return null;
        final ProviderInfo info = app.getPackageManager().resolveContentProvider(bare, 0);
        if (info == null) return null;
        final List<String> pathReadPermissions = new ArrayList<>();
        final String path = uri.getPath();
        if (info.pathPermissions != null && path != null) {
            for (PathPermission pp : info.pathPermissions) {
                if (pp != null && pp.getReadPermission() != null && pp.match(path)) {
                    pathReadPermissions.add(pp.getReadPermission());
                }
            }
        }
        return new OpenWithUriPolicy.ProviderFacts(
                info.packageName, info.exported, info.readPermission, pathReadPermissions);
    }

    private static boolean selfHasPersistedGrant(@NonNull Context app, @NonNull Uri uri) {
        final String target = uri.toString();
        for (UriPermission granted : app.getContentResolver().getPersistedUriPermissions()) {
            if (granted.isReadPermission()
                    && OpenWithUriPolicy.grantCovers(granted.getUri().toString(), target)) {
                return true;
            }
        }
        return false;
    }

    /** Fushi 持有该权限且它不是 normal 级；查不到定义的权限按特权处理（宁拒勿放）。 */
    @SuppressWarnings("deprecation")
    private static boolean selfHoldsPrivileged(@NonNull Context app, @NonNull String permission) {
        if (app.checkPermission(permission, Process.myPid(), Process.myUid())
                != PackageManager.PERMISSION_GRANTED) {
            return false;
        }
        try {
            final PermissionInfo info = app.getPackageManager().getPermissionInfo(permission, 0);
            return (info.protectionLevel & PermissionInfo.PROTECTION_MASK_BASE)
                    != PermissionInfo.PROTECTION_NORMAL;
        } catch (PackageManager.NameNotFoundException e) {
            return true;
        }
    }

    @Nullable
    private static Map<String, Object> copyToCache(
            @NonNull Context app, @NonNull Uri uri, @Nullable String intentType) {
        final ContentResolver resolver = app.getContentResolver();
        final File dir = new File(new File(app.getCacheDir(), CACHE_DIR), UUID.randomUUID().toString());
        final File dest = new File(dir, COPY_NAME);
        try {
            if (!dir.mkdirs()) return null;
            try (InputStream in = resolver.openInputStream(uri);
                 OutputStream out = new FileOutputStream(dest)) {
                if (in == null) {
                    deleteRecursively(dir);
                    return null;
                }
                final byte[] buf = new byte[64 * 1024];
                int len;
                while ((len = in.read(buf)) > 0) {
                    out.write(buf, 0, len);
                }
            }
        } catch (Exception e) {
            android.util.Log.w("fushi-open-with", "copy failed: " + e);
            deleteRecursively(dir);
            return null;
        }
        String mime = null;
        try {
            mime = resolver.getType(uri);
        } catch (RuntimeException ignored) {
            // 部分 provider 不实现 getType：退回 intent 上声明的类型。
        }
        if (mime == null) mime = intentType;
        final Map<String, Object> out = new HashMap<>();
        out.put("path", dest.getAbsolutePath());
        out.put("displayName", displayName(resolver, uri));
        out.put("mimeType", mime);
        return out;
    }

    @Nullable
    private static String displayName(@NonNull ContentResolver resolver, @NonNull Uri uri) {
        try (Cursor cursor = resolver.query(
                uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                final int idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (idx >= 0) {
                    final String name = cursor.getString(idx);
                    if (name != null && !name.isEmpty()) return name;
                }
            }
        } catch (RuntimeException ignored) {
            // provider 不支持 OpenableColumns：退回 URI 最后一段。
        }
        return uri.getLastPathSegment();
    }

    private static void deleteRecursively(@NonNull File file) {
        final File[] children = file.listFiles();
        if (children != null) {
            for (File child : children) deleteRecursively(child);
        }
        //noinspection ResultOfMethodCallIgnored
        file.delete();
    }
}
