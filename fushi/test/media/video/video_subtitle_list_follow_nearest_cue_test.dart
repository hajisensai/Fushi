// BUG-1484：字幕列表开着「跟随播放」时，打开面板 / 播放头处在**静默段**（OP 之后、章节
// 间隙、长间白）里，列表应停在最近播过的那一行，而不是被扔回列表开头。
//
// 根因是语义错配：`JsonAlignmentParser.findCueIndex` 是「命中」语义（gap 返回 -1，让画面
// 字幕消失，BUG-074 的正确行为），而面板把这个 -1 直接当成「没有可定位的行」。本文件钉死
// 新的「最近一行」求法（[nearestCueIndexAtOrBefore] / [resolveFollowCueIndex]）与它在真
// 面板上的行为，包括跟随关闭时**不得**改变历史行为。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart';
import 'package:fushi_audio/fushi_audio.dart';

AudioCue _cue(int i, int s, int e, String text) => AudioCue()
  ..bookKey = 'video/1'
  ..chapterHref = 'video://default'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = text
  ..startMs = s
  ..endMs = e
  ..audioFileIndex = 0;

AudioCue _posCue(String raw, {required int startMs, required int endMs}) {
  final SubtitleMarkup m =
      parseSubtitleMarkup(raw, playResX: 1280, playResY: 720);
  return AudioCue()
    ..bookKey = 'video/1'
    ..chapterHref = 'video://default'
    ..sentenceIndex = 0
    ..textFragmentId = ''
    ..text = m.plainText
    ..markup = m
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = 0;
}

/// 每 10 秒一条、每条只亮 2 秒 —— 相邻两条之间有 8 秒静默 gap（用户报的形态）。
List<AudioCue> _spacedCues(int count) => <AudioCue>[
      for (int i = 0; i < count; i++)
        _cue(i, i * 10000, i * 10000 + 2000, 'line $i'),
    ];

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: Stack(children: <Widget>[child])),
    );

Widget _panel(VideoPlayerController controller, {required bool autoScroll}) =>
    VideoSubtitleJumpPanel(
      controller: controller,
      onTapCue: (_) {},
      onClose: () {},
      onCopyCue: (_) {},
      onFavoriteCue: (_) async {},
      isCueFavorited: (_) => false,
      colorScheme: const ColorScheme.dark(),
      title: 'Subtitle list',
      emptyHint: 'empty',
      initialAutoScroll: autoScroll,
    );

