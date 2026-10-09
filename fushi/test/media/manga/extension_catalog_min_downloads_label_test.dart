import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/extension_catalog_controls.dart';
import 'package:fushi/utils.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-3140：扩展页「最低下载量」一排的首档（门槛 0 = 不筛）借用了语言筛选的
/// `mihon_extension_language_all`，显示成「全部语言」。首档必须是下载量自己的
/// 「不限」（`mihon_extension_min_downloads_any`）。
///
/// 设 `FUSHI_PREVIEW_PNG=<目录>` 时额外把渲染结果写成真实像素 PNG（视觉证据用）。
void main() {
  Future<void> pumpActions(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey<String>('preview'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ExtensionCatalogActions(
                keyPrefix: 'test_extension',
                minDownloads: 0,
                onMinDownloadsChanged: (int _) {},
                onBulkInstall: () {},
                onUpdateAll: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String firstChipText(WidgetTester tester) {
    final Finder chip = find.byKey(
      const ValueKey<String>('test_extension_min_downloads_0'),
    );
    expect(chip, findsOneWidget);
    return find
        .descendant(of: chip, matching: find.byType(Text))
        .evaluate()
        .map((Element e) => (e.widget as Text).data ?? '')
        .where((String s) => s.isNotEmpty)
        .join('|');
  }

  for (final AppLocale locale in <AppLocale>[AppLocale.en, AppLocale.zhCn]) {
    testWidgets('最低下载量首档显示「不限」而不是「全部语言」（${locale.languageTag}）', (
      WidgetTester tester,
    ) async {
      LocaleSettings.setLocale(locale);
      tester.view.physicalSize = const Size(1080, 600);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      final String? previewDir = Platform.environment['FUSHI_PREVIEW_PNG'];
      if (previewDir != null) {
        await tester.runAsync(() async {
          // 同一进程里 FontLoader 的同名族只认第一次注册，所以两个 locale 都用
          // 同一份同时覆盖拉丁与中日文的字体（别用 .ttc：FontLoader 会卡死）。
          const String fontPath = r'C:\Windows\Fonts\Deng.ttf';
          final FontLoader loader = FontLoader('Roboto')
            ..addFont(
              File(fontPath).readAsBytes().then(
                (List<int> b) => ByteData.sublistView(Uint8List.fromList(b)),
              ),
            );
          await loader.load();
        });
      }

      await pumpActions(tester);

      if (previewDir != null) {
        await tester.runAsync(() async {
          final RenderRepaintBoundary boundary = tester.renderObject(
            find.byKey(const ValueKey<String>('preview')),
          );
          final ui.Image image = await boundary.toImage(pixelRatio: 2.0);
          final ByteData? png = await image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File(
            '$previewDir/min_downloads_${locale.languageTag}.png',
          ).writeAsBytes(png!.buffer.asUint8List());
        });
      }

      final String label = firstChipText(tester);
      expect(label, t.mihon_extension_min_downloads_any);
      expect(label, isNot(t.mihon_extension_language_all));
    });
  }
}
