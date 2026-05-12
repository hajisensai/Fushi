package app.hibiki.reader;

import android.app.Notification;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.PixelFormat;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;

import java.lang.ref.WeakReference;
import java.util.Map;

import io.flutter.FlutterInjector;
import io.flutter.embedding.android.FlutterTextureView;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.FlutterEngineGroup;
import io.flutter.embedding.engine.dart.DartExecutor;
import io.flutter.embedding.engine.loader.FlutterLoader;
import io.flutter.plugin.common.MethodChannel;

public class FloatingDictService extends BaseFloatingService {

    private static final String TAG = "FloatingDict";
    private static final int NOTIFICATION_ID = 9528;
    private static final int MIN_WIDTH_DP = 180;
    private static final int MIN_HEIGHT_DP = 200;
    private static final String OVERLAY_CHANNEL = "app.hibiki.reader/floating_overlay";

    private FlutterEngine overlayEngine;
    private FlutterTextureView flutterView;
    private MethodChannel overlayChannel;

    private String lastSelectedText = "";

    private static WeakReference<FloatingDictService> instanceRef;
    private static FlutterEngineGroup engineGroup;

    public static FloatingDictService getInstance() {
        return instanceRef != null ? instanceRef.get() : null;
    }

    public static void initEngineGroup(Context appContext) {
        if (engineGroup == null) {
            engineGroup = new FlutterEngineGroup(appContext);
        }
    }

    @Override
    public void onCreate() {
        instanceRef = new WeakReference<>(this);
        initEngineGroup(getApplicationContext());
        createOverlayEngine();
        super.onCreate();
        setupOverlayChannel();
    }

    @Override
    public void onDestroy() {
        instanceRef = null;
        if (overlayChannel != null) {
            overlayChannel.setMethodCallHandler(null);
            overlayChannel = null;
        }
        if (flutterView != null) {
            flutterView.detachFromRenderer();
            flutterView = null;
        }
        if (overlayEngine != null) {
            overlayEngine.destroy();
            overlayEngine = null;
        }
        super.onDestroy();
    }

    private void createOverlayEngine() {
        FlutterLoader loader = FlutterInjector.instance().flutterLoader();
        loader.startInitialization(getApplicationContext());
        loader.ensureInitializationComplete(getApplicationContext(), null);

        DartExecutor.DartEntrypoint entrypoint = new DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(), "floatingDictMain");

