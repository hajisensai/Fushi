// 来源「自动扫描」开关（v155，拍板台 C_8oheua0H / ICOLa6LZLU / enSm2GOuFA）：来源行
// 菜单切换、名字后的时钟角标；首页自动扫描在扫这一行时行级 loading 跟着亮、手动入口
// 置忙。Material 与 Apple 两套各跑一遍。
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/source_library/source_auto_scan.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

void main() {
  late FushiDatabase db;
  late int source;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    source = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Books',
        mediaKind: 'book',
        rootPath: 'D:/Books',
        createdAt: 1,
      ),
    );
  });

  tearDown(() => db.close());

  Future<void> pumpView(WidgetTester tester) async {
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(420, 800)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: MediaSourcesView(mediaKind: 'book'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  final TargetPlatformVariant platforms = TargetPlatformVariant(
    <TargetPlatform>{TargetPlatform.android, TargetPlatform.iOS},
  );

  testWidgets('row menu turns auto scan on and off; badge follows', (
    WidgetTester tester,
  ) async {
    await pumpView(tester);
    final Finder badge = find.byKey(
      ValueKey<String>('media_source_auto_scan_badge_$source'),
    );
    expect(badge, findsNothing, reason: '默认关');

    await tester.tap(find.byKey(ValueKey<String>('media_source_menu_$source')));
    await tester.pumpAndSettle();
    expect(find.text(t.media_source_auto_scan_enable), findsOneWidget);
    await tester.tap(
      find.byKey(ValueKey<String>('media_source_auto_scan_$source')),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect((await db.getMediaSourceById(source))!.autoScan, isTrue);
    expect(badge, findsOneWidget);

    await tester.tap(find.byKey(ValueKey<String>('media_source_menu_$source')));
    await tester.pumpAndSettle();
    expect(find.text(t.media_source_auto_scan_disable), findsOneWidget);
    await tester.tap(
      find.byKey(ValueKey<String>('media_source_auto_scan_$source')),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect((await db.getMediaSourceById(source))!.autoScan, isFalse);
    expect(badge, findsNothing);
  }, variant: platforms);

  testWidgets('an auto scan running elsewhere shows on the row and blocks '
      'row mutations', (WidgetTester tester) async {
    await pumpView(tester);
    expect(find.byType(FushiLinearProgressIndicator), findsNothing);

    final Completer<void> hold = Completer<void>();
    // 全局占用表跨用例共享：本用例中途失败也要放掉，不连累下一个变体。
    addTearDown(() {
      if (!hold.isCompleted) hold.complete();
    });
    final Future<void> autoScan = sourceScanActivity.run(
      source,
      () => hold.future,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(FushiLinearProgressIndicator), findsOneWidget);

    // 扫描期间行底进度条是无限动画，pumpAndSettle 永远不会停：改有界 pump。
    await tester.tap(find.byKey(ValueKey<String>('media_source_menu_$source')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final PopupMenuItem<Object?> remove = tester.widget(
      find.byKey(ValueKey<String>('media_source_remove_$source')),
    );
    expect(remove.enabled, isFalse, reason: '扫描期间不许移除来源');
    final PopupMenuItem<Object?> toggle = tester.widget(
      find.byKey(ValueKey<String>('media_source_auto_scan_$source')),
    );
    expect(toggle.enabled, isTrue, reason: '自动扫描开关不随全局忙置灰，扫描途中也能关');
    await tester.tapAt(Offset.zero);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    hold.complete();
    await autoScan;
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.byType(FushiLinearProgressIndicator), findsNothing);
    expect(sourceScanActivity.isIdle, isTrue);
  }, variant: platforms);

  // 拍板台 design-nmv-scan-progress：长扫描在行内显示进度——列目录阶段「已找到 N 个
  // 文件 · 当前目录」+ 不定进度条，导入阶段「正在导入 i/n · 当前条目」+ 定量进度条。
  testWidgets('a running scan shows listing / importing progress on the row', (
    WidgetTester tester,
  ) async {
    await pumpView(tester);
    final Completer<void> hold = Completer<void>();
    addTearDown(() {
      if (!hold.isCompleted) hold.complete();
    });
    final Future<void> scan = sourceScanActivity.run(source, () => hold.future);
    await tester.pump();
    expect(find.text(t.media_source_scan_progress_started), findsOneWidget);

    sourceScanActivity.reportListing(source, 'D:/Books/Series A', 12);
    await tester.pump();
    expect(
      find.text(
        '${t.media_source_scan_progress_listing(count: 12)}  ·  Series A',
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FushiLinearProgressIndicator>(
            find.byType(FushiLinearProgressIndicator),
          )
          .value,
      isNull,
      reason: '列目录阶段总量未知，画不定进度条',
    );

    await tester.pump(const Duration(milliseconds: 300));
    sourceScanActivity.beginImport(source, 4);
    sourceScanActivity.reportImportItem(source, 'D:/Books/Series A/v1.epub');
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.text(
        '${t.media_source_scan_progress_importing(current: 1, total: 4)}'
        '  ·  v1.epub',
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FushiLinearProgressIndicator>(
            find.byType(FushiLinearProgressIndicator),
          )
          .value,
      0.25,
    );

    hold.complete();
    await scan;
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(ValueKey<String>('media_source_scan_progress_$source')),
      findsNothing,
    );
    expect(find.byType(FushiLinearProgressIndicator), findsNothing);
  }, variant: platforms);
}
