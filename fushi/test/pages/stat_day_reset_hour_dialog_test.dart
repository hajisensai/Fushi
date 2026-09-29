import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/stat_day_reset_hour_dialog.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 「今日」重置时刻从「阅读」设置页挪到统计中心（用户 2026-09-18）：
///  * 弹窗本体：标题 / 说明文案 / `HH:00` 外显齐全，点 + 即写穿偏好并镜像到
///    `FushiDatabase.statDayResetHour`（dateKey 派生的唯一输入）；
///  * 结构守卫：统计中心页头必须挂带文字标签（label）的入口按钮并落到本弹窗，
///    阅读设置 schema 不再保留该项（挪走不是复制，否则两处各改一份）。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    FushiDatabase.statDayResetHour = 0;
  });

  tearDown(() {
    FushiDatabase.statDayResetHour = 0;
  });

  Future<(FushiDatabase, AppModel, Directory)> harness() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tmpDir =
        Directory.systemTemp.createTempSync('fushi_day_reset_dialog_');
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo, databaseDirectory: tmpDir);
    return (db, appModel, tmpDir);
  }

  testWidgets('renders title, explanation and HH:00 value', (
    WidgetTester tester,
  ) async {
    final (FushiDatabase db, AppModel appModel, Directory tmpDir) =
        await harness();
    addTearDown(() async {
      await db.close();
      tmpDir.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(body: StatDayResetHourDialog(appModel: appModel)),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text(t.stat_center_day_reset_action), findsOneWidget);
    expect(find.text(t.stat_center_day_reset_hour), findsOneWidget);
    expect(find.text(t.stat_center_day_reset_hour_hint), findsOneWidget);
    expect(find.text('00:00'), findsOneWidget);
    expect(find.text(t.dialog_close), findsOneWidget);
  });

  testWidgets('stepping writes through to prefs and FushiDatabase mirror', (
    WidgetTester tester,
  ) async {
    final (FushiDatabase db, AppModel appModel, Directory tmpDir) =
        await harness();
    addTearDown(() async {
      await db.close();
      tmpDir.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(body: StatDayResetHourDialog(appModel: appModel)),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('01:00'), findsOneWidget);
    expect(appModel.statDayResetHour, 1);
    expect(FushiDatabase.statDayResetHour, 1,
        reason: '弹窗写穿必须走 AppModel.setStatDayResetHour，镜像到 DB 静态量');

    // 真落库：新建仓储重读同一个 DB 得到同一值。
    final PreferencesRepository reread = PreferencesRepository(db);
    await reread.loadFromDb();
    expect(reread.statDayResetHour, 1);

    await tester.tap(find.byIcon(Icons.remove));
    await tester.pumpAndSettle();
    expect(find.text('00:00'), findsOneWidget);
    expect(appModel.statDayResetHour, 0);

    // 下限夹紧：0 再减仍是 0。
    await tester.tap(find.byIcon(Icons.remove));
    await tester.pumpAndSettle();
    expect(find.text('00:00'), findsOneWidget);
    expect(appModel.statDayResetHour, 0);
  });

  testWidgets('opens through showStatDayResetHourDialog without layout errors',
      (WidgetTester tester) async {
    final (FushiDatabase db, AppModel appModel, Directory tmpDir) =
        await harness();
    addTearDown(() async {
      await db.close();
      tmpDir.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ElevatedButton(
                onPressed: () => showStatDayResetHourDialog(context, appModel),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // AlertDialog 用 IntrinsicWidth 包内容：内容里若有 LayoutBuilder 会在这里抛
    // 「does not support returning intrinsic dimensions」——真实弹出路径必须干净。
    expect(tester.takeException(), isNull);
    expect(find.text(t.stat_center_day_reset_hour), findsOneWidget);
    expect(find.text('00:00'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('01:00'), findsOneWidget);
    expect(appModel.statDayResetHour, 1);

    await tester.tap(find.text(t.dialog_close));
    await tester.pumpAndSettle();
    expect(find.text(t.stat_center_day_reset_hour), findsNothing);
  });

  testWidgets('phone width (360dp) lays out without overflow', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final (FushiDatabase db, AppModel appModel, Directory tmpDir) =
        await harness();
    addTearDown(() async {
      await db.close();
      tmpDir.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ElevatedButton(
                onPressed: () => showStatDayResetHourDialog(context, appModel),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: '定宽 480 的内容在 360dp 窄屏必须被对话框约束夹住而不是溢出');
    expect(find.text('00:00'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('01:00'), findsOneWidget);
  });

  test('统计中心页头挂带文字标签的入口；阅读设置不再保留该项', () {
    final String center = File(
      'lib/src/pages/implementations/statistics_center_page.dart',
    ).readAsStringSync();
    expect(center, contains('showStatDayResetHourDialog('));
    expect(center, contains('label: t.stat_center_day_reset_action'),
        reason: '页头入口必须是带文字说明的按钮（宽窗展开成图标 + 文字）');
    expect(center, contains('tooltip: t.stat_center_day_reset_hour'));

    final String reading = File(
      'lib/src/settings/settings_schema_reading.dart',
    ).readAsStringSync();
    expect(reading, isNot(contains("id: 'reading.stats_day_reset_hour'")),
        reason: '是挪走不是复制：阅读设置里不再有「今日从几点开始」');
    expect(reading, isNot(contains('setStatDayResetHour(')));
  });
}
