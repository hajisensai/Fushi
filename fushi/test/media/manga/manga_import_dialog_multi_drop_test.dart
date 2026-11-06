/// 用户实报：漫画库多选拖入只导进来一本。拖放落点把整组漫画路径交给
/// [MangaImportDialog.initialPaths]；≥2 卷时对话框必须进「逐卷批量」模式（说明要导
/// 几卷、不再显示单一标题框），而不是只收第一个、其余静默丢掉。
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/manga_import_dialog.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late FushiDatabase db;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpDialog(WidgetTester tester, List<String> paths) async {
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: MangaImportDialog(db: db, initialPaths: paths),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('多卷预填 → 逐卷批量模式，列出每一卷', (WidgetTester tester) async {
    await pumpDialog(tester, <String>[
      r'C:\manga\vol01.cbz',
      r'C:\manga\vol02.cbz',
      r'C:\manga\vol03.cbz',
    ]);

    expect(
      find.text(t.manga_import_selection_batch_hint(n: 3)),
      findsOneWidget,
    );
    expect(find.textContaining('vol01.cbz'), findsOneWidget);
    expect(find.textContaining('vol03.cbz'), findsOneWidget);
    expect(
      find.text(t.srt_import_title_hint),
      findsNothing,
      reason: '一个标题套 N 卷只会得到 X / X (2)……，批量模式不显示标题框',
    );
  });

  testWidgets('非漫画路径不计入批量（只剩一卷时按单卷处理）', (WidgetTester tester) async {
    await pumpDialog(tester, <String>[
      r'C:\manga\vol01.cbz',
      r'C:\manga\notes.txt',
    ]);

    expect(find.text(t.manga_import_selection_batch_hint(n: 2)), findsNothing);
    expect(find.text(t.srt_import_title_hint), findsOneWidget);
  });
}
