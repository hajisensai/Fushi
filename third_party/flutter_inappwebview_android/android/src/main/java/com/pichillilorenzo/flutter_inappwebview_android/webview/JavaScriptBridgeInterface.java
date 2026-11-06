package com.pichillilorenzo.flutter_inappwebview_android.webview;

import android.os.Build;
import android.os.Handler;
import android.util.Log;
import android.webkit.JavascriptInterface;
import android.webkit.ValueCallback;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.pichillilorenzo.flutter_inappwebview_android.print_job.PrintJobController;
import com.pichillilorenzo.flutter_inappwebview_android.print_job.PrintJobSettings;
import com.pichillilorenzo.flutter_inappwebview_android.webview.in_app_webview.InAppWebView;
import com.pichillilorenzo.flutter_inappwebview_android.plugin_scripts_js.JavaScriptBridgeJS;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;

public class JavaScriptBridgeInterface {
  private static final String LOG_TAG = "JSBridgeInterface";
  // Fushi patch (bridge lock): handler name intercepted by the bridge script itself; it must
  // never be dispatched to app-registered handlers. See PATCHES.md.
  public static final String FUSHI_LOCK_BRIDGE_HANDLER_NAME = "_fushiLockBridge";
  private static final int FUSHI_BRIDGE_TOKEN_BYTES = 32; // 256 bit
  private static final SecureRandom FUSHI_BRIDGE_RANDOM = new SecureRandom();
  private InAppWebView inAppWebView;
  // Fushi patch (bridge lock): null = unlocked (upstream behaviour). Guarded by fushiBridgeLockMonitor:
  // read/written from the JavaBridge thread (@JavascriptInterface calls) and the UI thread
  // (onPageStarted reset).
  private final Object fushiBridgeLockMonitor = new Object();
  @Nullable
  private byte[] fushiBridgeToken;

  public JavaScriptBridgeInterface(InAppWebView inAppWebView) {
    this.inAppWebView = inAppWebView;
  }

  /**
   * Fushi patch (bridge lock): issues the per-WebView bridge token. Returns the token once per
   * top-level document; returns null while a token is already held (the bridge script then
   * resolves the lock request with {@code false}). Native code cannot tell which frame calls this,
   * so the bridge script only asks from the top frame and the page must lock before rendering
   * untrusted content. See PATCHES.md.
   */
  @JavascriptInterface
  @Nullable
  public String _fushiLockBridge() {
    if (inAppWebView == null) {
      return null;
    }
    synchronized (fushiBridgeLockMonitor) {
      if (fushiBridgeToken != null) {
        Log.w(LOG_TAG, "Refusing _fushiLockBridge: the bridge is already locked");
        return null;
      }
      byte[] raw = new byte[FUSHI_BRIDGE_TOKEN_BYTES];
      FUSHI_BRIDGE_RANDOM.nextBytes(raw);
      StringBuilder hex = new StringBuilder(raw.length * 2);
      for (byte b : raw) {
        hex.append(Character.forDigit((b >> 4) & 0xF, 16));
        hex.append(Character.forDigit(b & 0xF, 16));
      }
      String token = hex.toString();
      fushiBridgeToken = token.getBytes(StandardCharsets.UTF_8);
      return token;
    }
  }

  /** Fushi patch (bridge lock): back to unlocked; called when a new top-level document starts. */
  public void fushiResetBridgeLock() {
    synchronized (fushiBridgeLockMonitor) {
      fushiBridgeToken = null;
    }
  }

  /**
   * Fushi patch (bridge lock): true when the call may be dispatched. Unlocked accepts everything
   * (upstream behaviour); locked requires the exact token (constant-time compare).
   */
  private boolean fushiAcceptsBridgeCall(@Nullable String token, @NonNull String what) {
    synchronized (fushiBridgeLockMonitor) {
      if (fushiBridgeToken == null) {
        return true;
      }
      if (token != null && MessageDigest.isEqual(fushiBridgeToken, token.getBytes(StandardCharsets.UTF_8))) {
        return true;
      }
    }
    Log.w(LOG_TAG, "Dropping " + what + ": the bridge is locked and the call carries no valid token");
    return false;
  }

  @JavascriptInterface
  public void _hideContextMenu() {
    _fushiHideContextMenu(null);
  }

