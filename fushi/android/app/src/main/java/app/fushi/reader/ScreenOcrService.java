package app.fushi.reader;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ServiceInfo;
import android.content.res.Configuration;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.RectF;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.Looper;
import android.os.RemoteException;
import android.os.SystemClock;
import android.text.TextPaint;
import android.util.DisplayMetrics;
import android.util.Log;
import android.util.TypedValue;
import android.view.Display;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;

import com.google.mlkit.common.MlKitException;
import com.google.mlkit.vision.common.InputImage;
import com.google.mlkit.vision.text.Text;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;

import app.fushi.reader.constants.NotificationIds;

/**
 * 截屏 OCR：拿用户同意后的 MediaProjection 截**一帧**整屏 → ML Kit 识别 → 全屏透明
 * 选取层框出文字行 → 点字 → {@link PopupDictFlutterActivity}（锚点 = 被点字符的框，
 * 避让区 = 整行框，均为屏幕物理像素）。
 *
 * <p>类型是 mediaProjection 前台服务：Android 14 起 {@code getMediaProjection} 必须在
 * 这种前台服务里、且在 {@code startForeground(..., MEDIA_PROJECTION)} 之后调用。截到帧
 * 就立刻 stop 投屏并退出前台状态——之后只剩选取层，不再持有任何录屏能力。
 *
 * <p><b>取哪一帧</b>：确认框消失、透明请求页 finish 的退场动画都要几帧才画完，第一帧常
 * 带着它们的残影。所以不取第一帧、也不固定 sleep，而是等画面<em>静止</em>：VirtualDisplay
 * 只在合成结果变化时才出新帧，于是「最近一帧之后 {@link #SETTLE_MS} 内没有新帧」就等价
 * 于「退场动画已结束」，取那一帧。一直在动的画面（视频）没有静止的时候，
 * {@link #MAX_WAIT_MS} 封顶后取当时最新一帧；封顶时一帧都没有就按失败处理。
 *
 * <p><b>选取层可重复用（BUG-2901）</b>：点字拉起查词窗后选取层只是<em>隐藏</em>，不拆。
 * 查词窗与选取层之间是一次「会话」（会话号见 {@link ScreenOcrSelectionSession}），查词窗经定向广播回报：
 * 显示出来了（{@link #ACTION_LOOKUP_SHOWN}，此时才隐藏选取层——拉起失败时选取层留着，
 * 不会藏起来再也回不来）、被关掉了（{@link #ACTION_LOOKUP_CLOSED}，恢复选取层，同一张
 * 截图接着点）、用户离开了（{@link #ACTION_LOOKUP_LEFT}，整条流程收尾）。选取层画的是
 * 定格的那一帧，所以恢复时框与画面始终对齐，与底下的 app 此刻在播什么无关。
 * 会话的取舍全在纯状态机 {@link ScreenOcrSelectionSession} 里（JVM 单测钉住），本服务只接线。
 *
 * <p><b>选取层随屏幕几何失效</b>：截屏时记下屏幕物理尺寸 + display rotation 作这张截图的
 * 身份；之后屏幕转了 / 尺寸变了（{@link #onConfigurationChanged}，或查词窗关掉、恢复选取层
 * 之前核对）就收尾，不把竖屏几何的旧定格帧盖到横屏上，也不尝试映射旧框。
 *
 * <p>整条流程的「进行中」锁与悬浮球的隐藏由 {@link ScreenCaptureRequestActivity} 持有，
 * 本服务在任何出口（选取层关闭 / 失败 / 被系统停掉）都经 {@link #finishFlow} 收尾。
 */
public class ScreenOcrService extends Service {
    private static final String TAG = "ScreenOcrService";

    static final String EXTRA_RESULT_CODE = "resultCode";
    static final String EXTRA_RESULT_DATA = "resultData";
    static final String EXTRA_LANGUAGE = "language";
    static final String EXTRA_LABELS = "labels";

    // labels 可选键（Dart 侧 i18n 下发；缺省回退英文）。
    static final String LABEL_HINT = "ocr_hint";
    static final String LABEL_NO_TEXT = "ocr_no_text";
    static final String LABEL_MODEL_UNAVAILABLE = "ocr_model_unavailable";
    static final String LABEL_FAILED = "ocr_failed";
    static final String LABEL_NOTIFICATION = "ocr_notification";

