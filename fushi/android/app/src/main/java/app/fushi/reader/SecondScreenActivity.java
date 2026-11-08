package app.fushi.reader;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.res.Configuration;
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
import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.WindowManager;
import android.webkit.WebView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import app.fushi.reader.constants.ChannelNames;
import io.flutter.FlutterInjector;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.dart.DartExecutor;
import io.flutter.plugin.common.MethodChannel;

/**
 * The panel on the second display (process {@code :second_screen}), in one of
 * two modes chosen at launch ({@link #EXTRA_MODE}): the companion, or the game
 * stream's lookup panel. It only renders: the main process owns every bit of
 * state and pushes it here through {@link SecondScreenRelayService}.
 *
 * <p>Controller buttons always belong to the top screen. Touching this
 * display (or launching the panel) can make it Android's focused display, and
 * then keys arrive here; every key and controller motion is forwarded to the
 * main Activity instead of being handled. The window stays focusable on
 * purpose: as the top activity of its display it is the focused app there, and
 * a non-focusable window leaves InputDispatcher waiting for a focused window
 * until it raises an ANR and kills the panel (seen on an API 37 emulator).
 * Nothing in the panel takes text input, so focus here never opens a keyboard.
 *
 * <p>Its lifetime belongs to the main process: Back never closes the panel, and
 * the panel closes itself when it is not on the display it was launched for
 * (its display went away and Android moved it, possibly on top of the game).
 * In companion mode, Back from this display's own navigation (gesture / nav
 * bar, not a controller) steps back in the companion's tab history; the game
 * stream panel ignores it.
 */
