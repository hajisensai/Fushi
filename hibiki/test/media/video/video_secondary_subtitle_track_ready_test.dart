import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';

/// TODO-1295 / BUG：副字幕（TODO-857 双字幕 Path A，libmpv `secondary-sid`）有时不
/// 显示。根因＝按 ffmpeg `0:s:N` 序号选第 N 条内嵌字幕轨时，容器多条轨在 `player.open`
/// 后**逐条异步**解析，旧 `_waitUntilSubtitleTracksReady` 只要「任意一条」真实轨就绪就
/// 早退；选第 2 条（`streamIndex=1`）时若这一刻只解析出第 1 条，`real.length==1`、
/// `streamIndex >= real.length` 越界，一次性放弃下发 →「有时候不显示」（移动端 IO 慢
/// 更易命中）。修复：按 index 选轨改传 `minTrackCount: streamIndex + 1`，等到**目标序号
/// 那条轨真正就绪**或超时才继续。
///
/// 本测试直击就绪等待内核 [VideoPlayerController.waitForSubtitleTrackCount]（不依赖真
/// libmpv）：注入「真实轨数」读取器 + 轨列表变化事件流，验证「等到目标轨数就绪才完成」
/// 「超时才 false」「check-then-subscribe 竞态闭合」。
void main() {
  group('TODO-1295 副字幕轨就绪竞态：按 streamIndex 就绪判据', () {
    test('目标轨数已就绪：立即返回 true', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      final StreamController<Object?> changes =
          StreamController<Object?>.broadcast();
      addTearDown(changes.close);

      final bool ready = await c.waitForSubtitleTrackCount(
        currentRealCount: () => 2,
        changes: changes.stream,
        minTrackCount: 2,
      );
      expect(ready, isTrue);
    });

    test('轨逐条异步解析：只解析出第 1 条时不早退，等第 2 条就绪才完成', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      final StreamController<Object?> changes =
          StreamController<Object?>.broadcast();
      addTearDown(changes.close);

      int count = 1; // 首次解析只出第 1 条（旧实现在此早退 → 选第 2 条越界）。
      bool? result;
      final Future<bool> f = c
          .waitForSubtitleTrackCount(
        currentRealCount: () => count,
        changes: changes.stream,
        minTrackCount: 2, // streamIndex=1 → 需要第 2 条就绪。
        timeout: const Duration(seconds: 5),
      )
          .then((bool r) {
        result = r;
        return r;
      });

      // 目标第 2 条尚未解析出：绝不能提前完成（旧实现在此已越界放弃）。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(result, isNull, reason: '目标第 2 条未就绪前不得早退');

      // 第 2 条解析出来并广播「轨列表变化」事件。
      count = 2;
      changes.add(null);

      expect(await f, isTrue, reason: '目标轨数就绪后完成 true');
    });

    test('目标轨永不出现：在超时上界内返回 false（有界，不无限等）', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      final StreamController<Object?> changes =
          StreamController<Object?>.broadcast();
      addTearDown(changes.close);

      final bool ready = await c.waitForSubtitleTrackCount(
        currentRealCount: () => 1, // 永远只有 1 条。
        changes: changes.stream,
        minTrackCount: 2,
        timeout: const Duration(milliseconds: 100),
      );
      expect(ready, isFalse,
          reason: '超时上界内目标轨未就绪 → false，由调用方按 real.length 判越界');
    });

    test('check-then-subscribe 竞态：订阅后立即复读闭合（无后续事件也完成）', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      final StreamController<Object?> changes =
          StreamController<Object?>.broadcast();
      addTearDown(changes.close);

      // 首次调用（初始检查）返回 1（不足）；此后返回 2——模拟「初始检查与 listen 注册
      // 之间轨列表已增长，且此后不再有事件」。若无「订阅后立即复读」，将卡到超时。
      int calls = 0;
      final bool ready = await c.waitForSubtitleTrackCount(
        currentRealCount: () {
          calls++;
          return calls == 1 ? 1 : 2;
        },
        changes: changes.stream,
        minTrackCount: 2,
        timeout: const Duration(seconds: 5),
      );
      expect(ready, isTrue, reason: 'listen 后立即复读到第 2 条，无需等 stream 事件，闭合竞态');
    });

    test('到达阈值即停：更高目标轨数需要更多轨才完成', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      final StreamController<Object?> changes =
          StreamController<Object?>.broadcast();
      addTearDown(changes.close);

      int count = 1;
      bool? result;
      final Future<bool> f = c
          .waitForSubtitleTrackCount(
        currentRealCount: () => count,
        changes: changes.stream,
        minTrackCount: 3, // 选第 3 条（streamIndex=2）。
        timeout: const Duration(seconds: 5),
      )
          .then((bool r) {
        result = r;
        return r;
      });

      count = 2;
      changes.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(result, isNull, reason: '只到第 2 条，选第 3 条仍不得完成');

      count = 3;
      changes.add(null);
      expect(await f, isTrue);
    });
  });
}
