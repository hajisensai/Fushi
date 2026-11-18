import 'dart:convert';

import 'package:drift/drift.dart' show DatabaseConnection, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/links/media_link_inference_host.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/links/media_link_inference.dart';
import 'package:fushi_engine/media/links/music_link_inference.dart';
import 'package:fushi_engine/media/video/metadata/mal_video_metadata_provider.dart';

/// 作品图谱「动画 / 游戏 ↔ CD」推断（AI 库管家设计稿 §4.4）：证据分级、关系类型、
/// 全库批量落库与整批撤销。全部离线。
void main() {
  FushiDatabase memDb() {
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    addTearDown(db.close);
    return db;
  }

  MediaLinkSubject work(
    MediaLinkKind kind,
    String key,
    List<String> titles, {
    Map<String, String> ids = const <String, String>{},
  }) => MediaLinkSubject(
    endpoint: (kind: kind, key: key),
    titles: titles,
    externalIds: ids,
  );

  MusicLinkAlbum album(
    String uid,
    String title, {
    List<MusicLinkTrack> tracks = const <MusicLinkTrack>[],
    List<MusicLinkTitle> extra = const <MusicLinkTitle>[],
    Set<String> groupTypes = const <String>{},
  }) => MusicLinkAlbum(
    albumUid: uid,
    titles: <MusicLinkTitle>[
      (text: title, source: kMediaLinkTitleMatchSource),
      ...extra,
    ],
    tracks: tracks,
    releaseGroupTypes: groupTypes,
  );

  group('关系类型（关键词）', () {
    test('原声类 → soundtrack，主题曲类 → theme_song，都有取原声，都没有 null', () {
      expect(
        musicRelationOf('TVアニメ「進撃の巨人」オリジナルサウンドトラック'),
        MediaLinkRelation.soundtrack,
      );
      expect(musicRelationOf('Steins;Gate OST'), MediaLinkRelation.soundtrack);
      expect(musicRelationOf('けいおん！ サントラ'), MediaLinkRelation.soundtrack);
      expect(
        musicRelationOf('Fate/Zero Original Soundtrack'),
        MediaLinkRelation.soundtrack,
      );
      expect(musicRelationOf('「X」OP主題歌'), MediaLinkRelation.themeSong);
      expect(musicRelationOf('X エンディングテーマ'), MediaLinkRelation.themeSong);
      expect(musicRelationOf('X キャラクターソング Vol.1'), MediaLinkRelation.themeSong);
      expect(musicRelationOf('X ドラマCD'), MediaLinkRelation.themeSong);
      expect(musicRelationOf('X OP2'), MediaLinkRelation.themeSong);
      expect(
        musicRelationOf('X オリジナルサウンドトラック（OP / ED TV size 収録）'),
        MediaLinkRelation.soundtrack,
        reason: '两类关键词都有时取原声',
      );
      expect(musicRelationOf('Tropical Edition'), isNull, reason: '拉丁关键词不吃词内');
      expect(musicRelationOf('ベストアルバム'), isNull);
      expect(
        musicRelationOf(
          'Some Album',
          releaseGroupTypes: const <String>{'album', 'soundtrack'},
        ),
        MediaLinkRelation.soundtrack,
        reason: 'MusicBrainz release group 类别 Soundtrack 等同原声关键词',
      );
    });
  });

  group('证据分级', () {
    test('作品名 + 关键词 = titleKeyword；只有作品名 = titleOnly；对不上 none', () {
      final MusicTitleMatch k = gradeMusicTitle(
        'ＴＶアニメ「ＣＬＡＮＮＡＤ」オリジナル・サウンドトラック',
        <String>['clannad'],
      );
      expect(
        k.evidence,
        MusicLinkEvidence.titleKeyword,
        reason: '全半角 / 大小写 / 标点规范化',
      );
      expect(k.relation, MediaLinkRelation.soundtrack);
      final MusicTitleMatch o = gradeMusicTitle('CLANNAD ベスト', <String>[
        'CLANNAD',
      ]);
      expect(o.evidence, MusicLinkEvidence.titleOnly);
      expect(o.relation, isNull);
      expect(
        gradeMusicTitle('Kanon OST', <String>['Air']).evidence,
        MusicLinkEvidence.none,
      );
    });

    test('规范化后 ≤2 字符的作品名不靠子串判', () {
      expect(
        gradeMusicTitle('ARIA The ORIGINAL SOUNDTRACK', <String>[
          'AR',
        ]).evidence,
        MusicLinkEvidence.none,
      );
      expect(
        gradeMusicTitle('ヨルムンガンド OST', <String>['ヨル']).evidence,
        MusicLinkEvidence.none,
      );
      expect(
        gradeMusicTitle('AIR OST', <String>['AIR']).evidence,
        MusicLinkEvidence.titleKeyword,
        reason: '3 字符可以',
      );
    });
  });

  group('候选（纯函数）', () {
    final MediaLinkSubject anime = work(
      MediaLinkKind.videoCollection,
      '7',
      <String>['進撃の巨人'],
      ids: <String, String>{'anidb': '9541'},
    );
    final MediaLinkSubject anime2 = work(
      MediaLinkKind.videoCollection,
      '8',
      <String>['進撃の巨人 Season 2'],
    );
    final MediaLinkSubject game = work(MediaLinkKind.game, 'g1', <String>[
      'STEINS;GATE',
    ]);
    final MediaLinkSubject book = work(MediaLinkKind.book, 'b1', <String>[
      '進撃の巨人',
    ]);

    test('声纹命中：专辑 → 作品 theme_song，共享证据、来源 fingerprint、排在最前', () {
      final List<MediaLinkCandidate> got = collectMusicLinkCandidates(
        music: MusicLinkLibrary(
          albums: <MusicLinkAlbum>[
            album(
              'a1',
              '紅蓮の弓矢',
              tracks: const <MusicLinkTrack>[
                MusicLinkTrack(trackUid: 't1', title: '紅蓮の弓矢'),
              ],
            ),
          ],
          spanHits: const <MusicLinkSpanHit>[
            MusicLinkSpanHit(
              trackUid: 't1',
              videoBookUid: 'ep1',
              episodeIndex: 0,
              videoEndpoints: <MediaLinkEndpoint>[
                (kind: MediaLinkKind.videoCollection, key: '7'),
                (kind: MediaLinkKind.videoEpisode, key: 'ep1'),
              ],
            ),
            MusicLinkSpanHit(
              trackUid: 't1',
              videoBookUid: 'ep2',
              episodeIndex: 0,
              videoEndpoints: <MediaLinkEndpoint>[
                (kind: MediaLinkKind.videoCollection, key: '7'),
                (kind: MediaLinkKind.videoEpisode, key: 'ep2'),
              ],
            ),
          ],
        ),
        works: <MediaLinkSubject>[anime, anime2, game],
      );
      final MediaLinkCandidate c = got.single;
      expect(c.from.endpoint, (kind: MediaLinkKind.musicAlbum, key: 'a1'));
      expect(c.to.endpoint, anime.endpoint);
      expect(c.relation, MediaLinkRelation.themeSong);
      expect(c.source, MediaLinkSource.fingerprint);
      expect(c.idEvidence, isTrue);
      expect(c.reason, contains('2 episode(s)'));
      expect(
        mediaLinkDispositionOf(
          original: c,
          verdict: null,
          trigger: MediaLinkInferenceTrigger.automatic,
        ),
        MediaLinkDisposition.apply,
      );
      expect(mediaLinkSkipsJudge(c), isTrue, reason: '声纹命中不交 AI');
    });

    test('声纹命中的视频不在任何作品合集里 → 落到单集端点', () {
      final MusicLinkSpanHit hit = MusicLinkSpanHit(
        trackUid: 't',
        videoBookUid: 'movie',
        episodeIndex: 0,
        videoEndpoints: const <MediaLinkEndpoint>[
          (kind: MediaLinkKind.videoEpisode, key: 'movie'),
        ],
      );
      expect(
        pickMusicLinkVideoTarget(hit, <MediaLinkSubject>[anime]).endpoint,
        (kind: MediaLinkKind.videoEpisode, key: 'movie'),
      );
    });

    test('关键词：只连更具体的作品；游戏也能连；书不是音乐的落点；没有关键词不出候选', () {
      final List<MediaLinkCandidate> got = collectMusicLinkCandidates(
        music: MusicLinkLibrary(
          albums: <MusicLinkAlbum>[
            album('a2', 'TVアニメ「進撃の巨人 Season 2」オリジナルサウンドトラック'),
            album('a3', 'STEINS;GATE 主題歌集'),
            album('a4', '進撃の巨人 ベスト'),
          ],
        ),
        works: <MediaLinkSubject>[anime, anime2, game, book],
      );
      expect(got, hasLength(2));
      final MediaLinkCandidate ost = got.firstWhere(
        (MediaLinkCandidate c) => c.from.endpoint.key == 'a2',
      );
      expect(ost.to.endpoint, anime2.endpoint, reason: '不连正篇');
      expect(ost.relation, MediaLinkRelation.soundtrack);
      expect(ost.idEvidence, isFalse);
      expect(
        mediaLinkDispositionOf(
          original: ost,
          verdict: null,
          trigger: MediaLinkInferenceTrigger.manual,
        ),
        MediaLinkDisposition.suggest,
        reason: '中证据没经 AI 写建议',
      );
      final MediaLinkCandidate songs = got.firstWhere(
        (MediaLinkCandidate c) => c.from.endpoint.key == 'a3',
      );
      expect(songs.to.endpoint, game.endpoint);
      expect(songs.relation, MediaLinkRelation.themeSong);
    });

    test('专辑名对不上时看曲目名，落到曲目；VGMdb 名命中记来源 vgmdb', () {
      final List<MediaLinkCandidate> got = collectMusicLinkCandidates(
        music: MusicLinkLibrary(
          albums: <MusicLinkAlbum>[
            album(
              'a5',
              'Linked Horizon シングル',
              tracks: const <MusicLinkTrack>[
                MusicLinkTrack(trackUid: 't5', title: '進撃の巨人 オープニングテーマ'),
                MusicLinkTrack(trackUid: 't6', title: 'カップリング'),
              ],
            ),
            album(
              'a6',
              'GATE OF STEINER',
              extra: const <MusicLinkTitle>[
                (
                  text: 'STEINS;GATE Original Soundtrack',
                  source: MediaLinkSource.vgmdb,
                ),
              ],
            ),
          ],
        ),
        works: <MediaLinkSubject>[anime, game],
      );
      expect(got, hasLength(2));
      final MediaLinkCandidate track = got.firstWhere(
        (MediaLinkCandidate c) =>
            c.from.endpoint.kind == MediaLinkKind.musicTrack,
      );
      expect(track.from.endpoint.key, 't5');
      expect(track.to.endpoint, anime.endpoint);
      expect(track.relation, MediaLinkRelation.themeSong);
      final MediaLinkCandidate vgm = got.firstWhere(
        (MediaLinkCandidate c) => c.from.endpoint.key == 'a6',
      );
      expect(vgm.source, MediaLinkSource.vgmdb);
      expect(vgm.relation, MediaLinkRelation.soundtrack);
    });

    test('AI 结论按候选种类约束关系：音乐只能主题曲 / 原声、方向音乐 → 作品', () {
      final MediaLinkCandidate music = MediaLinkCandidate(
        from: work(MediaLinkKind.musicAlbum, 'a', <String>['X OST']),
        to: anime,
        relation: MediaLinkRelation.soundtrack,
        source: kMediaLinkTitleMatchSource,
        confidence: 0.6,
        reason: 'r',
      );
      final MediaLinkVerdict? v = fitMediaLinkVerdict(
        music,
        const MediaLinkVerdict(
          related: true,
          relation: MediaLinkRelation.adaptation,
          fromIsOriginal: false,
          confidence: 0.95,
          reason: 'ai',
        ),
      );
      expect(v!.relation, MediaLinkRelation.soundtrack);
      expect(v.fromIsOriginal, isTrue);
      final MediaLinkCandidate other = MediaLinkCandidate(
        from: book,
        to: anime,
        relation: MediaLinkRelation.sameWork,
        source: kMediaLinkTitleMatchSource,
        confidence: 0.35,
        reason: 'r',
      );
      expect(
        fitMediaLinkVerdict(
          other,
          const MediaLinkVerdict(
            related: true,
            relation: MediaLinkRelation.themeSong,
            fromIsOriginal: true,
            confidence: 0.9,
            reason: 'ai',
          ),
        ),
        isNull,
        reason: '非音乐候选给主题曲关系 = 结论形状不对，当没裁决',
      );
    });
  });

  group('全库批量（内存库）', () {
    late FushiDatabase db;
    late int animeId;
    late MediaLinkEndpoint animeEp;
    const MediaLinkEndpoint gameEp = (kind: MediaLinkKind.game, key: 'g1');
    const MediaLinkEndpoint opAlbum = (
      kind: MediaLinkKind.musicAlbum,
      key: 'a-op',
    );
    const MediaLinkEndpoint ostAlbum = (
      kind: MediaLinkKind.musicAlbum,
      key: 'a-ost',
    );

    Future<void> addAlbum(String uid, String title, List<String> tracks) async {
      await db
          .into(db.musicAlbums)
          .insert(
            MusicAlbumsCompanion.insert(
              albumUid: uid,
              title: title,
              addedAt: 1,
              updatedAt: 1,
            ),
          );
      for (final String t in tracks) {
        await db
            .into(db.musicTracks)
            .insert(
              MusicTracksCompanion.insert(
                trackUid: t,
                path: '/m/$t.flac',
                title: t,
                albumUid: Value<String?>(uid),
                fileMtimeAt: 1,
                fileSize: 1,
                addedAt: 1,
              ),
            );
      }
    }

    setUp(() async {
      db = memDb();
      animeId = await db.createMediaCollection('ゆるキャン△');
      animeEp = (
        kind: MediaLinkKind.videoCollection,
        key: collectionTagEntryKey(animeId),
      );
      await db
          .into(db.videoMetadataWorks)
          .insert(
            VideoMetadataWorksCompanion.insert(
              collectionId: Value<int?>(animeId),
              mediaType: 'tv',
              title: 'ゆるキャン△',
              updatedAt: 1,
            ),
          );
      await db.addToCollectionRaw(animeId, MediaKind.video.dbValue, 'ep1');
      await db
          .into(db.galgames)
          .insert(
            GalgamesCompanion.insert(
              id: 'g1',
              name: 'サクラノ詩',
              exePath: '/g/g1.exe',
              workdir: '/g',
              addedAt: 0,
            ),
          );
      // OP 单曲：声纹在第 1 集命中。
      await addAlbum('a-op', 'SHINY DAYS', <String>['SHINY DAYS']);
      await db
          .into(db.videoThemeSongSpans)
          .insert(
            VideoThemeSongSpansCompanion.insert(
              bookUid: 'ep1',
              episodeIndex: 0,
              trackUid: 'SHINY DAYS',
              fileSizeBytes: 1,
              fileModifiedAt: 1,
              detectorVersion: 1,
              startMs: const Value<int?>(1000),
              endMs: const Value<int?>(91000),
              detectedAt: 1,
            ),
          );
      // 游戏原声：本地专辑名带作品名 + 关键词。
      await addAlbum('a-ost', 'サクラノ詩 オリジナルサウンドトラック', <String>['櫻ノ詩']);
      // 没有关键词：不出候选。
      await addAlbum('a-best', 'サクラノ詩 ベスト', <String>['x']);
      // 短作品名不误配：「AB」作品 vs 带 AB 的 OST。
      final int shortId = await db.createMediaCollection('AB');
      await db
          .into(db.videoMetadataWorks)
          .insert(
            VideoMetadataWorksCompanion.insert(
              collectionId: Value<int?>(shortId),
              mediaType: 'tv',
              title: 'AB',
              updatedAt: 1,
            ),
          );
      await addAlbum('a-short', 'FABULOUS ORIGINAL SOUNDTRACK', <String>['y']);
    });

    test('声纹命中直接生效、关键词写建议、短名与无关键词不出；整批撤销回到写入前', () async {
      final MusicLinkBatchResult r = await runMusicMediaLinkBatchInference(
        db: db,
      );
      expect(r.writes, hasLength(2));
      final MusicLinkBatchWrite applied = r.applied.single;
      expect(
        applied.id,
        mediaLinkIdFor(MediaLinkRelation.themeSong, opAlbum, animeEp),
      );
      expect(applied.previous, isNull);
      final MediaLinkRow op = (await db.mediaLinkById(applied.id))!;
      expect(op.confirmedBy, MediaLinkConfirmer.ai);
      expect(op.source, MediaLinkSource.fingerprint);
      expect(op.reason, contains('SHINY DAYS'));

      final MusicLinkBatchWrite suggested = r.suggested.single;
      expect(
        suggested.id,
        mediaLinkIdFor(MediaLinkRelation.soundtrack, ostAlbum, gameEp),
      );
      final MediaLinkRow ost = (await db.mediaLinkById(suggested.id))!;
      expect(ost.confirmedBy, isNull);
      expect(ost.source, kMediaLinkTitleMatchSource);

      expect(await revertMusicLinkBatch(db, r), 2);
      // 建议直接删；生效的那条写墓碑（不删行：已同步出去的副本会被 LWW 拉回来），
      // 这一对之后也不再自动连。
      final List<MediaLinkRow> left = await db.allMediaLinks();
      expect(left.map(mediaLinkIdOf), <MediaLinkId>[applied.id]);
      expect(mediaLinkStateOf(left.single), MediaLinkState.removed);
      final MusicLinkBatchResult again = await runMusicMediaLinkBatchInference(
        db: db,
      );
      expect(again.applied, isEmpty, reason: '撤销过的一对不再自动生效');
    });

    test('否决过的一对不再提议；用户确认过的连接不改', () async {
      final MediaLinkId ostId = mediaLinkIdFor(
        MediaLinkRelation.soundtrack,
        ostAlbum,
        gameEp,
      );
      await db.proposeMediaLink(
        relation: MediaLinkRelation.soundtrack,
        from: ostAlbum,
        to: gameEp,
        source: kMediaLinkTitleMatchSource,
      );
      await db.removeMediaLink(ostId);
      // 用户把 OP 专辑手动连成 soundtrack（关系与推断不同）。
      final MediaLinkId manual = await db.upsertManualMediaLink(
        relation: MediaLinkRelation.soundtrack,
        from: opAlbum,
        to: animeEp,
      );

      final MusicLinkBatchResult r = await runMusicMediaLinkBatchInference(
        db: db,
      );
      expect(r.writes, isEmpty);
      expect((await db.mediaLinkById(ostId))!.deletedAt, isNotNull);
      final MediaLinkRow kept = (await db.mediaLinkById(manual))!;
      expect(kept.confirmedBy, MediaLinkConfirmer.user);
      expect(kept.relation, MediaLinkRelation.soundtrack.dbValue);
      expect(await db.allMediaLinks(), hasLength(2));
    });

    test('刮削数据：VGMdb 名与 MusicBrainz release group 类别参与', () async {
      await addAlbum('a-vgm', 'YC OST', <String>['v1']);
      await db
          .into(db.musicScrapeMeta)
          .insert(
            MusicScrapeMetaCompanion.insert(
              trackUid: 'v1',
              status: 'matched',
              scraperVersion: 1,
              scrapedAt: 1,
              vgmdbJson: Value<String?>(
                jsonEncode(<String, Object?>{
                  'id': '1',
                  'link': 'https://vgmdb.net/album/1',
                  'names': <String, String>{
                    'ja': 'TVアニメ「ゆるキャン△」オリジナル・サウンドトラック',
                  },
                }),
              ),
            ),
          );
      final MusicLinkLibrary music = await loadMusicLinkLibrary(db);
      final MusicLinkAlbum vgm = music.albums.firstWhere(
        (MusicLinkAlbum a) => a.albumUid == 'a-vgm',
      );
      expect(
        vgm.titles.map((MusicLinkTitle t) => t.source),
        contains(MediaLinkSource.vgmdb),
      );
      final MusicLinkBatchResult r = await runMusicMediaLinkBatchInference(
        db: db,
      );
      final MediaLinkRow row = (await db.mediaLinkById(
        mediaLinkIdFor(MediaLinkRelation.soundtrack, (
          kind: MediaLinkKind.musicAlbum,
          key: 'a-vgm',
        ), animeEp),
      ))!;
      expect(row.source, MediaLinkSource.vgmdb);
      expect(row.confirmedBy, isNull);
      expect(r.writes, hasLength(3));
    });

    test('详情页「查找相关作品」以专辑为中心：只出这张专辑的连接，不查 MAL / Wikidata', () async {
      final int added = await runMediaLinkInference(
        db: db,
        self: opAlbum,
        fetchMalSourceMaterial: (String _) async => throw StateError('不该查 MAL'),
        lookupWikidataAnime: (Iterable<String> _) async =>
            throw StateError('不该查 Wikidata'),
      );
      expect(added, 1);
      final MediaLinkRow row = (await db.allMediaLinks()).single;
      expect(row.fromKey, 'a-op');
      expect(row.confirmedBy, MediaLinkConfirmer.ai);

      // 从作品一侧看也能找到连到它的原声。
      final int fromGame = await runMediaLinkInference(
        db: db,
        self: gameEp,
        fetchMalSourceMaterial: (String _) async => const <MalSourceMaterial>[],
        lookupWikidataAnime: (Iterable<String> _) async =>
            const <String, Set<String>>{},
      );
      expect(fromGame, 1);
      expect(
        await db.mediaLinkById(
          mediaLinkIdFor(MediaLinkRelation.soundtrack, ostAlbum, gameEp),
        ),
        isNotNull,
      );
    });
  });
}
