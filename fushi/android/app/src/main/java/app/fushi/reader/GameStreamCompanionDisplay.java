package app.fushi.reader;

import android.app.Activity;
import android.app.ActivityManager;
import android.app.ActivityOptions;
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
 * Game stream on a dual-screen device (AYN Thor bottom screen, a display
 * plugged into a phone): the stream page stays on the app's own display and
 * the lookup panel goes on the other one.
 *
 * <p>Main-process half. The panel is {@link GameStreamCompanionActivity}, its
 * own activity in the {@code :companion} process with its own Flutter engine
 * (the dictionary WebView needs a real Activity, and the panel needs the
 * popup's full AppModel, which only runs safely in a separate process like
 * {@code :popup}). The two talk through {@link GameStreamCompanionRelayService}.
 *
 * <p>Channel {@link ChannelNames#GAME_STREAM_COMPANION} on the main engine:
 * <ul>
 *   <li>Dart → Java: {@code listDisplays}, {@code show(displayId)},
 *       {@code dismiss}, {@code send(json)}.</li>
 *   <li>Java → Dart: {@code displaysChanged(list)}, {@code companionAttached(bool)},
 *       {@code companionMessage(json)}, {@code companionReset(list)} (a new
 *       instance took over: nothing placed before survives).</li>
 * </ul>
 *
 * <p>Controller keys the panel receives are dispatched into this Activity, so
 * the buttons always drive the stream page whichever screen was touched last.
 */
final class GameStreamCompanionDisplay implements DisplayManager.DisplayListener {
    private static final String TAG = "GameStreamCompanion";

    @Nullable private static GameStreamCompanionDisplay instance;

    private final Activity activity;
    private final MethodChannel channel;
    private final DisplayManager displayManager;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    /** Which panel is wanted and whether it is up (see the class). */
    private final GameStreamCompanionLifecycle<Messenger> lifecycle =
            new GameStreamCompanionLifecycle<>(new GameStreamCompanionLifecycle.Effects<Messenger>() {
                @Override
                public void finish(@NonNull Messenger panel) {
                    finishPanel(panel);
                }

                @Override
                public void attachedChanged(boolean attached) {
                    channel.invokeMethod("companionAttached", attached);
                }
            });

    /** Death links of registered panels, removed when each one goes. */
    private final Map<IBinder, IBinder.DeathRecipient> deathLinks = new HashMap<>();
    private boolean listening = false;

    private GameStreamCompanionDisplay(Activity activity, FlutterEngine engine) {
        this.activity = activity;
        this.displayManager =
                (DisplayManager) activity.getSystemService(Context.DISPLAY_SERVICE);
        this.channel = new MethodChannel(
                engine.getDartExecutor().getBinaryMessenger(),
                ChannelNames.GAME_STREAM_COMPANION);
        this.channel.setMethodCallHandler(this::onMethodCall);
    }

    static void registerWith(@NonNull FlutterEngine engine, @NonNull Activity activity) {
        detach();
        final GameStreamCompanionDisplay created = new GameStreamCompanionDisplay(activity, engine);
        instance = created;
        // The engine can outlive the Activity: a stream page that was already
        // running is told its placement is void (detach above dropped any
        // panel, also one launched but not yet registered, which reports no
        // attached edge) and gets the current displays to place it again on
        // this instance. Nothing listens when no page runs.
        created.channel.invokeMethod("companionReset", created.describeDisplays());
    }

    /**
     * Activity teardown: close the panel and stop listening. The engine may
     * outlive this Activity (MainActivity's engine is cached), so Dart is told
     * the panel is gone, and asks the next instance for one again.
     */
    static void detach() {
        final GameStreamCompanionDisplay current = instance;
        instance = null;
        if (current == null) return;
        current.channel.setMethodCallHandler(null);
        current.stopListening();
        current.lifecycle.dismiss();
        current.unlinkAll();
    }

    @Nullable
    static GameStreamCompanionDisplay current() {
        return instance;
    }

    /** Running on API 29+: multi-resume keeps both activities live. */
    static boolean supported() {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q;
    }

    private void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "listDisplays":
                startListening();
                result.success(describeDisplays());
                break;
            case "show": {
                final Integer displayId = call.argument("displayId");
                if (displayId == null) {
                    result.error("INVALID_ARG", "displayId required", null);
                    return;
                }
                result.success(show(displayId));
                break;
            }
            case "dismiss":
                dismiss();
                result.success(null);
                break;
            case "send": {
                final Object json = call.arguments;
                if (!(json instanceof String)) {
                    result.error("INVALID_ARG", "json string required", null);
                    return;
                }
                result.success(sendToCompanion((String) json));
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
     * Displays the panel can go on: on, not the app's own, not private, and
     * open to this app's activities.
     */
    private List<Map<String, Object>> describeDisplays() {
        final List<Map<String, Object>> out = new ArrayList<>();
        if (!supported()) return out;
        final int own = ownDisplayId();
        final Intent probe = new Intent(activity, GameStreamCompanionActivity.class);
        for (Display display : displayManager.getDisplays()) {
            final int id = display.getDisplayId();
            if (id == own) continue;
            if ((display.getFlags() & Display.FLAG_PRIVATE) != 0) continue;
            if (display.getState() == Display.STATE_OFF) continue;
            final ActivityManager am =
                    (ActivityManager) activity.getSystemService(Context.ACTIVITY_SERVICE);
            if (am == null || !am.isActivityStartAllowedOnDisplay(activity, id, probe)) {
                continue;
            }
            final android.graphics.Point size = new android.graphics.Point();
            display.getRealSize(size);
            final Map<String, Object> entry = new HashMap<>();
            entry.put("id", id);
            entry.put("name", display.getName());
            entry.put("width", size.x);
            entry.put("height", size.y);
            out.add(entry);
        }
        return out;
    }

    private boolean show(int displayId) {
        if (!supported()) return false;
        // A page asking for a panel wants to hear about displays too, also on
        // an instance created after it last listed them (Activity recreated).
        startListening();
        final int token = lifecycle.show(displayId);
        if (token == GameStreamCompanionLifecycle.NO_TOKEN) return true;
        final Intent intent = new Intent(activity, GameStreamCompanionActivity.class);
        intent.putExtra(GameStreamCompanionActivity.EXTRA_DISPLAY_ID, displayId);
        intent.putExtra(GameStreamCompanionActivity.EXTRA_LAUNCH_TOKEN, token);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                | Intent.FLAG_ACTIVITY_MULTIPLE_TASK
                | Intent.FLAG_ACTIVITY_NO_ANIMATION);
        final ActivityOptions options = ActivityOptions.makeBasic();
        options.setLaunchDisplayId(displayId);
        try {
            activity.startActivity(intent, options.toBundle());
        } catch (RuntimeException e) {
            // SecurityException (display closed to this app) or the display went
            // away between listDisplays and now: report, Dart keeps the rail.
            Log.w(TAG, "launch on display " + displayId + " failed", e);
            lifecycle.launchFailed(token);
            return false;
        }
        return true;
    }

    private void dismiss() {
        lifecycle.dismiss();
    }

    private static void finishPanel(@NonNull Messenger panel) {
        try {
            panel.send(Message.obtain(null, GameStreamCompanionRelayService.MSG_FINISH));
        } catch (RemoteException e) {
            // The panel process is already gone; its death link reports it.
            Log.w(TAG, "finish: companion already gone", e);
        }
    }

    private boolean sendToCompanion(String json) {
        final Messenger target = lifecycle.panel();
        if (target == null) return false;
        final Message message =
                Message.obtain(null, GameStreamCompanionRelayService.MSG_TO_COMPANION);
        final Bundle data = new Bundle();
        data.putString(GameStreamCompanionRelayService.KEY_JSON, json);
        message.setData(data);
        try {
            target.send(message);
            return true;
        } catch (RemoteException e) {
            Log.w(TAG, "send: companion gone", e);
            return false;
        }
    }

    // ---- From GameStreamCompanionRelayService (main thread) ----------------

    /** A panel started; {@code token} is the launch token it was started with. */
    void onCompanionRegistered(@NonNull Messenger messenger, int token) {
        final IBinder binder = messenger.getBinder();
        final IBinder.DeathRecipient death = () -> mainHandler.post(() -> onCompanionClosed(messenger));
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
    void onCompanionClosed(@NonNull Messenger messenger) {
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

    void onCompanionMessage(@NonNull String json) {
        channel.invokeMethod("companionMessage", json);
    }

    void onCompanionKey(@NonNull KeyEvent event) {
        activity.dispatchKeyEvent(event);
    }

    void onCompanionMotion(@NonNull MotionEvent event) {
        activity.dispatchGenericMotionEvent(event);
    }

    // ---- DisplayManager.DisplayListener -----------------------------------

    @Override
    public void onDisplayAdded(int displayId) {
        channel.invokeMethod("displaysChanged", describeDisplays());
    }

    @Override
    public void onDisplayRemoved(int displayId) {
        // The list first: the page re-places the panel from it when it hears
        // the panel went away.
        channel.invokeMethod("displaysChanged", describeDisplays());
        if (displayId == lifecycle.displayId()) dismiss();
    }

    @Override
    public void onDisplayChanged(int displayId) {
        channel.invokeMethod("displaysChanged", describeDisplays());
    }
}
