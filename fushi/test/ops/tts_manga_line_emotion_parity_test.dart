import 'package:test/test.dart';
import 'package:fushi_cli/fushi_cli.dart' show kTtsMangaLineEmotions;
import 'package:fushi_engine/tts/cast/cast_line_kind.dart' show CastEmotion;

/// CLI 包不依赖 fushi_engine，语气 wire 名只能手写一份；这里钉住它与引擎词表一致
/// （操作目录 `tts.manga.line.edit` 的 emotion 枚举也直接引用这份）。
void main() {
  test('CLI / 操作目录的语气词表 = none + CastEmotion 全部 wire 名', () {
    expect(kTtsMangaLineEmotions, <String>[
      'none',
      for (final CastEmotion e in CastEmotion.values) e.wire,
    ]);
  });
}
