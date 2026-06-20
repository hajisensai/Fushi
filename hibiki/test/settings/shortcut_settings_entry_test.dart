import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/models/theme_notifier.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

/// TODO-180：快捷键是全局输入配置，不属于阅读设置；入口必须位于「系统」
/// destination，并且不能再出现在书内 reading controls / ReaderGroup.behavior。
///
/// 用真 schema（prefs-backed AppModel + 内存 DB）断言入口仍可见并标记实验性，
/// 但归属改为 System destination。
///
/// 撤销修改即转红。
void main() {
  const String kShortcutItemId = 'system.keyboard_shortcuts';

  SettingsItem? findById(
    List<SettingsDestination> destinations,
    String id,
  ) {
    for (final SettingsDestination dest in destinations) {
      for (final SettingsSection section in dest.sections) {
        for (final SettingsItem item in section.items) {
          if (item.id == id) return item;
        }
      }
    }
    return null;
  }

  testWidgets('shortcut settings entry is visible in system settings only',
      (WidgetTester tester) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final ReaderSettings? prevReaderSettings =
        ReaderHibikiSource.readerSettings;
    final ReaderSettings readerSettings = ReaderSettings(db);
    await readerSettings.refreshFromDb();
    ReaderHibikiSource.readerSettings = readerSettings;
    addTearDown(() => ReaderHibikiSource.readerSettings = prevReaderSettings);

    final ThemeNotifier themeNotifier =
        ThemeNotifier(db, () => const TextTheme())
          ..loadFromPrefsSnapshot(<String, String>{
            'design_system': PrefCodec.encode('material'),
            'app_theme_key': PrefCodec.encode('system-theme'),
            'brightness_mode': PrefCodec.encode('system'),
            'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
          });
    addTearDown(themeNotifier.dispose);

    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_shortcut_entry_');
    addTearDown(() {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final AppModel appModel = AppModel(testPlatformServices())
      ..themeNotifier = themeNotifier
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo, databaseDirectory: tmpDir)
      ..populateLanguages()
      ..populateLocales();

    List<SettingsDestination> destinations = const <SettingsDestination>[];
    Map<ReaderGroup, List<SettingsItem>> readerItems =
        const <ReaderGroup, List<SettingsItem>>{};

    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Consumer(
          builder: (BuildContext ctx, WidgetRef ref, _) {
            final SettingsContext sctx = SettingsContext(
              context: ctx,
              appModel: ref.read(appProvider),
              ref: ref,
              readerSource: ReaderHibikiSource.instance,
              refresh: () {},
            );
            destinations = buildSettingsSchema(sctx);
            readerItems = collectReaderItems(sctx);
            return const SizedBox.shrink();
          },
        ),
      ),
    ));
    await tester.pump();

    // 1) 入口可见：出现在 schema 里（不再被注释隐藏）。
    final SettingsItem? item = findById(destinations, kShortcutItemId);
    expect(item, isNotNull, reason: '快捷键设置入口应在 settings schema 中可见（已从隐藏恢复）');
    expect(item, isA<SettingsNavigationItem>());
    expect(item!.title, t.shortcut_settings_title);

    // 2) 实验性标记：subtitle 用 settings_experimental_suffix（同既有范式）。
    expect(item.subtitle, t.settings_experimental_suffix,
        reason: '入口须标记为实验性（subtitle == settings_experimental_suffix）');

    // 3) 不再加进书籍（阅读器）设置：快捷键是系统/全局输入配置。
    expect(item.reader, isNull, reason: '快捷键入口不应再出现在书内阅读设置');

    final List<SettingsItem> behaviorItems =
        readerItems[ReaderGroup.behavior] ?? const <SettingsItem>[];
    expect(
      behaviorItems.any((SettingsItem i) => i.id == kShortcutItemId),
      isFalse,
      reason: 'collectReaderItems 的 behavior 组不应含快捷键入口',
    );

    // 它落在 system destination（全局「系统」设置）下。
    final SettingsDestination system = destinations.firstWhere(
      (SettingsDestination d) => d.id == SettingsDestinationId.system,
    );
    final bool inSystem = system.sections.any(
      (SettingsSection s) =>
          s.items.any((SettingsItem i) => i.id == kShortcutItemId),
    );
    expect(inSystem, isTrue, reason: '快捷键入口应位于「系统」设置分组下');

    final SettingsDestination reading = destinations.firstWhere(
      (SettingsDestination d) => d.id == SettingsDestinationId.reading,
    );
    final bool inReading = reading.sections.any(
      (SettingsSection s) =>
          s.items.any((SettingsItem i) => i.title == t.shortcut_settings_title),
    );
    expect(inReading, isFalse, reason: '快捷键入口不应继续位于「阅读」设置分组下');
  });

  test('shortcut settings entry is no longer commented out in schema source',
      () {
    final String source = File('lib/src/settings/settings_schema_system.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    // 入口的 onTap 推 ShortcutSettingsPage，且推它的那行不能是注释行
    // （旧隐藏态是整块 `// SettingsNavigationItem(...)` 注释）。
    expect(source, contains('const ShortcutSettingsPage()'),
        reason: '入口应推 ShortcutSettingsPage');
    final List<String> activePageLines = source
        .split('\n')
        .where((String line) => line.contains('ShortcutSettingsPage'))
        .where((String line) => !line.trimLeft().startsWith('//'))
        .toList();
    expect(activePageLines, isNotEmpty,
        reason: '推 ShortcutSettingsPage 的那行必须是未注释的真实代码');
    expect(source, isNot(contains('快捷键设置入口暂时隐藏')), reason: '旧的「暂时隐藏」注释应已移除');
  });
}
