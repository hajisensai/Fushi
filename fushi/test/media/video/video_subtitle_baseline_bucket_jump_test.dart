// BUG-1335：高分屏上「字幕渲染出来动一下才正常，只有特定的话会这样」。
//
// 根因：底部锚点 cue 有两处本该同源的判断用了不同的量——
//   分组键 (_positionKey)  用 **原始 MarginV**（PlayRes 像素）比用户基线 → 是否折进基线桶
//   渲染 padding (_paddingFor) 用 **缩放后 MarginV**（显示像素）取 max(基线, ·)
//
// 用户片源 PlayResY=720，用户基线 75，4K 显示（×3）：
//   Text_JP  MarginV=30 → 分组键判进基线桶，padding 却是 max(75, 90) = 90
//   OP_JP    MarginV=10 → 分组键判进基线桶，padding      max(75, 30) = 75
// 二者**同组**却不同 padding，而组的 padding 取自「组代表」(cues.first)；代表随活动集切换，
// padding 就在 75↔90 之间跳，AnimatedPadding 把 15px 差值动画播出来 = 用户看到的「动一下」。
// 1080p 下 Text_JP 缩放后 45 会被基线夹回 75、与 OP_JP 相同，故只有高分屏触发。
//
// libass/mpv 不跳，是因为它每条事件各自独立定位，没有「组代表」这个共享量。分组是 Hibiki
// 为消除同位叠印引入的，那么这个共享量就必须由**分组键唯一决定**，而不是由谁碰巧当代表。
//
// 本组测试钉死该不变量：**同分组键 → 同基线**。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';

void main() {
  const double userBase = 75;
  // 4K 显示区 2160 / PlayResY 720 = ×3
  double scaled(double raw) => raw * 3;

  double baselineOf(double? raw) => resolveBottomBaseline(
        userBase: userBase,
        rawMarginV: raw,
        scaledMarginV: raw == null ? null : scaled(raw),
      );

  group('基线桶不变量：同组 → 同基线（BUG-1335）', () {
    test('用户片源：4K 下 Text_JP(30) 与 OP_JP(10) 基线相同 —— 代表切换不再跳', () {
      expect(baselineOf(30), baselineOf(10),
          reason: '两者都被分组键判进基线桶，就必须有同一个基线，否则组代表一换字幕就跳');
      expect(baselineOf(30), userBase);
    });

    test('片源全部四个样式（30/15/10/10）在 4K 下基线一致', () {
      final Set<double> baselines = <double>{
        for (final double mv in <double>[30, 15, 10, 10]) baselineOf(mv)
      };
      expect(baselines, <double>{userBase}, reason: '基线桶内不得出现第二个基线值');
    });

    test('4K 与 1080p 表现一致（此前只有 4K 会逃出基线）', () {
      double at(double displayScale) => resolveBottomBaseline(
            userBase: userBase,
            rawMarginV: 30,
            scaledMarginV: 30 * displayScale,
          );
      expect(at(1.5), at(3.0), reason: '1080p 本就是 75（45 被基线夹掉），4K 也应是 75');
      expect(at(3.0), userBase);
    });

    test('无 MarginV / MarginV<=0 恒用用户基线（srt/vtt 像素级不变）', () {
      expect(baselineOf(null), userBase);
      expect(baselineOf(0), userBase);
      expect(baselineOf(-5), userBase);
    });
  });

  group('桶外语义不回归（TODO-1341）', () {
    test('真正的高位标题（MarginV=400 > 基线）仍按缩放值抬升', () {
      expect(baselineOf(400), scaled(400));
      expect(baselineOf(400), greaterThan(userBase));
    });

    test('恰好等于基线的 MarginV 落在桶内（判据是 <=）', () {
      expect(baselineOf(userBase), userBase);
    });

    test('刚超出基线的 MarginV 出桶，按缩放值抬升', () {
      expect(baselineOf(userBase + 1), scaled(userBase + 1));
    });

    test('单调不降：基线永不低于用户基线（控制条避让前提，TODO-129/161/238）', () {
      for (final double mv in <double>[1, 10, 30, 74, 75, 76, 400, 1000]) {
        expect(baselineOf(mv), greaterThanOrEqualTo(userBase));
      }
    });

    test('副字幕用自己的基线时，桶边界随之移动（层各自成立）', () {
      // 副字幕基线 200：MarginV=100 在主字幕(75)下出桶，在副字幕(200)下入桶。
      expect(
        resolveBottomBaseline(
            userBase: 75, rawMarginV: 100, scaledMarginV: 300),
        300,
      );
      expect(
        resolveBottomBaseline(
            userBase: 200, rawMarginV: 100, scaledMarginV: 300),
        200,
      );
    });
  });

  group('判据必须独立于缩放值（实现本条时踩过的坑）', () {
    // 首版让分组键调 resolveBottomBaseline(scaledMarginV: null) 再比 userBase 来判桶：
    // 缺缩放值时该函数回退 userBase，于是 MarginV=400 的高位标题被误判成「在基线桶」，
    // 与贴底对白折叠 —— 既有守卫（TODO-1341「大 MarginV 仍各自 authored 高度」）当场变红。
    // 故判据单独成函数、只看原始 MarginV。
    test('高位标题（400）不在基线桶，且该结论与是否有缩放值无关', () {
      expect(isBaselineBucketMarginV(userBase: userBase, rawMarginV: 400),
          isFalse);
    });

    test('基线桶判据对同一 rawMarginV 恒定，不随显示尺寸变化（BUG-709：组身份不漂移）', () {
      for (final double mv in <double>[10, 30, 74, 75, 76, 400]) {
        final bool bucket =
            isBaselineBucketMarginV(userBase: userBase, rawMarginV: mv);
        // 无论缩放到多大，桶归属不变。
        for (final double sc in <double>[1.0, 1.5, 3.0, 6.0]) {
          expect(
            resolveBottomBaseline(
                    userBase: userBase,
                    rawMarginV: mv,
                    scaledMarginV: mv * sc) ==
                userBase,
            bucket,
            reason: 'MarginV=$mv 在 ×$sc 下的桶归属必须与判据一致',
          );
        }
      }
    });
  });

  group('源码守卫：分组键与 padding 必须同源', () {
    final String src = File('lib/src/media/video/video_subtitle_overlay.dart')
        .readAsStringSync();

    test('_paddingFor 的底部基线走真相源，不得退回裸 max(userBase, scaledMarginV)', () {
      final int fn = src.indexOf('EdgeInsets _paddingFor(');
      expect(fn, greaterThanOrEqualTo(0));
      final int fnEnd = src.indexOf('\n  }', fn);
      final String body = src.substring(fn, fnEnd);
      expect(body, contains('resolveBottomBaseline('),
          reason: '底部基线必须问真相源，才能与分组键同源');
      expect(body, isNot(contains('math.max(userBase, scaledMarginV)')),
          reason: '裸 max 与分组键脱节，正是 BUG-1335 的形状');
    });

    test('_positionKey 的基线桶判据也走同一个真相源', () {
      final int fn = src.indexOf('String _positionKey(');
      expect(fn, greaterThanOrEqualTo(0));
      final int fnEnd = src.indexOf('\n  }', fn);
      final String body = src.substring(fn, fnEnd);
      expect(body, contains('isBaselineBucketMarginV('),
          reason: '分组判据与渲染基线必须共用同一个判据，脱节才在结构上不可能');
    });
  });
}
