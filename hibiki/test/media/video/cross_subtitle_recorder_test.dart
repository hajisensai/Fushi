import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/cross_subtitle_recorder.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// TODO-102 跨字幕制卡（区间录制；参考 asbplayer）的纯逻辑单测。
///
/// media_kit 跑不了 headless（无真实播放 / 真实 ffmpeg），故把可测不变量收敛到
/// [CrossSubtitleRecorder] / [CrossSubtitleSelection] 纯逻辑里：
/// ① 录制状态机 idle→record→stop 的 cue 区间捕获 + 升序规范化；
/// ② 文本拼接（区间内所有 cue 文本按序连接）；
/// ③ 区间音频范围 = [起始cue.startMs, 结束cue.endMs] 一整段（不逐句抽再拼）+ 音画延迟；
/// ④ 退化单句（startIdx == endIdx）。
/// 真音频抽取靠真机验证（绝不 mock ffmpeg 伪造音频片段）。
AudioCue _cue(int i, int s, int e, String text) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = text
  ..startMs = s
  ..endMs = e
  ..audioFileIndex = 0;

void main() {
  final List<AudioCue> cues = <AudioCue>[
    _cue(0, 0, 1000, 'こんにちは'),
    _cue(1, 2000, 3000, '元気ですか'),
    _cue(2, 5000, 6000, 'はい'),
    _cue(3, 7000, 8000, '元気です'),
  ];

  group('CrossSubtitleRecorder 状态机（①）', () {
    test('start 置位录制态并记录起点；stop 复位并产出升序区间', () {
      final CrossSubtitleRecorder rec = CrossSubtitleRecorder();
      expect(rec.isRecording.value, isFalse);

      expect(rec.start(1), isTrue);
      expect(rec.isRecording.value, isTrue);
      expect(rec.debugStartCueIndex, 1);

      final CrossSubtitleSelection? sel = rec.stop(3);
      expect(rec.isRecording.value, isFalse);
      expect(rec.debugStartCueIndex, isNull);
      expect(sel, isNotNull);
      expect(sel!.startIndex, 1);
      expect(sel.endIndex, 3);
      rec.dispose();
    });

    test('结束句早于起始句也规范化成升序（用户从后往前录）', () {
      final CrossSubtitleRecorder rec = CrossSubtitleRecorder();
      rec.start(3);
      final CrossSubtitleSelection? sel = rec.stop(1);
      expect(sel!.startIndex, 1);
      expect(sel.endIndex, 3);
      rec.dispose();
    });

    test('start 拒绝 null / 负下标（位置早于全部 cue / 无字幕），不置位录制态', () {
      final CrossSubtitleRecorder rec = CrossSubtitleRecorder();
      expect(rec.start(null), isFalse);
      expect(rec.isRecording.value, isFalse);
      expect(rec.start(-1), isFalse);
      expect(rec.isRecording.value, isFalse);
      rec.dispose();
    });

    test('cancel 复位录制态且不产出区间（换集 / Esc）', () {
      final CrossSubtitleRecorder rec = CrossSubtitleRecorder();
      rec.start(2);
      expect(rec.isRecording.value, isTrue);
      rec.cancel();
      expect(rec.isRecording.value, isFalse);
      expect(rec.debugStartCueIndex, isNull);
      rec.dispose();
    });

    test('结束 cue 为 null（位置不在任何 cue）退化成只录起始那一句', () {
      final CrossSubtitleRecorder rec = CrossSubtitleRecorder();
      rec.start(2);
      final CrossSubtitleSelection? sel = rec.stop(null);
      expect(sel, isNotNull);
      expect(sel!.startIndex, 2);
      expect(sel.endIndex, 2);
      expect(sel.isSingleCue, isTrue);
      rec.dispose();
    });
  });

  group('CrossSubtitleSelection 文本拼接（②）', () {
    test('区间内所有 cue 文本按序拼接（换行分隔）', () {
      const CrossSubtitleSelection sel =
          CrossSubtitleSelection(startIndex: 0, endIndex: 2);
      expect(sel.joinText(cues), 'こんにちは\n元気ですか\nはい');
    });

    test('自定义分隔符', () {
      const CrossSubtitleSelection sel =
          CrossSubtitleSelection(startIndex: 1, endIndex: 3);
      expect(sel.joinText(cues, separator: ' '), '元気ですか はい 元気です');
    });

    test('单句区间只产出那一句（退化单句，④）', () {
      const CrossSubtitleSelection sel =
          CrossSubtitleSelection(startIndex: 1, endIndex: 1);
      expect(sel.isSingleCue, isTrue);
      expect(sel.cueCount, 1);
      expect(sel.joinText(cues), '元気ですか');
    });

    test('空白 cue 文本跳过、不产出多余分隔符', () {
      final List<AudioCue> withBlank = <AudioCue>[
        _cue(0, 0, 1000, 'A'),
        _cue(1, 2000, 3000, '   '),
        _cue(2, 5000, 6000, 'B'),
      ];
      const CrossSubtitleSelection sel =
          CrossSubtitleSelection(startIndex: 0, endIndex: 2);
      expect(sel.joinText(withBlank), 'A\nB');
    });

    test('下标越界按可用范围 clamp（防御性）', () {
      const CrossSubtitleSelection sel =
          CrossSubtitleSelection(startIndex: 0, endIndex: 99);
      expect(sel.joinText(cues), 'こんにちは\n元気ですか\nはい\n元気です');
    });
  });

  group('CrossSubtitleSelection 区间音频范围（③）', () {
    test('区间音频 = [起始cue.startMs, 结束cue.endMs] 一整段（非逐句）', () {
      const CrossSubtitleSelection sel =
          CrossSubtitleSelection(startIndex: 0, endIndex: 2);
      final CrossSubtitleAudioRange? range = sel.audioRange(cues);
      expect(range, isNotNull);
      // cue0.startMs=0 → cue2.endMs=6000，含中间 cue1 与两段 gap，整段连续。
      expect(range!.startMs, 0);
      expect(range.endMs, 6000);
    });

    test('退化单句的音频范围就是该 cue 的时间窗（④）', () {
      const CrossSubtitleSelection sel =
          CrossSubtitleSelection(startIndex: 3, endIndex: 3);
      final CrossSubtitleAudioRange? range = sel.audioRange(cues);
      expect(range!.startMs, 7000);
      expect(range.endMs, 8000);
    });

    test('音画延迟加回两端（与真实声轨对齐）', () {
      const CrossSubtitleSelection sel =
          CrossSubtitleSelection(startIndex: 0, endIndex: 1);
      final CrossSubtitleAudioRange? range = sel.audioRange(cues, delayMs: 500);
      expect(range!.startMs, 500);
      expect(range.endMs, 3500);
    });

    test('负延迟下界 clamp 到 0（起点不为负，终点仍正）', () {
      // cue1 [2000,3000] 配 -2500ms 延迟：起点 clamp 到 0、终点 500，区间仍有效。
      const CrossSubtitleSelection sel =
          CrossSubtitleSelection(startIndex: 1, endIndex: 1);
      final CrossSubtitleAudioRange? range =
          sel.audioRange(cues, delayMs: -2500);
      expect(range, isNotNull);
      expect(range!.startMs, 0);
      expect(range.endMs, 500);
    });

    test('负延迟把整段压成非正区间时返回 null（诚实拒绝）', () {
      // cue0 [0,1000] 配 -5000ms：两端都 clamp 到 0 → endMs <= startMs → null。
      const CrossSubtitleSelection sel =
          CrossSubtitleSelection(startIndex: 0, endIndex: 0);
      expect(sel.audioRange(cues, delayMs: -5000), isNull);
    });

    test('空 cue 列表返回 null', () {
      const CrossSubtitleSelection sel =
          CrossSubtitleSelection(startIndex: 0, endIndex: 1);
      expect(sel.audioRange(const <AudioCue>[]), isNull);
    });
  });
}
