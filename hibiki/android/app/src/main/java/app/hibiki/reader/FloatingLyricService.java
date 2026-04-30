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
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.LinearLayout;
import android.widget.TextView;

import androidx.annotation.Nullable;

public class FloatingLyricService extends Service {

    private static final String CHANNEL_ID = "hibiki_floating_lyric";
    private static final String PREFS_NAME = "floating_lyric_prefs";
    private static final int NOTIFICATION_ID = 9527;

    private WindowManager windowManager;
    private LinearLayout rootView;
    private TextView lyricText;
    private WindowManager.LayoutParams layoutParams;

    private float fontSize = 16f;
    private int textColor = Color.WHITE;
    private int bgColor = 0xCC000000;
    private boolean isLocked = false;

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
                if (lyricText != null && text != null) {
                    lyricText.setText(text);
                }
            } else if ("updateStyle".equals(action)) {
                fontSize = intent.getFloatExtra("fontSize", fontSize);
                textColor = intent.getIntExtra("textColor", textColor);
                bgColor = intent.getIntExtra("bgColor", bgColor);
                applyStyle();
            } else if ("setLocked".equals(action)) {
                isLocked = intent.getBooleanExtra("locked", false);
                updateTouchability();
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

    public void updateLyricText(String text) {
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
        updateTouchability();
    }

    private void createOverlayView() {
        int dp8 = dpToPx(8);
        int dp16 = dpToPx(16);

        rootView = new LinearLayout(this);
        rootView.setOrientation(LinearLayout.HORIZONTAL);
        rootView.setGravity(Gravity.CENTER_VERTICAL);
        rootView.setPadding(dp16, dp8, dp16, dp8);

        lyricText = new TextView(this);
        lyricText.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize);
        lyricText.setTextColor(textColor);
        lyricText.setMaxLines(3);
        lyricText.setGravity(Gravity.CENTER);
        lyricText.setTypeface(Typeface.DEFAULT);
        lyricText.setText("");

        LinearLayout.LayoutParams textLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        rootView.addView(lyricText, textLp);

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

    private void setupTouchListener() {
        rootView.setOnTouchListener(new View.OnTouchListener() {
            private int initialY;
            private float initialTouchY;
            private boolean isDragging = false;

            @Override
            public boolean onTouch(View v, MotionEvent event) {
                if (isLocked) return false;
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
                        }
                        return true;
                }
                return false;
            }
        });
    }

    private void updateTouchability() {
        if (layoutParams == null || rootView == null) return;
        int base = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
                | WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                | WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD;
        if (isLocked) {
            layoutParams.flags = base | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE;
        } else {
            layoutParams.flags = base;
        }
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
