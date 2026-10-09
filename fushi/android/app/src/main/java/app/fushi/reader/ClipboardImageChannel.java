package app.fushi.reader;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.ContentResolver;
import android.content.Context;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;
import androidx.core.content.FileProvider;

import app.fushi.reader.constants.ChannelNames;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/**
 * 复制图片到系统剪贴板：{@code app.fushi.reader/clipboard_image} 的 Android 实现。
 *
 * <p>这条通道最早只有 Windows 一端（{@code windows/runner/flutter_window.cpp} 的
 * {@code CopyImageFileToClipboard}，WIC 解码 → 32bpp BGRA → {@code CF_DIB}），服务
 * 阅读器内联图与插画查看器的「复制图片」。视频截图要把它铺到五端，这里补 Android。
 * <b>方法名与入参逐字对齐 Windows</b>：{@code copyImageFile} + {@code {"path": ...}}。
 *
 * <p>Android 的剪贴板放不下位图本身，只能放一个 {@code content://} URI 引用，于是
 * 这里必须经 {@link FushiFileProvider}（manifest 里 authority
 * {@code ${applicationId}.provider}，{@code grantUriPermissions="true"}）。两条由此
 * 而来的约束，写代码时容易漏：
 *
 * <ul>
 *   <li>{@link ClipData#newUri} 必须用 {@link android.content.ContentResolver} 那个重载
 *       （而不是 {@code newPlainText}）——它会去 resolver 问 MIME 类型并写进
 *       {@code ClipDescription}，接收方据此才知道剪贴板里是张图而不是一段文本。</li>
 *   <li>文件必须落在 {@code provider_paths.xml} 覆盖到的目录下（cache / files /
 *       external-*）。Dart 侧 {@code clipboard_image.dart} 写的是
 *       {@code getTemporaryDirectory()}，即 cacheDir，已被 {@code cache-path} 覆盖。</li>
 * </ul>
 *
 * <p>粘贴方能否真的读到这张图，取决于系统给剪贴板 URI 的临时授权；这一条只有真机
 * 粘进第三方 app 才算验过，自己 {@code getPrimaryClip} 读回来不算。
 */
public final class ClipboardImageChannel {
    private static final String METHOD_COPY_IMAGE_FILE = "copyImageFile";
    private static final String METHOD_READ_IMAGE = "readImage";
    /** 粘贴的单张图读取上限：再大就不是截图了，也不该整个读进内存。 */
    private static final int MAX_READ_BYTES = 64 * 1024 * 1024;
    private static final String ARG_PATH = "path";
    private static final String CLIP_LABEL = "Fushi image";

    private ClipboardImageChannel() {
    }

    public static void registerWith(@NonNull FlutterEngine flutterEngine,
                                    @NonNull Context context) {
        final Context appContext = context.getApplicationContext();
        new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(),
                ChannelNames.CLIPBOARD_IMAGE)
            .setMethodCallHandler((call, result) -> {
                if (METHOD_READ_IMAGE.equals(call.method)) {
                    handleReadImage(appContext, result);
                    return;
                }
                if (!METHOD_COPY_IMAGE_FILE.equals(call.method)) {
                    result.notImplemented();
                    return;
                }
                handleCopyImageFile(appContext, call.argument(ARG_PATH), result);
            });
    }

    /**
     * 反馈提交页「粘贴截图」：剪贴板里第一条 {@code image/*} 的 {@code content://} 条目，
     * 读出原始字节（压缩 / 缩小由 Dart 侧按反馈上限处理）。没有图片回 null。
     *
     * <p>{@code getPrimaryClip} 在主线程取（Android 10 起只有拿着焦点的前台 app 能读，
     * 用户点按钮 / 长按菜单时正是如此）；读流放后台线程，结果回主线程交给 Flutter。
     */
    private static void handleReadImage(@NonNull Context context,
                                        @NonNull MethodChannel.Result result) {
        final ClipboardManager clipboard =
                (ClipboardManager) context.getSystemService(Context.CLIPBOARD_SERVICE);
        if (clipboard == null) {
            result.error("CLIPBOARD_FAILED", "ClipboardManager is unavailable", null);
            return;
        }
        final ClipData clip = clipboard.getPrimaryClip();
        if (clip == null) {
            result.success(null);
            return;
        }
        final ContentResolver resolver = context.getContentResolver();
        Uri imageUri = null;
        for (int i = 0; i < clip.getItemCount(); i++) {
            final Uri uri = clip.getItemAt(i).getUri();
            if (uri == null) continue;
            final String type = resolver.getType(uri);
            if (type != null && type.startsWith("image/")) {
                imageUri = uri;
                break;
            }
        }
        if (imageUri == null) {
            result.success(null);
            return;
        }
        final Uri target = imageUri;
        final Handler main = new Handler(Looper.getMainLooper());
        new Thread(() -> {
            try (InputStream in = resolver.openInputStream(target)) {
                if (in == null) {
                    main.post(() -> result.success(null));
                    return;
                }
                final ByteArrayOutputStream out = new ByteArrayOutputStream();
                final byte[] buffer = new byte[64 * 1024];
                int read;
                while ((read = in.read(buffer)) != -1) {
                    if (out.size() + read > MAX_READ_BYTES) {
                        main.post(() -> result.error("READ_FAILED",
                                "Clipboard image is too large", null));
                        return;
                    }
                    out.write(buffer, 0, read);
                }
                final Map<String, Object> map = new HashMap<>();
                map.put("bytes", out.toByteArray());
                main.post(() -> result.success(map));
            } catch (IOException | SecurityException e) {
                final String message = String.valueOf(e.getMessage());
                main.post(() -> result.error("READ_FAILED", message, null));
            }
        }, "fushi-clipboard-read").start();
    }

    private static void handleCopyImageFile(@NonNull Context context,
                                            String path,
                                            @NonNull MethodChannel.Result result) {
        if (path == null || path.isEmpty()) {
            result.error("INVALID_ARGUMENTS",
                    "copyImageFile requires a non-empty 'path'", null);
            return;
        }
        final File file = new File(path);
        if (!file.exists()) {
            result.error("READ_FAILED", "Image file not found: " + path, null);
            return;
        }
        try {
            final Uri uri = FileProvider.getUriForFile(
                    context, context.getPackageName() + ".provider", file);
            final ClipboardManager clipboard =
                    (ClipboardManager) context.getSystemService(Context.CLIPBOARD_SERVICE);
            if (clipboard == null) {
                result.error("CLIPBOARD_FAILED",
                        "ClipboardManager is unavailable", null);
                return;
            }
            clipboard.setPrimaryClip(
                    ClipData.newUri(context.getContentResolver(), CLIP_LABEL, uri));
            result.success(null);
        } catch (IllegalArgumentException e) {
            // getUriForFile 对 provider_paths.xml 没覆盖到的目录抛这个。报出来而不是
            // 吞掉：静默失败会让用户以为复制成功了，粘贴时才发现是空的。
            result.error("READ_FAILED",
                    "Path is outside the FileProvider roots: " + path, null);
        } catch (Exception e) {
            result.error("CLIPBOARD_FAILED", String.valueOf(e.getMessage()), null);
        }
    }
}
