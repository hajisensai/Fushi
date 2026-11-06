import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_page_backdrop.dart';
import 'package:fushi/src/utils/adaptive/page_backdrop_style.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// 反馈 DYI1IOZxSM：「外观 › 页面背景」里的「按模块设置」入口与模块子页的选择器。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  tearDown(() {
    pageBackdropSettings.value = const PageBackdropSettings();
    pageBackdropModuleOverrides.value =
        const <HomeTab, PageBackdropModuleOverride>{};
  });

  List<SettingsItem> itemsOf(SettingsDestination destination) => <SettingsItem>[
    for (final SettingsSection section in destination.sections)
      ...section.items,
  ];

  test('全局页有「按模块设置」分组：每个主导航模块一行，各自推子页', () {
    final SettingsDestination destination = buildPageBackdropDestination();
    final SettingsSection section = destination.sections.singleWhere(
      (SettingsSection s) => s.id == 'appearance.page_backdrop.section.modules',
    );
    expect(section.title, t.page_backdrop_module_section);
    final List<String> ids = <String>[
      for (final SettingsItem item in section.items) item.id,
    ];
    expect(ids, <String>[
      for (final HomeTab tab in HomeTab.values)
        'appearance.page_backdrop.module.${pageBackdropModuleWire(tab)}',
    ]);
    for (final SettingsItem item in section.items) {
      expect((item as SettingsNavigationItem).child, isNotNull);
    }
  });

  test('模块子页的 item id 全局唯一（不和全局页、别的模块撞）', () {
    final Set<String> seen = <String>{
      for (final SettingsItem item in itemsOf(buildPageBackdropDestination()))
        item.id,
    };
    for (final HomeTab tab in HomeTab.values) {
      for (final SettingsItem item in itemsOf(
        buildPageBackdropModuleDestination(tab),
      )) {
        expect(seen.add(item.id), isTrue, reason: '${item.id} 重复');
      }
    }
  });

  Finder tile(String label, {required bool selected}) => find.byWidgetPredicate(
    (Widget w) =>
        w is Semantics &&
        w.properties.label == label &&
        w.properties.selected == selected,
  );

  Future<void> pumpModulePicker(WidgetTester tester, HomeTab tab) async {
    final AppModel model = AppModel(testPlatformServices());
    final SettingsCustomItem item =
        itemsOf(
              buildPageBackdropModuleDestination(tab),
            ).singleWhere((SettingsItem i) => i.id.endsWith('.preset'))
            as SettingsCustomItem;
    await tester.pumpWidget(
      ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (BuildContext context, WidgetRef ref, Widget? child) {
                  final SettingsContext settingsContext = SettingsContext(
                    context: context,
                    appModel: model,
                    ref: ref,
                    readerSource: ReaderFushiSource.instance,
                    refresh: () {},
                  );
                  return SingleChildScrollView(
                    child: item.builder(settingsContext),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('模块选择器：没单独设置时「跟随全局」选中，设了之后对应预设选中', (WidgetTester tester) async {
    await pumpModulePicker(tester, HomeTab.books);
    expect(tester.takeException(), isNull);
    expect(
      tile(t.page_backdrop_module_follow_global, selected: true),
      findsOneWidget,
    );
    expect(tile(t.page_backdrop_preset_mesh, selected: false), findsOneWidget);

    pageBackdropModuleOverrides.value =
        const <HomeTab, PageBackdropModuleOverride>{
          HomeTab.books: PageBackdropModuleOverride(
            preset: PageBackdropPreset.mesh,
          ),
        };
    await tester.pumpAndSettle();
    expect(
      tile(t.page_backdrop_module_follow_global, selected: false),
      findsOneWidget,
    );
    expect(tile(t.page_backdrop_preset_mesh, selected: true), findsOneWidget);
  });
}
