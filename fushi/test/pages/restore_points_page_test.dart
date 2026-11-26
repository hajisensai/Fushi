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
import 'package:fushi/src/sync/auto_backup/auto_backup_controller.dart'
    show AutoBackupMirrorKind;
import 'package:fushi/src/sync/auto_backup/backup_folder_mirror.dart';
import 'package:fushi/src/sync/auto_backup/received_device_backups.dart'
    show listReceivedDeviceBackupsSync;
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

  /// 云端（拿一个目录假扮同步服务）；null = 云端副本没开 / 没有后端。
  String? cloudDir;

  /// 云端列表失败时抛的异常（假扮登录失效等）。
  Exception? cloudListError;

  /// 服务器（拿一个目录假扮互联服务器）；null = 服务器副本没开 / 没有互联服务器。
  String? serverDir;

  /// 宿主收到的副本操作（`<copy|delete>:<kind>:<id>`）。
  final List<String> copyCalls = <String>[];

  String _dirOf(AutoBackupMirrorKind kind) => switch (kind) {
    AutoBackupMirrorKind.folder => folderDir!,
    AutoBackupMirrorKind.cloud => cloudDir!,
    AutoBackupMirrorKind.server => serverDir!,
  };

  @override
  Future<String?> mirrorLabel(AutoBackupMirrorKind kind) async =>
      switch (kind) {
        AutoBackupMirrorKind.folder => folderDir == null ? null : 'Backups',
        AutoBackupMirrorKind.cloud => cloudDir == null ? null : 'Google Drive',
        AutoBackupMirrorKind.server => serverDir == null ? null : 'Desk PC',
      };

  @override
  Future<MirrorFolderListing?> listMirrorCopies(
    AutoBackupMirrorKind kind,
  ) async {
    if (kind == AutoBackupMirrorKind.cloud) {
      final Exception? error = cloudListError;
      if (error != null) throw error;
      if (cloudDir == null) return null;
    }
    if (kind == AutoBackupMirrorKind.folder && folderDir == null) return null;
    if (kind == AutoBackupMirrorKind.server && serverDir == null) return null;
    return IoBackupFolderMirror(_dirOf(kind)).list();
  }

  @override
  Future<void> copyMirrorCopyToDevice(
    MirroredRestorePoint copy,
    AutoBackupMirrorKind kind,
  ) async {
    copyCalls.add('copy:${kind.name}:${copy.id}');
    await copyMirroredPointToStore(
      IoBackupFolderMirror(_dirOf(kind)),
      copy,
      RestorePointStore(dir),
    );
  }

  @override
  Future<void> deleteMirrorCopy(
    MirroredRestorePoint copy,
    AutoBackupMirrorKind kind,
  ) {
    copyCalls.add('delete:${kind.name}:${copy.id}');
    return IoBackupFolderMirror(_dirOf(kind)).delete(copy.id);
  }

  /// 假扮 app 当 host 时的同步根（`fushi-data/`）；null = 没有收件箱。
  String? receivedRoot;

  /// 宿主收到的「收到的备份」操作（`<export|delete>:<设备键>:<id|*>`）。
  final List<String> receivedCalls = <String>[];

  @override
  Future<List<ReceivedDeviceBackupGroup>> listReceivedBackups() async {
    final String? root = receivedRoot;
    if (root == null) return const <ReceivedDeviceBackupGroup>[];
    // 生产实现在后台 isolate 里跑同一个函数；假时钟里直接同步跑。
    return listReceivedDeviceBackupsSync(root, _kOwnDeviceKey);
  }

  @override
  Future<bool> exportReceivedBackup(ReceivedDeviceBackup copy) async {
    receivedCalls.add('export:${copy.deviceKey}:${copy.id}');
    return false;
  }

  @override
  Future<void> deleteReceivedBackup(String deviceKey, {String? id}) async {
    receivedCalls.add('delete:$deviceKey:${id ?? '*'}');
    final String dir = p.joinAll(<String>[
      receivedRoot!,
      kDeviceBackupsNamespace,
      deviceKey,
      ?id,
    ]);
    // 假时钟里不走真异步 IO。
    Directory(dir).deleteSync(recursive: true);
  }
}

/// 本机自己的设备键（收件箱里它的副本不列）。
const String _kOwnDeviceKey = '00000000000000aa';

