package app.fushi.reader;

import android.content.Context;
import android.net.wifi.WifiManager;
import android.os.PowerManager;

import androidx.annotation.NonNull;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * 下载保活期间持有的 CPU / Wi-Fi 锁（反馈 nLXqmvv5Fy：息屏后下载停）。
 *
 * <p>前台服务只把进程提升为「不该被杀」的优先级，<b>不</b>阻止 CPU 休眠：息屏一段
 * 时间后 CPU 挂起，主 Dart isolate 里的 HTTP / 互联 / libtorrent 循环随之停摆，
 * 亮屏才接着跑——正是反馈描述的现象。下载期间必须同时持有
 * {@link PowerManager#PARTIAL_WAKE_LOCK}（CPU 不睡）和 Wi-Fi 锁（Wi-Fi 不进省电
 * 模式掉速 / 断连）。
 *
 * <p>生命周期严格绑在 {@link DownloadKeepAliveService} 进前台到停止之间：服务进
 * 前台后 {@link #acquire()}，{@code stopNow} / {@code onDestroy} 里
 * {@link #release()}。两把锁都设成非引用计数，acquire / release 都幂等——服务的
 * 停止路径（Dart 撤租约、启动挂起期间的 stop、Android 15 dataSync 超时、系统销毁）
 * 会重叠，任何一条走到都必须真放锁，重复放也不能抛。进程死亡时系统自动回收。
 *
 * <p>不设超时：下载时长不可预知（整季 torrent 可以跑几小时），超时到点放锁等于
 * 息屏下载照样中途停。防泄漏靠上面的生命周期绑定，而不是靠超时。
 */
final class DownloadKeepAliveLocks {
    private static final String TAG = "Fushi:DownloadKeepAlive";

    /** 一把可持有的锁；抽出来是为了让 acquire / release 的幂等逻辑能在 JVM 单测里验。 */
    interface Lock {
        void acquire();

        void release();

        boolean isHeld();
    }

    private final List<Lock> mLocks;

    DownloadKeepAliveLocks(@NonNull List<Lock> locks) {
        mLocks = Collections.unmodifiableList(new ArrayList<>(locks));
    }

    /** 真机用：PARTIAL_WAKE_LOCK + Wi-Fi 锁（设备没有 Wi-Fi 时只有前者）。 */
    @NonNull
    static DownloadKeepAliveLocks create(@NonNull Context context) {
        final Context app = context.getApplicationContext();
        final List<Lock> locks = new ArrayList<>(2);
        PowerManager power = app.getSystemService(PowerManager.class);
        if (power != null) {
            final PowerManager.WakeLock wake =
                    power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, TAG);
            wake.setReferenceCounted(false);
            locks.add(new Lock() {
                @Override
                public void acquire() {
                    wake.acquire();
                }

                @Override
                public void release() {
                    wake.release();
                }

                @Override
                public boolean isHeld() {
                    return wake.isHeld();
                }
            });
        }
        WifiManager wifi = app.getSystemService(WifiManager.class);
        if (wifi != null) {
            // HIGH_PERF 是后台长时间传输的模式（LOW_LATENCY 只在前台亮屏时生效）。
            // 新系统版本对它的处理以平台为准；让 CPU 不睡的是上面的 wake lock。
            @SuppressWarnings("deprecation")
            final WifiManager.WifiLock wifiLock =
                    wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, TAG);
            wifiLock.setReferenceCounted(false);
            locks.add(new Lock() {
                @Override
                public void acquire() {
                    wifiLock.acquire();
                }

                @Override
                public void release() {
                    wifiLock.release();
                }

                @Override
                public boolean isHeld() {
                    return wifiLock.isHeld();
                }
            });
        }
        return new DownloadKeepAliveLocks(locks);
    }

    /** 拿齐所有锁；已持有的不重复拿。 */
    void acquire() {
        for (Lock lock : mLocks) {
            if (!lock.isHeld()) lock.acquire();
        }
    }

    /** 放掉所有锁；没持有的跳过（重复调用安全）。 */
    void release() {
        for (Lock lock : mLocks) {
            if (lock.isHeld()) lock.release();
        }
    }

    /** 是否还有任何一把锁被持有。 */
    boolean isAnyHeld() {
        for (Lock lock : mLocks) {
            if (lock.isHeld()) return true;
        }
        return false;
    }
}
