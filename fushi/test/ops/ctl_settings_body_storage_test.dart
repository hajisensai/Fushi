import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/ops/ctl_settings_body_storage.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/storage/storage_usage_actions.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';
import 'package:fushi_core/fushi_core.dart' show DatabaseSnapshotDeletionResult;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

/// 存储页的控制通道条目：列出占用、按明细删除（真删临时目录里的文件）、只读
/// 明细拒删、Anime4K 删除需确认。
void main() {
  late Directory tempRoot;
  late Directory docs;
  late Directory support;
  late SettingsContext sc;
  late List<String> deletedBooks;
  late List<String> anime4kDeleted;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('ctl_storage_test');
    docs = Directory(p.join(tempRoot.path, 'docs'))..createSync();
    support = Directory(p.join(tempRoot.path, 'support'))..createSync();
    deletedBooks = <String>[];
    anime4kDeleted = <String>[];
  });

  tearDown(() {
    try {
      tempRoot.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄延迟释放：留给系统临时目录清理。
    }
  });

  void writeFile(String path, int bytes) {
    final File f = File(path);
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(List<int>.filled(bytes, 0x61));
  }

  StorageUsageService service() => StorageUsageService(
    documentsRoot: () async => docs,
    supportRoot: () async => support,
    cacheRoots: () async => const <Directory>[],
    documentsRootIsFushiOwned: () async => true,
    isolateRunner: <R>(R Function() computation) async => computation(),
  );

  StorageUsageActions actions(SettingsContext _) => StorageUsageActions(
    booksProvider: () async => <StorageBookRef>[
      StorageBookRef(
        id: 'keyA',
        title: 'Book A',
        extractDir: p.join(docs.path, 'fushi_books', 'keyA'),
      ),
    ],
    dictionaryNamesProvider: () async => const <String>[],
    deleteBook: (String key) async {
      deletedBooks.add(key);
      return null;
    },
    deleteSrtBook: (String _) async => null,
    deleteDictionary: (String _) async => null,
    deleteDatabaseSnapshots: () async => const DatabaseSnapshotDeletionResult(
      deleted: <String>[],
      failures: <String, String>{},
    ),
    deleteFiles: deleteStorageDerivedFiles,
    anime4kBytesProvider: () async => 4096,
    anime4kDelete: () async {
      anime4kDeleted.add('Anime4K_Clamp_Highlights.glsl');
      return anime4kDeleted;
    },
  );

  List<SettingsItem> items() => buildCtlStorageBodyPages(
    service: service,
    actions: actions,
  ).expand((CtlBodyPage page) => page.items).toList();

  SettingsCliList list(String name) =>
      (items().singleWhere(
                (SettingsItem i) => i.id == '$kCtlStorageIdPrefix$name',
              )
              as SettingsCustomItem)
          .cliList!;

  Future<void> pumpContext(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              sc = SettingsContext(
                context: context,
                appModel: AppModel(testPlatformServices()),
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

  testWidgets('categories 列出各类目字节数，Anime4K 占用挂在着色器类目上', (
    WidgetTester tester,
  ) async {
    writeFile(p.join(docs.path, 'thumbnails', 'a.png'), 2048);
    writeFile(p.join(docs.path, 'mpv_shaders', 'x.glsl'), 100);
    await pumpContext(tester);
    await tester.runAsync(() async {
      final List<Map<String, Object?>> rows = await list('categories').list(sc);
      final Map<String, Object?> covers = rows.singleWhere(
        (Map<String, Object?> r) => r['id'] == 'covers',
      );
      expect(covers['bytes'], 2048);
      expect(covers['size'], '2.0 KB');
      expect(covers['deletableEntries'], 1);
      final Map<String, Object?> shaders = rows.singleWhere(
        (Map<String, Object?> r) => r['id'] == 'shaders',
      );
      expect(shaders['anime4kBytes'], 4096);
      expect(rows.first['id'], 'covers', reason: '按体积降序');
    });
  });

  testWidgets('entries rm 真删派生文件、书走 deleteBook、只读明细与坏 id 拒删', (
    WidgetTester tester,
  ) async {
    final String thumb = p.join(docs.path, 'thumbnails', 'a.png');
    writeFile(thumb, 2048);
    writeFile(p.join(docs.path, 'video_subtitles', 's.srt'), 64);
    writeFile(p.join(docs.path, 'fushi_books', 'keyA', 'ch1.html'), 512);
    await pumpContext(tester);
    await tester.runAsync(() async {
      final SettingsCliList entries = list('entries');
      final List<Map<String, Object?>> rows = await entries.list(sc);

      final Map<String, Object?> thumbRow = rows.singleWhere(
        (Map<String, Object?> r) => r['category'] == 'covers',
      );
      expect(thumbRow['kind'], 'derivedFile');
      expect(thumbRow['deletable'], isTrue);
      await entries.remove!(sc, thumbRow['id']! as String);
      expect(File(thumb).existsSync(), isFalse);

      final Map<String, Object?> subRow = rows.singleWhere(
        (Map<String, Object?> r) => r['category'] == 'subtitles',
      );
      expect(subRow['deletable'], isFalse);
      await expectLater(
        entries.remove!(sc, subRow['id']! as String),
        throwsArgumentError,
      );

      await entries.remove!(sc, 'books:keyA');
      expect(deletedBooks, <String>['keyA']);

      await expectLater(
        entries.remove!(sc, 'no-separator'),
        throwsArgumentError,
      );
      await expectLater(
        entries.remove!(sc, 'covers:/gone'),
        throwsArgumentError,
      );
    });
  });

  testWidgets('anime4k_delete 是破坏性动作，执行后回报删除清单', (WidgetTester tester) async {
    await pumpContext(tester);
    final SettingsActionItem item =
        items().singleWhere(
              (SettingsItem i) =>
                  i.id == '${kCtlStorageIdPrefix}anime4k_delete',
            )
            as SettingsActionItem;
    expect(item.cli!.confirm, isTrue);
    expect(item.destructive, isTrue);
    await tester.runAsync(() async {
      final Map<String, Object?> result =
          await item.cli!.run!(sc, const <String, String>{})
              as Map<String, Object?>;
      expect(result['deleted'], <String>['Anime4K_Clamp_Highlights.glsl']);
      expect(result['freedBytes'], 4096);
    });
  });

  test('ids 唯一且都带 storage.cli. 前缀', () {
    final List<String> ids = items().map((SettingsItem i) => i.id).toList();
    expect(ids.toSet().length, ids.length);
    expect(
      ids.every((String id) => id.startsWith(kCtlStorageIdPrefix)),
      isTrue,
    );
  });
}
