import 'dart:io';

import 'package:test/test.dart';
import 'reader_history_source_corpus.dart';

/// TODO-558 / BUG-326 源码守卫：书架（books 表面）拖入视频/播放列表时，必须**自动切到
/// 视频导入流程**并带上拖入文件（`openVideoImport` → [VideoImportDialog] 预填路径），
/// 而不是回退到只弹 SnackBar 提示「请切到视频页面」让用户手动重选。headless 测不到
/// 真实拖放命中几何，故在源码层钉死接线防回归。
///
/// 分发本体在 `routeReaderShelfDrop`（书架、漫画库与书 / 漫画导入视图共用，IM2）；
/// 书架的 `_handleShelfDrop` 只把参数交过去。决策纯函数（books 表面视频→
/// importNewVideo / importNewPlaylist）由 drop_decision_test.dart 覆盖。
void main() {
  final String routerSrc = File(
    'lib/src/media/drag_drop/reader_shelf_drop_router.dart',
  ).readAsStringSync();

  String caseBlock(String label) {
    final int start = routerSrc.indexOf('case DropIntent.$label:');
    expect(start, greaterThan(-1), reason: '$label case must be handled');
    final int next = routerSrc.indexOf('case DropIntent.', start + 1);
    expect(next, greaterThan(start));
    return routerSrc.substring(start, next);
  }

  test('shelf delegates its drop to the shared router', () {
    expect(readReaderHistorySource(), contains('routeReaderShelfDrop('));
  });

  test('shelf drop wires importNewVideo to prefilled video import', () {
    final String block = caseBlock('importNewVideo');
    expect(
      block.contains('openVideoImport('),
      isTrue,
      reason:
          'importNewVideo must auto-open VideoImportDialog with the dragged '
          'file (not just a SnackBar)',
    );
    expect(
      block.contains('initialVideoPath: files.videos.first'),
      isTrue,
      reason: 'must pass the dragged video path into the prefilled import',
    );
  });

  test('shelf drop wires importNewPlaylist to prefilled playlist import', () {
    final String block = caseBlock('importNewPlaylist');
    expect(
      block.contains('initialPlaylistPath: files.playlists.first'),
      isTrue,
      reason:
          'importNewPlaylist branch must auto-open VideoImportDialog with the '
          'dragged playlist (not just a SnackBar)',
    );
  });

  test('prefilled opener passes paths into VideoImportDialog', () {
    expect(routerSrc.contains('initialVideoPath: initialVideoPath'), isTrue);
    expect(
      routerSrc.contains('initialPlaylistPath: initialPlaylistPath'),
      isTrue,
    );
    expect(routerSrc.contains('initialStreamUrl: initialStreamUrl'), isTrue);
  });
}
