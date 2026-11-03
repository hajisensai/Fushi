package app.fushi.reader;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

/**
 * Which companion panel the stream page wants, and whether it is up: the state
 * machine behind {@link GameStreamCompanionDisplay}, free of Android types so
 * the JVM tests can drive every ordering of launches, registrations and
 * closes.
 *
 * <p>Every launch gets a fresh token (an intent extra the panel sends back when
 * it registers). Only a panel carrying the current token is the wanted one:
 * a panel from an earlier launch (replaced by a launch on another display, or
 * still starting when the page dismissed it) is closed when it registers, and
 * its late unregister changes nothing. Without tokens an old panel's
 * unregister arriving after the new launch reset the state and the new panel
 * was closed on arrival.
 *
 * <p>{@code P} is the panel's handle (its {@code Messenger}); handles are
 * compared with {@code equals}.
 */
final class GameStreamCompanionLifecycle<P> {
    interface Effects<P> {
        /** Close {@code panel}: it is not, or no longer, the wanted one. */
        void finish(@NonNull P panel);

        /** The wanted panel registered ({@code true}) or went away. */
        void attachedChanged(boolean attached);
    }

    static final int NO_TOKEN = 0;
    static final int NO_DISPLAY = -1;

    private final Effects<P> effects;
    private int nextToken = 1;

    /** The launch the page wants; NO_TOKEN when it wants no panel. */
    private int launchToken = NO_TOKEN;
    private int displayId = NO_DISPLAY;

    /** The wanted panel once it registered. */
    @Nullable private P panel;

    GameStreamCompanionLifecycle(@NonNull Effects<P> effects) {
        this.effects = effects;
    }

    /**
     * The page wants the panel on {@code display}. Returns the token for a new
     * launch there, or {@link #NO_TOKEN} when the wanted panel already is (or
     * is being) shown there. A panel elsewhere is closed.
     */
    int show(int display) {
        if (launchToken != NO_TOKEN && displayId == display) return NO_TOKEN;
        retire();
        launchToken = nextToken++;
        displayId = display;
        return launchToken;
    }

    /** The launch for {@code token} could not start. */
    void launchFailed(int token) {
        if (token != launchToken) return;
        launchToken = NO_TOKEN;
        displayId = NO_DISPLAY;
    }

    /** The page wants no panel. A panel still starting is closed on arrival. */
    void dismiss() {
        retire();
        launchToken = NO_TOKEN;
        displayId = NO_DISPLAY;
    }

    /**
     * {@code candidate} started and registered with {@code token}. Returns
     * whether it is the wanted panel; any other is closed.
     */
    boolean register(@NonNull P candidate, int token) {
        if (token == NO_TOKEN || token != launchToken) {
            effects.finish(candidate);
            return false;
        }
        final boolean wasAttached = panel != null;
        panel = candidate;
        if (!wasAttached) effects.attachedChanged(true);
        return true;
    }

    /**
     * {@code closed} unregistered or its process died. Only the wanted
     * panel's loss counts: the page then wants no panel until it asks again.
     */
    boolean gone(@NonNull P closed) {
        if (panel == null || !panel.equals(closed)) return false;
        panel = null;
        launchToken = NO_TOKEN;
        displayId = NO_DISPLAY;
        effects.attachedChanged(false);
        return true;
    }

    @Nullable
    P panel() {
        return panel;
    }

    int displayId() {
        return displayId;
    }

    private void retire() {
        final P current = panel;
        panel = null;
        if (current == null) return;
        effects.finish(current);
        effects.attachedChanged(false);
    }
}
