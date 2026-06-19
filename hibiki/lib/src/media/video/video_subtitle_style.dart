import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';

/// media_kit 默认底部控制条的**进度条（seek bar）上缘**距视频底边的清空高度（逻辑像素）。
///
/// TODO-171（抄 B站）：字幕避让只需让出**进度条本身那一条**，不是整条底部按钮行。
/// media_kit 底部控制条在同一个 `Stack(bottomCenter)` 里自底向上堆：按钮行
/// （`buttonBarHeight: 56`，播放/快进/时间/全屏图标），进度条（seek bar）骑在按钮行
/// 上沿（桌面用 `Transform.translate(Offset(0, 16))` 把进度条下压、与按钮行顶部重叠）。
/// 真正会遮住字幕的只有进度条那一条，它落在距视频底约一个按钮行高（`buttonBarHeight`）
/// 处。故避让高度取 [_kButtonBarHeight]=56：字幕底缘抬到进度条上方一点点恰骑其顶，
/// 不再多抬整条按钮行 + 离底 margin（旧 `42 + 56 = 98` 把字幕顶过整条按钮行、飞进
/// 画面中上部，用户报「进度条出来把字幕往上顶太高很怪」）。
///
/// 旧值的 `42` 是 media_kit 导出常量 [kDefaultMaterialVideoControlsThemeData] 那套含
/// `bottomButtonBarMargin.bottom: 42` 的整体离底留白——它是控制条离屏幕底边的空白，
/// 不是遮挡字幕的实体，叠进避让只会凭空多抬一个 margin。Hibiki 实际 new 的桌面主题
/// （`MaterialDesktopVideoControlsThemeData`）走构造器默认（`bottomButtonBarMargin`
/// 只有左右、vertical=0），本就没有这 42px，故去掉它也更贴合 Hibiki 真实几何。
///
/// Hibiki 用自绘 `VideoSubtitleOverlay`（非 media_kit 内置字幕视图）。TODO-129 起字幕
/// **动态**避让：控制条出现时把字幕在用户位置之上抬到 `max(用户位置, 本值)`、隐藏时
/// 落回用户位置（由 [VideoSubtitleOverlay] 的 `controlsVisible` 驱动 `AnimatedPadding`，
/// TODO-161 取下限而非加法），不再像 TODO-089 那样把本值恒加进默认
/// [VideoSubtitleStyle.bottomPadding]。本常量是「控制条可见时字幕底缘骑到的进度条上缘
/// 高度」。
const double _kButtonBarHeight = 56;
const double kVideoControlsBottomReserve = _kButtonBarHeight;

