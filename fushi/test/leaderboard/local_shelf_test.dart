import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:fushi_engine/leaderboard/local_shelf.dart';

/// 引擎 `buildLocalShelf`：本机库 + 统计事实面 → 排行榜书架（真内存库，flutter test
/// 下才有 sqlite 原生库）。
void main() {
  late FushiDatabase db;
  const int profile = 1;
  int seq = 0;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    seq = 0;
  });
  tearDown(() => db.close());

  Future<void> segment(
    String kind,
    String key, {
    required String date,
    int chars = 0,
    int ms = 0,
    int profileId = profile,
    String format = '',
  }) => db.upsertStudySegment(
    StudySegmentsCompanion.insert(
      uid: 'seg${seq++}',
      deviceId: 'd',
      mediaKind: kind,
      mediaKey: key,
      format: Value<String>(format),
      title: key,
      startAt: 1000 + seq,
      endAt: 2000 + seq,
      dateKey: date,
      hour: 10,
      durationMs: Value<int>(ms),
      chars: Value<int>(chars),
      updatedAt: 1,
      profileId: Value<int>(profileId),
    ),
  );

  Future<void> book(
    String key, {
    String? author,
    String format = 'epub',
    DateTime? completedAt,
    String? isbn,
    String? sourceMetadata,
    String? coverPath,
  }) => db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: key,
      title: key,
      author: Value<String?>(author),
      coverPath: Value<String?>(coverPath),
      epubPath: '/x/$key.epub',
      extractDir: '/x/$key',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: 0,
      format: Value<String>(format),
      completedAt: Value<DateTime?>(completedAt),
      isbn: Value<String?>(isbn),
      sourceMetadata: Value<String?>(sourceMetadata),
    ),
  );

  Future<void> video(String uid, {DateTime? completedAt, String? cover}) => db
      .into(db.videoBooks)
      .insert(
        VideoBooksCompanion.insert(
          bookUid: uid,
          title: 'file $uid',
          videoPath: '/v/$uid.mkv',
          completedAt: Value<DateTime?>(completedAt),
          coverPath: Value<String?>(cover),
        ),
      );

  Future<void> extension(String pkg, int warning, {String kind = 'manga'}) => db
      .into(db.mangaExtensions)
      .insert(
        MangaExtensionsCompanion.insert(
          packageName: pkg,
          name: pkg,
          versionCode: 1,
          versionName: '1',
          libVersion: '1.4',
          language: 'ja',
          contentWarning: Value<int>(warning),
          apkPath: '$pkg.apk',
          apkSha256: 'x',
          signerSha256: 'y',
          installedAt: 0,
          mediaKind: Value<String>(kind),
        ),
      );

  String onlineManga(String pkg, String key) => jsonEncode(<String, Object?>{
    'type': 'hibiki-online-manga',
    'version': 3,
    'runtime': 'mihon',
    'extensionPackage': pkg,
    'sourceId': '1',
    'series': <String, Object?>{'key': key, 'title': key},
    'chapters': <Object?>[],
  });

  Future<int> scrapedMovie(
    String bookUid, {
    String? contentRating,
    String provider = 'anidb',
  }) async {
    final int w = await db
        .into(db.videoMetadataWorks)
        .insert(
          VideoMetadataWorksCompanion.insert(
            bookUid: Value<String?>(bookUid),
            mediaType: 'movie',
            title: 'T $bookUid',
            contentRating: Value<String?>(contentRating),
            updatedAt: 0,
          ),
        );
    await db
        .into(db.videoMetadataProviderIdentities)
        .insert(
          VideoMetadataProviderIdentitiesCompanion.insert(
            identityKey: 'work:$w:$provider',
            workId: Value<int?>(w),
            provider: provider,
            externalId: 'id_$bookUid',
            isPrimary: const Value<bool>(true),
            updatedAt: 0,
          ),
        );
    return w;
  }

  Map<String, LocalShelfEntry> byKey(LocalShelf s) => <String, LocalShelfEntry>{
    for (final LocalShelfEntry e in s.entries) e.localKey: e,
  };

  group('书 / 漫画', () {
    test('读完或有活动才纳入；refs / 封面 / 读完日 / 字数时长', () async {
      final DateTime done = DateTime(2026, 9, 3, 23, 30);
      await book(
        'Novel',
        author: '作者',
        completedAt: done,
        isbn: '9784040000015',
        coverPath: '/c/novel.jpg',
      );
      await book('Idle'); // 既没读完也没活动：不纳入。
      await book(
        'Online',
        format: 'manga',
        sourceMetadata: jsonEncode(<String, Object?>{
          'type': 'hibiki-online-manga',
          'version': 3,
          'runtime': 'mihon',
          'extensionPackage': 'pkg',
          'sourceId': '123',
          'series': <String, Object?>{
            'key': '/manga/9',
            'title': 'Online',
            'coverUrl': 'https://img.example/9.jpg',
            'raw': <String, Object?>{},
          },
          'chapters': <Object?>[],
        }),
      );
      await book(
        'Peer',
        format: 'manga',
        sourceMetadata: jsonEncode(<String, Object?>{
          'type': 'hibiki-online-manga',
          'version': 3,
          'runtime': 'interconnect',
          'sourceId': 'library',
          'series': <String, Object?>{'key': 'k', 'title': 'Peer'},
          'chapters': <Object?>[],
        }),
      );
      await book(
        'Web Novel',
        sourceMetadata: jsonEncode(<String, Object?>{
          'type': 'fushi-lnreader-online',
          'version': 1,
          'pluginId': 'syosetu',
          'novelPath': 'n1234ab/',
          'chapters': <Object?>[],
        }),
      );
      await db
          .into(db.mediaTrackingMappings)
          .insert(
            MediaTrackingMappingsCompanion.insert(
              mediaType: 'book',
              mediaKey: 'Novel',
              mediaTitle: 'Novel',
              kind: 'novel',
              subjectId: 42,
              subjectName: 'Novel',
              progressMode: 'volume',
              createdAt: 0,
              updatedAt: 0,
            ),
          );
      await segment('book', 'Novel', date: '2026-09-01', chars: 100, ms: 60);
      await segment('book', 'Novel', date: '2026-09-02', chars: 50, ms: 40);
      await segment(
        'book',
        'Online',
        date: '2026-09-02',
        ms: 5,
        format: 'manga',
      );
      await segment('book', 'Peer', date: '2026-09-02', ms: 5, format: 'manga');
      await segment('book', 'Web Novel', date: '2026-09-02', chars: 7);
      // 另一个 Profile 的活动不计入。
      await segment('book', 'Idle', date: '2026-09-02', chars: 9, profileId: 2);

      final LocalShelf shelf = await buildLocalShelf(db, profileId: profile);
      final Map<String, LocalShelfEntry> m = byKey(shelf);
      expect(
        m.keys,
        unorderedEquals(<String>[
          'book:Novel',
          'book:Online',
          'book:Peer',
          'book:Web Novel',
        ]),
      );

      final ShelfEntryUpload novel = m['book:Novel']!.upload;
      expect(novel.kind, LeaderboardKind.book);
      expect(novel.refs, <String>[
        'bgm:42',
        'isbn:9784040000015',
        't:novel|作者',
      ]);
      expect(novel.finished, isTrue);
      expect(novel.finishedAt, done.millisecondsSinceEpoch);
      expect(novel.finishedDate, '2026-09-03');
      expect(novel.chars, 150);
      expect(novel.ms, 100);
      expect(novel.author, '作者');
      expect(m['book:Novel']!.localCoverPath, '/c/novel.jpg');

      final ShelfEntryUpload online = m['book:Online']!.upload;
      expect(online.kind, LeaderboardKind.manga);
      expect(online.finished, isFalse);
      expect(online.refs.first, 'src:123:/manga/9');
      expect(online.coverUrl, 'https://img.example/9.jpg');
      // 互联对端的作品 key 是对端本机身份，不产 src。
      expect(
        m['book:Peer']!.upload.refs.where((String r) => r.startsWith('src:')),
        isEmpty,
      );
      expect(m['book:Web Novel']!.upload.refs.first, 'src:syosetu:n1234ab/');

      // daily：全部种类按日求和（本 Profile）。
      expect(
        shelf.daily.map((DailyCharsUpload d) => '${d.date}=${d.chars}'),
        <String>['2026-09-01=100', '2026-09-02=57'],
      );
    });
  });

  group('nsfw', () {
    test('在线漫画：所属扩展仓库分级 NSFW（≥3）才算；MIXED / 未装 / 普通书为 false', () async {
      await extension('pkg.nsfw', 3);
      await extension('pkg.mixed', 2);
      final DateTime done = DateTime(2026, 9, 1, 12);
      await book(
        'Adult',
        format: 'manga',
        completedAt: done,
        sourceMetadata: onlineManga('pkg.nsfw', '/a'),
      );
      await book(
        'Mixed',
        format: 'manga',
        completedAt: done,
        sourceMetadata: onlineManga('pkg.mixed', '/m'),
      );
      await book(
        'Gone',
        format: 'manga',
        completedAt: done,
        sourceMetadata: onlineManga('pkg.uninstalled', '/g'),
      );
      await book('Plain', completedAt: done);

      final Map<String, LocalShelfEntry> m = byKey(
        await buildLocalShelf(db, profileId: profile),
      );
      expect(m['book:Adult']!.upload.nsfw, isTrue);
      expect(m['book:Mixed']!.upload.nsfw, isFalse);
      expect(m['book:Gone']!.upload.nsfw, isFalse);
      expect(m['book:Plain']!.upload.nsfw, isFalse);
    });

    test('视频：刮削分级成人向（R18+ / Rx）或 Aniyomi 扩展 NSFW 为 true；R+ 不算', () async {
      final DateTime done = DateTime(2026, 8, 1, 12);
      await extension('anime.nsfw', 3, kind: 'anime');
      for (final String uid in <String>['r18', 'rx', 'rplus', 'ext', 'safe']) {
        await video(uid, completedAt: done);
      }
      await (db.update(
        db.videoBooks,
      )..where(($VideoBooksTable v) => v.bookUid.equals('ext'))).write(
        VideoBooksCompanion(
          streamSpecJson: Value<String?>(
            jsonEncode(<String, Object?>{
              'kind': 'anime-source',
              'extensionPackage': 'anime.nsfw',
              'sourceId': '1',
              'anime': <String, Object?>{},
              'episode': <String, Object?>{},
            }),
          ),
        ),
      );
      await scrapedMovie('r18', contentRating: 'R18+');
      await scrapedMovie('rx', contentRating: 'Rx - Hentai', provider: 'mal');
      await scrapedMovie(
        'rplus',
        contentRating: 'R+ - Mild Nudity',
        provider: 'mal',
      );
      await scrapedMovie('ext');
      await scrapedMovie('safe', contentRating: 'PG-13', provider: 'mal');

      final Map<String, LocalShelfEntry> m = byKey(
        await buildLocalShelf(db, profileId: profile),
      );
      bool nsfw(String uid) => m['video:b$uid']!.upload.nsfw;
      expect(nsfw('r18'), isTrue);
      expect(nsfw('rx'), isTrue);
      expect(nsfw('rplus'), isFalse);
      expect(nsfw('ext'), isTrue);
      expect(nsfw('safe'), isFalse);
    });

    test('isAdultVideoContentRating 与刮削协调器同口径', () {
      expect(isAdultVideoContentRating('R18+'), isTrue);
      expect(isAdultVideoContentRating(' rx - hentai'), isTrue);
      expect(isAdultVideoContentRating('R+ - Mild Nudity'), isFalse);
      expect(isAdultVideoContentRating(null), isFalse);
    });
  });

  group('视频', () {
    test('作品单位：剧 = 刮削合集、电影 = 单片、无作品按主合集、再无按单片', () async {
      final DateTime d1 = DateTime(2026, 8, 1, 12);
      final DateTime d2 = DateTime(2026, 8, 5, 12);
      // 剧：合集 c1 有刮削作品，两集都看完。
      await video('e1', completedAt: d1);
      await video('e2', completedAt: d2);
      // 电影：单片有刮削作品。
      await video('movie', completedAt: d1, cover: '/c/movie.jpg');
      // 无作品的合集：一集看完一集没看完 → 在读。
      await video('p1', completedAt: d1);
      await video('p2');
      // 孤片：有活动。
      await video('solo');
      // 无活动也没看完：不纳入。
      await video('idle');
      final int c1 = await db
          .into(db.mediaCollections)
          .insert(
            MediaCollectionsCompanion.insert(
              name: '剧合集',
              createdAt: 0,
              coverPath: const Value<String?>('/c/show.jpg'),
            ),
          );
      final int c2 = await db
          .into(db.mediaCollections)
          .insert(MediaCollectionsCompanion.insert(name: '播放列表', createdAt: 0));
      for (final (int c, String uid) in <(int, String)>[
        (c1, 'e1'),
        (c1, 'e2'),
        (c2, 'p1'),
        (c2, 'p2'),
      ]) {
        await db
            .into(db.mediaCollectionItems)
            .insert(
              MediaCollectionItemsCompanion.insert(
                collectionId: c,
                mediaType: 'video',
                entryKey: uid,
              ),
            );
      }
      final int showWork = await db
          .into(db.videoMetadataWorks)
          .insert(
            VideoMetadataWorksCompanion.insert(
              collectionId: Value<int?>(c1),
              mediaType: 'tv',
              title: 'ぼっち・ざ・ろっく！',
              updatedAt: 0,
            ),
          );
      final int movieWork = await db
          .into(db.videoMetadataWorks)
          .insert(
            VideoMetadataWorksCompanion.insert(
              bookUid: const Value<String?>('movie'),
              mediaType: 'movie',
              title: '映画',
              updatedAt: 0,
            ),
          );
      for (final (int w, String provider, String id) in <(int, String, String)>[
        (showWork, 'anidb', '17330'),
        (showWork, 'tmdb', '119100'),
        (showWork, 'mal', '47917'),
        (showWork, 'bangumi', '328609'),
        (movieWork, 'tmdb', '555'),
      ]) {
        await db
            .into(db.videoMetadataProviderIdentities)
            .insert(
              VideoMetadataProviderIdentitiesCompanion.insert(
                identityKey: 'work:$w:$provider',
                workId: Value<int?>(w),
                provider: provider,
                externalId: id,
                updatedAt: 0,
              ),
            );
      }
      await db
          .into(db.videoMetadataImages)
          .insert(
            VideoMetadataImagesCompanion.insert(
              workId: Value<int?>(showWork),
              provider: 'tmdb',
              kind: 'cover',
              position: const Value<int>(1),
              remoteUrl: 'https://image.tmdb.org/t/p/w500/b.jpg',
              updatedAt: 0,
            ),
          );
      await db
          .into(db.videoMetadataImages)
          .insert(
            VideoMetadataImagesCompanion.insert(
              workId: Value<int?>(showWork),
              provider: 'tmdb',
              kind: 'cover',
              remoteUrl: 'https://image.tmdb.org/t/p/w500/a.jpg',
              updatedAt: 0,
            ),
          );
      await segment('video', 'e1', date: '2026-08-01', chars: 30, ms: 1000);
      await segment('video', 'e2', date: '2026-08-05', chars: 20, ms: 500);
      await segment('video', 'solo', date: '2026-08-06', ms: 10);
      // 播放列表：p1 有活动 → 整个单位在读（p2 没看完，不算读完）。
      await segment('video', 'p1', date: '2026-08-06', ms: 10);

      final Map<String, LocalShelfEntry> m = byKey(
        await buildLocalShelf(db, profileId: profile),
      );
      // 播放列表 c2 与孤片 solo 没刮削过：标题只能是合集名 / 文件名，不上报。
      expect(m.keys, unorderedEquals(<String>['video:c$c1', 'video:bmovie']));

      final LocalShelfEntry show = m['video:c$c1']!;
      expect(show.upload.title, 'ぼっち・ざ・ろっく！');
      expect(show.upload.refs, <String>[
        'bgm:328609',
        'anidb:17330',
        'mal:47917',
        'tmdb:tv:119100',
        't:ぼっち・ざ・ろっく!|',
      ]);
      expect(show.upload.finished, isTrue);
      expect(show.upload.finishedAt, d2.millisecondsSinceEpoch);
      expect(show.upload.chars, 50);
      expect(show.upload.ms, 1500);
      expect(show.upload.coverUrl, 'https://image.tmdb.org/t/p/w500/a.jpg');
      expect(show.localCoverPath, '/c/show.jpg');

      final LocalShelfEntry movie = m['video:bmovie']!;
      expect(movie.upload.refs.first, 'tmdb:movie:555');
      expect(movie.upload.finished, isTrue);
      expect(movie.localCoverPath, '/c/movie.jpg');
    });

    group('剧集读完 = 看完整部（服务端合并同一作品取「任一读完」）', () {
      Future<int> tvWork({int? collectionId, String? bookUid}) async {
        final int w = await db
            .into(db.videoMetadataWorks)
            .insert(
              VideoMetadataWorksCompanion.insert(
                collectionId: Value<int?>(collectionId),
                bookUid: Value<String?>(bookUid),
                mediaType: 'tv',
                title: 'リトルウィッチアカデミア',
                updatedAt: 0,
              ),
            );
        await db
            .into(db.videoMetadataProviderIdentities)
            .insert(
              VideoMetadataProviderIdentitiesCompanion.insert(
                identityKey: 'work:$w:anidb',
                workId: Value<int?>(w),
                provider: 'anidb',
                externalId: '12346',
                isPrimary: const Value<bool>(true),
                updatedAt: 0,
              ),
            );
        return w;
      }

      /// 季集骨架：[bound] 的第 i 个元素绑到第 i+1 集（null = 本地没有这一集）。
      Future<void> skeleton(
        int work,
        List<String?> bound, {
        int season = 1,
      }) async {
        final int s = await db
            .into(db.videoMetadataSeasons)
            .insert(
              VideoMetadataSeasonsCompanion.insert(
                workId: work,
                seasonNumber: season,
                updatedAt: 0,
              ),
            );
        for (int i = 0; i < bound.length; i++) {
          await db
              .into(db.videoMetadataEpisodes)
              .insert(
                VideoMetadataEpisodesCompanion.insert(
                  seasonId: s,
                  episodeNumber: i + 1,
                  bookUid: Value<String?>(bound[i]),
                  updatedAt: 0,
                ),
              );
        }
      }

      Future<int> collectionOf(List<String> uids) async {
        final int c = await db
            .into(db.mediaCollections)
            .insert(
              MediaCollectionsCompanion.insert(name: 'LWA', createdAt: 0),
            );
        for (final String uid in uids) {
          await db
              .into(db.mediaCollectionItems)
              .insert(
                MediaCollectionItemsCompanion.insert(
                  collectionId: c,
                  mediaType: 'video',
                  entryKey: uid,
                ),
              );
        }
        return c;
      }

      test('每集各自刮成剧集作品：看完第 1 集不算看完整部', () async {
        // 用户报告的原始路径：第 1 集看完，第 2 集之后从没打开过。
        await video('ep1', completedAt: DateTime(2026, 9, 26, 12));
        await video('ep2');
        await video('ep3');
        for (final String uid in <String>['ep1', 'ep2', 'ep3']) {
          await skeleton(await tvWork(bookUid: uid), <String?>[
            if (uid == 'ep1') 'ep1' else null,
            if (uid == 'ep2') 'ep2' else null,
            if (uid == 'ep3') 'ep3' else null,
          ]);
        }
        await segment('video', 'ep1', date: '2026-09-26', chars: 1204, ms: 10);

        final Map<String, LocalShelfEntry> m = byKey(
          await buildLocalShelf(db, profileId: profile),
        );
        expect(m.keys, <String>['video:bep1']);
        expect(m['video:bep1']!.upload.finished, isFalse);
        expect(m['video:bep1']!.upload.finishedAt, isNull);
      });

      test('每集各自刮成剧集作品：全部看完才读完，组内每条都带整部的读完时刻', () async {
        final DateTime last = DateTime(2026, 9, 27, 12);
        await video('ep1', completedAt: DateTime(2026, 9, 26, 12));
        await video('ep2', completedAt: last);
        for (final String uid in <String>['ep1', 'ep2']) {
          await skeleton(await tvWork(bookUid: uid), <String?>[
            if (uid == 'ep1') 'ep1' else null,
            if (uid == 'ep2') 'ep2' else null,
          ]);
        }
        final Map<String, LocalShelfEntry> m = byKey(
          await buildLocalShelf(db, profileId: profile),
        );
        for (final String k in <String>['video:bep1', 'video:bep2']) {
          expect(m[k]!.upload.finished, isTrue, reason: k);
          expect(m[k]!.upload.finishedAt, last.millisecondsSinceEpoch);
        }
      });

      test('单个文件刮成剧集作品、没有骨架：看完它不算看完整部', () async {
        await video('ep1', completedAt: DateTime(2026, 9, 26, 12));
        await tvWork(bookUid: 'ep1');
        await segment('video', 'ep1', date: '2026-09-26', ms: 10);
        final Map<String, LocalShelfEntry> m = byKey(
          await buildLocalShelf(db, profileId: profile),
        );
        expect(m['video:bep1']!.upload.finished, isFalse);
      });

      test('合集只下了前两集且都看完：骨架里还有没下的集 → 在读', () async {
        await video('a', completedAt: DateTime(2026, 9, 1));
        await video('b', completedAt: DateTime(2026, 9, 2));
        final int c = await collectionOf(<String>['a', 'b']);
        await skeleton(await tvWork(collectionId: c), <String?>[
          'a',
          'b',
          null,
        ]);
        await segment('video', 'a', date: '2026-09-01', ms: 10);
        final Map<String, LocalShelfEntry> m = byKey(
          await buildLocalShelf(db, profileId: profile),
        );
        expect(m['video:c$c']!.upload.finished, isFalse);
      });

      test('正片全部看完即读完；季 0 特典没看不影响', () async {
        final DateTime last = DateTime(2026, 9, 3);
        await video('a', completedAt: DateTime(2026, 9, 1));
        await video('b', completedAt: last);
        await video('sp');
        final int c = await collectionOf(<String>['a', 'b', 'sp']);
        final int w = await tvWork(collectionId: c);
        await skeleton(w, <String?>['a', 'b']);
        await skeleton(w, <String?>['sp'], season: 0);
        final Map<String, LocalShelfEntry> m = byKey(
          await buildLocalShelf(db, profileId: profile),
        );
        expect(m['video:c$c']!.upload.finished, isTrue);
        expect(m['video:c$c']!.upload.finishedAt, last.millisecondsSinceEpoch);
      });
    });

    test('没刮削过的视频不上报：本地索引的临时作品（provider local）同样不算', () async {
      await video('a1', completedAt: DateTime(2026, 8, 1, 12));
      await video('b1', completedAt: DateTime(2026, 8, 1, 12));
      Future<int> collection(String name) => db
          .into(db.mediaCollections)
          .insert(MediaCollectionsCompanion.insert(name: name, createdAt: 0));
      final int local = await collection('Season 1');
      final int scraped = await collection('[Group] Show S01 1080p');
      for (final (int c, String uid) in <(int, String)>[
        (local, 'a1'),
        (scraped, 'b1'),
      ]) {
        await db
            .into(db.mediaCollectionItems)
            .insert(
              MediaCollectionItemsCompanion.insert(
                collectionId: c,
                mediaType: 'video',
                entryKey: uid,
              ),
            );
      }
      Future<void> work(int c, String title, String provider, String id) async {
        final int w = await db
            .into(db.videoMetadataWorks)
            .insert(
              VideoMetadataWorksCompanion.insert(
                collectionId: Value<int?>(c),
                mediaType: 'tv',
                title: title,
                updatedAt: 0,
              ),
            );
        await db
            .into(db.videoMetadataProviderIdentities)
            .insert(
              VideoMetadataProviderIdentitiesCompanion.insert(
                identityKey: 'work:$w:$provider',
                workId: Value<int?>(w),
                provider: provider,
                externalId: id,
                isPrimary: const Value<bool>(true),
                updatedAt: 0,
              ),
            );
      }

      // 本地索引出的临时作品：标题就是文件夹名。
      await work(local, 'Season 1', 'local', 'Season 1');
      // 刮削过但没有强 ID（历史资料源）：作品标题来自资料源，照常上报。
      await work(scraped, '葬送のフリーレン', 'douban', '36014526');

      final Map<String, LocalShelfEntry> m = byKey(
        await buildLocalShelf(db, profileId: profile),
      );
      expect(m.keys, <String>['video:c$scraped']);
      expect(m['video:c$scraped']!.upload.title, '葬送のフリーレン');
      expect(m['video:c$scraped']!.upload.refs, <String>['t:葬送のフリーレン|']);
    });
  });

  group('服务端同口径', () {
    test('越界读完时刻降级为「读完、日期未知」；控制字符标题丢弃；其余条目不受连累', () async {
      final DateTime now = DateTime.utc(2026, 9, 28, 12);
      await book('Ancient', completedAt: DateTime(1990, 1, 1));
      await book(
        'Future',
        completedAt: now.add(const Duration(days: 1)).toLocal(),
      );
      await book('Fine', completedAt: DateTime(2026, 9, 1, 12));
      await book('\u0001', completedAt: DateTime(2026, 9, 1, 12));
      final Map<String, LocalShelfEntry> m = byKey(
        await buildLocalShelf(db, profileId: profile, now: now),
      );
      expect(
        m.keys,
        unorderedEquals(<String>['book:Ancient', 'book:Future', 'book:Fine']),
      );
      for (final String k in <String>['book:Ancient', 'book:Future']) {
        final ShelfEntryUpload u = m[k]!.upload;
        expect(u.finished, isTrue, reason: k);
        expect(u.finishedAt, isNull, reason: k);
        expect(u.finishedDate, isNull, reason: k);
      }
      expect(
        m['book:Fine']!.upload.finishedAt,
        DateTime(2026, 9, 1, 12).millisecondsSinceEpoch,
      );
    });

    test('标题 / 作者按服务端上限截断', () async {
      await book(
        'Long',
        author: 'a' * 250,
        completedAt: DateTime(2026, 9, 1, 12),
      );
      await db.customStatement(
        "UPDATE epub_books SET title = ? WHERE book_key = 'Long'",
        <Object>['t' * 400],
      );
      final ShelfEntryUpload u = byKey(
        await buildLocalShelf(db, profileId: profile),
      )['book:Long']!.upload;
      expect(u.title, hasLength(300));
      expect(u.author, hasLength(200));
    });
  });

  group('Profile 口径', () {
    Future<void> profiles(int n) async {
      for (int i = 0; i < n; i++) {
        await db.insertProfile(
          ProfilesCompanion.insert(name: 'p$i', createdAt: 0, updatedAt: 0),
        );
      }
    }

    test('多个 Profile：别的 Profile 的作品不上报，谁都没记录的照常上报（BUG-2870）', () async {
      await profiles(2);
      await book('Mine', completedAt: DateTime(2026, 9, 1, 12));
      await book('Theirs', completedAt: DateTime(2026, 9, 1, 12));
      await book('NoFacts', completedAt: DateTime(2026, 9, 1, 12));
      await segment('book', 'Mine', date: '2026-09-01', chars: 5);
      await segment(
        'book',
        'Theirs',
        date: '2026-09-01',
        chars: 5,
        profileId: 2,
      );
      final Map<String, LocalShelfEntry> m = byKey(
        await buildLocalShelf(db, profileId: profile),
      );
      // NoFacts 读完但哪个 Profile 都没记录（标了读完没留统计 / 早于统计域的老书）：
      // 不是别人的书，此前多建一个 Profile 就被整批丢掉。
      expect(m.keys, unorderedEquals(<String>['book:Mine', 'book:NoFacts']));
      expect(m['book:Mine']!.lastActiveAt, isNotNull);
      expect(m['book:NoFacts']!.lastActiveAt, isNull);
    });

    test('谁都没记录的作品只由同机代表 Profile 计入读者数（BUG-2870）', () async {
      await profiles(2);
      await book('Mine', completedAt: DateTime(2026, 9, 1, 12));
      await book('NoFacts', completedAt: DateTime(2026, 9, 1, 12));
      await segment('book', 'Mine', date: '2026-09-01', chars: 5);
      final Map<String, LocalShelfEntry> owner = byKey(
        await buildLocalShelf(db, profileId: profile),
      );
      expect(owner['book:Mine']!.upload.counted, isTrue);
      expect(owner['book:NoFacts']!.upload.counted, isTrue);

      final Map<String, LocalShelfEntry> other = byKey(
        await buildLocalShelf(
          db,
          profileId: profile,
          countsUnattributed: false,
        ),
      );
      // 有学习记录的照常计入（同一本书换配置读完不去重）；只有无主的那份不计入，
      // 但仍上架、仍计入本账户读完数。
      expect(other['book:Mine']!.upload.counted, isTrue);
      expect(other['book:NoFacts']!.upload.counted, isFalse);
      expect(other['book:NoFacts']!.upload.toJson()['counted'], isFalse);
      expect(other['book:NoFacts']!.upload.finished, isTrue);
    });

    test('只有一个 Profile：读完的全部上报（有没有学习记录都算）', () async {
      await profiles(1);
      await book('A', completedAt: DateTime(2026, 9, 1, 12));
      await book('B', completedAt: DateTime(2026, 9, 1, 12));
      final Map<String, LocalShelfEntry> m = byKey(
        await buildLocalShelf(db, profileId: profile),
      );
      expect(m.keys, unorderedEquals(<String>['book:A', 'book:B']));
    });
  });

  group('游戏', () {
    test('玩过 = 读完（日期可未知）、在玩或有活动 = 在读、其余不纳入', () async {
      final int doneAt = DateTime(2026, 7, 7, 8).millisecondsSinceEpoch;
      Future<void> game(String id, int status, {int? completedAt}) => db
          .into(db.galgames)
          .insert(
            GalgamesCompanion.insert(
              id: id,
              name: 'exe_$id',
              exePath: 'C:/g/$id.exe',
              workdir: 'C:/g',
              addedAt: 0,
              playStatus: Value<int>(status),
              completedAt: Value<int?>(completedAt),
              coverPath: Value<String?>('/c/$id.jpg'),
              customDataJson: id == 'g1'
                  ? const Value<String?>('{"developer":"自定义社"}')
                  : const Value<String?>(null),
            ),
          );
      await game('g1', 2, completedAt: doneAt);
      await game('g2', 2);
      await game('g3', 3);
      await game('g4', 1);
      await game('g5', 0);
      await db
          .into(db.galgameSources)
          .insert(
            GalgameSourcesCompanion.insert(
              gameId: 'g1',
              source: 'bgm',
              externalId: const Value<String?>('1234'),
              dataJson: jsonEncode(<String, Object?>{
                'name': 'ゲーム',
                'developer': 'bgm社',
                'nsfw': true,
                'coverUrl': 'https://lain.bgm.tv/pic/cover/l/x.jpg',
              }),
              fetchedAt: 0,
            ),
          );
      await db
          .into(db.galgameSources)
          .insert(
            GalgameSourcesCompanion.insert(
              gameId: 'g1',
              source: 'vndb',
              externalId: const Value<String?>('v99'),
              dataJson: jsonEncode(<String, Object?>{'developer': 'vndb社'}),
              fetchedAt: 0,
            ),
          );
      for (final String id in <String>['g2', 'g3', 'g5']) {
        await db
            .into(db.galgameSources)
            .insert(
              GalgameSourcesCompanion.insert(
                gameId: id,
                source: 'vndb',
                externalId: Value<String?>('v_$id'),
                dataJson: '{}',
                fetchedAt: 0,
              ),
            );
      }
      await db
          .into(db.galgameSessions)
          .insert(
            GalgameSessionsCompanion.insert(
              gameId: 'g5',
              startMs: 0,
              endMs: 60000,
              durationSeconds: 60,
              dateKey: '2026-07-01',
              profileId: const Value<int>(profile),
            ),
          );

      final Map<String, LocalShelfEntry> m = byKey(
        await buildLocalShelf(db, profileId: profile),
      );
      expect(
        m.keys,
        unorderedEquals(<String>['game:g1', 'game:g2', 'game:g3', 'game:g5']),
      );
      final ShelfEntryUpload g1 = m['game:g1']!.upload;
      expect(g1.refs, <String>['bgm:1234', 'vndb:v99', 't:ゲーム|自定义社']);
      expect(g1.title, 'ゲーム');
      expect(g1.author, '自定义社');
      expect(g1.nsfw, isTrue);
      expect(g1.coverUrl, 'https://lain.bgm.tv/pic/cover/l/x.jpg');
      expect(g1.finishedAt, doneAt);
      expect(g1.finishedDate, '2026-07-07');
      expect(m['game:g1']!.localCoverPath, '/c/g1.jpg');

      final ShelfEntryUpload g2 = m['game:g2']!.upload;
      expect(g2.finished, isTrue);
      expect(g2.finishedAt, isNull, reason: '玩过但日期未知');
      // 刮削资料没有名字：用资料源键占位，绝不用本地库名（exe 推出来的）。
      expect(g2.title, 'vndb:v_g2');

      expect(m['game:g3']!.upload.finished, isFalse);
      expect(m['game:g5']!.upload.ms, 60000);
    });
  });

  test('游戏：没有 bgm / vndb 身份（未刮削）的不上报，哪怕玩过或有自定义名', () async {
    Future<void> game(String id, {String? custom}) => db
        .into(db.galgames)
        .insert(
          GalgamesCompanion.insert(
            id: id,
            name: 'local_$id',
            exePath: 'C:/g/$id.exe',
            workdir: 'C:/g',
            addedAt: 0,
            playStatus: const Value<int>(2),
            customDataJson: Value<String?>(custom),
          ),
        );
    await game('plain');
    await game('custom', custom: '{"name":"自定义名"}');
    await game('scraped');
    await db
        .into(db.galgameSources)
        .insert(
          GalgameSourcesCompanion.insert(
            gameId: 'scraped',
            source: 'bgm',
            externalId: const Value<String?>('77'),
            dataJson: jsonEncode(<String, Object?>{'name': 'スクレイプ'}),
            fetchedAt: 0,
          ),
        );
    final Map<String, LocalShelfEntry> m = byKey(
      await buildLocalShelf(db, profileId: profile),
    );
    expect(m.keys, <String>['game:scraped']);
    expect(m['game:scraped']!.upload.title, 'スクレイプ');
  });

  test('每日字数只保留服务端窗口：UTC now − 3649 天到 now + 36 小时', () async {
    // 服务端下界 = UTC(now − 3650 天) = 2016-09-30；「年 − 10」会得到 2016-09-29（整批 400）。
    await segment('book', 'x', date: '2016-09-29', chars: 1);
    await segment('book', 'x', date: '2016-09-30', chars: 2); // 离下界只差一天：留余量
    await segment('book', 'x', date: '2016-10-01', chars: 3);
    await segment('book', 'x', date: '2026-09-30', chars: 4); // 本地日可能比 UTC 快
    await segment('book', 'x', date: '2026-10-01', chars: 5); // 坏时钟写下的未来日期
    final LocalShelf shelf = await buildLocalShelf(
      db,
      profileId: profile,
      now: DateTime.utc(2026, 9, 28, 12),
    );
    expect(shelf.dailyFrom, '2016-10-01');
    expect(
      shelf.daily.map((DailyCharsUpload d) => '${d.date}=${d.chars}'),
      <String>['2016-10-01=3', '2026-09-30=4'],
    );
  });
}
