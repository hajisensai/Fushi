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
import java.util.List;

import app.fushi.reader.constants.ChannelNames;
import io.flutter.FlutterInjector;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.dart.DartExecutor;
import io.flutter.plugin.common.MethodChannel;

/**
 * The game stream's lookup panel on the second display (process
 * {@code :companion}). It only renders: the stream page in the main process
 * owns every bit of state and pushes it here through
 * {@link GameStreamCompanionRelayService}.
 *
 * <p>Controller buttons always belong to the stream page. Touching this
 * display (or launching the panel) can make it Android's focused display, and
 * then keys arrive here; every key and controller motion is forwarded to the
 * main Activity instead of being handled. The window stays focusable on
 * purpose: as the top activity of its display it is the focused app there, and
 * a non-focusable window leaves InputDispatcher waiting for a focused window
 * until it raises an ANR and kills the panel (seen on an API 37 emulator).
 * Nothing in the panel takes text input, so focus here never opens a keyboard.
 *
 * <p>Its lifetime belongs to the stream page: Back does nothing, and the panel
 * closes itself when it is not on the display it was launched for (its display
 * went away and Android moved it, possibly on top of the game).
 */
public class GameStreamCompanionActivity extends FlutterActivity
        implements DisplayManager.DisplayListener {
    private static final String TAG = "GameStreamCompanion";
    private static final String ENTRYPOINT = "gameStreamCompanionMain";

    /** Intent extra: the display this panel was launched for. */
    static final String EXTRA_DISPLAY_ID = "app.fushi.reader.extra.COMPANION_DISPLAY_ID";

    /** The display this panel belongs on; anywhere else it closes. */
    private int targetDisplayId = Display.INVALID_DISPLAY;

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
                    Message.obtain(null, GameStreamCompanionRelayService.MSG_REGISTER);
            register.replyTo = inbox;
            if (!sendToRelay(register)) finish();
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            // The main process died: there is no stream left to show.
            relay = null;
            finish();
        }
    };

    /** Whether this process already chose its WebView data directory. */
    private static boolean webViewDataDirConfigured = false;

    /**
     * The panel renders the dictionary in a flutter_inappwebview WebView inside
     * the :companion process, while the main process (stream page, reader, ...)
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
                WebView.setDataDirectorySuffix("companion");
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
        if (isOffTargetDisplay()) {
            finish();
            return;
        }
        displayManager = (DisplayManager) getSystemService(Context.DISPLAY_SERVICE);
        if (displayManager != null) displayManager.registerDisplayListener(this, mainHandler);
        bound = bindService(
                new Intent(this, GameStreamCompanionRelayService.class),
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
                ChannelNames.GAME_STREAM_COMPANION);
        channel.setMethodCallHandler((call, result) -> {
            switch (call.method) {
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
                            Message.obtain(null, GameStreamCompanionRelayService.MSG_TO_HOST);
                    final Bundle data = new Bundle();
                    data.putString(GameStreamCompanionRelayService.KEY_JSON, (String) json);
                    message.setData(data);
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
            case GameStreamCompanionRelayService.MSG_TO_COMPANION: {
                final String json =
                        message.getData().getString(GameStreamCompanionRelayService.KEY_JSON);
                if (json == null) return true;
                if (!dartListening || channel == null) {
                    pendingForDart.add(json);
                } else {
                    channel.invokeMethod("message", json);
                }
                return true;
            }
            case GameStreamCompanionRelayService.MSG_FINISH:
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
        // Back belongs to the stream page; the panel never closes itself on it.
        if (event.getKeyCode() == KeyEvent.KEYCODE_BACK) return true;
        final Message message = Message.obtain(null, GameStreamCompanionRelayService.MSG_KEY);
        final Bundle data = new Bundle();
        data.putParcelable(GameStreamCompanionRelayService.KEY_EVENT, event);
        message.setData(data);
        sendToRelay(message);
        return true;
    }

    @Override
    public boolean dispatchGenericMotionEvent(MotionEvent event) {
        // Controller sticks / triggers go to the game; mouse wheel and hover
        // stay with this panel's Flutter view.
        if (!event.isFromSource(InputDevice.SOURCE_JOYSTICK)
                && !event.isFromSource(InputDevice.SOURCE_GAMEPAD)) {
            return super.dispatchGenericMotionEvent(event);
        }
        final Message message =
                Message.obtain(null, GameStreamCompanionRelayService.MSG_MOTION);
        final Bundle data = new Bundle();
        data.putParcelable(GameStreamCompanionRelayService.KEY_EVENT, event);
        message.setData(data);
        sendToRelay(message);
        return true;
    }

    @Override
    @SuppressWarnings("MissingSuperCall")
    public void onBackPressed() {
        // See dispatchKeyEvent: a back gesture on this display does nothing.
    }

    // ---- Display: close instead of being moved to another display --------

    private int currentDisplayId() {
        final Display display = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
                ? getDisplay()
                : getWindowManager().getDefaultDisplay();
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
                    Message.obtain(null, GameStreamCompanionRelayService.MSG_UNREGISTER);
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
