import 'package:test/test.dart';
import 'package:fushi/src/sync/interconnect_adaptive_quality.dart';
import 'package:fushi/src/sync/interconnect_video_quality.dart';

/// 喂 [ticks] 拍平稳播放（不卡、缓冲深度充足）。
int _runQuiet(
  AdaptiveQualityController c,
  int ticks, {
  required int currentIndex,
  double cacheSeconds = 60,
}) {
  int index = currentIndex;
  for (int i = 0; i < ticks; i++) {
    final AdaptiveQualityDecision? d = c.tick(
      currentIndex: index,
      buffering: false,
      cacheSeconds: cacheSeconds,
    );
    if (d != null) index = d.targetIndex;
  }
  return index;
}

void main() {
  // BUG-2731：平板实测局域网原画直传，一次横滑 seek 缓冲 3～4 秒 → 被判「撑不住」降成
  // 转码并按 seek 前的旧位置重开，用户的滑动被抹掉。
  group('seek 引起的缓冲不算网况（BUG-2731）', () {
    test('原画直传 seek 后连续缓冲 4 拍：不降档', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      _runQuiet(c, kAdaptiveCooldownTicks, currentIndex: -1);
      c.noteSeek();
      for (int i = 0; i < 4; i++) {
        expect(
          c.tick(currentIndex: -1, buffering: true, cacheSeconds: 0),
          isNull,
          reason: '第 ${i + 1} 拍：seek 的缓冲不该触发降档',
        );
      }
      expect(_runQuiet(c, 5, currentIndex: -1), -1);
    });

    test('seek 之后一直缓冲超过宽限：照常降档（真卡不被 seek 掩盖）', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      _runQuiet(c, kAdaptiveCooldownTicks, currentIndex: -1);
      c.noteSeek();
      AdaptiveQualityDecision? decision;
      for (
        int i = 0;
        i < kAdaptiveSeekGraceTicks + kAdaptiveStallTicksToDrop;
        i++
      ) {
        decision ??= c.tick(currentIndex: -1, buffering: true, cacheSeconds: 0);
      }
      expect(decision, isNotNull);
      expect(decision!.reason, AdaptiveQualityReason.stall);
    });

    test('seek 落地起播后宽限立即结束，之后的卡顿照常计', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      _runQuiet(c, kAdaptiveCooldownTicks, currentIndex: 1, cacheSeconds: 1);
      c.noteSeek();
      expect(c.tick(currentIndex: 1, buffering: true, cacheSeconds: 0), isNull);
      // 起播：宽限结束。
      expect(
        c.tick(currentIndex: 1, buffering: false, cacheSeconds: 1),
        isNull,
      );
      AdaptiveQualityDecision? decision;
      for (int i = 0; i < kAdaptiveStallTicksToDrop; i++) {
        decision ??= c.tick(currentIndex: 1, buffering: true, cacheSeconds: 0);
      }
      expect(decision?.targetIndex, 2);
    });

    test('reset 清掉未用完的 seek 宽限', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      c.noteSeek();
      c.reset();
      _runQuiet(c, kAdaptiveCooldownTicks, currentIndex: 1, cacheSeconds: 1);
      AdaptiveQualityDecision? decision;
      for (int i = 0; i < kAdaptiveStallTicksToDrop; i++) {
        decision ??= c.tick(currentIndex: 1, buffering: true, cacheSeconds: 0);
      }
      expect(decision, isNotNull);
    });

    // 频繁 seek 时宽限不能每次续命（R11(a)）：判据是「窗口内平均 seek 代价」是否
    // 超出健康链路的正常代价 [kAdaptiveSeekCostBaselineTicks]。
    List<AdaptiveQualityDecision> runSeekLoop(
      AdaptiveQualityController c, {
      required int rounds,
      required int bufferTicksPerSeek,
    }) {
      final List<AdaptiveQualityDecision> decisions =
          <AdaptiveQualityDecision>[];
      int index = -1;
      void feed(bool buffering) {
        final AdaptiveQualityDecision? d = c.tick(
          currentIndex: index,
          buffering: buffering,
          cacheSeconds: buffering ? 0 : 5,
        );
        if (d != null) {
          decisions.add(d);
          index = d.targetIndex;
        }
      }

      for (int r = 0; r < rounds; r++) {
        c.noteSeek();
        for (int i = 0; i < bufferTicksPerSeek; i++) {
          feed(true);
        }
        feed(false);
      }
      return decisions;
    }

    test('差网句子循环：每次 seek 缓冲 8 拍 → 降档', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      _runQuiet(c, kAdaptiveCooldownTicks, currentIndex: -1);
      final List<AdaptiveQualityDecision> decisions = runSeekLoop(
        c,
        rounds: 4,
        bufferTicksPerSeek: 8,
      );
      expect(
        decisions.any(
          (AdaptiveQualityDecision d) =>
              d.reason == AdaptiveQualityReason.stall,
        ),
        isTrue,
        reason: '每次 seek 都缓冲 8 拍，超出正常 seek 代价，宽限不该不断续命',
      );
    });

    test('局域网原画 20 秒内 seek 4 次、每次缓冲 4 拍 → 不降档', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      _runQuiet(c, kAdaptiveCooldownTicks, currentIndex: -1);
      expect(runSeekLoop(c, rounds: 4, bufferTicksPerSeek: 4), isEmpty);
    });

    test('连续拖动：缓冲中多次 seek → 不降档', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      _runQuiet(c, kAdaptiveCooldownTicks, currentIndex: -1);
      final List<AdaptiveQualityDecision?> decisions =
          <AdaptiveQualityDecision?>[];
      void feed(bool buffering) => decisions.add(
        c.tick(currentIndex: -1, buffering: buffering, cacheSeconds: 0),
      );
      c.noteSeek();
      feed(true);
      feed(true);
      c.noteSeek();
      feed(true);
      feed(true);
      c.noteSeek();
      for (int i = 0; i < 4; i++) {
        feed(true);
      }
      for (int i = 0; i < 10; i++) {
        feed(false);
      }
      expect(decisions.whereType<AdaptiveQualityDecision>(), isEmpty);
    });
  });

  // BUG-4459 残留 T4：平均每次 3～5 拍的高频 seek，只看拍数分不开「局域网的延迟」与
  // 「差网的吞吐不足」。分界在起播后的缓冲深度走向：吞吐 ≥ 码率时播放中深度只增不减，
  // 跟不上就一路往下掉。
  group('高频 seek：按起播后的缓冲深度走向分网况（BUG-4459 T4）', () {
    /// 每轮：seek → 缓冲 [bufferTicksPerSeek] 拍 → 按 [playingCache] 逐拍播放。
    /// [pauseAfter] 非 null 时在第这么多拍播放后暂停一次（页面不喂 tick，只调
    /// [AdaptiveQualityController.notePlaybackPaused]）。
    List<AdaptiveQualityDecision> runLoop(
      AdaptiveQualityController c, {
      required int rounds,
      required int bufferTicksPerSeek,
      required List<double> playingCache,
      int? pauseAfter,
    }) {
      final List<AdaptiveQualityDecision> decisions =
          <AdaptiveQualityDecision>[];
      int index = -1;
      void feed({required bool buffering, required double cacheSeconds}) {
        final AdaptiveQualityDecision? d = c.tick(
          currentIndex: index,
          buffering: buffering,
          cacheSeconds: cacheSeconds,
        );
        if (d != null) {
          decisions.add(d);
          index = d.targetIndex;
        }
      }

      for (int r = 0; r < rounds; r++) {
        c.noteSeek();
        for (int i = 0; i < bufferTicksPerSeek; i++) {
          feed(buffering: true, cacheSeconds: 0);
        }
        for (int i = 0; i < playingCache.length; i++) {
          if (pauseAfter != null && i == pauseAfter) c.notePlaybackPaused();
          feed(buffering: false, cacheSeconds: playingCache[i]);
        }
      }
      return decisions;
    }

    test('差网句子循环：每次 seek 缓冲 4 拍、起播后缓冲深度一路下降 → 降档', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      _runQuiet(c, kAdaptiveCooldownTicks, currentIndex: -1);
      // 吞吐约 0.7 倍码率：每播一秒深度少 0.3 秒。平均代价 4 拍 < 正常代价 5 拍，
      // 只按拍数判（修复前）永远不降档。
      final List<AdaptiveQualityDecision> decisions = runLoop(
        c,
        rounds: 6,
        bufferTicksPerSeek: 4,
        playingCache: <double>[1.0, 0.7, 0.4],
      );
      expect(decisions, isNotEmpty, reason: '吞吐跟不上，seek 的缓冲不是固定代价');
      expect(decisions.first.reason, AdaptiveQualityReason.stall);
      expect(decisions.first.targetIndex, kAdaptiveMaxIndex);
    });

    test('局域网同样的 seek 节奏：起播后缓冲深度快速回升 → 不降档', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      _runQuiet(c, kAdaptiveCooldownTicks, currentIndex: -1);
      expect(
        runLoop(
          c,
          rounds: 6,
          bufferTicksPerSeek: 4,
          playingCache: <double>[1.0, 4.0, 8.0],
        ),
        isEmpty,
      );
    });

    test('局域网满缓冲时的回落不当证据：缓存内 seek 后深度下降 + 高频缓冲 seek → 不降档', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      _runQuiet(c, kAdaptiveCooldownTicks, currentIndex: -1);
      final List<AdaptiveQualityDecision?> decisions =
          <AdaptiveQualityDecision?>[];
      void feed({required bool buffering, required double cacheSeconds}) =>
          decisions.add(
            c.tick(
              currentIndex: -1,
              buffering: buffering,
              cacheSeconds: cacheSeconds,
            ),
          );
      // 往回 seek 落在后向缓冲里：不缓冲，前向深度超出预读上限，播放器按需停下载，
      // 深度一秒少一秒——这是被截断的读数，不反映网况。
      c.noteSeek();
      for (final double cache in <double>[36, 35, 34, 33, 32, 31]) {
        feed(buffering: false, cacheSeconds: cache);
      }
      // 随后几次缓存外 seek，各缓冲 4 拍、只播一拍就又 seek（拿不到深度走向）。
      for (int r = 0; r < 3; r++) {
        c.noteSeek();
        for (int i = 0; i < 4; i++) {
          feed(buffering: true, cacheSeconds: 0);
        }
        feed(buffering: false, cacheSeconds: 1);
      }
      expect(decisions.whereType<AdaptiveQualityDecision>(), isEmpty);
    });

    test('千兆内网起播一秒就填满预读上限：上限附近的抖动不当证据 → 不降档', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      _runQuiet(c, kAdaptiveCooldownTicks, currentIndex: -1);
      // 第一拍播放时深度已经到 cache-secs 上限（30 秒），之后只有抖动，净值为负。
      expect(
        runLoop(
          c,
          rounds: 6,
          bufferTicksPerSeek: 4,
          playingCache: <double>[30.0, 29.8, 29.7],
        ),
        isEmpty,
      );
    });

    test('片尾句子循环：缓冲已铺到文件末尾，深度随播放减少不当证据 → 不降档', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      _runQuiet(c, kAdaptiveCooldownTicks, currentIndex: -1);
      final List<AdaptiveQualityDecision?> decisions =
          <AdaptiveQualityDecision?>[];
      for (int r = 0; r < 6; r++) {
        c.noteSeek();
        for (int i = 0; i < 4; i++) {
          decisions.add(
            c.tick(currentIndex: -1, buffering: true, cacheSeconds: 0),
          );
        }
        for (final double cache in <double>[2.5, 1.5, 0.5]) {
          decisions.add(
            c.tick(
              currentIndex: -1,
              buffering: false,
              cacheSeconds: cache,
              cacheReachesEnd: true,
            ),
          );
        }
      }
      expect(decisions.whereType<AdaptiveQualityDecision>(), isEmpty);
    });

    test('adaptiveCacheReachesEnd：位置 + 缓冲深度够到片尾才算', () {
      expect(
        adaptiveCacheReachesEnd(
          positionMs: 596000,
          durationMs: 600000,
          cacheSeconds: 3.2,
        ),
        isTrue,
      );
      expect(
        adaptiveCacheReachesEnd(
          positionMs: 300000,
          durationMs: 600000,
          cacheSeconds: 30,
        ),
        isFalse,
      );
      // 时长 / 位置 / 深度任一拿不到：不能断言到了片尾。
      expect(
        adaptiveCacheReachesEnd(
          positionMs: 596000,
          durationMs: null,
          cacheSeconds: 3.2,
        ),
        isFalse,
      );
      expect(
        adaptiveCacheReachesEnd(
          positionMs: 596000,
          durationMs: 0,
          cacheSeconds: 3.2,
        ),
        isFalse,
      );
    });

    test('跨暂停的两拍不构成读数：暂停期间涨上来的深度不掩盖差网', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      _runQuiet(c, kAdaptiveCooldownTicks, currentIndex: -1);
      // 每轮播放：1.0 → 0.7，暂停期间下载到 3.0，再播 3.0 → 2.7 → 2.4。若把暂停前后
      // 当成相邻两拍（+2.3），净值为正，差网会被判成「跟得上」。
      final List<AdaptiveQualityDecision> decisions = runLoop(
        c,
        rounds: 6,
        bufferTicksPerSeek: 4,
        playingCache: <double>[1.0, 0.7, 3.0, 2.7, 2.4],
        pauseAfter: 2,
      );
      expect(decisions, isNotEmpty);
      expect(decisions.first.reason, AdaptiveQualityReason.stall);
    });
  });

  group('降档（卡了）', () {
    test('冷却期内不换档——一次网络抖动不该连降三档', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      AdaptiveQualityDecision? first;
      for (int i = 0; i < kAdaptiveCooldownTicks - 1; i++) {
        first ??= c.tick(currentIndex: 1, buffering: true, cacheSeconds: 0);
      }
      expect(first, isNull);
    });

    test('冷却过后、窗口内卡够拍数 → 降一档', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      _runQuiet(c, kAdaptiveCooldownTicks, currentIndex: 1, cacheSeconds: 1);
      AdaptiveQualityDecision? decision;
      for (int i = 0; i < kAdaptiveStallTicksToDrop; i++) {
        decision ??= c.tick(currentIndex: 1, buffering: true, cacheSeconds: 0);
      }
      expect(decision, isNotNull);
      expect(decision!.targetIndex, 2);
      expect(decision.reason, AdaptiveQualityReason.stall);
    });

    test('零星一两拍缓冲不算卡（起播 / seek / 关键帧对齐都会有）', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      _runQuiet(c, kAdaptiveCooldownTicks, currentIndex: 1, cacheSeconds: 1);
      expect(c.tick(currentIndex: 1, buffering: true, cacheSeconds: 0), isNull);
      expect(c.tick(currentIndex: 1, buffering: true, cacheSeconds: 0), isNull);
    });

    test('卡顿要落在同一个窗口里才算数（窗口滑过就重新计）', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      _runQuiet(c, kAdaptiveCooldownTicks, currentIndex: 1, cacheSeconds: 1);
      // 卡两拍……
      c.tick(currentIndex: 1, buffering: true, cacheSeconds: 0);
      c.tick(currentIndex: 1, buffering: true, cacheSeconds: 0);
      // ……然后顺畅地过完整个窗口，旧卡顿滑出窗口。
      _runQuiet(c, kAdaptiveStallWindowTicks, currentIndex: 1, cacheSeconds: 1);
      // 再卡两拍不该触发（窗口里只有这两拍）。
      expect(c.tick(currentIndex: 1, buffering: true, cacheSeconds: 0), isNull);
      expect(c.tick(currentIndex: 1, buffering: true, cacheSeconds: 0), isNull);
    });

    test('原画撑不住 → 落到受管档位里最高的那档，不是一路砸到最低', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      _runQuiet(c, kAdaptiveCooldownTicks, currentIndex: -1, cacheSeconds: 1);
      AdaptiveQualityDecision? decision;
      for (int i = 0; i < kAdaptiveStallTicksToDrop; i++) {
        decision ??= c.tick(currentIndex: -1, buffering: true, cacheSeconds: 0);
      }
      expect(decision?.targetIndex, kAdaptiveMaxIndex);
    });

    test('已经在最低档就不再降（没有更低的了）', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      final int last = kInterconnectQualityPresets.length - 1;
      _runQuiet(c, kAdaptiveCooldownTicks, currentIndex: last, cacheSeconds: 1);
      AdaptiveQualityDecision? decision;
      for (int i = 0; i < kAdaptiveStallTicksToDrop + 2; i++) {
        decision ??= c.tick(
          currentIndex: last,
          buffering: true,
          cacheSeconds: 0,
        );
      }
      expect(decision, isNull);
    });
  });

  group('升档（富余）', () {
    test('长时间不卡 + 缓冲一直很足 → 升一档', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      final int result = _runQuiet(
        c,
        kAdaptiveHeadroomQuietTicks + 5,
        currentIndex: 3,
      );
      expect(result, 2);
    });

    test('缓冲不够深就不升——「下载速度够」在按需下载下永远成立，不能当富余', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      final int result = _runQuiet(
        c,
        kAdaptiveHeadroomQuietTicks * 2,
        currentIndex: 3,
        cacheSeconds: kAdaptiveHeadroomCacheSeconds - 1,
      );
      expect(result, 3);
    });

    test('拿不到缓冲深度时不升档（宁可不动也不要赌）', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      int index = 3;
      for (int i = 0; i < kAdaptiveHeadroomQuietTicks * 2; i++) {
        final AdaptiveQualityDecision? d = c.tick(
          currentIndex: index,
          buffering: false,
        );
        if (d != null) index = d.targetIndex;
      }
      expect(index, 3);
    });

    test('升档天花板是受管最高档，不回原画', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      int index = 1;
      for (int i = 0; i < kAdaptiveHeadroomQuietTicks * 4; i++) {
        final AdaptiveQualityDecision? d = c.tick(
          currentIndex: index,
          buffering: false,
          cacheSeconds: 120,
        );
        if (d != null) index = d.targetIndex;
      }
      expect(index, kAdaptiveMaxIndex);
    });

    test('中途卡一下就重新计时（升档要迟钝）', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      int index = 3;
      for (int i = 0; i < kAdaptiveHeadroomQuietTicks - 5; i++) {
        final AdaptiveQualityDecision? d = c.tick(
          currentIndex: index,
          buffering: false,
          cacheSeconds: 60,
        );
        if (d != null) index = d.targetIndex;
      }
      c.tick(currentIndex: index, buffering: true, cacheSeconds: 0);
      // 再过原本足够的拍数之前，不该升档。
      for (int i = 0; i < 10; i++) {
        expect(
          c.tick(currentIndex: index, buffering: false, cacheSeconds: 60),
          isNull,
        );
      }
    });
  });

  group('换档后重新观察', () {
    test('降档之后立刻进入冷却，不会连着再降', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      _runQuiet(c, kAdaptiveCooldownTicks, currentIndex: 1, cacheSeconds: 1);
      AdaptiveQualityDecision? first;
      for (int i = 0; i < kAdaptiveStallTicksToDrop; i++) {
        first ??= c.tick(currentIndex: 1, buffering: true, cacheSeconds: 0);
      }
      expect(first, isNotNull);
      // 继续一直卡，冷却期内一次都不该再换。
      for (int i = 0; i < kAdaptiveCooldownTicks - 1; i++) {
        expect(
          c.tick(currentIndex: 2, buffering: true, cacheSeconds: 0),
          isNull,
        );
      }
    });

    test('reset 抹掉历史（换集 / 用户手动换档后重新起算）', () {
      final AdaptiveQualityController c = AdaptiveQualityController();
      _runQuiet(
        c,
        kAdaptiveCooldownTicks * 2,
        currentIndex: 1,
        cacheSeconds: 1,
      );
      c.reset();
      // reset 后又要重新熬过冷却期。
      for (int i = 0; i < kAdaptiveStallTicksToDrop; i++) {
        expect(
          c.tick(currentIndex: 1, buffering: true, cacheSeconds: 0),
          isNull,
        );
      }
    });
  });

  group('换档事务（失败回滚）', () {
    test('reload 返回 false → 共享档回到原值', () async {
      int? shared = 2;
      final bool ok = await runAdaptiveQualitySwitch(
        read: () => shared,
        write: (int? v) => shared = v,
        targetIndex: 4,
        reload: () async {
          expect(shared, 4, reason: '取流协商要读到目标档，必须先写');
          return false;
        },
      );
      expect(ok, isFalse);
      expect(shared, 2);
    });

    test('reload 抛错 → 共享档回到原值并重新抛出', () async {
      int? shared = 2;
      await expectLater(
        runAdaptiveQualitySwitch(
          read: () => shared,
          write: (int? v) => shared = v,
          targetIndex: 4,
          reload: () async => throw StateError('streamurl failed'),
        ),
        throwsStateError,
      );
      expect(shared, 2);
    });

    test('reload 返回 true → 保持目标档', () async {
      int? shared = 2;
      final bool ok = await runAdaptiveQualitySwitch(
        read: () => shared,
        write: (int? v) => shared = v,
        targetIndex: 4,
        reload: () async => true,
      );
      expect(ok, isTrue);
      expect(shared, 4);
    });

    test('reload 期间外部改了共享档 → 失败也不覆盖外部的值', () async {
      int? shared = 2;
      final bool ok = await runAdaptiveQualitySwitch(
        read: () => shared,
        write: (int? v) => shared = v,
        targetIndex: 4,
        reload: () async {
          shared = null; // 换源 / 用户手动选档清空了自适应档。
          return false;
        },
      );
      expect(ok, isFalse);
      expect(shared, isNull);
    });

    test('原值是 null（还没定档）时回滚回 null', () async {
      int? shared;
      await runAdaptiveQualitySwitch(
        read: () => shared,
        write: (int? v) => shared = v,
        targetIndex: 3,
        reload: () async => false,
      );
      expect(shared, isNull);
    });
  });

  group('起点判据（局域网 vs 公网）', () {
    test('局域网 / 本机 → 原画直传', () {
      for (final String url in <String>[
        'http://192.168.1.8:15001',
        'http://10.0.0.5:15001',
        'http://172.16.3.9:15001',
        'http://172.31.255.1:15001',
        'http://127.0.0.1:15001',
        'http://localhost:15001',
        'http://fushi-desktop.local:15001',
        'http://fushi-desktop:15001',
        'http://169.254.4.4:15001',
        'http://[fe80::1]:15001',
        'http://[fd12::9]:15001',
      ]) {
        expect(isPrivateNetworkHost(url), isTrue, reason: url);
        expect(resolveInterconnectAutoPreset(url), isNull, reason: url);
      }
    });

    test('公网 → 压到中档', () {
      for (final String url in <String>[
        'http://203.0.113.9:15001',
        'https://fushi.example.com',
        'http://172.32.0.1:15001', // 刚出私有段
        'http://192.169.0.1:15001',
        'http://11.0.0.1:15001',
      ]) {
        expect(isPrivateNetworkHost(url), isFalse, reason: url);
        expect(
          resolveInterconnectAutoPreset(url),
          kInterconnectQualityPresets[kInterconnectAutoQualityPresetIndex],
          reason: url,
        );
      }
    });

    test('CGNAT（Tailscale 之类隧道）算「在外面」——流量还是走对端上行', () {
      expect(isPrivateNetworkHost('http://100.64.0.1:15001'), isFalse);
      expect(isPrivateNetworkHost('http://100.127.255.254:15001'), isFalse);
    });

    test('解析不出主机名时按「在外面」处理（判错方向的代价不对称）', () {
      expect(isPrivateNetworkHost(null), isFalse);
      expect(isPrivateNetworkHost(''), isFalse);
      expect(isPrivateNetworkHost('   '), isFalse);
    });

    test('没有 scheme 的裸地址也认得出来', () {
      expect(isPrivateNetworkHost('192.168.1.8:15001'), isTrue);
      expect(isPrivateNetworkHost('203.0.113.9:15001'), isFalse);
    });

    test('自动档的起点是受管档位里的一个真档', () {
      expect(kAdaptiveAutoIndexIsValid, isTrue, reason: '自动起点下标必须落在档位表内');
    });
  });
}

/// 起点下标落在档位表内（越界的话自动档会在起播时抛）。
bool get kAdaptiveAutoIndexIsValid =>
    kInterconnectAutoQualityPresetIndex >= 0 &&
    kInterconnectAutoQualityPresetIndex < kInterconnectQualityPresets.length;
