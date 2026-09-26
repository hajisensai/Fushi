package app.fushi.reader;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;
import androidx.core.app.ServiceCompat;
import androidx.core.content.ContextCompat;

import app.fushi.reader.constants.ChannelNames;
import app.fushi.reader.constants.NotificationIds;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/**
 * 互联下载保活前台服务（foregroundServiceType = dataSync）。
 *
 * <p>互联下载（手机从已配对电脑拉视频）跑在主 Dart isolate 的
 * {@code InterconnectDownloadManager} 里，没有任何原生组件托底。用户一切走，
 * 进程只剩一个不可见 Activity，系统随时可以杀掉，下载随进程一起死。这个服务
 * 只做一件事：下载进行期间挂一条常驻进度通知，把进程提升为前台服务优先级。
 * 它**不**下载任何东西，也不在进程死后自我复活（{@link #START_NOT_STICKY}）——
 * Dart 侧随进程一起没了，复活一个空服务毫无意义，断点续传由 Dart 侧负责。
 *
 * <p>Dart 门面：{@code lib/src/platform/mobile/android_download_keep_alive.dart}，
 * 通道 {@link ChannelNames#DOWNLOAD_KEEP_ALIVE}；方法名 / 参数名是跨语言契约。
 *
 * <p><b>后台启动限制</b>（Android 12+）：后台调用 {@code startForegroundService}
 * 会抛 {@code ForegroundServiceStartNotAllowedException}。所以只有「服务还没在跑」
 * 时才走 startForegroundService（此时用户刚在前台点了下载）；服务已在跑时的
 * 进度更新直接改通知，不再经过 startForegroundService——否则切到后台后的第一条
 * 进度更新就会撞上这条限制。启动失败只记日志，不崩。
 *
 * <p>所有入口（通道回调、onStartCommand、onDestroy）都在主线程，静态状态不加锁。
 */
public final class DownloadKeepAliveService extends Service {
    private static final String TAG = "FushiDownloadKeepAlive";

    private static final String ACTION_UPDATE = "app.fushi.reader.action.DOWNLOAD_KEEP_ALIVE_UPDATE";
    private static final String EXTRA_TITLE = "title";
    private static final String EXTRA_TEXT = "text";
    private static final String EXTRA_PROGRESS = "progress";

    private static final String METHOD_UPDATE = "update";
    private static final String METHOD_STOP = "stop";

    /** 已进入前台的服务实例；null = 没在跑。 */
    @Nullable
    private static DownloadKeepAliveService sInstance;

    /** 已发出 startForegroundService、但 onStartCommand 还没到。 */
    private static boolean sStartPending;

    /** 启动挂起期间收到了 stop：进前台后立刻收尾（不能在 startForeground 之前停）。 */
    private static boolean sStopRequested;

    /** 启动挂起期间收到的最新状态，onStartCommand 时以它为准。 */
    @Nullable
    private static Intent sPendingState;

    // ── 通道 ────────────────────────────────────────────────────────────────

    public static void registerWith(@NonNull FlutterEngine engine, @NonNull Context context) {
        final Context appContext = context.getApplicationContext();
        new MethodChannel(
                engine.getDartExecutor().getBinaryMessenger(), ChannelNames.DOWNLOAD_KEEP_ALIVE)
                .setMethodCallHandler((call, result) -> {
                    switch (call.method) {
                        case METHOD_UPDATE: {
                            String title = call.argument(EXTRA_TITLE);
                            String text = call.argument(EXTRA_TEXT);
                            Integer progress = call.argument(EXTRA_PROGRESS);
                            update(appContext,
                                    title != null ? title : "",
                                    text != null ? text : "",
                                    progress != null ? progress : -1);
                            result.success(null);
                            return;
                        }
                        case METHOD_STOP:
                            stop(appContext);
                            result.success(null);
                            return;
                        default:
                            result.notImplemented();
                    }
                });
    }

