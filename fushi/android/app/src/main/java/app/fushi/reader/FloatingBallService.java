package app.fushi.reader;

import android.animation.Animator;
import android.animation.AnimatorListenerAdapter;
import android.animation.ValueAnimator;
import android.app.Notification;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.ColorStateList;
import android.content.res.Configuration;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.Outline;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.hardware.display.DisplayManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.util.Log;
import android.util.TypedValue;
import android.view.Display;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewOutlineProvider;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.view.WindowMetrics;
import android.view.animation.LinearInterpolator;
import android.view.animation.PathInterpolator;
import android.widget.FrameLayout;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.InputStream;
import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;

import app.fushi.reader.constants.NotificationIds;
import app.fushi.reader.constants.PreferenceKeys;
import io.flutter.FlutterInjector;

/**
 * 全局悬浮球的 Android 系统常驻形态（{@code floating_ball.mode = system}）。
 *
 * <p>观感与交互对齐应用内球（{@code lib/src/reader/reader_floating_ball.dart}，BUG-2793）：
 * 收起时是停靠在左/右边缘、外缩约 1/3 的半透明圆球（球面 = 与应用内同一张 Fushi 图标）；
 * 点一下球点亮（主题色描边 + 阴影）并滑回屏内，圆形图标按钮从球心错峰飞出、在球正上方
 * 竖排（屏幕太矮时向中央续列）；再点一下收起。拖动沿边上下挪或换边，松手吸附到最近边。
 * 几何全部在 {@link FloatingBallGeometry}（与 Dart 同一套公式）。
 *
 * <p>按钮：Dart 下发的动作（{@code lookup} / {@code popup_lookup} / {@code clipboard} /
 * {@code screen_ocr} / {@code camera_ocr} / {@code sync}）+ 固定的 {@code open_app} /
 * {@code close}。
 * 图标是 Dart 下发的 Material Icons 码位（与应用内同一颗 IconData，字体取 app 自带的
 * Flutter 资源），颜色是 Dart 下发的主题色。契约见 docs/specs/2026-09-28-floating-ball.md。
 *
 * <p>两个查词按钮是两种相反的取舍，别合并：{@code lookup} 把 Fushi 主窗唤到前台并打开
 * 查词页（桌面「唤起主窗并打开查词页」同一语义）；{@code popup_lookup} 不碰主窗，弹出
 * 与系统「处理文本」/ 截屏识字同一个独立查词窗 {@link PopupDictFlutterActivity}。
 *
 * <p>{@code close}（按钮与常驻通知上的关闭）= 用户关掉了应用外悬浮球：除了停服务，
 * 还要让 Dart 把设置里的「应用外」开关关掉，两边保持一致——见 {@link #closeByUser}。
 *
 * <p>两个窗口（BUG-2793 点球会闪的根因就是旧实现只有一个 WRAP_CONTENT 窗口：展开时窗口
 * 先按旧 x 变宽、下一帧才挪回屏内，整块跳一下）：
 * <ul>
 *   <li>球窗（{@link #rootView}）：固定尺寸，只画球，永远不改大小；</li>
 *   <li>按钮窗（{@link #menuRoot}）：展开时按<b>最终几何</b>一次建好、按钮初始全透明，
 *       之后只做动画，收起动画结束才移除。</li>
 * </ul>
 *
 * <p>可见性由两路独立状态合成，任一为真就隐藏（GONE + 不可触摸）：
 * <ul>
 *   <li>{@link #setAppForeground}：Fushi 自己在前台时由 Flutter 球接管（场景按钮只有
 *       Flutter 侧知道），原生球让位；</li>
 *   <li>{@link #setCaptureHidden}：截屏 OCR 流程进行中，球不能出现在截图里，也不能
 *       盖在选取层上。</li>
 * </ul>
 * 两者都是静态状态：Dart 可能在服务起来之前就报前台状态，OCR 流程也可能在别的入口
 * （Dart 直接调 {@code startScreenOcr}）发起。
 *
 * <p>按钮配置（动作列表 / 文案 / 图标 / 颜色 / OCR 语言）与位置（停靠边 + 纵向比例）落
 * {@link PreferenceKeys#FILE_FLOATING_BALL}，服务重建时从那里重放，不依赖 Dart 再推一次。
 */
public class FloatingBallService extends BaseFloatingService {
    private static final String TAG = "FloatingBallService";

    // ── 动作 id（与 Dart 侧 floating_ball.actions 同名，改一边必须改另一边） ──────
    static final String ACTION_LOOKUP = "lookup";
    static final String ACTION_POPUP_LOOKUP = "popup_lookup";
    static final String ACTION_CLIPBOARD = "clipboard";
    static final String ACTION_SCREEN_OCR = "screen_ocr";
    static final String ACTION_CAMERA_OCR = "camera_ocr";
    static final String ACTION_SYNC = "sync";
    static final String ACTION_OPEN_APP = "open_app";
    static final String ACTION_CLOSE = "close";

    /** Dart 可下发的动作；{@code open_app} / {@code close} 恒在，不受配置控制。 */
    private static final List<String> CONFIGURABLE_ACTIONS =
            Arrays.asList(
                    ACTION_LOOKUP, ACTION_POPUP_LOOKUP, ACTION_CLIPBOARD, ACTION_SCREEN_OCR,
                    ACTION_CAMERA_OCR, ACTION_SYNC);

    /** labels 里可选的通知标题键（原生不维护 17 种语言，缺省回退英文）。 */
    static final String LABEL_NOTIFICATION = "notification";
    /** labels 里球本身的无障碍名。 */
    static final String LABEL_BALL = "ball";

    /** colors 的键（Dart 当前主题的 ColorScheme，见 floatingBallNativeColors）。 */
    static final String COLOR_SURFACE = "surface";
    static final String COLOR_ON_SURFACE = "onSurface";
    static final String COLOR_PRIMARY = "primary";
    /** M3E 球本体 FAB（primaryContainer；墨水屏 surface）。 */
    static final String COLOR_BALL_CONTAINER = "ballContainer";
    /** M3E tonal 小圆钮底色与图标色（secondaryContainer / onSecondaryContainer）。 */
    static final String COLOR_BUTTON_CONTAINER = "buttonContainer";
    static final String COLOR_ON_BUTTON_CONTAINER = "onButtonContainer";
    /** 描边：只有墨水屏不透明（描边无填色），其余全透明 = 不画环。 */
    static final String COLOR_OUTLINE = "outline";