public class SecondScreenActivity extends FlutterActivity
        implements DisplayManager.DisplayListener {
    private static final String TAG = "SecondScreen";
    private static final String ENTRYPOINT = "secondScreenMain";

    /** Intent extra: the display this panel was launched for. */
    static final String EXTRA_DISPLAY_ID = "app.fushi.reader.extra.SECOND_SCREEN_DISPLAY_ID";

    /**
     * Intent extra: the launch this panel belongs to; sent back on register
     * so the host can tell it from an earlier, replaced panel.
     */
    static final String EXTRA_LAUNCH_TOKEN = "app.fushi.reader.extra.SECOND_SCREEN_LAUNCH_TOKEN";

    /** Intent extra: the panel's mode ({@code companion} / {@code gameStream}). */
    static final String EXTRA_MODE = "app.fushi.reader.extra.SECOND_SCREEN_MODE";

    /** {@link #EXTRA_MODE} of the companion (handles Back in its own history). */
    static final String MODE_COMPANION = "companion";

    /** The display this panel belongs on; anywhere else it closes. */
    private int targetDisplayId = Display.INVALID_DISPLAY;
    private int launchToken = SecondScreenLifecycle.NO_TOKEN;
    @Nullable private String mode;

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Messenger inbox = new Messenger(new Handler(Looper.getMainLooper(), this::onRelayMessage));
    @Nullable private Messenger relay;
    @Nullable private MethodChannel channel;
    @Nullable private DisplayManager displayManager;
    private boolean bound = false;

    /** Messages for Dart that arrived before Dart asked for them. */
    private final List<String> pendingForDart = new ArrayList<>();
    private boolean dartListening = false;

    private final ServiceConnection connection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder service) {
            relay = new Messenger(service);
            final Message register =
                    Message.obtain(null, SecondScreenRelayService.MSG_REGISTER);
            register.replyTo = inbox;
            register.arg1 = launchToken;
            if (!sendToRelay(register)) finish();
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            // The main process died: there is nothing left to show.
            relay = null;
            finish();
        }
    };

    /** Whether this process already chose its WebView data directory. */
    private static boolean webViewDataDirConfigured = false;

    /**
     * The panel renders the dictionary in a flutter_inappwebview WebView inside
     * the :second_screen process, while the main process (reader, stream page, ...)
     * already uses WebView. Android forbids two processes sharing one WebView
     * data directory (crbug.com/558377): without its own suffix the panel's
     * WebView fails to create and the dictionary stays blank. Must run before
     * anything in this process touches WebView, so before the engine starts
     * in super.onCreate. Same as the :popup process.
     */
    private static void configureWebViewDataDir() {
        if (webViewDataDirConfigured) return;
        webViewDataDirConfigured = true;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                WebView.setDataDirectorySuffix("second_screen");
            } catch (IllegalStateException e) {
                // WebView was already initialised in this process; it keeps the
                // directory it started with.
            }
        }
    }

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        configureWebViewDataDir();
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        super.onCreate(savedInstanceState);
        targetDisplayId = getIntent().getIntExtra(EXTRA_DISPLAY_ID, Display.INVALID_DISPLAY);
        launchToken = getIntent().getIntExtra(
                EXTRA_LAUNCH_TOKEN, SecondScreenLifecycle.NO_TOKEN);
        mode = getIntent().getStringExtra(EXTRA_MODE);
        if (isOffTargetDisplay()) {
            finish();
            return;
        }
        displayManager = (DisplayManager) getSystemService(Context.DISPLAY_SERVICE);
        if (displayManager != null) displayManager.registerDisplayListener(this, mainHandler);
        bound = bindService(
                new Intent(this, SecondScreenRelayService.class),
                connection,
                Context.BIND_AUTO_CREATE);
        if (!bound) finish();
    }

    @Override
    public FlutterEngine provideFlutterEngine(@NonNull Context context) {
        final FlutterEngine engine = new FlutterEngine(context.getApplicationContext(), null, false);
        // Same curated plugin set as the :popup engine (dictionary WebView,
        // path_provider, sqflite, Anki/TTS channels, ...): the popup's AppModel
        // runs here too.
        FloatingDictPluginRegistrant.registerWith(engine, context.getApplicationContext());
        channel = new MethodChannel(
                engine.getDartExecutor().getBinaryMessenger(),
                ChannelNames.SECOND_SCREEN);
        channel.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "launchInfo": {
                    // Asked first by secondScreenMain to pick what to render.
                    final Map<String, Object> info = new HashMap<>();
                    info.put("mode", mode);
                    final Display display = currentDisplay();
                    info.put("display",
                            display == null ? null : SecondScreenDisplay.describe(display));
                    result.success(info);
                    break;
                }
                case "listen": {
                    dartListening = true;
                    final List<String> backlog = new ArrayList<>(pendingForDart);
                    pendingForDart.clear();
                    result.success(backlog);
                    break;
                }
                case "send": {
                    final Object json = call.arguments;
                    if (!(json instanceof String)) {
                        result.error("INVALID_ARG", "json string required", null);
                        return;
                    }
                    final Message message =
                            Message.obtain(null, SecondScreenRelayService.MSG_TO_HOST);
                    final Bundle data = new Bundle();
                    data.putString(SecondScreenRelayService.KEY_JSON, (String) json);
                    message.setData(data);
                    message.replyTo = inbox;
                    result.success(sendToRelay(message));
                    break;
                }
                default:
                    result.notImplemented();
            }
        });
        final String bundlePath =
                FlutterInjector.instance().flutterLoader().findAppBundlePath();
        engine.getDartExecutor().executeDartEntrypoint(
                new DartExecutor.DartEntrypoint(bundlePath, ENTRYPOINT));
        return engine;
    }

    @Override
    public boolean shouldDestroyEngineWithHost() {
        return true;
    }

    private boolean onRelayMessage(@NonNull Message message) {
        switch (message.what) {
            case SecondScreenRelayService.MSG_TO_PANEL: {
                final String json =
                        message.getData().getString(SecondScreenRelayService.KEY_JSON);
                if (json == null) return true;
                if (!dartListening || channel == null) {
                    pendingForDart.add(json);
                } else {
                    channel.invokeMethod("message", json);
                }
                return true;
            }
            case SecondScreenRelayService.MSG_FINISH:
                finish();
                return true;
            default:
                return false;
        }
    }

    private boolean sendToRelay(@NonNull Message message) {
        final Messenger target = relay;
        if (target == null) return false;
        try {
            target.send(message);
            return true;
        } catch (RemoteException e) {
            Log.w(TAG, "relay gone", e);
            return false;
        }
    }

    // ---- Input: nothing is handled here ----------------------------------

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        if (event.getKeyCode() == KeyEvent.KEYCODE_BACK) {
            // The panel never closes itself on Back. The companion steps back
            // in its tab history on this display's own Back; a controller's
            // Back belongs to the top screen.
            if (handlesBackItself()
                    && !isFromController(event)
                    && event.getAction() == KeyEvent.ACTION_UP
                    && !event.isCanceled()) {
                popFlutterRoute();
            }
            return true;
        }
        final Message message = Message.obtain(null, SecondScreenRelayService.MSG_KEY);
        final Bundle data = new Bundle();
        data.putParcelable(SecondScreenRelayService.KEY_EVENT, event);
        message.setData(data);
        sendToRelay(message);
        return true;
    }

    @Override
    public boolean dispatchGenericMotionEvent(MotionEvent event) {
        // Controller sticks / triggers go to the top screen; mouse wheel and hover
        // stay with this panel's Flutter view.
        if (!event.isFromSource(InputDevice.SOURCE_JOYSTICK)
                && !event.isFromSource(InputDevice.SOURCE_GAMEPAD)) {
            return super.dispatchGenericMotionEvent(event);
        }
        final Message message =
                Message.obtain(null, SecondScreenRelayService.MSG_MOTION);
        final Bundle data = new Bundle();
        data.putParcelable(SecondScreenRelayService.KEY_EVENT, event);
        message.setData(data);
        sendToRelay(message);
        return true;
    }

    @Override
    @SuppressWarnings("MissingSuperCall")
    public void onBackPressed() {
        // A back gesture (API 33: through the framework's back callback) steps
        // back in the companion; otherwise it does nothing (see dispatchKeyEvent).
        if (handlesBackItself()) popFlutterRoute();
    }

    @Override
    public boolean popSystemNavigator() {
        // The companion's Dart side found nothing to pop: stay up (the panel's
        // lifetime belongs to the main process) instead of finishing.
        return handlesBackItself() || super.popSystemNavigator();
    }

    private boolean handlesBackItself() {
        return MODE_COMPANION.equals(mode);
    }

    private static boolean isFromController(KeyEvent event) {
        return event.isFromSource(InputDevice.SOURCE_GAMEPAD)
                || event.isFromSource(InputDevice.SOURCE_JOYSTICK);
    }

    /** Hands Back to the Flutter framework (the companion's root PopScope). */
    private void popFlutterRoute() {
        final FlutterEngine engine = getFlutterEngine();
        if (engine != null) engine.getNavigationChannel().popRoute();
    }

    // ---- Display: close instead of being moved to another display --------

    @Nullable
    private Display currentDisplay() {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
                ? getDisplay()
                : getWindowManager().getDefaultDisplay();
    }

    private int currentDisplayId() {
        final Display display = currentDisplay();
        return display == null ? Display.DEFAULT_DISPLAY : display.getDisplayId();
    }

    private boolean isOffTargetDisplay() {
        return currentDisplayId() != targetDisplayId;
    }

    @Override
    public void onConfigurationChanged(@NonNull Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        if (isOffTargetDisplay()) finish();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (isOffTargetDisplay()) finish();
    }

    @Override
    public void onDisplayAdded(int displayId) {}

    @Override
    public void onDisplayRemoved(int displayId) {
        if (displayId == targetDisplayId || isOffTargetDisplay()) finish();
    }

    @Override
    public void onDisplayChanged(int displayId) {
        if (isOffTargetDisplay()) finish();
    }

    @Override
    protected void onDestroy() {
        if (displayManager != null) displayManager.unregisterDisplayListener(this);
        if (bound) {
            final Message unregister =
                    Message.obtain(null, SecondScreenRelayService.MSG_UNREGISTER);
            unregister.replyTo = inbox;
            sendToRelay(unregister);
            unbindService(connection);
            bound = false;
        }
        relay = null;
        if (channel != null) {
            channel.setMethodCallHandler(null);
            channel = null;
        }
        super.onDestroy();
    }
}
