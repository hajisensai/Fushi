# Floating Dictionary Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a floating overlay window that monitors clipboard and performs dictionary lookups outside the app, with manual input and Anki export.

**Architecture:** Extract `BaseFloatingService` from existing `FloatingLyricService`, then build `FloatingDictService` on top. Dictionary queries go through Method Channel to Dart's existing search engine. Three launch points: app settings toggle, notification actions, Quick Settings Tile.

**Tech Stack:** Java (Android Service/WindowManager), Dart/Flutter (Method Channel, dictionary engine, Anki), SharedPreferences (position/size persistence)

---

## File Structure

### New Files (Android Java)

| File | Responsibility |
|------|----------------|
| `android/app/src/main/java/app/hibiki/reader/BaseFloatingService.java` | Abstract base: overlay lifecycle, drag, position save, notification, dpToPx |
| `android/app/src/main/java/app/hibiki/reader/FloatingDictService.java` | Clipboard listener, search input, result rendering, Anki button |
| `android/app/src/main/java/app/hibiki/reader/FloatingDictTile.java` | Quick Settings tile to toggle FloatingDictService |

### New Files (Dart)

| File | Responsibility |
|------|----------------|
| `lib/src/media/floating_dict_channel.dart` | Method Channel wrapper for FloatingDictService ↔ Dart |

### Modified Files

| File | Changes |
|------|---------|
| `FloatingLyricService.java` | Refactor to extend BaseFloatingService |
| `MainActivity.java` | Add `FLOATING_DICT_CHANNEL`, register handler, add `notifyFloatingDictEvent()` |
| `AndroidManifest.xml` | Declare FloatingDictService, FloatingDictTile, add `FOREGROUND_SERVICE_SPECIAL_USE` |
| `channel_constants.dart` | Add `floatingDict` channel |

---

### Task 1: Extract BaseFloatingService from FloatingLyricService

**Files:**
- Create: `hibiki/android/app/src/main/java/app/hibiki/reader/BaseFloatingService.java`
- Modify: `hibiki/android/app/src/main/java/app/hibiki/reader/FloatingLyricService.java`

- [ ] **Step 1: Create BaseFloatingService.java**

Extract overlay lifecycle, drag, position save, notification channel, dpToPx into an abstract base class. Subclasses implement `createContentView()`, `getPreferencePrefix()`, `getNotificationChannelId()`, `getNotificationChannelName()`, `getNotificationId()`, `buildNotification()`, `onServiceCommand(Intent)`.

