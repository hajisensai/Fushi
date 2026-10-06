// HBK039 回归（Codex 第 6 轮复现迁入）：挂真实非空控制器的有声书侧板在窄宽 /
// 矮高下不溢出（既有测试只用 null 控制器，没覆盖正在播放卡的完整控件）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart'
    show TtuTocEntry;
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi/src/reader/reader_audiobook_panel.dart';
import 'package:fushi/utils.dart';

Future<void> _pumpPanel(
  WidgetTester tester,
  AudiobookPlayerController controller,
  Size size,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        splashFactory: NoSplash.splashFactory,
      ),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: Scaffold(
        body: ReaderAudiobookPanel(
          controller: controller,
          toc: const <TtuTocEntry>[
            TtuTocEntry(index: 0, label: 'Chapter one'),
            TtuTocEntry(index: 1, label: 'Chapter two'),
          ],
          currentSection: 0,
          onJumpSection: (int _, String? __) async {},
          title: 'Book',
          chapterLabel: 'Chapter one',
          coverPath: null,
          settingsBuilder: (_) => const Text('AUDIO_SETTINGS'),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  setUpAll(() => LocaleSettings.setLocale(AppLocale.en));

  for (final Size size in <Size>[
    const Size(320, 800),
    const Size(400, 460),
    const Size(400, 420),
  ]) {
    testWidgets('non-null controller panel fits $size', (tester) async {
      final AudiobookPlayerController controller = AudiobookPlayerController();
      addTearDown(controller.dispose);
      await _pumpPanel(tester, controller, size);
      final Object? layoutError = tester.takeException();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(
        layoutError,
        isNull,
        reason:
            'The transport, speed presets and chapter viewport must fit '
            'when the real controller branch is displayed.',
      );
    });
  }

  testWidgets('control: actual follow action turns off and persists', (
    tester,
  ) async {
    final AudiobookPlayerController controller = AudiobookPlayerController();
    addTearDown(controller.dispose);
    final List<bool> saved = <bool>[];
    controller.onFollowAudioPersist = (bool value) async => saved.add(value);
    await _pumpPanel(tester, controller, const Size(600, 900));
    final Finder follow = find.byWidgetPredicate(
      (Widget widget) =>
          widget is FushiFocusTarget && widget.id.value == 'audiobook_follow',
    );
    expect(follow, findsOneWidget);
    Actions.maybeInvoke<ActivateIntent>(
      tester.element(follow),
      const ActivateIntent(),
    );
    await tester.pump();
    expect(controller.followAudio.value, isFalse);
    expect(saved, <bool>[false]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
