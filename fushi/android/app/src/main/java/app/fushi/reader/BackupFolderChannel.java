package app.fushi.reader;

import android.app.Activity;
import android.content.ContentResolver;
import android.content.Intent;
import android.content.UriPermission;
import android.database.Cursor;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.provider.DocumentsContract;
import android.provider.DocumentsContract.Document;

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
 * {@code DocumentsContract} / {@code ContentResolver} 做；I/O 在单独线程，结果回主线程。
 *
 * <p>副本布局与本机还原点存储相同：{@code <树根>/<id>/backup.zip} + {@code restore_point.json}，元数据
 * 最后写 = 完整标记。全部按显示名寻址（每次在父目录下按名字找），Dart 不持有文档 id。
 *
 * <p>方法：{@code pick} → {@code {tree, label}} / null（取消）；{@code release({tree})}；
 * {@code check({tree})} → bool（授权还在、树根还查得到）；{@code list({tree})} →
 * {@code [{name, meta}]}（只列有元数据的子目录，meta 是元数据原文）；
 * {@code upload({tree, dir, files:[{name, path}], metaName, metaText})}；
 * {@code download({tree, dir, files:[name], destDir})}；{@code delete({tree, dir})}。
 * 树不可用（授权收回、文件夹被删）→ 错误码 {@code UNAVAILABLE}；其它 I/O 失败 → {@code IO_FAILED}。
 */
final class BackupFolderChannel {
    static final int REQUEST_CODE = 0x4B46;