/// 控制条可见时字幕要让出的「进度条上缘距视频底边的高度」（逻辑像素），由真实控制条
/// 几何加总而成，并随界面缩放（`uiScale`）放大（BUG-238）。
///
/// 背景（BUG-226/228 的失效区间）：避让用 `max(bottomPadding, reserve)`（取下限，
/// 非加法——加法会把高位字幕顶飞，BUG-226），但旧 reserve 是**常量** 56：
/// - 不随界面缩放（放大界面后控制条变高、reserve 不变 → 盖不住）；
/// - 桌面进度条骑按钮行上沿（约一个按钮行高）56 够用，但**移动端**进度条被抬到
///   `底部留白 + 按钮行 + 间距 + 进度条热区` 之上，上缘 ≈ 140px，远高于默认基线 75，
///   `max(75, 56)=75` 把字幕留在进度条**下面**被遮（用户报「只动了一点点」=实际 0）。
///
/// 故 reserve 必须 = 进度条上缘真实高度（按平台几何加总）×缩放，且 > 默认基线 75 才能
/// 让取下限真正抬升字幕盖过进度条。本函数把这套几何收敛成纯函数（页面与测试同源调用）：
/// - 桌面：进度条骑按钮行上沿 → reserve = 一个按钮行高（[buttonBarHeight]），保持
///   BUG-228「只让出进度条那一条、不抬过整条按钮行」的桌面观感，但现在随缩放变化；
/// - 移动：进度条整体被抬到按钮行上方 → reserve = [bottomChromeBaseline] + 系统底部
///   inset + [buttonBarHeight] + [seekBarButtonGap] + **可见轨道高** [seekBarTrackHeight]
///   + 字幕呼吸间距 [subtitleBreathingGap]（= 可见进度条**轨道上缘** + 一点点呼吸距离，
///   字幕底缘恰骑其上方）。
///
/// TODO-568（手机端字幕被顶飞 / 位置不对）：BUG-238 当初移动分支加的是
/// **`seekBarContainerHeight`（进度条触摸热区全高 ≈52×缩放）**，但 media_kit
/// `MaterialSeekBar` 把**可见轨道**放在容器底缘（`Alignment.bottomCenter`，
/// `third_party/media_kit_video/.../material.dart` 的 `seekBarAlignment` + 内层 Stack），
/// 可见轨道只占 `seekBarHeight`（≈5×缩放），容器其余 ~47×缩放 全是轨道**上方**的透明
/// 命中区。用整段热区高当 reserve → 字幕底缘被抬到热区**顶缘**，比可见进度条上缘还高出
/// ~47×缩放 的空白，字幕悬空「顶飞」（BUG-238 备注里预留的「真机微调项」，现兑现）。修正：
/// 改用**可见轨道高** [seekBarTrackHeight] + 小呼吸间距 [subtitleBreathingGap]，让字幕
/// 底缘骑在可见进度条上方一点点（不被遮、也不顶飞）。
///
/// 几何项均来自 `video_hibiki_page.dart` 的同名控制条 getter（已 ×uiScale）；本函数不再
/// 二次乘 uiScale，由调用方传入已缩放值，避免双重缩放。[bottomChromeBaseline] 是不随
/// 缩放的离底基线常量（与页面 `_videoBottomChromeBaseline` 一致），故在此显式加上而非
/// 乘缩放。
double videoSubtitleControlsReserve({
  required bool isDesktop,
  required double buttonBarHeight,
  required double seekBarButtonGap,
  required double seekBarTrackHeight,
  required double subtitleBreathingGap,
  required double bottomChromeBaseline,
  required double bottomSystemInset,
}) {
  if (isDesktop) {
    // 桌面进度条骑按钮行上沿：让出一个（已缩放的）按钮行高即可（BUG-228）。
    return buttonBarHeight;
  }
  // 移动可见进度条**轨道上缘** = 离底基线 + 系统 inset + 按钮行 + 进度条/按钮间距 +
  // 可见轨道高；再加字幕呼吸间距让字幕底缘骑在其上方一点点（不顶飞、不被遮，TODO-568）。
  return bottomChromeBaseline +
      bottomSystemInset +
      buttonBarHeight +
      seekBarButtonGap +
      seekBarTrackHeight +
      subtitleBreathingGap;
}

/// seek bar 章节刻度层（TODO-432）相对**控制条区域底边**的竖直锚定：返回紧贴轨道的刻度带
/// `bottom`（带底缘离控制条区底边的距离）与 `height`（带高）。纯函数，页面与测试同源。
///
/// 刻度带不取整个 seek bar 容器（会让竖线在桌面凭空高出一截），而是以**轨道中线**为中心、
/// 取 [tickHeight] 的一小段，让竖线只在轨道上下各探出一点点（既盖住轨道又不喧宾夺主）。
///
/// 与 media_kit + [videoSubtitleControlsReserve] 同源的几何（值均已 ×uiScale，本函数不再
/// 二次缩放，[bottomChromeBaseline] 例外为不随缩放的离底常量）：
/// - **桌面**：media_kit 把进度条骑在底部按钮行上沿（`Transform.translate(Offset(0,16))`
///   把进度条下压、与按钮行顶部重叠）。轨道中线大致落在距控制条底边一个按钮行高
///   （[buttonBarHeight]）处。
/// - **移动**：进度条容器底缘 = 离底基线 + 系统 inset + 按钮行 + 进度条/按钮间距
///   （= 页面 `seekBarBottom`），容器高 = [seekBarContainerHeight]，轨道在容器内
///   bottomCenter（贴容器底缘）→ 轨道中线 ≈ `seekBarBottom + seekBarTrackHeight/2`。
({double bottom, double height}) videoSeekBarTrackBand({
  required bool isDesktop,
  required double buttonBarHeight,
  required double seekBarButtonGap,
  required double seekBarContainerHeight,
  required double seekBarTrackHeight,
  required double bottomChromeBaseline,
  required double bottomSystemInset,
  required double tickHeight,
}) {
  final double trackCenter;
  if (isDesktop) {
    // 桌面：轨道骑按钮行上沿，中线 ≈ 一个按钮行高处。
    trackCenter = buttonBarHeight;
  } else {
    // 移动：轨道贴容器底缘（bottomCenter），中线 = seekBarBottom + 轨道半高。
    final double seekBarBottom = bottomChromeBaseline +
        bottomSystemInset +
        buttonBarHeight +
        seekBarButtonGap;
    trackCenter = seekBarBottom + seekBarTrackHeight / 2;
  }
  // 以轨道中线为中心展开 tickHeight：带底缘 = 中线 − 半高。
  return (bottom: trackCenter - tickHeight / 2, height: tickHeight);
}

