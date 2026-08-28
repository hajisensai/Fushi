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
            id: 'keyA',
            title: 'A',
            extractDir: bookA,
            persistKeys: const <String>['keyA', 'srtbook_1'],
          ),
          StorageBookRef(
            id: 'keyB',
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

    test('BUG-1893：同步导入的明文音频目录（非哈希）计进明细，且不重复计数', () async {
      // 互联/同步拉来的有声书落 audiobooks/<safeDirName(bookKey)>——**明文**目录，
      // 不是 fnv1a32Hex(key)。旧实现只按哈希反推，这本书的明细恒为 0，几 GB 音频
      // 全掉进「类目总量 − 明细之和」的差额里。
      final String bookA = p.join(docs.path, 'fushi_books', 'keyA');
      writeFile(p.join(bookA, 'ch1.html'), 100);
      final String plainDir = p.join(docs.path, 'audiobooks', 'My Sync Book');
      writeFile(p.join(plainDir, 'a.mp3'), 500);
      writeFile(p.join(plainDir, 'b.mp3'), 200);
      // 哈希目录根本不存在（同步导入从不建它）。
      expect(Directory(audiobookPersistDirPath(docs, 'keyA')).existsSync(),
          isFalse);

      final List<StorageCategoryUsage> all = await service().scanCategories(
        books: <StorageBookRef>[
          StorageBookRef(
            id: 'keyA',
            title: 'A',
            extractDir: bookA,
            persistKeys: const <String>['keyA'],
            // DB 真相源：audioRoot（目录）+ audioPathsJson（它下面的文件）。
            audioPaths: <String>[
              plainDir,
              p.join(plainDir, 'a.mp3'),
              p.join(plainDir, 'b.mp3'),
            ],
          ),
        ],
        dictionaryNames: const <String>[],
      ).toList();

      final StorageCategoryUsage books = all.singleWhere(
          (StorageCategoryUsage u) => u.id == StorageCategoryId.books);
      expect(books.bytes, 800);
      // 明细之和 == 类目总量：音频不再只出现在差额里。
      expect(books.entries.single.bytes, 800);
      // 目录与它下面的文件同时喂进来时只留目录（去嵌套），不会 800 变 1500。
      expect(books.entries.single.paths, <String>[
        bookA,
        audiobookPersistDirPath(docs, 'keyA'),
        plainDir,
      ]);
      expect(books.entries.single.externalPaths, isEmpty);
    });

    test('BUG-1893：哈希目录形态与 DB 路径指向同一目录时只算一次', () async {
      // 本地导入的存量形态：audioPathsJson 里的文件就落在哈希持久目录内。
      AudiobookStorage.documentsRootResolver = () async => docs;
      addTearDown(() => AudiobookStorage.documentsRootResolver = null);
      final Directory persist = await AudiobookStorage.ensurePersistDir('keyA');
      writeFile(p.join(persist.path, 'audio.mp3'), 640);

      final List<StorageCategoryUsage> all = await service().scanCategories(
        books: <StorageBookRef>[
          StorageBookRef(
            id: 'keyA',
            title: 'A',
            extractDir: p.join(docs.path, 'fushi_books', 'keyA'),
            persistKeys: const <String>['keyA'],
            audioPaths: <String>[
              persist.path,
              p.join(persist.path, 'audio.mp3'),
            ],
          ),
        ],
        dictionaryNames: const <String>[],
      ).toList();

      final StorageCategoryUsage books = all.singleWhere(
          (StorageCategoryUsage u) => u.id == StorageCategoryId.books);
      expect(books.entries.single.bytes, 640);
      expect(books.bytes, 640);
    });

    test('BUG-1893：standalone 字幕书（bookKey 空、无 EPUB 正文）单独出条目', () async {
      // 这类书只有 SrtBooks 行，旧接线按 bookKey 过滤掉 → 存储页永远无行、
      // 也没有删除入口。
      AudiobookStorage.documentsRootResolver = () async => docs;
      addTearDown(() => AudiobookStorage.documentsRootResolver = null);
      final Directory persist =
          await AudiobookStorage.ensurePersistDir('srt-uid-1');
      writeFile(p.join(persist.path, 'ch1.mp3'), 300);
      writeFile(p.join(persist.path, 'sub.srt'), 20);

      final List<StorageCategoryUsage> all = await service().scanCategories(
        books: <StorageBookRef>[
          const StorageBookRef(
            id: 'srt-uid-1',
            title: 'S',
            extractDir: '',
            persistKeys: <String>['srt-uid-1'],
            kind: StorageEntryKind.srtBook,
          ),
        ],
        dictionaryNames: const <String>[],
      ).toList();

      final StorageCategoryUsage books = all.singleWhere(
          (StorageCategoryUsage u) => u.id == StorageCategoryId.books);
      final StorageEntryUsage entry = books.entries.single;
      expect(entry.id, 'srt-uid-1');
      expect(entry.kind, StorageEntryKind.srtBook);
      expect(entry.bytes, 320);
      // extractDir 为空串时不能混进求和路径（Directory('') 是个陷阱）。
      expect(entry.paths, <String>[persist.path]);
    });

    test('BUG-1893：桌面「引用原文件」的外部音频不计体积，但如实报进 externalPaths', () async {
      final String bookA = p.join(docs.path, 'fushi_books', 'keyA');
      writeFile(p.join(bookA, 'ch1.html'), 100);
      // app 目录之外：既不占应用空间，也删不掉。
      final String external = p.join(tempRoot.path, 'external', 'audio.mp3');
      writeFile(external, 900);

      final List<StorageCategoryUsage> all = await service().scanCategories(
        books: <StorageBookRef>[
          StorageBookRef(
            id: 'keyA',
            title: 'A',
            extractDir: bookA,
            persistKeys: const <String>['keyA'],
            audioPaths: <String>[external],
          ),
        ],
        dictionaryNames: const <String>[],
      ).toList();

      final StorageCategoryUsage books = all.singleWhere(
          (StorageCategoryUsage u) => u.id == StorageCategoryId.books);
      // 类目总量本来就扫不到 app 目录外的文件；明细必须同口径，否则明细之和 >
      // 类目总量，页面自相矛盾。
      expect(books.bytes, 100);
      expect(books.entries.single.bytes, 100);
      expect(books.entries.single.externalPaths, <String>[external]);
      expect(books.entries.single.paths, isNot(contains(external)));
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

    test('通用类目：明细 = 类目根下直接子项，label 带顶层目录前缀，总量 = 明细之和', () async {
      writeFile(p.join(docs.path, 'videos', 'a.mkv'), 700);
      writeFile(p.join(docs.path, 'remote_videos', 'series', 'ep1.mp4'), 300);
      writeFile(p.join(docs.path, 'mpv_shaders', 'Anime4K_Clamp.glsl'), 12);
      writeFile(p.join(docs.path, 'custom_fonts', 'NotoSerif.ttf'), 55);

      final List<StorageCategoryUsage> all = await service().scanCategories(
        books: const <StorageBookRef>[],
        dictionaryNames: const <String>[],
      ).toList();

      final StorageCategoryUsage video = all.singleWhere(
          (StorageCategoryUsage u) => u.id == StorageCategoryId.videoDownloads);
      // 跨 4 个根（videos / remote_videos / anime_downloads / manual_torrents）
      // 的直接子项合成一张明细，按字节降序。
      expect(video.bytes, 1000);
      expect(video.entries.map((StorageEntryUsage e) => e.label).toList(),
          <String>['videos/a.mkv', 'remote_videos/series']);
      expect(video.entries[0].bytes, 700);
      expect(video.entries[1].bytes, 300);
      // 通用条目的 id 是绝对路径（没有域内主键）。
      expect(video.entries[0].id, p.join(docs.path, 'videos', 'a.mkv'));

      final StorageCategoryUsage shaders = all.singleWhere(
          (StorageCategoryUsage u) => u.id == StorageCategoryId.shaders);
      expect(shaders.entries.single.label, 'mpv_shaders/Anime4K_Clamp.glsl');
      expect(shaders.bytes, 12);

      final StorageCategoryUsage fonts = all.singleWhere(
          (StorageCategoryUsage u) => u.id == StorageCategoryId.customFonts);
      expect(fonts.entries.single.label, 'custom_fonts/NotoSerif.ttf');
      expect(fonts.bytes, 55);
    });

    test('database 明细列出 support 根子项，且不含被单列的 OCR 模型目录', () async {
      writeFile(p.join(support.path, 'fushi.sqlite'), 1000);
      writeFile(p.join(support.path, 'local_audio_1.db'), 20);
      writeFile(
          p.join(support.path, kOcrModelsSupportChild, 'manga', 'a.onnx'), 300);

      final List<StorageCategoryUsage> all = await service().scanCategories(
        books: const <StorageBookRef>[],
        dictionaryNames: const <String>[],
      ).toList();

      final StorageCategoryUsage db = all.singleWhere(
          (StorageCategoryUsage u) => u.id == StorageCategoryId.database);
      expect(db.bytes, 1020);
      expect(db.entries.map((StorageEntryUsage e) => e.label).toList(),
          <String>['support/fushi.sqlite', 'support/local_audio_1.db']);

      final StorageCategoryUsage ocr = all.singleWhere(
          (StorageCategoryUsage u) => u.id == StorageCategoryId.ocrModels);
      expect(ocr.entries.single.label, 'ocr_models/manga');
      expect(ocr.bytes, 300);
    });

    test('BUG-1870：database 明细把主库快照残留聚成一条可删条目，活库/侧车仍只读单列', () async {
      // 用户机器实测：support 根下几十个 hibiki.db.bak.v16.* / fushi.db.corrupt-bak-*
      // 逐条按原始文件名铺开、没有删除按钮。修复后它们聚成一条 databaseSnapshots。
      writeFile(p.join(support.path, 'fushi.db'), 1000);
      writeFile(p.join(support.path, 'fushi.db-wal'), 100);
      writeFile(p.join(support.path, 'fushi.db-shm'), 10);
      writeFile(p.join(support.path, 'fushi.db.corrupt-bak-1.db'), 7);
      writeFile(p.join(support.path, 'fushi.db.corrupt-bak-1.db-wal'), 5);
      writeFile(p.join(support.path, 'hibiki.db.bak.v16.1780592923530'), 3);
      writeFile(p.join(support.path, 'hibiki.db-wal.bak.v20.1'), 1);
      writeFile(p.join(support.path, 'local_audio_1.db'), 20);
      // BUG-1870 审查：backup_service 的活控制文件同样以主库名开头，但它们不是
      // 副本——被聚进可删条目就是永久丢 LAN 配对/同步基线（必须留在只读明细里）。
      writeFile(p.join(support.path, 'fushi.db.merge-src'), 9);
      writeFile(p.join(support.path, 'fushi.db.merge-preview-src'), 8);
      // 同名子目录不是文件，不进快照集合（按只读目录单列）。
      writeFile(p.join(support.path, 'fushi.db.corrupt-bak-2.db', 'x'), 2);

      final List<StorageCategoryUsage> all = await service().scanCategories(
        books: const <StorageBookRef>[],
        dictionaryNames: const <String>[],
      ).toList();
      final StorageCategoryUsage db = all.singleWhere(
          (StorageCategoryUsage u) => u.id == StorageCategoryId.database);

      final StorageEntryUsage snapshots = db.entries.singleWhere(
          (StorageEntryUsage e) =>
              e.kind == StorageEntryKind.databaseSnapshots);
      expect(snapshots.id, StorageUsageService.kDatabaseSnapshotsEntryId);
      expect(snapshots.bytes, 7 + 5 + 3 + 1);
      expect(
        snapshots.paths.map(p.basename).toSet(),
        <String>{
          'fushi.db.corrupt-bak-1.db',
          'fushi.db.corrupt-bak-1.db-wal',
          'hibiki.db.bak.v16.1780592923530',
          'hibiki.db-wal.bak.v20.1',
        },
      );
      // 新旧两个库名都命中时 fallback label 并列列出，不再写死 fushi.db。
      expect(snapshots.label, 'support/{fushi.db,hibiki.db}.*');
      // 其余条目全是只读，且活库 + 侧车 + 活控制文件 + 无关文件 + 同名目录
      // 一个不少、一个不多。
      final List<StorageEntryUsage> readOnly = db.entries
          .where((StorageEntryUsage e) => e.kind == StorageEntryKind.readOnly)
          .toList();
      expect(
        readOnly.map((StorageEntryUsage e) => e.label).toSet(),
        <String>{
          'support/fushi.db',
          'support/fushi.db-wal',
          'support/fushi.db-shm',
          'support/local_audio_1.db',
          'support/fushi.db.merge-src',
          'support/fushi.db.merge-preview-src',
          'support/fushi.db.corrupt-bak-2.db',
        },
      );
      // 类目总量 = 全部明细之和（快照没有被算两次、也没有丢）。
      expect(db.bytes, 1000 + 100 + 10 + 7 + 5 + 3 + 1 + 20 + 9 + 8 + 2);
      expect(db.entries.length, readOnly.length + 1);
    });

    test('BUG-1870 审查：待恢复的 pre-restore.bak 有 sidecar 时不进可删条目', () async {
      // 覆盖导入的 device-local replay 没跑完时，sidecar + bak 会被刻意保留，
      // 下次启动 recoverPendingRestore 靠它们补完。此时把 bak 聚进「可删」＝
      // 用户点一下删除就永久丢 LAN 配对/同步基线。
      writeFile(p.join(support.path, 'fushi.db'), 1000);
      writeFile(p.join(support.path, 'fushi.db.sync-preserve.json'), 50);
      writeFile(p.join(support.path, 'fushi.db.pre-restore.bak'), 300);
      writeFile(p.join(support.path, 'fushi.db.corrupt-bak-9.db'), 7);

      final List<StorageCategoryUsage> all = await service().scanCategories(
        books: const <StorageBookRef>[],
        dictionaryNames: const <String>[],
      ).toList();
      final StorageCategoryUsage db = all.singleWhere(
          (StorageCategoryUsage u) => u.id == StorageCategoryId.database);
      final StorageEntryUsage snapshots = db.entries.singleWhere(
          (StorageEntryUsage e) =>
              e.kind == StorageEntryKind.databaseSnapshots);
      expect(snapshots.paths.map(p.basename).toSet(),
          <String>{'fushi.db.corrupt-bak-9.db'});
      // 只命中新库名 ⇒ label 不带并列括号。
      expect(snapshots.label, 'support/fushi.db.*');
      expect(
        db.entries
            .where((StorageEntryUsage e) => e.kind == StorageEntryKind.readOnly)
            .map((StorageEntryUsage e) => e.label)
            .toSet(),
        containsAll(<String>[
          'support/fushi.db.sync-preserve.json',
          'support/fushi.db.pre-restore.bak',
        ]),
      );
    });

    test('BUG-1870 审查：sidecar 已消失的 pre-restore.bak 是孤儿，可删', () async {
      writeFile(p.join(support.path, 'fushi.db'), 1000);
      writeFile(p.join(support.path, 'fushi.db.pre-restore.bak'), 300);

      final List<StorageCategoryUsage> all = await service().scanCategories(
        books: const <StorageBookRef>[],
        dictionaryNames: const <String>[],
      ).toList();
      final StorageCategoryUsage db = all.singleWhere(
          (StorageCategoryUsage u) => u.id == StorageCategoryId.database);
      final StorageEntryUsage snapshots = db.entries.singleWhere(
          (StorageEntryUsage e) =>
              e.kind == StorageEntryKind.databaseSnapshots);
      expect(snapshots.paths.map(p.basename).toSet(),
          <String>{'fushi.db.pre-restore.bak'});
      expect(snapshots.bytes, 300);
    });

    test('无快照残留时 database 明细不出现空的聚合条目', () async {
      writeFile(p.join(support.path, 'fushi.db'), 1000);
      writeFile(p.join(support.path, 'fushi.db-wal'), 100);

      final List<StorageCategoryUsage> all = await service().scanCategories(
        books: const <StorageBookRef>[],
        dictionaryNames: const <String>[],
      ).toList();
      final StorageCategoryUsage db = all.singleWhere(
          (StorageCategoryUsage u) => u.id == StorageCategoryId.database);
      expect(
        db.entries.map((StorageEntryUsage e) => e.kind).toSet(),
        <StorageEntryKind>{StorageEntryKind.readOnly},
      );
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