        overlayEngine = engineGroup.createAndRunEngine(
                getApplicationContext(), entrypoint);
        FloatingDictPluginRegistrant.registerWith(overlayEngine);
    }

    private void setupOverlayChannel() {
        overlayChannel = new MethodChannel(
                overlayEngine.getDartExecutor().getBinaryMessenger(),
                OVERLAY_CHANNEL);
        overlayChannel.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "drag": {
                    Map<?, ?> args = (Map<?, ?>) call.arguments;
                    double dx = ((Number) args.get("dx")).doubleValue();
                    double dy = ((Number) args.get("dy")).doubleValue();
                    layoutParams.x += (int) dx;
                    layoutParams.y += (int) dy;
                    windowManager.updateViewLayout(rootView, layoutParams);
                    result.success(null);
                    break;
                }
                case "resize": {
                    Map<?, ?> args = (Map<?, ?>) call.arguments;
                    double dw = ((Number) args.get("dw")).doubleValue();
                    double dh = ((Number) args.get("dh")).doubleValue();
                    DisplayMetrics dm = getResources().getDisplayMetrics();
                    int newW = Math.max(dpToPx(MIN_WIDTH_DP),
                            Math.min(layoutParams.width + (int) dw, dm.widthPixels));
                    int newH = Math.max(dpToPx(MIN_HEIGHT_DP),
                            Math.min(layoutParams.height + (int) dh, dm.heightPixels));
                    updateLayoutSize(newW, newH);
                    result.success(null);
                    break;
                }
                case "close": {
                    stopSelf();
                    result.success(null);
                    break;
                }
                case "dragEnd": {
                    savePosition();
                    result.success(null);
                    break;
                }
                case "setFocusable": {
                    boolean focusable = (boolean) call.arguments;
                    setFocusable(focusable);
                    result.success(null);
                    break;
                }
                default:
                    result.notImplemented();
            }
        });
    }

    @Override
    protected String getPreferencePrefix() { return "floating_dict_prefs"; }

    @Override
    protected String getNotificationChannelId() { return "hibiki_floating_dict"; }

    @Override
    protected String getNotificationChannelName() { return "Floating Dictionary"; }

    @Override
    protected int getNotificationId() { return NOTIFICATION_ID; }

    @Override
    protected Notification buildNotification() {
        Intent closeIntent = new Intent(this, FloatingDictService.class);
        closeIntent.putExtra("action", "close");
        PendingIntent closePending = PendingIntent.getService(this, 1,
                closeIntent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder = new Notification.Builder(this, getNotificationChannelId());
        } else {
            builder = new Notification.Builder(this);
        }

        return builder
                .setContentTitle("Hibiki Dictionary")
                .setContentText("Select text in any app to look up")
                .setSmallIcon(R.drawable.ic_stat_hibiki)
                .setOngoing(true)
                .addAction(new Notification.Action.Builder(
                        null, "Close", closePending).build())
                .build();
    }

    @Override
    protected WindowManager.LayoutParams createLayoutParams() {
        SharedPreferences prefs = getSharedPreferences(getPreferencePrefix(), MODE_PRIVATE);
        int w = prefs.getInt("sizeW", dpToPx(300));
        int h = prefs.getInt("sizeH", dpToPx(400));
        w = Math.max(dpToPx(MIN_WIDTH_DP), w);
        h = Math.max(dpToPx(MIN_HEIGHT_DP), h);
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                w, h,
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                        ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                        : WindowManager.LayoutParams.TYPE_PHONE,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        lp.gravity = Gravity.TOP | Gravity.START;
        return lp;
    }

    private void setFocusable(boolean focusable) {
        if (layoutParams == null) return;
        if (focusable) {
            layoutParams.flags &= ~WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE;
        } else {
            layoutParams.flags |= WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE;
        }
        windowManager.updateViewLayout(rootView, layoutParams);
    }

    @Override
    protected View createContentView() {
        flutterView = new FlutterTextureView(this);
        flutterView.setOpaque(false);
        flutterView.attachToRenderer(overlayEngine.getRenderer());

        FrameLayout wrapper = new FrameLayout(this);
        wrapper.addView(flutterView, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));

        return wrapper;
    }

    @Override
    protected void savePosition() {
        if (layoutParams == null) return;
        getSharedPreferences(getPreferencePrefix(), MODE_PRIVATE)
                .edit()
                .putInt("posX", layoutParams.x)
                .putInt("posY", layoutParams.y)
                .putInt("sizeW", layoutParams.width)
                .putInt("sizeH", layoutParams.height)
                .apply();
    }

    @Override
    protected void setupDragListener() {
        // Drag handled by Flutter side via MethodChannel — no Java touch listener needed
    }

    @Override
    protected void onServiceCommand(Intent intent) {
        String action = intent.getStringExtra("action");
        if ("close".equals(action)) {
            stopSelf();
        }
    }

    public void onTextSelected(String text) {
        if (text == null || text.trim().isEmpty()) return;
        String trimmed = text.trim();
        if (trimmed.equals(lastSelectedText)) return;
        lastSelectedText = trimmed;
        Log.d(TAG, "onTextSelected: " + trimmed);
        new Handler(Looper.getMainLooper()).post(() -> {
            if (overlayChannel != null) {
                overlayChannel.invokeMethod("searchTerm", trimmed);
            }
        });
    }
}