/// Video subtitle appearance persisted as app preferences.
///
/// The default is a high-contrast caption look: fixed white text with a thick
/// black outline/shadow so it stays readable on any video regardless of the
/// active app theme (TODO-051). Weight and shadow thickness stay nullable so the
/// default thickness can follow the global UI size, while explicit user choices
/// remain fixed. [textColor]/[shadowColor] left null means "follow the theme"
/// (legacy data persisted before TODO-051), resolved via [resolveTextColor] /
/// [resolveShadowColor].
@immutable
class VideoSubtitleStyle {
  const VideoSubtitleStyle({
    required this.fontSize,
    required this.textColor,
    required this.fontWeight,
    required this.shadowColor,
    required this.shadowThickness,
    required this.backgroundColor,
    required this.backgroundOpacity,
    required this.bottomPadding,
  });

  static const int defaultFontWeight = 700;
  static const double defaultShadowThickness = 5;

  /// v1 持久化时代硬编码的默认阴影粗细（3px）。仅供 [decode] 把 v1 存的
  /// 该值迁移成 null（跟随 UI scale）用，不参与当前外观（当前默认是
  /// [defaultShadowThickness]=5）。与当前常量解耦，改默认不破坏旧数据迁移。
  static const double _v1LegacyShadowThickness = 3;

  /// High-contrast caption defaults (TODO-051): 36px bold WHITE text with a
  /// thick BLACK outline/shadow, no box. Fixed white/black instead of theme
  /// colors so subtitles stay legible on any video and don't wash out on
  /// low-contrast themes. [fontWeight]/[shadowThickness] stay null to follow the
  /// global UI scale ([defaultFontWeight] / [defaultShadowThickness] at 1.0).
  ///
  /// [bottomPadding] is the user's subtitle position only (default 75). It no
  /// longer bakes in the controls-bar clearance: TODO-129 made the self-drawn
  /// [VideoSubtitleOverlay] dodge the bar *dynamically* — when the controls show
  /// it lifts the subtitle to `max(this position, [kVideoControlsBottomReserve])`
  /// (the progress-bar upper edge) and drops back when they hide (driven by
  /// `controlsVisible`, lower-bound not addition — TODO-161). So the default
  /// stays at the natural 75 and is only nudged just above the progress bar
  /// while it is on screen, instead of being permanently raised (TODO-089) or
  /// lifted over the whole button row (TODO-171). Users who manually pick a
  /// position keep their value verbatim (no "is-manual" branch — it's the same
  /// field; the dynamic dodge takes the lower bound on top of it).
  static const VideoSubtitleStyle defaults = VideoSubtitleStyle(
    fontSize: 36,
    textColor: Color(0xFFFFFFFF),
    fontWeight: null,
    shadowColor: Color(0xFF000000),
    shadowThickness: null,
    backgroundColor: null,
    backgroundOpacity: 0,
    // 用户位置基线（不含控制条避让）：避让在控制条可见时由 overlay 动态叠加（TODO-129）。
    bottomPadding: 75,
  );

  final double fontSize;
  final Color? textColor;
  final int? fontWeight;
  final Color? shadowColor;
  final double? shadowThickness;
  final Color? backgroundColor;
  final double backgroundOpacity;
  final double bottomPadding;

  VideoSubtitleStyle copyWith({
    double? fontSize,
    Color? textColor,
    int? fontWeight,
    Color? shadowColor,
    double? shadowThickness,
    Color? backgroundColor,
    double? backgroundOpacity,
    double? bottomPadding,
  }) {
    return VideoSubtitleStyle(
      fontSize: fontSize ?? this.fontSize,
      textColor: textColor ?? this.textColor,
      fontWeight: fontWeight ?? this.fontWeight,
      shadowColor: shadowColor ?? this.shadowColor,
      shadowThickness: shadowThickness ?? this.shadowThickness,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
      bottomPadding: bottomPadding ?? this.bottomPadding,
    );
  }

  Color resolveTextColor(Color themeColor) => textColor ?? themeColor;
  Color resolveShadowColor(Color themeColor) => shadowColor ?? themeColor;
  Color resolveBackgroundColor(Color themeColor) =>
      backgroundColor ?? themeColor;

  int resolveFontWeight(double uiScale) {
    if (fontWeight != null) return fontWeight!;
    final double scale = _normalizeUiScale(uiScale);
    final int rounded = (defaultFontWeight * scale / 100).round() * 100;
    if (rounded < 100) return 100;
    if (rounded > 900) return 900;
    return rounded;
  }

