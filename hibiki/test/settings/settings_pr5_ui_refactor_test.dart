import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_hibiki_source.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_card_creation.dart';
import 'package:fushi/src/settings/settings_schema_widgets.dart';
import 'package:fushi/src/settings/settings_search.dart';

import '../helpers/test_platform_services.dart';

/// UI/UX 重构 PR-5 守卫：
/// 1. 宽屏设置默认选中分类取 schema 首个可见分类（不再硬编码某个 id）。
/// 2. 「制卡」分类经 bodySearchEntries 进入设置搜索并跳转正确 destination。
/// 3. 值控件行（Switch/Slider/Stepper/Segmented/内联 Picker）转发 showIcon，
///    schema 层 showIcons 真正生效（同卡片左栏图标对齐）。
void main() {
  group('默认选中分类 = schema 首项（源码守卫）', () {
    test('settings_home_page 不再硬编码 appearance 默认值', () {
      final String home = File('lib/src/settings/settings_home_page.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      // 默认项延迟到 build 里从可见分类列表解析，顺序真相源是 buildSettingsSchema
      // （settings_destination_order_guard_test 锁顺序）；这里锁「不再硬编码」。
      expect(home, contains('SettingsDestinationId? _selectedDestinationId'));
      expect(home, contains('destinations.first.id'));
      expect(
        home,
        isNot(contains('SettingsDestinationId.appearance')),
        reason: '宽屏默认选中分类不得再硬编码外观（重排后首项是阅读，未来跟随 schema）',
      );
      // body 合成搜索条目不登记 reveal 挂点（挂点永远不会被消费）。
      expect(home, contains('entry.isBodyEntry ? null : entry.item.id'));
    });
  });

  group('制卡分类搜索可见性', () {
    late SettingsContext sctx;

    Future<void> pumpContext(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) {
                sctx = SettingsContext(
                  context: context,
                  appModel: _TestAppModel(),
                  ref: ref,
                  readerSource: ReaderHibikiSource.instance,
                  refresh: () {},
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
    }

    testWidgets('bodySearchEntries 被展平进搜索索引且指向 cardCreation',
        (WidgetTester tester) async {
      await pumpContext(tester);
      final SettingsDestination dest = buildCardCreationDestination();
      final List<SettingsSearchEntry> entries =
          flattenVisibleSettings(<SettingsDestination>[dest], sctx);

      // sections 为空（body 逃生口），条目全部来自 bodySearchEntries。
      expect(entries, isNotEmpty,
          reason: '制卡分类必须有可搜条目（此前 sections 空 = 搜索完全不可见）');
      for (final SettingsSearchEntry entry in entries) {
        expect(entry.destination.id, SettingsDestinationId.cardCreation);
        expect(entry.isBodyEntry, isTrue);
        expect(entry.title, isNotEmpty);
      }
      final List<String> ids =
          entries.map((SettingsSearchEntry e) => e.item.id).toList();
      expect(ids, contains('card_creation.anki.deck'));
      expect(ids, contains('card_creation.anki.note_type'));
      expect(ids, contains('card_creation.anki.field_mappings'));
      expect(ids, contains('card_creation.anki.mining_audio_quality'));
    });

    testWidgets('按「牌组」行标题检索能命中并跳转制卡分类', (WidgetTester tester) async {
      await pumpContext(tester);
      final SettingsDestination dest = buildCardCreationDestination();
      final List<SettingsSearchEntry> entries =
          flattenVisibleSettings(<SettingsDestination>[dest], sctx);
      // 用与正文行同源的 i18n 文案检索（locale 无关）。
      final List<SettingsSearchEntry> hits =
          filterSettingsEntries(entries, t.anki_deck);
      expect(hits, isNotEmpty);
      expect(hits.first.destination.id, SettingsDestinationId.cardCreation);
      expect(hits.first.item.id, 'card_creation.anki.deck');
    });
  });

  group('值控件行 showIcon 转发（schema showIcons 生效）', () {
    Widget schemaHarness({required bool showIcons}) {
      final SettingsSection section = SettingsSection(
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'x.toggle',
            title: 'Toggle',
            icon: Icons.toggle_on_outlined,
            value: (_) => true,
            onChanged: (_, __) {},
          ),
          SettingsSliderItem(
            id: 'x.slider',
            title: 'Slider',
            icon: Icons.linear_scale_outlined,
            value: (_) => 0.5,
            divisions: 4,
            onChanged: (_, __) {},
          ),
          SettingsStepperItem(
            id: 'x.stepper',
            title: 'Stepper',
            icon: Icons.exposure_outlined,
            value: (_) => 1,
            step: 1,
            min: 0,
            max: 4,
            format: (double v) => v.toStringAsFixed(0),
            onChanged: (_, __) {},
          ),
          SettingsSegmentedItem<String>(
            id: 'x.segmented',
            title: 'Mode',
            icon: Icons.tune_outlined,
            options: const <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(value: 'a', label: 'A'),
              SettingsSegmentOption<String>(value: 'b', label: 'B'),
            ],
            selected: (_) => 'a',
            onChanged: (_, __) {},
          ),
          SettingsSegmentedItem<String>(
            id: 'x.dropdown',
            title: 'Pick',
            icon: Icons.list_outlined,
            dropdown: true,
            options: const <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(value: 'a', label: 'A'),
              SettingsSegmentOption<String>(value: 'b', label: 'B'),
            ],
            selected: (_) => 'a',
            onChanged: (_, __) {},
          ),
        ],
      );
      return ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              final SettingsContext sctx = SettingsContext(
                context: context,
                appModel: _TestAppModel(),
                ref: ref,
                readerSource: ReaderHibikiSource.instance,
                refresh: () {},
              );
              return Scaffold(
                body: ListView(
                  children: <Widget>[
                    for (final SettingsItem item in section.items)
                      SettingsSchemaItem(
                        item: item,
                        settingsContext: sctx,
                        showIcons: showIcons,
                        routeBuilder:
                            (BuildContext context, WidgetBuilder builder) =>
                                MaterialPageRoute<void>(builder: builder),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      );
    }

    testWidgets('showIcons=true 时各值控件行真正渲染图标', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(schemaHarness(showIcons: true));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.toggle_on_outlined), findsOneWidget,
          reason: 'Switch 行声明的 icon 必须渲染（此前 showIcon 未转发从不渲染）');
      expect(find.byIcon(Icons.linear_scale_outlined), findsOneWidget,
          reason: 'Slider 行图标');
      expect(find.byIcon(Icons.exposure_outlined), findsOneWidget,
          reason: 'Stepper 行图标');
      expect(find.byIcon(Icons.tune_outlined), findsOneWidget,
          reason: 'Segmented 行图标');
      expect(find.byIcon(Icons.list_outlined), findsOneWidget,
          reason: '内联 Picker（dropdown 分支）行图标');
    });

    testWidgets('showIcons=false 时不渲染（Cupertino 渲染器契约不变）',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(schemaHarness(showIcons: false));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.toggle_on_outlined), findsNothing);
      expect(find.byIcon(Icons.linear_scale_outlined), findsNothing);
      expect(find.byIcon(Icons.exposure_outlined), findsNothing);
      expect(find.byIcon(Icons.tune_outlined), findsNothing);
      expect(find.byIcon(Icons.list_outlined), findsNothing);
    });
  });
}

/// 轻量 AppModel：schema 构建/搜索展平只求值 visibility 谓词与本测试自带的
/// item 闭包，不触碰真实子系统。
class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());
}
