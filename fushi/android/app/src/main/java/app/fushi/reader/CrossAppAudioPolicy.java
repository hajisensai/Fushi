package app.fushi.reader;

import androidx.annotation.NonNull;

/**
 * 跨应用语音缓存的纯判定（不碰任何 Android 类，JVM 单测直接测，见
 * {@code CrossAppAudioPolicyTest}）。
 */
final class CrossAppAudioPolicy {
    static final String METHOD_STATUS = "status";
    static final String METHOD_STOP = "stop";
    static final String METHOD_SNAPSHOT = "snapshot";

    private CrossAppAudioPolicy() {}

    /**
     * 通道方法是否要走 {@link CrossAppAudioProvider} 的跨进程 RPC。这些方法一律投到后台
     * 线程：Binder 往返可能把主进程冷启动，snapshot 还要在 Provider 端同步写约 2.9MB 的
     * PCM 文件，放在平台主线程上会卡住查词窗（BUG-4791）。其余方法（isSupported 只读本地
     * 常量；start 要起 Activity 且读写只在主线程的 pendingStart；encodeAac 自己投编码线程）
     * 留在主线程。
     */
    static boolean callsProviderOffMain(@NonNull String method) {
        switch (method) {
            case METHOD_STATUS:
            case METHOD_STOP:
            case METHOD_SNAPSHOT:
                return true;
            default:
                return false;
        }
    }

    /**
     * 授权页销毁时要不要把挂着的 start 结成 {@code denied}（BUG-4792）。只有配置变更
     * 重建（旋转等，同进程马上有新实例接着等回调）才不结；系统回收、从最近任务划掉这类
     * 非 finishing 的销毁之后 Activity 未必重建，不结账 {@code pendingStart} 就永远挂着，
     * 之后每次开启都回 busy。重复结账无害：{@link CrossAppAudioChannel#completeStart}
     * 没有挂起请求时什么都不做，授权结果若仍到达并起了服务，状态经 onState 推给 Dart。
     */
    static boolean releasesPendingStartOnDestroy(boolean owesResult,
            boolean changingConfigurations) {
        return owesResult && !changingConfigurations;
    }
}
