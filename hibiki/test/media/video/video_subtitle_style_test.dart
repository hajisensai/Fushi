import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';

void main() {
  test('default is high-contrast white text + black outline (TODO-051)', () {
    const VideoSubtitleStyle s = VideoSubtitleStyle.defaults;
    expect(s.fontSize, 36);
    // 默认不再跟随主题：固定白字 + 黑描边，避免低对比主题下看不清。
    expect(s.textColor, const Color(0xFFFFFFFF));
    expect(s.shadowColor, const Color(0xFF000000));
    // 显式白/黑：resolve 时即便给了主题色也不被它覆盖。
    expect(
        s.resolveTextColor(const Color(0xFF112233)), const Color(0xFFFFFFFF));
    expect(
      s.resolveShadowColor(const Color(0xFF112233)),
      const Color(0xFF000000),
    );
    expect(s.fontWeight, isNull);
    expect(s.resolveFontWeight(1.0), 700);
    // 阴影粗细加大：默认 3 -> 5（黑描边更明显）。
    expect(s.shadowThickness, isNull);
    expect(VideoSubtitleStyle.defaultShadowThickness, 5);
    expect(s.resolveShadowThickness(1.0), 5);
    expect(s.backgroundColor, isNull);
    expect(s.backgroundOpacity, closeTo(0.0, 1e-9));
    // 默认位置是用户基线 75（TODO-129 反转 089 的恒抬升）：不再把控制条避让恒含进默认值，
    // 避让改由 overlay 在控制条可见时动态叠加。
    expect(s.bottomPadding, 75);
  });

  test('unconfigured weight and shadow follow app UI scale', () {
    const VideoSubtitleStyle s = VideoSubtitleStyle.defaults;

    expect(s.resolveFontWeight(2.0), 900);
    expect(s.resolveShadowThickness(2.0), 10); // 5 * 2.0
    expect(s.resolveFontWeight(0.5), 400);
    expect(s.resolveShadowThickness(0.5), 2.5); // 5 * 0.5
  });

  test('null color still means follow the active theme (legacy data)', () {
    // 旧数据（TODO-051 前默认）持久化时颜色为 null = 跟随主题；resolve 仍回退主题色。
    const VideoSubtitleStyle s = VideoSubtitleStyle(
      fontSize: 36,
      textColor: null,
      fontWeight: null,
      shadowColor: null,
      shadowThickness: null,
      backgroundColor: null,
      backgroundOpacity: 0,
      bottomPadding: 75,
    );
    const Color themeColor = Color(0xFF112233);

    expect(s.resolveTextColor(themeColor), themeColor);
    expect(s.resolveShadowColor(themeColor), themeColor);
    expect(s.resolveBackgroundColor(themeColor), themeColor);
  });

  test('decode of pre-TODO-051 stored data keeps theme-following (back-compat)',
      () {
    // 旧版本持久化的就是「跟随主题」的 defaults：textColor/shadowColor 为 null。
    // 这类老 JSON 反序列化后颜色必须仍是 null（不被新白/黑默认污染），保住旧外观。
    final VideoSubtitleStyle s = VideoSubtitleStyle.decode(
      '{"_v":2,"fontSize":36,"textColor":null,"shadowColor":null,'
      '"backgroundOpacity":0,"bottomPadding":75}',
    );
    expect(s.textColor, isNull);
    expect(s.shadowColor, isNull);
    const Color themeColor = Color(0xFF445566);
    expect(s.resolveTextColor(themeColor), themeColor);
    expect(s.resolveShadowColor(themeColor), themeColor);
  });

  test('default white/black round-trips and persists explicitly (TODO-051)',
      () {
    // 新默认（白字黑描边）encode->decode 必须如实存住，不再被「白=折叠成 null」吃掉。
    final VideoSubtitleStyle back = VideoSubtitleStyle.decode(
      VideoSubtitleStyle.encode(VideoSubtitleStyle.defaults),
    );
    expect(back.textColor, const Color(0xFFFFFFFF));
    expect(back.shadowColor, const Color(0xFF000000));
    // resolve 给主题色也不被覆盖（仍是显式白/黑）。
    expect(back.resolveTextColor(const Color(0xFF112233)),
        const Color(0xFFFFFFFF));
    expect(back.resolveShadowColor(const Color(0xFF112233)),
        const Color(0xFF000000));
  });

  test('explicit white text color is no longer folded to null', () {
    // 用户显式选白色：之前会被折叠成 null（退回主题色）；现在如实保留为白。
    final VideoSubtitleStyle s =
        VideoSubtitleStyle.decode('{"_v":2,"textColor":4294967295}');
    expect(s.textColor, const Color(0xFFFFFFFF));
  });

  test('encode/decode round-trips', () {
    const VideoSubtitleStyle s = VideoSubtitleStyle(
      fontSize: 30,
      textColor: Color(0xFFFF0000),
      fontWeight: 500,
      shadowColor: Color(0xFF112233),
      shadowThickness: 6,
      backgroundColor: Color(0xFF445566),
      backgroundOpacity: 0.2,
      bottomPadding: 40,
    );
    final VideoSubtitleStyle back =
        VideoSubtitleStyle.decode(VideoSubtitleStyle.encode(s));
    expect(back.fontSize, 30);
    expect(back.textColor, const Color(0xFFFF0000));
    expect(back.fontWeight, 500);
    expect(back.resolveFontWeight(2.0), 500);
    expect(back.shadowColor, const Color(0xFF112233));
    expect(back.shadowThickness, 6);
    expect(back.resolveShadowThickness(2.0), 6);
    expect(back.backgroundColor, const Color(0xFF445566));
    expect(back.backgroundOpacity, closeTo(0.2, 1e-9));
    expect(back.bottomPadding, 40);
  });

  test('encode/decode preserves explicit asb baseline choices', () {
    const VideoSubtitleStyle s = VideoSubtitleStyle(
      fontSize: 36,
      textColor: null,
      fontWeight: VideoSubtitleStyle.defaultFontWeight,
      shadowColor: null,
      shadowThickness: VideoSubtitleStyle.defaultShadowThickness,
      backgroundColor: null,
      backgroundOpacity: 0,
      bottomPadding: 75,
    );

    final VideoSubtitleStyle back =
        VideoSubtitleStyle.decode(VideoSubtitleStyle.encode(s));

    expect(back.fontWeight, VideoSubtitleStyle.defaultFontWeight);
    expect(back.shadowThickness, VideoSubtitleStyle.defaultShadowThickness);
    expect(back.resolveFontWeight(2.0), VideoSubtitleStyle.defaultFontWeight);
    expect(
      back.resolveShadowThickness(2.0),
      VideoSubtitleStyle.defaultShadowThickness,
    );
  });

  test('decode tolerates empty/garbage -> defaults', () {
    expect(VideoSubtitleStyle.decode('').fontSize, 36);
    // 垃圾 JSON 回退到新默认（白字），不再是 null=跟随主题。
    expect(VideoSubtitleStyle.decode('not json').textColor,
        const Color(0xFFFFFFFF));
    expect(VideoSubtitleStyle.decode('').textColor, const Color(0xFFFFFFFF));
    expect(VideoSubtitleStyle.decode('').shadowColor, const Color(0xFF000000));
  });

  test('decode migrates stored asb defaults to scale-derived defaults', () {
    // v1 数据存的是当时硬编码默认（fontWeight 700 / shadowThickness 3px）=「跟随
    // UI scale」，迁移成 null，让其继续跟随缩放。TODO-051 把默认阴影加大到 5px 后，
    // 这类「跟随默认」的旧数据 resolve 出新的 5px（享受加大阴影，非钉死在旧 3px）。
    final VideoSubtitleStyle s =
        VideoSubtitleStyle.decode('{"fontWeight":700,"shadowThickness":3}');

    expect(s.fontWeight, isNull);
    expect(s.shadowThickness, isNull);
    expect(s.resolveFontWeight(1.0), 700);
    expect(s.resolveShadowThickness(1.0), 5); // 加大后的默认（TODO-051）。
  });

  group('dynamic subtitle dodge of the bottom controls bar (TODO-129)', () {
    test(
        'default bottomPadding is the natural user baseline, NOT a forced lift',
        () {
      // TODO-129 反转 089：默认 bottomPadding 不再把控制条避让恒加进去（否则进度条
      // 隐藏时字幕也恒抬高、留一大块空白）。默认回到自然基线 75；避让改由 overlay 在
      // 控制条可见时动态叠加 [kVideoControlsBottomReserve]、隐藏时落回（见
      // video_subtitle_overlay_test.dart）。撤回修复（恒含避让 => 默认 >= 98）则本条变红。
      expect(VideoSubtitleStyle.defaults.bottomPadding, 75);
      expect(
        VideoSubtitleStyle.defaults.bottomPadding,
        lessThan(kVideoControlsBottomReserve),
        reason: '默认不应把控制条避让恒含进 bottomPadding（那是 089 的恒抬升，已反转）',
      );
    });

    test('controls reserve matches media_kit default bottom bar geometry', () {
      // 守卫：避让高度 = bottomButtonBarMargin.vertical(42) + buttonBarHeight(56)。
      // 若 media_kit 升级改了默认布局，这条会提醒重新核对常量。
      expect(kVideoControlsBottomReserve, 98);
    });

    test('an explicit user bottomPadding is honoured verbatim', () {
      // 「除非用户手动调位置」：用户显式选的任何值都如实尊重，不被默认 / 动态避让逻辑
      // 改写——模型里就是同一个字段，无「是否手动」分支。动态避让在 overlay 侧叠加在
      // 这个基线之上，不污染持久化的用户位置。
      final VideoSubtitleStyle back = VideoSubtitleStyle.decode(
        VideoSubtitleStyle.encode(
          VideoSubtitleStyle.defaults.copyWith(bottomPadding: 20),
        ),
      );
      expect(back.bottomPadding, 20);
    });
  });

  test('decode clamps out-of-range', () {
    final VideoSubtitleStyle s = VideoSubtitleStyle.decode(
        '{"fontSize":999,"fontWeight":9999,"shadowThickness":999,'
        '"backgroundOpacity":5,"bottomPadding":-10}');
    expect(s.fontSize, lessThanOrEqualTo(72));
    expect(s.fontWeight, 900);
    expect(s.shadowThickness, 12);
    expect(s.backgroundOpacity, lessThanOrEqualTo(1.0));
    expect(s.bottomPadding, greaterThanOrEqualTo(0));
  });
}
