/// TTS 文本按引擎单次输入上限切块（纯 Dart，Galgame 台词朗读与漫画朗读共用）。
library;

/// 按引擎单次输入上限切句：先按句末标点切，单句仍超长再硬切。
List<String> splitTtsTextForInputLimit(String text, {required int maxLength}) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) return const <String>[];
  if (maxLength <= 0 || trimmed.length <= maxLength) return <String>[trimmed];
  final List<String> sentences = <String>[
    for (final Match m in RegExp(
      r'[^。！？!?…\n]+[。！？!?…」』]*|[。！？!?…]+',
    ).allMatches(trimmed))
      if (m.group(0)!.trim().isNotEmpty) m.group(0)!.trim(),
  ];
  final List<String> out = <String>[];
  final StringBuffer buffer = StringBuffer();
  void flush() {
    if (buffer.isNotEmpty) out.add(buffer.toString());
    buffer.clear();
  }

  for (final String sentence in sentences) {
    if (sentence.length > maxLength) {
      flush();
      for (int i = 0; i < sentence.length; i += maxLength) {
        out.add(
          sentence.substring(
            i,
            i + maxLength > sentence.length ? sentence.length : i + maxLength,
          ),
        );
      }
      continue;
    }
    if (buffer.length + sentence.length > maxLength) flush();
    buffer.write(sentence);
  }
  flush();
  return out;
}
