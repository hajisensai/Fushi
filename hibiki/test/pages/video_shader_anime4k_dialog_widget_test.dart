import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/video/video_shader_downloader.dart';
import 'package:hibiki/src/pages/implementations/video_shader_dialog.dart';

/// Anime4K 预设选择对话框的 widget 行为：列出全部预设、已下载预设标 check、点击未下载
/// 预设 pop 回该预设对象。
void main() {
  Widget wrap(Widget child) =>
      TranslationProvider(child: MaterialApp(home: child));

  testWidgets('列出全部 Anime4K 预设（可滚动到每个）', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(
      const Scaffold(
        body: Anime4kPresetPickerDialog(downloadedFiles: <String>{}),
      ),
    ));
    await tester.pumpAndSettle();
    final Finder list = find.byType(Scrollable).first;
    // 预设较多时列表可滚动：逐个滚到可见再断言，覆盖全部 6 个（Fast/HQ A·B·C）。
    for (final Anime4kPreset preset in kAnime4kPresets) {
      await tester.scrollUntilVisible(find.text(preset.name), 80,
          scrollable: list);
      expect(find.text(preset.name), findsOneWidget,
          reason: '预设 ${preset.name} 应显示');
    }
    // 没有任何文件下载 → 没有 check 标记。
    expect(find.byIcon(Icons.check), findsNothing);
  });

  testWidgets('已下载全部文件的预设显示 check', (WidgetTester tester) async {
    final Anime4kPreset first = kAnime4kPresets.first;
    await tester.pumpWidget(wrap(
      Scaffold(
        body: Anime4kPresetPickerDialog(
          downloadedFiles: first.fileNames.toSet(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // 第一个预设全部文件已存在 → 至少一个 check（其它预设若共享文件也可能 check）。
    expect(find.byIcon(Icons.check), findsWidgets);
  });

  testWidgets('点击未下载预设 pop 回该预设', (WidgetTester tester) async {
    Anime4kPreset? popped;
    await tester.pumpWidget(wrap(
      Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                popped = await showDialog<Anime4kPreset>(
                  context: context,
                  builder: (_) => const Anime4kPresetPickerDialog(
                      downloadedFiles: <String>{}),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final Anime4kPreset target = kAnime4kPresets.first;
    await tester.tap(find.text(target.name));
    await tester.pumpAndSettle();

    expect(popped, isNotNull);
    expect(popped!.id, target.id);
  });
}
