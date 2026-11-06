import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/people/person_detail_page.dart';
import 'package:fushi/src/media/people/person_directory.dart';
import 'package:fushi/src/media/people/person_entry_sections.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/people/person_identity.dart';
import 'package:fushi_engine/media/people/vndb_voice_cast.dart';
import 'package:fushi_engine/media/people/wikidata_person_bridge.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

/// 人物聚合页数据层 + 页面（作品图谱 L5）：视频 AniDB 人物、游戏 VNDB 声优、音乐
/// MusicBrainz 艺人按外部 id 合成一个人；角色歌、Wikidata 桥、同名建议确认 / 否决。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late int collectionId;
  const String mbid = '8d41ed72-5c9b-4db8-9253-685f9763ae4d';

  Future<void> seed() async {
    collectionId = await db.createMediaCollection('Ever17 TV');
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: 'Ever17 TV',
        updatedAt: 1,
      ),
    );
    await db.upsertVideoMetadataPeople(<VideoMetadataPeopleCompanion>[
      VideoMetadataPeopleCompanion.insert(
        personKey: 'person:anidb:232',
        name: 'Shitaya Noriko',
        updatedAt: 1,
      ),
      VideoMetadataPeopleCompanion.insert(
        personKey: 'person:tmdb:999',
        name: 'Noriko Shitaya',
        updatedAt: 1,
      ),
    ]);
    await db.upsertVideoMetadataCharacters(<VideoMetadataCharactersCompanion>[
      VideoMetadataCharactersCompanion.insert(
        characterKey: 'character:anidb:1',
        name: 'Tanaka Yuubi',
        originalName: const Value<String?>('田中 優美清春香菜'),
        updatedAt: 1,
      ),
    ]);
    await db.replaceVideoMetadataProviderIdentities(
      personKey: 'person:anidb:232',
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        VideoMetadataProviderIdentitiesCompanion.insert(
          identityKey: 'person:anidb:232:anidb',
          provider: 'anidb',
          externalId: '232',
          isPrimary: const Value<bool>(true),
          updatedAt: 1,
        ),
      ],
    );
    await db.replaceVideoMetadataProviderIdentities(
      personKey: 'person:tmdb:999',
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        VideoMetadataProviderIdentitiesCompanion.insert(
          identityKey: 'person:tmdb:999:tmdb',
          provider: 'tmdb',
          externalId: '999',
          isPrimary: const Value<bool>(true),
          updatedAt: 1,
        ),
      ],
    );
    await db.replaceVideoMetadataCredits(
      workId: workId,
      credits: <VideoMetadataCreditsCompanion>[
        VideoMetadataCreditsCompanion.insert(
          personKey: 'person:anidb:232',
          characterKey: const Value<String?>('character:anidb:1'),
          creditKind: 'voice_actor',
          roleName: const Value<String>('Tanaka Yuubi'),
        ),
      ],
    );
    // 游戏 + VNDB 配音表（声优带 AniDB / MusicBrainz 外部链接）。
    await db.upsertGalgame(
      GalgamesCompanion.insert(
        id: 'g1',
        name: 'Ever17',
        exePath: 'C:/g/ever17.exe',
        workdir: 'C:/g',
        addedAt: 1,
      ),
    );
    await db.upsertGameVoiceCast(
      GameVoiceCastsCompanion.insert(
        gameId: 'g1',
        vndbId: 'v17',
        castJson: encodeGameVoiceCast(<GameVoiceCredit>[
          GameVoiceCredit(
            characterId: 'c28',
            characterName: 'Tanaka Yubiseiharukana',
            characterOriginal: '田中 優美清春香菜',
            staffId: 's71',
            staffName: 'Shitaya Noriko',
            staffOriginal: '下屋 則子',
            staffIdNodes: <String>[
              'id:vndb:s71',
              'id:anidb:232',
              'id:musicbrainz:$mbid',
            ],
          ),
        ]),
        fetchedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    // 音乐：艺人（MBID）以 CV 名义演唱一首角色歌。
    await db
        .into(db.musicArtists)
        .insert(
          MusicArtistsCompanion.insert(
            artistUid: 'a1',
            name: '下屋則子',
            mbArtistId: const Value<String?>(mbid),
            addedAt: 1,
          ),
        );
    await db
        .into(db.musicArtists)
        .insert(
          MusicArtistsCompanion.insert(
            artistUid: 'a-char',
            name: '田中優美清春香菜',
            addedAt: 1,
          ),
        );
    await db
        .into(db.musicTracks)
        .insert(
          MusicTracksCompanion.insert(
            trackUid: 't1',
            path: 'C:/m/t1.flac',
            title: 'Character Song',
            fileMtimeAt: 1,
            fileSize: 1,
            addedAt: 1,
          ),
        );
    for (final MusicTrackCreditsCompanion c in <MusicTrackCreditsCompanion>[
      MusicTrackCreditsCompanion.insert(
        trackUid: 't1',
        artistUid: 'a1',
        role: 'vocal_cv',
        creditName: '下屋則子',
      ),
      MusicTrackCreditsCompanion.insert(
        trackUid: 't1',
        artistUid: 'a-char',
        role: 'character',
        creditName: '田中優美清春香菜',
      ),
    ]) {
      await db.into(db.musicTrackCredits).insert(c);
    }
  }

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    await seed();
  });

  tearDown(() => db.close());

  test('三域按外部 id 合成一人：动画角色 / 游戏角色 / 角色歌齐全', () async {
    final PersonPageData data = (await loadPersonPage(
      db,
      personRefNode(PersonRefDomain.music, 'a1'),
    ))!;
    expect(
      data.cluster.records.map((PersonRecord r) => r.node).toSet(),
      <String>{'ref:video:person:anidb:232', 'ref:game:s71', 'ref:music:a1'},
    );
    expect(data.cluster.displayName, '下屋 則子');
    expect(data.videoRoles.single.characterName, '田中 優美清春香菜');
    expect(data.videoRoles.single.work.entry.endpoint, (
      kind: MediaLinkKind.videoCollection,
      key: collectionTagEntryKey(collectionId),
    ));
    expect(data.gameRoles.single.work.entry.endpoint.key, 'g1');
    expect(data.songs.single.isCharacterSong, isTrue);
    expect(data.songs.single.characterNames, <String>['田中優美清春香菜']);
    expect(
      data.suggestions.single.other.records.single.node,
      'ref:video:person:tmdb:999',
      reason: '只同名（段序互换）→ 建议，不自动合并',
    );
  });

  test('手动确认合并、否决写墓碑；Wikidata 桥落「查过」标记与等价边', () async {
    final String seedNode = personRefNode(PersonRefDomain.game, 's71');
    await db.setManualPersonBridge(
      'ref:video:person:tmdb:999',
      seedNode,
      same: true,
      at: 5,
    );
    PersonPageData data = (await loadPersonPage(db, seedNode))!;
    expect(data.cluster.records, hasLength(4));
    expect(data.manualPairs, hasLength(1));
    expect(data.suggestions, isEmpty);

    await db.setManualPersonBridge(
      seedNode,
      'ref:video:person:tmdb:999',
      same: false,
      at: 6,
    );
    data = (await loadPersonPage(db, seedNode))!;
    expect(data.cluster.records, hasLength(3));
    expect(data.suggestions, isEmpty, reason: '否决过的一对不再建议');

    int requests = 0;
    final WikidataPersonBridge bridge = WikidataPersonBridge(
      minInterval: Duration.zero,
      client: MockClient((http.Request r) async {
        requests++;
        return http.Response(
          '{"results":{"bindings":[{"item":{"value":"http://www.wikidata.org/entity/Q3273278"},'
          '"anidb":{"value":"232"},"tmdb":{"value":"999"}}]}}',
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    final bool changed = await refreshPersonWikidataBridges(
      db,
      data.cluster,
      bridge: bridge,
    );
    expect(changed, isTrue);
    expect(requests, 1);
    data = (await loadPersonPage(db, seedNode))!;
    expect(
      data.cluster.records,
      hasLength(4),
      reason: 'Wikidata 上 AniDB 232 与 TMDB 999 同一条目 → 外部 id 合并（不受名字否决影响）',
    );
    expect(
      await personIdsNeedingWikidata(db, data.cluster, now: DateTime.now()),
      isNot(contains('id:anidb:232')),
      reason: '查过的 id 30 天内不重查',
    );
  });

  test('GameVoiceCastService：缓存有效不重取，换绑 VN 重取，失败不写缓存', () async {
    int calls = 0;
    int status = 200;
    final GameVoiceCastService service = GameVoiceCastService(
      db,
      client: VndbVoiceCastClient(
        minInterval: Duration.zero,
        client: MockClient((_) async {
          calls++;
          return http.Response('{"results":[{"id":"v18","va":[]}]}', status);
        }),
      ),
    );
    expect(await service.refreshIfStale('g1', 'v17'), isFalse);
    expect(calls, 0);
    expect(await service.refreshIfStale('g1', 'v18'), isTrue);
    expect(await service.cached('g1'), isEmpty);
    status = 500;
    await db.upsertGameVoiceCast(
      GameVoiceCastsCompanion.insert(
        gameId: 'g1',
        vndbId: 'v18',
        castJson: '[]',
        fetchedAt: 0,
      ),
    );
    expect(await service.refreshIfStale('g1', 'v18'), isFalse);
    expect((await db.getGameVoiceCast('g1'))!.fetchedAt, 0);
  });

  test('groupMusicTrackCredits：角色名义挂到 CV 上，不当人列出', () async {
    final List<MusicTrackPersonCredit> list = groupMusicTrackCredits(
      await db.musicCreditsForTracks(<String>{'t1'}),
    );
    expect(list.single.artist.artistUid, 'a1');
    expect(list.single.characterNames, <String>['田中優美清春香菜']);
  });

  testWidgets('人物页：三个区块 + 同名建议「是同一人」写穿后合并', (WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: PersonDetailPage(
            database: db,
            seedNode: personRefNode(PersonRefDomain.video, 'person:anidb:232'),
            bridgeLookup: false,
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('person-name')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('person-anime-roles')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('person-game-roles')),
      findsOneWidget,
    );
    // 外层纵向列表是懒构建的：下面的区块要滚到才建出来。
    final Finder page = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey<String>('person-songs')),
      200,
      scrollable: page,
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey<String>('person-suggestion-0-yes')),
      200,
      scrollable: page,
    );
    final Finder yes = find.byKey(
      const ValueKey<String>('person-suggestion-0-yes'),
    );
    await tester.ensureVisible(yes);
    await tester.pumpAndSettle();
    await tester.tap(yes);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    expect(
      (await tester.runAsync(
        db.allPersonIdentityBridges,
      ))!.where((PersonIdentityBridgeRow b) => b.deletedAt == null),
      hasLength(1),
    );
    expect(
      find.byKey(const ValueKey<String>('person-suggestions')),
      findsNothing,
    );
  });
}
