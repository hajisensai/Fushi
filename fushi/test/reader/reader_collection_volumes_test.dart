import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart';
import 'package:fushi/src/reader/reader_collection_volumes.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_book.dart';

/// BUG-2521：阅读器「同合集卷」上下文——归属 / 顺序 / 单卷退化 / 孤儿过滤，
/// 以及兄弟卷目录构建与插图文件越界判据。
void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  Future<String> insertEpub(String key, {String format = 'epub'}) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: 'Title $key',
        epubPath: '/$key.epub',
        extractDir: '/extract/$key',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1000,
        format: Value<String>(format),
      ),
    );
    return (await db.resolveEpubBookUid(key))!;
  }

  test('not in any collection → null', () async {
    final String uid = await insertEpub('solo');
    expect(await loadReaderVolumeContext(db, bookUid: uid), isNull);
  });

  test('single-volume collection → null (no switcher)', () async {
    final String uid = await insertEpub('v1');
    final int cid = await db.createMediaCollection('Series');
    await db.addToCollection(cid, MediaKind.epub, uid);
    expect(await loadReaderVolumeContext(db, bookUid: uid), isNull);
  });

  test('multi-volume collection: sortIndex order, current index, orphan and '
      'non-book members filtered, PDF volume kept but not peekable', () async {
    final String v1 = await insertEpub('v1');
    final String v2 = await insertEpub('v2');
    final String v3 = await insertEpub('v3', format: 'pdf');
    final int cid = await db.createMediaCollection('Series');
    await db.addToCollection(cid, MediaKind.epub, v2);
    await db.addToCollection(cid, MediaKind.epub, v1);
    await db.addToCollection(cid, MediaKind.epub, 'gone-uid'); // 孤儿。
    await db.addToCollection(cid, MediaKind.video, 'some-video');
    await db.addToCollection(cid, MediaKind.epub, v3);

    final ReaderVolumeContext? ctx = await loadReaderVolumeContext(
      db,
      bookUid: v1,
    );
    expect(ctx, isNotNull);
    expect(ctx!.collectionId, cid);
    expect(ctx.collectionName, 'Series');
    expect(
      ctx.volumes.map((ReaderVolume v) => v.bookKey).toList(),
      <String>['v2', 'v1', 'v3'],
      reason: '合集内顺序 = sortIndex（加入顺序），不是书名序',
    );
    expect(ctx.currentIndex, 1);
    expect(ctx.current.uid, v1);
    expect(ctx.volumes[0].canPeek, isTrue);
    expect(ctx.volumes[2].canPeek, isFalse, reason: 'PDF 卷只能整卷切过去');
    expect(ctx.volumes[0].extractDir, '/extract/v2');
  });

  test(
    'primary collection = smallest collection id (shelf fold rule)',
    () async {
      final String v1 = await insertEpub('v1');
      final String v2 = await insertEpub('v2');
      final String other = await insertEpub('other');
      final int first = await db.createMediaCollection('First');
      final int second = await db.createMediaCollection('Second');
      await db.addToCollection(first, MediaKind.epub, v1);
      await db.addToCollection(first, MediaKind.epub, v2);
      await db.addToCollection(second, MediaKind.epub, v1);
      await db.addToCollection(second, MediaKind.epub, other);

      final ReaderVolumeContext? ctx = await loadReaderVolumeContext(
        db,
        bookUid: v1,
      );
      expect(ctx!.collectionId, first);
      expect(ctx.volumes.length, 2);
    },
  );

  test('buildTtuTocForBook: no toc → auto chapter labels; toc → flattened', () {
    final EpubBook noToc = EpubBook(
      title: 't',
      chapters: <EpubChapter>[
        EpubChapter(id: 'a', href: 'a.xhtml', mediaType: 'x', html: '<p>a</p>'),
        EpubChapter(id: 'b', href: 'b.xhtml', mediaType: 'x', html: '<p>b</p>'),
      ],
    );
    final List<TtuTocEntry> auto = buildTtuTocForBook(
      noToc,
      autoLabel: (int n) => 'Chapter $n',
    );
    expect(auto.map((TtuTocEntry e) => e.label), <String>[
      'Chapter 1',
      'Chapter 2',
    ]);
    expect(auto.map((TtuTocEntry e) => e.index), <int>[0, 1]);

    final EpubBook withToc = EpubBook(
      title: 't',
      chapters: <EpubChapter>[
        EpubChapter(id: 'a', href: 'a.xhtml', mediaType: 'x', html: '<p>a</p>'),
        EpubChapter(id: 'b', href: 'b.xhtml', mediaType: 'x', html: '<p>b</p>'),
      ],
      toc: <EpubTocItem>[
        EpubTocItem(label: 'One', href: 'a.xhtml'),
        EpubTocItem(label: 'Two', href: 'b.xhtml'),
      ],
    );
    final List<TtuTocEntry> flat = buildTtuTocForBook(
      withToc,
      autoLabel: (int n) => 'x',
    );
    expect(flat.map((TtuTocEntry e) => e.label), <String>['One', 'Two']);
    expect(flat.map((TtuTocEntry e) => e.index), <int>[0, 1]);
  });

  test(
    'volumeImageFile resolves inside the volume dir and rejects escapes',
    () {
      final Directory dir = Directory.systemTemp.createTempSync(
        'reader_volume_img_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/img/a.png').createSync(recursive: true);
      final ReaderVolume volume = ReaderVolume(
        bookKey: 'k',
        uid: 'u',
        title: 't',
        extractDir: dir.path,
        format: BookFormat.epub,
      );
      expect(
        volumeImageFile(
          volume,
          const EpubImageRef(chapterIndex: 0, orderInBook: 0, src: 'img/a.png'),
        )?.path,
        isNotNull,
      );
      expect(
        volumeImageFile(
          volume,
          const EpubImageRef(
            chapterIndex: 0,
            orderInBook: 0,
            src: '../../etc/passwd',
          ),
        ),
        isNull,
        reason: '越界路径必须拒绝（与阅读器 _readerImageFileForUrl 同判据）',
      );
      expect(
        volumeImageFile(
          volume,
          const EpubImageRef(
            chapterIndex: 0,
            orderInBook: 0,
            src: 'img/missing.png',
          ),
        ),
        isNull,
      );
    },
  );
}
