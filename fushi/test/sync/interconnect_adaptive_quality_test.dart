import 'package:flutter_test/flutter_test.dart';
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
