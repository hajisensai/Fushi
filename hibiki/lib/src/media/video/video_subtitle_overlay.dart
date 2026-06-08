import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/subtitle_pos_mapping.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
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
    this.hitTester,
    this.blurEnabled = false,
    this.fontSize = 36,
    this.textColor = Colors.white,
    this.backgroundOpacity = 0,
    this.bottomPadding = 75,
    this.fontFamily,
    super.key,
  });

  final VideoPlayerController controller;

  /// 点击字幕第 [graphemeIndex] 个字符时回调，[sentence] 为整条字幕文本，
  /// [charRect] 为被点字符在全局坐标系下的矩形（弹窗定位用）。
  final void Function(String sentence, int graphemeIndex, Rect charRect)?
      onCharTap;

  /// 可选的字符命中句柄：build 时把按全局坐标反查字符的实现绑进来，供查词浮层的
  /// dismiss barrier「点同句换词保持暂停」用（见 [VideoSubtitleHitTester]）。
  final VideoSubtitleHitTester? hitTester;

  /// 听力沉浸：字幕默认模糊，悬停/点击显形。
  final bool blurEnabled;

  /// 字幕字号（外观设置）。
  final double fontSize;

  /// 字幕文字颜色（外观设置）。
  final Color textColor;

  /// 字幕背景不透明度 0..1（外观设置；历史值 0.54 = Colors.black54）。
  final double backgroundOpacity;

  /// 字幕距底部抬升量（避开 media_kit 控制条；外观设置）。
  final double bottomPadding;

  /// 字幕字体。传 null 时走平台默认；视频页传 app-wide reader custom font。
  final String? fontFamily;

  @override
  State<VideoSubtitleOverlay> createState() => _VideoSubtitleOverlayState();
}

class _VideoSubtitleOverlayState extends State<VideoSubtitleOverlay> {
  bool _revealed = false;

  /// 当前句各字符的 [BuildContext]（每帧 build 重建，下标==grapheme 下标），供
  /// [_charHitTest] 按全局坐标反查命中的字符。
  final List<BuildContext> _charContexts = <BuildContext>[];

  /// 当前句文本与模糊态快照，供 [_charHitTest] 在 build 之外读取。
  String _currentText = '';
  bool _currentBlurred = false;

  /// 按全局坐标反查命中的字幕字符；模糊态/空句返回 null（与点击行为一致：模糊时不
  /// 查词）。供 [VideoSubtitleHitTester] 绑定。
  SubtitleCharHit? _charHitTest(Offset globalPos) {
    if (_currentBlurred || _currentText.isEmpty) return null;
    for (int i = 0; i < _charContexts.length; i++) {
      final Rect r = _globalRectOf(_charContexts[i]);
      if (r != Rect.zero && r.contains(globalPos)) {
        return (sentence: _currentText, graphemeIndex: i, charRect: r);
      }
    }
    return null;
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
        final bool blurred = widget.blurEnabled && !_revealed;
        _currentBlurred = blurred;

        final Color backgroundColor = widget.backgroundOpacity <= 0
            ? Colors.transparent
            : Colors.black.withValues(alpha: widget.backgroundOpacity);
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
                      // 登记字符 context（下标==i==grapheme 下标）供全局坐标反查。
                      _charContexts.add(charContext);
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onCharTap == null
                            ? null
                            : () => widget.onCharTap!(
                                  text,
                                  i,
                                  _globalRectOf(charContext),
                                ),
                        child: Text(
                          chars[i],
                          style: _styleForGrapheme(i, markup),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        );

        if (blurred) {
          // 模糊态：盖一层高斯模糊 + 拦截字符点击（避免误触查词），并提供显形热区。
          box = Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: box,
              ),
              // 透明覆盖：拦截字符点击 + 移动端点它显形。
              Positioned.fill(
                child: GestureDetector(
                  key: const Key('video-subtitle-reveal'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _setRevealed(true),
                ),
              ),
            ],
          );
        }

        // 桌面悬停显形/移开复原（移动端无 hover，靠上面的点击热区）。
        final Widget hoverable = widget.blurEnabled
            ? MouseRegion(
                onEnter: (_) => _setRevealed(true),
                onExit: (_) => _setRevealed(false),
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
              child: Padding(
                padding: _paddingFor(markup?.anchor),
                child: hoverable,
              ),
            );
          },
        );
      },
    );
  }

  /// 合并外观默认与覆盖第 [i] 个 grapheme 的 span 样式。
  TextStyle _styleForGrapheme(int i, SubtitleMarkup? markup) {
    final TextStyle base = TextStyle(
      color: widget.textColor,
      fontSize: widget.fontSize,
      height: 1.3,
      fontFamily: widget.fontFamily,
      fontWeight: FontWeight.w700,
      shadows: const <Shadow>[
        Shadow(
          color: Colors.black,
          blurRadius: 3,
          offset: Offset(0, 3),
        ),
      ],
    );
    SubtitleSpan? span;
    if (markup != null) {
      for (final SubtitleSpan s in markup.spans) {
        if (i >= s.startGrapheme && i < s.endGrapheme) {
          span = s;
          break;
        }
      }
    }
    if (span == null) return base;
    final List<TextDecoration> decos = <TextDecoration>[];
    if (span.underline) decos.add(TextDecoration.underline);
    if (span.strike) decos.add(TextDecoration.lineThrough);
    return base.copyWith(
      fontStyle: span.italic ? FontStyle.italic : null,
      fontWeight: span.bold ? FontWeight.bold : null,
      color: span.colorArgb != null ? Color(span.colorArgb!) : null,
      fontSize: span.fontSizePx ?? widget.fontSize,
      decoration: decos.isEmpty ? null : TextDecoration.combine(decos),
    );
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

  /// 顶部锚点用顶部 padding、底部用现有 bottomPadding、中部不加。
  EdgeInsets _paddingFor(SubtitleAnchor? a) {
    final SubtitleVAlign v = a?.vertical ?? SubtitleVAlign.bottom;
    return switch (v) {
      SubtitleVAlign.bottom => EdgeInsets.only(bottom: widget.bottomPadding),
      SubtitleVAlign.top => EdgeInsets.only(top: widget.bottomPadding),
      SubtitleVAlign.middle => EdgeInsets.zero,
    };
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
