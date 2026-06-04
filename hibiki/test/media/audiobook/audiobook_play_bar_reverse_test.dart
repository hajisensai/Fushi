import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/audiobook/audiobook_play_bar.dart';

/// BUG-021 守卫：反转有声书播放底栏只镜像整体布局，**不能**反转
/// ⏮⏯⏭ 播放三联键的内部方向——快退/上一句永远在左、快进/下一句永远在右。
Future<void> _pumpBar(WidgetTester tester,
    {required bool reversed,
    required AudiobookPlayerController controller}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: AudiobookPlayBar(
            controller: controller,
            onOpenSettings: () {},
            reversed: reversed,
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
}
