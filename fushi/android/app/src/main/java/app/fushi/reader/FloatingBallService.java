package app.fushi.reader;

import android.app.Notification;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Outline;
import android.graphics.Rect;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewOutlineProvider;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import org.json.JSONException;
import org.json.JSONObject;

import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;

import app.fushi.reader.constants.NotificationIds;
import app.fushi.reader.constants.PreferenceKeys;

/**
 * 全局悬浮球的 Android 系统常驻形态（{@code floating_ball.mode = system}）。
 *
 * <p>一颗约 48dp 的圆球（app 图标），自由拖动、松手吸附到最近的左/右边缘，闲置时半透明。
 * 点一下展开竖排按钮面板：Dart 下发的动作（{@code lookup} / {@code popup_lookup} /
 * {@code clipboard} / {@code screen_ocr}）+ 固定的 {@code open_app} / {@code close}。
 * 契约见 docs/specs/2026-09-28-floating-ball.md。
 *
 * <p>两个查词按钮是两种相反的取舍，别合并：{@code lookup} 把 Fushi 主窗唤到前台并打开
 * 查词页（桌面「唤起主窗并打开查词页」同一语义）；{@code popup_lookup} 不碰主窗，弹出
 * 与系统「处理文本」/ 截屏识字同一个独立查词窗 {@link PopupDictFlutterActivity}。
 *
 * <p>{@code close}（面板按钮与常驻通知上的关闭）= 用户关掉了应用外悬浮球：除了停服务，
 * 还要让 Dart 把设置里的「应用外」开关关掉，两边保持一致——见 {@link #closeByUser}。
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
 * <p>按钮配置（动作列表 / 文案 / OCR 语言）落 {@link PreferenceKeys#FILE_FLOATING_BALL}，
 * 服务重建时从那里重放，不依赖 Dart 再推一次。
 */
public class FloatingBallService extends BaseFloatingService {
    private static final String TAG = "FloatingBallService";

    // ── 动作 id（与 Dart 侧 floating_ball.actions 同名，改一边必须改另一边） ──────
    static final String ACTION_LOOKUP = "lookup";
    static final String ACTION_POPUP_LOOKUP = "popup_lookup";
    static final String ACTION_CLIPBOARD = "clipboard";
    static final String ACTION_SCREEN_OCR = "screen_ocr";
    static final String ACTION_CAMERA_OCR = "camera_ocr";
    static final String ACTION_OPEN_APP = "open_app";
    static final String ACTION_CLOSE = "close";

    /** Dart 可下发的动作；{@code open_app} / {@code close} 恒在面板末尾，不受配置控制。 */
    private static final List<String> CONFIGURABLE_ACTIONS =
            Arrays.asList(
                    ACTION_LOOKUP, ACTION_POPUP_LOOKUP, ACTION_CLIPBOARD, ACTION_SCREEN_OCR,
                    ACTION_CAMERA_OCR);

    /** labels 里可选的通知标题键（原生不维护 17 种语言，缺省回退英文）。 */
    static final String LABEL_NOTIFICATION = "notification";

    private static final String PREF_ACTIONS = "ball_actions";
    private static final String PREF_LABELS = "ball_labels";
    private static final String PREF_OCR_LANGUAGE = "ball_ocr_language";
    /** 用户在球 / 通知上点了关闭、Dart 还没来得及把「应用外」开关关掉。 */
    private static final String PREF_CLOSED_BY_USER = "ball_closed_by_user";
    private static final String DEFAULT_OCR_LANGUAGE = "ja";

    private static final String EXTRA_COMMAND = "command";
    private static final String COMMAND_CLOSE = "close";

    private static final int BALL_DP = 48;
    private static final int EDGE_MARGIN_DP = 4;
    private static final float IDLE_ALPHA = 0.5f;
    /** 触摸 / 收起面板后多久淡回闲置透明度。只影响观感，不参与任何状态判定。 */
    private static final long IDLE_FADE_DELAY_MS = 2500;

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

    /** 把 Dart 下发的配置落盘；服务在跑就立刻重建面板。 */
    static void saveConfig(
            @NonNull Context context,
            @Nullable List<String> actions,
            @Nullable Map<String, String> labels,
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
        JSONObject json = new JSONObject();
        if (labels != null) {
            for (Map.Entry<String, String> e : labels.entrySet()) {
                if (e.getKey() == null || e.getValue() == null) continue;
                try {
                    json.put(e.getKey(), e.getValue());
                } catch (JSONException ignored) {
                    // key 非空时 JSONObject.put(String, String) 不会抛。
                }
            }
        }
        SharedPreferences.Editor editor = context
                .getSharedPreferences(PreferenceKeys.FILE_FLOATING_BALL, Context.MODE_PRIVATE)
                .edit()
                // Dart 重新打开了应用外球：之前那次「用户关闭」已经处理完。
                .remove(PREF_CLOSED_BY_USER)
                .putString(PREF_ACTIONS, String.join(",", sanitized))
                .putString(PREF_LABELS, json.toString());
        if (ocrLanguage != null && !ocrLanguage.isEmpty()) {
            editor.putString(PREF_OCR_LANGUAGE, ocrLanguage);
        }
        editor.apply();
        FloatingBallService svc = getInstance();
        if (svc != null) svc.reloadConfig();
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
    private final Runnable fadeToIdle = this::fadeBallToIdle;

    private List<String> actions = new ArrayList<>(CONFIGURABLE_ACTIONS);
    private Map<String, String> labels = new HashMap<>();
    private String ocrLanguage = DEFAULT_OCR_LANGUAGE;

    private LinearLayout container;
    private FrameLayout ballView;
    private LinearLayout panel;
    private boolean panelExpanded = false;
    private boolean snappedRight = true;

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
        snappedRight = layoutParams != null
                && layoutParams.x + dpToPx(BALL_DP) / 2 > screenBounds().centerX();
        applyVisibility();
        // 等首帧布局出真实尺寸再贴边（排在基类 setupOverlay 的越界修正之后）。
        rootView.post(this::snapToEdge);
    }

