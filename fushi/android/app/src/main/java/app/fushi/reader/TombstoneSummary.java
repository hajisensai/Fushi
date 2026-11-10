package app.fushi.reader;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * API 31+ {@code ApplicationExitInfo#getTraceInputStream()} 给 native crash 的是 tombstone
 * protobuf（AOSP {@code system/core/debuggerd/proto/tombstone.proto}）。这里只解出定位崩溃要用的
 * 那几样，排成跟文本 tombstone 一样的读法：信号 / abort message / cause、**崩溃线程**的完整栈，
 * 再有余量带上主线程的栈。
 *
 * <p>为什么不再「抽可打印串」：线程表是 {@code map<uint32, Thread>}，序列化顺序与崩溃线程无关，
 * 一百多条线程里崩溃线程常排在后面；旧做法只取前 64 KB、截 3000 字，#MdVKlfPOWD 那份报告里只剩
 * hwuiTask1 / mali-compiler / CookieMonster 几条无关线程的帧，abort message 之外什么都定位不了。
 *
 * <p>纯 JVM 代码（不碰 android.*），单测直接喂字节。格式不对抛 {@link IllegalArgumentException}。
 */
final class TombstoneSummary {
    /** 崩溃线程最多列几帧。 */
    static final int MAX_CRASH_FRAMES = 40;
    /** 主线程（不是崩溃线程时）最多列几帧。 */
    static final int MAX_MAIN_FRAMES = 12;

    private TombstoneSummary() {}

    static final class Frame {
        long relPc;
        String functionName = "";
        long functionOffset;
        String fileName = "";
        long fileMapOffset;
        String buildId = "";
    }

    static final class ThreadInfo {
        int id;
        String name = "";
        final List<Frame> frames = new ArrayList<>();
    }

    /** 解析 + 排版；结果不超过 [maxChars]（按整行截，截掉的行数写在末尾）。 */
    static String summarize(byte[] bytes, int maxChars) {
        final Reader r = new Reader(bytes, 0, bytes.length);
        int pid = 0;
        int tid = 0;
        long uptime = -1;
        String abort = "";
        String signal = "";
        final List<String> causes = new ArrayList<>();
        final List<ThreadInfo> threads = new ArrayList<>();
        while (r.more()) {
            final long tag = r.varint();
            final int field = (int) (tag >>> 3);
            final int wire = (int) (tag & 7);
            switch (field) {
                case 5: pid = (int) r.varint(); break;
                case 6: tid = (int) r.varint(); break;
                case 20: uptime = r.varint(); break;
                case 10: signal = parseSignal(r.sub()); break;
                case 14: abort = r.string(); break;
                case 15: {
                    final String cause = parseCause(r.sub());
                    if (!cause.isEmpty()) causes.add(cause);
                    break;
                }
                case 16: {
                    final ThreadInfo t = parseThreadEntry(r.sub());
                    if (t != null) threads.add(t);
                    break;
                }
                default: r.skip(wire);
            }
        }
        ThreadInfo crashing = null;
        ThreadInfo main = null;
        for (ThreadInfo t : threads) {
            if (t.id == tid) crashing = t;
            if (t.id == pid) main = t;
        }
        final List<String> lines = new ArrayList<>();
        if (!signal.isEmpty()) lines.add(signal);
        if (!abort.isEmpty()) lines.add("Abort message: '" + abort + "'");
        for (String c : causes) lines.add("Cause: " + c);
        lines.add(String.format(Locale.ROOT, "pid=%d tid=%d threads=%d%s", pid, tid,
                threads.size(), uptime >= 0 ? " uptime=" + uptime + "s" : ""));
        if (crashing == null) {
            lines.add("crashing thread " + tid + " not in tombstone");
        } else {
            appendThread(lines, "crashing thread", crashing, MAX_CRASH_FRAMES);
        }
        if (main != null && main != crashing) {
            appendThread(lines, "main thread", main, MAX_MAIN_FRAMES);
        }
        return fit(lines, maxChars);
    }

    private static void appendThread(List<String> lines, String label, ThreadInfo t, int max) {
        lines.add(label + " \"" + t.name + "\" (tid " + t.id + "):");
        final int n = Math.min(max, t.frames.size());
        for (int i = 0; i < n; i++) lines.add(formatFrame(i, t.frames.get(i)));
        if (t.frames.size() > n) lines.add("  … " + (t.frames.size() - n) + " more frames");
    }

    /**
     * 跟 debuggerd 文本格式一致：{@code #00 pc 000000000005823c  libc.so (syscall+28) (BuildId: …)}。
     * apk 内未解压的 so 带 {@code (offset 0x…)}，拿它和 BuildId 在本地对符号。安装目录里的随机
     * 段（{@code ~~xxxx==/app.fushi.reader-xxxx==}）只占篇幅，折掉。
     */
    static String formatFrame(int index, Frame f) {
        final StringBuilder b = new StringBuilder();
        b.append(String.format(Locale.ROOT, "  #%02d pc %08x  %s", index, f.relPc,
                shortPath(f.fileName)));
        if (f.fileMapOffset != 0) b.append(String.format(Locale.ROOT, " (offset 0x%x)", f.fileMapOffset));
        if (!f.functionName.isEmpty()) {
            b.append(" (").append(f.functionName).append('+').append(f.functionOffset).append(')');
        }
        if (!f.buildId.isEmpty()) b.append(" (BuildId: ").append(f.buildId).append(')');
        return b.toString();
    }

    static String shortPath(String path) {
        final int apk = path.indexOf("/base.apk");
        if (path.startsWith("/data/app/") && apk >= 0) return path.substring(apk + 1);
        return path;
    }

    private static String fit(List<String> lines, int maxChars) {
        final StringBuilder out = new StringBuilder();
        int i = 0;
        for (; i < lines.size(); i++) {
            final String line = lines.get(i);
            if (out.length() + line.length() + 1 > maxChars) break;
            if (out.length() > 0) out.append('\n');
            out.append(line);
        }
        if (i < lines.size()) out.append("\n…[").append(lines.size() - i).append(" lines cut]");
        return out.toString();
    }

    private static String parseSignal(Reader r) {
        long number = 0;
        String name = "";
        long code = 0;
        String codeName = "";
        boolean hasFault = false;
        long fault = 0;
        while (r.more()) {
            final long tag = r.varint();
            switch ((int) (tag >>> 3)) {
                case 1: number = r.varint(); break;
                case 2: name = r.string(); break;
                case 3: code = r.varint(); break;
                case 4: codeName = r.string(); break;
                case 8: hasFault = r.varint() != 0; break;
                case 9: fault = r.varint(); break;
                default: r.skip((int) (tag & 7));
            }
        }
        return String.format(Locale.ROOT, "signal %d (%s), code %d (%s), fault addr %s",
                (int) number, name, (int) code, codeName,
                hasFault ? String.format(Locale.ROOT, "0x%x", fault) : "--------");
    }

    private static String parseCause(Reader r) {
        String text = "";
        while (r.more()) {
            final long tag = r.varint();
            if ((tag >>> 3) == 1) text = r.string();
            else r.skip((int) (tag & 7));
        }
        return text;
    }

    /** map 条目：key = 1（tid），value = 2（Thread）。 */
    private static ThreadInfo parseThreadEntry(Reader r) {
        ThreadInfo t = null;
        while (r.more()) {
            final long tag = r.varint();
            if ((tag >>> 3) == 2) t = parseThread(r.sub());
            else r.skip((int) (tag & 7));
        }
        return t;
    }

    private static ThreadInfo parseThread(Reader r) {
        final ThreadInfo t = new ThreadInfo();
        while (r.more()) {
            final long tag = r.varint();
            switch ((int) (tag >>> 3)) {
                case 1: t.id = (int) r.varint(); break;
                case 2: t.name = r.string(); break;
                case 4: t.frames.add(parseFrame(r.sub())); break;
                default: r.skip((int) (tag & 7));
            }
        }
        return t;
    }

    private static Frame parseFrame(Reader r) {
        final Frame f = new Frame();
        while (r.more()) {
            final long tag = r.varint();
            switch ((int) (tag >>> 3)) {
                case 1: f.relPc = r.varint(); break;
                case 4: f.functionName = r.string(); break;
                case 5: f.functionOffset = r.varint(); break;
                case 6: f.fileName = r.string(); break;
                case 7: f.fileMapOffset = r.varint(); break;
                case 8: f.buildId = r.string(); break;
                default: r.skip((int) (tag & 7));
            }
        }
        return f;
    }

    /** protobuf 线格式的最小读取器（varint / fixed64 / length-delimited / fixed32）。 */
    static final class Reader {
        private final byte[] buf;
        private int pos;
        private final int end;

        Reader(byte[] buf, int pos, int end) {
            this.buf = buf;
            this.pos = pos;
            this.end = end;
        }

        boolean more() {
            return pos < end;
        }

        long varint() {
            long result = 0;
            for (int shift = 0; shift < 64; shift += 7) {
                if (pos >= end) throw new IllegalArgumentException("truncated varint");
                final int b = buf[pos++] & 0xff;
                result |= (long) (b & 0x7f) << shift;
                if ((b & 0x80) == 0) return result;
            }
            throw new IllegalArgumentException("varint too long");
        }

        private int length() {
            final long len = varint();
            if (len < 0 || len > end - pos) throw new IllegalArgumentException("bad length " + len);
            return (int) len;
        }

        Reader sub() {
            final int len = length();
            final Reader r = new Reader(buf, pos, pos + len);
            pos += len;
            return r;
        }

        String string() {
            final int len = length();
            final String s = new String(buf, pos, len, StandardCharsets.UTF_8);
            pos += len;
            return s;
        }

        void skip(int wire) {
            switch (wire) {
                case 0: varint(); break;
                case 1: advance(8); break;
                case 2: advance(length()); break;
                case 5: advance(4); break;
                default: throw new IllegalArgumentException("unsupported wire type " + wire);
            }
        }

        private void advance(int n) {
            if (n > end - pos) throw new IllegalArgumentException("truncated field");
            pos += n;
        }
    }
}
