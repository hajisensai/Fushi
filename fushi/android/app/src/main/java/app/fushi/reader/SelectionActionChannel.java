package app.fushi.reader;

import android.app.Activity;
import android.app.SearchManager;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.net.Uri;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import app.fushi.reader.constants.ChannelNames;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/** Android-only selected-text actions shared by the reader and popup engines. */
public final class SelectionActionChannel {
    private static final String METHOD_WEB_SEARCH = "webSearch";
    private static final String ARG_QUERY = "query";
    /** Never launched; only resolves which app holds the default-browser role. */
    private static final String BROWSER_PROBE_URL = "https://example.com/";

    private SelectionActionChannel() {}

    public static void registerWith(
            @NonNull FlutterEngine flutterEngine, @NonNull Context context) {
        new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(),
                ChannelNames.SELECTION_ACTIONS)
            .setMethodCallHandler((call, result) -> {
                if (!METHOD_WEB_SEARCH.equals(call.method)) {
                    result.notImplemented();
                    return;
                }

                final String query = call.argument(ARG_QUERY);
                if (query == null || query.isEmpty()) {
                    result.error("INVALID_QUERY", "query must not be empty", null);
                    return;
                }
                result.success(launchWebSearch(context, query));
            });
    }

    /**
     * Sends {@code ACTION_WEB_SEARCH} to the user's default browser first.
     *
     * <p>Android resolves {@code ACTION_WEB_SEARCH} independently of the
     * default-browser role (which only covers {@code ACTION_VIEW http/https}),
     * so a bare intent lands on whatever registered the action — on OEM ROMs
     * that is the stock browser regardless of the user's choice (BUG-2491).
     * Targeting the default browser lets it search with its own engine; a
     * browser that does not handle the action falls back to the bare intent,
     * i.e. the previous behaviour.
     */
    private static boolean launchWebSearch(@NonNull Context context, @NonNull String query) {
        final Intent intent = new Intent(Intent.ACTION_WEB_SEARCH);
        // Do not trim or otherwise normalize: CJK, spaces, and newlines are the
        // user's selected payload and must reach the system handler unchanged.
        intent.putExtra(SearchManager.QUERY, query);
        if (!(context instanceof Activity)) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        }
        final String browser = defaultBrowserPackage(context);
        if (browser != null) {
            try {
                context.startActivity(new Intent(intent).setPackage(browser));
                return true;
            } catch (ActivityNotFoundException error) {
                // Default browser does not register ACTION_WEB_SEARCH; let the
                // system pick a handler as before.
            }
        }
        try {
            context.startActivity(intent);
            return true;
        } catch (ActivityNotFoundException error) {
            return false;
        }
    }

    /**
     * Package of the app holding the default-browser role, or {@code null} when
     * none is set (the resolver activity reports the {@code android} package).
     * Needs the {@code <queries>} VIEW-https declaration in the manifest;
     * without it Android 11+ package visibility hides every browser.
     */
    @Nullable
    private static String defaultBrowserPackage(@NonNull Context context) {
        final Intent probe = new Intent(Intent.ACTION_VIEW, Uri.parse(BROWSER_PROBE_URL))
                .addCategory(Intent.CATEGORY_BROWSABLE);
        final ResolveInfo info = context.getPackageManager()
                .resolveActivity(probe, PackageManager.MATCH_DEFAULT_ONLY);
        if (info == null || info.activityInfo == null) {
            return null;
        }
        final String packageName = info.activityInfo.packageName;
        return "android".equals(packageName) ? null : packageName;
    }
}
