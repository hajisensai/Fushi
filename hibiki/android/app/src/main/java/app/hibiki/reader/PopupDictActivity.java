package app.hibiki.reader;

import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.WindowManager;
import android.webkit.WebView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import io.flutter.FlutterInjector;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.android.FlutterActivityLaunchConfigs;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.FlutterEngineCache;
import io.flutter.embedding.engine.dart.DartExecutor;
import io.flutter.embedding.engine.loader.FlutterLoader;
import io.flutter.plugin.common.MethodChannel;

public class PopupDictActivity extends FlutterActivity {
    private static final String ENGINE_ID = "popup_dict_engine";
    private static final String POPUP_CHANNEL = "app.hibiki.reader/popup";
    private static boolean webViewDataDirectoryConfigured = false;
    private static boolean dartStarted = false;

    private MethodChannel popupChannel;
    private AnkiChannelHandler ankiChannelHandler;
    private TtsChannelHandler ttsChannelHandler;
    private FlutterEngine configuredFlutterEngine;
    private String pendingProcessText;
    private int pendingCharIndex = -1;

    @Nullable
    @Override
    public String getCachedEngineId() {
        return null;
    }

    @Nullable
    @Override
    public FlutterEngine provideFlutterEngine(@NonNull Context context) {
        return ensureCachedEngine(context);
    }

    @Override
    public boolean shouldDestroyEngineWithHost() {
        return false;
    }

    @NonNull
    @Override
    public String getDartEntrypointFunctionName() {
        return "popupMain";
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        configureWebViewDataDirectory();
        pendingProcessText = extractProcessText(getIntent());
        pendingCharIndex = getIntent().getIntExtra("charIndex", -1);
        FlutterEngine flutterEngine = ensureCachedEngine(this);

        ankiChannelHandler = new AnkiChannelHandler(this);
        ttsChannelHandler = new TtsChannelHandler(this);

        boolean engineWasRunning =
                dartStarted || flutterEngine.getDartExecutor().isExecutingDart();
        configurePopupEngine(flutterEngine);
        startPopupDartIfNeeded(flutterEngine);
        if (engineWasRunning && pendingProcessText != null) {
            dispatchProcessTextToDart(pendingProcessText, pendingCharIndex);
        }

        super.onCreate(savedInstanceState);

        applyPopupWindowSize();
    }

    @Override
    protected void onNewIntent(@NonNull Intent intent) {
        super.onNewIntent(intent);
        String text = extractProcessText(intent);
        int charIdx = intent.getIntExtra("charIndex", -1);
        if (text != null) {
            pendingProcessText = text;
            pendingCharIndex = charIdx;
            dispatchProcessTextToDart(text, charIdx);
        }
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        configurePopupEngine(flutterEngine);
        startPopupDartIfNeeded(flutterEngine);
    }

    private void configurePopupEngine(@NonNull FlutterEngine flutterEngine) {
        if (configuredFlutterEngine == flutterEngine) return;

        if (ankiChannelHandler == null) {
            ankiChannelHandler = new AnkiChannelHandler(this);
        }
        if (ttsChannelHandler == null) {
            ttsChannelHandler = new TtsChannelHandler(this);
        }

        ankiChannelHandler.register(flutterEngine);
        ttsChannelHandler.register(flutterEngine);

        popupChannel = new MethodChannel(
            flutterEngine.getDartExecutor().getBinaryMessenger(), POPUP_CHANNEL);
        popupChannel.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "getInitialProcessText": {
                    java.util.HashMap<String, Object> data = new java.util.HashMap<>();
                    data.put("text", pendingProcessText);
                    data.put("charIndex", pendingCharIndex);
                    result.success(data);
                    break;
                }
                case "finishPopup":
                    result.success(null);
                    finish();
                    break;
                default:
                    result.notImplemented();
            }
        });
        configuredFlutterEngine = flutterEngine;
    }

    private void startPopupDartIfNeeded(@NonNull FlutterEngine flutterEngine) {
        if (dartStarted || flutterEngine.getDartExecutor().isExecutingDart()) {
            dartStarted = true;
            return;
        }

        dartStarted = true;
        FlutterLoader loader = FlutterInjector.instance().flutterLoader();
        flutterEngine.getDartExecutor().executeDartEntrypoint(
            new DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "popupMain"
            )
        );
    }

    private void dispatchProcessTextToDart(String text, int charIdx) {
        if (popupChannel == null) return;
        java.util.HashMap<String, Object> args = new java.util.HashMap<>();
        args.put("text", text);
        args.put("charIndex", charIdx);
        popupChannel.invokeMethod("onNewProcessText", args);
    }

    @NonNull
    @Override
    protected FlutterActivityLaunchConfigs.BackgroundMode getBackgroundMode() {
        return FlutterActivityLaunchConfigs.BackgroundMode.transparent;
    }

    @Override
    protected void onDestroy() {
        if (ttsChannelHandler != null) {
            ttsChannelHandler.destroy();
        }
        super.onDestroy();
    }

    private String extractProcessText(Intent intent) {
        if (intent == null) return null;
        String text = intent.getStringExtra(Intent.EXTRA_PROCESS_TEXT);
        if (text != null) return text;
        text = intent.getStringExtra(Intent.EXTRA_TEXT);
        if (text != null) return text;
        android.net.Uri data = intent.getData();
        if (data != null
                && "hibiki".equals(data.getScheme())
                && "lookup".equals(data.getHost())) {
            String word = data.getQueryParameter("word");
            if (word != null && !word.trim().isEmpty()) return word;
        }
        return null;
    }

    private void applyPopupWindowSize() {
        DisplayMetrics dm = getResources().getDisplayMetrics();
        float density = dm.density;
        int screenWidth = dm.widthPixels;
        int screenHeight = dm.heightPixels;

        int maxWidthPx = (int) (520 * density);
        int maxHeightPx = (int) (640 * density);
        int width = Math.min((int) (screenWidth * 0.92f), maxWidthPx);
        int height = Math.min((int) (screenHeight * 0.70f), maxHeightPx);

        WindowManager.LayoutParams params = getWindow().getAttributes();
        params.width = width;
        params.height = height;
        params.gravity = Gravity.CENTER;
        params.dimAmount = 0f;
        getWindow().setAttributes(params);
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
    }

    private static synchronized FlutterEngine ensureCachedEngine(@NonNull Context context) {
        FlutterEngine cachedEngine = FlutterEngineCache.getInstance().get(ENGINE_ID);
        if (cachedEngine != null) return cachedEngine;

        Context appContext = context.getApplicationContext();
        FlutterLoader loader = FlutterInjector.instance().flutterLoader();
        loader.startInitialization(appContext);
        loader.ensureInitializationComplete(appContext, null);

        FlutterEngine engine = new FlutterEngine(appContext, null, false);
        PopupPluginRegistrant.registerWith(engine);
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine);
        return engine;
    }

    private static synchronized void configureWebViewDataDirectory() {
        if (webViewDataDirectoryConfigured) return;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            WebView.setDataDirectorySuffix("popup");
        }
        webViewDataDirectoryConfigured = true;
    }
}
