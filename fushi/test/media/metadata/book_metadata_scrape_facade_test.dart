import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/metadata/book_metadata_scrape_facade.dart';
import 'package:fushi/src/media/metadata/book_metadata_scraper.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../ops/book_metadata_test_fixture.dart';

/// [BookMetadataScrapeFacade]：从弹窗搬出来的候选解析规则 + 写回 / 快照 / 恢复。

/// 只取可见候选（门面只暴露 [BookMetadataScrapeFacade.searchDetailed]：弹窗与控制
/// 通道都走它）。
Future<List<BookScrapeCandidate>> _search(
  BookMetadataScrapeFacade facade, {
  required BookScrapeSource source,
  required String query,
}) async =>
    (await facade.searchDetailed(source: source, query: query)).candidates;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('search（原弹窗的候选解析规则）', () {
    test('贴 Bangumi 条目 URL = 按 id 直取，不走关键词搜索', () async {
      final BookMetadataScrapeFacade facade = BookMetadataScrapeFacade(
        scraper: offlineScraper(
          subjects: <String, Map<String, Object?>>{
            '42': bangumiSubject('42', 'Direct'),
          },
          searchHits: <Map<String, Object?>>[bangumiSubject('9', 'Searched')],
        ),
      );
      final List<BookScrapeCandidate> got = await _search(
        facade,
        source: BookScrapeSource.bangumi,
        query: 'https://bgm.tv/subject/42',
      );
      expect(got.map((BookScrapeCandidate c) => c.subjectId), <String>['42']);
    });

    test('纯数字：搜索 + id 直取并列，直取置顶、按 id 去重', () async {
      final BookMetadataScrapeFacade facade = BookMetadataScrapeFacade(
        scraper: offlineScraper(
          subjects: <String, Map<String, Object?>>{
            '1984': bangumiSubject('1984', 'By id'),
          },
          searchHits: <Map<String, Object?>>[
            bangumiSubject('7', 'Nineteen'),
            bangumiSubject('1984', 'By id'),
          ],
        ),
      );
      final List<BookScrapeCandidate> got = await _search(
        facade,
        source: BookScrapeSource.bangumi,
        query: '1984',
      );
      expect(got.map((BookScrapeCandidate c) => c.subjectId), <String>[
        '1984',
        '7',
      ]);
    });

    test('空词不发请求', () async {
      final BookMetadataScrapeFacade facade = BookMetadataScrapeFacade(
        scraper: offlineScraper(),
      );
      expect(
        await _search(facade, source: BookScrapeSource.bangumi, query: '  '),
        isEmpty,
      );
    });
  });

  // BUG-5372：书架单卷名原词零结果时按源的粒度改写重搜，命中即停。
  group('searchDetailed 改写重搜', () {
    /// Bangumi 桩：只有 [hit] 这个词有结果；记下每次搜的 keyword。
    BookMetadataScrapeFacade bangumiOnly(
      String hit,
      List<String> keywords, {
      int status = 200,
    }) => BookMetadataScrapeFacade(
      scraper: BookMetadataScraper(
        client: MockClient((http.Request req) async {
          final Object? body = req.body.isEmpty ? null : jsonDecode(req.body);
          final String keyword = body is Map ? '${body['keyword']}' : '';
          keywords.add(keyword);
          if (status != 200) return http.Response('', status);
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'data': <Object?>[
                  if (keyword == hit) bangumiSubject('1', 'Hit'),
                ],
              }),
            ),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
    );

    test('原词零结果：依次试「名 卷号」→ 名，命中即停并报实际用的词', () async {
      final List<String> keywords = <String>[];
      final BookScrapeSearchResult got = await bangumiOnly('ホリミヤ', keywords)
          .searchDetailed(
            source: BookScrapeSource.bangumi,
            query: 'Horimiya ホリミヤ 第01巻',
          );
      expect(keywords, <String>['Horimiya ホリミヤ 第01巻', 'ホリミヤ 1', 'ホリミヤ']);
      expect(got.query, 'ホリミヤ');
      expect(got.candidates.single.subjectId, '1');
    });

    test('原词有结果：只搜一次，query 不变', () async {
      final List<String> keywords = <String>[];
      final BookScrapeSearchResult got = await bangumiOnly(
        '进击的巨人 第1卷',
        keywords,
      ).searchDetailed(source: BookScrapeSource.bangumi, query: '进击的巨人 第1卷');
      expect(keywords, <String>['进击的巨人 第1卷']);
      expect(got.query, '进击的巨人 第1卷');
    });

    test('全都零结果：空结果，query 是原词', () async {
      final List<String> keywords = <String>[];
      final BookScrapeSearchResult got = await bangumiOnly(
        'nothing',
        keywords,
      ).searchDetailed(source: BookScrapeSource.bangumi, query: '龍珠 第1集');
      expect(keywords, <String>['龍珠 第1集', '龍珠 1', '龍珠']);
      expect(got.candidates, isEmpty);
      expect(got.query, '龍珠 第1集');
    });

    test('请求出错：直接抛出，不拿改写词接着打', () async {
      final List<String> keywords = <String>[];
      await expectLater(
        bangumiOnly(
          'x',
          keywords,
          status: 500,
        ).searchDetailed(source: BookScrapeSource.bangumi, query: 'ホリミヤ 第01巻'),
        throwsA(anything),
      );
      expect(keywords, hasLength(1));
    });

    test('searchQueriesFor：系列源去卷号；ISBN / URL / 纯数字 / 无粒度源不改写', () {
      expect(
        BookMetadataScrapeFacade.searchQueriesFor(
          BookScrapeSource.mangabaka,
          'Horimiya ホリミヤ 第01巻',
        ),
        <String>['Horimiya ホリミヤ', 'ホリミヤ', 'Horimiya'],
      );
      for (final String q in <String>[
        '9784757541734',
        'ISBN 978-4-7575-4173-4',
        'https://bgm.tv/subject/42',
        '1984',
      ]) {
        expect(
          BookMetadataScrapeFacade.searchQueriesFor(BookScrapeSource.ndl, q),
          <String>[q],
          reason: q,
        );
      }
      expect(
        BookMetadataScrapeFacade.searchQueriesFor(
          BookScrapeSource.dlsite,
          'ホリミヤ 第01巻',
        ),
        <String>['ホリミヤ 第01巻'],
      );
    });
  });

  group('NSFW 候选跟随作品 NSFW 标记（拍板台 pr3497）', () {
    BookMetadataScrapeFacade mixed() => BookMetadataScrapeFacade(
      scraper: offlineScraper(
        subjects: <String, Map<String, Object?>>{
          '12': <String, Object?>{
            ...bangumiSubject('12', 'Adult work'),
            'nsfw': true,
          },
        },
        searchHits: <Map<String, Object?>>[
          bangumiSubject('11', 'Plain'),
          <String, Object?>{
            ...bangumiSubject('12', 'Adult work'),
            'nsfw': true,
          },
        ],
      ),
    );

    test('默认藏 NSFW 候选并报条数；includeNsfw 全回', () async {
      final BookScrapeSearchResult hidden = await mixed().searchDetailed(
        source: BookScrapeSource.bangumi,
        query: 'x',
      );
      expect(
        <String>[
          for (final BookScrapeCandidate c in hidden.candidates) c.subjectId,
        ],
        <String>['11'],
      );
      expect(hidden.hiddenNsfw, 1);

      final BookScrapeSearchResult all = await mixed().searchDetailed(
        source: BookScrapeSource.bangumi,
        query: 'x',
        includeNsfw: true,
      );
      expect(all.candidates, hasLength(2));
      expect(all.candidates.last.isAdult, isTrue);
      expect(all.hiddenNsfw, 0);
    });

    test('贴 id 直取到的 NSFW 条目同样跟随规则', () async {
      final BookScrapeSearchResult got = await mixed().searchDetailed(
        source: BookScrapeSource.bangumi,
        query: 'https://bgm.tv/subject/12',
      );
      expect(got.candidates, isEmpty);
      expect(got.hiddenNsfw, 1);
    });

    test('isNsfwHost：书自己标了 / 在 NSFW 合集里才算；认不出的书不算', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      const BookNsfwHost host = (kind: TagHostKind.epub, entryKey: 'nsfw-book');
      expect(await BookMetadataScrapeFacade.isNsfwHost(db, host), isFalse);
      expect(await BookMetadataScrapeFacade.isNsfwHost(db, null), isFalse);
      await db.setMediaNsfw(TagHostKind.epub, 'nsfw-book', true);
      expect(await BookMetadataScrapeFacade.isNsfwHost(db, host), isTrue);
    });
  });

  group('isSongForItem（导入的歌曲默认 iTunes）', () {
    late FushiDatabase db;

    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    MediaItem itemFor(String identifier) => MediaItem(
      mediaIdentifier: identifier,
      title: 'Lemon',
      mediaTypeIdentifier: 'reader',
      mediaSourceIdentifier: 'reader_fushi',
      position: 0,
      duration: 0,
      canDelete: true,
      canEdit: true,
    );

    Future<void> srtBook(String uid, String srtPath) => db.upsertSrtBook(
      SrtBooksCompanion.insert(
        uid: uid,
        title: 'Lemon',
        srtPath: srtPath,
        importedAt: 0,
      ),
    );

    test('字幕书：字幕文件是 .lrc 才算歌曲（大小写不敏感）', () async {
      await srtBook('song', 'C:/music/Lemon.LRC');
      await srtBook('drama', 'C:/books/drama.srt');
      expect(
        await BookMetadataScrapeFacade.isSongForItem(
          db,
          itemFor(ReaderFushiSource.mediaIdentifierForSrtUid('song')),
        ),
        isTrue,
      );
      expect(
        await BookMetadataScrapeFacade.isSongForItem(
          db,
          itemFor(ReaderFushiSource.mediaIdentifierForSrtUid('drama')),
        ),
        isFalse,
      );
      expect(
        await BookMetadataScrapeFacade.isSongForItem(
          db,
          itemFor(ReaderFushiSource.mediaIdentifierForSrtUid('missing')),
        ),
        isFalse,
      );
    });

    test('EPUB 有声书：对齐格式 lrc 算歌曲；smil / 没挂有声书不算', () async {
      await db.upsertAudiobook(
        AudiobooksCompanion.insert(
          bookKey: 'epub-song',
          alignmentFormat: 'lrc',
          alignmentPath: 'C:/a/song.lrc',
        ),
      );
      await db.upsertAudiobook(
        AudiobooksCompanion.insert(
          bookKey: 'epub-novel',
          alignmentFormat: 'smil',
          alignmentPath: 'C:/a/novel.smil',
        ),
      );
      Future<bool> isSong(String key) => BookMetadataScrapeFacade.isSongForItem(
        db,
        itemFor(ReaderFushiSource.mediaIdentifierFor(key)),
      );
      expect(await isSong('epub-song'), isTrue);
      expect(await isSong('epub-novel'), isFalse);
      expect(await isSong('epub-plain'), isFalse);
    });
  });

  group('applyToBook / restore', () {
    late FushiDatabase db;
    late Directory thumbs;
    late BookMetaTestModel model;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      final PreferencesRepository prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      thumbs = await Directory.systemTemp.createTemp('fushi_facade_');
      model = BookMetaTestModel(db, prefs, thumbs);
      MediaSource.setDatabase(db);
    });

    tearDown(() async {
      await db.close();
      if (thumbs.existsSync()) await thumbs.delete(recursive: true);
    });

    Future<MediaItem> book(String key, {String? author}) async {
      await seedBook(db, key, author: author);
      return (await ReaderFushiSource.instance.mediaItemForBookKey(key))!;
    }

    File image(int seed) =>
        File('${thumbs.path}/src_$seed.jpg')..writeAsBytesSync(fakeJpeg(seed));

    test('换封面先留备份；restore 拷回旧图并删备份', () async {
      final MediaItem item = await book('facade-cover');
      final BookMetadataScrapeFacade facade = BookMetadataScrapeFacade();
      await facade.applyToBook(appModel: model, item: item, cover: image(1));
      final BookMetadataState original = await facade.currentState(
        appModel: model,
        item: item,
      );
      expect(original.coverSha, isNotNull);

      final BookMetadataApplyResult result = await facade.applyToBook(
        appModel: model,
        item: item,
        cover: image(2),
        keepBackup: true,
      );
      expect(result.applied, <BookMetadataField>{BookMetadataField.cover});
      expect(result.after.coverSha, isNot(original.coverSha));
      final String backup = result.before.coverBackupPath!;
      expect(File(backup).existsSync(), isTrue);

      await facade.restore(
        appModel: model,
        item: item,
        snapshot: BookMetadataSnapshot.fromJson(result.before.toJson()),
        fields: result.applied,
      );
      expect(
        (await facade.currentState(appModel: model, item: item)).coverSha,
        original.coverSha,
      );
      expect(File(backup).existsSync(), isFalse);
    });

    test('旧封面（修改时间早于保留期）的备份按建立时刻算保留期，下次清理不删', () async {
      final MediaItem item = await book('facade-old-cover');
      final BookMetadataScrapeFacade facade = BookMetadataScrapeFacade();
      await facade.applyToBook(appModel: model, item: item, cover: image(7));
      // 这张封面已经用了 40 天：复制出来的备份会沿用这个修改时间。
      ReaderFushiSource.instance
          .resolveOverrideThumbnailFile(appModel: model, item: item)!
          .setLastModifiedSync(
            DateTime.now().subtract(const Duration(days: 40)),
          );
      final BookMetadataApplyResult result = await facade.applyToBook(
        appModel: model,
        item: item,
        cover: image(8),
        keepBackup: true,
      );
      final File backup = File(result.before.coverBackupPath!);
      expect(
        backup.lastModifiedSync().isAfter(
          DateTime.now().subtract(BookMetadataScrapeFacade.backupRetention),
        ),
        isTrue,
      );

      // 另一本书再留一次备份 → 触发清理；上一份备份必须还在，撤销才做得成。
      final MediaItem other = await book('facade-old-cover-2');
      await facade.applyToBook(appModel: model, item: other, cover: image(9));
      await facade.applyToBook(
        appModel: model,
        item: other,
        cover: image(10),
        keepBackup: true,
      );
      expect(backup.existsSync(), isTrue);
      await facade.restore(
        appModel: model,
        item: item,
        snapshot: result.before,
        fields: result.applied,
      );
    });

    test('执行前没有 override 封面：不留备份，restore 清除', () async {
      final MediaItem item = await book('facade-nocover');
      final BookMetadataScrapeFacade facade = BookMetadataScrapeFacade();
      final BookMetadataApplyResult result = await facade.applyToBook(
        appModel: model,
        item: item,
        cover: image(3),
        keepBackup: true,
      );
      expect(result.before.coverBackupPath, isNull);
      expect(result.before.state.coverSha, isNull);
      await facade.restore(
        appModel: model,
        item: item,
        snapshot: result.before,
        fields: result.applied,
      );
      expect(
        (await facade.currentState(appModel: model, item: item)).coverSha,
        isNull,
      );
    });

    test('图片校验不过：不算写回、旧图不动、备份删掉', () async {
      final MediaItem item = await book('facade-bad');
      final BookMetadataScrapeFacade facade = BookMetadataScrapeFacade();
      await facade.applyToBook(appModel: model, item: item, cover: image(4));
      final String? before = (await facade.currentState(
        appModel: model,
        item: item,
      )).coverSha;
      final File bad = File('${thumbs.path}/bad.jpg')
        ..writeAsStringSync('<html>not an image</html>');
      final BookMetadataApplyResult result = await facade.applyToBook(
        appModel: model,
        item: item,
        cover: bad,
        keepBackup: true,
      );
      expect(result.applied, isEmpty);
      expect(result.before.coverBackupPath, isNull);
      expect(result.after.coverSha, before);
      final Directory backups = Directory('${thumbs.path}/undo_backups');
      expect(
        backups.existsSync() ? backups.listSync() : const <FileSystemEntity>[],
        isEmpty,
      );
    });

    test('显示名 / 作者写回与恢复（显示名原本没有 → 恢复成清除）', () async {
      final MediaItem item = await book('facade-text', author: '旧作者');
      final BookMetadataScrapeFacade facade = BookMetadataScrapeFacade();
      final BookMetadataApplyResult result = await facade.applyToBook(
        appModel: model,
        item: item,
        title: '新标题',
        author: '新作者',
      );
      expect(result.applied, <BookMetadataField>{
        BookMetadataField.title,
        BookMetadataField.author,
      });
      expect(result.after.overrideTitle, '新标题');
      expect(result.after.author, '新作者');
      expect((await db.getEpubBook('facade-text'))!.author, '新作者');

      await facade.restore(
        appModel: model,
        item: item,
        snapshot: result.before,
        fields: result.applied,
      );
      final BookMetadataState now = await facade.currentState(
        appModel: model,
        item: item,
      );
      expect(now.overrideTitle, isNull);
      expect(now.author, '旧作者');
    });

    test('有封面但备份已不在：restore 抛 StateError，不拿别的图凑数', () async {
      final MediaItem item = await book('facade-lost');
      final BookMetadataScrapeFacade facade = BookMetadataScrapeFacade();
      await facade.applyToBook(appModel: model, item: item, cover: image(5));
      final BookMetadataApplyResult result = await facade.applyToBook(
        appModel: model,
        item: item,
        cover: image(6),
        keepBackup: true,
      );
      File(result.before.coverBackupPath!).deleteSync();
      expect(
        () => facade.restore(
          appModel: model,
          item: item,
          snapshot: result.before,
          fields: result.applied,
        ),
        throwsStateError,
      );
    });
  });
}
