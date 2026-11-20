package app.fushi.reader;

import android.app.Activity;
import android.app.ActivityManager;
import android.app.Application;
import android.app.ApplicationExitInfo;
import android.content.ComponentCallbacks2;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.res.Configuration;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;

import androidx.annotation.NonNull;
import androidx.annotation.RequiresApi;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import app.fushi.reader.constants.ChannelNames;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/**
 * 上次进程「怎么没的」取证（Dart 门面 {@code lib/src/diagnostics/previous_exit_log.dart}）。
 *
 * <p>原生崩溃、被系统按内存杀、裸 Java 线程未捕获异常都绕过 Dart 的错误钩子，错误日志里
 * 只剩一次冷启动。系统其实记着：API 30+ 的 {@link ActivityManager#getHistoricalProcessExitReasons}
 * 给出 reason / description / importance / pss / rss / 时间，native crash（tombstone）与 ANR
 * 还能取 trace。Java 层崩溃（{@code REASON_CRASH}）系统不给 trace，由 {@link JavaCrashCapture}
 * 的链式未捕获异常处理器在崩溃时落盘，这里按 pid + 时间窗并进对应记录的 trace，交出后删除。启动时 Dart 调一次 {@code consumeExitReports}，只取上次汇报之后的新记录
 * （时间戳游标存 SharedPreferences），trace 只回传有限长度的摘要，不传完整 tombstone。
 *
 * <p>另外进程级登记 {@link ComponentCallbacks2#onTrimMemory}，把最近几次级别和时间记进
 * SharedPreferences，随下一次 consume 一起交出——被系统按内存杀之前通常先收到
 * RUNNING_CRITICAL / COMPLETE，这是 API &lt; 30 时唯一的系统侧旁证。
 */
public final class ProcessExitChannel {
    private static final String METHOD_CONSUME = "consumeExitReports";
    private static final String PREFS = "fushi_process_exit";
    private static final String KEY_LAST_EXIT_TS = "last_reported_exit_ts";
    private static final String KEY_TRIMS = "trim_events";
    private static final int MAX_TRIMS = 8;
    private static final int MAX_REASONS = 5;
    /**
     * 读 ANR 文本 trace 的字节上限：除主线程外还要找 Flutter 引擎线程段（raster / ui），
     * 一百多条线程的转储常过百 KB，引擎线程排在后面，只读开头会读不到。
     */
    private static final int TRACE_READ_BYTES = 1024 * 1024;
    /**
     * 读 tombstone proto 的字节上限：线程表在 proto 中段、顺序与崩溃线程无关，一百多条线程
     * （各带寄存器与栈内存片段）的 tombstone 常有几百 KB，只读开头会读不到崩溃线程。
     */
    private static final int TOMBSTONE_READ_BYTES = 8 * 1024 * 1024;
    /** 回传给 Dart 的 trace 摘要字符上限。 */
    private static final int TRACE_SUMMARY_CHARS = 3400;

    private static final String KEY_UI_EVENTS = "ui_visibility_events";
    private static final int MAX_UI_EVENTS = 8;
    /** trim / 可见性两个事件环的「读—改—写」互斥（主线程追加、consume 在后台线程取走）。 */
    private static final Object EVENTS_LOCK = new Object();

    private static boolean trimCallbacksRegistered;
    private static boolean uiTrackingInstalled;
    /** 本进程当前处于 started 状态的 Activity 数（只在主线程改）。 */
    private static int startedActivities;
    private static final ExecutorService EXECUTOR = Executors.newSingleThreadExecutor();

    private ProcessExitChannel() {
    }

    /**
     * 记下本进程界面「可见 / 不可见」的切换（任一 Activity started 时可见，全部 stopped 时
     * 不可见），每次切换同步落盘 "1|0@timestamp@pid"，随下一次 consume 交出。
     *
     * <p>为什么要它：{@code ApplicationExitInfo} 的 importance 落在 101–125（前台服务）时说不清
     * 界面在不在屏幕上，Dart 会话标记又只认得写它的那个进程——中间夹一个 Flutter 没起来的进程
     * （{@code PRESTART WITHOUT START ACTIVITY}）或标记被别的进程覆写，旧判定就只能按前台算，
     * 后台被回收也弹闪退报告（反馈 gTrf6djABo）。这里由原生按 pid 记，不依赖 Dart 起没起来。
     * 在 {@link FushiApplication#onCreate} 里装，第一个 Activity 的 onStart 之前就位。
     */
    static synchronized void installUiVisibilityTracking(Application app) {
        if (uiTrackingInstalled) return;
        uiTrackingInstalled = true;
        app.registerActivityLifecycleCallbacks(new Application.ActivityLifecycleCallbacks() {
            @Override
            public void onActivityStarted(@NonNull Activity activity) {
                if (startedActivities++ == 0) recordUiVisibility(app, true);
            }

            @Override
            public void onActivityStopped(@NonNull Activity activity) {
                if (startedActivities == 0) return;
                if (--startedActivities == 0) recordUiVisibility(app, false);
            }

            @Override
            public void onActivityCreated(@NonNull Activity activity, Bundle savedInstanceState) {
            }

            @Override
            public void onActivityResumed(@NonNull Activity activity) {
            }

            @Override
            public void onActivityPaused(@NonNull Activity activity) {
            }

            @Override
            public void onActivitySaveInstanceState(@NonNull Activity activity, @NonNull Bundle outState) {
            }

            @Override
            public void onActivityDestroyed(@NonNull Activity activity) {
            }
        });
    }

