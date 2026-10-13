package app.fushi.reader;

import android.app.Activity;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.PixelCopy;
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewTreeObserver;
import android.view.Window;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
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
 *
 * <p>时序：Dart 侧藏掉悬浮球、等 Dart 帧提交完才发本调用。HC 下 Flutter 画面经
 * {@code FlutterImageView} 进窗口缓冲区，要等 Android 主线程真正画一次窗口才落进去；
 * Dart 的 {@code endOfFrame} 只说明 Dart 帧提交完。所以这里先让窗口重画一次
 * （{@link RedrawThenCapture}），这一帧交给 RenderThread 之后再发 PixelCopy。
 *
 * <p>内存：整窗 ARGB 位图（1440×3200 约 18MB）+ 每个 SurfaceView 一张 + 输出图一张，
 * 低端机上 {@link Bitmap#createBitmap} 可能抛 {@link OutOfMemoryError}（Error，不是
 * RuntimeException，通道外层接不住）。每一处分配都在本类里接住、回收已分配的位图并
 * 回 {@code CAPTURE_FAILED}，Dart 回退到 toImage。
 */
final class AppWindowSnapshot {
    private static final String TAG = "AppWindowSnapshot";
    private static final String CAPTURE_FAILED = "CAPTURE_FAILED";

    private AppWindowSnapshot() {}

    /**
     * 主线程调用；{@code result} 恰好回调一次。{@code maxSide} 为输出图长边上限
     * （像素），null / ≤0 表示不缩放。
     */
    static void capture(
            @NonNull Context context,
            @Nullable Integer maxSide,
            @NonNull MethodChannel.Result result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(null);
            return;
        }
        if (!(context instanceof Activity)) {
            result.error(CAPTURE_FAILED, "No activity window to capture", null);
            return;
        }
        Window window = ((Activity) context).getWindow();
        View decor = window == null ? null : window.peekDecorView();
        if (decor == null || decor.getWidth() <= 0 || decor.getHeight() <= 0) {
            result.error(CAPTURE_FAILED, "Window has no laid-out decor view", null);
            return;
        }
        if (!decor.isAttachedToWindow() || !decor.isShown()) {
            // 不可见的窗口不会重画，等下去 result 永远不回。
            result.error(CAPTURE_FAILED, "Window is not visible", null);
            return;
        }
        final int limit = maxSide == null ? 0 : maxSide;
        new RedrawThenCapture(decor, result, () -> startSession(window, decor, limit, result))
                .arm();
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private static void startSession(
            @NonNull Window window,
            @NonNull View decor,
            int maxSide,
            @NonNull MethodChannel.Result result) {
        if (decor.getWidth() <= 0 || decor.getHeight() <= 0) {
            result.error(CAPTURE_FAILED, "Window has no laid-out decor view", null);
            return;
        }
        final Session session;
        try {
            session = new Session(window, decor, maxSide, result);
        } catch (OutOfMemoryError e) {
            Log.w(TAG, "window bitmap allocation failed", e);
            result.error(CAPTURE_FAILED, "Out of memory allocating window bitmap", null);
            return;
        }
        session.start();
    }

    /**
     * 让窗口真正重画一次再截：{@code invalidate} 后在 {@link ViewTreeObserver.OnDrawListener}
     * 里登记，post 到本轮遍历结束（这一帧已交给 RenderThread）之后再回调
     * {@code onDrawn}；PixelCopy 的拷贝任务排在这一帧绘制之后。窗口在重画前被拆掉
     * （Activity 销毁）则回 {@code CAPTURE_FAILED}，保证 result 恰好回调一次。
     */
    private static final class RedrawThenCapture
            implements ViewTreeObserver.OnDrawListener, View.OnAttachStateChangeListener {
        private final View decor;
        private final MethodChannel.Result result;
        private final Runnable onDrawn;
        private final Handler main = new Handler(Looper.getMainLooper());
        private boolean done = false;

        RedrawThenCapture(
                @NonNull View decor,
                @NonNull MethodChannel.Result result,
                @NonNull Runnable onDrawn) {
            this.decor = decor;
            this.result = result;
            this.onDrawn = onDrawn;
        }

        void arm() {
            decor.addOnAttachStateChangeListener(this);
            decor.getViewTreeObserver().addOnDrawListener(this);
            decor.invalidate();
        }

        @Override
        public void onDraw() {
            if (done) return;
            done = true;
            // onDraw 里不能移除 OnDrawListener（会抛 IllegalStateException），且这时
            // 这一帧还没交给 RenderThread——统一 post 到遍历结束之后。
            main.post(() -> {
                disarm();
                onDrawn.run();
            });
        }

        @Override
        public void onViewAttachedToWindow(@NonNull View v) {}

        @Override
        public void onViewDetachedFromWindow(@NonNull View v) {
            if (done) return;
            done = true;
            disarm();
            result.error(CAPTURE_FAILED, "Window detached before redraw", null);
        }

        private void disarm() {
            decor.removeOnAttachStateChangeListener(this);
            ViewTreeObserver observer = decor.getViewTreeObserver();
            if (observer.isAlive()) observer.removeOnDrawListener(this);
        }
    }

    /**
     * 输出图尺寸：长边缩到 {@code maxSide} 以内、保持宽高比，只缩不放；
     * {@code maxSide ≤ 0} 原样返回。
     */
    @NonNull
    static int[] scaledSize(int width, int height, int maxSide) {
        int longest = Math.max(width, height);
        if (maxSide <= 0 || longest <= maxSide) return new int[] {width, height};
        double scale = (double) maxSide / longest;
        return new int[] {
            Math.max(1, (int) Math.round(width * scale)),
            Math.max(1, (int) Math.round(height * scale)),
        };
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private static final class Session {
        private final Window window;
        private final MethodChannel.Result result;
        private final int maxSide;
        private final Handler main = new Handler(Looper.getMainLooper());
        private final Bitmap windowBitmap;
        private final List<SurfaceView> surfaceViews = new ArrayList<>();
        private final List<Bitmap> surfaceBitmaps = new ArrayList<>();
        private final List<Rect> surfaceRects = new ArrayList<>();
        private boolean windowCopied = false;
        private int windowError = PixelCopy.SUCCESS;
        /** 某个 SurfaceView 的位图分配失败：整张作废（缺的那块可能就是 Flutter 本身）。 */
        @Nullable private String allocationError = null;
        private int pending;

        /** 整窗位图分配失败抛 {@link OutOfMemoryError}，此时本对象没有任何已分配位图。 */
        Session(
                @NonNull Window window,
                @NonNull View decor,
                int maxSide,
                @NonNull MethodChannel.Result result) {
            this.window = window;
            this.result = result;
            this.maxSide = maxSide;
            collectSurfaceViews(decor, surfaceViews);
            this.windowBitmap = Bitmap.createBitmap(
                    decor.getWidth(), decor.getHeight(), Bitmap.Config.ARGB_8888);
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
                result.error(CAPTURE_FAILED, "PixelCopy(window): " + e.getMessage(), null);
                return;
            }
            for (SurfaceView view : surfaceViews) {
                if (allocationError != null) {
                    // 已经注定失败，不再分配；计数照减，等在途拷贝回来后统一回收。
                    finishOne();
                    continue;
                }
                requestSurface(view);
            }
        }

        private void requestSurface(@NonNull SurfaceView view) {
            int[] loc = new int[2];
            view.getLocationInWindow(loc);
            final Bitmap bitmap;
            try {
                bitmap = Bitmap.createBitmap(
                        view.getWidth(), view.getHeight(), Bitmap.Config.ARGB_8888);
            } catch (OutOfMemoryError e) {
                Log.w(TAG, "SurfaceView bitmap allocation failed", e);
                allocationError = "Out of memory allocating SurfaceView bitmap";
                finishOne();
                return;
            }
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
            if (allocationError != null) {
                windowBitmap.recycle();
                recycleSurfaces();
                result.error(CAPTURE_FAILED, allocationError, null);
                return;
            }
            if (!windowCopied) {
                windowBitmap.recycle();
                recycleSurfaces();
                result.error(CAPTURE_FAILED, "PixelCopy(window) failed: " + windowError, null);
                return;
            }
            new Thread(this::composeAndEncode, "AppWindowSnapshot").start();
        }

        /** 合成时直接缩到 {@link #maxSide} 以内再编码，不把全分辨率 PNG 经通道传给 Dart。 */
        private void composeAndEncode() {
            byte[] png = null;
            String error = null;
            Bitmap out = null;
            try {
                int width = windowBitmap.getWidth();
                int height = windowBitmap.getHeight();
                int[] size = scaledSize(width, height, maxSide);
                out = Bitmap.createBitmap(size[0], size[1], Bitmap.Config.ARGB_8888);
                Canvas canvas = new Canvas(out);
                canvas.drawColor(Color.BLACK);
                canvas.scale((float) size[0] / width, (float) size[1] / height);
                Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG);
                for (int i = 0; i < surfaceBitmaps.size(); i++) {
                    canvas.drawBitmap(surfaceBitmaps.get(i), null, surfaceRects.get(i), paint);
                }
                canvas.drawBitmap(windowBitmap, 0f, 0f, paint);
                ByteArrayOutputStream stream = new ByteArrayOutputStream();
                // PNG 无损，quality 参数被忽略。
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
                    result.error(CAPTURE_FAILED, message, null);
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
