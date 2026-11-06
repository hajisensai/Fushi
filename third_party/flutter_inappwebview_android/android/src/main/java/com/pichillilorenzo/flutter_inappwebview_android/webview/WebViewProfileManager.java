package com.pichillilorenzo.flutter_inappwebview_android.webview;

import android.util.Log;
import android.webkit.CookieManager;
import android.webkit.WebView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.webkit.Profile;
import androidx.webkit.ProfileStore;
import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;

import com.pichillilorenzo.flutter_inappwebview_android.InAppWebViewFlutterPlugin;
import com.pichillilorenzo.flutter_inappwebview_android.types.ChannelDelegateImpl;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Hibiki patch: named WebView profiles (androidx.webkit {@code MULTI_PROFILE}).
 *
 * <p>Why: upstream's {@code incognito} setting only wipes the <b>global</b>
 * {@link CookieManager} and turns caching off. That neither isolates the
 * incognito page (it shares the cookie jar with every other WebView) nor
 * leaves the normal tabs / online-source logins alone. A non-default
 * {@link Profile} has its own cookie jar, web storage, cache and service
 * workers, so Fushi's incognito browser tabs get one profile per incognito
 * session (the Dart side never reuses a session name) and the session's data
 * is removed when it ends.
 *
 * <p>Lifecycle rules this class enforces:
 * <ul>
 *   <li>{@link WebViewCompat#setProfile} must run before the WebView is used
 *   for anything (settings, loads, scripts), so {@code FlutterWebView} calls
 *   {@link #attach} right after constructing the view.</li>
 *   <li>A profile cannot be deleted by the process that loaded it. Chromium's
 *   {@code AwBrowserContextStore::Delete} answers {@code kInUse} ("Cannot
 *   delete in-use profile") whenever the profile's {@code AwBrowserContext}
 *   has been instantiated, and an instantiated context is never unloaded.
 *   Verified on device (WebView 158): {@code deleteProfile} after the last
 *   WebView of the profile was destroyed still threw. So ending a session whose
 *   profile this process loaded <b>wipes</b> the profile's cookies, web storage
 *   and geolocation grants, and the profile itself (directory incl. HTTP cache)
 *   is deleted by {@link #deleteUnused} on the next start, before anything
 *   loads it. Never call {@link ProfileStore#getProfile} on a profile you want
 *   to delete in this process: it instantiates the context.</li>
 *   <li>Plugin disposal only <i>schedules</i> {@code WebView.destroy()} (from
 *   the about:blank {@code onPageFinished}), so ending a session while views
 *   are alive is recorded and carried out when the last one is destroyed
 *   ({@link #release}, called from {@code InAppWebView.destroy()}).</li>
 * </ul>
 * All methods run on the main thread (WebView APIs and the platform channel
 * handler both live there), so the static state needs no locking.
 */
public class WebViewProfileManager extends ChannelDelegateImpl {
  protected static final String LOG_TAG = "WebViewProfileManager";
  public static final String METHOD_CHANNEL_NAME = "com.pichillilorenzo/flutter_inappwebview_profile";

  /** Settings-map key the Dart side puts the profile name under. */
  public static final String SETTINGS_KEY = "webViewProfileName";

  private static final Map<String, Integer> liveWebViews = new HashMap<>();
  private static final Set<String> pendingEnds = new HashSet<>();
  /** Profiles this process loaded: they can be wiped but not deleted. */
  private static final Set<String> loadedInProcess = new HashSet<>();

  @Nullable
  public InAppWebViewFlutterPlugin plugin;

  public WebViewProfileManager(@NonNull final InAppWebViewFlutterPlugin plugin) {
    super(new MethodChannel(plugin.messenger, METHOD_CHANNEL_NAME));
    this.plugin = plugin;
  }

  public static boolean isSupported() {
    return WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE);
  }

  private static boolean isNamed(@Nullable String name) {
    return name != null && !name.isEmpty() && !Profile.DEFAULT_PROFILE_NAME.equals(name);
  }

  /**
   * Puts a freshly constructed WebView into profile {@code name} (created on
   * demand). Returns the name actually attached, or null when the view stays
   * on the default profile (no name / feature unsupported / setProfile
   * refused). The Dart side only asks after {@code isSupported} answered true.
   */
  @Nullable
  public static String attach(@NonNull WebView webView, @Nullable String name) {
    if (!isNamed(name) || !isSupported()) return null;
    try {
      ProfileStore.getInstance().getOrCreateProfile(name);
      WebViewCompat.setProfile(webView, name);
    } catch (RuntimeException e) {
      Log.e(LOG_TAG, "setProfile(" + name + ") failed", e);
      return null;
    }
    // A new view for a profile whose session end is pending means the Dart
    // side reused the name; keep the data.
    pendingEnds.remove(name);
    loadedInProcess.add(name);
    Integer count = liveWebViews.get(name);
    liveWebViews.put(name, count == null ? 1 : count + 1);
    return name;
  }

  /** Called once per attached WebView, after its native side is gone. */
  public static void release(@Nullable String name) {
    if (!isNamed(name)) return;
    Integer count = liveWebViews.get(name);
    int next = count == null ? 0 : count - 1;
    if (next > 0) {
      liveWebViews.put(name, next);
      return;
    }
    liveWebViews.remove(name);
    if (pendingEnds.remove(name)) {
      endNow(name);
    }
  }

  private static boolean exists(@NonNull String name) {
    return ProfileStore.getInstance().getAllProfileNames().contains(name);
  }

  /** No live WebView: delete the profile, or wipe it if this process loaded it. */
  private static boolean endNow(@NonNull String name) {
    if (!exists(name)) return true;
    if (!loadedInProcess.contains(name)) return deleteNow(name);
    Profile profile = ProfileStore.getInstance().getProfile(name);
    if (profile == null) return true;
    CookieManager cookies = profile.getCookieManager();
    cookies.removeAllCookies(null);
    cookies.flush();
    profile.getWebStorage().deleteAllData();
    profile.getGeolocationPermissions().clearAll();
    return true;
  }

  private static boolean deleteNow(@NonNull String name) {
    try {
      return ProfileStore.getInstance().deleteProfile(name);
    } catch (RuntimeException e) {
      Log.e(LOG_TAG, "deleteProfile(" + name + ") failed", e);
      return false;
    }
  }

  /**
   * Ends the session of profile {@code name} (see class doc): now when no
   * WebView uses it, otherwise when the last one is destroyed. Returns true
   * when done or scheduled.
   */
  public static boolean requestEnd(@Nullable String name) {
    if (!isNamed(name) || !isSupported()) return false;
    Integer count = liveWebViews.get(name);
    if (count != null && count > 0) {
      pendingEnds.add(name);
      return true;
    }
    return endNow(name);
  }

  /**
   * Deletes profiles whose name starts with {@code prefix} and that this
   * process has not loaded: sessions ended in an earlier process (wiped but
   * not deletable there) and sessions the process died in.
   */
  @NonNull
  public static List<String> deleteUnused(@NonNull String prefix) {
    List<String> deleted = new ArrayList<>();
    if (prefix.isEmpty() || !isSupported()) return deleted;
    for (String name : ProfileStore.getInstance().getAllProfileNames()) {
      if (!isNamed(name) || !name.startsWith(prefix)) continue;
      if (loadedInProcess.contains(name)) continue;
      if (deleteNow(name)) deleted.add(name);
    }
    return deleted;
  }

  @Nullable
  private static CookieManager cookieManagerOf(@Nullable String name) {
    // Only for a profile in use by this process (getProfile loads it).
    if (!isNamed(name) || !isSupported() || !loadedInProcess.contains(name)) return null;
    Profile profile = ProfileStore.getInstance().getProfile(name);
    return profile == null ? null : profile.getCookieManager();
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    switch (call.method) {
      case "isSupported":
        result.success(isSupported());
        break;
      case "deleteProfile":
        result.success(requestEnd((String) call.argument("name")));
        break;
      case "deleteUnusedProfiles": {
        String prefix = (String) call.argument("prefix");
        result.success(prefix == null ? new ArrayList<String>() : deleteUnused(prefix));
        break;
      }
      case "getCookie": {
        // The profile's own jar: the global CookieManager (what the plugin's
        // CookieManager class talks to) never sees an incognito page's cookies.
        CookieManager manager = cookieManagerOf((String) call.argument("name"));
        String url = (String) call.argument("url");
        result.success(manager == null || url == null ? null : manager.getCookie(url));
        break;
      }
      default:
        result.notImplemented();
    }
  }

  @Override
  public void dispose() {
    super.dispose();
    plugin = null;
  }
}
