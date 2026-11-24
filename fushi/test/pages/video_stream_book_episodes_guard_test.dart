import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 源码守卫（拍板台 zGXhhMAglH）：有列表上下文的流媒体书（合集里的流媒体书 / 从 YouTube
/// 播放列表打开）接进选集面板后，**每集是一本独立的书、换集是换页**。
///
/// 数据层（列表拉取 / 映射）由 `stream_book_episodes_test.dart` 行为测试覆盖；这里钉住
/// 播放页里三条不变量，它们一旦被改回去不会有编译错误，只会悄悄坏掉用户数据：
/// * 远端键不随选集下标变：本页只播它自己那本书，`_currentEpisode` 只是它在列表里的位置，
///   拿它当远端集下标会把断点 / 字幕 / 调轴写到 `(book, 7)` 这种别的键上；
/// * 换集走换页，不走「同一远端换 episodeIndex」——流客户端只认它自己那一条 URL；
/// * 取流完成不能用取流下标（恒 0）覆盖列表维护的当前集（列表可能在取流途中才到）。
void main() {
  late String src;
  setUpAll(() => src = maskComments(readVideoFushiSource()));

  String bodyOf(String signature) {
    final int start = src.indexOf(signature);
    expect(start, greaterThan(-1), reason: '应保留 $signature');
    final int end = src.indexOf('\n  }\n', start);
    return src.substring(start, end);
  }

  test('远端键：每集一本书的列表恒用本书自己的 (bookUid, 0)', () {
    final String body = bodyOf(
      '(String uid, int episodeIndex) _remotePositionKeyForIndex(int index) {',
    );
    final int streamBook = body.indexOf(
      'if (_streamBookEpisodes) return (_activeBookUid, 0);',
    );
    expect(streamBook, greaterThan(-1));
    expect(
      streamBook,
      lessThan(body.indexOf('if (_isRemoteCollection)')),
      reason: '先于合集 / host 播放列表分支判定',
    );
  });

  test('换集：每集一本书的列表不走远端原地换流，按本地合集换页', () {
    final String body = bodyOf('Future<void> _switchEpisode(');
    expect(body.contains('if (_isRemote && !_streamBookEpisodes) {'), isTrue);
    expect(
      body.contains('await _episodeTargetBookUid(index)'),
      isTrue,
      reason: '目标集在换过去时才落书',
    );
    expect(
      body.contains('youtubePlaylistId: _streamBookYoutubePlaylistId,'),
      isTrue,
      reason: '列表上下文随集交给下一页',
    );
  });

  test('取流完成不覆盖列表维护的当前集', () {
    expect(
      src.contains('if (!_streamBookEpisodes) _currentEpisode = index;'),
      isTrue,
    );
  });

  test('列表在网页档 / 内置网页播放器 / 内核播放分流之前建', () {
    final int load = src.indexOf('await _loadStreamBookEpisodes();');
    final int split = src.indexOf('shouldOpenInWebVideoPlayer(row.videoPath)');
    expect(load, greaterThan(-1));
    expect(split, greaterThan(load));
  });
}
