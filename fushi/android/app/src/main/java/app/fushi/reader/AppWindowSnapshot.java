package app.fushi.reader;

import android.app.Activity;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Rect;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.PixelCopy;
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;

import androidx.annotation.NonNull;
import androidx.annotation.RequiresApi;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.List;

import io.flutter.plugin.common.MethodChannel;

/**
 * 截本 App 自己的 Activity 窗口为 PNG（{@code floating_ball.captureScreen}，Dart 侧
 * 反馈截图 {@code captureFeedbackScreenshot} 用）。
 *
 * <p>为什么不用 Flutter 的 {@code RenderRepaintBoundary.toImage}：阅读器 / 查词卡的
 * WebView 走 Hybrid Composition，是真 Android View，不在 Flutter 场景里，toImage 截出来
 * 那一块是空白。这里用 {@link PixelCopy}（API 26+）直接拷合成用的缓冲区：
 * <ul>
 *   <li>窗口自己的 surface：所有普通 View（含 WebView、HC 下 Flutter 的
 *       {@code FlutterImageView} 叠层）都画在这里；</li>
 *   <li>窗口里每个可见的 {@link SurfaceView}（没有平台视图时 Flutter 自己就画在
 *       {@code FlutterSurfaceView} 上）各有独立 surface，不在窗口缓冲区里——窗口在它
 *       的位置挖了一个透明洞（有 SurfaceView 时 ViewRootImpl 会把窗口格式提到带
 *       alpha）。所以先把 SurfaceView 的内容按位置铺在底下，再把窗口缓冲区按 alpha
 *       叠在上面，得到的就是屏幕上看到的样子。</li>
 * </ul>
 * 只拷本窗口的缓冲区，拿不到其它 App、状态栏或系统界面的像素。API 24/25 没有
 * PixelCopy 窗口拷贝，返回 {@code null}，Dart 回退到 toImage。
 */
final class AppWindowSnapshot {
    private static final String TAG = "AppWindowSnapshot";

    private AppWindowSnapshot() {}