    /** 服务在跑就直接改通知；没在跑就（前台时）拉起前台服务。 */
    static void update(@NonNull Context context, @NonNull String title, @NonNull String text,
            int progress) {
        sStopRequested = false;
        if (sInstance != null) {
            sInstance.showState(title, text, progress);
            return;
        }
        Intent intent = new Intent(context, DownloadKeepAliveService.class)
                .setAction(ACTION_UPDATE)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_TEXT, text)
                .putExtra(EXTRA_PROGRESS, progress);
        sPendingState = intent;
        if (sStartPending) {
            return;
        }
        try {
            ContextCompat.startForegroundService(context, intent);
            sStartPending = true;
        } catch (RuntimeException e) {
            // Android 12+ 后台启动（ForegroundServiceStartNotAllowedException 是
            // IllegalStateException 子类）/ 8+ 后台 startService 限制。下载照常跑，
            // 只是没有保活。
            sPendingState = null;
            Log.w(TAG, "startForegroundService rejected: " + e);
        }
    }

    static void stop(@NonNull Context context) {
        sPendingState = null;
        if (sInstance != null) {
            sInstance.stopNow();
            return;
        }
        if (sStartPending) {
            // 系统已答应拉起服务：此时停掉会触发「startForegroundService 后没有
            // startForeground」的 ANR/崩溃，等 onStartCommand 进前台后再收尾。
            sStopRequested = true;
        }
    }

    // ── Service ─────────────────────────────────────────────────────────────

    @Override
    public int onStartCommand(@Nullable Intent intent, int flags, int startId) {
        sStartPending = false;
        Intent state = sPendingState != null ? sPendingState : intent;
        sPendingState = null;
        String title = state != null ? state.getStringExtra(EXTRA_TITLE) : null;
        String text = state != null ? state.getStringExtra(EXTRA_TEXT) : null;
        int progress = state != null ? state.getIntExtra(EXTRA_PROGRESS, -1) : -1;
        createNotificationChannel();
        Notification notification = buildNotification(
                title != null ? title : "", text != null ? text : "", progress);
        try {
            ServiceCompat.startForeground(this, NotificationIds.DOWNLOAD_KEEP_ALIVE, notification,
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
                            ? ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                            : 0);
        } catch (RuntimeException e) {
            // Android 12+ 在后台被拉起时 startForeground 同样可能被拒；
            // Android 15 dataSync 超出每日时长配额时也会拒。
            Log.w(TAG, "startForeground rejected: " + e);
            sStopRequested = false;
            stopSelf();
            return START_NOT_STICKY;
        }
        sInstance = this;
        if (sStopRequested) {
            sStopRequested = false;
            stopNow();
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
        if (sInstance == this) {
            sInstance = null;
        }
        super.onDestroy();
    }

    /**
     * Android 15+：dataSync 前台服务用满系统时长配额后回调；此时必须在几秒内
     * 停掉，否则系统判定为 ANR 并杀进程——那就连下载也一起没了。
     */
    @Override
    public void onTimeout(int startId, int fgsType) {
        Log.w(TAG, "dataSync foreground time limit reached, stopping keep-alive");
        stopNow();
    }

    private void stopNow() {
        if (sInstance == this) {
            sInstance = null;
        }
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE);
        stopSelf();
    }

    private void showState(@NonNull String title, @NonNull String text, int progress) {
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager == null) return;
        manager.notify(NotificationIds.DOWNLOAD_KEEP_ALIVE, buildNotification(title, text, progress));
    }

    // ── Notification ────────────────────────────────────────────────────────

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager == null) return;
        NotificationChannel channel = new NotificationChannel(
                NotificationIds.CHANNEL_DOWNLOAD_KEEP_ALIVE,
                "Downloads",
                NotificationManager.IMPORTANCE_LOW);
        channel.setShowBadge(false);
        channel.setSound(null, null);
        channel.enableVibration(false);
        manager.createNotificationChannel(channel);
    }

    @NonNull
    private Notification buildNotification(@NonNull String title, @NonNull String text,
            int progress) {
        Intent open = new Intent(this, MainActivity.class)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent contentIntent = PendingIntent.getActivity(this, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        boolean determinate = progress >= 0 && progress <= 100;
        return new NotificationCompat.Builder(this, NotificationIds.CHANNEL_DOWNLOAD_KEEP_ALIVE)
                .setSmallIcon(R.drawable.ic_stat_fushi)
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(contentIntent)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setShowWhen(false)
                .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .setProgress(100, determinate ? progress : 0, !determinate)
                .build();
    }
}
