// 导入对话框的 Apple（Cupertino）外观（用户 2026-11-24「不像 Cupertino」）：
// 只在 isGlassDesign 主题下换成 iOS 27 / macOS 27 的 inset grouped 表单——
// 不画色块（FushiCard），文件选择是分组行，表单字段进分组卡；从导入页色块
// 弹出时不承接块配色（此前标题取了色块的深棕前景，在深色面板上看不见）。
// M3E 主题下仍是色块（同一组件，判据只有 isGlassDesign）。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/audiobook/book_import_dialog.dart';
import 'package:fushi/src/media/import/import_dialog_blocks.dart';
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/components/fushi_block_color_scope.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

ThemeData _theme({required bool glass}) => buildFushiThemeData(
  scheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFF6750A4),
    brightness: Brightness.dark,
  ),
  textTheme: const TextTheme(),
  glassDesign: glass,
);

Widget _dialog({required VoidCallback onAudio}) => BookImportDialogFrame(
  title: 'Import book',
  subtitle: 'Pick a book',
  content: Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      ImportPickBlock(
        tone: ImportTone.coral,
        icon: FushiIcons.books,
        title: 'Pick book file',
        subtitle: 'EPUB · PDF',
        dropHint: 'Drop files here',
        onTap: () {},
      ),
      ImportPickTileGrid(
        children: <Widget>[
          ImportPickTile(
            tone: ImportTone.coral,
            icon: FushiIcons.audio,
            title: 'Pick audio',
            subtitle: 'With subtitles',
            onTap: onAudio,
          ),
          Builder(
            builder: (BuildContext context) => ImportPickTile(
              tone: ImportTone.coral,
              icon: FushiIcons.subtitles,
              title: 'Pick subtitles',
              onTap: () {},
              below: ImportTileActions(
                colors: ImportPickTile.colorsOf(context, ImportTone.coral),
                note: 'Pick audio first',
                actions: <ImportTileAction>[
                  ImportTileAction(
                    icon: FushiIcons.voice,
                    label: 'Transcribe',
                    enabled: false,
                    onTap: () {},
                  ),
                ],
              ),
            ),
          ),
          ImportPickTile(
            tone: ImportTone.coral,
            icon: FushiIcons.image,
            title: 'Pick cover',
            subtitle: 'cover.jpg',
            selected: true,
            onTap: () {},
            onClear: () {},
          ),
        ],
      ),
      const ImportSectionBlock(
        tone: ImportTone.coral,
        children: <Widget>[
          FushiTextField(labelText: 'Title'),
          FushiTextField(labelText: 'Author'),
        ],
      ),
    ],
  ),
  actions: const <Widget>[
    TextButton(onPressed: null, child: Text('Cancel')),
    FilledButton(onPressed: null, child: Text('Import')),
  ],
);

Future<void> _pump(
  WidgetTester tester, {
  required bool glass,
  required VoidCallback onAudio,
  required void Function(FushiAppleColors? neutral) onNeutral,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(420, 1000);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: _theme(glass: glass),
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) {
            onNeutral(Theme.of(context).extension<FushiAppleColors>());
            // 从导入页反色色块弹出（来源配色）。
            final FushiCoverBlockColors source = importToneColors(
              context,
              ImportTone.coral,
              inverse: true,
            );
            return FushiBlockColorScope(
              colors: source,
              child: _dialog(onAudio: onAudio),
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Apple：inset grouped 表单，不画色块、不承接来源块配色', (
    WidgetTester tester,
  ) async {
    int audioTaps = 0;
    FushiAppleColors? neutral;
    await _pump(
      tester,
      glass: true,
      onAudio: () => audioTaps++,
      onNeutral: (FushiAppleColors? c) => neutral = c,
    );
    expect(tester.takeException(), isNull);
    // 没有色块卡：主选择 / 次要选择 / 表单都是分组（主块 1 + 三行一组 1 + 表单 1）。
    expect(find.byType(FushiCard), findsNothing);
    expect(find.byType(AdaptiveSettingsSection), findsNWidgets(3));
    // 拖放说明是组尾脚注；转录不可用的原因照常写出。
    expect(find.text('Drop files here'), findsOneWidget);
    expect(find.text('Pick audio first'), findsOneWidget);
    expect(find.text('Transcribe'), findsOneWidget);
    expect(find.text('cover.jpg'), findsOneWidget);
    // 标题取中性 Apple 色板（不是来源色块的前景）。
    final FushiAppleColors titleColors = appleColorsOf(
      tester.element(find.text('Import book')),
    );
    expect(neutral, isNotNull);
    expect(titleColors.label, neutral!.label);
    expect(
      FushiBlockColorScope.maybeColorsOf(
        tester.element(find.text('Pick audio')),
      ),
      isNull,
    );
    // 行可点。
    await tester.tap(find.text('Pick audio'));
    await tester.pump();
    expect(audioTaps, 1);
  });

  testWidgets('M3E：仍是色块（判据只有 isGlassDesign）', (WidgetTester tester) async {
    await _pump(
      tester,
      glass: false,
      onAudio: () {},
      onNeutral: (FushiAppleColors? _) {},
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(FushiCard), findsWidgets);
    expect(find.byType(AdaptiveSettingsSection), findsNothing);
  });
}
