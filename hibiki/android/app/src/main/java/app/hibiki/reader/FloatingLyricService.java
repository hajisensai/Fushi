package app.hibiki.reader;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.os.IBinder;
import android.text.Layout;
import android.text.SpannableString;
import android.text.Spanned;
import android.text.style.BackgroundColorSpan;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.LinearLayout;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.TextView;

import androidx.annotation.Nullable;

import java.util.HashMap;
import java.util.Map;

public class FloatingLyricService extends Service {

    private static final String CHANNEL_ID = "hibiki_floating_lyric";
    private static final String PREFS_NAME = "floating_lyric_prefs";
    private static final int NOTIFICATION_ID = 9527;

    private WindowManager windowManager;
    private LinearLayout rootView;
    private TextView lyricText;
    private LinearLayout controlsView;
    private ImageButton previousButton;
    private ImageButton playPauseButton;
    private ImageButton nextButton;
    private ImageButton lockButton;
    private ImageButton closeButton;
    private WindowManager.LayoutParams layoutParams;

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

    private static FloatingLyricService instance;

    public static FloatingLyricService getInstance() {
        return instance;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
        windowManager = (WindowManager) getSystemService(Context.WINDOW_SERVICE);
        createNotificationChannel();
        startForeground(NOTIFICATION_ID, buildNotification());
        createOverlayView();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null) {
            String action = intent.getStringExtra("action");
            if ("updateText".equals(action)) {
                String text = intent.getStringExtra("text");
                if (text != null) {
                    updateLyricText(text);
                }
            } else if ("updateStyle".equals(action)) {
                fontSize = intent.getFloatExtra("fontSize", fontSize);
                textColor = intent.getIntExtra("textColor", textColor);
                bgColor = intent.getIntExtra("bgColor", bgColor);
                buttonTextColor = intent.getIntExtra("buttonTextColor", buttonTextColor);
                buttonBgColor = intent.getIntExtra("buttonBgColor", buttonBgColor);
                highlightColor = intent.getIntExtra("highlightColor", highlightColor);
                activeColor = intent.getIntExtra("activeColor", activeColor);
                applyStyle();
            } else if ("setLocked".equals(action)) {
                setLocked(intent.getBooleanExtra("locked", false));
            }
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
        instance = null;
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

    private void applyLyricText() {
        if (lyricText != null) {
            if (highlightStart >= 0 && highlightLength > 0 && currentText != null) {
                int start = Math.max(0, Math.min(highlightStart, currentText.length()));
                int end = Math.max(start, Math.min(start + highlightLength, currentText.length()));
                SpannableString span = new SpannableString(currentText);
                if (end > start) {
                    span.setSpan(
                            new BackgroundColorSpan(highlightColor),
                            start,
                            end,
                            Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                }
                lyricText.setText(span);
            } else {
                lyricText.setText(currentText);
            }
        }
    }

    public void updateStyle(
            float size,
            int color,
            int bg,
            int buttonColor,
            int buttonBg,
            int highlight,
            int active) {
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
        updateLockButton();
        updateTouchability();
    }

    public void setPlaybackState(boolean playing) {
        isPlaying = playing;
        updatePlayPauseButton();
    }

    public void updateLabels(Map<String, Object> labels) {
        previousLabel = stringLabel(labels, "previous", previousLabel);
        playPauseLabel = stringLabel(labels, "playPause", playPauseLabel);
        nextLabel = stringLabel(labels, "next", nextLabel);
        lockLabel = stringLabel(labels, "lock", lockLabel);
        unlockLabel = stringLabel(labels, "unlock", unlockLabel);
        closeLabel = stringLabel(labels, "close", closeLabel);
        updateControlLabels();
    }

    private String stringLabel(Map<String, Object> labels, String key, String fallback) {
        if (labels == null) return fallback;
        Object value = labels.get(key);
        if (value == null) return fallback;
        String text = value.toString();
        return text.isEmpty() ? fallback : text;
    }

    private void updateControlLabels() {
        if (previousButton != null) previousButton.setContentDescription(previousLabel);
        if (playPauseButton != null) playPauseButton.setContentDescription(playPauseLabel);
        if (nextButton != null) nextButton.setContentDescription(nextLabel);
        if (closeButton != null) closeButton.setContentDescription(closeLabel);
        updateLockButton();
    }

    private void createOverlayView() {
        int dp6 = dpToPx(6);
        int dp8 = dpToPx(8);
        int dp12 = dpToPx(12);
        int dp16 = dpToPx(16);

        rootView = new LinearLayout(this);
        rootView.setOrientation(LinearLayout.VERTICAL);
        rootView.setGravity(Gravity.CENTER);
        rootView.setPadding(dp16, dp8, dp16, dp8);

        lyricText = new TextView(this);
        lyricText.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize);
        lyricText.setTextColor(textColor);
        lyricText.setMaxLines(3);
        lyricText.setGravity(Gravity.CENTER);
        lyricText.setTypeface(Typeface.DEFAULT);
        lyricText.setText(currentText);

        LinearLayout.LayoutParams textLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        rootView.addView(lyricText, textLp);

        controlsView = new LinearLayout(this);
        controlsView.setOrientation(LinearLayout.HORIZONTAL);
        controlsView.setGravity(Gravity.CENTER);
        controlsView.setPadding(0, dp6, 0, 0);
        rootView.addView(controlsView, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        previousButton = addControlButton(
                previousLabel,
                "previousCue",
                R.drawable.ic_floating_previous,
                dp12);
        playPauseButton = addControlButton(
                playPauseLabel,
                "playPause",
                R.drawable.ic_floating_play,
                dp12);
        nextButton = addControlButton(
                nextLabel,
                "nextCue",
                R.drawable.ic_floating_next,
                dp12);
        lockButton = addControlButton(
                lockLabel,
                "toggleLock",
                R.drawable.ic_floating_lock,
                dp12);
        closeButton = addControlButton(
                closeLabel,
                "close",
                R.drawable.ic_floating_close,
                dp12);

        applyStyle();

        SharedPreferences prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        int savedY = prefs.getInt("posY", 100);

        layoutParams = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                        ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                        : WindowManager.LayoutParams.TYPE_PHONE,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        layoutParams.gravity = Gravity.TOP | Gravity.START;
        layoutParams.x = 0;
        layoutParams.y = savedY;

        setupTouchListener();
        windowManager.addView(rootView, layoutParams);
    }

    private ImageButton addControlButton(
            String label,
            String action,
            int iconResId,
            int horizontalPadding) {
        ImageButton button = new ImageButton(this);
        button.setImageResource(iconResId);
        button.setContentDescription(label);
        button.setPadding(horizontalPadding, dpToPx(4), horizontalPadding, dpToPx(4));
        button.setMinimumWidth(dpToPx(44));
        button.setMinimumHeight(dpToPx(36));
        button.setScaleType(ImageView.ScaleType.CENTER);
        button.setBackgroundColor(buttonBgColor);
        applyIconTint(button, buttonTextColor);
        button.setOnClickListener(v -> {
            if (isLocked && !"toggleLock".equals(action)) {
                return;
            }
            if ("close".equals(action)) {
                MainActivity.notifyFloatingLyricEvent("close", null);
                stopSelf();
            } else if ("toggleLock".equals(action)) {
                setLocked(!isLocked);
            } else {
                MainActivity.notifyFloatingLyricEvent(action, null);
            }
        });
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.setMargins(dpToPx(4), 0, dpToPx(4), 0);
        controlsView.addView(button, lp);
        return button;
    }

    private void updateLockButton() {
        if (lockButton == null) return;
        lockButton.setImageResource(
                isLocked ? R.drawable.ic_floating_lock_open : R.drawable.ic_floating_lock);
        lockButton.setContentDescription(isLocked ? unlockLabel : lockLabel);
        applyIconTint(lockButton, isLocked ? activeColor : buttonTextColor);
        lockButton.setBackgroundColor(buttonBgColor);
    }

    private void updatePlayPauseButton() {
        if (playPauseButton == null) return;
        playPauseButton.setImageResource(
                isPlaying ? R.drawable.ic_floating_pause : R.drawable.ic_floating_play);
        playPauseButton.setContentDescription(playPauseLabel);
        applyIconTint(playPauseButton, isPlaying ? activeColor : buttonTextColor);
        playPauseButton.setBackgroundColor(buttonBgColor);
    }

    private void setupTouchListener() {
        View.OnTouchListener touchListener = new View.OnTouchListener() {
            private int initialY;
            private float initialTouchY;
            private boolean isDragging = false;

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
                        if (Math.abs(dy) > 10) isDragging = true;
                        if (isDragging) {
                            layoutParams.y = initialY + (int) dy;
                            windowManager.updateViewLayout(rootView, layoutParams);
                        }
                        return true;
                    case MotionEvent.ACTION_UP:
                        if (isDragging) {
                            savePosition();
                        } else if (v == lyricText) {
                            notifyLookupFromTouch(event);
                        }
                        return true;
                }
                return false;
            }
        };
        rootView.setOnTouchListener(touchListener);
        lyricText.setOnTouchListener(touchListener);
    }

