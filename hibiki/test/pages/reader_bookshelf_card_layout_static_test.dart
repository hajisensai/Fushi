import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bookshelf cards render the title below the cover, not as an overlay',
      () {
    final String source =
        File('lib/src/pages/implementations/reader_hibiki_history_page.dart')
            .readAsStringSync();

    expect(
      source,
      isNot(contains('Widget _titleOverlay(String title)')),
      reason: 'book titles must no longer draw inside the cover artwork',
    );
    expect(
      source,
      contains('Widget _bookCardFooter(String title)'),
      reason: 'the title must live in a stable below-cover footer',
    );
    final String layout = _functionSource(source, 'Widget _bookCardLayout({');
    expect(
      layout,
      contains('Column('),
      reason: 'the shared card layout separates cover and title footer',
    );
    expect(
      layout,
      contains('height: kShelfTitleFooterHeight'),
      reason: 'the footer height must stay stable across long titles',
    );
    expect(
      layout,
      contains('_bookCardFooter(title)'),
      reason: 'the title footer must render below the cover stack',
    );
    expect(
      layout,
      isNot(contains('_titleOverlay(title)')),
      reason: 'the title must not be added to the cover stack',
    );
    expect(
      RegExp(r'(?:child:|return) _bookCardLayout\(').allMatches(source).length,
      greaterThanOrEqualTo(4),
      reason: 'all bookshelf card variants should share the overlay layout',
    );
  });

  test('card layout exposes title footer, tags, badge, and metadata', () {
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

    // The cover fills its stable region; badge/tags/progress overlay the cover,
    // while the title is rendered after the cover stack in the footer.
    expect(layout, contains('Stack('));
    expect(layout, contains('ClipRect(child: cover)'));
    expect(layout, isNot(contains('_titleOverlay(title)')));
    expect(layout, contains('_bookCardTagArea(tagLabels)'));
    final int coverStack = layout.indexOf('Stack(');
    final int titleFooter = layout.indexOf('_bookCardFooter(title)');
    expect(titleFooter, greaterThan(coverStack),
        reason: 'the title footer must be after the cover stack');

    // The progress metadata stays visible, pinned to the bottom of the cover.
    final int metadataPin = layout.indexOf('child: metadata,');
    expect(metadataPin, isNonNegative,
        reason: 'progress metadata must still render');
    final int bottomPin = layout.lastIndexOf('bottom: 0,', metadataPin);
    expect(bottomPin, isNonNegative,
        reason: 'metadata (progress bar) must be pinned to the cover bottom');
  });

  test('book cover artwork fills the card across all shelf sources', () {
    final String source =
        File('lib/src/pages/implementations/reader_hibiki_history_page.dart')
            .readAsStringSync();
    final String remoteCover =
        _functionSource(source, 'Widget _buildRemoteBookCover(');
    final String videoCover =
        _functionSource(source, 'Widget _buildVideoCover(');
    final String srtCover = _functionSource(source, 'Widget _buildSrtCover(');
    final String epubCover =
        _functionSource(source, 'Widget buildMediaItemContent(');

    expect(
      source,
      contains('BoxFit get _bookCardCoverFit => BoxFit.cover;'),
      reason: 'book card artwork should share a single cover-fill fit helper',
    );
    expect(
      source,
      isNot(contains('fit: BoxFit.fitHeight')),
      reason: 'fitHeight leaves horizontal gutters instead of filling the card',
    );
    expect(
      RegExp(r'fit: _bookCardCoverFit').allMatches(remoteCover).length,
      2,
      reason: 'remote cached and network covers must both fill the card',
    );
    expect(videoCover, contains('fit: _bookCardCoverFit'));
    expect(srtCover, contains('fit: _bookCardCoverFit'));
    expect(epubCover, contains('fit: _bookCardCoverFit'));
  });

  test('visual card frame wraps only the cover, while interactions wrap all',
      () {
    final String source =
        File('lib/src/pages/implementations/reader_hibiki_history_page.dart')
            .readAsStringSync();
    final String shell = _functionSource(source, 'Widget _bookCardShell({');
    final String layout = _functionSource(source, 'Widget _bookCardLayout({');

    expect(
      shell,
      isNot(contains('HibikiCard(')),
      reason:
          'the whole touch target may not draw the visual card around the footer',
    );
    expect(shell, contains('InkWell('),
        reason: 'tap/long-press/right-click must still cover the whole card');
    expect(
        shell, contains('onSecondaryTap: _selectionMode ? null : onLongPress'));
    expect(shell, contains('HibikiFocusTarget('),
        reason: 'keyboard/gamepad activation must stay on the full card');

    final int coverStack = layout.indexOf('Stack(');
    final int coverFrame = layout.indexOf('_bookCardCoverFrame(');
    final int footer = layout.indexOf('_bookCardFooter(title)');
    expect(coverStack, greaterThan(coverFrame),
        reason: 'the visual frame should wrap the cover stack');
    expect(coverFrame, lessThan(footer),
        reason: 'the title footer must remain outside the visual frame');
  });

  test('book card footer clamps long titles without resizing the grid', () {
    final String source =
        File('lib/src/pages/implementations/reader_hibiki_history_page.dart')
            .readAsStringSync();
    final String footer = _functionSource(source, 'Widget _bookCardFooter(');

    expect(source, contains('const double kShelfTitleFooterHeight ='));
    expect(footer, contains('HibikiDesignTokens.of(context)'));
    expect(footer, contains('maxLines: 2'));
    expect(footer, contains('overflow: TextOverflow.ellipsis'));
    expect(footer, contains('textAlign: TextAlign.center'));
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
