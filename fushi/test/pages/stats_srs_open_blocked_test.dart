// BUG-5454（反馈 m2tUYgIijK）：复习库待升级（SrsStoreNotMigrated(needsMigration)）时，统计中心「总览」整页
// 「加载出错」、重试也一样；「复习」tab 只给笼统的「加载出错」。代际状态不是加载失败：总览照常出、不并复习时长，
// 「复习」tab 给迁移页（SrsGenerationView），都不写错误日志。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_generation_view.dart';
import 'package:fushi/src/pages/implementations/srs_statistics_page.dart';
import 'package:fushi/src/pages/implementations/statistics_center_page.dart';
import 'package:fushi/src/srs/srs_gen4_migration_controller.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart'
    show SrsCoreException, SrsGenState, SrsStoreNotMigrated;
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

const SrsStoreNotMigrated _needsMigration = SrsStoreNotMigrated(
  'gen4 store: not migrated yet',
  SrsGenState.needsMigration,
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('statsOverviewSrsStorage', () {
    test('库待升级 / 迁移中 / 旧主库待搬：返回 null，总览照常出', () async {
      for (final Exception blocked in <Exception>[
        _needsMigration,
        const SrsStoreNotMigrated('x', SrsGenState.migratingElsewhere),
        const SrsStoreNotMigrated('x', SrsGenState.migrationFailed),
        const SrsLegacyMainDatabasePending(),
      ]) {
        expect(
          await statsOverviewSrsStorage(() async => throw blocked),
          isNull,
          reason: '$blocked',
        );
      }
    });

    test('别的错误照抛（真的加载失败仍给「加载出错」）', () async {
      await expectLater(
        statsOverviewSrsStorage(
          () async => throw const SrsCoreException(1, 'disk I/O error'),
        ),
        throwsA(isA<SrsCoreException>()),
      );
      await expectLater(
        statsOverviewSrsStorage(() async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
    });

    test('打开成功 / 模块没有库：原样返回', () async {
      expect(await statsOverviewSrsStorage(() async => null), isNull);
    });
  });

  testWidgets('「复习」tab：库待升级时给迁移页，不是「加载出错」', (WidgetTester tester) async {
    final AppModel appModel = AppModel(testPlatformServices());
    final SrsGen4MigrationController controller = SrsGen4MigrationController(
      directory: 'unused',
      profileUids: () async => <String>[],
      onCommitted: () async {},
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => appModel),
          srsStoreProvider.overrideWith(
            (Ref ref) async => throw _needsMigration,
          ),
          srsGen4IsMainProcessProvider.overrideWithValue(true),
          srsGen4MigrationProvider.overrideWithValue(controller),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: buildFushiThemeData(
              scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
              textTheme: Typography.material2021().black,
              glass: FushiGlassMaterial.off,
              glassDesign: false,
            ),
            builder: (BuildContext context, Widget? child) =>
                FushiGlassScope(child: child!),
            home: const Scaffold(body: SrsStatisticsTab()),
          ),
        ),
      ),
    );
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(SrsGenerationView), findsOneWidget);
    expect(find.byKey(SrsGenerationView.startKey), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('srs-stats-retry')), findsNothing);
    expect(find.text(t.error_load_failed), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
