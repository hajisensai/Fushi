import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-080 source guard: the dictionary popup WebView must be mounted as soon
/// as the lookup starts (while `isSearching`, before results arrive) so it
/// cold-loads in parallel with the FFI lookup, instead of only after results
/// are ready. Driving this behaviorally needs a real InAppWebView + platform
/// view (not available headless), so this locks the call-site invariant.
void main() {
  final String src =
      File('lib/src/pages/implementations/dictionary_popup_layer.dart')
          .readAsStringSync();

  test('a shared empty result exists for the search-phase preload', () {
    expect(src.contains('kPopupSearchingPlaceholderResult'), isTrue);
  });

  test('_buildBody mounts the WebView during searching, not only with results',
      () {
    final int bodyStart = src.indexOf('Widget _buildBody(');
    expect(bodyStart, greaterThanOrEqualTo(0));
    final String body = src.substring(bodyStart);

    // The WebView branch must be entered while searching, not gated solely on
    // having entries.
    expect(body.contains('hasRenderableResults || isSearching'), isTrue,
        reason: 'WebView must mount during the search phase to preload');

    // And it must fall back to the shared empty result when results are not
    // ready yet.
    expect(body.contains('result ?? kPopupSearchingPlaceholderResult'), isTrue,
        reason: 'preload mounts with the shared empty result');
  });
}
