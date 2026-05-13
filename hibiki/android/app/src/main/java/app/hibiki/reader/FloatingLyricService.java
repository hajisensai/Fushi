package app.hibiki.reader;

import android.app.Notification;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.text.Layout;
import android.text.SpannableString;
import android.text.Spanned;
import android.text.style.BackgroundColorSpan;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.lang.ref.WeakReference;
import java.util.Map;

public class FloatingLyricService extends BaseFloatingService {

    private static final int DP_PAD_H = 16;
    private static final int DP_PAD_V = 8;
    private static final int DP_CONTROLS_BOTTOM = 6;
    private static final int DP_BTN_PAD_H = 12;
    private static final int DP_BTN_PAD_V = 4;
    private static final int DP_BTN_MARGIN = 4;
    private static final int DP_BTN_MIN_W = 44;
    private static final int DP_BTN_MIN_H = 36;
    private static final int DRAG_THRESHOLD = 10;

    private TextView lyricText;
    private ImageButton previousButton;
    private ImageButton playPauseButton;
    private ImageButton nextButton;
    private ImageButton lockButton;
    private ImageButton closeButton;

    private float fontSize = 16f;
    private int textColor = Color.WHITE;
    private int bgColor = 0xCC000000;
    private int buttonTextColor = Color.WHITE;
    private int buttonBgColor = 0x33000000;
    private int highlightColor = 0x80FFD54F;
    private int activeColor = 0xFFFFD54F;
    private boolean isLocked = false;
    private boolean isPlaying = false;
    private String currentText = "";
    private int highlightStart = -1;
    private int highlightLength = 0;

    private String previousLabel = "Previous";
    private String playPauseLabel = "Play";
    private String nextLabel = "Next";
    private String lockLabel = "Lock";
    private String unlockLabel = "Unlock";
    private String closeLabel = "Close";

    private static WeakReference<FloatingLyricService> instanceRef;

    public static FloatingLyricService getInstance() {
        return instanceRef != null ? instanceRef.get() : null;
    }

    // ── BaseFloatingService abstract implementations ──

    @Override
    protected View createContentView() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        root.setPadding(dpToPx(DP_PAD_H), dpToPx(DP_PAD_V), dpToPx(DP_PAD_H), dpToPx(DP_PAD_V));

        LinearLayout controls = new LinearLayout(this);
        controls.setOrientation(LinearLayout.HORIZONTAL);
        controls.setGravity(Gravity.CENTER);
        controls.setPadding(0, 0, 0, dpToPx(DP_CONTROLS_BOTTOM));
        root.addView(controls, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        previousButton = addButton(controls, previousLabel, "previousCue",
                R.drawable.ic_floating_previous);
        playPauseButton = addButton(controls, playPauseLabel, "playPause",
                R.drawable.ic_floating_play);
        nextButton = addButton(controls, nextLabel, "nextCue",
                R.drawable.ic_floating_next);
        lockButton = addButton(controls, lockLabel, "toggleLock",
                R.drawable.ic_floating_lock);
        closeButton = addButton(controls, closeLabel, "close",
                R.drawable.ic_floating_close);

        lyricText = new TextView(this);
        lyricText.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize);
        lyricText.setTextColor(textColor);
        lyricText.setGravity(Gravity.CENTER_HORIZONTAL);
        lyricText.setTypeface(Typeface.DEFAULT);
        lyricText.setText(currentText);
        root.addView(lyricText, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        applyStyle();
        return root;
    }

    @Override
    protected String getPreferencePrefix() {
        return "floating_lyric_prefs";
    }

    @Override
    protected String getNotificationChannelId() {
        return "hibiki_floating_lyric";
    }

    @Override
    protected String getNotificationChannelName() {
        return "Floating Lyric";
    }

    @Override
    protected int getNotificationId() {
        return 9527;
    }