  /** Fushi patch (bridge lock): token-carrying variant used by the bridge script. */
  @JavascriptInterface
  public void _fushiHideContextMenu(@Nullable final String token) {
    if (inAppWebView == null) {
      return;
    }
    if (!fushiAcceptsBridgeCall(token, "_hideContextMenu")) {
      return;
    }

    final Handler handler = new Handler(inAppWebView.getWebViewLooper());
    handler.post(new Runnable() {
      @Override
      public void run() {
        if (inAppWebView != null && inAppWebView.floatingContextMenu != null) {
          inAppWebView.hideContextMenu();
        }
      }
    });
  }

  @JavascriptInterface
  public void _callHandler(final String handlerName, final String _callHandlerID, final String args) {
    fushiDispatchCallHandler(handlerName, _callHandlerID, args, null);
  }

  /**
   * Fushi patch (bridge lock): token-carrying entry point. The bridge script's callHandler wrapper
   * uses it once the page has locked the bridge; the 3-argument {@link #_callHandler} stays for the
   * unlocked case and is equivalent to passing a null token.
   */
  @JavascriptInterface
  public void _fushiCallHandler(final String handlerName, final String _callHandlerID, final String args,
                                @Nullable final String token) {
    fushiDispatchCallHandler(handlerName, _callHandlerID, args, token);
  }

