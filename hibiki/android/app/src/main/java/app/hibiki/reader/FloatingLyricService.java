package app.hibiki.reader;

import android.app.Notification;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Rect;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.text.Layout;
import android.text.SpannableString;
import android.text.Spanned;
import android.text.style.BackgroundColorSpan;
import android.text.style.ForegroundColorSpan;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.lang.ref.WeakReference;
import java.util.Map;

import app.hibiki.reader.constants.FloatingColors;
import app.hibiki.reader.constants.NotificationIds;
import app.hibiki.reader.constants.PreferenceKeys;

public class FloatingLyricService extends BaseFloatingService {

    public FloatingLyricService() {
        super(
                PreferenceKeys.FILE_FLOATING_LYRIC,
                NotificationIds.CHANNEL_FLOATING_LYRIC,
                "Floating Lyric",
                NotificationIds.FLOATING_LYRIC);
    }

    private static final int DP_PAD_H = 16;
    private static final int DP_PAD_V = 8;
    private static final int DP_CONTROLS_BOTTOM = 6;
    private static final int DP_BTN_PAD_H = 12;
    private static final int DP_BTN_PAD_V = 4;
    private static final int DP_BTN_MARGIN = 4;
    private static final int DP_BTN_MIN_W = 44;
    private static final int DP_BTN_MIN_H = 36;

    private TextView lyricText;
    private ImageButton previousButton;
    private ImageButton playPauseButton;
    private ImageButton nextButton;
    private ImageButton lockButton;
    private ImageButton closeButton;

    private float fontSize = 16f;
    private int textColor = FloatingColors.LYRIC_TEXT;
    private int bgColor = FloatingColors.LYRIC_BACKGROUND;
    private int buttonTextColor = FloatingColors.LYRIC_BUTTON_TEXT;
    private int buttonBgColor = FloatingColors.LYRIC_BUTTON_BG;
    private int highlightColor = FloatingColors.LYRIC_HIGHLIGHT;
    private int activeColor = FloatingColors.LYRIC_ACTIVE;
    // TODO-708 P2: 圆角半径 / 窗宽（逻辑 dp）。0 = 平台原生默认观感（直角背景 / MATCH_PARENT 撑满）。
    private int cornerRadiusDp = 0;
    private int windowWidthDp = 0;
    private boolean isLocked = false;
    private boolean clickLookupEnabled = true;
    private boolean isPlaying = false;
    private String currentText = "";
    private int highlightStart = -1;
    private int highlightLength = 0;

    // TODO-708 P4: 多行上下文块内「当前行」区间（UTF-16 offset/length）。-1/0 = 无
    // 行标记（N=0 单行或旧 payload），退化为无中间行明暗（never-break userspace）。
    private int currentLineStart = -1;
    private int currentLineLength = 0;

    private String previousLabel = "Previous";
    private String playPauseLabel = "Play";
    private String nextLabel = "Next";
    private String lockLabel = "Lock";
    private String unlockLabel = "Unlock";
    private String closeLabel = "Close";

    private static WeakReference<FloatingLyricService> instanceRef;

    public static FloatingLyricService getInstance() {
        return instanceRef != null ? instanceRef.get() : null;
    }

    // ── BaseFloatingService abstract implementations ──

    @Override
    protected View createContentView() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        root.setPadding(dpToPx(DP_PAD_H), dpToPx(DP_PAD_V), dpToPx(DP_PAD_H), dpToPx(DP_PAD_V));

