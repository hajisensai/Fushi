package app.fushi.reader;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

/**
 * Java / Kotlin 未捕获异常落盘记录的纯逻辑（不依赖 Android 类，JVM 单测直接跑）。
 *
 * <p>为什么要有：{@code ApplicationExitInfo} 对 {@code REASON_CRASH} 不给 trace
 * （{@code getTraceInputStream} 只对 native crash / ANR 有内容），所以 Java 层崩溃在退出报告里
 * 只剩「reason=CRASH description: crash」。{@link JavaCrashCapture} 在每个进程装一个链式
 * {@code UncaughtExceptionHandler}，崩溃时把异常写成一份小文件；下次启动
 * {@link ProcessExitChannel} 按 pid + 时间窗把文件匹配到那条 CRASH 记录，作为 trace 交给 Dart。
 *
 * <p>格式化写进预分配的 {@link Utf8Sink}，不拼 String：Java 堆 OOM 时 handler 里再大块分配
 * 很可能再抛 OOM，预分配缓冲保证至少写出异常类与顶部栈帧。
 */
final class JavaCrashRecord {
    /** 单份记录的字节上限。 */
    static final int MAX_FILE_BYTES = 64 * 1024;
    /** 目录里最多保留的记录份数（多余的按时间从旧到新删）。 */
    static final int MAX_FILES = 8;
    /** 每层 throwable 最多写的栈帧数。 */
    static final int MAX_FRAMES_PER_THROWABLE = 64;
    /** cause 链最多写几层（也防自引用环）。 */
    static final int MAX_CAUSE_DEPTH = 16;
    /** 记录时间最多晚于退出记录时间多少（同一台设备同一时钟，只留少量余量）。 */
    static final long MATCH_AFTER_EXIT_MS = 5_000L;
    /** 记录时间最多早于退出记录时间多少（原 handler 收尾后系统才记退出）。 */
    static final long MATCH_BEFORE_EXIT_MS = 60_000L;

    static final String FILE_PREFIX = "jcrash-";
    static final String FILE_SUFFIX = ".txt";
    static final String TRUNCATED_MARKER = "\n…[truncated]\n";

    private JavaCrashRecord() {
    }

    /** {@code jcrash-<epochMs>-<pid>-<进程名>.txt}；进程名只留文件名安全字符。 */
    static String fileName(String processName, int pid, long timestampMs) {
        final StringBuilder b = new StringBuilder(FILE_PREFIX)
                .append(timestampMs).append('-').append(pid).append('-');
        final String p = processName == null || processName.isEmpty() ? "unknown" : processName;
        for (int i = 0; i < p.length() && i < 80; i++) {
            final char c = p.charAt(i);
            final boolean safe = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                    || (c >= '0' && c <= '9') || c == '.' || c == '_';
            b.append(safe ? c : '_');
        }
        return b.append(FILE_SUFFIX).toString();
    }

    /** 从文件名解出 {@code {timestampMs, pid}}；不是本格式返回 null。 */
    static long[] parseFileName(String name) {
        if (name == null || !name.startsWith(FILE_PREFIX) || !name.endsWith(FILE_SUFFIX)) {
            return null;
        }
        final String body = name.substring(FILE_PREFIX.length(),
                name.length() - FILE_SUFFIX.length());
        final int a = body.indexOf('-');
        if (a <= 0) return null;
        final int b = body.indexOf('-', a + 1);
        if (b <= a + 1) return null;
        try {
            final long ts = Long.parseLong(body.substring(0, a));
            final long pid = Long.parseLong(body.substring(a + 1, b));
            if (ts <= 0 || pid <= 0 || pid > Integer.MAX_VALUE) return null;
            return new long[] {ts, pid};
        } catch (NumberFormatException e) {
            return null;
        }
    }

    /** 一份记录是否属于某条退出记录：同 pid，且记录时间落在退出时间附近的窗口里（防 pid 复用）。 */
    static boolean matchesExit(int recordPid, long recordTsMs, int exitPid, long exitTsMs) {
        return recordPid == exitPid
                && recordTsMs <= exitTsMs + MATCH_AFTER_EXIT_MS
                && recordTsMs >= exitTsMs - MATCH_BEFORE_EXIT_MS;
    }

