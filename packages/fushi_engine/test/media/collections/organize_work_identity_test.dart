// BUG-5460：AI 整理 / AI 管库的合集归属改动不得与条目的权威作品身份矛盾。
//
// 用户真实数据（媒体服务器入库）：同一部剧 13 集按服务器剧名收进同一个合集
// （`adoptRemoteCollectionMember`）。一次 agent 复查把 13 集全部从这个合集移出（合集被
// 移空删掉），之后一次自动整理又把这 13 集放进另一部剧的合集。两步的 AI 置信度都是
// high，本地裁决没有一条拦它们。这里用真实的入库 / 收养路径建库，喂假的 AI 回复 /
// 变更集原样复现两步，断言本地校验把它们拒掉；同时断言真正放错的那一集照常能移走。
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_library_organize_assistant.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_facts.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_service.dart';
import 'package:fushi_engine/media/library_agent/library_changeset.dart';
import 'package:fushi_engine/media/video/media_server_video_path.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/remote_collection_adoption_service.dart';
import 'package:test/test.dart';

const String _server = 'jellyfin-1';

/// 与 app `MediaServerBookSpec.encode` 同形的 spec（封面 / 断点不落库）。
String _mediaServerSpec(RemoteVideoInfo info, String workId) =>
    jsonEncode(<String, Object?>{
      'kind': kMediaServerStreamSpecKind,
      'serverId': _server,
      'workId': workId,
      'info': info.toJson()
        ..remove('coverUrl')
        ..remove('positionMs')
        ..remove('positionUpdatedAtMs'),
    });

