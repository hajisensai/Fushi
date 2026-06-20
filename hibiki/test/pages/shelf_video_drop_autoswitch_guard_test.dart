import 'package:flutter_test/flutter_test.dart';
import 'reader_history_source_corpus.dart';

/// TODO-558 / BUG-326 源码守卫：书架（books 表面）拖入视频/播放列表时，必须**自动切到
/// 视频导入流程**并带上拖入文件（[_openVideoImportPrefilled] / [_openPlaylistImportPrefilled]
/// → [VideoImportDialog] 预填路径），而不是回退到只弹 SnackBar 提示「请切到视频页面」让
/// 用户手动重选。headless 测不到真实拖放命中几何，故在源码层钉死接线防回归。
///
/// 决策纯函数（books 表面视频→importNewVideo / importNewPlaylist）由
/// drop_decision_test.dart 覆盖；本守卫钉死书架页 handler 对这两个意图的接线。
void main() {
  final String pageSrc = readReaderHistorySource();

  test('shelf drop wires importNewVideo to prefilled video import', () {
    final String src = pageSrc;

    expect(src.contains('case DropIntent.importNewVideo:'), isTrue,
        reason: 'importNewVideo case must be handled on the shelf');
    expect(src.contains('_openVideoImportPrefilled('), isTrue,
        reason:
            'importNewVideo must auto-open VideoImportDialog with the dragged '
            'file (not just a SnackBar)');

    // importNewVideo 分支内确实调用预填打开（带上 files.videos.first）。
    final int start = src.indexOf('case DropIntent.importNewVideo:');
    expect(start, greaterThan(-1));
    final int next = src.indexOf('case DropIntent.', start + 1);
    expect(next, greaterThan(start));
    final String block = src.substring(start, next);
    expect(block.contains('_openVideoImportPrefilled('), isTrue,
        reason: 'importNewVideo branch must call _openVideoImportPrefilled');
    expect(block.contains('files.videos.first'), isTrue,
        reason: 'must pass the dragged video path into the prefilled import');
  });

  test('shelf drop wires importNewPlaylist to prefilled playlist import', () {
    final String src = pageSrc;

    expect(src.contains('case DropIntent.importNewPlaylist:'), isTrue,
        reason: 'importNewPlaylist case must be handled on the shelf');

    final int start = src.indexOf('case DropIntent.importNewPlaylist:');
    expect(start, greaterThan(-1));
    final int next = src.indexOf('case DropIntent.', start + 1);
    expect(next, greaterThan(start));
    final String block = src.substring(start, next);
    expect(block.contains('_openPlaylistImportPrefilled('), isTrue,
        reason:
            'importNewPlaylist branch must auto-open VideoImportDialog with the '
            'dragged playlist (not just a SnackBar)');
  });

  test('prefilled openers pass paths into VideoImportDialog', () {
    final String src = pageSrc;

    // 预填打开方法把拖入路径透传进 VideoImportDialog（initialVideoPath / initialPlaylistPath）。
    expect(src.contains('initialVideoPath: videoPath'), isTrue,
        reason: '_openVideoImportPrefilled must forward initialVideoPath');
    expect(src.contains('initialPlaylistPath: playlistPath'), isTrue,
        reason:
            '_openPlaylistImportPrefilled must forward initialPlaylistPath');
  });
}
