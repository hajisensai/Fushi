// 反馈 E1pq561P2q：字幕工作台（生成 / 拆分双语 / 逐句对轴 / 参考面板）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_studio_sheet.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
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
