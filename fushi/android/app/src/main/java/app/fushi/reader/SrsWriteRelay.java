package app.fushi.reader;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

import io.flutter.FlutterInjector;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.dart.DartExecutor;
import io.flutter.plugin.common.MethodChannel;

/**
 * 主进程一端的复习写入转交（BUG-5542，拍板 D10「弹窗进程只读，弹窗里的制卡转交主进程」）。
 *
 * <p>新代复习库只有主进程按 Primary 打开；{@code :popup} 查词窗与 {@code :second_screen} 面板按
 * Secondary 只读打开，它们的写入（制卡、覆写、改字段、删卡）经 {@link SrsWriteRelayService} 送到这里，
 * 由主进程里的一个 Dart 执行引擎执行（{@code srs_write_relay.dart} 的 {@code SrsWriteRelayHost}）：
 *
 * <ul>
 *   <li>主界面的引擎在（{@link #attachMain}）：交给它，在主界面自己的复习副本上写；</li>
 *   <li>主界面不在（进程刚被这次绑定拉起，或主界面已被关掉）：起一个无界面的执行引擎（Dart 入口
 *       {@code srsWriteHostMain}），它按 Primary 开库、执行，空闲 {@link #HEADLESS_IDLE_MS} 后交出主库并销毁。</li>
 * </ul>
 *
 * <p>同一进程里同一时刻只有一个 Primary：主界面的引擎开主库之前调 {@code claimPrimary}，这里先让无界面执行引擎
 * 做完手上的请求、关库、销毁，才回给它。
 *
 * <p>全部状态只在主线程上读写。
 */
final class SrsWriteRelay {
    private static final String TAG = "SrsWriteRelay";
    static final String HOST_CHANNEL = "app.fushi.reader/srs_write_relay_host";
    private static final String HEADLESS_ENTRYPOINT = "srsWriteHostMain";

    /** 执行引擎装好处理器（{@code ready}）的时限：主界面冷启动时初始化、闪退提示都在它前面。 */
    private static final long READY_TIMEOUT_MS = 90_000L;
    /** 一条请求在主进程这端的总时限（含排队等引擎就绪）。 */
    private static final long REQUEST_TIMEOUT_MS = 150_000L;
    /** 无界面执行引擎空闲多久交出主库（连续查词制卡时不反复冷启动）。 */
    private static final long HEADLESS_IDLE_MS = 60_000L;
    /** 交出主库（{@code release}）的时限：超时照样销毁引擎。 */
    private static final long RELEASE_TIMEOUT_MS = 30_000L;

    /** 一条请求的结果：{@code json} 是执行端的回包，{@code error} 非空表示没执行成（传输 / 引擎层面的失败）。 */
    interface Reply {
        void done(@Nullable String json, @Nullable String error);
    }

    private static final class Pending {
        final String json;
        final Reply reply;
        boolean done;
        Runnable timeout;

        Pending(String json, Reply reply) {
            this.json = json;
            this.reply = reply;
        }
    }

    private static final class Target {
        final FlutterEngine engine;
        final MethodChannel channel;
        final boolean headless;
        boolean ready;
        final Set<Pending> inFlight = new HashSet<>();

        Target(FlutterEngine engine, MethodChannel channel, boolean headless) {
            this.engine = engine;
            this.channel = channel;
            this.headless = headless;
        }
    }

    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final ArrayDeque<Pending> queue = new ArrayDeque<>();
    private static final List<Runnable> afterRelease = new ArrayList<>();

    @Nullable private static Context appContext;
    @Nullable private static Target main;
    @Nullable private static Target headless;
    private static boolean releasing;
    @Nullable private static Runnable idleRelease;

    private SrsWriteRelay() {}

    /** 收下一条请求（主线程）。 */
    static void submit(@NonNull Context context, @NonNull String json, @NonNull Reply reply) {
        appContext = context.getApplicationContext();
        final Pending p = new Pending(json, reply);
        p.timeout = () -> finish(p, null, "timed out waiting for the main app to save");
        MAIN.postDelayed(p.timeout, REQUEST_TIMEOUT_MS);
        queue.add(p);
        pump();
    }

