package app.fushi.reader;

import android.app.Activity;
import android.nfc.FormatException;
import android.nfc.NdefMessage;
import android.nfc.NdefRecord;
import android.nfc.NfcAdapter;
import android.nfc.Tag;
import android.nfc.tech.Ndef;
import android.nfc.tech.NdefFormatable;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.io.IOException;

import app.fushi.reader.constants.ChannelNames;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/**
 * 把互联配对链接（{@code fushi://pair?…}，**不含**一次性票据）写进 NFC 贴纸。
 *
 * <p>Dart 侧门面在 {@code lib/src/sync/sync_settings_schema/interconnect_link.part.dart}
 * （{@code writeInterconnectPairNfcTag}），方法名 / 参数名是跨语言契约。设计见
 * {@code docs/specs/2026-09-28-interconnect-remote-reach.md} §4。
 *
 * <p>读贴纸不经这里：manifest 里 {@code NDEF_DISCOVERED} + {@code fushi://pair} 的
 * intent-filter 让系统直接把链接交给 MainActivity，走与 VIEW 深链同一条路。
 *
 * <p>三条实现约束：
 * <ol>
 *   <li>用 {@code enableReaderMode} 而不是前台分发：读卡回调在 binder 线程，结果必须
 *       post 回主线程再回给 Dart。</li>
 *   <li>一次只允许一个待决写入；新请求到来时先把旧的按失败收尾，免得 Dart 侧的
 *       Future 永远不完成。超时同理（30 秒），不让读卡模式一直开着。</li>
 *   <li>{@code disableReaderMode} 在 Activity 不在前台时会抛 IllegalStateException；
 *       收尾时吞掉它是安全的——系统在 Activity 暂停时本就会撤掉读卡模式。</li>
 * </ol>
 */
public final class NfcTagWriterChannelHandler {
    private static final String METHOD_WRITE_URI = "writeUri";
    private static final String ARG_URI = "uri";
    private static final long TIMEOUT_MS = 30_000L;
    private static final int READER_FLAGS = NfcAdapter.FLAG_READER_NFC_A
            | NfcAdapter.FLAG_READER_NFC_B
            | NfcAdapter.FLAG_READER_NFC_F
            | NfcAdapter.FLAG_READER_NFC_V;

    @NonNull
    private final Activity activity;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    @Nullable
    private MethodChannel channel;
    @Nullable
    private MethodChannel.Result pending;
    @Nullable
    private Runnable timeout;
    /** 每次写入请求一个代际：旧请求的读卡回调 post 回来时不许完成新请求。 */
    private int generation;

    public NfcTagWriterChannelHandler(@NonNull Activity activity) {
        this.activity = activity;
    }

    public void register(@NonNull FlutterEngine engine) {
        final MethodChannel created = new MethodChannel(
                engine.getDartExecutor().getBinaryMessenger(),
                ChannelNames.NFC_TAG_WRITER);
        created.setMethodCallHandler((call, result) -> {
            if (METHOD_WRITE_URI.equals(call.method)) {
                final String uri = call.argument(ARG_URI);
                start(uri, result);
                return;
            }
            result.notImplemented();
        });
        channel = created;
    }

    /** MainActivity 的 onDestroy 调用：收尾待决写入并断开 channel。 */
    public void destroy() {
        finish(false);
        if (channel != null) {
            channel.setMethodCallHandler(null);
            channel = null;
        }
    }

    private void start(@Nullable String uri, @NonNull MethodChannel.Result result) {
        final NfcAdapter adapter = NfcAdapter.getDefaultAdapter(activity);
        if (uri == null || uri.isEmpty() || adapter == null || !adapter.isEnabled()) {
            result.success(false);
            return;
        }
        finish(false); // 旧的待决写入按失败收尾（见类注释第 2 条）。
        pending = result;
        final int mine = ++generation;
        final Runnable onTimeout = () -> finishIfCurrent(mine, false);
        timeout = onTimeout;
        mainHandler.postDelayed(onTimeout, TIMEOUT_MS);
        try {
            adapter.enableReaderMode(
                    activity,
                    (Tag tag) -> {
                        final boolean ok = write(tag, uri);
                        mainHandler.post(() -> finishIfCurrent(mine, ok));
                    },
                    READER_FLAGS,
                    null);
        } catch (IllegalStateException e) {
            // Activity 不在前台：直接按失败收尾，超时回调随之撤销，不会二次回复。
            finish(false);
        }
    }

    /** 只有仍是第 [mine] 次请求时才收尾；旧请求的回调 / 超时落空。 */
    private void finishIfCurrent(int mine, boolean ok) {
        if (mine == generation) {
            finish(ok);
        }
    }

    private static boolean write(@NonNull Tag tag, @NonNull String uri) {
        final NdefMessage message = new NdefMessage(NdefRecord.createUri(uri));
        final Ndef ndef = Ndef.get(tag);
        if (ndef != null) {
            try {
                ndef.connect();
                if (!ndef.isWritable() || ndef.getMaxSize() < message.getByteArrayLength()) {
                    return false;
                }
                ndef.writeNdefMessage(message);
                return true;
            } catch (IOException | FormatException | SecurityException e) {
                return false;
            } finally {
                closeQuietly(ndef);
            }
        }
        final NdefFormatable formatable = NdefFormatable.get(tag);
        if (formatable != null) {
            try {
                formatable.connect();
                formatable.format(message);
                return true;
            } catch (IOException | FormatException | SecurityException e) {
                return false;
            } finally {
                closeQuietly(formatable);
            }
        }
        return false;
    }

    private void finish(boolean ok) {
        if (timeout != null) {
            mainHandler.removeCallbacks(timeout);
            timeout = null;
        }
        final MethodChannel.Result result = pending;
        pending = null;
        if (result == null) {
            return;
        }
        final NfcAdapter adapter = NfcAdapter.getDefaultAdapter(activity);
        if (adapter != null) {
            try {
                adapter.disableReaderMode(activity);
            } catch (IllegalStateException ignored) {
                // Activity 已不在前台：系统暂停时本就撤掉了读卡模式（类注释第 3 条）。
            }
        }
        result.success(ok);
    }

    private static void closeQuietly(@NonNull android.nfc.tech.TagTechnology tech) {
        try {
            tech.close();
        } catch (IOException ignored) {
            // 关闭失败不影响已经得出的写入结果。
        }
    }
}
