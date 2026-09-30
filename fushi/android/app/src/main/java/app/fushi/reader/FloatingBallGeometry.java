package app.fushi.reader;

import android.graphics.Rect;

/**
 * 应用外悬浮球的几何（纯计算，物理 px）：与应用内球的
 * {@code lib/src/reader/reader_floating_ball.dart} 里 {@code ReaderFloatingBallLayout}
 * 逐项同一套公式，两边的观感才能一致——改一边必须改另一边（守卫
 * {@code test/floating_ball/system_floating_ball_native_guard_test.dart} 钉常量）。
 *
 * <p>坐标系：窗口 {@code gravity = TOP|START}、{@code fitInsetsTypes = 0}、
 * {@code FLAG_LAYOUT_IN_SCREEN}，x/y 就是整块显示区的坐标；{@link #viewport} 是显示区扣掉
 * 系统栏与刘海的安全区（= 应用内球的「整窗扣掉系统 inset」）。
 *
 * <p>位置只存「停靠边 + 球在活动范围里的纵向比例」，不存 px：旋转 / 分辨率变化后按新
 * 视口重算，永远落在屏内（BUG-2793：旧实现存 px，竖屏里 x=2328 的球转成宽 1600 的
 * 竖屏就整个跑到屏外）。
 */
final class FloatingBallGeometry {
    // 与 Dart kReaderFloatingBall* 同值（dp）。
    static final int BALL_DP = 48;
    static final int BUTTON_DP = 40;
    static final int GAP_DP = 6;
    static final int MARGIN_DP = 8;
    /** 收起时缩进停靠边外的比例（Dart tuck = ballSize * 0.34）。 */
    static final float TUCK_RATIO = 0.34f;
    /** 收起态不透明度（Dart kReaderFloatingBallIdleOpacity）。 */
    static final float IDLE_OPACITY = 0.42f;

    final Rect viewport;
    final boolean dockLeft;
    final float verticalFraction;
    final int actionCount;
    final int ball;
    final int button;
    final int gap;
    final int margin;

    FloatingBallGeometry(
            Rect viewport,
            boolean dockLeft,
            float verticalFraction,
            int actionCount,
            float density) {
        this.viewport = new Rect(viewport);
        this.dockLeft = dockLeft;
        this.verticalFraction = verticalFraction;
        this.actionCount = Math.max(0, actionCount);
        this.ball = Math.round(BALL_DP * density);
        this.button = Math.round(BUTTON_DP * density);
        this.gap = Math.round(GAP_DP * density);
        this.margin = Math.round(MARGIN_DP * density);
    }

    int tuck() {
        return Math.round(ball * TUCK_RATIO);
    }

    /** 相邻两颗按钮中心的竖向间距，也是相邻两列的横向间距。 */
    int pitch() {
        return button + gap;
    }

    /** 每列最多几颗：视口扣掉上下 margin 与球后，球顶以上还能放几个 pitch（至少 1）。 */
    int perColumn() {
        int available = viewport.height() - 2 * margin - ball;
        if (available < pitch()) return 1;
        return Math.max(1, available / pitch());
    }

    int columnCount() {
        if (actionCount == 0) return 0;
        int per = perColumn();
        return (actionCount + per - 1) / per;
    }

    /** 最高一列的颗数（= 第一列）。 */
    int rowCount() {
        return Math.min(actionCount, perColumn());
    }

    /** 新列朝屏幕中央展开：左停靠往右 +1，右停靠往左 -1。 */
    int columnDirection() {
        return dockLeft ? 1 : -1;
    }

    /**
     * 第 index 颗按钮中心相对球心的偏移（展开态）：列表末颗离球最近、紧贴球顶，
     * 先自下而上填满第一列，再往中央方向换列（Dart {@code buttonOffset}）。
     */
    int[] buttonOffset(int index) {
        int slot = actionCount - 1 - index;
        int per = perColumn();
        int column = slot / per;
        int row = slot % per;
        int nearest = ball / 2 + gap + button / 2;
        return new int[] {columnDirection() * column * pitch(), -(nearest + row * pitch())};
    }

    /** 展开态按钮区从球心向上伸出的距离（到最高一颗的上缘）。 */
    int reach() {
        return actionCount == 0 ? 0 : ball / 2 + rowCount() * pitch();
    }

    int minTop() {
        return viewport.top + margin;
    }

    int maxTop() {
        return Math.max(minTop(), viewport.bottom - ball - margin);
    }

    /** 收起态球顶边 y（比例落在活动范围内）。 */
    int ballTop() {
        float f = Float.isNaN(verticalFraction) ? 0.5f
                : Math.max(0f, Math.min(1f, verticalFraction));
        return Math.round(minTop() + (maxTop() - minTop()) * f);
    }

    /** 展开态球顶边 y：最高一列要放得进视口，放不下把球沿边往下滑。 */
    int expandedBallTop() {
        int lo = viewport.top + margin + reach() - ball / 2;
        int max = maxTop();
        if (max < lo) return max;
        return Math.max(lo, Math.min(max, ballTop()));
    }

    /** 收起态球左边 x：停靠边外缩 tuck。 */
    int collapsedBallLeft() {
        return dockLeft ? viewport.left - tuck() : viewport.right - ball + tuck();
    }

    /** 展开态球左边 x：整球回到视口内、贴边留 margin。 */
    int expandedBallLeft() {
        return dockLeft ? viewport.left + margin : viewport.right - ball - margin;
    }

    /** 任意球顶 y 反算持久化比例。 */
    float fractionForTop(int top) {
        int span = maxTop() - minTop();
        if (span <= 0) return 0.5f;
        return Math.max(0f, Math.min(1f, (top - minTop()) / (float) span));
    }

    /** 松手时按球心落在视口左右哪一半决定停靠边。 */
    boolean dockLeftForBallLeft(int ballLeft) {
        return ballLeft + ball / 2 < viewport.centerX();
    }
}
