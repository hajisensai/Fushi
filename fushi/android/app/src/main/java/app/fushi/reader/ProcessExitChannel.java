package app.fushi.reader;

import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.content.ComponentCallbacks2;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.res.Configuration;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;

import androidx.annotation.NonNull;
import androidx.annotation.RequiresApi;

import java.io.ByteArrayOutputStream;
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
 * 还能取 trace。启动时 Dart 调一次 {@code consumeExitReports}，只取上次汇报之后的新记录
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
    /** 读 trace 的字节上限（tombstone proto / ANR 文本都只取开头）。 */
    private static final int TRACE_READ_BYTES = 64 * 1024;
    /** 回传给 Dart 的 trace 摘要字符上限。 */
    private static final int TRACE_SUMMARY_CHARS = 3000;

    private static boolean trimCallbacksRegistered;
    private static final ExecutorService EXECUTOR = Executors.newSingleThreadExecutor();

    private ProcessExitChannel() {
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
        final SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        final String existing = prefs.getString(KEY_TRIMS, "");
        final List<String> items = new ArrayList<>();
        if (!existing.isEmpty()) {
            for (String s : existing.split(";")) {
                if (!s.isEmpty()) items.add(s);
            }
        }
        items.add(level + "@" + System.currentTimeMillis() + "@" + Process.myPid());
        while (items.size() > MAX_TRIMS) items.remove(0);
        prefs.edit().putString(KEY_TRIMS, String.join(";", items)).commit();
    }

    static Map<String, Object> consume(Context context, long lookbackMs) {
        final SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        final Map<String, Object> out = new HashMap<>();
        out.put("sdk", Build.VERSION.SDK_INT);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            out.put("reasons", readExitReasons(context, prefs, lookbackMs));
        }
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
        prefs.edit().remove(KEY_TRIMS).apply();
        return out;
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
        // 系统按时间倒序给出（最新在前）。
        for (ApplicationExitInfo info : infos) {
            newest = Math.max(newest, info.getTimestamp());
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
            }
            reasons.add(r);
        }
        prefs.edit().putLong(KEY_LAST_EXIT_TS, newest).apply();
        return reasons;
    }

    /**
     * ANR trace 是文本：从 "main" 线程段开始取一截。native crash 的 tombstone 在 API 31+ 是
     * protobuf：抽出其中长度 ≥ 6 的可打印 ASCII 串（信号、abort message、栈帧里的 .so 名与
     * 符号都在里面），截到上限。
     */
    @RequiresApi(api = Build.VERSION_CODES.R)
    private static String readTraceSummary(ApplicationExitInfo info, boolean text) {
        try (InputStream in = info.getTraceInputStream()) {
            if (in == null) return null;
            final ByteArrayOutputStream buf = new ByteArrayOutputStream();
            final byte[] chunk = new byte[8192];
            int n;
            while (buf.size() < TRACE_READ_BYTES && (n = in.read(chunk)) > 0) {
                buf.write(chunk, 0, Math.min(n, TRACE_READ_BYTES - buf.size()));
            }
            final byte[] bytes = buf.toByteArray();
            if (text) {
                final String s = new String(bytes, StandardCharsets.UTF_8);
                final int main = s.indexOf("\"main\"");
                final String from = main >= 0 ? s.substring(main) : s;
                return from.length() > TRACE_SUMMARY_CHARS
                        ? from.substring(0, TRACE_SUMMARY_CHARS) : from;
            }
            return printableRuns(bytes, 6, TRACE_SUMMARY_CHARS);
        } catch (IOException | RuntimeException e) {
            return "trace unavailable: " + e;
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
