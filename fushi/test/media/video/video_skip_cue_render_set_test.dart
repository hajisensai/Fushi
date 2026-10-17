// BUG-3285：上 / 下一句跳转（skipToCue）在途时，渲染集不得混入 seek 落地前的旧句。
//
// 旧实现：代表 cue 已 snap 到目标句，但时间活动集仍按滞后旧位置（或 preRoll 引导窗口）求，
// 两者并集 = {旧句, 目标句}。overlay 槽位表把旧句放锚点槽、目标句追加到上方，旧句退场后
// 锚点侧死槽保留 → 目标句一直被顶高到下一句。修复后在途期间按目标句起点取样。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';

AudioCue _cue(int i, int s, int e) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = 'line$i'
  ..startMs = s
  ..endMs = e
  ..audioFileIndex = 0;

List<String> _texts(VideoPlayerController c) =>
    c.activeCues.map((AudioCue x) => x.text).toList();

void main() {
  group('BUG-3285 skipToCue 在途渲染集', () {
    test('上一句：滞后旧位置 tick 只渲染目标句，不与旧句并排', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[
        _cue(0, 0, 2000),
        _cue(1, 2100, 4000),
        _cue(2, 4100, 6000),
      ]);
      c.debugUpdateCueForPosition(3000);
      expect(_texts(c), <String>['line1']);

      await c.skipToCue(c.cues[0]);
      // seek 未落地：position 仍是旧的 3000（在 line1 里）。
      c.debugUpdateCueForPosition(3000);
      expect(c.currentCueIndex, 0);
      expect(_texts(c), <String>['line0'], reason: '旧句 line1 不得残留在渲染集里把目标句顶高');

      // 落地后正常跟随。
      c.debugUpdateCueForPosition(100);
      expect(_texts(c), <String>['line0']);
    });

    test('下一句：旧位置与 preRoll 引导窗口都只渲染目标句', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[
        _cue(0, 0, 2000),
        _cue(1, 2100, 4000),
        _cue(2, 4100, 6000),
      ]);
      c.debugUpdateCueForPosition(2500);

      await c.skipToCue(c.cues[2]);
      c.debugUpdateCueForPosition(2500);
      expect(_texts(c), <String>['line2']);

      // preRoll 落点（4100-180=3920）还压着 line1 的尾巴。
      c.debugUpdateCueForPosition(
        4100 - VideoPlayerController.kCueSeekPreRollMs,
      );
      expect(c.currentCueIndex, 2);
      expect(_texts(c), <String>[
        'line2',
      ], reason: 'preRoll 窗口里 line1 尾巴不得与目标句并排');

      c.debugUpdateCueForPosition(4200);
      expect(_texts(c), <String>['line2']);
      // 自然播放越过句尾进下一句后恢复纯位置推导。
      c.debugUpdateCueForPosition(6100);
      expect(_texts(c), isEmpty);
    });

    test('在途期间真正与目标句重叠的 cue 仍一起渲染（TODO-1312 不回归）', () async {
      final VideoPlayerController c = VideoPlayerController();
      addTearDown(c.dispose);
      c.setCues(<AudioCue>[
        _cue(0, 0, 2000),
        _cue(1, 2100, 4000),
        _cue(2, 4100, 6000),
        _cue(3, 4050, 5000), // 与目标句开场重叠的招牌字幕
      ]);
      c.debugUpdateCueForPosition(2500);
      final AudioCue target = c.cues.firstWhere(
        (AudioCue x) => x.text == 'line2',
      );
      await c.skipToCue(target);
      c.debugUpdateCueForPosition(2500);
      expect(_texts(c), unorderedEquals(<String>['line2', 'line3']));
    });

    test('cueRenderPositionMs 纯决策', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, 0, 2000),
        _cue(1, 2100, 4000),
      ];
      int f(int eff, int primary, int? target) =>
          VideoPlayerController.cueRenderPositionMs(
            effectiveMs: eff,
            primaryIdx: primary,
            seekTargetIndex: target,
            cues: cues,
          );
      expect(f(3000, 1, null), 3000, reason: '无快照用实时位置');
      expect(f(3000, 0, 0), 0, reason: '在途旧位置在目标句之后 → 目标句起点');
      expect(f(1950, 1, 1), 2100, reason: 'preRoll 窗口 → 目标句起点');
      expect(f(2500, 1, 1), 2500, reason: '已落进目标句 → 实时位置');
      expect(f(3000, 1, 0), 3000, reason: '代表 cue 不是快照目标 → 实时位置');
      expect(f(3000, 0, 9), 3000, reason: '越界快照不取样');
    });
  });
}
