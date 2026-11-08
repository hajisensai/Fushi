package app.fushi.reader;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

/**
 * Which second-screen panel the app wants, and whether it is up: the state
 * machine behind {@link SecondScreenDisplay}, free of Android types so the JVM
 * tests can drive every ordering of launches, registrations, closes and host
 * start / stop.
 *
 * <p>The app wants at most one panel: a display plus a mode (the companion, or
 * the game stream's lookup panel). Every launch gets a fresh token (an intent
 * extra the panel sends back when it registers). Only a panel carrying the
 * current token is the wanted one: a panel from an earlier launch (replaced by
 * a launch on another display or in another mode, still starting when the app
 * dismissed it, or launched before the host stopped) is closed when it
 * registers, and its late unregister changes nothing.
 *
 * <p>The panel only lives while the host Activity is started: stopping the
 * host closes it but keeps what is wanted, starting the host launches it
 * again. A panel that goes away on its own (crash, closed itself) clears what
 * is wanted; the app asks again.
 *
 * <p>{@code P} is the panel's handle (its {@code Messenger}); handles are
 * compared with {@code equals}.
 */
final class SecondScreenLifecycle<P> {
    interface Effects<P> {
        /**
         * Start a panel in {@code mode} on {@code display}, carrying
         * {@code token}. Returns false when it could not be started.
         */
        boolean launch(int display, @NonNull String mode, int token);

        /** Close {@code panel}: it is not, or no longer, the wanted one. */
        void finish(@NonNull P panel);

        /** The wanted panel registered ({@code true}) or went away. */
        void attachedChanged(boolean attached);
    }

    static final int NO_TOKEN = 0;
    static final int NO_DISPLAY = -1;

    private final Effects<P> effects;
    private int nextToken = 1;

    /** What the app wants; NO_DISPLAY / null when it wants no panel. */
    private int wantedDisplay = NO_DISPLAY;
    @Nullable private String wantedMode;

    /** The outstanding launch; NO_TOKEN when none was issued (or it is void). */
    private int launchToken = NO_TOKEN;

    private boolean hostStarted;

    /** The wanted panel once it registered. */
    @Nullable private P panel;

    SecondScreenLifecycle(@NonNull Effects<P> effects, boolean hostStarted) {
        this.effects = effects;
        this.hostStarted = hostStarted;
    }

    /**
     * The app wants a panel in {@code mode} on {@code display}. A panel
     * elsewhere or in another mode is closed. Returns false only when a
     * launch was needed and could not start (nothing is wanted then).
     */
    boolean show(int display, @NonNull String mode) {
        if (display == wantedDisplay && mode.equals(wantedMode)) {
            // Already up, on its way, or waiting for the host to start.
            if (panel != null || launchToken != NO_TOKEN || !hostStarted) return true;
        } else {
            retire();
            wantedDisplay = display;
            wantedMode = mode;
        }
        return hostStarted ? launch() : true;
    }

    /** The app wants no panel. A panel still starting is closed on arrival. */
    void dismiss() {
        retire();
        clearWanted();
    }

    /** The host Activity started: bring up the wanted panel. */
    void hostStarted() {
        hostStarted = true;
        if (wantedMode != null && panel == null && launchToken == NO_TOKEN) launch();
    }

    /**
     * The host Activity stopped: close the panel, keep what is wanted. A
     * panel still starting is closed on arrival.
     */
    void hostStopped() {
        hostStarted = false;
        retire();
    }

    /** {@code display} went away: a panel wanted there is not any more. */
    void displayRemoved(int display) {
        if (display == wantedDisplay) dismiss();
    }

    /**
     * {@code candidate} started and registered with {@code token}. Returns
     * whether it is the wanted panel; any other is closed.
     */
    boolean register(@NonNull P candidate, int token) {
        if (token == NO_TOKEN || token != launchToken || !hostStarted) {
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
     * panel's loss counts: the app then wants no panel until it asks again.
     */
    boolean gone(@NonNull P closed) {
        if (panel == null || !panel.equals(closed)) return false;
        panel = null;
        clearWanted();
        effects.attachedChanged(false);
        return true;
    }

    @Nullable
    P panel() {
        return panel;
    }

    int displayId() {
        return wantedDisplay;
    }

    @Nullable
    String mode() {
        return wantedMode;
    }

    boolean isHostStarted() {
        return hostStarted;
    }

    private boolean launch() {
        final int token = nextToken++;
        launchToken = token;
        final String mode = wantedMode;
        if (mode != null && effects.launch(wantedDisplay, mode, token)) return true;
        // Only void the wish when it still is this launch's (launch effects
        // never call back in, but stay safe against a re-entrant dismiss).
        if (launchToken == token) clearWanted();
        return false;
    }

    private void clearWanted() {
        launchToken = NO_TOKEN;
        wantedDisplay = NO_DISPLAY;
        wantedMode = null;
    }

    /** Close the current panel and void any launch still on its way. */
    private void retire() {
        launchToken = NO_TOKEN;
        final P current = panel;
        panel = null;
        if (current == null) return;
        effects.finish(current);
        effects.attachedChanged(false);
    }
}
