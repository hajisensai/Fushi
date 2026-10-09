import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_search_seed.dart';
import 'package:fushi/src/pages/implementations/subtitle_search_panel.dart';

/// BUG-3199：字幕搜索框默认填原名，并能一键切回中文标题（服务器显示名）。
void main() {
  testWidgets('原名预填，点中文标题 chip 换词', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final SubtitleSearchSeed seed = buildSubtitleSearchSeed(
      originalTitle: '葬送のフリーレン',
      metadataTitle: '葬送的芙莉莲',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubtitleSearchPanel(
            onDownloaded: (_) {},
            initialQuery: seed.primaryQuery,
            initialApiKey: '',
            onApiKeyChanged: (_) async {},
            saveDirectory: '/tmp/sub',
            seed: seed,
          ),
        ),
      ),
    );
    await tester.pump();

    TextField queryField() => tester.widget<TextField>(
      find.byWidgetPredicate(
        (Widget w) =>
            w is TextField &&
            (w.controller?.text == '葬送のフリーレン' ||
                w.controller?.text == '葬送的芙莉莲'),
      ),
    );
    expect(queryField().controller!.text, '葬送のフリーレン');
    expect(
      find.byKey(const ValueKey<String>('subtitle-query-alt-0')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('subtitle-query-alt-1')),
    );
    await tester.pump();
    expect(queryField().controller!.text, '葬送的芙莉莲');
  });

  testWidgets('只有一个候选标题时不显示备选', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubtitleSearchPanel(
            onDownloaded: (_) {},
            initialQuery: 'Frieren',
            initialApiKey: '',
            onApiKeyChanged: (_) async {},
            saveDirectory: '/tmp/sub',
            seed: buildSubtitleSearchSeed(displayTitle: 'Frieren'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('subtitle-query-alt-0')),
      findsNothing,
    );
  });
}
