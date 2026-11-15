package com.pichillilorenzo.flutter_inappwebview_android;

import android.content.ComponentCallbacks2;
import android.content.Context;
import android.content.res.Configuration;
import android.util.Log;
import android.webkit.CookieManager;

import androidx.annotation.NonNull;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Fushi patch (BUG-4261 follow-up): persist page-set cookies when the app's UI
 * goes to the background, off the UI thread.
 *
 * <p>Upstream flushed the cookie store synchronously on the UI thread after
 * every page load, which ANR'd under memory / IO pressure, so that flush was
 * removed. Without any flush a cookie a page just set (e.g. a Cloudflare
 * clearance cookie) is only written on Chromium's own periodic schedule and is
 * lost if the process is killed in the background before that.
 *
 * <p>This class closes that gap: {@link #markDirty()} records that a page
 * finished loading (cheap, UI thread safe), and when the process' UI becomes
 * hidden ({@link ComponentCallbacks2#TRIM_MEMORY_UI_HIDDEN} or any background
 * trim level) one {@link CookieManager#flush()} runs on a dedicated
 * single-thread executor. Requests are coalesced: while a flush is queued,
 * further requests are dropped; a page finishing during a running flush marks
 * the store dirty again and schedules exactly one more. Nothing here ever
 * blocks the UI thread.
 */
public final class BackgroundCookieFlusher implements ComponentCallbacks2 {
  private static final String LOG_TAG = "BackgroundCookieFlusher";

  /** A page finished loading since the last flush started. */
  private static final AtomicBoolean dirty = new AtomicBoolean(false);
  /** A flush task is queued and has not started yet. */
  private static final AtomicBoolean scheduled = new AtomicBoolean(false);

  private static final ExecutorService executor =
      Executors.newSingleThreadExecutor(new ThreadFactory() {
        @Override
        public Thread newThread(@NonNull Runnable runnable) {
          Thread thread = new Thread(runnable, "fushi-cookie-flush");
          thread.setDaemon(true);
          thread.setPriority(Thread.MIN_PRIORITY);
          return thread;
        }
      });

  @NonNull
  private final Context context;

  public BackgroundCookieFlusher(@NonNull Context context) {
    this.context = context.getApplicationContext() != null
        ? context.getApplicationContext()
        : context;
    this.context.registerComponentCallbacks(this);
  }

  /** Called from WebViewClient.onPageFinished: the page may have set cookies. */
  public static void markDirty() {
    dirty.set(true);
  }

  /**
   * Queues one background flush if a page finished loading since the last
   * flush. Never blocks the caller; safe from any thread.
   */
  public static void requestFlush() {
    if (!dirty.get()) return;
    if (!scheduled.compareAndSet(false, true)) return;
    executor.execute(new Runnable() {
      @Override
      public void run() {
        scheduled.set(false);
        if (!dirty.getAndSet(false)) return;
        try {
          CookieManager.getInstance().flush();
        } catch (Exception e) {
          // WebView package missing / being updated: nothing to persist into.
          Log.w(LOG_TAG, "background cookie flush failed", e);
        }
      }
    });
  }

  @Override
  public void onTrimMemory(int level) {
    // UI_HIDDEN (20) and the background levels (40/60/80) all mean no activity
    // of this process is visible; RUNNING_* (5/10/15) are foreground signals.
    if (level >= TRIM_MEMORY_UI_HIDDEN) {
      requestFlush();
    }
  }

  @Override
  public void onConfigurationChanged(@NonNull Configuration newConfig) {}

  @Override
  public void onLowMemory() {
    requestFlush();
  }

  public void dispose() {
    context.unregisterComponentCallbacks(this);
  }
}
