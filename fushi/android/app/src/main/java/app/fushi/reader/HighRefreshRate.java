package app.fushi.reader;

import android.app.Activity;
import android.os.Build;
import android.util.Log;
import android.view.Display;
import android.view.Window;
import android.view.WindowManager;

/**
 * 让本 App 的每个原生窗口主动向系统请求「与当前分辨率相同、刷新率最高」的
 * {@link Display.Mode}。Flutter/WebView 本身从不请求高刷，很多机型在自适应刷新 /
 * 省电策略下会把没表态的第三方 App 钉在 60Hz 甚至更低——阅读器主窗口、查词弹窗
 * （{@code PopupDictFlutterActivity}，独立 {@code :popup} 进程、独立 window，绝不
 * 继承 MainActivity 的偏好）、悬浮查词 / 悬浮歌词窗整屏明显掉刷新率。
 *
 * <p>这里只声明偏好（{@code preferredDisplayModeId}），由系统调度；拿不到 display /
 * 无更高模式 / 任意异常都安全退化为系统默认，never break userspace。等价于
 * flutter_displaymode 的原生做法，但不引入依赖。
 *
 * <p>覆盖两种窗口形态各一个入口：Activity 主窗口走 {@link #applyToActivity(Activity)}
 * （改 {@code window.attributes}）；悬浮窗 overlay 走
 * {@link #applyToLayoutParams(WindowManager.LayoutParams, WindowManager)}（在
 * {@code addView} 之前改 {@link WindowManager.LayoutParams}）。
 */
public final class HighRefreshRate {
    private static final String TAG = "hibiki-refresh";

    private HighRefreshRate() {}

    /**
     * 在 {@code display} 支持的所有模式里挑一个与当前分辨率一致、刷新率严格更高
     * （+1f 容差抗浮点抖动）的模式，返回其 {@code modeId}；当前已是最高刷 / 无可用
     * 模式 / {@code display} 为空时返回 0（= 不表态，系统默认）。
     *
     * @param display 目标窗口所在的显示器，可为 null。
     * @return 目标 {@code Display.Mode} 的 id，或 0 表示不改。
     */
    public static int bestModeId(Display display) {
        if (display == null) return 0;
        Display.Mode current = display.getMode();
        Display.Mode[] modes = display.getSupportedModes();
        if (current == null || modes == null || modes.length == 0) return 0;
        int bestModeId = 0;
        float bestRate = current.getRefreshRate();
        for (Display.Mode mode : modes) {
            // 只在与当前分辨率一致的模式里挑，避免顺带改了分辨率。
            if (mode.getPhysicalWidth() == current.getPhysicalWidth()
                    && mode.getPhysicalHeight() == current.getPhysicalHeight()
                    && mode.getRefreshRate() > bestRate + 1f) {
                bestRate = mode.getRefreshRate();
                bestModeId = mode.getModeId();
            }
        }
        return bestModeId;
    }

    /** 给 Activity 主窗口请求最高刷新率。须在 {@code super.onCreate} 之后调用。安全 no-op 退化。 */
    public static void applyToActivity(Activity activity) {
        if (activity == null) return;
        try {
            Display display = (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                    ? activity.getDisplay()
                    : activity.getWindowManager().getDefaultDisplay();
            int modeId = bestModeId(display);
            if (modeId == 0) return;
            Window window = activity.getWindow();
            if (window == null) return;
            WindowManager.LayoutParams lp = window.getAttributes();
            lp.preferredDisplayModeId = modeId;
            window.setAttributes(lp);
        } catch (Exception e) {
            Log.w(TAG, "request high refresh rate (activity) failed", e);
        }
    }

    /**
     * 给悬浮窗 overlay 的 {@link WindowManager.LayoutParams} 请求最高刷新率。须在
     * {@code windowManager.addView(view, lp)} 之前调用，用该 overlay 的
     * {@link WindowManager} 解析所在 display。安全 no-op 退化。
     */
    public static void applyToLayoutParams(WindowManager.LayoutParams lp, WindowManager wm) {
        if (lp == null || wm == null) return;
        try {
            int modeId = bestModeId(wm.getDefaultDisplay());
            if (modeId == 0) return;
            lp.preferredDisplayModeId = modeId;
        } catch (Exception e) {
            Log.w(TAG, "request high refresh rate (overlay) failed", e);
        }
    }
}
