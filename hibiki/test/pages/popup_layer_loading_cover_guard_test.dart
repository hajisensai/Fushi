import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// White-flash unification guard: the shared [DictionaryPopupLayer] (used by the
/// reader, audiobook, video, home dictionary tab and the standalone popup
/// window) must, while a lookup is searching and no entries have arrived yet,
/// cover the still-mounted/warm WebView with an OPAQUE themed surface. The video
/// popup (mixin `reuseWarmSlot`) reveals its warm slot before results arrive, so
/// without this cover the empty WebView leaks a white background on Windows'
/// inappwebview fork — the "白屏等一会才出字" the user reported. A finished search
/// with results (hasEntries) or pagination load-more must NOT trigger the cover.
///
/// The branch mounts the real platform WebView, which can't run headlessly, so
/// this is a source-scan guard (repo convention for WebView-mounting code).
void main() {
  const String path =
      'lib/src/pages/implementations/dictionary_popup_layer.dart';

  test('searching-without-entries paints an opaque themed loading cover', () {
    final String src = File(path).readAsStringSync();

    final int bodyIdx = src.indexOf('Widget _buildBody(');
    expect(bodyIdx, greaterThanOrEqualTo(0), reason: '_buildBody not found');
    final String body = src.substring(bodyIdx);

    // The cover is gated on "searching AND no renderable result yet" so
    // dictionary/kanji results and pagination never get covered, and an idle slot (not
    // searching) shows nothing.
    expect(body, contains('isSearching && !hasRenderableResults'),
        reason:
            'loading cover must be gated on searching-without-renderable-results only');
    // It must be an OPAQUE fill (ColoredBox with the popup fill color), not a
    // transparent spinner that lets the white WebView show through.
    expect(body, contains('ColoredBox('),
        reason: 'cover must be an opaque ColoredBox over the WebView');
    expect(body, contains('color: fillColor'),
        reason: 'cover must use the themed popup fill color');
    expect(body, contains('LinearProgressIndicator('),
        reason: 'cover must show a progress indicator for feedback');
  });
}
