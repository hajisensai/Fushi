package app.fushi.reader;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

/**
 * #TQVbIm9NrT：主线程在 {@code FlutterJNI.nativeSurfaceDestroyed} 里等 raster 线程，ANR 摘要
 * 却只截了主线程开头，被等的 raster 线程一帧都没留下。摘要必须带上 Flutter 引擎线程段。
 */
public class AnrTraceSummaryTest {
    private static final String APK =
            "/data/app/~~KQo4XAHRNcKMW0iMHM5seA==/app.fushi.reader-RNf4TPK59QAjKih3qVaehw==/base.apk";

    private static String filler(String name, int frames) {
        StringBuilder b = new StringBuilder();
        b.append('"').append(name).append("\" prio=5 tid=9 Waiting\n");
        b.append("  | group=\"main\" sCount=1 ucsCount=0 flags=1 obj=0x1 self=0x2\n");
        for (int i = 0; i < frames; i++) {
            b.append("  at java.lang.Object.wait(Native method) frame ").append(i).append('\n');
        }
        return b.append('\n').toString();
    }

    private static String trace() {
        StringBuilder b = new StringBuilder();
        b.append("----- pid 12375 at 2026-11-19 13:15:39 -----\nCmd line: app.fushi.reader\n\n");
        b.append("\"main\" prio=5 tid=1 Native\n");
        b.append("  | group=\"main\" sCount=1 ucsCount=0 flags=1 obj=0x72008ef8 self=0xb40000739355a7b0\n");
        b.append("  | sysTid=12375 nice=-10 cgrp=top-app sched=0/0 handle=0x757d1b84f8\n");
        b.append("  | held mutexes=\n");
        b.append("  native: #00 pc 0005823c  /apex/com.android.runtime/lib64/bionic/libc.so (syscall+28)"
                + " (BuildId: e2d9c5ba32145bb6e11e59494ee68593)\n");
        b.append("  native: #02 pc 000c8fc8  /apex/com.android.runtime/lib64/bionic/libc.so"
                + " (pthread_cond_wait+72) (BuildId: e2d9c5ba32145bb6e11e59494ee68593)\n");
        b.append("  native: #03 pc 004f9c2c  ").append(APK)
                .append(" (offset 8468000) (???) (BuildId: 3042c18dd243797671f94adc831f8ada24daec26)\n");
        b.append("  at io.flutter.embedding.engine.FlutterJNI.nativeSurfaceDestroyed(Native method)\n");
        b.append("  at io.flutter.embedding.engine.FlutterJNI.onSurfaceDestroyed(SourceFile:16)\n");
        b.append("  at android.view.SurfaceView.onWindowVisibilityChanged(SurfaceView.java:548)\n\n");
        // 一大堆无关线程，把引擎线程推到 3400 字以后。
        for (int i = 0; i < 60; i++) b.append(filler("binder:12375_" + i, 6));
        b.append("\"1.raster\" prio=5 (not attached)\n");
        b.append("  | sysTid=12400 nice=-5 cgrp=top-app\n");
        b.append("  native: #00 pc 0005823c  /apex/com.android.runtime/lib64/bionic/libc.so (syscall+28)\n");
        b.append("  native: #01 pc 00012345  /vendor/lib64/egl/libGLES_mali.so (eglDestroySurface+40)\n\n");
        b.append("\"1.ui\" prio=5 (not attached)\n");
        b.append("  native: #00 pc 00011111  ").append(APK).append(" (offset 8468000) (???)\n\n");
        b.append("\"1.io\" prio=5 (not attached)\n");
        b.append("  native: #00 pc 00022222  /apex/com.android.runtime/lib64/bionic/libc.so (__epoll_pwait+8)\n\n");
        b.append("\"DartWorker\" prio=5 (not attached)\n");
        b.append("  native: #00 pc 00033333  /apex/com.android.runtime/lib64/bionic/libc.so (futex)\n\n");
        return b.toString();
    }

    @Test
    public void keepsMainAndFlutterEngineThreadsBeyondMainThreadCap() {
        String out = AnrTraceSummary.summarize(trace(), 3400);

        assertTrue(out, out.startsWith("\"main\" prio=5 tid=1 Native\n"));
        assertTrue(out, out.contains("FlutterJNI.nativeSurfaceDestroyed"));
        assertTrue(out, out.contains("\"1.raster\" prio=5 (not attached)"));
        assertTrue(out, out.contains("libGLES_mali.so (eglDestroySurface+40)"));
        assertTrue(out, out.contains("\"1.ui\""));
        assertTrue(out, out.contains("\"1.io\""));
        // 无关线程与状态行不占预算。
        assertFalse(out, out.contains("binder:12375_"));
        assertFalse(out, out.contains("DartWorker"));
        assertFalse(out, out.contains("| group="));
        assertTrue(out.length() <= 3400);
    }

    @Test
    public void stripsBuildIdAndInstallPathNoise() {
        String out = AnrTraceSummary.summarize(trace(), 3400);

        assertFalse(out, out.contains("BuildId"));
        assertFalse(out, out.contains("/data/app/"));
        assertTrue(out, out.contains("  native: #03 pc 004f9c2c  base.apk (offset 8468000) (???)"));
    }

    @Test
    public void capsFramesPerThread() {
        StringBuilder b = new StringBuilder("\"main\" prio=5 tid=1 Native\n");
        for (int i = 0; i < AnrTraceSummary.MAX_MAIN_FRAMES + 5; i++) {
            b.append("  at a.B.c").append(i).append("(B.java:1)\n");
        }
        String out = AnrTraceSummary.summarize(b.toString(), 100000);

        assertTrue(out, out.contains("c" + (AnrTraceSummary.MAX_MAIN_FRAMES - 1) + "("));
        assertFalse(out, out.contains("c" + AnrTraceSummary.MAX_MAIN_FRAMES + "("));
        assertTrue(out, out.contains("  ... (+5 frames)"));
        assertTrue(out, out.contains("(no Flutter engine thread in trace)"));
    }

    @Test
    public void unrecognisedTraceFallsBackToHead() {
        assertEquals("abcde", AnrTraceSummary.summarize("abcdefgh", 5));
    }
}
