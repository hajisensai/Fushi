# flutter_inappwebview_ios 1.1.2

Whole-file overlays applied onto the pub cache by `ci/apply-patches.sh` /
`tool/bootstrap.ps1`, pinned to 1.1.2. The Swift files carry the BUG-4013
content-rule-list fix (guard: `fushi/test/build/inappwebview_content_rule_list_patch_guard_test.dart`).

## `preventGestureDelay` → `UiKitViewGestureBlockingPolicy.doNotBlockGesture`

Feedback P2jQzOBBag / BUG-4360 (manga paged double-tap zoom on iOS): a double tap
on a blank part of a manga page almost always toggled the reader chrome
instead of zooming; only fast triple taps zoomed now and then.

The manga reader recognises every gesture in page JavaScript (DOM pointer
events, see `fushi/lib/src/media/manga/manga_overlay_html.dart`): a blank
single tap is held for the double-tap window and cancelled when the second
tap's `pointerdown` lands. That window measures time **between DOM pointer
events**, so it is only correct if WKWebView sees the fingers in real time.

On iOS it does not. With the engine's default `eager` blocking policy, every
platform view gets a `FlutterDelayingGestureRecognizer` with
`delaysTouchesBegan` / `delaysTouchesEnded`, and all of WKWebView's
recognizers (including the one that dispatches DOM touch / pointer events)
are required to wait for it to fail. It only fails when the Flutter gesture
arena resolves in favour of the platform view and the framework's
`acceptGesture` platform-channel call arrives back on the platform thread.
Each touch sequence therefore reaches the page after an asynchronous round
trip whose length depends on what else sits in the arena and how busy the UI
thread is; when the arena only resolves on pointer up, the second tap's
`pointerdown` is delivered together with its `pointerup`. The deferred blank
tap fires first and the chrome toggles. (Derived from the engine source and
the reported symptom; the delivery delay has not been timestamped on a
device.)

Upstream already has an option for exactly this — `preventGestureDelay`,
documented as "Used to prevent gesture delay on iOS caused by Flutter's
gestures handling between native/platform views" — but its implementation
(`InAppWebView.swift`, `hitTest`) disables a recognizer whose class name must
equal `DelayingGestureRecognizer`. The engine renamed it to
`FlutterDelayingGestureRecognizer`, so the option has been a no-op.

Patch (overlay `lib/src/in_app_webview/in_app_webview.dart`, the upstream file
plus the function below and one `UiKitView` argument): `UiKitView` now gets
`gestureBlockingPolicy: inAppWebViewGestureBlockingPolicy(...)`, which maps
`preventGestureDelay == true` to `doNotBlockGesture` and everything else to
`fallbackToPluginDefault` (unchanged behaviour for every other WebView).
With `doNotBlockGesture` the engine never installs the delaying recognizer;
Flutter widgets drawn over the WebView (lookup popup barrier, reader chrome,
dialogs) are still blocked by the engine's synchronous hit test. The policy is
also what Flutter recommends for WKWebView recognisers stuck in a stale state
on iOS 26 (flutter/flutter#175099). Requires the `UiKitView.gestureBlockingPolicy`
API (present in the pinned Flutter 3.47.6).

Only WebViews that pass `preventGestureDelay: true` are affected, and they
must not rely on Flutter gesture recognisers (ancestors or
`gestureRecognizers`) winning gestures away from the page. Current user:
the manga reader WebView (`MangaFushiPage._buildWebViewSurface`). The dead
native class-name branch in `InAppWebView.swift` is left untouched (with
`doNotBlockGesture` there is no delaying recognizer for it to find).
Guard: `fushi/test/media/manga/manga_webview_gesture_policy_test.dart`.
