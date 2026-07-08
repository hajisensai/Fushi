import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;

import 'package:hibiki/src/media/video/subtitle_pos_mapping.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// 命中字幕某字符的结果：整条字幕、被点 grapheme 下标、该字符的全局屏幕矩形。
/// 与 [VideoSubtitleOverlay.onCharTap] 的回调三元组同构。
typedef SubtitleCharHit = ({String sentence, int graphemeIndex, Rect charRect});

/// 给上层（查词浮层的 dismiss barrier）按全局坐标反查「点到的是哪个字幕字符」用的
/// 句柄。[VideoSubtitleOverlay] 在 build 时把自己的命中实现绑进来；上层持有同一个
/// 句柄对象、调 [hitTest]。常驻句柄、最近一次 build 的 overlay 覆盖绑定（全屏复用
/// 同一字幕 overlay 组件，故全屏路由会重新绑定其命中实现）。
///
/// 存在动机：查词浮层打开时，根 Overlay 的全屏 dismiss barrier 盖在字幕之上、会吞掉
/// 点击 → 点同句第二个词只会关栈+恢复播放，查不了第二个词。让 barrier 先用本句柄反查
/// 是否点到了字幕字符，是则切换查词（保持暂停），否则才 dismiss。
class VideoSubtitleHitTester {
  SubtitleCharHit? Function(Offset globalPos)? _impl;

  void bindHitTest(SubtitleCharHit? Function(Offset globalPos) impl) =>
      _impl = impl;

  SubtitleCharHit? hitTest(Offset globalPos) => _impl?.call(globalPos);
}

/// 按全局坐标在一组字符屏幕矩形里反查命中的字符下标（纯函数，可测）。
///
/// TODO-916 症状④：字幕字符之间有 [Wrap] 间隙 + 描边层不计入命中盒，落在字缝/描边
/// 外缘的点用「精确 [Rect.contains]」会全 miss、查不到词。两段判据消除 miss：
/// 1. 先精确包含：命中第一个 `contains(point)` 的字符（旧行为，零容差时等价）。
/// 2. 未命中则取**距点击点最近**的字符，且仅当该距离在合理阈值内才采纳——阈值取该候选
///    字符的半个宽度（再夹一个最小值 [minTolerance]，防极窄字符阈值过小），保证只在字缝/
///    描边一字之内兜底，不会跨到隔壁字符或远处误命中。
///
/// [Rect.zero]（无 RenderBox 的字符）跳过。无任何有效矩形或全部超阈值时返回 -1。
@visibleForTesting
int resolveSubtitleCharHit(
  List<Rect> charRects,
  Offset point, {
  // TODO-971：手指比 6px 宽，旧 6.0 下手机字幕点词常落在字缝/描边外缘 miss。
  // 放宽到 10.0，字缝/描边一字之内更易兜底命中（仍夹半字宽，不跨到隔壁字）。
  double minTolerance = 10.0,
}) {
  // 第一段：精确包含。
  for (int i = 0; i < charRects.length; i++) {
    final Rect r = charRects[i];
    if (r == Rect.zero) continue;
    if (r.contains(point)) return i;
  }
  // 第二段：最近字符兜底（在该字符半字宽 / [minTolerance] 容差内）。
  int bestIndex = -1;
  double bestDistance = double.infinity;
  for (int i = 0; i < charRects.length; i++) {
    final Rect r = charRects[i];
    if (r == Rect.zero) continue;
    final double dx = (point.dx.clamp(r.left, r.right)) - point.dx;
    final double dy = (point.dy.clamp(r.top, r.bottom)) - point.dy;
    final double distance = (dx * dx + dy * dy);
    if (distance >= bestDistance) continue;
    final double tolerance =
        (r.width / 2).clamp(minTolerance, double.infinity).toDouble();
    if (distance <= tolerance * tolerance) {
      bestDistance = distance;
      bestIndex = i;
    }
  }
  return bestIndex;
}

/// 视频底部当前句字幕 overlay；监听 [VideoPlayerController.currentCue]。
///
/// 字幕逐字符可点击：点击第 [int] 个 grapheme 时回调
/// `(sentence, graphemeIndex, charRect)`，调用方据此从该位置起取词查词（最长匹配
/// 交给 HoshiDicts），并用 [charRect]（被点字符的全局屏幕矩形）把查词浮层定位到
/// 字符附近。非字符区域不拦截指针，让底层 media_kit 控制（点击显隐控制条）正常工作。
///
/// [blurEnabled] 为听力沉浸模式：字幕默认打码（[ImageFiltered] 高斯模糊），桌面悬停
/// （[MouseRegion]）或移动端点击右上角「显形」热区后变清晰，再次移开/点击恢复。
/// 默认关闭，关闭时与历史外观完全一致。
class VideoSubtitleOverlay extends StatefulWidget {
  const VideoSubtitleOverlay({
    required this.controller,
    this.onCharTap,
    this.onCharHover,
    this.hoverAutoLookupEnabled = false,
    this.onHoverChanged,
    this.hitTester,
    this.isCueFavorited,
    this.blurEnabled = false,
    this.subtitleHidden = false,
    this.fontSize = 36,
    this.textColor,
    this.fontWeight = VideoSubtitleStyle.defaultFontWeight,
    this.shadowColor,
    this.shadowThickness = VideoSubtitleStyle.defaultShadowThickness,
    this.backgroundColor,
    this.backgroundOpacity = 0,
    this.bottomPadding = 75,
    this.controlsVisible,
    this.controlsBottomReserve = kVideoControlsBottomReserve,
    this.fontFamily,
    this.respectAssStyle = false,
    super.key,
  });

  final VideoPlayerController controller;

  /// 点击字幕第 [graphemeIndex] 个字符时回调，[sentence] 为整条字幕文本，
  /// [charRect] 为被点字符在全局坐标系下的矩形（弹窗定位用）。
  final void Function(String sentence, int graphemeIndex, Rect charRect)?
      onCharTap;

  /// 桌面 Shift-鼠标悬停查词（TODO-756a，与阅读器 `onShiftHover` 同语义）。按住 Shift 时鼠标
  /// 在字幕字符上移动即回调 `(sentence, graphemeIndex, charRect)`——与 [onCharTap] **同一条
  /// 查词链路**（页面侧都走 `_handleSubtitleLookupTap` → `_lookupAt`），故点击查词与 Shift-悬停
  /// 查词行为一致、零重写。命中节流（8px 阈值 + 同一字符不重复触发）由本组件内部承载，避免每帧
  /// hover 都查词。非 Shift 悬停 / 模糊态 / 空句不触发（与点击不查词一致）。null（移动端 / 测试 /
  /// 无控制条场景）= 不挂 Shift-悬停通道，外观与历史一致。
  final void Function(String sentence, int graphemeIndex, Rect charRect)?
      onCharHover;

  /// TODO-756b：是否“鼠标悬停即自动查词”。true 时 [_handleShiftHover] 不再要求按住
  /// Shift，纯悬停划过字幕字符即经 [onCharHover] 查词；false 时退回 756a 的
  /// Shift+悬停门控。由页面侧从 `ReaderHibikiSource.instance.hoverAutoLookup` 传入。
  /// 移动端无 OS hover，本标志为何值都不产生 hover 事件、自然不触发。
  final bool hoverAutoLookupEnabled;

