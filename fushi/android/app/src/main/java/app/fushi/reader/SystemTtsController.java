package app.fushi.reader;

import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import android.speech.tts.Voice;

import java.io.File;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;

import io.flutter.plugin.common.MethodChannel;

/**
 * 系统语音（Android TextToSpeech）：列引擎、列某个引擎的声音、按指定引擎 / 声音合成到文件。
 *
 * <p>以前 TtsChannelHandler 构造时就 {@code new TextToSpeech(context, listener)}，只能绑
 * 系统默认引擎；而 targetSdk 30+ 的包可见性让清单里没声明 TTS_SERVICE 查询的 app 看不见
 * 第三方引擎（讯飞、MultiTTS、商店版谷歌 / 微软……），默认引擎恰好是它们时绑定直接失败或
 * 回落到别的引擎——「别的软件能用系统 TTS，Fushi 不能」就是这么来的（清单的
 * {@code <queries>} 补了声明，这里补「能选」）。
 *
 * <p>形态：<b>所有请求排成一个队列、一次只跑一个</b>，因为一个 TextToSpeech 实例同一时刻
 * 只绑一个引擎、只有一个 UtteranceProgressListener。轮到某个请求时，所需引擎与当前实例
 * 不同就关掉旧实例、按包名新建一个，等初始化回调再继续。实例懒建：{@code :popup} 进程
 * 的查词引擎也挂着本 handler，但多数时候根本用不到语音，不该为它常驻一个引擎绑定。
 *
 * <p>线程：队列只在主线程读写（channel 回调、init 回调、utterance 回调全部 post 回主线程）。
 */
final class SystemTtsController {
    /** 一个请求在某个引擎实例上的执行体。完成（无论成败）后必须调一次 {@code done}。 */
    private interface Job {
        /** 请求要的引擎包名；"" = 系统默认引擎。 */
        String engine();

        void run(TextToSpeech tts, Runnable done);

        /** 没轮到执行就失败（引擎不可用 / handler 已销毁）。 */
        void fail(String code, String message);
    }

    private static final int INIT_PENDING = 0;
    private static final int INIT_OK = 1;
    private static final int INIT_FAILED = 2;

    /** 单个请求从开跑到引擎回调的上界：个别引擎出错时既不回 onDone 也不回 onError，队列不能就此卡死。 */
    private static final long JOB_TIMEOUT_MS = 30_000;

    private final Context context;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ArrayDeque<Job> queue = new ArrayDeque<>();

    private TextToSpeech tts;
    /** 当前实例绑的引擎包名；"" = 系统默认引擎；null = 没有实例。 */
    private String ttsEngine;
    private int initState = INIT_PENDING;
    /** 每建一个实例自增：旧实例迟到的 init 回调据此作废。 */
    private int instanceGeneration = 0;
    private boolean busy = false;
    private boolean destroyed = false;
    private int utteranceSeq = 0;

    SystemTtsController(Context context) {
        this.context = context;
    }

