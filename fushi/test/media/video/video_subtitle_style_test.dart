import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';

void main() {
  test('default is high-contrast white text + soft black shadow (Niratan)', () {
    const VideoSubtitleStyle s = VideoSubtitleStyle.defaults;
    expect(s.fontSize, 36);
    // 默认不再跟随主题：固定白字 + 柔和黑投影（黑@0.9，抄 Niratan），低对比主题下也看清。
    expect(s.textColor, const Color(0xFFFFFFFF));
    expect(s.shadowColor, const Color(0xE6000000));
    // 显式白/黑@0.9：resolve 时即便给了主题色也不被它覆盖。
    expect(
        s.resolveTextColor(const Color(0xFF112233)), const Color(0xFFFFFFFF));
    expect(
      s.resolveShadowColor(const Color(0xFF112233)),
      const Color(0xE6000000),
    );
    expect(s.fontWeight, isNull);
    expect(s.resolveFontWeight(1.0), 700);
    // 阴影半径改回 Niratan 默认 3（柔和投影模糊半径，不再是 5px 硬描边）。
    expect(s.shadowThickness, isNull);
    expect(VideoSubtitleStyle.defaultShadowThickness, 3);
    expect(s.resolveShadowThickness(1.0), 3);
    expect(s.backgroundColor, isNull);
    expect(s.backgroundOpacity, closeTo(0.0, 1e-9));
    // 默认位置是用户基线 75（TODO-129 反转 089 的恒抬升）：不再把控制条避让恒含进默认值，
    // 避让改由 overlay 在控制条可见时动态叠加。
    expect(s.bottomPadding, 75);
  });

  test('unconfigured weight and shadow follow app UI scale', () {
    const VideoSubtitleStyle s = VideoSubtitleStyle.defaults;

    expect(s.resolveFontWeight(2.0), 900);
    expect(s.resolveShadowThickness(2.0), 6); // 3 * 2.0
    expect(s.resolveFontWeight(0.5), 400);
    expect(s.resolveShadowThickness(0.5), 1.5); // 3 * 0.5
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
    // 新默认（白字 + 黑@0.9 软投影）encode->decode 必须如实存住，不被「白=折叠成 null」吃掉。
    final VideoSubtitleStyle back = VideoSubtitleStyle.decode(
      VideoSubtitleStyle.encode(VideoSubtitleStyle.defaults),
    );
    expect(back.textColor, const Color(0xFFFFFFFF));
    expect(back.shadowColor, const Color(0xE6000000));
    // resolve 给主题色也不被覆盖（仍是显式白 / 黑@0.9）。
    expect(back.resolveTextColor(const Color(0xFF112233)),
        const Color(0xFFFFFFFF));
    expect(back.resolveShadowColor(const Color(0xFF112233)),
        const Color(0xE6000000));
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
    expect(VideoSubtitleStyle.decode('').shadowColor, const Color(0xE6000000));
  });

  test('decode migrates stored asb defaults to scale-derived defaults', () {
    // v1 数据存的是当时硬编码默认（fontWeight 700 / shadowThickness 3px）=「跟随
    // UI scale」，迁移成 null，让其继续跟随缩放。默认阴影半径现为 Niratan 的 3，故这类
    // 「跟随默认」的旧数据 resolve 出 3（与迁移锚点巧合同值，但语义各自独立）。
    final VideoSubtitleStyle s =
        VideoSubtitleStyle.decode('{"fontWeight":700,"shadowThickness":3}');

    expect(s.fontWeight, isNull);
    expect(s.shadowThickness, isNull);
    expect(s.resolveFontWeight(1.0), 700);
    expect(s.resolveShadowThickness(1.0), 3); // Niratan 默认半径。
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

  group('videoSubtitleControlsReserve 按平台真实几何 + 随缩放（BUG-238 / BUG-901）', () {
    // 视频页控制条几何基线（×1.0）：与 video_fushi_page.dart 同名常量保持一致。
    const double buttonBarBase = 56;
    const double seekGapBase = 8;
    // BUG-901：移动 reserve 抬到「进度条**触摸热区**上缘 + 呼吸间距」——热区含可见轨道
    // 上方那段透明可点 seek 区，字幕命中区要整体清出它才不与 seek 重叠误触（推翻 TODO-568
    // 只让可见轨道高 5 的取舍）。
    const double seekContainerBase =
        40; // 触摸热区全高（_videoSeekBarContainerHeightBase，TODO-971 收窄到 40）。
    const double breathingBase =
        8; // 字幕呼吸间距（_videoSubtitleSeekBarBreathingBase）。
    const double chromeBaseline = 24; // 不随缩放的离底基线常量。
    // BUG-1224：桌面控制条的进度条几何与移动端不同——热区高恒 36（fork 默认，不随缩放，
    // 页面 _videoDesktopSeekBarContainerHeight），且被 Transform.translate 下压 16 骑到
    // 按钮行上沿（_videoDesktopSeekBarButtonBarOverlap / fork 主题字段
    // seekBarBottomButtonBarOverlap）。
    const double desktopSeekContainer = 36;
    const double desktopSeekOverlap = 16;

    double mobileReserve(double scale) => videoSubtitleControlsReserve(
          isDesktop: false,
          buttonBarHeight: buttonBarBase * scale,
          seekBarButtonGap: seekGapBase * scale,
          seekBarContainerHeight: seekContainerBase * scale,
          // 移动端进度条被整体抬到按钮行上方、不下压，故无重叠量。
          seekBarBottomButtonBarOverlap: 0,
          subtitleBreathingGap: breathingBase * scale,
          bottomChromeBaseline: chromeBaseline,
          bottomSystemInset: 0,
        );
    double desktopReserve(double scale) => videoSubtitleControlsReserve(
          isDesktop: true,
          buttonBarHeight: buttonBarBase * scale,
          seekBarButtonGap: seekGapBase * scale,
          seekBarContainerHeight: desktopSeekContainer,
          seekBarBottomButtonBarOverlap: desktopSeekOverlap,
          subtitleBreathingGap: breathingBase * scale,
          bottomChromeBaseline: chromeBaseline,
          bottomSystemInset: 0,
        );

    // 移动端进度条触摸热区**上缘**离底高（= reserve 减去呼吸间距）：字幕命中区必须清出它
    // 才不与 seek 命中区重叠。scale=1.0：24 + 56 + 8 + 40 = 128。
    double seekHotzoneTop(double scale) =>
        chromeBaseline +
        (buttonBarBase + seekGapBase + seekContainerBase) * scale;

    // 桌面进度条触摸热区**上缘**离底高（BUG-1224）：热区下缘 = 按钮行高 − 下压量，
    // 上缘再加热区全高。scale=1.0：56 − 16 + 36 = 76（比按钮行高 56 还高出 20）。
    double desktopSeekHotzoneTop(double scale) =>
        buttonBarBase * scale - desktopSeekOverlap + desktopSeekContainer;

    test('移动端 reserve = 进度条触摸热区上缘 + 呼吸间距，字幕命中区整体清出 seek 命中区（BUG-901）', () {
      // 根因守卫：只让**可见轨道高** 5 的旧取舍（TODO-568）让 reserve 只抬到可见轨道上缘，
      // 字幕命中区落进轨道上方那段透明但可点的 seek 热区里，两命中区在同一手势竞技场重叠、
      // 手指差几像素就误触。改用**触摸热区全高** 40：字幕底缘骑在整段可点区上方一点点。
      // scale=1.0：24 + 56 + 8 + 40 + 8 = 136。
      expect(mobileReserve(1.0), closeTo(136, 0.001));
      // 核心不变量：reserve 必须 ≥ 进度条触摸热区上缘（清出整段 seek 命中区），差值 = 呼吸。
      expect(mobileReserve(1.0), greaterThanOrEqualTo(seekHotzoneTop(1.0)),
          reason: '字幕底缘必须骑在进度条触摸热区上缘之上，否则命中区与 seek 重叠误触（BUG-901）');
      expect(mobileReserve(1.0) - seekHotzoneTop(1.0),
          closeTo(breathingBase, 0.001),
          reason: 'reserve 应恰为热区上缘 + 一个呼吸间距');
      expect(mobileReserve(1.0),
          greaterThan(VideoSubtitleStyle.defaults.bottomPadding),
          reason: '移动 reserve 必须 > 默认基线 75，否则 max 不抬升、字幕被进度条遮');
      // BUG-901 防回退：撤回成只让**可见轨道高** 5（= 24+56+8+5+8 = 101，落进热区）→ 本条红。
      const double trackOnlyReserve = 24 + 56 + 8 + 5 + 8; // 101，旧 TODO-568 值。
      expect(mobileReserve(1.0), greaterThan(trackOnlyReserve),
          reason: '不应退回只让可见轨道高（101）——那让字幕命中区落进进度条透明热区、误触（BUG-901）');
    });

    test('系统底部 inset 计入移动 reserve（导航条唤回时进度条随之上移）', () {
      // 唤回手势导航条时进度条整体上移，字幕避让也要跟着抬高。
      expect(mobileReserve(1.0) + 48, closeTo(136 + 48, 0.001));
      final double withInset = videoSubtitleControlsReserve(
        isDesktop: false,
        buttonBarHeight: buttonBarBase,
        seekBarButtonGap: seekGapBase,
        seekBarContainerHeight: seekContainerBase,
        seekBarBottomButtonBarOverlap: 0,
        subtitleBreathingGap: breathingBase,
        bottomChromeBaseline: chromeBaseline,
        bottomSystemInset: 48,
      );
      expect(withInset, closeTo(136 + 48, 0.001));
    });

    test('reserve 随界面缩放放大（缩放敏感几何项 ×scale）', () {
      // 旧常量 56 恒定不随缩放，放大界面后控制条变高、reserve 不变 → 盖不住（根因之二）。
      // 缩放敏感项（按钮行/间距/热区/呼吸）随 scale 放大；离底基线常量不随缩放。
      expect(mobileReserve(2.0), greaterThan(mobileReserve(1.0)),
          reason: 'reserve 必须随界面缩放变大，否则放大界面后盖不住进度条');
      // scale=2.0：24 + (56+8+40+8)*2 = 24 + 224 = 248。
      expect(mobileReserve(2.0), closeTo(248, 0.001));
      // 缩放后仍清出热区上缘（差值 = 呼吸 ×scale）。
      expect(mobileReserve(2.0), greaterThanOrEqualTo(seekHotzoneTop(2.0)),
          reason: '任意缩放下字幕命中区都要清出进度条触摸热区（BUG-901）');
      // 桌面也随缩放：按钮行高 ×scale（热区高 / 下压量是 fork 常量，不随缩放）。
      expect(desktopReserve(2.0), greaterThan(desktopReserve(1.0)));
      // scale=2.0：112 − 16 + 36 + 8*2 = 148。
      expect(desktopReserve(2.0), closeTo(148, 0.001));
      expect(
          desktopReserve(2.0), greaterThanOrEqualTo(desktopSeekHotzoneTop(2.0)),
          reason: '任意缩放下桌面字幕也要清出进度条触摸热区（BUG-1224）');
    });

    test('桌面 reserve = 进度条触摸热区上缘 + 呼吸间距，点进度条不再被字幕吸走（BUG-1224）', () {
      // 根因守卫：旧实现桌面分支直接 `return buttonBarHeight`（56），那只是**可见轨道**
      // 所在高度。桌面 seek bar 的透明触摸热区高 36、被下压 16 骑按钮行上沿，热区上缘其实
      // 在 56 − 16 + 36 = 76 —— 比 56 高出 20px。字幕底缘停在 56（或默认基线 75）就压住这
      // 条带，而字幕层在 Stack 上层且对 glyph 命中主动吸收指针（_GlyphPriorityHitTest，
      // BUG-838）→ 用户点进度条上缘 = 弹查词、seek 收不到指针（悬停缩略图却照常出现，
      // 因为 hover 走 non-opaque MouseRegion 不被吸收）。
      // scale=1.0：56 − 16 + 36 + 8 = 84。
      expect(desktopReserve(1.0), closeTo(84, 0.001));
      // 核心不变量（与移动端同一条，无平台特例）：reserve ≥ 进度条触摸热区上缘。
      expect(
          desktopReserve(1.0), greaterThanOrEqualTo(desktopSeekHotzoneTop(1.0)),
          reason: '桌面字幕底缘必须骑在进度条触摸热区上缘之上，否则点进度条被字幕吸走成查词（BUG-1224）');
      expect(desktopReserve(1.0) - desktopSeekHotzoneTop(1.0),
          closeTo(breathingBase, 0.001),
          reason: 'reserve 应恰为热区上缘 + 一个呼吸间距');
      // BUG-1224 防回退：退回「只让一个按钮行高」(56) → 本条红。
      expect(desktopReserve(1.0), greaterThan(buttonBarBase),
          reason: '不应退回只让一个按钮行高——那让字幕压住进度条热区上缘 20px 带（BUG-1224）');
      // BUG-228 不回归：仍必须小于旧的「整条按钮行 + 离底 margin」98，字幕不被顶飞。
      expect(desktopReserve(1.0), lessThan(98),
          reason: '桌面避让仍不得抬过旧的 98（BUG-228 用户报「字幕被顶太高很怪」）');
      expect(desktopReserve(1.0), lessThan(mobileReserve(1.0)),
          reason: '桌面 reserve 应小于移动（桌面进度条没被整体抬到按钮行上方）');
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

  group('buildSubtitleStrokePaint (BUG-323 / TODO-569 真描边取代伪描边)', () {
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

  group('buildSubtitleSoftShadow (抄 Niratan 默认统一外观的柔和投影)', () {
    const Color c = Color(0xFF224466);

    test('thickness<=0 无投影（空列表）', () {
      expect(buildSubtitleSoftShadow(c, 0), isEmpty);
      expect(buildSubtitleSoftShadow(c, -3), isEmpty);
    });

    test('正粗细生成单枚柔和投影：色 / 模糊半径 / 向下 1px 偏移', () {
      final List<Shadow> shadows = buildSubtitleSoftShadow(c, 3);
      // 单枚（不是 8 向伪描边）→ 不会重现 BUG-222/323 的残留黑字。
      expect(shadows.length, 1);
      final Shadow s = shadows.single;
      expect(s.color, c);
      expect(s.blurRadius, 3); // blurRadius == thickness（模糊半径）
      // 向下偏移 1px（对应 Niratan `.shadow(..., y: 1)`）。
      expect(s.offset, const Offset(0, 1));
    });

    test('blurRadius 随 thickness 线性变化（仍单枚、偏移恒 (0,1)）', () {
      final Shadow s6 = buildSubtitleSoftShadow(c, 6).single;
      expect(s6.blurRadius, 6);
      expect(s6.offset, const Offset(0, 1));
      final Shadow s12 = buildSubtitleSoftShadow(c, 12).single;
      expect(s12.blurRadius, 12);
      expect(s12.offset, const Offset(0, 1));
    });
  });

  group('videoTopBarMargin (BUG-463/BUG-556 顶栏避让状态栏/刘海)', () {
    test('无系统 inset 时左右回退到默认 16、顶部为 0', () {
      // 隐栏 + 无刘海（padding 全 0）：左右不被叠出多余留白、顶部不下压。
      final EdgeInsets m = videoTopBarMargin(
        systemPadding: EdgeInsets.zero,
        systemViewPadding: EdgeInsets.zero,
        systemBarsVisible: false,
      );
      expect(m.left, 16);
      expect(m.right, 16);
      expect(m.top, 0);
    });

    test('隐栏时即使 padding.top 残留过渡值，顶部也不被下压', () {
      // BUG-556：iOS 横竖屏切换 / 系统栏临时显隐期间，padding.top 可能短暂带旧值。
      // 系统栏真实不可见时 top 必须归零，避免顶栏偶发下沉。
      final EdgeInsets m = videoTopBarMargin(
        systemPadding: const EdgeInsets.only(top: 42),
        systemViewPadding: const EdgeInsets.only(top: 59),
        systemBarsVisible: false,
      );
      expect(m.top, 0);
    });

    test('状态栏真实可见时用 viewPadding.top 把顶栏整体下压避让', () {
      // 上划临时唤出状态栏：顶栏 top = 真实物理 inset，按钮不再被盖。
      final EdgeInsets m = videoTopBarMargin(
        systemPadding: const EdgeInsets.only(top: 42),
        systemViewPadding: const EdgeInsets.only(top: 59),
        systemBarsVisible: true,
      );
      expect(m.top, 59);
      // 无横向 cutout 时左右仍是默认 16，不被 0 拉低。
      expect(m.left, 16);
      expect(m.right, 16);
    });

    test('横屏短边刘海：左右逐边取 max(16, inset)，不叠加成双重留白', () {
      // 刘海落在左侧（landscape）：左边取刘海高 48 > 16；右侧无刘海仍 16。
      final EdgeInsets m = videoTopBarMargin(
        systemPadding: EdgeInsets.zero,
        systemViewPadding: const EdgeInsets.only(left: 48, top: 0),
        systemBarsVisible: false,
      );
      expect(m.left, 48); // max(16, 48)
      expect(m.right, 16); // max(16, 0)
      expect(m.top, 0);
    });

    test('小于默认 16 的横向 inset 不会把 margin 拉低到 inset 以下', () {
      final EdgeInsets m = videoTopBarMargin(
        systemPadding: const EdgeInsets.only(left: 8, right: 4),
        systemViewPadding: EdgeInsets.zero,
        systemBarsVisible: false,
      );
      expect(m.left, 16); // max(16, 8)
      expect(m.right, 16); // max(16, 4)
    });
  });

  group('subtitleScreenScaleFactor (TODO-1199 字幕字号屏幕自适应)', () {
    test('小屏缩小 < 参考(≈1) < 大屏放大', () {
      // 参考短边 400 → 因子约 1（基准即所见）。
      expect(
          subtitleScreenScaleFactor(const Size(800, 400)), closeTo(1.0, 1e-9));
      // 小屏短边 360 < 400 → 因子 < 1（自动缩小），仍在 min 之上（未夹）。
      final double small = subtitleScreenScaleFactor(const Size(640, 360));
      expect(small, lessThan(1.0));
      expect(small, closeTo(0.9, 1e-9)); // 360/400
      // 大屏短边 560 → 因子 > 1（自动放大），未夹。
      final double large = subtitleScreenScaleFactor(const Size(1000, 560));
      expect(large, greaterThan(1.0));
      expect(large, closeTo(1.4, 1e-9)); // 560/400
    });

    test('取视口短边：横竖屏同尺寸得同因子', () {
      expect(
        subtitleScreenScaleFactor(const Size(400, 800)),
        subtitleScreenScaleFactor(const Size(800, 400)),
      );
    });

    test('夹上下限防极端；未布局(0)返回 1.0 不缩放', () {
      // 超小屏夹到 minFactor 0.85（100/400=0.25 被夹）。
      expect(subtitleScreenScaleFactor(const Size(100, 100)), 0.85);
      // 超大屏夹到 maxFactor 1.6（4000/400=10 被夹）。
      expect(subtitleScreenScaleFactor(const Size(4000, 4000)), 1.6);
      // 短边 <= 0（未布局）→ 1.0。
      expect(subtitleScreenScaleFactor(Size.zero), 1.0);
    });

    test('手动基准仍被尊重：有效字号 = 基准 × 因子（因子只是叠加乘数）', () {
      final double bigScreen = subtitleScreenScaleFactor(const Size(1000, 560));
      final double smallScreen =
          subtitleScreenScaleFactor(const Size(640, 360));
      // 同一基准在大屏比小屏放得更大。
      expect(36.0 * bigScreen, greaterThan(36.0 * smallScreen));
      // 同屏下有效字号与基准成正比（改基准 → 有效字号按比例变，手动可调）。
      expect(
        (48.0 * bigScreen) / (24.0 * bigScreen),
        closeTo(2.0, 1e-9),
      );
    });
  });
}
