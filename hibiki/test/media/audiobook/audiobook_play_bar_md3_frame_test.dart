import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/audiobook/audiobook_play_bar.dart';

/// TODO-297 守卫：阅读器有声书播放条的播放/暂停键必须是 MD3 圆框
/// （[IconButton.filledTonal] —— 标准 filled-tonal 圆形容器 + state-layer +
/// ripple），而不是扁平的自定义 [HibikiIconButton]。提交 48a8d2044 曾把它换成
/// 无框的 HibikiIconButton，本守卫锁住「图标 + 圆框 md3」旧观感的还原。
///
/// 「filled-tonal」在 Flutter 里通过一个私有的 `_IconButtonVariant` 区分，外部
/// 不可直接读取；但 filled-tonal 变体会渲染一个**非透明背景**的圆形容器，而无框
/// [IconButton]（上一句/下一句/follow/设置）背景透明。因此用「播放键有非透明背景
/// 容器、其余键无」作为可观测断言。
Material _backingMaterial(WidgetTester tester, IconData icon) {
  final Finder iconButton = find.ancestor(
    of: find.byIcon(icon),
    matching: find.byType(IconButton),
  );
  expect(iconButton, findsOneWidget, reason: '$icon 应被一个 IconButton 包裹');
  // IconButton 内部用 Material（filled-tonal 变体的 Material 有非透明颜色）。
  final Finder material = find.descendant(
    of: iconButton,
    matching: find.byType(Material),
  );
  return tester.widgetList<Material>(material).first;
}

void main() {
  testWidgets('play/pause button is a filled-tonal MD3 frame (non-transparent)',
      (tester) async {
    final controller = AudiobookPlayerController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: AudiobookPlayBar(
            controller: controller,
            onOpenSettings: () {},
          ),
        ),
      ),
    );

    // 播放键用 IconButton.filledTonal → 背景容器非透明。
    final Material play = _backingMaterial(tester, Icons.play_arrow_outlined);
    expect(
      play.color,
      isNot(Colors.transparent),
      reason: '播放键应是 filled-tonal 圆框，背景非透明（TODO-297）',
    );
    expect(play.color, isNotNull);

    // 上一句/下一句/设置键是无框原生 IconButton → 背景透明（或无填充）。
    final Material prev =
        _backingMaterial(tester, Icons.skip_previous_outlined);
    final Material next = _backingMaterial(tester, Icons.skip_next_outlined);
    final Material settings = _backingMaterial(tester, Icons.tune_outlined);
    for (final Material m in <Material>[prev, next, settings]) {
      expect(
        m.color ?? Colors.transparent,
        Colors.transparent,
        reason: '非播放键应无框（背景透明）',
      );
    }
  });

  testWidgets('play/pause keeps the MD3 frame when a paper foreground is set',
      (tester) async {
    final controller = AudiobookPlayerController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: AudiobookPlayBar(
            controller: controller,
            onOpenSettings: () {},
            // 模拟阅读器纸张主题前景色注入（c3dbe59a1）。
            foregroundColor: const Color(0xFFEEEEEE),
          ),
        ),
      ),
    );

    // 注入纸张前景色后播放键仍是非透明 tonal 底（不退回扁平/透明）。
    final Material play = _backingMaterial(tester, Icons.play_arrow_outlined);
    expect(play.color, isNot(Colors.transparent));
    expect(play.color, isNotNull);
  });
}