    private static final String PREF_ACTIONS = "ball_actions";
    private static final String PREF_LABELS = "ball_labels";
    private static final String PREF_ICONS = "ball_icons";
    private static final String PREF_COLORS = "ball_colors";
    private static final String PREF_OCR_LANGUAGE = "ball_ocr_language";
    private static final String PREF_DOCK = "ball_dock";
    private static final String PREF_FRACTION = "ball_fraction";
    /** 用户在球 / 通知上点了关闭、Dart 还没来得及把「应用外」开关关掉。 */
    private static final String PREF_CLOSED_BY_USER = "ball_closed_by_user";
    private static final String DEFAULT_OCR_LANGUAGE = "ja";

    private static final String EXTRA_COMMAND = "command";
    private static final String COMMAND_CLOSE = "close";

    // 与应用内球同一组时长（_expandDuration / _collapseDuration / _snapDuration）。
    private static final long EXPAND_MS = 280;
    private static final long COLLAPSE_MS = 190;
    private static final long SNAP_MS = 220;

    /** 球窗四周给阴影留的边（px 由 dp 换算）；比按钮间距小，免得挡到按钮。 */
    private static final int BALL_SHADOW_PAD_DP = 6;
    /** 按钮窗四周给阴影留的边：小于按钮与球的间距，按钮窗不会压到球上抢点击。 */
    private static final int MENU_SHADOW_PAD_DP = 4;
    private static final int ICON_DP = 22;

    /** 与应用内球同一只吉祥物（透明底前景，Flutter 资源），叠在主题色球面上。 */
    private static final String BALL_IMAGE_ASSET = "assets/meta/splash_foreground.png";
    /** 吉祥物在球里的放大倍数（Dart kReaderFloatingBallMascotScale）。 */
    private static final float MASCOT_SCALE = 1.55f;
    /** Fushi 语义图标字体（FushiIcons，Material Symbols Rounded 子集；按 Dart 引用到的码位裁剪过）。 */
    private static final String ICON_FONT_ASSET = "assets/icon_fonts/FushiSymbolsRounded.ttf";

    // Material 3 基线配色：Dart 没下发主题色时兜底。
    private static final int DEFAULT_SURFACE = 0xFFFEF7FF;
    private static final int DEFAULT_ON_SURFACE = 0xFF1D1B20;
    private static final int DEFAULT_PRIMARY = 0xFF6750A4;
    private static final int DEFAULT_PRIMARY_CONTAINER = 0xFFEADDFF;

    // Flutter Curves.easeOutBack / Curves.easeOutCubic 的三次贝塞尔。
    private static final PathInterpolator EASE_OUT_BACK =
            new PathInterpolator(0.175f, 0.885f, 0.32f, 1.275f);
    private static final PathInterpolator EASE_OUT_CUBIC =
            new PathInterpolator(0.215f, 0.61f, 0.355f, 1f);

    // ── 跨实例静态状态 ────────────────────────────────────────────────────────

    private static WeakReference<FloatingBallService> instanceRef;

    /**
     * 服务只会从正在运行的 Fushi 里被启动（Dart 调 startSystemBall），那一刻 app 必在
     * 前台，所以默认 true；之后以 Dart 的 setAppForeground 为准。
     */
    private static volatile boolean appForeground = true;
    private static volatile boolean captureHidden = false;

    @Nullable
    static FloatingBallService getInstance() {
        return instanceRef != null ? instanceRef.get() : null;
    }

    /** Dart {@code setAppForeground}。主线程调用。 */
    static void setAppForeground(boolean foreground) {
        appForeground = foreground;
        FloatingBallService svc = getInstance();
        if (svc != null) svc.applyVisibility();
    }

    /** 截屏 OCR 流程开始 / 结束时调用。主线程调用。 */
    static void setCaptureHidden(boolean hidden) {
        captureHidden = hidden;
        FloatingBallService svc = getInstance();
        if (svc != null) svc.applyVisibility();
    }

    /** 把 Dart 下发的配置落盘；服务在跑就立刻重建按钮与配色。 */
    static void saveConfig(
            @NonNull Context context,
            @Nullable List<String> actions,
            @Nullable Map<String, String> labels,
            @Nullable Map<String, Integer> icons,
            @Nullable Map<String, Integer> colors,
            @Nullable String ocrLanguage) {
        List<String> sanitized = new ArrayList<>();
        if (actions == null) {
            sanitized.addAll(CONFIGURABLE_ACTIONS);
        } else {
            for (String id : actions) {
                if (CONFIGURABLE_ACTIONS.contains(id) && !sanitized.contains(id)) {
                    sanitized.add(id);
                }
            }
        }
        SharedPreferences.Editor editor = context
                .getSharedPreferences(PreferenceKeys.FILE_FLOATING_BALL, Context.MODE_PRIVATE)
                .edit()
                // Dart 重新打开了应用外球：之前那次「用户关闭」已经处理完。
                .remove(PREF_CLOSED_BY_USER)
                .putString(PREF_ACTIONS, String.join(",", sanitized))
                .putString(PREF_LABELS, toJson(labels).toString());
        // 旧 Dart（没传图标 / 颜色）不覆盖已存的值。
        if (icons != null && !icons.isEmpty()) {
            editor.putString(PREF_ICONS, toJson(icons).toString());
        }
        if (colors != null && !colors.isEmpty()) {
            editor.putString(PREF_COLORS, toJson(colors).toString());
        }
        if (ocrLanguage != null && !ocrLanguage.isEmpty()) {
            editor.putString(PREF_OCR_LANGUAGE, ocrLanguage);
        }
        editor.apply();
        FloatingBallService svc = getInstance();
        if (svc != null) svc.reloadConfig();
    }

    private static JSONObject toJson(@Nullable Map<String, ?> map) {
        JSONObject json = new JSONObject();
        if (map == null) return json;
        for (Map.Entry<String, ?> e : map.entrySet()) {
            if (e.getKey() == null || e.getValue() == null) continue;
            try {
                json.put(e.getKey(), e.getValue());
            } catch (JSONException ignored) {
                // key 非空、值是 String / Integer 时 JSONObject.put 不会抛。
            }
        }
        return json;
    }

    /**
     * 取走「用户点过关闭」标记（读完即清）。Dart 收到推送、或下次启动同步开关前调用，
     * 据此把「应用外」开关关掉，而不是按旧开关把球重新拉起来。
     */
    static boolean takeClosedByUser(@NonNull Context context) {
        SharedPreferences prefs = context
                .getSharedPreferences(PreferenceKeys.FILE_FLOATING_BALL, Context.MODE_PRIVATE);
        boolean closed = prefs.getBoolean(PREF_CLOSED_BY_USER, false);
        if (closed) prefs.edit().remove(PREF_CLOSED_BY_USER).apply();
        return closed;
    }

