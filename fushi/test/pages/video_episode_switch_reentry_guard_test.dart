import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-3298 守卫：本地换集不得重入。
///
/// 手动点选（剧集列表 / 上下集键）与自动连播倒计时归零可以同时进入
/// `_switchEpisode`；本地分支在 `pause` 与 `pushReplacement` / 接管之间隔着 await，
/// 第二次进来会多压一页新集页，并对已被摘掉的本页路由再 `removeRoute`（抛异常）。
/// 本页同一时刻只允许一次本地换集在飞：标志必须在第一个 await 之前置位、在 finally
/// 里复位；远端换集不受此限（靠 `_episodeLoadSeq` 让后一次取代前一次）。
void main() {
  late String body;

  setUpAll(() {
    final String src = File(
      'lib/src/pages/implementations/video_fushi/episode.part.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final int start = src.indexOf('Future<void> _switchEpisode(');
    expect(start, isNonNegative);
    final int end = src.indexOf('\n  /// ', start);
    body = src.substring(start, end);
  });

  test('guard flag is declared on the page state', () {
    final String shell = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();
    expect(shell, contains('bool _localEpisodeSwitchInFlight = false;'));
  });

  test('local branch checks and sets the flag before its first await', () {
    final int remoteReturn = body.indexOf(
      '_loadRemoteEpisode(index, startIntent: intent)',
    );
    final int check = body.indexOf('_localEpisodeSwitchInFlight) return;');
    final int set = body.indexOf('_localEpisodeSwitchInFlight = true;');
    final int pause = body.lastIndexOf('await _controller?.pause();');
    expect(check, greaterThan(remoteReturn), reason: '远端换集不受重入门限制');
    expect(set, greaterThan(check));
    expect(set, lessThan(pause), reason: '标志必须在本地分支第一个 await 之前置位');
  });

  test(
    'flag is released in finally and the navigation stays inside the try',
    () {
      final int tryAt = body.indexOf('_localEpisodeSwitchInFlight = true;');
      final int removeAt = body.indexOf('navigator.removeRoute<Object?>');
      final int finallyAt = body.indexOf(
        '_localEpisodeSwitchInFlight = false;',
      );
      expect(finallyAt, greaterThan(removeAt));
      expect(
        body.substring(finallyAt - 20, finallyAt),
        contains('finally'),
        reason: '复位必须在 finally 里，早退 / 异常不能把换集永久锁死',
      );
      expect(removeAt, greaterThan(tryAt));
    },
  );
}