    // 查词窗（:popup 进程）→ 本服务的会话回报，经 setPackage 定向、接收端不导出。
    static final String ACTION_LOOKUP_SHOWN = "app.fushi.reader.SCREEN_OCR_LOOKUP_SHOWN";
    static final String ACTION_LOOKUP_CLOSED = "app.fushi.reader.SCREEN_OCR_LOOKUP_CLOSED";
    static final String ACTION_LOOKUP_LEFT = "app.fushi.reader.SCREEN_OCR_LOOKUP_LEFT";
    static final String EXTRA_SESSION = "screenOcrSession";
    /** SHOWN 回报带上查词窗的 Binder 令牌：:popup 进程死了也能收到通知（linkToDeath）。 */
    static final String EXTRA_LOOKUP_TOKEN = "screenOcrLookupToken";

    /** 画面静止判据：最后一帧之后这么久没有新帧，就认为退场动画已画完。 */
    private static final long SETTLE_MS = 250;
    /** 等帧封顶：持续变化的画面取此刻最新一帧；此刻仍无帧则判失败。 */
    private static final long MAX_WAIT_MS = 1500;
    /** 点在行框外这么多 dp 以内仍算点到该行（手指比字框粗）。 */
    private static final int LINE_SLOP_DP = 12;

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private HandlerThread captureThread;
    private Handler captureHandler;

    private MediaProjection projection;
    private VirtualDisplay virtualDisplay;
    private ImageReader imageReader;
    /** 最近一帧（只在 captureThread 上读写）。 */
    private Image latestImage;
    private boolean captureDone = false;

    private int screenWidth;
    private int screenHeight;
    private int screenDensityDpi;

    private String language = "ja";
    private Map<String, String> labels = Collections.emptyMap();

    private WindowManager windowManager;
    private SelectionView selectionView;
    private WindowManager.LayoutParams selectionParams;
    /** 识别用的那一帧，选取层拿它当背景；流程收尾时回收。 */
    private Bitmap frozenFrame;
    private boolean receiverRegistered = false;
    private boolean finished = false;
    /** 隐藏选取层时盯住的查词窗令牌；它所在进程一死就收尾（否则选取层永远藏着、悬浮球回不来）。 */
    @Nullable private IBinder lookupToken;
    @Nullable private IBinder.DeathRecipient lookupDeath;

    /** 会话协议的全部决定（隐藏 / 恢复 / 收尾 / 失效）；本服务只把副作用接到 Android 上。 */
    private final ScreenOcrSelectionSession<IBinder> session =
            new ScreenOcrSelectionSession<>(new ScreenOcrSelectionSession.Effects<IBinder>() {
                @Override
                public boolean watchLookupToken(@NonNull IBinder token) {
                    return ScreenOcrService.this.watchLookupToken(token);
                }

                @Override
                public void unwatchLookupToken() {
                    ScreenOcrService.this.unwatchLookupToken();
                }

                @Override
                public void setSelectionHidden(boolean hidden) {
                    ScreenOcrService.this.setSelectionHidden(hidden);
                }

                @Override
                public void finishFlow() {
                    ScreenOcrService.this.finishFlow();
                }
            });

