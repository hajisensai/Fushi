package app.fushi.reader;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioPlaybackCaptureConfiguration;
import android.media.AudioRecord;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Process;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;

import java.util.Map;

import app.fushi.reader.constants.NotificationIds;

/**
 * 跨应用语音挖掘（拍板 oqk37s3QFL）：用户同意后用 AudioPlaybackCapture（Android 10+）
 * 在后台循环录其他 app 播放的声音，写进 {@link CrossAppAudioRing}（最近
 * {@link #RING_SECONDS} 秒）。查词窗（{@code :popup} 进程）在查词那一刻经
 * {@link CrossAppAudioProvider} 取最近一段落成文件，制卡时截出语音挂到句子音频上。
 *
 * <p>类型是 mediaProjection（+ microphone，Android 11 起后台录音要求）前台服务：
 * Android 14 起 {@code getMediaProjection} 必须在该类型前台服务里、且在
 * {@code startForeground} 之后调用。通知上有「停止」；用户在系统里停止共享时
 * {@link MediaProjection.Callback#onStop} 收掉采集。
 *
 * <p>目标 app 可以用 {@code allowAudioPlaybackCapture=false} / 播放策略拒绝被录——那种
 * app 录到的是静音，这是系统限制，不是故障。本 app 自己的声音（查词读音等）不录。
 */
public class CrossAppAudioService extends Service {
    private static final String TAG = "CrossAppAudioService";

    static final String EXTRA_RESULT_CODE = "resultCode";
    static final String EXTRA_RESULT_DATA = "resultData";
    static final String EXTRA_LABELS = "labels";
    static final String ACTION_STOP = "app.fushi.reader.CROSS_APP_AUDIO_STOP";

    static final String LABEL_NOTIFICATION = "notification";
    static final String LABEL_STOP = "stop";

    /** 采集格式：48 kHz 单声道 16-bit（制卡语音不需要立体声，环内存减半）。 */
    static final int SAMPLE_RATE = 48000;
    static final int CHANNELS = 1;
    static final int BITS_PER_SAMPLE = 16;
    /** 环容量（秒）：与 Windows loopback 环同值。 */
    static final int RING_SECONDS = 60;
    static final int BLOCK_ALIGN = CHANNELS * BITS_PER_SAMPLE / 8;
    static final int BYTE_RATE = SAMPLE_RATE * BLOCK_ALIGN;

    /** 采集状态变化（主线程回调）。 */
    interface StateListener {
        void onStateChanged(boolean running, @Nullable String error);
    }

    @Nullable private static volatile CrossAppAudioService instance;
    @Nullable private static StateListener stateListener;

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    @Nullable private MediaProjection projection;
    @Nullable private AudioRecord record;
    @Nullable private Thread captureThread;
    @Nullable private CrossAppAudioRing ring;
    private volatile boolean capturing = false;
    private Map<String, String> labels = new java.util.HashMap<>();

    static void setStateListener(@Nullable StateListener listener) {
        stateListener = listener;
    }

    static boolean isRunning() {
        CrossAppAudioService s = instance;
        return s != null && s.capturing;
    }

    /** 取最近 [backMs] 毫秒的 PCM（16-bit 单声道）；没在录返回 null。任意线程。 */
    @Nullable
    static byte[] snapshot(int backMs) {
        CrossAppAudioService s = instance;
        CrossAppAudioRing r = s == null ? null : s.ring;
        if (s == null || !s.capturing || r == null) return null;
        long bytes = (long) Math.max(0, backMs) * BYTE_RATE / 1000L;
        return r.tail((int) Math.min(Integer.MAX_VALUE, bytes));
    }