    /** 追加一条可见性切换，只留最近 {@link #MAX_UI_EVENTS} 条。commit() 同步落盘：切到后台后随时可能被杀。 */
    static void recordUiVisibility(Context context, boolean visible) {
        appendEvent(context, KEY_UI_EVENTS, MAX_UI_EVENTS,
                (visible ? "1" : "0") + "@" + System.currentTimeMillis() + "@" + Process.myPid());
    }

    private static void appendEvent(Context context, String key, int max, String item) {
        synchronized (EVENTS_LOCK) {
            appendEventLocked(context, key, max, item);
        }
    }

    private static void appendEventLocked(Context context, String key, int max, String item) {
        final SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        final String existing = prefs.getString(key, "");
        final List<String> items = new ArrayList<>();
        if (!existing.isEmpty()) {
            for (String s : existing.split(";")) {
                if (!s.isEmpty()) items.add(s);
            }
        }
        items.add(item);
        while (items.size() > max) items.remove(0);
        prefs.edit().putString(key, String.join(";", items)).commit();
    }

    public static void registerWith(@NonNull FlutterEngine flutterEngine,
                                    @NonNull Context context) {
        final Context appContext = context.getApplicationContext();
        registerTrimCallbacks(appContext);
        final Handler main = new Handler(Looper.getMainLooper());
        new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(),
                ChannelNames.PROCESS_EXIT)
            .setMethodCallHandler((call, result) -> {
                if (!METHOD_CONSUME.equals(call.method)) {
                    result.notImplemented();
                    return;
                }
                final Number lookback = call.argument("lookbackMs");
                final long lookbackMs = lookback != null ? lookback.longValue() : 7L * 86400000L;
                // getHistoricalProcessExitReasons 是 binder IPC，读 trace 是磁盘 IO：不占主线程。
                EXECUTOR.execute(() -> {
                    try {
                        final Map<String, Object> out = consume(appContext, lookbackMs);
                        main.post(() -> result.success(out));
                    } catch (RuntimeException e) {
                        // 取证本身失败要让 Dart 记下来（PlatformException 进错误日志），不是吞掉。
                        main.post(() -> result.error("process_exit_failed", e.toString(), null));
                    }
                });
            });
    }

    private static synchronized void registerTrimCallbacks(Context appContext) {
        if (trimCallbacksRegistered) return;
        trimCallbacksRegistered = true;
        appContext.registerComponentCallbacks(new ComponentCallbacks2() {
            @Override
            public void onTrimMemory(int level) {
                recordTrim(appContext, level);
            }

            @Override
            public void onConfigurationChanged(@NonNull Configuration newConfig) {
            }

            @Override
            public void onLowMemory() {
                recordTrim(appContext, ComponentCallbacks2.TRIM_MEMORY_COMPLETE);
            }
        });
    }

    /** 追加一条 "level@timestamp@pid"，只留最近 {@link #MAX_TRIMS} 条。commit() 同步落盘：被杀前最后一条最有用。 */
    static void recordTrim(Context context, int level) {
        appendEvent(context, KEY_TRIMS, MAX_TRIMS,
                level + "@" + System.currentTimeMillis() + "@" + Process.myPid());
    }

    static Map<String, Object> consume(Context context, long lookbackMs) {
        final SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        final Map<String, Object> out = new HashMap<>();
        out.put("sdk", Build.VERSION.SDK_INT);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            out.put("reasons", readExitReasons(context, prefs, lookbackMs));
        }
        // 主线程的 recordTrim / recordUiVisibility 与这里都是「读—改—写」同一份 prefs：
        // 不加锁的话，consume 读完到写回之间落下的那条会被覆盖掉。
        synchronized (EVENTS_LOCK) {
            consumeEvents(prefs, out);
        }
        return out;
    }

    private static void consumeEvents(SharedPreferences prefs, Map<String, Object> out) {
        final List<Map<String, Object>> trims = new ArrayList<>();
        final String raw = prefs.getString(KEY_TRIMS, "");
        for (String s : raw.split(";")) {
            final String[] parts = s.split("@");
            if (parts.length != 3) continue;
            try {
                final Map<String, Object> t = new HashMap<>();
                t.put("level", Integer.parseInt(parts[0]));
                t.put("timestamp", Long.parseLong(parts[1]));
                t.put("pid", Integer.parseInt(parts[2]));
                trims.add(t);
            } catch (NumberFormatException ignored) {
                // 旧格式 / 损坏的一条：跳过，其余照常交出。
            }
        }
        out.put("trims", trims);
        // 可见性切换：交出全部，但本进程自己的留着——consume 在本进程第一次 onStart 之后才跑，
        // 删了它，本进程之后再死时就没有「最后一次可见」的记录了。
        final int myPid = Process.myPid();
        final List<Map<String, Object>> uiEvents = new ArrayList<>();
        final List<String> keep = new ArrayList<>();
        for (String s : prefs.getString(KEY_UI_EVENTS, "").split(";")) {
            final String[] parts = s.split("@");
            if (parts.length != 3) continue;
            try {
                final Map<String, Object> e = new HashMap<>();
                e.put("visible", "1".equals(parts[0]));
                e.put("timestamp", Long.parseLong(parts[1]));
                final int pid = Integer.parseInt(parts[2]);
                e.put("pid", pid);
                uiEvents.add(e);
                if (pid == myPid) keep.add(s);
            } catch (NumberFormatException ignored) {
                // 损坏的一条：跳过，其余照常交出。
            }
        }
        out.put("uiEvents", uiEvents);
        prefs.edit()
                .remove(KEY_TRIMS)
                .putString(KEY_UI_EVENTS, String.join(";", keep))
                .apply();
    }

    @RequiresApi(api = Build.VERSION_CODES.R)
    private static List<Map<String, Object>> readExitReasons(
            Context context, SharedPreferences prefs, long lookbackMs) {
        final List<Map<String, Object>> reasons = new ArrayList<>();
        final ActivityManager am = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
        if (am == null) return reasons;
        final List<ApplicationExitInfo> infos =
                am.getHistoricalProcessExitReasons(context.getPackageName(), 0, 16);
        final long cursor = Math.max(
                prefs.getLong(KEY_LAST_EXIT_TS, 0L),
                System.currentTimeMillis() - lookbackMs);
        long newest = prefs.getLong(KEY_LAST_EXIT_TS, 0L);
        final int myPid = Process.myPid();
        final File[] javaCrashFiles = JavaCrashCapture.crashDir(context).listFiles();
        final List<File> consumedJavaCrashes = new ArrayList<>();
        // 系统按时间倒序给出（最新在前）。
        for (ApplicationExitInfo info : infos) {
            newest = Math.max(newest, info.getTimestamp());
            // 先于游标过滤匹配：已汇报过 / 超出上限的那条 CRASH 的落盘记录也算消费掉，不留在目录里。
            final File javaCrash = info.getReason() == ApplicationExitInfo.REASON_CRASH
                    ? JavaCrashRecord.findMatch(javaCrashFiles, info.getPid(), info.getTimestamp())
                    : null;
            if (javaCrash != null) consumedJavaCrashes.add(javaCrash);
            if (info.getTimestamp() <= cursor || info.getPid() == myPid) continue;
            if (reasons.size() >= MAX_REASONS) continue;
            final Map<String, Object> r = new HashMap<>();
            r.put("reason", reasonName(info.getReason()));
            r.put("status", info.getStatus());
            r.put("description", info.getDescription());
            r.put("importance", info.getImportance());
            r.put("pssKb", info.getPss());
            r.put("rssKb", info.getRss());
            r.put("timestamp", info.getTimestamp());
            r.put("processName", info.getProcessName());
            r.put("pid", info.getPid());
            final int reason = info.getReason();
            if (reason == ApplicationExitInfo.REASON_CRASH_NATIVE
                    || reason == ApplicationExitInfo.REASON_ANR) {
                r.put("trace", readTraceSummary(info, reason == ApplicationExitInfo.REASON_ANR));
            } else if (javaCrash != null) {
                r.put("trace", readJavaCrashSummary(javaCrash));
            }
            reasons.add(r);
        }
        prefs.edit().putLong(KEY_LAST_EXIT_TS, newest).apply();
        for (File f : consumedJavaCrashes) {
            //noinspection ResultOfMethodCallIgnored
            f.delete();
        }
        return reasons;
    }

    /**
     * ANR trace 是文本：取主线程段 + Flutter 引擎线程段（{@link AnrTraceSummary}）。native crash 的 tombstone 在 API 31+ 是
     * protobuf：按 tombstone.proto 解出信号 / abort message / 崩溃线程完整栈（{@link
     * TombstoneSummary}）。解不开（读到的不是 proto，或被截断）时如实标明，再退回抽可打印串，
     * 好歹留下 abort message 与 .so 名。
     */
    @RequiresApi(api = Build.VERSION_CODES.R)
    private static String readTraceSummary(ApplicationExitInfo info, boolean text) {
        final int limit = text ? TRACE_READ_BYTES : TOMBSTONE_READ_BYTES;
        try (InputStream in = info.getTraceInputStream()) {
            if (in == null) return null;
            final ByteArrayOutputStream buf = new ByteArrayOutputStream();
            final byte[] chunk = new byte[8192];
            int n;
            while (buf.size() < limit && (n = in.read(chunk)) > 0) {
                buf.write(chunk, 0, Math.min(n, limit - buf.size()));
            }
            final byte[] bytes = buf.toByteArray();
            if (!text) {
                try {
                    return TombstoneSummary.summarize(bytes, TRACE_SUMMARY_CHARS);
                } catch (IllegalArgumentException e) {
                    return "tombstone unparsed (" + e.getMessage() + ", " + bytes.length
                            + " bytes):\n" + printableRuns(bytes, 6, TRACE_SUMMARY_CHARS);
                }
            }
            return AnrTraceSummary.summarize(
                    new String(bytes, StandardCharsets.UTF_8), TRACE_SUMMARY_CHARS);
        } catch (IOException | RuntimeException e) {
            return "trace unavailable: " + e;
        }
    }

    /** 读 {@link JavaCrashCapture} 落盘的 Java 崩溃记录，按 trace 摘要上限压缩。 */
    private static String readJavaCrashSummary(File file) {
        try (InputStream in = new FileInputStream(file)) {
            final ByteArrayOutputStream buf = new ByteArrayOutputStream();
            final byte[] chunk = new byte[8192];
            int n;
            while (buf.size() < JavaCrashRecord.MAX_FILE_BYTES && (n = in.read(chunk)) > 0) {
                buf.write(chunk, 0, Math.min(n, JavaCrashRecord.MAX_FILE_BYTES - buf.size()));
            }
            return JavaCrashRecord.summarize(
                    new String(buf.toByteArray(), StandardCharsets.UTF_8), TRACE_SUMMARY_CHARS);
        } catch (IOException | RuntimeException e) {
            return "java crash record unavailable: " + e;
        }
    }

    static String printableRuns(byte[] bytes, int minRun, int maxChars) {
        final StringBuilder out = new StringBuilder();
        final StringBuilder run = new StringBuilder();
        for (byte b : bytes) {
            final int c = b & 0xff;
            if (c >= 0x20 && c < 0x7f) {
                run.append((char) c);
                continue;
            }
            if (run.length() >= minRun) {
                if (out.length() > 0) out.append('\n');
                out.append(run);
                if (out.length() >= maxChars) break;
            }
            run.setLength(0);
        }
        if (run.length() >= minRun && out.length() < maxChars) {
            if (out.length() > 0) out.append('\n');
            out.append(run);
        }
        return out.length() > maxChars ? out.substring(0, maxChars) : out.toString();
    }

    /** 与 Dart 侧 {@code kSevereAndroidExitReasons} 的名字一致。 */
    @RequiresApi(api = Build.VERSION_CODES.R)
    static String reasonName(int reason) {
        switch (reason) {
            case ApplicationExitInfo.REASON_EXIT_SELF: return "EXIT_SELF";
            case ApplicationExitInfo.REASON_SIGNALED: return "SIGNALED";
            case ApplicationExitInfo.REASON_LOW_MEMORY: return "LOW_MEMORY";
            case ApplicationExitInfo.REASON_CRASH: return "CRASH";
            case ApplicationExitInfo.REASON_CRASH_NATIVE: return "CRASH_NATIVE";
            case ApplicationExitInfo.REASON_ANR: return "ANR";
            case ApplicationExitInfo.REASON_INITIALIZATION_FAILURE: return "INITIALIZATION_FAILURE";
            case ApplicationExitInfo.REASON_PERMISSION_CHANGE: return "PERMISSION_CHANGE";
            case ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE: return "EXCESSIVE_RESOURCE_USAGE";
            case ApplicationExitInfo.REASON_USER_REQUESTED: return "USER_REQUESTED";
            case ApplicationExitInfo.REASON_USER_STOPPED: return "USER_STOPPED";
            case ApplicationExitInfo.REASON_DEPENDENCY_DIED: return "DEPENDENCY_DIED";
            case ApplicationExitInfo.REASON_OTHER: return "OTHER";
            // 编译期常量（compileSdk 36），旧系统上不会出现这些值。
            case ApplicationExitInfo.REASON_FREEZER: return "FREEZER";
            case ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE: return "PACKAGE_STATE_CHANGE";
            case ApplicationExitInfo.REASON_PACKAGE_UPDATED: return "PACKAGE_UPDATED";
            default: return "UNKNOWN_" + reason;
        }
    }
}
