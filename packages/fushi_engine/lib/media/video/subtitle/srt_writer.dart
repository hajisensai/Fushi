/// SRT 写出的唯一一份：时间戳格式化与「序号 / 时间轴 / 正文 / 空行」块拼接。
///
/// 各调用方（片段导出、有声书对齐、图形字幕 OCR、Lua 字幕镜像、双语拆轨）只负责
/// 挑 cue、算时间、清洗正文，再把结果交给 [writeSrtBlocks]；块格式不再各写一份。
/// 产物与 `SrtParser` 的解析契约一致：序号从 1 起连续、`HH:MM:SS,mmm`、`\n` 换行、
/// 每块后跟一个空行。
library;

/// 一条待写出的 SRT 块。[text] 由调用方清洗好：SRT 以空行分隔块，正文内部
/// 不得含空行（本模块不替调用方决定清洗规则，各来源的规则不同）。
typedef SrtBlock = ({int startMs, int endMs, String text});

/// SRT 时间戳：`HH:MM:SS,mmm`。负值 clamp 到 0（SRT 无负时间轴）；小时不封顶，
/// 超过 99 小时按实际位数写出。
String formatSrtTimestamp(int ms) {
  final int safe = ms < 0 ? 0 : ms;
  String pad(int value, int width) => value.toString().padLeft(width, '0');
  return '${pad(safe ~/ 3600000, 2)}:${pad(safe ~/ 60000 % 60, 2)}:'
      '${pad(safe ~/ 1000 % 60, 2)},${pad(safe % 1000, 3)}';
}

/// 把 [blocks] 按给定顺序写成 SRT 文本，序号从 1 起连续编号。空输入返回空串。
String writeSrtBlocks(Iterable<SrtBlock> blocks) {
  final StringBuffer out = StringBuffer();
  int index = 0;
  for (final SrtBlock block in blocks) {
    index++;
    out
      ..write('$index\n')
      ..write(
        '${formatSrtTimestamp(block.startMs)} --> '
        '${formatSrtTimestamp(block.endMs)}\n',
      )
      ..write('${block.text}\n\n');
  }
  return out.toString();
}
