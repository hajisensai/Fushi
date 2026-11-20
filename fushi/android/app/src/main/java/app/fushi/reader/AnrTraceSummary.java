package app.fushi.reader;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * ANR 的 {@code ApplicationExitInfo#getTraceInputStream()} 是 ART 的文本线程转储（各线程一段，
 * 以 {@code "线程名" ...} 开头、空行分隔）。这里把它压成退出报告里那一小段 trace 摘要。
 *
 * <p>为什么不再「从 "main" 起截前 N 字」：Flutter 的 ANR 多半是主线程同步等引擎线程
 * （{@code FlutterJNI.nativeSurfaceDestroyed} 等 raster 线程拆 surface、{@code nativeDispatch*}
 * 等 ui 线程），真正卡住的是 {@code 1.raster} / {@code 1.ui} 那一段；旧做法只留主线程开头 3400 字
 * （#TQVbIm9NrT 那份报告的主线程段连 Java 帧都没截完），被等的线程一帧都没有，定位不了。
 *
 * <p>现在：主线程段 + 全部 Flutter 引擎线程段（{@code N.raster} / {@code N.ui} / {@code N.io}，
 * 多引擎时有多组），去掉 {@code | group=...} 之类的状态行、BuildId 与安装路径噪音，每段限帧数。
 *
 * <p>纯 JVM 代码（不碰 android.*），单测直接喂文本。
 */
final class AnrTraceSummary {
    /** 主线程段最多保留几行栈帧（native + Java）。 */
    static final int MAX_MAIN_FRAMES = 24;
    /** 每条引擎线程段最多保留几行栈帧。 */
    static final int MAX_ENGINE_FRAMES = 14;

    private static final Pattern ENGINE_THREAD = Pattern.compile("^\\d+\\.(raster|ui|io)$");
    private static final Pattern BUILD_ID = Pattern.compile(" \\(BuildId: [0-9a-fA-F]+\\)");
    private static final Pattern APK_PATH = Pattern.compile("/data/app/\\S*/([^/\\s]+\\.apk)");

    private AnrTraceSummary() {}

    /** 一条线程段：名字 + 原始行（含首行）。 */
    static final class ThreadBlock {
        final String name;
        final List<String> lines = new ArrayList<>();

        ThreadBlock(String name) {
            this.name = name;
        }
    }

    /** 拆出所有以 {@code "名字"} 开头的线程段。 */
    static List<ThreadBlock> parse(String trace) {
        final List<ThreadBlock> blocks = new ArrayList<>();
        ThreadBlock cur = null;
        for (String raw : trace.split("\r?\n", -1)) {
            if (cur == null) {
                if (raw.startsWith("\"")) {
                    final int end = raw.indexOf('"', 1);
                    if (end > 0) {
                        cur = new ThreadBlock(raw.substring(1, end));
                        cur.lines.add(raw);
                    }
                }
                continue;
            }
            if (raw.trim().isEmpty()) {
                blocks.add(cur);
                cur = null;
                continue;
            }
            cur.lines.add(raw);
        }
        if (cur != null) blocks.add(cur);
        return blocks;
    }

    /**
     * 压缩 ANR 文本 trace：主线程段在前，随后各引擎线程段；总长不超过 {@code maxChars}。
     * 找不到任何线程段（格式不认识）时退回原文开头。
     */
    static String summarize(String trace, int maxChars) {
        final List<ThreadBlock> blocks = parse(trace);
        ThreadBlock main = null;
        final List<ThreadBlock> engine = new ArrayList<>();
        for (ThreadBlock b : blocks) {
            if (main == null && "main".equals(b.name)) {
                main = b;
            } else if (ENGINE_THREAD.matcher(b.name).matches()) {
                engine.add(b);
            }
        }
        if (main == null && engine.isEmpty()) {
            return trace.length() > maxChars ? trace.substring(0, maxChars) : trace;
        }
        final StringBuilder out = new StringBuilder();
        if (main != null) appendBlock(out, main, MAX_MAIN_FRAMES);
        for (ThreadBlock b : engine) {
            if (out.length() > 0) out.append('\n');
            appendBlock(out, b, MAX_ENGINE_FRAMES);
        }
        if (main != null && engine.isEmpty()) {
            out.append("\n(no Flutter engine thread in trace)\n");
        }
        return out.length() > maxChars ? out.substring(0, maxChars) : out.toString();
    }

    private static void appendBlock(StringBuilder out, ThreadBlock b, int maxFrames) {
        out.append(b.lines.get(0)).append('\n');
        int kept = 0;
        int dropped = 0;
        for (int i = 1; i < b.lines.size(); i++) {
            final String line = b.lines.get(i);
            if (line.trim().startsWith("|")) continue;
            if (kept >= maxFrames) {
                dropped++;
                continue;
            }
            out.append(compact(line)).append('\n');
            kept++;
        }
        if (dropped > 0) out.append("  ... (+").append(dropped).append(" frames)\n");
    }

    /** 去掉 BuildId 与安装路径里的随机目录名，只留 apk / so 文件名。 */
    static String compact(String line) {
        String s = BUILD_ID.matcher(line).replaceAll("");
        final Matcher m = APK_PATH.matcher(s);
        s = m.replaceAll("$1");
        return s;
    }
}
