import 'dart:io';

import 'package:test/test.dart';

import '../helpers/source_guard.dart';

/// gap-remote-4（路线图 #3722 m3）：远端起播时「开播位置」与「取流」互不依赖，
/// 必须一起发。串行时互联 host 离线要先等位置读超时、再等取流超时：本机实测
/// 未选路 4.0 s → 并行 2.0 s，已选路后 host 掉线 17.0 s → 15.0 s。
///
/// 播放页要真 libmpv 与真 host 才能端到端驱动（本仓没有能挂远端 client 的播放页
/// widget 测试装置），这里钉住 `_loadRemoteEpisode` 的发起顺序：取流的 future
/// 在等开播位置**之前**发出，等完位置之后才 await 它。
void main() {
  test('远端起播先发取流、再等开播位置', () {
    final String source = maskComments(
      File(
        'lib/src/pages/implementations/video_fushi_page.dart',
      ).readAsStringSync(),
    );
    final int load = source.indexOf('Future<void> _loadRemoteEpisode(');
    expect(load, greaterThanOrEqualTo(0));
    final String body = source.substring(load);
    final int streamCall = body.indexOf('.remoteVideoStreamUrls(');
    final int positionAwait = body.indexOf('.startPositionFor(');
    final int urlsAwait = body.indexOf('await urlsFuture');
    expect(streamCall, greaterThanOrEqualTo(0));
    expect(positionAwait, greaterThanOrEqualTo(0));
    expect(streamCall, lessThan(positionAwait), reason: '取流必须在等开播位置之前发出（两者并行）');
    expect(
      urlsAwait,
      greaterThan(positionAwait),
      reason: '取流结果在开播位置定下之后才 await',
    );
    expect(
      RegExp(r'await\s+client\s*\.\s*remoteVideoStreamUrls\(').hasMatch(body),
      isFalse,
      reason: '不得退回「等完位置再串行取流」',
    );
  });
}
