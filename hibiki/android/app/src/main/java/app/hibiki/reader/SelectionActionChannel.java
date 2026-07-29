package app.hibiki.reader;

import android.app.Activity;
import android.app.SearchManager;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;

import androidx.annotation.NonNull;

import app.hibiki.reader.constants.ChannelNames;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/** Android-only selected-text actions shared by the reader and popup engines. */
public final class SelectionActionChannel {
    private static final String METHOD_WEB_SEARCH = "webSearch";
    private static final String ARG_QUERY = "query";

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

    private static boolean launchWebSearch(@NonNull Context context, @NonNull String query) {
        final Intent intent = new Intent(Intent.ACTION_WEB_SEARCH);
        // Do not trim or otherwise normalize: CJK, spaces, and newlines are the
        // user's selected payload and must reach the system handler unchanged.
        intent.putExtra(SearchManager.QUERY, query);
        if (!(context instanceof Activity)) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        }
        if (intent.resolveActivity(context.getPackageManager()) == null) {
            return false;
        }
        try {
            context.startActivity(intent);
            return true;
        } catch (ActivityNotFoundException error) {
            return false;
        }
    }
}
