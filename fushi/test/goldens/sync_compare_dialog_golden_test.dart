import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/sync_compare_dialog.dart';
import 'package:fushi_core/fushi_core.dart';

import '../sync/helpers/sync_compare_fixture.dart';

/// 同步对比对话框排版的 golden（C3 改前/改后对照）。场景见
/// [seedCompareScenario]；1200 宽下对话框吃到 720 的上限。字体是测试字体，只比排版。
FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('sync compare dialog · wide', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final FakeCompareBackend fake = await seedCompareScenario(db);

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: SyncCompareDialog(db: db, backend: fake),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('golden_files/sync_compare_dialog_wide.png'),
    );
  }, tags: <String>['golden']);
}