```java
package app.hibiki.reader;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.PixelFormat;
import android.os.Build;
import android.os.IBinder;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;

import androidx.annotation.Nullable;

public abstract class BaseFloatingService extends Service {

    protected WindowManager windowManager;
    protected View rootView;
    protected WindowManager.LayoutParams layoutParams;

    protected abstract View createContentView();
    protected abstract String getPreferencePrefix();
    protected abstract String getNotificationChannelId();
    protected abstract String getNotificationChannelName();
    protected abstract int getNotificationId();
    protected abstract Notification buildNotification();
    protected abstract void onServiceCommand(Intent intent);

    @Override
    public void onCreate() {
        super.onCreate();
        windowManager = (WindowManager) getSystemService(Context.WINDOW_SERVICE);
        createNotificationChannel();
        startForeground(getNotificationId(), buildNotification());
        rootView = createContentView();
        setupOverlay();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null) {
            onServiceCommand(intent);
        }
        return START_NOT_STICKY;
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        savePosition();
        if (rootView != null) {
            windowManager.removeView(rootView);
            rootView = null;
        }
        super.onDestroy();
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        stopSelf();
        super.onTaskRemoved(rootIntent);
    }

    protected void setupOverlay() {
        SharedPreferences prefs = getSharedPreferences(getPreferencePrefix(), MODE_PRIVATE);
        int savedX = prefs.getInt("posX", 0);
        int savedY = prefs.getInt("posY", 100);

        layoutParams = createLayoutParams();
        layoutParams.x = savedX;
        layoutParams.y = savedY;

        setupDragListener();
        windowManager.addView(rootView, layoutParams);
    }

    protected WindowManager.LayoutParams createLayoutParams() {
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                        ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                        : WindowManager.LayoutParams.TYPE_PHONE,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        lp.gravity = Gravity.TOP | Gravity.START;
        return lp;
    }

    protected void setupDragListener() {
        rootView.setOnTouchListener(new View.OnTouchListener() {
            private int initialY;
            private float initialTouchY;
            private boolean isDragging = false;

            @Override
            public boolean onTouch(View v, MotionEvent event) {
                switch (event.getAction()) {
                    case MotionEvent.ACTION_DOWN:
                        initialY = layoutParams.y;
                        initialTouchY = event.getRawY();
                        isDragging = false;
                        return true;
                    case MotionEvent.ACTION_MOVE:
                        float dy = event.getRawY() - initialTouchY;
                        if (Math.abs(dy) > 10) isDragging = true;
                        if (isDragging) {
                            layoutParams.y = initialY + (int) dy;
                            windowManager.updateViewLayout(rootView, layoutParams);
                        }
                        return true;
                    case MotionEvent.ACTION_UP:
                        if (isDragging) savePosition();
                        else onOverlayTap(v, event);
                        return true;
                }
                return false;
            }
        });
    }

    protected void onOverlayTap(View v, MotionEvent event) {
        // Subclasses override for tap behavior
    }

    protected void savePosition() {
        if (layoutParams == null) return;
        getSharedPreferences(getPreferencePrefix(), MODE_PRIVATE)
                .edit()
                .putInt("posX", layoutParams.x)
                .putInt("posY", layoutParams.y)
                .apply();
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    getNotificationChannelId(),
                    getNotificationChannelName(),
                    NotificationManager.IMPORTANCE_LOW);
            channel.setShowBadge(false);
            getSystemService(NotificationManager.class)
                    .createNotificationChannel(channel);
        }
    }

    protected int dpToPx(int dp) {
        return (int) (dp * getResources().getDisplayMetrics().density);
    }
}
```

- [ ] **Step 2: Refactor FloatingLyricService to extend BaseFloatingService**

Remove all overlay/notification/drag/position code that's now in the base class. Keep only lyric-specific UI and logic. Key changes:

- `extends BaseFloatingService` instead of `extends Service`
- `createContentView()` returns the lyric LinearLayout (previously built in `createOverlayView()`)
- `getPreferencePrefix()` returns `"floating_lyric_prefs"`
- Override `onOverlayTap()` for text lookup (instead of inline in touch listener)
- `onServiceCommand(Intent)` replaces `onStartCommand()` body
- Remove `onCreate()`/`onDestroy()`/`onBind()`/`onTaskRemoved()` — call `super` where needed
- Keep the `instanceRef` static pattern, `setupTouchListener()` now only adds the lyricText-specific touch handling on top of base drag
- The lyric touch listener needs special handling: it needs both drag (on rootView) and text-tap (on lyricText). Override `setupDragListener()` to also set the lyricText touch listener.