    /** 停止采集（任意线程；切到主线程执行）。没在录时什么都不做。 */
    static void requestStop() {
        CrossAppAudioService s = instance;
        if (s == null) return;
        s.mainHandler.post(s::stopCaptureAndSelf);
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            stopCaptureAndSelf();
            return START_NOT_STICKY;
        }
        if (capturing || intent == null) {
            // 已在录（重复同意）或系统重投空 intent（授权不可复用，没法自己续上）。
            if (!capturing) stopSelf();
            return START_NOT_STICKY;
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            fail("unsupported");
            return START_NOT_STICKY;
        }
        labels = ScreenCaptureRequestActivity.fromBundle(intent.getBundleExtra(EXTRA_LABELS));
        try {
            startForegroundTyped();
        } catch (RuntimeException e) {
            Log.w(TAG, "startForeground failed", e);
            fail("start_failed");
            return START_NOT_STICKY;
        }
        int resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0);
        Intent data = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                ? intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent.class)
                : intent.getParcelableExtra(EXTRA_RESULT_DATA);
        MediaProjectionManager mpm = getSystemService(MediaProjectionManager.class);
        try {
            projection = (mpm == null || data == null)
                    ? null
                    : mpm.getMediaProjection(resultCode, data);
        } catch (RuntimeException e) {
            Log.w(TAG, "getMediaProjection failed", e);
            projection = null;
        }
        if (projection == null) {
            fail("start_failed");
            return START_NOT_STICKY;
        }
        if (!startCapture(projection)) {
            fail("start_failed");
            return START_NOT_STICKY;
        }
        return START_NOT_STICKY;
    }

    private void startForegroundTyped() {
        Notification notification = buildNotification();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startForeground(NotificationIds.CROSS_APP_AUDIO, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                            | ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE);
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NotificationIds.CROSS_APP_AUDIO, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
        } else {
            startForeground(NotificationIds.CROSS_APP_AUDIO, notification);
        }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private boolean startCapture(@NonNull MediaProjection current) {
        current.registerCallback(new MediaProjection.Callback() {
            @Override
            public void onStop() {
                // 用户在系统里停止共享 / 授权被收回：采集随之结束。
                if (current == projection) mainHandler.post(() -> stopCaptureAndSelf());
            }
        }, mainHandler);
        AudioRecord created;
        try {
            AudioPlaybackCaptureConfiguration config =
                    new AudioPlaybackCaptureConfiguration.Builder(current)
                            .addMatchingUsage(AudioAttributes.USAGE_GAME)
                            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                            .build();
            AudioFormat format = new AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                    .build();
            int minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
            created = new AudioRecord.Builder()
                    .setAudioFormat(format)
                    .setBufferSizeInBytes(Math.max(minBuffer, BYTE_RATE / 2))
                    .setAudioPlaybackCaptureConfig(config)
                    .build();
        } catch (RuntimeException e) {
            // 没有 RECORD_AUDIO（SecurityException）/ 参数不被设备支持。
            Log.w(TAG, "AudioRecord (playback capture) could not be created", e);
            return false;
        }
        if (created.getState() != AudioRecord.STATE_INITIALIZED) {
            created.release();
            return false;
        }
        try {
            created.startRecording();
        } catch (RuntimeException e) {
            Log.w(TAG, "startRecording failed", e);
            created.release();
            return false;
        }
        record = created;
        ring = new CrossAppAudioRing(BYTE_RATE * RING_SECONDS, BLOCK_ALIGN);
        capturing = true;
        instance = this;
        final AudioRecord rec = created;
        final CrossAppAudioRing target = ring;
        captureThread = new Thread(() -> {
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO);
            byte[] chunk = new byte[BYTE_RATE / 20];
            while (capturing) {
                int n = rec.read(chunk, 0, chunk.length);
                if (n > 0) {
                    target.write(chunk, 0, n);
                } else if (n < 0) {
                    Log.w(TAG, "AudioRecord.read returned " + n);
                    mainHandler.post(this::stopCaptureAndSelf);
                    break;
                }
            }
        }, "fushi-cross-app-audio");
        captureThread.start();
        // 截屏识字借用这份授权取帧，不再另申请（另申请会让系统停掉它，BUG-4922）。
        ProjectionShare.MEDIA.publish(current);
        CrossAppAudioProvider.setCapturingMarker(this, true);
        notifyState(true, null);
        return true;
    }

    private void fail(@NonNull String error) {
        releaseCapture();
        stopForegroundCompat();
        stopSelf();
        notifyState(false, error);
    }

    private void stopCaptureAndSelf() {
        boolean wasCapturing = capturing;
        releaseCapture();
        stopForegroundCompat();
        stopSelf();
        if (wasCapturing) notifyState(false, null);
    }

    private void releaseCapture() {
        boolean wasCapturing = capturing;
        // 先置假再清扫：provider 的快照与清扫互斥，清扫之后的快照请求看到的是「没在录」。
        capturing = false;
        if (instance == this) instance = null;
        if (wasCapturing) {
            CrossAppAudioProvider.setCapturingMarker(this, false);
            CrossAppAudioProvider.deleteSnapshots(this);
        }
        Thread thread = captureThread;
        captureThread = null;
        AudioRecord rec = record;
        record = null;
        if (rec != null) {
            try {
                rec.stop();
            } catch (IllegalStateException e) {
                Log.w(TAG, "AudioRecord.stop failed", e);
            }
        }
        if (thread != null) {
            try {
                thread.join(1000);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        if (rec != null) rec.release();
        MediaProjection p = projection;
        projection = null;
        if (p != null) {
            // 先撤下共享（放掉截屏识字借用的虚拟屏），再停投屏。
            ProjectionShare.MEDIA.withdraw(p);
            p.stop();
        }
        CrossAppAudioRing r = ring;
        ring = null;
        if (r != null) r.clear();
    }

    private void stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE);
        } else {
            stopForeground(true);
        }
    }

    private void notifyState(boolean running, @Nullable String error) {
        mainHandler.post(() -> {
            StateListener listener = stateListener;
            if (listener != null) listener.onStateChanged(running, error);
        });
    }

    @Override
    public void onDestroy() {
        boolean wasCapturing = capturing;
        releaseCapture();
        if (wasCapturing) notifyState(false, null);
        super.onDestroy();
    }

    private String label(String key, String fallback) {
        String value = labels.get(key);
        return value == null || value.isEmpty() ? fallback : value;
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        NotificationChannel channel = new NotificationChannel(
                NotificationIds.CHANNEL_CROSS_APP_AUDIO,
                "App audio capture",
                NotificationManager.IMPORTANCE_LOW);
        channel.setShowBadge(false);
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm != null) nm.createNotificationChannel(channel);
    }

    private Notification buildNotification() {
        Intent stop = new Intent(this, CrossAppAudioService.class).setAction(ACTION_STOP);
        PendingIntent stopIntent = PendingIntent.getService(this, 0, stop,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, NotificationIds.CHANNEL_CROSS_APP_AUDIO)
                : new Notification.Builder(this);
        Notification.Action action = new Notification.Action.Builder(
                (android.graphics.drawable.Icon) null, label(LABEL_STOP, "Stop"), stopIntent).build();
        return builder
                .setContentTitle(label(LABEL_NOTIFICATION, "Capturing app audio for card mining"))
                .setSmallIcon(R.drawable.ic_stat_fushi)
                .setOngoing(true)
                .addAction(action)
                .build();
    }
}
