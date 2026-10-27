import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 反馈 XmUBLYR1Ut：互联远程播放合集连播时，`_loadRemoteEpisode` 的 [index] 是
/// 合集内位置，而每个成员在主机上都是单视频（主机侧集序号恒 0，存在
/// `streamEpisodeIndex` 里）。任何发往主机的按集请求都必须用 `streamEpisodeIndex`；
/// 默认字幕下载曾传 `episodeIndex: index`，主机 404、客户端静默吞掉，第 2 集起
/// 永远拿不到主机选定的外挂字幕。
void main() {
  test('remote episode host requests use streamEpisodeIndex, never index', () {
    final String src = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();
    final int start = src.indexOf('Future<void> _loadRemoteEpisode(');
    expect(start, greaterThanOrEqualTo(0));
    final int end = src.indexOf('\n  }\n', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);

    // 只看发往主机的 client 调用（本地 prefs 记忆键另有自己的 (uid, ep) 口径）。
    final List<String> hostCalls = RegExp(
      r'client\.\w+\([^;]*?episodeIndex:\s*(\w+)',
      dotAll: true,
    ).allMatches(body).map((RegExpMatch m) => m.group(1)!).toList();
    expect(hostCalls, isNotEmpty);
    expect(
      hostCalls.where((String v) => v != 'streamEpisodeIndex'),
      isEmpty,
      reason: '主机侧按集请求必须传 streamEpisodeIndex（合集连播恒 0）',
    );
  });
}