```java
package app.hibiki.reader;

import android.app.Notification;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.text.Layout;
import android.text.SpannableString;
import android.text.Spanned;
import android.text.style.BackgroundColorSpan;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.lang.ref.WeakReference;
import java.util.Map;

public class FloatingLyricService extends BaseFloatingService {

    private static final String CHANNEL_ID = "hibiki_floating_lyric";
    private static final String PREFS_NAME = "floating_lyric_prefs";
    private static final int NOTIFICATION_ID = 9527;

    private TextView lyricText;
    private LinearLayout controlsView;
    private ImageButton previousButton;
    private ImageButton playPauseButton;
    private ImageButton nextButton;
    private ImageButton lockButton;
    private ImageButton closeButton;

    private float fontSize = 16f;
    private int textColor = Color.WHITE;
    private int bgColor = 0xCC000000;
    private int buttonTextColor = Color.WHITE;
    private int buttonBgColor = 0x33000000;
    private int highlightColor = 0x80FFD54F;
    private int activeColor = 0xFFFFD54F;
    private boolean isLocked = false;
    private boolean isPlaying = false;
    private String currentText = "";
    private int highlightStart = -1;
    private int highlightLength = 0;
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

    @Override
    public void onCreate() {
        super.onCreate();
        instanceRef = new WeakReference<>(this);
    }

    @Override
    public void onDestroy() {
        instanceRef = null;
        super.onDestroy();
    }

    @Override
    protected String getPreferencePrefix() { return PREFS_NAME; }

    @Override
    protected String getNotificationChannelId() { return CHANNEL_ID; }

    @Override
    protected String getNotificationChannelName() { return "Floating Lyric"; }

    @Override
    protected int getNotificationId() { return NOTIFICATION_ID; }

    @Override
    protected Notification buildNotification() {
        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder = new Notification.Builder(this, CHANNEL_ID);
        } else {
            builder = new Notification.Builder(this);
        }
        return builder
                .setContentTitle("Hibiki")
                .setContentText("Floating lyric is active")
                .setSmallIcon(R.drawable.ic_stat_hibiki)
                .setOngoing(true)
                .build();
    }

    @Override
    protected View createContentView() {
        int dp6 = dpToPx(6);
        int dp8 = dpToPx(8);
        int dp12 = dpToPx(12);
        int dp16 = dpToPx(16);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER);
        root.setPadding(dp16, dp8, dp16, dp8);

        lyricText = new TextView(this);
        lyricText.setTextSize(TypedValue.COMPLEX_UNIT_SP, fontSize);
        lyricText.setTextColor(textColor);
        lyricText.setMaxLines(3);
        lyricText.setGravity(Gravity.CENTER);
        lyricText.setTypeface(Typeface.DEFAULT);
        lyricText.setText(currentText);

        root.addView(lyricText, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        controlsView = new LinearLayout(this);
        controlsView.setOrientation(LinearLayout.HORIZONTAL);
        controlsView.setGravity(Gravity.CENTER);
        controlsView.setPadding(0, dp6, 0, 0);
        root.addView(controlsView, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        previousButton = addControlButton(previousLabel, "previousCue",
                R.drawable.ic_floating_previous, dp12);
        playPauseButton = addControlButton(playPauseLabel, "playPause",
                R.drawable.ic_floating_play, dp12);
        nextButton = addControlButton(nextLabel, "nextCue",
                R.drawable.ic_floating_next, dp12);
        lockButton = addControlButton(lockLabel, "toggleLock",
                R.drawable.ic_floating_lock, dp12);
        closeButton = addControlButton(closeLabel, "close",
                R.drawable.ic_floating_close, dp12);

        applyStyle();
        return root;
    }

    @Override
    protected void setupDragListener() {
        View.OnTouchListener touchListener = new View.OnTouchListener() {
            private int initialY;
            private float initialTouchY;
            private boolean isDragging = false;

            @Override
            public boolean onTouch(View v, MotionEvent event) {
                if (isLocked) return true;
                switch (event.getAction()) {
                    case MotionEvent.ACTION_DOWN:
                        initialY = layoutParams.y;
                        initialTouchY = event.getRawY();
                        isDragging = false;
                        return true;
                    case MotionEvent.ACTION_MOVE:
                        float dy = event.getRawY() - initialTouchY;
                        if (Math.abs(dy) > 10) isDragging = true;
                        if (isDragging) {
                            layoutParams.y = initialY + (int) dy;
                            windowManager.updateViewLayout(rootView, layoutParams);
                        }
                        return true;
                    case MotionEvent.ACTION_UP:
                        if (isDragging) {
                            savePosition();
                        } else if (v == lyricText) {
                            notifyLookupFromTouch(event);
                        }
                        return true;
                }
                return false;
            }
        };
        rootView.setOnTouchListener(touchListener);
        lyricText.setOnTouchListener(touchListener);
    }

    @Override
    protected void onServiceCommand(Intent intent) {
        String action = intent.getStringExtra("action");
        if ("updateText".equals(action)) {
            String text = intent.getStringExtra("text");
            if (text != null) updateLyricText(text);
        } else if ("updateStyle".equals(action)) {
            fontSize = intent.getFloatExtra("fontSize", fontSize);
            textColor = intent.getIntExtra("textColor", textColor);
            bgColor = intent.getIntExtra("bgColor", bgColor);
            buttonTextColor = intent.getIntExtra("buttonTextColor", buttonTextColor);
            buttonBgColor = intent.getIntExtra("buttonBgColor", buttonBgColor);
            highlightColor = intent.getIntExtra("highlightColor", highlightColor);
            activeColor = intent.getIntExtra("activeColor", activeColor);
            applyStyle();
        } else if ("setLocked".equals(action)) {
            setLocked(intent.getBooleanExtra("locked", false));
        }
    }

    // --- All existing public/private methods below remain unchanged ---
    // updateLyricText, updateHighlight, applyLyricText, updateStyle,
    // setLocked, setPlaybackState, updateLabels, stringLabel,
    // updateControlLabels, addControlButton, updateLockButton,
    // updatePlayPauseButton, notifyLookupFromTouch, getTouchedTextIndex,
    // bringAppToFront, updateTouchability, applyStyle, applyButtonStyle,
    // applyIconTint
    // (全部保留，不做任何改动)
}
```