  /// 鼠标进 / 出**字幕盒本身**（非整片视频区）时回调（BUG-283）。桌面用：字幕盒覆盖在
  /// media_kit 控制条之上，鼠标停字幕上读字 / 查词时，media_kit 控制条 2s 自动隐藏会让
  /// 画面光标被 `hideMouseOnControlsRemoval` 隐藏（用户报「鼠标放字幕上消失」）。页面据
  /// 本回调在 hover 字幕时唤回光标 + 续命控制条。null（测试 / 有声书 / 无控制条）= 不挂。
  final void Function(bool hovering)? onHoverChanged;

  /// 可选的字符命中句柄：build 时把按全局坐标反查字符的实现绑进来，供查词浮层的
  /// dismiss barrier「点同句换词保持暂停」用（见 [VideoSubtitleHitTester]）。
  final VideoSubtitleHitTester? hitTester;

  /// 当前字幕句是否已收藏（TODO-301 / BUG-264）。非 null 时，当前句已收藏会在字幕盒
  /// 起始处显示一枚实心星标记（与字幕列表行的收藏标记同语义）。null（测试 / 有声书等
  /// 无收藏数据源场景）= 不显示标记，外观与历史像素级一致。
  final bool Function(AudioCue cue)? isCueFavorited;

  /// 听力沉浸：字幕默认模糊，悬停/点击显形。
  final bool blurEnabled;

  /// 遮蔽模式「隐藏」（TODO-840 Part B）：为 true 时主字幕整条不渲染（即时返回空盒），
  /// 与 [blurEnabled] 正交且优先级更高（两者来自互斥的 [VideoSubtitleObscureMode]，
  /// 页面侧映射保证不会同时为 true，但即便同时为 true 也以隐藏为准）。默认 false =
  /// 不隐藏，外观与历史一致。隐藏只针对底部主字幕 overlay，不影响查词 / 字幕列表 /
  /// cue 同步等其它文本通道。
  final bool subtitleHidden;

  /// 字幕字号（外观设置）。
  final double fontSize;

  /// 字幕文字颜色（外观设置）。
  final Color? textColor;

  /// 字幕字重（CSS numeric weight 100..900；asbplayer 默认 700）。
  final int fontWeight;

  /// 字幕阴影颜色。
  final Color? shadowColor;

  /// 字幕阴影粗细；asbplayer 默认 3px。
  final double shadowThickness;

  /// 字幕背景颜色。
  final Color? backgroundColor;

  /// 字幕背景不透明度 0..1（外观设置；历史值 0.54 = Colors.black54）。
  final double backgroundOpacity;

  /// 字幕距底部的**用户位置**（外观设置）。控制条避让不含在此值里——TODO-129 起由
  /// [controlsVisible] 在控制条可见时对 [controlsBottomReserve] 取下限（max），此处只是
  /// 用户手选的基线位置。
  final double bottomPadding;

  /// media_kit 控制条当前是否可见（TODO-129/161）。非 null 时驱动字幕动态避让：可见时
  /// 字幕底部 padding 取 `max([bottomPadding], [controlsBottomReserve])`（字幕底缘骑到
  /// 控制条顶、躲开进度条），隐藏时落回 [bottomPadding] 基线（[AnimatedPadding] 平滑过渡）。
  /// 取下限而非加法：基线 < 控制条高时不会被顶飞、手选高位也不被改写。null（默认、测试、
  /// 有声书等无控制条场景）= 不避让，字幕恒贴 [bottomPadding] 基线（旧行为）。
  final ValueListenable<bool>? controlsVisible;

  /// 控制条可见时字幕底缘对其取下限的避让高度 = 底部控制条**进度条上缘**距视频底边的
  /// 高度。仅在 [controlsVisible] 非 null 时生效；基线 ≥ 本值则避让不抬（取基线）。
  ///
  /// 默认 [kVideoControlsBottomReserve]=56（桌面进度条骑按钮行上沿那一条，约一个按钮行
  /// 高，TODO-171/BUG-228；也是测试 / 无控制条场景的兜底）。视频页**显式传入**按平台真实
  /// 控制条几何加总 + 随界面缩放的值（`videoSubtitleControlsReserve`，BUG-238）：移动端
  /// 进度条被抬到按钮行上方，上缘 ≈140×缩放 > 默认基线 75，故取下限 `max(75,140)` 才真正
  /// 抬升盖过进度条；否则常量 56 < 75 → `max(75,56)=75` 把字幕留在进度条下面被遮。
  final double controlsBottomReserve;

  /// 字幕字体。传 null 时走平台默认；视频页传 app-wide reader custom font。
  final String? fontFamily;

  /// 是否尊重 .ass 字幕自带样式（TODO-1105）。为 true 时，字体名 / 主色 / 字号 / 描边色 /
  /// 描边宽 / 阴影色 / 阴影深度优先取 markup 里 ASS 解析出的值（行内 {...} 覆盖 > [V4+ Styles]
  /// cue 默认），缺失才回退用户统一样式（[fontFamily] / [textColor] / [fontSize] /
  /// [shadowColor] / [shadowThickness]）。为 false 时（默认）全部走 widget.* 统一样式，与历史
  /// 外观像素级一致（仅行内 \i \b \u \s \c \fs 这些旧就支持的 span 样式照旧生效——那是本开关
  /// 出现前既有行为、不受影响）。
  final bool respectAssStyle;

  @override
  State<VideoSubtitleOverlay> createState() => _VideoSubtitleOverlayState();
}

/// 字幕文字的 CJK 日文字体回退链（TODO-088）。
///
/// 字幕逐字符渲染成独立 [Text]，每个 [Text] 单独做字体选择。当主字体（用户在
/// TODO-049 设的 app 自定义字体，或某平台默认字体）不含某个字形时，缺失这条统一
/// 回退链就会让每个字符各自落到「引擎默认 fallback」——相邻字符可能挑到不同字体，
/// 单字（典型如假名「の」）字形与周围突兀不一致。
///
/// 这里给出覆盖五个出包平台主流系统日文字体的有序列表。Flutter 引擎按顺序解析、
/// 自动跳过当前平台不存在的字体名，故无需平台分支：
/// - Windows：`Yu Gothic` / `Yu Gothic UI` / `Meiryo` / `MS Gothic`
/// - macOS / iOS：`Hiragino Sans` / `Hiragino Kaku Gothic ProN`
/// - Android / Linux：`Noto Sans CJK JP` / `Noto Sans JP`
const List<String> _kSubtitleCjkFallback = <String>[
  'Yu Gothic',
  'Yu Gothic UI',
  'Hiragino Sans',
  'Hiragino Kaku Gothic ProN',
  'Noto Sans CJK JP',
  'Noto Sans JP',
  'Meiryo',
  'MS Gothic',
];

class _VideoSubtitleOverlayState extends State<VideoSubtitleOverlay> {
  bool _revealed = false;

  /// TODO-1312：当前帧渲染的所有字幕字符登记表（每帧 build 重建）。主字幕活动集（重叠
  /// cue 多个字幕盒）+ 副字幕活动集的**每个字符**各登记一条，携带所属整条 cue 文本、在该
  /// cue 内的 grapheme 下标、字符 context（求全局矩形）、及该字符所在层是否模糊。命中反查
  /// （[_hitEntryIndexAt] / [_charHitTest]）扫全表，故点主字幕 / 副字幕 / 重叠某条都能查到
  /// 正确的整句 + grapheme。旧的一维 `_charContexts`（单 cue、下标==grapheme）升级为二维。
  final List<_SubtitleCharEntry> _charEntries = <_SubtitleCharEntry>[];

