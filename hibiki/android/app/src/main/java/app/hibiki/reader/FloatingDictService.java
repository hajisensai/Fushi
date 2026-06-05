package app.hibiki.reader;

import android.app.Notification;
import android.app.PendingIntent;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.widget.EditText;
import android.widget.ImageButton;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONObject;

import java.lang.ref.WeakReference;

import app.hibiki.reader.constants.FloatingColors;
import app.hibiki.reader.constants.NotificationIds;
import app.hibiki.reader.constants.PreferenceKeys;

public class FloatingDictService extends BaseFloatingService {

    public FloatingDictService() {
        super(
                PreferenceKeys.FILE_FLOATING_DICT,
                NotificationIds.CHANNEL_FLOATING_DICT,
                "Floating Dictionary",
                NotificationIds.FLOATING_DICT);
    }

    private EditText searchInput;
    private TextView resultView;
    private ScrollView resultScroll;
    private ImageButton ankiButton;

    private ClipboardManager clipboardManager;
    private ClipboardManager.OnPrimaryClipChangedListener clipListener;
    private String lastClipText = "";
    private boolean monitoringEnabled = true;

    private String currentWord = "";
    private String currentReading = "";
    private String currentMeaning = "";

    private static WeakReference<FloatingDictService> instanceRef;
    private static io.flutter.embedding.engine.FlutterEngineGroup engineGroup;

    public static FloatingDictService getInstance() {
        return instanceRef != null ? instanceRef.get() : null;
    }

