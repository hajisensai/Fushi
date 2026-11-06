// BUG-4075 本机复现：牌组列表停着不动时，后台任务按钮上不定态的 [FushiSegmentedProgressRing] 以 120 fps
// 逐帧重绘（#VJLEBHP4lz：fcb=[_RepeatingTicker.syncTicker@fushi_expressive_progress.dart:91×3602]），同窗口
// SRS 内核零调用、原生 malloc 每 30 s 涨约 1 GB。这里在真引擎（Impeller）上只挂进度环，对照「静止」与「不定态
// 逐帧动画」两段的进程 RSS 增量，判定逐帧重绘本身是否在漏原生内存。
//
// 跑：fushi/ 下 `.\tool\run_windows_itest.ps1 integration_test/progress_ring_native_leak_probe_itest.dart`

import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

/// 一组进度环；[indeterminate] 为 true 时每个环都是不定态（逐帧动画）。
Widget _rings({required bool indeterminate}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: <Widget>[
          for (int i = 0; i < 6; i++)
            FushiSegmentedProgressRing(
              key: ValueKey<String>('ring-$i'),
              values: <double?>[indeterminate ? null : 0.4],
              colors: const <Color>[Color(0xFF3366FF)],
              trackColor: const Color(0x333366FF),
            ),
        ],
      ),
    ),
  ),
);

int _rssMb() => ProcessInfo.currentRss ~/ (1024 * 1024);

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('不定态分段进度环逐帧重绘时进程 RSS 是否持续增长', (WidgetTester tester) async {
    int frames = 0;
    SchedulerBinding.instance.addPersistentFrameCallback((Duration _) {
      frames++;
    });

    Future<List<int>> measure(String label, int seconds) async {
      final List<int> samples = <int>[];
      frames = 0;
      for (int s = 0; s <= seconds; s += 5) {
        samples.add(_rssMb());
        debugPrint(
          '[ring-leak] $label t=${s}s rss=${samples.last}MB frames=$frames',
        );
        if (s < seconds) {
          await tester.binding.delayed(const Duration(seconds: 5));
        }
      }
      return samples;
    }

    await tester.pumpWidget(_rings(indeterminate: false));
    await tester.binding.delayed(const Duration(seconds: 3));
    final List<int> still = await measure('static', 30);

    await tester.pumpWidget(_rings(indeterminate: true));
    await tester.binding.delayed(const Duration(seconds: 3));
    final List<int> moving = await measure('indeterminate', 60);

    final int stillGrowth = still.last - still.first;
    final int movingGrowth = moving.last - moving.first;
    debugPrint(
      '[ring-leak] RESULT static=+${stillGrowth}MB/30s '
      'indeterminate=+${movingGrowth}MB/60s',
    );
    await tester.pumpWidget(const SizedBox());
  });
}
