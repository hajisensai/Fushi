import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

/// 反馈 NrRPRDTprI：移动端「设备端语音转录」弹层点到遮罩 / 下拉就关闭，关闭即
/// 暂停并释放转录会话。[adaptiveModalSheet] 补 `isDismissible`：false 时点遮罩
/// 与下拉都不关闭（桌面 `barrierDismissible: false` 同语义），系统返回 / Esc
/// 与弹层内按钮照常关闭。
void main() {
  const Key sheetKey = ValueKey<String>('sheet-body');

  ThemeData theme({required bool glass}) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: FushiGlassMaterial.off,
    glassDesign: glass,
  ).copyWith(platform: glass ? TargetPlatform.iOS : TargetPlatform.android);

  Future<void> open(
    WidgetTester tester, {
    required bool glass,
    required bool isDismissible,
    Size size = const Size(400, 800),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(glass: glass),
        home: FushiGlassScope(
          child: Scaffold(
            body: Builder(
              builder: (BuildContext context) => Center(
                child: TextButton(
                  onPressed: () => adaptiveModalSheet<void>(
                    context: context,
                    isDismissible: isDismissible,
                    builder: (BuildContext _) => const SizedBox(
                      key: sheetKey,
                      height: 240,
                      child: Center(child: Text('transcribing')),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(sheetKey), findsOneWidget);
  }

  for (final ({String name, bool glass, Size size}) variant
      in <({String name, bool glass, Size size})>[
        (name: 'MD3 窄屏底部弹层', glass: false, size: const Size(400, 800)),
        (name: 'MD3 宽屏浮动面板', glass: false, size: const Size(900, 800)),
        (name: 'Apple 移动 sheet', glass: true, size: const Size(400, 800)),
      ]) {
    testWidgets('${variant.name}：isDismissible=false 点遮罩 / 下拉不关闭，返回仍关闭', (
      WidgetTester tester,
    ) async {
      await open(
        tester,
        glass: variant.glass,
        isDismissible: false,
        size: variant.size,
      );
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      expect(find.byKey(sheetKey), findsOneWidget, reason: '点遮罩把弹层关了');

      await tester.fling(find.text('transcribing'), const Offset(0, 400), 2000);
      await tester.pumpAndSettle();
      expect(find.byKey(sheetKey), findsOneWidget, reason: '下拉把弹层关了');

      final NavigatorState navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      await navigator.maybePop();
      await tester.pumpAndSettle();
      expect(find.byKey(sheetKey), findsNothing, reason: '系统返回应照常关闭');
    });

    testWidgets('${variant.name}：默认点遮罩关闭（行为不变）', (WidgetTester tester) async {
      await open(
        tester,
        glass: variant.glass,
        isDismissible: true,
        size: variant.size,
      );
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      expect(find.byKey(sheetKey), findsNothing);
    });
  }

  test('转录弹层移动端分支以 isDismissible: false 打开', () {
    // 移动端分支在桌面测试宿主上走不到（isDesktopPlatform 读 Platform），
    // 这里钉住调用参数。
    final String source = File(
      'lib/src/media/audiobook/asr_transcribe_sheet.dart',
    ).readAsStringSync();
    final RegExp call = RegExp(
      r'adaptiveModalSheet<String>\(([^;]*?)\);',
      dotAll: true,
    );
    final Iterable<RegExpMatch> matches = call.allMatches(source);
    expect(matches, isNotEmpty);
    for (final RegExpMatch m in matches) {
      expect(m.group(1), contains('isDismissible: false'));
    }
  });
}
