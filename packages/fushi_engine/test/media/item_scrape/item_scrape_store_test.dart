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

  test('setUserImageFromFile 落盘到目录内并登记；换扩展名回收旧文件', () async {
    final String first = await store.setUserImageFromFile(
      book,
      MediaImageKind.backdrop,
      source('a.png'),
    );
    expect(p.isWithin(dir.path, first), isTrue);
    expect(File(first).existsSync(), isTrue);
    final String second = await store.setUserImageFromFile(
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
      store.setUserImageFromFile(book, MediaImageKind.backdrop, bad),
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
    final String kept = await store.setUserImageFromFile(
      ItemScrapeKey(MediaKind.game, 'keep'),
      MediaImageKind.backdrop,
      source('k.gif'),
    );
    final String gone = await store.setUserImageFromFile(
      book,
      MediaImageKind.logo,
      source('l.png'),
    );
    await db.deleteItemScrapeDataFor(MediaKind.epub, <String>['uid-1']);
    expect(await store.reclaimUnreferencedFiles(), 1);
    expect(File(kept).existsSync(), isTrue);
    expect(File(gone).existsSync(), isFalse);
  });

  // BUG-5609：「获取各卷封面与横幅」把同一张系列横幅贴到每一卷：只存一份文件，
  // 各卷一行指向它；换图 / 清图时随最后一行回收，别的条目还在用就留着。
  test('writeScrapedSharedImageFromFile：同 URL 共用一个文件，最后一行撤掉才回收', () async {
    const String url = 'https://images.mangabaka.dev/banner/1';
    final ItemScrapeKey a = ItemScrapeKey(MediaKind.epub, 'uid-a');
    final ItemScrapeKey b = ItemScrapeKey(MediaKind.epub, 'uid-b');
    final String pathA = (await store.writeScrapedSharedImageFromFile(
      a,
      MediaImageKind.backdrop,
      source('banner.gif'),
      sourceUrl: url,
    ))!;
    final String pathB = (await store.writeScrapedSharedImageFromFile(
      b,
      MediaImageKind.backdrop,
      source('banner.gif'),
      sourceUrl: url,
    ))!;
    expect(pathB, pathA);
    expect(p.basename(pathA), startsWith('epub_shared_'));
    expect(
      p.basename(pathA),
      isNot(
        p.basename(
          itemImageFileName(a, MediaImageKind.backdrop, File('x.gif')),
        ),
      ),
    );
    final ItemImageRow row = (await store.firstImage(
      a,
      MediaImageKind.backdrop,
    ))!;
    expect(row.path, pathA);
    expect(row.sourceUrl, url);

    // a 换成用户自己选的图：共用文件 b 还在用。
    final String own = await store.setUserImageFromFile(
      a,
      MediaImageKind.backdrop,
      source('own.gif'),
      sourceUrl: 'https://s4.anilist.co/banner/1.jpg',
    );
    expect(own, isNot(pathA));
    expect(File(pathA).existsSync(), isTrue);

    expect(await store.clearScrapedImage(b, MediaImageKind.backdrop), isTrue);
    expect(await store.firstImage(b, MediaImageKind.backdrop), isNull);
    expect(File(pathA).existsSync(), isFalse);
    expect(File(own).existsSync(), isTrue);
  });

  // 获取按并发 3 逐卷落盘：各卷同时贴同一张图，只复制一次，一卷都不能丢（各自
  // 「不在 → 复制 → 改名」在 Windows 上撞目标已存在，曾让并发的那几卷失败）。
  test('writeScrapedSharedImageFromFile：多卷并发贴同一张图全部成功', () async {
    const String url = 'https://images.mangabaka.dev/banner/9';
    final List<ItemScrapeKey> keys = <ItemScrapeKey>[
      for (int i = 0; i < 6; i++) ItemScrapeKey(MediaKind.epub, 'uid-$i'),
    ];
    final List<String?> paths = await Future.wait(<Future<String?>>[
      for (final ItemScrapeKey k in keys)
        store.writeScrapedSharedImageFromFile(
          k,
          MediaImageKind.backdrop,
          source('banner_${k.entryKey}.gif'),
          sourceUrl: url,
        ),
    ]);
    expect(paths.toSet(), hasLength(1));
    for (final ItemScrapeKey k in keys) {
      expect(
        (await store.firstImage(k, MediaImageKind.backdrop))?.path,
        paths.first,
      );
    }
    expect(
      dir.listSync().whereType<File>().map((File f) => p.basename(f.path)),
      <String>[p.basename(paths.first!)],
    );
  });

  test('writeScrapedSharedImageFromFile：源不是完整图片时抛，旧图不动', () async {
    final ItemScrapeKey a = ItemScrapeKey(MediaKind.epub, 'uid-a');
    final String old = (await store.writeScrapedImageFromFile(
      a,
      MediaImageKind.backdrop,
      source('old.gif'),
    ))!;
    final File broken = File(p.join(scratch.path, 'broken.png'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    await expectLater(
      store.writeScrapedSharedImageFromFile(
        a,
        MediaImageKind.backdrop,
        broken,
        sourceUrl: 'https://images.mangabaka.dev/banner/x',
      ),
      throwsA(isA<CoverImageInvalidException>()),
    );
    expect((await store.firstImage(a, MediaImageKind.backdrop))!.path, old);
  });

  // BUG-5609 审查：共用文件「已在就复用」与行的登记之间曾有空当——同时撤掉最后
  // 一行（或回收扫描）的一方看到零引用就删文件，复用方随后插进的行指向一个不存在
  // 的文件。现在「确保文件 + 登记行」与「确认无引用 + 删」在同一把文件锁里互斥。
  test('共用文件：并发撤掉最后一行 / 回收与另一卷复用同一张图，行永不指向缺失文件', () async {
    const String url = 'https://images.mangabaka.dev/banner/race';
    final ItemScrapeKey a = ItemScrapeKey(MediaKind.epub, 'uid-a');
    final ItemScrapeKey b = ItemScrapeKey(MediaKind.epub, 'uid-b');
    for (int round = 0; round < 12; round++) {
      await store.clearScrapedImage(b, MediaImageKind.backdrop);
      await store.writeScrapedSharedImageFromFile(
        a,
        MediaImageKind.backdrop,
        source('banner_a.gif'),
        sourceUrl: url,
      );
      final File reuseSource = source('banner_b.gif');
      // 每轮换一种起跑先后，覆盖不同的交错。
      Future<void> later(int ticks, Future<void> Function() body) async {
        for (int i = 0; i < ticks; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        await body();
      }

      await Future.wait(<Future<void>>[
        later(
          round % 3,
          () => store.clearScrapedImage(a, MediaImageKind.backdrop),
        ),
        later(
          (round ~/ 3) % 2,
          () => store.writeScrapedSharedImageFromFile(
            b,
            MediaImageKind.backdrop,
            reuseSource,
            sourceUrl: url,
          ),
        ),
        later(round % 2, () => store.reclaimUnreferencedFiles()),
      ]);
      final ItemImageRow? row = await store.firstImage(
        b,
        MediaImageKind.backdrop,
      );
      expect(row, isNotNull, reason: 'round $round');
      expect(File(row!.path).existsSync(), isTrue, reason: 'round $round');
    }
  });

  // BUG-5609 审查：「书没有背景图才贴」的判断与写入必须原子，不能先读再写——中间
  // 插进来的书籍刮削 / 手选会被覆盖。条件写拿着本格的锁判断。
  test('条件写：判断与写入之间插不进别的写入，先来的单本背景图不被覆盖', () async {
    const String url = 'https://images.mangabaka.dev/banner/cond';
    for (int round = 0; round < 6; round++) {
      final ItemScrapeKey k = ItemScrapeKey(MediaKind.epub, 'uid-c$round');
      String? shared;
      late String own;
      Future<void> later(int ticks, Future<void> Function() body) async {
        for (int i = 0; i < ticks; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        await body();
      }

      await Future.wait(<Future<void>>[
        later(round % 3, () async {
          shared = await store.writeScrapedSharedImageFromFile(
            k,
            MediaImageKind.backdrop,
            source('shared_$round.gif'),
            sourceUrl: url,
            when: (ItemImageRow? current) => current == null,
          );
        }),
        later(round ~/ 3, () async {
          own = (await store.writeScrapedImageFromFile(
            k,
            MediaImageKind.backdrop,
            source('own_$round.gif'),
            sourceUrl: 'https://s4.anilist.co/banner/$round.jpg',
          ))!;
        }),
      ]);
      // 两种先后都以单本背景图收场：条件写先到则被它覆盖，后到则不写。
      final ItemImageRow row = (await store.firstImage(
        k,
        MediaImageKind.backdrop,
      ))!;
      expect(row.path, own, reason: 'round $round');
      expect(File(own).existsSync(), isTrue);
      if (shared != null) expect(p.basename(shared!), startsWith('epub_'));
    }
    final ItemScrapeKey taken = ItemScrapeKey(MediaKind.epub, 'uid-taken');
    await store.writeScrapedImageFromFile(
      taken,
      MediaImageKind.backdrop,
      source('taken.gif'),
    );
    expect(
      await store.writeScrapedSharedImageFromFile(
        taken,
        MediaImageKind.backdrop,
        source('x.gif'),
        sourceUrl: url,
        when: (ItemImageRow? current) => current == null,
      ),
      isNull,
    );
    expect(
      await store.clearScrapedImage(
        taken,
        MediaImageKind.backdrop,
        when: (ItemImageRow? current) => current?.sourceUrl == url,
      ),
      isFalse,
    );
    expect(await store.firstImage(taken, MediaImageKind.backdrop), isNotNull);
  });

  // BUG-5609 审查：批量贴图的归属按共用文件名认，不按 source_url——单本刮削 / 手选
  // 恰好用了同一个 URL 也不会被认成共用图（否则「清除」会撤掉用户自己的背景图）。
  test('isItemSharedImageRow：共用文件名才算，同 URL 的单条目图不算', () async {
    const String url = 'https://images.mangabaka.dev/banner/own';
    final ItemScrapeKey a = ItemScrapeKey(MediaKind.epub, 'uid-a');
    final ItemScrapeKey b = ItemScrapeKey(MediaKind.epub, 'uid-b');
    await store.writeScrapedSharedImageFromFile(
      a,
      MediaImageKind.backdrop,
      source('shared.png'),
      sourceUrl: url,
    );
    await store.setUserImageFromFile(
      b,
      MediaImageKind.backdrop,
      source('picked.gif'),
      sourceUrl: url,
    );
    expect(
      isItemSharedImageRow(
        (await store.firstImage(a, MediaImageKind.backdrop))!,
      ),
      isTrue,
    );
    expect(
      isItemSharedImageRow(
        (await store.firstImage(b, MediaImageKind.backdrop))!,
      ),
      isFalse,
    );
  });

  test('ItemScrapeKey 拒收 video 与空键', () {
    expect(() => ItemScrapeKey(MediaKind.video, 'v'), throwsArgumentError);
    expect(() => ItemScrapeKey(MediaKind.epub, ''), throwsArgumentError);
  });

  group('v177 字段锁（BUG-5111 书的简介手填）', () {
    const Map<ItemScrapeLockableField, String?> typed =
        <ItemScrapeLockableField, String?>{
          ItemScrapeLockableField.summary: '  我写的简介  ',
        };
    const Map<ItemScrapeLockableField, String?> cleared =
        <ItemScrapeLockableField, String?>{
          ItemScrapeLockableField.summary: '   ',
        };

    Future<ItemScrapeMetaRow?> read() =>
        db.getItemScrapeMeta(book.mediaType, book.entryKey);

    test('锁列编解码：未知值忽略、空集合 = NULL', () {
      expect(parseItemScrapeLockedFields(null), isEmpty);
      expect(
        parseItemScrapeLockedFields(' , future ,summary'),
        <ItemScrapeLockableField>{ItemScrapeLockableField.summary},
      );
      expect(
        encodeItemScrapeLockedFields(const <ItemScrapeLockableField>{}),
        isNull,
      );
      expect(
        encodeItemScrapeLockedFields(<ItemScrapeLockableField>{
          ItemScrapeLockableField.summary,
        }),
        'summary',
      );
    });

    test('刮不到资料的书：手填新建 manual 行并上锁', () async {
      expect(await store.setManualFields(book, typed), isTrue);
      final ItemScrapeMetaRow row = (await read())!;
      expect(row.source, ItemScrapeStore.manualSource);
      expect(row.summary, '我写的简介');
      expect(row.lockedFields, 'summary');
    });

    test('手填后重刮：简介不被覆盖、锁保留，其余字段照常更新', () async {
      await store.writeMeta(
        book,
        const ItemScrapeDetails(source: 'bangumi', summary: '刮来的', rating: 6),
      );
      await store.setManualFields(book, typed);
      await store.writeMeta(
        book,
        const ItemScrapeDetails(source: 'dlsite', summary: '新刮的', rating: 8),
      );
      final ItemScrapeMetaRow row = (await read())!;
      expect(row.summary, '我写的简介');
      expect(row.lockedFields, 'summary');
      expect(row.source, 'dlsite');
      expect(row.rating, 8);
    });

    test('清空 = 解锁：下一次刮削回填简介', () async {
      await store.writeMeta(
        book,
        const ItemScrapeDetails(source: 'bangumi', summary: '刮来的'),
      );
      await store.setManualFields(book, typed);
      expect(await store.setManualFields(book, cleared), isTrue);
      ItemScrapeMetaRow row = (await read())!;
      expect(row.summary, isNull);
      expect(row.lockedFields, isNull);
      await store.writeMeta(
        book,
        const ItemScrapeDetails(source: 'bangumi', summary: '刮来的'),
      );
      row = (await read())!;
      expect(row.summary, '刮来的');
    });

    test('只有手填的行清空后删行（回到未刮削）；没改动返回 false', () async {
      await store.setManualFields(book, typed);
      expect(await store.setManualFields(book, typed), isFalse);
      expect(await store.setManualFields(book, cleared), isTrue);
      expect(await read(), isNull);
      expect(await store.setManualFields(book, cleared), isFalse);
      expect(await read(), isNull);
    });

    test('脚本整行替换 / 合并写：值照写，锁保留；撤销快照原样写回', () async {
      await store.setManualFields(book, typed);
      await store.writeMeta(
        book,
        const ItemScrapeDetails(source: 'manual', summary: 'AI 改的'),
        overrideLocked: true,
      );
      ItemScrapeMetaRow row = (await read())!;
      expect(row.summary, 'AI 改的');
      expect(row.lockedFields, 'summary');

      await store.mergeMeta(
        book,
        const ItemScrapeDetails(source: 'manual', summary: '再改'),
      );
      row = (await read())!;
      expect(row.summary, '再改');
      expect(row.lockedFields, 'summary');

      await store.restoreMeta(
        book,
        const ItemScrapeDetails(source: 'bangumi', summary: '快照'),
      );
      row = (await read())!;
      expect(row.summary, '快照');
      expect(row.lockedFields, isNull, reason: '快照里没锁就原样无锁');
    });
  });

  group('v183 附加图来源锁（用户选的横幅不被刮削覆盖）', () {
    Future<ItemImageRow> backdropRow() async => (await db.getItemImages(
      MediaKind.epub,
      'uid-1',
    )).singleWhere((ItemImageRow r) => r.kind == 'backdrop');

    test('刮削写入：没有用户图时照常落库，记为刮削来源', () async {
      final String? path = await store.writeScrapedImageFromFile(
        book,
        MediaImageKind.backdrop,
        source('s.gif'),
        sourceUrl: 'https://example.invalid/s.gif',
      );
      expect(path, isNotNull);
      final ItemImageRow row = await backdropRow();
      expect(row.userChosen, isFalse);
      expect(row.path, path);
      expect(await store.isUserChosen(book, MediaImageKind.backdrop), isFalse);
    });

    test('用户写入替换刮削图并上锁；之后刮削写入（文件 / URL / applyScrape）全跳过', () async {
      final String scraped = (await store.writeScrapedImageFromFile(
        book,
        MediaImageKind.backdrop,
        source('s.gif'),
      ))!;
      final String mine = await store.setUserImageFromFile(
        book,
        MediaImageKind.backdrop,
        source('mine.gif'),
      );
      expect(mine, isNot(scraped), reason: '用户图文件名带 _user，与刮削图分开');
      expect(File(scraped).existsSync(), isFalse, reason: '被换掉的刮削图回收');
      expect((await backdropRow()).userChosen, isTrue);

      int downloads = 0;
      final ItemScrapeStore counting = ItemScrapeStore(
        db,
        imagesDirectory: dir,
        downloadImage: (String url) async {
          downloads++;
          return File(p.join(scratch.path, 'never.gif'))..writeAsBytesSync(gif);
        },
      );
      expect(
        await counting.writeScrapedImageFromFile(
          book,
          MediaImageKind.backdrop,
          source('s2.gif'),
        ),
        isNull,
      );
      expect(
        await counting.writeScrapedImageFromUrl(
          book,
          MediaImageKind.backdrop,
          'https://example.invalid/new.jpg',
        ),
        isNull,
      );
      await counting.applyScrape(
        book,
        const ItemScrapeDetails(source: 'anilist', subjectId: '1'),
        backdropUrl: 'https://example.invalid/banner.jpg',
      );
      expect(downloads, 0, reason: '锁住时连下载都省掉');
      final ItemImageRow row = await backdropRow();
      expect(row.path, mine);
      expect(row.userChosen, isTrue);
      expect(File(mine).existsSync(), isTrue);
      expect(
        (await db.getItemScrapeMeta(MediaKind.epub, 'uid-1'))!.subjectId,
        '1',
        reason: '锁只管图，资料照常写',
      );
      expect(
        await store.clearScrapedImage(book, MediaImageKind.backdrop),
        isFalse,
        reason: '刮削写回的撤销不清用户图',
      );
      expect(File(mine).existsSync(), isTrue);
    });

    test('用户再换一张仍生效；移除 = 解锁，刮削可以再写', () async {
      await store.setUserImageFromFile(
        book,
        MediaImageKind.backdrop,
        source('a.gif'),
      );
      final String second = await store.setUserImageFromUrl(
        book,
        MediaImageKind.backdrop,
        'https://example.invalid/b.gif',
      );
      ItemImageRow row = await backdropRow();
      expect(row.path, second);
      expect(row.sourceUrl, 'https://example.invalid/b.gif');
      expect(row.userChosen, isTrue);

      await store.clearUserImage(book, MediaImageKind.backdrop);
      expect(await db.getItemImages(MediaKind.epub, 'uid-1'), isEmpty);
      expect(File(second).existsSync(), isFalse);
      expect(
        await store.writeScrapedImageFromFile(
          book,
          MediaImageKind.backdrop,
          source('s.gif'),
        ),
        isNotNull,
      );
      row = await backdropRow();
      expect(row.userChosen, isFalse);
    });

    test('锁按种类：用户选了 backdrop 不挡 logo 的刮削写入', () async {
      await store.setUserImageFromFile(
        book,
        MediaImageKind.backdrop,
        source('a.gif'),
      );
      expect(
        await store.writeScrapedImageFromFile(
          book,
          MediaImageKind.logo,
          source('l.gif'),
        ),
        isNotNull,
      );
    });

    test('数据库层：刮削口径的替换在事务里查锁，撞上用户图返回 null 不动行', () async {
      await db.replaceItemImagesOfKind(
        mediaType: MediaKind.epub,
        entryKey: 'uid-1',
        kind: MediaImageKind.backdrop,
        images: const <({String path, String? sourceUrl})>[
          (path: '/u.jpg', sourceUrl: null),
        ],
        userChosen: true,
      );
      expect(
        await db.replaceScrapedItemImagesOfKind(
          mediaType: MediaKind.epub,
          entryKey: 'uid-1',
          kind: MediaImageKind.backdrop,
          images: const <({String path, String? sourceUrl})>[
            (path: '/s.jpg', sourceUrl: null),
          ],
        ),
        isNull,
      );
      expect((await backdropRow()).path, '/u.jpg');
      expect(
        await db.hasUserChosenItemImage(
          MediaKind.epub,
          'uid-1',
          MediaImageKind.backdrop,
        ),
        isTrue,
      );
    });

    test('撤销快照：备份 → 用户换图 → 写回原图与原来源（刮削图写回仍是刮削来源）', () async {
      final Directory backups = Directory(p.join(scratch.path, 'undo'));
      await store.writeScrapedImageFromFile(
        book,
        MediaImageKind.backdrop,
        source('orig.gif'),
        sourceUrl: 'https://example.invalid/orig.gif',
      );
      final ItemImageBackup backup = (await store.backupImage(
        book,
        MediaImageKind.backdrop,
        backups,
      ))!;
      expect(backup.userChosen, isFalse);
      await store.setUserImageFromFile(
        book,
        MediaImageKind.backdrop,
        source('ai.gif'),
      );
      await store.restoreImage(
        book,
        MediaImageKind.backdrop,
        ItemImageBackup.fromJson(backup.toJson()),
      );
      final ItemImageRow row = await backdropRow();
      expect(row.userChosen, isFalse);
      expect(row.sourceUrl, 'https://example.invalid/orig.gif');
      expect(File(row.path).existsSync(), isTrue);
      expect(File(backup.path).existsSync(), isFalse, reason: '备份写回后删掉');

      expect(
        await store.backupImage(book, MediaImageKind.logo, backups),
        isNull,
      );
      await store.restoreImage(book, MediaImageKind.backdrop, null);
      expect(await db.getItemImages(MediaKind.epub, 'uid-1'), isEmpty);
    });

    // 批量贴横幅（BUG-5609）与旧数据搬家、撤销都走刮削口径的共用写 / 条件清：用户
    // 选的图在格锁里、`when` 之前就让路，`when` 根本看不到它，也不留下孤儿共用文件。
    test('共用写 / 条件清（获取横幅）遇用户图整格让路，when 不被调用', () async {
      const String url = 'https://images.mangabaka.dev/banner/locked';
      final String mine = await store.setUserImageFromFile(
        book,
        MediaImageKind.backdrop,
        source('mine.gif'),
        sourceUrl: url,
      );
      int asked = 0;
      expect(
        await store.writeScrapedSharedImageFromFile(
          book,
          MediaImageKind.backdrop,
          source('banner.gif'),
          sourceUrl: url,
          when: (ItemImageRow? _) {
            asked++;
            return true;
          },
        ),
        isNull,
      );
      expect(
        await store.writeScrapedSharedImageFromFile(
          book,
          MediaImageKind.backdrop,
          source('banner.gif'),
          sourceUrl: url,
        ),
        isNull,
      );
      expect(
        await store.clearScrapedImage(
          book,
          MediaImageKind.backdrop,
          when: (ItemImageRow? _) {
            asked++;
            return true;
          },
        ),
        isFalse,
      );
      expect(asked, 0);
      final ItemImageRow row = await backdropRow();
      expect(row.path, mine);
      expect(row.userChosen, isTrue);
      expect(isItemSharedImageRow(row), isFalse, reason: '同 URL 的用户图不算批量贴的');
      expect(dir.listSync().whereType<File>().map((File f) => f.path), <String>[
        mine,
      ]);
    });

    test('用户写入与共用条件写并发：总以用户图收场，共用文件不残留', () async {
      const String url = 'https://images.mangabaka.dev/banner/race-user';
      for (int round = 0; round < 6; round++) {
        final ItemScrapeKey k = ItemScrapeKey(MediaKind.epub, 'uid-u$round');
        late String mine;
        Future<void> later(int ticks, Future<void> Function() body) async {
          for (int i = 0; i < ticks; i++) {
            await Future<void>.delayed(Duration.zero);
          }
          await body();
        }

        await Future.wait(<Future<void>>[
          later(round % 3, () async {
            await store.writeScrapedSharedImageFromFile(
              k,
              MediaImageKind.backdrop,
              source('shared_$round.gif'),
              sourceUrl: url,
              when: (ItemImageRow? current) => true,
            );
          }),
          later(round ~/ 3, () async {
            mine = await store.setUserImageFromFile(
              k,
              MediaImageKind.backdrop,
              source('mine_$round.gif'),
            );
          }),
        ]);
        final ItemImageRow row = (await store.firstImage(
          k,
          MediaImageKind.backdrop,
        ))!;
        expect(row.path, mine, reason: 'round $round');
        expect(row.userChosen, isTrue, reason: 'round $round');
        expect(
          dir.listSync().whereType<File>().where(
            (File f) => p.basename(f.path).contains('_shared_'),
          ),
          isEmpty,
          reason: 'round $round',
        );
      }
    });

    test('撤销快照：批量贴的共用图写回同一个共用文件，仍认得是批量贴的', () async {
      const String url = 'https://images.mangabaka.dev/banner/undo';
      final ItemScrapeKey other = ItemScrapeKey(MediaKind.epub, 'uid-2');
      final String shared = (await store.writeScrapedSharedImageFromFile(
        book,
        MediaImageKind.backdrop,
        source('banner.gif'),
        sourceUrl: url,
      ))!;
      await store.writeScrapedSharedImageFromFile(
        other,
        MediaImageKind.backdrop,
        source('banner.gif'),
        sourceUrl: url,
      );
      final ItemImageBackup backup = (await store.backupImage(
        book,
        MediaImageKind.backdrop,
        Directory(p.join(scratch.path, 'undo')),
      ))!;
      expect(backup.shared, isTrue);
      await store.setUserImageFromFile(
        book,
        MediaImageKind.backdrop,
        source('ai.gif'),
      );
      await store.restoreImage(
        book,
        MediaImageKind.backdrop,
        ItemImageBackup.fromJson(backup.toJson()),
      );
      final ItemImageRow row = await backdropRow();
      expect(row.path, shared);
      expect(row.userChosen, isFalse);
      expect(isItemSharedImageRow(row), isTrue);
      expect(
        (await store.firstImage(other, MediaImageKind.backdrop))!.path,
        shared,
      );
    });

    test('文件名：用户图带 _user 后缀', () {
      final File src = File('x.png');
      expect(
        itemImageFileName(book, MediaImageKind.backdrop, src),
        endsWith('_backdrop.png'),
      );
      expect(
        itemImageFileName(book, MediaImageKind.backdrop, src, userChosen: true),
        endsWith('_backdrop_user.png'),
      );
    });
  });
}
