import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards BUG-546 (TODO-1135) under the TODO-1321 unified-width model.
///
/// In the reader quick-settings 「布局与显示」 sub-page the theme selector card sits
/// in the same Column as the layout schema section (rendered by
/// [MaterialSettingsRenderer.buildDetailContent]). Originally the schema body
/// carried an extra horizontal inset while the theme card did not, so their edges
/// misaligned; the first fix wrapped the theme card in the SAME
/// detailHorizontalInsets. TODO-1321 removed the double-indent entirely: the
/// schema body is now projected with `insetHorizontally: false` (the reader pane
/// owns the horizontal margins), so BOTH the theme card and the schema section are
/// bare [AdaptiveSettingsSection]s spanning the full pane width — equal width
/// (BUG-546) preserved, now at the wider, pane-flush width that also matches the
/// bespoke 导航 / 有声书 sub-pages.
void main() {
  test('theme selector section is bare (no self horizontal inset)', () {
    final String sheet =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();

    final int start = sheet.indexOf('Widget _buildThemeSelectorSection()');
    expect(start, greaterThanOrEqualTo(0),
        reason: 'theme selector section builder must exist');
    final int end = sheet.indexOf('\n  }', start);
    expect(end, greaterThan(start));
    final String body = sheet.substring(start, end);

    // The card must render as a plain AdaptiveSettingsSection with NO Padding /
    // detailHorizontalInsets wrapper — otherwise it would inset differently from
    // the flush schema body and misalign again (BUG-546).
    expect(body.contains('AdaptiveSettingsSection('), isTrue,
        reason: 'theme card is a plain settings section');
    expect(body.contains('Padding('), isFalse,
        reason: 'theme card must not re-wrap in a horizontal Padding');
    expect(body.contains('detailHorizontalInsets'), isFalse,
        reason: 'theme card must not carry its own detailHorizontalInsets');
  });

  test('layout schema projection drops the renderer inset (equal width)', () {
    final String sheet =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();
    // Config rows come from buildDetailContent; projecting them with
    // insetHorizontally:false makes them span the same pane width as the theme
    // card above (equal width, BUG-546) — and the bespoke sub-pages (TODO-1321).
    expect(sheet.contains('insetHorizontally: false'), isTrue,
        reason:
            'schema projection must let the renderer drop its horizontal inset');
  });
}
