import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 书 / 漫画「导入」视图（导入稿 v2）接线守卫。
///
/// - BUG-4859（IM2）：导入视图画着拖放虚线与悬停态，祖先链上却没有
///   `FushiFileDropTarget`；书架 / 漫画库的落点又被壳的 `DropSurfaceScope` 关在
///   隐藏视图里，拖进来什么都不发生。现在两页的 spec 都给 `onDrop`，骨架据此整页包
///   落点，落下走与书架同一份 `routeReaderShelfDrop`（不另写分发）。
/// - IM4 / IM5：漫画互联浏览入口挪进互联块，「在线源」区标题删掉（入口保留）。
/// - IM15 / IM17：书多一个「有声书」方式块；两页来源区末尾有「连接服务器 ›」。
///
/// 为什么用源码扫描：两页都从 `appProvider` 拿整个 `AppModel`，挂起来测的是环境
/// 不是接线；落点在桌面 OS 拖放下才触发，headless 也模拟不了 desktop_drop 的全局
/// 广播。读源码并掩掉注释，防「实现删光、注释里留字面量」的假绿。
String _read(String path) => maskComments(File(path).readAsStringSync());

String _body(String source, String start, String end) {
  final int s = source.indexOf(start);
  expect(s, isNonNegative, reason: 'missing $start');
  final int e = source.indexOf(end, s + start.length);
  expect(e, greaterThan(s), reason: 'missing $end after $start');
  return source.substring(s, e);
}

void main() {
  final String book = _read(
    'lib/src/pages/implementations/book_import_page.dart',
  );
  final String manga = _read('lib/src/media/manga/manga_sources_page.dart');
  final String collage = _read('lib/src/media/import/import_collage_page.dart');
  final String router = _read(
    'lib/src/media/drag_drop/reader_shelf_drop_router.dart',
  );

  group('BUG-4859：书 / 漫画导入视图整页是落点，走书架同一份分发', () {
    for (final (String name, String source, String mangaOnly)
        in <(String, String, String)>[
          ('book', book, 'mangaOnly: false'),
          ('manga', manga, 'mangaOnly: true'),
        ]) {
      test('$name 导入页的 spec 给了 onDrop，落下交给 routeReaderShelfDrop', () {
        expect(source, contains('onDrop: _handleDrop'));
        final String drop = _body(
          source,
          'Future<void> _handleDrop(',
          'ImportSurfaceSpec _buildSpec()',
        );
        expect(drop, contains('routeReaderShelfDrop('));
        expect(drop, contains(mangaOnly));
        expect(
          drop,
          isNot(contains('hitTestCard')),
          reason: '导入视图没有书卡，音频单独拖入要给「拖到某本书上」的提示',
        );
        expect(
          source,
          isNot(contains('decideDropIntent(')),
          reason: '不另写分发：两条入口对同一批文件给同一个结果',
        );
      });
    }

    test('骨架在 spec.onDrop 非空时整页包 FushiFileDropTarget', () {
      final String build = _body(
        collage,
        'Widget build(BuildContext context) {',
        'class _ImportCollageBody',
      );
      expect(build, contains('spec.onDrop'));
      expect(build, contains('FushiFileDropTarget('));
      expect(build, contains('onDrop: onDrop'));
    });

    test('书架落点只把参数交给同一份分发', () {
      final String shelf = _read(
        'lib/src/pages/implementations/reader_history/books.part.dart',
      );
      final String drop = _body(
        shelf,
        'Future<void> _handleShelfDrop(',
        'routeReaderShelfDrop(',
      );
      expect(drop, contains('Offset globalPosition'));
      expect(shelf, contains('hitTestCard: _cardDropRegistry.hitTest,'));
      expect(shelf, isNot(contains('decideDropIntent(')));
      expect(router, contains('decideDropIntent('));
      expect(
        router,
        contains('if (route != null && !route.isCurrent) return;'),
      );
    });
  });

  group('IM4 / IM5：漫画互联浏览入口挪进互联块', () {
    test('浏览入口还在，只是住进来源区的互联块', () {
      expect(manga, contains('onBrowseInterconnect: _browseInterconnect'));
      expect(manga, contains('InterconnectMangaBrowsePage('));
      expect(manga, contains('t.import_interconnect_browse_manga'));
      expect(manga, contains('t.import_interconnect_browse_disabled_hint'));
    });

    test('「在线源」区标题与旧互联行已删', () {
      expect(manga, isNot(contains('t.media_import_segment_sources')));
      expect(manga, isNot(contains('InterconnectMangaSourceRow')));
      expect(
        File(
          'lib/src/media/manga/interconnect/interconnect_manga_source_row.dart',
        ).existsSync(),
        isFalse,
      );
    });
  });

  group('IM15 / IM17', () {
    test('书有「有声书」方式块：同一个导入书对话框，先选音频', () {
      expect(book, contains('ImportMethodKind.audiobook'));
      expect(book, contains('_importBook(pickAudioFirst: true)'));
      expect(
        _read('lib/src/media/audiobook/book_import_dialog.dart'),
        contains('if (widget.pickAudioFirst)'),
      );
    });

    test('书 / 漫画来源区末尾有「连接服务器 ›」，跳设置 › 服务', () {
      for (final String source in <String>[book, manga]) {
        expect(
          source,
          contains('onConnectServer: () => openMediaServerSettings(context)'),
        );
      }
    });

    test('方式按规范顺序声明（主方式 → 文件夹 → 其他 → 网络）', () {
      final List<String> bookOrder = <String>[
        'ImportMethodKind.primary',
        'ImportMethodKind.folder',
        'ImportMethodKind.pasteText',
        'ImportMethodKind.audiobook',
        'ImportMethodKind.network',
      ];
      int at = -1;
      for (final String kind in bookOrder) {
        final int next = book.indexOf(kind, at + 1);
        expect(next, greaterThan(at), reason: '$kind 顺序不对');
        at = next;
      }
      at = -1;
      for (final String kind in <String>[
        'ImportMethodKind.primary',
        'ImportMethodKind.folder',
        'ImportMethodKind.network',
      ]) {
        final int next = manga.indexOf(kind, at + 1);
        expect(next, greaterThan(at), reason: '$kind 顺序不对');
        at = next;
      }
    });
  });
}
