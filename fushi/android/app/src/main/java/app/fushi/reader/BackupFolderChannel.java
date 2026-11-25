package app.fushi.reader;

import android.app.Activity;
import android.content.ContentResolver;
import android.content.Intent;
import android.content.UriPermission;
import android.database.Cursor;
import android.net.ConnectivityManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.DocumentsContract;
import android.provider.DocumentsContract.Document;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.atomic.AtomicBoolean;

import app.fushi.reader.constants.ChannelNames;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * 自动备份的用户文件夹（docs/specs/2026-11-25-auto-backup-restore-points.md 第三期；Dart 门面
 * {@code sync/auto_backup/backup_folder_platform.dart}）。
 *
 * <p>用户在系统选择器里挑一个文件夹（{@code ACTION_OPEN_DOCUMENT_TREE}），这里
 * {@code takePersistableUriPermission} 记住读写授权，之后每次备份都能往里写，不借全文件访问。SAF
 * 文件夹没有 {@code dart:io} 能用的路径，所以副本的列、写、读、删全在这里经
 * {@code DocumentsContract} / {@code ContentResolver} 做；I/O 在单独线程，结果回主线程，且每次调用
 * 恰好回 Dart 一次（含 {@code Error}），Dart 侧的锁不会因为这边线程死掉而永远挂住。
 *
 * <p>副本布局与本机还原点存储相同：{@code <树根>/<id>/backup.zip} + {@code restore_point.json}，元数据
 * 最后写 = 完整标记。全部按显示名寻址（每次在父目录下按名字找），Dart 不持有文档 id。
 *
 * <p>方法：{@code pick} → {@code {tree, label}} / null（取消）；{@code release({tree})}；
 * {@code check({tree})} → bool（授权还在、树根还查得到）；{@code list({tree})} →
 * {@code [{name, meta}]}（只列有元数据的子目录，meta 是元数据原文；单个读不了的子目录跳过）；
 * {@code upload({tree, dir, files:[{name, path}], metaName, metaText})}；
 * {@code download({tree, dir, files:[name], destDir})}；{@code delete({tree, dir})}；
 * {@code networkUnmetered} → bool（有活动网络且不计流量）。
 *
 * <p>错误码（Dart 按原字符串映射，别改）：
 * <ul>
 *   <li>{@code UNAVAILABLE}：树本身不能用——持久授权没了 / 被收回（含途中的 SecurityException），
 *       树根查不到（文件夹被删、改名、存储被卸载）。</li>
 *   <li>{@code NOT_FOUND}：文件夹里的副本目录或其中的文件不存在（下载缺失的副本 / 文件）。</li>
 *   <li>{@code LOCAL_IO}：本机一侧失败——上传的本机源文件不存在 / 读不了，下载的本机目标写不了。</li>
 *   <li>{@code UNSUPPORTED}：提供者拒绝操作（不支持 "wt" 覆盖写且删了重建也不行、不支持新建）。</li>
 *   <li>{@code RENAMED}：提供者把新建的文件 / 目录改了名（多半是同名已存在、被加了 " (1)"）。</li>
 *   <li>{@code LOADING}：云端提供者还在加载目录内容，稍后再试（不拿半截列表去做决定）。</li>
 *   <li>{@code INVALID_ARG}：参数缺失或名字非法（空、"."、".."、含 '/' 或 '\'）。</li>
 *   <li>{@code IO_FAILED}：其它 I/O 失败（含删旧元数据失败）。</li>
 *   <li>{@code INTERNAL}：其它意外（含 Error）。</li>
 * </ul>
 * {@code pick} 另有 {@code BUSY} / {@code NO_PICKER} / {@code PERMISSION_FAILED}。
 */
final class BackupFolderChannel {
    static final int REQUEST_CODE = 0x4B46;

    private static final String TAG = "BackupFolderChannel";

