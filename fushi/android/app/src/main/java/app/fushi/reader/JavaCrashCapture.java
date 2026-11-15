package app.fushi.reader;

import android.app.Application;
import android.content.Context;
import android.os.Build;
import android.os.Process;

import androidx.annotation.NonNull;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

/**
 * 每个进程（主进程、{@code :popup}、{@code :second_screen}、{@code :network_challenge}…）在
 * {@link FushiApplication#onCreate} 最早处装链式未捕获异常处理器，Java 层崩溃时把异常类型 +
 * 完整 cause 链栈落到 {@link #crashDir}；{@link ProcessExitChannel} 下次启动按 pid + 时间窗并入
 * 对应的 {@code REASON_CRASH} 退出记录。格式化 / 匹配逻辑在 {@link JavaCrashRecord}（JVM 单测）。
 */
final class JavaCrashCapture {
    private static final String DIR_NAME = "java_crashes";
    private static boolean installed;

    private JavaCrashCapture() {
    }

    /** 所有进程共用的落盘目录（应用私有、不进备份）。 */
    static File crashDir(@NonNull Context context) {
        return new File(context.getNoBackupFilesDir(), DIR_NAME);
    }

    static synchronized void install(@NonNull Application app) {
        if (installed) return;
        installed = true;
        final File dir = crashDir(app);
        // 目录建不出来时处理器照装：写失败由处理器自己截住，原处理器照常被调用。
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        JavaCrashRecord.prune(dir, JavaCrashRecord.MAX_FILES);
        final Thread.UncaughtExceptionHandler previous = Thread.getDefaultUncaughtExceptionHandler();
        if (previous instanceof JavaCrashRecord.ChainedHandler) return;
        Thread.setDefaultUncaughtExceptionHandler(new JavaCrashRecord.ChainedHandler(
                dir, currentProcessName(app), Process.myPid(), previous));
    }

    /** 当前进程名（主进程 = 包名，其余带 {@code :popup} 之类的后缀）。 */
    static String currentProcessName(@NonNull Context context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            final String name = Application.getProcessName();
            if (name != null && !name.isEmpty()) return name;
        }
        // API 24–27：/proc/self/cmdline 第一个 NUL 之前就是进程名。
        try (FileInputStream in = new FileInputStream("/proc/self/cmdline")) {
            final byte[] buf = new byte[256];
            final int n = in.read(buf);
            int end = 0;
            while (end < n && buf[end] != 0) end++;
            if (end > 0) return new String(buf, 0, end, StandardCharsets.UTF_8);
        } catch (IOException e) {
            // 读不到就退回包名：记录里进程名只用于展示，匹配靠 pid + 时间。
        }
        return context.getPackageName();
    }
}
