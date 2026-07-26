import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'reader_history_source_corpus.dart';

void main() {
  test('bookshelf cards render the title below the cover, not as an overlay',
      () {
    final String source = readReaderHistorySource();

    expect(
      source,
      isNot(contains('Widget _titleOverlay(String title)')),
      reason: 'book titles must no longer draw inside the cover artwork',
    );
    // 巡检 PR-3：footer 实现提取到共享组件 ShelfCardFooter（书卡与
    // SeriesShelfCard 共用，消除逐行手抄），书架侧守卫改锁「layout 消费共享
    // footer」；footer 本体的排版守卫移到下方对共享文件的断言。
    expect(
      source,
      contains('ShelfCardFooter(title: title)'),
      reason: 'the title must live in the shared below-cover footer component',
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
      contains('ShelfCardFooter(title: title)'),
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
    final String source = readReaderHistorySource();
    final String layout = _functionSource(source, 'Widget _bookCardLayout({');

    // Signature stays footer-era compatible so the four call sites need no edit.
    expect(layout, contains('Widget? tagLabels'));
    expect(layout, contains('Widget? coverBadge'));
    expect(layout, contains('Widget? metadata'));
    // TODO-655a: remote cards add a top-left `leadingBadge` type-badge slot
    // (download button keeps the top-right `coverBadge`). The forbidden API is
    // still the generic bare `leading`/`trailing` slot, not `leadingBadge`.
    expect(layout, contains('Widget? leadingBadge'));
    expect(layout, isNot(contains('Widget? leading,')));
    expect(layout, isNot(contains('Widget? trailing')));
    expect(source, isNot(contains('leading: tagWidget')));

    // The cover fills its stable region; badge/tags/progress overlay the cover,
    // while the title is rendered after the cover stack in the footer.
    expect(layout, contains('Stack('));
    expect(layout, contains('ClipRect(child: cover)'));
    expect(layout, isNot(contains('_titleOverlay(title)')));
    expect(layout, contains('_bookCardTagArea(tagLabels)'));
    final int coverStack = layout.indexOf('Stack(');
    final int titleFooter = layout.indexOf('ShelfCardFooter(title: title)');
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

  test(
      'book cover artwork scales by height (no distortion) across all shelf '
      'sources (TODO-552)', () {
    final String source = readReaderHistorySource();
    final String remoteCover =
        _functionSource(source, 'Widget _buildRemoteBookCover(');
    final String srtCover = _functionSource(source, 'Widget _buildSrtCover(');
    final String fileCover = _functionSource(source, 'Widget _buildFileCover(');
    final String epubCover =
        _functionSource(source, 'Widget buildMediaItemContent(');

    expect(
      source,
      contains('BoxFit get _bookCardCoverFit => BoxFit.fitHeight;'),
      reason: 'book card artwork must scale by height to keep aspect ratio; '
          'BoxFit.cover crops and distorts the cover (TODO-552)',
    );
    expect(
      source,
      isNot(contains('BoxFit get _bookCardCoverFit => BoxFit.cover;')),
      reason: 'BoxFit.cover distorts/crops the cover under the footer layout',
    );
    expect(
      RegExp(r'fit: _bookCardCoverFit').allMatches(remoteCover).length,
      2,
      reason: 'remote cached and network covers must both fill the card',
    );
    expect(srtCover, contains('_buildFileCover'));
    expect(fileCover, contains('fit: _bookCardCoverFit'));
    expect(epubCover, contains('fit: _bookCardCoverFit'));
  });

  test('linked SRT cards fall back to the EPUB cover before placeholder', () {
    final String source = readReaderHistorySource();
    final String body =
        _functionSource(source, 'Widget _buildBodyWithSrtBooks(');
    final String srtCard = _functionSource(source, 'Widget _buildSrtCard(');
    final String srtCover = _functionSource(source, 'Widget _buildSrtCover(');

    expect(
      body,
      contains('epubCoverUrisByBookKey'),
      reason:
          'SRT entries with bookKey replace their EPUB card, so the pre-filter '
          'EPUB cover map must survive for fallback rendering.',
    );
    expect(
      srtCard,
      contains('epubCoverUri'),
      reason: 'the linked EPUB cover URI must be passed into the SRT card',
    );
    expect(
      srtCover,
      contains('book.bookKey'),
      reason:
          'standalone SRT keeps its own cover, linked SRT must inspect bookKey',
    );
    expect(
      srtCover,
      contains('_buildCoverFromUri'),
      reason: 'linked SRT fallback should reuse the EPUB cover URI provider',
    );
  });

  test('visual card frame wraps only the cover, while interactions wrap all',
      () {
    final String source = readReaderHistorySource();
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
    final int footer = layout.indexOf('ShelfCardFooter(title: title)');
    expect(coverStack, greaterThan(coverFrame),
        reason: 'the visual frame should wrap the cover stack');
    expect(coverFrame, lessThan(footer),
        reason: 'the title footer must remain outside the visual frame');
  });

  test('book card footer clamps long titles without resizing the grid', () {
    final String source = readReaderHistorySource();
    // 巡检 PR-3：footer 实现活在共享组件文件（ShelfCardFooter），排版守卫跟随。
    final String shared = File(
      'lib/src/utils/components/shelf_card_widgets.dart',
    ).readAsStringSync();
    final String footer = _sectionSource(
      shared,
      'class ShelfCardFooter extends StatelessWidget',
      'class ShelfSelectionCheck',
    );

    expect(source, contains('const double kShelfTitleFooterHeight ='));
    expect(footer, contains('HibikiDesignTokens.of(context)'));
    expect(footer, contains('maxLines: 2'));
    expect(footer, contains('overflow: TextOverflow.ellipsis'));
    expect(footer, contains('textAlign: TextAlign.center'));
  });

  test('book type badge is pinned to the top-right corner of the cover', () {
    final String source = readReaderHistorySource();
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

  test('cover type badge renders at its normal intrinsic size (TODO-552)', () {
    final String source = readReaderHistorySource();
    final String layout = _functionSource(source, 'Widget _bookCardLayout({');

    // The badge box equals the badge intrinsic size (22px). With BoxFit.contain
    // the 22px HibikiBadge is neither enlarged nor shrunk, so it renders at its
    // normal size. TODO-361 had wrongly shrunk it to 16px ("too small").
    expect(
      layout,
      contains('dimension: kShelfCoverBadgeDimension'),
      reason: 'the cover badge must use the centralized badge dimension',
    );
    expect(
      layout,
      contains('fit: BoxFit.contain'),
      reason: 'the badge fits its same-size box without distortion',
    );
    expect(
      layout,
      isNot(contains('dimension: tokens.spacing.gap * 5')),
      reason: 'the oversized gap*5 cover badge box must stay gone',
    );

    // The constant must equal the badge intrinsic size (22px) so BoxFit.contain
    // renders it at full, normal size (not shrunk down to 16px).
    expect(
      source,
      contains('const double kShelfCoverBadgeDimension = 22.0;'),
      reason: 'the cover badge dimension must be the normal 22px badge size',
    );
    expect(
      source,
      isNot(contains('const double kShelfCoverBadgeDimension = 8.0 * 2;')),
      reason: 'the shrunk 16px badge dimension must be gone (TODO-552)',
    );
  });

  test('shelf book card slot uses the narrow book cover ratio (TODO-786)', () {
    final String source = readReaderHistorySource();

    // ① 书类卡槽比例常量必须存在（窄，接近书封比例）。
    expect(
      source,
      contains('const double kShelfBookCardAspectRatio = 160 / 260;'),
      reason: 'TODO-786: book/audiobook/SRT/remote cards must use the narrow '
          'book cover ratio so fitHeight fills the slot without side white',
    );

    // ② 书架不再渲染视频卡/分区（视频归「视频」tab 独占，书架视频分区死路径已删）。
    //    kShelfVideoCardAspectRatio 常量随之删除（零代码引用，孤儿清理）。
    expect(
      source,
      isNot(contains('kShelfVideoCardAspectRatio')),
      reason: 'the orphaned video slot ratio constant must stay deleted; the '
          'video tab owns its own card geometry',
    );

    // 书类卡壳与三处书类 grid delegate（SRT × 2 + EPUB + remote）走书比例：
    // slotAspectRatio: kShelfBookCardAspectRatio 与 childAspectRatio:
    // kShelfBookCardAspectRatio 合计应出现多次。
    expect(
      'kShelfBookCardAspectRatio'.allMatches(source).length,
      greaterThanOrEqualTo(4),
      reason: 'book ratio must drive the book/SRT/remote card shells and grids',
    );

    // ③ reader_media_source.dart 不再含 176 / 250 字面量（改成了书比例常量）。
    final String mediaSource = File(
      'lib/src/media/sources/reader_media_source.dart',
    ).readAsStringSync();
    expect(
      mediaSource,
      isNot(contains('176 / 250')),
      reason: 'the reader media source default ratio must use the book ratio '
          'constant, not the old 176/250 literal (TODO-786)',
    );
    expect(
      mediaSource,
      contains('double get aspectRatio => kShelfBookCardAspectRatio;'),
      reason: 'the reader media source must default to the book cover ratio',
    );

    // ④ 注释钉死 TODO-786 是 TODO-552「不裁切」的延续，同向非回退。
    expect(
      source,
      contains('TODO-786'),
      reason: 'the ratio change must be attributed to TODO-786 in comments',
    );
    expect(
      source,
      contains('TODO-552'),
      reason: 'TODO-786 must reference TODO-552: 552 keeps the cover '
          'undistorted (fitHeight), 786 removes the side white — same '
          'direction, not a regression',
    );
    // 仍保持 fitHeight 与 cover 禁令（不与既有守卫冲突，这里再点一次方向）。
    expect(
      source,
      contains('BoxFit get _bookCardCoverFit => BoxFit.fitHeight;'),
      reason: 'TODO-786 narrows the slot but must NOT switch to BoxFit.cover',
    );
  });

  test('long or multiple book tags are clipped in their own overlay area', () {
    final String source = readReaderHistorySource();
    final String tagArea = _functionSource(source, 'Widget _bookCardTagArea(');

    expect(tagArea, contains('ConstrainedBox('));
    expect(tagArea, contains('maxHeight: tokens.spacing.gap * 3.5'));
    expect(tagArea, contains('ClipRect(child: tagLabels)'));
  });
}

/// 从 [source] 里切 [startToken]（含）到 [endToken]（不含）的片段。
String _sectionSource(String source, String startToken, String endToken) {
  final int start = source.indexOf(startToken);
  expect(start, isNonNegative, reason: 'missing $startToken');
  final int end = source.indexOf(endToken, start);
  expect(end, greaterThan(start), reason: 'missing $endToken');
  return source.substring(start, end);
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
