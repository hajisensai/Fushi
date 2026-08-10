import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the BUG-1489 fix: the local video/book shelf first paint must stay fast.
///
/// Three regressions made the desktop「视频」/ 书架 pages take "half a day" to show
/// collections and covers, all on the LOCAL path (not interconnect/remote):
///   1. Collection grouping ran an N+1: `_loadLibraryMaps` / `_loadShelfMaps`
///      called `getCollectionItems(c.id)` once PER collection just to compute the
///      in-group sortIndex, gating the collection-row render on a serial chain.
///      The fix adds `getAllCollectionItems()` (one query) + in-memory grouping.
///   2. Local covers decoded at native resolution: `Image.file` / `FileImage`
///      with no `cacheWidth`/`ResizeImage`. A 1080p/4K frame (or a 1600×2400 EPUB
///      cover) decoded whole into the 100MB ImageCache → LRU thrash + jank. The fix
///      routes every local cover through `resizedFileImage` / `cacheWidth`.
/// (A third avenue — making `_repairMovedCoverPaths`' full-library stat async —
/// was dropped: it regressed widget tests that pumpAndSettle through the shelf
/// refresh path, and its win was marginal vs the two above. Per-card `existsSync`
/// short-circuits are kept intentionally to avoid decoding known-missing files.)
///
/// Source-level guard is the strongest landing layer: these live on private methods
/// of ~7300-line page states that cannot be stood up in a widget test without a
/// controller + DB + real files. The DB equivalence of `getAllCollectionItems` is
/// covered behaviorally in `test/database/media_collections_dao_test.dart`.
void main() {
  final String coverImageSrc =
      File('lib/src/utils/cover_image.dart').readAsStringSync();
  final String dbSrc =
      File('../packages/fushi_core/lib/src/database/database.dart')
          .readAsStringSync();
  final String videoPageSrc =
      File('lib/src/pages/implementations/home_video_page.dart')
          .readAsStringSync();
  final String historyPageSrc =
      File('lib/src/pages/implementations/reader_fushi_history_page.dart')
          .readAsStringSync();
  final String mediaSourceSrc =
      File('lib/src/media/media_source.dart').readAsStringSync();
  final String cardWidgetsSrc = File(
          'lib/src/pages/implementations/reader_history/card_widgets.part.dart')
      .readAsStringSync();
  final String remotePartSrc =
      File('lib/src/pages/implementations/reader_history/remote.part.dart')
          .readAsStringSync();
  final String miniBarSrc =
      File('lib/src/media/audiobook/now_listening_mini_bar.dart')
          .readAsStringSync();

  /// Extracts a method body from `source` starting at `signatureNeedle`, up to the
  /// next top-level (2-space-indented) member declaration.
  String methodBody(String source, String signatureNeedle) {
    final int start = source.indexOf(signatureNeedle);
    expect(start, greaterThanOrEqualTo(0),
        reason: 'Method "$signatureNeedle" must exist.');
    final RegExp nextMember = RegExp(
      r'\n  (Future|void|Widget|String|bool|List|int|Map)\b',
    );
    final Match? next =
        nextMember.firstMatch(source.substring(start + signatureNeedle.length));
    final int end = next == null
        ? source.length
        : start + signatureNeedle.length + next.start;
    return source.substring(start, end);
  }

  group('BUG-1489 · 降采样 helper', () {
    test('cover_image.dart 定义解码上限常量与 resizedFileImage', () {
      expect(coverImageSrc.contains('const int kLocalCoverDecodePixelWidth'),
          isTrue);
      expect(coverImageSrc.contains('const int kMiniCoverDecodePixelWidth'),
          isTrue);
      expect(coverImageSrc.contains('ImageProvider resizedFileImage('), isTrue);
      // 必须真正降采样（ResizeImage）且不放大。
      expect(coverImageSrc.contains('ResizeImage(FileImage'), isTrue);
      expect(coverImageSrc.contains('allowUpscaling: false'), isTrue);
    });
  });

  group('BUG-1489 · 合集 N+1 收敛为单查询', () {
    test('database.dart 提供 getAllCollectionItems 批量查询', () {
      expect(
          dbSrc.contains(
              'Future<List<MediaCollectionItemRow>> getAllCollectionItems()'),
          isTrue);
    });

    test('_loadLibraryMaps 用 getAllCollectionItems，不再逐合集 getCollectionItems',
        () {
      final String body =
          methodBody(videoPageSrc, 'Future<void> _loadLibraryMaps() async {');
      expect(body.contains('getAllCollectionItems()'), isTrue,
          reason: '视频页合集分组必须一次查全部成员，否则合集行渲染被 N+1 gate（BUG-1489）。');
      expect(body.contains('getCollectionItems('), isFalse,
          reason: '不得再逐合集查询（N+1）。');
    });

    test('_loadShelfMaps 用 getAllCollectionItems，不再逐合集 getCollectionItems', () {
      final String body =
          methodBody(historyPageSrc, 'Future<void> _loadShelfMaps() async {');
      expect(body.contains('getAllCollectionItems()'), isTrue,
          reason: '书架页合集分组必须一次查全部成员（BUG-1489）。');
      expect(body.contains('getCollectionItems('), isFalse,
          reason: '不得再逐合集查询（N+1）。');
    });
  });

  group('BUG-1489 · 本地封面降采样', () {
    test('视频 _buildCover 按上限解码降采样', () {
      final String body = methodBody(videoPageSrc, 'Widget _buildCover(');
      expect(body.contains('cacheWidth: kLocalCoverDecodePixelWidth'), isTrue,
          reason: '视频封面必须降采样，否则原生分辨率整帧撑爆 ImageCache（BUG-1489）。');
    });

    test('书籍封面 provider 走 resizedFileImage（media_source / 卡片 / 已下载书）', () {
      expect(mediaSourceSrc.contains('resizedFileImage('), isTrue);
      expect(cardWidgetsSrc.contains('resizedFileImage('), isTrue);
      expect(remotePartSrc.contains('resizedFileImage('), isTrue);
    });

    test('有声书迷你条封面降采样', () {
      final String body = methodBody(miniBarSrc, 'Widget _cover(');
      expect(body.contains('cacheWidth: kMiniCoverDecodePixelWidth'), isTrue);
    });
  });
}
