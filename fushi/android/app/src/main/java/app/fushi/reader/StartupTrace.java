package app.fushi.reader;

import android.os.Process;
import android.os.SystemClock;

import androidx.annotation.NonNull;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import app.fushi.reader.constants.ChannelNames;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;

/**
 * 冷启动原生段计时：进程创建到 Dart {@code main()} 之前，Application / Activity / 引擎
 * 装配各花了多久。Dart 侧（{@code lib/src/startup/startup_timeline.dart}）在首页画出来
 * 之后经 {@link ChannelNames#STARTUP_TRACE} 取一次，和它自己的阶段拼成一行写进诊断日志。
 *
 * <p>时间一律是 Unix epoch 微秒（墙钟），这样才能和 Dart 的 {@code DateTime.now()} 对上。
 * 只有主进程的第一个 Activity 引擎会来取；{@code :popup} 等进程里记了也没人读，开销是
 * 几次 {@code System.currentTimeMillis()}。
 */
public final class StartupTrace {
    private StartupTrace() {}

    private static final List<Object[]> marks = new ArrayList<>();

    /** 记「{@code name} 这一段刚结束」。任何线程可调。 */
    public static void mark(@NonNull String name) {
        final long nowMicros = System.currentTimeMillis() * 1000L;
        synchronized (marks) {
            marks.add(new Object[] {name, nowMicros});
        }
    }

    /** 进程创建时刻（epoch 微秒）：进程启动的开机计时换算到墙钟。 */
    private static long processStartMicros() {
        final long sinceStartMs =
                SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime();
        return (System.currentTimeMillis() - sinceStartMs) * 1000L;
    }

    /** 在主引擎上挂 {@code get}：返回 {@code {processStartMicros, marks: [[name, micros], …]}}。 */
    public static void registerWith(@NonNull BinaryMessenger messenger) {
        new MethodChannel(messenger, ChannelNames.STARTUP_TRACE)
                .setMethodCallHandler(
                        (call, result) -> {
                            if (!"get".equals(call.method)) {
                                result.notImplemented();
                                return;
                            }
                            final List<Object> out = new ArrayList<>();
                            synchronized (marks) {
                                for (Object[] mark : marks) {
                                    out.add(Arrays.asList(mark));
                                }
                            }
                            final Map<String, Object> payload = new HashMap<>();
                            payload.put("processStartMicros", processStartMicros());
                            payload.put("marks", out);
                            result.success(payload);
                        });
    }
}
