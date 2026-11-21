import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/video/video_orientation_policy.dart';
import 'package:fushi/src/media/video/subtitle_transcript_text.dart';
import 'package:fushi/src/media/video/video_portrait_layout.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;

/// 拍板台 P9AS-fvjJh：竖屏学习版式的几何、页签切换、当前句与工具栏。
AudioCue _cue(String text, int startMs) => AudioCue()
  ..bookKey = 'b'
  ..chapterHref = ''
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = text
  ..startMs = startMs
  ..endMs = startMs + 1000
  ..audioFileIndex = 0;

/// 把测试视图设成 [size]（逻辑像素 = 物理像素），再盖上顶部 24 / 底部 16 的安全区。
Future<void> _pumpHost(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(padding: const EdgeInsets.only(top: 24, bottom: 16)),
          child: Scaffold(body: child),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _CueSource extends ChangeNotifier {
  AudioCue? cue;
  void set(AudioCue? next) {
    cue = next;
    notifyListeners();
  }
}

void main() {
  late ValueNotifier<VideoPortraitTab> tab;
  late _CueSource cues;
  late List<String> events;

  setUp(() {
    tab = ValueNotifier<VideoPortraitTab>(VideoPortraitTab.subtitles);
    cues = _CueSource();
    events = <String>[];
  });

  tearDown(() {
    tab.dispose();
    cues.dispose();
  });

  Widget layout(VideoPortraitLayoutKind kind) => VideoPortraitLayout(
    kind: kind,
    video: const ColoredBox(
      key: ValueKey<String>('video'),
      color: Colors.black,
    ),
    currentCue: VideoPortraitCurrentCue(
      listenable: cues,
      currentCue: () => cues.cue,
      onLookup: (AudioCue cue, int index, Rect _) =>
          events.add('lookup ${cue.text} $index'),
      onTapCue: (AudioCue cue) => events.add('tap ${cue.text}'),
      emptyHint: 'no cue',
    ),
    pane: (EdgeInsets insets) => VideoPortraitPane(
      tabs: <VideoPortraitTabSpec>[
        VideoPortraitTabSpec(
          tab: VideoPortraitTab.subtitles,
          icon: Icons.subtitles,
          label: 'Subtitles',
          builder: (BuildContext _, EdgeInsets inner) => Text(
            'subtitle list ${inner.bottom.toStringAsFixed(0)}',
            key: const ValueKey<String>('subtitle-body'),
          ),
        ),
        VideoPortraitTabSpec(
          tab: VideoPortraitTab.chapters,
          icon: Icons.list,
          label: 'Chapters',
          builder: (BuildContext _, EdgeInsets __) =>
              const Text('chapter list', key: ValueKey<String>('chapter-body')),
        ),
      ],
      selected: tab,
      onSelect: (VideoPortraitTab next) => tab.value = next,
      insets: insets,
    ),
    toolbar: videoPortraitToolbar(
      items: <FushiToolbarItem>[
        FushiToolbarItem(
          key: const ValueKey<String>('tb-play'),
          icon: Icons.play_arrow,
          label: 'Play',
          onPressed: () => events.add('play'),
        ),
      ],
    ),
  );

  testWidgets('phone: video strip on top follows 16:9 below the top inset', (
    WidgetTester tester,
  ) async {
    await _pumpHost(tester, layout(VideoPortraitLayoutKind.stacked));

    final Rect video = tester.getRect(
      find.byKey(const ValueKey<String>('video')),
    );
    expect(video.top, 24);
    expect(video.width, 390);
    expect(
      video.bottom,
      closeTo(
        videoPortraitVideoBottom(
          kind: VideoPortraitLayoutKind.stacked,
          screen: const Size(390, 844),
          topInset: 24,
        ),
        0.01,
      ),
    );
    // 页签内容给底部浮动工具栏 + 底部安全区让位。
    expect(
      find.text(
        'subtitle list ${(16 + VideoPortraitLayout.toolbarReserve).toStringAsFixed(0)}',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('video-portrait-toolbar')),
      findsOneWidget,
    );
    // 工具栏在当前句与页签之下。
    expect(
      tester.getRect(find.byKey(const ValueKey<String>('tb-play'))).top,
      greaterThan(video.bottom),
    );
  });

  testWidgets('tablet portrait splits: pane on the right', (
    WidgetTester tester,
  ) async {
    await _pumpHost(
      tester,
      layout(VideoPortraitLayoutKind.split),
      size: const Size(800, 1280),
    );

    expect(
      find.byKey(const ValueKey<String>('video-portrait-split')),
      findsOneWidget,
    );
    final Rect video = tester.getRect(
      find.byKey(const ValueKey<String>('video')),
    );
    final Rect body = tester.getRect(
      find.byKey(const ValueKey<String>('subtitle-body')),
    );
    expect(video.width, closeTo(800 - videoPortraitSplitPaneWidth(800), 0.01));
    expect(body.left, greaterThanOrEqualTo(video.right));
  });

  testWidgets('tabs switch the pane content', (WidgetTester tester) async {
    await _pumpHost(tester, layout(VideoPortraitLayoutKind.stacked));
    expect(find.byKey(const ValueKey<String>('subtitle-body')), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('video-portrait-tab-chapters')),
    );
    await tester.pumpAndSettle();
    expect(tab.value, VideoPortraitTab.chapters);
    expect(find.byKey(const ValueKey<String>('chapter-body')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('subtitle-body')), findsNothing);
  });

  testWidgets('current cue follows playback and hands taps to lookup', (
    WidgetTester tester,
  ) async {
    await _pumpHost(tester, layout(VideoPortraitLayoutKind.stacked));
    expect(find.text('no cue'), findsOneWidget);

    cues.set(_cue('ねこがすき', 1000));
    await tester.pumpAndSettle();
    expect(find.text('no cue'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('video-portrait-cue-1000')),
      findsOneWidget,
    );

    // 点在句子文字上（Align 占满整行，句子右侧的空白不接点击）。
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('video-portrait-cue-1000')),
        matching: find.byType(SubtitleTranscriptText),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      events.where((String e) => e.startsWith('lookup ねこがすき')),
      isNotEmpty,
    );

    await tester.tap(find.byKey(const ValueKey<String>('tb-play')));
    expect(events, contains('play'));
  });
}
