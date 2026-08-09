import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// TODO-1312：`findActiveCueIndices` 纯函数守卫——同一时刻区间重叠的多条 cue **全部**
/// 返回（升序），供视频字幕 overlay 把重叠 cue 都渲染出来（不再因越过被选那条 end 落
/// gap 而闪烁 / 只显其一）。与只回一个「代表」下标的 [JsonAlignmentParser.findCueIndex]
/// 互补——后者服务有声书正文高亮 / 查词锚 / 跳句，其契约不受本函数影响（同文件旧测试守）。
AudioCue _cue(int startMs, int endMs) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = 'ch'
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = ''
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = 0;

void main() {
  group('JsonAlignmentParser.findActiveCueIndices', () {
    test('empty cues returns empty', () {
      expect(
        JsonAlignmentParser.findActiveCueIndices(
            cues: <AudioCue>[], positionMs: 0),
        isEmpty,
      );
    });

    test('single cue: before/inside(closed [start,end])/after', () {
      final List<AudioCue> single = <AudioCue>[_cue(1000, 2000)];
      expect(
          JsonAlignmentParser.findActiveCueIndices(
              cues: single, positionMs: 999),
          isEmpty);
      expect(
          JsonAlignmentParser.findActiveCueIndices(
              cues: single, positionMs: 1000),
          <int>[0]);
      expect(
          JsonAlignmentParser.findActiveCueIndices(
              cues: single, positionMs: 1500),
          <int>[0]);
      // endMs 是闭区间（与 findCueIndex 一致，HBK-AUDIT-153）。
      expect(
          JsonAlignmentParser.findActiveCueIndices(
              cues: single, positionMs: 2000),
          <int>[0]);
      expect(
          JsonAlignmentParser.findActiveCueIndices(
              cues: single, positionMs: 2001),
          isEmpty);
    });

    test('non-overlapping cues: only the covering one, gap returns empty', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(1000, 2000),
        _cue(3000, 4000),
        _cue(5000, 6000),
      ];
      expect(
          JsonAlignmentParser.findActiveCueIndices(cues: cues, positionMs: 500),
          isEmpty);
      expect(
          JsonAlignmentParser.findActiveCueIndices(
              cues: cues, positionMs: 1500),
          <int>[0]);
      // gap between cue0.end(2000) and cue1.start(3000).
      expect(
          JsonAlignmentParser.findActiveCueIndices(
              cues: cues, positionMs: 2500),
          isEmpty);
      expect(
          JsonAlignmentParser.findActiveCueIndices(
              cues: cues, positionMs: 3500),
          <int>[1]);
      expect(
          JsonAlignmentParser.findActiveCueIndices(
              cues: cues, positionMs: 5500),
          <int>[2]);
      expect(
          JsonAlignmentParser.findActiveCueIndices(
              cues: cues, positionMs: 7000),
          isEmpty);
    });

    test('overlapping cues on same track: ALL active returned (the fix)', () {
      // cue0 [1000,3000] 与 cue1 [2000,4000] 重叠。旧 findCueIndex 在 [2000,3000] 内
      // 只回 cue1（丢 cue0 → 少显一条 / 越过 cue0.end 落 gap 闪烁）。findActiveCueIndices
      // 全返回：重叠区两条都渲染。
      final List<AudioCue> ov = <AudioCue>[_cue(1000, 3000), _cue(2000, 4000)];
      // 只 cue0 覆盖。
      expect(
          JsonAlignmentParser.findActiveCueIndices(cues: ov, positionMs: 1500),
          <int>[0]);
      // 重叠区：两条都活动（核心修复点）。
      expect(
          JsonAlignmentParser.findActiveCueIndices(cues: ov, positionMs: 2000),
          <int>[0, 1]);
      expect(
          JsonAlignmentParser.findActiveCueIndices(cues: ov, positionMs: 2500),
          <int>[0, 1]);
      // cue0 已结束（>3000），只剩 cue1。此前 overlay 会因 findCueIndex 越过 cue0.end
      // 返回不同/gap 而闪烁；现在 cue1 仍在集里，连续不断。
      expect(
          JsonAlignmentParser.findActiveCueIndices(cues: ov, positionMs: 3500),
          <int>[1]);
      // 全部结束。
      expect(
          JsonAlignmentParser.findActiveCueIndices(cues: ov, positionMs: 4500),
          isEmpty);
    });

    test('nested cue fully inside another: no flicker when inner ends', () {
      // cue0 [0,5000] 包住 cue1 [3000,4000]。越过 cue1.end 后 cue0 仍活动——旧
      // findCueIndex 在 4500 处返回 -1（gap，cue1 那条 end 已过、cue0 被二分跳过）导致
      // overlay 清空闪烁；findActiveCueIndices 恒回 [0]（cue0 还没结束）。
      final List<AudioCue> nested = <AudioCue>[_cue(0, 5000), _cue(3000, 4000)];
      expect(
          JsonAlignmentParser.findActiveCueIndices(
              cues: nested, positionMs: 3500),
          <int>[0, 1]);
      expect(
          JsonAlignmentParser.findActiveCueIndices(
              cues: nested, positionMs: 4500),
          <int>[0]);
    });

    test('three-way overlap returns all covering indices ascending', () {
      final List<AudioCue> tri = <AudioCue>[
        _cue(0, 4000),
        _cue(1000, 5000),
        _cue(2000, 6000),
      ];
      expect(
          JsonAlignmentParser.findActiveCueIndices(cues: tri, positionMs: 3000),
          <int>[0, 1, 2]);
      // cue0 结束(>4000)，剩 cue1/cue2。
      expect(
          JsonAlignmentParser.findActiveCueIndices(cues: tri, positionMs: 4500),
          <int>[1, 2]);
    });
  });
}
