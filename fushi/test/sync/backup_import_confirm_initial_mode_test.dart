import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/onboarding/recommended_pack_import.dart'
    show kRecommendedPackImportMode;
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show BackupImportMode, showBackupImportConfirmDialogForTesting;
import 'package:material_ui/material_ui.dart';

/// 拍板台 pr3449：推荐包导入**照弹**确认框，但打开时预选「合并」。
///
/// BUG-4698 的根因就是这个框的预选项：通用备份导入框默认选「覆盖」，用户照默认点
/// 「确定」，整库被推荐包里只有词典的库替换。这里真弹确认框、不碰任何选项直接点
/// 「确定」，咬住「打开时预选的是谁」这一交互契约：推荐包 → 合并；设置页通用导入
/// 保持既有的「覆盖」；预选合并时用户仍可主动改选覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  final BackupMeta meta = BackupMeta(
    appVersion: '2.0.0',
    schemaVersion: 1,
    createdAt: DateTime(2026, 11, 16),
    bookCount: 0,
    statsCount: 0,
  );

  Future<Future<BackupImportMode?> Function()> pumpOpener(
    WidgetTester tester, {
    required BackupImportMode initialMode,
  }) async {
    Future<BackupImportMode?>? result;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => TextButton(
                onPressed: () {
                  result = showBackupImportConfirmDialogForTesting(
                    ctx,
                    meta,
                    initialMode: initialMode,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(t.backup_import_confirm_title), findsOneWidget);
    return () => result!;
  }

  Future<void> tapOk(WidgetTester tester) async {
    await tester.tap(find.text(t.dialog_ok));
    await tester.pumpAndSettle();
  }

  test('recommended pack preselects merge', () {
    expect(kRecommendedPackImportMode, BackupImportMode.merge);
  });

  testWidgets('recommended pack: confirming untouched imports as merge', (
    WidgetTester tester,
  ) async {
    final Future<BackupImportMode?> Function() result = await pumpOpener(
      tester,
      initialMode: kRecommendedPackImportMode,
    );
    await tapOk(tester);
    expect(await result(), BackupImportMode.merge);
  });

  testWidgets('generic backup import keeps overwrite as the preselection', (
    WidgetTester tester,
  ) async {
    final Future<BackupImportMode?> Function() result = await pumpOpener(
      tester,
      initialMode: BackupImportMode.overwrite,
    );
    await tapOk(tester);
    expect(await result(), BackupImportMode.overwrite);
  });

  testWidgets('merge preselected: user can still pick overwrite explicitly', (
    WidgetTester tester,
  ) async {
    final Future<BackupImportMode?> Function() result = await pumpOpener(
      tester,
      initialMode: kRecommendedPackImportMode,
    );
    await tester.tap(find.text(t.backup_import_mode_overwrite));
    await tester.pumpAndSettle();
    await tapOk(tester);
    expect(await result(), BackupImportMode.overwrite);
  });

  testWidgets('cancel returns null', (WidgetTester tester) async {
    final Future<BackupImportMode?> Function() result = await pumpOpener(
      tester,
      initialMode: kRecommendedPackImportMode,
    );
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(await result(), isNull);
  });
}