    /** 在 [files] 里找与退出记录匹配的那份；多份都匹配时取时间最接近退出时间的。没有返回 null。 */
    static File findMatch(File[] files, int exitPid, long exitTsMs) {
        if (files == null) return null;
        File best = null;
        long bestDistance = Long.MAX_VALUE;
        for (File f : files) {
            final long[] parsed = parseFileName(f.getName());
            if (parsed == null) continue;
            if (!matchesExit((int) parsed[1], parsed[0], exitPid, exitTsMs)) continue;
            final long distance = Math.abs(exitTsMs - parsed[0]);
            if (distance < bestDistance) {
                best = f;
                bestDistance = distance;
            }
        }
        return best;
    }

    /** 只留最新的 [keep] 份记录，返回删掉的份数。非本格式的文件不动。 */
    static int prune(File dir, int keep) {
        final File[] files = dir.listFiles();
        if (files == null) return 0;
        final List<File> records = new ArrayList<>();
        for (File f : files) {
            if (parseFileName(f.getName()) != null) records.add(f);
        }
        if (records.size() <= keep) return 0;
        records.sort(Comparator.comparingLong((File f) -> parseFileName(f.getName())[0]));
        int deleted = 0;
        for (int i = 0; i < records.size() - keep; i++) {
            if (records.get(i).delete()) deleted++;
        }
        return deleted;
    }

    /**
     * 退出报告里的 trace 字符上限比文件小：放得下就原样；放不下保留开头（最外层异常与顶部帧），
     * 再接最后一个 {@code Caused by:} 段（根因异常通常在最里层）。
     */
    static String summarize(String text, int maxChars) {
        if (text == null || text.length() <= maxChars) return text;
        final String gap = "\n…\n";
        final int lastCause = text.lastIndexOf("\nCaused by: ");
        final int head = maxChars / 2;
        if (lastCause <= head) {
            return text.substring(0, maxChars);
        }
        final int tailLen = maxChars - head - gap.length();
        final int tailEnd = Math.min(text.length(), lastCause + 1 + tailLen);
        return text.substring(0, head) + gap + text.substring(lastCause + 1, tailEnd);
    }

    /**
     * 把一次未捕获异常格式化进 [out]（先 reset，最后 finish）。写的顺序就是重要性顺序：抬头 →
     * 异常类与 message → 栈帧 → cause 链；缓冲满了就截断并标记，已写的内容不丢。
     */
    static void format(Utf8Sink out, Throwable error, String threadName, long threadId,
                       int pid, String processName, long timestampMs) {
        out.reset();
        out.append("java uncaught exception\nprocess=").append(processName)
                .append(" pid=").append(pid)
                .append(" thread=").append(threadName).append(" (id=").append(threadId)
                .append(")\nat=").append(timestampMs).append('\n');
        final Throwable[] seen = new Throwable[MAX_CAUSE_DEPTH];
        Throwable current = error;
        StackTraceElement[] enclosing = null;
        int depth = 0;
        while (current != null && depth < MAX_CAUSE_DEPTH && !out.isFull()) {
            for (int i = 0; i < depth; i++) {
                if (seen[i] == current) {
                    out.append("[CIRCULAR REFERENCE]\n");
                    out.finish();
                    return;
                }
            }
            seen[depth] = current;
            if (depth > 0) out.append("Caused by: ");
            out.append(current.getClass().getName());
            final String message = safeMessage(current);
            if (message != null) out.append(": ").append(message);
            out.append('\n');
            final StackTraceElement[] frames = current.getStackTrace();
            final int common = enclosing == null ? 0 : framesInCommon(frames, enclosing);
            final int unique = frames.length - common;
            final int shown = Math.min(unique, MAX_FRAMES_PER_THROWABLE);
            for (int i = 0; i < shown; i++) {
                appendFrame(out, frames[i]);
            }
            if (unique > shown) {
                out.append("\t... ").append(unique - shown).append(" frames omitted\n");
            }
            if (common > 0) out.append("\t... ").append(common).append(" more\n");
            enclosing = frames;
            current = current.getCause();
            depth++;
        }
        if (current != null && !out.isFull()) out.append("[cause chain truncated]\n");
        out.finish();
    }

