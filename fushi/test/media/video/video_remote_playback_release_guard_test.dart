import 'dart:io';

import 'package:test/test.dart';

import '../../helpers/source_guard.dart';

/// BUG-4461：远端播放的「释放服务端资源」（互联 host 的流票）与「播放停止上报」
/// （Jellyfin / Plex 的 Stopped）是两件事，页面在不同边界上调：
///
/// - 自然播完只**上报**停止：播放器 `keep-open`，页面停在本集，用户还能回拖 /
///   重看——此时释放流票会让之后的 Range / 分段请求 403 / 410（评审 correctness-1）。
/// - 退出 / 换集 / 换档 / 换线路重载之前**同步**释放（不 await），且在新流取流之前，
///   否则互联 backend 按视频 id 摘会话会摘掉新会话；释放不阻塞换档（compat-2）。
/// - 两个「落库 + 报停止」helper 保持先落库、后报停止：Jellyfin / Plex 的最后一次
///   Progress 不能排在 Stopped 之后（correctness-2）。
/// - 外链跳转只在确定关页后才释放：之前任一处取消导航，本页留下且流仍可用
///   （correctness-3）。
void main() {
  String read(String path) => File(path).readAsStringSync();
  final String page = read(
    'lib/src/pages/implementations/video_fushi_page.dart',
  );
  final String episode = read(
    'lib/src/pages/implementations/video_fushi/episode.part.dart',
  );
  final String quality = read(
    'lib/src/pages/implementations/video_fushi/quality.part.dart',
  );

  /// [source] 里 [signature] 起到函数体结束（下一个两格缩进的 `}`）的代码，注释抹掉。
  String body(String source, String signature) {
    final int start = source.indexOf(signature);
    expect(start, isNot(-1), reason: '找不到 $signature');
    final int end = source.indexOf('\n  }\n', start);
    expect(end, isNot(-1));
    return maskComments(source.substring(start, end));
  }

  test('释放 helper 同步调用、不等结果', () {
    final String b = body(page, 'void _releaseRemotePlayback(');
    expect(b, contains('RemoteVideoPlaybackRelease'));
    expect(b, contains('unawaited('));
    expect(b, isNot(contains('await ')));
    expect(page, isNot(contains('await _releaseRemotePlayback(')));
    expect(episode, isNot(contains('await _releaseRemotePlayback(')));
    expect(quality, isNot(contains('await _releaseRemotePlayback(')));
  });

  test('自然播完只上报停止、不释放流', () {
    final String b = body(episode, 'void _handlePlaybackCompleted(');
    expect(b, contains('_reportRemotePlaybackStopped('));
    expect(b, isNot(contains('_releaseRemotePlayback(')));
    expect(b, isNot(contains('releaseRemoteVideoPlayback(')));
  });

  for (final (String name, String source, String signature)
      in <(String, String, String)>[
        ('换集', episode, 'Future<void> _switchEpisode('),
        ('自适应换档', quality, 'Future<void> _applyAdaptiveQuality('),
        ('手动换档', quality, 'Future<void> _switchMediaServerQuality('),
        ('换线路', quality, 'Future<void> _switchStreamVariant('),
      ]) {
    test('$name：在停止上报与重新取流之前释放旧流', () {
      final String b = body(source, signature);
      final int release = b.indexOf('_releaseRemotePlayback(');
      final int load = b.indexOf('_loadRemoteEpisode(');
      expect(release, isNot(-1), reason: '$name 必须释放旧流');
      expect(load, isNot(-1));
      expect(release, lessThan(load));
      final int stop = b.indexOf('_reportRemotePlaybackStopped(');
      if (stop != -1) {
        expect(release, lessThan(stop), reason: '不能排在会 await 的停止上报之后');
      }
    });
  }

  test('退出页面在 pop 之前同步释放', () {
    final String b = body(page, 'void _exitVideoPage(');
    final int release = b.indexOf('_releaseRemotePlayback(');
    expect(release, isNot(-1));
    expect(release, lessThan(b.indexOf('exitAfterPersist(')));
  });

  test('外链跳转在确定关页之后才释放', () {
    final String b = body(page, 'Future<bool> _closeForExternalNavigation(');
    final int release = b.indexOf('_releaseRemotePlayback(');
    expect(release, isNot(-1), reason: '外链跳转关页也要释放');
    expect(
      b.lastIndexOf('if (!route.isCurrent) return false;'),
      lessThan(release),
      reason: '释放之前的取消导航分支会留下本页，流不能已作废',
    );
    expect(release, lessThan(b.indexOf('navigator.pop();')));
  });

  for (final (String name, String persistAwait) in <(String, String)>[
    (
      'Future<void> _flushPositionAndReportRemotePlaybackStopped(',
      'await controller?.flushPosition();',
    ),
    (
      'Future<void> _persistRemotePositionAndReportPlaybackStopped(',
      'await _persistRemotePosition(uid, positionMs);',
    ),
  ]) {
    test('$name 先落库（含最后一次进度上报）、后报停止', () {
      final String b = body(page, name);
      final int stop = b.indexOf('_reportRemotePlaybackStopped(');
      final int persist = b.indexOf(persistAwait);
      expect(stop, isNot(-1), reason: '必须报远端停止');
      expect(persist, isNot(-1), reason: '必须落库');
      expect(persist, lessThan(stop), reason: 'Progress 不能排在 Stopped 之后');
      expect(b, isNot(contains('_releaseRemotePlayback(')));
    });
  }
}
