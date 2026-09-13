import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/src/media/audiobook/audiobook_play_bar.dart';

/// 播放条只呈现控制按钮，不再重复正文中的当前句。
class _CueController extends AudiobookPlayerController {
  _CueController(this._cueText);

  final String _cueText;

  @override
  AudioCue? get currentCue {
    final AudioCue cue = AudioCue()
      ..bookKey = 'b'
      ..chapterHref = 'c'
      ..sentenceIndex = 0
      ..textFragmentId = '#s1'
      ..text = _cueText
      ..startMs = 0
      ..endMs = 1000
      ..audioFileIndex = 0;
    return cue;
  }
}

Future<void> _pumpBar(
  WidgetTester tester, {
  required AudiobookPlayerController controller,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: 400,
            child: AudiobookPlayBar(
              controller: controller,
              onOpenSettings: () {},
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
      '320 wide shared header leaves six playback targets within bounds',
      (WidgetTester tester) async {
    final _CueController controller = _CueController('現在の文');
    addTearDown(controller.dispose);
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AudiobookPlayBar(
      controller: controller,
      onOpenSettings: () {},
      showSeekButtons: true,
      showSettingsButton: false,
    ))));
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.tune_outlined), findsNothing);
    final Rect bar = tester.getRect(find.byType(AudiobookPlayBar));
    for (final Element button in find.byType(IconButton).evaluate()) {
      final Rect rect = tester.getRect(find.byWidget(button.widget));
      expect(bar.contains(rect.topLeft), isTrue);
      expect(bar.contains(rect.bottomRight), isTrue);
    }
    expect(find.byType(IconButton), findsNWidgets(6));
  });

  testWidgets('current sentence stays absent as the cue changes', (
    WidgetTester tester,
  ) async {
    final _CueController first = _CueController('現在の文');
    addTearDown(first.dispose);
    await _pumpBar(tester, controller: first);
    expect(find.text('現在の文'), findsNothing);
    final Offset playPosition = tester.getCenter(
      find.byIcon(Icons.play_arrow_outlined),
    );
    final _CueController next = _CueController('次の文');
    addTearDown(next.dispose);
    await _pumpBar(tester, controller: next);
    expect(find.text('次の文'), findsNothing);
    expect(
      tester.getCenter(find.byIcon(Icons.play_arrow_outlined)),
      playPosition,
    );
    expect(find.byIcon(Icons.skip_previous_outlined), findsOneWidget);
    expect(find.byIcon(Icons.skip_next_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
