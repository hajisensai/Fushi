import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/utils.dart';

/// TODO-2937：书架 / 漫画 / 视频 / 游戏四个模块的顶栏分段因每页段数与文案长度
/// 不同而宽窄不一。四页顶栏统一走 [LibrarySectionTabs]（唯一实现），每段宽度
/// 下限 [kLibrarySectionTabMinSegmentWidth]——常规中文文案（≤5 字）下四页的分段
/// 块渲染成同一宽度。
void main() {
  setUp(() => LocaleSettings.setLocaleRaw('zh-CN'));
  tearDown(() => LocaleSettings.setLocaleRaw('en'));

  Future<double> cellWidthOf(
    WidgetTester tester,
    List<String> labels,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: LibrarySectionTabs<int>(
              tabs: <LibrarySectionTab<int>>[
                for (int i = 0; i < labels.length; i++)
                  LibrarySectionTab<int>(value: i, label: labels[i]),
              ],
              selected: 0,
              onChanged: (int _) {},
              focusIdPrefix: 'uniform-test',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final Rect strip = tester.getRect(find.byType(SegmentedButton<int>));
    return strip.width / labels.length;
  }

  testWidgets('中文短文案下四模块顶栏分段块等宽（统一最小段宽）', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // 书架/漫画形态：4 段、全 2 字文案。
    final double shortCells = await cellWidthOf(
      tester,
      <String>['书架', '发现', '导入', '设置'],
    );
    // 游戏形态：6 段、含 5 字「捕获工作台」。
    final double gameCells = await cellWidthOf(
      tester,
      <String>['首页', '游戏库', '发现', '捕获工作台', '导入', '设置'],
    );

    expect(
      shortCells,
      moreOrLessEquals(kLibrarySectionTabMinSegmentWidth, epsilon: 0.5),
      reason: '短文案页的分段块应被统一最小段宽垫到同宽',
    );
    expect(
      gameCells,
      moreOrLessEquals(shortCells, epsilon: 0.5),
      reason: '游戏页与书架页的分段块宽度应一致（中文 ≤5 字文案）',
    );
  });

  test('四模块顶栏分段收敛到 LibrarySectionTabs（不许各写一份分段条）', () {
    const Map<String, String> topBarSources = <String, String>{
      '书架/漫画': 'lib/src/pages/implementations/media_library_shell.dart',
      '视频': 'lib/src/pages/implementations/video_library_shell.dart',
      '游戏': 'lib/src/pages/implementations/game_shared.dart',
    };
    for (final MapEntry<String, String> entry in topBarSources.entries) {
      final String src = File(entry.value).readAsStringSync();
      expect(
        src.contains('LibrarySectionTabs<'),
        isTrue,
        reason: '${entry.key} 顶栏（${entry.value}）应使用共享的 LibrarySectionTabs',
      );
      expect(
        src.contains('FushiSegmentedStrip<'),
        isFalse,
        reason: '${entry.key} 顶栏（${entry.value}）不应绕过共享组件手拼分段条'
            '（统一段宽/焦点约定会漂移，TODO-2937）',
      );
    }
  });
}
