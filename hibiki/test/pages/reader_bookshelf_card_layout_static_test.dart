import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bookshelf cards use footer layout instead of title cover overlay', () {
    final String source =
        File('lib/src/pages/implementations/reader_hibiki_history_page.dart')
            .readAsStringSync();

    expect(
      source,
      isNot(contains('_titleOverlay(')),
      reason:
          'titles for local, SRT, video, and remote books must not overlay covers',
    );
    expect(
      source,
      isNot(contains('constraints.maxHeight * 0.38')),
      reason: 'the old bottom overlay occupied a large part of the cover',
    );
    expect(
      RegExp(r'(?:child:|return) _bookCardLayout\(').allMatches(source).length,
      greaterThanOrEqualTo(4),
      reason: 'all bookshelf card variants should share the footer layout',
    );
  });

  test(
      'book title row starts with title and does not reserve leading tag width',
      () {
    final String source =
        File('lib/src/pages/implementations/reader_hibiki_history_page.dart')
            .readAsStringSync();
    final String layout = _functionSource(source, 'Widget _bookCardLayout({');
    final String footer = _functionSource(source, 'Widget _bookCardFooter({');

    expect(layout, contains('Widget? tagLabels'));
    expect(layout, contains('Widget? coverBadge'));
    expect(layout, isNot(contains('Widget? leading')));
    expect(layout, isNot(contains('Widget? trailing')));
    expect(source, isNot(contains('leading: tagWidget')));

    final int titleText = footer.indexOf('Text(\n                    title,');
    final int tagArea = footer.indexOf('_bookCardTagArea(tagLabels)');
    expect(titleText, isNonNegative, reason: 'title must be rendered directly');
    expect(tagArea, greaterThan(titleText),
        reason: 'tags must render after the title area, not as title leading');

    final RegExp titleFirstRow = RegExp(
      r'Row\([\s\S]*?children:\s*\[[\s\S]*?Expanded\([\s\S]*?Text\(\s*title,',
      multiLine: true,
    );
    expect(titleFirstRow.hasMatch(footer), isTrue,
        reason: 'the first semantic child in the title row must be the title');
  });

  test('book type badge is pinned to the top-right corner of the cover', () {
    final String source =
        File('lib/src/pages/implementations/reader_hibiki_history_page.dart')
            .readAsStringSync();
    final String layout = _functionSource(source, 'Widget _bookCardLayout({');

    // The badge must sit at the trailing top corner, not the bottom.
    expect(
      layout,
      contains('PositionedDirectional('),
      reason: 'the badge must be positioned within the cover stack',
    );
    expect(
      layout,
      contains('top: tokens.spacing.gap * 0.75'),
      reason: 'the type badge must be pinned to the top of the cover',
    );
    expect(
      layout,
      isNot(contains('bottom: tokens.spacing.gap * 0.75')),
      reason: 'the type badge must not sit at the bottom of the cover',
    );

    // The single PositionedDirectional drives all card variants' badge spot.
    expect(
      RegExp(r'PositionedDirectional\(').allMatches(layout).length,
      equals(1),
      reason: 'badge placement must stay centralized in one layout helper',
    );
  });

  test('long or multiple book tags are clipped in their own footer area', () {
    final String source =
        File('lib/src/pages/implementations/reader_hibiki_history_page.dart')
            .readAsStringSync();
    final String tagArea = _functionSource(source, 'Widget _bookCardTagArea(');

    expect(tagArea, contains('ConstrainedBox('));
    expect(tagArea, contains('maxHeight: tokens.spacing.gap * 3.5'));
    expect(tagArea, contains('ClipRect(child: tagLabels)'));
  });
}

String _functionSource(String source, String startToken) {
  final int start = source.indexOf(startToken);
  expect(start, isNonNegative, reason: 'missing $startToken');
  final RegExp nextWidget = RegExp(r'\n  Widget [_A-Za-z0-9]+\(');
  final RegExpMatch? next = nextWidget.firstMatch(
    source.substring(start + startToken.length),
  );
  final int end =
      next == null ? source.length : start + startToken.length + next.start + 1;
  return source.substring(start, end);
}