    @Override
    protected Notification buildNotification() {
        Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, getNotificationChannelId())
                : new Notification.Builder(this);
        return builder
                .setContentTitle("Hibiki")
                .setContentText("Floating lyric is active")
                .setSmallIcon(R.drawable.ic_stat_hibiki)
                .setOngoing(true)
                .build();
    }

    @Override
    protected void onServiceCommand(Intent intent) {
        // FloatingLyricService is controlled via static getInstance() + public API
    }

    // ── Lifecycle ──

    @Override
    public void onCreate() {
        super.onCreate();
        instanceRef = new WeakReference<>(this);
    }

    @Override
    public void onDestroy() {
        instanceRef = null;
        super.onDestroy();
    }

    // ── Drag listener (lock-aware) ──

    @Override
    protected void setupDragListener() {
        rootView.setOnTouchListener(new View.OnTouchListener() {
            private int initialY;
            private float initialTouchY;
            private boolean isDragging;

            @Override
            public boolean onTouch(View v, MotionEvent event) {
                if (isLocked) return true;
                switch (event.getAction()) {
                    case MotionEvent.ACTION_DOWN:
                        initialY = layoutParams.y;
                        initialTouchY = event.getRawY();
                        isDragging = false;
                        return true;
                    case MotionEvent.ACTION_MOVE:
                        float dy = event.getRawY() - initialTouchY;
                        if (Math.abs(dy) > DRAG_THRESHOLD) isDragging = true;
                        if (isDragging) {
                            layoutParams.y = initialY + (int) dy;
                            windowManager.updateViewLayout(rootView, layoutParams);
                        }
                        return true;
                    case MotionEvent.ACTION_UP:
                        if (isDragging) {
                            savePosition();
                        } else {
                            handleTap(event);
                        }
                        return true;
                }
                return false;
            }
        });
    }

    // ── Saved position uses posYTop key for backward compat ──

    @Override
    protected void setupOverlay() {
        int savedY = getSharedPreferences(getPreferencePrefix(), MODE_PRIVATE)
                .getInt("posYTop", 100);

        layoutParams = createLayoutParams();
        layoutParams.x = 0;
        layoutParams.y = savedY;

        setupDragListener();
        windowManager.addView(rootView, layoutParams);
    }

    @Override
    protected void savePosition() {
        if (layoutParams == null) return;
        getSharedPreferences(getPreferencePrefix(), MODE_PRIVATE).edit()
                .putInt("posYTop", layoutParams.y)
                .apply();
    }

    // ── Public API (called from MainActivity) ──

    public void updateLyricText(String text) {
        currentText = text;
        highlightStart = -1;
        highlightLength = 0;
        applyLyricText();
    }

    public void updateHighlight(int start, int length) {
        highlightStart = start;
        highlightLength = length;
        applyLyricText();
    }

    public void updateStyle(
            float size, int color, int bg,
            int buttonColor, int buttonBg,
            int highlight, int active) {
        fontSize = size;
        textColor = color;
        bgColor = bg;
        buttonTextColor = buttonColor;
        buttonBgColor = buttonBg;
        highlightColor = highlight;
        activeColor = active;
        applyStyle();
    }

    public void setLocked(boolean locked) {
        isLocked = locked;
        applyLockButton();
    }

    public void setPlaybackState(boolean playing) {
        isPlaying = playing;
        applyPlayPauseButton();
    }

    public void updateLabels(Map<String, Object> labels) {
        previousLabel = extractLabel(labels, "previous", previousLabel);
        playPauseLabel = extractLabel(labels, "playPause", playPauseLabel);
        nextLabel = extractLabel(labels, "next", nextLabel);
        lockLabel = extractLabel(labels, "lock", lockLabel);
        unlockLabel = extractLabel(labels, "unlock", unlockLabel);
        closeLabel = extractLabel(labels, "close", closeLabel);
        applyControlLabels();
    }

    // ── View helpers ──

    private ImageButton addButton(LinearLayout parent, String label,
                                   String action, int iconResId) {
        ImageButton btn = new ImageButton(this);
        btn.setImageResource(iconResId);
        btn.setContentDescription(label);
        btn.setPadding(dpToPx(DP_BTN_PAD_H), dpToPx(DP_BTN_PAD_V),
                dpToPx(DP_BTN_PAD_H), dpToPx(DP_BTN_PAD_V));
        btn.setMinimumWidth(dpToPx(DP_BTN_MIN_W));
        btn.setMinimumHeight(dpToPx(DP_BTN_MIN_H));
        btn.setScaleType(ImageView.ScaleType.CENTER);
        btn.setBackgroundColor(buttonBgColor);
        tintIcon(btn, buttonTextColor);
        btn.setOnClickListener(v -> onControlClick(action));

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.setMargins(dpToPx(DP_BTN_MARGIN), 0, dpToPx(DP_BTN_MARGIN), 0);
        parent.addView(btn, lp);
        return btn;
    }

    // ── Tap handling ──

    private void handleTap(MotionEvent event) {
        if (lyricText == null || currentText == null || currentText.trim().isEmpty()) return;
        int[] loc = new int[2];
        lyricText.getLocationOnScreen(loc);
        float localX = event.getRawX() - loc[0];
        float localY = event.getRawY() - loc[1];
        if (localX < 0 || localX > lyricText.getWidth()
                || localY < 0 || localY > lyricText.getHeight()) return;

        int index = getCharIndexAt(localX, localY);

        // Notify Flutter for highlight
        java.util.HashMap<String, Object> args = new java.util.HashMap<>();
        args.put("text", currentText);
        args.put("index", index);
        MainActivity.notifyFloatingLyricEvent("lookupText", args);

        // Forward to floating dict if running
        FloatingDictService dict = FloatingDictService.getInstance();
        if (dict != null) {
            int safeIndex = Math.min(index, currentText.length());
            int end = Math.min(safeIndex + 20, currentText.length());
            if (end > safeIndex) {
                String searchTerm = currentText.substring(safeIndex, end);
                if (!searchTerm.trim().isEmpty()) {
                    dict.onTextSelected(searchTerm);
                }
            }
        }
    }

    private int getCharIndexAt(float x, float y) {
        Layout layout = lyricText.getLayout();
        CharSequence value = lyricText.getText();
        if (layout == null || value == null || value.length() == 0) return 0;

        float adjX = x - lyricText.getTotalPaddingLeft() + lyricText.getScrollX();
        float adjY = y - lyricText.getTotalPaddingTop() + lyricText.getScrollY();
        int line = layout.getLineForVertical((int) adjY);
        int lineStart = layout.getLineStart(line);
        int lineEnd = layout.getLineEnd(line);
        String source = value.toString();
        while (lineEnd > lineStart && lineEnd <= source.length()
                && Character.isWhitespace(source.charAt(lineEnd - 1))) {
            lineEnd--;
        }

        for (int i = lineStart; i < lineEnd; i++) {
            float left = layout.getPrimaryHorizontal(i);
            float right = layout.getPrimaryHorizontal(i + 1);
            if (right < left) { float tmp = left; left = right; right = tmp; }
            if (adjX >= left && adjX <= right) return i;
        }

        int offset = layout.getOffsetForHorizontal(line, adjX);
        return Math.max(0, Math.min(offset, Math.max(0, source.length() - 1)));
    }

    // ── Control callbacks ──

    private void onControlClick(String action) {
        if (isLocked && !"toggleLock".equals(action)) return;
        if ("close".equals(action)) {
            MainActivity.notifyFloatingLyricEvent("close", null);
            stopSelf();
        } else if ("toggleLock".equals(action)) {
            setLocked(!isLocked);
            java.util.HashMap<String, Object> args = new java.util.HashMap<>();
            args.put("locked", isLocked);
            MainActivity.notifyFloatingLyricEvent("lockChanged", args);
        } else {
            MainActivity.notifyFloatingLyricEvent(action, null);
        }
    }

    // ── Style application ──

    private void applyLyricText() {
        if (lyricText == null) return;
        if (highlightStart >= 0 && highlightLength > 0 && currentText != null) {
            int start = Math.max(0, Math.min(highlightStart, currentText.length()));
            int end = Math.max(start, Math.min(start + highlightLength, currentText.length()));
            SpannableString span = new SpannableString(currentText);
            if (end > start) {
                span.setSpan(new BackgroundColorSpan(highlightColor),
                        start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            }
            lyricText.setText(span);
        } else {
            lyricText.setText(currentText);
        }
        if (windowManager != null && rootView != null && layoutParams != null) {
            rootView.post(() -> windowManager.updateViewLayout(rootView, layoutParams));
        }
    }

    private void applyStyle() {
        if (lyricText == null || rootView == null) return;
        lyricText.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize);
        lyricText.setTextColor(textColor);
        rootView.setBackgroundColor(bgColor);
        applyButtonStyle(previousButton);
        applyButtonStyle(nextButton);
        applyButtonStyle(closeButton);
        applyPlayPauseButton();
        applyLockButton();
        applyLyricText();
    }

    private void applyButtonStyle(ImageButton btn) {
        if (btn == null) return;
        btn.setBackgroundColor(buttonBgColor);
        tintIcon(btn, buttonTextColor);
    }

    private void applyLockButton() {
        if (lockButton == null) return;
        lockButton.setImageResource(
                isLocked ? R.drawable.ic_floating_lock_open : R.drawable.ic_floating_lock);
        lockButton.setContentDescription(isLocked ? unlockLabel : lockLabel);
        tintIcon(lockButton, isLocked ? activeColor : buttonTextColor);
        lockButton.setBackgroundColor(buttonBgColor);
    }

    private void applyPlayPauseButton() {
        if (playPauseButton == null) return;
        playPauseButton.setImageResource(
                isPlaying ? R.drawable.ic_floating_pause : R.drawable.ic_floating_play);
        playPauseButton.setContentDescription(playPauseLabel);
        tintIcon(playPauseButton, isPlaying ? activeColor : buttonTextColor);
        playPauseButton.setBackgroundColor(buttonBgColor);
    }

    private void applyControlLabels() {
        if (previousButton != null) previousButton.setContentDescription(previousLabel);
        if (playPauseButton != null) playPauseButton.setContentDescription(playPauseLabel);
        if (nextButton != null) nextButton.setContentDescription(nextLabel);
        if (closeButton != null) closeButton.setContentDescription(closeLabel);
        applyLockButton();
    }

    // ── Utilities ──

    private void tintIcon(ImageButton btn, int color) {
        Drawable d = btn.getDrawable();
        if (d != null) d.mutate().setTint(color);
    }

    private static String extractLabel(Map<String, Object> labels, String key, String fallback) {
        if (labels == null) return fallback;
        Object value = labels.get(key);
        if (value == null) return fallback;
        String text = value.toString();
        return text.isEmpty() ? fallback : text;
    }
}