  /// 最近一次 build 的字幕显示区高度（本 widget 的 LayoutBuilder 记录），供
  /// [_styleForGrapheme] 把 ASS 绝对字号 / 阴影深度按 显示区高 / PlayResY 缩放
  /// （TODO-1246）。在 LayoutBuilder builder 里赋值，早于 box 内各字符 Builder 回调
  /// 求值（同帧生效）。null=尚未布局，缩放退回 1.0。
  double? _lastLayoutHeight;

  /// TODO-916 症状④-A（down-snap）：onTapDown 时刻 [_hitEntryIndexAt] 命中的**登记表下标**
  /// （非 grapheme——二维登记后同一 grapheme 下标可能属不同 cue，故锁扁平 entry 下标），
  /// onTapUp 用它经 [_charHitByEntryIndex] 查词，使命中锁定按下时刻（字幕盒尚未被控制条避让
  /// 动画推移），而非 up 时刻的实时反查。-1 表示按下未命中字符。
  int _pendingTapEntry = -1;

  /// Shift-悬停查词的移动节流阈值（像素，TODO-756a）。与阅读器 `webview.part.dart` 的
  /// `dx*dx+dy*dy < 64`（8px）同构：鼠标移动距离平方未超 64 时不重新命中查词。
  static const double _kShiftHoverThresholdPx = 8;

  /// Shift-悬停查词节流状态（TODO-756a，与阅读器 8px 阈值同构）：上次触发查词的全局 hover
  /// 位置与命中的**登记表下标**。鼠标移动未超 [_kShiftHoverThresholdPx]、或仍落在同一字符上
  /// 时不重复查词（避免每帧 hover 都查），命中新字符或越过阈值才再次触发。`松开 Shift` /
  /// 离开字幕在 [_handleShiftHover] 里复位为 [Offset.zero] / -1，使下次按 Shift 重新进入即触发。
  Offset _lastShiftHoverPos = Offset.zero;
  int _lastShiftHoverEntry = -1;

  /// TODO-1312：按全局坐标在**全部**已渲染字幕字符（主字幕活动集含重叠 cue + 副字幕
  /// 活动集）里反查命中的登记表下标；模糊层字符按 [Rect.zero] 跳过（不参与命中，与点击
  /// 行为一致：模糊时不查词）。无命中返回 -1。是 [_charHitTest] / 竞技场门控 / 悬停查词
  /// 的共享命中内核。
  int _hitEntryIndexAt(Offset globalPos) {
    if (_charEntries.isEmpty) return -1;
    final List<Rect> rects = <Rect>[
      for (final _SubtitleCharEntry e in _charEntries)
        e.blurred ? Rect.zero : _globalRectOf(e.context),
    ];
    return resolveSubtitleCharHit(rects, globalPos);
  }

  /// 按全局坐标反查命中的字幕字符，返回其**所属整条 cue 文本** + 该 cue 内 grapheme 下标
  /// + 字符全局矩形。模糊 / 空 / 无命中返回 null。供 [VideoSubtitleHitTester] 绑定，
  /// 二维登记后点主字幕 / 副字幕 / 重叠某条都能查到正确的整句（TODO-1312）。
  SubtitleCharHit? _charHitTest(Offset globalPos) {
    final int i = _hitEntryIndexAt(globalPos);
    if (i < 0) return null;
    final _SubtitleCharEntry e = _charEntries[i];
    return (
      sentence: e.sentence,
      graphemeIndex: e.graphemeIndex,
      charRect: _globalRectOf(e.context),
    );
  }

  /// 按已知**登记表下标**取命中三元组（TODO-916 症状④-A 的 down-snap 用）：down 时刻已
  /// 经 [_hitEntryIndexAt] 确定命中的 entry 下标，up 时刻直接用该下标重算当前字符矩形即可，
  /// **不再**用 up 时刻的点重新反查——这样即便 down 唤起控制条致字幕盒在 down→up 间被避让
  /// 动画上移，命中仍锁定按下瞄准的那个字符。下标越界 / 模糊字符返回 null。
  SubtitleCharHit? _charHitByEntryIndex(int entryIndex) {
    if (entryIndex < 0 || entryIndex >= _charEntries.length) return null;
    final _SubtitleCharEntry e = _charEntries[entryIndex];
    if (e.blurred) return null;
    final Rect r = _globalRectOf(e.context);
    return (
      sentence: e.sentence,
      graphemeIndex: e.graphemeIndex,
      charRect: r,
    );
  }

  /// 桌面 Shift-鼠标悬停查词（TODO-756a）。仅在 [VideoSubtitleOverlay.onCharHover] 注册时由
  /// [MouseRegion.onHover] 调；语义与阅读器 `onShiftHover`（`webview.part.dart`）一致：
  /// 按住 Shift 在字幕字符上移动即对命中字符走查词。移动端无 OS hover、自然不触发。
  ///
  /// 节流（与阅读器 8px 阈值同构，避免每帧 hover 都查词）：
  /// - 未按 Shift：复位节流锚（[Offset.zero] / -1），下次按 Shift 进入即触发，并直接返回；
  /// - 按住 Shift 但移动距离平方 < [_kShiftHoverThresholdPx]² 且仍落在同一字符上：跳过（不重复查词）；
  /// - 越过阈值或命中新字符：刷新锚并经 [VideoSubtitleOverlay.onCharHover] 触发查词（页面侧
  ///   与点击查词同链路 `_handleSubtitleLookupTap` → `_lookupAt`）。
  ///
  /// 命中复用 [_charHitTest]（模糊态 / 空句返回 null → 不查词，与点击一致）。[PointerHoverEvent]
  /// 的 `position` 已是全局坐标，与 [_charHitTest] 的全局命中契约一致。
  void _handleShiftHover(PointerHoverEvent event) {
    final void Function(String, int, Rect)? onCharHover = widget.onCharHover;
    if (onCharHover == null) return;
    // TODO-756b：开了“悬停即查词”则纯悬停即触发，无需 Shift；否则退回 756a 的
    // Shift 门控。两路都共用同一节流锚与命中链路（onCharHover），仅门控判据不同。
    if (!widget.hoverAutoLookupEnabled &&
        !HardwareKeyboard.instance.isShiftPressed) {
      // 未开“悬停即查词”且未按 Shift：复位节流锚，使下次按 Shift 重新进入即触发
      // （不被旧锚误判为同位置）。
      _lastShiftHoverPos = Offset.zero;
      _lastShiftHoverEntry = -1;
      return;
    }
    final int entryIndex = _hitEntryIndexAt(event.position);
    if (entryIndex < 0) return;
    final _SubtitleCharEntry e = _charEntries[entryIndex];
    // 同一字符（同一登记表下标）+ 未越过移动阈值 → 不重复触发（节流）。命中新字符立即放行
    // （即使移动很小，也应换词查词，与阅读器逐字符 hover 一致）。
    final double dx = event.position.dx - _lastShiftHoverPos.dx;
    final double dy = event.position.dy - _lastShiftHoverPos.dy;
    final bool sameEntry = entryIndex == _lastShiftHoverEntry;
    if (sameEntry &&
        dx * dx + dy * dy < _kShiftHoverThresholdPx * _kShiftHoverThresholdPx) {
      return;
    }
    _lastShiftHoverPos = event.position;
    _lastShiftHoverEntry = entryIndex;
    onCharHover(e.sentence, e.graphemeIndex, _globalRectOf(e.context));
  }

