package app.fushi.reader;

import android.app.Service;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Message;
import android.os.Messenger;
import android.view.KeyEvent;
import android.view.MotionEvent;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

/**
 * Main-process end of the pipe between the game stream page and its panel on
 * the second display ({@link GameStreamCompanionActivity}, process
 * {@code :companion}). The panel binds this service and talks through
 * {@link Messenger}s; everything lands on the main thread and goes to
 * {@link GameStreamCompanionDisplay}.
 *
 * <p>Panel → main: {@link #MSG_REGISTER} (replyTo = the panel's messenger),
 * {@link #MSG_UNREGISTER}, {@link #MSG_TO_HOST} (one JSON message),
 * {@link #MSG_KEY} / {@link #MSG_MOTION} (controller input the panel's
 * window received). Main → panel: {@link #MSG_TO_COMPANION}, {@link #MSG_FINISH}.
 */
public class GameStreamCompanionRelayService extends Service {
    static final int MSG_REGISTER = 1;
    static final int MSG_UNREGISTER = 2;
    static final int MSG_TO_HOST = 3;
    static final int MSG_KEY = 4;
    static final int MSG_MOTION = 5;
    static final int MSG_TO_COMPANION = 10;
    static final int MSG_FINISH = 11;

    static final String KEY_JSON = "json";
    static final String KEY_EVENT = "event";

    private final Messenger messenger =
            new Messenger(new Handler(Looper.getMainLooper(), this::handle));

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return messenger.getBinder();
    }

    private boolean handle(@NonNull Message message) {
        final GameStreamCompanionDisplay display = GameStreamCompanionDisplay.current();
        final Bundle data = message.getData();
        data.setClassLoader(KeyEvent.class.getClassLoader());
        switch (message.what) {
            case MSG_REGISTER:
                if (message.replyTo == null) return true;
                if (display == null) {
                    // The stream page's Activity is gone: nothing to show for.
                    finishPanel(message.replyTo);
                    return true;
                }
                display.onCompanionRegistered(message.replyTo);
                return true;
            case MSG_UNREGISTER:
                if (display != null && message.replyTo != null) {
                    display.onCompanionUnregistered(message.replyTo);
                }
                return true;
            case MSG_TO_HOST: {
                final String json = data.getString(KEY_JSON);
                if (display != null && json != null) display.onCompanionMessage(json);
                return true;
            }
            case MSG_KEY: {
                final KeyEvent event = data.getParcelable(KEY_EVENT);
                if (display != null && event != null) display.onCompanionKey(event);
                return true;
            }
            case MSG_MOTION: {
                final MotionEvent event = data.getParcelable(KEY_EVENT);
                if (display != null && event != null) display.onCompanionMotion(event);
                return true;
            }
            default:
                return false;
        }
    }

    private static void finishPanel(@NonNull Messenger panel) {
        try {
            panel.send(Message.obtain(null, MSG_FINISH));
        } catch (android.os.RemoteException ignored) {
            // The panel process died first; nothing left to close.
        }
    }
}
