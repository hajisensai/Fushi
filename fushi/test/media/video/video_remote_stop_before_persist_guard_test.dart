import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-4285：互联 backend 按视频 id 释放「本次播放」的流票。换集（同一 host
/// 播放列表、同一视频 id 换 episodeIndex）时页面先落库、再报停止，而新集的取流
/// 紧跟在后面——停止若排在落库的 await 之后，就会把新集刚签的票一并释放，新集
/// 起播即 403。所以两个「落库 + 报停止」helper 必须在第一个 await 之前同步发起
/// 停止上报，最后再等它。
void main() {
  final String page = File(
    'lib/src/pages/implementations/video_fushi_page.dart',
  ).readAsStringSync();

  String body(String signature) {
    final int start = page.indexOf(signature);
    expect(start, isNot(-1), reason: '找不到 $signature');
    final int end = page.indexOf('\n  }\n', start);
    // 去掉整行注释：注释里写到「await」不算代码里的 await。
    return page
        .substring(start, end)
        .split('\n')
        .where((String line) => !line.trimLeft().startsWith('//'))
        .join('\n');
  }

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
    test('$name 在落库 await 之前同步发起停止上报', () {
      final String b = body(name);
      final int stop = b.indexOf('_reportRemotePlaybackStopped(');
      final int persist = b.indexOf(persistAwait);
      expect(stop, isNot(-1), reason: '必须报远端停止');
      expect(persist, isNot(-1), reason: '必须落库');
      expect(stop, lessThan(persist), reason: '停止上报必须先于落库的 await 发起（BUG-4285）');
      expect(
        b.indexOf('await '),
        greaterThanOrEqualTo(persist),
        reason: '发起停止之前不得有任何 await',
      );
    });
  }
}
