import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/video_player_controller.dart';

/// 视频底部当前句字幕 overlay；监听 [VideoPlayerController.currentCue]。
///
/// 字幕逐字符可点击：点击第 [int] 个 grapheme 时回调 `(sentence, graphemeIndex)`，
/// 调用方据此从该位置起取词查词（最长匹配交给 HoshiDicts）。非字符区域不拦截
/// 指针，让底层 media_kit 控制（点击显隐控制条）正常工作。
class VideoSubtitleOverlay extends StatelessWidget {
  const VideoSubtitleOverlay({
    required this.controller,
    this.onCharTap,
    super.key,
  });

  final VideoPlayerController controller;

  /// 点击字幕第 [graphemeIndex] 个字符时回调，[sentence] 为整条字幕文本。
  final void Function(String sentence, int graphemeIndex)? onCharTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, _) {
        final String text = controller.currentCue?.text ?? '';
        if (text.isEmpty) return const SizedBox.shrink();
        final List<String> chars = text.characters.toList(growable: false);
        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            // 抬高到 media_kit 底部控制条之上，避免遮挡进度条/按钮。
            padding: const EdgeInsets.only(bottom: 72),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  children: <Widget>[
                    for (int i = 0; i < chars.length; i++)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onCharTap == null
                            ? null
                            : () => onCharTap!(text, i),
                        child: Text(
                          chars[i],
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            height: 1.3,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
