package app.fushi.reader;

/**
 * 截屏 OCR 一次流程的编号与「识别中」阶段的纯状态（无 Android 依赖，JVM 单测
 * {@code ScreenOcrRecognitionGateTest} 钉住）。只在主线程读写。
 *
 * <p>BUG-4790：定格帧交给识别器（设备自带 ML Kit / Dart 侧本机模型 / Lens）期间，
 * 识别中的通知上有「取消」。取消立刻收尾这次流程（解流程锁、放回悬浮球），可那次
 * 识别本身不一定停得下来（本机模型推理在原生里跑完为止，ML Kit 没有取消接口）——
 * 它晚到的结果不能落进用户紧接着发起的下一次流程。所以每次流程有一个编号，所有
 * 异步回调带着发起时的编号回来，编号对不上的一律当过期丢掉。
 *
 * <p>通知上的取消也带着编号：用户点的是上一次流程残留的通知（或系统晚投递的
 * PendingIntent）时，不会取消掉此刻正在跑的这一次。
 */
final class ScreenOcrRecognitionGate {
    /** 当前流程的编号；0 = 这个服务实例还没跑过任何流程。 */
    private long flow = 0;
    /** 当前流程正在识别（定格帧已交出、选取层还没画出来）。 */
    private boolean recognizing = false;

    /** 新的一次流程开始（每次申请截屏 / 保持会话直接取帧）：返回它的编号，旧编号全部作废。 */
    long begin() {
        flow++;
        recognizing = false;
        return flow;
    }

    /** 当前流程的编号；0 = 还没跑过流程。 */
    long current() {
        return flow;
    }

    /** 带 {@code id} 回来的异步回调是不是当前流程的（不是就丢掉它的结果）。 */
    boolean isCurrent(long id) {
        return id != 0 && id == flow;
    }

    /** 定格帧交给识别器：从这里起到选取层画出来 / 流程收尾，通知上可以取消。 */
    void onRecognitionStarted(long id) {
        if (isCurrent(id)) recognizing = true;
    }

    /** 当前流程正处在识别阶段（识别中的通知该挂着）。 */
    boolean isRecognizing() {
        return recognizing;
    }

    /** 识别结束（选取层画出来了 / 流程收尾）：取消入口随之撤掉。 */
    void onRecognitionEnded() {
        recognizing = false;
    }

    /**
     * 通知上点了取消，带着那条通知所属流程的 {@code id}。只有当前流程、且正在识别时
     * 才接受（返回 true，同一次取消只接受一次）；过期流程或已经画出选取层的不接受。
     */
    boolean takeCancel(long id) {
        if (!isCurrent(id) || !recognizing) return false;
        recognizing = false;
        return true;
    }
}