- [ ] **Step 3: Verify compile**

Run:
```bash
cd d:\APP\vs_claude_code\hibiki\hibiki && flutter build apk --release --split-per-abi --target-platform android-arm64
```
Expected: BUILD SUCCESSFUL — FloatingLyricService behavior unchanged.

- [ ] **Step 4: Commit**

```bash
git add hibiki/android/app/src/main/java/app/hibiki/reader/BaseFloatingService.java hibiki/android/app/src/main/java/app/hibiki/reader/FloatingLyricService.java
git commit -m "refactor: extract BaseFloatingService from FloatingLyricService

Moves overlay lifecycle, drag positioning, notification channel,
and SharedPreferences persistence into abstract base class.
FloatingLyricService now extends BaseFloatingService."
```

---

### Task 2: Add Dart-side channel and constants for FloatingDictService

**Files:**
- Modify: `hibiki/lib/src/utils/misc/channel_constants.dart`
- Create: `hibiki/lib/src/media/floating_dict_channel.dart`

- [ ] **Step 1: Add channel constant**

In `channel_constants.dart`, add after the `floatingLyric` line:

```dart
static const MethodChannel floatingDict =
    MethodChannel('$_prefix/floating_dict');
```

- [ ] **Step 2: Create floating_dict_channel.dart**

```dart
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:hibiki/src/dictionary/dictionary_search_result.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

typedef FloatingDictSearchHandler = Future<DictionarySearchResult?> Function(
    String term);
typedef FloatingDictAnkiHandler = Future<void> Function(
    String word, String reading, String meaning);

class FloatingDictChannel {
  FloatingDictChannel._();

  static const MethodChannel _channel = HibikiChannels.floatingDict;

  static FloatingDictSearchHandler? _onSearch;
  static FloatingDictAnkiHandler? _onAnkiExport;

  static void setEventHandlers({
    required FloatingDictSearchHandler onSearch,
    required FloatingDictAnkiHandler onAnkiExport,
  }) {
    _onSearch = onSearch;
    _onAnkiExport = onAnkiExport;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static void clearEventHandlers() {
    _onSearch = null;
    _onAnkiExport = null;
    _channel.setMethodCallHandler(null);
  }

  static Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'searchTerm':
        final String term = call.arguments as String? ?? '';
        if (term.trim().isEmpty || _onSearch == null) return;
        final DictionarySearchResult? result = await _onSearch!(term);
        if (result == null || result.entries.isEmpty) {
          await _channel.invokeMethod('searchResult', null);
          return;
        }
        final List<Map<String, String>> entries = result.entries
            .map((e) => {
                  return <String, String>{
                    'word': e.word,
                    'reading': e.reading,
                    'meaning': e.meaning,
                  };
                })
            .toList();
        await _channel.invokeMethod(
            'searchResult', jsonEncode(entries));
        break;
      case 'ankiExport':
        final Map<dynamic, dynamic>? args =
            call.arguments as Map<dynamic, dynamic>?;
        if (args == null || _onAnkiExport == null) return;
        await _onAnkiExport!(
          args['word']?.toString() ?? '',
          args['reading']?.toString() ?? '',
          args['meaning']?.toString() ?? '',
        );
        break;
      default:
        break;
    }
  }

  static Future<bool> canDrawOverlays() async {
    final bool? result = await _channel.invokeMethod<bool>('canDrawOverlays');
    return result ?? false;
  }

  static Future<bool> show() async {
    final bool? result = await _channel.invokeMethod<bool>('show');
    return result ?? false;
  }

  static Future<void> hide() async {
    await _channel.invokeMethod<void>('hide');
  }

  static Future<bool> isShowing() async {
    final bool? result = await _channel.invokeMethod<bool>('isShowing');
    return result ?? false;
  }

  static Future<void> setClipboardMonitoring(
      {required bool enabled}) async {
    await _channel
        .invokeMethod<void>('setClipboardMonitoring', enabled);
  }
}
```

