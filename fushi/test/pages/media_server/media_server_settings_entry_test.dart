import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_server_list_view.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_platform_services.dart';

/// BUG-5359：媒体服务器列表「去设置添加服务器」在「在线服务」模块关着时点了没
/// 反应——服务设置页判分类不可见、推上来当帧就自己 pop。入口须跟模块门走：
/// 开着时点击 / Enter 真的停在 设置 › 在线服务；关着时入口整条不渲染。
/// MD3 与 Apple 两套设计系统各验一遍（判据与设计系统无关）。
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

  /// 生产装配：入口动作一律经 [mediaServerSettingsAction] 取。
  Widget list({required bool empty}) => Consumer(
    builder: (BuildContext context, WidgetRef ref, Widget? _) {
      final VoidCallback? open = mediaServerSettingsAction(context, ref);
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

  void expectServicesPageShown(WidgetTester tester) {
    final Finder page = find.byType(SettingsDetailPage);
    expect(page, findsOneWidget, reason: '服务设置页必须推上来并停住，不能当帧自 pop');
    expect(
      tester.widget<SettingsDetailPage>(page).destination?.id,
      SettingsDestinationId.services,
    );
  }

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    group('$ds：在线服务模块开着', () {
      testWidgets('点「去设置添加服务器」行 → 停在 设置 › 在线服务', (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1400, 1000);
        addTearDown(tester.view.reset);
        final AppModel app = await env(tester, services: true);
        await tester.pumpWidget(
          host(app, apple: apple, home: list(empty: false)),
        );
        await settle(tester);

        await tester.tap(
          find.byKey(const ValueKey<String>('media-server-list-add')),
        );
        await settle(tester);
        expectServicesPageShown(tester);
        await teardown(tester);
      });

      testWidgets('焦点在添加行上按 Enter → 同样停在 设置 › 在线服务', (
        WidgetTester tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1400, 1000);
        addTearDown(tester.view.reset);
        final AppModel app = await env(tester, services: true);
        await tester.pumpWidget(
          host(app, apple: apple, home: list(empty: false)),
        );
        await settle(tester);

        final Finder row = find.byKey(
          const ValueKey<String>('media-server-list-add'),
        );
        // 行内文字向上最近的 Focus = 行的点按目标（Apple FocusableActionDetector /
        // MD3 InkWell）的焦点节点。
        final Finder label = find.descendant(
          of: row,
          matching: find.text(t.media_server_servers_go_settings),
        );
        Focus.of(tester.element(label)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester);
        expectServicesPageShown(tester);
        await teardown(tester);
      });

      testWidgets('空态按钮 → 停在 设置 › 在线服务', (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1400, 1000);
        addTearDown(tester.view.reset);
        final AppModel app = await env(tester, services: true);
        await tester.pumpWidget(
          host(app, apple: apple, home: list(empty: true)),
        );
        await settle(tester);

        await tester.tap(
          find.byKey(const ValueKey<String>('media-server-list-go-settings')),
        );
        await settle(tester);
        expectServicesPageShown(tester);
        await teardown(tester);
      });
    });

    testWidgets('$ds：在线服务模块关着 → 添加行与空态按钮都不渲染（去不了就不给死路）', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 1000);
      addTearDown(tester.view.reset);
      final AppModel app = await env(tester, services: false);

      await tester.pumpWidget(
        host(app, apple: apple, home: list(empty: false)),
      );
      await settle(tester);
      expect(
        find.byKey(const ValueKey<String>('media-server-card-uhd')),
        findsOneWidget,
        reason: '已登录的服务器照常列出',
      );
      expect(
        find.byKey(const ValueKey<String>('media-server-list-add')),
        findsNothing,
      );

      await tester.pumpWidget(host(app, apple: apple, home: list(empty: true)));
      await settle(tester);
      expect(find.text(t.media_server_servers_empty_hint), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('media-server-list-go-settings')),
        findsNothing,
      );
      await teardown(tester);
    });
  }

  testWidgets('病根复现：模块关着时直接推服务设置页，当帧自 pop、什么也看不到', (WidgetTester tester) async {
    final AppModel app = await env(tester, services: false);
    await tester.pumpWidget(
      host(
        app,
        apple: true,
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => openMediaServerSettings(context),
            child: const Text('raw-open'),
          ),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('raw-open'));
    await settle(tester);
    expect(find.byType(SettingsDetailPage), findsNothing);
    expect(find.text('raw-open'), findsOneWidget);
    await teardown(tester);
  });
}