    static final String UNAVAILABLE = "UNAVAILABLE";
    static final String NOT_FOUND = "NOT_FOUND";
    static final String LOCAL_IO = "LOCAL_IO";
    static final String UNSUPPORTED = "UNSUPPORTED";
    static final String RENAMED = "RENAMED";
    static final String LOADING = "LOADING";
    static final String INVALID_ARG = "INVALID_ARG";
    static final String IO_FAILED = "IO_FAILED";
    static final String INTERNAL = "INTERNAL";

    /** 元数据最大读取量：正常只有几 KB，防止把一个同名大文件读进内存。 */
    private static final int MAX_META_BYTES = 1 << 20;
    /** 云端提供者 EXTRA_LOADING 时重查的次数与间隔（在 I/O 线程上睡，合计约 3 秒）。 */
    private static final int LOADING_RETRIES = 10;
    private static final long LOADING_RETRY_MS = 300;
    private static final String MIME_BINARY = "application/octet-stream";
    private static final int RW =
            Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION;

    private static BackupFolderChannel instance;

    private final Activity activity;
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private MethodChannel.Result pendingPick;

    private BackupFolderChannel(Activity activity) {
        this.activity = activity;
    }

    static void registerWith(@NonNull FlutterEngine engine, @NonNull Activity activity) {
        final BackupFolderChannel channel = new BackupFolderChannel(activity);
        instance = channel;
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), ChannelNames.BACKUP_FOLDER)
                .setMethodCallHandler(channel::onMethodCall);
    }

    /** {@link MainActivity#onActivityResult} 转来；是本通道的请求时返回 true。 */
    static boolean onActivityResult(int requestCode, int resultCode, @Nullable Intent data) {
        final BackupFolderChannel channel = instance;
        if (requestCode != REQUEST_CODE || channel == null) return false;
        channel.finishPick(resultCode == Activity.RESULT_OK && data != null ? data.getData() : null);
        return true;
    }

    private void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "pick":
                pick(result);
                return;
            case "release":
                runIo(result, () -> {
                    release(treeOf(call));
                    return null;
                });
                return;
            case "check":
                runIo(result, () -> check(treeOf(call)));
                return;
            case "list":
                runIo(result, () -> list(treeOf(call)));
                return;
            case "upload":
                runIo(result, () -> {
                    upload(treeOf(call), call.argument("dir"), call.argument("files"),
                            call.argument("metaName"), call.argument("metaText"));
                    return null;
                });
                return;
            case "download":
                runIo(result, () -> {
                    download(treeOf(call), call.argument("dir"), call.argument("files"),
                            call.argument("destDir"));
                    return null;
                });
                return;
            case "delete":
                runIo(result, () -> {
                    delete(treeOf(call), call.argument("dir"));
                    return null;
                });
                return;
            case "networkUnmetered":
                runIo(result, this::networkUnmetered);
                return;
            default:
                result.notImplemented();
        }
    }

    // ── 选择与授权 ──────────────────────────────────────────────────────────

    private void pick(MethodChannel.Result result) {
        if (pendingPick != null) {
            result.error("BUSY", "A folder pick is already in progress", null);
            return;
        }
        final Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
        intent.addFlags(RW
                | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);
        pendingPick = result;
        try {
            activity.startActivityForResult(intent, REQUEST_CODE);
        } catch (RuntimeException e) {
            // 没有 DocumentsUI：复位，别让通道一直 BUSY。
            pendingPick = null;
            result.error("NO_PICKER", e.getMessage(), null);
        }
    }

    private void finishPick(@Nullable Uri tree) {
        final MethodChannel.Result result = pendingPick;
        pendingPick = null;
        if (result == null) return;
        if (tree == null) {
            result.success(null);
            return;
        }
        try {
            activity.getContentResolver().takePersistableUriPermission(tree, RW);
        } catch (SecurityException e) {
            result.error("PERMISSION_FAILED", e.getMessage(), null);
            return;
        }
        runIo(result, () -> {
            final Uri root = requireRoot(tree);
            final String label = queryDisplayName(root);
            final Map<String, Object> out = new HashMap<>();
            out.put("tree", tree.toString());
            out.put("label", label != null ? label : root.getLastPathSegment());
            return out;
        });
    }

    private void release(Uri tree) {
        try {
            activity.getContentResolver().releasePersistableUriPermission(tree, RW);
        } catch (SecurityException ignored) {
            // 授权早就没了：本来就是要放掉它。
        }
    }

    private boolean check(Uri tree) {
        return rootProblem(tree) == null;
    }

    /** 树不可用的原因（授权没了 / 树根查不到）；可用时返回 null。 */
    @Nullable
    private String rootProblem(Uri tree) {
        boolean granted = false;
        for (UriPermission perm : activity.getContentResolver().getPersistedUriPermissions()) {
            if (perm.getUri().equals(tree) && perm.isReadPermission() && perm.isWritePermission()) {
                granted = true;
                break;
            }
        }
        if (!granted) return "no persisted read/write grant for the folder";
        try (Cursor c = activity.getContentResolver().query(
                rootDocument(tree), new String[]{Document.COLUMN_DOCUMENT_ID}, null, null, null)) {
            if (c == null || !c.moveToFirst()) return "the folder no longer exists";
            return null;
        } catch (RuntimeException e) {
            // SecurityException（授权已失效）、提供者的 IllegalArgumentException（文档 id 不存在）等。
            return "the folder is unreachable: " + e;
        }
    }

    /** 每个操作开头先确认授权与树根还在，不在就 UNAVAILABLE；返回树根文档。 */
    private Uri requireRoot(Uri tree) throws ChannelException {
        final String problem = rootProblem(tree);
        if (problem != null) throw new ChannelException(UNAVAILABLE, problem);
        return rootDocument(tree);
    }

    // ── 网络 ────────────────────────────────────────────────────────────────

    /** 有活动网络且不计流量时 true；计流量或没网时 false。 */
    private Boolean networkUnmetered() {
        final ConnectivityManager cm = activity.getSystemService(ConnectivityManager.class);
        if (cm == null || cm.getActiveNetwork() == null) return false;
        return !cm.isActiveNetworkMetered();
    }

    // ── 副本 ────────────────────────────────────────────────────────────────

    private List<Map<String, Object>> list(Uri tree) throws IOException {
        final Uri root = requireRoot(tree);
        final List<Map<String, Object>> out = new ArrayList<>();
        // 树根这一层失败照常抛（UNAVAILABLE / LOADING）。
        for (Child dir : children(tree, root, UNAVAILABLE)) {
            if (!dir.isDirectory()) continue;
            try {
                final Child meta = find(children(tree, dir.uri(tree), IO_FAILED), "restore_point.json");
                if (meta == null || meta.isDirectory()) continue;
                final String text = readText(meta.uri(tree));
                if (text == null) continue;
                final Map<String, Object> entry = new HashMap<>();
                entry.put("name", dir.name);
                entry.put("meta", text);
                out.add(entry);
            } catch (ChannelException e) {
                // 子目录还在加载：漏列一个副本比报错更糟（会被当成没有），整体稍后重试。
                if (LOADING.equals(e.code)) throw e;
                Log.w(TAG, "skip unreadable copy " + dir.name, e);
            } catch (IOException | RuntimeException e) {
                // 单个副本读不了不拖垮整份列表。
                Log.w(TAG, "skip unreadable copy " + dir.name, e);
            }
        }
        return out;
    }

    private void upload(Uri tree, String dirName, List<?> files, String metaName, String metaText)
            throws IOException {
        requireName(dirName, "dir");
        requireName(metaName, "metaName");
        if (files == null || metaText == null) {
            throw new ChannelException(INVALID_ARG, "files and metaText are required");
        }
        // 先把参数全验完，别写到一半才发现后面的名字不合法。
        final List<String[]> sources = new ArrayList<>();
        for (Object item : files) {
            if (!(item instanceof Map)) throw new ChannelException(INVALID_ARG, "file entry");
            final Object name = ((Map<?, ?>) item).get("name");
            final Object path = ((Map<?, ?>) item).get("path");
            if (!(name instanceof String) || !(path instanceof String) || ((String) path).isEmpty()) {
                throw new ChannelException(INVALID_ARG, "file name/path");
            }
            requireName((String) name, "file name");
            if (name.equals(metaName)) {
                throw new ChannelException(INVALID_ARG, "file name equals metaName: " + name);
            }
            sources.add(new String[]{(String) name, (String) path});
        }

        final ContentResolver resolver = activity.getContentResolver();
        final Uri root = requireRoot(tree);
        final Child dir = find(children(tree, root, UNAVAILABLE), dirName);
        final Uri dirUri;
        if (dir == null) {
            // 同名目录其实已存在但没列出来时，提供者会建成 "<名> (1)"：createChecked 判 RENAMED 并删掉它。
            dirUri = createChecked(root, Document.MIME_TYPE_DIR, dirName);
        } else if (dir.isDirectory()) {
            dirUri = dir.uri(tree);
        } else {
            throw new ChannelException(IO_FAILED, dirName + " exists and is not a folder");
        }
        // 先删旧元数据：被打断的上一次若已写过元数据，覆盖文件的途中不能看起来「完整」。
        final List<Child> existing = children(tree, dirUri, IO_FAILED);
        final Child oldMeta = find(existing, metaName);
        if (oldMeta != null) {
            if (oldMeta.isDirectory()) {
                throw new ChannelException(IO_FAILED, metaName + " is a folder");
            }
            if (!DocumentsContract.deleteDocument(resolver, oldMeta.uri(tree))) {
                throw new ChannelException(IO_FAILED, "could not remove the old " + metaName);
            }
        }
        for (String[] source : sources) {
            final String name = source[0];
            final InputStream in;
            try {
                in = new FileInputStream(source[1]);
            } catch (FileNotFoundException e) {
                throw new ChannelException(LOCAL_IO, "cannot read local " + source[1], e);
            }
            try (InputStream input = in;
                    OutputStream out = openForOverwrite(tree, dirUri, existing, name)) {
                copy(input, out, LOCAL_IO, IO_FAILED);
            }
        }
        try (OutputStream out =
                openForOverwrite(tree, dirUri, children(tree, dirUri, IO_FAILED), metaName)) {
            out.write(metaText.getBytes(StandardCharsets.UTF_8));
            out.flush();
        }
    }

    private void download(Uri tree, String dirName, List<?> files, String destDir)
            throws IOException {
        requireName(dirName, "dir");
        if (files == null || destDir == null || destDir.isEmpty()) {
            throw new ChannelException(INVALID_ARG, "files and destDir are required");
        }
        final List<String> names = new ArrayList<>();
        for (Object item : files) {
            if (!(item instanceof String)) throw new ChannelException(INVALID_ARG, "file name");
            requireName((String) item, "file name");
            names.add((String) item);
        }
        final Uri root = requireRoot(tree);
        final Child dir = find(children(tree, root, UNAVAILABLE), dirName);
        if (dir == null || !dir.isDirectory()) {
            throw new ChannelException(NOT_FOUND, "missing copy " + dirName);
        }
        final List<Child> inside = children(tree, dir.uri(tree), NOT_FOUND);
        for (String name : names) {
            final Child child = find(inside, name);
            if (child == null || child.isDirectory()) {
                throw new ChannelException(NOT_FOUND, "missing file " + name);
            }
            final InputStream in;
            try {
                in = activity.getContentResolver().openInputStream(child.uri(tree));
            } catch (FileNotFoundException e) {
                throw new ChannelException(NOT_FOUND, "missing file " + name, e);
            }
            if (in == null) throw new ChannelException(IO_FAILED, "cannot read " + name);
            try (InputStream input = in) {
                final OutputStream local;
                try {
                    local = new FileOutputStream(new File(destDir, name));
                } catch (FileNotFoundException e) {
                    throw new ChannelException(LOCAL_IO, "cannot write local " + name, e);
                }
                try (OutputStream out = local) {
                    copy(input, out, IO_FAILED, LOCAL_IO);
                } catch (ChannelException e) {
                    throw e;
                } catch (IOException e) {
                    // 只剩本机文件 close 会走到这里。
                    throw new ChannelException(LOCAL_IO, "cannot write local " + name, e);
                }
            }
        }
    }

    private void delete(Uri tree, String dirName) throws IOException {
        requireName(dirName, "dir");
        final Uri root = requireRoot(tree);
        final Child dir = find(children(tree, root, UNAVAILABLE), dirName);
        if (dir == null) return;
        if (!DocumentsContract.deleteDocument(activity.getContentResolver(), dir.uri(tree))) {
            throw new ChannelException(IO_FAILED, "could not delete " + dirName);
        }
    }

    // ── DocumentsContract 小工具 ─────────────────────────────────────────────

    /** 带错误码的 I/O 失败；runIo 原样把 code 交给 Dart。 */
    private static final class ChannelException extends IOException {
        final String code;

        ChannelException(String code, String message) {
            super(message);
            this.code = code;
        }

        ChannelException(String code, String message, Throwable cause) {
            super(message, cause);
            this.code = code;
        }
    }

    private static final class Child {
        final String documentId;
        final String name;
        final String mime;

        Child(String documentId, String name, String mime) {
            this.documentId = documentId;
            this.name = name;
            this.mime = mime;
        }

        boolean isDirectory() {
            return Document.MIME_TYPE_DIR.equals(mime);
        }

        Uri uri(Uri tree) {
            return DocumentsContract.buildDocumentUriUsingTree(tree, documentId);
        }
    }

    private static Uri treeOf(MethodCall call) throws ChannelException {
        final String tree = call.argument("tree");
        if (tree == null || tree.isEmpty()) throw new ChannelException(INVALID_ARG, "tree is required");
        final Uri uri = Uri.parse(tree);
        try {
            DocumentsContract.getTreeDocumentId(uri);
        } catch (IllegalArgumentException e) {
            throw new ChannelException(INVALID_ARG, "not a document tree: " + tree, e);
        }
        return uri;
    }

    /** 名字只能是单层：不空、不是 "." / ".."、不含路径分隔符。 */
    private static void requireName(@Nullable String name, String what) throws ChannelException {
        if (name == null || name.isEmpty() || name.equals(".") || name.equals("..")
                || name.indexOf('/') >= 0 || name.indexOf('\\') >= 0 || name.indexOf('\0') >= 0) {
            throw new ChannelException(INVALID_ARG, "invalid " + what + ": " + name);
        }
    }

    private static Uri rootDocument(Uri tree) {
        return DocumentsContract.buildDocumentUriUsingTree(
                tree, DocumentsContract.getTreeDocumentId(tree));
    }

    /**
     * 列 {@code parent} 的子文档。查不到（游标为 null / 提供者抛错）按 {@code missingCode} 失败；
     * 云端提供者带 {@code EXTRA_LOADING} 时有限次重查，仍在加载就 LOADING——半截列表会让 upload
     * 重复建目录、让 list 漏掉副本。
     */
    private List<Child> children(Uri tree, Uri parent, String missingCode) throws IOException {
        final Uri childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                tree, DocumentsContract.getDocumentId(parent));
        for (int attempt = 0; ; attempt++) {
            final List<Child> out = new ArrayList<>();
            final boolean loading;
            try (Cursor c = activity.getContentResolver().query(childrenUri, new String[]{
                    Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
            }, null, null, null)) {
                if (c == null) throw new ChannelException(missingCode, "cannot list " + parent);
                final Bundle extras = c.getExtras();
                loading = extras != null && extras.getBoolean(DocumentsContract.EXTRA_LOADING, false);
                if (!loading) {
                    while (c.moveToNext()) {
                        out.add(new Child(c.getString(0), c.getString(1), c.getString(2)));
                    }
                }
            } catch (SecurityException e) {
                throw e;
            } catch (IllegalArgumentException | IllegalStateException
                    | UnsupportedOperationException e) {
                throw new ChannelException(missingCode, "cannot list " + parent, e);
            }
            if (!loading) return out;
            if (attempt >= LOADING_RETRIES) {
                throw new ChannelException(LOADING, "the folder is still loading, try later");
            }
            try {
                Thread.sleep(LOADING_RETRY_MS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new ChannelException(LOADING, "interrupted while the folder was loading", e);
            }
        }
    }

    @Nullable
    private static Child find(List<Child> children, String name) {
        for (Child c : children) {
            if (name.equals(c.name)) return c;
        }
        return null;
    }

    /**
     * 新建文档并核对提供者给的实际显示名；被改名（同名已存在时常见的 " (1)"）就删掉新建的那个、
     * RENAMED——之后按名字找不到它，宁可现在就失败。
     */
    private Uri createChecked(Uri parent, String mime, String name) throws IOException {
        final ContentResolver resolver = activity.getContentResolver();
        final Uri created;
        try {
            created = DocumentsContract.createDocument(resolver, parent, mime, name);
        } catch (IllegalArgumentException | UnsupportedOperationException e) {
            throw new ChannelException(UNSUPPORTED, "the folder refuses to create " + name, e);
        }
        if (created == null) throw new ChannelException(IO_FAILED, "could not create " + name);
        final String actual = queryDisplayName(created);
        if (!name.equals(actual)) {
            deleteBestEffort(created, "renamed " + name);
            if (actual == null) {
                throw new ChannelException(IO_FAILED, "cannot read back the name of " + name);
            }
            throw new ChannelException(RENAMED, "the folder renamed " + name + " to " + actual);
        }
        return created;
    }

    /**
     * 打开 {@code name} 准备从头覆盖写（不存在就新建）。首选 "wt"；提供者不认 "wt" 时：新建的空文件
     * 直接用 "w"；已有文件不用 "w"（有的提供者 "w" 不截断，旧内容尾巴会留在后面），改为删了重建再
     * "w"。全都不行 → UNSUPPORTED。
     */
    private OutputStream openForOverwrite(Uri tree, Uri dirUri, List<Child> existing, String name)
            throws IOException {
        final ContentResolver resolver = activity.getContentResolver();
        final Child found = find(existing, name);
        if (found != null && found.isDirectory()) {
            throw new ChannelException(IO_FAILED, name + " is a folder");
        }
        Uri target = found != null ? found.uri(tree) : createChecked(dirUri, MIME_BINARY, name);
        try {
            final OutputStream out = resolver.openOutputStream(target, "wt");
            if (out == null) throw new ChannelException(IO_FAILED, "cannot write " + name);
            return out;
        } catch (FileNotFoundException | IllegalArgumentException | UnsupportedOperationException e) {
            Log.w(TAG, "provider refused mode wt for " + name + ", falling back", e);
        }
        try {
            if (found != null) {
                if (!DocumentsContract.deleteDocument(resolver, target)) {
                    throw new ChannelException(UNSUPPORTED, "cannot replace " + name);
                }
                target = createChecked(dirUri, MIME_BINARY, name);
            }
            final OutputStream out = resolver.openOutputStream(target, "w");
            if (out == null) throw new ChannelException(UNSUPPORTED, "cannot write " + name);
            return out;
        } catch (FileNotFoundException | IllegalArgumentException | UnsupportedOperationException e) {
            if (found == null) deleteBestEffort(target, "unwritable " + name);
            throw new ChannelException(UNSUPPORTED, "the folder refuses to overwrite " + name, e);
        }
    }

    /** 收尾删除：失败不打断主错误，但记日志，不悄悄吞掉。 */
    private void deleteBestEffort(Uri document, String what) {
        try {
            if (!DocumentsContract.deleteDocument(activity.getContentResolver(), document)) {
                Log.w(TAG, "could not delete " + what + " (" + document + ")");
            }
        } catch (IOException | RuntimeException e) {
            Log.w(TAG, "could not delete " + what + " (" + document + ")", e);
        }
    }

    @Nullable
    private String queryDisplayName(Uri document) {
        try (Cursor c = activity.getContentResolver().query(
                document, new String[]{Document.COLUMN_DISPLAY_NAME}, null, null, null)) {
            if (c != null && c.moveToFirst()) return c.getString(0);
        } catch (SecurityException e) {
            throw e;
        } catch (RuntimeException e) {
            Log.w(TAG, "cannot read the name of " + document, e);
        }
        return null;
    }

    @Nullable
    private String readText(Uri document) throws IOException {
        try (InputStream in = activity.getContentResolver().openInputStream(document)) {
            if (in == null) return null;
            final ByteArrayOutputStream buf = new ByteArrayOutputStream();
            final byte[] chunk = new byte[8192];
            int n;
            while ((n = in.read(chunk)) != -1) {
                buf.write(chunk, 0, n);
                if (buf.size() > MAX_META_BYTES) return null;
            }
            return new String(buf.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    /** 拷贝；读、写两侧各自的 IOException 分别记成 {@code readCode} / {@code writeCode}。 */
    private static void copy(InputStream in, OutputStream out, String readCode, String writeCode)
            throws ChannelException {
        final byte[] buf = new byte[1 << 20];
        while (true) {
            final int n;
            try {
                n = in.read(buf);
            } catch (IOException e) {
                throw new ChannelException(readCode, "read failed: " + e.getMessage(), e);
            }
            if (n == -1) break;
            try {
                out.write(buf, 0, n);
            } catch (IOException e) {
                throw new ChannelException(writeCode, "write failed: " + e.getMessage(), e);
            }
        }
        try {
            out.flush();
        } catch (IOException e) {
            throw new ChannelException(writeCode, "write failed: " + e.getMessage(), e);
        }
    }

    // ── 线程 ────────────────────────────────────────────────────────────────

    private interface IoTask {
        Object run() throws Exception;
    }

    /**
     * 在 I/O 线程跑 {@code task}，结果回主线程，保证恰好回 Dart 一次：任何 Throwable（含 OOM、
     * StackOverflowError）都变成错误码，不让线程死掉、Dart 的 future 永远不完成。
     */
    private void runIo(MethodChannel.Result result, IoTask task) {
        final AtomicBoolean replied = new AtomicBoolean(false);
        try {
            io.execute(() -> {
                Object value = null;
                String code = null;
                String message = null;
                try {
                    value = task.run();
                } catch (ChannelException e) {
                    code = e.code;
                    message = e.getMessage();
                } catch (SecurityException e) {
                    // 途中授权被收回。
                    code = UNAVAILABLE;
                    message = e.toString();
                } catch (IOException e) {
                    code = IO_FAILED;
                    message = e.toString();
                } catch (Throwable t) {
                    code = INTERNAL;
                    message = t.toString();
                    Log.e(TAG, "unexpected failure", t);
                }
                postReply(result, replied, value, code, message);
            });
        } catch (RejectedExecutionException e) {
            reply(result, replied, null, INTERNAL, "I/O executor rejected the task: " + e);
        }
    }

    private void postReply(MethodChannel.Result result, AtomicBoolean replied, Object value,
            String code, String message) {
        try {
            if (!main.post(() -> reply(result, replied, value, code, message))) {
                Log.e(TAG, "main looper gone, reply dropped");
            }
        } catch (Throwable t) {
            Log.e(TAG, "could not post reply", t);
        }
    }

    /** 主线程上回复；success 编码失败时改回 INTERNAL，最多回一次。 */
    private static void reply(MethodChannel.Result result, AtomicBoolean replied, Object value,
            @Nullable String code, @Nullable String message) {
        if (!replied.compareAndSet(false, true)) return;
        try {
            if (code == null) {
                result.success(value);
            } else {
                result.error(code, message, null);
            }
        } catch (Throwable t) {
            Log.e(TAG, "reply failed", t);
            if (code != null) return;
            try {
                result.error(INTERNAL, "reply failed: " + t, null);
            } catch (Throwable t2) {
                Log.e(TAG, "error reply failed", t2);
            }
        }
    }
}
