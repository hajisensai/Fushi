import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudiobookStorage;
import 'package:fushi_core/fushi_core.dart' show fnv1a32Hex;
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';

void main() {
  late Directory tempRoot;
  late Directory docs;
  late Directory support;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('storage_usage_test');
    docs = Directory(p.join(tempRoot.path, 'docs'))..createSync();
    support = Directory(p.join(tempRoot.path, 'support'))..createSync();
  });

  tearDown(() {
    try {
      tempRoot.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上偶发句柄延迟释放：留给系统临时目录清理。
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
      );

  group('directorySizeSync', () {
    test('递归求和整棵树', () {
      writeFile(p.join(docs.path, 'a', 'x.bin'), 100);
      writeFile(p.join(docs.path, 'a', 'b', 'y.bin'), 50);
      writeFile(p.join(docs.path, 'z.bin'), 7);
      expect(directorySizeSync(docs.path), 157);
    });

    test('不存在的路径返回 0', () {
      expect(directorySizeSync(p.join(docs.path, 'missing')), 0);
    });

    test('单文件路径按文件长度算（随包组件有单文件项）', () {
      final String file = p.join(docs.path, 'ffmpeg.exe');
      writeFile(file, 42);
      expect(directorySizeSync(file), 42);
    });
  });

  test('类目清单全覆盖 documents 白名单：每个顶层目录归属且只归属一个类目', () {
    final List<String> assigned = <String>[
      for (final List<String> children
          in kStorageCategoryDocumentsChildren.values)
        ...children,
    ];
    // 无重复归属。
    expect(assigned.toSet().length, assigned.length, reason: '同一顶层目录被分进了多个类目');
    // 与白名单互为全集（新目录加进 fushiOwnedDocumentsEntries 时，这里逼着
    // 给它选一个存储类目——否则存储页总量会漏账）。
    expect(assigned.toSet(), AppPaths.fushiOwnedDocumentsEntries,
        reason: '存储类目清单必须与 AppPaths.fushiOwnedDocumentsEntries 全覆盖对齐');
  });

  test('audiobookPersistDirPath 与 AudiobookStorage 真实落盘目录逐字节一致', () async {
    // 用真实导入原语落盘（不是自算哈希自验自证）：ensurePersistDir 是唯一的
    // 持久目录创建点，扫描端的纯派生必须与它指向同一目录（审查 H1 的守卫）。
    AudiobookStorage.documentsRootResolver = () async => docs;
    addTearDown(() => AudiobookStorage.documentsRootResolver = null);
    const String persistKey = 'book-key-123';
    final Directory real = await AudiobookStorage.ensurePersistDir(persistKey);
    expect(audiobookPersistDirPath(docs, persistKey), real.path);
    // 哈希口径回归锚（与 fushi_core stable_hash 金标同源）。
    expect(real.path,
        p.join(docs.path, 'audiobooks', fnv1a32Hex(utf8.encode(persistKey))));
  });

  group('scanCategories', () {
    test('书籍类目：总量按目录整树，明细含真实原语落盘的配对音频，按字节降序', () async {
      // 两本书 + 一个孤儿目录（不在 DB 里）。
      final String bookA = p.join(docs.path, 'fushi_books', 'keyA');
      final String bookB = p.join(docs.path, 'fushi_books', 'keyB');
      writeFile(p.join(bookA, 'ch1.html'), 100);
      writeFile(p.join(bookB, 'ch1.html'), 300);
      writeFile(p.join(docs.path, 'fushi_books', 'orphan', 'x.html'), 11);
      // 书 A 的配对音频用**真实导入原语**落盘（键 = bookKey，与
      // AudiobookRepository 删除侧同口径；EpubBooks.uid 从不入哈希——审查 H1）；
      // 书 A 另挂一条字幕书音频（键 = SrtBooks.uid）。
      AudiobookStorage.documentsRootResolver = () async => docs;
      addTearDown(() => AudiobookStorage.documentsRootResolver = null);
      final Directory audioA = await AudiobookStorage.ensurePersistDir('keyA');
      writeFile(p.join(audioA.path, 'audio.mp3'), 500);
      final Directory srtAudioA =
          await AudiobookStorage.ensurePersistDir('srtbook_1');
      writeFile(p.join(srtAudioA.path, 'audio2.mp3'), 40);

      final List<StorageCategoryUsage> all = await service().scanCategories(
        books: <StorageBookRef>[
          StorageBookRef(
            bookKey: 'keyA',
            title: 'A',
            extractDir: bookA,
            persistKeys: const <String>['keyA', 'srtbook_1'],
          ),
          StorageBookRef(
            bookKey: 'keyB',
            title: 'B',
            extractDir: bookB,
            persistKeys: const <String>['keyB'],
          ),
        ],
        dictionaryNames: const <String>[],
      ).toList();

      final StorageCategoryUsage books = all.singleWhere(
          (StorageCategoryUsage u) => u.id == StorageCategoryId.books);
      // 100 + 300 + 11（孤儿也计入总量）+ 500 + 40（audiobooks 整树）。
      expect(books.bytes, 951);
      expect(books.entries.length, 2);
      // 降序：A = 100 + 500 + 40 = 640 在前，B = 300 在后（B 的 persist 目录
      // 不存在，计 0）。
      expect(books.entries[0].id, 'keyA');
      expect(books.entries[0].bytes, 640);
      expect(books.entries[1].id, 'keyB');
      expect(books.entries[1].bytes, 300);
    });

    test('词典类目：明细按词典名对应资源子目录', () async {
      writeFile(
          p.join(docs.path, 'dictionaryResources', 'JMdict', 'blobs.bin'), 800);
      writeFile(
          p.join(docs.path, 'dictionaryResources', 'Pixiv', 'blobs.bin'), 200);
      writeFile(
          p.join(docs.path, 'dictionaryImportWorkingDirectory', 'tmp.bin'), 5);

      final List<StorageCategoryUsage> all = await service().scanCategories(
        books: const <StorageBookRef>[],
        dictionaryNames: const <String>['JMdict', 'Pixiv'],
      ).toList();

      final StorageCategoryUsage dicts = all.singleWhere(
          (StorageCategoryUsage u) => u.id == StorageCategoryId.dictionaries);
      expect(dicts.bytes, 1005);
      expect(dicts.entries.map((StorageEntryUsage e) => e.id).toList(),
          <String>['JMdict', 'Pixiv']);
      expect(dicts.entries[0].bytes, 800);
      expect(dicts.entries[1].bytes, 200);
    });

    test('database 类目 = support 根整体减去 OCR 模型；ocrModels 单列', () async {
      writeFile(p.join(support.path, 'fushi.sqlite'), 1000);
      writeFile(
          p.join(support.path, kOcrModelsSupportChild, 'manga', 'a.onnx'), 300);

      final List<StorageCategoryUsage> all = await service().scanCategories(
        books: const <StorageBookRef>[],
        dictionaryNames: const <String>[],
      ).toList();

      expect(
          all
              .singleWhere((StorageCategoryUsage u) =>
                  u.id == StorageCategoryId.database)
              .bytes,
          1000);
      expect(
          all
              .singleWhere((StorageCategoryUsage u) =>
                  u.id == StorageCategoryId.ocrModels)
              .bytes,
          300);
    });

    test('每个类目恰好产出一次结果', () async {
      final List<StorageCategoryUsage> all = await service().scanCategories(
        books: const <StorageBookRef>[],
        dictionaryNames: const <String>[],
      ).toList();
      expect(all.map((StorageCategoryUsage u) => u.id).toSet(),
          StorageCategoryId.values.toSet());
      expect(all.length, StorageCategoryId.values.length);
    });
  });

  group('formatStorageBytes', () {
    test('分档口径', () {
      expect(formatStorageBytes(0), '0 B');
      expect(formatStorageBytes(1023), '1023 B');
      expect(formatStorageBytes(1024), '1.0 KB');
      expect(formatStorageBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatStorageBytes((2.5 * 1024 * 1024 * 1024).round()), '2.5 GB');
      expect(formatStorageBytes(200 * 1024 * 1024), '200 MB');
    });
  });
}
