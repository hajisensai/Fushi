import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show buildFushiFallbackTheme;
import 'package:fushi/src/pages/implementations/library_recovery_page.dart';
import 'package:fushi/src/storage/orphan_book_recovery.dart';
import 'package:fushi/src/sync/auto_backup/backup_folder_mirror.dart';
import 'package:fushi/src/sync/auto_backup/restore_point_catalog.dart';
import 'package:fushi/src/sync/backup_service.dart'
    show BackupCategory, OverwriteSnapshotBook, OverwriteSnapshotPreview;
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show backupCategoryLabel;

import '../../integration_test/helpers/focus_driver.dart';

/// 还原点页：列出更新前与定时还原点（种类、内容）；删除走行内确认面板，全程焦点驱动（Enter）。
class _DirHost implements RestorePointsHost {
  _DirHost(this.dir);

  final String dir;
  final List<String> replaced = <String>[];
  Exception? fillError;
  int fillCalls = 0;

  @override
  List<RestorePointEntry> listEntries() =>
      listRestorePointEntries(dbDirectory: dir);

  @override
  void deleteEntry(RestorePointEntry entry) => deleteRestorePointEntry(entry);

  OverwriteSnapshotPreview? preview;

  @override
  Future<OverwriteSnapshotPreview?> previewFillIn(
    RestorePointEntry entry,
  ) async => preview;

  @override
  Future<void> fillIn(RestorePointEntry entry) async {
    fillCalls++;
    final Exception? error = fillError;
    if (error != null) throw error;
  }

  @override
  Future<void> replace(RestorePointEntry entry) async => replaced.add(entry.id);

  @override
  Future<bool> export(RestorePointEntry entry) async => false;

  @override
  Future<OrphanBookRecovery?> orphanRecovery() async => null;

  /// 用户文件夹（目录）；null = 没设。
  String? folderDir;

  @override
  String? get folderLabel => folderDir == null ? null : 'Backups';

  @override
  Future<MirrorFolderListing?> listFolderCopies() async =>
      folderDir == null ? null : IoBackupFolderMirror(folderDir!).list();

  @override
  Future<void> copyFolderCopyToDevice(MirroredRestorePoint copy) async {
    await copyMirroredPointToStore(
      IoBackupFolderMirror(folderDir!),
      copy,
      RestorePointStore(dir),
    );
  }

  @override
  Future<void> deleteFolderCopy(MirroredRestorePoint copy) =>
      IoBackupFolderMirror(folderDir!).delete(copy.id);
}

/// 在文件夹 [folder] 里造一份副本（[source] 的文件 + 元数据，标上写入设备）。
void _mirrorInto(String folder, RestorePoint source, {required String device}) {
  final Directory dest = Directory(p.join(folder, source.id))
    ..createSync(recursive: true);
  for (final RestorePointFile f in source.files) {
    File(p.join(source.directory, f.name)).copySync(p.join(dest.path, f.name));
  }
  final Map<String, Object?> meta = source.toJson()
    ..['deviceId'] = device
    ..['deviceName'] = 'Phone $device';
  File(
    p.join(dest.path, kRestorePointMetaFileName),
  ).writeAsStringSync(jsonEncode(meta));
}

