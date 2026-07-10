import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-634 第四次复诉根因（连续模式误导）守卫：
/// 「每页列数」(pageColumns / `reading_display.page_columns`) 的 CSS multicol 列模型
/// 只存在于翻页(paginated)布局（`reader_content_styles.dart` 只把 columnsCss 传给
/// `_paginatedLayoutCss`）；连续滚动(continuous)与 VN 模式的布局根本不含 column-count。
/// 用户在连续模式把它设成 4 却无任何变化 → 误判「功能坏了」（此前三轮 triage 都被引到
/// 「构建过旧」上，因为没人看用户 DB 的 `ttu_view_mode=continuous`）。
///
/// 根因修复 = 非翻页模式隐藏该设置项（`visible: isPaginated`）。本守卫两层：
/// ① schema 层：该项仅在 `ttu_view_mode == 'paginated'` 时可见；
/// ② CSS 层：连续模式即便 pageColumns>0 也不发 `column-count`，翻页模式才发——
///    证明隐藏是对的（连续下它确实无效），而非藏掉一个本可工作的功能。
void main() {
  /// 从真实生产 schema 取出「每页列数」这条 stepper（测的是生产配置本身）。
  SettingsStepperItem pageColumnsItem(SettingsContext settingsContext) {
    return buildSettingsSchema(settingsContext)
        .expand((SettingsDestination d) => d.sections)
        .expand((SettingsSection s) => s.items)
        .whereType<SettingsStepperItem>()
        .firstWhere(
            (SettingsStepperItem i) => i.id == 'reading_display.page_columns');
  }

  group('page columns visibility (schema)', () {
    late HibikiDatabase db;
    late ReaderSettings readerSettings;

    setUp(() async {
      db = HibikiDatabase.forTesting(NativeDatabase.memory());
      MediaSource.setDatabase(db);
      readerSettings = ReaderSettings(db);
      await readerSettings.refreshFromDb();
      ReaderHibikiSource.readerSettings = readerSettings;
    });

    tearDown(() async {
      ReaderHibikiSource.readerSettings = null;
      await db.close();
    });

    testWidgets('shown in paginated, hidden in continuous / vn', (
      WidgetTester tester,
    ) async {
      // 捕获真实 SettingsContext + 生产 schema 里的该项；`isVisible` 只读
      // `readerSource.ttuViewMode`，不依赖 BuildContext，故可在帧外异步切模式后复查。
      late SettingsContext settingsContext;
      late SettingsStepperItem item;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) {
                settingsContext = SettingsContext(
                  context: context,
                  appModel: AppModel(testPlatformServices()),
                  ref: ref,
                  readerSource: ReaderHibikiSource.instance,
                  refresh: () {},
                );
                item = pageColumnsItem(settingsContext);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      await readerSettings.setViewMode('paginated');
      expect(item.isVisible(settingsContext), isTrue,
          reason: '翻页模式：每页列数生效，必须显示');

      await readerSettings.setViewMode('continuous');
      expect(item.isVisible(settingsContext), isFalse,
          reason: '连续滚动无「页」可分列 → 该项无效 → 隐藏，避免误导');

      await readerSettings.setViewMode('vn');
      expect(item.isVisible(settingsContext), isFalse,
          reason: 'VN 模式单屏 stage 布局无 multicol → 隐藏');
    });
  });

  group('page columns CSS effect (behavior)', () {
    late HibikiDatabase db;
    late ReaderSettings settings;

    setUp(() async {
      db = HibikiDatabase.forTesting(NativeDatabase.memory());
      settings = ReaderSettings(db);
      await settings.refreshFromDb();
      // 用户实测场景：竖排、列数设成 4。
      await settings.setWritingMode('vertical-rl');
      await settings.setPageColumns(4);
    });

    tearDown(() async {
      await db.close();
    });

    test('continuous mode ignores pageColumns (no column-count)', () async {
      await settings.setViewMode('continuous');
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, isNot(contains('column-count')),
          reason: '连续模式布局不含 multicol，列数无从生效——正是隐藏该设置的理由');
    });

    test('paginated mode honors pageColumns (column-count: 4)', () async {
      await settings.setViewMode('paginated');
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('column-count: 4'),
          reason: '翻页模式必须真发 column-count:4，每页排 4 列');
    });
  });
}
