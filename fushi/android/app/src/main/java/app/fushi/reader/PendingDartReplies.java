package app.fushi.reader;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

import io.flutter.plugin.common.MethodChannel;

/**
 * 发给某个 Flutter 引擎、还在等 Dart 回话的请求（截屏 OCR 问引擎 / 交定格帧识别）。
 *
 * <p>引擎被销毁时 Flutter 不会回调这些挂起的 reply（{@code DartMessenger.pendingReplies}
 * 随引擎一起丢掉），等回话的一方（{@link ScreenOcrService}）就永远停在「等 Dart」：流程锁
 * 不解、悬浮球一直藏着。这里给每个请求记账，引擎销毁时（{@link #abandonAll}）统一按
 * {@link #ENGINE_DESTROYED} 错误收尾，调用方走自己「Dart 不在」的那条路。
 *
 * <p>每个请求至多完成一次：先到的那个（Dart 的回话或 {@link #abandonAll}）生效，之后的
 * 一律忽略。只在主线程读写（MethodChannel 回调与引擎生命周期回调都在主线程）。
 */
final class PendingDartReplies {
    static final String ENGINE_DESTROYED = "ENGINE_DESTROYED";

    private final Set<Tracked> pending = new LinkedHashSet<>();

    /** 登记一个即将发出的请求；把返回的 Result 交给 {@code invokeMethod}。 */
    @NonNull
    MethodChannel.Result track(@NonNull MethodChannel.Result callback) {
        Tracked tracked = new Tracked(callback);
        pending.add(tracked);
        return tracked;
    }

    /** {@code invokeMethod} 当场抛了（请求没发出去）：撤掉登记，不回调。 */
    void forget(@NonNull MethodChannel.Result tracked) {
        if (tracked instanceof Tracked) {
            Tracked t = (Tracked) tracked;
            t.done = true;
            pending.remove(t);
        }
    }

    /** 引擎销毁：所有还没回话的请求按 {@link #ENGINE_DESTROYED} 错误收尾。 */
    void abandonAll() {
        List<Tracked> orphans = new ArrayList<>(pending);
        pending.clear();
        for (Tracked t : orphans) {
            t.error(ENGINE_DESTROYED, "Flutter engine destroyed before Dart replied", null);
        }
    }

    /** 还在等回话的请求数。 */
    int size() {
        return pending.size();
    }

    private final class Tracked implements MethodChannel.Result {
        private final MethodChannel.Result callback;
        private boolean done = false;

        Tracked(@NonNull MethodChannel.Result callback) {
            this.callback = callback;
        }

        /** 第一次完成返回 true 并销账；之后返回 false。 */
        private boolean settle() {
            if (done) return false;
            done = true;
            pending.remove(this);
            return true;
        }

        @Override
        public void success(@Nullable Object result) {
            if (settle()) callback.success(result);
        }

        @Override
        public void error(@NonNull String errorCode, @Nullable String errorMessage,
                @Nullable Object errorDetails) {
            if (settle()) callback.error(errorCode, errorMessage, errorDetails);
        }

        @Override
        public void notImplemented() {
            if (settle()) callback.notImplemented();
        }
    }
}