    private final BroadcastReceiver lookupReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            ScreenOcrLookupEvent event = lookupEventOf(intent.getAction());
            if (event == null) return;
            Bundle extras = intent.getExtras();
            IBinder token = extras == null ? null : extras.getBinder(EXTRA_LOOKUP_TOKEN);
            session.onLookupEvent(event, intent.getLongExtra(EXTRA_SESSION, 0), token,
                    currentScreenIdentity());
        }
    };

    @Nullable
    private static ScreenOcrLookupEvent lookupEventOf(@Nullable String action) {
        if (ACTION_LOOKUP_SHOWN.equals(action)) return ScreenOcrLookupEvent.SHOWN;
        if (ACTION_LOOKUP_CLOSED.equals(action)) return ScreenOcrLookupEvent.CLOSED;
        if (ACTION_LOOKUP_LEFT.equals(action)) return ScreenOcrLookupEvent.LEFT;
        return null;
    }

    private final Runnable settleTimeout = this::finishCapture;
    private final Runnable maxWaitTimeout = this::finishCapture;

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        windowManager = (WindowManager) getSystemService(Context.WINDOW_SERVICE);
        createNotificationChannel();
        IntentFilter filter = new IntentFilter();
        filter.addAction(ACTION_LOOKUP_SHOWN);
        filter.addAction(ACTION_LOOKUP_CLOSED);
        filter.addAction(ACTION_LOOKUP_LEFT);
        // 不导出：只收本 app（同 UID，含 :popup 进程）发来的回报。
        ContextCompat.registerReceiver(this, lookupReceiver, filter,
                ContextCompat.RECEIVER_NOT_EXPORTED);
        receiverRegistered = true;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (projection != null || intent == null) {
            // 已有一次截屏在进行（流程锁本应挡住），或系统重投空 intent：不接新活。
            if (projection == null && selectionView == null) finishFlow();
            return START_NOT_STICKY;
        }
        String lang = intent.getStringExtra(EXTRA_LANGUAGE);
        if (lang != null && !lang.isEmpty()) language = lang;
        labels = ScreenCaptureRequestActivity.fromBundle(intent.getBundleExtra(EXTRA_LABELS));

        // Android 14+：必须先以 mediaProjection 类型进入前台，再 getMediaProjection。
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NotificationIds.SCREEN_OCR, buildNotification(),
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
            } else {
                startForeground(NotificationIds.SCREEN_OCR, buildNotification());
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "startForeground(mediaProjection) failed", e);
            finishFlow();
            return START_NOT_STICKY;
        }

        int resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0);
        Intent data = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                ? intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent.class)
                : intent.getParcelableExtra(EXTRA_RESULT_DATA);
        MediaProjectionManager mpm = getSystemService(MediaProjectionManager.class);
        try {
            projection = (mpm == null || data == null)
                    ? null
                    : mpm.getMediaProjection(resultCode, data);
        } catch (RuntimeException e) {
            Log.w(TAG, "getMediaProjection failed", e);
            projection = null;
        }
        if (projection == null) {
            toast(label(LABEL_FAILED, "Screen capture failed"));
            finishFlow();
            return START_NOT_STICKY;
        }
        startCapture();
        return START_NOT_STICKY;
    }

    @Override
    public void onConfigurationChanged(@NonNull Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        // 选取层（含隐藏中的）画的是截屏那一刻的几何：屏幕转了 / 尺寸变了就收尾。
        session.onConfigurationChanged(currentScreenIdentity());
    }

    @Override
    public void onDestroy() {
        if (receiverRegistered) {
            unregisterReceiver(lookupReceiver);
            receiverRegistered = false;
        }
        unwatchLookupToken();
        releaseCapture();
        removeSelectionView();
        releaseFrame();
        if (captureThread != null) {
            captureThread.quitSafely();
            captureThread = null;
        }
        if (!finished) {
            finished = true;
            ScreenCaptureRequestActivity.onFlowFinished();
        }
        super.onDestroy();
    }

    // ── 截屏 ──────────────────────────────────────────────────────────────────

    private void startCapture() {
        Rect bounds = realScreenBounds();
        screenWidth = bounds.width();
        screenHeight = bounds.height();
        screenDensityDpi = getResources().getDisplayMetrics().densityDpi;
        // 这张截图的屏幕身份：虚拟屏按此尺寸建，定格帧与行框都按它算。
        session.onCaptureStarted(new ScreenOcrSelectionSession.ScreenIdentity(
                screenWidth, screenHeight, displayRotation()));

        captureThread = new HandlerThread("fushi-screen-ocr");
        captureThread.start();
        captureHandler = new Handler(captureThread.getLooper());

        // Android 14+ 规定 createVirtualDisplay 之前必须先注册回调。
        projection.registerCallback(new MediaProjection.Callback() {
            @Override
            public void onStop() {
                // 用户从系统面板停止共享 / 系统收回授权：还没截到就当失败收尾。
                captureHandler.post(() -> {
                    if (!captureDone) {
                        captureDone = true;
                        closeLatestImage();
                        mainHandler.post(() -> {
                            releaseCapture();
                            finishFlow();
                        });
                    }
                });
            }
        }, captureHandler);

        // maxImages = 3：手里压着 latestImage 时 acquireLatestImage 仍有余量。
        imageReader = ImageReader.newInstance(
                screenWidth, screenHeight, PixelFormat.RGBA_8888, 3);
        imageReader.setOnImageAvailableListener(reader -> {
            if (captureDone) return;
            Image next;
            try {
                closeLatestImage();
                next = reader.acquireLatestImage();
            } catch (RuntimeException e) {
                Log.w(TAG, "acquireLatestImage failed", e);
                return;
            }
            if (next == null) return;
            latestImage = next;
            captureHandler.removeCallbacks(settleTimeout);
            captureHandler.postDelayed(settleTimeout, SETTLE_MS);
        }, captureHandler);

        try {
            virtualDisplay = projection.createVirtualDisplay(
                    "fushi-screen-ocr",
                    screenWidth, screenHeight, screenDensityDpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                    imageReader.getSurface(), null, captureHandler);
        } catch (RuntimeException e) {
            Log.w(TAG, "createVirtualDisplay failed", e);
            toast(label(LABEL_FAILED, "Screen capture failed"));
            releaseCapture();
            finishFlow();
            return;
        }
        captureHandler.postDelayed(maxWaitTimeout, MAX_WAIT_MS);
    }

    /** captureThread 上执行：定格最新一帧，立刻停投屏，转交主线程识别。 */
    private void finishCapture() {
        if (captureDone) return;
        captureDone = true;
        captureHandler.removeCallbacks(settleTimeout);
        captureHandler.removeCallbacks(maxWaitTimeout);
        Bitmap bitmap = null;
        if (latestImage != null) {
            try {
                bitmap = imageToBitmap(latestImage);
            } catch (RuntimeException e) {
                Log.w(TAG, "frame conversion failed", e);
            }
        }
        closeLatestImage();
        final Bitmap frame = bitmap;
        mainHandler.post(() -> {
            releaseCapture();
            // 画面已定格：Dart 可以立刻放回自己的 Flutter 球（识别与选取层不再截屏）。
            FloatingBallChannel.notifyScreenOcrFinished();
            if (frame == null) {
                toast(label(LABEL_FAILED, "Screen capture failed"));
                finishFlow();
                return;
            }
            recognize(frame);
        });
    }

    private Bitmap imageToBitmap(@NonNull Image image) {
        Image.Plane plane = image.getPlanes()[0];
        ByteBuffer buffer = plane.getBuffer();
        int pixelStride = plane.getPixelStride();
        int rowStride = plane.getRowStride();
        int width = image.getWidth();
        int height = image.getHeight();
        int rowPaddingPx = (rowStride - pixelStride * width) / pixelStride;
        Bitmap padded = Bitmap.createBitmap(
                width + rowPaddingPx, height, Bitmap.Config.ARGB_8888);
        padded.copyPixelsFromBuffer(buffer);
        if (rowPaddingPx == 0) return padded;
        Bitmap cropped = Bitmap.createBitmap(padded, 0, 0, width, height);
        padded.recycle();
        return cropped;
    }

    private void closeLatestImage() {
        if (latestImage != null) {
            latestImage.close();
            latestImage = null;
        }
    }

    /** 主线程：停掉投屏相关的一切，并退出前台（之后只剩选取层，不再持有录屏能力）。 */
    private void releaseCapture() {
        if (virtualDisplay != null) {
            virtualDisplay.release();
            virtualDisplay = null;
        }
        if (projection != null) {
            try {
                projection.stop();
            } catch (RuntimeException e) {
                Log.w(TAG, "projection.stop failed", e);
            }
            projection = null;
        }
        if (imageReader != null) {
            // 在 captureThread 上关：监听回调也跑在那条线程，避免关到一半还有回调进来。
            final ImageReader reader = imageReader;
            imageReader = null;
            if (captureHandler != null) {
                captureHandler.post(reader::close);
            } else {
                reader.close();
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE);
        } else {
            stopForeground(true);
        }
    }

    // ── 识别 ──────────────────────────────────────────────────────────────────

    private void recognize(@NonNull Bitmap bitmap) {
        SystemOcrChannel.recognizerFor(language)
                .process(InputImage.fromBitmap(bitmap, 0))
                .addOnSuccessListener(text -> {
                    // 识别期间流程已被收尾（系统重投空 intent 等）：不能再挂一个没人管的选取层。
                    if (finished) {
                        bitmap.recycle();
                        return;
                    }
                    List<ScreenOcrLayout.Line> lines = toLines(text);
                    if (lines.isEmpty()) {
                        bitmap.recycle();
                        toast(label(LABEL_NO_TEXT, "No text recognized"));
                        finishFlow();
                        return;
                    }
                    // 框是在这一帧上识别出来的：选取层就画这一帧，框与画面恒对齐。
                    frozenFrame = bitmap;
                    showSelection(lines);
                })
                .addOnFailureListener(error -> {
                    bitmap.recycle();
                    if (finished) return;
                    // 与 SystemOcrChannel 同口径：模型没就绪 ≠ 识别失败，提示要分开。
                    boolean unavailable = error instanceof MlKitException
                            && ((MlKitException) error).getErrorCode()
                            == MlKitException.UNAVAILABLE;
                    Log.w(TAG, "text recognition failed", error);
                    toast(unavailable
                            ? label(LABEL_MODEL_UNAVAILABLE,
                                    "Text recognition model is not ready yet")
                            : label(LABEL_FAILED, "Text recognition failed"));
                    finishFlow();
                    if (unavailable) {
                        // 只提示「没就绪」是死胡同：用户不知道该去哪配。拉起 Fushi，
                        // 由 Dart 弹出系统 OCR 模型配置（查状态 / 立即下载）（BUG-2906）。
                        FloatingBallChannel.requestSystemOcrSetup();
                        BackgroundActivityLauncher.bringAppToFront(this);
                    }
                });
    }

    private static List<ScreenOcrLayout.Line> toLines(@NonNull Text text) {
        List<ScreenOcrLayout.Line> out = new ArrayList<>();
        for (Text.TextBlock block : text.getTextBlocks()) {
            for (Text.Line line : block.getLines()) {
                Rect box = line.getBoundingBox();
                String value = line.getText();
                if (box == null || box.width() <= 0 || box.height() <= 0) continue;
                if (value == null || value.trim().isEmpty()) continue;
                List<String> symbolTexts = new ArrayList<>();
                List<int[]> symbolBoxes = new ArrayList<>();
                for (Text.Element element : line.getElements()) {
                    for (Text.Symbol symbol : element.getSymbols()) {
                        Rect sb = symbol.getBoundingBox();
                        if (sb == null) continue;
                        symbolTexts.add(symbol.getText());
                        symbolBoxes.add(new int[] {sb.left, sb.top, sb.right, sb.bottom});
                    }
                }
                List<ScreenOcrLayout.Glyph> glyphs =
                        ScreenOcrLayout.glyphsFromSymbols(value, symbolTexts, symbolBoxes);
                boolean vertical = ScreenOcrLayout.isVertical(
                        box.left, box.top, box.right, box.bottom, glyphs);
                if (glyphs.isEmpty()) {
                    glyphs = ScreenOcrLayout.proportionalGlyphs(
                            value, box.left, box.top, box.right, box.bottom, vertical);
                }
                out.add(new ScreenOcrLayout.Line(
                        value, box.left, box.top, box.right, box.bottom, glyphs, vertical));
            }
        }
        return out;
    }

    // ── 选取层 ────────────────────────────────────────────────────────────────

    private void showSelection(@NonNull List<ScreenOcrLayout.Line> lines) {
        selectionView = new SelectionView(this, lines, frozenFrame, label(LABEL_HINT,
                "Tap text to look it up · tap elsewhere to close"));
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                        ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                        : WindowManager.LayoutParams.TYPE_PHONE,
                // 不带 FLAG_NOT_FOCUSABLE：要收返回键关闭选取层。
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        lp.gravity = Gravity.TOP | Gravity.START;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            lp.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // 盖住状态栏 / 导航栏区域：截图是整屏，框也要能画到那里。
            lp.setFitInsetsTypes(0);
            lp.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS;
        }
        selectionParams = lp;
        try {
            windowManager.addView(selectionView, lp);
        } catch (RuntimeException e) {
            Log.w(TAG, "selection overlay could not be added", e);
            selectionView = null;
            selectionParams = null;
            toast(label(LABEL_FAILED, "Screen capture failed"));
            finishFlow();
            return;
        }
        selectionView.setFocusableInTouchMode(true);
        selectionView.requestFocus();
    }

    private void onSelectionTap(int rawX, int rawY) {
        if (selectionView == null) return;
        List<ScreenOcrLayout.Line> lines = selectionView.lines;
        int slop = dpToPx(LINE_SLOP_DP);
        int index = ScreenOcrLayout.hitLine(lines, rawX, rawY, slop);
        if (index < 0) {
            finishFlow();
            return;
        }
        ScreenOcrLayout.Line line = lines.get(index);
        ScreenOcrLayout.Glyph glyph = ScreenOcrLayout.glyphAt(line, rawX, rawY);

        Intent intent = new Intent(this, PopupDictFlutterActivity.class);
        intent.putExtra(Intent.EXTRA_PROCESS_TEXT, line.text);
        intent.putExtra(PopupDictFlutterActivity.EXTRA_CHAR_INDEX,
                glyph != null ? glyph.start : -1);
        if (glyph != null) {
            intent.putExtra(PopupDictFlutterActivity.EXTRA_ANCHOR_LEFT, glyph.left);
            intent.putExtra(PopupDictFlutterActivity.EXTRA_ANCHOR_TOP, glyph.top);
            intent.putExtra(PopupDictFlutterActivity.EXTRA_ANCHOR_RIGHT, glyph.right);
            intent.putExtra(PopupDictFlutterActivity.EXTRA_ANCHOR_BOTTOM, glyph.bottom);
        }
        intent.putExtra(PopupDictFlutterActivity.EXTRA_SUBTITLE_LEFT, line.left);
        intent.putExtra(PopupDictFlutterActivity.EXTRA_SUBTITLE_TOP, line.top);
        intent.putExtra(PopupDictFlutterActivity.EXTRA_SUBTITLE_RIGHT, line.right);
        intent.putExtra(PopupDictFlutterActivity.EXTRA_SUBTITLE_BOTTOM, line.bottom);
        // BUG-2901：选取层不再随点字拆掉。它是 TYPE_APPLICATION_OVERLAY、压在一切 Activity
        // 之上，查词窗显示出来后（ACTION_LOOKUP_SHOWN）才隐藏它；查词窗关掉再恢复。启动
        // 那一刻选取层仍可见，Android 15 的后台启动豁免（要求有可见悬浮窗）照样成立。
        session.onLookupLaunched(SystemClock.elapsedRealtimeNanos());
        intent.putExtra(PopupDictFlutterActivity.EXTRA_SCREEN_OCR_SESSION,
                session.getSessionId());
        BackgroundActivityLauncher.start(this, intent);
    }

    /**
     * 查词窗在前时隐藏选取层：不画、不吃触摸、不抢焦点（返回键归查词窗）。恢复时
     * 重新拿焦点，返回键仍能关闭选取层。
     */
    private void setSelectionHidden(boolean hidden) {
        if (selectionView == null || selectionParams == null) return;
        int passThrough = WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                | WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE;
        selectionParams.flags = hidden
                ? selectionParams.flags | passThrough
                : selectionParams.flags & ~passThrough;
        selectionView.clearPressed();
        selectionView.setVisibility(hidden ? View.GONE : View.VISIBLE);
        try {
            windowManager.updateViewLayout(selectionView, selectionParams);
        } catch (RuntimeException e) {
            Log.w(TAG, "selection overlay update failed", e);
            finishFlow();
            return;
        }
        if (!hidden) selectionView.requestFocus();
    }

    /** 盯住查词窗进程；令牌已死（进程刚没了）返回 false。主线程。 */
    private boolean watchLookupToken(@NonNull IBinder token) {
        if (token == lookupToken) return true;
        unwatchLookupToken();
        IBinder.DeathRecipient recipient = () -> mainHandler.post(() -> {
            if (lookupToken != token) return;
            lookupToken = null;
            lookupDeath = null;
            Log.w(TAG, "lookup popup process died; finishing screen OCR flow");
            session.onLookupProcessDied();
        });
        try {
            token.linkToDeath(recipient, 0);
        } catch (RemoteException e) {
            return false;
        }
        lookupToken = token;
        lookupDeath = recipient;
        return true;
    }

    private void unwatchLookupToken() {
        if (lookupToken != null && lookupDeath != null) {
            lookupToken.unlinkToDeath(lookupDeath, 0);
        }
        lookupToken = null;
        lookupDeath = null;
    }

    private void removeSelectionView() {
        if (selectionView != null) {
            try {
                windowManager.removeView(selectionView);
            } catch (RuntimeException e) {
                Log.w(TAG, "selection overlay removal failed", e);
            }
            selectionView = null;
        }
        selectionParams = null;
    }

    private void releaseFrame() {
        if (frozenFrame != null) {
            frozenFrame.recycle();
            frozenFrame = null;
        }
    }

    /** 任何出口都走这里：拆选取层、解流程锁、放回悬浮球、停服务。主线程。 */
    private void finishFlow() {
        session.reset();
        unwatchLookupToken();
        removeSelectionView();
        releaseFrame();
        if (!finished) {
            finished = true;
            ScreenCaptureRequestActivity.onFlowFinished();
        }
        stopSelf();
    }

    /**
     * 全屏选取层：铺定格帧，每一行只给一层淡底色标出「这里能点」；手指按下的那一行
     * 才加深并描边（BUG-2901：此前每行都画实线框、整屏再压暗，满屏蓝框盖住要读的字）。
     * 坐标一律用屏幕物理像素（与截图 1:1）；画的时候减去本窗口在屏幕上的原点，点的
     * 时候直接用 getRawX/Y，两边都不依赖窗口是否真的铺到了 (0,0)。
     */
    private final class SelectionView extends View {
        final List<ScreenOcrLayout.Line> lines;
        private final String hint;
        @Nullable private final Bitmap frame;
        private final Paint framePaint = new Paint(Paint.FILTER_BITMAP_FLAG);
        private final Paint restPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint pressedFillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint strokePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final TextPaint hintPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
        private final Paint hintBgPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final int[] origin = new int[2];
        private final RectF scratch = new RectF();
        private final int touchSlop;
        private float downX;
        private float downY;
        private boolean tapCandidate;
        /** 手指按着的那一行；-1 = 没按在任何一行上。 */
        private int pressedLine = -1;

        SelectionView(Context context, List<ScreenOcrLayout.Line> lines,
                @Nullable Bitmap frame, String hint) {
            super(context);
            this.lines = lines;
            this.frame = frame;
            this.hint = hint;
            restPaint.setColor(0x1A3D8BFF);
            pressedFillPaint.setColor(0x403D8BFF);
            strokePaint.setColor(0xFF3D8BFF);
            strokePaint.setStyle(Paint.Style.STROKE);
            strokePaint.setStrokeWidth(dpToPx(2));
            hintPaint.setColor(Color.WHITE);
            hintPaint.setTextSize(TypedValue.applyDimension(
                    TypedValue.COMPLEX_UNIT_SP, 14, getResources().getDisplayMetrics()));
            hintBgPaint.setColor(0xCC202124);
            touchSlop = ViewConfiguration.get(context).getScaledTouchSlop();
        }

        @Override
        protected void onDraw(@NonNull Canvas canvas) {
            super.onDraw(canvas);
            getLocationOnScreen(origin);
            if (frame != null && !frame.isRecycled()) {
                canvas.drawBitmap(frame, -origin[0], -origin[1], framePaint);
            }
            float radius = dpToPx(4);
            float pad = dpToPx(2);
            for (int i = 0; i < lines.size(); i++) {
                ScreenOcrLayout.Line line = lines.get(i);
                scratch.set(line.left - origin[0] - pad, line.top - origin[1] - pad,
                        line.right - origin[0] + pad, line.bottom - origin[1] + pad);
                if (i == pressedLine) {
                    canvas.drawRoundRect(scratch, radius, radius, pressedFillPaint);
                    canvas.drawRoundRect(scratch, radius, radius, strokePaint);
                } else {
                    canvas.drawRoundRect(scratch, radius, radius, restPaint);
                }
            }
            if (hint != null && !hint.isEmpty()) {
                float textWidth = hintPaint.measureText(hint);
                float padH = dpToPx(12);
                float padV = dpToPx(8);
                float top = topInset() + dpToPx(8);
                float height = hintPaint.descent() - hintPaint.ascent() + padV * 2;
                float left = (getWidth() - textWidth) / 2f - padH;
                scratch.set(left, top, left + textWidth + padH * 2, top + height);
                canvas.drawRoundRect(scratch, height / 2f, height / 2f, hintBgPaint);
                canvas.drawText(hint, left + padH, top + padV - hintPaint.ascent(), hintPaint);
            }
        }

        private float topInset() {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                WindowInsets insets = getRootWindowInsets();
                if (insets != null) {
                    return insets.getInsets(WindowInsets.Type.statusBars()).top;
                }
            }
            return dpToPx(24);
        }

        @Override
        public boolean onTouchEvent(MotionEvent event) {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    downX = event.getRawX();
                    downY = event.getRawY();
                    tapCandidate = true;
                    setPressedLine(ScreenOcrLayout.hitLine(lines,
                            (int) downX, (int) downY, dpToPx(LINE_SLOP_DP)));
                    return true;
                case MotionEvent.ACTION_MOVE:
                    if (Math.abs(event.getRawX() - downX) > touchSlop
                            || Math.abs(event.getRawY() - downY) > touchSlop) {
                        tapCandidate = false;
                        clearPressed();
                    }
                    return true;
                case MotionEvent.ACTION_UP:
                    clearPressed();
                    if (tapCandidate) {
                        onSelectionTap((int) event.getRawX(), (int) event.getRawY());
                    }
                    return true;
                case MotionEvent.ACTION_CANCEL:
                    tapCandidate = false;
                    clearPressed();
                    return true;
                default:
                    return true;
            }
        }

        void clearPressed() {
            setPressedLine(-1);
        }

        private void setPressedLine(int index) {
            if (pressedLine == index) return;
            pressedLine = index;
            invalidate();
        }

        @Override
        public boolean dispatchKeyEvent(KeyEvent event) {
            if (event.getKeyCode() == KeyEvent.KEYCODE_BACK) {
                if (event.getAction() == KeyEvent.ACTION_UP) finishFlow();
                return true;
            }
            return super.dispatchKeyEvent(event);
        }
    }

    // ── 杂项 ──────────────────────────────────────────────────────────────────

    private Rect realScreenBounds() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return new Rect(windowManager.getMaximumWindowMetrics().getBounds());
        }
        DisplayMetrics dm = new DisplayMetrics();
        windowManager.getDefaultDisplay().getRealMetrics(dm);
        return new Rect(0, 0, dm.widthPixels, dm.heightPixels);
    }

    /** 此刻的屏幕身份：与截屏时同一口径（物理像素尺寸 + 默认屏 rotation）。 */
    @NonNull
    private ScreenOcrSelectionSession.ScreenIdentity currentScreenIdentity() {
        Rect bounds = realScreenBounds();
        return new ScreenOcrSelectionSession.ScreenIdentity(
                bounds.width(), bounds.height(), displayRotation());
    }

    /**
     * 默认屏的 rotation。Service 不是视觉 Context，R+ 上 {@code getDisplay()} 会抛，
     * 走 DisplayManager 取。0 与 180 尺寸相同但定格帧是倒的，所以 rotation 必须进身份。
     */
    private int displayRotation() {
        DisplayManager dm = getSystemService(DisplayManager.class);
        Display display = dm == null ? null : dm.getDisplay(Display.DEFAULT_DISPLAY);
        return display == null ? Surface.ROTATION_0 : display.getRotation();
    }

    private String label(String key, String fallback) {
        String value = labels.get(key);
        return value == null || value.isEmpty() ? fallback : value;
    }

    private void toast(String message) {
        mainHandler.post(() ->
                Toast.makeText(getApplicationContext(), message, Toast.LENGTH_SHORT).show());
    }

    private int dpToPx(int dp) {
        return (int) (dp * getResources().getDisplayMetrics().density);
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    NotificationIds.CHANNEL_SCREEN_OCR,
                    "Screen OCR",
                    NotificationManager.IMPORTANCE_LOW);
            channel.setShowBadge(false);
            NotificationManager nm = getSystemService(NotificationManager.class);
            if (nm != null) nm.createNotificationChannel(channel);
        }
    }

    private Notification buildNotification() {
        Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, NotificationIds.CHANNEL_SCREEN_OCR)
                : new Notification.Builder(this);
        return builder
                .setContentTitle(label(LABEL_NOTIFICATION, "Reading text on screen…"))
                .setSmallIcon(R.drawable.ic_stat_fushi)
                .setOngoing(true)
                .build();
    }
}
