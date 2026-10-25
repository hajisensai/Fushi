import 'package:drift/drift.dart' show DatabaseConnection, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/media_link_sync.dart';

/// 互联作品图谱同步（`media_link_sync.dart`）：手动连接、建议、确认、否决墓碑在两端
/// 一致；端点按跨端身份对号（合集自然键、游戏 VNDB / 标题身份、书 wire bookKey），
/// 本机落不了地的合集 / 游戏端点跳过、到了之后下一轮补上。
void main() {
  FushiDatabase memDb() {
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    addTearDown(db.close);
    return db;
  }

  Future<void> seedBook(FushiDatabase db, String bookKey) => db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: bookKey,
      epubPath: '/tmp/$bookKey.epub',
      extractDir: '/tmp/$bookKey',
      chapterCount: 1,
      chaptersJson: '["ch1"]',
      importedAt: 0,
    ),
  );

  Future<void> seedGame(
    FushiDatabase db,
    String id, {
    required String vndb,
  }) async {
    await db.upsertGalgame(
      GalgamesCompanion.insert(
        id: id,
        name: id,
        exePath: 'Z:\\vn\\$id\\$id.exe',
        workdir: 'Z:\\vn\\$id',
        addedAt: 1700000000000,
      ),
    );
    await db.upsertGalgameSource(
      GalgameSourcesCompanion.insert(
        gameId: id,
        source: 'vndb',
        externalId: Value(vndb),
        dataJson: '{}',
        fetchedAt: 1,
      ),
    );
  }

  /// 一轮 client ↔ host 同步（与 SyncOrchestrator._syncMediaLinksLive 同形）。
  Future<void> syncPair(FushiDatabase client, FushiDatabase host) async {
    final MediaLinkManifest remote = await loadLocalMediaLinkManifest(host);
    await applyMediaLinkManifest(client, remote);
    final MediaLinkManifest local = await loadLocalMediaLinkManifest(client);
    if (!mediaLinkManifestCovers(remote, local)) {
      await applyMediaLinkManifest(host, local);
    }
  }

  test('合集 id 两端不同：按自然键对号；手动连接双向一致', () async {
    final FushiDatabase host = memDb();
    final FushiDatabase client = memDb();
    // host 先建一个无关合集，让同名合集在两端拿到不同的自增 id。
    await host.createMediaCollection('Other');
    final int hostAnime = await host.createMediaCollection('Clannad');
    final int clientAnime = await client.createMediaCollection('Clannad');
    expect(hostAnime, isNot(clientAnime));
    for (final FushiDatabase db in <FushiDatabase>[host, client]) {
      await seedBook(db, 'clannad-novel');
    }
    await client.upsertManualMediaLink(
      relation: MediaLinkRelation.adaptation,
      from: (kind: MediaLinkKind.book, key: 'clannad-novel'),
      to: (
        kind: MediaLinkKind.videoCollection,
        key: collectionTagEntryKey(clientAnime),
      ),
      at: 100,
    );
    await syncPair(client, host);
    final List<MediaLinkRow> onHost = await host.mediaLinksForEndpoint(
      MediaLinkKind.videoCollection,
      collectionTagEntryKey(hostAnime),
    );
    expect(onHost, hasLength(1));
    expect(onHost.single.fromKey, 'clannad-novel');
    expect(onHost.single.isUserConfirmed, isTrue);

    // host 删除（墓碑）→ client 也消失，再同步不复活。
    await host.removeMediaLink(mediaLinkIdOf(onHost.single), at: 200);
    await syncPair(client, host);
    expect(
      await client.mediaLinksForEndpoint(MediaLinkKind.book, 'clannad-novel'),
      isEmpty,
    );
    await syncPair(client, host);
    expect(
      await host.mediaLinksForEndpoint(MediaLinkKind.book, 'clannad-novel'),
      isEmpty,
    );
  });

  test('游戏 id 两端不同：按 VNDB 身份对号；否决的建议不在对端复活', () async {
    final FushiDatabase host = memDb();
    final FushiDatabase client = memDb();
    await seedGame(host, 'host-game', vndb: 'v4');
    await seedGame(client, 'client-game', vndb: 'v4');
    await seedBook(host, 'book');
    await seedBook(client, 'book');
    await host.proposeMediaLink(
      relation: MediaLinkRelation.sameWork,
      from: (kind: MediaLinkKind.game, key: 'host-game'),
      to: (kind: MediaLinkKind.book, key: 'book'),
      source: MediaLinkSource.ai,
      confidence: 0.7,
      reason: 'same title',
      at: 10,
    );
    await syncPair(client, host);
    final List<MediaLinkRow> onClient = await client.mediaLinksForEndpoint(
      MediaLinkKind.game,
      'client-game',
    );
    expect(onClient, hasLength(1));
    expect(mediaLinkStateOf(onClient.single), MediaLinkState.suggested);
    expect(onClient.single.reason, 'same title');

    await client.removeMediaLink(mediaLinkIdOf(onClient.single), at: 20);
    await syncPair(client, host);
    final List<MediaLinkRow> hostRows = await host.mediaLinksForEndpoint(
      MediaLinkKind.game,
      'host-game',
      includeRemoved: true,
    );
    expect(hostRows.single.deletedAt, 20, reason: 'client 的否决墓碑到了 host');
    expect(
      await host.proposeMediaLink(
        relation: MediaLinkRelation.sameWork,
        from: (kind: MediaLinkKind.game, key: 'host-game'),
        to: (kind: MediaLinkKind.book, key: 'book'),
        source: MediaLinkSource.ai,
      ),
      isFalse,
      reason: 'host 上的推断也不会再提议被 client 否决过的这一对',
    );
  });

  test('本机没有的合集端点跳过，合集到了之后下一轮补上；书 / 视频端点照常落地', () async {
    final FushiDatabase host = memDb();
    final FushiDatabase client = memDb();
    final int anime = await host.createMediaCollection('Kanon');
    await host.upsertManualMediaLink(
      relation: MediaLinkRelation.adaptation,
      from: (kind: MediaLinkKind.book, key: 'kanon-novel'),
      to: (kind: MediaLinkKind.videoCollection, key: '$anime'),
      at: 1,
    );
    await host.upsertManualMediaLink(
      relation: MediaLinkRelation.sameWork,
      from: (kind: MediaLinkKind.book, key: 'kanon-novel'),
      to: (kind: MediaLinkKind.videoEpisode, key: 'video/kanon-movie'),
      at: 1,
    );
    await syncPair(client, host);
    final List<MediaLinkRow> first = await client.allMediaLinks();
    expect(first, hasLength(1), reason: '合集端点落不了地：只到了书 ↔ 视频那条');
    expect(first.single.toKind, 'video_episode');

    await client.createMediaCollection('Kanon');
    await syncPair(client, host);
    expect(await client.allMediaLinks(), hasLength(2));
  });

  test('收敛后清单互相覆盖；对端更新的知识让 covers 为 false', () async {
    final FushiDatabase host = memDb();
    final FushiDatabase client = memDb();
    await seedBook(host, 'a');
    await seedBook(client, 'a');
    await client.upsertManualMediaLink(
      relation: MediaLinkRelation.sameWork,
      from: (kind: MediaLinkKind.book, key: 'a'),
      to: (kind: MediaLinkKind.musicAlbum, key: 'album-uid-1'),
      at: 5,
    );
    await syncPair(client, host);
    final MediaLinkManifest h = await loadLocalMediaLinkManifest(host);
    final MediaLinkManifest c = await loadLocalMediaLinkManifest(client);
    expect(mediaLinkManifestCovers(h, c), isTrue);
    expect(mediaLinkManifestCovers(c, h), isTrue);
    expect(h.canonicalJson(), c.canonicalJson());

    await client.removeMediaLink(
      mediaLinkIdFor(
        MediaLinkRelation.sameWork,
        (kind: MediaLinkKind.book, key: 'a'),
        (kind: MediaLinkKind.musicAlbum, key: 'album-uid-1'),
      ),
      at: 5,
    );
    final MediaLinkManifest c2 = await loadLocalMediaLinkManifest(client);
    expect(
      mediaLinkManifestCovers(h, c2),
      isFalse,
      reason: '同一时刻的墓碑名次高于已确认：host 还没有这条知识',
    );
  });

  test('清单 JSON 往返；未知种类 / 关系原样跳过，高版本清单拒收', () {
    const MediaLinkManifest m = MediaLinkManifest(
      links: <MediaLinkManifestEntry>[
        MediaLinkManifestEntry(
          from: MediaLinkWireEndpoint(
            kind: 'game',
            key: 'vndb:v4',
            aliases: <String>['title:clannad'],
          ),
          relation: 'adaptation',
          to: MediaLinkWireEndpoint(
            kind: 'video_collection',
            key: 'collection:A',
          ),
          source: 'manual',
          isUserConfirmed: true,
          createdAt: 1,
          updatedAt: 2,
          role: 'op',
          confidence: 0.5,
          deletedAt: 3,
        ),
      ],
    );
    final MediaLinkManifest back = MediaLinkManifest.fromJson(m.toJson());
    expect(back.canonicalJson(), m.canonicalJson());
    expect(
      () => MediaLinkManifest.fromJson(<String, dynamic>{
        'version': 99,
        'links': <Object?>[],
      }),
      throwsFormatException,
    );
  });

  test('未知种类的条目应用时跳过', () async {
    final FushiDatabase db = memDb();
    final int changed = await applyMediaLinkManifest(
      db,
      MediaLinkManifest.fromJson(<String, dynamic>{
        'version': 1,
        'links': <Object?>[
          <String, Object?>{
            'from': <String, Object?>{'kind': 'person', 'key': 'p1'},
            'relation': 'cast',
            'to': <String, Object?>{'kind': 'book', 'key': 'b'},
            'createdAt': 1,
            'updatedAt': 1,
          },
          <String, Object?>{
            'from': <String, Object?>{'kind': 'book', 'key': 'b'},
            'relation': 'future_relation',
            'to': <String, Object?>{'kind': 'video_episode', 'key': 'v'},
            'createdAt': 1,
            'updatedAt': 1,
          },
        ],
      }),
    );
    expect(changed, 0);
    expect(await db.allMediaLinks(), isEmpty);
  });
}