    /** 设备上声明了 TTS_SERVICE 的全部引擎（不需要实例，直接问 PackageManager）。 */
    List<Map<String, Object>> listEngines() {
        List<Map<String, Object>> engines = new ArrayList<>();
        PackageManager pm = context.getPackageManager();
        List<ResolveInfo> infos = pm.queryIntentServices(
                new Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE),
                PackageManager.MATCH_DEFAULT_ONLY);
        String defaultEngine = defaultEnginePackage();
        for (ResolveInfo info : infos) {
            if (info.serviceInfo == null) continue;
            String pkg = info.serviceInfo.packageName;
            boolean seen = false;
            for (Map<String, Object> e : engines) {
                if (pkg.equals(e.get("name"))) seen = true;
            }
            if (seen) continue;
            Map<String, Object> engine = new HashMap<>();
            engine.put("name", pkg);
            CharSequence label = info.loadLabel(pm);
            engine.put("label", label == null ? pkg : label.toString());
            engine.put("isDefault", pkg.equals(defaultEngine));
            engines.add(engine);
        }
        return engines;
    }

    private String defaultEnginePackage() {
        try {
            // Settings.Secure.TTS_DEFAULT_SYNTH 的值；用字面量免得踩到常量的弃用标注。
            return Settings.Secure.getString(context.getContentResolver(), "tts_default_synth");
        } catch (RuntimeException e) {
            return null;
        }
    }

    private boolean isEngineInstalled(String pkg) {
        for (Map<String, Object> e : listEngines()) {
            if (pkg.equals(e.get("name"))) return true;
        }
        return false;
    }

    /** 列 [engine]（"" / null = 默认引擎）的已安装声音。 */
    void listVoices(String engine, MethodChannel.Result result) {
        enqueue(new Job() {
            @Override public String engine() { return normalize(engine); }

            @Override public void run(TextToSpeech instance, Runnable done) {
                List<Map<String, Object>> out = new ArrayList<>();
                try {
                    Set<Voice> voices = instance.getVoices();
                    if (voices != null) {
                        for (Voice v : voices) {
                            Set<String> features = v.getFeatures();
                            // 「列出但没下载」的声音一合成就失败或在后台触发下载：不给选。
                            if (features != null && features.contains(
                                    TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED)) {
                                continue;
                            }
                            Map<String, Object> m = new HashMap<>();
                            m.put("name", v.getName());
                            Locale locale = v.getLocale();
                            m.put("locale", locale == null ? "" : locale.toLanguageTag());
                            m.put("network", v.isNetworkConnectionRequired());
                            out.add(m);
                        }
                    }
                } catch (RuntimeException e) {
                    // 个别引擎 getVoices 未实现会抛：等同于「这个引擎不支持按声音选」。
                    android.util.Log.w("fushi-tts", "getVoices failed", e);
                }
                result.success(out);
                done.run();
            }

            @Override public void fail(String code, String message) {
                result.error(code, message, null);
            }
        });
    }

    /**
     * 合成到文件。失败一律以错误码回 Dart（BUG-3669）：ENGINE_UNAVAILABLE（引擎初始化失败
     * 或指定的引擎没装）/ VOICE_UNAVAILABLE（指定的声音不在该引擎里）/
     * LANGUAGE_MISSING_DATA / LANGUAGE_NOT_SUPPORTED（setLanguage 的结果）/
     * SYNTHESIS_FAILED。指定了 voice 时按声音合成、不再按语言挑；languageTag 为
     * null = 引擎默认语言。
     */
    void synthesize(String text, String languageTag, String engine, String voiceName,
                    String outputPath, MethodChannel.Result result) {
        enqueue(new Job() {
            @Override public String engine() { return normalize(engine); }

            @Override public void run(TextToSpeech instance, Runnable done) {
                runSynthesis(instance, text, languageTag, voiceName, outputPath, result, done);
            }

            @Override public void fail(String code, String message) {
                result.error(code, message, null);
            }
        });
    }

    private void runSynthesis(TextToSpeech instance, String text, String languageTag,
                              String voiceName, String outputPath,
                              MethodChannel.Result result, Runnable done) {
        if (voiceName != null && !voiceName.isEmpty()) {
            Voice target = null;
            try {
                Set<Voice> voices = instance.getVoices();
                if (voices != null) {
                    for (Voice v : voices) {
                        if (voiceName.equals(v.getName())) target = v;
                    }
                }
            } catch (RuntimeException ignored) {
                // 同 listVoices：拿不到声音表就当这个声音不在。
            }
            if (target == null || instance.setVoice(target) != TextToSpeech.SUCCESS) {
                result.error("VOICE_UNAVAILABLE", voiceName, null);
                done.run();
                return;
            }
        } else {
            Locale locale = (languageTag != null && !languageTag.isEmpty())
                    ? Locale.forLanguageTag(languageTag)
                    : engineDefaultLocale(instance);
            int langResult = instance.setLanguage(locale);
            if (langResult == TextToSpeech.LANG_MISSING_DATA) {
                result.error("LANGUAGE_MISSING_DATA", locale.toLanguageTag(), null);
                done.run();
                return;
            }
            if (langResult == TextToSpeech.LANG_NOT_SUPPORTED) {
                result.error("LANGUAGE_NOT_SUPPORTED", locale.toLanguageTag(), null);
                done.run();
                return;
            }
        }
        final String utteranceId = "fushi_tts_" + (++utteranceSeq);
        // 引擎回调在 TTS 后台线程；synthesizeToFile 也可能同步失败；看门狗在主线程。
        // 三条路只许答复一次。
        final AtomicBoolean answered = new AtomicBoolean(false);
        final Runnable[] watchdog = new Runnable[1];
        final java.util.function.BiConsumer<String, String> finish = (code, message) -> {
            if (!answered.compareAndSet(false, true)) return;
            main.post(() -> {
                main.removeCallbacks(watchdog[0]);
                if (instance == tts) instance.setOnUtteranceProgressListener(null);
                if (code == null) {
                    result.success(outputPath);
                } else {
                    result.error(code, message, null);
                }
                done.run();
            });
        };
        watchdog[0] = () -> {
            if (answered.get()) return;
            // 卡住的实例不再复用：先拆掉（本回调就在主线程），下一个请求重新初始化。
            // 顺序不能反：finish 的答复里会 pump 下一个请求，那时实例必须已经换掉。
            dropInstance();
            finish.accept("SYNTHESIS_FAILED", "engine did not answer within " + JOB_TIMEOUT_MS + "ms");
        };
        instance.setOnUtteranceProgressListener(new UtteranceProgressListener() {
            @Override public void onStart(String id) {}

            @Override public void onDone(String id) {
                if (utteranceId.equals(id)) finish.accept(null, null);
            }

            @Override public void onError(String id) {
                if (utteranceId.equals(id)) finish.accept("SYNTHESIS_FAILED", "utterance error");
            }

            @Override public void onError(String id, int errorCode) {
                if (utteranceId.equals(id)) {
                    finish.accept("SYNTHESIS_FAILED", "utterance error " + errorCode);
                }
            }

            @Override public void onStop(String id, boolean interrupted) {
                if (utteranceId.equals(id)) finish.accept("SYNTHESIS_FAILED", "stopped");
            }
        });
        main.postDelayed(watchdog[0], JOB_TIMEOUT_MS);
        int r = instance.synthesizeToFile(text, null, new File(outputPath), utteranceId);
        if (r != TextToSpeech.SUCCESS) {
            finish.accept("SYNTHESIS_FAILED", "synthesizeToFile returned " + r);
        }
    }

    /** 引擎自己的默认语言（用户在系统 TTS 设置里选的）；取不到再用系统区域。 */
    private static Locale engineDefaultLocale(TextToSpeech instance) {
        try {
            Voice voice = instance.getDefaultVoice();
            if (voice != null && voice.getLocale() != null) return voice.getLocale();
        } catch (RuntimeException ignored) {
            // 个别引擎 getDefaultVoice 未实现会抛；退回系统区域，不影响合成。
        }
        return Locale.getDefault();
    }

    void stop() {
        if (initState == INIT_OK && tts != null) tts.stop();
    }

    /** handler 拆除：释放实例，排队中的请求不能永远不答复。 */
    void destroy() {
        destroyed = true;
        dropInstance();
        List<Job> waiting = new ArrayList<>(queue);
        queue.clear();
        for (Job job : waiting) job.fail("ENGINE_UNAVAILABLE", "handler destroyed");
    }

    private static String normalize(String engine) {
        return engine == null ? "" : engine.trim();
    }

    private void enqueue(Job job) {
        if (destroyed) {
            job.fail("ENGINE_UNAVAILABLE", "handler destroyed");
            return;
        }
        queue.add(job);
        pump();
    }

    private void pump() {
        if (busy || destroyed || queue.isEmpty()) return;
        Job job = queue.peek();
        String want = job.engine();
        if (!want.equals(ttsEngine)) bind(want);
        if (initState == INIT_PENDING) return; // 初始化回调里再 pump。
        queue.poll();
        if (initState != INIT_OK || tts == null) {
            job.fail("ENGINE_UNAVAILABLE",
                    want.isEmpty() ? "default TextToSpeech engine failed to initialise"
                            : "TextToSpeech engine " + want + " is not available");
            // 不留失败的实例：用户之后装好 / 换好引擎，下一个请求就能重新绑定。
            dropInstance();
            pump();
            return;
        }
        busy = true;
        job.run(tts, () -> {
            busy = false;
            pump();
        });
    }

    private void bind(String engine) {
        dropInstance();
        ttsEngine = engine;
        final int generation = ++instanceGeneration;
        if (!engine.isEmpty() && !isEngineInstalled(engine)) {
            // 指定的引擎不在（卸载了 / 换了设备）：TextToSpeech 会悄悄换成默认引擎，
            // 那就不是用户选的声音了。直接报引擎不可用。
            initState = INIT_FAILED;
            return;
        }
        initState = INIT_PENDING;
        TextToSpeech.OnInitListener listener = status -> main.post(() -> {
            if (generation != instanceGeneration) return; // 已被换掉的实例。
            initState = status == TextToSpeech.SUCCESS ? INIT_OK : INIT_FAILED;
            pump();
        });
        tts = engine.isEmpty()
                ? new TextToSpeech(context, listener)
                : new TextToSpeech(context, listener, engine);
    }

    private void dropInstance() {
        instanceGeneration++;
        if (tts != null) {
            try {
                tts.shutdown();
            } catch (RuntimeException ignored) {
                // 引擎进程已死时 shutdown 可能抛；实例反正不再用。
            }
        }
        tts = null;
        ttsEngine = null;
        initState = INIT_PENDING;
    }
}
