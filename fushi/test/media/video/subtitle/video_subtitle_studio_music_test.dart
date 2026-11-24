// 拍板台 niQk_Ns4OV：音乐歌词进通用字幕工作台（音乐工具集 + 对时结果逐行微调）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_studio_page.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_engine/media/video/subtitle/subtitle_content_language.dart';
import 'package:material_ui/material_ui.dart';

AudioCue _cue(int i, int startMs, int endMs, String text) => AudioCue()
  ..bookKey = 'track'
  ..chapterHref = ''
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = text
  ..startMs = startMs
  ..endMs = endMs
  ..audioFileIndex = 0;

void main() {
  Finder byKey(String key) => find.byKey(ValueKey<String>(key));

  Future<List<String>> pump(
    WidgetTester tester, {
    Future<void> Function()? syncPlainText,
    bool fineTune = true,
    bool Function()? canSetCueStart,
  }) async {
    tester.view
      ..physicalSize = const Size(900, 1600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ValueNotifier<int> pos = ValueNotifier<int>(4200);
    final List<String> calls = <String>[];
    final List<AudioCue> lines = <AudioCue>[
      _cue(0, 1000, 3000, 'きみのなまえをよんだ'),
      _cue(1, 4000, 6000, 'とおいそらのしたで'),
    ];
    await tester.pumpWidget(
      MaterialApp(
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
                    primaryCues: () => lines,
                    secondaryCues: () => const <AudioCue>[],
                    primaryPositionMs: () => pos.value,
                    secondaryPositionMs: () => pos.value,
                    primaryLanguage: () => SubtitleContentLanguage.japanese,
                    jumpToCue: (AudioCue c) => calls.add('jump ${c.text}'),
                  ),
                  actions: VideoSubtitleStudioActions(
                    toolset: VideoSubtitleStudioToolset.music,
                    generate: () async => calls.add('generate'),
                    syncPlainText: syncPlainText,
                    setCueStart: fineTune
                        ? (AudioCue c, int ms) async =>
                              calls.add('start ${c.sentenceIndex} $ms')
                        : null,
                    canSetCueStart: canSetCueStart,
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

  testWidgets('music toolset lists generate and plain-text sync only', (
    WidgetTester tester,
  ) async {
    final List<String> calls = await pump(tester, syncPlainText: () async {});
    expect(byKey('video-subtitle-studio-generate'), findsOneWidget);
    expect(byKey('video-subtitle-studio-sync-plain'), findsOneWidget);
    expect(byKey('video-subtitle-studio-split'), findsNothing);
    expect(byKey('video-subtitle-studio-retime'), findsNothing);
    expect(byKey('video-subtitle-studio-align'), findsNothing);
    expect(calls, isEmpty);
  });

  testWidgets('plain-text sync runs its action', (WidgetTester tester) async {
    int runs = 0;
    await pump(tester, syncPlainText: () async => runs++);
    await tester.tap(byKey('video-subtitle-studio-sync-plain'));
    await tester.pumpAndSettle();
    expect(runs, 1);
  });

  testWidgets('without plain lyrics the sync tool is disabled', (
    WidgetTester tester,
  ) async {
    await pump(tester);
    await tester.tap(byKey('video-subtitle-studio-sync-plain'));
    await tester.pumpAndSettle();
    // 没崩、也没别的动作：工具置灰。
    expect(byKey('video-subtitle-studio-sync-plain'), findsOneWidget);
  });

  testWidgets('each line can be started at the playhead', (
    WidgetTester tester,
  ) async {
    final List<String> calls = await pump(tester);
    await tester.tap(byKey('video-subtitle-studio-set-start-4000'));
    await tester.pumpAndSettle();
    expect(calls, <String>['start 1 4200']);
  });

  testWidgets('no per-line button when the track cannot be fine-tuned', (
    WidgetTester tester,
  ) async {
    await pump(tester, fineTune: false);
    expect(byKey('video-subtitle-studio-set-start-4000'), findsNothing);
    await pump(tester, canSetCueStart: () => false);
    expect(byKey('video-subtitle-studio-set-start-4000'), findsNothing);
  });

  testWidgets('the video toolset keeps its tools and has no per-line button', (
    WidgetTester tester,
  ) async {
    tester.view
      ..physicalSize = const Size(900, 1600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ValueNotifier<int> pos = ValueNotifier<int>(0);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: FilledButton(
              key: const ValueKey<String>('open'),
              onPressed: () => openVideoSubtitleStudioPage(
                context: context,
                reference: VideoSubtitleStudioReference(
                  listenable: pos,
                  primaryCues: () => <AudioCue>[_cue(0, 0, 1000, 'あ')],
                  secondaryCues: () => const <AudioCue>[],
                  primaryPositionMs: () => pos.value,
                  secondaryPositionMs: () => pos.value,
                  primaryLanguage: () => SubtitleContentLanguage.japanese,
                ),
                actions: const VideoSubtitleStudioActions(),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(byKey('open'));
    await tester.pumpAndSettle();
    expect(byKey('video-subtitle-studio-split'), findsOneWidget);
    expect(byKey('video-subtitle-studio-sync-plain'), findsNothing);
    expect(byKey('video-subtitle-studio-set-start-0'), findsNothing);
  });
}