  @override
  void didUpdateWidget(VideoSubtitleOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 关闭模糊时重置显形态，避免下次开启残留。
    if (!widget.blurEnabled && _revealed) _revealed = false;
  }

  void _setRevealed(bool v) {
    if (_revealed == v) return;
    setState(() => _revealed = v);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (BuildContext context, _) {
        // 每帧重置字符登记表并（重新）绑定命中句柄——空句也要绑定，使浮层打开但当前无字幕
        // 时 hitTest 返回 null（barrier 走 dismiss）。TODO-1312：登记表二维（主 + 副字幕）。
        _charEntries.clear();
        widget.hitTester?.bindHitTest(_charHitTest);

        // 主字幕活动集（重叠 cue 全渲染，TODO-1312）。遮蔽模式「隐藏」时主层不渲染
        // （TODO-840 Part B）——只影响底部主字幕，不影响副字幕 / 查词 / 字幕列表。
        final List<AudioCue> mainCues = widget.subtitleHidden
            ? const <AudioCue>[]
            : widget.controller.activeCues;
        // 副字幕活动集（TODO-1312：并入 Flutter overlay 多层渲染、可查词）。
        final List<AudioCue> secondaryCues =
            widget.controller.secondaryActiveCues;

        if (mainCues.isEmpty && secondaryCues.isEmpty) {
          return const SizedBox.shrink();
        }

        // 副字幕层放画面顶部（翻译参考，不夺主字幕位置）；主字幕层按 markup 锚点 / pos。
        // 二者几何不重叠。单层时直接返回该层（无 Stack 包裹），保持历史单字幕盒几何。
        final List<Widget> layers = <Widget>[
          if (secondaryCues.isNotEmpty)
            _buildSubtitleLayer(context, secondaryCues, isSecondary: true),
          if (mainCues.isNotEmpty)
            _buildSubtitleLayer(context, mainCues, isSecondary: false),
        ];
        if (layers.length == 1) return layers.single;
        return Stack(
          children: <Widget>[
            for (final Widget layer in layers) Positioned.fill(child: layer),
          ],
        );
      },
    );
  }

  /// TODO-1312 / TODO-1341：渲染一「层」字幕（主字幕或副字幕）。
  ///
  /// 主字幕层可能同时有多条时间重叠、但**锚点各异**的 cue（如 OP/ED 的顶部 \an8 歌词与
  /// 底部 \an2 对白同时在屏）。旧实现把整层所有活动 cue 塞进**一个** [Column]、再用单一
  /// 「代表」cue（currentCue）的 pos/anchor 定位——两条锚点不同的字幕于是被裹挟到同一处，
  /// 且代表 cue 随播放位置在两条间翻转时整列在顶 / 底来回跳（TODO-1341 根因）。
  ///
  /// 修复：按各自 markup 的 \pos / \an 锚点**分组**——同锚点的 cue 竖排堆叠进一个字幕盒，
  /// 不同锚点的 cue 各自独立定位（[Stack] 叠放），两条字幕**各就各位**、不再来回跳。每条
  /// cue 仍用**自己的** markup 逐字符描边 / 上色（双轨样式独立，各遵自带样式，TODO-1246）。
  ///
  /// [isSecondary]：副字幕层——强制置顶（画面顶部）、不吃自带 pos/anchor、不模糊、不显
  /// 收藏角标（副字幕=纯翻译参考），全部 cue 归一到一个顶部盒；但仍逐字符可查词（登记进
  /// 同一 [_charEntries]）。单组 / 单 cue 时结构退化为单字幕盒，与历史几何等价。
  Widget _buildSubtitleLayer(
    BuildContext context,
    List<AudioCue> cues, {
    required bool isSecondary,
  }) {
    // 听力沉浸模糊只主层、只播放中生效（暂停 / 查词时清晰，BUG-199；副字幕不模糊）。
    final bool blurred = !isSecondary &&
        widget.blurEnabled &&
        !_revealed &&
        widget.controller.isPlaying;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size container = constraints.biggest;
        // TODO-1246：记录显示区高度，供 _styleForGrapheme 缩放 ASS 绝对字号 / 阴影。
        // 本 builder 早于层内字符 Builder 回调求值，故同帧写入即可被读到。
        _lastLayoutHeight = container.height;

        // 按锚点 / \pos 分组：副层强制单组（顶部）；主层同位置的 cue 归一堆叠、不同位置的
        // cue 各自成组独立定位（TODO-1341）。
        final List<List<AudioCue>> groups = isSecondary
            ? <List<AudioCue>>[cues]
            : _groupMainCuesByPosition(cues);

        final List<Widget> positioned = <Widget>[
          for (final List<AudioCue> group in groups)
            _positionCueGroup(
              context,
              group,
              isSecondary: isSecondary,
              blurred: blurred,
              container: container,
            ),
        ];

        // 单组：直接返回该定位盒（历史单字幕盒几何像素级不变）。多组：Stack 叠放，各组用
        // Positioned.fill 填满同一层边界、按各自锚点定位互不重叠（TODO-1341）。
        if (positioned.length == 1) return positioned.single;
        return Stack(
          children: <Widget>[
            for (final Widget w in positioned) Positioned.fill(child: w),
          ],
        );
      },
    );
  }

  /// TODO-1341：把主字幕活动集按「有效定位」（\pos 分数 + 锚点，或纯锚点）分组，保留发现
  /// 顺序。同组的 cue 共享一个位置、竖排堆叠；不同组各自独立定位，从而顶部歌词与底部对白
  /// 不再被裹挟到同一处。返回每组的 cue 列表（组内顺序即活动集顺序）。
  List<List<AudioCue>> _groupMainCuesByPosition(List<AudioCue> cues) {
    final Map<String, List<AudioCue>> byKey = <String, List<AudioCue>>{};
    final List<List<AudioCue>> order = <List<AudioCue>>[];
    for (final AudioCue cue in cues) {
      final String key = _positionKey(cue.markup);
      final List<AudioCue>? existing = byKey[key];
      if (existing != null) {
        existing.add(cue);
      } else {
        final List<AudioCue> group = <AudioCue>[cue];
        byKey[key] = group;
        order.add(group);
      }
    }
    return order;
  }

  /// 一条 cue 的「有效定位」分组键（TODO-1341）：有 \pos 时按分数（+ 锚点），否则按锚点
  /// （竖直 + 水平对齐；null=历史底居中）。同键的 cue 同位置堆叠，不同键各自独立定位。
  static String _positionKey(SubtitleMarkup? markup) {
    final SubtitlePos? pf = markup?.posFraction;
    final SubtitleAnchor? a = markup?.anchor;
    final int av = a?.vertical.index ?? -1;
    final int ah = a?.horizontal.index ?? -1;
    if (pf != null) {
      return 'p:${pf.xFraction.toStringAsFixed(4)},'
          '${pf.yFraction.toStringAsFixed(4)}:$av:$ah';
    }
    return 'a:$av:$ah';
  }

  /// TODO-1341：把一个位置分组（同锚点的 cue 列表）渲染成**定位好**的字幕盒——竖排堆叠成
  /// [Column]、套查词点击 / 模糊 / 悬停交互（[_wrapInteractive]），再按该组代表 markup 的
  /// \pos / 锚点定位。副层强制顶部、不吃自带 pos。返回填满层边界（[Align] / [Stack]）、可
  /// 作 [Stack] 直接子的定位盒。
  Widget _positionCueGroup(
    BuildContext context,
    List<AudioCue> cues, {
    required bool isSecondary,
    required bool blurred,
    required Size container,
  }) {
    // 每条 cue 一个字幕盒，竖排堆叠（同锚点重叠 cue / 副字幕多行都在此堆叠，TODO-1312）。
    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        for (final AudioCue cue in cues)
          _buildCueBox(context, cue,
              isSecondary: isSecondary, blurred: blurred),
      ],
    );

    content = _wrapInteractive(context, content,
        isSecondary: isSecondary, blurred: blurred);

    // 定位代表 markup：副层强制顶部、不吃自带 pos；主层取本组首条（同组锚点 / pos 等价）。
    final SubtitleMarkup? posMarkup = isSecondary ? null : cues.first.markup;
    final Offset? posScreen = _posScreen(posMarkup, container);
    if (posScreen != null) {
      // pos 绝对定位（仅主层）：把字幕盒的 an 锚点精确落到映射坐标。
      final SubtitleAnchor anchor = posMarkup!.anchor ??
          const SubtitleAnchor(SubtitleVAlign.bottom, SubtitleHAlign.center);
      return Stack(
        children: <Widget>[
          Positioned(
            left: posScreen.dx,
            top: posScreen.dy,
            child: FractionalTranslation(
              translation: Offset(
                -_hFrac(anchor.horizontal),
                -_vFrac(anchor.vertical),
              ),
              child: content,
            ),
          ),
        ],
      );
    }
    // 副层强制顶部锚点（画面上方）；主层无 pos 按 markup 锚点（null → 历史底居中）。
    final SubtitleAnchor? anchor = isSecondary
        ? const SubtitleAnchor(SubtitleVAlign.top, SubtitleHAlign.center)
        : posMarkup?.anchor;
    return Align(
      alignment: _alignFor(anchor),
      child: _anchoredPadded(anchor, content),
    );
  }

  /// TODO-1312 / TODO-1341：给一「组」字幕盒套查词点击（[_SubtitleCharTapRecognizer]）、
  /// 听力沉浸模糊（仅主层）、桌面 hover（显形 / 光标唤回 / Shift-悬停查词）。定位在
  /// [_positionCueGroup] 里做，本方法只负责交互层包裹（原 _buildSubtitleLayer 中段抽出）。
  ///
  /// 字符点击查词：一片 translucent [RawGestureDetector]，其识别器只在按下点命中某字符时才
  /// 收指针进竞技场（BUG-553 门控）。命中反查扫全 [_charEntries]（含各组各层）。translucent
  /// 保证 hover 透传、media_kit 控制条唤起不被吞（BUG-198）。
  Widget _wrapInteractive(
    BuildContext context,
    Widget content, {
    required bool isSecondary,
    required bool blurred,
  }) {
    if (widget.onCharTap != null) {
      content = RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: <Type, GestureRecognizerFactory>{
          _SubtitleCharTapRecognizer:
              GestureRecognizerFactoryWithHandlers<_SubtitleCharTapRecognizer>(
            () => _SubtitleCharTapRecognizer(
              hitTestChar: (Offset globalPosition) =>
                  _hitEntryIndexAt(globalPosition) >= 0,
            ),
            (_SubtitleCharTapRecognizer instance) {
              instance
                ..onTapDown = (TapDownDetails details) {
                  _pendingTapEntry = _hitEntryIndexAt(details.globalPosition);
                }
                ..onTapUp = (TapUpDetails details) {
                  final SubtitleCharHit? hit =
                      _charHitByEntryIndex(_pendingTapEntry);
                  _pendingTapEntry = -1;
                  if (hit != null) {
                    widget.onCharTap!(
                        hit.sentence, hit.graphemeIndex, hit.charRect);
                  }
                }
                ..onTapCancel = () {
                  _pendingTapEntry = -1;
                };
            },
          ),
        },
        child: content,
      );
    }

    if (blurred) {
      // 模糊态（仅主层）：盖一层高斯模糊 + 拦字符点击（避免误触查词）+ 显形热区。
      content = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: content,
          ),
          Positioned.fill(
            child: GestureDetector(
              key: const Key('video-subtitle-reveal'),
              behavior: HitTestBehavior.translucent,
              onTap: () => _setRevealed(true),
            ),
          ),
        ],
      );
    }

    // 桌面悬停：①听力沉浸显形/复原（主层 blurEnabled）②向页面回报 hover（唤回光标 + 续命
    // 控制条，BUG-283/284）③Shift-鼠标悬停查词（TODO-756a）。三者合一个 opaque:false 的
    // MouseRegion（不阻断 hover 下探 media_kit，BUG-198）。仅确需 hover 时挂（外观零变化）。
    final bool needHover = (!isSecondary && widget.blurEnabled) ||
        widget.onHoverChanged != null ||
        widget.onCharHover != null;
    if (!needHover) return content;
    return MouseRegion(
      opaque: false,
      onEnter: (_) {
        if (!isSecondary && widget.blurEnabled) _setRevealed(true);
        widget.onHoverChanged?.call(true);
      },
      onHover: _handleShiftHover,
      onExit: (_) {
        if (!isSecondary && widget.blurEnabled) _setRevealed(false);
        widget.onHoverChanged?.call(false);
        _lastShiftHoverPos = Offset.zero;
        _lastShiftHoverEntry = -1;
      },
      child: content,
    );
  }

  /// TODO-1312：渲染一条 cue 的字幕盒（背景盒 + 逐字符描边文本 + 主层收藏角标）。逐字符
  /// 登记进 [_charEntries]（携带整条 cue 文本、该 cue 内 grapheme 下标、字符 context、模糊
  /// 态），供全局坐标反查命中。空文本 cue 返回零尺寸盒（不占位）。
  Widget _buildCueBox(
    BuildContext context,
    AudioCue cue, {
    required bool isSecondary,
    required bool blurred,
  }) {
    final String text = cue.text;
    if (text.isEmpty) return const SizedBox.shrink();
    final SubtitleMarkup? markup = cue.markup;
    final List<String> chars = text.characters.toList(growable: false);

    final Color backgroundColor = widget.backgroundOpacity <= 0
        ? Colors.transparent
        : (widget.backgroundColor ?? kDefaultSubtitleBackgroundColor)
            .withValues(alpha: widget.backgroundOpacity);

    Widget box = DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Wrap(
          alignment: WrapAlignment.center,
          children: <Widget>[
            for (int i = 0; i < chars.length; i++)
              Builder(
                builder: (BuildContext charContext) {
                  // 登记字符（所属 cue 文本 + 该 cue 内 grapheme 下标 + context + 模糊态）
                  // 供全局坐标反查。字符本身不各自包 opaque GestureDetector（会吞 hover /
                  // 光标，BUG-198）；tap 命中由上层 translucent RawGestureDetector + 本登记
                  // 表反查承载（BUG-553 竞技场门控）。
                  _charEntries.add(_SubtitleCharEntry(
                    sentence: text,
                    graphemeIndex: i,
                    context: charContext,
                    blurred: blurred,
                  ));
                  return _buildStrokedChar(chars[i], i, markup);
                },
              ),
          ],
        ),
      ),
    );

    // 当前句已收藏：字幕盒左上角外侧叠一枚实心星角标（TODO-301 / BUG-264）。仅主层
    // （副字幕=翻译参考，不制卡/不收藏）。[isCueFavorited] 为 null（测试 / 无数据源）不叠。
    if (!isSecondary) {
      final bool favorited = widget.isCueFavorited?.call(cue) ?? false;
      if (favorited) {
        final Color starColor =
            widget.textColor ?? Theme.of(context).colorScheme.tertiary;
        box = Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            box,
            Positioned(
              left: -6,
              top: -10,
              child: Icon(
                Icons.star,
                size: widget.fontSize * 0.6,
                color: starColor,
                shadows: buildSubtitleShadows(
                  widget.shadowColor ?? Theme.of(context).colorScheme.shadow,
                  widget.shadowThickness,
                ),
              ),
            ),
          ],
        );
      }
    }
    return box;
  }

  /// 渲染单个字幕字符为**真描边**：底层 stroke [Text]（[buildSubtitleStrokePaint] 沿
  /// 字形轮廓描一圈）+ 上层 fill [Text]（正文填充色）精确重叠（BUG-323 / TODO-569）。
  ///
  /// 描边色 / 描边宽默认取用户统一样式（[VideoSubtitleOverlay.shadowColor] /
  /// [VideoSubtitleOverlay.shadowThickness]）；开 [VideoSubtitleOverlay.respectAssStyle]
  /// 时优先取 .ass 的 \3c 描边色 / \bord 描边宽（行内 span > cueStyle，缺失回退统一样式，
  /// TODO-1105）。thickness<=0（无描边）时 [buildSubtitleStrokePaint] 返回 null，直接渲染
  /// 单层 fill [Text]（与历史无描边场景等价、零多余层）。
  Widget _buildStrokedChar(String char, int i, SubtitleMarkup? markup) {
    final TextStyle fillStyle = _styleForGrapheme(i, markup);
    final (Color strokeColor, double strokeWidth) = _resolveStroke(i, markup);
    final Paint? strokePaint =
        buildSubtitleStrokePaint(strokeColor, strokeWidth);
    if (strokePaint == null) {
      // 无描边：单层 fill（自带 ASS 阴影，若有）。
      return Text(char, style: fillStyle);
    }
    // 描边层：复制 fill 的所有几何属性，但用 foreground 画笔取代 color（Flutter 断言
    // foreground 与 color 不可共存，故显式重建而非 copyWith——copyWith 无法把 color 清空）。
    final TextStyle strokeStyle = fillStyle.copyWith(
      color: null,
      foreground: strokePaint,
      // 描边层不画下划线/删除线，避免与 fill 层重叠加粗装饰线（fill 层已画）。
      decoration: TextDecoration.none,
    );
    // 阴影只保留在描边层（最底）→ 正确 z 序（阴影 < 描边 < 填充）；填充层清空阴影防重叠。
    final bool hasShadows =
        fillStyle.shadows != null && fillStyle.shadows!.isNotEmpty;
    final TextStyle fillTopStyle =
        hasShadows ? fillStyle.copyWith(shadows: const <Shadow>[]) : fillStyle;
    return Stack(
      // 底层 stroke 先画（在下），上层 fill 后画（在上）盖住描边内缘，露出外缘成轮廓。
      children: <Widget>[
        Text(char, style: strokeStyle),
        Text(char, style: fillTopStyle),
      ],
    );
  }

  /// 解析第 [i] 个 grapheme 的**描边色 + 描边宽**（[_buildStrokedChar] 用）。
  ///
  /// respectAssStyle 关：恒返回用户统一 (shadowColor, shadowThickness)——与历史像素级一致。
  /// respectAssStyle 开：描边色取 span.\3c ?? cueStyle.OutlineColour ?? 统一色；描边宽取
  /// span.\bord ?? cueStyle.Outline ?? 统一宽（TODO-1105，行内覆盖 cue 默认覆盖统一样式），
  /// 且 ASS 描边宽按 显示区高/PlayResY 与字号同源缩放（TODO-1246，见下）。
  (Color, double) _resolveStroke(int i, SubtitleMarkup? markup) {
    final Color baseColor =
        widget.shadowColor ?? Theme.of(context).colorScheme.shadow;
    final double baseWidth = widget.shadowThickness;
    if (!widget.respectAssStyle || markup == null) {
      return (baseColor, baseWidth);
    }
    final SubtitleSpan? span = _spanAt(i, markup);
    final SubtitleCueStyle? cue = markup.cueStyle;
    final int? outlineArgb = span?.outlineColorArgb ?? cue?.outlineColorArgb;
    // ASS `Outline`/`\bord` 描边宽是相对 PlayResY 的**绝对像素**（`ScaledBorderAndShadow: yes`
    // 时随画面缩放，anime .ass 普遍如此），必须与字号（BUG-604 已按 显示区高/PlayResY 缩放）
    // **同源缩放**到显示尺寸；否则在小于 PlayResY 的显示区里，描边相对**已缩放**的字号偏粗——
    // 大制作字幕（PlayResY=1080、Outline=2.5）设计的细描边被渲染成一圈过重的黑边，「尊重自带
    // 样式」名不副实（用户报开关无明显区别；TODO-1246）。回退到用户统一描边宽（[baseWidth]，
    // 已是逻辑像素）时不缩放。缩放结果夹到 [0.5, 24] 防 PlayResY 缺失/异常时描边消失或撑爆
    // （与 _resolveAssShadows 阴影深度夹同量级）。
    final double? outlineWidthAss = span?.outlineWidthPx ?? cue?.outlineWidthPx;
    final double outlineWidth = outlineWidthAss != null
        ? (outlineWidthAss * _assFontScale(markup)).clamp(0.5, 24.0).toDouble()
        : baseWidth;
    return (
      outlineArgb != null ? Color(outlineArgb) : baseColor,
      outlineWidth,
    );
  }

  /// 覆盖第 [i] 个 grapheme 的行内 span（半开区间命中）；无则 null。
  SubtitleSpan? _spanAt(int i, SubtitleMarkup? markup) {
    if (markup == null) return null;
    for (final SubtitleSpan s in markup.spans) {
      if (i >= s.startGrapheme && i < s.endGrapheme) return s;
    }
    return null;
  }

  /// 合并外观默认与覆盖第 [i] 个 grapheme 的 span 样式（**填充层**，不含描边——描边由
  /// [_buildStrokedChar] 的底层 stroke [Text] 单独承载，BUG-323 / TODO-569）。
  ///
  /// respectAssStyle 关：只应用行内 `\i \b \u \s \c \fs` 这些历史就支持的 span 样式，字体 /
  /// 字号 / 颜色的基线恒为用户统一样式，与历史像素级一致。
  /// respectAssStyle 开：字体名 / 主色 / 字号 / 粗斜下删线优先取 .ass 值（行内 span >
  /// [SubtitleCueStyle] cue 默认 > 用户统一样式，TODO-1105）。字体缺字时仍挂
  /// [_kSubtitleCjkFallback] 兜底。
  TextStyle _styleForGrapheme(int i, SubtitleMarkup? markup) {
    final bool respect = widget.respectAssStyle && markup != null;
    final SubtitleCueStyle? cue = respect ? markup.cueStyle : null;
    final SubtitleSpan? span = _spanAt(i, markup);

    // 基线字体 / 颜色 / 字号：respect 时先叠 cueStyle（V4+ Styles）默认，否则恒用户统一样式。
    final String? baseFontFamily =
        (respect ? cue?.fontName : null) ?? widget.fontFamily;
    final Color baseColor = (respect && cue?.primaryColorArgb != null)
        ? Color(cue!.primaryColorArgb!)
        : (widget.textColor ?? Theme.of(context).colorScheme.onSurface);
    // ASS 绝对字号（PlayRes 像素）按 显示区高 / PlayResY 缩放到播放尺寸（TODO-1246）；
    // cueStyle 无字号时回退用户统一样式（已含 subtitleScreenScaleFactor）。
    final double assFontScale = respect ? _assFontScale(markup) : 1.0;
    final double? cueFontPx = respect ? cue?.fontSizePx : null;
    final double baseFontSize = cueFontPx != null
        ? _scaleAssFontSize(cueFontPx * assFontScale)
        : widget.fontSize;
    final FontWeight baseWeight = (respect && (cue?.bold ?? false))
        ? FontWeight.bold
        : _fontWeight(widget.fontWeight);

    final TextStyle base = TextStyle(
      color: baseColor,
      fontSize: baseFontSize,
      height: 1.3,
      fontFamily: baseFontFamily,
      // 统一的 CJK 日文回退链：主字体（自定义或平台默认）缺某字形（如假名「の」缺字）
      // 时，引擎按本列表顺序找到第一个存在的系统日文字体，而非各字符独立走引擎默认
      // fallback（不同字符可能落到不同字体、字形割裂）。引擎自动忽略当前平台不存在的
      // 项，故一条列表覆盖全平台、无需平台分支（TODO-088）。
      fontFamilyFallback: _kSubtitleCjkFallback,
      fontWeight: baseWeight,
      // cueStyle 的斜体 / 下划线 / 删除线（respect 时）作为基线，行内 span 可再覆盖。
      fontStyle: (respect && (cue?.italic ?? false)) ? FontStyle.italic : null,
      decoration: (respect) ? _cueDecoration(cue) : null,
      // ASS 阴影（Shadow 深度 + BackColour；行内 span 覆盖 cueStyle 默认）映射成向右下
      // 的硬投影（TODO-1246）。respect 关或无阴影时为 null，与历史像素级一致。
      shadows: respect ? _resolveAssShadows(span, cue, assFontScale) : null,
    );
    if (span == null) return base;

    final List<TextDecoration> decos = <TextDecoration>[];
    if (span.underline) decos.add(TextDecoration.underline);
    if (span.strike) decos.add(TextDecoration.lineThrough);
    // 行内 \fn 字体（respect 时）：优先于 base 的 cue 字体 / 统一字体。
    final String? spanFontFamily = (respect ? span.fontName : null);
    return base.copyWith(
      fontFamily: spanFontFamily,
      fontStyle: span.italic ? FontStyle.italic : null,
      fontWeight: span.bold ? FontWeight.bold : null,
      color: span.colorArgb != null ? Color(span.colorArgb!) : null,
      // 行内字号（respect 时）同按 ASS 缩放；respect 关时保持历史裸像素（旧 span 行为）。
      fontSize: span.fontSizePx != null
          ? (respect
              ? _scaleAssFontSize(span.fontSizePx! * assFontScale)
              : span.fontSizePx!)
          : base.fontSize,
      decoration: decos.isEmpty ? null : TextDecoration.combine(decos),
    );
  }

  /// [SubtitleCueStyle] 的下划线 / 删除线合成 [TextDecoration]（respect 基线用）；都无则 null。
  static TextDecoration? _cueDecoration(SubtitleCueStyle? cue) {
    if (cue == null) return null;
    final List<TextDecoration> decos = <TextDecoration>[];
    if (cue.underline ?? false) decos.add(TextDecoration.underline);
    if (cue.strikeOut ?? false) decos.add(TextDecoration.lineThrough);
    return decos.isEmpty ? null : TextDecoration.combine(decos);
  }

  static FontWeight _fontWeight(int value) {
    final int index = ((value.clamp(100, 900) ~/ 100).clamp(1, 9)) - 1;
    return FontWeight.values[index];
  }

  /// ASS 字号 / 阴影深度是相对 [SubtitleMarkup.playResY] 的绝对像素（TODO-1246）；本因子把
  /// 它们缩放到当前字幕显示区高度（[_lastLayoutHeight]，由 build 的 LayoutBuilder 记录）。
  /// 缺 playResY / 未布局时返回 1.0（不缩放，历史行为）。
  double _assFontScale(SubtitleMarkup? markup) {
    final double? playResY = markup?.playResY;
    final double? displayH = _lastLayoutHeight;
    if (playResY == null ||
        playResY <= 0 ||
        displayH == null ||
        displayH <= 0) {
      return 1.0;
    }
    return displayH / playResY;
  }

  /// 缩放后的 ASS 字号夹到合理范围：下限 8px、上限 = 显示区高的 40%（防 PlayResY 缺失 /
  /// 异常时字号撑爆整屏；PlayResY 正确时常规字号远低于该上限、不受影响）。
  double _scaleAssFontSize(double px) {
    final double maxPx = (_lastLayoutHeight ?? 720) * 0.4;
    return px.clamp(8.0, maxPx > 8.0 ? maxPx : 8.0).toDouble();
  }

  /// 把 ASS 阴影（Shadow 深度 + BackColour 阴影色，行内 span 覆盖 cueStyle 默认）解析成
  /// 向右下偏移的硬投影 [Shadow]（TODO-1246）。深度按 [scale] 与字号同步缩放。深度<=0 /
  /// 无阴影返回 null（不加 shadows，历史像素级一致）。阴影色缺失时按 ASS 默认取黑，而非
  /// 描边色（描边由 [_resolveStroke] 单独承载）。
  List<Shadow>? _resolveAssShadows(
      SubtitleSpan? span, SubtitleCueStyle? cue, double scale) {
    final double? depth = span?.shadowDepthPx ?? cue?.shadowDepthPx;
    if (depth == null || depth <= 0) return null;
    final int? colorArgb = span?.shadowColorArgb ?? cue?.shadowColorArgb;
    final Color color =
        colorArgb != null ? Color(colorArgb) : const Color(0xFF000000);
    final double off = (depth * scale).clamp(0.5, 24.0).toDouble();
    return <Shadow>[Shadow(color: color, offset: Offset(off, off))];
  }

  /// \pos 映射到容器局部坐标；无 \pos 或视频未解码返回 null（走 anchor 对齐）。
  Offset? _posScreen(SubtitleMarkup? markup, Size container) {
    final SubtitlePos? pf = markup?.posFraction;
    if (pf == null) return null;
    final int? w = widget.controller.videoWidth;
    final int? h = widget.controller.videoHeight;
    if (w == null || h == null) return null;
    return mapPosFractionToContainer(pf, w, h, container);
  }

  static double _hFrac(SubtitleHAlign h) => switch (h) {
        SubtitleHAlign.left => 0,
        SubtitleHAlign.center => 0.5,
        SubtitleHAlign.right => 1,
      };

  static double _vFrac(SubtitleVAlign v) => switch (v) {
        SubtitleVAlign.top => 0,
        SubtitleVAlign.middle => 0.5,
        SubtitleVAlign.bottom => 1,
      };

  /// anchor → Align 对齐（无 \pos 时用）。null=历史底居中。
  Alignment _alignFor(SubtitleAnchor? a) {
    if (a == null) return Alignment.bottomCenter;
    final double x = switch (a.horizontal) {
      SubtitleHAlign.left => -1,
      SubtitleHAlign.center => 0,
      SubtitleHAlign.right => 1,
    };
    final double y = switch (a.vertical) {
      SubtitleVAlign.top => -1,
      SubtitleVAlign.middle => 0,
      SubtitleVAlign.bottom => 1,
    };
    return Alignment(x, y);
  }

  /// 顶部锚点用顶部 padding、中部不加、底部按 [controlsVisible] 取避让下限。
  ///
  /// 底部锚点避让是「字幕底缘 ≥ 控制条顶缘」的约束，故控制条可见时底部 padding 取
  /// `max(bottomPadding, controlsBottomReserve)`——而**不是** `bottomPadding + reserve`
  /// 的加法叠加。加法会把高位字幕凭空多抬一个基线、顶出可视底带（TODO-161 用户报「桌面
  /// hover 字幕消失」，BUG-226）；取下限只把字幕抬到 reserve（=进度条上缘）恰骑控制条顶，
  /// 避开进度条又不飞。reserve 是按平台真实控制条几何加总 + 随界面缩放的值（视频页传入
  /// `videoSubtitleControlsReserve`，BUG-238），移动端 ≈140×缩放 > 默认基线 75，故默认字幕
  /// 在控制条可见时真正被抬升盖过被抬高的移动进度条。用户手选高位（> reserve）时 max 取其
  /// 值、不被避让改写；手选低位（< reserve）时控制条可见仍抬到 reserve 躲进度条、隐藏落回
  /// 原值。避让只对底部锚点生效——控制条在底部，顶部 / 中部字幕不会被进度条遮挡。
  EdgeInsets _paddingFor(SubtitleAnchor? a, bool controlsVisible) {
    final SubtitleVAlign v = a?.vertical ?? SubtitleVAlign.bottom;
    return switch (v) {
      SubtitleVAlign.bottom => EdgeInsets.only(
          bottom: controlsVisible
              ? (widget.bottomPadding > widget.controlsBottomReserve
                  ? widget.bottomPadding
                  : widget.controlsBottomReserve)
              : widget.bottomPadding,
        ),
      SubtitleVAlign.top => EdgeInsets.only(top: widget.bottomPadding),
      SubtitleVAlign.middle => EdgeInsets.zero,
    };
  }

  /// 给字幕盒套底部 padding。无 [VideoSubtitleOverlay.controlsVisible]（测试 / 有声书 /
  /// 无控制条场景）走静态 [Padding]，与历史像素级一致（controlsVisible=false → 贴
  /// bottomPadding 基线）。有控制条可见性时改 [ValueListenableBuilder] 监听 +
  /// [AnimatedPadding]：控制条出现 → 底部 padding 取 `max(bottomPadding, reserve)`（字幕
  /// 底缘骑到控制条顶、躲开进度条）、隐藏 → 落回 bottomPadding 基线（TODO-129/161，几何
  /// 见 [_paddingFor]）。取下限而非加法，故基线 < 控制条高时不会把字幕顶飞、手选高位也
  /// 不被改写（同一字段无特例分支）。
  Widget _anchoredPadded(SubtitleAnchor? anchor, Widget child) {
    final ValueListenable<bool>? visible = widget.controlsVisible;
    if (visible == null) {
      return Padding(padding: _paddingFor(anchor, false), child: child);
    }
    return ValueListenableBuilder<bool>(
      valueListenable: visible,
      builder: (BuildContext _, bool controlsVisible, Widget? padded) {
        return AnimatedPadding(
          // 与 media_kit 控制条淡入淡出同量级（~200ms），字幕上顶/落回跟随控制条显隐。
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: _paddingFor(anchor, controlsVisible),
          child: padded,
        );
      },
      child: child,
    );
  }

  /// 把 [charContext] 对应字符的局部布局矩形转成全局屏幕矩形（弹窗定位用）。
  /// 无 RenderBox 时退化成 [Rect.zero]，调用方有 fallback。
  static Rect _globalRectOf(BuildContext charContext) {
    final RenderObject? ro = charContext.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return Rect.zero;
    final Offset topLeft = ro.localToGlobal(Offset.zero);
    return topLeft & ro.size;
  }
}

