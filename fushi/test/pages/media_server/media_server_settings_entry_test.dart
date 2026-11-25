import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_server_list_view.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

/// BUG-5445：媒体服务器列表「去设置添加服务器」在「在线服务」模块关着时点了没
/// 反应——入口推的是整个在线服务分类，分类受模块门控，[SettingsDetailPage] 判
/// 不可见、当帧自 pop。用户拍板：媒体服务器入口在就一定进得去服务器设置，不管
/// 模块开没开；在线服务里其余条目仍随模块门控。
///
/// 模块开 / 关 × MD3 / Apple 各验：点击、Enter、空态按钮都停在媒体服务器管理页。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Future<AppModel> env(WidgetTester tester, {required bool services}) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await tester.runAsync(prefs.loadFromDb);
    await tester.runAsync(
      () => prefs.setModuleEnabled(ModuleId.services, services),
    );
    return AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
        prefsRepo: prefs,
        databaseDirectory: Directory.systemTemp,
      )
      ..wireDatabaseForTesting(db);
  }

  Widget host(AppModel app, {required bool apple, required Widget home}) {
    return ProviderScope(
      overrides: [appProvider.overrideWith((Ref ref) => app)],
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            extensions: <ThemeExtension<dynamic>>[
              FushiGlassTheme(FushiGlassMaterial.off, glassDesign: apple),
            ],
          ),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(body: home),
        ),
      ),
    );
  }

  /// 生产装配：入口回调就是 [openMediaServerSettings]（视频分区缺省、书 / 漫画
  /// 页签、导入页「连接服务器」块同一条）。
  Widget list({required bool empty}) => Builder(
    builder: (BuildContext context) {
      void open() => openMediaServerSettings(context);
      if (empty) return MediaServerListEmpty(top: 0, onOpenSettings: open);
      return MediaServerGroupedList(
        top: 0,
        onOpenSettings: open,
        rows: <MediaServerListRowData>[
          MediaServerListRowData(
            id: 'uhd',
            name: 'UHD',
            url: 'https://uhd.example.invalid',
            kindLabel: 'Emby',
            icon: Icons.dns,
            onTap: () {},
          ),
        ],
      );
    },
  );

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
    }
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  void useWideView(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.reset);
  }

  void expectMediaServersPageShown(WidgetTester tester) {
    final Finder page = find.byType(SettingsDetailPage);
    expect(page, findsOneWidget, reason: '媒体服务器设置页必须推上来并停住，不能当帧自 pop');
    expect(
      tester.widget<SettingsDetailPage>(page).subPageBuilder,
      equals(buildMediaServersDestination),
    );
    // 正文真的渲染出来了（媒体服务器一节里的一行）。
    expect(find.text(t.kavita_settings_title), findsOneWidget);
  }

  for (final bool apple in <bool>[false, true]) {
    for (final bool services in <bool>[true, false]) {
      final String label =
          '${apple ? 'Apple' : 'MD3'}：在线服务模块${services ? '开' : '关'}';

      testWidgets('$label：点「去设置添加服务器」行 → 停在媒体服务器设置', (
        WidgetTester tester,
      ) async {
        useWideView(tester);
        final AppModel app = await env(tester, services: services);
        await tester.pumpWidget(
          host(app, apple: apple, home: list(empty: false)),
        );
        await settle(tester);
        expect(
          find.byKey(const ValueKey<String>('media-server-list-add')),
          findsOneWidget,
          reason: '媒体服务器界面在，添加入口就在',
        );

        await tester.tap(
          find.byKey(const ValueKey<String>('media-server-list-add')),
        );
        await settle(tester);
        expectMediaServersPageShown(tester);
        await teardown(tester);
      });

      testWidgets('$label：焦点在添加行上按 Enter → 停在媒体服务器设置', (
        WidgetTester tester,
      ) async {
        useWideView(tester);
        final AppModel app = await env(tester, services: services);
        await tester.pumpWidget(
          host(app, apple: apple, home: list(empty: false)),
        );
        await settle(tester);

        // 行内文字向上最近的 Focus = 行的点按目标（Apple FocusableActionDetector /
        // MD3 InkWell）的焦点节点。
        final Finder label = find.descendant(
          of: find.byKey(const ValueKey<String>('media-server-list-add')),
          matching: find.text(t.media_server_servers_go_settings),
        );
        Focus.of(tester.element(label)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester);
        expectMediaServersPageShown(tester);
        await teardown(tester);
      });

      testWidgets('$label：空态按钮 → 停在媒体服务器设置', (WidgetTester tester) async {
        useWideView(tester);
        final AppModel app = await env(tester, services: services);
        await tester.pumpWidget(
          host(app, apple: apple, home: list(empty: true)),
        );
        await settle(tester);

        await tester.tap(
          find.byKey(const ValueKey<String>('media-server-list-go-settings')),
        );
        await settle(tester);
        expectMediaServersPageShown(tester);
        await teardown(tester);
      });
    }
  }

  test('媒体服务器独立页只有「媒体服务器」一节、不挂模块门；在线服务分类仍嵌同一节', () {
    final List<String?> standalone = buildMediaServersDestination().sections
        .map((SettingsSection s) => s.id)
        .toList();
    expect(standalone, <String?>['services.media']);
    expect(buildMediaServersDestination().visible, isNull);
    final List<String?> category = buildServicesDestination().sections
        .map((SettingsSection s) => s.id)
        .toList();
    expect(category, contains('services.media'));
    expect(category.length, greaterThan(1));
  });

  testWidgets('模块关着：媒体服务器以外的在线服务条目仍受门控（整个分类推上去当帧自 pop）', (
    WidgetTester tester,
  ) async {
    useWideView(tester);
    final AppModel app = await env(tester, services: false);
    await tester.pumpWidget(
      host(
        app,
        apple: true,
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) =>
                    SettingsDetailPage(destination: buildServicesDestination()),
              ),
            ),
            child: const Text('open-services-category'),
          ),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('open-services-category'));
    await settle(tester);
    expect(find.byType(SettingsDetailPage), findsNothing);
    expect(find.text('open-services-category'), findsOneWidget);
    await teardown(tester);
  });
}
