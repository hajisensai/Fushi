// 反馈 E1pq561P2q：字幕工作台（生成 / 拆分双语 / 逐句对轴 / 参考面板）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_studio_sheet.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_content_language.dart';
import 'package:material_ui/material_ui.dart';

AudioCue _cue(int startMs, int endMs, String text) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = ''
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = 0;

final List<AudioCue> _primary = <AudioCue>[
  for (int i = 0; i < 8; i++) _cue(i * 2000, i * 2000 + 1500, '日本語$i'),
];

final List<AudioCue> _secondary = <AudioCue>[
  for (int i = 0; i < 8; i++) _cue(i * 2000, i * 2000 + 1500, 'English $i'),
];

void main() {
  group('videoSubtitleStudioRows', () {
    test('anchors on the line under the playhead with two lines around', () {
      final List<VideoSubtitleStudioRow> rows = videoSubtitleStudioRows(
        primary: _primary,
        secondary: _secondary,
        primaryPositionMs: 6500,
        secondaryShiftMs: 0,
      );
      expect(rows.map((VideoSubtitleStudioRow r) => r.cue.text), <String>[
        '日本語1',
        '日本語2',
        '日本語3',
        '日本語4',
        '日本語5',
      ]);
      expect(
        rows.where((VideoSubtitleStudioRow r) => r.current).single.cue.text,
        '日本語3',
      );
      expect(rows[2].secondaryText, 'English 3');
    });

    test('in a gap between lines nothing is current', () {
      final List<VideoSubtitleStudioRow> rows = videoSubtitleStudioRows(
        primary: _primary,
        secondary: const <AudioCue>[],
        primaryPositionMs: 7800,
        secondaryShiftMs: 0,
      );
      expect(rows.any((VideoSubtitleStudioRow r) => r.current), isFalse);
      expect(
        rows.every((VideoSubtitleStudioRow r) => r.secondaryText == null),
        isTrue,
      );
    });

    test('secondary window follows each track\'s own delay', () {
      // 副字幕轴比主字幕晚 2 s（两条轨调轴不同）：主句 3 对上副字幕里的 English 4。
      final List<VideoSubtitleStudioRow> rows = videoSubtitleStudioRows(
        primary: _primary,
        secondary: _secondary,
        primaryPositionMs: 6500,
        secondaryShiftMs: 2000,
      );
      expect(
        rows.firstWhere((VideoSubtitleStudioRow r) => r.current).secondaryText,
        'English 4',
      );
    });

    test(
      'render-only and empty cues are skipped; empty track gives no rows',
      () {
        expect(
          videoSubtitleStudioRows(
            primary: <AudioCue>[_cue(0, 1000, '   ')],
            secondary: const <AudioCue>[],
            primaryPositionMs: 0,
            secondaryShiftMs: 0,
          ),
          isEmpty,
        );
      },
    );
  });

  group('videoSubtitleStudioEvidenceTrack', () {
    test('cues land on video time with the track delay; language is detected '
        'from the text', () {
      final SubtitleEvidenceTrack track = videoSubtitleStudioEvidenceTrack(
        cues: _secondary,
        delayMs: -500,
        label: 'player-secondary',
      )!;
      expect(track.label, 'player-secondary');
      expect(track.language, 'en');
      expect(track.kind, SubtitleEvidenceKind.text);
      expect(track.cues, hasLength(8));
      expect(track.cues[1].startMs, 1500);
      expect(track.cues[1].endMs, 3000);
      expect(track.cues[1].text, 'English 1');
    });

    test('empty lines are dropped, lines are sorted, and a track whose '
        'language cannot be told is not handed over', () {
      final SubtitleEvidenceTrack track = videoSubtitleStudioEvidenceTrack(
        cues: <AudioCue>[
          _cue(4000, 5000, 'second line of the track'),
          _cue(2000, 3000, '   '),
          _cue(0, 1000, 'first line of the track'),
          _cue(6000, 6000, 'zero length'),
        ],
        delayMs: 0,
        label: 'x',
      )!;
      expect(track.cues.map((SubtitleEvidenceCue c) => c.text), <String>[
        'first line of the track',
        'second line of the track',
      ]);
      expect(
        videoSubtitleStudioEvidenceTrack(
          cues: <AudioCue>[_cue(0, 1000, '…')],
          delayMs: 0,
          label: 'x',
        ),
        isNull,
      );
      expect(
        videoSubtitleStudioEvidenceTrack(
          cues: const <AudioCue>[],
          delayMs: 0,
          label: 'x',
        ),
        isNull,
      );
    });
  });

  test('videoSubtitleStudioClock', () {
    expect(videoSubtitleStudioClock(65000), '1:05');
    expect(videoSubtitleStudioClock(3723000), '1:02:03');
    expect(videoSubtitleStudioClock(-5), '0:00');
  });

  group('VideoSubtitleStudioSheet', () {
    Finder byKey(String key) => find.byKey(ValueKey<String>(key));

    Future<List<String>> pump(
      WidgetTester tester, {
      required SubtitleContentLanguage language,
      List<AudioCue>? secondary,
      bool withRetime = true,
      ValueNotifier<int>? position,
      VideoSubtitleStudioAiReference? ai,
    }) async {
      tester.view
        ..physicalSize = const Size(900, 1600)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final ValueNotifier<int> pos = position ?? ValueNotifier<int>(6500);
      final List<String> calls = <String>[];
      final List<AudioCue> sec = secondary ?? _secondary;
      await tester.pumpWidget(
        MaterialApp(
          // 每次 pump 都是一棵新 app：同一个测试里第二次 pump 时，不换 key 的话
          // MaterialApp 原地复用，上一次打开的工作台路由还开着，「open」点到的是
          // 那张旧工作台（旧语言、旧回调），新参数的工作台根本没打开。
          key: UniqueKey(),
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: FilledButton(
                  key: const ValueKey<String>('open'),
                  onPressed: () => showVideoSubtitleStudioSheet(
                    context: context,
                    reference: VideoSubtitleStudioReference(
                      listenable: pos,
                      primaryCues: () => _primary,
                      secondaryCues: () => sec,
                      primaryPositionMs: () => pos.value,
                      secondaryPositionMs: () => pos.value,
                      primaryLanguage: language,
                      captureFrame: () async => null,
                      jumpToCue: (AudioCue c) => calls.add('jump ${c.text}'),
                    ),
                    actions: VideoSubtitleStudioActions(
                      generate: () async => calls.add('generate'),
                      splitBilingual: () async => calls.add('split'),
                      retime: withRetime
                          ? () async => calls.add('retime')
                          : null,
                      alignEmbedded: () async => calls.add('align'),
                    ),
                    aiReference: ai,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(byKey('open'));
      await tester.pumpAndSettle();
      return calls;
    }

    testWidgets('without an AI pipeline the "given to the AI" section is not '
        'shown', (WidgetTester tester) async {
      await pump(tester, language: SubtitleContentLanguage.japanese);
      expect(byKey('video-subtitle-studio-ai-frames'), findsNothing);
      expect(byKey('video-subtitle-studio-ai-subtitles'), findsNothing);
    });

    testWidgets('the frames switch reads and writes the shared setting', (
      WidgetTester tester,
    ) async {
      bool frames = false;
      final List<bool> asked = <bool>[];
      await pump(
        tester,
        language: SubtitleContentLanguage.japanese,
        ai: VideoSubtitleStudioAiReference(
          framesEnabled: () => frames,
          setFramesEnabled: (BuildContext context, bool value) async {
            asked.add(value);
            frames = value;
          },
          framesProblem: () => null,
        ),
      );
      Switch control() => tester.widget<Switch>(
        find.descendant(
          of: byKey('video-subtitle-studio-ai-frames-switch'),
          matching: find.byType(Switch),
        ),
      );
      expect(control().value, isFalse);
      await tester.ensureVisible(
        byKey('video-subtitle-studio-ai-frames-switch'),
      );
      await tester.tap(byKey('video-subtitle-studio-ai-frames-switch'));
      await tester.pumpAndSettle();
      expect(asked, <bool>[true]);
      expect(control().value, isTrue);
      // 说明这两样什么时候会被用到。
      expect(byKey('video-subtitle-studio-ai-scope'), findsOneWidget);
    });

    testWidgets('a declined consent leaves the frames switch off', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        language: SubtitleContentLanguage.japanese,
        ai: VideoSubtitleStudioAiReference(
          framesEnabled: () => false,
          // 用户在说明弹窗里点了取消：实现不改值。
          setFramesEnabled: (BuildContext context, bool value) async {},
          framesProblem: () => null,
        ),
      );
      await tester.ensureVisible(
        byKey('video-subtitle-studio-ai-frames-switch'),
      );
      await tester.tap(byKey('video-subtitle-studio-ai-frames-switch'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Switch>(
              find.descendant(
                of: byKey('video-subtitle-studio-ai-frames-switch'),
                matching: find.byType(Switch),
              ),
            )
            .value,
        isFalse,
      );
    });

    testWidgets('says why frames cannot reach the AI; a non-local video locks '
        'the switch', (WidgetTester tester) async {
      String hint() => tester
          .widget<Text>(byKey('video-subtitle-studio-ai-frames-hint'))
          .data!;
      VideoSubtitleStudioAiReference ai(
        VideoSubtitleStudioFramesProblem? problem,
        List<bool> asked,
      ) => VideoSubtitleStudioAiReference(
        framesEnabled: () => true,
        setFramesEnabled: (BuildContext context, bool value) async =>
            asked.add(value),
        framesProblem: () => problem,
      );
      final List<bool> asked = <bool>[];
      await pump(
        tester,
        language: SubtitleContentLanguage.japanese,
        ai: ai(null, asked),
      );
      final String normal = hint();

      await pump(
        tester,
        language: SubtitleContentLanguage.japanese,
        ai: ai(VideoSubtitleStudioFramesProblem.providerRejectsImages, asked),
      );
      final String rejects = hint();
      expect(rejects, isNot(normal));

      await pump(
        tester,
        language: SubtitleContentLanguage.japanese,
        ai: ai(VideoSubtitleStudioFramesProblem.noProvider, asked),
      );
      expect(hint(), isNot(normal));
      expect(hint(), isNot(rejects));

      await pump(
        tester,
        language: SubtitleContentLanguage.japanese,
        ai: ai(VideoSubtitleStudioFramesProblem.notLocalFile, asked),
      );
      expect(hint(), isNot(normal));
      await tester.ensureVisible(
        byKey('video-subtitle-studio-ai-frames-switch'),
      );
      await tester.tap(
        byKey('video-subtitle-studio-ai-frames-switch'),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(asked, isEmpty);
    });

    testWidgets('the other-language row names the secondary subtitle being '
        'handed over, or says what is used automatically', (
      WidgetTester tester,
    ) async {
      String hint() => tester
          .widget<Text>(byKey('video-subtitle-studio-ai-subtitles-hint'))
          .data!;
      VideoSubtitleStudioAiReference ai() => VideoSubtitleStudioAiReference(
        framesEnabled: () => false,
        setFramesEnabled: (BuildContext context, bool value) async {},
        framesProblem: () => null,
      );
      await pump(tester, language: SubtitleContentLanguage.japanese, ai: ai());
      final String withSecondary = hint();
      expect(withSecondary, contains('English'));

      await pump(
        tester,
        language: SubtitleContentLanguage.japanese,
        secondary: const <AudioCue>[],
        ai: ai(),
      );
      expect(hint(), isNot(withSecondary));
      expect(hint(), isNot(contains('English')));
    });

    testWidgets('reference shows the language, lines around the playhead and '
        'the other-language subtitle', (WidgetTester tester) async {
      await pump(tester, language: SubtitleContentLanguage.bilingualJaZh);
      expect(byKey('video-subtitle-studio-language'), findsOneWidget);
      expect(find.textContaining('中日双语'), findsOneWidget);
      expect(find.text('日本語3'), findsOneWidget);
      expect(find.text('English 3'), findsOneWidget);
      expect(find.text('日本語0'), findsNothing);
    });

    testWidgets('the comparison follows the playhead live', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<int> pos = ValueNotifier<int>(6500);
      await pump(
        tester,
        language: SubtitleContentLanguage.japanese,
        position: pos,
      );
      expect(find.text('日本語6'), findsNothing);
      pos.value = 12500;
      await tester.pumpAndSettle();
      expect(find.text('日本語6'), findsOneWidget);
    });

    testWidgets('turning off other-language subtitles hides them', (
      WidgetTester tester,
    ) async {
      await pump(tester, language: SubtitleContentLanguage.japanese);
      expect(find.text('English 3'), findsOneWidget);
      await tester.tap(byKey('video-subtitle-studio-secondary'));
      await tester.pumpAndSettle();
      expect(find.text('English 3'), findsNothing);
      expect(find.text('日本語3'), findsOneWidget);
    });

    testWidgets('without a secondary track it says how to add one', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        language: SubtitleContentLanguage.japanese,
        secondary: const <AudioCue>[],
      );
      expect(byKey('video-subtitle-studio-no-secondary'), findsOneWidget);
    });

    testWidgets('turning off the frame hides the screenshot area', (
      WidgetTester tester,
    ) async {
      await pump(tester, language: SubtitleContentLanguage.japanese);
      expect(byKey('video-subtitle-studio-capture'), findsOneWidget);
      await tester.tap(byKey('video-subtitle-studio-frame'));
      await tester.pumpAndSettle();
      expect(byKey('video-subtitle-studio-capture'), findsNothing);
    });

    testWidgets('tapping a line jumps to it', (WidgetTester tester) async {
      final List<String> calls = await pump(
        tester,
        language: SubtitleContentLanguage.japanese,
      );
      await tester.tap(find.text('日本語4'));
      await tester.pumpAndSettle();
      expect(calls, <String>['jump 日本語4']);
    });

    testWidgets('split is enabled only for bilingual subtitles and closes the '
        'workbench before running', (WidgetTester tester) async {
      List<String> calls = await pump(
        tester,
        language: SubtitleContentLanguage.japanese,
      );
      await tester.tap(byKey('video-subtitle-studio-split'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(byKey('video-subtitle-studio-split'), findsOneWidget);

      calls = await pump(
        tester,
        language: SubtitleContentLanguage.bilingualJaZh,
      );
      await tester.tap(byKey('video-subtitle-studio-split'));
      await tester.pumpAndSettle();
      expect(calls, <String>['split']);
      expect(byKey('video-subtitle-studio-split'), findsNothing);
    });

    testWidgets('tools dispatch their actions; unavailable ones do nothing', (
      WidgetTester tester,
    ) async {
      List<String> calls = await pump(
        tester,
        language: SubtitleContentLanguage.japanese,
        withRetime: false,
      );
      await tester.tap(byKey('video-subtitle-studio-retime'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(byKey('video-subtitle-studio-generate'));
      await tester.pumpAndSettle();
      expect(calls, <String>['generate']);

      calls = await pump(tester, language: SubtitleContentLanguage.japanese);
      await tester.tap(byKey('video-subtitle-studio-retime'));
      await tester.pumpAndSettle();
      expect(calls, <String>['retime']);

      calls = await pump(tester, language: SubtitleContentLanguage.japanese);
      await tester.tap(byKey('video-subtitle-studio-align'));
      await tester.pumpAndSettle();
      expect(calls, <String>['align']);
    });
  });
}
