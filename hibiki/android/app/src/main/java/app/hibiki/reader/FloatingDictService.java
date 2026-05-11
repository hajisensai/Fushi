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
import android.view.MotionEvent;
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

public class FloatingDictService extends BaseFloatingService {

    private static final int NOTIFICATION_ID = 9528;

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

    public static FloatingDictService getInstance() {
        return instanceRef != null ? instanceRef.get() : null;
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
        instanceRef = null;
        if (clipboardManager != null && clipListener != null) {
            clipboardManager.removePrimaryClipChangedListener(clipListener);
        }
        super.onDestroy();
    }

    @Override
    protected String getPreferencePrefix() { return "floating_dict_prefs"; }

    @Override
    protected String getNotificationChannelId() { return "hibiki_floating_dict"; }

    @Override
    protected String getNotificationChannelName() { return "Floating Dictionary"; }

    @Override
    protected int getNotificationId() { return NOTIFICATION_ID; }

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

        return builder
                .setContentTitle("Hibiki Dictionary")
                .setContentText(monitoringEnabled
                        ? "Clipboard monitoring active"
                        : "Clipboard monitoring paused")
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
        root.setBackgroundColor(0xF01E1E2E);
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
        searchInput.setHintTextColor(0x80FFFFFF);
        searchInput.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        searchInput.setSingleLine(true);
        searchInput.setBackgroundColor(0x33FFFFFF);
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
        ankiButton.setBackgroundColor(0x33FFFFFF);
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
    protected void setupDragListener() {
        View titleBar = ((LinearLayout) rootView).getChildAt(0);
        titleBar.setOnTouchListener(new View.OnTouchListener() {
            private int initialX, initialY;
            private float initialTouchX, initialTouchY;
            private boolean isDragging = false;

            @Override
            public boolean onTouch(View v, MotionEvent event) {
                switch (event.getAction()) {
                    case MotionEvent.ACTION_DOWN:
                        initialX = layoutParams.x;
                        initialY = layoutParams.y;
                        initialTouchX = event.getRawX();
                        initialTouchY = event.getRawY();
                        isDragging = false;
                        return true;
                    case MotionEvent.ACTION_MOVE:
                        float dx = event.getRawX() - initialTouchX;
                        float dy = event.getRawY() - initialTouchY;
                        if (Math.abs(dx) > 10 || Math.abs(dy) > 10)
                            isDragging = true;
                        if (isDragging) {
                            layoutParams.x = initialX + (int) dx;
                            layoutParams.y = initialY + (int) dy;
                            windowManager.updateViewLayout(rootView, layoutParams);
                        }
                        return true;
                    case MotionEvent.ACTION_UP:
                        if (isDragging) savePosition();
                        return true;
                }
                return false;
            }
        });
    }

    @Override
    protected void onServiceCommand(Intent intent) {
        String action = intent.getStringExtra("action");
        if ("toggle_monitoring".equals(action)) {
            monitoringEnabled = !monitoringEnabled;
            startForeground(NOTIFICATION_ID, buildNotification());
        } else if ("close".equals(action)) {
            stopSelf();
        } else if ("setClipboardMonitoring".equals(action)) {
            monitoringEnabled = intent.getBooleanExtra("enabled", true);
            startForeground(NOTIFICATION_ID, buildNotification());
        }
    }

    private void onClipboardChanged() {
        if (!monitoringEnabled) return;
        ClipData clip = clipboardManager.getPrimaryClip();
        if (clip == null || clip.getItemCount() == 0) return;
        CharSequence text = clip.getItemAt(0).getText();
        if (text == null) return;
        String trimmed = text.toString().trim();
        if (trimmed.isEmpty() || trimmed.equals(lastClipText)) return;
        lastClipText = trimmed;
        new Handler(Looper.getMainLooper()).post(() -> {
            searchInput.setText(trimmed);
            triggerSearch(trimmed);
        });
    }

    private void triggerSearch(String term) {
        if (term == null || term.trim().isEmpty()) return;
        resultView.setText("Searching...");
        MainActivity.notifyFloatingDictEvent("searchTerm", term);
    }

    public void onSearchResult(String json) {
        new Handler(Looper.getMainLooper()).post(() -> {
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
        startForeground(NOTIFICATION_ID, buildNotification());
    }
}
