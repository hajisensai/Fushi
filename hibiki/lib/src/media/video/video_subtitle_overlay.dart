import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerHoverEvent;
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

  /// 当前句各字符的 [BuildContext]（每帧 build 重建，下标==grapheme 下标），供
  /// [_charHitTest] 按全局坐标反查命中的字符。
  final List<BuildContext> _charContexts = <BuildContext>[];

  /// TODO-916 症状④-A（down-snap）：onTapDown 时刻 [_charHitTest] 命中的 grapheme 下标，
  /// onTapUp 用它经 [_charHitByIndex] 查词，使命中锁定按下时刻（字幕盒尚未被控制条避让
  /// 动画推移），而非 up 时刻的实时反查。-1 表示按下未命中字符。
  int _pendingTapGrapheme = -1;

  /// Shift-悬停查词的移动节流阈值（像素，TODO-756a）。与阅读器 `webview.part.dart` 的
  /// `dx*dx+dy*dy < 64`（8px）同构：鼠标移动距离平方未超 64 时不重新命中查词。
  static const double _kShiftHoverThresholdPx = 8;

  /// 当前句文本与模糊态快照，供 [_charHitTest] 在 build 之外读取。
  String _currentText = '';
  bool _currentBlurred = false;

  /// Shift-悬停查词节流状态（TODO-756a，与阅读器 8px 阈值同构）：上次触发查词的全局 hover
  /// 位置与命中的 grapheme 下标。鼠标移动未超 [_kShiftHoverThresholdPx]、或仍落在同一字符上
  /// 时不重复查词（避免每帧 hover 都查），命中新字符或越过阈值才再次触发。`松开 Shift` /
  /// 离开字幕在 [_handleShiftHover] 里复位为 [Offset.zero] / -1，使下次按 Shift 重新进入即触发。
  Offset _lastShiftHoverPos = Offset.zero;
  int _lastShiftHoverGrapheme = -1;

  /// 按全局坐标反查命中的字幕字符；模糊态/空句返回 null（与点击行为一致：模糊时不
  /// 查词）。供 [VideoSubtitleHitTester] 绑定。
  SubtitleCharHit? _charHitTest(Offset globalPos) {
    if (_currentBlurred || _currentText.isEmpty) return null;
    final List<Rect> rects = <Rect>[
      for (final BuildContext c in _charContexts) _globalRectOf(c),
    ];
    final int i = resolveSubtitleCharHit(rects, globalPos);
    if (i < 0) return null;
    return (sentence: _currentText, graphemeIndex: i, charRect: rects[i]);
  }

  /// 按已知 grapheme 下标取命中三元组（TODO-916 症状④-A 的 down-snap 用）：down 时刻已
  /// 经 [_charHitTest] 确定命中下标，up 时刻直接用该下标重算当前字符矩形即可，**不再**用
  /// up 时刻的点重新反查——这样即便 down 唤起控制条致字幕盒在 down→up 间被避让动画上移，
  /// 命中仍锁定按下瞄准的那个字符。下标越界 / 模糊态 / 空句返回 null。
  SubtitleCharHit? _charHitByIndex(int graphemeIndex) {
    if (_currentBlurred || _currentText.isEmpty) return null;
    if (graphemeIndex < 0 || graphemeIndex >= _charContexts.length) return null;
    final Rect r = _globalRectOf(_charContexts[graphemeIndex]);
    return (sentence: _currentText, graphemeIndex: graphemeIndex, charRect: r);
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
      _lastShiftHoverGrapheme = -1;
      return;
    }
    final SubtitleCharHit? hit = _charHitTest(event.position);
    if (hit == null) return;
    // 同一字符 + 未越过移动阈值 → 不重复触发（节流）。命中新字符立即放行（即使移动很小，
    // 也应换词查词，与阅读器逐字符 hover 一致）。
    final double dx = event.position.dx - _lastShiftHoverPos.dx;
    final double dy = event.position.dy - _lastShiftHoverPos.dy;
    final bool sameGrapheme = hit.graphemeIndex == _lastShiftHoverGrapheme;
    if (sameGrapheme &&
        dx * dx + dy * dy < _kShiftHoverThresholdPx * _kShiftHoverThresholdPx) {
      return;
    }
    _lastShiftHoverPos = event.position;
    _lastShiftHoverGrapheme = hit.graphemeIndex;
    onCharHover(hit.sentence, hit.graphemeIndex, hit.charRect);
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
        // 遮蔽模式「隐藏」：主字幕整条不渲染，且清空命中状态 + 解绑命中句柄（返回
        // null 让查词 barrier 走 dismiss，不会反查到一条不可见的字幕）。TODO-840 Part B。
        if (widget.subtitleHidden) {
          _charContexts.clear();
          _currentText = '';
          _currentBlurred = false;
          widget.hitTester?.bindHitTest(_charHitTest);
          return const SizedBox.shrink();
        }
        // 每帧重置字符命中状态并（重新）绑定句柄——空句也要绑定，使浮层打开但当前
        // 无字幕时 hitTest 返回 null（barrier 走 dismiss）。
        _charContexts.clear();
        final String text = widget.controller.currentCue?.text ?? '';
        _currentText = text;
        widget.hitTester?.bindHitTest(_charHitTest);
        if (text.isEmpty) {
          _currentBlurred = false;
          return const SizedBox.shrink();
        }
        final SubtitleMarkup? markup = widget.controller.currentCue?.markup;
        final List<String> chars = text.characters.toList(growable: false);
        // 听力沉浸模糊只在「播放中」生效：暂停（含查词暂停、用户手动暂停）时字幕一律
        // 清晰。查词必然先暂停视频，旧实现靠桌面 hover 维持清晰，但查词浮层弹出后鼠标
        // 移到浮层 → 字幕 MouseRegion 收到 onExit → _revealed 复位 → 字幕又变模糊
        // （用户正盯着这句查词，却被打码，BUG-199）。沉浸模糊的语义本就是「播放中逼你
        // 听」，暂停时没有在听、显形理所当然，故以 isPlaying 为闸根除该竞态——无需让
        // overlay 感知浮层栈状态。
        final bool blurred =
            widget.blurEnabled && !_revealed && widget.controller.isPlaying;
        _currentBlurred = blurred;

        final Color backgroundColor = widget.backgroundOpacity <= 0
            ? Colors.transparent
            // TODO-1059 方案A：未显式设背景色时用固定半透明黑
            // ([kDefaultSubtitleBackgroundColor])，不再跟随主题 `surface`（浅色
            // 主题近白会让字幕背景泛白）。页面路径恒传非 null（已由
            // [_subtitleBackgroundColor] 解析成该常量）；此 `??` 兜底测试/直接
            // 构造场景，二者同色。
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
                      // 登记字符 context（下标==i==grapheme 下标）供全局坐标反查
                      // （[_charHitTest]）。字符本身不再各自包 opaque GestureDetector
                      // ——那样每个字符矩形都吞掉指针 hover hit-test，盖在其下的
                      // media_kit `MouseRegion.onHover/onEnter` 收不到鼠标 → 鼠标移到
                      // 字幕文字上时控制条不再被唤起、光标被字幕层吃掉（BUG-198）。
                      // tap 命中改由下方整片 translucent GestureDetector + 本登记表
                      // 反查承载。
                      _charContexts.add(charContext);
                      return _buildStrokedChar(chars[i], i, markup);
                    },
                  ),
              ],
            ),
          ),
        );

        // 当前句已收藏：在字幕盒左上角外侧叠一枚实心星角标（TODO-301 / BUG-264），与
        // 字幕列表行的收藏标记同语义。用 [Stack](clipBehavior: none) + [Positioned] 叠在
        // 盒外，不挤压字符布局（不改字幕盒尺寸、不影响居中与字符 hit-test 几何）。
        // [isCueFavorited] 为 null（测试 / 无收藏数据源）时不叠，外观像素级不变。
        final AudioCue? currentCue = widget.controller.currentCue;
        final bool favorited = currentCue != null &&
            (widget.isCueFavorited?.call(currentCue) ?? false);
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

        // 字符点击查词：整个字幕盒一个 translucent GestureDetector，松手时用
        // [_charHitTest] 按全局坐标反查命中的字符 grapheme 再回调 [onCharTap]。
        // - translucent：hover/指针 hit-test 不被本层独占，media_kit 的
        //   `MouseRegion` 仍进 path → 鼠标在字幕上时控制条照常唤起、不被吞
        //   （BUG-198，对比旧的逐字符 opaque）。
        // - 本层在 Stack 上层，tap 会赢手势竞技场 → media_kit 的 `playAndPauseOnTap`
        //   （onTapDown）被截断 → 点字幕文字仍是查词、不会顺手暂停（保留旧 opaque
        //   行为）；点字幕盒内字符间空白则什么也不做（不查词、不暂停）。
        if (widget.onCharTap != null) {
          box = GestureDetector(
            behavior: HitTestBehavior.translucent,
            // down-snap（TODO-916 ④-A）：按下时刻字幕盒尚未被控制条避让动画推移，此刻
            // 反查命中字符并记下其下标；up 时刻用该下标（[_charHitByIndex]）查词，即便
            // 控制条已唤起、字幕盒上移，命中仍锁按下瞄准的字符。
            onTapDown: (TapDownDetails details) {
              final SubtitleCharHit? hit = _charHitTest(details.globalPosition);
              _pendingTapGrapheme = hit?.graphemeIndex ?? -1;
            },
            onTapUp: (TapUpDetails details) {
              final SubtitleCharHit? hit = _charHitByIndex(_pendingTapGrapheme);
              _pendingTapGrapheme = -1;
              if (hit != null) {
                widget.onCharTap!(
                    hit.sentence, hit.graphemeIndex, hit.charRect);
              }
            },
            onTapCancel: () {
              _pendingTapGrapheme = -1;
            },
            child: box,
          );
        }

        if (blurred) {
          // 模糊态：盖一层高斯模糊 + 拦截字符点击（避免误触查词），并提供显形热区。
          box = Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: box,
              ),
              // 透明覆盖：拦字符点击（避免模糊态误触查词）+ 移动端点它显形。
              // translucent（非 opaque）：tap 仍由本层（Stack 上层）赢手势竞技场、
              // 截断 media_kit 暂停，但 hover hit-test 不被独占 → 鼠标在模糊字幕上时
              // media_kit `MouseRegion` 照常收 hover、控制条可唤起、不被吞（BUG-198）。
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

        // 桌面悬停：①听力沉浸显形/复原（blurEnabled）②向页面回报 hover 字幕盒，让页面
        // 唤回光标 + 续命控制条（[onHoverChanged]，BUG-283——鼠标停字幕上读字时不被
        // media_kit 自动隐藏吞掉光标）③Shift-鼠标悬停查词（[onCharHover]，TODO-756a，与
        // 阅读器 onShiftHover 同语义，经 onHover 在按 Shift 时对命中字符查词）。三者合一个
        // MouseRegion。opaque:false：本 region 收 hover 的同时不阻断 hover hit-test 继续下探到
        // media_kit 的 `MouseRegion` → 鼠标在字幕上时字幕显形 / 查词 / 控制条唤起并存、光标
        // 不被吞（BUG-198）。仅在确需 hover（blur / onHoverChanged / onCharHover 任一）时挂，
        // 否则透传 box（外观像素级不变）。
        final bool needHover = widget.blurEnabled ||
            widget.onHoverChanged != null ||
            widget.onCharHover != null;
        final Widget hoverable = needHover
            ? MouseRegion(
                opaque: false,
                onEnter: (_) {
                  if (widget.blurEnabled) _setRevealed(true);
                  widget.onHoverChanged?.call(true);
                },
                // Shift-悬停查词（TODO-756a）：onHover 每次鼠标在字幕盒内移动都来，内部按
                // Shift 门控 + 命中节流。onCharHover==null 时 _handleShiftHover 立即返回（零开销）。
                onHover: _handleShiftHover,
                onExit: (_) {
                  if (widget.blurEnabled) _setRevealed(false);
                  widget.onHoverChanged?.call(false);
                  // 离开字幕盒：复位 Shift-悬停节流锚，下次进入即可触发（与松开 Shift 同处理）。
                  _lastShiftHoverPos = Offset.zero;
                  _lastShiftHoverGrapheme = -1;
                },
                child: box,
              )
            : box;

        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final Size container = constraints.biggest;
            final Offset? posScreen = _posScreen(markup, container);
            if (posScreen != null) {
              // \pos 绝对定位：把字幕盒的 \an 锚点精确落到映射坐标。
              final SubtitleAnchor anchor = markup!.anchor ??
                  const SubtitleAnchor(
                      SubtitleVAlign.bottom, SubtitleHAlign.center);
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
                      child: hoverable,
                    ),
                  ),
                ],
              );
            }
            // 无 \pos：按 \an 锚点对齐（anchor==null → 历史底居中，像素级不变）。
            return Align(
              alignment: _alignFor(markup?.anchor),
              child: _anchoredPadded(markup?.anchor, hoverable),
            );
          },
        );
      },
    );
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
    final Widget fill = Text(char, style: fillStyle);
    if (strokePaint == null) return fill;
    // 描边层：复制 fill 的所有几何属性，但用 foreground 画笔取代 color（Flutter 断言
    // foreground 与 color 不可共存，故显式重建而非 copyWith——copyWith 无法把 color 清空）。
    final TextStyle strokeStyle = fillStyle.copyWith(
      color: null,
      foreground: strokePaint,
      // 描边层不画下划线/删除线，避免与 fill 层重叠加粗装饰线（fill 层已画）。
      decoration: TextDecoration.none,
    );
    return Stack(
      // 底层 stroke 先画（在下），上层 fill 后画（在上）盖住描边内缘，露出外缘成轮廓。
      children: <Widget>[
        Text(char, style: strokeStyle),
        fill,
      ],
    );
  }

  /// 解析第 [i] 个 grapheme 的**描边色 + 描边宽**（[_buildStrokedChar] 用）。
  ///
  /// respectAssStyle 关：恒返回用户统一 (shadowColor, shadowThickness)——与历史像素级一致。
  /// respectAssStyle 开：描边色取 span.\3c ?? cueStyle.OutlineColour ?? 统一色；描边宽取
  /// span.\bord ?? cueStyle.Outline ?? 统一宽（TODO-1105，行内覆盖 cue 默认覆盖统一样式）。
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
    final double? outlineWidth = span?.outlineWidthPx ?? cue?.outlineWidthPx;
    return (
      outlineArgb != null ? Color(outlineArgb) : baseColor,
      outlineWidth ?? baseWidth,
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
    final double baseFontSize =
        (respect ? cue?.fontSizePx : null) ?? widget.fontSize;
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
      fontSize: span.fontSizePx ?? base.fontSize,
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