    /** 已落盘的 labels（Dart 直接调 startScreenOcr 没带文案时沿用）。 */
    static Map<String, String> storedLabels(@NonNull Context context) {
        return parseLabels(context
                .getSharedPreferences(PreferenceKeys.FILE_FLOATING_BALL, Context.MODE_PRIVATE)
                .getString(PREF_LABELS, null));
    }

    // ── 实例状态 ──────────────────────────────────────────────────────────────

    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    private List<String> actions = new ArrayList<>(CONFIGURABLE_ACTIONS);
    private Map<String, String> labels = new HashMap<>();
    private Map<String, Integer> icons = new HashMap<>();
    private int colorSurface = DEFAULT_SURFACE;
    private int colorOnSurface = DEFAULT_ON_SURFACE;
    private int colorPrimary = DEFAULT_PRIMARY;
    private int colorBallContainer = DEFAULT_PRIMARY_CONTAINER;
    private int colorButtonContainer = DEFAULT_SURFACE;
    private int colorOnButtonContainer = DEFAULT_ON_SURFACE;
    private int colorOutline = Color.TRANSPARENT;
    private String ocrLanguage = DEFAULT_OCR_LANGUAGE;

    /** 停靠边 + 球在活动范围里的纵向比例（持久化值，不存 px）。 */
    private boolean dockLeft = false;
    private float fraction = 1f / 3f;
    private boolean positionLoaded = false;
    /** 上次摆放用的视口：显示变化事件里只有它真的变了才重摆。 */
    @Nullable private Rect lastViewport;

    private BallView ballView;
    private int ballPad;

    @Nullable private FrameLayout menuRoot;
    @Nullable private WindowManager.LayoutParams menuParams;
    private final List<View> menuButtons = new ArrayList<>();
    /** 按钮窗坐标系里：各按钮中心与展开态球心。 */
    private int[][] menuButtonCenters = new int[0][];
    private int menuBallCx;
    private int menuBallCy;

    /** 展开进度 0（收起）..1（展开），球位置 / 不透明度 / 按钮都由它驱动。 */
    private float progress = 0f;
    private boolean expandTarget = false;
    @Nullable private ValueAnimator expandAnimator;
    @Nullable private ValueAnimator snapAnimator;

    private boolean dragging = false;
    private float downRawX;
    private float downRawY;
    private int dragStartBallLeft;
    private int dragStartBallTop;
    private int dragBallLeft;
    private int dragBallTop;

    @Nullable private Typeface iconFont;
    private boolean iconFontLoaded = false;

    @Nullable private DisplayManager displayManager;
    private final DisplayManager.DisplayListener displayListener =
            new DisplayManager.DisplayListener() {
                @Override
                public void onDisplayAdded(int displayId) {}

                @Override
                public void onDisplayRemoved(int displayId) {}

                @Override
                public void onDisplayChanged(int displayId) {
                    if (displayId == Display.DEFAULT_DISPLAY) relayoutForDisplayChange();
                }
            };

    public FloatingBallService() {
        super(
                PreferenceKeys.FILE_FLOATING_BALL,
                NotificationIds.CHANNEL_FLOATING_BALL,
                "Floating Ball",
                NotificationIds.FLOATING_BALL);
    }

    @Override
    public void onCreate() {
        // 先读配置：super.onCreate() 里就要 buildNotification() 与 createContentView()。
        loadConfig();
        super.onCreate();
        instanceRef = new WeakReference<>(this);
        displayManager = getSystemService(DisplayManager.class);
        if (displayManager != null) {
            displayManager.registerDisplayListener(displayListener, mainHandler);
        }
        applyVisibility();
    }

    @Override
    public void onDestroy() {
        if (displayManager != null) displayManager.unregisterDisplayListener(displayListener);
        cancelAnimators();
        removeMenuWindow();
        mainHandler.removeCallbacksAndMessages(null);
        instanceRef = null;
        super.onDestroy();
    }

    @Override
    public void onConfigurationChanged(@NonNull Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        relayoutForDisplayChange();
    }

    @Override
    protected void onServiceCommand(Intent intent) {
        if (COMMAND_CLOSE.equals(intent.getStringExtra(EXTRA_COMMAND))) {
            closeByUser();
        }
    }

    // ── 窗口 ──────────────────────────────────────────────────────────────────

    /**
     * 不走基类按存盘 px 摆放的流程：位置由「停靠边 + 纵向比例」按当前视口算出来，
     * 旧版本存的 px 只在第一次迁移时参考（{@link #loadPosition}）。
     */
    @Override
    protected void setupOverlay() {
        loadPosition();
        lastViewport = viewport();
        layoutParams = createLayoutParams();
        placeBallWindow(0f);
        setupDragListener();
        windowManager.addView(rootView, layoutParams);
    }

    @Override
    protected WindowManager.LayoutParams createLayoutParams() {
        WindowManager.LayoutParams lp = super.createLayoutParams();
        int size = dp(FloatingBallGeometry.BALL_DP) + 2 * ballPad;
        lp.width = size;
        lp.height = size;
        configureOverlayParams(lp);
        return lp;
    }

