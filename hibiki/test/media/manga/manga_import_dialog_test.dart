import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/manga/manga_import_dialog.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  late HibikiDatabase db;

  setUp(() {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Widget wrap(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: child)),
    );
  }

  testWidgets('renders pick + confirm; confirm disabled until a file picked',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrap(MangaImportDialog(db: db)));
    await tester.pump();

    // 选取按钮存在。
    expect(find.byType(OutlinedButton), findsWidgets);

    // 未选文件时 confirm 按钮 onPressed == null（禁用）。
    final FilledButton confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, t.manga_import_confirm),
    );
    expect(confirm.onPressed, isNull,
        reason: 'confirm must be disabled before a valid .mokuro is picked');
  });
}