    /** getMessage 可被子类覆写成任意代码：它自己再抛就只记个标记，不让格式化中断。 */
    private static String safeMessage(Throwable t) {
        try {
            return t.getMessage();
        } catch (RuntimeException e) {
            return "<getMessage threw " + e.getClass().getName() + ">";
        }
    }

    /** 与 {@code Throwable.printStackTrace} 相同：从尾部数与外层栈相同的帧数。 */
    static int framesInCommon(StackTraceElement[] frames, StackTraceElement[] enclosing) {
        int m = frames.length - 1;
        int n = enclosing.length - 1;
        int common = 0;
        while (m >= 0 && n >= 0 && frames[m].equals(enclosing[n])) {
            m--;
            n--;
            common++;
        }
        return common;
    }

    /** 逐段写帧，不调 {@code StackTraceElement.toString()}（那会分配新 String）。 */
    private static void appendFrame(Utf8Sink out, StackTraceElement f) {
        out.append("\tat ").append(f.getClassName()).append('.').append(f.getMethodName())
                .append('(');
        if (f.isNativeMethod()) {
            out.append("Native Method");
        } else if (f.getFileName() == null) {
            out.append("Unknown Source");
        } else {
            out.append(f.getFileName());
            if (f.getLineNumber() >= 0) out.append(':').append(f.getLineNumber());
        }
        out.append(")\n");
    }

    /**
     * 链式默认未捕获异常处理器：先同步落盘一份记录，再<b>一定</b>交给原处理器。
     *
     * <p>落盘是尽力而为的取证：它自己的任何失败（目录不可写、磁盘满、OOM 里再 OOM）都只在
     * 这一层截住，不能改变崩溃行为——异常照样交给原处理器（Android 的 RuntimeInit 处理器负责
     * 打 logcat、弹「应用已停止」、杀进程），这里不吞原异常、不自己 kill。
     */
    static final class ChainedHandler implements Thread.UncaughtExceptionHandler {
        private final File dir;
        private final String processName;
        private final int pid;
        private final Thread.UncaughtExceptionHandler previous;
        /** 装处理器时预分配；OOM 时不必再分配 64KB。 */
        private final Utf8Sink sink;

        ChainedHandler(File dir, String processName, int pid,
                       Thread.UncaughtExceptionHandler previous) {
            this.dir = dir;
            this.processName = processName;
            this.pid = pid;
            this.previous = previous;
            this.sink = new Utf8Sink(MAX_FILE_BYTES);
        }

        Thread.UncaughtExceptionHandler previous() {
            return previous;
        }

        @Override
        public void uncaughtException(Thread thread, Throwable error) {
            try {
                record(thread, error, System.currentTimeMillis());
            } catch (Throwable recordFailure) {
                // 取证失败只能截在这里：再往外抛会顶掉原异常、跳过原处理器。
            }
            if (previous != null) {
                previous.uncaughtException(thread, error);
            } else {
                // 没有原默认处理器时 JVM 的行为就是 ThreadGroup 打到 stderr（不能回调
                // ThreadGroup.uncaughtException：它会再查默认处理器，也就是我们自己）。
                System.err.print("Exception in thread \"" + thread.getName() + "\" ");
                error.printStackTrace(System.err);
            }
        }

        /** 返回写出的文件；多线程同时崩溃时串行写，共用同一块缓冲。 */
        File record(Thread thread, Throwable error, long nowMs) throws IOException {
            synchronized (sink) {
                try {
                    format(sink, error, thread.getName(), thread.getId(), pid, processName, nowMs);
                } catch (Throwable formatFailure) {
                    // 已写进缓冲的抬头 / 异常类 / 顶部帧照样落盘，只标明格式化中途失败。
                    sink.append("\n[format aborted: ")
                            .append(formatFailure.getClass().getName()).append("]\n");
                    sink.finish();
                }
                final File file = new File(dir, fileName(processName, pid, nowMs));
                try (FileOutputStream out = new FileOutputStream(file)) {
                    out.write(sink.buffer(), 0, sink.length());
                    out.getFD().sync();
                }
                return file;
            }
        }
    }

