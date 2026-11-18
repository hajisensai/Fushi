import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/metadata/book_art_store.dart';
import 'package:image/image.dart' as img;

/// 刮削层存储：写 / 读 / 横幅投票 / 清除回收孤儿横幅 / 快照撤销往返。
List<int> png(int width, int height, {int shade = 0}) => img.encodePng(
  img.Image(width: width, height: height)
    ..clear(img.ColorRgb8(shade, shade, shade)),
);

BookArtRecord record(
  String bookKey, {
  String? bannerKey,
  String source = 'mangabaka',
  int scrapedAt = 1,
}) => BookArtRecord(
  bookKey: bookKey,
  source: source,
  seriesId: '42',
  seriesTitle: 'Series',
  coverSource: source,
  coverUrl: 'https://images.example/$bookKey',
  bannerKey: bannerKey,
  scrapedAt: scrapedAt,
);

void main() {
  // 写盘 / 清除都会驱逐解码缓存（ImageCache 要 binding）。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory thumbs;
  late BookArtStore store;

  setUp(() async {
    BookArtStore.resetForTesting();
    thumbs = await Directory.systemTemp.createTemp('fushi_book_art_store_');
    store = BookArtStore.of(thumbs);
  });

  tearDown(() async {
    BookArtStore.resetForTesting();
    if (thumbs.existsSync()) await thumbs.delete(recursive: true);
  });

  test('写入后 hasCover / coverFileFor / recordFor 命中；重开实例从磁盘读回', () async {
    expect(store.hasCover('a'), isFalse);
    await store.write(record: record('a'), coverBytes: png(4, 6));
    expect(store.hasCover('a'), isTrue);
    expect(store.coverFileFor('a')!.existsSync(), isTrue);
    expect(store.recordFor('a')!.seriesId, '42');
    expect(store.recordFor('a')!.usesMangaBaka, isTrue);

    BookArtStore.resetForTesting();
    final BookArtStore reopened = BookArtStore.of(thumbs);
    expect(reopened.hasCover('a'), isTrue);
    expect(reopened.recordFor('a')!.coverUrl, 'https://images.example/a');
  });

  test('解码不了的字节不落盘，旧卷封面不动', () async {
    await store.write(record: record('a'), coverBytes: png(4, 6, shade: 9));
    final List<int> before = store.coverFileFor('a')!.readAsBytesSync();
    await expectLater(
      store.write(record: record('a'), coverBytes: <int>[1, 2, 3, 4]),
      throwsA(anything),
    );
    expect(store.coverFileFor('a')!.readAsBytesSync(), before);
  });

  test('合集横幅按成员多数票；单本横幅取自己的', () async {
    await store.writeBanner('mangabaka_1', png(16, 9));
    await store.writeBanner('mangabaka_2', png(16, 9, shade: 50));
    await store.write(record: record('a', bannerKey: 'mangabaka_1'));
    await store.write(record: record('b', bannerKey: 'mangabaka_2'));
    await store.write(record: record('c', bannerKey: 'mangabaka_2'));
    expect(
      store.backdropForCollection(<String>['a', 'b', 'c'])!.path,
      store.bannerPathFor('mangabaka_2'),
    );
    expect(
      store.backdropForBook('a')!.path,
      store.bannerPathFor('mangabaka_1'),
    );
    expect(store.backdropForCollection(<String>['zzz']), isNull);
  });

  test('清除一本：卷封面与元数据删掉，没人引用的横幅一起回收', () async {
    await store.writeBanner('mangabaka_1', png(16, 9));
    await store.write(
      record: record('a', bannerKey: 'mangabaka_1'),
      coverBytes: png(4, 6),
    );
    await store.write(record: record('b', bannerKey: 'mangabaka_1'));
    await store.remove('a');
    expect(store.hasCover('a'), isFalse);
    expect(store.recordFor('a'), isNull);
    expect(File(store.bannerPathFor('mangabaka_1')).existsSync(), isTrue);
    await store.remove('b');
    expect(File(store.bannerPathFor('mangabaka_1')).existsSync(), isFalse);
  });

  test('快照 → 覆盖写 → 恢复：卷封面字节与元数据回到快照', () async {
    await store.write(
      record: record('a', scrapedAt: 1),
      coverBytes: png(4, 6, shade: 1),
    );
    final List<int> original = store.coverFileFor('a')!.readAsBytesSync();
    final BookArtSnapshot snap = await store.snapshot('a');
    await store.write(
      record: record('a', scrapedAt: 2, source: 'bangumi'),
      coverBytes: png(8, 12, shade: 200),
    );
    final Map<String, Object?> after = await store.fingerprint('a');
    expect(after['scrapedAt'], 2);

    // 快照过 JSON 往返（撤销载荷持久化后同一形态）。
    await store.restore(BookArtSnapshot.fromJson(snap.toJson()));
    expect(store.coverFileFor('a')!.readAsBytesSync(), original);
    expect(store.recordFor('a')!.scrapedAt, 1);
    expect(store.recordFor('a')!.source, 'mangabaka');
    expect(await store.fingerprint('a'), isNot(after));
  });

  test('从无到有的写入，恢复 = 清除', () async {
    final BookArtSnapshot snap = await store.snapshot('a');
    await store.write(record: record('a'), coverBytes: png(4, 6));
    await store.restore(snap);
    expect(store.hasCover('a'), isFalse);
    expect(store.recordFor('a'), isNull);
  });

  test('备份文件不在时恢复抛 StateError，不拿别的图凑数', () async {
    await store.write(record: record('a'), coverBytes: png(4, 6));
    final BookArtSnapshot snap = await store.snapshot('a');
    await File(snap.coverBackupPath!).delete();
    await expectLater(store.restore(snap), throwsStateError);
  });

  test('清除后撤销：横幅随快照恢复（清除时它因无人引用被回收）', () async {
    await store.writeBanner('mangabaka_1', png(16, 9));
    await store.write(
      record: record('a', bannerKey: 'mangabaka_1'),
      coverBytes: png(4, 6),
    );
    final BookArtSnapshot snap = await store.snapshot('a');
    await store.remove('a');
    expect(File(store.bannerPathFor('mangabaka_1')).existsSync(), isFalse);
    expect(store.canRestore(snap), isTrue);
    await store.restore(BookArtSnapshot.fromJson(snap.toJson()));
    expect(store.backdropForBook('a'), isNotNull);
    expect(store.hasCover('a'), isTrue);
  });

  test('备份按文件名时间戳过期，不看 copy 继承来的修改时间', () async {
    await store.write(record: record('a'), coverBytes: png(4, 6));
    await store.write(record: record('b'), coverBytes: png(4, 6, shade: 3));
    // 封面写于很久以前：File.copy 在 Windows / macOS 上会把这个修改时间带给备份。
    final DateTime old = DateTime(2020);
    await File(store.coverPathFor('a')).setLastModified(old);
    await File(store.coverPathFor('b')).setLastModified(old);
    final BookArtSnapshot first = await store.snapshot('a');
    // 第二本的 snapshot 会先 prune：不能把第一本刚做的备份当过期删掉。
    await store.snapshot('b');
    expect(File(first.coverBackupPath!).existsSync(), isTrue);
    expect(store.canRestore(first), isTrue);
  });

  test('持有中的横幅不被回收（记录还没落盘）', () async {
    await store.writeBanner('mangabaka_9', png(16, 9));
    final void Function() release = store.holdBanner('mangabaka_9');
    await store.write(record: record('x'), coverBytes: png(4, 6));
    await store.remove('x'); // 触发回收
    expect(File(store.bannerPathFor('mangabaka_9')).existsSync(), isTrue);
    release();
    await store.collectOrphanBanners();
    expect(File(store.bannerPathFor('mangabaka_9')).existsSync(), isFalse);
  });

  test('单本否决：卷封面删掉，只留否决记录；JSON 往返保留', () async {
    await store.write(record: record('a'), coverBytes: png(4, 6));
    await store.rejectCover('a');
    expect(store.hasCover('a'), isFalse);
    expect(store.recordFor('a')!.hasSeries, isFalse);
    expect(store.recordFor('a')!.rejectedCoverUrls, <String>[
      'https://images.example/a',
    ]);
    BookArtStore.resetForTesting();
    final BookArtStore reopened = BookArtStore.of(thumbs);
    expect(reopened.recordFor('a')!.rejectedCoverUrls, <String>[
      'https://images.example/a',
    ]);
  });

  test('编辑弹窗展示的记录：有卷封面或只有横幅都算，只剩否决记录不算', () async {
    expect(store.displayableRecordFor('none'), isNull);

    await store.write(record: record('cover'), coverBytes: png(4, 6));
    expect(store.displayableRecordFor('cover')!.seriesId, '42');

    // 本地更清晰时只写了横幅：没有卷封面文件，仍要能看到来源 / 署名并移除。
    await store.writeBanner('mangabaka_1', png(16, 9));
    await store.write(
      record: BookArtRecord(
        bookKey: 'banner',
        source: 'mangabaka',
        seriesId: '42',
        seriesTitle: 'Series',
        bannerKey: 'mangabaka_1',
        scrapedAt: 1,
      ),
    );
    expect(store.hasCover('banner'), isFalse);
    expect(store.displayableRecordFor('banner')!.usesMangaBaka, isTrue);

    await store.rejectCover('cover');
    expect(store.recordFor('cover'), isNotNull);
    expect(store.displayableRecordFor('cover'), isNull);
  });
}
