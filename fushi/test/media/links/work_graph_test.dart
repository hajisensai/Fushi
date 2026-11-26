import 'dart:math';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/links/work_graph.dart';
import 'package:fushi_engine/media/links/work_graph_loader.dart';

/// 作品层（作品图谱的连通分量）与关系网（AI 库管家 spec §4.2 / §4.4）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MediaLinkEndpoint book(String k) => (kind: MediaLinkKind.book, key: k);
  MediaLinkEndpoint vc(String k) =>
      (kind: MediaLinkKind.videoCollection, key: k);
  MediaLinkEndpoint ep(String k) => (kind: MediaLinkKind.videoEpisode, key: k);
  MediaLinkEndpoint game(String k) => (kind: MediaLinkKind.game, key: k);
  MediaLinkEndpoint track(String k) => (kind: MediaLinkKind.musicTrack, key: k);
  MediaLinkEndpoint album(String k) => (kind: MediaLinkKind.musicAlbum, key: k);

  WorkGraphLink link(
    MediaLinkEndpoint from,
    MediaLinkRelation relation,
    MediaLinkEndpoint to, {
    WorkLinkStatus status = WorkLinkStatus.effective,
    String source = MediaLinkSource.manual,
  }) => WorkGraphLink(
    from: from,
    relation: relation,
    to: to,
    status: status,
    source: source,
  );

  group('WorkGraph（纯函数）', () {
    test('same_work / adaptation / 系列合集成员成边，连通分量 = 作品', () {
      final WorkGraph g = WorkGraph.build(
        links: <WorkGraphLink>[
          link(book('n1'), MediaLinkRelation.sameWork, book('m1')),
          link(book('n1'), MediaLinkRelation.adaptation, vc('7')),
        ],
        seriesCollections: <WorkSeriesCollection>[
          WorkSeriesCollection(
            id: 1,
            members: <MediaLinkEndpoint>[book('n1'), book('n2'), book('n3')],
          ),
          WorkSeriesCollection(
            id: 7,
            endpoint: vc('7'),
            members: <MediaLinkEndpoint>[ep('e1'), ep('e2')],
          ),
          WorkSeriesCollection(
            id: 9,
            members: <MediaLinkEndpoint>[game('g1'), game('g2')],
          ),
        ],
      );
      final Work w = g.workOf(ep('e2'))!;
      expect(w.members, <MediaLinkEndpoint>[
        book('m1'),
        book('n1'),
        book('n2'),
        book('n3'),
        vc('7'),
        ep('e1'),
        ep('e2'),
      ]);
      expect(w.identity, book('m1'));
      expect(w.seriesCollectionIds, <int>[1, 7]);
      expect(identical(g.workOf(book('n3')), w), isTrue);
      expect(g.works, hasLength(2));
      expect(g.workOf(game('g1'))!.members, <MediaLinkEndpoint>[
        game('g1'),
        game('g2'),
      ]);
      expect(g.workOf(book('unknown')), isNull);
    });

    test('主题曲 / 原声 / 声优连接不合并作品，建议态 / 否决也不成边', () {
      final WorkGraph g = WorkGraph.build(
        links: <WorkGraphLink>[
          // 一首合辑曲同时是两部动画的主题曲：两部动画仍是两部作品。
          link(track('t1'), MediaLinkRelation.themeSong, vc('1')),
          link(track('t1'), MediaLinkRelation.themeSong, vc('2')),
          link(album('a1'), MediaLinkRelation.soundtrack, vc('1')),
          link(album('a1'), MediaLinkRelation.soundtrack, vc('2')),
          link(track('t1'), MediaLinkRelation.cast, game('g1')),
          link(
            vc('1'),
            MediaLinkRelation.sameWork,
            vc('2'),
            status: WorkLinkStatus.suggested,
            source: MediaLinkSource.ai,
          ),
          link(
            vc('1'),
            MediaLinkRelation.adaptation,
            game('g1'),
            status: WorkLinkStatus.rejected,
          ),
        ],
      );
      expect(g.works, isEmpty);
      expect(g.workOf(vc('1'))!.members, <MediaLinkEndpoint>[vc('1')]);
      expect(g.workOf(track('t1'))!.members, <MediaLinkEndpoint>[track('t1')]);
    });

    test('关系网：卫星只取成员一跳，边带关系 / 方向 / 来源 / 状态', () {
      final WorkGraph g = WorkGraph.build(
        links: <WorkGraphLink>[
          link(book('n1'), MediaLinkRelation.adaptation, vc('1')),
          link(
            track('op'),
            MediaLinkRelation.themeSong,
            vc('1'),
            source: 'voiceprint',
          ),
          link(album('ost'), MediaLinkRelation.soundtrack, vc('1')),
          // 两跳：op 也是另一部动画的主题曲——那部动画不进关系网。
          link(track('op'), MediaLinkRelation.themeSong, vc('2')),
          link(track('ed'), MediaLinkRelation.themeSong, vc('2')),
        ],
      );
      final WorkNetwork net = g.networkOf(book('n1'))!;
      expect(net.nodes, <WorkNetworkNode>[
        (endpoint: book('n1'), role: WorkNetworkRole.member),
        (endpoint: album('ost'), role: WorkNetworkRole.satellite),
        (endpoint: track('op'), role: WorkNetworkRole.satellite),
        (endpoint: vc('1'), role: WorkNetworkRole.member),
      ]);
      expect(
        net.edges
            .map(
              (WorkNetworkEdge e) =>
                  '${e.from.key}-${e.relation.dbValue}-${e.to.key}'
                  '|${e.source}|${e.directed}|${e.effective}',
            )
            .toList(),
        <String>[
          'n1-adaptation-1|manual|true|true',
          'ost-soundtrack-1|manual|true|true',
          'op-theme_song-1|voiceprint|true|true',
        ],
      );
      // 卫星自己的关系网：它不属于任何作品，自成单成员作品。
      expect(g.networkOf(track('op'))!.work.members, <MediaLinkEndpoint>[
        track('op'),
      ]);
      expect(g.networkOf(track('nope')), isNull);
    });

    test('建议态连接：默认不出现；includeSuggested 时带出另一端并标记', () {
      final WorkGraph g = WorkGraph.build(
        links: <WorkGraphLink>[
          link(book('n1'), MediaLinkRelation.sameWork, book('m1')),
          link(
            book('n1'),
            MediaLinkRelation.adaptation,
            vc('1'),
            status: WorkLinkStatus.suggested,
            source: MediaLinkSource.mal,
          ),
          link(
            track('op'),
            MediaLinkRelation.themeSong,
            book('m1'),
            status: WorkLinkStatus.suggested,
          ),
          link(
            book('m1'),
            MediaLinkRelation.adaptation,
            game('g1'),
            status: WorkLinkStatus.rejected,
          ),
        ],
      );
      expect(g.workOf(book('n1'))!.members, <MediaLinkEndpoint>[
        book('m1'),
        book('n1'),
      ]);
      final WorkNetwork plain = g.networkOf(book('n1'))!;
      expect(plain.nodes.map((WorkNetworkNode n) => n.endpoint), <Object>[
        book('m1'),
        book('n1'),
      ]);
      expect(plain.edges, hasLength(1));

      final WorkNetwork withSuggested = g.networkOf(
        book('n1'),
        includeSuggested: true,
      )!;
      expect(withSuggested.nodes, <WorkNetworkNode>[
        (endpoint: book('m1'), role: WorkNetworkRole.member),
        (endpoint: book('n1'), role: WorkNetworkRole.member),
        (endpoint: track('op'), role: WorkNetworkRole.suggested),
        (endpoint: vc('1'), role: WorkNetworkRole.suggested),
      ]);
      expect(
        withSuggested.edges
            .map(
              (WorkNetworkEdge e) =>
                  '${e.from.key}-${e.relation.dbValue}-${e.to.key}|${e.status.name}',
            )
            .toList(),
        <String>[
          'm1-same_work-n1|effective',
          'n1-adaptation-1|suggested',
          'op-theme_song-m1|suggested',
        ],
        reason: '否决的连接永不出现',
      );
    });

    test('原作：单源标出，多源 / 有环不标', () {
      MediaLinkEndpoint? originalOf(List<WorkGraphLink> links) =>
          WorkGraph.build(links: links).workOf(links.first.from)!.original;

      expect(
        originalOf(<WorkGraphLink>[
          link(book('n1'), MediaLinkRelation.adaptation, vc('1')),
          link(vc('1'), MediaLinkRelation.adaptation, game('g1')),
          link(book('n1'), MediaLinkRelation.sameWork, book('m1')),
        ]),
        book('n1'),
      );
      expect(
        originalOf(<WorkGraphLink>[
          link(book('n1'), MediaLinkRelation.adaptation, vc('1')),
          link(game('g1'), MediaLinkRelation.adaptation, vc('1')),
        ]),
        isNull,
        reason: '两个源头',
      );
      expect(
        originalOf(<WorkGraphLink>[
          link(book('n1'), MediaLinkRelation.adaptation, vc('1')),
          link(vc('1'), MediaLinkRelation.adaptation, game('g1')),
          link(game('g1'), MediaLinkRelation.adaptation, book('n1')),
        ]),
        isNull,
        reason: '纯环没有源头',
      );
      expect(
        originalOf(<WorkGraphLink>[
          link(book('s'), MediaLinkRelation.adaptation, vc('1')),
          link(vc('1'), MediaLinkRelation.adaptation, game('g1')),
          link(game('g1'), MediaLinkRelation.adaptation, vc('1')),
        ]),
        isNull,
        reason: '单源但带环',
      );
      expect(
        originalOf(<WorkGraphLink>[
          link(book('n1'), MediaLinkRelation.sameWork, book('m1')),
        ]),
        isNull,
        reason: '没有 adaptation 边',
      );
      // 源头按系列合集归并：小说第 1、2 卷各连一条 adaptation 到动画 = 单源，
      // 原作取该系列的最小端点（第 3 卷没连也一样在组里）。
      final List<WorkGraphLink> volumes = <WorkGraphLink>[
        link(book('n2'), MediaLinkRelation.adaptation, vc('1')),
        link(book('n3'), MediaLinkRelation.adaptation, vc('1')),
        link(vc('1'), MediaLinkRelation.adaptation, game('g1')),
      ];
      final WorkSeriesCollection novelSeries = WorkSeriesCollection(
        id: 1,
        members: <MediaLinkEndpoint>[book('n3'), book('n2'), book('n1')],
      );
      expect(
        WorkGraph.build(
          links: volumes,
          seriesCollections: <WorkSeriesCollection>[novelSeries],
        ).workOf(vc('1'))!.original,
        book('n1'),
      );
      expect(
        WorkGraph.build(links: volumes).workOf(vc('1'))!.original,
        isNull,
        reason: '不在同一系列合集里的两卷仍是两个源头',
      );
      expect(
        WorkGraph.build(
          links: <WorkGraphLink>[
            ...volumes,
            link(game('m1'), MediaLinkRelation.adaptation, vc('1')),
          ],
          seriesCollections: <WorkSeriesCollection>[
            novelSeries,
            WorkSeriesCollection(
              id: 2,
              members: <MediaLinkEndpoint>[game('m1'), game('m2')],
            ),
          ],
        ).workOf(vc('1'))!.original,
        isNull,
        reason: '两个不同系列各是一个源头',
      );
      expect(
        WorkGraph.build(
          links: <WorkGraphLink>[
            ...volumes,
            link(game('g1'), MediaLinkRelation.adaptation, book('n1')),
          ],
          seriesCollections: <WorkSeriesCollection>[novelSeries],
        ).workOf(vc('1'))!.original,
        isNull,
        reason: '归并后有环',
      );
      // 视频合集端点与它的集同组：集连出去的 adaptation 源头是整个合集。
      expect(
        WorkGraph.build(
          links: <WorkGraphLink>[
            link(ep('e1'), MediaLinkRelation.adaptation, game('g1')),
            link(vc('1'), MediaLinkRelation.adaptation, game('g2')),
          ],
          seriesCollections: <WorkSeriesCollection>[
            WorkSeriesCollection(
              id: 3,
              endpoint: vc('1'),
              members: <MediaLinkEndpoint>[ep('e1'), ep('e2')],
            ),
          ],
        ).workOf(game('g2'))!.original,
        vc('1'),
      );
      // 建议态的 adaptation 不参与判定。
      expect(
        originalOf(<WorkGraphLink>[
          link(book('n1'), MediaLinkRelation.adaptation, vc('1')),
          link(
            game('g1'),
            MediaLinkRelation.adaptation,
            vc('1'),
            status: WorkLinkStatus.suggested,
          ),
        ]),
        book('n1'),
      );
    });

    test('代表端点：外部 id 视频合集 → 成员最多的系列合集 → 最小端点', () {
      final List<WorkGraphLink> links = <WorkGraphLink>[
        link(book('b1'), MediaLinkRelation.sameWork, game('g1')),
        link(book('b1'), MediaLinkRelation.adaptation, vc('5')),
      ];
      final List<WorkSeriesCollection> series = <WorkSeriesCollection>[
        WorkSeriesCollection(
          id: 2,
          members: <MediaLinkEndpoint>[book('b1'), book('b2')],
        ),
        WorkSeriesCollection(
          id: 3,
          members: <MediaLinkEndpoint>[game('g1'), game('g2'), game('g3')],
        ),
      ];

      final WorkRepresentative withExternal = WorkGraph.build(
        links: links,
        seriesCollections: series,
        externalIdEndpoints: <MediaLinkEndpoint>{vc('5'), book('b1')},
      ).workOf(book('b2'))!.representative;
      expect(withExternal.endpoint, vc('5'));
      expect(
        withExternal.reason,
        WorkRepresentativeReason.externalVideoCollection,
      );

      final WorkRepresentative bySeries = WorkGraph.build(
        links: links,
        seriesCollections: series,
        externalIdEndpoints: <MediaLinkEndpoint>{book('b1')},
      ).workOf(book('b2'))!.representative;
      expect(bySeries.endpoint, game('g1'), reason: '成员最多的是游戏系列');
      expect(bySeries.seriesCollectionId, 3);
      expect(bySeries.reason, WorkRepresentativeReason.largestSeriesCollection);

      final WorkRepresentative fallback = WorkGraph.build(
        links: links,
      ).workOf(vc('5'))!.representative;
      expect(fallback.endpoint, book('b1'));
      expect(fallback.reason, WorkRepresentativeReason.smallestEndpoint);
      expect(fallback.seriesCollectionId, isNull);
    });

    test('性质：同一份输入任意打乱顺序（含重复连接），结果完全相同', () {
      final List<MediaLinkEndpoint> pool = <MediaLinkEndpoint>[
        for (int i = 0; i < 6; i++) book('b$i'),
        for (int i = 0; i < 4; i++) vc('$i'),
        for (int i = 0; i < 6; i++) ep('e$i'),
        for (int i = 0; i < 4; i++) game('g$i'),
        for (int i = 0; i < 4; i++) track('t$i'),
        for (int i = 0; i < 2; i++) album('a$i'),
      ];
      for (int seed = 0; seed < 60; seed++) {
        final Random rnd = Random(seed);
        final List<WorkGraphLink> links = <WorkGraphLink>[
          for (int i = 0; i < 18; i++)
            link(
              pool[rnd.nextInt(pool.length)],
              MediaLinkRelation.values[rnd.nextInt(
                MediaLinkRelation.values.length,
              )],
              pool[rnd.nextInt(pool.length)],
              status: WorkLinkStatus.values[rnd.nextInt(3)],
              source: <String>['manual', 'ai', 'mal'][rnd.nextInt(3)],
            ),
        ];
        // 同一条连接重复出现（同向 / 反向）。
        for (int i = 0; i < 4; i++) {
          final WorkGraphLink l = links[rnd.nextInt(links.length)];
          links.add(
            link(
              l.relation.directed ? l.from : l.to,
              l.relation,
              l.relation.directed ? l.to : l.from,
              status: WorkLinkStatus.values[rnd.nextInt(3)],
              source: <String>['manual', 'ai'][rnd.nextInt(2)],
            ),
          );
        }
        final List<WorkSeriesCollection> series = <WorkSeriesCollection>[
          for (int c = 0; c < 3; c++)
            WorkSeriesCollection(
              id: c,
              endpoint: c == 0 ? vc('0') : null,
              members: <MediaLinkEndpoint>[
                for (int i = 0; i < 1 + rnd.nextInt(3); i++)
                  c == 0
                      ? ep('e${rnd.nextInt(6)}')
                      : pool[rnd.nextInt(pool.length)],
              ],
            ),
        ];
        final Set<MediaLinkEndpoint> external = <MediaLinkEndpoint>{
          vc('${rnd.nextInt(4)}'),
        };

        final String expected = _dump(
          WorkGraph.build(
            links: links,
            seriesCollections: series,
            externalIdEndpoints: external,
          ),
          pool,
        );
        for (int round = 0; round < 3; round++) {
          final Random shuffler = Random(seed * 31 + round);
          final List<WorkSeriesCollection> shuffledSeries =
              <WorkSeriesCollection>[
                for (final WorkSeriesCollection c in series)
                  WorkSeriesCollection(
                    id: c.id,
                    endpoint: c.endpoint,
                    members: List<MediaLinkEndpoint>.of(c.members)
                      ..shuffle(shuffler),
                  ),
              ]..shuffle(shuffler);
          final String actual = _dump(
            WorkGraph.build(
              links: List<WorkGraphLink>.of(links)..shuffle(shuffler),
              seriesCollections: shuffledSeries,
              externalIdEndpoints: external,
            ),
            pool,
          );
          expect(actual, expected, reason: 'seed=$seed round=$round');
        }
      }
    });
  });

  group('loadWorkGraph（内存库）', () {
    late FushiDatabase db;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() => db.close());

    /// 插一本书，返回 epub uid（合集成员行用 uid，图谱端点用 bookKey）。
    Future<String> addBook(String title, {String format = 'epub'}) async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'bk:$title',
          title: title,
          epubPath: '/b/$title',
          extractDir: '/b/$title',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1000,
          format: Value<String>(format),
        ),
      );
      return (await db.resolveEpubBookUid('bk:$title'))!;
    }

    Future<int> playlist(
      String name, {
      CollectionOrigin origin = CollectionOrigin.user,
      String? organizeKey,
    }) => db.createMediaCollection(
      name,
      collectionType: 'playlist',
      origin: origin,
      organizeKey: organizeKey,
    );

    Future<void> add(int id, MediaKind kind, String entryKey) =>
        db.addToCollection(id, kind, entryKey, userIntent: false);

    test('小说系列 + 漫画系列经一条已确认 same_work 连成一部作品', () async {
      final int novels = await playlist('物語', origin: CollectionOrigin.rule);
      for (final String t in <String>['物語 1', '物語 2', '物語 3']) {
        await add(novels, MediaKind.epub, await addBook(t));
      }
      final int manga = await playlist('物語（漫画）', origin: CollectionOrigin.rule);
      for (final String t in <String>['物語 漫画 1', '物語 漫画 2']) {
        await add(manga, MediaKind.epub, await addBook(t, format: 'manga'));
      }
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.sameWork,
        from: book('bk:物語 1'),
        to: book('bk:物語 漫画 1'),
      );

      final WorkGraph g = await loadWorkGraph(db);
      final Work w = g.workOf(book('bk:物語 3'))!;
      expect(w.members.toSet(), <MediaLinkEndpoint>{
        book('bk:物語 1'),
        book('bk:物語 2'),
        book('bk:物語 3'),
        book('bk:物語 漫画 1'),
        book('bk:物語 漫画 2'),
      });
      expect(identical(g.workOf(book('bk:物語 漫画 2')), w), isTrue);
      expect(w.seriesCollectionIds, <int>[novels, manga]..sort());
      expect(w.representative.seriesCollectionId, novels, reason: '成员最多');
    });

    test('用户随手建的阅读清单不成边；像系列的用户合集才算', () async {
      final int reading = await playlist('想读');
      for (final String t in <String>['とらドラ!', '灼眼のシャナ', '志乃と恋 1']) {
        await add(reading, MediaKind.epub, await addBook(t));
      }
      // 同系列过半 + 一本无关的：算系列。配对 EPUB 的 srt 归到那本书，未配对的忽略。
      final int shino = await playlist('志乃');
      for (final String t in <String>['志乃と恋 2', '志乃と恋 3', '無関係']) {
        await add(shino, MediaKind.epub, await addBook(t));
      }
      await db.upsertSrtBook(
        SrtBooksCompanion.insert(
          uid: 'srt_paired',
          title: '志乃と恋 2',
          srtPath: '/s/a.srt',
          importedAt: 1000,
          bookKey: const Value<String>('bk:志乃と恋 2'),
        ),
      );
      await db.upsertSrtBook(
        SrtBooksCompanion.insert(
          uid: 'srt_lonely',
          title: 'lonely',
          srtPath: '/s/b.srt',
          importedAt: 1000,
        ),
      );
      await add(shino, MediaKind.srt, 'srt_paired');
      await add(shino, MediaKind.srt, 'srt_lonely');
      // 有整理分组键的用户合集（整理器建后被用户接手）照算。
      final int keyed = await playlist('Keyed', organizeKey: 't:books:x');
      for (final String t in <String>['甲', '乙']) {
        await add(keyed, MediaKind.epub, await addBook(t));
      }
      // 主题型 collection 不算。
      final int topic = await db.createMediaCollection(
        '百合',
        origin: CollectionOrigin.rule,
      );
      for (final String t in <String>['丙', '丁']) {
        await add(topic, MediaKind.epub, await addBook(t));
      }

      final WorkGraph g = await loadWorkGraph(db);
      expect(g.workOf(book('bk:とらドラ!')), isNull, reason: '阅读清单不进图');
      expect(g.workOf(book('bk:志乃と恋 1')), isNull);
      expect(g.workOf(book('bk:志乃と恋 2'))!.members, <MediaLinkEndpoint>[
        book('bk:志乃と恋 2'),
        book('bk:志乃と恋 3'),
        book('bk:無関係'),
      ]);
      expect(g.workOf(book('bk:甲'))!.members, hasLength(2));
      expect(g.workOf(book('bk:丙')), isNull);
      expect(g.works, hasLength(2));

      expect(
        isWorkSeriesCollection(
          collectionType: 'playlist',
          sourceFolderPath: null,
          origin: CollectionOrigin.user,
          organizeKey: null,
          hasVideo: false,
          hasWorkIdentity: false,
          memberCount: 4,
          bookTitles: <String>['志乃と恋 1', '志乃と恋 2', 'A', 'B'],
        ),
        isFalse,
        reason: '恰好一半不算过半',
      );
      expect(
        isWorkSeriesCollection(
          collectionType: 'playlist',
          sourceFolderPath: '/videos/x',
          origin: CollectionOrigin.folder,
          organizeKey: null,
          hasVideo: true,
          hasWorkIdentity: false,
          memberCount: 2,
          bookTitles: const <String>[],
        ),
        isTrue,
        reason: '含视频的目录合集就是一部作品的各集，不要求外部 id',
      );
      expect(
        isWorkSeriesCollection(
          collectionType: 'playlist',
          sourceFolderPath: '/books/x',
          origin: CollectionOrigin.folder,
          organizeKey: 'k',
          hasVideo: false,
          hasWorkIdentity: false,
          memberCount: 2,
          bookTitles: const <String>['志乃と恋 1', '志乃と恋 2'],
        ),
        isFalse,
        reason: '只含书的目录合集只是磁盘目录',
      );
      expect(
        isWorkSeriesCollection(
          collectionType: 'playlist',
          sourceFolderPath: null,
          origin: CollectionOrigin.user,
          organizeKey: null,
          hasVideo: true,
          hasWorkIdentity: false,
          memberCount: 1,
          bookTitles: const <String>[],
        ),
        isTrue,
        reason: '只装一个视频的用户合集就是那个视频的外壳，与它折成一个节点',
      );
      expect(
        isWorkSeriesCollection(
          collectionType: 'playlist',
          sourceFolderPath: null,
          origin: CollectionOrigin.user,
          organizeKey: null,
          hasVideo: true,
          hasWorkIdentity: false,
          memberCount: 2,
          bookTitles: const <String>[],
        ),
        isFalse,
        reason: '两个以上视频的用户合集仍要作品身份才算系列',
      );
    });

    test('视频合集端点的连接把整个合集的集带进作品；主题曲是卫星', () async {
      final int anime = await playlist('アニメ', origin: CollectionOrigin.rule);
      for (final String e in <String>['ep1', 'ep2', 'ep3']) {
        await add(anime, MediaKind.video, e);
      }
      // 用户建的视频合集，绑了 AniList id = 带作品身份，算系列。
      final int movie = await playlist('劇場版');
      for (final String e in <String>['mv1', 'mv2']) {
        await add(movie, MediaKind.video, e);
      }
      await (db.update(db.mediaCollections)
            ..where(($MediaCollectionsTable t) => t.id.equals(movie)))
          .write(const MediaCollectionsCompanion(anilistId: Value<int?>(42)));
      // 目录视频合集：不要求外部 id，集经合集端点相连。
      final int folderVideo = await playlist('[Sub] Folder Anime');
      for (final String e in <String>['f1', 'f2']) {
        await add(folderVideo, MediaKind.video, e);
      }
      // 只含书的目录合集：不成边。
      final int folderBooks = await playlist('books dir');
      for (final String t in <String>['目录书 甲', '目录书 乙']) {
        await add(folderBooks, MediaKind.epub, await addBook(t));
      }
      for (final int id in <int>[folderVideo, folderBooks]) {
        await (db.update(
          db.mediaCollections,
        )..where(($MediaCollectionsTable t) => t.id.equals(id))).write(
          MediaCollectionsCompanion(
            sourceFolderPath: Value<String?>('/lib/$id'),
            origin: Value<String>(CollectionOrigin.folder.dbValue),
          ),
        );
      }
      // 没有作品身份的用户视频合集：集之间不成边。
      final int loose = await playlist('あとで見る');
      for (final String e in <String>['x1', 'x2']) {
        await add(loose, MediaKind.video, e);
      }
      await addBook('原作 1');
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book('bk:原作 1'),
        to: videoCollectionEndpoint(anime),
      );
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.sameWork,
        from: ep('ep2'),
        to: ep('mv1'),
      );
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.themeSong,
        from: track('op'),
        to: videoCollectionEndpoint(anime),
      );
      await db.proposeMediaLink(
        relation: MediaLinkRelation.soundtrack,
        from: album('ost'),
        to: videoCollectionEndpoint(anime),
        source: MediaLinkSource.ai,
      );

      final WorkGraph g = await loadWorkGraph(db);
      final Work w = g.workOf(book('bk:原作 1'))!;
      expect(w.members.toSet(), <MediaLinkEndpoint>{
        book('bk:原作 1'),
        videoCollectionEndpoint(anime),
        videoCollectionEndpoint(movie),
        ep('ep1'),
        ep('ep2'),
        ep('ep3'),
        ep('mv1'),
        ep('mv2'),
      });
      expect(w.original, book('bk:原作 1'));
      expect(w.representative.endpoint, videoCollectionEndpoint(movie));
      expect(
        w.representative.reason,
        WorkRepresentativeReason.externalVideoCollection,
      );
      expect(g.workOf(ep('x1')), isNull);
      expect(g.workOf(ep('f2'))!.members, <MediaLinkEndpoint>[
        videoCollectionEndpoint(folderVideo),
        ep('f1'),
        ep('f2'),
      ]);
      expect(g.workOf(book('bk:目录书 甲')), isNull);
      expect(g.workOf(track('op'))!.members, <MediaLinkEndpoint>[track('op')]);

      final WorkNetwork net = g.networkOf(ep('ep3'), includeSuggested: true)!;
      final Map<MediaLinkEndpoint, WorkNetworkRole> roles =
          <MediaLinkEndpoint, WorkNetworkRole>{
            for (final WorkNetworkNode n in net.nodes) n.endpoint: n.role,
          };
      expect(roles[track('op')], WorkNetworkRole.satellite);
      expect(roles[album('ost')], WorkNetworkRole.suggested);
      expect(roles[ep('ep1')], WorkNetworkRole.member);
      final WorkNetworkEdge opEdge = net.edges.singleWhere(
        (WorkNetworkEdge e) => e.relation == MediaLinkRelation.themeSong,
      );
      expect(opEdge.from, track('op'));
      expect(opEdge.to, videoCollectionEndpoint(anime));
      expect(opEdge.effective, isTrue);
      expect(opEdge.source, MediaLinkSource.manual);
      expect(
        g.networkOf(ep('ep3'))!.nodes.map((WorkNetworkNode n) => n.endpoint),
        isNot(contains(album('ost'))),
      );
    });
  });
}