  double resolveShadowThickness(double uiScale) {
    if (shadowThickness != null) return shadowThickness!;
    return (defaultShadowThickness * _normalizeUiScale(uiScale))
        .clamp(0, 12)
        .toDouble();
  }

  static String encode(VideoSubtitleStyle s) => jsonEncode(<String, dynamic>{
        '_v': 2,
        'fontSize': s.fontSize,
        'textColor': s.textColor?.toARGB32(),
        'fontWeight': s.fontWeight,
        'shadowColor': s.shadowColor?.toARGB32(),
        'shadowThickness': s.shadowThickness,
        'backgroundColor': s.backgroundColor?.toARGB32(),
        'backgroundOpacity': s.backgroundOpacity,
        'bottomPadding': s.bottomPadding,
      });

  static VideoSubtitleStyle decode(String? json) {
    if (json == null || json.isEmpty) return defaults;
    try {
      final dynamic d = jsonDecode(json);
      if (d is! Map) return defaults;
      final int version = d['_v'] is num ? (d['_v'] as num).round() : 1;
      double num2d(Object? v, double fallback) =>
          v is num ? v.toDouble() : fallback;
      int? colorArgb(Object? v) => v is num ? v.toInt() : null;
      int normalizeWeight(Object? v) {
        final int raw = v is num ? v.round() : defaultFontWeight;
        final int rounded = (raw / 100).round() * 100;
        if (rounded < 100) return 100;
        if (rounded > 900) return 900;
        return rounded;
      }

      int? readFontWeight(Object? v) {
        if (v is! num) return null;
        final int normalized = normalizeWeight(v);
        return version < 2 && normalized == defaultFontWeight
            ? null
            : normalized;
      }

      double? readShadowThickness(Object? v) {
        if (v is! num) return null;
        final double normalized = v.toDouble().clamp(0, 12).toDouble();
        // v1 数据存的是当时硬编码的默认阴影粗细（3px）= 「跟随 UI scale」，迁移成 null。
        // 用 v1 时代的字面值对照，而非当前 [defaultShadowThickness]（TODO-051 已改为
        // 5），否则改默认会把老用户的 3px 误当显式值钉死、不再跟随缩放。
        return version < 2 && normalized == _v1LegacyShadowThickness
            ? null
            : normalized;
      }

      // Colors round-trip verbatim: a stored ARGB int is honoured as an explicit
      // choice, a missing/null value stays null = "follow the theme" (legacy
      // data persisted before TODO-051, when defaults were theme-following).
      // White (0xFFFFFFFF) is the new default text color (TODO-051) and must
      // persist as an explicit value — no longer folded back to null.
      final int? argb = colorArgb(d['textColor']);
      final int? shadowArgb = colorArgb(d['shadowColor']);
      final int? backgroundArgb = colorArgb(d['backgroundColor']);
      return VideoSubtitleStyle(
        fontSize: num2d(d['fontSize'], defaults.fontSize).clamp(10, 72),
        textColor: argb == null ? null : Color(argb),
        fontWeight: readFontWeight(d['fontWeight']),
        shadowColor: shadowArgb == null ? null : Color(shadowArgb),
        shadowThickness: readShadowThickness(d['shadowThickness']),
        backgroundColor: backgroundArgb == null ? null : Color(backgroundArgb),
        backgroundOpacity: num2d(
          d['backgroundOpacity'],
          defaults.backgroundOpacity,
        ).clamp(0.0, 1.0),
        bottomPadding:
            num2d(d['bottomPadding'], defaults.bottomPadding).clamp(0, 400),
      );
    } catch (_) {
      return defaults;
    }
  }

  static double _normalizeUiScale(double uiScale) {
    return HibikiAppUiScale.normalize(uiScale);
  }
}

