package app.hibiki.reader;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.PixelFormat;
import android.os.Build;
import android.os.IBinder;
import android.graphics.Rect;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.view.WindowMetrics;

import androidx.annotation.Nullable;

import app.hibiki.reader.constants.PreferenceKeys;

public abstract class BaseFloatingService extends Service {

    // TODO-832: at least this many dp of the overlay must always remain inside
    // the screen on every axis it can move along, so a floating subtitle /
    // dictionary window can never be dragged or restored fully off-screen.
    // Mirrors Windows kMinVisibleMarginDip=48.
    private static final int MIN_VISIBLE_DP = 48;

    // ── Drag mode ─────────────────────────────────────────────────────────────

    protected enum DragMode {
        /** Drag only along the Y axis. */
        VERTICAL_ONLY,
        /** Drag freely along both X and Y axes. */
        FREE
    }

    // ── Shared overlay state ──────────────────────────────────────────────────

    protected WindowManager windowManager;
    protected View rootView;
    protected WindowManager.LayoutParams layoutParams;

    // ── Per-service config (set via constructor) ───────────────────────────────

    private final String preferencePrefix;
    private final String notificationChannelId;
    private final String notificationChannelName;
    private final int notificationId;

    // ── Constructor ───────────────────────────────────────────────────────────

    protected BaseFloatingService(
            String preferencePrefix,
            String notificationChannelId,
            String notificationChannelName,
            int notificationId) {
        this.preferencePrefix = preferencePrefix;
        this.notificationChannelId = notificationChannelId;
        this.notificationChannelName = notificationChannelName;
        this.notificationId = notificationId;
    }

    // ── Abstract API ──────────────────────────────────────────────────────────

    protected abstract View createContentView();

    protected abstract Notification buildNotification();

    protected abstract void onServiceCommand(Intent intent);

    // ── Subclass hooks (override as needed) ───────────────────────────────────

    /**
     * Returns the drag mode for this overlay.
     * Default is {@link DragMode#VERTICAL_ONLY}.
     */
    protected DragMode getDragMode() {
        return DragMode.VERTICAL_ONLY;
    }

    /**
     * The view that the touch listener is attached to.
     * Default is {@link #rootView} (the whole overlay).
     * Override to restrict dragging to a specific handle (e.g. a title bar).
     */
    protected View getDragHandle() {
        return rootView;
    }

    /**
     * Returns true if dragging is currently locked for this service.
     * Default is always {@code false}.
     */
    protected boolean isDragLocked() {
        return false;
    }

    /**
     * Called when the user taps the overlay without dragging.
     * Default does nothing.
     */
    protected void onOverlayTapped(MotionEvent event) {
    }

    /**
     * Reads the saved X position from shared prefs.
     * Override to return a fixed value (e.g. 0) if X should not be persisted.
     */
    protected int readSavedX(SharedPreferences prefs) {
        return prefs.getInt(PreferenceKeys.POS_X, 0);
    }

    /**
     * Reads the saved Y position from shared prefs.
     * Override to add backward-compatible key fallback logic.
     */
    protected int readSavedY(SharedPreferences prefs) {
        return prefs.getInt(PreferenceKeys.POS_Y, 100);
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    @Override
    public void onCreate() {
        super.onCreate();
        windowManager = (WindowManager) getSystemService(Context.WINDOW_SERVICE);
        createNotificationChannel();
        startForeground(notificationId, buildNotification());
        rootView = createContentView();
        setupOverlay();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null) {
            onServiceCommand(intent);
        }
        return START_NOT_STICKY;
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        savePosition();
        if (rootView != null) {
            windowManager.removeView(rootView);
            rootView = null;
        }
        super.onDestroy();
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        stopSelf();
        super.onTaskRemoved(rootIntent);
    }

    // ── Notification ──────────────────────────────────────────────────────────

