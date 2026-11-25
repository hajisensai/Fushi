package app.fushi.reader;

import static org.junit.Assert.assertEquals;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

import org.junit.Test;

import io.flutter.plugin.common.MethodChannel;

/**
 * 截屏 OCR 等 Dart 回话时主引擎被销毁：Flutter 不回调挂起的 reply，{@link PendingDartReplies}
 * 必须替它们收尾，否则 {@link ScreenOcrService} 一直停在「等 Dart」（流程锁不解、悬浮球藏着）。
 */
public class PendingDartRepliesTest {
    /** 记下回调到达的顺序与内容。 */
    private static final class Recorder implements MethodChannel.Result {
        final List<String> events = new ArrayList<>();

        @Override
        public void success(@Nullable Object result) {
            events.add("success:" + result);
        }

        @Override
        public void error(@NonNull String errorCode, @Nullable String errorMessage,
                @Nullable Object errorDetails) {
            events.add("error:" + errorCode);
        }

        @Override
        public void notImplemented() {
            events.add("notImplemented");
        }
    }

    @Test
    public void engineDestroyedBeforeReplyCompletesEveryPendingRequestAsError() {
        PendingDartReplies replies = new PendingDartReplies();
        Recorder engineQuery = new Recorder();
        Recorder frame = new Recorder();
        replies.track(engineQuery);
        replies.track(frame);
        assertEquals(2, replies.size());

        replies.abandonAll();

        assertEquals(Collections.singletonList("error:" + PendingDartReplies.ENGINE_DESTROYED), engineQuery.events);
        assertEquals(Collections.singletonList("error:" + PendingDartReplies.ENGINE_DESTROYED), frame.events);
        assertEquals(0, replies.size());
    }

    @Test
    public void answeredRequestIsNotAbandonedAndLateReplyIsIgnored() {
        PendingDartReplies replies = new PendingDartReplies();
        Recorder answered = new Recorder();
        Recorder orphan = new Recorder();
        MethodChannel.Result answeredTracked = replies.track(answered);
        MethodChannel.Result orphanTracked = replies.track(orphan);

        answeredTracked.success("lines");
        assertEquals(1, replies.size());
        replies.abandonAll();
        // 引擎销毁后 Flutter 万一又把回话送来：已经收尾的请求不能被回调第二次。
        orphanTracked.success("late");
        answeredTracked.error("X", null, null);

        assertEquals(Collections.singletonList("success:lines"), answered.events);
        assertEquals(Collections.singletonList("error:" + PendingDartReplies.ENGINE_DESTROYED), orphan.events);
    }

    @Test
    public void forgottenRequestIsNeverCalledBack() {
        PendingDartReplies replies = new PendingDartReplies();
        Recorder notSent = new Recorder();
        MethodChannel.Result tracked = replies.track(notSent);

        replies.forget(tracked);
        replies.abandonAll();
        tracked.notImplemented();

        assertEquals(0, replies.size());
        assertEquals(Collections.<String>emptyList(), notSent.events);
    }
}