    private void notifyLookupFromTouch(MotionEvent event) {
        int index = getTouchedTextIndex(event);
        String text = currentText;
        if (text == null || text.trim().isEmpty()) return;

        Map<String, Object> args = new HashMap<>();
        args.put("text", text);
        args.put("index", index);
        MainActivity.notifyFloatingLyricEvent("lookupText", args);
        bringAppToFront();
    }

    private int getTouchedTextIndex(MotionEvent event) {
        if (lyricText == null) return 0;
        Layout layout = lyricText.getLayout();
        CharSequence value = lyricText.getText();
        if (layout == null || value == null || value.length() == 0) {
            return 0;
        }
        int x = (int) event.getX() - lyricText.getTotalPaddingLeft()
                + lyricText.getScrollX();
        int y = (int) event.getY() - lyricText.getTotalPaddingTop()
                + lyricText.getScrollY();
        int line = layout.getLineForVertical(y);
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
            if (right < left) {
                float tmp = left;
                left = right;
                right = tmp;
            }
            if (x >= left && x <= right) {
                return i;
            }
        }

        int offset = layout.getOffsetForHorizontal(line, x);
        return Math.max(0, Math.min(offset, Math.max(0, source.length() - 1)));
    }

    private void bringAppToFront() {
        Intent launchIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (launchIntent == null) return;
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                | Intent.FLAG_ACTIVITY_SINGLE_TOP
                | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        startActivity(launchIntent);
    }

    private void updateTouchability() {
        if (layoutParams == null || rootView == null) return;
        layoutParams.flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS;
        windowManager.updateViewLayout(rootView, layoutParams);
    }

    private void applyStyle() {
        if (lyricText == null || rootView == null) return;
        lyricText.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize);
        lyricText.setTextColor(textColor);
        rootView.setBackgroundColor(bgColor);
        applyButtonStyle(previousButton);
        applyButtonStyle(nextButton);
        applyButtonStyle(closeButton);
        updatePlayPauseButton();
        updateLockButton();
        applyLyricText();
    }

    private void applyButtonStyle(ImageButton button) {
        if (button == null) return;
        button.setBackgroundColor(buttonBgColor);
        applyIconTint(button, buttonTextColor);
    }

    private void applyIconTint(ImageButton button, int color) {
        Drawable drawable = button.getDrawable();
        if (drawable == null) return;
        drawable.mutate().setTint(color);
    }

    private void savePosition() {
        if (layoutParams == null) return;
        getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
                .edit()
                .putInt("posY", layoutParams.y)
                .apply();
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID,
                    "Floating Lyric",
                    NotificationManager.IMPORTANCE_LOW);
            channel.setShowBadge(false);
            NotificationManager nm = getSystemService(NotificationManager.class);
            nm.createNotificationChannel(channel);
        }
    }

    private Notification buildNotification() {
        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder = new Notification.Builder(this, CHANNEL_ID);
        } else {
            builder = new Notification.Builder(this);
        }
        return builder
                .setContentTitle("Hibiki")
                .setContentText("Floating lyric is active")
                .setSmallIcon(R.drawable.ic_stat_hibiki)
                .setOngoing(true)
                .build();
    }

    private int dpToPx(int dp) {
        return (int) (dp * getResources().getDisplayMetrics().density);
    }
}