    /** 主界面的引擎建好（MainActivity.configureFlutterEngine）。 */
    static void attachMain(@NonNull FlutterEngine engine, @NonNull Context context) {
        appContext = context.getApplicationContext();
        final MethodChannel channel =
                new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), HOST_CHANNEL);
        final Target t = new Target(engine, channel, false);
        channel.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "ready":
                    t.ready = true;
                    result.success(null);
                    pump();
                    break;
                case "claimPrimary":
                    // 主界面要开主库：无界面执行引擎（若有）先交出。
                    releaseHeadless(() -> result.success(null));
                    break;
                default:
                    result.notImplemented();
            }
        });
        main = t;
        pump();
    }

    /** 主界面的引擎要销毁（MainActivity.onDestroy）。已派给它、还没回的请求报失败。 */
    static void detachMain(@Nullable FlutterEngine engine) {
        final Target t = main;
        if (t == null || engine == null || t.engine != engine) return;
        main = null;
        t.channel.setMethodCallHandler(null);
        for (Pending p : new ArrayList<>(t.inFlight)) {
            finish(p, null, "the main app closed while saving; check whether the card was added");
        }
        pump();
    }

    private static void pump() {
        if (queue.isEmpty()) return;
        final Target t = main != null ? main : headless;
        if (t == null) {
            startHeadless();
            return;
        }
        if (!t.ready || (t.headless && releasing)) return;
        cancelIdleRelease();
        while (!queue.isEmpty()) {
            dispatch(t, queue.poll());
        }
    }

    private static void dispatch(@NonNull Target t, @NonNull Pending p) {
        if (p.done) return;
        t.inFlight.add(p);
        t.channel.invokeMethod("execute", p.json, new MethodChannel.Result() {
            @Override
            public void success(@Nullable Object r) {
                t.inFlight.remove(p);
                if (r instanceof String) {
                    finish(p, (String) r, null);
                } else {
                    finish(p, null, "empty reply from the main app");
                }
                scheduleIdleRelease();
            }

            @Override
            public void error(@NonNull String code, @Nullable String message,
                    @Nullable Object details) {
                t.inFlight.remove(p);
                finish(p, null, message != null ? message : code);
                scheduleIdleRelease();
            }

            @Override
            public void notImplemented() {
                t.inFlight.remove(p);
                finish(p, null, "the main app cannot save cards for other windows");
                scheduleIdleRelease();
            }
        });
    }

    private static void finish(@NonNull Pending p, @Nullable String json, @Nullable String error) {
        if (p.done) return;
        p.done = true;
        queue.remove(p);
        if (p.timeout != null) MAIN.removeCallbacks(p.timeout);
        if (main != null) main.inFlight.remove(p);
        if (headless != null) headless.inFlight.remove(p);
        p.reply.done(json, error);
    }

    // ------------------------------------------------------------ 无界面执行引擎

    private static void startHeadless() {
        if (headless != null || releasing) return;
        final Context context = appContext;
        if (context == null) return;
        final FlutterEngine engine;
        try {
            engine = new FlutterEngine(context, null, false);
        } catch (RuntimeException e) {
            Log.e(TAG, "could not create the srs write engine", e);
            failQueued("could not start the main app's review store: " + e);
            return;
        }
        FloatingDictPluginRegistrant.registerWith(engine, context);
        final MethodChannel channel =
                new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), HOST_CHANNEL);
        final Target t = new Target(engine, channel, true);
        channel.setMethodCallHandler((call, result) -> {
            if ("ready".equals(call.method)) {
                t.ready = true;
                result.success(null);
                if (releasing && headless == t) {
                    sendRelease(t);
                } else {
                    pump();
                    scheduleIdleRelease();
                }
            } else if ("claimPrimary".equals(call.method)) {
                result.success(null);
            } else {
                result.notImplemented();
            }
        });
        headless = t;
        engine.getDartExecutor().executeDartEntrypoint(new DartExecutor.DartEntrypoint(
                FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                HEADLESS_ENTRYPOINT));
        MAIN.postDelayed(() -> {
            if (headless != t || t.ready) return;
            Log.e(TAG, "srs write engine never became ready");
            destroyHeadless(t);
            failQueued("the main app's review store did not start in time");
        }, READY_TIMEOUT_MS);
    }

    /** 让无界面执行引擎交出主库并销毁；没有它时立即 {@code done}。 */
    private static void releaseHeadless(@NonNull Runnable done) {
        final Target t = headless;
        if (t == null) {
            done.run();
            return;
        }
        afterRelease.add(done);
        if (releasing) return;
        releasing = true;
        cancelIdleRelease();
        // 还没就绪：等它 ready 再发（它就绪之前没开过库），ready 超时由 startHeadless 的定时器销毁。
        if (t.ready) sendRelease(t);
    }

    private static void sendRelease(@NonNull Target t) {
        final Runnable timeout = () -> {
            Log.w(TAG, "srs write engine did not release in time; destroying it");
            destroyHeadless(t);
        };
        MAIN.postDelayed(timeout, RELEASE_TIMEOUT_MS);
        t.channel.invokeMethod("release", null, new MethodChannel.Result() {
            @Override
            public void success(@Nullable Object r) {
                MAIN.removeCallbacks(timeout);
                destroyHeadless(t);
            }

            @Override
            public void error(@NonNull String code, @Nullable String message,
                    @Nullable Object details) {
                Log.w(TAG, "srs write engine release failed: " + message);
                MAIN.removeCallbacks(timeout);
                destroyHeadless(t);
            }

            @Override
            public void notImplemented() {
                MAIN.removeCallbacks(timeout);
                destroyHeadless(t);
            }
        });
    }

    private static void destroyHeadless(@NonNull Target t) {
        if (headless != t) return;
        headless = null;
        for (Pending p : new ArrayList<>(t.inFlight)) {
            finish(p, null, "the main app's review store stopped while saving");
        }
        t.channel.setMethodCallHandler(null);
        try {
            t.engine.destroy();
        } catch (RuntimeException e) {
            Log.w(TAG, "srs write engine destroy failed", e);
        }
        releasing = false;
        final List<Runnable> callbacks = new ArrayList<>(afterRelease);
        afterRelease.clear();
        for (Runnable r : callbacks) r.run();
        pump();
    }

    private static void scheduleIdleRelease() {
        final Target t = headless;
        if (t == null || !t.inFlight.isEmpty() || !queue.isEmpty() || releasing) return;
        cancelIdleRelease();
        idleRelease = () -> {
            idleRelease = null;
            if (headless == t && t.inFlight.isEmpty() && queue.isEmpty()) {
                releaseHeadless(() -> {});
            }
        };
        MAIN.postDelayed(idleRelease, HEADLESS_IDLE_MS);
    }

    private static void cancelIdleRelease() {
        if (idleRelease != null) {
            MAIN.removeCallbacks(idleRelease);
            idleRelease = null;
        }
    }

    private static void failQueued(@NonNull String error) {
        for (Pending p : new ArrayList<>(queue)) finish(p, null, error);
    }
}
