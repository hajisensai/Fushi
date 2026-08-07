import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';

void main() {
  // TODO-916 症状④-B：字幕字符命中容差（纯函数 resolveSubtitleCharHit）。
  // 一排 10px 宽的字符，字符间有 4px 间隙（Wrap gap / 描边外缘）。
  List<Rect> row() => <Rect>[
        const Rect.fromLTWH(0, 0, 10, 20), // 0: x[0,10]
        const Rect.fromLTWH(14, 0, 10, 20), // 1: x[14,24]
        const Rect.fromLTWH(28, 0, 10, 20), // 2: x[28,38]
      ];

  test('精确命中：点落在字符矩形内返回该字符', () {
    expect(resolveSubtitleCharHit(row(), const Offset(5, 10)), 0);
    expect(resolveSubtitleCharHit(row(), const Offset(19, 10)), 1);
    expect(resolveSubtitleCharHit(row(), const Offset(33, 10)), 2);
  });

  test('落在字缝内：兜底命中最近字符（半字宽 = 5px 容差内）', () {
    // 字符 0 右缘 x=10、字符 1 左缘 x=14；缝中点 x=12 距两者各 2px < 5px 容差。
    final int hit = resolveSubtitleCharHit(row(), const Offset(12, 10));
    expect(hit, anyOf(0, 1), reason: '字缝内应兜底命中相邻字符之一');
    // 偏向字符 1 一侧（x=13，距 1 仅 1px、距 0 为 3px）→ 命中更近的 1。
    expect(resolveSubtitleCharHit(row(), const Offset(13, 10)), 1);
    // 偏向字符 0 一侧（x=11，距 0 仅 1px）→ 命中更近的 0。
    expect(resolveSubtitleCharHit(row(), const Offset(11, 10)), 0);
  });

  test('描边外缘垂直方向小幅 miss：在容差内兜底', () {
    // 字符 0 顶 y=0，点 y=-3（描边上缘外 3px，水平在字符内 x=5）→ 垂直容差内命中 0。
    expect(resolveSubtitleCharHit(row(), const Offset(5, -3)), 0);
    // 字符 0 底 y=20，点 y=23（描边下缘外 3px）→ 垂直容差内命中 0。
    expect(resolveSubtitleCharHit(row(), const Offset(5, 23)), 0);
  });

  test('超出容差：返回 -1（不误命中远处字符）', () {
    // x=50 远在所有字符右侧 > 半字宽 → miss。
    expect(resolveSubtitleCharHit(row(), const Offset(50, 10)), -1);
    // y=40 远在下方 > 垂直容差 → miss。
    expect(resolveSubtitleCharHit(row(), const Offset(5, 40)), -1);
  });

  test('BUG-825：垂直兜底容差是描边级，不放半字宽裙边溢出到进度条', () {
    // 真实场景：36px 字幕（宽≈36），底行字符紧贴其下方的视频进度条轨道。旧各向同性容差
    // = clamp(半字宽=18, 10, ∞) = 18px，向下也放 18px 裙边 → tap 落在字符正下方 12~15px
    // （已在进度条轨道顶部一条带）被误判成点字符、暂停视频弹查词、seek 被吞。
    final List<Rect> wide = <Rect>[const Rect.fromLTWH(0, 0, 36, 40)];
    // 字符底 y=40。正下方 15px（y=55，水平在字符内 x=18）：旧 18px 裙边会误命中，
    // 现垂直容差 6px → 必须 miss，让 tap 穿透到 media_kit 进度条 seek。
    expect(
      resolveSubtitleCharHit(wide, const Offset(18, 55)),
      -1,
      reason: 'BUG-825：字符正下方 15px 不得被误判命中（否则点进度条→暂停+查词）',
    );
    // 正下方 12px（y=52）同样 miss（仍在轨道带内）。
    expect(resolveSubtitleCharHit(wide, const Offset(18, 52)), -1);
    // 对照：水平方向半字宽（18px）兜底不受影响——字符右缘外 12px（x=48）仍命中，
    // 证明只收紧了垂直、没伤水平字缝兜底（TODO-916/971）。
    expect(resolveSubtitleCharHit(wide, const Offset(48, 20)), 0);
  });

  test('Rect.zero（无 RenderBox 的字符）被跳过', () {
    final List<Rect> rects = <Rect>[
      Rect.zero,
      const Rect.fromLTWH(0, 0, 10, 20),
    ];
    expect(resolveSubtitleCharHit(rects, const Offset(5, 10)), 1);
    expect(resolveSubtitleCharHit(rects, const Offset(500, 500)), -1);
  });

  test('空列表返回 -1', () {
    expect(resolveSubtitleCharHit(<Rect>[], const Offset(5, 10)), -1);
  });

  group('BUG-910：exactOnly（barrier 关闭判定用，跳过裙边兜底）', () {
    test('exactOnly：点落在字形内仍命中（切词意图保留）', () {
      // 字上 x=5 正落在字符 0 矩形内 → exactOnly 也命中（点字仍切词，TODO-758 不回归）。
      expect(
        resolveSubtitleCharHit(row(), const Offset(5, 10), exactOnly: true),
        0,
      );
      expect(
        resolveSubtitleCharHit(row(), const Offset(19, 10), exactOnly: true),
        1,
      );
    });

    test('exactOnly：字缝/描边 halo 一律 miss（点空白 → dismiss，不误判切词）', () {
      // 字缝 x=12（宽容差下会兜底命中相邻字符）：exactOnly 下必须 -1 → barrier 走 dismiss。
      expect(resolveSubtitleCharHit(row(), const Offset(12, 10)), anyOf(0, 1),
          reason: '对照：默认宽容差字缝会兜底命中');
      expect(
        resolveSubtitleCharHit(row(), const Offset(12, 10), exactOnly: true),
        -1,
        reason: 'exactOnly：字缝空白不命中，barrier 应 dismiss 而非切词重查',
      );
      // 字符 0 上缘外 3px（默认垂直容差内会命中）：exactOnly 下 miss。
      expect(resolveSubtitleCharHit(row(), const Offset(5, -3)), 0,
          reason: '对照：默认容差描边外缘会兜底命中');
      expect(
        resolveSubtitleCharHit(row(), const Offset(5, -3), exactOnly: true),
        -1,
        reason: 'exactOnly：字身外描边 halo 不命中',
      );
    });

    test('BUG-910 核心：字幕行水平裙边 halo 空白 exactOnly 必 miss', () {
      // 36px 字幕单字，右缘外 12px（x=48）在默认水平半字宽兜底内会命中（用户误以为点的是
      // 空白，却被吃成命中→切词重查死循环）。exactOnly 下 miss → barrier dismiss+续播。
      final List<Rect> wide = <Rect>[const Rect.fromLTWH(0, 0, 36, 40)];
      expect(resolveSubtitleCharHit(wide, const Offset(48, 20)), 0,
          reason: '对照：默认宽容差右缘 12px halo 会误命中');
      expect(
        resolveSubtitleCharHit(wide, const Offset(48, 20), exactOnly: true),
        -1,
        reason: 'BUG-910：字幕行右侧空白 halo exactOnly 必 miss，barrier 才会关闭续播',
      );
    });
  });

  test('TODO-971：默认容差 ≥ 10（手指比 6px 宽，放宽兜底命中）', () {
    // 极窄字符（width=4 → 半字宽=2）下，默认 minTolerance 决定实际容差。手指比 6px
    // 宽，旧 6.0 仍偏小，手机字幕点词常 miss。默认放宽到 ≥ 10：距字符 9px 的点必须
    // 兜底命中，证明默认容差至少 10。
    final List<Rect> narrow = <Rect>[const Rect.fromLTWH(0, 0, 4, 20)];
    // 点在字符右缘外 9px（x=13，char right=4 → 距 9）。容差 6 时 miss，容差 ≥ 10 命中。
    expect(
      resolveSubtitleCharHit(narrow, const Offset(13, 10)),
      0,
      reason: 'TODO-971：默认容差须 ≥ 10，距字符 9px 的点应兜底命中',
    );
    // 反向：距 11px（x=15）仍应 miss（容差不会无限放大，仍夹在 10 附近）。
    expect(
      resolveSubtitleCharHit(narrow, const Offset(15, 10)),
      -1,
      reason: '距 11px 超出 ~10px 容差应 miss，证明容差有界不误命中远处',
    );
  });
}
