/// 框选识别结果卡片：展示识别文本与来源、两个采纳入口经 Navigator.pop 回传，
/// 空文本时两个动作都禁用（没有可查/可回写的东西）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/reader/manga_rescan_result_sheet.dart';

Widget _wrap(Widget child) {
  return TranslationProvider(
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

/// 真 `showModalBottomSheet` 宿主：卡片的动作契约是「pop 出枚举」，只有真开
/// sheet 才验得到返回值。
Widget _sheetHost(String text, void Function(MangaRescanAction?) onPopped) {
  return TranslationProvider(
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                onPopped(
                  await showModalBottomSheet<MangaRescanAction>(
                    context: context,
                    builder: (BuildContext sheetContext) =>
                        MangaRescanResultSheet(text: text),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('有识别文本：展示文本 + 本地来源标注 + 两个采纳入口可用', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(const MangaRescanResultSheet(text: 'こんにちは')),
    );
    expect(find.text('こんにちは'), findsOneWidget);
    expect(find.text(t.manga_rescan_local_source), findsOneWidget);

    final FilledButton lookup = tester.widget<FilledButton>(
      find.byKey(const ValueKey<String>('manga_rescan_lookup')),
    );
    final OutlinedButton writeBack = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey<String>('manga_rescan_writeback')),
    );
    expect(lookup.onPressed, isNotNull);
    expect(writeBack.onPressed, isNotNull);
  });

  testWidgets('空文本：给出「未识别出文字」并禁用两个动作', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const MangaRescanResultSheet(text: '')));
    expect(find.text(t.manga_rescan_empty), findsOneWidget);

    final FilledButton lookup = tester.widget<FilledButton>(
      find.byKey(const ValueKey<String>('manga_rescan_lookup')),
    );
    final OutlinedButton writeBack = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey<String>('manga_rescan_writeback')),
    );
    expect(lookup.onPressed, isNull, reason: '没有文本就没有可查的词');
    expect(writeBack.onPressed, isNull, reason: '空块回写进 manga.json 只会污染页面');
  });

  testWidgets('点「查词」返回 MangaRescanAction.lookup', (WidgetTester tester) async {
    MangaRescanAction? popped;
    await tester.pumpWidget(
      _sheetHost('こんにちは', (MangaRescanAction? a) => popped = a),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('manga_rescan_lookup')));
    await tester.pumpAndSettle();
    expect(popped, MangaRescanAction.lookup);
  });

  testWidgets('点「回写本页」返回 MangaRescanAction.writeBack',
      (WidgetTester tester) async {
    MangaRescanAction? popped;
    await tester.pumpWidget(
      _sheetHost('こんにちは', (MangaRescanAction? a) => popped = a),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey<String>('manga_rescan_writeback')));
    await tester.pumpAndSettle();
    expect(popped, MangaRescanAction.writeBack);
  });
}
