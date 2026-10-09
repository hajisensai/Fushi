import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_uninstall.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extensions_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_installed_sources_section.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 来源页 / 扩展页的扩展管理（2026-10-09 用户需求 + BUG-3099）：
///
/// 1. 来源页条目「⋯」菜单有「卸载扩展」，二次确认；扩展含多个源时确认框逐条列出
///    会一起移除的源，确认后真卸载（运行时 + DB）。
/// 2. 来源页副标题：源名与扩展名不同时显示扩展名，不再显示截断的包名。
/// 3. 扩展页「有更新」状态也有卸载按钮（BUG-3099）。
///
/// 视频（Aniyomi，`MihonMediaKind.anime`）与漫画（`manga`）是同一组件、同一份
/// manager 实现按 media_kind 分片，两种 kind 各跑一遍；浏览模块与库页子标签复用
/// 同一组件的接线由 `test/pages/import_page_unification_guard_test.dart` 守。
void main() {
  for (final MihonMediaKind kind in MihonMediaKind.values) {
    group('kind=${kind.name}', () {
      late Directory root;
      late FushiDatabase database;
      late _RecordingRuntime runtime;
      late MihonManager manager;

      const String multiPackage = 'eu.kanade.example.animeblkom';
      const String singlePackage = 'eu.kanade.example.anikoto';

      setUp(() async {
        LocaleSettings.setLocale(AppLocale.en);
        root = await Directory.systemTemp.createTemp('hibiki-src-ext-manage-');
        database = FushiDatabase.forTesting(NativeDatabase.memory());
        runtime = _RecordingRuntime();
        await database.upsertMangaExtensionStore(
          MangaExtensionStoresCompanion.insert(
            indexUrl: 'https://repo.example/index.json',
            name: 'Fixture repository',
            format: MihonStoreFormat.currentJson.name,
            signingKey: const Value<String?>('aabb'),
            mediaKind: Value<String>(kind.dbValue),
          ),
        );
        manager = MihonManager(
          database: database,
          rootDirectory: root,
          runtime: runtime,
          kind: kind,
        );
        await _installExtension(
          database,
          kind: kind,
          packageName: multiPackage,
          name: 'Anime Blkom',
          versionCode: 1,
          sources: const <(String, String, String)>[
            ('1', 'أنمي بالكوم', 'ar'),
            ('2', 'Anime Blkom', 'en'),
          ],
        );
        await _installExtension(
          database,
          kind: kind,
          packageName: singlePackage,
          name: 'Anikoto',
          versionCode: 1,
          sources: const <(String, String, String)>[('9', 'Anikoto', 'en')],
        );
        await manager.reload();
      });

      tearDown(() async {
        manager.dispose();
        await database.close();
        if (await root.exists()) await root.delete(recursive: true);
      });

      Future<void> pumpSlivers(
        WidgetTester tester,
        List<Widget> slivers,
      ) async {
        await tester.binding.setSurfaceSize(const Size(1400, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: ThemeData.light(useMaterial3: true),
              home: Scaffold(body: CustomScrollView(slivers: slivers)),
            ),
          ),
        );
        await tester.pump();
      }

      /// 卸载路径里有真实文件 IO（桌面 sidecar 删 APK）与 DB 事务，FakeAsync 区里
      /// 不会完成：在 runAsync 里有界轮询到 manager 回到空闲。
      Future<void> settleUninstall(WidgetTester tester) async {
        await tester.pump();
        await tester.runAsync(() async {
          final Stopwatch clock = Stopwatch()..start();
          while (manager.loading &&
              clock.elapsed < const Duration(seconds: 10)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });
        await tester.pumpAndSettle();
      }

      testWidgets('副标题：源名与扩展名不同才显示扩展名，包名不再出现在行里', (WidgetTester tester) async {
        await pumpSlivers(tester, <Widget>[
          MihonInstalledSourcesSection(manager: manager),
        ]);
        final Finder arabicRow = find.byKey(
          const ValueKey<String>('mihon_source_row_${multiPackage}_1'),
        );
        expect(
          find.descendant(of: arabicRow, matching: find.text('Anime Blkom')),
          findsOneWidget,
          reason: '源名「أنمي بالكوم」与扩展名不同：副标题必须写出扩展名',
        );
        final Finder sameNameRow = find.byKey(
          const ValueKey<String>('mihon_source_row_${singlePackage}_9'),
        );
        expect(
          find.descendant(of: sameNameRow, matching: find.text('Anikoto')),
          findsOneWidget,
          reason: '名字相同：只剩标题那一处，不重复写扩展名',
        );
        expect(
          find.textContaining('eu.kanade'),
          findsNothing,
          reason: '截断的包名没有信息量，不再当副标题',
        );
        // 搜索也认扩展名：按扩展名搜得到阿拉伯语名的源。
        await tester.enterText(
          find.byKey(const ValueKey<String>('mihon_sources_search_field')),
          'blkom',
        );
        await tester.pump();
        expect(find.text('أنمي بالكوم'), findsOneWidget);
        expect(find.text('Anikoto'), findsNothing);
        expect(tester.takeException(), null);
      });

      testWidgets('菜单「卸载扩展」：多源确认框列出全部源，取消不动、确认真卸载', (
        WidgetTester tester,
      ) async {
        await pumpSlivers(tester, <Widget>[
          MihonInstalledSourcesSection(manager: manager),
        ]);
        Future<void> openUninstall() async {
          await tester.tap(
            find.byKey(
              const ValueKey<String>('mihon_source_menu_${multiPackage}_1'),
            ),
          );
          await tester.pumpAndSettle();
          final Finder item = find.byKey(
            const ValueKey<String>('mihon_source_uninstall_${multiPackage}_1'),
          );
          expect(item, findsOneWidget);
          expect(
            find.descendant(
              of: item,
              matching: find.text(t.mihon_source_uninstall_extension),
            ),
            findsOneWidget,
          );
          await tester.tap(item);
          await tester.pumpAndSettle();
        }

        await openUninstall();
        // 确认框：多源说明 + 两个源逐条列出 + 包名。
        expect(
          find.text(
            t.mihon_extension_uninstall_confirm_multi(
              name: 'Anime Blkom',
              count: 2,
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const ValueKey<String>('mihon_uninstall_source_${multiPackage}_1'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const ValueKey<String>('mihon_uninstall_source_${multiPackage}_2'),
          ),
          findsOneWidget,
        );
        expect(
          find.text(t.mihon_extension_package_label(package: multiPackage)),
          findsOneWidget,
        );

        // 取消：什么都不发生。
        await tester.tap(find.text(t.dialog_cancel));
        await tester.pumpAndSettle();
        expect(runtime.uninstalled, isEmpty);
        expect(
          await database.getMangaOnlineSources(mediaKind: kind.dbValue),
          hasLength(3),
        );

        // 确认：运行时卸载 + 两个源一起从 DB 与列表里消失，另一个扩展不受影响。
        await openUninstall();
        await tester.tap(find.text(t.mihon_extension_uninstall));
        await settleUninstall(tester);
        expect(runtime.uninstalled, <String>[multiPackage]);
        final List<MangaOnlineSourceRow> left = await database
            .getMangaOnlineSources(mediaKind: kind.dbValue);
        expect(
          left.map((MangaOnlineSourceRow row) => row.extensionPackage),
          <String>[singlePackage],
        );
        expect(find.text('أنمي بالكوم'), findsNothing);
        expect(find.text('Anikoto'), findsOneWidget);
        expect(tester.takeException(), null);
      });

      testWidgets('单源扩展的确认框用单源文案、不列清单', (WidgetTester tester) async {
        await pumpSlivers(tester, <Widget>[
          MihonInstalledSourcesSection(manager: manager),
        ]);
        await tester.tap(
          find.byKey(
            const ValueKey<String>('mihon_source_menu_${singlePackage}_9'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(
            const ValueKey<String>('mihon_source_uninstall_${singlePackage}_9'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            t.mihon_extension_uninstall_confirm_single(name: 'Anikoto'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const ValueKey<String>('mihon_uninstall_source_${singlePackage}_9'),
          ),
          findsNothing,
        );
        expect(tester.takeException(), null);
      });

      testWidgets('BUG-3099：扩展页「有更新」状态同时给「更新」与「卸载」，卸载真生效', (
        WidgetTester tester,
      ) async {
        // 只留「有更新」的那一个：本地专有段的已装扩展也有「卸载」按钮，会混淆计数。
        await database.deleteMangaExtension(singlePackage);
        await manager.reload();
        manager.available = <MihonAvailableExtension>[
          _available(
            name: 'Anime Blkom',
            packageName: multiPackage,
            versionCode: 2,
          ),
        ];
        await pumpSlivers(tester, <Widget>[
          MihonExtensionsPage(
            manager: manager,
            embedded: true,
            sections: const <MihonExtensionsSection>[
              MihonExtensionsSection.catalog,
            ],
          ),
        ]);
        expect(find.text(t.mihon_extension_update), findsOneWidget);
        final Finder uninstall = find.text(t.mihon_extension_uninstall);
        expect(uninstall, findsOneWidget, reason: '有更新时主按钮是「更新」，卸载必须仍然可达');
        await tester.tap(uninstall);
        await tester.pumpAndSettle();
        expect(
          find.text(
            t.mihon_extension_uninstall_confirm_multi(
              name: 'Anime Blkom',
              count: 2,
            ),
          ),
          findsOneWidget,
        );
        await tester.tap(find.text(t.mihon_extension_uninstall).last);
        await settleUninstall(tester);
        expect(runtime.uninstalled, <String>[multiPackage]);
        expect(
          (await database.getMangaExtensions(
            mediaKind: kind.dbValue,
          )).map((MangaExtensionRow row) => row.packageName),
          isEmpty,
        );
        expect(tester.takeException(), null);
      });
    });
  }

  test('mihonSourceExtensionLabel：同名（忽略大小写 / 空白）或缺失时为 null', () {
    expect(
      mihonSourceExtensionLabel(
        sourceName: 'أنمي بالكوم',
        extensionName: 'Anime Blkom',
      ),
      'Anime Blkom',
    );
    expect(
      mihonSourceExtensionLabel(
        sourceName: 'anikoto ',
        extensionName: 'Anikoto',
      ),
      isNull,
    );
    expect(
      mihonSourceExtensionLabel(sourceName: 'X', extensionName: null),
      isNull,
    );
    expect(
      mihonSourceExtensionLabel(sourceName: 'X', extensionName: '  '),
      isNull,
    );
  });
}

Future<void> _installExtension(
  FushiDatabase database, {
  required MihonMediaKind kind,
  required String packageName,
  required String name,
  required int versionCode,
  required List<(String, String, String)> sources,
}) async {
  await database.upsertMangaExtension(
    MangaExtensionsCompanion.insert(
      packageName: packageName,
      name: name,
      versionCode: versionCode,
      versionName: '14.$versionCode',
      libVersion: '14',
      language: 'all',
      apkPath: '$packageName.apk',
      apkSha256: 'aa',
      signerSha256: 'bb',
      installedAt: 1,
      mediaKind: Value<String>(kind.dbValue),
    ),
  );
  await database
      .replaceMangaOnlineSources(packageName, <MangaOnlineSourcesCompanion>[
        for (final (int index, (String, String, String) source)
            in sources.indexed)
          MangaOnlineSourcesCompanion.insert(
            extensionPackage: packageName,
            sourceId: source.$1,
            name: source.$2,
            language: source.$3,
            sortOrder: Value<int>(index),
            mediaKind: Value<String>(kind.dbValue),
          ),
      ]);
}

MihonAvailableExtension _available({
  required String name,
  required String packageName,
  required int versionCode,
}) => MihonAvailableExtension(
  storeUrl: 'https://repo.example/index.json',
  name: name,
  packageName: packageName,
  apkUrl: 'https://repo.example/$packageName.apk',
  iconUrl: '',
  libVersion: '14',
  extensionVersionCode: versionCode,
  versionName: '14.$versionCode',
  language: 'all',
  contentWarning: 0,
  sources: const <MihonAvailableSource>[],
);

class _RecordingRuntime extends Fake implements MihonRuntime {
  final List<String> uninstalled = <String>[];

  @override
  Future<void> uninstallPrivateExtension(String packageName) async {
    uninstalled.add(packageName);
  }

  @override
  Future<void> invalidateExtension(String packageName) async {}

  @override
  Future<void> dispose() async {}
}
