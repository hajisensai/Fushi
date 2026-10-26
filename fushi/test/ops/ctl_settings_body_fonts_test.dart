import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/font_preview/system_font_catalog.dart';
import 'package:fushi/src/ops/ctl_settings_body_fonts.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/reader/custom_font_library.dart';
import 'package:fushi/src/reader/font_catalog.dart';
import 'package:fushi/src/reader/font_download_service.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/settings/settings_cli_tasks.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/media_pref_keys.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// 字体库控制通道条目：导入 / 系统字体 / 用途 / 排序 / 删除真写穿目录偏好，
/// 删除连带清理不再被引用的字体文件。
void main() {
  late FushiDatabase db;
  late AppModel appModel;
  late SettingsContext sc;
  late Directory tempDir;
  late Directory fontsDir;

  List<SettingsItem> items() =>
      buildCtlFontsBodyPages().expand((CtlBodyPage p) => p.items).toList();

  T itemOf<T extends SettingsItem>(String id) =>
      items().singleWhere((SettingsItem i) => i.id == id) as T;

  SettingsCliList fonts() =>
      itemOf<SettingsCustomItem>('${kCtlFontsIdPrefix}fonts').cliList!;

  String pref(String key) => dbSourcePrefKey(kReaderSourcePersistedKey, key);

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    tempDir = Directory.systemTemp.createTempSync('fushi_fonts_cli_');
    fontsDir = Directory('${tempDir.path}${Platform.pathSeparator}fonts');
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tempDir)
      ..wireDatabaseForTesting(db);
    ReaderFushiSource.readerSettings = null;
    SystemFontCatalog.debugReset();
    SystemFontCatalog.debugLoaderOverride = () async => const SystemFontList(
      families: <SystemFontFamily>[
        SystemFontFamily(family: 'Yu Gothic', supportsJapanese: true),
        SystemFontFamily(family: 'Arial', supportsJapanese: false),
      ],
      namesReliable: true,
    );
    ctlFontLibraryFactory = (AppModel _) => CustomFontLibrary(
      database: db,
      fontsDir: fontsDir,
      // 裸 Dio：下载用例只连本机回环服务，不经应用代理装配。
      service: FontDownloadService(fontsDir: fontsDir, dioFactory: Dio.new),
      // 生产 persist 额外刷新 app 字体 / galgame 浮窗；这里只验目录写穿。
      persist:
          (
            ReaderSettings settings,
            FontCatalogState state,
            Map<String, List<Map<String, dynamic>>> legacy,
          ) async {
            await db.setPref(
              pref(ReaderSettings.fontCatalogKey),
              jsonEncode(state.toCatalogJson()),
            );
            await db.setPref(
              pref(ReaderSettings.fontTargetsKey),
              jsonEncode(state.toTargetsJson()),
            );
            for (final MapEntry<String, List<Map<String, dynamic>>> e
                in legacy.entries) {
              await db.setPref(pref(e.key), jsonEncode(e.value));
            }
            await settings.refreshFromDb();
          },
    );
  });

  tearDown(() async {
    ctlFontLibraryFactory = CustomFontLibrary.forApp;
    ReaderFushiSource.readerSettings = null;
    SystemFontCatalog.debugReset();
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> pumpContext(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              sc = SettingsContext(
                context: context,
                appModel: appModel,
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }

  File fakeFont(String name) {
    final File f = File('${tempDir.path}${Platform.pathSeparator}$name');
    // TrueType 魔数 + 填充：按扩展名直接落库（与页面导入同一条路径）。
    f.writeAsBytesSync(<int>[
      0x00,
      0x01,
      0x00,
      0x00,
      ...List<int>.filled(64, 0),
    ]);
    return f;
  }

  testWidgets('import file / system font, set targets, move, remove', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    await tester.runAsync(() async {
      final SettingsCliList cli = fonts();
      expect(await cli.list(sc), isEmpty);

      final File src = fakeFont('MyFont.ttf');
      final Map<String, Object?> imported =
          (await cli.add!(sc, <String, String>{
                'path': src.path,
                'name': 'My Font',
                'targets': 'body,dictionary',
              }))!
              as Map<String, Object?>;
      expect(imported['name'], 'My Font');
      expect(imported['kind'], 'file');
      expect(imported['targets'], <String>['body', 'dictionary']);
      final String fileId = imported['id']! as String;
      final String copied = imported['path']! as String;
      expect(File(copied).existsSync(), isTrue);
      expect(copied, startsWith(fontsDir.path));

      final Map<String, Object?> sys =
          (await cli.add!(sc, <String, String>{'system': 'yu gothic'}))!
              as Map<String, Object?>;
      expect(sys['name'], 'Yu Gothic', reason: '按系统清单规范大小写');
      expect(sys['targets'], <String>['body'], reason: '新增省略 targets = body');
      final String sysId = sys['id']! as String;

      // 写穿：目录偏好与 body 旧列表都在 DB 里。
      final String? catalog = await db.getPref(
        pref(ReaderSettings.fontCatalogKey),
      );
      expect(catalog, contains('My Font'));
      expect(catalog, contains('Yu Gothic'));

      // 用途链（config get/set）。
      final SettingsCliValue body = itemOf<SettingsCustomItem>(
        '${kCtlFontsIdPrefix}target.body',
      ).cliValue!;
      expect(body.read(sc), 'My Font,Yu Gothic');
      await body.write(sc, 'Yu Gothic');
      expect(body.read(sc), 'Yu Gothic');
      await body.write(sc, '$fileId,Yu Gothic');
      expect(body.read(sc), 'My Font,Yu Gothic');

      // 排序 = 字体链顺序。
      final Map<String, Object?> moved =
          (await cli.update!(sc, sysId, <String, String>{'position': '0'}))!
              as Map<String, Object?>;
      expect(moved['id'], sysId);
      expect(body.read(sc), 'Yu Gothic,My Font');

      // 改用途（整体替换）。
      await cli.update!(sc, fileId, <String, String>{'targets': 'appUi'});
      expect(body.read(sc), 'Yu Gothic');
      final SettingsCliValue appUi = itemOf<SettingsCustomItem>(
        '${kCtlFontsIdPrefix}target.appUi',
      ).cliValue!;
      expect(appUi.read(sc), 'My Font');

      // 删除文件字体：文件跟着删。
      await cli.remove!(sc, fileId);
      expect(File(copied).existsSync(), isFalse);
      final List<Map<String, Object?>> left = await cli.list(sc);
      expect(left.map((Map<String, Object?> r) => r['id']), <Object?>[sysId]);
    });
  });

  testWidgets('url download runs as a background task: progress → done', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsCliTaskRegistry registry = SettingsCliTaskRegistry();
    ctlFontTaskRegistry = registry;
    addTearDown(() => ctlFontTaskRegistry = SettingsCliTaskRegistry.instance);
    _useRealHttpClient();
    await tester.runAsync(() async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      server.listen((HttpRequest request) async {
        final List<int> bytes = <int>[
          0x00,
          0x01,
          0x00,
          0x00,
          ...List<int>.filled(64, 0),
        ];
        request.response
          ..contentLength = bytes.length
          ..add(bytes);
        await request.response.close();
      });
      try {
        final Object? started =
            await itemOf<SettingsActionItem>(
              '${kCtlFontsIdPrefix}download',
            ).cli!.run!(sc, <String, String>{
              'url': 'http://127.0.0.1:${server.port}/Net.ttf',
              'name': 'NetFont',
            });
        final Map<String, Object?> json = started! as Map<String, Object?>;
        expect(json['kind'], kCtlFontDownloadTaskKind);
        expect(json['status'], 'running', reason: '立即返回，不等下载');
        expect(json['cancellable'], isTrue);
        final SettingsCliTask task = registry.byId(json['id']! as String)!;
        expect(await registry.wait(task, const Duration(seconds: 20)), isTrue);
        expect(
          task.status,
          SettingsCliTaskStatus.done,
          reason: '${task.error}',
        );
        final List<Object?> added = task.result!['added']! as List<Object?>;
        expect((added.single! as Map<String, Object?>)['name'], 'NetFont');
        expect(
          (await fonts().list(sc)).map((Map<String, Object?> r) => r['name']),
          contains('NetFont'),
        );
      } finally {
        await server.close(force: true);
      }
    });
  });

  testWidgets('items add with url also returns a task; cancel stops it', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsCliTaskRegistry registry = SettingsCliTaskRegistry();
    ctlFontTaskRegistry = registry;
    addTearDown(() => ctlFontTaskRegistry = SettingsCliTaskRegistry.instance);
    _useRealHttpClient();
    await tester.runAsync(() async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      // 只发头和一小段就挂住：下载停在 downloading 阶段，等取消。
      server.listen((HttpRequest request) {
        request.response
          ..contentLength = 1 << 20
          ..add(<int>[0x00, 0x01, 0x00, 0x00]);
        unawaited(request.response.flush());
      });
      try {
        final Map<String, Object?> created =
            await fonts().add!(sc, <String, String>{
                  'url': 'http://127.0.0.1:${server.port}/Slow.ttf',
                })
                as Map<String, Object?>;
        final Map<String, Object?> taskJson =
            created['task']! as Map<String, Object?>;
        final SettingsCliTask task = registry.byId(taskJson['id']! as String)!;
        // 同一来源不能并行起第二个。
        await expectLater(
          fonts().add!(sc, <String, String>{
            'url': 'http://127.0.0.1:${server.port}/Slow.ttf',
          }),
          throwsStateError,
        );
        expect(registry.cancel(task), SettingsCliCancelOutcome.requested);
        expect(await registry.wait(task, const Duration(seconds: 20)), isTrue);
        expect(task.status, SettingsCliTaskStatus.cancelled);
        expect(await fonts().list(sc), isEmpty, reason: '取消后不落库');
      } finally {
        await server.close(force: true);
      }
    });
  });

  testWidgets('bad input is rejected before touching the catalog', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    await tester.runAsync(() async {
      final SettingsCliList cli = fonts();
      await expectLater(
        cli.add!(sc, <String, String>{}),
        throwsArgumentError,
        reason: '没有来源',
      );
      await expectLater(
        cli.add!(sc, <String, String>{'system': 'Arial', 'url': 'https://x'}),
        throwsArgumentError,
        reason: '两个来源',
      );
      await expectLater(
        cli.add!(sc, <String, String>{'system': 'No Such Font'}),
        throwsArgumentError,
      );
      await expectLater(
        cli.add!(sc, <String, String>{'url': 'ftp://x/y.ttf'}),
        throwsArgumentError,
      );
      await expectLater(
        cli.add!(sc, <String, String>{'recommended': 'Not A Font'}),
        throwsArgumentError,
      );
      await expectLater(
        cli.add!(sc, <String, String>{'system': 'Arial', 'targets': 'nope'}),
        throwsArgumentError,
      );
      await cli.add!(sc, <String, String>{'system': 'Arial'});
      await expectLater(
        cli.add!(sc, <String, String>{'system': 'arial'}),
        throwsArgumentError,
        reason: '同名不重复加',
      );
      final String id = (await cli.list(sc)).single['id']! as String;
      await expectLater(
        cli.update!(sc, id, <String, String>{'position': '5'}),
        throwsArgumentError,
      );
      await expectLater(
        cli.update!(sc, id, <String, String>{'name': 'x'}),
        throwsArgumentError,
      );
      await expectLater(
        itemOf<SettingsCustomItem>(
          '${kCtlFontsIdPrefix}target.body',
        ).cliValue!.write(sc, 'Ghost'),
        throwsArgumentError,
      );
      expect(await cli.list(sc), hasLength(1));
    });
  });

  testWidgets('woff never lands on native-overlay targets', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    await tester.runAsync(() async {
      final SettingsCliList cli = fonts();
      final Map<String, Object?> row =
          (await cli.add!(sc, <String, String>{
                'path': fakeFont('Web.woff').path,
                'targets': 'body${Platform.isWindows ? ',gameLookup' : ''}',
              }))!
              as Map<String, Object?>;
      expect(row['targets'], <String>['body']);
      if (Platform.isWindows) {
        await expectLater(
          cli.update!(sc, row['id']! as String, <String, String>{
            'targets': 'floatingLyric',
          }),
          throwsArgumentError,
        );
      }
    });
  });

  testWidgets('recommended / system_fonts list actions', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    await tester.runAsync(() async {
      await fonts().add!(sc, <String, String>{'system': 'Arial'});
      final Map<String, Object?> sys =
          (await itemOf<SettingsActionItem>(
                '${kCtlFontsIdPrefix}system_fonts',
              ).cli!.run!(sc, <String, String>{'query': 'ar'}))!
              as Map<String, Object?>;
      expect(sys['count'], 1);
      expect((sys['families']! as List<Object?>).single, <String, Object?>{
        'family': 'Arial',
        'supportsJapanese': false,
        'added': true,
      });
      final Map<String, Object?> rec =
          (await itemOf<SettingsActionItem>(
                '${kCtlFontsIdPrefix}recommended',
              ).cli!.run!(sc, const <String, String>{}))!
              as Map<String, Object?>;
      expect((rec['fonts']! as List<Object?>), isNotEmpty);
    });
  });
}

/// flutter_test 给 `HttpClient` 装了一律回 400 的假实现；下载用例连本机回环服务，
/// 要真客户端，测完还原。
void _useRealHttpClient() {
  final HttpOverrides? saved = HttpOverrides.current;
  HttpOverrides.global = _RealHttpOverrides();
  addTearDown(() => HttpOverrides.global = saved);
}

class _RealHttpOverrides extends HttpOverrides {}
