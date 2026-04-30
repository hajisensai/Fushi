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
import android.os.Build;
import android.os.IBinder;
import android.text.Layout;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.LinearLayout;
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
    private TextView lockButton;
    private WindowManager.LayoutParams layoutParams;

    private float fontSize = 16f;
    private int textColor = Color.WHITE;
    private int bgColor = 0xCC000000;
    private boolean isLocked = false;
    private String currentText = "";

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
        if (lyricText != null) {
            lyricText.setText(text);
        }
    }

    public void updateStyle(float size, int color, int bg) {
        fontSize = size;
        textColor = color;
        bgColor = bg;
        applyStyle();
    }

    public void setLocked(boolean locked) {
        isLocked = locked;
        updateLockButton();
        updateTouchability();
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

        addControlButton("<", "previousCue", dp12);
        addControlButton("Play", "playPause", dp12);
        addControlButton(">", "nextCue", dp12);
        lockButton = addControlButton("Lock", "toggleLock", dp12);
        addControlButton("X", "close", dp12);

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
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
                        | WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                        | WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD,
                PixelFormat.TRANSLUCENT);
        layoutParams.gravity = Gravity.TOP | Gravity.START;
        layoutParams.x = 0;
        layoutParams.y = savedY;

        setupTouchListener();
        windowManager.addView(rootView, layoutParams);
    }

    private TextView addControlButton(String label, String action, int horizontalPadding) {
        TextView button = new TextView(this);
        button.setText(label);
        button.setTextColor(Color.WHITE);
        button.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f);
        button.setGravity(Gravity.CENTER);
        button.setPadding(horizontalPadding, dpToPx(4), horizontalPadding, dpToPx(4));
        button.setMinWidth(dpToPx(44));
        button.setBackgroundColor(0x33000000);
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
        lockButton.setText(isLocked ? "Unlock" : "Lock");
        lockButton.setTextColor(isLocked ? 0xFFFFD54F : Color.WHITE);
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
        String text = getTouchedLookupText(event);
        if (text == null || text.trim().isEmpty()) {
            text = currentText;
        }
        if (text == null || text.trim().isEmpty()) return;

        Map<String, Object> args = new HashMap<>();
        args.put("text", text.trim());
        MainActivity.notifyFloatingLyricEvent("lookupText", args);
        bringAppToFront();
    }

    private String getTouchedLookupText(MotionEvent event) {
        if (lyricText == null) return currentText;
        Layout layout = lyricText.getLayout();
        CharSequence value = lyricText.getText();
        if (layout == null || value == null || value.length() == 0) {
            return currentText;
        }
        int x = (int) event.getX() - lyricText.getTotalPaddingLeft()
                + lyricText.getScrollX();
        int y = (int) event.getY() - lyricText.getTotalPaddingTop()
                + lyricText.getScrollY();
        int line = layout.getLineForVertical(y);
        int offset = layout.getOffsetForHorizontal(line, x);
        String source = value.toString();
        if (offset < 0 || offset >= source.length()) {
            return currentText;
        }
        int start = offset;
        int end = offset;
        while (start > 0) {
            int cp = source.codePointBefore(start);
            if (!isLookupCodePoint(cp)) break;
            start -= Character.charCount(cp);
        }
        while (end < source.length()) {
            int cp = source.codePointAt(end);
            if (!isLookupCodePoint(cp)) break;
            end += Character.charCount(cp);
        }
        if (start == end) {
            return currentText;
        }
        return source.substring(start, end);
    }

    private boolean isLookupCodePoint(int codePoint) {
        if (Character.isLetterOrDigit(codePoint)) return true;
        if (codePoint == 0x3005 || codePoint == 0x3006 || codePoint == 0x3007) {
            return true;
        }
        if (codePoint >= 0x3040 && codePoint <= 0x30FF) return true;
        if (codePoint >= 0x3400 && codePoint <= 0x9FFF) return true;
        if (codePoint >= 0xF900 && codePoint <= 0xFAFF) return true;
        if (codePoint >= 0xFF10 && codePoint <= 0xFF9D) return true;
        return codePoint >= 0x20000 && codePoint <= 0x323AF;
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
                | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
                | WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                | WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD;
        windowManager.updateViewLayout(rootView, layoutParams);
    }

    private void applyStyle() {
        if (lyricText == null || rootView == null) return;
        lyricText.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize);
        lyricText.setTextColor(textColor);
        rootView.setBackgroundColor(bgColor);
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
