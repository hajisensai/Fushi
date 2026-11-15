package app.fushi.reader;

import android.app.Activity;
import android.app.ActivityManager;
import android.app.ActivityOptions;
import android.app.Application;
import android.content.Context;
import android.content.Intent;
import android.hardware.display.DisplayManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Message;
import android.os.Messenger;
import android.os.RemoteException;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.Display;
import android.view.KeyEvent;
import android.view.MotionEvent;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import app.fushi.reader.constants.ChannelNames;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * The second-screen host on a dual-screen device (AYN Thor bottom screen, a
 * display plugged into a phone): the app stays on its own display and one
 * panel goes on the other one. The panel has a mode: the companion (module
 * panels, lookups) or the game stream's lookup panel; the Dart side decides
 * which one it wants and on which display.
 *
 * <p>Main-process half. The panel is {@link SecondScreenActivity}, its own
 * activity in the {@code :second_screen} process with its own Flutter engine
 * (the dictionary WebView needs a real Activity, and the panel runs the
 * popup's full AppModel, which only runs safely in a separate process like
 * {@code :popup}). The two talk through {@link SecondScreenRelayService}.
 *
 * <p>Channel {@link ChannelNames#SECOND_SCREEN} on the main engine:
 * <ul>
 *   <li>Dart → Java: {@code listDisplays} (also starts watching displays),
 *       {@code show({displayId, mode})} (false when the launch could not
 *       start), {@code dismiss}, {@code send(json)} (false while no panel is
 *       registered).</li>
 *   <li>Java → Dart: {@code displaysChanged(list)},
 *       {@code panelAttached(map|null)} ({@code {mode, displayId}} of the
 *       panel that came up, null when it went away),
 *       {@code panelMessage(json)}, {@code hostReset(list)} (whatever was
 *       placed before is gone: a new instance took over, or the panel wanted
 *       when the host started again could not be launched).</li>
 * </ul>
 * A display entry is {@code {id, name, widthPx, heightPx, widthDp, heightDp,
 * densityDpi}}.
 *
 * <p>Lifecycle (see {@link SecondScreenLifecycle}): the panel lives while this
 * Activity is started; it is closed on stop and launched again on start if
 * still wanted. Key and controller motion events that land on the panel are
 * dispatched into this Activity, so the buttons always drive the top screen.
 */
final class SecondScreenDisplay
        implements DisplayManager.DisplayListener, Application.ActivityLifecycleCallbacks {
    private static final String TAG = "SecondScreen";

    @Nullable private static SecondScreenDisplay instance;

    private final Activity activity;
    private final MethodChannel channel;
    private final DisplayManager displayManager;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    /** Which panel is wanted and whether it is up (see the class). */
    private final SecondScreenLifecycle<Messenger> lifecycle;

    /** Death links of registered panels, removed when each one goes. */
    private final Map<IBinder, IBinder.DeathRecipient> deathLinks = new HashMap<>();
    private boolean listening = false;

    private SecondScreenDisplay(Activity activity, FlutterEngine engine) {
        this.activity = activity;
        this.displayManager =
                (DisplayManager) activity.getSystemService(Context.DISPLAY_SERVICE);
        this.channel = new MethodChannel(
                engine.getDartExecutor().getBinaryMessenger(), ChannelNames.SECOND_SCREEN);
        // configureFlutterEngine runs in onCreate, before onStart; a cached
        // engine re-attached later gets a fresh instance the same way.
        this.lifecycle = new SecondScreenLifecycle<>(
                new SecondScreenLifecycle.Effects<Messenger>() {
                    @Override
                    public boolean launch(int display, @NonNull String mode, int token) {
                        return launchPanel(display, mode, token);
                    }

                    @Override
                    public void finish(@NonNull Messenger panel) {
                        finishPanel(panel);
                    }

                    @Override
                    public void attachedChanged(boolean attached) {
                        channel.invokeMethod("panelAttached", attached ? attachedState() : null);
                    }
                },
                false);
        this.channel.setMethodCallHandler(this::onMethodCall);
        activity.getApplication().registerActivityLifecycleCallbacks(this);
    }

    static void registerWith(@NonNull FlutterEngine engine, @NonNull Activity activity) {
        detach();
        final SecondScreenDisplay created = new SecondScreenDisplay(activity, engine);
        instance = created;
        // The engine can outlive the Activity: Dart clients that already
        // placed a panel are told their placement is void (detach above
        // dropped any panel, also one launched but not yet registered, which
        // reports no attached edge) and get the current displays to place it
        // again on this instance.
        created.channel.invokeMethod("hostReset", created.describeDisplays());
    }

    /**
     * Activity teardown: close the panel and stop listening. The engine may
     * outlive this Activity (MainActivity's engine is cached), so Dart is told
     * the panel is gone and asks the next instance again.
     */
    static void detach() {
        final SecondScreenDisplay current = instance;
        instance = null;
        if (current == null) return;
        current.channel.setMethodCallHandler(null);
        current.activity.getApplication().unregisterActivityLifecycleCallbacks(current);
        current.stopListening();
        current.lifecycle.dismiss();
        current.unlinkAll();
    }

    @Nullable
    static SecondScreenDisplay current() {
        return instance;
    }

    /** API 29+: multi-resume keeps both activities live. */
    static boolean supported() {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q;
    }

    /** One display entry; shared with the panel's own channel. */
    @NonNull
    static Map<String, Object> describe(@NonNull Display display) {
        final DisplayMetrics metrics = new DisplayMetrics();
        display.getRealMetrics(metrics);
        final float scale = metrics.densityDpi > 0 ? metrics.densityDpi / 160f : 1f;
        final Map<String, Object> entry = new HashMap<>();
        entry.put("id", display.getDisplayId());
        entry.put("name", display.getName());
        entry.put("widthPx", metrics.widthPixels);
        entry.put("heightPx", metrics.heightPixels);
        entry.put("widthDp", (double) (metrics.widthPixels / scale));
        entry.put("heightDp", (double) (metrics.heightPixels / scale));
        entry.put("densityDpi", metrics.densityDpi);
        return entry;
    }

    private void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "listDisplays":
                startListening();
                result.success(describeDisplays());
                break;
            case "show": {
                final Integer displayId = call.argument("displayId");
                final String mode = call.argument("mode");
                if (displayId == null || mode == null) {
                    result.error("INVALID_ARG", "displayId and mode required", null);
                    return;
                }
                result.success(show(displayId, mode));
                break;
            }
            case "dismiss":
                lifecycle.dismiss();
                result.success(null);
                break;
            case "send": {
                final Object json = call.arguments;
                if (!(json instanceof String)) {
                    result.error("INVALID_ARG", "json string required", null);
                    return;
                }
                result.success(sendToPanel((String) json));
                break;
            }
            default:
                result.notImplemented();
        }
    }

    private void startListening() {
        if (listening) return;
        listening = true;
        displayManager.registerDisplayListener(this, mainHandler);
    }

    private void stopListening() {
        if (!listening) return;
        listening = false;
        displayManager.unregisterDisplayListener(this);
    }

    private int ownDisplayId() {
        final Display own = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
                ? activity.getDisplay()
                : activity.getWindowManager().getDefaultDisplay();
        return own == null ? Display.DEFAULT_DISPLAY : own.getDisplayId();
    }

    /**
     * Whether the panel can go on {@code display}: on, not the app's own, not
     * private, and open to this app's activities.
     */
    private boolean capable(@NonNull Display display, @NonNull Intent probe, int own,
            @Nullable ActivityManager am) {
        final int id = display.getDisplayId();
        if (id == own) return false;
        if ((display.getFlags() & Display.FLAG_PRIVATE) != 0) return false;
        if (display.getState() == Display.STATE_OFF) return false;
        return am != null && am.isActivityStartAllowedOnDisplay(activity, id, probe);
    }

    /** Displays the panel can go on. */
    private List<Map<String, Object>> describeDisplays() {
        final List<Map<String, Object>> out = new ArrayList<>();
        if (!supported()) return out;
        final int own = ownDisplayId();
        final Intent probe = new Intent(activity, SecondScreenActivity.class);
        final ActivityManager am =
                (ActivityManager) activity.getSystemService(Context.ACTIVITY_SERVICE);
        for (Display display : displayManager.getDisplays()) {
            if (capable(display, probe, own, am)) out.add(describe(display));
        }
        return out;
    }

    private boolean show(int displayId, @NonNull String mode) {
        if (!supported()) return false;
        // A client asking for a panel wants to hear about displays too, also
        // on an instance created after it last listed them (Activity
        // recreated).
        startListening();
        return lifecycle.show(displayId, mode);
    }

    private boolean launchPanel(int displayId, @NonNull String mode, int token) {
        final Display display = displayManager.getDisplay(displayId);
        final ActivityManager am =
                (ActivityManager) activity.getSystemService(Context.ACTIVITY_SERVICE);
        final Intent intent = new Intent(activity, SecondScreenActivity.class);
        // The display can be gone or off by now (a relaunch on host start).
        if (display == null || !capable(display, intent, ownDisplayId(), am)) return false;
        intent.putExtra(SecondScreenActivity.EXTRA_DISPLAY_ID, displayId);
        intent.putExtra(SecondScreenActivity.EXTRA_LAUNCH_TOKEN, token);
        intent.putExtra(SecondScreenActivity.EXTRA_MODE, mode);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                | Intent.FLAG_ACTIVITY_MULTIPLE_TASK
                | Intent.FLAG_ACTIVITY_NO_ANIMATION);
        final ActivityOptions options = ActivityOptions.makeBasic();
        options.setLaunchDisplayId(displayId);
        try {
            activity.startActivity(intent, options.toBundle());
        } catch (RuntimeException e) {
            // SecurityException (display closed to this app) or the display went
            // away between the check and now: report, Dart stays single-screen.
            Log.w(TAG, "launch on display " + displayId + " failed", e);
            return false;
        }
        return true;
    }

    @NonNull
    private Map<String, Object> attachedState() {
        final Map<String, Object> state = new HashMap<>();
        state.put("mode", lifecycle.mode());
        state.put("displayId", lifecycle.displayId());
        return state;
    }

    private static void finishPanel(@NonNull Messenger panel) {
        try {
            panel.send(Message.obtain(null, SecondScreenRelayService.MSG_FINISH));
        } catch (RemoteException e) {
            // The panel process is already gone; its death link reports it.
            Log.w(TAG, "finish: panel already gone", e);
        }
    }

    private boolean sendToPanel(@NonNull String json) {
        final Messenger target = lifecycle.panel();
        if (target == null) return false;
        final Message message = Message.obtain(null, SecondScreenRelayService.MSG_TO_PANEL);
        final Bundle data = new Bundle();
        data.putString(SecondScreenRelayService.KEY_JSON, json);
        message.setData(data);
        try {
            target.send(message);
            return true;
        } catch (RemoteException e) {
            Log.w(TAG, "send: panel gone", e);
            return false;
        }
    }

    // ---- From SecondScreenRelayService (main thread) ------------------------

    /** A panel started; {@code token} is the launch token it was started with. */
    void onPanelRegistered(@NonNull Messenger messenger, int token) {
        final IBinder binder = messenger.getBinder();
        final IBinder.DeathRecipient death = () -> mainHandler.post(() -> onPanelClosed(messenger));
        try {
            binder.linkToDeath(death, 0);
        } catch (RemoteException e) {
            // Died between bind and register: nothing to show.
            return;
        }
        if (lifecycle.register(messenger, token)) {
            deathLinks.put(binder, death);
        } else {
            binder.unlinkToDeath(death, 0);
        }
    }

    /** A panel unregistered or its process died. */
    void onPanelClosed(@NonNull Messenger messenger) {
        final IBinder.DeathRecipient death = deathLinks.remove(messenger.getBinder());
        if (death != null) messenger.getBinder().unlinkToDeath(death, 0);
        lifecycle.gone(messenger);
    }

    private void unlinkAll() {
        for (Map.Entry<IBinder, IBinder.DeathRecipient> link : deathLinks.entrySet()) {
            link.getKey().unlinkToDeath(link.getValue(), 0);
        }
        deathLinks.clear();
    }

    /**
     * A message from {@code sender}. Only the registered panel's count: a
     * replaced one still closing (another mode, another display) is not heard,
     * so Dart can route by the mode of the panel that is up.
     */
    void onPanelMessage(@NonNull Messenger sender, @NonNull String json) {
        if (!sender.equals(lifecycle.panel())) return;
        channel.invokeMethod("panelMessage", json);
    }

    void onPanelKey(@NonNull KeyEvent event) {
        activity.dispatchKeyEvent(event);
    }

    void onPanelMotion(@NonNull MotionEvent event) {
        activity.dispatchGenericMotionEvent(event);
    }

    // ---- DisplayManager.DisplayListener -----------------------------------

    @Override
    public void onDisplayAdded(int displayId) {
        channel.invokeMethod("displaysChanged", describeDisplays());
    }

    @Override
    public void onDisplayRemoved(int displayId) {
        // The list first: clients re-place the panel from it when they hear
        // the panel went away.
        channel.invokeMethod("displaysChanged", describeDisplays());
        lifecycle.displayRemoved(displayId);
    }

    @Override
    public void onDisplayChanged(int displayId) {
        channel.invokeMethod("displaysChanged", describeDisplays());
    }

    // ---- Application.ActivityLifecycleCallbacks (host Activity only) ------

    @Override
    public void onActivityStarted(@NonNull Activity started) {
        if (started != activity) return;
        final boolean hadWish = lifecycle.mode() != null;
        lifecycle.hostStarted();
        // The wanted panel could not come back (its display went away or
        // closed to this app while the host was stopped): clients place again.
        if (hadWish && lifecycle.mode() == null) {
            channel.invokeMethod("hostReset", describeDisplays());
        }
    }

    @Override
    public void onActivityStopped(@NonNull Activity stopped) {
        if (stopped != activity) return;
        lifecycle.hostStopped();
    }

    @Override
    public void onActivityCreated(@NonNull Activity a, @Nullable Bundle b) {}

    @Override
    public void onActivityResumed(@NonNull Activity a) {}

    @Override
    public void onActivityPaused(@NonNull Activity a) {}

    @Override
    public void onActivitySaveInstanceState(@NonNull Activity a, @NonNull Bundle b) {}

    @Override
    public void onActivityDestroyed(@NonNull Activity a) {}
}
