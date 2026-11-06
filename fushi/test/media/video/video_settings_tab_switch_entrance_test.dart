// Zc-iEbsImS：第一次打开播放器侧边栏，从「播放」切到「画质增强」，页面滑到位后
// 列表又闪一下重建。根因：面板在切页**落定后**才 setState 打开进场开关，已经滑进
// 来、看得见的那页被整页重播一次进场。这里逐帧记录新页的透明度：进场应单调变亮，
// 显示出来后不许再跌回透明。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/settings/settings_destination.dart' show VideoGroup;

import '../../helpers/video_quick_settings_harness.dart';

/// [page] 下进场动画包装（Opacity）的最小透明度；页不在树上时为 null。
double? _minOpacity(WidgetTester tester, Finder page) {
  if (page.evaluate().isEmpty) return null;
  double? min;
  for (final Opacity o in tester.widgetList<Opacity>(
    find.descendant(of: page, matching: find.byType(Opacity)),
  )) {
    min = min == null || o.opacity < min ? o.opacity : min;
  }
  return min ?? 1;
}

void main() {
  testWidgets('首次从「播放」切到「画质增强」：新页完全显示后不再重播进场', (WidgetTester tester) async {
    final VideoSheetHarness harness = await VideoSheetHarness.create();
    addTearDown(harness.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: buildVideoSheetUnderTest(
            harness: harness,
            host: buildTestVideoHost(),
            initialCategory: VideoGroup.playback.name,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder chip = find.byKey(
      ValueKey<String>('video-settings-cat-${VideoGroup.shaders.name}'),
    );
    expect(chip, findsOneWidget);
    await tester.tap(chip);

    final Finder page = find.byKey(
      PageStorageKey<String>('video-settings-page-${VideoGroup.shaders.name}'),
    );
    // 进场是一次单调变亮（0 → 1）；之后若又跌回去，就是整页重播了一次。
    double peak = 0;
    final List<double?> trace = <double?>[];
    for (int i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final double? min = _minOpacity(tester, page);
      trace.add(min);
      if (min == null) continue;
      if (min > peak) peak = min;
      if (peak - min > 0.3) {
        fail('画质增强页显示后又重播了进场（列表闪一下）；逐帧最小透明度=$trace');
      }
    }
    expect(trace.last, 1, reason: '切页后画质增强页应完全显示；$trace');
    expect(tester.takeException(), isNull);
  });
}
