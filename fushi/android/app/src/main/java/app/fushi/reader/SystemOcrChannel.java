package app.fushi.reader;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Rect;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import app.fushi.reader.constants.ChannelNames;

import com.google.android.gms.common.ConnectionResult;
import com.google.android.gms.common.GoogleApiAvailability;
import com.google.android.gms.common.moduleinstall.InstallStatusListener;
import com.google.android.gms.common.moduleinstall.ModuleInstall;
import com.google.android.gms.common.moduleinstall.ModuleInstallClient;
import com.google.android.gms.common.moduleinstall.ModuleInstallRequest;
import com.google.android.gms.common.moduleinstall.ModuleInstallStatusUpdate;
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
import java.util.concurrent.atomic.AtomicBoolean;

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
    private static final String METHOD_MODEL_STATUS = "modelStatus";
    private static final String METHOD_INSTALL_MODEL = "installModel";
    private static final String METHOD_RESOLVE_PLAY_SERVICES = "resolvePlayServices";
    private static final String METHOD_OPEN_PLAY_SERVICES_SETTINGS = "openPlayServicesSettings";

    private static final String TAG = "FushiSystemOcr";

    /**
     * {@code modelStatus} 回答的 {@code status} 字段（Dart 侧 {@code parseSystemOcrModelReport}）。
     *
     * <p>Play 服务有问题时只报 {@link #STATUS_PLAY_SERVICES_PROBLEM} 加**原始**
     * {@link ConnectionResult} 码与版本号，按码细分成哪种状态由 Dart 侧一个纯函数决定
     * （BUG-4127）：以前在这里用 isUserResolvableError 二分成「可修 / 不可修」两个状态，
     * 原始码丢了，用户 Play 服务已是最新也只能看到「缺失、被停用或版本过旧」。
     */
    private static final String STATUS_READY = "ready";
    private static final String STATUS_MISSING = "missing";
    private static final String STATUS_PLAY_SERVICES_PROBLEM = "play_services_problem";
    private static final String KEY_STATUS = "status";
    private static final String KEY_CONNECTION_RESULT = "connectionResult";
    private static final String KEY_INSTALLED_VERSION_CODE = "installedVersionCode";
    private static final String KEY_INSTALLED_VERSION_NAME = "installedVersionName";
    private static final String KEY_REQUIRED_VERSION_CODE = "requiredVersionCode";
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

    /**
     * @param activity 宿主 Activity：「修复 Google Play 服务」的系统对话框要从 Activity 起；
     *     模型状态查询 / 下载只用它的 Context。
     */
    public static void registerWith(
            @NonNull FlutterEngine flutterEngine, @NonNull Activity activity) {
        new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(),
                ChannelNames.SYSTEM_OCR)
            .setMethodCallHandler((call, result) -> {
                switch (call.method) {
                    case METHOD_IS_AVAILABLE:
                        // 能力探测只答「这个平台有没有系统 OCR」：恒 true。模型是否已由
                        // Play 服务取下是另一件事，由 modelStatus 回答；缺模型时 recognize
                        // 报 MODEL_UNAVAILABLE，调用方据此带用户去下载（BUG-2906），而不是
                        // 在这里把整个引擎置灰——置灰了用户就再也走不到下载入口。
                        result.success(Boolean.TRUE);
                        return;
                    case METHOD_RECOGNIZE:
                        handleRecognize(call.argument(ARG_BYTES),
                                call.argument(ARG_LANGUAGE), result);
                        return;
                    case METHOD_MODEL_STATUS:
                        handleModelStatus(activity, call.argument(ARG_LANGUAGE), result);
                        return;
                    case METHOD_INSTALL_MODEL:
                        handleInstallModel(activity, call.argument(ARG_LANGUAGE), result);
                        return;
                    case METHOD_RESOLVE_PLAY_SERVICES:
                        GoogleApiAvailability.getInstance()
                                .makeGooglePlayServicesAvailable(activity)
                                .addOnSuccessListener(unused -> result.success(Boolean.TRUE))
                                .addOnFailureListener(error -> result.success(Boolean.FALSE));
                        return;
                    case METHOD_OPEN_PLAY_SERVICES_SETTINGS:
                        handleOpenPlayServicesSettings(activity, result);
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

    /**
     * Play 服务不在 / 版本不对时的诊断载荷；在位返回 null。模型由 Play 服务保管，它不在就
     * 无从谈起下载，必须先把这件事告诉用户。
     *
     * <p>原样回传 {@link ConnectionResult} 码、本机 Play 服务 APK 的版本，以及本库要求的
     * 最低版本 {@link GoogleApiAvailability#GOOGLE_PLAY_SERVICES_VERSION_CODE}（BUG-4127）：
     * 报「版本过旧」而 Play 商店说已是最新时，只有两个版本号摆出来才看得懂是哪一边的事。
     */
    @Nullable
    private static Map<String, Object> playServicesProblem(@NonNull Activity activity) {
        final GoogleApiAvailability gms = GoogleApiAvailability.getInstance();
        final int code = gms.isGooglePlayServicesAvailable(activity);
        if (code == ConnectionResult.SUCCESS) return null;
        final Map<String, Object> problem = new HashMap<>();
        problem.put(KEY_STATUS, STATUS_PLAY_SERVICES_PROBLEM);
        problem.put(KEY_CONNECTION_RESULT, code);
        problem.put(KEY_REQUIRED_VERSION_CODE,
                GoogleApiAvailability.GOOGLE_PLAY_SERVICES_VERSION_CODE);
        Long installedCode = null;
        String installedName = null;
        try {
            final PackageInfo info = activity.getPackageManager().getPackageInfo(
                    GoogleApiAvailability.GOOGLE_PLAY_SERVICES_PACKAGE, 0);
            installedCode = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
                    ? info.getLongVersionCode()
                    : (long) info.versionCode;
            installedName = info.versionName;
        } catch (PackageManager.NameNotFoundException notFound) {
            // 包管理器查不到 com.google.android.gms（没装，或对本 app 不可见）：版本留空，
            // Dart 侧诊断行显示「查不到」——只陈述查询结果，不替它断言「未安装」。
        }
        problem.put(KEY_INSTALLED_VERSION_CODE, installedCode);
        problem.put(KEY_INSTALLED_VERSION_NAME, installedName);
        Log.w(TAG, "Google Play services unavailable for system OCR: "
                + gms.getErrorString(code) + " (ConnectionResult " + code
                + "), installed " + installedName + " (" + installedCode + ")"
                + ", required " + GoogleApiAvailability.GOOGLE_PLAY_SERVICES_VERSION_CODE);
        return problem;
    }

    /** 单字段状态载荷（Play 服务在位时的 ready / missing）。 */
    private static Map<String, Object> statusPayload(@NonNull String status) {
        final Map<String, Object> payload = new HashMap<>();
        payload.put(KEY_STATUS, status);
        return payload;
    }

    /**
     * Play 服务被停用时，系统的「修复」对话框帮不上忙——只能去它的应用详情页点「启用」。
     * 这里直接打开那一页；打不开就照实报错，由 Dart 侧显示出来。
     */
    private static void handleOpenPlayServicesSettings(
            @NonNull Activity activity, @NonNull MethodChannel.Result result) {
        final Intent intent = new Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package",
                        GoogleApiAvailability.GOOGLE_PLAY_SERVICES_PACKAGE, null));
        try {
            activity.startActivity(intent);
            result.success(Boolean.TRUE);
        } catch (ActivityNotFoundException error) {
            result.error("SETTINGS_UNAVAILABLE", error.getMessage(), null);
        }
    }

    /**
     * 该语言的文字模型是否已由 Play 服务取下。只查询、不触发下载（BUG-2906）。
     *
     * <p>manifest 的 DEPENDENCIES 只是请 Play 服务在安装时**顺手**取模型，不保证真取到
     * （没联网、Play 服务排队、侧载安装都会落空）；这里如实回答「现在有没有」。
     */
    private static void handleModelStatus(
            @NonNull Activity activity,
            @Nullable String language,
            @NonNull MethodChannel.Result result) {
        final Map<String, Object> problem = playServicesProblem(activity);
        if (problem != null) {
            result.success(problem);
            return;
        }
        ModuleInstall.getClient(activity)
                .areModulesAvailable(recognizerFor(language))
                .addOnSuccessListener(response -> result.success(statusPayload(
                        response.areModulesAvailable() ? STATUS_READY : STATUS_MISSING)))
                .addOnFailureListener(error ->
                        result.error("STATUS_FAILED", error.getMessage(), null));
    }

    /**
     * 请 Play 服务立即下载该语言的文字模型（ModuleInstall API），下完 / 失败才回答。
     *
     * <p>不回进度：模型只有几 MB，Dart 侧显示不定进度即可；用户关掉弹窗也不取消，
     * 下载仍由 Play 服务在后台做完。
     */
    private static void handleInstallModel(
            @NonNull Activity activity,
            @Nullable String language,
            @NonNull MethodChannel.Result result) {
        final Map<String, Object> problem = playServicesProblem(activity);
        if (problem != null) {
            // details 与 modelStatus 的载荷同形：Dart 侧据此切到对应的 Play 服务状态。
            result.error("PLAY_SERVICES_UNAVAILABLE",
                    "Google Play services ConnectionResult "
                            + problem.get(KEY_CONNECTION_RESULT),
                    problem);
            return;
        }
        final ModuleInstallClient client = ModuleInstall.getClient(activity);
        // 安装终态与「本来就装好了」两条路都可能回答，result 只许回一次。
        final AtomicBoolean answered = new AtomicBoolean(false);
        final InstallStatusListener[] holder = new InstallStatusListener[1];
        final InstallStatusListener listener = update -> {
            final int state = update.getInstallState();
            final boolean done =
                    state == ModuleInstallStatusUpdate.InstallState.STATE_COMPLETED;
            final boolean failed =
                    state == ModuleInstallStatusUpdate.InstallState.STATE_FAILED
                            || state == ModuleInstallStatusUpdate.InstallState.STATE_CANCELED;
            if (!done && !failed) return;
            client.unregisterListener(holder[0]);
            if (!answered.compareAndSet(false, true)) return;
            if (done) {
                result.success(STATUS_READY);
            } else {
                result.error("INSTALL_FAILED",
                        "module install ended in state " + state
                                + " (error " + update.getErrorCode() + ")",
                        null);
            }
        };
        holder[0] = listener;
        final ModuleInstallRequest request = ModuleInstallRequest.newBuilder()
                .addApi(recognizerFor(language))
                .setListener(listener)
                .build();
        client.installModules(request)
                .addOnSuccessListener(response -> {
                    if (!response.areModulesAlreadyInstalled()) return;
                    client.unregisterListener(listener);
                    if (answered.compareAndSet(false, true)) result.success(STATUS_READY);
                })
                .addOnFailureListener(error -> {
                    client.unregisterListener(listener);
                    if (answered.compareAndSet(false, true)) {
                        result.error("INSTALL_FAILED", error.getMessage(), null);
                    }
                });
    }

    /**
     * 取（或建）该语言的识别器。调用恒在平台主线程，无需额外同步。
     *
     * <p>包内可见：截屏 OCR（ScreenOcrService）复用同一份缓存，不再各加载一套模型。
     */
    static TextRecognizer recognizerFor(@Nullable String language) {
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
