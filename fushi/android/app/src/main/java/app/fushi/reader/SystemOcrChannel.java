package app.fushi.reader;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Rect;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import app.fushi.reader.constants.ChannelNames;

import com.google.mlkit.vision.common.InputImage;
import com.google.mlkit.vision.text.Text;
import com.google.mlkit.vision.text.TextRecognition;
import com.google.mlkit.vision.text.TextRecognizer;
import com.google.mlkit.vision.text.TextRecognizerOptionsInterface;
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions;
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions;
import com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions;
import com.google.mlkit.vision.text.latin.TextRecognizerOptions;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/**
 * 设备自带文字识别（ML Kit，**bundled** 模型）。
 *
 * <p>存在的理由是用户那句「安装后不用下载模型也能用」。这里刻意用 bundled 依赖
 * （{@code com.google.mlkit:text-recognition-*}）而不是 unbundled 的
 * {@code play-services-mlkit-text-recognition-*}：后者的模型要经 Google Play
 * services 按需下载，在下不动 huggingface 的网络环境里同样下不动，等于没解决问题。
 * 代价是 APK 变大（每种文字约 4 MB），换来的是装完即用、完全离线。
 *
 * <p><b>别把它当主力</b>：ML Kit 是通用识别器，对漫画的竖排气泡和手写拟声词明显
 * 不如 manga-ocr。Dart 侧把它定位成兜底档，UI 文案也如实这么写。
 *
 * <p>逐行返回，不做任何分组：气泡的合并由 Dart/JS 侧统一处理（Google Lens 也会把
 * 一个竖排气泡拆成多列回来，那套合并逻辑早就存在）。
 */
public final class SystemOcrChannel {
    private static final String METHOD_IS_AVAILABLE = "isAvailable";
    private static final String METHOD_RECOGNIZE = "recognize";
    private static final String ARG_BYTES = "bytes";
    private static final String ARG_LANGUAGE = "language";

    private SystemOcrChannel() {}

    public static void registerWith(@NonNull FlutterEngine flutterEngine) {
        new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(),
                ChannelNames.SYSTEM_OCR)
            .setMethodCallHandler((call, result) -> {
                switch (call.method) {
                    case METHOD_IS_AVAILABLE:
                        // 模型随 APK 打包，设备上恒可用——不需要探测下载状态，
                        // 也不该在这里触发任何网络请求。
                        result.success(Boolean.TRUE);
                        return;
                    case METHOD_RECOGNIZE:
                        handleRecognize(call.argument(ARG_BYTES),
                                call.argument(ARG_LANGUAGE), result);
                        return;
                    default:
                        result.notImplemented();
                }
            });
    }

    private static void handleRecognize(
            @Nullable byte[] bytes,
            @Nullable String language,
            @NonNull MethodChannel.Result result) {
        if (bytes == null || bytes.length == 0) {
            result.error("INVALID_IMAGE", "image bytes must not be empty", null);
            return;
        }
        final Bitmap bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
        if (bitmap == null) {
            result.error("INVALID_IMAGE", "could not decode image bytes", null);
            return;
        }

        final TextRecognizer recognizer = TextRecognition.getClient(optionsFor(language));
        recognizer.process(InputImage.fromBitmap(bitmap, 0))
            .addOnSuccessListener(text -> {
                try {
                    result.success(toPayload(text, bitmap.getWidth(), bitmap.getHeight()));
                } finally {
                    recognizer.close();
                    bitmap.recycle();
                }
            })
            .addOnFailureListener(error -> {
                recognizer.close();
                bitmap.recycle();
                result.error("RECOGNIZE_FAILED", error.getMessage(), null);
            });
    }

    /**
     * 按内容语言挑识别器。
     *
     * <p>不假设日语：Fushi 没有全局学习语言，漫画的内容语言由调用方传进来。认不出
     * 的语言回退拉丁识别器（它同时覆盖英语等大多数拉丁字母语言）。
     */
    private static TextRecognizerOptionsInterface optionsFor(@Nullable String language) {
        final String tag = language == null ? "" : language.toLowerCase();
        if (tag.startsWith("ja")) {
            return new JapaneseTextRecognizerOptions.Builder().build();
        }
        if (tag.startsWith("zh")) {
            return new ChineseTextRecognizerOptions.Builder().build();
        }
        if (tag.startsWith("ko")) {
            return new KoreanTextRecognizerOptions.Builder().build();
        }
        return TextRecognizerOptions.DEFAULT_OPTIONS;
    }

    /**
     * ML Kit 结果 → Dart 侧 {@code parseSystemOcrPayload} 认识的载荷。
     *
     * <p>字段名是跨语言契约的一部分，改这里必须同步改 Dart 侧那个解析函数（那边有
     * 契约测试盯着；只改一边的后果是真机上返回一页空结果，看起来和「这页真没字」
     * 一模一样）。
     */
    private static Map<String, Object> toPayload(
            @NonNull Text text, int width, int height) {
        final List<Map<String, Object>> lines = new ArrayList<>();
        for (final Text.TextBlock block : text.getTextBlocks()) {
            for (final Text.Line line : block.getLines()) {
                final Rect box = line.getBoundingBox();
                if (box == null || box.width() <= 0 || box.height() <= 0) {
                    continue;
                }
                final String value = line.getText();
                if (value == null || value.trim().isEmpty()) {
                    continue;
                }
                final Map<String, Object> entry = new HashMap<>();
                entry.put("text", value);
                entry.put("left", box.left);
                entry.put("top", box.top);
                entry.put("right", box.right);
                entry.put("bottom", box.bottom);
                // ML Kit 不直接报竖排；留空让 Dart 侧按包围盒推断，避免在这里
                // 和那边各写一套判据。
                lines.add(entry);
            }
        }
        final Map<String, Object> payload = new HashMap<>();
        payload.put("width", width);
        payload.put("height", height);
        payload.put("lines", lines);
        return payload;
    }
}