    /** 主线程调用；{@code result} 恰好回调一次。 */
    static void capture(@NonNull Context context, @NonNull MethodChannel.Result result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(null);
            return;
        }
        if (!(context instanceof Activity)) {
            result.error("CAPTURE_FAILED", "No activity window to capture", null);
            return;
        }
        Window window = ((Activity) context).getWindow();
        View decor = window == null ? null : window.peekDecorView();
        if (decor == null || decor.getWidth() <= 0 || decor.getHeight() <= 0) {
            result.error("CAPTURE_FAILED", "Window has no laid-out decor view", null);
            return;
        }
        new Session(window, decor, result).start();
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private static final class Session {
        private final Window window;
        private final MethodChannel.Result result;
        private final Handler main = new Handler(Looper.getMainLooper());
        private final Bitmap windowBitmap;
        private final List<SurfaceView> surfaceViews = new ArrayList<>();
        private final List<Bitmap> surfaceBitmaps = new ArrayList<>();
        private final List<Rect> surfaceRects = new ArrayList<>();
        private boolean windowCopied = false;
        private int windowError = PixelCopy.SUCCESS;
        private int pending;

        Session(@NonNull Window window, @NonNull View decor, @NonNull MethodChannel.Result result) {
            this.window = window;
            this.result = result;
            this.windowBitmap = Bitmap.createBitmap(
                    decor.getWidth(), decor.getHeight(), Bitmap.Config.ARGB_8888);
            collectSurfaceViews(decor, surfaceViews);
        }

        void start() {
            pending = 1 + surfaceViews.size();
            try {
                PixelCopy.request(window, windowBitmap, code -> {
                    windowCopied = code == PixelCopy.SUCCESS;
                    windowError = code;
                    finishOne();
                }, main);
            } catch (RuntimeException e) {
                Log.w(TAG, "window PixelCopy request failed", e);
                windowBitmap.recycle();
                result.error("CAPTURE_FAILED", "PixelCopy(window): " + e.getMessage(), null);
                return;
            }
            for (SurfaceView view : surfaceViews) {
                requestSurface(view);
            }
        }

        private void requestSurface(@NonNull SurfaceView view) {
            int[] loc = new int[2];
            view.getLocationInWindow(loc);
            Bitmap bitmap = Bitmap.createBitmap(
                    view.getWidth(), view.getHeight(), Bitmap.Config.ARGB_8888);
            Rect rect = new Rect(loc[0], loc[1], loc[0] + view.getWidth(), loc[1] + view.getHeight());
            try {
                PixelCopy.request(view, bitmap, code -> {
                    if (code == PixelCopy.SUCCESS) {
                        surfaceBitmaps.add(bitmap);
                        surfaceRects.add(rect);
                    } else {
                        // 这块 surface 还没出过帧 / 已暂停：窗口缓冲区里它那块透明，
                        // 合成出来就是底色，不影响其它部分。
                        Log.w(TAG, "SurfaceView PixelCopy failed: " + code);
                        bitmap.recycle();
                    }
                    finishOne();
                }, main);
            } catch (RuntimeException e) {
                Log.w(TAG, "SurfaceView PixelCopy request failed", e);
                bitmap.recycle();
                finishOne();
            }
        }

        /** 主线程；全部拷贝回来后在后台线程合成 + 编码。 */
        private void finishOne() {
            if (--pending > 0) return;
            if (!windowCopied) {
                windowBitmap.recycle();
                recycleSurfaces();
                result.error("CAPTURE_FAILED", "PixelCopy(window) failed: " + windowError, null);
                return;
            }
            new Thread(this::composeAndEncode, "AppWindowSnapshot").start();
        }

        private void composeAndEncode() {
            byte[] png = null;
            String error = null;
            Bitmap out = null;
            try {
                out = Bitmap.createBitmap(
                        windowBitmap.getWidth(), windowBitmap.getHeight(), Bitmap.Config.ARGB_8888);
                Canvas canvas = new Canvas(out);
                canvas.drawColor(Color.BLACK);
                for (int i = 0; i < surfaceBitmaps.size(); i++) {
                    canvas.drawBitmap(surfaceBitmaps.get(i), null, surfaceRects.get(i), null);
                }
                canvas.drawBitmap(windowBitmap, 0f, 0f, null);
                ByteArrayOutputStream stream = new ByteArrayOutputStream();
                if (out.compress(Bitmap.CompressFormat.PNG, 100, stream)) {
                    png = stream.toByteArray();
                } else {
                    error = "PNG encode failed";
                }
            } catch (RuntimeException | OutOfMemoryError e) {
                Log.w(TAG, "compose failed", e);
                error = e.toString();
            } finally {
                if (out != null) out.recycle();
                windowBitmap.recycle();
                recycleSurfaces();
            }
            final byte[] bytes = png;
            final String message = error;
            main.post(() -> {
                if (bytes != null) {
                    result.success(bytes);
                } else {
                    result.error("CAPTURE_FAILED", message, null);
                }
            });
        }

        private void recycleSurfaces() {
            for (Bitmap b : surfaceBitmaps) b.recycle();
            surfaceBitmaps.clear();
            surfaceRects.clear();
        }
    }

    /** 收集当前可见、已有有效 surface 的 SurfaceView（按视图树先序，即自下而上）。 */
    private static void collectSurfaceViews(@NonNull View view, @NonNull List<SurfaceView> out) {
        if (!view.isShown() || view.getWidth() <= 0 || view.getHeight() <= 0) return;
        if (view instanceof SurfaceView) {
            SurfaceView surface = (SurfaceView) view;
            if (surface.getHolder().getSurface().isValid()) out.add(surface);
            return;
        }
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) {
                collectSurfaceViews(group.getChildAt(i), out);
            }
        }
    }
}
