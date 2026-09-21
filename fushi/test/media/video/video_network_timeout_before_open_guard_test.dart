import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：网络流的 libmpv 网络属性（含 `network-timeout`）必须在 `player.open` **之前**
/// 下发。
///
/// media_kit 建 Player 时把 `network-timeout` 钉成 5（media_kit-1.2.6
/// `native/player/real.dart` 的初始化属性块）。Hibiki 的网络流全部经 Dart 中继
/// （`http-proxy`）取字节，mpv 看到的首字节延迟 = 真上游的首字节延迟；在线视频源的
/// hoster CDN 冷缓存 / 重定向 / 限流下常在 5~15s。属性若在 open 之后才设，loadfile 的
/// 第一个请求已经带着 5s 超时发出去了——媒体压根打不开、duration/position 恒 0，页面
/// 等满宽限报「播放器打不开该视频」，用户观感是「点开必超时」（BUG-2617）。
///
/// 这条顺序无法在 widget 层测：libmpv 不能离屏起，`Player.open` 也没有可注入的缝。
/// 故在最强可落地层——源码顺序——上钉死。
void main() {
  test('网络缓存属性在 player.open 之前下发', () {
    final File source = File(
      'lib/src/media/video/video_player_controller.dart',
    );
    expect(source.existsSync(), isTrue, reason: '守卫目标文件不在预期位置');
    final String text = source.readAsStringSync();

    final int applyIndex = text.indexOf(
      'await applyNetworkCachePropertiesToPlayer(player, sourceUri);',
    );
    final int openIndex = text.indexOf('await player.open(');

    expect(
      applyIndex,
      isNonNegative,
      reason:
          'applyNetworkCachePropertiesToPlayer 的调用点消失了；'
          '改名请连同本守卫一起改，别把它删掉',
    );
    expect(openIndex, isNonNegative, reason: 'player.open 的调用点消失了');
    expect(
      applyIndex,
      lessThan(openIndex),
      reason:
          '网络属性必须在 open 之前下发：open 之后再设，本次 loadfile 仍跑在 '
          'media_kit 默认的 network-timeout=5 上，慢 CDN 的首开必然被撕掉',
    );
  });

  test('网络属性只下发一次（没有残留的 open 后重复下发）', () {
    final File source = File(
      'lib/src/media/video/video_player_controller.dart',
    );
    final String text = source.readAsStringSync();
    final int count = 'await applyNetworkCachePropertiesToPlayer('
        .allMatches(text)
        .length;
    expect(count, 1, reason: '同一次 load 里重复下发说明前移没做干净：open 后那一处应当删掉');
  });
}
