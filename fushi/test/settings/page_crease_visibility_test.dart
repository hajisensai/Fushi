import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 「中缝折痕」(`reading_display.page_crease`) 只在开关真能生效时露出：翻页模式且本次
/// 排版实际恰好两栏（每页列数 = 2，或「自动」在折叠屏书本姿态 + 横排下被解析成两栏）。
/// 列数 ≠ 2 时 CSS 根本不发折痕（`ReaderContentStyles.pageCreaseApplies`），此前该项
/// 照样显示，用户打开了看不到任何变化。判据与 CSS 生成同源，这里咬住 schema 显隐。
void main() {
  SettingsSwitchItem creaseItem(SettingsContext settingsContext) {
    return buildSettingsSchema(settingsContext)
        .expand((SettingsDestination d) => d.sections)
        .expand((SettingsSection s) => s.items)
        .whereType<SettingsSwitchItem>()
        .firstWhere(
          (SettingsSwitchItem i) => i.id == 'reading_display.page_crease',
        );
  }

  late FushiDatabase db;
  late ReaderSettings readerSettings;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    readerSettings = ReaderSettings(db);
    await readerSettings.refreshFromDb();
    ReaderFushiSource.readerSettings = readerSettings;
  });

  tearDown(() async {
    ReaderFushiSource.readerSettings = null;
    await db.close();
  });

  testWidgets('仅在翻页且实际两栏时显示（含折叠屏书本姿态下的自动两栏）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late SettingsContext flat;
    late SettingsContext book;
    late SettingsSwitchItem item;

    Widget capture(void Function(SettingsContext) sink) => Consumer(
      builder: (BuildContext context, WidgetRef ref, _) {
        final SettingsContext c = SettingsContext(
          context: context,
          appModel: AppModel(testPlatformServices()),
          ref: ref,
          readerSource: ReaderFushiSource.instance,
          refresh: () {},
        );
        sink(c);
        item = creaseItem(c);
        return const SizedBox.shrink();
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              final MediaQueryData mq = MediaQuery.of(context);
              return Column(
                children: <Widget>[
                  capture((SettingsContext c) => flat = c),
                  MediaQuery(
                    data: mq.copyWith(
                      displayFeatures: const <DisplayFeature>[
                        DisplayFeature(
                          bounds: Rect.fromLTWH(400, 0, 0, 600),
                          type: DisplayFeatureType.fold,
                          state: DisplayFeatureState.postureHalfOpened,
                        ),
                      ],
                    ),
                    child: capture((SettingsContext c) => book = c),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    await readerSettings.setViewMode('paginated');
    await readerSettings.setWritingMode('horizontal-tb');

    await readerSettings.setPageColumns(2);
    expect(item.isVisible(flat), isTrue, reason: '翻页 + 两栏：折痕生效');

    for (final int columns in <int>[1, 3, 4]) {
      await readerSettings.setPageColumns(columns);
      expect(
        item.isVisible(flat),
        isFalse,
        reason: '每页 $columns 栏没有「两页之间」，开关无效必须隐藏',
      );
      expect(item.isVisible(book), isFalse, reason: '用户显式列数优先于折叠姿态');
    }

    await readerSettings.setPageColumns(0);
    expect(item.isVisible(flat), isFalse, reason: '自动列数在普通屏是单栏');
    expect(item.isVisible(book), isTrue, reason: '自动列数在书本姿态 + 横排被解析成两栏，折痕生效');

    await readerSettings.setWritingMode('vertical-rl');
    expect(item.isVisible(book), isFalse, reason: '竖排不做折叠自动两栏');

    await readerSettings.setPageColumns(2);
    for (final String mode in <String>['continuous', 'vn']) {
      await readerSettings.setViewMode(mode);
      expect(item.isVisible(flat), isFalse, reason: '$mode 模式不经多列');
      expect(item.isVisible(book), isFalse, reason: '$mode 模式不经多列');
    }
  });
}
