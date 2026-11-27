package app.fushi.reader;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Message;
import android.os.Messenger;
import android.os.RemoteException;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.Map;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/**
 * {@code app.fushi.reader/srs_write_relay}：辅助引擎（{@code :popup} 查词窗 / {@code :second_screen}
 * 面板）把复习写入交给主进程（BUG-5542）。Dart 调 {@code forward}（参数是请求 JSON 串），回包 JSON 串；
 * 没执行成（主进程起不来 / 中途死掉 / 超时）回 error。
 *
 * <p>本进程就是主进程时直接交给 {@link SrsWriteRelay}；否则绑定 {@link SrsWriteRelayService}
 * （{@code BIND_AUTO_CREATE}：主进程不在时把它拉起来），经 {@link Messenger} 收发。绑定在空闲
 * {@link #IDLE_UNBIND_MS} 后解开，不让一个缓存着的查词窗进程一直吊着主进程。
 *
 * <p>全部状态只在主线程上读写。
 */
final class SrsWriteRelayClient {
    private static final String TAG = "SrsWriteRelayClient";
    static final String CHANNEL = "app.fushi.reader/srs_write_relay";
    /** 比主进程那端（{@link SrsWriteRelay} 150 秒）长一点：正常情况下总是那端先给出结论。 */
    private static final long REQUEST_TIMEOUT_MS = 170_000L;
    private static final long IDLE_UNBIND_MS = 60_000L;

    private SrsWriteRelayClient() {}

    static void registerWith(@NonNull FlutterEngine engine, @NonNull Context context) {
        final Context app = context.getApplicationContext();
        final boolean inMainProcess =
                JavaCrashCapture.currentProcessName(app).equals(app.getPackageName());
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), CHANNEL)
                .setMethodCallHandler((call, result) -> {
                    if (!"forward".equals(call.method)) {
                        result.notImplemented();
                        return;
                    }
                    final Object args = call.arguments;
                    if (!(args instanceof String)) {
                        result.error("bad_request", "request must be a JSON string", null);
                        return;
                    }
                    final SrsWriteRelay.Reply reply = (String json, String error) -> {
                        if (json != null) {
                            result.success(json);
                        } else {
                            result.error("relay_failed",
                                    error != null ? error : "no reply from the main app", null);
                        }
                    };
                    if (inMainProcess) {
                        SrsWriteRelay.submit(app, (String) args, reply);
                    } else {
                        Connection.get(app).send((String) args, reply);
                    }
                });
    }

    /** 辅助进程到 {@link SrsWriteRelayService} 的一条绑定。 */
    private static final class Connection implements ServiceConnection {
        @Nullable private static Connection instance;

        static Connection get(@NonNull Context app) {
            if (instance == null) instance = new Connection(app);
            return instance;
        }

        private static final class Request {
            final String json;
            final SrsWriteRelay.Reply reply;
            boolean sent;
            Runnable timeout;

            Request(String json, SrsWriteRelay.Reply reply) {
                this.json = json;
                this.reply = reply;
            }
        }

        private final Context app;
        private final Handler main = new Handler(Looper.getMainLooper());
        private final Messenger incoming = new Messenger(new Handler(Looper.getMainLooper(), this::onReply));
        private final Map<Integer, Request> pending = new LinkedHashMap<>();
        @Nullable private Messenger service;
        private boolean bound;
        private int nextId = 1;
        private final Runnable idleUnbind = this::unbindIfIdle;

        private Connection(Context app) {
            this.app = app;
        }

        void send(@NonNull String json, @NonNull SrsWriteRelay.Reply reply) {
            main.removeCallbacks(idleUnbind);
            final int id = nextId++;
            final Request r = new Request(json, reply);
            r.timeout = () -> complete(id, null, "timed out waiting for the main app");
            main.postDelayed(r.timeout, REQUEST_TIMEOUT_MS);
            pending.put(id, r);
            if (service != null) {
                deliver(id, r);
            } else {
                ensureBound();
            }
        }

        private void ensureBound() {
            if (bound) return;
            final Intent intent = new Intent(app, SrsWriteRelayService.class);
            try {
                bound = app.bindService(intent, this,
                        Context.BIND_AUTO_CREATE | Context.BIND_IMPORTANT);
            } catch (SecurityException e) {
                Log.e(TAG, "bind failed", e);
                bound = false;
            }
            if (!bound) {
                failAll("could not reach the main app");
            }
        }

        private void deliver(int id, @NonNull Request r) {
            final Messenger s = service;
            if (s == null) return;
            final Message m = Message.obtain(null, SrsWriteRelayService.MSG_REQUEST, id, 0);
            final Bundle data = new Bundle();
            data.putString(SrsWriteRelayService.KEY_JSON, r.json);
            m.setData(data);
            m.replyTo = incoming;
            try {
                s.send(m);
                r.sent = true;
            } catch (RemoteException e) {
                complete(id, null, "the main app stopped: " + e);
            }
        }

        private boolean onReply(@NonNull Message message) {
            if (message.what != SrsWriteRelayService.MSG_REPLY) return false;
            final Bundle data = message.getData();
            complete(message.arg1, data.getString(SrsWriteRelayService.KEY_JSON),
                    data.getString(SrsWriteRelayService.KEY_ERROR));
            return true;
        }

        private void complete(int id, @Nullable String json, @Nullable String error) {
            final Request r = pending.remove(id);
            if (r == null) return;
            main.removeCallbacks(r.timeout);
            r.reply.done(json, json == null && error == null ? "no reply from the main app" : error);
            if (pending.isEmpty()) main.postDelayed(idleUnbind, IDLE_UNBIND_MS);
        }

        private void failAll(@NonNull String error) {
            for (Integer id : new ArrayList<>(pending.keySet())) complete(id, null, error);
        }

        private void unbindIfIdle() {
            if (!pending.isEmpty() || !bound) return;
            bound = false;
            service = null;
            try {
                app.unbindService(this);
            } catch (IllegalArgumentException ignored) {
                // 已经解开。
            }
        }

        @Override
        public void onServiceConnected(ComponentName name, IBinder binder) {
            service = new Messenger(binder);
            for (Map.Entry<Integer, Request> e : new ArrayList<>(pending.entrySet())) {
                if (!e.getValue().sent) deliver(e.getKey(), e.getValue());
            }
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            // 主进程死了：已经送过去的请求不会再有回包（写没写成不确定）；没送出去的等系统重连后再送。
            service = null;
            for (Map.Entry<Integer, Request> e : new ArrayList<>(pending.entrySet())) {
                if (e.getValue().sent) {
                    complete(e.getKey(), null,
                            "the main app stopped while saving; check whether the card was added");
                }
            }
        }

        @Override
        public void onBindingDied(ComponentName name) {
            // 这条绑定作废了（例如 app 被更新）：解开，剩下的请求重新绑定后再送。
            service = null;
            if (bound) {
                bound = false;
                try {
                    app.unbindService(this);
                } catch (IllegalArgumentException ignored) {
                    // 已经解开。
                }
            }
            for (Map.Entry<Integer, Request> e : new ArrayList<>(pending.entrySet())) {
                if (e.getValue().sent) {
                    complete(e.getKey(), null,
                            "the main app stopped while saving; check whether the card was added");
                }
            }
            if (!pending.isEmpty()) ensureBound();
        }
    }
}
