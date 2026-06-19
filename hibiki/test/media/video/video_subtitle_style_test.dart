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
      // 控制条可见时对 [kVideoControlsBottomReserve] 取下限、隐藏时落回（见
      // video_subtitle_overlay_test.dart）。撤回修复（恒含避让 => 默认 = 75 + reserve）
      // 则本条变红。
      expect(VideoSubtitleStyle.defaults.bottomPadding, 75);
      // 反转 089 的核心：默认就是裸基线 75，不是「基线 + 整条控制条避让」的恒抬升合值。
      // TODO-171 把 reserve 降到 56（< 基线 75）后不能再用 `< reserve` 表达这层语义（默认
      // 基线本就高于进度条上缘 = 已避开进度条），改为直接守「不等于 089 的恒抬升合值」。
      expect(
        VideoSubtitleStyle.defaults.bottomPadding,
        isNot(75 + kVideoControlsBottomReserve),
        reason: '默认不应把控制条避让恒含进 bottomPadding（那是 089 的恒抬升，已反转）',
      );
    });

    test('controls reserve = 进度条上缘高度（一个按钮行），不再含整条按钮行 + margin 累加（TODO-171）',
        () {
      // TODO-171（抄 B站）根因守卫：避让只让出底部控制条的**进度条那一条**，不是整条
      // 底部按钮行。进度条骑在按钮行上沿，落在距视频底约一个按钮行高（buttonBarHeight=56）
      // 处，故避让高度 = 56。旧值 42 + 56 = 98 把字幕顶过整条按钮行 + 离底 margin（飞进
      // 画面中上部，用户报「进度条出来把字幕往上顶太高很怪」）。
      expect(kVideoControlsBottomReserve, 56,
          reason: '避让应只到进度条上缘（一个按钮行高 56），抄 B站只让出进度条那一条');
      // 防回退：撤回成 98 / 重新把 42 离底 margin 累加进来即转红。
      expect(kVideoControlsBottomReserve, isNot(98),
          reason: '不应再抬过整条按钮行 + 离底 margin（旧 42 + 56 = 98，TODO-171 已减小）');
      expect(kVideoControlsBottomReserve, lessThan(98),
          reason: '避让高度必须比旧的整条控制条高 98 小（只让出进度条上缘那一条）');
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

  group('videoSubtitleControlsReserve 按平台真实几何 + 随缩放（BUG-238）', () {
    // 视频页控制条几何基线（×1.0）：与 video_hibiki_page.dart 同名常量保持一致。
    const double buttonBarBase = 56;
    const double seekGapBase = 8;
    const double seekContainerBase = 52;
    const double chromeBaseline = 24; // 不随缩放的离底基线常量。

    double mobileReserve(double scale) => videoSubtitleControlsReserve(
          isDesktop: false,
          buttonBarHeight: buttonBarBase * scale,
          seekBarButtonGap: seekGapBase * scale,
          seekBarContainerHeight: seekContainerBase * scale,
          bottomChromeBaseline: chromeBaseline,
          bottomSystemInset: 0,
        );
    double desktopReserve(double scale) => videoSubtitleControlsReserve(
          isDesktop: true,
          buttonBarHeight: buttonBarBase * scale,
          seekBarButtonGap: seekGapBase * scale,
          seekBarContainerHeight: seekContainerBase * scale,
          bottomChromeBaseline: chromeBaseline,
          bottomSystemInset: 0,
        );

    test('移动端 reserve = 进度条上缘高度（基线 + 按钮行 + 间距 + 热区）且 > 默认基线 75', () {
      // 旧常量 56 < 默认基线 75 → max(75,56)=75 把字幕留在被抬高的移动进度条下面被遮
      // （用户报「只动一点点」=实际 0）。真实几何 reserve 必须盖过进度条上缘且 > 75，
      // 取下限 max(75, reserve) 才真正抬升字幕盖过进度条。
      // scale=1.0：24 + 56 + 8 + 52 = 140。
      expect(mobileReserve(1.0), closeTo(140, 0.001));
      expect(mobileReserve(1.0),
          greaterThan(VideoSubtitleStyle.defaults.bottomPadding),
          reason: '移动 reserve 必须 > 默认基线 75，否则 max 不抬升、字幕被进度条遮（根因）');
      // 防回退：撤回成旧常量 56 → 本条红（56 < 75）。
      expect(mobileReserve(1.0), greaterThan(kVideoControlsBottomReserve),
          reason: '真实几何 reserve 应远大于旧的常量 56');
    });

    test('系统底部 inset 计入移动 reserve（导航条唤回时进度条随之上移）', () {
      // 唤回手势导航条时进度条整体上移，字幕避让也要跟着抬高。
      expect(mobileReserve(1.0) + 48, closeTo(140 + 48, 0.001));
      final double withInset = videoSubtitleControlsReserve(
        isDesktop: false,
        buttonBarHeight: buttonBarBase,
        seekBarButtonGap: seekGapBase,
        seekBarContainerHeight: seekContainerBase,
        bottomChromeBaseline: chromeBaseline,
        bottomSystemInset: 48,
      );
      expect(withInset, closeTo(140 + 48, 0.001));
    });

    test('reserve 随界面缩放放大（缩放敏感几何项 ×scale）', () {
      // 旧常量 56 恒定不随缩放，放大界面后控制条变高、reserve 不变 → 盖不住（根因之二）。
      // 缩放敏感项（按钮行/间距/热区）随 scale 放大；离底基线常量不随缩放。
      expect(mobileReserve(2.0), greaterThan(mobileReserve(1.0)),
          reason: 'reserve 必须随界面缩放变大，否则放大界面后盖不住进度条');
      // scale=2.0：24 + (56+8+52)*2 = 24 + 232 = 256。
      expect(mobileReserve(2.0), closeTo(256, 0.001));
      // 桌面也随缩放：一个按钮行高 ×scale。
      expect(desktopReserve(2.0), greaterThan(desktopReserve(1.0)));
      expect(desktopReserve(2.0), closeTo(112, 0.001)); // 56 * 2.0
    });

    test('桌面 reserve = 一个按钮行高（进度条骑按钮行上沿，保 BUG-228 观感）', () {
      // 桌面进度条用 Transform.translate 骑在按钮行上沿，只需让出一个按钮行高；
      // 默认基线 75 已在其上（scale 1.0 时 max(75,56)=75），不被多抬（BUG-228）。
      expect(desktopReserve(1.0), closeTo(56, 0.001));
      expect(desktopReserve(1.0), lessThan(mobileReserve(1.0)),
          reason: '桌面 reserve 应小于移动（桌面进度条没被抬高）');
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

  group('buildSubtitleShadows (BUG-222 对称描边而非单向投影)', () {
    const Color c = Color(0xFF224466);

    test('thickness<=0 无描边', () {
      expect(buildSubtitleShadows(c, 0), isEmpty);
      expect(buildSubtitleShadows(c, -3), isEmpty);
    });

    test('正粗细生成八方向对称描边、无单向下方投影', () {
      final List<Shadow> shadows = buildSubtitleShadows(c, 6);
      // 八方向 → 多个阴影（不再是单个）。
      expect(shadows.length, 8);
      for (final Shadow s in shadows) {
        expect(s.color, c);
        expect(s.blurRadius, 6); // blurRadius == thickness
      }
      // 对称：所有偏移向量求和为零 → 围绕文字、无单向「掉落」。
      final double sumDx =
          shadows.fold(0.0, (double a, Shadow s) => a + s.offset.dx);
      final double sumDy =
          shadows.fold(0.0, (double a, Shadow s) => a + s.offset.dy);
      expect(sumDx, moreOrLessEquals(0, epsilon: 1e-6));
      expect(sumDy, moreOrLessEquals(0, epsilon: 1e-6));
      // 绝不含旧的「纯向下 Offset(0, thickness)」投影。
      expect(
        shadows.any((Shadow s) => s.offset == const Offset(0, 6)),
        isFalse,
      );
      // 也不含任何 dx==0 且 |dy| 等于整粗细的纯竖直大偏移（描边偏移是半粗细）。
      expect(
        shadows.any((Shadow s) => s.offset.dx == 0 && s.offset.dy.abs() >= 6),
        isFalse,
      );
    });

    test('描边偏移围绕文字四周（上下左右四个正交方向都有）', () {
      final List<Shadow> shadows = buildSubtitleShadows(c, 8);
      bool hasDir(double dx, double dy) => shadows.any((Shadow s) =>
          s.offset.dx.sign == dx.sign && s.offset.dy.sign == dy.sign);
      expect(hasDir(1, 0), isTrue); // 右
      expect(hasDir(-1, 0), isTrue); // 左
      expect(hasDir(0, 1), isTrue); // 下
      expect(hasDir(0, -1), isTrue); // 上（旧实现完全没有的方向）
    });
  });

  group('buildSubtitleStrokePaint (BUG-321 / TODO-569 真描边取代伪描边)', () {
    const Color c = Color(0xFF224466);

    test('thickness<=0 无描边（返回 null，不渲染描边层）', () {
      expect(buildSubtitleStrokePaint(c, 0), isNull);
      expect(buildSubtitleStrokePaint(c, -3), isNull);
    });

    test('正粗细返回 stroke 画笔：宽度==thickness、色==描边色、轮廓圆滑', () {
      final Paint? p = buildSubtitleStrokePaint(c, 6);
      expect(p, isNotNull);
      // 沿字形轮廓描边（PaintingStyle.stroke），不是填充——这是真描边的本质，
      // 区别于旧 buildSubtitleShadows 的「整字 glyph 模糊拷贝偏移」（残留黑字源）。
      expect(p!.style, PaintingStyle.stroke);
      // 描边宽度 == thickness（用户/缩放控制的描边强度，语义与旧路径一致）。
      expect(p.strokeWidth, 6);
      // Paint.color round-trip 后实例不严格 ==（colorSpace/浮点表示），比 ARGB32。
      expect(p.color.toARGB32(), c.toARGB32());
      // 转角/端点圆滑，贴合 ASS/asbplayer outline 观感、无尖刺。
      expect(p.strokeJoin, StrokeJoin.round);
      expect(p.strokeCap, StrokeCap.round);
      expect(p.isAntiAlias, isTrue);
    });

    test('strokeWidth 随 thickness 线性变化（缩放/横竖屏只改粗细、不产生残影）', () {
      // 真描边的关键不变量：任何 thickness 都只是描边变粗变细的单层轮廓，
      // 绝不像旧 8 层模糊 Shadow 那样在大 thickness 下外溢成第二个错位黑字。
      expect(buildSubtitleStrokePaint(c, 2)!.strokeWidth, 2);
      expect(buildSubtitleStrokePaint(c, 12)!.strokeWidth, 12);
    });
  });
}