/// 把整张图的可观察结果写成一串，供乱序性质测试比较。
String _dump(WorkGraph g, List<MediaLinkEndpoint> pool) {
  String e(MediaLinkEndpoint? x) =>
      x == null ? '-' : '${x.kind.dbValue}:${x.key}';
  String work(Work w) =>
      '[${w.members.map(e).join(',')}] id=${e(w.identity)} '
      'orig=${e(w.original)} rep=${e(w.representative.endpoint)}/'
      '${w.representative.reason.name}/${w.representative.seriesCollectionId} '
      'series=${w.seriesCollectionIds}';
  final StringBuffer out = StringBuffer();
  for (final Work w in g.works) {
    out.writeln(work(w));
  }
  for (final MediaLinkEndpoint p in pool) {
    for (final bool suggested in <bool>[false, true]) {
      final WorkNetwork? net = g.networkOf(p, includeSuggested: suggested);
      if (net == null) {
        out.writeln('${e(p)} -> null');
        continue;
      }
      out.writeln('${e(p)} -> ${work(net.work)}');
      for (final WorkNetworkNode n in net.nodes) {
        out.writeln('  node ${e(n.endpoint)} ${n.role.name}');
      }
      for (final WorkNetworkEdge edge in net.edges) {
        out.writeln(
          '  edge ${e(edge.from)} ${edge.relation.dbValue} ${e(edge.to)} '
          '${edge.source} ${edge.status.name}',
        );
      }
    }
  }
  return out.toString();
}
