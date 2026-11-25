package app.fushi.reader;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.ArrayList;
import java.util.List;

/**
 * The panel's messages to the main process, in order, across the relay
 * connection coming up.
 *
 * <p>{@code bindService} connects asynchronously while the panel's Dart side
 * starts right away: its first message (the companion's "ready") could reach
 * the Activity before {@code onServiceConnected}. Sending it straight to a
 * relay that is not there yet lost it, so the main engine never answered and
 * every panel page kept loading. Messages taken while connecting wait here and
 * go out, in order, right after the panel registered with the relay; once the
 * connection is closed (disconnected, destroyed) nothing is taken any more.
 *
 * <p>Free of Android types so the JVM tests can drive it; {@code M} is the
 * relay message.
 */
final class SecondScreenRelayOutbox<M> {
    /** Sends one message to the connected relay; false when it is gone. */
    interface Sink<M> {
        boolean send(@NonNull M message);
    }

    private final List<M> pending = new ArrayList<>();
    @Nullable private Sink<M> sink;
    private boolean closed = false;

    /**
     * Takes [message]: sent now when connected, kept for the connection while
     * it is coming up. False when the relay did not take it (closed, or the
     * connected relay refused it).
     */
    boolean offer(@NonNull M message) {
        if (closed) return false;
        final Sink<M> target = sink;
        if (target == null) {
            pending.add(message);
            return true;
        }
        return target.send(message);
    }

    /**
     * The relay is connected (and the panel registered): sends what waited, in
     * order. False when the relay refused one; the rest is dropped and the
     * outbox closed (the panel has nothing left to talk to).
     */
    boolean connect(@NonNull Sink<M> target) {
        if (closed) return false;
        sink = target;
        final List<M> waiting = new ArrayList<>(pending);
        pending.clear();
        for (final M message : waiting) {
            if (!target.send(message)) {
                close();
                return false;
            }
        }
        return true;
    }

    /** The connection is gone for good: drops what waited, takes nothing more. */
    void close() {
        closed = true;
        sink = null;
        pending.clear();
    }

    /** Messages waiting for the connection (tests). */
    int pendingCount() {
        return pending.size();
    }
}
