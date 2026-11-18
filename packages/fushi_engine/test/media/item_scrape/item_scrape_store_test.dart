import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/cover_file_writer.dart';
import 'package:fushi_engine/media/item_scrape/item_scrape_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// [ItemScrapeStore]：v161 条目刮削资料 / 附加图的唯一写入口——资料整行写 / 合并写、
/// 附加图原子落盘 + 登记、换图回收旧文件、宿主删除后按「不被任何行引用」回收。
void main() {
  late FushiDatabase db;
  late Directory dir;
  late Directory scratch;
  late ItemScrapeStore store;

  // 最小 GIF：写侧判据只查 "GIF8" 头（尾部无固定标记）。
  final List<int> gif = <int>[
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0, 0, 0, 0x3B, //
  ];

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('item_images_');
    scratch = Directory.systemTemp.createTempSync('item_src_');
    store = ItemScrapeStore(
      db,
      imagesDirectory: dir,
      now: () => DateTime.fromMillisecondsSinceEpoch(1234),
      downloadImage: (String url) async {
        final File f = File(p.join(scratch.path, 'dl_${url.hashCode}.gif'));
        await f.writeAsBytes(gif);
        return f;
      },
    );
  });

  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
    scratch.deleteSync(recursive: true);
  });

  File source(String name) =>
      File(p.join(scratch.path, name))..writeAsBytesSync(gif);

  final ItemScrapeKey book = ItemScrapeKey(MediaKind.epub, 'uid-1');

  test('writeMeta 落库：标签折成与合集同形的 JSON，写入时刻取 now', () async {
    await store.writeMeta(
      book,
      const ItemScrapeDetails(
        source: 'bangumi',
        subjectId: '9',
        summary: '  简介  ',
        airDate: '2014-04',
        rating: 7.5,
        tags: <String>['恋爱', '日常'],
      ),
    );
    final ItemScrapeMetaRow row = (await db.getItemScrapeMeta(
      MediaKind.epub,
      'uid-1',
    ))!;
    expect(row.summary, '简介');
    expect(row.tagsJson, '[{"name":"恋爱"},{"name":"日常"}]');
    expect(decodeItemScrapeTags(row.tagsJson), <String>['恋爱', '日常']);
    expect(row.scrapedAt, 1234);
  });

  test('mergeMeta 只覆盖给了的字段', () async {
    await store.writeMeta(
      book,
      const ItemScrapeDetails(
        source: 'bangumi',
        summary: 'old',
        rating: 7,
        tags: <String>['a'],
      ),
    );
    await store.mergeMeta(
      book,
      const ItemScrapeDetails(source: ItemScrapeStore.manualSource, rating: 9),
    );
    final ItemScrapeMetaRow row = (await db.getItemScrapeMeta(
      MediaKind.epub,
      'uid-1',
    ))!;
    expect(row.summary, 'old');
    expect(row.rating, 9);
    expect(row.source, 'manual');
    expect(decodeItemScrapeTags(row.tagsJson), <String>['a']);
  });

  test('setImageFromFile 落盘到目录内并登记；换扩展名回收旧文件', () async {
    final String first = await store.setImageFromFile(
      book,
      MediaImageKind.backdrop,
      source('a.png'),
    );
    expect(p.isWithin(dir.path, first), isTrue);
    expect(File(first).existsSync(), isTrue);
    final String second = await store.setImageFromFile(
      book,
      MediaImageKind.backdrop,
      source('b.gif'),
    );
    expect(second, isNot(first));
    expect(File(first).existsSync(), isFalse, reason: '旧图随换图回收');
    expect(
      (await db.getItemImages(MediaKind.epub, 'uid-1')).single.path,
      second,
    );
  });

  test('坏图拒写：抛 CoverImageInvalidException，不登记', () async {
    final File bad = File(p.join(scratch.path, 'bad.jpg'))
      ..writeAsStringSync('<html>');
    await expectLater(
      store.setImageFromFile(book, MediaImageKind.backdrop, bad),
      throwsA(isA<CoverImageInvalidException>()),
    );
    expect(await db.getAllItemImages(), isEmpty);
  });

  test('applyScrape：资料 + URL 背景一起落，sourceUrl 记下', () async {
    await store.applyScrape(
      ItemScrapeKey(MediaKind.game, 'g1'),
      const ItemScrapeDetails(source: 'vndb', subjectId: 'v1'),
      backdropUrl: 'https://example.invalid/shot.jpg',
    );
    final ItemImageRow row = (await db.getItemImages(
      MediaKind.game,
      'g1',
    )).single;
    expect(row.kind, MediaImageKind.backdrop.dbValue);
    expect(row.sourceUrl, 'https://example.invalid/shot.jpg');
    expect(File(row.path).existsSync(), isTrue);
  });

  test('删宿主后 reclaimUnreferencedFiles 只删没人引用的文件', () async {
    final String kept = await store.setImageFromFile(
      ItemScrapeKey(MediaKind.game, 'keep'),
      MediaImageKind.backdrop,
      source('k.gif'),
    );
    final String gone = await store.setImageFromFile(
      book,
      MediaImageKind.logo,
      source('l.png'),
    );
    await db.deleteItemScrapeDataFor(MediaKind.epub, <String>['uid-1']);
    expect(await store.reclaimUnreferencedFiles(), 1);
    expect(File(kept).existsSync(), isTrue);
    expect(File(gone).existsSync(), isFalse);
  });

  test('ItemScrapeKey 拒收 video 与空键', () {
    expect(() => ItemScrapeKey(MediaKind.video, 'v'), throwsArgumentError);
    expect(() => ItemScrapeKey(MediaKind.epub, ''), throwsArgumentError);
  });
}
