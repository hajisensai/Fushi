import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// Perf guard (查词弹窗弹出慢): in [_lookupAt] the lookup popup must not be
/// blocked on `controller.pause()`. media_kit/libmpv `pause()` has an IPC
/// round-trip on desktop, and awaiting it before `pushNestedPopup` delayed the
/// first lookup's popup by a whole pause latency. Pause is a side effect, so it
/// is fired-and-forgotten (`unawaited`) while the popup is pushed immediately.
/// VideoHibikiPage drives media_kit and can't be widget-tested headlessly, so a
/// source guard locks the ordering.
void main() {
  test('lookup pause is fire-and-forget, never awaited before the popup', () {
    // TODO-590 batch13: `_lookupAt` 已搬进 lookup_favorite.part.dart，改读合并语料。
    final String src = readVideoHibikiSource();

    final int start = src.indexOf('Future<void> _lookupAt(');
    expect(start, greaterThanOrEqualTo(0), reason: '_lookupAt not found');
    final int end = src.indexOf('\n  }', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);

    expect(body, contains('unawaited(controller.pause())'),
        reason: 'pause must be fire-and-forget so it never blocks the popup');
    expect(body.contains('await controller.pause()'), isFalse,
        reason: 'awaiting pause before pushNestedPopup re-introduces the first-'
            'lookup popup delay (perf regression)');
    // The resume contract (BUG-072) still requires the paused flag to be set.
    expect(body, contains('_pausedForLookup = true'),
        reason: 'must still mark paused-for-lookup for the resume path');
  });
}