- [ ] **Step 3: Run analyze**

```bash
cd d:\APP\vs_claude_code\hibiki\hibiki && flutter analyze
```
Expected: No new errors.

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/src/utils/misc/channel_constants.dart hibiki/lib/src/media/floating_dict_channel.dart
git commit -m "feat: add FloatingDictChannel and channel constant

Dart-side Method Channel wrapper for floating dictionary window.
Handles searchTerm requests from Java and returns serialized results."
```

---

### Task 3: Create FloatingDictService (Android)

**Files:**
- Create: `hibiki/android/app/src/main/java/app/hibiki/reader/FloatingDictService.java`

- [ ] **Step 1: Create FloatingDictService.java**

```java
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
import android.text.Editable;
import android.text.TextWatcher;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.ImageButton;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONObject;

import java.lang.ref.WeakReference;

import io.flutter.plugin.common.MethodChannel;

public class FloatingDictService extends BaseFloatingService {

    private static final String CHANNEL_ID = "hibiki_floating_dict";
    private static final String PREFS_NAME = "floating_dict_prefs";
    private static final int NOTIFICATION_ID = 9528;

    public static final String ACTION_TOGGLE_MONITORING = "toggle_monitoring";
    public static final String ACTION_CLOSE = "close";

    private EditText searchInput;
    private TextView resultView;
    private ScrollView resultScroll;
    private ImageButton ankiButton;
    private ImageButton closeButton;

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
    protected String getPreferencePrefix() { return PREFS_NAME; }

    @Override
    protected String getNotificationChannelId() { return CHANNEL_ID; }

    @Override
    protected String getNotificationChannelName() { return "Floating Dictionary"; }

    @Override
    protected int getNotificationId() { return NOTIFICATION_ID; }

