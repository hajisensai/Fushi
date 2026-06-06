import 'dart:async';

import 'helpers/fake_inappwebview_platform.dart';

/// Suite-wide setup for all tests under `test/`.
///
/// Registers a no-op [InAppWebViewPlatform] (BUG-093) so any widget tree that
/// mounts an `InAppWebView` can build under the unit-test harness, which has no
/// real platform view. The persistent warm dictionary popup slot now mounts its
/// WebView as soon as any `BaseSourcePageState` page builds, so every widget
/// test that pumps a reader / video / audiobook surface needs this. The fake is
/// inert (renders an empty box, fires no callbacks) and only takes effect when
/// an `InAppWebView` actually builds, so tests that don't use one are unaffected.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  installFakeInAppWebViewPlatform();
  await testMain();
}