    public static void initEngineGroup(Context appContext) {
        if (engineGroup == null) {
            engineGroup = new io.flutter.embedding.engine.FlutterEngineGroup(appContext);
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        instanceRef = new WeakReference<>(this);
        clipboardManager = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        clipListener = this::onClipboardChanged;
        clipboardManager.addPrimaryClipChangedListener(clipListener);
    }

    @Override
    public void onDestroy() {
        // HBK-AUDIT-056: remove the clipboard listener FIRST so no callback can
        // fire while super.onDestroy() tears down the views.
        if (clipboardManager != null && clipListener != null) {
            clipboardManager.removePrimaryClipChangedListener(clipListener);
            clipListener = null;
        }
        instanceRef = null;
        // HBK-AUDIT-056: null the view refs so the null-guards in the callbacks
        // (onClipboardChanged/triggerSearch/setSearchText/onTextSelected/
        // onSearchResult) actually fire if a posted event runs after teardown.
        searchInput = null;
        resultView = null;
        super.onDestroy();
    }

    @Override
    protected Notification buildNotification() {
        Intent toggleIntent = new Intent(this, FloatingDictService.class);
        toggleIntent.putExtra("action", "toggle_monitoring");
        PendingIntent togglePending = PendingIntent.getService(this, 0,
                toggleIntent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Intent closeIntent = new Intent(this, FloatingDictService.class);
        closeIntent.putExtra("action", "close");
        PendingIntent closePending = PendingIntent.getService(this, 1,
                closeIntent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder = new Notification.Builder(this, getNotificationChannelId());
        } else {
            builder = new Notification.Builder(this);
        }

        String monitorLabel = monitoringEnabled ? "Pause" : "Resume";

        String contentText;
        if (!monitoringEnabled) {
            contentText = "Clipboard monitoring paused";
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                && !isAccessibilityEnabled()) {
            contentText = "Use search bar or enable accessibility service";
        } else {
            contentText = "Clipboard monitoring active";
        }

        return builder
                .setContentTitle("Hibiki Dictionary")
                .setContentText(contentText)
                .setSmallIcon(R.drawable.ic_stat_hibiki)
                .setOngoing(true)
                .addAction(new Notification.Action.Builder(
                        null, monitorLabel, togglePending).build())
                .addAction(new Notification.Action.Builder(
                        null, "Close", closePending).build())
                .build();
    }

    @Override
    protected WindowManager.LayoutParams createLayoutParams() {
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                dpToPx(300),
                dpToPx(400),
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                        ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                        : WindowManager.LayoutParams.TYPE_PHONE,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        lp.gravity = Gravity.TOP | Gravity.START;
        return lp;
    }

    private void setFocusable(boolean focusable) {
        if (layoutParams == null) return;
        if (focusable) {
            layoutParams.flags &= ~WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE;
        } else {
            layoutParams.flags |= WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE;
        }
        windowManager.updateViewLayout(rootView, layoutParams);
    }

    @Override
    protected View createContentView() {
        int dp4 = dpToPx(4);
        int dp8 = dpToPx(8);
        int dp12 = dpToPx(12);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(FloatingColors.DICT_BACKGROUND);
        root.setPadding(dp8, dp4, dp8, dp4);

        LinearLayout titleBar = new LinearLayout(this);
        titleBar.setOrientation(LinearLayout.HORIZONTAL);
        titleBar.setGravity(Gravity.CENTER_VERTICAL);
        titleBar.setPadding(dp4, dp4, dp4, dp4);

        TextView title = new TextView(this);
        title.setText("Dictionary");
        title.setTextColor(Color.WHITE);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        LinearLayout.LayoutParams titleLp = new LinearLayout.LayoutParams(
                0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        titleBar.addView(title, titleLp);

        ImageButton closeButton = new ImageButton(this);
        closeButton.setImageResource(R.drawable.ic_floating_close);
        closeButton.setBackgroundColor(Color.TRANSPARENT);
        closeButton.getDrawable().mutate().setTint(Color.WHITE);
        closeButton.setOnClickListener(v -> stopSelf());
        titleBar.addView(closeButton, new LinearLayout.LayoutParams(
                dpToPx(32), dpToPx(32)));

        root.addView(titleBar, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        LinearLayout searchBar = new LinearLayout(this);
        searchBar.setOrientation(LinearLayout.HORIZONTAL);
        searchBar.setGravity(Gravity.CENTER_VERTICAL);
        searchBar.setPadding(dp4, 0, dp4, dp4);

        searchInput = new EditText(this);
        searchInput.setHint("Search...");
        searchInput.setTextColor(Color.WHITE);
        searchInput.setHintTextColor(FloatingColors.DICT_SEARCH_HINT);
        searchInput.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        searchInput.setSingleLine(true);
        searchInput.setBackgroundColor(FloatingColors.DICT_SEARCH_INPUT_BG);
        searchInput.setPadding(dp8, dp4, dp8, dp4);
        searchInput.setImeOptions(EditorInfo.IME_ACTION_SEARCH);
        searchInput.setOnFocusChangeListener((v, hasFocus) -> {
            setFocusable(hasFocus);
        });
        searchInput.setOnEditorActionListener((v, actionId, event) -> {
            if (actionId == EditorInfo.IME_ACTION_SEARCH) {
                triggerSearch(searchInput.getText().toString());
                searchInput.clearFocus();
                setFocusable(false);
                return true;
            }
            return false;
        });

        LinearLayout.LayoutParams inputLp = new LinearLayout.LayoutParams(
                0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        searchBar.addView(searchInput, inputLp);

        ImageButton searchButton = new ImageButton(this);
        searchButton.setImageResource(android.R.drawable.ic_menu_search);
        searchButton.setBackgroundColor(Color.TRANSPARENT);
        searchButton.getDrawable().mutate().setTint(Color.WHITE);
        searchButton.setOnClickListener(v ->
                triggerSearch(searchInput.getText().toString()));
        searchBar.addView(searchButton, new LinearLayout.LayoutParams(
                dpToPx(36), dpToPx(36)));

        root.addView(searchBar, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        resultScroll = new ScrollView(this);
        resultView = new TextView(this);
        resultView.setTextColor(Color.WHITE);
        resultView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        resultView.setPadding(dp8, dp8, dp8, dp8);
        resultScroll.addView(resultView);

        LinearLayout.LayoutParams scrollLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f);
        root.addView(resultScroll, scrollLp);

        LinearLayout bottomBar = new LinearLayout(this);
        bottomBar.setOrientation(LinearLayout.HORIZONTAL);
        bottomBar.setGravity(Gravity.END | Gravity.CENTER_VERTICAL);
        bottomBar.setPadding(dp4, dp4, dp4, dp4);

        ankiButton = new ImageButton(this);
        ankiButton.setImageResource(android.R.drawable.ic_input_add);
        ankiButton.setBackgroundColor(FloatingColors.DICT_ANKI_BUTTON_BG);
        ankiButton.getDrawable().mutate().setTint(Color.WHITE);
        ankiButton.setContentDescription("Anki");
        ankiButton.setPadding(dp12, dp4, dp12, dp4);
        ankiButton.setOnClickListener(v -> exportToAnki());
        bottomBar.addView(ankiButton, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                dpToPx(36)));

        root.addView(bottomBar, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        return root;
    }

    @Override
    protected DragMode getDragMode() {
        return DragMode.FREE;
    }

    @Override
    protected View getDragHandle() {
        // Only the title bar is draggable; the rest of the view handles input events.
        return ((LinearLayout) rootView).getChildAt(0);
    }

    @Override
    protected void onServiceCommand(Intent intent) {
        String action = intent.getStringExtra("action");
        if ("toggle_monitoring".equals(action)) {
            monitoringEnabled = !monitoringEnabled;
            startForeground(NotificationIds.FLOATING_DICT, buildNotification());
        } else if ("close".equals(action)) {
            stopSelf();
        } else if ("setClipboardMonitoring".equals(action)) {
            monitoringEnabled = intent.getBooleanExtra("enabled", true);
            startForeground(NotificationIds.FLOATING_DICT, buildNotification());
        }
    }

    private void onClipboardChanged() {
        if (!monitoringEnabled) return;
        ClipData clip = null;
        try {
            clip = clipboardManager.getPrimaryClip();
        } catch (SecurityException e) {
            // Android 13+ restricts clipboard access for non-foreground apps
        }
        if (clip == null || clip.getItemCount() == 0) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                showClipboardRestrictionHint();
            }
            return;
        }
        CharSequence text = clip.getItemAt(0).getText();
        if (text == null) return;
        String trimmed = text.toString().trim();
        if (trimmed.isEmpty() || trimmed.equals(lastClipText)) return;
        lastClipText = trimmed;
        new Handler(Looper.getMainLooper()).post(() -> {
            // HBK-AUDIT-056: a clip event posted before teardown can run after
            // the views are gone; bail if the content view no longer exists.
            if (searchInput == null) return;
            searchInput.setText(trimmed);
            triggerSearch(trimmed);
        });
    }

    private boolean clipboardHintShown = false;

    private void showClipboardRestrictionHint() {
        if (clipboardHintShown) return;
        clipboardHintShown = true;
        boolean a11yEnabled = isAccessibilityEnabled();
        if (a11yEnabled) return;
        new Handler(Looper.getMainLooper()).post(() -> {
            if (resultView != null && (resultView.getText() == null
                    || resultView.getText().length() == 0)) {
                // 暂时取消无障碍权限的申请：不再引导用户去启用无障碍服务
                // （服务声明已在 AndroidManifest 中注释掉）。后面恢复无障碍时，
                // 改回下方被注释的原始提示文案即可。
                resultView.setText(
                    "Android 13+ restricts clipboard access.\n\n"
                    + "Use the search bar to look up words manually.");
                // resultView.setText(
                //     "Android 13+ restricts clipboard access.\n\n"
                //     + "Enable Hibiki accessibility service in "
                //     + "Settings → Accessibility for automatic text detection,"
                //     + " or use the search bar to look up words manually.");
            }
        });
    }

    private boolean isAccessibilityEnabled() {
        String prefString = android.provider.Settings.Secure.getString(
                getContentResolver(),
                android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
        if (prefString == null) return false;
        String flatName = getPackageName() + "/"
                + DictAccessibilityService.class.getName();
        return prefString.contains(flatName);
    }

    private void triggerSearch(String term) {
        if (term == null || term.trim().isEmpty()) return;
        if (resultView == null) return; // HBK-AUDIT-056: view may be torn down
        resultView.setText("Searching...");
        MainActivity.notifyFloatingDictEvent("searchTerm", term);
    }

    public void onSearchResult(String json) {
        new Handler(Looper.getMainLooper()).post(() -> {
            if (resultView == null) return; // HBK-AUDIT-056: view torn down
            if (json == null) {
                resultView.setText("No results found.");
                currentWord = "";
                currentReading = "";
                currentMeaning = "";
                return;
            }
            try {
                JSONArray entries = new JSONArray(json);
                StringBuilder sb = new StringBuilder();
                for (int i = 0; i < entries.length(); i++) {
                    JSONObject entry = entries.getJSONObject(i);
                    String word = entry.optString("word", "");
                    String reading = entry.optString("reading", "");
                    String meaning = entry.optString("meaning", "");

                    if (i == 0) {
                        currentWord = word;
                        currentReading = reading;
                        currentMeaning = meaning;
                    }

                    if (!word.isEmpty()) {
                        sb.append(word);
                        if (!reading.isEmpty()) {
                            sb.append(" 【").append(reading).append("】");
                        }
                        sb.append("\n");
                    }
                    if (!meaning.isEmpty()) {
                        sb.append(meaning);
                    }
                    if (i < entries.length() - 1) {
                        sb.append("\n\n─────────\n\n");
                    }
                }
                resultView.setText(sb.toString());
                resultScroll.scrollTo(0, 0);
            } catch (Exception e) {
                resultView.setText("Error parsing results.");
            }
        });
    }

    private void exportToAnki() {
        if (currentWord.isEmpty()) {
            Toast.makeText(this, "No word to export", Toast.LENGTH_SHORT).show();
            return;
        }
        MainActivity.notifyFloatingDictAnki(currentWord, currentReading, currentMeaning);
    }

    public void setClipboardMonitoring(boolean enabled) {
        monitoringEnabled = enabled;
        startForeground(NotificationIds.FLOATING_DICT, buildNotification());
    }

    public void setSearchText(String text) {
        if (text == null) return;
        new Handler(Looper.getMainLooper()).post(() -> {
            if (searchInput != null) searchInput.setText(text); // HBK-AUDIT-056
        });
    }

    public void onTextSelected(String text) {
        if (text == null || text.trim().isEmpty()) return;
        new Handler(Looper.getMainLooper()).post(() -> {
            if (searchInput == null) return; // HBK-AUDIT-056
            searchInput.setText(text);
            triggerSearch(text);
        });
    }
}
