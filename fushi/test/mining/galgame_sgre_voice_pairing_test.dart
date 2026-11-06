import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';

/// BUG-4130（反馈 3drXfc4GFk，STEINS;GATE RE:BOOT）：SGRE 的 xWMA 资源语音由 native
/// 按场景页绑定事件 ID（`fushi_textseq<seq>`），宿主走事件 ID 精确层配对；无标记资源
/// 仍只在原来的 [T-330, T-130] 窗内匹配——不为 SGRE 放宽时间窗（BUG-1605 教训）。
void main() {
  const String body = 'sgre-voicebody-4096-0000000000001234-3-7.xwma';
  const int textTs = 50000;

  String marked(int tick, int seq) => '${tick}_fushi_textseq${seq}_$body';
  String unmarked(int tick) => '${tick}_$body';

  test('带 textseq 的 SGRE xwma 按事件 ID 配对（语音比文本早 900ms 也配得上）', () {
    final List<String> picked = pickPairedGameResources(
      oggFileNames: <String>[marked(textTs - 900, 42)],
      wavFileNames: const <String>[],
      textTsMs: textTs,
      textEventId: 42,
    );
    expect(picked, <String>[marked(textTs - 900, 42)]);
  });

  test('带标资源只配给自己的事件，不降级给别的文本', () {
    final List<String> picked = pickPairedGameResources(
      oggFileNames: <String>[marked(textTs - 220, 41)],
      wavFileNames: const <String>[],
      textTsMs: textTs,
      textEventId: 42,
    );
    expect(picked, isEmpty);
  });

  test('带标资源超出事件 ID 容差（跨会话重用的 seq）被拒', () {
    final List<String> picked = pickPairedGameResources(
      oggFileNames: <String>[marked(textTs - kGalVoicePairingWindowMs - 1, 42)],
      wavFileNames: const <String>[],
      textTsMs: textTs,
      textEventId: 42,
    );
    expect(picked, isEmpty);
  });

  test('无标记 SGRE 资源仍只在原窗口 [T-330, T-130] 内匹配', () {
    expect(
      pickPairedGameResources(
        oggFileNames: <String>[unmarked(textTs - 900)],
        wavFileNames: const <String>[],
        textTsMs: textTs,
        textEventId: 42,
      ),
      isEmpty,
      reason: '没有归属证据的宽窗会把上一句语音错配进来',
    );
    expect(
      pickPairedGameResources(
        oggFileNames: <String>[unmarked(textTs - 220)],
        wavFileNames: const <String>[],
        textTsMs: textTs,
        textEventId: 42,
      ),
      <String>[unmarked(textTs - 220)],
    );
  });

  test('事件 ID 精确层优先于同窗内的无标记资源', () {
    final List<String> picked = pickPairedGameResources(
      oggFileNames: <String>[unmarked(textTs - 220), marked(textTs - 900, 42)],
      wavFileNames: const <String>[],
      textTsMs: textTs,
      textEventId: 42,
    );
    expect(picked, <String>[marked(textTs - 900, 42)]);
  });
}
