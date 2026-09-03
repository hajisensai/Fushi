package app.fushi.reader;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Rect;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import app.fushi.reader.constants.ChannelNames;

import com.google.mlkit.common.MlKitException;
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
 * 设备自带文字识别（ML Kit，**unbundled** 模型 —— 模型由 Google Play 服务保管）。
 *
 * <p>存在的理由是用户那句「安装后不用下载模型也能用」。这件事由
 * {@code AndroidManifest.xml} 里的 {@code com.google.mlkit.vision.DEPENDENCIES}
 * meta-data 兑现：Play 服务在**安装时**就把声明的四套文字模型取下来，而不是拖到第一次
 * 识别才现下。模型住在系统侧、多个 app 共享，所以 APK 只带 API 壳，不像 bundled 版
 * 那样每种文字往包里塞约 4 MB（四种合计约 16 MB，而用户实际只会用到其中一两套）。
 *
 * <p>代价是它依赖 Google Play 服务。**这条依赖不允许静默**：模型没就绪时 ML Kit 抛
 * {@link MlKitException#UNAVAILABLE}，这里单独映射成 {@code MODEL_UNAVAILABLE}，与
 * 真正的识别失败 {@code RECOGNIZE_FAILED} 分开——两者塞进同一个错误码的话，用户看到的
 * 是「识别失败」，会去怀疑图片或引擎，而真正该做的是等模型下完或换引擎。
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

    /**
     * 按语言缓存的识别器。
     *
     * <p>每页新建再销毁一个 TextRecognizer 等于每页重新加载一次模型——一卷两百页
     * 就是两百次。识别器本身是线程安全的可复用对象，缓存起来只占一份模型内存。
     *
     * <p>不主动 close：进程存活期间它就是要被反复用的；进程结束时随之释放。
     */
    private static final Map<String, TextRecognizer> RECOGNIZERS = new HashMap<>();

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

        final TextRecognizer recognizer = recognizerFor(language);
        recognizer.process(InputImage.fromBitmap(bitmap, 0))
            .addOnSuccessListener(text -> {
                try {
                    result.success(toPayload(text, bitmap.getWidth(), bitmap.getHeight()));
                } finally {
                    bitmap.recycle();
                }
            })
            .addOnFailureListener(error -> {
                bitmap.recycle();
                // 「模型还没就绪」和「这张图识别失败」是两回事，不能塌成同一个码：
                // 前者要么等 Play 服务把模型下完、要么换引擎，后者才该怀疑图片。
                // unbundled 版模型缺失时 ML Kit 抛的正是 UNAVAILABLE。
                final boolean unavailable = error instanceof MlKitException
                    && ((MlKitException) error).getErrorCode() == MlKitException.UNAVAILABLE;
                result.error(
                    unavailable ? "MODEL_UNAVAILABLE" : "RECOGNIZE_FAILED",
                    error.getMessage(),
                    null);
            });
    }

    /** 取（或建）该语言的识别器。调用恒在平台主线程，无需额外同步。 */
    private static TextRecognizer recognizerFor(@Nullable String language) {
        final String key = scriptKeyFor(language);
        TextRecognizer cached = RECOGNIZERS.get(key);
        if (cached == null) {
            cached = TextRecognition.getClient(optionsFor(language));
            RECOGNIZERS.put(key, cached);
        }
        return cached;
    }

    /** 缓存键取「用哪套文字模型」而不是原始语言标签：ja-JP 与 ja 共用一个。 */
    private static String scriptKeyFor(@Nullable String language) {
        final String tag = language == null ? "" : language.toLowerCase();
        if (tag.startsWith("ja")) {
            return "ja";
        }
        if (tag.startsWith("zh")) {
            return "zh";
        }
        if (tag.startsWith("ko")) {
            return "ko";
        }
        return "latn";
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