    /**
     * 两个窗口共用：x/y 取整块显示区坐标（不让系统按系统栏给窗口再挪一层），
     * 安全区由 {@link #viewport} 自己扣——与应用内球「整窗扣掉系统 inset」同一口径。
     * BUG-2793：旧实现窗口按系统栏 inset 摆放、吸附却按整屏算，两套坐标对不上。
     */
    private void configureOverlayParams(WindowManager.LayoutParams lp) {
        lp.gravity = Gravity.TOP | Gravity.START;
        lp.flags |= WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
                | WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            lp.setFitInsetsTypes(0);
            lp.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS;
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            lp.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
        }
    }

    @Override
    protected DragMode getDragMode() {
        return DragMode.FREE;
    }

    @Override
    protected View getDragHandle() {
        return ballView;
    }

    /** 位置持久化：停靠边 + 纵向比例（基类的 px 存法换算不了旋转）。 */
    @Override
    protected void savePosition() {
        getSharedPreferences(PreferenceKeys.FILE_FLOATING_BALL, MODE_PRIVATE)
                .edit()
                .putString(PREF_DOCK, dockLeft ? "left" : "right")
                .putFloat(PREF_FRACTION, fraction)
                .apply();
    }

    private void loadPosition() {
        if (positionLoaded) return;
        positionLoaded = true;
        SharedPreferences prefs = getSharedPreferences(PreferenceKeys.FILE_FLOATING_BALL,
                MODE_PRIVATE);
        if (prefs.contains(PREF_DOCK)) {
            dockLeft = "left".equals(prefs.getString(PREF_DOCK, "right"));
            fraction = prefs.getFloat(PREF_FRACTION, 1f / 3f);
            return;
        }
        // 旧版本存的是球窗左上角 px：按当时的球心换算一次停靠边与比例。
        if (prefs.contains(PreferenceKeys.POS_Y)) {
            FloatingBallGeometry g = geometry();
            int oldX = prefs.getInt(PreferenceKeys.POS_X, Integer.MAX_VALUE / 2);
            int oldY = prefs.getInt(PreferenceKeys.POS_Y, 0);
            dockLeft = oldX < g.viewport.centerX();
            fraction = g.fractionForTop(oldY);
        }
    }

    /**
     * 显示区的安全区：整块显示区扣掉系统栏与刘海（不论此刻是否可见，与 Flutter 的
     * viewPadding 同义）。坐标与 {@link #configureOverlayParams} 的窗口坐标同一个系。
     */
    private Rect viewport() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            WindowMetrics metrics = windowManager.getCurrentWindowMetrics();
            Rect bounds = new Rect(metrics.getBounds());
            Insets insets = metrics.getWindowInsets().getInsetsIgnoringVisibility(
                    WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
            return new Rect(
                    bounds.left + insets.left,
                    bounds.top + insets.top,
                    bounds.right - insets.right,
                    bounds.bottom - insets.bottom);
        }
        // API < 30：getMetrics 已扣掉导航栏（竖屏在下、横屏在右），顶上再扣状态栏。
        DisplayMetrics app = new DisplayMetrics();
        windowManager.getDefaultDisplay().getMetrics(app);
        int statusBar = 0;
        int id = getResources().getIdentifier("status_bar_height", "dimen", "android");
        if (id > 0) statusBar = getResources().getDimensionPixelSize(id);
        return new Rect(0, statusBar, app.widthPixels, app.heightPixels);
    }

    private FloatingBallGeometry geometry() {
        return new FloatingBallGeometry(
                viewport(),
                dockLeft,
                fraction,
                menuIds().size(),
                getResources().getDisplayMetrics().density);
    }

    /** 进度 t 下的球窗位置（球左上角 = 窗口左上角 + 阴影边）。 */
    private void placeBallWindow(float t) {
        if (layoutParams == null) return;
        FloatingBallGeometry g = geometry();
        int left = lerp(g.collapsedBallLeft(), g.expandedBallLeft(), t);
        int top = lerp(g.ballTop(), g.expandedBallTop(), t);
        moveBallWindowTo(left, top);
    }

    private void moveBallWindowTo(int ballLeft, int ballTop) {
        if (layoutParams == null) return;
        layoutParams.x = ballLeft - ballPad;
        layoutParams.y = ballTop - ballPad;
        if (isOverlayAdded()) windowManager.updateViewLayout(rootView, layoutParams);
    }

    /**
     * 旋转 / 分辨率 / 系统栏变化：收起并按新视口重摆。位置存的是停靠边 + 比例，
     * 所以换算后一定落在屏内（BUG-2793「旋转后球不见了」）。等一帧再算，让窗口度量
     * 先更新到新方向。
     *
     * <p>{@code onDisplayChanged} 远不止旋转会发（亮度、屏幕开关、动画时的刷新率切换都会），
     * 只有视口真的变了才动——否则高刷设备上刚展开就会被这里收掉。
     */
    private void relayoutForDisplayChange() {
        mainHandler.post(() -> {
            if (rootView == null || layoutParams == null) return;
            if (dragging) return;
            Rect vp = viewport();
            if (vp.equals(lastViewport)) return;
            lastViewport = vp;
            collapseImmediately();
        });
    }

    // ── View ──────────────────────────────────────────────────────────────────

    @Override
    protected View createContentView() {
        ballPad = dp(BALL_SHADOW_PAD_DP);
        FrameLayout root = new FrameLayout(this);
        ballView = new BallView(this);
        int ball = dp(FloatingBallGeometry.BALL_DP);
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(ball, ball);
        lp.leftMargin = ballPad;
        lp.topMargin = ballPad;
        root.addView(ballView, lp);
        ballView.setContentDescription(labelFor(LABEL_BALL));
        ballView.setProgress(0f);
        return root;
    }

    /** 按钮自上而下的顺序：固定的关闭 / 打开 Fushi 在最上（离球最远，防误触），
     *  用户勾选的动作在下、末颗紧贴球顶——与应用内「列表末颗离球最近」同序。 */
    private List<String> menuIds() {
        List<String> ids = new ArrayList<>();
        ids.add(ACTION_CLOSE);
        ids.add(ACTION_OPEN_APP);
        ids.addAll(actions);
        return ids;
    }

    /** 按最终几何一次建好按钮窗（按钮全透明），之后只做动画。 */
    private void ensureMenuWindow() {
        if (menuRoot != null) return;
        FloatingBallGeometry g = geometry();
        List<String> ids = menuIds();
        int n = ids.size();
        int cx = g.expandedBallLeft() + g.ball / 2;
        int cy = g.expandedBallTop() + g.ball / 2;
        int half = g.button / 2;
        int pad = dp(MENU_SHADOW_PAD_DP);
        int[][] centers = new int[n][];
        int minX = Integer.MAX_VALUE, minY = Integer.MAX_VALUE;
        int maxX = Integer.MIN_VALUE, maxY = Integer.MIN_VALUE;
        for (int i = 0; i < n; i++) {
            int[] off = g.buttonOffset(i);
            centers[i] = new int[] {cx + off[0], cy + off[1]};
            minX = Math.min(minX, centers[i][0] - half - pad);
            minY = Math.min(minY, centers[i][1] - half - pad);
            maxX = Math.max(maxX, centers[i][0] + half + pad);
            maxY = Math.max(maxY, centers[i][1] + half + pad);
        }
        FrameLayout root = new FrameLayout(this);
        root.setClipChildren(false);
        menuButtons.clear();
        menuButtonCenters = new int[n][];
        for (int i = 0; i < n; i++) {
            View button = buildButton(ids.get(i), g.button);
            menuButtonCenters[i] = new int[] {centers[i][0] - minX, centers[i][1] - minY};
            FrameLayout.LayoutParams p = new FrameLayout.LayoutParams(g.button, g.button);
            p.leftMargin = menuButtonCenters[i][0] - half;
            p.topMargin = menuButtonCenters[i][1] - half;
            root.addView(button, p);
            menuButtons.add(button);
        }
        menuBallCx = cx - minX;
        menuBallCy = cy - minY;
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                maxX - minX,
                maxY - minY,
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                        ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                        : WindowManager.LayoutParams.TYPE_PHONE,
                0,
                PixelFormat.TRANSLUCENT);
        configureOverlayParams(lp);
        lp.x = minX;
        lp.y = minY;
        menuRoot = root;
        menuParams = lp;
        applyButtonProgress(progress);
        windowManager.addView(root, lp);
    }

    private void removeMenuWindow() {
        FrameLayout root = menuRoot;
        menuRoot = null;
        menuParams = null;
        menuButtons.clear();
        if (root != null && root.getParent() != null) {
            try {
                windowManager.removeView(root);
            } catch (IllegalArgumentException e) {
                Log.w(TAG, "menu window already removed", e);
            }
        }
    }

    private View buildButton(final String id, int size) {
        FrameLayout button = new FrameLayout(this);
        // M3E tonal 小圆钮（应用内 _ColumnButton 同一配方）：secondaryContainer 底 +
        // onSecondaryContainer 图标、level 1 阴影、按下 10% 状态层；墨水屏 surface 底 +
        // 描边、无阴影。
        boolean outlined = Color.alpha(colorOutline) > 0;
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.OVAL);
        bg.setColor(colorButtonContainer);
        if (outlined) bg.setStroke(Math.max(1, dp(1.5f)), colorOutline);
        button.setBackground(bg);
        GradientDrawable mask = new GradientDrawable();
        mask.setShape(GradientDrawable.OVAL);
        mask.setColor(Color.WHITE);
        button.setForeground(new RippleDrawable(
                ColorStateList.valueOf(withAlpha(colorOnButtonContainer, 0.10f)), null, mask));
        button.setOutlineProvider(OVAL_OUTLINE);
        button.setClipToOutline(true);
        button.setElevation(outlined ? 0 : dp(1));

        TextView glyph = new TextView(this);
        glyph.setGravity(Gravity.CENTER);
        glyph.setIncludeFontPadding(false);
        glyph.setTextColor(colorOnButtonContainer);
        Integer codePoint = icons.get(id);
        Typeface font = iconFont();
        String label = labelFor(id);
        if (font != null && codePoint != null && codePoint > 0) {
            glyph.setTypeface(font);
            glyph.setTextSize(TypedValue.COMPLEX_UNIT_PX, dp(ICON_DP));
            glyph.setText(new String(Character.toChars(codePoint)));
        } else {
            // 没有图标（旧 Dart / 字体缺失）：退化成文案首字，至少认得出。
            glyph.setTextSize(TypedValue.COMPLEX_UNIT_PX, dp(16));
            glyph.setText(label.isEmpty() ? "?" : label.substring(0, label.offsetByCodePoints(0, 1)));
        }
        button.addView(glyph, new FrameLayout.LayoutParams(size, size));
        button.setContentDescription(label);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) button.setTooltipText(label);
        button.setClickable(true);
        button.setOnClickListener(v -> runAction(id));
        return button;
    }

    @Nullable
    private Typeface iconFont() {
        if (iconFontLoaded) return iconFont;
        iconFontLoaded = true;
        try {
            iconFont = Typeface.createFromAsset(getAssets(), flutterAssetKey(ICON_FONT_ASSET));
        } catch (RuntimeException e) {
            Log.w(TAG, "FushiSymbols icon font unavailable; falling back to labels", e);
            iconFont = null;
        }
        return iconFont;
    }

    /** Flutter 资源在 APK assets 里的路径（引擎没初始化时回退默认的 flutter_assets/）。 */
    private static String flutterAssetKey(String asset) {
        try {
            return FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(asset);
        } catch (RuntimeException e) {
            return "flutter_assets/" + asset;
        }
    }

    private static final ViewOutlineProvider OVAL_OUTLINE = new ViewOutlineProvider() {
        @Override
        public void getOutline(View view, Outline outline) {
            outline.setOval(0, 0, view.getWidth(), view.getHeight());
        }
    };

    // ── 展开 / 收起 ───────────────────────────────────────────────────────────

    private void toggle() {
        setExpanded(!expandTarget);
    }

    private void setExpanded(boolean expand) {
        if (expand == expandTarget) return;
        if (expand && isHidden()) return;
        expandTarget = expand;
        if (snapAnimator != null) snapAnimator.cancel();
        if (expand) ensureMenuWindow();
        animateProgress(expand ? 1f : 0f, expand ? EXPAND_MS : COLLAPSE_MS);
    }

    private void animateProgress(final float target, long fullDuration) {
        if (expandAnimator != null) expandAnimator.cancel();
        ValueAnimator anim = ValueAnimator.ofFloat(progress, target);
        // 中途反向时按剩余路程缩短（与 AnimationController 反向同感）。
        anim.setDuration(Math.max(1L, Math.round(fullDuration * Math.abs(target - progress))));
        anim.setInterpolator(new LinearInterpolator());
        anim.addUpdateListener(a -> setProgress((float) a.getAnimatedValue()));
        anim.addListener(new AnimatorListenerAdapter() {
            private boolean canceled;

            @Override
            public void onAnimationCancel(Animator animation) {
                canceled = true;
            }

            @Override
            public void onAnimationEnd(Animator animation) {
                if (expandAnimator == animation) expandAnimator = null;
                if (canceled) return;
                setProgress(target);
                if (target == 0f) removeMenuWindow();
            }
        });
        expandAnimator = anim;
        anim.start();
    }

    /** 收起到 t=0、不做动画（拖动开始 / 被隐藏 / 屏幕变化）。 */
    private void collapseImmediately() {
        cancelAnimators();
        expandTarget = false;
        removeMenuWindow();
        setProgress(0f);
    }

    private void cancelAnimators() {
        if (expandAnimator != null) {
            ValueAnimator a = expandAnimator;
            expandAnimator = null;
            a.cancel();
        }
        if (snapAnimator != null) {
            ValueAnimator a = snapAnimator;
            snapAnimator = null;
            a.cancel();
        }
    }

    private void setProgress(float t) {
        progress = t;
        placeBallWindow(t);
        if (ballView != null) ballView.setProgress(t);
        applyButtonProgress(t);
    }

    /**
     * 每颗按钮占总时长里错开的一段：离球越远起得越晚、尾部对齐，从球心飞到落点并
     * 缩放淡入（应用内 {@code _buildColumnButton} 同一套区间与曲线）；收起沿同一
     * 区间反放。
     */
    private void applyButtonProgress(float t) {
        int n = menuButtons.size();
        if (n == 0) return;
        float step = n <= 1 ? 0f : 0.35f / (n - 1);
        for (int i = 0; i < n; i++) {
            float begin = (n - 1 - i) * step;
            float end = Math.min(1f, begin + 0.65f);
            float raw = end > begin ? (t - begin) / (end - begin) : (t >= end ? 1f : 0f);
            raw = Math.max(0f, Math.min(1f, raw));
            float k = EASE_OUT_BACK.getInterpolation(raw);
            View b = menuButtons.get(i);
            int[] c = menuButtonCenters[i];
            b.setTranslationX((menuBallCx - c[0]) * (1f - k));
            b.setTranslationY((menuBallCy - c[1]) * (1f - k));
            float scale = 0.4f + 0.6f * Math.min(Math.max(k, 0f), 1.2f);
            b.setScaleX(scale);
            b.setScaleY(scale);
            b.setAlpha(Math.max(0f, Math.min(1f, k)));
        }
    }

    // ── 拖动 ──────────────────────────────────────────────────────────────────

    /**
     * 自己的手势：点一下 = 展开 / 收起；越过系统 tap/drag 边界（{@link #dragSlopPx}）就
     * 是拖动——先收起（按钮跟着球飞没有意义），球跟手，纵向夹在活动范围内；松手按球心
     * 落在哪一半决定停靠边，动画吸附过去并落盘（应用内 _onPan* 同一语义）。
     */
    @Override
    protected void setupDragListener() {
        ballView.setOnTouchListener((v, event) -> {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    downRawX = event.getRawX();
                    downRawY = event.getRawY();
                    dragging = false;
                    return true;
                case MotionEvent.ACTION_MOVE: {
                    float dx = event.getRawX() - downRawX;
                    float dy = event.getRawY() - downRawY;
                    if (!dragging) {
                        int slop = dragSlopPx();
                        if (Math.abs(dx) <= slop && Math.abs(dy) <= slop) return true;
                        beginDrag();
                    }
                    FloatingBallGeometry g = geometry();
                    int left = dragStartBallLeft + Math.round(dx);
                    int top = dragStartBallTop + Math.round(dy);
                    dragBallLeft = Math.max(g.viewport.left - g.tuck(),
                            Math.min(g.viewport.right - g.ball + g.tuck(), left));
                    dragBallTop = Math.max(g.minTop(), Math.min(g.maxTop(), top));
                    moveBallWindowTo(dragBallLeft, dragBallTop);
                    return true;
                }
                case MotionEvent.ACTION_UP:
                    if (dragging) {
                        endDrag();
                    } else {
                        v.performClick();
                        toggle();
                    }
                    return true;
                case MotionEvent.ACTION_CANCEL:
                    if (dragging) endDrag();
                    return true;
                default:
                    return false;
            }
        });
    }

    private void beginDrag() {
        dragging = true;
        collapseImmediately();
        FloatingBallGeometry g = geometry();
        dragStartBallLeft = g.collapsedBallLeft();
        dragStartBallTop = g.ballTop();
        dragBallLeft = dragStartBallLeft;
        dragBallTop = dragStartBallTop;
        ballView.setDragging(true);
    }

    private void endDrag() {
        dragging = false;
        ballView.setDragging(false);
        FloatingBallGeometry g = geometry();
        dockLeft = g.dockLeftForBallLeft(dragBallLeft);
        fraction = g.fractionForTop(dragBallTop);
        savePosition();
        FloatingBallGeometry settled = geometry();
        final int fromLeft = dragBallLeft;
        final int fromTop = dragBallTop;
        final int toLeft = settled.collapsedBallLeft();
        final int toTop = settled.ballTop();
        ValueAnimator anim = ValueAnimator.ofFloat(0f, 1f);
        anim.setDuration(SNAP_MS);
        anim.setInterpolator(EASE_OUT_CUBIC);
        anim.addUpdateListener(a -> {
            float f = (float) a.getAnimatedValue();
            moveBallWindowTo(lerp(fromLeft, toLeft, f), lerp(fromTop, toTop, f));
        });
        anim.addListener(new AnimatorListenerAdapter() {
            @Override
            public void onAnimationEnd(Animator animation) {
                if (snapAnimator == animation) snapAnimator = null;
            }
        });
        snapAnimator = anim;
        anim.start();
    }

    // ── 动作 ──────────────────────────────────────────────────────────────────

    private void runAction(String id) {
        setExpanded(false);
        switch (id) {
            case ACTION_LOOKUP:
                // 先排请求再拉前台：冷启动时 Dart 装好 handler 后来取；热引擎直接推送。
                FloatingBallChannel.requestOpenLookupPage();
                BackgroundActivityLauncher.bringAppToFront(this);
                break;
            case ACTION_POPUP_LOOKUP:
                startPopupLookup(this);
                break;
            case ACTION_CLIPBOARD: {
                Intent intent = new Intent(this, PopupDictFlutterActivity.class);
                intent.putExtra(PopupDictFlutterActivity.EXTRA_READ_CLIPBOARD, true);
                BackgroundActivityLauncher.start(this, intent);
                break;
            }
            case ACTION_SCREEN_OCR:
                if (!ScreenCaptureRequestActivity.launch(this, ocrLanguage, labels)) {
                    Log.w(TAG, "screen OCR not started (no overlay permission or already running)");
                }
                break;
            case ACTION_CAMERA_OCR:
                // 拍照、识别、选字都在主窗里做（相机要 Activity 结果，服务拿不到）：
                // 与「查词」同样先排请求再拉前台。
                FloatingBallChannel.requestCameraOcr();
                BackgroundActivityLauncher.bringAppToFront(this);
                break;
            case ACTION_SYNC:
                // 同步的结果、冲突裁决与重新登录提示都在主窗里给：同样先排请求再拉前台。
                FloatingBallChannel.requestSync();
                BackgroundActivityLauncher.bringAppToFront(this);
                break;
            case ACTION_OPEN_APP:
                BackgroundActivityLauncher.bringAppToFront(this);
                break;
            case ACTION_CLOSE:
                closeByUser();
                break;
            default:
                Log.w(TAG, "unknown floating ball action: " + id);
        }
    }

    /** 弹出只有搜索栏的独立查词窗（应用外查词）。应用内 Flutter 球走同一个出口。 */
    static void startPopupLookup(@NonNull Context context) {
        Intent intent = new Intent(context, PopupDictFlutterActivity.class);
        intent.putExtra(PopupDictFlutterActivity.EXTRA_OPEN_SEARCH, true);
        BackgroundActivityLauncher.start(context, intent);
    }

    /**
     * 用户关掉了应用外悬浮球：先落持久标记（主引擎可能不在，Dart 下次起来还要据此把
     * 「应用外」开关关掉），再尽量立刻推给 Dart，最后停服务。
     */
    private void closeByUser() {
        getSharedPreferences(PreferenceKeys.FILE_FLOATING_BALL, MODE_PRIVATE)
                .edit()
                .putBoolean(PREF_CLOSED_BY_USER, true)
                .apply();
        FloatingBallChannel.notifySystemBallClosedByUser();
        stopSelf();
    }

    private String labelFor(String id) {
        String label = labels.get(id);
        if (label != null && !label.isEmpty()) return label;
        switch (id) {
            case ACTION_LOOKUP: return "Look up";
            case ACTION_POPUP_LOOKUP: return "App-external lookup";
            case ACTION_CLIPBOARD: return "Clipboard";
            case ACTION_SCREEN_OCR: return "Screen OCR";
            case ACTION_CAMERA_OCR: return "Photo lookup";
            case ACTION_SYNC: return "Sync now";
            case ACTION_OPEN_APP: return "Open Fushi";
            case ACTION_CLOSE: return "Close";
            case LABEL_BALL: return "Floating ball";
            default: return id;
        }
    }

    // ── 可见性 ────────────────────────────────────────────────────────────────

    private boolean isHidden() {
        return appForeground || captureHidden;
    }

    private void applyVisibility() {
        if (rootView == null || layoutParams == null) return;
        boolean hidden = isHidden();
        if (hidden) collapseImmediately();
        rootView.setVisibility(hidden ? View.GONE : View.VISIBLE);
        if (hidden) {
            layoutParams.flags |= WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE;
        } else {
            layoutParams.flags &= ~WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE;
        }
        if (isOverlayAdded()) {
            windowManager.updateViewLayout(rootView, layoutParams);
        }
    }

    /**
     * 窗口已 addView 到 WindowManager（ViewRootImpl 在 addView 里同步成为 parent）。
     * 不用 isAttachedToWindow：那要等首帧 traversal，addView 之后立刻改 LayoutParams
     * 会被它误判成「还没加」而漏掉 updateViewLayout。
     */
    private boolean isOverlayAdded() {
        return rootView != null && rootView.getParent() != null;
    }

    // ── 配置 ──────────────────────────────────────────────────────────────────

    private void loadConfig() {
        SharedPreferences prefs =
                getSharedPreferences(PreferenceKeys.FILE_FLOATING_BALL, MODE_PRIVATE);
        String csv = prefs.getString(PREF_ACTIONS, null);
        List<String> loaded = new ArrayList<>();
        if (csv == null) {
            loaded.addAll(CONFIGURABLE_ACTIONS);
        } else if (!csv.isEmpty()) {
            for (String id : csv.split(",")) {
                if (CONFIGURABLE_ACTIONS.contains(id)) loaded.add(id);
            }
        }
        actions = loaded;
        labels = parseLabels(prefs.getString(PREF_LABELS, null));
        icons = parseInts(prefs.getString(PREF_ICONS, null));
        Map<String, Integer> colors = parseInts(prefs.getString(PREF_COLORS, null));
        colorSurface = colorOr(colors, COLOR_SURFACE, DEFAULT_SURFACE);
        colorOnSurface = colorOr(colors, COLOR_ON_SURFACE, DEFAULT_ON_SURFACE);
        colorPrimary = colorOr(colors, COLOR_PRIMARY, DEFAULT_PRIMARY);
        // 旧版存下的配色表没有 M3E 键：按旧配方兜底，等 Dart 下次起球重发。
        colorBallContainer = colorOr(colors, COLOR_BALL_CONTAINER, DEFAULT_PRIMARY_CONTAINER);
        colorButtonContainer = colorOr(colors, COLOR_BUTTON_CONTAINER,
                blend(withAlpha(colorOnSurface, 0.06f), colorSurface));
        colorOnButtonContainer = colorOr(colors, COLOR_ON_BUTTON_CONTAINER, colorOnSurface);
        colorOutline = colorOr(colors, COLOR_OUTLINE, Color.TRANSPARENT);
        ocrLanguage = prefs.getString(PREF_OCR_LANGUAGE, DEFAULT_OCR_LANGUAGE);
    }

    private static int colorOr(Map<String, Integer> colors, String key, int fallback) {
        Integer c = colors.get(key);
        return c != null ? c : fallback;
    }

    private static Map<String, String> parseLabels(@Nullable String raw) {
        Map<String, String> out = new HashMap<>();
        if (raw == null || raw.isEmpty()) return out;
        try {
            JSONObject json = new JSONObject(raw);
            Iterator<String> keys = json.keys();
            while (keys.hasNext()) {
                String key = keys.next();
                out.put(key, json.optString(key, ""));
            }
        } catch (JSONException e) {
            Log.w(TAG, "corrupt floating ball labels; using defaults", e);
        }
        return out;
    }

    private static Map<String, Integer> parseInts(@Nullable String raw) {
        Map<String, Integer> out = new HashMap<>();
        if (raw == null || raw.isEmpty()) return out;
        try {
            JSONObject json = new JSONObject(raw);
            Iterator<String> keys = json.keys();
            while (keys.hasNext()) {
                String key = keys.next();
                Object v = json.opt(key);
                if (v instanceof Number) out.put(key, ((Number) v).intValue());
            }
        } catch (JSONException e) {
            Log.w(TAG, "corrupt floating ball icon / color table; using defaults", e);
        }
        return out;
    }

    private void reloadConfig() {
        loadConfig();
        // 按钮个数 / 图标 / 配色都可能变：收起（下次展开按新配置重建按钮窗），球重画。
        collapseImmediately();
        if (ballView != null) {
            ballView.setContentDescription(labelFor(LABEL_BALL));
            ballView.invalidate();
        }
        try {
            android.app.NotificationManager nm =
                    getSystemService(android.app.NotificationManager.class);
            if (nm != null) nm.notify(NotificationIds.FLOATING_BALL, buildNotification());
        } catch (RuntimeException e) {
            Log.w(TAG, "notification refresh failed", e);
        }
    }

    // ── 小工具 ────────────────────────────────────────────────────────────────

    private int dp(float value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private static int lerp(int a, int b, float t) {
        return Math.round(a + (b - a) * t);
    }

    private static int withAlpha(int color, float alpha) {
        int a = Math.round(Color.alpha(color) * alpha);
        return (color & 0x00FFFFFF) | (a << 24);
    }

    /** Color.alphaBlend(fg, bg)：fg 按自身 alpha 叠在 bg 上。 */
    private static int blend(int fg, int bg) {
        float a = Color.alpha(fg) / 255f;
        int r = Math.round(Color.red(fg) * a + Color.red(bg) * (1 - a));
        int g = Math.round(Color.green(fg) * a + Color.green(bg) * (1 - a));
        int b = Math.round(Color.blue(fg) * a + Color.blue(bg) * (1 - a));
        return Color.argb(Color.alpha(bg), r, g, b);
    }

    /**
     * 球：M3E FAB 球面（主题 primaryContainer + 吉祥物，按圆裁切）。收起态半透明；
     * 随展开进度不透明、阴影加深；拖动中不透明（应用内 {@code _buildBall}）。墨水屏
     * 只画描边环、不投影。原生球不做应用内的方块 → 圆形变。
     */
    private final class BallView extends View {
        private final Paint imagePaint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
        private final Paint fillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF mascot = new RectF();
        private final Paint ringPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Path clip = new Path();
        private final RectF oval = new RectF();
        private final Rect src = new Rect();
        @Nullable private final Bitmap image;
        @Nullable private final Drawable fallback;
        private float t = 0f;
        private boolean dragging = false;

        BallView(Context context) {
            super(context);
            Bitmap bitmap = null;
            try (InputStream in = context.getAssets().open(flutterAssetKey(BALL_IMAGE_ASSET))) {
                BitmapFactory.Options opts = new BitmapFactory.Options();
                // 432² 原图放大 1.55 倍后只在 48dp 圆里露脸：缩到 216 解码足够
                // （应用内 cacheWidth 同理）。
                opts.inSampleSize = 2;
                bitmap = BitmapFactory.decodeStream(in, null, opts);
            } catch (Exception e) {
                Log.w(TAG, "ball image asset unavailable; using launcher icon", e);
            }
            image = bitmap;
            fallback = bitmap == null ? context.getDrawable(R.mipmap.launcher_icon) : null;
            ringPaint.setStyle(Paint.Style.STROKE);
            setOutlineProvider(OVAL_OUTLINE);
            setClickable(true);
        }

        void setProgress(float progress) {
            t = progress;
            refresh();
        }

        void setDragging(boolean value) {
            dragging = value;
            refresh();
        }

        private void refresh() {
            float opacity = dragging ? 1f
                    : FloatingBallGeometry.IDLE_OPACITY
                            + (1f - FloatingBallGeometry.IDLE_OPACITY) * t;
            setAlpha(opacity);
            // M3E elevation level 1 → 3；墨水屏（有描边）不投影。
            setElevation(Color.alpha(colorOutline) > 0 ? 0 : dp(1f + 5f * t));
            invalidate();
        }

        /**
         * 球停在屏幕边缘（收起时还外缩 1/3），整颗落在系统手势导航的「边缘返回」热区里：
         * 从球上起手的横向拖动会被系统当成返回手势抢走（我们收到 ACTION_CANCEL，球只挪
         * 一点就吸回原边——真机 SM-X716B 手势导航实测）。把球从系统手势里排除掉。
         */
        @Override
        protected void onLayout(boolean changed, int left, int top, int right, int bottom) {
            super.onLayout(changed, left, top, right, bottom);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                setSystemGestureExclusionRects(java.util.Collections.singletonList(
                        new Rect(0, 0, right - left, bottom - top)));
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            float w = getWidth();
            float h = getHeight();
            oval.set(0, 0, w, h);
            clip.reset();
            clip.addOval(oval, Path.Direction.CW);
            canvas.save();
            canvas.clipPath(clip);
            if (image != null) {
                // M3E FAB 球面：主题 primaryContainer 底 + 居中放大的吉祥物（应用内
                // _BallFace 同一配方；墨水屏底色是 surface）。
                fillPaint.setColor(colorBallContainer);
                canvas.drawRect(oval, fillPaint);
                int side = Math.min(image.getWidth(), image.getHeight());
                int l = (image.getWidth() - side) / 2;
                int tp = (image.getHeight() - side) / 2;
                src.set(l, tp, l + side, tp + side);
                float extent = Math.min(w, h) * MASCOT_SCALE;
                mascot.set((w - extent) / 2f, (h - extent) / 2f,
                        (w + extent) / 2f, (h + extent) / 2f);
                canvas.drawBitmap(image, src, mascot, imagePaint);
            } else if (fallback != null) {
                fallback.setBounds(0, 0, (int) w, (int) h);
                fallback.draw(canvas);
            }
            canvas.restore();
            // 只有墨水屏画描边环（描边无填色）；其余靠 elevation 区分，M3E FAB 无环。
            if (Color.alpha(colorOutline) > 0) {
                float stroke = dp(1.5f);
                ringPaint.setStrokeWidth(stroke);
                ringPaint.setColor(colorOutline);
                float inset = stroke / 2f;
                canvas.drawOval(inset, inset, w - inset, h - inset, ringPaint);
            }
        }

        @Override
        public boolean performClick() {
            super.performClick();
            return true;
        }
    }

    // ── 通知 ──────────────────────────────────────────────────────────────────

    @Override
    protected Notification buildNotification() {
        Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, getNotificationChannelId())
                : new Notification.Builder(this);

        Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (launch != null) {
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
            builder.setContentIntent(PendingIntent.getActivity(this, 0, launch,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
        }

        Intent closeIntent = new Intent(this, FloatingBallService.class);
        closeIntent.putExtra(EXTRA_COMMAND, COMMAND_CLOSE);
        PendingIntent closePending = PendingIntent.getService(this, 0, closeIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        String title = labels.get(LABEL_NOTIFICATION);
        if (title == null || title.isEmpty()) title = "Fushi floating ball";

        return builder
                .setContentTitle(title)
                .setSmallIcon(R.drawable.ic_stat_fushi)
                .setOngoing(true)
                .addAction(new Notification.Action.Builder(
                        null, labelFor(ACTION_CLOSE), closePending).build())
                .build();
    }
}
