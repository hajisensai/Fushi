package app.fushi.reader;

import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;

import app.fushi.reader.constants.PreferenceKeys;

/**
 * 截屏识字的两个用户选项（Dart 偏好经 {@code setScreenOcrOptions} 下发、落在悬浮球的
 * SharedPreferences 里，原生在悬浮球服务 / 截屏服务里直接读，不必等 Dart 引擎）：
 *
 * <ul>
 *   <li>{@link #keepSession}：保持截屏会话（默认关）。第一次同意后 MediaProjection 与
 *       VirtualDisplay 常驻，之后截屏识字直接取帧，不再弹系统确认框、不再从后台起
 *       Activity（反馈 9bdhVTgq3A / LHyeNKyYjH）。</li>
 *   <li>{@link #cardImage}：截屏识字制卡带图（默认开，反馈 Gz7z6Y6Mbr）。开着时把定格帧
 *       写进 app 缓存，查词窗（{@code :popup} 进程）按路径读、裁成卡图；关着时不写。</li>
 * </ul>
 */
final class ScreenOcrOptions {
    private static final String TAG = "ScreenOcrOptions";
    private static final String PREF_KEEP_SESSION = "screen_ocr_keep_session";
    private static final String PREF_CARD_IMAGE = "screen_ocr_card_image";
    /** 定格帧所在的缓存子目录：每次截屏只留最新一张。 */
    private static final String CARD_DIR = "screen_ocr_card";
    private static final int CARD_JPEG_QUALITY = 92;

    private ScreenOcrOptions() {}

    private static SharedPreferences prefs(@NonNull Context context) {
        return context.getApplicationContext()
                .getSharedPreferences(PreferenceKeys.FILE_FLOATING_BALL, Context.MODE_PRIVATE);
    }

    static boolean keepSession(@NonNull Context context) {
        return prefs(context).getBoolean(PREF_KEEP_SESSION, false);
    }

    static boolean cardImage(@NonNull Context context) {
        return prefs(context).getBoolean(PREF_CARD_IMAGE, true);
    }

    /** Dart 下发。关掉「带图」时顺手清掉缓存里的定格帧；关掉「保持」时停掉常驻会话。 */
    static void save(@NonNull Context context, boolean keepSession, boolean cardImage) {
        prefs(context).edit()
                .putBoolean(PREF_KEEP_SESSION, keepSession)
                .putBoolean(PREF_CARD_IMAGE, cardImage)
                .apply();
        if (!cardImage) clearCardFrames(context);
        if (!keepSession) ScreenOcrService.stopKeptSession();
    }

    @NonNull
    private static File cardDir(@NonNull Context context) {
        return new File(context.getCacheDir(), CARD_DIR);
    }

    /** 本次定格帧的落盘位置（文件名带时间戳，查词窗读到的永远是它点字时那一张）。 */
    @NonNull
    static File newCardFrameFile(@NonNull Context context, long stamp) {
        return new File(cardDir(context), "frame-" + stamp + ".jpg");
    }

    /**
     * 后台线程：把定格帧写成 JPEG（先写临时名再改名，读的一方不会读到半个文件），并删掉
     * 目录里别的旧帧。失败只记日志——这次制卡不带图，查词照常。
     */
    static void writeCardFrame(@NonNull Bitmap frame, @NonNull File target) {
        File dir = target.getParentFile();
        if (dir == null) return;
        if (!dir.isDirectory() && !dir.mkdirs()) {
            Log.w(TAG, "card frame dir could not be created: " + dir);
            return;
        }
        File[] old = dir.listFiles();
        if (old != null) {
            for (File f : old) {
                if (!f.equals(target)) deleteQuietly(f);
            }
        }
        File tmp = new File(dir, target.getName() + ".part");
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            if (!frame.compress(Bitmap.CompressFormat.JPEG, CARD_JPEG_QUALITY, out)) {
                Log.w(TAG, "card frame encode failed");
                deleteQuietly(tmp);
                return;
            }
        } catch (IOException | RuntimeException e) {
            Log.w(TAG, "card frame write failed", e);
            deleteQuietly(tmp);
            return;
        }
        if (!tmp.renameTo(target)) {
            Log.w(TAG, "card frame rename failed");
            deleteQuietly(tmp);
        }
    }

    static void clearCardFrames(@NonNull Context context) {
        File[] files = cardDir(context).listFiles();
        if (files == null) return;
        for (File f : files) deleteQuietly(f);
    }

    private static void deleteQuietly(@Nullable File file) {
        if (file != null && file.exists() && !file.delete()) {
            Log.w(TAG, "could not delete " + file);
        }
    }
}
