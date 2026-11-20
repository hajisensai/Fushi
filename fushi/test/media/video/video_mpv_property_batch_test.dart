// BUG-4911（路线图 #3722 video-36m）：mpv 属性批量下发只有一份实现
// [setMpvPropertiesInOrder]，逐条 await 保序，mpv 拒绝的写入留痕。
//
// 修前五份同形循环各自 `try { await native.setProperty(...) } catch (_) {}`：
// media_kit 的 setProperty 把 libmpv 的结果码丢掉，属性名拼错 / 值非法 / rawConf 里
// 写了运行时不可设的选项，全都无声无息。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_mpv_config.dart';
import 'package:media_kit/media_kit.dart';

/// 按名字提供 media_kit 补丁的 `setPropertyWithResult`（经 `player.platform` 动态分派）。
class _FakeMpv extends PlatformPlayer {
  _FakeMpv(this.results) : super(configuration: const PlayerConfiguration());

  /// 属性名 → 结果码；没列的返回 0。值为 null 表示这条写入抛出（销毁竞态）。
  final Map<String, int?> results;

  final List<String> written = <String>[];
  int inFlight = 0;
  int maxInFlight = 0;

  Future<int> setPropertyWithResult(String property, String value) async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    // 让出一次事件循环：并发下发时下一条会在这里与本条重叠。
    await Future<void>.delayed(Duration.zero);
    inFlight--;
    written.add(property);
    if (results.containsKey(property) && results[property] == null) {
      throw AssertionError('[Player] has been disposed');
    }
    return results[property] ?? 0;
  }
}

/// 没有 mpv 属性的后端（网页播放器那类 PlatformPlayer）。
class _NoMpv extends PlatformPlayer {
  _NoMpv() : super(configuration: const PlayerConfiguration());
}

void main() {
  late List<String> logs;
  late DebugPrintCallback savedDebugPrint;

  setUp(() {
    logs = <String>[];
    savedDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
  });
  tearDown(() => debugPrint = savedDebugPrint);

  test(
    'writes in map order, one at a time, and logs rejected writes',
    () async {
      final _FakeMpv mpv = _FakeMpv(<String, int?>{'scale': -8, 'hue': -7});
      await setMpvPropertiesInOrder(
        Player(platformPlayer: mpv),
        <String, String>{
          'volume-max': '150',
          'scale': 'ewa_lanczossharp',
          'hue': 'secret-value',
          'volume': '120',
        },
      );
      expect(mpv.written, <String>['volume-max', 'scale', 'hue', 'volume']);
      expect(mpv.maxInFlight, 1, reason: 'libmpv 异步写不保序，必须等上一条回包再发下一条');
      expect(logs, <String>[
        '[mpv-prop] scale rejected: property not found (-8)',
        '[mpv-prop] hue rejected: option error (-7)',
      ]);
      expect(logs.join(), isNot(contains('secret-value')), reason: '日志不记值');
    },
  );

  test('stops the batch once the player is gone', () async {
    final _FakeMpv uninitialized = _FakeMpv(<String, int?>{'b': -3});
    await setMpvPropertiesInOrder(
      Player(platformPlayer: uninitialized),
      <String, String>{'a': '1', 'b': '2', 'c': '3'},
    );
    expect(uninitialized.written, <String>['a', 'b']);
    expect(logs, isEmpty, reason: '销毁不是 mpv 拒绝写入');

    final _FakeMpv throwing = _FakeMpv(<String, int?>{'b': null});
    await setMpvPropertiesInOrder(
      Player(platformPlayer: throwing),
      <String, String>{'a': '1', 'b': '2', 'c': '3'},
    );
    expect(throwing.written, <String>['a', 'b']);
    expect(logs.single, startsWith('[mpv-prop] b: write aborted'));
  });

  test('is a silent no-op on a backend without mpv properties', () async {
    await setMpvPropertiesInOrder(
      Player(platformPlayer: _NoMpv()),
      <String, String>{'a': '1'},
    );
    expect(logs, isEmpty);
  });

  test('every batch helper goes through setMpvPropertiesInOrder', () async {
    final _FakeMpv mpv = _FakeMpv(<String, int?>{});
    final Player player = Player(platformPlayer: mpv);
    await applySubtitleMpvPropertiesToPlayer(
      player,
      buildSubtitleSuppressionProperties(),
    );
    await applyHttpHeaderFieldsToPlayer(player, <String, String>{
      'Referer': 'https://example.test/',
    });
    await clearHttpHeaderFieldsOnPlayer(player);
    await applyNetworkCachePropertiesToPlayer(
      player,
      'https://example.test/v.m3u8',
    );
    await applyMpvConfigToPlayer(player, VideoMpvConfig.defaults);
    expect(
      mpv.written,
      containsAllInOrder(<String>[
        ...buildSubtitleSuppressionProperties().keys,
        'http-header-fields',
        'http-header-fields',
        ...buildNetworkCacheProperties().keys,
        'volume-max',
      ]),
    );
    expect(mpv.maxInFlight, 1);
  });
}
