// BUG-2368：「导入文件夹 → 设为常驻来源」选到一个**已经登记过**的文件夹时，旧行为
// 是播一条只有路径、没有任何说明的 toast 就 return。用户视角是「文件选择器闪一下就
// 被强制弹回」——不知道原因，也没有任何进展。
//
// 修复后撞同根走与 `importLocalFolderOnce` 一致的落地：提示原因 + **重扫已有那一行**。
//
// 判据为什么是 lastScannedAt 而不是 toast 文案：桌面自绘 toast 要 overlay，而
// `FushiToast` 拿的是全局 navigatorKey，widget 测试的树里永远没有它——断言 toast 文案
// 是空壳。`SourceLibraryScanner.scan` 收尾一律写 `lastScannedAt: DateTime.now()`，
// 于是「时间戳被推进」就是「确实重扫了」的硬证据；旧的 `return` 行为下它恒不变。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

FushiDatabase _memDb() => FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
      ),
    );

void main() {
  late Directory tempDir;
  late FushiDatabase db;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('bug2368_source_root');
    db = _memDb();
  });

  tearDown(() async {
    debugRealDirectoryPathOverride = null;
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<MediaSourcesViewState> pumpView(
    WidgetTester tester, {
    required String mediaKind,
  }) async {
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db);
    final GlobalKey<MediaSourcesViewState> viewKey =
        GlobalKey<MediaSourcesViewState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(420, 800)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: MediaSourcesView(key: viewKey, mediaKind: mediaKind),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return viewKey.currentState!;
  }

  testWidgets('选到已登记的文件夹时重扫已有来源，而不是静默弹回', (WidgetTester tester) async {
    final String root =
        normalizeSourceRootPath(tempDir.path, transport: 'local');
    final DateTime staleScan = DateTime(2020, 1, 1);
    final int sourceId = await db.insertMediaSource(MediaSourcesCompanion(
      label: const Value('既有来源'),
      mediaKind: const Value('book'),
      transport: const Value('local'),
      rootPath: Value(root),
      recursive: const Value(true),
      sortOrder: const Value(0),
      lastScannedAt: Value(staleScan),
      createdAt: Value(DateTime.now().millisecondsSinceEpoch),
    ));

    final MediaSourcesViewState state =
        await pumpView(tester, mediaKind: 'book');

    // 用户在系统目录选择器里选中的正是那条来源的根。
    debugRealDirectoryPathOverride = tempDir.path;
    // 必须 runAsync：扫描器读的是真实磁盘，而 testWidgets 默认的 fake-async 区里
    // 真实 IO 的 Future 永远不会完成（直接 await 会挂到用例超时）。
    await tester.runAsync(() => state.addLocalFolder());
    await tester.pumpAndSettle();

    final List<MediaSourceRow> rows = await db.getMediaSourcesByKind('book');
    expect(rows.length, 1, reason: '撞同根不得插入第二条来源行');
    expect(rows.single.id, sourceId);

    final DateTime? scannedAt = rows.single.lastScannedAt;
    expect(scannedAt, isNotNull, reason: '撞同根必须重扫已有来源行');
    expect(
      scannedAt!.isAfter(staleScan),
      isTrue,
      reason: '旧行为只播一条裸路径 toast 就 return，时间戳恒停在预置值',
    );
  });

  testWidgets('「仅导入这一次」选到已登记的文件夹时同样重扫已有来源', (WidgetTester tester) async {
    final String root =
        normalizeSourceRootPath(tempDir.path, transport: 'local');
    final DateTime staleScan = DateTime(2020, 1, 1);
    await db.insertMediaSource(MediaSourcesCompanion(
      label: const Value('既有来源'),
      mediaKind: const Value('book'),
      transport: const Value('local'),
      rootPath: Value(root),
      recursive: const Value(true),
      sortOrder: const Value(0),
      lastScannedAt: Value(staleScan),
      createdAt: Value(DateTime.now().millisecondsSinceEpoch),
    ));

    final MediaSourcesViewState state =
        await pumpView(tester, mediaKind: 'book');

    debugRealDirectoryPathOverride = tempDir.path;
    await tester.runAsync(() => state.importLocalFolderOnce());
    await tester.pumpAndSettle();

    final List<MediaSourceRow> rows = await db.getMediaSourcesByKind('book');
    expect(rows.length, 1, reason: '同根不造一次性影子来源');
    expect(rows.single.lastScannedAt!.isAfter(staleScan), isTrue);
  });

  test('来源页不得把归一化路径本身当成整条提示语', () {
    // 这条 bug 的形状就是「提示 = 一条裸路径」。行为测试钉不住它（toast 进不了
    // widget 树），但源码层可以：撞重复的提示必须是 i18n 文案，路径只作参数。
    final File source = File(
      'lib/src/pages/implementations/media_sources_view.dart',
    );
    expect(source.existsSync(), isTrue);
    final String code = source.readAsStringSync();
    expect(
      code.contains('FushiToast.show(msg: norm'),
      isFalse,
      reason: '裸路径 toast 让用户看不出为什么被弹回（BUG-2368）',
    );
    expect(
      'media_source_root_already_added'.allMatches(code).length,
      3,
      reason: '本地 / 一次性导入 / 网络三条撞重复分支都要说明原因',
    );
  });
}
