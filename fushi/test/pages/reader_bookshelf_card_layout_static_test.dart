import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'reader_history_source_corpus.dart';

void main() {
  // 2026-10-25 库页定版（用户：「全部都不用角标设计」）：封面上不压任何角标，
  // 类型 / 对齐状态 / 远端 / 下载 / 标签 / 进度全部进封面下的 ShelfCardMeta。
  test('bookshelf cards put title + subtitle + progress below the cover', () {
    final String source = readReaderHistorySource();
    final String layout = _functionSource(source, 'Widget _bookCardLayout({');

    expect(
      source,
      isNot(contains('Widget _titleOverlay(String title)')),
      reason: 'book titles must no longer draw inside the cover artwork',
    );
    expect(layout, contains('Column('));
    expect(
      layout,
      contains('ShelfCardMeta('),
      reason: 'the shared below-cover text block carries title + subtitle',
    );
    expect(
      layout,
      contains('height: ShelfCardMeta.heightFor(context)'),
      reason:
          'the text block height follows the text scale, never the title '
          'length (BUG-1184 intent)',
    );
    final int coverFrame = layout.indexOf('_bookCardCoverFrame(');
    final int meta = layout.indexOf('ShelfCardMeta.heightFor(context)');
    expect(coverFrame, isNonNegative);
    expect(
      meta,
      greaterThan(coverFrame),
      reason: 'the text block must sit below (outside) the cover frame',
    );
    expect(
      RegExp(r'(?:child:|return) _bookCardLayout\(').allMatches(source).length,
      greaterThanOrEqualTo(4),
      reason: 'all bookshelf card variants should share the same layout',
    );
  });

  test('no badge slots remain on the shelf cover', () {
    final String source = readReaderHistorySource();
    final String layout = _functionSource(source, 'Widget _bookCardLayout({');

    for (final String banned in <String>[
      'Widget? coverBadge',
      'Widget? leadingBadge',
      'Widget? tagLabels',
      'Widget? metadata',
      '_bookCardTagArea',
      'CoverProgressStrip(',
    ]) {
      expect(
        layout,
        isNot(contains(banned)),
        reason: '$banned put information on top of the cover',
      );
    }
    for (final String banned in <String>[
      'Widget _cardBadge(',
      'Widget _audiobookBadge(',
      'Widget _remoteCloudBadge(',
      'Widget _buildRemoteBookTypeBadge(',
      'kShelfCoverBadgeDimension',
      'CoverBadge(',
      'FushiTagChip(',
    ]) {
      expect(
        source,
        isNot(contains(banned)),
        reason: '$banned is a cover badge; the info belongs in the subtitle',
      );
    }
    // 封面上只剩导入 / 下载中的居中加载遮罩。
    expect(
      layout,
      contains('Positioned.fill(child: Center(child: loadingOverlay))'),
    );
  });

  test('book cover artwork scales by height (no distortion) across all shelf '
      'sources (TODO-552)', () {
    final String source = readReaderHistorySource();
    final String remoteCover = _functionSource(
      source,
      'Widget _buildRemoteBookCover(',
    );
    final String srtCover = _functionSource(source, 'Widget _buildSrtCover(');
    final String fileCover = _functionSource(source, 'Widget _buildFileCover(');
    final String epubCover = _functionSource(
      source,
      'Widget buildMediaItemContent(',
    );

    expect(
      source,
      contains('BoxFit get _bookCardCoverFit => BoxFit.fitHeight;'),
      reason:
          'book card artwork must scale by height to keep aspect ratio; '
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
    final String body = _functionSource(
      source,
      'Widget _buildBodyWithSrtBooks(',
    );
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

  test('visual card frame wraps only the cover, while interactions wrap all', () {
    final String source = readReaderHistorySource();
    final String shell = _functionSource(source, 'Widget _bookCardShell({');
    final String layout = _functionSource(source, 'Widget _bookCardLayout({');

    expect(
      shell,
      isNot(contains('FushiCard(')),
      reason:
          'the whole touch target may not draw the visual card around the footer',
    );
    expect(
      shell,
      contains('InkWell('),
      reason: 'tap/long-press/right-click must still cover the whole card',
    );
    expect(
      shell,
      contains(
        'onInvoke: contextMenuInvoker(_selectionMode ? null : onLongPress)',
      ),
    );
    expect(
      shell,
      contains('FushiFocusTarget('),
      reason: 'keyboard/gamepad activation must stay on the full card',
    );

    final int coverStack = layout.indexOf('Stack(');
    final int coverFrame = layout.indexOf('_bookCardCoverFrame(');
    final int footer = layout.indexOf('ShelfCardMeta.heightFor(context)');
    expect(
      coverStack,
      greaterThan(coverFrame),
      reason: 'the visual frame should wrap the cover stack',
    );
    expect(
      coverFrame,
      lessThan(footer),
      reason: 'the title footer must remain outside the visual frame',
    );
  });

  test('shelf book card slot uses the narrow book cover ratio (TODO-786)', () {
    final String source = readReaderHistorySource();

    // ① 书类卡槽比例常量必须存在（窄，接近书封比例）。
    expect(
      source,
      contains('const double kShelfBookCardAspectRatio = 180 / 302;'),
      reason:
          'book/audiobook/SRT/remote cards keep a ~1:1.42 cover above the '
          'ShelfCardMeta text block (2026-10-25), so fitHeight fills the slot '
          'without side white (TODO-786)',
    );

    // ② 书架不再渲染视频卡/分区（视频归「视频」tab 独占，书架视频分区死路径已删）。
    //    kShelfVideoCardAspectRatio 常量随之删除（零代码引用，孤儿清理）。
    expect(
      source,
      isNot(contains('kShelfVideoCardAspectRatio')),
      reason:
          'the orphaned video slot ratio constant must stay deleted; the '
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
      reason:
          'the reader media source default ratio must use the book ratio '
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
      reason:
          'TODO-786 must reference TODO-552: 552 keeps the cover '
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
}

String _functionSource(String source, String startToken) {
  final int start = source.indexOf(startToken);
  expect(start, isNonNegative, reason: 'missing $startToken');
  final RegExp nextWidget = RegExp(r'\n  Widget [_A-Za-z0-9]+\(');
  final RegExpMatch? next = nextWidget.firstMatch(
    source.substring(start + startToken.length),
  );
  final int end = next == null
      ? source.length
      : start + startToken.length + next.start + 1;
  return source.substring(start, end);
}