void main() {
  group('remoteSeriesKeyOfStreamSpec', () {
    test('媒体服务器单集：服务器 + 入库时的剧归属；电影没有剧归属', () {
      const RemoteVideoInfo episode = RemoteVideoInfo(
        id: 'e1',
        title: 'Show A S01E01',
        collection: RemoteCollectionMembership(
          collectionName: 'Show A',
          collectionType: 'playlist',
          sortIndex: 10001,
        ),
      );
      final String? key = remoteSeriesKeyOfStreamSpec(
        _mediaServerSpec(episode, 'series-h'),
      );
      expect(key, isNotNull);
      // 同一部剧：入库时点的是整部剧、某一季还是单集（workId 不同）都是同一个身份。
      expect(
        remoteSeriesKeyOfStreamSpec(_mediaServerSpec(episode, 'season-1')),
        key,
      );
      expect(
        remoteSeriesKeyOfStreamSpec(
          _mediaServerSpec(
            const RemoteVideoInfo(
              id: 'e2',
              title: 'Show B S01E01',
              collection: RemoteCollectionMembership(
                collectionName: 'Show B',
                collectionType: 'playlist',
                sortIndex: 10001,
              ),
            ),
            'series-f',
          ),
        ),
        isNot(key),
      );
      expect(
        remoteSeriesKeyOfStreamSpec(
          _mediaServerSpec(
            const RemoteVideoInfo(id: 'm1', title: 'A Movie'),
            'm1',
          ),
        ),
        isNull,
      );
    });

    test('在线视频源：同扩展、同源、同作品 URL', () {
      String spec(String url) => jsonEncode(<String, Object?>{
        'kind': kAnimeSourceStreamSpecKind,
        'extensionPackage': 'pkg',
        'sourceId': '7',
        'anime': <String, Object?>{'url': url, 'title': 'T'},
        'episode': <String, Object?>{'url': '$url/1', 'name': 'E1'},
      });
      expect(remoteSeriesKeyOfStreamSpec(spec('/a')), isNotNull);
      expect(
        remoteSeriesKeyOfStreamSpec(spec('/a')),
        remoteSeriesKeyOfStreamSpec(spec('/a')),
      );
      expect(
        remoteSeriesKeyOfStreamSpec(spec('/a')),
        isNot(remoteSeriesKeyOfStreamSpec(spec('/b'))),
      );
    });

    test('不是这两种 spec / 坏 JSON / 空：null，不抛', () {
      expect(remoteSeriesKeyOfStreamSpec(null), isNull);
      expect(remoteSeriesKeyOfStreamSpec(''), isNull);
      expect(remoteSeriesKeyOfStreamSpec('{not json'), isNull);
      expect(remoteSeriesKeyOfStreamSpec('[1]'), isNull);
      expect(
        remoteSeriesKeyOfStreamSpec('{"subtitleUrl":"https://x/y.srt"}'),
        isNull,
      );
      expect(
        remoteSeriesKeyOfStreamSpec('{"kind":"media-server","info":{}}'),
        isNull,
      );
    });
  });

  group('否决规则（纯函数）', () {
    const OrganizeWorkIdentity w = OrganizeWorkIdentity(
      seriesKey: 'ms:a\u0000W',
    );
    const OrganizeWorkIdentity f = OrganizeWorkIdentity(
      seriesKey: 'ms:a\u0000F',
    );
    const OrganizeWorkIdentity otherServer = OrganizeWorkIdentity(
      seriesKey: 'ms:b\u0000F',
    );
    const OrganizeWorkIdentity scraped = OrganizeWorkIdentity(
      externalWorkKey: 'anilist:1',
    );

    test('规则 1：合集里另有同一部作品的成员才不许移出', () {
      expect(
        organizeIdentityForbidsRelease(<String, OrganizeWorkIdentity>{
          'x': w,
          'y': w,
        }, 'x'),
        isTrue,
      );
      // 只有它一条是这部剧：放错了的那一集，可以移出。
      expect(
        organizeIdentityForbidsRelease(<String, OrganizeWorkIdentity>{
          'x': f,
          'y': w,
          'z': w,
        }, 'x'),
        isFalse,
      );
      // 刮削作品 id 相同同样算同一部作品。
      expect(
        organizeIdentityForbidsRelease(<String, OrganizeWorkIdentity>{
          'x': scraped,
          'y': scraped,
        }, 'x'),
        isTrue,
      );
      // 整部作品一起离开：合集里留着同一来源的另一部剧 → 它是混进来的，放行。
      expect(
        organizeIdentityForbidsRelease(
          <String, OrganizeWorkIdentity>{'x': w, 'y': w, 'z': f},
          'x',
          leaving: <String>{'x', 'y'},
        ),
        isFalse,
      );
      // 整部作品一起离开它自己的合集（没有可比的别的作品留下）→ 移空，拒绝；
      // 别的来源的剧不可比，不算。
      expect(
        organizeIdentityForbidsRelease(
          <String, OrganizeWorkIdentity>{'x': w, 'y': w, 'z': otherServer},
          'x',
          leaving: <String>{'x', 'y'},
        ),
        isTrue,
      );
      // …除非去处就是这部作品的合集（归拢）。
      expect(
        organizeIdentityForbidsRelease(
          <String, OrganizeWorkIdentity>{'x': w},
          'x',
          destination: <OrganizeWorkIdentity>[w],
        ),
        isFalse,
      );
      // 一起离开的只是一部分 = 拆散，拒绝。
      expect(
        organizeIdentityForbidsRelease(
          <String, OrganizeWorkIdentity>{'x': w, 'y': w, 'z': w, 'q': f},
          'x',
          leaving: <String>{'x', 'y'},
        ),
        isTrue,
      );
      // 刮到不同作品同样可比：整部移出放行。
      expect(
        organizeIdentityForbidsRelease(
          <String, OrganizeWorkIdentity>{
            'x': scraped,
            'y': scraped,
            'z': const OrganizeWorkIdentity(externalWorkKey: 'anilist:2'),
          },
          'x',
          leaving: <String>{'x', 'y'},
        ),
        isFalse,
      );
      // 没身份的不受限。
      expect(
        organizeIdentityForbidsRelease(<String, OrganizeWorkIdentity>{
          'y': w,
        }, 'x'),
        isFalse,
      );
    });

    test('规则 2：同一来源的另一部剧不许放进来；别的来源 / 没身份 / 空合集不受限', () {
      expect(OrganizeSeriesGate(<OrganizeWorkIdentity>[f]).admit(w), isFalse);
      expect(OrganizeSeriesGate(<OrganizeWorkIdentity>[f, w]).admit(w), isTrue);
      expect(
        OrganizeSeriesGate(<OrganizeWorkIdentity>[otherServer]).admit(w),
        isTrue,
      );
      expect(
        OrganizeSeriesGate(<OrganizeWorkIdentity>[scraped]).admit(w),
        isTrue,
      );
      expect(OrganizeSeriesGate().admit(w), isTrue);
      expect(
        OrganizeSeriesGate(<OrganizeWorkIdentity>[f]).admit(scraped),
        isTrue,
      );
      // 同一批里先放进去的也算。
      final OrganizeSeriesGate fresh = OrganizeSeriesGate();
      expect(fresh.admit(w), isTrue);
      expect(fresh.admit(f), isFalse);
      // admitAll：一条冲突就一条都不记。
      final OrganizeSeriesGate all = OrganizeSeriesGate();
      expect(all.admitAll(<OrganizeWorkIdentity>[w, f]), isFalse);
      expect(all.admit(f), isTrue);
    });
  });

  group('真实入库路径：媒体服务器的剧合集', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    /// 走「加入媒体库」同一条路：落 video_books（spec 带入库快照）+ 按剧名收养进
    /// playlist 合集。[adopt] = false 模拟合集已被删、各集散在库里。
    Future<List<String>> addShow(
      String series,
      String prefix,
      int count, {
      bool adopt = true,
    }) async {
      final List<String> uids = <String>[];
      for (int n = 1; n <= count; n++) {
        final String id = '$prefix$n';
        final RemoteVideoInfo info = RemoteVideoInfo(
          id: id,
          title: '$series S01E${n.toString().padLeft(2, '0')}',
          collection: RemoteCollectionMembership(
            collectionName: series,
            collectionType: 'playlist',
            sortIndex: 10000 + n,
          ),
        );
        await db.upsertVideoBook(
          VideoBooksCompanion.insert(
            bookUid: id,
            title: info.title,
            videoPath: mediaServerVideoPath(itemId: id, label: info.title),
            streamSpecJson: Value<String?>(
              _mediaServerSpec(info, 'series-$prefix'),
            ),
          ),
        );
        if (adopt) {
          await RemoteCollectionAdoptionService(db).adoptVideo(info);
        }
        uids.add(id);
      }
      return uids;
    }

    Future<int> collectionId(String name) async =>
        (await db.getMediaCollectionByNaturalKey(name, 'playlist'))!.id;

    Future<Set<String>> members(String name) async => <String>{
      for (final MediaCollectionItemRow i in await db.getCollectionItems(
        await collectionId(name),
      ))
        i.entryKey,
    };

    Future<({LibraryOrganizeFacts facts, OrganizeChunk chunk})> world() async {
      final LibraryOrganizeFacts facts = await loadLibraryOrganizeFacts(
        db,
        CollectionShelfDomain.video,
      );
      return (
        facts: facts,
        chunk: buildOrganizeChunk(facts, <String>[
          for (final OrganizeEntry e in facts.entries) e.memberKey,
        ])!,
      );
    }

    String cRef(OrganizeChunk chunk, int id) => chunk.collectionIdOf(
      chunk.collections.indexWhere((OrganizeCollectionFact c) => c.id == id),
    );

    List<int> indexes(OrganizeChunk chunk, List<String> uids) => <int>[
      for (final String u in uids)
        chunk.entries.indexWhere((OrganizeEntry e) => e.entryKey == u),
    ];

    List<OrganizeAction> plan(
      ({LibraryOrganizeFacts facts, OrganizeChunk chunk}) w,
      AiOrganizeReply reply,
    ) => planOrganizeReply(
      facts: w.facts,
      chunk: w.chunk,
      reply: reply,
      trigger: OrganizeTrigger.auto,
      tagPrefix: 'Series: ',
    ).actions;

    Future<LibraryChangesetOutcome> apply(List<Map<String, Object?>> changes) =>
        applyLibraryChangeset(
          db,
          parseLibraryChangeset(<String, Object?>{'changes': changes}),
        );

    String ref(String uid) => '${MediaKind.video.dbValue}:$uid';

    test('事实：收养来的剧合集带着每一集的剧身份，媒体服务器路径不当文件夹发给 AI', () async {
      final List<String> h = await addShow('Show A', 'h', 3);
      final ({LibraryOrganizeFacts facts, OrganizeChunk chunk}) w =
          await world();
      final OrganizeCollectionFact showA = w.facts.collections.single;
      expect(showA.origin, CollectionOrigin.user);
      expect(showA.memberIdentities.keys, hasLength(3));
      final Set<String?> series = <String?>{
        for (final OrganizeWorkIdentity i in showA.memberIdentities.values)
          i.seriesKey,
      };
      expect(series, hasLength(1));
      expect(series.single, isNotNull);
      for (final OrganizeEntry e in w.facts.entries) {
        expect(e.identity.seriesKey, series.single);
        // 目录段是条目 id，不是文件夹：不发（空串不进提示词）。
        expect(e.item.folder ?? '', isEmpty);
      }
      expect(h, hasLength(3));
    });

    test('复现第 1 步（AI 整理）：把一部剧的全部集从它自己的合集里移出 → 拒绝', () async {
      final List<String> h = await addShow('Show A', 'h', 13);
      final int showA = await collectionId('Show A');
      final ({LibraryOrganizeFacts facts, OrganizeChunk chunk}) w =
          await world();
      final List<OrganizeAction> actions = plan(
        w,
        AiOrganizeReply(
          evictions: <AiOrganizeEvictionProposal>[
            AiOrganizeEvictionProposal(
              collection: cRef(w.chunk, showA),
              members: indexes(w.chunk, h),
              confidence: AiOrganizeConfidence.high,
              reason:
                  'Multiple episodes of Show A found in an existing '
                  'collection could lead to confusion.',
            ),
          ],
        ),
      );
      expect(actions, isEmpty);
    });

    test('复现第 2 步（AI 整理）：把一部剧的散集放进另一部剧的合集 → 拒绝', () async {
      final List<String> h = await addShow('Show A', 'h', 13, adopt: false);
      await addShow('Show B', 'f', 3);
      final int showB = await collectionId('Show B');
      final ({LibraryOrganizeFacts facts, OrganizeChunk chunk}) w =
          await world();
      final List<OrganizeAction> actions = plan(
        w,
        AiOrganizeReply(
          groups: <AiOrganizeGroupProposal>[
            AiOrganizeGroupProposal(
              members: indexes(w.chunk, h),
              into: cRef(w.chunk, showB),
              name: 'Show B',
              level: AiOrganizeLevel.work,
              confidence: AiOrganizeConfidence.high,
            ),
          ],
        ),
      );
      expect(actions, isEmpty);
    });

    test('AI 整理：一部剧的散集各自成组 / 并回同一部剧的合集照常执行', () async {
      final List<String> h = await addShow('Show A', 'h', 4, adopt: false);
      final ({LibraryOrganizeFacts facts, OrganizeChunk chunk}) w =
          await world();
      final List<OrganizeAction> actions = plan(
        w,
        AiOrganizeReply(
          groups: <AiOrganizeGroupProposal>[
            AiOrganizeGroupProposal(
              members: indexes(w.chunk, h),
              name: 'Show A',
              originalTitle: 'ショーA',
              level: AiOrganizeLevel.work,
              confidence: AiOrganizeConfidence.high,
            ),
          ],
        ),
      );
      expect(actions.single.kind, OrganizeActionKind.create);
      expect(actions.single.entries, hasLength(4));
    });

    test('AI 整理：一个新组混了两部来源剧 → 不建合集（降为系列标签）', () async {
      final List<String> h = await addShow('Show A', 'h', 2, adopt: false);
      final List<String> f = await addShow('Show B', 'f', 2, adopt: false);
      final ({LibraryOrganizeFacts facts, OrganizeChunk chunk}) w =
          await world();
      final List<OrganizeAction> actions = plan(
        w,
        AiOrganizeReply(
          groups: <AiOrganizeGroupProposal>[
            AiOrganizeGroupProposal(
              members: indexes(w.chunk, <String>[...h, ...f]),
              name: 'Mixed',
              originalTitle: 'Mixed',
              level: AiOrganizeLevel.work,
              confidence: AiOrganizeConfidence.high,
            ),
          ],
        ),
      );
      expect(
        actions.map((OrganizeAction a) => a.kind),
        isNot(contains(OrganizeActionKind.create)),
      );
    });

    test('AI 整理：真正放错的那一集（别的剧的集）照常能挪回它自己的剧', () async {
      await addShow('Show A', 'h', 3);
      await addShow('Show B', 'f', 2);
      final int showA = await collectionId('Show A');
      final int showB = await collectionId('Show B');
      // 一集 Show B 被放进了 Show A（AI 身份，不钉住）。
      await db.addToCollection(showA, MediaKind.video, 'f1', userIntent: false);
      final ({LibraryOrganizeFacts facts, OrganizeChunk chunk}) w =
          await world();
      final List<OrganizeAction> actions = plan(
        w,
        AiOrganizeReply(
          evictions: <AiOrganizeEvictionProposal>[
            AiOrganizeEvictionProposal(
              collection: cRef(w.chunk, showA),
              members: indexes(w.chunk, <String>['f1']),
              into: cRef(w.chunk, showB),
              confidence: AiOrganizeConfidence.high,
              reason: 'Episode 1 of Show B',
            ),
          ],
        ),
      );
      // f1 已经在 Show B 里：只剩从 Show A 移出这一步。
      expect(actions.single.kind, OrganizeActionKind.evict);
      expect(actions.single.targetCollectionId, showA);
      expect(actions.single.entries.single.entryKey, 'f1');
    });

    test('AI 整理：两部来源剧的合集不合并', () async {
      await addShow('Show A', 'h', 2);
      await addShow('Show B', 'f', 2);
      final int showA = await collectionId('Show A');
      final int showB = await collectionId('Show B');
      final ({LibraryOrganizeFacts facts, OrganizeChunk chunk}) w =
          await world();
      expect(
        plan(
          w,
          AiOrganizeReply(
            merges: <AiOrganizeMergeProposal>[
              AiOrganizeMergeProposal(
                collections: <String>[
                  cRef(w.chunk, showA),
                  cRef(w.chunk, showB),
                ],
                confidence: AiOrganizeConfidence.high,
              ),
            ],
          ),
        ),
        isEmpty,
      );
    });

    test('复现第 1 步（AI 管库变更集）：拆散 / 全部单独放 → work_identity，合集原样', () async {
      final List<String> h = await addShow('Show A', 'h', 13);
      final int showA = await collectionId('Show A');
      final LibraryChangesetOutcome o = await apply(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'dissolve',
          'collection': 'C$showA',
          'why': 'Multiple episodes of Show A could lead to confusion.',
        },
        <String, Object?>{
          'op': 'move',
          'items': <String>[for (final String u in h) ref(u)],
          'to': 'standalone',
          'why': 'Multiple episodes of Show A could lead to confusion.',
        },
      ]);
      expect(o.applied, isEmpty);
      expect(o.skipped.map((Map<String, Object?> s) => s['reason']), <String>[
        LibraryChangeSkip.workIdentity,
        LibraryChangeSkip.workIdentity,
      ]);
      expect(o.runId, isNull);
      expect(await members('Show A'), h.toSet());
    });

    test('复现第 2 步（AI 管库变更集）：散集放进另一部剧的合集 → work_identity', () async {
      final List<String> h = await addShow('Show A', 'h', 13, adopt: false);
      final List<String> f = await addShow('Show B', 'f', 3);
      final int showB = await collectionId('Show B');
      final LibraryChangesetOutcome o = await apply(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'move',
          'items': <String>[for (final String u in h) ref(u)],
          'to': 'C$showB',
          'why': 'same show',
        },
      ]);
      expect(o.applied, isEmpty);
      expect(o.skipped.single['reason'], LibraryChangeSkip.workIdentity);
      expect(await members('Show B'), f.toSet());
    });

    test('AI 管库变更集：放错的那一集照常挪走；两部剧的合集不合并', () async {
      await addShow('Show A', 'h', 3);
      final List<String> f = await addShow('Show B', 'f', 2);
      // 同一部剧的另一集被放进了 Show A（AI 身份，不钉住）。
      await addShow('Show B', 'g', 1, adopt: false);
      final int showA = await collectionId('Show A');
      final int showB = await collectionId('Show B');
      await db.addToCollection(showA, MediaKind.video, 'g1', userIntent: false);
      final LibraryChangesetOutcome o = await apply(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'move',
          'items': <String>[ref('g1')],
          'from': 'C$showA',
          'to': 'C$showB',
          'why': 'Episode 2 of Show B',
        },
        <String, Object?>{
          'op': 'merge',
          'into': 'C$showA',
          'from': <String>['C$showB'],
          'why': 'same series',
        },
      ]);
      expect(o.applied.single['i'], 0);
      expect(o.skipped.single['reason'], LibraryChangeSkip.workIdentity);
      expect(await members('Show B'), <String>{...f, 'g1'});
      expect(await members('Show A'), <String>{'h1', 'h2', 'h3'});
    });

    // 这个 bug 第 2 步造成的现场：一整部剧（不止一集）被塞进了另一部剧的合集。规则 1
    // 只拦「拆散」与「把一部剧从它自己的合集里移空」，一整部剧从别人的合集里挪走要放行，
    // 否则坏现场永远修不回来。
    test('AI 整理：被塞进另一部剧合集的一整部剧能整体挪走', () async {
      final List<String> h = await addShow('Show A', 'h', 3, adopt: false);
      await addShow('Show B', 'f', 2);
      final int showB = await collectionId('Show B');
      for (final String u in h) {
        await db.addToCollection(showB, MediaKind.video, u, userIntent: false);
      }
      final ({LibraryOrganizeFacts facts, OrganizeChunk chunk}) w =
          await world();
      final List<OrganizeAction> actions = plan(
        w,
        AiOrganizeReply(
          evictions: <AiOrganizeEvictionProposal>[
            AiOrganizeEvictionProposal(
              collection: cRef(w.chunk, showB),
              members: indexes(w.chunk, h),
              confidence: AiOrganizeConfidence.high,
              reason: 'Show A episodes are not Show B',
            ),
          ],
        ),
      );
      expect(actions.single.kind, OrganizeActionKind.evict);
      expect(
        actions.single.entries.map((OrganizeEntry e) => e.entryKey).toSet(),
        h.toSet(),
      );
      // 只挪一部分 = 拆散，仍然拒绝。
      final List<OrganizeAction> partial = plan(
        w,
        AiOrganizeReply(
          evictions: <AiOrganizeEvictionProposal>[
            AiOrganizeEvictionProposal(
              collection: cRef(w.chunk, showB),
              members: indexes(w.chunk, h.sublist(0, 2)),
              confidence: AiOrganizeConfidence.high,
              reason: 'Show A episodes are not Show B',
            ),
          ],
        ),
      );
      expect(partial, isEmpty);
    });

    test('AI 管库变更集：被塞进另一部剧合集的一整部剧能整体挪出；剧自己的合集不能移空', () async {
      final List<String> h = await addShow('Show A', 'h', 3, adopt: false);
      final List<String> f = await addShow('Show B', 'f', 2);
      final int showB = await collectionId('Show B');
      for (final String u in h) {
        await db.addToCollection(showB, MediaKind.video, u, userIntent: false);
      }
      final LibraryChangesetOutcome o = await apply(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'move',
          'items': <String>[for (final String u in h) ref(u)],
          'from': 'C$showB',
          'to': 'new:Show A',
          'why': 'Show A episodes are not Show B',
        },
        <String, Object?>{
          'op': 'move',
          'items': <String>[for (final String u in f) ref(u)],
          'to': 'standalone',
          'why': 'confusing',
        },
      ]);
      expect(o.applied.single['i'], 0);
      expect(o.skipped.single['reason'], LibraryChangeSkip.workIdentity);
      expect(await members('Show A'), h.toSet());
      expect(await members('Show B'), f.toSet());
    });
  });
}
