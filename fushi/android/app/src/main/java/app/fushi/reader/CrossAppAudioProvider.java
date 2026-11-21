package app.fushi.reader;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.Arrays;
import java.util.Comparator;

/**
 * 跨应用语音缓存（拍板 oqk37s3QFL）的跨进程入口。采集服务与环形缓冲在主进程，查词窗
 * 在 {@code :popup} 进程；这个不导出的 provider 跑在主进程，用 {@link #call} 当同 uid
 * 的同步 RPC：
 *
 * <ul>
 *   <li>{@code status} → {@code {running}}；</li>
 *   <li>{@code snapshot}（arg = backMs）→ 把环里最近一段 PCM 落到 app 缓存目录，返回
 *       {@code {path, sampleRate, channels, bitsPerSample}}；没在录返回 null；</li>
 *   <li>{@code stop} → 停止采集。</li>
 * </ul>
 *
 * 文件只保留最近 {@link #KEEP_SNAPSHOTS} 份（每次查词一份，制卡时读）。
 */
public class CrossAppAudioProvider extends ContentProvider {
    private static final String TAG = "CrossAppAudioProvider";
    static final String AUTHORITY_SUFFIX = ".cross_app_audio";
    static final String METHOD_STATUS = "status";
    static final String METHOD_SNAPSHOT = "snapshot";
    static final String METHOD_STOP = "stop";
    private static final String DIR = "cross_app_audio";
    private static final int KEEP_SNAPSHOTS = 4;

    static Uri uri(@NonNull Context context) {
        return Uri.parse("content://" + context.getPackageName() + AUTHORITY_SUFFIX);
    }

    /**
     * 「正在录」标记文件：服务录起来时建、停下时删。查词窗进程先看它再发 RPC——主进程
     * 没在跑时 provider 调用会把整个主进程拉起来，只为回一句「没在录」。主进程被杀留下的
     * 陈旧标记由下一次 [#METHOD_SNAPSHOT] 清掉。
     */
    static File capturingMarker(@NonNull Context context) {
        return new File(new File(context.getCacheDir(), DIR), "capturing");
    }

    static void setCapturingMarker(@NonNull Context context, boolean capturing) {
        File marker = capturingMarker(context);
        if (capturing) {
            File dir = marker.getParentFile();
            try {
                if (dir != null && (dir.isDirectory() || dir.mkdirs())) {
                    //noinspection ResultOfMethodCallIgnored
                    marker.createNewFile();
                }
            } catch (IOException e) {
                Log.w(TAG, "capturing marker could not be created", e);
            }
        } else {
            //noinspection ResultOfMethodCallIgnored
            marker.delete();
        }
    }

    @Override
    public boolean onCreate() {
        return true;
    }

    @Nullable
    @Override
    public Bundle call(@NonNull String method, @Nullable String arg, @Nullable Bundle extras) {
        Context context = getContext();
        if (context == null) return null;
        switch (method) {
            case METHOD_STATUS: {
                Bundle out = new Bundle();
                out.putBoolean("running", CrossAppAudioService.isRunning());
                return out;
            }
            case METHOD_STOP:
                CrossAppAudioService.requestStop();
                return Bundle.EMPTY;
            case METHOD_SNAPSHOT:
                return snapshot(context, parseBackMs(arg));
            default:
                return null;
        }
    }

    private static int parseBackMs(@Nullable String arg) {
        if (arg == null) return 0;
        try {
            return Integer.parseInt(arg);
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    /**
     * 快照落盘与停止时的清扫互斥：「确认还在录 → 取环 → 写文件」整段持锁，
     * [#deleteSnapshots] 也持同一把锁，并且服务先把「在录」置假再清扫——所以一次快照要么
     * 在清扫前写完（被扫掉），要么在清扫后看到「没在录」而不写，停止后不会再冒出新文件。
     */
    private static final Object SNAPSHOT_LOCK = new Object();

    @Nullable
    private static Bundle snapshot(@NonNull Context context, int backMs) {
        File out;
        synchronized (SNAPSHOT_LOCK) {
            if (!CrossAppAudioService.isRunning()) {
                // 主进程被杀后重启：服务早没了，标记是陈旧的。
                setCapturingMarker(context, false);
                return null;
            }
            byte[] pcm = CrossAppAudioService.snapshot(backMs);
            if (pcm == null || pcm.length == 0) return null;
            File dir = new File(context.getCacheDir(), DIR);
            if (!dir.isDirectory() && !dir.mkdirs()) return null;
            prune(dir);
            out = new File(dir, "lookup_" + System.currentTimeMillis() + ".pcm");
            try (FileOutputStream stream = new FileOutputStream(out)) {
                stream.write(pcm);
            } catch (IOException e) {
                Log.w(TAG, "snapshot write failed", e);
                //noinspection ResultOfMethodCallIgnored
                out.delete();
                return null;
            }
        }
        Bundle result = new Bundle();
        result.putString("path", out.getAbsolutePath());
        result.putInt("sampleRate", CrossAppAudioService.SAMPLE_RATE);
        result.putInt("channels", CrossAppAudioService.CHANNELS);
        result.putInt("bitsPerSample", CrossAppAudioService.BITS_PER_SAMPLE);
        return result;
    }

    /**
     * 停止采集时调（调用前服务必须已把「在录」置假）：其他 app 的录音不在用户关掉开关后
     * 继续留在缓存里。目录里的东西全删（含写到一半的文件与标记），不按扩展名挑。
     */
    static void deleteSnapshots(@NonNull Context context) {
        synchronized (SNAPSHOT_LOCK) {
            File[] files = new File(context.getCacheDir(), DIR).listFiles();
            if (files == null) return;
            for (File f : files) {
                //noinspection ResultOfMethodCallIgnored
                f.delete();
            }
        }
    }

    /** 只留最新的 KEEP_SNAPSHOTS - 1 份，给这次腾位置。 */
    private static void prune(@NonNull File dir) {
        File[] files = dir.listFiles((File f) -> f.getName().endsWith(".pcm"));
        if (files == null || files.length < KEEP_SNAPSHOTS) return;
        Arrays.sort(files, Comparator.comparingLong(File::lastModified));
        for (int i = 0; i <= files.length - KEEP_SNAPSHOTS; i++) {
            //noinspection ResultOfMethodCallIgnored
            files[i].delete();
        }
    }

    @Nullable
    @Override
    public Cursor query(@NonNull Uri uri, @Nullable String[] projection, @Nullable String selection,
            @Nullable String[] selectionArgs, @Nullable String sortOrder) {
        return null;
    }

    @Nullable
    @Override
    public String getType(@NonNull Uri uri) {
        return null;
    }

    @Nullable
    @Override
    public Uri insert(@NonNull Uri uri, @Nullable ContentValues values) {
        return null;
    }

    @Override
    public int delete(@NonNull Uri uri, @Nullable String selection,
            @Nullable String[] selectionArgs) {
        return 0;
    }

    @Override
    public int update(@NonNull Uri uri, @Nullable ContentValues values, @Nullable String selection,
            @Nullable String[] selectionArgs) {
        return 0;
    }
}
