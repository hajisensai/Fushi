/// 占位样式：居中一行当前歌词，逐字擦亮。只在样式还没移植完时用；也是最小的样式写法示例。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';

class LyricVisualizerPlaceholder extends StatelessWidget {
  const LyricVisualizerPlaceholder({super.key, required this.context});

  final LyricVisualizerContext context;

  @override
  Widget build(BuildContext buildContext) {
    final LyricVisualizerContext c = context;
    return LyricVisualizerFrameBuilder(
      context: c,
      builder: (BuildContext bc, LyricVisualizerTick tick) {
        final int i = c.runtime.lastStartedLineAt(tick.timeMs);
        if (i < 0) return const SizedBox.expand();
        final LyricVisualizerLine line = c.runtime.lines[i];
        final TextStyle base = TextStyle(
          fontSize: 40 * c.fontScale,
          fontWeight: FontWeight.w700,
          height: 1.3,
        );
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  for (final LyricVisualizerGlyph g in line.glyphs)
                    TextSpan(
                      text: g.text,
                      style: base.copyWith(
                        color: Color.lerp(
                          c.palette.dimText,
                          c.palette.text,
                          g.progress(tick.timeMs),
                        ),
                      ),
                    ),
                ],
              ),
              textAlign: TextAlign.center,
            ),
          ),
        );
      },
    );
  }
}