void main() {
  group('nearestCueIndexAtOrBefore', () {
    test('空列表返回 -1', () {
      expect(nearestCueIndexAtOrBefore(const <AudioCue>[], 1234), -1);
    });

    test('播放头落在某条 cue 内 → 就是那条', () {
      final List<AudioCue> cues = _spacedCues(3);
      expect(nearestCueIndexAtOrBefore(cues, 10500), 1);
    });

    test('播放头落在两条之间的静默 gap → 上一条（这就是本 bug）', () {
      final List<AudioCue> cues = _spacedCues(3);
      // 12000 = 第 1 条已在 12000ms 结束、第 2 条 20000ms 才开始。
      expect(nearestCueIndexAtOrBefore(cues, 15000), 1);
    });

    test('播放头早于第一条 → 第一条（而不是 -1）', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, 5000, 6000, 'a'),
        _cue(1, 7000, 8000, 'b'),
      ];
      expect(nearestCueIndexAtOrBefore(cues, 0), 0);
      expect(nearestCueIndexAtOrBefore(cues, 4999), 0);
    });

    test('播放头晚于最后一条 → 最后一条', () {
      final List<AudioCue> cues = _spacedCues(4);
      expect(nearestCueIndexAtOrBefore(cues, 9999999), 3);
    });

    test('边界：positionMs == startMs 命中该条（闭区间下界）', () {
      final List<AudioCue> cues = _spacedCues(3);
      expect(nearestCueIndexAtOrBefore(cues, 20000), 2);
    });

    test('startMs 并列 → 取最先出现的那条（与代表行「首条为代表」同源）', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, 1000, 2000, '层1'),
        _cue(1, 1000, 2000, '层2'),
        _cue(2, 5000, 6000, '后面'),
      ];
      expect(nearestCueIndexAtOrBefore(cues, 3000), 0);
    });

    test('未排序输入也按定义给出确定结果（取 startMs 最大的那条）', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, 8000, 9000, '晚'),
        _cue(1, 1000, 2000, '早'),
        _cue(2, 4000, 5000, '中'),
      ];
      expect(nearestCueIndexAtOrBefore(cues, 6000), 2);
      expect(nearestCueIndexAtOrBefore(cues, 500), 1,
          reason: '早于全部时取 startMs 最小的那条，不是下标 0');
    });

    test('时间轴重叠时取 startMs 更大的那条（与 findCueIndex 的代表口径一致）', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, 1000, 9000, '长条'),
        _cue(1, 3000, 4000, '插入'),
      ];
      expect(nearestCueIndexAtOrBefore(cues, 5000), 1);
    });
  });

  group('resolveFollowCueIndex', () {
    final List<AudioCue> cues = _spacedCues(5);

    test('命中当前句时原样用 controller 的下标（保留 delay / preRoll snap）', () {
      expect(
        resolveFollowCueIndex(
          cues: cues,
          currentCueIndex: 3,
          positionMs: 0,
          follow: true,
        ),
        3,
        reason: '有当前句就不重算，位置参数不参与',
      );
    });

    test('跟随开启 + gap → 回落最近一行', () {
      expect(
        resolveFollowCueIndex(
          cues: cues,
          currentCueIndex: -1,
          positionMs: 35000,
          follow: true,
        ),
        3,
      );
    });

    test('跟随关闭 + gap → 仍是 -1（向后兼容：列表不动）', () {
      expect(
        resolveFollowCueIndex(
          cues: cues,
          currentCueIndex: -1,
          positionMs: 35000,
          follow: false,
        ),
        -1,
      );
    });

    test('无位置（未 load）→ -1，不瞎猜', () {
      expect(
        resolveFollowCueIndex(
          cues: cues,
          currentCueIndex: -1,
          positionMs: null,
          follow: true,
        ),
        -1,
      );
    });

    test('越界的 currentCueIndex 按未命中处理（换轨竞态）', () {
      expect(
        resolveFollowCueIndex(
          cues: cues,
          currentCueIndex: 99,
          positionMs: 35000,
          follow: true,
        ),
        3,
      );
    });
  });

  group('逐字卡拉OK 合并后仍落在代表行上', () {
    test('gap 里的最近 raw 映射到整句代表行，而不是某个单字行', () {
      // 片源形态：一句歌词被拆成 3 个单字事件（各带 \pos），列表合并成一行。
      final List<AudioCue> cues = <AudioCue>[
        _posCue(r'{\an7\pos(461,672)}手', startMs: 41350, endMs: 44480),
        _posCue(r'{\an7\pos(491,672)}を', startMs: 41390, endMs: 44520),
        _posCue(r'{\an7\pos(521,672)}伸', startMs: 41430, endMs: 44560),
        _cue(3, 60000, 62000, '次のセリフ'),
      ];
      // 播放头在歌词结束后、下一句开始前的静默段。
      final int raw = nearestCueIndexAtOrBefore(cues, 50000);
      expect(raw, 2, reason: '按 startMs 最大取到组内末字');
      final ({Map<int, AudioCue> byRep, Map<int, int> repByRaw}) merged =
          mergePerCharacterCueGroups(cues);
      expect(merged.repByRaw[raw], 0, reason: '面板会把它映射回唯一渲染的整句代表行');
      expect(merged.byRep[0]!.text, '手を伸');
    });
  });

  group('面板行为（用户原始路径）', () {
    testWidgets('跟随开启：打开面板时播放头在静默段 → 定位到最近一行', (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(_spacedCues(200));
      // 第 100 条 [1000000, 1002000] 已结束，第 101 条 1010000 还没开始 → gap，
      // controller.currentCueIndex 保持 -1（正是 findCueIndex 的 gap 契约）。
      controller.debugSetPositionForTesting(1005000);
      expect(controller.currentCueIndex, -1);

      await tester.pumpWidget(_wrap(_panel(controller, autoScroll: true)));
      await tester.pumpAndSettle();

      expect(find.text('line 100'), findsOneWidget, reason: '最近一行应已滚进视口');
      expect(find.text('line 0'), findsNothing, reason: '不该还停在列表开头');
    });

    testWidgets('跟随关闭：同样位置不定位，列表停在开头（向后兼容）', (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(_spacedCues(200));
      controller.debugSetPositionForTesting(1005000);

      await tester.pumpWidget(_wrap(_panel(controller, autoScroll: false)));
      await tester.pumpAndSettle();

      expect(find.text('line 0'), findsOneWidget);
      expect(find.text('line 100'), findsNothing);
    });

    testWidgets('跟随开启：静默段里 seek 到另一段静默也跟着滚（两处 currentCueIndex 都是 -1）',
        (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(_spacedCues(200));
      controller.debugSetPositionForTesting(5000);

      await tester.pumpWidget(_wrap(_panel(controller, autoScroll: true)));
      await tester.pumpAndSettle();
      expect(find.text('line 0'), findsOneWidget);

      // gap → gap 的 seek：裸 currentCueIndex 前后都是 -1，只有位置变了。
      controller.debugSetPositionForTesting(1505000);
      await tester.pumpAndSettle();

      expect(controller.currentCueIndex, -1);
      expect(find.text('line 150'), findsOneWidget);
      expect(find.text('line 0'), findsNothing);
    });

    testWidgets('播放头早于第一条字幕时定位到第一条，不越界', (WidgetTester tester) async {
      final VideoPlayerController controller = VideoPlayerController();
      addTearDown(controller.dispose);
      controller.setCues(<AudioCue>[
        _cue(0, 600000, 602000, 'first line'),
        _cue(1, 610000, 612000, 'second line'),
      ]);
      controller.debugSetPositionForTesting(1000);

      await tester.pumpWidget(_wrap(_panel(controller, autoScroll: true)));
      await tester.pumpAndSettle();

      expect(find.text('first line'), findsOneWidget);
    });
  });
}
