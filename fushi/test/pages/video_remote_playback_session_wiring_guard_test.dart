/// BUG-4283 页面接线守卫：互联远端视频每一集载入时经
/// `InterconnectRemotePlaybackSession.startPositionFor` 走与 sweep 同一份三方判定，
/// 实时上报经同一个会话。播放页依赖 libmpv，widget test 起不来；行为本身由
/// `test/sync/interconnect_remote_playback_session_test.dart`（真 host）钉住，这里只
/// 钉页面的调用形态。
library;

import 'dart:io';

import 'package:test/test.dart';

String _flat(String v) =>
    v.replaceAll(RegExp(r'\s+'), '').replaceAll(',)', ')');

void main() {
  final File page = File('lib/src/pages/implementations/video_fushi_page.dart');
  late String src;

  setUpAll(() {
    expect(page.existsSync(), isTrue);
    src = page.readAsStringSync();
  });

  String region(String startSig, String endSig) {
    final int start = src.indexOf(startSig);
    expect(start, isNonNegative, reason: 'missing region start: $startSig');
    final int end = src.indexOf(endSig, start + startSig.length);
    expect(end, isNonNegative, reason: 'missing region end: $endSig');
    return src.substring(start, end);
  }

  test('播放页不自建位置同步实例 / 上报器，只经远端播放会话', () {
    expect(src.contains('InterconnectPlaybackPositionSync('), isFalse);
    expect(src.contains('LivePositionReporter('), isFalse);
    expect(src.contains('InterconnectRemotePlaybackSession('), isTrue);
  });

  test('每一集载入（_loadRemoteEpisode）的开播位置经 startPositionFor 三方判定', () {
    final String load = _flat(
      region('Future<void> _loadRemoteEpisode(', '\n  }\n'),
    );
    expect(load, contains('.startPositionFor('));
    expect(load, contains('isInterconnectSyncBackend'));
    // 显式起点（换画质 / 换线路回到当前位置、卡片回看）不经三方判定。
    expect(load, contains('EpisodeStartIntent.explicitCue'));
  });

  test('互联分支的实时上报经同一个远端播放会话', () {
    final String persist = _flat(
      region(
        'Future<void> _persistRemotePosition(String uid, int posMs) async {',
        'Future<void> _persistRemotePositionAndReportPlaybackStopped',
      ),
    );
    expect(persist, contains('_remoteSessionFor(client).report('));
  });
}
