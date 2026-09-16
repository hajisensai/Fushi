package app.fushi.reader;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.net.Uri;

import androidx.annotation.NonNull;
import androidx.core.content.FileProvider;

import app.fushi.reader.constants.ChannelNames;

import java.io.File;

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
                if (!METHOD_COPY_IMAGE_FILE.equals(call.method)) {
                    result.notImplemented();
                    return;
                }
                handleCopyImageFile(appContext, call.argument(ARG_PATH), result);
            });
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