    @Override
    public void onDestroy() {
        mainHandler.removeCallbacksAndMessages(null);
        instanceRef = null;
        super.onDestroy();
    }

    @Override
    protected void onServiceCommand(Intent intent) {
        if (COMMAND_CLOSE.equals(intent.getStringExtra(EXTRA_COMMAND))) {
            closeByUser();
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

    @Override
    protected int readSavedX(SharedPreferences prefs) {
        // 首次默认贴右缘（snapToEdge 会按实际宽度修正）。
        return prefs.getInt(PreferenceKeys.POS_X, Integer.MAX_VALUE / 2);
    }

    @Override
    protected int readSavedY(SharedPreferences prefs) {
        return prefs.getInt(PreferenceKeys.POS_Y, screenBounds().height() / 3);
    }

    @Override
    protected WindowManager.LayoutParams createLayoutParams() {
        WindowManager.LayoutParams lp = super.createLayoutParams();
        lp.width = WindowManager.LayoutParams.WRAP_CONTENT;
        lp.height = WindowManager.LayoutParams.WRAP_CONTENT;
        return lp;
    }

    @Override
    protected void onOverlayTapped(MotionEvent event) {
        setPanelExpanded(!panelExpanded);
    }

    /**
     * 拖动松手时基类调 savePosition：先吸附到最近的左/右边缘再落盘，保证落盘的就是
     * 吸附后的位置（下次启动不会出现在屏幕中间）。onDestroy 同样经过这里，吸附幂等。
     */
    @Override
    protected void savePosition() {
        if (layoutParams != null && rootView != null && isOverlayAdded()) {
            int width = rootView.getWidth() > 0 ? rootView.getWidth() : dpToPx(BALL_DP);
            snappedRight = layoutParams.x + width / 2 > screenBounds().centerX();
            snapToEdge();
        }
        super.savePosition();
    }

    // ── View ──────────────────────────────────────────────────────────────────

    @Override
    protected View createContentView() {
        container = new LinearLayout(this);
        container.setOrientation(LinearLayout.VERTICAL);

        ballView = new FrameLayout(this) {
            @Override
            public boolean dispatchTouchEvent(MotionEvent ev) {
                if (ev.getActionMasked() == MotionEvent.ACTION_DOWN) wakeFromIdle();
                return super.dispatchTouchEvent(ev);
            }
        };
        int ballPx = dpToPx(BALL_DP);
        ImageView icon = new ImageView(this);
        icon.setImageResource(R.mipmap.launcher_icon);
        icon.setScaleType(ImageView.ScaleType.CENTER_CROP);
        ballView.addView(icon, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        ballView.setOutlineProvider(new ViewOutlineProvider() {
            @Override
            public void getOutline(View view, Outline outline) {
                outline.setOval(0, 0, view.getWidth(), view.getHeight());
            }
        });
        ballView.setClipToOutline(true);
        ballView.setElevation(dpToPx(4));
        ballView.setAlpha(IDLE_ALPHA);
        LinearLayout.LayoutParams ballLp = new LinearLayout.LayoutParams(ballPx, ballPx);
        ballLp.setMargins(dpToPx(4), dpToPx(4), dpToPx(4), dpToPx(4));
        container.addView(ballView, ballLp);

        panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(dpToPx(4), dpToPx(4), dpToPx(4), dpToPx(4));
        GradientDrawable panelBg = new GradientDrawable();
        panelBg.setColor(0xF0202124);
        panelBg.setCornerRadius(dpToPx(12));
        panel.setBackground(panelBg);
        panel.setElevation(dpToPx(6));
        panel.setVisibility(View.GONE);
        LinearLayout.LayoutParams panelLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        panelLp.setMargins(dpToPx(4), 0, dpToPx(4), dpToPx(4));
        container.addView(panel, panelLp);
        rebuildPanel();
        return container;
    }

    private void rebuildPanel() {
        if (panel == null) return;
        panel.removeAllViews();
        List<String> ids = new ArrayList<>(actions);
        ids.add(ACTION_OPEN_APP);
        ids.add(ACTION_CLOSE);
        for (String id : ids) {
            panel.addView(buildButton(id));
        }
    }

    private View buildButton(final String id) {
        TextView button = new TextView(this);
        button.setText(labelFor(id));
        button.setTextColor(Color.WHITE);
        button.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        button.setGravity(Gravity.CENTER_VERTICAL | Gravity.START);
        button.setMinWidth(dpToPx(96));
        button.setMinHeight(dpToPx(40));
        button.setPadding(dpToPx(12), dpToPx(6), dpToPx(12), dpToPx(6));
        TypedValue ripple = new TypedValue();
        if (getTheme().resolveAttribute(
                android.R.attr.selectableItemBackground, ripple, true)) {
            button.setBackgroundResource(ripple.resourceId);
        }
        button.setClickable(true);
        button.setOnClickListener(v -> runAction(id));
        return button;
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
            case ACTION_OPEN_APP: return "Open Fushi";
            case ACTION_CLOSE: return "Close";
            default: return id;
        }
    }

    // ── 动作 ──────────────────────────────────────────────────────────────────

    private void runAction(String id) {
        setPanelExpanded(false);
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

    // ── 面板 / 吸附 / 可见性 ──────────────────────────────────────────────────

    private void setPanelExpanded(boolean expanded) {
        if (panel == null) return;
        panelExpanded = expanded;
        panel.setVisibility(expanded ? View.VISIBLE : View.GONE);
        container.setGravity(snappedRight ? Gravity.END : Gravity.START);
        if (expanded) {
            wakeFromIdle();
        } else {
            scheduleIdleFade();
        }
        // 面板展开后窗口变大：等布局完成再按真实尺寸贴边、并把整块挪回屏内（靠下边缘
        // 展开时面板不能伸出屏幕）。
        rootView.post(this::snapToEdge);
    }

    private void snapToEdge() {
        if (layoutParams == null || rootView == null) return;
        Rect screen = screenBounds();
        int width = rootView.getWidth() > 0 ? rootView.getWidth() : dpToPx(BALL_DP + 8);
        int height = rootView.getHeight() > 0 ? rootView.getHeight() : dpToPx(BALL_DP + 8);
        int margin = dpToPx(EDGE_MARGIN_DP);
        layoutParams.x = snappedRight
                ? screen.right - width - margin
                : screen.left + margin;
        int maxY = screen.bottom - height - margin;
        int minY = screen.top + margin;
        if (layoutParams.y > maxY) layoutParams.y = maxY;
        if (layoutParams.y < minY) layoutParams.y = minY;
        if (container != null) {
            container.setGravity(snappedRight ? Gravity.END : Gravity.START);
        }
        if (isOverlayAdded()) {
            windowManager.updateViewLayout(rootView, layoutParams);
        }
    }

    private void applyVisibility() {
        if (rootView == null || layoutParams == null) return;
        boolean hidden = appForeground || captureHidden;
        if (hidden && panelExpanded) setPanelExpanded(false);
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

    private void wakeFromIdle() {
        mainHandler.removeCallbacks(fadeToIdle);
        if (ballView != null) {
            ballView.animate().cancel();
            ballView.setAlpha(1f);
        }
        if (!panelExpanded) scheduleIdleFade();
    }

    private void fadeBallToIdle() {
        if (ballView != null && !panelExpanded) {
            ballView.animate().alpha(IDLE_ALPHA).setDuration(200);
        }
    }

    private void scheduleIdleFade() {
        mainHandler.removeCallbacks(fadeToIdle);
        mainHandler.postDelayed(fadeToIdle, IDLE_FADE_DELAY_MS);
    }

    /**
     * 窗口已 addView 到 WindowManager（ViewRootImpl 在 addView 里同步成为 parent）。
     * 不用 isAttachedToWindow：那要等首帧 traversal，addView 之后立刻改 LayoutParams
     * 会被它误判成「还没加」而漏掉 updateViewLayout。
     */
    private boolean isOverlayAdded() {
        return rootView != null && rootView.getParent() != null;
    }

    private Rect screenBounds() {
        WindowManager wm = windowManager != null
                ? windowManager
                : (WindowManager) getSystemService(Context.WINDOW_SERVICE);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return new Rect(wm.getCurrentWindowMetrics().getBounds());
        }
        DisplayMetrics dm = new DisplayMetrics();
        wm.getDefaultDisplay().getRealMetrics(dm);
        return new Rect(0, 0, dm.widthPixels, dm.heightPixels);
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
        ocrLanguage = prefs.getString(PREF_OCR_LANGUAGE, DEFAULT_OCR_LANGUAGE);
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

    private void reloadConfig() {
        loadConfig();
        rebuildPanel();
        try {
            android.app.NotificationManager nm =
                    getSystemService(android.app.NotificationManager.class);
            if (nm != null) nm.notify(NotificationIds.FLOATING_BALL, buildNotification());
        } catch (RuntimeException e) {
            Log.w(TAG, "notification refresh failed", e);
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
