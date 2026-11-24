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
    pageBackdropPageOverrides.value =
        const <PageBackdropPage, PageBackdropModuleOverride>{};
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

  test('拍板台 xxbbL0j15l：复习模块子页多一组「按页面设置」，答题页推自己的子页', () {
    final SettingsDestination srs = buildPageBackdropModuleDestination(
      HomeTab.srs,
    );
    final SettingsSection pages = srs.sections.singleWhere(
      (SettingsSection s) =>
          s.id == 'appearance.page_backdrop.module.srs.section.pages',
    );
    expect(pages.title, t.page_backdrop_page_section);
    final SettingsNavigationItem entry =
        pages.items.single as SettingsNavigationItem;
    expect(entry.id, 'appearance.page_backdrop.page.srs_review');
    expect(entry.title, t.page_backdrop_page_srs_review);
    expect(entry.child, isNotNull);

    // 没有单独页面的模块不出这一组。
    expect(
      buildPageBackdropModuleDestination(
        HomeTab.books,
      ).sections.map((SettingsSection s) => s.id),
      isNot(contains(endsWith('.section.pages'))),
    );

    // 页面子页的 id 不和全局页、任何模块子页撞。
    final Set<String> seen = <String>{
      for (final SettingsItem item in itemsOf(buildPageBackdropDestination()))
        item.id,
      for (final HomeTab tab in HomeTab.values)
        for (final SettingsItem item in itemsOf(
          buildPageBackdropModuleDestination(tab),
        ))
          item.id,
    };
    for (final PageBackdropPage page in PageBackdropPage.values) {
      for (final SettingsItem item in itemsOf(
        buildPageBackdropPageDestination(page),
      )) {
        expect(seen.add(item.id), isTrue, reason: '${item.id} 重复');
      }
    }
  });

  Future<void> pumpPicker(
    WidgetTester tester,
    SettingsDestination destination,
  ) async {
    final AppModel model = AppModel(testPlatformServices());
    final SettingsCustomItem item =
        itemsOf(
              destination,
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

  Future<void> pumpModulePicker(WidgetTester tester, HomeTab tab) =>
      pumpPicker(tester, buildPageBackdropModuleDestination(tab));

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

  testWidgets('答题页选择器：没单独设时「跟随模块」选中，设成纯色后纯色选中', (WidgetTester tester) async {
    await pumpPicker(
      tester,
      buildPageBackdropPageDestination(PageBackdropPage.srsReview),
    );
    expect(tester.takeException(), isNull);
    expect(
      tile(t.page_backdrop_page_follow_module, selected: true),
      findsOneWidget,
    );
    expect(
      tile(t.page_backdrop_module_follow_global, selected: false),
      findsNothing,
    );

    pageBackdropPageOverrides.value =
        const <PageBackdropPage, PageBackdropModuleOverride>{
          PageBackdropPage.srsReview: PageBackdropModuleOverride(
            preset: PageBackdropPreset.plain,
          ),
        };
    await tester.pumpAndSettle();
    expect(
      tile(t.page_backdrop_page_follow_module, selected: false),
      findsOneWidget,
    );
    expect(tile(t.page_backdrop_preset_plain, selected: true), findsOneWidget);
  });
}
