import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/audiobook/audiobook_play_bar.dart';

/// BUG-021 守卫：反转有声书播放底栏只镜像整体布局，**不能**反转
/// ⏮⏯⏭ 播放三联键的内部方向——快退/上一句永远在左、快进/下一句永远在右。
///
/// TODO-830 守卫：[AudiobookPlayBar.invertSkip] 是与 [reversed] 正交的**功能**
/// 维度——开时把 ⏮/⏭ 两键的 icon+tooltip+onPressed 整体互换（左键变下一句、
/// 右键变上一句），但不碰屏幕左右位置；[reversed] 只镜像位置不碰功能。两者绝不
/// 连带（reversed && !invertSkip 仍守 BUG-021 不回归）。

/// 记录 skipToPrevCue / skipToNextCue 调用顺序的 spy 控制器。
class _SpyController extends AudiobookPlayerController {
  final List<String> calls = <String>[];

  @override
  Future<void> skipToPrevCue() async {
    calls.add('prevCue');
  }

  @override
  Future<void> skipToNextCue() async {
    calls.add('nextCue');
  }
}

Future<void> _pumpBar(
  WidgetTester tester, {
  required bool reversed,
  required AudiobookPlayerController controller,
  bool invertSkip = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: AudiobookPlayBar(
            controller: controller,
            onOpenSettings: () {},
            reversed: reversed,
            invertSkip: invertSkip,
          ),
        ),
      ),
    ),
  );
}

void main() {
  // skipActionSeconds 默认 0 → ⏮ skip_previous / ⏭ skip_next。
  double dx(WidgetTester tester, IconData icon) =>
      tester.getCenter(find.byIcon(icon)).dx;

  testWidgets('playback prev/play/next keep natural order when NOT reversed',
      (tester) async {
    final controller = AudiobookPlayerController();
    addTearDown(controller.dispose);
    await _pumpBar(tester, reversed: false, controller: controller);

    final double prev = dx(tester, Icons.skip_previous_outlined);
    final double play = dx(tester, Icons.play_arrow_outlined);
    final double next = dx(tester, Icons.skip_next_outlined);
    final double tune = dx(tester, Icons.tune_outlined);

    // ⏮ < ⏯ < ⏭，且设置簇（⚙）在最右。
    expect(prev, lessThan(play));
    expect(play, lessThan(next));
    expect(next, lessThan(tune));
  });

  testWidgets('reversed mirrors the bar but NOT the prev/play/next direction',
      (tester) async {
    final controller = AudiobookPlayerController();
    addTearDown(controller.dispose);
    await _pumpBar(tester, reversed: true, controller: controller);

    final double prev = dx(tester, Icons.skip_previous_outlined);
    final double play = dx(tester, Icons.play_arrow_outlined);
    final double next = dx(tester, Icons.skip_next_outlined);
    final double tune = dx(tester, Icons.tune_outlined);

    // 三联键内部方向保持自然：⏮ 仍在 ⏯ 左、⏯ 仍在 ⏭ 左。
    expect(prev, lessThan(play),
        reason: 'rewind/prev must stay left of play even when reversed');
    expect(play, lessThan(next),
        reason: 'next must stay right of play even when reversed');
    // 整体布局已镜像：设置簇（⚙）移到播放组左侧。
    expect(tune, lessThan(prev),
        reason: 'reversed bar mirrors layout: settings cluster goes left');
  });

  // ── TODO-830：功能反转维度（invertSkip）────────────────────────────────

  /// 焦点驱动激活：Tab 走到目标按钮后用 Enter 确认（禁 tap / 坐标点击）。
  Future<void> focusAndActivate(
    WidgetTester tester,
    IconData icon,
  ) async {
    final FocusNode node = Focus.of(
      tester.element(find.byIcon(icon)),
    );
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
  }

  testWidgets('invertSkip:false — left key triggers prevCue, right next',
      (tester) async {
    final _SpyController controller = _SpyController();
    addTearDown(controller.dispose);
    await _pumpBar(tester, reversed: false, controller: controller);

    // 左键图标 = skip_previous，激活调 skipToPrevCue。
    await focusAndActivate(tester, Icons.skip_previous_outlined);
    expect(controller.calls, <String>['prevCue']);

    // 右键图标 = skip_next，激活调 skipToNextCue。
    await focusAndActivate(tester, Icons.skip_next_outlined);
    expect(controller.calls, <String>['prevCue', 'nextCue']);
  });

  testWidgets(
      'invertSkip:true — left key shows skip_next icon and triggers nextCue; '
      'right shows skip_previous and triggers prevCue', (tester) async {
    final _SpyController controller = _SpyController();
    addTearDown(controller.dispose);
    await _pumpBar(tester,
        reversed: false, controller: controller, invertSkip: true);

    // 图标也互换：屏幕左侧（id=audiobook_prev）现在显示 skip_next，
    // 屏幕右侧（id=audiobook_next）显示 skip_previous。
    final double leftIconDx = dx(tester, Icons.skip_next_outlined);
    final double rightIconDx = dx(tester, Icons.skip_previous_outlined);
    expect(leftIconDx, lessThan(rightIconDx),
        reason: 'invertSkip swaps icons: skip_next now sits on the left side');

    // 屏幕左侧（现 skip_next 图标）激活调 skipToNextCue。
    await focusAndActivate(tester, Icons.skip_next_outlined);
    expect(controller.calls, <String>['nextCue']);

    // 屏幕右侧（现 skip_previous 图标）激活调 skipToPrevCue。
    await focusAndActivate(tester, Icons.skip_previous_outlined);
    expect(controller.calls, <String>['nextCue', 'prevCue']);
  });

  testWidgets(
      'reversed:true && invertSkip:false — position mirrors, function does NOT '
      '(BUG-021 not regressed by the new orthogonal flag)', (tester) async {
    final _SpyController controller = _SpyController();
    addTearDown(controller.dispose);
    await _pumpBar(tester,
        reversed: true, controller: controller, invertSkip: false);

    // 位置镜像但功能不反转：skip_previous 仍调 prevCue。
    await focusAndActivate(tester, Icons.skip_previous_outlined);
    expect(controller.calls, <String>['prevCue'],
        reason:
            'reversed only mirrors layout; prev key must still call prevCue');

    await focusAndActivate(tester, Icons.skip_next_outlined);
    expect(controller.calls, <String>['prevCue', 'nextCue'],
        reason:
            'reversed only mirrors layout; next key must still call nextCue');
  });
}
