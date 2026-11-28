// BUG-5610：玻璃设计下 FushiCheckboxListTile / FushiRadioListTile /
// FushiSwitchListTile 直接当 FushiAlertDialog 的 content 时，行内的 Align 没给
// heightFactor，在有界高度下撑满上限，对话框被拉成几乎整窗高（网页权限请求
// 「记住对此网站的选择」那一行）。两套设计系统下对话框都应只有内容高。
//
// 设了环境变量 FUSHI_TEST_SHOT_DIR 时把每个用例渲染出的像素存成 PNG（离屏证据）。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:material_ui/material_ui.dart';

const Key _shotKey = ValueKey<String>('shot');
const Key _titleKey = ValueKey<String>('title');
const Key _tileKey = ValueKey<String>('tile');
const Key _actionKey = ValueKey<String>('action');

/// 窗口高；对话框若被撑满会接近它。
const double _windowHeight = 1000;

Future<void> _pumpDialog(
  WidgetTester tester, {
  required bool glass,
  required Widget tile,
}) async {
  tester.view.physicalSize = const Size(900, _windowHeight);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildFushiThemeData(
          scheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          textTheme: Typography.material2021().black,
          glass: FushiGlassMaterial.off,
          glassDesign: glass,
        ),
        builder: (BuildContext context, Widget? child) =>
            FushiGlassScope(child: child!),
        home: Scaffold(
          body: Center(
            child: FushiAlertDialog(
              icon: const FushiDialogHeroIcon(
                icon: Icons.notifications_outlined,
              ),
              title: const Text('Allow example.com to notify?', key: _titleKey),
              content: tile,
              actions: <Widget>[
                FushiDialogAction(label: 'Block', onPressed: () {}),
                FushiDialogAction(
                  key: _actionKey,
                  label: 'Allow',
                  kind: FushiDialogActionKind.primary,
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _maybeSaveShot(WidgetTester tester, String name) async {
  final String? dir = Platform.environment['FUSHI_TEST_SHOT_DIR'];
  if (dir == null || dir.isEmpty) return;
  final RenderRepaintBoundary boundary = tester.renderObject(
    find.byKey(_shotKey),
  );
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage();
    final ByteData? bytes = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    image.dispose();
    File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  final Map<String, Widget Function()> tiles = <String, Widget Function()>{
    'checkbox': () => FushiCheckboxListTile(
      key: _tileKey,
      value: false,
      contentPadding: EdgeInsets.zero,
      title: const Text('Remember for this site'),
      onChanged: (bool? _) {},
    ),
    'radio': () => FushiRadioListTile<int>(
      key: _tileKey,
      value: 1,
      groupValue: 1,
      contentPadding: EdgeInsets.zero,
      title: const Text('Remember for this site'),
      onChanged: (int? _) {},
    ),
    'switch': () => FushiSwitchListTile(
      key: _tileKey,
      value: false,
      contentPadding: EdgeInsets.zero,
      title: const Text('Remember for this site'),
      onChanged: (bool _) {},
    ),
  };

  for (final bool glass in <bool>[false, true]) {
    final String ds = glass ? 'glass' : 'md3';
    for (final MapEntry<String, Widget Function()> entry in tiles.entries) {
      testWidgets('$ds：${entry.key} 行直接当对话框 content 时对话框只有内容高', (
        WidgetTester tester,
      ) async {
        await _pumpDialog(tester, glass: glass, tile: entry.value());

        expect(tester.takeException(), isNull);
        final double tileHeight = tester.getSize(find.byKey(_tileKey)).height;
        // 单行列表行：iOS 44、M3 56 上下；被撑满时是几百。
        expect(tileHeight, lessThanOrEqualTo(72), reason: '$ds ${entry.key}');

        final double top = tester.getRect(find.byKey(_titleKey)).top;
        final double bottom = tester.getRect(find.byKey(_actionKey)).bottom;
        // 标题顶到按钮底 = 标题 + 一行 + 按钮行 + 间距，远小于窗口高。
        expect(
          bottom - top,
          lessThan(_windowHeight * 0.4),
          reason: '$ds ${entry.key}: title→actions span ${bottom - top}',
        );

        await _maybeSaveShot(tester, 'BUG-5610-$ds-${entry.key}');
      });
    }
  }
}