    protected final String getNotificationChannelId() {
        return notificationChannelId;
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    notificationChannelId,
                    notificationChannelName,
                    NotificationManager.IMPORTANCE_LOW);
            channel.setShowBadge(false);
            getSystemService(NotificationManager.class)
                    .createNotificationChannel(channel);
        }
    }

    // ── Overlay setup ─────────────────────────────────────────────────────────

    protected void setupOverlay() {
        SharedPreferences prefs = getSharedPreferences(preferencePrefix, MODE_PRIVATE);
        int savedX = readSavedX(prefs);
        int savedY = readSavedY(prefs);

        layoutParams = createLayoutParams();
        layoutParams.x = savedX;
        layoutParams.y = savedY;

        setupDragListener();
        windowManager.addView(rootView, layoutParams);

        // TODO-832: a historically out-of-bounds saved position (or a smaller
        // screen than last time) would otherwise restore off-screen and be
        // unreachable. Clamp after the first layout pass so WRAP_CONTENT /
        // MATCH_PARENT dimensions are measured; fixed-size overlays are already
        // clampable but post() keeps a single code path.
        rootView.post(() -> {
            if (rootView == null || layoutParams == null) return;
            int beforeX = layoutParams.x;
            int beforeY = layoutParams.y;
            clampToScreen();
            if (layoutParams.x != beforeX || layoutParams.y != beforeY) {
                windowManager.updateViewLayout(rootView, layoutParams);
                savePosition();
            }
        });
    }

    protected WindowManager.LayoutParams createLayoutParams() {
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                        ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                        : WindowManager.LayoutParams.TYPE_PHONE,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        lp.gravity = Gravity.TOP | Gravity.START;
        return lp;
    }

    // ── Unified drag listener ─────────────────────────────────────────────────

    protected void setupDragListener() {
        getDragHandle().setOnTouchListener(new View.OnTouchListener() {
            private int initialX;
            private int initialY;
            private float initialTouchX;
            private float initialTouchY;
            private boolean isDragging;

            @Override
            public boolean onTouch(View v, MotionEvent event) {
                switch (event.getAction()) {
                    case MotionEvent.ACTION_DOWN:
                        initialX = layoutParams.x;
                        initialY = layoutParams.y;
                        initialTouchX = event.getRawX();
                        initialTouchY = event.getRawY();
                        isDragging = false;
                        return true;
                    case MotionEvent.ACTION_MOVE: {
                        float dx = event.getRawX() - initialTouchX;
                        float dy = event.getRawY() - initialTouchY;
                        boolean moved = getDragMode() == DragMode.FREE
                                ? (Math.abs(dx) > 10 || Math.abs(dy) > 10)
                                : (Math.abs(dy) > 10);
                        if (moved) isDragging = true;
                        if (isDragging && !isDragLocked()) {
                            if (getDragMode() == DragMode.FREE) {
                                layoutParams.x = initialX + (int) dx;
                            }
                            layoutParams.y = initialY + (int) dy;
                            // TODO-832: keep ≥ MIN_VISIBLE_DP on-screen so the
                            // overlay can never be dragged off and lost.
                            clampToScreen();
                            windowManager.updateViewLayout(rootView, layoutParams);
                        }
                        return true;
                    }
                    case MotionEvent.ACTION_UP:
                        if (isDragging) {
                            if (!isDragLocked()) {
                                savePosition();
                            }
                        } else {
                            onOverlayTapped(event);
                        }
                        return true;
                }
                return false;
            }
        });
    }

    // ── Position persistence ──────────────────────────────────────────────────

    protected void savePosition() {
        if (layoutParams == null) return;
        getSharedPreferences(preferencePrefix, MODE_PRIVATE)
                .edit()
                .putInt(PreferenceKeys.POS_X, layoutParams.x)
                .putInt(PreferenceKeys.POS_Y, layoutParams.y)
                .apply();
    }

    // ── Screen-bounds clamp (TODO-832) ─────────────────────────────────────────

    /**
     * Clamps {@link #layoutParams} (physical px, gravity TOP|START) so at least
     * {@link #MIN_VISIBLE_DP} dp of the overlay stays inside the screen on every
     * axis it can move along, keeping it grabbable. {@link DragMode#VERTICAL_ONLY}
     * only clamps Y (X is MATCH_PARENT / fixed at 0 and meaningless to clamp);
     * {@link DragMode#FREE} clamps both axes with the same per-axis formula, no
     * special-casing. Units throughout are physical px (layoutParams /
     * getRawX / WindowMetrics) with the margin run through {@link #dpToPx}.
     */
    protected void clampToScreen() {
        if (layoutParams == null) return;

        Rect screen = getScreenBounds();
        int margin = dpToPx(MIN_VISIBLE_DP);

        if (getDragMode() == DragMode.FREE) {
            int winW = resolveWindowWidth(screen.width());
            int marginX = Math.min(margin, winW);
            layoutParams.x =
                    clamp(layoutParams.x, screen.left - (winW - marginX),
                            screen.right - marginX);
        }

        int winH = resolveWindowHeight(screen.height());
        int marginY = Math.min(margin, winH);
        layoutParams.y =
                clamp(layoutParams.y, screen.top - (winH - marginY),
                        screen.bottom - marginY);
    }

    /**
     * Resolves the overlay's physical-px width: a fixed {@code layoutParams.width}
     * is authoritative immediately (FREE dict overlay is dpToPx(300), no need to
     * wait for measurement — a 0 first-frame width would dash it off-screen);
     * MATCH_PARENT / WRAP_CONTENT fall back to the measured view width, then the
     * full screen width.
     */
    private int resolveWindowWidth(int screenWidth) {
        if (layoutParams.width > 0) return layoutParams.width;
        if (rootView != null && rootView.getWidth() > 0) return rootView.getWidth();
        return screenWidth;
    }

    private int resolveWindowHeight(int screenHeight) {
        if (layoutParams.height > 0) return layoutParams.height;
        if (rootView != null && rootView.getHeight() > 0) return rootView.getHeight();
        return screenHeight;
    }

    private Rect getScreenBounds() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            WindowMetrics metrics = windowManager.getCurrentWindowMetrics();
            return new Rect(metrics.getBounds());
        }
        DisplayMetrics dm = new DisplayMetrics();
        windowManager.getDefaultDisplay().getRealMetrics(dm);
        return new Rect(0, 0, dm.widthPixels, dm.heightPixels);
    }

    /** Clamps {@code value} into [lo, hi]; anchors to {@code lo} when lo > hi
     *  (overlay larger than the screen — never eject it). */
    private static int clamp(int value, int lo, int hi) {
        if (lo > hi) return lo;
        if (value < lo) return lo;
        if (value > hi) return hi;
        return value;
    }

    // ── Utilities ─────────────────────────────────────────────────────────────

    protected int dpToPx(int dp) {
        return (int) (dp * getResources().getDisplayMetrics().density);
    }
}
