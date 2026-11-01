import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/utils.dart' show FushiMotion, t;
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show readerChapterFadeInEnabled;
import 'package:fushi/src/reader/page_turn_animation.dart';
import 'package:fushi/src/reader/reader_engine_config.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/settings/settings_schema_widgets.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 小说阅读器翻页动画的偏好、降级与设置项。
void main() {
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

  group('偏好', () {
    test('默认：淡入淡出 / 正常 / 跟手开', () {
      expect(readerSettings.pageTurnAnimation, PageTurnAnimation.fade);
      expect(
        readerSettings.pageTurnAnimationSpeed,
        PageTurnAnimationSpeed.normal,
      );
      expect(readerSettings.pageTurnFollowDrag, isTrue);
      expect(
        ReaderFushiSource.instance.pageTurnAnimation,
        PageTurnAnimation.fade,
      );
    });

    test('写入后重启读回；未知值回落默认', () async {
      await readerSettings.setPageTurnAnimation(PageTurnAnimation.cover);
      await readerSettings.setPageTurnAnimationSpeed(
        PageTurnAnimationSpeed.slow,
      );
      await readerSettings.setPageTurnFollowDrag(false);
      final ReaderSettings restored = ReaderSettings(db);
      await restored.refreshFromDb();
      expect(restored.pageTurnAnimation, PageTurnAnimation.cover);
      expect(restored.pageTurnAnimationSpeed, PageTurnAnimationSpeed.slow);
      expect(restored.pageTurnFollowDrag, isFalse);

      await db.setPref('src:reader_fushi:page_turn_animation', 'curl');
      await db.setPref('src:reader_fushi:page_turn_animation_speed', 'warp');
      await restored.refreshFromDb();
      expect(restored.pageTurnAnimation, PageTurnAnimation.fade);
      expect(restored.pageTurnAnimationSpeed, PageTurnAnimationSpeed.normal);
    });

    test('readerSettings 为空的旁路写入（PrefCodec 标签值）能被 ReaderSettings 读回', () async {
      ReaderFushiSource.readerSettings = null;
      await ReaderFushiSource.instance.setPageTurnAnimation(
        PageTurnAnimation.slide,
      );
      await ReaderFushiSource.instance.setPageTurnAnimationSpeed(
        PageTurnAnimationSpeed.fast,
      );
      final ReaderSettings restored = ReaderSettings(db);
      await restored.refreshFromDb();
      expect(restored.pageTurnAnimation, PageTurnAnimation.slide);
      expect(restored.pageTurnAnimationSpeed, PageTurnAnimationSpeed.fast);
    });
  });

  group('降级', () {
    test('动效不可播（墨水屏 / 减弱动态效果）时一律无，淡入也不例外', () {
      for (final PageTurnAnimation a in PageTurnAnimation.values) {
        expect(
          effectivePageTurnAnimation(a, motionEnabled: false),
          PageTurnAnimation.none,
          reason: '$a 在减弱动态效果 / 墨水屏下必须降成无（时长归零）',
        );
        expect(effectivePageTurnAnimation(a, motionEnabled: true), a);
      }
    });

    testWidgets('系统「减弱动态效果」下两个阅读器共用的判据为 false → 实际效果为无', (
      WidgetTester tester,
    ) async {
      Future<({bool motion, PageTurnAnimation effective})> probe({
        required bool disableAnimations,
        required bool eink,
      }) async {
        late bool motion;
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(disableAnimations: disableAnimations),
            child: Theme(
              data: ThemeData(),
              child: Builder(
                builder: (BuildContext context) {
                  motion = pageTurnMotionEnabledOf(context, eink: eink);
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        );
        return (
          motion: motion,
          effective: effectivePageTurnAnimation(
            PageTurnAnimation.slide,
            motionEnabled: motion,
          ),
        );
      }

      final reduced = await probe(disableAnimations: true, eink: false);
      expect(reduced.motion, isFalse);
      expect(reduced.effective, PageTurnAnimation.none);

      final eink = await probe(disableAnimations: false, eink: true);
      expect(eink.motion, isFalse);
      expect(eink.effective, PageTurnAnimation.none);

      final normal = await probe(disableAnimations: false, eink: false);
      expect(normal.motion, isTrue);
      expect(normal.effective, PageTurnAnimation.slide);
    });

    test('速度三档时长取 FushiMotion token，不另立毫秒常量', () {
      expect(PageTurnAnimationSpeed.fast.duration, FushiMotion.short);
      expect(PageTurnAnimationSpeed.normal.duration, FushiMotion.longReverse);
      expect(PageTurnAnimationSpeed.slow.duration, FushiMotion.medium);
      for (final PageTurnAnimationSpeed sp in PageTurnAnimationSpeed.values) {
        expect(sp.durationMs, sp.duration.inMilliseconds);
      }
    });

    test('跨章淡入只在翻页模式且效果非无', () {
      expect(
        readerChapterFadeInEnabled(
          viewMode: 'paginated',
          effect: PageTurnAnimation.fade,
        ),
        isTrue,
      );
      expect(
        readerChapterFadeInEnabled(
          viewMode: 'continuous',
          effect: PageTurnAnimation.slide,
        ),
        isFalse,
      );
      expect(
        readerChapterFadeInEnabled(
          viewMode: 'vn',
          effect: PageTurnAnimation.fade,
        ),
        isFalse,
      );
      expect(
        readerChapterFadeInEnabled(
          viewMode: 'paginated',
          effect: PageTurnAnimation.none,
        ),
        isFalse,
      );
    });

    test('热更新 patch 带翻页动画三项', () {
      final String js = ReaderEngineConfig.liveUpdateInvocation(
        marginTop: 0,
        marginBottom: 0,
        marginLeft: 2,
        marginRight: 2,
        swipeDistThreshold: 24,
        swipeFastDistThreshold: 12,
        swipeFastVelocity: 300,
        wheelGestureQuietMs: 450,
        scanNonJapaneseText: false,
        pageTurnAnimation: 'cover',
        pageTurnDurationMs: 160,
        pageTurnFollowDrag: true,
        swipeLeftIsForward: false,
      );
      expect(js, contains('"pageTurnAnimation":"cover"'));
      expect(js, contains('"pageTurnDurationMs":160'));
      expect(js, contains('"pageTurnFollowDrag":true'));
      expect(js, contains('"swipeLeftIsForward":false'));
    });
  });

  testWidgets('设置项：存在于翻页与手势分组（点击翻页区域之前），非翻页模式置灰并说明', (
    WidgetTester tester,
  ) async {
    late SettingsContext settingsContext;
    late List<SettingsItem> items;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              settingsContext = SettingsContext(
                context: context,
                appModel: AppModel(testPlatformServices()),
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              items = buildSettingsSchema(settingsContext)
                  .expand((SettingsDestination d) => d.sections)
                  .where(
                    (SettingsSection s) =>
                        s.id == 'reading.section.page_turn_input',
                  )
                  .expand((SettingsSection s) => s.items)
                  .toList();
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    final List<String> ids = items.map((SettingsItem i) => i.id).toList();
    // 翻页动画三项连排；其后是点击翻页区域（indZkg2A0I，三种模式都生效，不置灰）。
    final int first = ids.indexOf('reading_controls.page_turn_animation');
    expect(first, greaterThanOrEqualTo(0));
    expect(ids.sublist(first), <String>[
      'reading_controls.page_turn_animation',
      'reading_controls.page_turn_animation_speed',
      'reading_controls.page_turn_follow_drag',
      'reading_controls.tap_zone_layout',
    ]);
    final SettingsSegmentedItem<Object> effect =
        items[first] as SettingsSegmentedItem<Object>;
    final SettingsSegmentedItem<Object> speed =
        items[first + 1] as SettingsSegmentedItem<Object>;
    final SettingsSwitchItem follow = items[first + 2] as SettingsSwitchItem;
    expect(effect.options.map((o) => o.value), PageTurnAnimation.values);
    expect(effect.defaultValue, PageTurnAnimation.fade);
    expect(speed.defaultValue, PageTurnAnimationSpeed.normal);
    expect(follow.defaultValue, isTrue);

    await readerSettings.setViewMode('paginated');
    expect(effect.isEnabled(settingsContext), isTrue);
    expect(speed.isEnabled(settingsContext), isTrue);
    expect(effect.resolveSubtitle(settingsContext), isNull);
    // 默认淡入淡出：跟手对无位移的效果没有意义 → 置灰。
    expect(follow.isEnabled(settingsContext), isFalse);
    await readerSettings.setPageTurnAnimation(PageTurnAnimation.slide);
    expect(follow.isEnabled(settingsContext), isTrue);

    for (final String mode in <String>['continuous', 'vn']) {
      await readerSettings.setViewMode(mode);
      for (final SettingsItem item in <SettingsItem>[effect, speed, follow]) {
        final bool enabled = item is SettingsSwitchItem
            ? item.isEnabled(settingsContext)
            : (item as SettingsSegmentedItem<Object>).isEnabled(
                settingsContext,
              );
        expect(enabled, isFalse, reason: '${item.id} 在 $mode 下应置灰');
        expect(
          item.resolveSubtitle(settingsContext),
          t.page_turn_animation_paginated_only,
        );
      }
    }

    // 渲染层：置灰的开关 onChanged 为空、分段全部禁用。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              SettingsSchemaItem(
                item: follow,
                settingsContext: settingsContext,
                showIcons: false,
                routeBuilder: (BuildContext _, WidgetBuilder b) =>
                    MaterialPageRoute<void>(builder: b),
              ),
              SettingsSchemaItem(
                item: effect,
                settingsContext: settingsContext,
                showIcons: false,
                routeBuilder: (BuildContext _, WidgetBuilder b) =>
                    MaterialPageRoute<void>(builder: b),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final Switch toggle = tester.widget<Switch>(find.byType(Switch).first);
    expect(toggle.onChanged, isNull);
    // 渲染器以 `SettingsSegmentedItem<Object>` 派发，分段条的类型参数是 Object。
    final Finder strips = find.byWidgetPredicate(
      (Widget w) => w is SegmentedButton,
    );
    expect(strips, findsWidgets);
    final SegmentedButton<Object> strip = tester
        .widget<SegmentedButton<Object>>(strips.first);
    expect(strip.segments, hasLength(PageTurnAnimation.values.length));
    expect(
      strip.segments.every((ButtonSegment<Object> s) => !s.enabled),
      isTrue,
    );
    expect(find.text(t.page_turn_animation_paginated_only), findsWidgets);
  });
}
