import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/video_player_controller.dart';

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
    this.blurEnabled = false,
    this.fontSize = 22,
    this.textColor = Colors.white,
    this.backgroundOpacity = 0.54,
    this.bottomPadding = 72,
    super.key,
  });

  final VideoPlayerController controller;

  /// 点击字幕第 [graphemeIndex] 个字符时回调，[sentence] 为整条字幕文本，
  /// [charRect] 为被点字符在全局坐标系下的矩形（弹窗定位用）。
  final void Function(String sentence, int graphemeIndex, Rect charRect)?
      onCharTap;

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

  @override
  State<VideoSubtitleOverlay> createState() => _VideoSubtitleOverlayState();
}

class _VideoSubtitleOverlayState extends State<VideoSubtitleOverlay> {
  bool _revealed = false;

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
        final String text = widget.controller.currentCue?.text ?? '';
        if (text.isEmpty) return const SizedBox.shrink();
        final List<String> chars = text.characters.toList(growable: false);
        final bool blurred = widget.blurEnabled && !_revealed;

        Widget box = DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: widget.backgroundOpacity),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Wrap(
              alignment: WrapAlignment.center,
              children: <Widget>[
                for (int i = 0; i < chars.length; i++)
                  Builder(
                    builder: (BuildContext charContext) => GestureDetector(
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
                        style: TextStyle(
                          color: widget.textColor,
                          fontSize: widget.fontSize,
                          height: 1.3,
                        ),
                      ),
                    ),
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

        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(bottom: widget.bottomPadding),
            child: hoverable,
          ),
        );
      },
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
