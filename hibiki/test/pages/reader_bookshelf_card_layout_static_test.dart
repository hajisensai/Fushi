import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bookshelf cards render the title as a cover overlay, not a footer', () {
    final String source =
        File('lib/src/pages/implementations/reader_hibiki_history_page.dart')
            .readAsStringSync();

    // Titles are pressed back onto the cover (bottom gradient scrim) instead of
    // a separate footer band below the cover.
    expect(
      source,
      contains('Widget _titleOverlay(String title)'),
      reason: 'local, SRT, video, and remote book titles overlay the cover',
    );
    expect(
      source,
      isNot(contains('Widget _bookCardFooter(')),
      reason: 'the below-cover title footer must be gone after the revert',
    );
    final String layout = _functionSource(source, 'Widget _bookCardLayout({');
    expect(
      layout,
      contains('_titleOverlay(title)'),
      reason: 'the shared card layout draws the title overlay on the cover',
    );
    expect(
      RegExp(r'(?:child:|return) _bookCardLayout\(').allMatches(source).length,
      greaterThanOrEqualTo(4),
      reason: 'all bookshelf card variants should share the overlay layout',
    );
  });

  test('card layout exposes title, tags, badge, and metadata over the cover',
      () {
    final String source =
        File('lib/src/pages/implementations/reader_hibiki_history_page.dart')
            .readAsStringSync();
    final String layout = _functionSource(source, 'Widget _bookCardLayout({');

    // Signature stays footer-era compatible so the four call sites need no edit.
    expect(layout, contains('Widget? tagLabels'));
    expect(layout, contains('Widget? coverBadge'));
    expect(layout, contains('Widget? metadata'));
    expect(layout, isNot(contains('Widget? leading')));
    expect(layout, isNot(contains('Widget? trailing')));
    expect(source, isNot(contains('leading: tagWidget')));

    // The cover fills the whole card; title/badge/tags/progress all overlay it.
    expect(layout, contains('Stack('));
    expect(layout, contains('ClipRect(child: cover)'));
    expect(layout, contains('_titleOverlay(title)'));
    expect(layout, contains('_bookCardTagArea(tagLabels)'));

    // The progress metadata stays visible, pinned to the bottom of the cover.
    final int metadataPin = layout.indexOf('child: metadata,');
    expect(metadataPin, isNonNegative,
        reason: 'progress metadata must still render');
    final int bottomPin = layout.lastIndexOf('bottom: 0,', metadataPin);
    expect(bottomPin, isNonNegative,
        reason: 'metadata (progress bar) must be pinned to the cover bottom');
  });

  test('book type badge is pinned to the top-right corner of the cover', () {
    final String source =
        File('lib/src/pages/implementations/reader_hibiki_history_page.dart')
            .readAsStringSync();
    final String layout = _functionSource(source, 'Widget _bookCardLayout({');

    // The badge must sit at the trailing top corner, not the bottom (TODO-284).
    expect(
      layout,
      contains('PositionedDirectional('),
      reason: 'the badge must be positioned within the cover stack',
    );
    expect(
      layout,
      contains('top: overlayInset,'),
      reason: 'the type badge must be pinned to the top of the cover',
    );

    // The badge PositionedDirectional carries the coverBadge child.
    final int badgeAnchor = layout.indexOf('child: coverBadge,');
    expect(badgeAnchor, isNonNegative,
        reason: 'the cover badge must render in the top-right slot');
  });

  test(
      'cover type badge is shrunk to the restored small-corner size (TODO-361)',
      () {
    final String source =
        File('lib/src/pages/implementations/reader_hibiki_history_page.dart')
            .readAsStringSync();
    final String layout = _functionSource(source, 'Widget _bookCardLayout({');

    // The badge box is the centralized small-corner dimension, scaled with
    // BoxFit.contain so the 22px HibikiBadge is shrunk down (not left at full
    // size like the old gap*5 + scaleDown box did on the cover art).
    expect(
      layout,
      contains('dimension: kShelfCoverBadgeDimension'),
      reason: 'the cover badge must use the centralized small-corner dimension',
    );
    expect(
      layout,
      contains('fit: BoxFit.contain'),
      reason: 'BoxFit.contain shrinks the badge into the small box; '
          'BoxFit.scaleDown would leave the 22px badge at full size',
    );
    expect(
      layout,
      isNot(contains('dimension: tokens.spacing.gap * 5')),
      reason: 'the oversized gap*5 cover badge box must be gone',
    );

    // The constant must stay smaller than the badge intrinsic size (22px),
    // otherwise BoxFit.contain would not shrink anything.
    expect(
      source,
      contains('const double kShelfCoverBadgeDimension = 8.0 * 2;'),
      reason: 'the cover badge dimension must be the restored 16px small size',
    );
  });

  test('long or multiple book tags are clipped in their own overlay area', () {
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
