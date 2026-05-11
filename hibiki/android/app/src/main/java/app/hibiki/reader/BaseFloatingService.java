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
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;

import androidx.annotation.Nullable;

public abstract class BaseFloatingService extends Service {

    protected WindowManager windowManager;
    protected View rootView;
    protected WindowManager.LayoutParams layoutParams;

    protected abstract View createContentView();
    protected abstract String getPreferencePrefix();
    protected abstract String getNotificationChannelId();
    protected abstract String getNotificationChannelName();
    protected abstract int getNotificationId();
    protected abstract Notification buildNotification();
    protected abstract void onServiceCommand(Intent intent);

    @Override
    public void onCreate() {
        super.onCreate();
        windowManager = (WindowManager) getSystemService(Context.WINDOW_SERVICE);
        createNotificationChannel();
        startForeground(getNotificationId(), buildNotification());
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

    protected void setupOverlay() {
        SharedPreferences prefs = getSharedPreferences(getPreferencePrefix(), MODE_PRIVATE);
        int savedX = prefs.getInt("posX", 0);
        int savedY = prefs.getInt("posY", 100);

        layoutParams = createLayoutParams();
        layoutParams.x = savedX;
        layoutParams.y = savedY;

        setupDragListener();
        windowManager.addView(rootView, layoutParams);
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

    protected void setupDragListener() {
        rootView.setOnTouchListener(new View.OnTouchListener() {
            private int initialY;
            private float initialTouchY;
            private boolean isDragging = false;

            @Override
            public boolean onTouch(View v, MotionEvent event) {
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
                        if (isDragging) savePosition();
                        else onOverlayTap(v, event);
                        return true;
                }
                return false;
            }
        });
    }

    protected void onOverlayTap(View v, MotionEvent event) {
    }

    protected void savePosition() {
        if (layoutParams == null) return;
        getSharedPreferences(getPreferencePrefix(), MODE_PRIVATE)
                .edit()
                .putInt("posX", layoutParams.x)
                .putInt("posY", layoutParams.y)
                .apply();
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    getNotificationChannelId(),
                    getNotificationChannelName(),
                    NotificationManager.IMPORTANCE_LOW);
            channel.setShowBadge(false);
            getSystemService(NotificationManager.class)
                    .createNotificationChannel(channel);
        }
    }

    protected int dpToPx(int dp) {
        return (int) (dp * getResources().getDisplayMetrics().density);
    }
}