        LinearLayout controls = new LinearLayout(this);
        controls.setOrientation(LinearLayout.HORIZONTAL);
        controls.setGravity(Gravity.CENTER);
        controls.setPadding(0, 0, 0, dpToPx(DP_CONTROLS_BOTTOM));
        root.addView(controls, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        previousButton = addButton(controls, previousLabel, "previousCue",
                R.drawable.ic_floating_previous);
        playPauseButton = addButton(controls, playPauseLabel, "playPause",
                R.drawable.ic_floating_play);
        nextButton = addButton(controls, nextLabel, "nextCue",
                R.drawable.ic_floating_next);
        lockButton = addButton(controls, lockLabel, "toggleLock",
                R.drawable.ic_floating_lock_open);
        closeButton = addButton(controls, closeLabel, "close",
                R.drawable.ic_floating_close);

        lyricText = new TextView(this);
        lyricText.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize);
        lyricText.setTextColor(textColor);
        lyricText.setGravity(Gravity.CENTER_HORIZONTAL);
        lyricText.setTypeface(Typeface.DEFAULT);
        lyricText.setText(currentText);
        root.addView(lyricText, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        applyStyle();
        return root;
    }

    @Override
    protected Notification buildNotification() {
        Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, getNotificationChannelId())
                : new Notification.Builder(this);
        return builder
                .setContentTitle("Hibiki")
                .setContentText("Floating lyric is active")
                .setSmallIcon(R.drawable.ic_stat_hibiki)
                .setOngoing(true)
                .build();
    }

    @Override
    protected void onServiceCommand(Intent intent) {
        // FloatingLyricService is controlled via static getInstance() + public API
    }

    // ── Lifecycle ──

    @Override
    public void onCreate() {
        readInitialState();
        super.onCreate();
        instanceRef = new WeakReference<>(this);
    }

    @Override
    public void onDestroy() {
        instanceRef = null;
        super.onDestroy();
    }

    // ── Drag hooks ──────────────────────────────────────────────────────────

    @Override
    protected DragMode getDragMode() {
        return DragMode.VERTICAL_ONLY;
    }

    @Override
    protected boolean isDragLocked() {
        return isLocked;
    }

    @Override
    protected void onOverlayTapped(MotionEvent event) {
        handleTap(event);
    }

    // ── Position hooks (backward-compatible with posYTop key) ───────────────

    /** X is always 0 for the lyric overlay; do not read/restore from prefs. */
    @Override
    protected int readSavedX(SharedPreferences prefs) {
        return 0;
    }

    /**
     * Read Y from the standard {@code posY} key.
     * Fall back to the legacy {@code posYTop} key for older installs.
     * Writes use only the standard key (via {@link #savePosition()}).
     */
    @Override
    protected int readSavedY(SharedPreferences prefs) {
        if (prefs.contains(PreferenceKeys.POS_Y)) {
            return prefs.getInt(PreferenceKeys.POS_Y, 100);
        }
        return prefs.getInt(PreferenceKeys.POS_Y_TOP, 100);
    }

    // ── Window width (TODO-708 P2) ──────────────────────────────────────────

    /**
     * TODO-708 P2: 悬浮窗宽度。windowWidthDp == 0 时用基类默认（MATCH_PARENT 撑满屏宽，
     * 靠左 gravity，历史观感零变化）；>0 时按 dp 固定宽并水平居中（VERTICAL_ONLY 拖拽下
     * x 不变，clamp 只夹 Y，居中不受影响）。
     */
    @Override
    protected WindowManager.LayoutParams createLayoutParams() {
        WindowManager.LayoutParams lp = super.createLayoutParams();
        if (windowWidthDp > 0) {
            lp.width = dpToPx(windowWidthDp);
            lp.gravity = Gravity.TOP | Gravity.CENTER_HORIZONTAL;
        }
        return lp;
    }

    /** 宽度改变后在已显示的窗口上即时生效（无窗口时下次 createLayoutParams 会应用）。 */
    private void applyWindowWidth() {
        if (windowManager == null || rootView == null || layoutParams == null) return;
        int targetWidth = windowWidthDp > 0
                ? dpToPx(windowWidthDp)
                : WindowManager.LayoutParams.MATCH_PARENT;
        int targetGravity = windowWidthDp > 0
                ? (Gravity.TOP | Gravity.CENTER_HORIZONTAL)
                : (Gravity.TOP | Gravity.START);
        if (layoutParams.width == targetWidth && layoutParams.gravity == targetGravity) {
            return;
        }
        layoutParams.width = targetWidth;
        layoutParams.gravity = targetGravity;
        rootView.post(() -> {
            if (windowManager != null && rootView != null && layoutParams != null) {
                windowManager.updateViewLayout(rootView, layoutParams);
            }
        });
    }

    // ── Public API (called from MainActivity) ──

    public void updateLyricText(String text) {
        updateLyricText(text, -1, 0);
    }

    // TODO-708 P4: 带块内当前行区间的多行文本更新。currentLineStart<0 = 无行标记，
    // 整块满色（与今天单行观感一致）；>=0 时当前行满色、其余行降 alpha。
    public void updateLyricText(String text, int lineStart, int lineLength) {
        currentText = text;
        currentLineStart = lineStart;
        currentLineLength = lineLength;
        highlightStart = -1;
        highlightLength = 0;
        applyLyricText();
    }

    public void updateHighlight(int start, int length) {
        highlightStart = start;
        highlightLength = length;
        applyLyricText();
    }

    public void updateStyle(
            float size, int color, int bg,
            int buttonColor, int buttonBg,
            int highlight, int active,
            int cornerRadius, int windowWidth) {
        fontSize = size;
        textColor = color;
        bgColor = bg;
        buttonTextColor = buttonColor;
        buttonBgColor = buttonBg;
        highlightColor = highlight;
        activeColor = active;
        cornerRadiusDp = Math.max(0, cornerRadius);
        windowWidthDp = Math.max(0, windowWidth);
        applyWindowWidth();
        applyStyle();
    }

    public void setLocked(boolean locked) {
        isLocked = locked;
        getSharedPreferences(PreferenceKeys.FILE_FLOATING_LYRIC, MODE_PRIVATE)
                .edit()
                .putBoolean(PreferenceKeys.LYRIC_LOCKED, locked)
                .apply();
        applyLockButton();
    }

    public void setClickLookupEnabled(boolean enabled) {
        clickLookupEnabled = enabled;
        getSharedPreferences(PreferenceKeys.FILE_FLOATING_LYRIC, MODE_PRIVATE)
                .edit()
                .putBoolean(PreferenceKeys.LYRIC_CLICK_LOOKUP_ENABLED, enabled)
                .apply();
    }

    public void setPlaybackState(boolean playing) {
        isPlaying = playing;
        applyPlayPauseButton();
    }

    public void updateLabels(Map<String, Object> labels) {
        previousLabel = extractLabel(labels, "previous", previousLabel);
        playPauseLabel = extractLabel(labels, "playPause", playPauseLabel);
        nextLabel = extractLabel(labels, "next", nextLabel);
        lockLabel = extractLabel(labels, "lock", lockLabel);
        unlockLabel = extractLabel(labels, "unlock", unlockLabel);
        closeLabel = extractLabel(labels, "close", closeLabel);
        applyControlLabels();
    }

    // ── View helpers ──

    private ImageButton addButton(LinearLayout parent, String label,
                                   String action, int iconResId) {
        ImageButton btn = new ImageButton(this);
        btn.setImageResource(iconResId);
        btn.setContentDescription(label);
        btn.setPadding(dpToPx(DP_BTN_PAD_H), dpToPx(DP_BTN_PAD_V),
                dpToPx(DP_BTN_PAD_H), dpToPx(DP_BTN_PAD_V));
        btn.setMinimumWidth(dpToPx(DP_BTN_MIN_W));
        btn.setMinimumHeight(dpToPx(DP_BTN_MIN_H));
        btn.setScaleType(ImageView.ScaleType.CENTER);
        btn.setBackground(makeRoundedBackground(buttonBgColor));
        tintIcon(btn, buttonTextColor);
        btn.setOnClickListener(v -> onControlClick(action));

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.setMargins(dpToPx(DP_BTN_MARGIN), 0, dpToPx(DP_BTN_MARGIN), 0);
        parent.addView(btn, lp);
        return btn;
    }

    // ── Tap handling ──

    private void handleTap(MotionEvent event) {
        if (!clickLookupEnabled) return;
        if (lyricText == null || currentText == null || currentText.trim().isEmpty()) return;
        int[] loc = new int[2];
        lyricText.getLocationOnScreen(loc);
        float localX = event.getRawX() - loc[0];
        float localY = event.getRawY() - loc[1];
        if (localX < 0 || localX > lyricText.getWidth()
                || localY < 0 || localY > lyricText.getHeight()) return;

        int index = getCharIndexAt(localX, localY);

        // Route into the Flutter popup (PopupDictFlutterActivity), not the
        // deactivated native PopupDictActivity. The Flutter popup segments the
        // tapped word from charIndex (no whole-sentence head-match) and renders
        // a tap-to-lookup word card with no forced search keyboard — matching
        // every other lookup surface. The 0.5.0 Kotlin rewrite migrated the
        // system PROCESS_TEXT entry points but left this strip pointing at the
        // old native Activity (BUG-214).
        Intent intent = new Intent(this, PopupDictFlutterActivity.class);
        intent.putExtra(Intent.EXTRA_PROCESS_TEXT, currentText);
        intent.putExtra(PopupDictFlutterActivity.EXTRA_CHAR_INDEX, index);

        // TODO-872: ship the tapped glyph's on-screen rectangle (physical px,
        // same coordinate space as the WindowManager overlay) so the Flutter
        // popup can anchor the lookup card next to the word the user touched
        // instead of always pinning it to the screen top. Only this floating
        // lyric/subtitle entry carries the anchor; the absence of the anchor
        // extras is what routes every other entry (system PROCESS_TEXT /
        // hibiki://lookup) back to the default top-center placement.
        Rect glyph = glyphScreenRect(index);
        if (glyph != null && !glyph.isEmpty()) {
            intent.putExtra(PopupDictFlutterActivity.EXTRA_ANCHOR_LEFT, glyph.left);
            intent.putExtra(PopupDictFlutterActivity.EXTRA_ANCHOR_TOP, glyph.top);
            intent.putExtra(PopupDictFlutterActivity.EXTRA_ANCHOR_RIGHT, glyph.right);
            intent.putExtra(PopupDictFlutterActivity.EXTRA_ANCHOR_BOTTOM, glyph.bottom);
        }

        // TODO-708 P1 (6): also ship the whole subtitle-window rectangle (physical
        // px, same coordinate space as the glyph anchor above). The Flutter popup
        // avoids this superset rect so the lookup card never covers *any* glyph in
        // the strip - not just the tapped one. Absent -> Dart avoids only the glyph.
        Rect subtitle = subtitleWindowScreenRect();
        if (subtitle != null && !subtitle.isEmpty()) {
            intent.putExtra(PopupDictFlutterActivity.EXTRA_SUBTITLE_LEFT, subtitle.left);
            intent.putExtra(PopupDictFlutterActivity.EXTRA_SUBTITLE_TOP, subtitle.top);
            intent.putExtra(PopupDictFlutterActivity.EXTRA_SUBTITLE_RIGHT, subtitle.right);
            intent.putExtra(PopupDictFlutterActivity.EXTRA_SUBTITLE_BOTTOM, subtitle.bottom);
        }

        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        startActivity(intent);
    }

    /**
     * On-screen rectangle (physical px) of the glyph at {@code index} inside the
     * lyric TextView, in the same coordinate space as the WindowManager overlay
     * ({@link View#getLocationOnScreen}). Mirrors {@link #getCharIndexAt}'s
     * padding/scroll bookkeeping in reverse: glyph left/right come from the
     * layout's primary-horizontal offsets, top/bottom from the line geometry,
     * then both are shifted by the view's padding minus scroll and the view's
     * screen origin.
     *
     * Returns {@code null} when the layout is not ready or the index is out of
     * range, so the caller can omit the anchor extras and fall back to the
     * default top-center placement.
     */
    private Rect glyphScreenRect(int index) {
        if (lyricText == null) return null;
        Layout layout = lyricText.getLayout();
        CharSequence value = lyricText.getText();
        if (layout == null || value == null || value.length() == 0) return null;
        if (index < 0 || index >= value.length()) return null;

        int line = layout.getLineForOffset(index);
        float left = layout.getPrimaryHorizontal(index);
        float right = layout.getPrimaryHorizontal(index + 1);
        if (right < left) { float tmp = left; left = right; right = tmp; }
        int top = layout.getLineTop(line);
        int bottom = layout.getLineBottom(line);

        // Inverse of getCharIndexAt: layout space → view-local content space.
        float padLeft = lyricText.getTotalPaddingLeft() - lyricText.getScrollX();
        float padTop = lyricText.getTotalPaddingTop() - lyricText.getScrollY();

        int[] loc = new int[2];
        lyricText.getLocationOnScreen(loc);

        int screenLeft = Math.round(loc[0] + padLeft + left);
        int screenRight = Math.round(loc[0] + padLeft + right);
        int screenTop = Math.round(loc[1] + padTop + top);
        int screenBottom = Math.round(loc[1] + padTop + bottom);
        return new Rect(screenLeft, screenTop, screenRight, screenBottom);
    }

    /**
     * On-screen rectangle (physical px) of the whole subtitle overlay window
     * ({@link #rootView}), in the same coordinate space as {@link #glyphScreenRect}
     * ({@link View#getLocationOnScreen}, origin = physical screen top). TODO-708 P1
     * (6): the Flutter popup avoids this superset so the lookup card never covers
     * any glyph in the strip, not just the tapped one.
     *
     * Returns {@code null} when the overlay view is not laid out yet, so the caller
     * omits the extras and the Dart popup falls back to avoiding only the glyph.
     */
    private Rect subtitleWindowScreenRect() {
        View view = rootView;
        if (view == null) return null;
        int width = view.getWidth();
        int height = view.getHeight();
        if (width <= 0 || height <= 0) return null;
        int[] loc = new int[2];
        view.getLocationOnScreen(loc);
        return new Rect(loc[0], loc[1], loc[0] + width, loc[1] + height);
    }

    private int getCharIndexAt(float x, float y) {
        Layout layout = lyricText.getLayout();
        CharSequence value = lyricText.getText();
        if (layout == null || value == null || value.length() == 0) return 0;

        float adjX = x - lyricText.getTotalPaddingLeft() + lyricText.getScrollX();
        float adjY = y - lyricText.getTotalPaddingTop() + lyricText.getScrollY();
        int line = layout.getLineForVertical((int) adjY);
        int lineStart = layout.getLineStart(line);
        int lineEnd = layout.getLineEnd(line);
        String source = value.toString();
        while (lineEnd > lineStart && lineEnd <= source.length()
                && Character.isWhitespace(source.charAt(lineEnd - 1))) {
            lineEnd--;
        }

        for (int i = lineStart; i < lineEnd; i++) {
            float left = layout.getPrimaryHorizontal(i);
            float right = layout.getPrimaryHorizontal(i + 1);
            if (right < left) { float tmp = left; left = right; right = tmp; }
            if (adjX >= left && adjX <= right) return i;
        }

        int offset = layout.getOffsetForHorizontal(line, adjX);
        return Math.max(0, Math.min(offset, Math.max(0, source.length() - 1)));
    }

    // ── Control callbacks ──

    private void onControlClick(String action) {
        if ("close".equals(action)) {
            MainActivity.notifyFloatingLyricEvent("close", null);
            stopSelf();
        } else if ("toggleLock".equals(action)) {
            setLocked(!isLocked);
            java.util.HashMap<String, Object> args = new java.util.HashMap<>();
            args.put("locked", isLocked);
            MainActivity.notifyFloatingLyricEvent("lockChanged", args);
        } else {
            MainActivity.notifyFloatingLyricEvent(action, null);
        }
    }

    // ── Style application ──

    // TODO-708 P4: 中间行明暗——当前行满 textColor，上下文其余行降 alpha（~55%）。
    // 与 word 级 highlight（BackgroundColorSpan）正交：dim 用 ForegroundColorSpan 只改
    // 字色 alpha，highlight 仍单独叠加。currentLineStart<0（N=0 单行/无标记）时不 dim，
    // 整块满色 = 今天观感（never-break userspace）。
    private static final float CONTEXT_DIM_ALPHA = 0.55f;

    private void applyLyricText() {
        if (lyricText == null) return;
        final String text = currentText != null ? currentText : "";
        final int len = text.length();
        final boolean hasLineMarker =
                currentLineStart >= 0 && currentLineLength > 0 && len > 0;
        final boolean hasHighlight = highlightStart >= 0 && highlightLength > 0 && len > 0;

        if (!hasLineMarker && !hasHighlight) {
            lyricText.setText(text);
        } else {
            SpannableString span = new SpannableString(text);
            if (hasLineMarker) {
                int curStart = Math.max(0, Math.min(currentLineStart, len));
                int curEnd = Math.max(curStart, Math.min(curStart + currentLineLength, len));
                int dimColor = dimAlpha(textColor, CONTEXT_DIM_ALPHA);
                // Dim the prefix (before current line) and suffix (after current line).
                if (curStart > 0) {
                    span.setSpan(new ForegroundColorSpan(dimColor),
                            0, curStart, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                }
                if (curEnd < len) {
                    span.setSpan(new ForegroundColorSpan(dimColor),
                            curEnd, len, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                }
            }
            if (hasHighlight) {
                int hStart = Math.max(0, Math.min(highlightStart, len));
                int hEnd = Math.max(hStart, Math.min(hStart + highlightLength, len));
                if (hEnd > hStart) {
                    span.setSpan(new BackgroundColorSpan(highlightColor),
                            hStart, hEnd, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                }
            }
            lyricText.setText(span);
        }
        if (windowManager != null && rootView != null && layoutParams != null) {
            rootView.post(() -> windowManager.updateViewLayout(rootView, layoutParams));
        }
    }

    // 把颜色 alpha 乘以 factor（保留 RGB），用于上下文行降亮。
    private static int dimAlpha(int color, float factor) {
        int a = Math.round(Color.alpha(color) * factor);
        a = Math.max(0, Math.min(255, a));
        return Color.argb(a, Color.red(color), Color.green(color), Color.blue(color));
    }

    private void applyStyle() {
        if (lyricText == null || rootView == null) return;
        lyricText.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize);
        lyricText.setTextColor(textColor);
        rootView.setBackground(makeRoundedBackground(bgColor));
        applyButtonStyle(previousButton);
        applyButtonStyle(nextButton);
        applyButtonStyle(closeButton);
        applyPlayPauseButton();
        applyLockButton();
        applyLyricText();
    }

    /**
     * TODO-708 P2: 背景/按钮底色。cornerRadiusDp == 0 时退化为等价于 setBackgroundColor 的
     * 纯色直角矩形（GradientDrawable 半径 0 = 直角），保持历史像素观感零变化；>0 时按 dp
     * 半径圆角。单一实现供背景与所有按钮共用，圆角与颜色绝不会漂移。
     */
    private GradientDrawable makeRoundedBackground(int color) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setShape(GradientDrawable.RECTANGLE);
        drawable.setColor(color);
        drawable.setCornerRadius(dpToPx(cornerRadiusDp));
        return drawable;
    }

    private void applyButtonStyle(ImageButton btn) {
        if (btn == null) return;
        btn.setBackground(makeRoundedBackground(buttonBgColor));
        tintIcon(btn, buttonTextColor);
    }

    private void applyLockButton() {
        if (lockButton == null) return;
        lockButton.setImageResource(
                isLocked ? R.drawable.ic_floating_lock : R.drawable.ic_floating_lock_open);
        lockButton.setContentDescription(isLocked ? unlockLabel : lockLabel);
        tintIcon(lockButton, isLocked ? activeColor : buttonTextColor);
        lockButton.setBackground(makeRoundedBackground(buttonBgColor));
    }

    private void applyPlayPauseButton() {
        if (playPauseButton == null) return;
        playPauseButton.setImageResource(
                isPlaying ? R.drawable.ic_floating_pause : R.drawable.ic_floating_play);
        playPauseButton.setContentDescription(playPauseLabel);
        tintIcon(playPauseButton, isPlaying ? activeColor : buttonTextColor);
        playPauseButton.setBackground(makeRoundedBackground(buttonBgColor));
    }

    private void applyControlLabels() {
        if (previousButton != null) previousButton.setContentDescription(previousLabel);
        if (playPauseButton != null) playPauseButton.setContentDescription(playPauseLabel);
        if (nextButton != null) nextButton.setContentDescription(nextLabel);
        if (closeButton != null) closeButton.setContentDescription(closeLabel);
        applyLockButton();
    }

    // ── Utilities ──

    private void tintIcon(ImageButton btn, int color) {
        Drawable d = btn.getDrawable();
        if (d != null) d.mutate().setTint(color);
    }

    private void readInitialState() {
        SharedPreferences prefs =
                getSharedPreferences(PreferenceKeys.FILE_FLOATING_LYRIC, MODE_PRIVATE);
        fontSize = prefs.getFloat(PreferenceKeys.LYRIC_FONT_SIZE, fontSize);
        textColor = prefs.getInt(PreferenceKeys.LYRIC_TEXT_COLOR, textColor);
        bgColor = prefs.getInt(PreferenceKeys.LYRIC_BG_COLOR, bgColor);
        buttonTextColor = prefs.getInt(
                PreferenceKeys.LYRIC_BUTTON_TEXT_COLOR, buttonTextColor);
        buttonBgColor = prefs.getInt(PreferenceKeys.LYRIC_BUTTON_BG_COLOR, buttonBgColor);
        highlightColor = prefs.getInt(PreferenceKeys.LYRIC_HIGHLIGHT_COLOR, highlightColor);
        activeColor = prefs.getInt(PreferenceKeys.LYRIC_ACTIVE_COLOR, activeColor);
        // TODO-708 P2: 圆角半径 / 窗宽（dp，0=平台默认）。首帧即读，createLayoutParams 用宽、applyStyle 用圆角。
        cornerRadiusDp = Math.max(0, prefs.getInt(PreferenceKeys.LYRIC_CORNER_RADIUS, cornerRadiusDp));
        windowWidthDp = Math.max(0, prefs.getInt(PreferenceKeys.LYRIC_WIDTH, windowWidthDp));
        isLocked = prefs.getBoolean(PreferenceKeys.LYRIC_LOCKED, isLocked);
        clickLookupEnabled = prefs.getBoolean(
                PreferenceKeys.LYRIC_CLICK_LOOKUP_ENABLED, clickLookupEnabled);
        // BUG-400/TODO-711: replay the last line + playback state pushed from
        // Dart so createContentView's lyricText.setText(currentText) shows the
        // current line on the first frame, instead of "" until the next cue.
        // MainActivity persists these unconditionally because the service is not
        // alive yet when Dart pushes the current cue right after show().
        currentText = prefs.getString(PreferenceKeys.LYRIC_CURRENT_TEXT, currentText);
        // TODO-708 P4: 也重放块内当前行区间，让首帧多行上下文有正确的明暗。
        currentLineStart = prefs.getInt(PreferenceKeys.LYRIC_CURRENT_LINE_START, currentLineStart);
        currentLineLength = prefs.getInt(PreferenceKeys.LYRIC_CURRENT_LINE_LENGTH, currentLineLength);
        isPlaying = prefs.getBoolean(PreferenceKeys.LYRIC_PLAYING, isPlaying);
    }

    private void bringAppToFront() {
        Intent intent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (intent == null) return;
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                | Intent.FLAG_ACTIVITY_SINGLE_TOP
                | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        startActivity(intent);
    }


    private static String extractLabel(Map<String, Object> labels, String key, String fallback) {
        if (labels == null) return fallback;
        Object value = labels.get(key);
        if (value == null) return fallback;
        String text = value.toString();
        return text.isEmpty() ? fallback : text;
    }
}
