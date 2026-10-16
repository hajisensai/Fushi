import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/pages/implementations/external_reader_import_page.dart';
import 'package:fushi/src/settings/settings_cli_tasks.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_platform_services.dart';
import 'hoshi_backup_fixture.dart';

/// `config run sync.hoshi_import`：扫描 + 预览在请求里做完，导入起后台任务（进度 /
/// 取消同导入页：取消在书与书之间生效，已导入的保留并交回结果）。
void main() {
  late Directory tempRoot;
  late FushiDatabase db;
  late SettingsContext settings;
  late SettingsCliTaskRegistry registry;

  String writeBackup() {
    final String path = p.join(tempRoot.path, 'Books.hoshi');
    final int at = DateTime(2026, 9, 3, 21).millisecondsSinceEpoch;
    writeHoshiBackup(path, <String, Object>{
      for (final String title in <String>[
        'こころ',
        '吾輩は猫である',
      ]) ...<String, Object>{
        '$title/metadata.json': <String, Object?>{
          'id': 'id-$title',
          'title': title,
          'folder': title,
          'lastAccess': appleSeconds(at),
        },
        '$title/$title.epub': fixtureEpub(title),
      },
    });
    return path;
  }

  Future<void> capture(WidgetTester tester) async {
    await tester.runAsync(() async {
      tempRoot = Directory.systemTemp.createTempSync('hoshi_cli_task_');
      EpubStorage.debugBaseDirectoryOverride = p.join(tempRoot.path, 'books');
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      final int profileId = await db.insertProfile(
        ProfilesCompanion.insert(name: 'Main', createdAt: 1, updatedAt: 1),
      );
      await db.setPref(kActiveProfileIdPrefKey, profileId.toString());
    });
    final AppModel app = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db);
    registry = SettingsCliTaskRegistry();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, Widget? _) {
              settings = SettingsContext(
                context: context,
                appModel: app,
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

  tearDown(() async {
    await db.close();
    EpubStorage.debugBaseDirectoryOverride = null;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  testWidgets('dry_run 只回预览；导入起任务，结束后结果在 result 里', (
    WidgetTester tester,
  ) async {
    await capture(tester);
    final String path = writeBackup();
    final Map<String, Object?> preview =
        await tester.runAsync(
              () => runExternalReaderImportFromCli(
                settings,
                path,
                dryRun: true,
                registry: registry,
              ),
            )
            as Map<String, Object?>;
    expect((preview['preview']! as Map)['newBooks'], 2);
    expect(registry.tasks, isEmpty);

    final Map<String, Object?> started =
        await tester.runAsync(
              () => runExternalReaderImportFromCli(
                settings,
                path,
                dryRun: false,
                registry: registry,
              ),
            )
            as Map<String, Object?>;
    expect(started['kind'], kExternalReaderImportTaskKind);
    expect(started['status'], 'running');
    expect(started['cancellable'], isTrue);
    final SettingsCliTask task = registry.byId(started['id']! as String)!;
    await tester.runAsync(() => task.whenDone);
    expect(task.status, SettingsCliTaskStatus.done, reason: task.error);
    expect(task.result!['booksImported'], 2);
    expect(await tester.runAsync(db.getAllEpubBooks), hasLength(2));
  });

  testWidgets('取消在第一本之前生效：任务 cancelled，结果标 cancelled、没导入书', (
    WidgetTester tester,
  ) async {
    await capture(tester);
    final String path = writeBackup();
    final Map<String, Object?> started =
        await tester.runAsync(
              () => runExternalReaderImportFromCli(
                settings,
                path,
                dryRun: false,
                registry: registry,
              ),
            )
            as Map<String, Object?>;
    final SettingsCliTask task = registry.byId(started['id']! as String)!;
    expect(registry.cancel(task), SettingsCliCancelOutcome.requested);
    await tester.runAsync(() => task.whenDone);
    expect(task.status, SettingsCliTaskStatus.cancelled);
    expect(task.result!['cancelled'], isTrue);
    expect(task.result!['booksImported'], 0);
  });
}
