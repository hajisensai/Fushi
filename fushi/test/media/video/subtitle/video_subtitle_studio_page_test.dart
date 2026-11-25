// 反馈 E1pq561P2q：字幕工作台（生成 / 拆分双语 / 逐句对轴 / 参考面板）。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_studio_page.dart';
import 'package:fushi/src/utils/misc/toast_severity.dart';
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
  group('videoSubtitleStudioTable', () {
    test('lists the whole track with the overlapping other-language line', () {
      final List<VideoSubtitleStudioRow> rows = videoSubtitleStudioTable(
        primary: _primary,
        secondary: _secondary,
        secondaryShiftMs: 0,
      );
      expect(rows.map((VideoSubtitleStudioRow r) => r.cue.text), <String>[
        for (int i = 0; i < 8; i++) '日本語$i',
      ]);
      expect(rows[3].secondaryText, 'English 3');
    });

    test('without a secondary track no row has other-language text', () {
      final List<VideoSubtitleStudioRow> rows = videoSubtitleStudioTable(
        primary: _primary,
        secondary: const <AudioCue>[],
        secondaryShiftMs: 0,
      );
      expect(
        rows.every((VideoSubtitleStudioRow r) => r.secondaryText == null),
        isTrue,
      );
    });

    test('secondary window follows each track\'s own delay', () {
      // 副字幕轴比主字幕晚 2 s（两条轨调轴不同）：主句 3 对上副字幕里的 English 4。
      final List<VideoSubtitleStudioRow> rows = videoSubtitleStudioTable(
        primary: _primary,
        secondary: _secondary,
        secondaryShiftMs: 2000,
      );
      expect(rows[3].secondaryText, 'English 4');
    });

    test(
      'render-only and empty cues are skipped; empty track gives no rows',
      () {
        expect(
          videoSubtitleStudioTable(
            primary: <AudioCue>[_cue(0, 1000, '   ')],
            secondary: const <AudioCue>[],
            secondaryShiftMs: 0,
          ),
          isEmpty,
        );
      },
    );
  });

  group('videoSubtitleStudioAnchorIndex', () {
    final List<VideoSubtitleStudioRow> rows = videoSubtitleStudioTable(
      primary: _primary,
      secondary: const <AudioCue>[],
      secondaryShiftMs: 0,
    );

    test('is the last line starting at or before the playhead', () {
      expect(videoSubtitleStudioAnchorIndex(rows, 6500), 3);
      expect(videoSubtitleStudioAnchorIndex(rows, 6000), 3);
      expect(videoSubtitleStudioAnchorIndex(rows, 5999), 2);
      expect(videoSubtitleStudioAnchorIndex(rows, 999999), 7);
    });

    test('before the first line it is the first line; empty table is null', () {
      expect(videoSubtitleStudioAnchorIndex(rows, -100), 0);
      expect(
        videoSubtitleStudioAnchorIndex(const <VideoSubtitleStudioRow>[], 0),
        isNull,
      );
    });

    test('in a gap between lines nothing is current', () {
      expect(videoSubtitleStudioRowIsCurrent(rows[3], 6500), isTrue);
      // 7800 落在第 3 句（6000–7500）之后、第 4 句（8000）之前。
      expect(videoSubtitleStudioAnchorIndex(rows, 7800), 3);
      expect(
        rows.any(
          (VideoSubtitleStudioRow r) =>
              videoSubtitleStudioRowIsCurrent(r, 7800),
        ),
        isFalse,
      );
    });
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

  test('videoSubtitleStudioTimecode', () {
    expect(videoSubtitleStudioTimecode(65000), '1:05.00');
    expect(videoSubtitleStudioTimecode(65432), '1:05.43');
    expect(videoSubtitleStudioTimecode(3723450), '1:02:03.45');
    expect(videoSubtitleStudioTimecode(-5), '0:00.00');
  });

  group('VideoSubtitleStudioPage', () {
    Finder byKey(String key) => find.byKey(ValueKey<String>(key));

    Future<List<String>> pump(
      WidgetTester tester, {
      required SubtitleContentLanguage language,
      List<AudioCue>? primary,
      List<AudioCue>? secondary,
      bool withRetime = true,
      ValueNotifier<int>? position,
      VideoSubtitleStudioAiReference? ai,
      WidgetBuilder? generatePanel,
      ValueNotifier<VideoSubtitleStudioNotice?>? notice,
      Future<void> Function()? split,
    }) async {
      tester.view
        ..physicalSize = const Size(900, 1600)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final ValueNotifier<int> pos = position ?? ValueNotifier<int>(6500);
      final List<String> calls = <String>[];
      final List<AudioCue> pri = primary ?? _primary;
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
                  onPressed: () => openVideoSubtitleStudioPage(
                    context: context,
                    reference: VideoSubtitleStudioReference(
                      listenable: pos,
                      primaryCues: () => pri,
                      secondaryCues: () => sec,
                      primaryPositionMs: () => pos.value,
                      secondaryPositionMs: () => pos.value,
                      primaryLanguage: () => language,
                      captureFrame: () async => null,
                      jumpToCue: (AudioCue c) => calls.add('jump ${c.text}'),
                      notice: notice == null ? null : () => notice.value,
                      noticeListenable: notice,
                    ),
                    actions: VideoSubtitleStudioActions(
                      generate: () async => calls.add('generate'),
                      generatePanel: generatePanel,
                      splitBilingual: split ?? () async => calls.add('split'),
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

    testWidgets('reference shows the language and the whole track line by '
        'line with timecodes and the other-language subtitle', (
      WidgetTester tester,
    ) async {
      await pump(tester, language: SubtitleContentLanguage.bilingualJaZh);
      expect(byKey('video-subtitle-studio-language'), findsOneWidget);
      expect(find.textContaining('中日双语'), findsOneWidget);
      // 全集都在表里，不再只有播放头前后两句。
      expect(find.text('日本語0'), findsOneWidget);
      expect(find.text('日本語3'), findsOneWidget);
      expect(find.text('日本語7'), findsOneWidget);
      expect(find.text('English 3'), findsOneWidget);
      expect(find.text('0:06.00'), findsOneWidget);
    });

    testWidgets('opens as a full page, not a dialog', (
      WidgetTester tester,
    ) async {
      await pump(tester, language: SubtitleContentLanguage.japanese);
      // 整页路由盖住了打开它的那一页。
      expect(byKey('open').hitTestable(), findsNothing);
      expect(find.byType(VideoSubtitleStudioPage), findsOneWidget);
    });

    testWidgets('the comparison follows the playhead live', (
      WidgetTester tester,
    ) async {
      // 300 句的长轨：表格只建可见的那几行，远处的句子要跟着播放头滚过去才出现。
      final List<AudioCue> long = <AudioCue>[
        for (int i = 0; i < 300; i++) _cue(i * 2000, i * 2000 + 1500, '長い$i'),
      ];
      final ValueNotifier<int> pos = ValueNotifier<int>(6500);
      await pump(
        tester,
        language: SubtitleContentLanguage.japanese,
        primary: long,
        secondary: const <AudioCue>[],
        position: pos,
      );
      expect(find.text('長い3'), findsOneWidget);
      expect(find.text('長い250'), findsNothing);
      pos.value = 500500;
      await tester.pumpAndSettle();
      expect(find.text('長い250'), findsOneWidget);
      expect(find.text('長い3'), findsNothing);
    });

    testWidgets('scrolling the table by hand stops following; the follow '
        'button brings it back', (WidgetTester tester) async {
      final List<AudioCue> long = <AudioCue>[
        for (int i = 0; i < 300; i++) _cue(i * 2000, i * 2000 + 1500, '長い$i'),
      ];
      final ValueNotifier<int> pos = ValueNotifier<int>(500500);
      await pump(
        tester,
        language: SubtitleContentLanguage.japanese,
        primary: long,
        secondary: const <AudioCue>[],
        position: pos,
      );
      // 打开就停在当前句上。
      expect(find.text('長い250'), findsOneWidget);
      await tester.drag(
        byKey('video-subtitle-studio-table'),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      pos.value = 6500;
      await tester.pumpAndSettle();
      expect(find.text('長い3'), findsNothing);

      await tester.tap(byKey('video-subtitle-studio-follow'));
      await tester.pumpAndSettle();
      expect(find.text('長い3'), findsOneWidget);
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

    testWidgets('split is enabled only for bilingual subtitles and runs with '
        'the workbench still open', (WidgetTester tester) async {
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
      expect(byKey('video-subtitle-studio-split'), findsOneWidget);
    });

    testWidgets('a running tool shows progress, blocks the other tools and '
        'shows what the player reports', (WidgetTester tester) async {
      final Completer<void> running = Completer<void>();
      final ValueNotifier<VideoSubtitleStudioNotice?> notice =
          ValueNotifier<VideoSubtitleStudioNotice?>(null);
      final List<String> calls = await pump(
        tester,
        language: SubtitleContentLanguage.bilingualJaZh,
        notice: notice,
        split: () => running.future,
      );
      expect(byKey('video-subtitle-studio-busy'), findsNothing);
      expect(byKey('video-subtitle-studio-notice'), findsNothing);

      await tester.tap(byKey('video-subtitle-studio-split'));
      await tester.pump();
      expect(byKey('video-subtitle-studio-busy'), findsOneWidget);
      // 跑着的时候别的工具点不动。
      await tester.tap(byKey('video-subtitle-studio-align'));
      await tester.pump();
      expect(calls, isEmpty);

      notice.value = const VideoSubtitleStudioNotice(
        message: 'split into 5 lines',
        severity: ToastSeverity.success,
      );
      await tester.pump();
      expect(find.text('split into 5 lines'), findsOneWidget);
      // 播放页的提示自己消失了，工作台仍留着最后一条。
      notice.value = null;
      running.complete();
      await tester.pumpAndSettle();
      expect(byKey('video-subtitle-studio-busy'), findsNothing);
      expect(find.text('split into 5 lines'), findsOneWidget);

      await tester.tap(byKey('video-subtitle-studio-align'));
      await tester.pumpAndSettle();
      expect(calls, <String>['align']);
    });

    testWidgets('an embedded generate panel replaces the generate row and the '
        'duplicate frames switch', (WidgetTester tester) async {
      await pump(
        tester,
        language: SubtitleContentLanguage.japanese,
        generatePanel: (BuildContext context) => const Text('generate options'),
        ai: VideoSubtitleStudioAiReference(
          framesEnabled: () => false,
          setFramesEnabled: (BuildContext context, bool value) async {},
          framesProblem: () => null,
        ),
      );
      expect(byKey('video-subtitle-studio-generate-panel'), findsOneWidget);
      expect(find.text('generate options'), findsOneWidget);
      expect(byKey('video-subtitle-studio-generate'), findsNothing);
      expect(byKey('video-subtitle-studio-ai-frames'), findsNothing);
      // 其它语言字幕那一行（说明哪些字幕会交给 AI）仍在。
      expect(byKey('video-subtitle-studio-ai-subtitles'), findsOneWidget);
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
      // 没有嵌入面板时「生成字幕」自己起面板（盖在工作台上）：工作台不关。
      expect(byKey('video-subtitle-studio-generate'), findsOneWidget);

      calls = await pump(tester, language: SubtitleContentLanguage.japanese);
      await tester.tap(byKey('video-subtitle-studio-retime'));
      await tester.pumpAndSettle();
      expect(calls, <String>['retime']);
      expect(byKey('video-subtitle-studio-retime'), findsOneWidget);

      calls = await pump(tester, language: SubtitleContentLanguage.japanese);
      await tester.tap(byKey('video-subtitle-studio-align'));
      await tester.pumpAndSettle();
      expect(calls, <String>['align']);
    });
  });
}
