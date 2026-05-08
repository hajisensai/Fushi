package app.hibiki.reader;

import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.WindowManager;
import android.webkit.WebView;

import androidx.annotation.NonNull;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.android.FlutterActivityLaunchConfigs;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class PopupDictActivity extends FlutterActivity {
    private static final String POPUP_CHANNEL = "app.hibiki.reader/popup";
    private static boolean webViewDataDirectoryConfigured = false;

    private MethodChannel popupChannel;
    private AnkiChannelHandler ankiChannelHandler;
    private TtsChannelHandler ttsChannelHandler;
    private String pendingProcessText;

    @NonNull
    @Override
    public String getDartEntrypointFunctionName() {
        return "popupMain";
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        configureWebViewDataDirectory();

        ankiChannelHandler = new AnkiChannelHandler(this);
        ttsChannelHandler = new TtsChannelHandler(this);
        pendingProcessText = extractProcessText(getIntent());

        super.onCreate(savedInstanceState);

        applyPopupWindowSize();
    }

    @Override
    protected void onNewIntent(@NonNull Intent intent) {
        super.onNewIntent(intent);
        String text = extractProcessText(intent);
        if (text != null) {
            pendingProcessText = text;
            if (popupChannel != null) {
                popupChannel.invokeMethod("onNewProcessText", text);
            }
        }
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        PopupPluginRegistrant.registerWith(flutterEngine);

        ankiChannelHandler.register(flutterEngine);
        ttsChannelHandler.register(flutterEngine);

        popupChannel = new MethodChannel(
            flutterEngine.getDartExecutor().getBinaryMessenger(), POPUP_CHANNEL);
        popupChannel.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "getInitialProcessText":
                    result.success(pendingProcessText);
                    break;
                case "finishPopup":
                    result.success(null);
                    finish();
                    break;
                default:
                    result.notImplemented();
            }
        });
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
        return intent.getStringExtra(Intent.EXTRA_PROCESS_TEXT);
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
        getWindow().setAttributes(params);
    }

    private static synchronized void configureWebViewDataDirectory() {
        if (webViewDataDirectoryConfigured) return;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            WebView.setDataDirectorySuffix("popup");
        }
        webViewDataDirectoryConfigured = true;
    }
}
