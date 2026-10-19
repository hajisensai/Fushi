package app.fushi.reader;

/**
 * 截屏 OCR 流程里两件「欠账」的纯状态（无 Android 依赖，JVM 单测
 * {@code ScreenOcrFlowLatchTest} 钉住）。只在主线程读写。
 *
 * <p><b>发起了、宿主 Activity 却没起来</b>（BUG-3603）：{@link ScreenCaptureRequestActivity#launch}
 * 只是把 Intent 交给系统，返回 true 不代表 Activity 会出现——vivo 等 ROM 的「后台弹出界面」
 * 权限没开时，后台 startActivity 被<em>静默丢弃</em>（Android 9 没有 AOSP 的后台启动限制，
 * 不抛异常、没有回调）。Activity 一旦真的起来，{@code onCreate} 会先于 Fushi 主界面的下一次
 * {@code onResume}（发起时 Fushi 若在前台，宿主 Activity 盖上来时它先被 pause）。所以：
 * 登记过发起、Activity 一直没 onCreate、此刻也没有流程在跑，就是那次发起被丢了。
 *
 * <p><b>欠 Dart 一次 {@code screenOcrFinished}</b>（BUG-3602）：Dart 发起的截屏 OCR 先把应用内球
 * 藏起来，等这条回调再放回来。原来回调时主引擎通道不在（MainActivity 已销毁，但 audio_service
 * 的缓存引擎与 Dart isolate 还活着）就直接丢掉，或者发起被丢弃后永远等不到回调——应用内球
 * 从此一直藏着，而 Fushi 在前台时系统球又让位给应用内球，用户在应用内就一颗球都看不到。
 * 现在送不出去的回调留着，等主界面回到前台（通道重新挂上）补发。
 */
final class ScreenOcrFlowLatch {
    /** 发起已交给系统、宿主 Activity 还没 onCreate。 */
    private boolean launchRequested = false;
    /** Dart 发起的流程还欠一次 screenOcrFinished。 */
    private boolean dartOwed = false;
    /** 该回调时通道不在，等通道回来补发。 */
    private boolean finishUndelivered = false;

    /** 把宿主 Activity 的 Intent 交给系统之后调用。 */
    void onLaunchRequested() {
        launchRequested = true;
    }

    /** 宿主 Activity 的 onCreate（任何分支）：这次发起没被丢。 */
    void onHostCreated() {
        launchRequested = false;
    }

    /**
     * 上一次发起是否被系统丢弃（读即清）。{@code flowActive} 为 true 时流程还在跑，
     * 不算丢弃。
     */
    boolean takeDroppedLaunch(boolean flowActive) {
        if (!launchRequested || flowActive) return false;
        launchRequested = false;
        return true;
    }

    /** Dart 的 startScreenOcr 返回了 true：欠它一次回调。旧的未送达回调作废（新回调会覆盖它）。 */
    void onDartStarted() {
        dartOwed = true;
        finishUndelivered = false;
    }

    /**
     * 流程结束（或已截到帧）：是否此刻要给 Dart 发回调。不欠就 false；欠但通道不在就
     * 记成未送达、返回 false；否则清账并返回 true。
     */
    boolean finish(boolean channelAvailable) {
        if (!dartOwed) return false;
        dartOwed = false;
        if (!channelAvailable) {
            finishUndelivered = true;
            return false;
        }
        return true;
    }

    /** 通道回来了：是否要补发之前没送达的回调（读即清；通道还不在就继续留着）。 */
    boolean takeUndelivered(boolean channelAvailable) {
        if (!finishUndelivered || !channelAvailable) return false;
        finishUndelivered = false;
        return true;
    }

    /** 回调发送失败（通道在但抛异常）：改记未送达，等下次回到前台再补。 */
    void onDeliveryFailed() {
        finishUndelivered = true;
    }
}
