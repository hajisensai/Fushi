import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_online_book.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/online_novel_book.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// 在线小说占位书（LNReader，描述符在 `EpubBooks.sourceMetadata`）不得当普通
/// EPUB 外传。
///
/// 它的解压树只有取过的章是正文、其余是占位页，描述符又不随内容包走：推给对端
/// 的是一本永远补不全的书（没取过的章停在占位文案、也没有描述符可再取），本地
/// 后来取到的章也不会补推（对端按标题认为已有）。四条外传通道——互联推送、host
/// 书单 `hasContent`、host 导出、云盘上传——统一问 [isLnReaderOnlineBookMetadata]。
void main() {
  final String descriptor = const LnReaderOnlineBookDescriptor(
    pluginId: 'kakuyomu',
    novelPath: '/works/1',
    chapters: <LnReaderChapter>[LnReaderChapter(name: '一', path: '/1')],
  ).encode();

  test('判据：在线小说描述符命中；普通书 / 在线漫画 / 损坏 / 空都不命中', () {
    expect(isLnReaderOnlineBookMetadata(descriptor), isTrue);
    expect(LnReaderOnlineBookDescriptor.marker, kLnReaderOnlineBookMarker);
    expect(isLnReaderOnlineBookMetadata(null), isFalse);
    expect(isLnReaderOnlineBookMetadata(''), isFalse);
    expect(
      isLnReaderOnlineBookMetadata('{"type":"hibiki-mihon","version":1}'),
      isFalse,
    );
    // 只是字符串里出现了标记、类型不对（例如书名里）不算。
    expect(
      isLnReaderOnlineBookMetadata(
        '{"type":"other","title":"fushi-lnreader-online"}',
      ),
      isFalse,
    );
    expect(isLnReaderOnlineBookMetadata('fushi-lnreader-online{'), isFalse);
  });

  group('host（引擎）', () {
    late Directory root;
    late FushiDatabase db;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('online_novel_gate');
      db = FushiDatabase(root.path);
    });

    tearDown(() async {
      await db.close();
      await cleanupTempDir(root);
    });

    Future<void> addBook(String key, {String? sourceMetadata}) async {
      final Directory dir = Directory(p.join(root.path, 'books', key));
      File(p.join(dir.path, 'META-INF', 'container.xml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('<container/>');
      File(p.join(dir.path, 'OEBPS', 'chapter-1.xhtml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('<html/>');
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: key,
          title: key,
          epubPath: '$key.epub',
          extractDir: dir.path,
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1000,
          sourceMetadata: Value<String?>(sourceMetadata),
        ),
      );
    }

    LocalLibraryHostService host() => LocalLibraryHostService(
      db: db,
      dictionaryResourceRoot: Directory.systemTemp,
      packages: SyncAssetPackageService(db: db),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
    );

    test('书单：在线占位书不标 hasContent，普通 EPUB 照常', () async {
      await addBook('plain');
      await addBook('online', sourceMetadata: descriptor);

      final Map<String, RemoteBookInfo> books = <String, RemoteBookInfo>{
        for (final RemoteBookInfo b in await host().listBooks()) b.title: b,
      };
      expect(books['plain']!.hasContent, isTrue);
      expect(books['online']!.hasContent, isFalse);
    });

    test('导出：在线占位书拒绝打包（端点 404），普通 EPUB 照常', () async {
      await addBook('plain');
      await addBook('online', sourceMetadata: descriptor);

      final File exported = await host().exportBook('plain');
      addTearDown(() => exported.parent.delete(recursive: true));
      expect(exported.existsSync(), isTrue);
      await expectLater(
        host().exportBook('online'),
        throwsA(isA<StateError>()),
      );
    });
  });

  test('app 侧两条外传（互联推送 / 云盘上传）都先问这个判据', () {
    String read(String path) => File(path).readAsStringSync();
    final String push = read('lib/src/sync/sync_orchestrator/books.part.dart');
    expect(
      push,
      contains('if (isLnReaderOnlineBookMetadata(row.sourceMetadata)) {'),
    );
    final String cloud = read('lib/src/sync/sync_manager.dart');
    expect(
      cloud,
      contains('!isLnReaderOnlineBookMetadata(book.sourceMetadata) &&'),
    );
  });
}
