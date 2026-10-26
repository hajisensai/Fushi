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

import '../../ops/book_metadata_test_fixture.dart';

/// [BookMetadataScrapeFacade]：从弹窗搬出来的候选解析规则 + 写回 / 快照 / 恢复。
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
      final List<BookScrapeCandidate> got = await facade.search(
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
      final List<BookScrapeCandidate> got = await facade.search(
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
        await facade.search(source: BookScrapeSource.bangumi, query: '  '),
        isEmpty,
      );
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