    /**
     * 固定容量的 UTF-8 字节缓冲：构造时一次分配，之后的 append 不再分配堆内存。末尾预留
     * {@link #TRUNCATED_MARKER} 的位置，写满就截断，{@link #finish()} 时补上标记。
     */
    static final class Utf8Sink {
        private static final byte[] MARKER = TRUNCATED_MARKER.getBytes(StandardCharsets.UTF_8);
        private final byte[] buf;
        private final byte[] digits = new byte[20];
        private final int limit;
        private int len;
        private boolean truncated;
        private boolean markerWritten;

        Utf8Sink(int capacity) {
            if (capacity <= MARKER.length) {
                throw new IllegalArgumentException("capacity too small: " + capacity);
            }
            buf = new byte[capacity];
            limit = capacity - MARKER.length;
        }

        void reset() {
            len = 0;
            truncated = false;
            markerWritten = false;
        }

        boolean isFull() {
            return truncated;
        }

        int length() {
            return len;
        }

        byte[] buffer() {
            return buf;
        }

        /** 截断过就补上标记（只补一次）；返回有效字节数。 */
        int finish() {
            if (truncated && !markerWritten) {
                System.arraycopy(MARKER, 0, buf, len, MARKER.length);
                len += MARKER.length;
                markerWritten = true;
            }
            return len;
        }

        Utf8Sink append(CharSequence s) {
            if (s == null) s = "null";
            final int n = s.length();
            for (int i = 0; i < n && !truncated; i++) {
                final char c = s.charAt(i);
                if (Character.isHighSurrogate(c) && i + 1 < n
                        && Character.isLowSurrogate(s.charAt(i + 1))) {
                    final int cp = Character.toCodePoint(c, s.charAt(i + 1));
                    if (!room(4)) return this;
                    buf[len++] = (byte) (0xF0 | (cp >> 18));
                    buf[len++] = (byte) (0x80 | ((cp >> 12) & 0x3F));
                    buf[len++] = (byte) (0x80 | ((cp >> 6) & 0x3F));
                    buf[len++] = (byte) (0x80 | (cp & 0x3F));
                    i++;
                } else if (Character.isSurrogate(c)) {
                    putAscii('?');
                } else {
                    putChar(c);
                }
            }
            return this;
        }

        Utf8Sink append(char c) {
            if (!truncated) {
                if (Character.isSurrogate(c)) putAscii('?');
                else putChar(c);
            }
            return this;
        }

        Utf8Sink append(long v) {
            if (truncated) return this;
            if (v == 0) {
                putAscii('0');
                return this;
            }
            final boolean negative = v < 0;
            int n = 0;
            while (v != 0) {
                final int d = (int) (v % 10);
                digits[n++] = (byte) ('0' + (negative ? -d : d));
                v /= 10;
            }
            if (negative) putAscii('-');
            while (n > 0 && !truncated) putAscii((char) digits[--n]);
            return this;
        }

        private void putChar(char c) {
            if (c < 0x80) {
                putAscii(c);
            } else if (c < 0x800) {
                if (!room(2)) return;
                buf[len++] = (byte) (0xC0 | (c >> 6));
                buf[len++] = (byte) (0x80 | (c & 0x3F));
            } else {
                if (!room(3)) return;
                buf[len++] = (byte) (0xE0 | (c >> 12));
                buf[len++] = (byte) (0x80 | ((c >> 6) & 0x3F));
                buf[len++] = (byte) (0x80 | (c & 0x3F));
            }
        }

        private void putAscii(char c) {
            if (!room(1)) return;
            buf[len++] = (byte) c;
        }

        private boolean room(int bytes) {
            if (len + bytes <= limit) return true;
            truncated = true;
            return false;
        }
    }
}
