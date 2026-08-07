import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the BUG-735 fix: the shelf "添加" (book import) header button must
/// match the size of its sibling header buttons (管理来源 / 合集 / 统计, which
/// go through `_headerAction` → `FushiIconButton` with the default 24) and the
/// video tab's own import button (also default 24).
///
/// The regression was `buildBookImportButton` passing an explicit
/// `size: Theme.of(context).textTheme.titleLarge?.fontSize` (~22), making the
/// add button visibly smaller and its box shorter than its neighbours, so it
/// read as "位置大小不一样". A source-level guard is the strongest landing layer:
/// it prevents anyone re-introducing a `size:` override into that one builder
/// without having to stand up the full shelf page (AppModel + DB) in a widget
/// test.
void main() {
  test('buildBookImportButton passes no explicit size (BUG-735)', () {
    final String source =
        File('lib/src/media/sources/reader_fushi_source.dart')
            .readAsStringSync();

    // Isolate the buildBookImportButton method body up to the closing of the
    // returned FushiIconButton so we only inspect this one builder.
    final int start = source.indexOf('Widget buildBookImportButton(');
    expect(start, greaterThanOrEqualTo(0),
        reason:
            'buildBookImportButton must exist in reader_fushi_source.dart.');
    final int end = source.indexOf('\n  }', start);
    expect(end, greaterThan(start),
        reason: 'Could not find the end of buildBookImportButton.');
    final String body = source.substring(start, end);

    // The returned FushiIconButton must NOT set an explicit icon size — a
    // `size:` argument here diverges from the default-24 sibling buttons and
    // re-opens BUG-735.
    expect(body.contains('size:'), isFalse,
        reason: 'buildBookImportButton must not pass an explicit `size:` to '
            'FushiIconButton — the shelf/video header buttons use the default '
            '24, and overriding it made the add button smaller (BUG-735).');
  });
}