  private void fushiDispatchCallHandler(final String handlerName, final String _callHandlerID, final String args,
                                        @Nullable final String token) {
    if (inAppWebView == null) {
      return;
    }
    // Fushi patch (bridge lock): once locked, every JS->native call must carry the token issued by
    // _fushiLockBridge; anything else (e.g. a sandboxed dictionary iframe reaching the Java
    // interface directly) is dropped without dispatch or callback. See PATCHES.md.
    if (!fushiAcceptsBridgeCall(token, "_callHandler")) {
      return;
    }
    // The lock request is handled by the bridge script; a raw _callHandler with that name never
    // reaches app handlers.
    if (FUSHI_LOCK_BRIDGE_HANDLER_NAME.equals(handlerName)) {
      Log.w(LOG_TAG, "Dropping raw _callHandler for " + FUSHI_LOCK_BRIDGE_HANDLER_NAME);
      return;
    }
    // Fushi patch: _callHandlerID comes from the page (any frame can reach this interface) and is
    // concatenated into JavaScript evaluated in the top frame below. The bridge script only ever
    // passes a setTimeout() handle, so anything that is not a plain integer is an injection attempt
    // (e.g. '0]&&evil()//' from an ad iframe) and is dropped. See PATCHES.md.
    if (handlerName == null || _callHandlerID == null || !_callHandlerID.matches("\\d{1,15}")) {
      Log.w(LOG_TAG, "Dropping _callHandler with a non-numeric _callHandlerID");
      return;
    }

    // java.lang.RuntimeException: Methods marked with @UiThread must be executed on the main thread.
    // https://github.com/pichillilorenzo/flutter_inappwebview/issues/98
    final Handler handler = new Handler(inAppWebView.getWebViewLooper());
    handler.post(new Runnable() {
      @Override
      public void run() {
        if (inAppWebView == null) {
          // The webview has already been disposed, ignore.
          return;
        }

        if (handlerName.equals("onPrintRequest") && Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
          PrintJobSettings settings = new PrintJobSettings();
          settings.handledByClient = true;
          final String printJobId = inAppWebView.printCurrentPage(settings);
          if (inAppWebView != null && inAppWebView.channelDelegate != null) {
            inAppWebView.channelDelegate.onPrintRequest(inAppWebView.getUrl(), printJobId, new WebViewChannelDelegate.PrintRequestCallback() {
              @Override
              public boolean nonNullSuccess(@NonNull Boolean handledByClient) {
                return !handledByClient;
              }

              @Override
              public void defaultBehaviour(@Nullable Boolean handledByClient) {
                if (inAppWebView != null && inAppWebView.plugin != null && inAppWebView.plugin.printJobManager != null) {
                  PrintJobController printJobController = inAppWebView.plugin.printJobManager.jobs.get(printJobId);
                  if (printJobController != null) {
                    printJobController.disposeNoCancel();
                  }
                }
              }

              @Override
              public void error(String errorCode, @Nullable String errorMessage, @Nullable Object errorDetails) {
                Log.e(LOG_TAG, errorCode + ", " + ((errorMessage != null) ? errorMessage : ""));
                defaultBehaviour(null);
              }
            });
          }
          return;
        } else if (handlerName.equals("callAsyncJavaScript")) {
          try {
            JSONArray arguments = new JSONArray(args);
            JSONObject jsonObject = arguments.getJSONObject(0);
            String resultUuid = jsonObject.getString("resultUuid");
            ValueCallback<String> callAsyncJavaScriptCallback = inAppWebView.callAsyncJavaScriptCallbacks.get(resultUuid);
            if (callAsyncJavaScriptCallback != null) {
              callAsyncJavaScriptCallback.onReceiveValue(jsonObject.toString());
              inAppWebView.callAsyncJavaScriptCallbacks.remove(resultUuid);
            }
          } catch (JSONException e) {
            Log.e(LOG_TAG, "", e);
          }
          return;
        } else if (handlerName.equals("evaluateJavaScriptWithContentWorld")) {
          try {
            JSONArray arguments = new JSONArray(args);
            JSONObject jsonObject = arguments.getJSONObject(0);
            String resultUuid = jsonObject.getString("resultUuid");
            ValueCallback<String> evaluateJavaScriptCallback = inAppWebView.evaluateJavaScriptContentWorldCallbacks.get(resultUuid);
            if (evaluateJavaScriptCallback != null) {
              evaluateJavaScriptCallback.onReceiveValue(jsonObject.has("value") ? jsonObject.get("value").toString() : "null");
              inAppWebView.evaluateJavaScriptContentWorldCallbacks.remove(resultUuid);
            }
          } catch (JSONException e) {
            Log.e(LOG_TAG, "", e);
          }
          return;
        }

        if (inAppWebView.channelDelegate != null) {
          // invoke flutter javascript handler and send back flutter data as a JSON Object to javascript
          inAppWebView.channelDelegate.onCallJsHandler(handlerName, args, new WebViewChannelDelegate.CallJsHandlerCallback() {
            @Override
            public void defaultBehaviour(@Nullable Object json) {
              if (inAppWebView == null) {
                // The webview has already been disposed, ignore.
                return;
              }
              String sourceCode = "if (window." + JavaScriptBridgeJS.JAVASCRIPT_BRIDGE_NAME + "[" + _callHandlerID + "] != null) { " +
                "window." + JavaScriptBridgeJS.JAVASCRIPT_BRIDGE_NAME + "[" + _callHandlerID + "].resolve(" + json + "); " +
                "delete window." + JavaScriptBridgeJS.JAVASCRIPT_BRIDGE_NAME + "[" + _callHandlerID + "]; " +
              "}";
              if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
                inAppWebView.evaluateJavascript(sourceCode, (ValueCallback<String>) null);
              }
              else {
                inAppWebView.loadUrl("javascript:" + sourceCode);
              }
            }

            @Override
            public void error(String errorCode, @Nullable String errorMessage, @Nullable Object errorDetails) {
              String message = errorCode + ((errorMessage != null) ? ", " + errorMessage : "");
              Log.e(LOG_TAG, message);

              if (inAppWebView == null) {
                // The webview has already been disposed, ignore.
                return;
              }

              String sourceCode = "if (window." + JavaScriptBridgeJS.JAVASCRIPT_BRIDGE_NAME + "[" + _callHandlerID + "] != null) { " +
                      "window." + JavaScriptBridgeJS.JAVASCRIPT_BRIDGE_NAME + "[" + _callHandlerID + "].reject(new Error(" + JSONObject.quote(message) + ")); " +
                      "delete window." + JavaScriptBridgeJS.JAVASCRIPT_BRIDGE_NAME + "[" + _callHandlerID + "]; " +
                      "}";
              if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
                inAppWebView.evaluateJavascript(sourceCode, (ValueCallback<String>) null);
              }
              else {
                inAppWebView.loadUrl("javascript:" + sourceCode);
              }
            }
          });
        }
      }
    });
  }

  public void dispose() {
    fushiResetBridgeLock();
    inAppWebView = null;
  }
}
