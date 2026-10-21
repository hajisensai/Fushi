// 「从 Anki 迁移」的设置页与迁移设置：排程算法 / Lapis 模板这些选择在开始前一页给全，
// 选了「导入后把旧 Lapis 迁到 Fushi 卡片」时由迁移任务自己完成（不依赖迁移页还开着）。
//
// 数据库读写一律放 tester.runAsync（fake zone 里 await 真异步会挂死）。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_anki_migration_setup_page.dart';
import 'package:fushi/src/srs/srs_anki_migration.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('SrsAnkiMigrationSettings', () {
    test('默认：迁移选项（带排程与预设）、RWKV、转换 Lapis', () {
      const SrsAnkiMigrationSettings d = SrsAnkiMigrationSettings();
      expect(d.options, kSrsAnkiMigrationOptions);
      expect(d.options.useRwkv, isTrue);
      expect(d.convertLapis, isTrue);
    });

    test('JSON 往返；缺项 / 坏值回落到默认', () {
      final SrsAnkiMigrationSettings s = SrsAnkiMigrationSettings(
        options: kSrsAnkiMigrationOptions.copyWith(
          useRwkv: false,
          withScheduling: false,
        ),
        convertLapis: false,
      );
      final SrsAnkiMigrationSettings back = SrsAnkiMigrationSettings.fromJson(
        s.toJson(),
      );
      expect(back.options, s.options);
      expect(back.convertLapis, isFalse);
      final SrsAnkiMigrationSettings broken = SrsAnkiMigrationSettings.fromJson(
        <String, Object?>{'options': 'nope', 'convertLapis': 3},
      );
      expect(broken.options, kSrsAnkiMigrationOptions);
      expect(broken.convertLapis, isTrue);
    });
  });

  test('导入后转换 Lapis：内置 Lapis 笔记迁到 Fushi 卡片，计入报告', () async {
    final (FushiDatabase db, SrsDbStore store) = await openSrsTestStore();
    addTearDown(db.close);
    final String note = await store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(store.profileUid, 'Expression'): '切磋琢磨',
      },
    );
    final SrsImportReport report = SrsImportReport();
    await srsConvertLegacyLapisAfterImport(store, report);
    expect(report.lapisMigrationFailed, isFalse);
    expect(report.lapisNotesMigrated, 1);
    expect((await store.note(note))!.noteTypeId, store.fushiCardNoteTypeId);
  });

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('[$ds] 设置页列出全部选择与提醒；改成 FSRS、不转 Lapis 后开始，返回所选', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1100, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SrsAnkiMigrationSettings? result;
      bool returned = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            appProvider.overrideWith(
              (Ref ref) => AppModel(testPlatformServices()),
            ),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              theme: buildFushiThemeData(
                scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
                textTheme: Typography.material2021().black,
                designSystem: apple
                    ? FushiDesignSystem.cupertino
                    : FushiDesignSystem.material,
                glass: FushiGlassMaterial.off,
                glassDesign: apple,
              ),
              builder: (BuildContext context, Widget? child) =>
                  FushiGlassScope(child: child!),
              home: Builder(
                builder: (BuildContext context) => Center(
                  child: TextButton(
                    onPressed: () async {
                      result = await openSrsAnkiMigrationSetupPage(
                        context,
                        sourceName: 'User 1',
                        summary: 'summary-line',
                        initial: const SrsAnkiMigrationSettings(),
                        sourceProbablyOpen: true,
                      );
                      returned = true;
                    },
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('summary-line'), findsOneWidget);
      expect(find.text(t.srs_anki_migrate_open_warning), findsOneWidget);
      expect(find.text(t.srs_anki_migrate_setup_algorithm), findsOne);
      expect(find.text(t.srs_anki_migrate_setup_algorithm_rwkv_desc), findsOne);
      expect(find.text(t.srs_anki_migrate_setup_convert_lapis), findsOne);

      await tester.tap(find.text('FSRS'));
      await tester.pumpAndSettle();
      expect(find.text(t.srs_anki_migrate_setup_algorithm_fsrs_desc), findsOne);
      expect(
        find.text(t.srs_anki_migrate_setup_algorithm_rwkv_desc),
        findsNothing,
      );

      await tester.tap(find.text(t.srs_anki_migrate_setup_convert_lapis));
      await tester.pumpAndSettle();

      // 列表是懒构建的：逐个滚到再断言（滚过头的会被回收）。
      for (final String key in <String>[
        'merge',
        'restore',
        'background',
        'backup',
      ]) {
        final Finder notice = find.byKey(
          ValueKey<String>('srs-anki-setup-notice-$key'),
        );
        await tester.scrollUntilVisible(
          notice,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(notice, findsOneWidget);
      }
      final Finder start = find.byKey(
        const ValueKey<String>('srs-anki-setup-start'),
      );
      await tester.scrollUntilVisible(
        start,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(start);
      await tester.pumpAndSettle();

      expect(returned, isTrue);
      expect(result, isNotNull);
      expect(result!.options.useRwkv, isFalse);
      expect(result!.convertLapis, isFalse);
      expect(result!.options.withScheduling, isTrue);
    });
  }
}