/// 字幕**真**描边画笔（BUG-323 / TODO-569）：把粗细 [thickness] 渲染成沿字形轮廓的
/// 单层描边，由底层 stroke [Text] 用本画笔描出、上层 fill [Text] 填正文（见
/// [VideoSubtitleOverlay] 的双层渲染）。[thickness] <= 0 返回 null（无描边）。
///
/// 根因（为什么 BUG-222 的 [buildSubtitleShadows] 没修好、用户报「一点没修好、还是
/// 残留黑字」）：那套方案用 8 个 `Shadow(blurRadius: thickness, offset: r)` 模拟描边。
/// Flutter 的 `Shadow` 不是沿轮廓描边，而是把**整个字形 glyph 用阴影色重绘一遍**再做
/// 高斯模糊 + 偏移。8 个方向 = 8 份模糊的黑色字形拷贝叠加。由于 `blurRadius`(=thickness)
/// 大于偏移半径(=thickness/2)，这些模糊黑字大面积重叠并外溢到字身周围 → 白字下方/旁边
/// 浮现一团能看清字形轮廓的黑色虚影 = 用户说的「残留在文字下方的黑字、双重/残影」。
/// 横竖屏切换 / 切句是「重灾区 / 必现」是因为旋转后 `uiScale` 变化把 thickness 经
/// [VideoSubtitleStyle.resolveShadowThickness] 放大（默认随缩放、clamp 到 12），thickness
/// 越大模糊黑字拷贝越大越糊、残影越重——不是状态残留，是 8 层模糊 glyph 拷贝的固有产物。
///
/// 真描边修复：`Paint()..style = PaintingStyle.stroke` 沿字形外轮廓画**一圈**线，宽度
/// [thickness]、`strokeJoin.round` 让转角圆滑（ASS/asbplayer outline 观感）。它精确贴合
/// 字身、单层、无模糊、无偏移拷贝 → 任何 thickness / 缩放 / 横竖屏都只是描边变粗变细，
/// 绝不产生第二个错位黑字。`strokeWidth = thickness`：描边线以轮廓为中线，向内外各占
/// thickness/2，可视外缘厚度约 thickness/2，与旧 [buildSubtitleShadows] 偏移半径
/// `thickness/2` 同量级，外观厚度延续、不需用户重设。
///
/// [color] 仍是用户/主题描边色（默认黑）。语义与旧路径一致：thickness=描边强度，0=无描边。
Paint? buildSubtitleStrokePaint(Color color, double thickness) {
  if (thickness <= 0) return null;
  return Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = thickness
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round
    ..color = color
    ..isAntiAlias = true;
}

/// 字幕描边阴影：把粗细 [thickness] 渲染成**贴合文字四周的对称描边/光晕**，而非
/// 单向下方的投影（BUG-222）。
///
/// 旧实现是一个 `Shadow(offset: Offset(0, thickness))` 纯向下位移的 drop shadow：
/// thickness 越大阴影越往下「掉」，字幕移动/换句时阴影与字身分离，观感像「阴影没跟住、
/// 总有残留」。字幕该有的是 ASS/asbplayer 式的 **outline**——阴影包住字身四周。
///
/// 做法：八个方向（上下左右 + 四对角）各放一个小偏移阴影，偏移半径取 `thickness/2`
/// （对角乘 ~0.707 归一成圆形描边），`blurRadius=thickness` 让描边软化成贴合字身的
/// 光晕。八向对称 → 合成结果围绕文字、无单向「掉落」感。thickness 仍是用户/缩放控制的
/// 描边强度（0 = 无描边），[color] 仍是用户/主题阴影色，语义不变。
///
/// 历史：字幕**正文**字符的描边已于 BUG-323 / TODO-569 改用 [buildSubtitleStrokePaint]
/// 的真描边（双层 [Text]），因为本函数的 8 个模糊 `Shadow` glyph 拷贝在大 thickness /
/// 缩放下会外溢成「残留黑字」。本函数仍保留给**收藏星角标**那枚 [Icon] 用——图标无文字
/// 双层渲染的对应物，且尺寸小、不在用户报的字幕文字残影范围内，沿用四周阴影即可。
///
/// [thickness] <= 0 返回空列表（无描边，与旧 `shadowThickness<=0` 分支等价）。
List<Shadow> buildSubtitleShadows(Color color, double thickness) {
  if (thickness <= 0) return const <Shadow>[];
  // 描边偏移半径：thickness 的一半，最小 0.5px 保证薄描边也成形。
  final double r = (thickness / 2).clamp(0.5, double.infinity).toDouble();
  final double diag = r * 0.70710678; // 对角归一成圆形描边（cos45°）。
  const List<({double dx, double dy})> dirs = <({double dx, double dy})>[
    (dx: 1, dy: 0),
    (dx: -1, dy: 0),
    (dx: 0, dy: 1),
    (dx: 0, dy: -1),
    (dx: 1, dy: 1),
    (dx: 1, dy: -1),
    (dx: -1, dy: 1),
    (dx: -1, dy: -1),
  ];
  return <Shadow>[
    for (final ({double dx, double dy}) d in dirs)
      Shadow(
        color: color,
        blurRadius: thickness,
        offset: Offset(
          (d.dx.abs() == d.dy.abs() ? diag : r) * d.dx,
          (d.dx.abs() == d.dy.abs() ? diag : r) * d.dy,
        ),
      ),
  ];
}
