import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards BUG-573 (TODO-1234) under the TODO-1321 unified-width model.
///
/// In the reader quick-settings 「布局与显示」 sub-page (and its lyrics-mode twin) the
/// 「编辑书籍 CSS」 entry row sits in the same Column as the layout schema section.
/// It must line up with the config rows above. Originally the schema body carried
/// an extra horizontal inset, so the CSS row (a bare section) drifted; the first
/// fix wrapped it in the same detailHorizontalInsets. TODO-1321 removed the
/// double-indent: the schema body is projected with `insetHorizontally: false`, so
/// the CSS row is a bare [AdaptiveSettingsSection] at the full pane width, equal to
/// the config rows and to the bespoke 导航 / 有声书 sub-pages.
void main() {
  test('css editor section is bare and is the single call path', () {
    final String sheet =
        File('lib/src/media/audiobook/reader_quick_settings_sheet.dart')
            .readAsStringSync();

    final int start = sheet.indexOf('Widget _buildBookCssEditorSection()');
    expect(start, greaterThanOrEqualTo(0),
        reason: 'CSS editor section builder must exist');
    final int end = sheet.indexOf('\n  }', start);
    expect(end, greaterThan(start));
    final String body = sheet.substring(start, end);

    // Bare section — no self horizontal inset (would misalign vs the flush schema
    // body again, BUG-573).
    expect(body.contains('AdaptiveSettingsSection('), isTrue,
        reason: 'CSS row is a plain settings section');
    expect(body.contains('Padding('), isFalse,
        reason: 'CSS row must not re-wrap in a horizontal Padding');
    expect(body.contains('detailHorizontalInsets'), isFalse,
        reason: 'CSS row must not carry its own detailHorizontalInsets');

    // Both layout sub-pages (normal + lyrics) route through the single wrapper;
    // the raw row is wrapped in a section exactly once (no bare re-wrap at call
    // sites that would drop the shared width).
    final int wrapperCalls =
        '_buildBookCssEditorSection()'.allMatches(sheet).length;
    expect(wrapperCalls, greaterThanOrEqualTo(2),
        reason:
            'normal + lyrics layout sub-pages both route through the wrapper');
    final int bareRowSections =
        '<Widget>[_buildBookCssEditorRow()]'.allMatches(sheet).length;
    expect(bareRowSections, equals(1),
        reason: 'the CSS row is wrapped in a section exactly once');
  });
}