    @Override
    protected Notification buildNotification() {
        Intent toggleIntent = new Intent(this, FloatingDictService.class);
        toggleIntent.putExtra("action", ACTION_TOGGLE_MONITORING);
        PendingIntent togglePending = PendingIntent.getService(this, 0,
                toggleIntent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Intent closeIntent = new Intent(this, FloatingDictService.class);
        closeIntent.putExtra("action", ACTION_CLOSE);
        PendingIntent closePending = PendingIntent.getService(this, 1,
                closeIntent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder = new Notification.Builder(this, CHANNEL_ID);
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
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        lp.gravity = Gravity.TOP | Gravity.START;
        return lp;
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

        // --- Title bar ---
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

        closeButton = new ImageButton(this);
        closeButton.setImageResource(R.drawable.ic_floating_close);
        closeButton.setBackgroundColor(Color.TRANSPARENT);
        closeButton.getDrawable().mutate().setTint(Color.WHITE);
        closeButton.setOnClickListener(v -> stopSelf());
        titleBar.addView(closeButton, new LinearLayout.LayoutParams(
                dpToPx(32), dpToPx(32)));

        root.addView(titleBar, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        // --- Search bar ---
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
        searchInput.setOnEditorActionListener((v, actionId, event) -> {
            if (actionId == EditorInfo.IME_ACTION_SEARCH) {
                triggerSearch(searchInput.getText().toString());
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

        // --- Result area ---
        resultScroll = new ScrollView(this);
        resultView = new TextView(this);
        resultView.setTextColor(Color.WHITE);
        resultView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        resultView.setPadding(dp8, dp8, dp8, dp8);
        resultScroll.addView(resultView);

        LinearLayout.LayoutParams scrollLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f);
        root.addView(resultScroll, scrollLp);

        // --- Bottom bar ---
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
        // Only the title bar (first child) is draggable.
        // The rest (search input, scroll, buttons) handles its own touch.
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
        if (ACTION_TOGGLE_MONITORING.equals(action)) {
            monitoringEnabled = !monitoringEnabled;
            startForeground(NOTIFICATION_ID, buildNotification());
        } else if (ACTION_CLOSE.equals(action)) {
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
        Toast.makeText(this, "Sent to Anki: " + currentWord, Toast.LENGTH_SHORT).show();
    }

    public void setClipboardMonitoring(boolean enabled) {
        monitoringEnabled = enabled;
        startForeground(NOTIFICATION_ID, buildNotification());
    }
}
```

- [ ] **Step 2: Run compile**

```bash
cd d:\APP\vs_claude_code\hibiki\hibiki && flutter build apk --release --split-per-abi --target-platform android-arm64
```
Expected: Compile error — `MainActivity.notifyFloatingDictEvent` and `notifyFloatingDictAnki` don't exist yet. That's expected, we'll wire them in Task 4.

- [ ] **Step 3: Commit (WIP)**

```bash
git add hibiki/android/app/src/main/java/app/hibiki/reader/FloatingDictService.java
git commit -m "feat(wip): add FloatingDictService

Clipboard-monitoring floating overlay with search input, result
rendering, and Anki export button. Extends BaseFloatingService.
Not yet wired to MainActivity — will connect in next task."
```

---

### Task 4: Wire FloatingDictService into MainActivity

**Files:**
- Modify: `hibiki/android/app/src/main/java/app/hibiki/reader/MainActivity.java`
- Modify: `hibiki/android/app/src/main/AndroidManifest.xml`

- [ ] **Step 1: Add static methods and channel to MainActivity**

Add these constants and fields (alongside existing `FLOATING_LYRIC_CHANNEL`):

```java
private static final String FLOATING_DICT_CHANNEL = "app.hibiki.reader/floating_dict";
private static MethodChannel floatingDictChannel;
```

Add static helper methods (alongside `notifyFloatingLyricEvent`):

```java
public static void notifyFloatingDictEvent(String method, Object arguments) {
    if (floatingDictChannel == null) return;
    new Handler(Looper.getMainLooper()).post(() -> {
        floatingDictChannel.invokeMethod(method, arguments);
    });
}

public static void notifyFloatingDictAnki(String word, String reading, String meaning) {
    if (floatingDictChannel == null) return;
    java.util.Map<String, Object> args = new java.util.HashMap<>();
    args.put("word", word);
    args.put("reading", reading);
    args.put("meaning", meaning);
    new Handler(Looper.getMainLooper()).post(() -> {
        floatingDictChannel.invokeMethod("ankiExport", args);
    });
}
```

- [ ] **Step 2: Register floating dict channel handler in configureFlutterEngine**

Add after the existing `floatingLyricChannel` handler block (after line ~395):

```java
floatingDictChannel = new MethodChannel(
        flutterEngine.getDartExecutor().getBinaryMessenger(), FLOATING_DICT_CHANNEL);
floatingDictChannel.setMethodCallHandler((call, result) -> {
    switch (call.method) {
        case "show": {
            if (!Settings.canDrawOverlays(context)) {
                Intent intent = new Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:" + getPackageName()));
                startActivity(intent);
                result.success(false);
                return;
            }
            Intent svc = new Intent(context, FloatingDictService.class);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(svc);
            } else {
                startService(svc);
            }
            result.success(true);
            break;
        }
        case "hide": {
            stopService(new Intent(context, FloatingDictService.class));
            result.success(true);
            break;
        }
        case "isShowing": {
            result.success(FloatingDictService.getInstance() != null);
            break;
        }
        case "canDrawOverlays": {
            result.success(Settings.canDrawOverlays(context));
            break;
        }
        case "setClipboardMonitoring": {
            Boolean enabled = (Boolean) call.arguments;
            FloatingDictService svc = FloatingDictService.getInstance();
            if (svc != null) {
                svc.setClipboardMonitoring(enabled != null && enabled);
            }
            result.success(null);
            break;
        }
        case "searchResult": {
            String json = (String) call.arguments;
            FloatingDictService svc = FloatingDictService.getInstance();
            if (svc != null) {
                svc.onSearchResult(json);
            }
            result.success(null);
            break;
        }
        default:
            result.notImplemented();
    }
});
```

- [ ] **Step 3: Update AndroidManifest.xml**

Add permission (after `FOREGROUND_SERVICE_MEDIA_PLAYBACK`):

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE"/>
```

Add service declaration (after `FloatingLyricService`):

```xml
<service android:name=".FloatingDictService"
    android:exported="false"
    android:foregroundServiceType="specialUse" />
```

- [ ] **Step 4: Compile and verify**

```bash
cd d:\APP\vs_claude_code\hibiki\hibiki && flutter build apk --release --split-per-abi --target-platform android-arm64
```
Expected: BUILD SUCCESSFUL

- [ ] **Step 5: Commit**

```bash
git add hibiki/android/app/src/main/java/app/hibiki/reader/MainActivity.java hibiki/android/app/src/main/AndroidManifest.xml
git commit -m "feat: wire FloatingDictService to MainActivity

Register floating_dict Method Channel with show/hide/searchResult
handlers. Add notifyFloatingDictEvent and notifyFloatingDictAnki
static methods. Declare service in manifest with specialUse type."
```

---

### Task 5: Connect Dart event handlers for search and Anki

**Files:**
- Modify: `hibiki/lib/src/models/app_model.dart` (or wherever the app initializes channels)

- [ ] **Step 1: Find where FloatingLyricChannel.setEventHandlers is called**

Search for `FloatingLyricChannel.setEventHandlers` or `floatingLyric` usage in the Dart codebase to find the initialization point. Wire `FloatingDictChannel.setEventHandlers` alongside it.

- [ ] **Step 2: Register FloatingDictChannel handlers**

At the same initialization point, add:

```dart
import 'package:hibiki/src/media/floating_dict_channel.dart';

// In init or wherever FloatingLyricChannel is set up:
FloatingDictChannel.setEventHandlers(
  onSearch: (term) async {
    final result = await appModel.searchDictionary(
      searchTerm: term,
      searchWithWildcards: true,
      overrideMaximumTerms: appModel.maximumTerms,
    );
    return result;
  },
  onAnkiExport: (word, reading, meaning) async {
    // Use existing Anki export logic
    await appModel.addAnkiNote(
      word: word,
      reading: reading,
      meaning: meaning,
    );
  },
);
```

Note: The exact Anki export method name may differ — check the existing `AnkiChannelHandler` / `appModel` API. The key is to reuse whatever the popup dictionary page uses for Anki export.

- [ ] **Step 3: Run analyze + compile**

```bash
cd d:\APP\vs_claude_code\hibiki\hibiki && flutter analyze && flutter build apk --release --split-per-abi --target-platform android-arm64
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: connect FloatingDictChannel to dictionary engine and Anki

Register search and Anki export handlers so the floating dict
window can query the existing dictionary engine via Method Channel."
```

---

### Task 6: Add FloatingDictTile (Quick Settings)

**Files:**
- Create: `hibiki/android/app/src/main/java/app/hibiki/reader/FloatingDictTile.java`
- Modify: `hibiki/android/app/src/main/AndroidManifest.xml`

- [ ] **Step 1: Create FloatingDictTile.java**

```java
package app.hibiki.reader;

import android.content.Intent;
import android.os.Build;
import android.provider.Settings;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

public class FloatingDictTile extends TileService {

    @Override
    public void onStartListening() {
        super.onStartListening();
        updateTileState();
    }

    @Override
    public void onClick() {
        super.onClick();
        boolean isRunning = FloatingDictService.getInstance() != null;
        if (isRunning) {
            stopService(new Intent(this, FloatingDictService.class));
        } else {
            if (!Settings.canDrawOverlays(this)) {
                Intent intent = new Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        android.net.Uri.parse("package:" + getPackageName()));
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                startActivity(intent);
                return;
            }
            Intent svc = new Intent(this, FloatingDictService.class);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(svc);
            } else {
                startService(svc);
            }
        }
        updateTileState();
    }

    private void updateTileState() {
        Tile tile = getQsTile();
        if (tile == null) return;
        boolean isRunning = FloatingDictService.getInstance() != null;
        tile.setState(isRunning ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        tile.setLabel("Dictionary");
        tile.updateTile();
    }
}
```

- [ ] **Step 2: Declare in AndroidManifest.xml**

Add after the FloatingDictService declaration:

```xml
<service android:name=".FloatingDictTile"
    android:exported="true"
    android:label="Dictionary"
    android:icon="@drawable/ic_stat_hibiki"
    android:permission="android.permission.BIND_QUICK_SETTINGS_TILE">
    <intent-filter>
        <action android:name="android.service.quicksettings.action.QS_TILE" />
    </intent-filter>
</service>
```

- [ ] **Step 3: Compile**

```bash
cd d:\APP\vs_claude_code\hibiki\hibiki && flutter build apk --release --split-per-abi --target-platform android-arm64
```

- [ ] **Step 4: Commit**

```bash
git add hibiki/android/app/src/main/java/app/hibiki/reader/FloatingDictTile.java hibiki/android/app/src/main/AndroidManifest.xml
git commit -m "feat: add Quick Settings tile for floating dictionary

FloatingDictTile toggles the floating dict service on/off from
the notification shade quick settings panel."
```

---

### Task 7: Add app settings UI for floating dict toggle

**Files:**
- Find and modify the settings page that contains the floating lyric toggle
- Add a similar toggle for the floating dictionary

- [ ] **Step 1: Locate the settings page**

Search for where the floating lyric show/hide is triggered in the Dart UI (likely in a settings page or audiobook bridge). Add a parallel toggle for floating dict.

- [ ] **Step 2: Add floating dict toggle**

Add a `SwitchListTile` or equivalent widget:

```dart
SwitchListTile(
  title: Text(/* localized "Floating Dictionary" */),
  subtitle: Text(/* localized "Monitor clipboard for dictionary lookup" */),
  value: _floatingDictShowing,
  onChanged: (enabled) async {
    if (enabled) {
      final granted = await FloatingDictChannel.show();
      if (granted) setState(() => _floatingDictShowing = true);
    } else {
      await FloatingDictChannel.hide();
      setState(() => _floatingDictShowing = false);
    }
  },
),
```

- [ ] **Step 3: Run analyze + compile**

```bash
cd d:\APP\vs_claude_code\hibiki\hibiki && flutter analyze && flutter build apk --release --split-per-abi --target-platform android-arm64
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: add floating dictionary toggle in settings

Users can enable/disable the floating dictionary window from
the app settings page."
```

---

### Task 8: End-to-end test on emulator

- [ ] **Step 1: Install APK on emulator**

```bash
adb install -r hibiki/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

- [ ] **Step 2: Test floating dict activation**

1. Open Hibiki → Settings → enable Floating Dictionary toggle
2. Verify overlay permission prompt appears (if not already granted)
3. Verify floating window appears with title bar, search input, result area, Anki button

- [ ] **Step 3: Test clipboard monitoring**

1. Open another app (e.g., browser)
2. Copy a Japanese word (e.g., "食べる")
3. Verify the floating window shows the word in the search field
4. Verify dictionary results appear in the result area

- [ ] **Step 4: Test manual search**

1. Tap the search input in the floating window
2. Type a word manually
3. Press the search button or IME search action
4. Verify results appear

- [ ] **Step 5: Test Anki export**

1. Search a word, verify results show
2. Tap the Anki button
3. Verify toast "Sent to Anki: [word]" appears
4. Check AnkiDroid for the new card

- [ ] **Step 6: Test notification controls**

1. Pull down notification shade
2. Verify "Hibiki Dictionary" notification with Pause/Close actions
3. Tap Pause → verify clipboard monitoring stops
4. Tap Resume → verify monitoring resumes
5. Tap Close → verify floating window disappears

- [ ] **Step 7: Test Quick Settings Tile**

1. Edit Quick Settings panel, add "Dictionary" tile
2. Tap tile → verify floating window appears
3. Tap tile again → verify floating window disappears

- [ ] **Step 8: Test drag and position persistence**

1. Drag the floating window by its title bar
2. Close the floating window
3. Reopen → verify it appears at the last position

- [ ] **Step 9: Commit final state**

If any fixes were needed during testing, commit them:
```bash
git add -A
git commit -m "fix: address issues found during floating dict testing"
```
