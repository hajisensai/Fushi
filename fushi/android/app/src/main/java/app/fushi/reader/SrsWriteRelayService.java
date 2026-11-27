package app.fushi.reader;

import android.app.Service;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.Message;
import android.os.Messenger;
import android.os.RemoteException;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

/**
 * 复习写入转交的主进程入口（BUG-5542）：{@code :popup} 查词窗 / {@code :second_screen} 面板的
 * {@link SrsWriteRelayClient} 绑定本服务（主进程不在时绑定会把它拉起来），经 {@link Messenger} 发请求。
 * 不导出，只收同 uid 的调用。
 *
 * <p>辅助进程 → 主进程：{@link #MSG_REQUEST}（arg1 = 请求号，data[{@link #KEY_JSON}] = 请求，
 * replyTo = 辅助进程的 messenger）。主进程 → 辅助进程：{@link #MSG_REPLY}（arg1 = 同一个请求号，
 * data[{@link #KEY_JSON}] = 回包，或 data[{@link #KEY_ERROR}] = 没执行成的原因）。
 *
 * <p>请求只带文件路径与少量元数据：截图 / 音频这类媒体由辅助进程写进 app 的 cache 目录（Binder 一次事务装不下）。
 */
public class SrsWriteRelayService extends Service {
    static final int MSG_REQUEST = 1;
    static final int MSG_REPLY = 2;
    static final String KEY_JSON = "json";
    static final String KEY_ERROR = "error";

    private final Messenger messenger =
            new Messenger(new Handler(Looper.getMainLooper(), this::handle));

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return messenger.getBinder();
    }

    private boolean handle(@NonNull Message message) {
        if (message.what != MSG_REQUEST) return false;
        final Messenger client = message.replyTo;
        final int id = message.arg1;
        final String json = message.getData().getString(KEY_JSON);
        if (client == null) return true;
        if (json == null) {
            reply(client, id, null, "empty request");
            return true;
        }
        SrsWriteRelay.submit(getApplicationContext(), json,
                (String out, String error) -> reply(client, id, out, error));
        return true;
    }

    private static void reply(@NonNull Messenger client, int id, @Nullable String json,
            @Nullable String error) {
        final Message m = Message.obtain(null, MSG_REPLY, id, 0);
        final Bundle data = new Bundle();
        if (json != null) data.putString(KEY_JSON, json);
        if (error != null) data.putString(KEY_ERROR, error);
        m.setData(data);
        try {
            client.send(m);
        } catch (RemoteException ignored) {
            // 辅助进程先没了：没有人等这个结果。
        }
    }
}