void main() {
  late Directory tmp;
  late RestorePoint scheduled;
  late RestorePoint preUpdate;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_restore_points_page_');
    final RestorePointStore store = RestorePointStore(tmp.path);
    final int base = DateTime.utc(2026, 11, 25, 12).millisecondsSinceEpoch;

    final RestorePointDraft update = store.begin(
      kind: RestorePointKind.preUpdate,
      nowMs: base,
    );
    File(
      p.join(update.directory, RestorePointDatabase.fushi.fileName),
    ).writeAsStringSync('db');
    preUpdate = store.commit(
      update,
      fromSchema: kFushiDbSchemaVersion - 1,
      toSchema: kFushiDbSchemaVersion,
    );

    final RestorePointDraft backup = store.begin(
      kind: RestorePointKind.scheduled,
      nowMs: base + const Duration(hours: 1).inMilliseconds,
    );
    File(
      p.join(backup.directory, kRestorePointArchiveFileName),
    ).writeAsStringSync('zip');
    scheduled = store.commit(
      backup,
      fromSchema: kFushiDbSchemaVersion,
      toSchema: kFushiDbSchemaVersion,
      // 整库定时点（生产里的形态）：数据类别都在，文件只带了字体。
      categories: <String>[
        'fonts',
        'music',
        'progress',
        'statistics',
        'settings',
        'profiles',
        'srs',
      ],
      excludedCategories: <String>[
        'dictionary',
        'books',
        'audiobooks',
        'videos',
        'localAudio',
        'games',
      ],
      includesSrsMedia: false,
      fullDatabase: true,
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<_DirHost> pumpPage(WidgetTester tester, {String? folderDir}) async {
    if (folderDir != null) {
      // 文件夹那一节在两张还原点卡片下面：给足高度，懒构建的列表才会把它建出来。
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }
    final _DirHost host = _DirHost(tmp.path)..folderDir = folderDir;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildFushiFallbackTheme(Brightness.light),
          home: RestorePointsPage.withHost(host: host),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return host;
  }

  testWidgets('列出更新前与定时还原点：种类与内容', (WidgetTester tester) async {
    await pumpPage(tester);
    expect(find.text(t.restore_points_kind_scheduled), findsOneWidget);
    expect(find.text(t.restore_points_kind_pre_update), findsOneWidget);
    expect(
      find.textContaining(t.restore_points_contents_without_media),
      findsOneWidget,
    );
    // 更新前快照与整库定时点都写「整库」；定时点另列带了哪些文件。
    expect(
      find.textContaining(t.restore_points_contents_full_db),
      findsNWidgets(2),
    );
    expect(
      find.textContaining(
        t.restore_points_contents_files(
          categories: backupCategoryLabel(BackupCategory.fonts),
        ),
      ),
      findsOneWidget,
    );
    // 两份都能补回、替换（schema 在本版本可用区间内）。
    for (final RestorePoint point in <RestorePoint>[scheduled, preUpdate]) {
      expect(
        find.byKey(ValueKey<String>('restore-point-fill-${point.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey<String>('restore-point-replace-${point.id}')),
        findsOneWidget,
      );
    }
  });

  testWidgets('删除：键盘到「删除」→ 行内确认 → Enter 删掉那一个还原点', (WidgetTester tester) async {
    await pumpPage(tester);
    final FocusDriver driver = FocusDriver(tester);
    final bool reached = await driver.focusWidget(
      find.byKey(ValueKey<String>('restore-point-delete-${scheduled.id}')),
    );
    expect(reached, isTrue, reason: '「删除」必须能用键盘走到');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('restore-point-panel-${scheduled.id}')),
      findsOneWidget,
    );
    expect(find.text(t.restore_points_delete_body), findsOneWidget);
    expect(Directory(scheduled.directory).existsSync(), isTrue);

    // 确认键随面板出现就拿到焦点：Enter 即确认。
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(Directory(scheduled.directory).existsSync(), isFalse);
    expect(Directory(preUpdate.directory).existsSync(), isTrue);
    expect(find.text(t.restore_points_kind_scheduled), findsNothing);
    expect(find.text(t.restore_points_kind_pre_update), findsOneWidget);
  });

  testWidgets('替换整库定时点：面板说清数据全回来、没带的文件原样不动（不再说会被移除），Enter 确认', (
    WidgetTester tester,
  ) async {
    final _DirHost host = await pumpPage(tester);
    final FocusDriver driver = FocusDriver(tester);
    expect(
      await driver.focusWidget(
        find.byKey(ValueKey<String>('restore-point-replace-${scheduled.id}')),
      ),
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      find.textContaining(t.restore_points_replace_full_db),
      findsOneWidget,
    );
    expect(
      find.textContaining(backupCategoryLabel(BackupCategory.books)),
      findsWidgets,
    );
    expect(
      find.textContaining(
        t.restore_points_replace_removed(categories: '').trim(),
      ),
      findsNothing,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(host.replaced, <String>[scheduled.id]);
  });

  test('整库定时点：没有「会被移除」的类别，没带文件的类别单独列出', () {
    final RestorePointEntry entry = listRestorePointEntries(
      dbDirectory: tmp.path,
    ).firstWhere((RestorePointEntry e) => e.id == scheduled.id);
    expect(restorePointMissingCategories(entry), isEmpty);
    expect(
      restorePointFilesLeftAlone(entry),
      containsAll(<BackupCategory>[
        BackupCategory.books,
        BackupCategory.videos,
      ]),
    );
    expect(
      restorePointFilesLeftAlone(entry),
      isNot(contains(BackupCategory.fonts)),
    );
  });

  testWidgets('补回失败（关库之前，例如从 zip 解主库失败）：不抛未处理异常，页面恢复可用', (
    WidgetTester tester,
  ) async {
    final _DirHost host = await pumpPage(tester);
    host.fillError = const FileSystemException('zip is corrupt');
    host.preview = OverwriteSnapshotPreview(
      path: preUpdate.directory,
      sizeBytes: 1,
      createdAt: DateTime(2026, 11, 25),
      missingBooks: const <OverwriteSnapshotBook>[],
      missingVideoCount: 1,
    );
    final FocusDriver driver = FocusDriver(tester);
    expect(
      await driver.focusWidget(
        find.byKey(ValueKey<String>('restore-point-fill-${preUpdate.id}')),
      ),
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('restore-point-confirm-${preUpdate.id}')),
      findsOneWidget,
    );
    // 确认键随面板出现就拿到焦点：Enter 即确认。
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(host.fillCalls, 1);
    expect(tester.takeException(), isNull);
    // 页面没卡在忙碌态：还能再走到按钮上。
    expect(
      await driver.focusWidget(
        find.byKey(ValueKey<String>('restore-point-fill-${preUpdate.id}')),
      ),
      isTrue,
    );
  });

  testWidgets('没有还原点：显示空状态', (WidgetTester tester) async {
    Directory(
      p.join(tmp.path, kRestorePointsDirName),
    ).deleteSync(recursive: true);
    await pumpPage(tester);
    expect(find.text(t.restore_points_empty), findsOneWidget);
  });

  group('用户文件夹（第三期）', () {
    late String folder;
    late String foreignId;

    setUp(() {
      folder = p.join(tmp.path, 'user_folder');
      Directory(folder).createSync();
      // 本机这份也在文件夹里；另有一份只在文件夹里（别的设备写的，本机没有）。
      _mirrorInto(folder, scheduled, device: 'a');
      final RestorePointStore other = RestorePointStore(
        p.join(tmp.path, 'other_device'),
      );
      final RestorePointDraft draft = other.begin(
        kind: RestorePointKind.scheduled,
        nowMs: DateTime.utc(2026, 11, 20, 8).millisecondsSinceEpoch,
      );
      File(
        p.join(draft.directory, kRestorePointArchiveFileName),
      ).writeAsStringSync('zip2');
      final RestorePoint foreign = other.commit(
        draft,
        fromSchema: kFushiDbSchemaVersion,
        toSchema: kFushiDbSchemaVersion,
        categories: <String>['fonts'],
        excludedCategories: <String>['books'],
        includesSrsMedia: false,
        fullDatabase: true,
      );
      foreignId = foreign.id;
      _mirrorInto(folder, foreign, device: 'b');
    });

    testWidgets('只列本机没有的副本，本机那份标「文件夹里也有」', (WidgetTester tester) async {
      await pumpPage(tester, folderDir: folder);
      expect(find.text(t.restore_points_folder_section), findsOneWidget);
      expect(
        find.byKey(ValueKey<String>('restore-point-folder-$foreignId')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey<String>('restore-point-folder-${scheduled.id}')),
        findsNothing,
      );
      expect(find.textContaining(t.restore_points_folder_also), findsOneWidget);
      expect(
        find.textContaining(
          t.restore_points_folder_from_device(device: 'Phone b'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('「复制到本机」：键盘走到按钮 → Enter → 进本机还原点，可补回 / 替换', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, folderDir: folder);
      final FocusDriver driver = FocusDriver(tester);
      final bool reached = await driver.focusWidget(
        find.byKey(ValueKey<String>('restore-point-folder-copy-$foreignId')),
      );
      expect(reached, isTrue, reason: '「复制到本机」必须能用键盘走到');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      // 复制走真实文件 IO：让出真实事件循环等它完成，再把界面推进到底。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();

      expect(
        RestorePoint.tryRead(
          p.join(tmp.path, kRestorePointsDirName, foreignId),
        ),
        isNotNull,
      );
      expect(
        find.byKey(ValueKey<String>('restore-point-fill-$foreignId')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey<String>('restore-point-folder-$foreignId')),
        findsNothing,
      );
      expect(find.text(t.restore_points_folder_empty), findsOneWidget);
    });

    testWidgets('删除文件夹副本：行内确认 → Enter，本机的点不动', (WidgetTester tester) async {
      await pumpPage(tester, folderDir: folder);
      final FocusDriver driver = FocusDriver(tester);
      final bool reached = await driver.focusWidget(
        find.byKey(ValueKey<String>('restore-point-folder-delete-$foreignId')),
      );
      expect(reached, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text(t.restore_points_folder_delete_body), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      expect(Directory(p.join(folder, foreignId)).existsSync(), isFalse);
      expect(Directory(p.join(folder, scheduled.id)).existsSync(), isTrue);
      expect(Directory(scheduled.directory).existsSync(), isTrue);
    });

    testWidgets('文件夹打不开：那一节说明原因，本机列表照常', (WidgetTester tester) async {
      await pumpPage(tester, folderDir: p.join(tmp.path, 'missing'));
      expect(
        find.byKey(const ValueKey<String>('restore-point-folder-error')),
        findsOneWidget,
      );
      expect(find.text(t.restore_points_kind_scheduled), findsOneWidget);
    });
  });
}