    /** 元数据最大读取量：正常只有几 KB，防止把一个同名大文件读进内存。 */
    private static final int MAX_META_BYTES = 1 << 20;
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
            final Map<String, Object> out = new HashMap<>();
            out.put("tree", tree.toString());
            out.put("label", displayName(rootDocument(tree)));
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
        boolean granted = false;
        for (UriPermission perm : activity.getContentResolver().getPersistedUriPermissions()) {
            if (perm.getUri().equals(tree) && perm.isReadPermission() && perm.isWritePermission()) {
                granted = true;
                break;
            }
        }
        if (!granted) return false;
        try (Cursor c = activity.getContentResolver().query(
                rootDocument(tree), new String[]{Document.COLUMN_DOCUMENT_ID}, null, null, null)) {
            return c != null && c.moveToFirst();
        } catch (RuntimeException e) {
            return false;
        }
    }

    // ── 副本 ────────────────────────────────────────────────────────────────

    private List<Map<String, Object>> list(Uri tree) throws IOException {
        final List<Map<String, Object>> out = new ArrayList<>();
        for (Child dir : children(tree, rootDocument(tree))) {
            if (!dir.isDirectory()) continue;
            final Child meta = find(children(tree, dir.uri(tree)), "restore_point.json");
            if (meta == null || meta.isDirectory()) continue;
            final String text = readText(meta.uri(tree));
            if (text == null) continue;
            final Map<String, Object> entry = new HashMap<>();
            entry.put("name", dir.name);
            entry.put("meta", text);
            out.add(entry);
        }
        return out;
    }

    private void upload(Uri tree, String dirName, List<Map<String, Object>> files,
            String metaName, String metaText) throws IOException {
        if (dirName == null || files == null || metaName == null || metaText == null) {
            throw new IllegalArgumentException("dir, files, metaName and metaText are required");
        }
        final ContentResolver resolver = activity.getContentResolver();
        final Uri root = rootDocument(tree);
        Child dir = find(children(tree, root), dirName);
        final Uri dirUri;
        if (dir == null) {
            dirUri = DocumentsContract.createDocument(resolver, root, Document.MIME_TYPE_DIR, dirName);
            if (dirUri == null) throw new IOException("could not create " + dirName);
        } else if (dir.isDirectory()) {
            dirUri = dir.uri(tree);
        } else {
            throw new IOException(dirName + " exists and is not a folder");
        }
        // 先删旧元数据：被打断的上一次若已写过元数据，覆盖文件的途中不能看起来「完整」。
        final List<Child> existing = children(tree, dirUri);
        final Child oldMeta = find(existing, metaName);
        if (oldMeta != null) DocumentsContract.deleteDocument(resolver, oldMeta.uri(tree));
        for (Map<String, Object> f : files) {
            final String name = (String) f.get("name");
            final String path = (String) f.get("path");
            if (name == null || path == null) throw new IllegalArgumentException("file name/path");
            final Uri target = createOrTruncate(tree, dirUri, existing, name);
            try (InputStream in = new FileInputStream(path);
                    OutputStream out = resolver.openOutputStream(target, "wt")) {
                if (out == null) throw new IOException("cannot write " + name);
                copy(in, out);
            }
        }
        final Uri meta = createOrTruncate(tree, dirUri, children(tree, dirUri), metaName);
        try (OutputStream out = resolver.openOutputStream(meta, "wt")) {
            if (out == null) throw new IOException("cannot write " + metaName);
            out.write(metaText.getBytes(StandardCharsets.UTF_8));
        }
    }

    private void download(Uri tree, String dirName, List<String> files, String destDir)
            throws IOException {
        if (dirName == null || files == null || destDir == null) {
            throw new IllegalArgumentException("dir, files and destDir are required");
        }
        final Child dir = find(children(tree, rootDocument(tree)), dirName);
        if (dir == null || !dir.isDirectory()) throw new IOException("missing copy " + dirName);
        final List<Child> inside = children(tree, dir.uri(tree));
        for (String name : files) {
            final Child child = find(inside, name);
            if (child == null || child.isDirectory()) throw new IOException("missing file " + name);
            try (InputStream in = activity.getContentResolver().openInputStream(child.uri(tree));
                    OutputStream out = new FileOutputStream(new File(destDir, name))) {
                if (in == null) throw new IOException("cannot read " + name);
                copy(in, out);
            }
        }
    }

    private void delete(Uri tree, String dirName) throws IOException {
        if (dirName == null) throw new IllegalArgumentException("dir is required");
        final Child dir = find(children(tree, rootDocument(tree)), dirName);
        if (dir == null) return;
        if (!DocumentsContract.deleteDocument(activity.getContentResolver(), dir.uri(tree))) {
            throw new IOException("could not delete " + dirName);
        }
    }

    // ── DocumentsContract 小工具 ─────────────────────────────────────────────

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

    private static Uri treeOf(MethodCall call) {
        final String tree = call.argument("tree");
        if (tree == null) throw new IllegalArgumentException("tree is required");
        return Uri.parse(tree);
    }

    private static Uri rootDocument(Uri tree) {
        return DocumentsContract.buildDocumentUriUsingTree(
                tree, DocumentsContract.getTreeDocumentId(tree));
    }

    private List<Child> children(Uri tree, Uri parent) throws IOException {
        final Uri childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                tree, DocumentsContract.getDocumentId(parent));
        final List<Child> out = new ArrayList<>();
        try (Cursor c = activity.getContentResolver().query(childrenUri, new String[]{
                Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
        }, null, null, null)) {
            if (c == null) throw new FileNotFoundException(parent.toString());
            while (c.moveToNext()) {
                out.add(new Child(c.getString(0), c.getString(1), c.getString(2)));
            }
        }
        return out;
    }

    @Nullable
    private static Child find(List<Child> children, String name) {
        for (Child c : children) {
            if (name.equals(c.name)) return c;
        }
        return null;
    }

    private Uri createOrTruncate(Uri tree, Uri dirUri, List<Child> existing, String name)
            throws IOException {
        final Child found = find(existing, name);
        if (found != null) {
            if (found.isDirectory()) throw new IOException(name + " is a folder");
            return found.uri(tree);
        }
        final Uri created = DocumentsContract.createDocument(
                activity.getContentResolver(), dirUri, MIME_BINARY, name);
        if (created == null) throw new IOException("could not create " + name);
        // 提供者改了名字（加了后缀 / 序号）：之后按名字找不到它，宁可现在就失败。
        final String actual = displayName(created);
        if (!name.equals(actual)) {
            DocumentsContract.deleteDocument(activity.getContentResolver(), created);
            throw new IOException("the folder renamed " + name + " to " + actual);
        }
        return created;
    }

    private String displayName(Uri document) {
        try (Cursor c = activity.getContentResolver().query(
                document, new String[]{Document.COLUMN_DISPLAY_NAME}, null, null, null)) {
            if (c != null && c.moveToFirst()) return c.getString(0);
        }
        return document.getLastPathSegment();
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

    private static void copy(InputStream in, OutputStream out) throws IOException {
        final byte[] buf = new byte[1 << 20];
        int n;
        while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
        out.flush();
    }

    // ── 线程 ────────────────────────────────────────────────────────────────

    private interface IoTask {
        Object run() throws Exception;
    }

    private void runIo(MethodChannel.Result result, IoTask task) {
        io.execute(() -> {
            Object value = null;
            String code = null;
            String message = null;
            try {
                value = task.run();
            } catch (SecurityException | FileNotFoundException e) {
                // 授权被收回 / 文件夹被删或改名。
                code = "UNAVAILABLE";
                message = e.getMessage();
            } catch (IllegalArgumentException e) {
                code = "INVALID_ARG";
                message = e.getMessage();
            } catch (Exception e) {
                code = "IO_FAILED";
                message = e.getMessage();
            }
            final Object v = value;
            final String c = code;
            final String m = message;
            main.post(() -> {
                if (c == null) {
                    result.success(v);
                } else {
                    result.error(c, m, null);
                }
            });
        });
    }
}
