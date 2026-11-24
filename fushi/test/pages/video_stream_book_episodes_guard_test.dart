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

  test('「换没换集」按书 + 播放集下标判，不按选集列表位置判', () {
    // 每集一本书的列表里 `_currentEpisode` 是选集位置：长播放列表后几批晚到、刷新重排都会
    // 动它，播的却还是同一集——拿它判「换集了」会把排队的覆盖制卡 / 失败重试当成换集作废、
    // 把跳转记录清掉；网页档站内原地换集又只换书不换播放器，光比集下标看不出来。
    expect(
      src.contains(
        'int get _playingEpisodeIndex => _streamBookEpisodes ? 0 : _currentEpisode;',
      ),
      isTrue,
    );
    expect(
      src.contains(
        "String get _playingEpisodeScope => '\$_activeBookUid#\$_playingEpisodeIndex';",
      ),
      isTrue,
    );
    expect(
      RegExp(
        r'_currentEpisode != (queuedEpisode|request\.|episode\b)',
      ).hasMatch(src),
      isFalse,
      reason: '制卡排队 / 覆盖 / 重试的换集判据走 _playingEpisodeScope',
    );
    expect(src.contains("'\$_activeBookUid#\$_currentEpisode'"), isFalse);
    expect(
      bodyOf(
        'Future<bool> _reloadRemoteEpisodeInSession(',
      ).contains('_playingEpisodeIndex'),
      isTrue,
      reason: '换档 / 换线路重载的是本书自己的流，不是选集位置那一集',
    );
  });

  test('列表在网页档 / 内置网页播放器 / 内核播放分流之前建', () {
    final int load = src.indexOf('await _loadStreamBookEpisodes();');
    final int split = src.indexOf('shouldOpenInWebVideoPlayer(row.videoPath)');
    expect(load, greaterThan(-1));
    expect(split, greaterThan(load));
  });
}
