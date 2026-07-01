import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

// TODO-1065 / BUG-509：悬浮字幕首句空窗 / 每句要等上一句播完才出现。
//
// 修复在显示层新增 [AudiobookPlayerController.displayCueForFloatingLyric]（纯决策
// 抽成 static [displayCueForTesting]）：音频引子期先显示首句、句间 gap 提前显示
// 下一句；而 reader 正文高亮用的 [currentCue] 保持原 idx<0 hold 契约不变。
//
// 本测试锁定两条不可回归的语义：
//  ① display 决策：首句前=首句、句内=当前句、gap=下一句、末句后=末句。
//  ② reader hold 契约：_updateCurrentCue 在 idx<0（首句前 / gap）裸 return，
//     [currentCue] 停在上一句（首句前为 null），不被 display 逻辑污染。

AudioCue _cue({
  required int fileIndex,
  required int startMs,
  required int endMs,
  required String text,
}) {
  return AudioCue()
    ..bookKey = 'b'
    ..chapterHref = 'c'
    ..sentenceIndex = 0
    ..textFragmentId = '#$text'
    ..text = text
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = fileIndex;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // cue0 [1000,2000]  gap  cue1 [3000,4000]  gap  cue2 [5000,6000]
  // 引子期 [0,1000)、gap [2000,3000)/[4000,5000)、末句后 (6000,∞)。
  final List<AudioCue> cues = <AudioCue>[
    _cue(fileIndex: 0, startMs: 1000, endMs: 2000, text: 's0'),
    _cue(fileIndex: 0, startMs: 3000, endMs: 4000, text: 's1'),
    _cue(fileIndex: 0, startMs: 5000, endMs: 6000, text: 's2'),
  ];

  group('displayCueForFloatingLyric 纯决策（BUG-509 ①）', () {
    test('位置早于首句 startMs → 返回首句（消除首句空窗）', () {
      final AudioCue? c = AudiobookPlayerController.displayCueForTesting(
          cues: cues, effectiveMs: 0);
      expect(c?.text, 's0');
      final AudioCue? c2 = AudiobookPlayerController.displayCueForTesting(
          cues: cues, effectiveMs: 500);
      expect(c2?.text, 's0');
    });

    test('位置在某句区间内（含 startMs / endMs 边界）→ 返回当前句', () {
      expect(
        AudiobookPlayerController.displayCueForTesting(
                cues: cues, effectiveMs: 1000)
            ?.text,
        's0',
      );
      expect(
        AudiobookPlayerController.displayCueForTesting(
                cues: cues, effectiveMs: 1500)
            ?.text,
        's0',
      );
      expect(
        AudiobookPlayerController.displayCueForTesting(
                cues: cues, effectiveMs: 2000)
            ?.text,
        's0', // endMs 闭区间
      );
      expect(
        AudiobookPlayerController.displayCueForTesting(
                cues: cues, effectiveMs: 3500)
            ?.text,
        's1',
      );
    });

    test('位置落在句间 gap → 返回下一条即将到来的 cue（不再等上一句播完）', () {
      // gap [2000,3000) → 下一句 s1
      expect(
        AudiobookPlayerController.displayCueForTesting(
                cues: cues, effectiveMs: 2001)
            ?.text,
        's1',
      );
      expect(
        AudiobookPlayerController.displayCueForTesting(
                cues: cues, effectiveMs: 2999)
            ?.text,
        's1',
      );
      // gap [4000,5000) → 下一句 s2
      expect(
        AudiobookPlayerController.displayCueForTesting(
                cues: cues, effectiveMs: 4500)
            ?.text,
        's2',
      );
    });

    test('位置晚于末句 endMs → 返回末句（显示不清空）', () {
      expect(
        AudiobookPlayerController.displayCueForTesting(
                cues: cues, effectiveMs: 999999)
            ?.text,
        's2',
      );
    });

    test('空 cue 列表 → null', () {
      expect(
        AudiobookPlayerController.displayCueForTesting(
            cues: const <AudioCue>[], effectiveMs: 0),
        isNull,
      );
    });
  });

  group('reader 高亮 currentCue 的 idx<0 hold 契约不回归（BUG-509 ②）', () {
    test('首句前 currentCue 停 null / gap 保持上一句，不被 display 逻辑污染', () {
      final controller = AudiobookPlayerController();
      addTearDown(controller.dispose);
      controller.setChapterCues(cues);

      // 引子期（idx<0，早于首句）：_updateCurrentCue 裸 return，currentCue 仍 null。
      controller.debugUpdateCueForPosition(500);
      expect(controller.currentCue, isNull,
          reason: '首句前 reader 高亮不应被填充（hold 契约）');

      // 进入首句区间：currentCue = s0。
      controller.debugUpdateCueForPosition(1500);
      expect(controller.currentCue?.text, 's0');

      // 句间 gap（idx<0）：裸 return，currentCue 仍保持上一句 s0（不跳到下一句）。
      controller.debugUpdateCueForPosition(2500);
      expect(controller.currentCue?.text, 's0',
          reason: 'gap 内 reader 高亮应保持上一句，避免闪烁');

      // 进入下一句：currentCue = s1。
      controller.debugUpdateCueForPosition(3500);
      expect(controller.currentCue?.text, 's1');
    });
  });
}
