import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 阅读器正文字重（`reading_display.font_weight`）。与字号一样是纯 CSS 键：写穿
/// `ReaderSettings` → `ReaderContentStyles` 在 `body` 上发 `font-weight` →
/// `onSettingsChangedLive` 热替换 `<style>`。这里守三条不变式：
///  ① schema 值域是 CSS 数值轴 100~900 / 步进 100（不是 Flutter 的 w100..w900 索引）；
///  ② **默认 400 不发声明**——书自带样式表原样生效，功能引入前后渲染一致（零回归）；
///  ③ 非默认值写穿 DB 并落进三种视图模式（paginated / continuous / vn）的正文 CSS，
///     且是整数（`font-weight: 700`，绝不能是 double 往返出来的非法 `700.0`）。
void main() {
  /// 从真实 schema 取这条 stepper（保证测的是生产配置，不是测试自拟副本）。
  SettingsStepperItem readerFontWeightItem(SettingsContext settingsContext) {
    return buildSettingsSchema(settingsContext)
        .expand((SettingsDestination d) => d.sections)
        .expand((SettingsSection s) => s.items)
        .whereType<SettingsStepperItem>()
        .firstWhere(
          (SettingsStepperItem i) => i.id == 'reading_display.font_weight',
        );
  }

  group('reader font weight (schema)', () {
    late FushiDatabase db;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      MediaSource.setDatabase(db);
      final ReaderSettings readerSettings = ReaderSettings(db);
      await readerSettings.refreshFromDb();
      ReaderFushiSource.readerSettings = readerSettings;
    });

    tearDown(() async {
      ReaderFushiSource.readerSettings = null;
      await db.close();
    });

    testWidgets('stepper walks the CSS 100..900 axis and defaults to 400', (
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
                  readerSource: ReaderFushiSource.instance,
                  refresh: () {},
                );
                final SettingsStepperItem item = readerFontWeightItem(
                  settingsContext,
                );
                expect(item.min, 100, reason: 'CSS font-weight 数值轴下界');
                expect(item.max, 900, reason: 'CSS font-weight 数值轴上界');
                expect(item.step, 100, reason: '字重按档走，不是连续值');
                expect(
                  item.value(settingsContext),
                  400,
                  reason: '默认 400 = CSS normal',
                );
                expect(item.format(400), '400', reason: '展示成整数档位，不能出现 400.0');
                // 落在「排版」组里字号的紧邻位（order 1 是字号）。
                expect(item.reader!.group, ReaderGroup.layout);
                expect(item.reader!.order, 2);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
    });
  });

  group('reader font weight (behavior)', () {
    Future<ReaderSettings> freshSettings() async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      return settings;
    }

    test('default 400 emits no font-weight declaration at all', () async {
      final ReaderSettings settings = await freshSettings();
      expect(settings.fontWeight, 400);

      for (final String mode in <String>['paginated', 'continuous', 'vn']) {
        await settings.setViewMode(mode);
        final String css = ReaderContentStyles.css(settings: settings);
        // 断言收窄到「本设置注入的那条声明」，不要用裸 'font-weight' 扫整份 CSS：
        // 那样任何未来 PR 只要在阅读器 CSS 的任意位置（<rt>、滚动条、@font-face
        // 描述符…）写一条 font-weight，这条就红，而红的原因与那个 PR 无关。
        expect(
          css,
          isNot(contains(RegExp(r'font-weight:\s*\d'))),
          reason: '默认值必须不注入任何 font-weight 声明：书自带样式表原样生效（零回归）[$mode]',
        );
      }
    });

    test('a non-default weight persists and reaches the body CSS', () async {
      final ReaderSettings settings = await freshSettings();
      await settings.setFontWeight(700);
      expect(settings.fontWeight, 700);

      for (final String mode in <String>['paginated', 'continuous', 'vn']) {
        await settings.setViewMode(mode);
        final String css = ReaderContentStyles.css(settings: settings);
        expect(
          css,
          contains('font-weight: 700 !important;'),
          reason: '三种视图模式的 body 都要带上用户选的字重 [$mode]',
        );
        expect(
          css,
          isNot(contains('font-weight: 700.0')),
          reason: '字重是整数轴，double 往返出来的 700.0 是非法 CSS [$mode]',
        );
      }
    });

    test('the weight survives a DB round-trip', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setFontWeight(300);

      final ReaderSettings restored = ReaderSettings(db);
      await restored.refreshFromDb();
      expect(restored.fontWeight, 300, reason: '字重必须真写穿 DB');
      expect(
        ReaderContentStyles.css(settings: restored),
        contains('font-weight: 300 !important;'),
      );
    });

    test(
      'the source facade rounds and fires the live-apply callback',
      () async {
        final FushiDatabase db = FushiDatabase.forTesting(
          NativeDatabase.memory(),
        );
        addTearDown(db.close);
        final ReaderSettings settings = ReaderSettings(db);
        await settings.refreshFromDb();
        ReaderFushiSource.readerSettings = settings;
        addTearDown(() => ReaderFushiSource.readerSettings = null);

        int calls = 0;
        ReaderFushiSource.onSettingsChangedLive = () => calls++;
        addTearDown(() => ReaderFushiSource.onSettingsChangedLive = null);

        // stepper 的值域是 double；边界必须 round 成整数再进存储 / CSS。
        await ReaderFushiSource.instance.setReaderFontWeight(600.0);

        expect(calls, 1, reason: '纯 CSS 键必须触发活样式热替换');
        expect(settings.fontWeight, 600);
        expect(ReaderFushiSource.instance.readerFontWeight, 600.0);
        expect(
          ReaderContentStyles.css(settings: settings),
          contains('font-weight: 600 !important;'),
        );
      },
    );
  });
}