/// TODO-1312：一个已渲染字幕字符的登记项（[_VideoSubtitleOverlayState._charEntries]
/// 一条）。二维登记（主字幕活动集含重叠 cue + 副字幕活动集，每字符一条）后，按全局坐标
/// 反查命中能回到「哪条 cue + 该 cue 内第几个 grapheme」，故点主 / 副 / 重叠某条都查得对。
class _SubtitleCharEntry {
  _SubtitleCharEntry({
    required this.sentence,
    required this.graphemeIndex,
    required this.context,
    required this.blurred,
  });

  /// 该字符所属的整条 cue 文本（查词 / 制卡取整句用）。
  final String sentence;

  /// 该字符在其所属 cue 内的 grapheme 下标（从该位置起最长匹配取词）。
  final int graphemeIndex;

  /// 字符 widget 的 [BuildContext]（求其全局屏幕矩形做命中 / 弹窗定位）。
  final BuildContext context;

  /// 该字符所在层是否模糊（听力沉浸主层模糊时为 true）——模糊字符不参与命中反查
  /// （与点击不查词一致），命中扫描时按 [Rect.zero] 跳过。
  final bool blurred;
}

/// 字幕盒的**按字符矩形门控** tap 识别器（BUG-553）。语义同普通 [TapGestureRecognizer]，
/// 但只有当**按下点**命中某字幕字符（含 [resolveSubtitleCharHit] 字缝 / 描边容差，由
/// [hitTestChar] 判定）时才通过 [isPointerAllowed] 收下该指针、加入手势竞技场竞逐 tap；
/// 按下点落在字幕盒内字符间空白（超容差）时不收指针、不进竞技场，让盖在其下的 media_kit
/// 控制条 `onTap` 独占竞技场胜出（点字幕区空白照常唤出 / 隐藏控制条）。
///
/// 取代旧的「整片 translucent [GestureDetector] 无条件收下所有 tap」：那样字幕盒在 Stack
/// 上层、任何落在盒内的 tap 都赢竞技场并 reject 掉 media_kit 的 onTap，移动端（无 hover
/// 兜底）表现为「有字幕在屏时点画面唤不出控制条」。门控只作用于竞技场，不改变 translucent
/// 的命中 / hover hit-test 语义（media_kit 仍在命中路径里，桌面 hover 行为原样保留、BUG-198）。
class _SubtitleCharTapRecognizer extends TapGestureRecognizer {
  _SubtitleCharTapRecognizer({required this.hitTestChar});

  /// 按**全局**坐标判定按下点是否命中某字幕字符（与点击查词同一判据）。
  final bool Function(Offset globalPosition) hitTestChar;

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    // 按下点未命中字符 → 不收指针 → 不进竞技场 → media_kit 控制条 onTap 独占胜出。
    if (!hitTestChar(event.position)) return false;
    return super.isPointerAllowed(event);
  }
}
