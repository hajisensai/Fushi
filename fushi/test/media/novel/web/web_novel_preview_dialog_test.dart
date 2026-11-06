import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/novel/web/web_novel_reader_launch.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:material_ui/material_ui.dart';

/// 「用 Fushi 阅读（小说）」的预览确认框：只渲染 Rust 给的结论（章节标题、首段、
/// 下一章是否找到、并进哪本书），行内容错峰进场。
void main() {
  Future<void> pump(WidgetTester tester, WebNovelPreview preview) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Center(child: WebNovelPreviewDialog(preview: preview)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(ValueKey<String>(key))).data!;

  testWidgets('新书 + 找到下一章', (WidgetTester tester) async {
    await pump(
      tester,
      const WebNovelPreview(
        chapterTitle: 'プロローグ',
        workTitle: '無職転生',
        excerpt: '俺は34歳住所不定無職。',
        hasNext: true,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(textOf(tester, 'web-novel-preview-chapter'), 'プロローグ');
    expect(textOf(tester, 'web-novel-preview-excerpt'), '俺は34歳住所不定無職。');
    expect(
      textOf(tester, 'web-novel-preview-next'),
      t.novel_web_preview_next_found,
    );
    expect(textOf(tester, 'web-novel-preview-target'), t.novel_web_preview_new);
    expect(find.text('無職転生'), findsOneWidget);
    // 行内容走共享的错峰进场（动效守卫要求新 UI 接入）。
    expect(find.byType(FushiEntranceScope), findsOneWidget);
    expect(find.byType(FushiStaggeredEntrance), findsNWidgets(5));
    expect(
      find.byKey(const ValueKey<String>('web-novel-preview-read')),
      findsOneWidget,
    );
  });

  testWidgets('并进已有的书 + 没有下一章', (WidgetTester tester) async {
    await pump(
      tester,
      const WebNovelPreview(
        chapterTitle: '第二章',
        excerpt: '夕阳西下，彩霞满天。',
        hasNext: false,
        mergeIntoTitle: '何以笙箫默',
        existingChapters: 3,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      textOf(tester, 'web-novel-preview-next'),
      t.novel_web_preview_next_missing,
    );
    expect(
      textOf(tester, 'web-novel-preview-target'),
      t.novel_web_preview_merge(title: '何以笙箫默', count: 3),
    );
    expect(find.byType(FushiStaggeredEntrance), findsNWidgets(4));
  });
}