/// 照设备经 WebDAV 上传的样子在同步根 [syncRoot] 下写一份收到的定时还原点。
void _putReceived(
  String syncRoot,
  String device,
  String id, {
  required int createdAtMs,
  String? name,
}) {
  final Directory dir = Directory(
    p.join(syncRoot, kDeviceBackupsNamespace, device, id),
  )..createSync(recursive: true);
  File(p.join(dir.path, kRestorePointArchiveFileName)).writeAsStringSync('zip');
  final RestorePoint point = RestorePoint(
    id: id,
    directory: dir.path,
    kind: RestorePointKind.scheduled,
    database: RestorePointDatabase.fushi,
    createdAtMs: createdAtMs,
    fromSchema: kFushiDbSchemaVersion,
    toSchema: kFushiDbSchemaVersion,
    files: const <RestorePointFile>[
      RestorePointFile(name: kRestorePointArchiveFileName, size: 3),
    ],
    fullDatabase: true,
    appVersion: '9.9.9',
    deviceId: device,
    deviceName: name,
  );
  File(
    p.join(dir.path, kRestorePointMetaFileName),
  ).writeAsStringSync(jsonEncode(point.toJson()));
}

/// 在另一台设备的存储 [root] 里写一份定时还原点（只会出现在文件夹 / 云端里）。
RestorePoint _foreignPoint(String root) {
  final RestorePointStore other = RestorePointStore(root);
  final RestorePointDraft draft = other.begin(
    kind: RestorePointKind.scheduled,
    nowMs: DateTime.utc(2026, 11, 20, 8).millisecondsSinceEpoch,
  );
  File(
    p.join(draft.directory, kRestorePointArchiveFileName),
  ).writeAsStringSync('zip2');
  return other.commit(
    draft,
    fromSchema: kFushiDbSchemaVersion,
    toSchema: kFushiDbSchemaVersion,
    categories: <String>['fonts'],
    excludedCategories: <String>['books'],
    includesSrsMedia: false,
    fullDatabase: true,
  );
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

  Future<_DirHost> pumpPage(
    WidgetTester tester, {
    String? folderDir,
    String? cloudDir,
    Exception? cloudListError,
    String? serverDir,
    String? receivedRoot,
  }) async {
    if (folderDir != null ||
        cloudDir != null ||
        serverDir != null ||
        receivedRoot != null) {
      // 文件夹那一节在两张还原点卡片下面：给足高度，懒构建的列表才会把它建出来。
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }
    final _DirHost host = _DirHost(tmp.path)
      ..folderDir = folderDir
      ..cloudDir = cloudDir
      ..cloudListError = cloudListError
      ..serverDir = serverDir
      ..receivedRoot = receivedRoot;
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
      final RestorePoint foreign = _foreignPoint(
        p.join(tmp.path, 'other_device'),
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

  group('云端（第三期）', () {
    late String cloud;
    late String foreignId;

    setUp(() {
      cloud = p.join(tmp.path, 'cloud');
      Directory(cloud).createSync();
      // 本机这份也传上去了；另有一份只在云端（别的设备传的）。
      _mirrorInto(cloud, scheduled, device: 'a');
      final RestorePoint foreign = _foreignPoint(
        p.join(tmp.path, 'other_device'),
      );
      foreignId = foreign.id;
      _mirrorInto(cloud, foreign, device: 'b');
    });

    testWidgets('只列本机没有的云端副本，本机那份标「云端也有」，文件夹那一节不出现', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, cloudDir: cloud);
      expect(find.text(t.restore_points_cloud_section), findsOneWidget);
      expect(find.text(t.restore_points_folder_section), findsNothing);
      expect(
        find.text(t.restore_points_cloud_hint(service: 'Google Drive')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey<String>('restore-point-cloud-$foreignId')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey<String>('restore-point-cloud-${scheduled.id}')),
        findsNothing,
      );
      expect(find.textContaining(t.restore_points_cloud_also), findsOneWidget);
      expect(find.textContaining(t.restore_points_folder_also), findsNothing);
      expect(
        find.textContaining(
          t.restore_points_folder_from_device(device: 'Phone b'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('「复制到本机」：键盘走到按钮 → Enter → 宿主按云端取回，进本机还原点', (
      WidgetTester tester,
    ) async {
      final _DirHost host = await pumpPage(tester, cloudDir: cloud);
      final FocusDriver driver = FocusDriver(tester);
      final bool reached = await driver.focusWidget(
        find.byKey(ValueKey<String>('restore-point-cloud-copy-$foreignId')),
      );
      expect(reached, isTrue, reason: '「复制到本机」必须能用键盘走到');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();

      expect(host.copyCalls, <String>['copy:cloud:$foreignId']);
      expect(
        find.byKey(ValueKey<String>('restore-point-fill-$foreignId')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey<String>('restore-point-cloud-$foreignId')),
        findsNothing,
      );
      expect(find.text(t.restore_points_cloud_empty), findsOneWidget);
    });

    testWidgets('删除云端副本：行内确认（云端文案）→ Enter，本机的点不动', (WidgetTester tester) async {
      final _DirHost host = await pumpPage(tester, cloudDir: cloud);
      final FocusDriver driver = FocusDriver(tester);
      final bool reached = await driver.focusWidget(
        find.byKey(ValueKey<String>('restore-point-cloud-delete-$foreignId')),
      );
      expect(reached, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text(t.restore_points_cloud_delete_body), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      expect(host.copyCalls, <String>['delete:cloud:$foreignId']);
      expect(Directory(p.join(cloud, foreignId)).existsSync(), isFalse);
      expect(Directory(p.join(cloud, scheduled.id)).existsSync(), isTrue);
      expect(Directory(scheduled.directory).existsSync(), isTrue);
    });

    testWidgets('云端打不开：那一节给本地化原因（不显示异常原文），本机列表照常', (WidgetTester tester) async {
      await pumpPage(
        tester,
        cloudDir: cloud,
        cloudListError: const BackupMirrorException(
          kBackupMirrorErrorCloudAuth,
        ),
      );
      expect(
        find.byKey(const ValueKey<String>('restore-point-cloud-error')),
        findsOneWidget,
      );
      expect(
        find.text(
          t.restore_points_cloud_failed(reason: t.auto_backup_error_cloud_auth),
        ),
        findsOneWidget,
      );
      expect(find.textContaining(kBackupMirrorErrorCloudAuth), findsNothing);
      expect(find.text(t.restore_points_kind_scheduled), findsOneWidget);
    });

    testWidgets('文件夹与云端同时开着：两节各列各的', (WidgetTester tester) async {
      final String folder = p.join(tmp.path, 'user_folder');
      Directory(folder).createSync();
      _mirrorInto(folder, scheduled, device: 'a');
      await pumpPage(tester, folderDir: folder, cloudDir: cloud);
      expect(find.text(t.restore_points_folder_section), findsOneWidget);
      expect(find.text(t.restore_points_cloud_section), findsOneWidget);
      expect(find.text(t.restore_points_folder_empty), findsOneWidget);
      expect(
        find.byKey(ValueKey<String>('restore-point-cloud-$foreignId')),
        findsOneWidget,
      );
      expect(find.textContaining(t.restore_points_folder_also), findsOneWidget);
      expect(find.textContaining(t.restore_points_cloud_also), findsOneWidget);
    });
  });

  group('服务器（第四期）', () {
    late String server;
    late String foreignId;

    setUp(() {
      server = p.join(tmp.path, 'server');
      Directory(server).createSync();
      _mirrorInto(server, scheduled, device: 'a');
      final RestorePoint foreign = _foreignPoint(
        p.join(tmp.path, 'other_device'),
      );
      foreignId = foreign.id;
      _mirrorInto(server, foreign, device: 'b');
    });

    testWidgets('「服务器」一节只列本机没有的副本，本机那份标「服务器上也有」；删除用服务器文案', (
      WidgetTester tester,
    ) async {
      final _DirHost host = await pumpPage(tester, serverDir: server);
      expect(find.text(t.restore_points_server_section), findsOneWidget);
      expect(find.text(t.restore_points_cloud_section), findsNothing);
      expect(
        find.text(t.restore_points_server_hint(server: 'Desk PC')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey<String>('restore-point-server-$foreignId')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey<String>('restore-point-server-${scheduled.id}')),
        findsNothing,
      );
      expect(find.textContaining(t.restore_points_server_also), findsOneWidget);
      expect(find.textContaining(t.restore_points_cloud_also), findsNothing);
      expect(
        find.textContaining(
          t.restore_points_folder_from_device(device: 'Phone b'),
        ),
        findsOneWidget,
      );

      final FocusDriver driver = FocusDriver(tester);
      expect(
        await driver.focusWidget(
          find.byKey(
            ValueKey<String>('restore-point-server-delete-$foreignId'),
          ),
        ),
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text(t.restore_points_server_delete_body), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      expect(host.copyCalls, <String>['delete:server:$foreignId']);
      expect(Directory(p.join(server, foreignId)).existsSync(), isFalse);
      expect(find.text(t.restore_points_server_empty), findsOneWidget);
    });

    testWidgets('「复制到本机」按服务器取回', (WidgetTester tester) async {
      final _DirHost host = await pumpPage(tester, serverDir: server);
      final FocusDriver driver = FocusDriver(tester);
      expect(
        await driver.focusWidget(
          find.byKey(ValueKey<String>('restore-point-server-copy-$foreignId')),
        ),
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      expect(host.copyCalls, <String>['copy:server:$foreignId']);
      expect(
        find.byKey(ValueKey<String>('restore-point-fill-$foreignId')),
        findsOneWidget,
      );
    });
  });

  group('从其他设备收到的备份（本机当互联 host，第五期）', () {
    const String phone = '0123456789abcdef';
    const String tablet = 'fedcba9876543210';
    const String id1 = '20261120-030000-000-fushi-scheduled';
    const String id2 = '20261124-030000-000-fushi-scheduled';
    late String syncRoot;

    setUp(() {
      syncRoot = p.join(tmp.path, 'sync-data', 'fushi-data');
    });

    testWidgets('按设备分组列出（名字、份数、不完整），本机自己的副本不列；不提供恢复', (
      WidgetTester tester,
    ) async {
      _putReceived(syncRoot, phone, id1, createdAtMs: 1000, name: 'Pixel');
      _putReceived(syncRoot, phone, id2, createdAtMs: 3000, name: 'Pixel');
      _putReceived(syncRoot, tablet, id1, createdAtMs: 2000);
      _putReceived(syncRoot, _kOwnDeviceKey, id2, createdAtMs: 9000);
      // tablet 一份上传到一半（没有元数据）。
      Directory(
        p.join(syncRoot, kDeviceBackupsNamespace, tablet, id2),
      ).createSync(recursive: true);

      await pumpPage(tester, receivedRoot: syncRoot);
      expect(find.text(t.restore_points_received_section), findsOneWidget);
      expect(find.text(t.restore_points_received_hint), findsOneWidget);
      expect(find.text('Pixel'), findsOneWidget);
      expect(
        find.text(
          t.restore_points_received_unnamed_device(key: tablet.substring(0, 8)),
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(t.restore_points_received_incomplete(n: 1)),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>('restore-point-received-device-$phone'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>(
            'restore-point-received-device-$_kOwnDeviceKey',
          ),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey<String>('restore-point-received-$phone-$id1'),
        ),
        findsOneWidget,
      );
      // 只能导出 / 删除：收到的副本不出补回 / 替换 / 复制到本机。
      expect(
        find.byKey(const ValueKey<String>('restore-point-fill-$id1')),
        findsNothing,
      );
      expect(
        find.textContaining(t.restore_points_app_version(version: '9.9.9')),
        findsNWidgets(3),
      );
    });

    testWidgets('收件箱里只有本机自己的副本 / 没有收件箱：这一节不出现', (WidgetTester tester) async {
      _putReceived(syncRoot, _kOwnDeviceKey, id1, createdAtMs: 1000);
      await pumpPage(tester, receivedRoot: syncRoot);
      expect(find.text(t.restore_points_received_section), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await pumpPage(tester);
      expect(find.text(t.restore_points_received_section), findsNothing);
    });

    testWidgets('删一份：键盘到「删除」→ 行内确认 → Enter，只删那一份', (WidgetTester tester) async {
      _putReceived(syncRoot, phone, id1, createdAtMs: 1000, name: 'Pixel');
      _putReceived(syncRoot, phone, id2, createdAtMs: 3000, name: 'Pixel');
      final _DirHost host = await pumpPage(tester, receivedRoot: syncRoot);
      final FocusDriver driver = FocusDriver(tester);
      expect(
        await driver.focusWidget(
          find.byKey(
            const ValueKey<String>('restore-point-received-delete-$phone-$id1'),
          ),
        ),
        isTrue,
        reason: '「删除」必须能用键盘走到',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey<String>('restore-point-received-panel-$phone-$id1'),
        ),
        findsOneWidget,
      );
      expect(find.text(t.restore_points_received_delete_body), findsOneWidget);
      expect(host.receivedCalls, isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(host.receivedCalls, <String>['delete:$phone:$id1']);
      expect(
        find.byKey(
          const ValueKey<String>('restore-point-received-$phone-$id1'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey<String>('restore-point-received-$phone-$id2'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('删整台设备：行内确认带设备名 → Enter，这一节随之消失', (WidgetTester tester) async {
      _putReceived(syncRoot, phone, id1, createdAtMs: 1000, name: 'Pixel');
      final _DirHost host = await pumpPage(tester, receivedRoot: syncRoot);
      final FocusDriver driver = FocusDriver(tester);
      expect(
        await driver.focusWidget(
          find.byKey(
            const ValueKey<String>(
              'restore-point-received-delete-device-$phone',
            ),
          ),
        ),
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        find.text(
          t.restore_points_received_delete_device_body(device: 'Pixel'),
        ),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(host.receivedCalls, <String>['delete:$phone:*']);
      expect(find.text(t.restore_points_received_section), findsNothing);
    });

    testWidgets('导出：交给宿主导出那一份', (WidgetTester tester) async {
      _putReceived(syncRoot, phone, id1, createdAtMs: 1000, name: 'Pixel');
      final _DirHost host = await pumpPage(tester, receivedRoot: syncRoot);
      final FocusDriver driver = FocusDriver(tester);
      expect(
        await driver.focusWidget(
          find.byKey(
            const ValueKey<String>('restore-point-received-export-$phone-$id1'),
          ),
        ),
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(host.receivedCalls, <String>['export:$phone:$id1']);
    });
  });
}
