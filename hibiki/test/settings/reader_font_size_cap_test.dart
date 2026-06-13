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

/// 阅读器正文字号上限（TODO-299「为什么字体大小只有 64 最大」）：
/// `reading_display.font_size` 这条 stepper 的 `max` 旧值 64 是保守的 UI 上限，
/// 不是技术限制——CSS 直接 `font-size: ${fontSize}px`，ruby 用相对 `0.45em`，
/// column-gap / padding-bottom 也只是按字号加几像素，字号再大 WebView/分页都按
/// 渲染高度重新换行，没有上限依赖。抬到 128 给低视力/大屏用户留足空间。
/// 这里：① 守卫 schema 的 max 已抬过 64；② 行为证明 >64 的字号能写穿 DB 并落进
/// 生成的正文 CSS（不被任何 clamp 砍回 64）。
void main() {
  /// 从真实 schema 取出阅读器正文字号这条 stepper（保证测的是生产配置，不是
  /// 测试自拟副本）。
  SettingsStepperItem readerFontSizeItem(SettingsContext settingsContext) {
    return buildSettingsSchema(settingsContext)
        .expand((SettingsDestination d) => d.sections)
        .expand((SettingsSection s) => s.items)
        .whereType<SettingsStepperItem>()
        .firstWhere(
            (SettingsStepperItem i) => i.id == 'reading_display.font_size');
  }

  group('reader font size cap (schema)', () {
    late HibikiDatabase db;

    setUp(() async {
      db = HibikiDatabase.forTesting(NativeDatabase.memory());
      MediaSource.setDatabase(db);
      final ReaderSettings readerSettings = ReaderSettings(db);
      await readerSettings.refreshFromDb();
      ReaderHibikiSource.readerSettings = readerSettings;
    });

    tearDown(() async {
      ReaderHibikiSource.readerSettings = null;
      await db.close();
    });

    testWidgets('stepper max is raised above the old 64 cap', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) {
                final SettingsContext settingsContext = SettingsContext(
                  context: context,
                  appModel: AppModel(testPlatformServices()),
                  ref: ref,
                  readerSource: ReaderHibikiSource.instance,
                  refresh: () {},
                );
                final SettingsStepperItem item =
                    readerFontSizeItem(settingsContext);
                expect(item.min, 8, reason: '下限不变');
                expect(
                  item.max,
                  greaterThan(64),
                  reason: '旧的 64 保守上限必须抬高（TODO-299）',
                );
                expect(item.max, 128, reason: '当前抬到 128');
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
    });
  });

  group('reader font size cap (behavior)', () {
    test('a font size above 64 persists and reaches the body CSS', () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();

      // 96 > 旧上限 64：旧 max 下根本到不了，新 max(128) 下合法。
      await settings.setFontSize(96);

      // 同实例已生效。
      expect(settings.fontSize, 96);

      // DB 往返：新 ReaderSettings 从库里重读得到同一值（没有被 clamp 回 64）。
      final ReaderSettings restored = ReaderSettings(db);
      await restored.refreshFromDb();
      expect(restored.fontSize, 96, reason: '>64 的字号必须真写穿 DB，不被持久化层砍回上限');

      // 生成的正文 CSS 用的就是这个字号（DB 双精度往返渲染成 `96.0px`），
      // 不是被夹回 64 的值。
      final String css = ReaderContentStyles.css(settings: restored);
      expect(css, contains('font-size: 96.0px'),
          reason: '正文 CSS 必须用 96px（>64 字号能真生效渲染）');
      expect(css, isNot(contains('font-size: 64')));
    });
  });
}
