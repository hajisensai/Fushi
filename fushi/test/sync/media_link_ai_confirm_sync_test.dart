import 'dart:convert';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/collection_sync_engine.dart';
import 'package:fushi_engine/sync/media_link_sync.dart';

/// AI 库管家设计稿 §5.3 / §7 / §13 的同步口径（v159）：
/// - 作品图谱：`confirmedBy` 跨端合并——同一时钟 user 压过 ai；否决晚于 AI 那一端的
///   基线就胜；旧版对端丢字段回传不冲掉 AI 生效；3 台设备随机操作、随机同步顺序，
///   最终逐项一致，且用户确认 / 否决永不被 AI 覆盖。
/// - 合集成员 `pinned`：跨端取或、单调，旧版缺字段按 false、不清本机的 1。
void main() {
  FushiDatabase memDb() {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    return db;
  }

  MediaLinkEndpoint bookEp(int i) => (kind: MediaLinkKind.book, key: 'b$i');
  MediaLinkEndpoint episodeEp(int i) =>
      (kind: MediaLinkKind.videoEpisode, key: 'e$i');
  MediaLinkId pairId(int i) =>
      mediaLinkIdFor(MediaLinkRelation.adaptation, bookEp(i), episodeEp(i));

  /// 互联一轮：client 拉 host 清单并入，再把自己的清单推给 host。
  Future<int> exchange(FushiDatabase client, FushiDatabase host) async {
    int changed = await applyMediaLinkManifest(
      client,
      await loadLocalMediaLinkManifest(host),
    );
    changed += await applyMediaLinkManifest(
      host,
      await loadLocalMediaLinkManifest(client),
    );
    return changed;
  }

  Future<MediaLinkRow?> rowOf(FushiDatabase db, int i) =>
      db.mediaLinkById(pairId(i));

  Future<void> aiApply(FushiDatabase db, int i, {String reason = 'ai'}) =>
      db.applyAiMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: bookEp(i),
        to: episodeEp(i),
        source: MediaLinkSource.ai,
        confidence: 0.95,
        reason: reason,
      );

  group('wire 字段 confirmedBy', () {
    test('写出 user / ai / none；缺字段 = 旧版（confirmed=false 为未知）', () async {
      final FushiDatabase db = memDb();
      await aiApply(db, 1);
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: bookEp(2),
        to: episodeEp(2),
        at: 5,
      );
      await db.proposeMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: bookEp(3),
        to: episodeEp(3),
        source: MediaLinkSource.mal,
        at: 6,
      );
      final Map<String, Object?> byKey = <String, Object?>{
        for (final MediaLinkManifestEntry e
            in (await loadLocalMediaLinkManifest(db)).links)
          e.from.key: e.toJson()['confirmedBy'],
      };
      expect(byKey, <String, Object?>{'b1': 'ai', 'b2': 'user', 'b3': 'none'});

      final MediaLinkManifestEntry legacy = MediaLinkManifestEntry.fromJson(
        jsonDecode(
              jsonEncode(<String, Object?>{
                'from': <String, Object?>{'kind': 'book', 'key': 'b1'},
                'relation': 'adaptation',
                'to': <String, Object?>{'kind': 'video_episode', 'key': 'e1'},
                'source': 'ai',
                'confirmed': false,
                'createdAt': 1,
                'updatedAt': 1,
              }),
            )
            as Map<String, dynamic>,
      );
      expect(legacy.confirmerKnown, isFalse);
      expect(legacy.confirmer, isNull);
      expect(
        legacy.toJson().containsKey('confirmedBy'),
        isFalse,
        reason: '照实转述',
      );
      final MediaLinkManifestEntry legacyConfirmed =
          MediaLinkManifestEntry.fromJson(<String, dynamic>{
            ...legacy.toJson(),
            'confirmed': true,
          });
      expect(legacyConfirmed.confirmer, MediaLinkConfirmer.user);
      expect(legacyConfirmed.confirmerKnown, isTrue);
    });
  });

  group('两端合并', () {
    test('一边 user 一边 ai（同一对）→ 两端都是 user', () async {
      final FushiDatabase host = memDb();
      final FushiDatabase a = memDb();
      final FushiDatabase b = memDb();
      await aiApply(a, 1);
      await b.upsertManualMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: bookEp(1),
        to: episodeEp(1),
        at: 100,
      );
      await exchange(a, host);
      await exchange(b, host);
      await exchange(a, host);
      for (final FushiDatabase d in <FushiDatabase>[a, b, host]) {
        final MediaLinkRow row = (await rowOf(d, 1))!;
        expect(row.confirmedBy, MediaLinkConfirmer.user);
        expect(row.isUserConfirmed, isTrue);
      }
    });

    test('否决晚于 AI 的基线 → 否决胜；AI 建立在更新的状态上 → AI 生效胜', () async {
      final FushiDatabase host = memDb();
      final FushiDatabase a = memDb();
      final FushiDatabase b = memDb();
      // 对端否决的是一条 AI 没见过的连接：AI 凭空新建（基线 0）。
      await b.upsertManualMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: bookEp(1),
        to: episodeEp(1),
        at: 10,
      );
      await b.removeMediaLink(pairId(1), at: 20);
      await aiApply(a, 1);
      await exchange(a, host);
      await exchange(b, host);
      await exchange(a, host);
      for (final FushiDatabase d in <FushiDatabase>[a, b]) {
        expect(mediaLinkStateOf((await rowOf(d, 1))!), MediaLinkState.removed);
      }

      // b 否决了一条建议（20）；a 收到后用户撤销否决（恢复成建议，时刻 30），AI 再
      // 把它升为生效：AI 那一端见过否决，基线 30 晚于否决 ⇒ AI 生效胜。
      await b.proposeMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: bookEp(2),
        to: episodeEp(2),
        source: MediaLinkSource.mal,
        at: 10,
      );
      await b.removeMediaLink(pairId(2), at: 20);
      await exchange(b, host);
      await exchange(a, host);
      expect(await a.restoreMediaLinkSuggestion(pairId(2), at: 30), isTrue);
      await aiApply(a, 2);
      await exchange(a, host);
      await exchange(b, host);
      for (final FushiDatabase d in <FushiDatabase>[a, b]) {
        expect((await rowOf(d, 2))!.confirmedBy, MediaLinkConfirmer.ai);
        expect(
          mediaLinkStateOf((await rowOf(d, 2))!),
          MediaLinkState.confirmed,
        );
      }
    });

    test('旧版对端回传（丢 confirmedBy、confirmed=false）不冲掉本机 AI 生效', () async {
      final FushiDatabase a = memDb();
      await a.proposeMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: bookEp(1),
        to: episodeEp(1),
        source: MediaLinkSource.mal,
        at: 10,
      );
      await aiApply(a, 1);
      // 旧版对端：把它当建议存下（存不了 confirmedBy），之后原样回传，甚至时钟更新。
      final MediaLinkManifest mine = await loadLocalMediaLinkManifest(a);
      final MediaLinkManifest echoed = MediaLinkManifest.fromJson(
        jsonDecode(
          jsonEncode(<String, Object?>{
            'version': 1,
            'links': <Object?>[
              for (final MediaLinkManifestEntry e in mine.links)
                <String, Object?>{
                  ...e.toJson()..remove('confirmedBy'),
                  'confirmed': false,
                },
            ],
          }),
        ),
      );
      expect(
        mediaLinkManifestCovers(echoed, mine),
        isTrue,
        reason: '旧版存不下 AI 生效，不必 POST',
      );
      await applyMediaLinkManifest(a, echoed);
      expect((await rowOf(a, 1))!.confirmedBy, MediaLinkConfirmer.ai);
      final MediaLinkManifest newer = MediaLinkManifest.fromJson(
        jsonDecode(
          jsonEncode(<String, Object?>{
            'version': 1,
            'links': <Object?>[
              for (final MediaLinkManifestEntry e in echoed.links)
                <String, Object?>{...e.toJson(), 'updatedAt': 99},
            ],
          }),
        ),
      );
      await applyMediaLinkManifest(a, newer);
      final MediaLinkRow row = (await rowOf(a, 1))!;
      expect(row.confirmedBy, MediaLinkConfirmer.ai, reason: '缺字段 = 未知，不是清空');
      expect(row.updatedAt, 99);
    });
  });

  group('多端随机性质（3 台设备 + host）', () {
    for (int seed = 1; seed <= 25; seed++) {
      test('seed $seed：最终逐项一致；用户确认 / 否决永不被 AI 覆盖', () async {
        final Random random = Random(seed);
        final FushiDatabase host = memDb();
        final List<FushiDatabase> devices = <FushiDatabase>[
          memDb(),
          memDb(),
          memDb(),
        ];
        final List<List<MediaLinkAiWrite>> aiWrites = <List<MediaLinkAiWrite>>[
          <MediaLinkAiWrite>[],
          <MediaLinkAiWrite>[],
          <MediaLinkAiWrite>[],
        ];
        // 用户动作日志：pair → (时刻, 动作)。时刻步长 1000，AI 撤销的 +1 时钟不会与之撞。
        final Map<int, List<({int at, String kind})>> userEvents =
            <int, List<({int at, String kind})>>{};
        int clock = 0;
        int next() => clock += 1000;
        const int pairs = 4;

        for (int step = 0; step < 80; step++) {
          final int di = random.nextInt(devices.length);
          final FushiDatabase d = devices[di];
          final int p = random.nextInt(pairs);
          final MediaLinkRow? row = await rowOf(d, p);
          final bool live = row != null && row.deletedAt == null;
          final String? by = row == null ? null : mediaLinkConfirmerOf(row);
          switch (random.nextInt(9)) {
            case 0:
              final int at = next();
              await d.upsertManualMediaLink(
                relation: MediaLinkRelation.adaptation,
                from: bookEp(p),
                to: episodeEp(p),
                at: at,
              );
              (userEvents[p] ??= <({int at, String kind})>[]).add((
                at: at,
                kind: 'user',
              ));
            case 1:
              if (live && by != MediaLinkConfirmer.user) {
                final int at = next();
                expect(await d.confirmMediaLink(pairId(p), at: at), isTrue);
                (userEvents[p] ??= <({int at, String kind})>[]).add((
                  at: at,
                  kind: 'user',
                ));
              }
            case 2:
              if (live) {
                final int at = next();
                await d.removeMediaLink(pairId(p), at: at);
                (userEvents[p] ??= <({int at, String kind})>[]).add((
                  at: at,
                  kind: 'veto',
                ));
              }
            case 3:
              final int at = next();
              if (await d.unconfirmMediaLink(pairId(p), at: at)) {
                (userEvents[p] ??= <({int at, String kind})>[]).add((
                  at: at,
                  kind: 'unconfirm',
                ));
              }
            case 4:
            case 5:
              final MediaLinkAiWrite? w = await d.applyAiMediaLink(
                relation: MediaLinkRelation.adaptation,
                from: bookEp(p),
                to: episodeEp(p),
                source: MediaLinkSource.ai,
                confidence: 0.9,
                reason: 'device $di step $step',
              );
              if (w != null) aiWrites[di].add(w);
            case 6:
              if (aiWrites[di].isNotEmpty) {
                final MediaLinkAiWrite w = aiWrites[di].removeAt(
                  random.nextInt(aiWrites[di].length),
                );
                await d.revertAiMediaLink(w.id, previous: w.previous);
              }
            default:
              await exchange(d, host);
          }
        }

        int quiet = 0;
        for (int round = 0; round < 20 && quiet < 2; round++) {
          int changed = 0;
          for (final FushiDatabase d in List<FushiDatabase>.of(
            devices,
          )..shuffle(random)) {
            changed += await exchange(d, host);
          }
          quiet = changed == 0 ? quiet + 1 : 0;
        }
        expect(quiet, 2, reason: '同步不收敛');

        Future<List<String>> snapshot(FushiDatabase d) async => <String>[
          for (final MediaLinkRow r in await d.allMediaLinks())
            '${r.fromKey}|${mediaLinkConfirmerOf(r)}|${r.deletedAt != null}'
                '|${r.updatedAt}|${r.source}|${r.reason}',
        ]..sort();
        final List<String> expected = await snapshot(host);
        for (final FushiDatabase d in devices) {
          expect(await snapshot(d), expected);
        }

        for (final MapEntry<int, List<({int at, String kind})>> e
            in userEvents.entries) {
          final ({int at, String kind}) last = e.value.reduce(
            (({int at, String kind}) x, ({int at, String kind}) y) =>
                x.at >= y.at ? x : y,
          );
          for (final FushiDatabase d in <FushiDatabase>[host, ...devices]) {
            final MediaLinkRow? r = await rowOf(d, e.key);
            switch (last.kind) {
              case 'user':
                expect(r, isNotNull);
                expect(r!.deletedAt, isNull, reason: 'pair ${e.key}');
                expect(
                  mediaLinkConfirmerOf(r),
                  MediaLinkConfirmer.user,
                  reason: '最后的用户动作是确认：AI 不得改它（pair ${e.key}）',
                );
              case 'veto':
                expect(r, isNotNull);
                expect(
                  r!.deletedAt,
                  isNotNull,
                  reason: '最后的用户动作是否决：AI 不得复活（pair ${e.key}）',
                );
            }
          }
        }
      });
    }
  });

  group('合集成员 pinned', () {
    Future<int> syncCollections(
      FushiDatabase db,
      List<CollectionManifest> cloud,
    ) async {
      final CollectionSyncOutcome outcome = CollectionSyncEngine.merge(
        local: await loadLocalCollectionManifest(db),
        remote: cloud.single,
        lastSyncedAtMs: 0,
      );
      final int applied = await applyCollectionLocalChanges(
        db,
        outcome.changes,
      );
      cloud[0] = outcome.merged;
      return applied;
    }

    Future<bool?> pinnedOf(FushiDatabase db, String key) async {
      final MediaCollectionRow? c = await db.getMediaCollectionByNaturalKey(
        'S',
        'collection',
      );
      if (c == null) return null;
      for (final MediaCollectionItemRow m in await db.getCollectionItems(
        c.id,
      )) {
        if (m.entryKey == key) return m.pinnedByUser;
      }
      return null;
    }

    test('取或：一端用户加入（1）、另一端自动加入（0）→ 两端都是 1；不再降回 0', () async {
      final FushiDatabase a = memDb();
      final FushiDatabase b = memDb();
      final List<CollectionManifest> cloud = <CollectionManifest>[
        CollectionManifest.empty,
      ];
      final int ca = await a.createMediaCollection(
        'S',
        origin: CollectionOrigin.ai,
      );
      await a.addToCollection(ca, MediaKind.video, 'v1', userIntent: false);
      await a.addToCollection(ca, MediaKind.video, 'v2', userIntent: false);
      final int cb = await b.createMediaCollection(
        'S',
        origin: CollectionOrigin.ai,
      );
      await b.addToCollection(cb, MediaKind.video, 'v1');
      await b.addToCollection(cb, MediaKind.video, 'v2', userIntent: false);
      for (int i = 0; i < 3; i++) {
        await syncCollections(a, cloud);
        await syncCollections(b, cloud);
      }
      for (final FushiDatabase d in <FushiDatabase>[a, b]) {
        expect(await pinnedOf(d, 'v1'), isTrue);
        expect(await pinnedOf(d, 'v2'), isFalse);
      }
      final List<CollectionManifestMember> wire =
          cloud.single.collections.single.members;
      expect(
        <String, bool>{
          for (final CollectionManifestMember m in wire) m.entryKey: m.pinned,
        },
        <String, bool>{'v1': true, 'v2': false},
      );
      expect(
        jsonEncode(
          wire
              .firstWhere((CollectionManifestMember m) => m.entryKey == 'v2')
              .toJson(),
        ),
        isNot(contains('pinned')),
        reason: 'false 不写出，与旧版字节相同',
      );
      // 再同步一轮应当静默（不来回改）。
      expect(await syncCollections(a, cloud), 0);
      expect(await syncCollections(b, cloud), 0);
    });

    test('旧版对端回传缺 pinned 字段：按 false 合并，本机的 1 不降', () async {
      final FushiDatabase a = memDb();
      final int ca = await a.createMediaCollection('S');
      await a.addToCollection(ca, MediaKind.video, 'v1');
      final List<CollectionManifest> cloud = <CollectionManifest>[
        CollectionManifest.empty,
      ];
      await syncCollections(a, cloud);
      final Map<String, dynamic> json =
          jsonDecode(jsonEncode(cloud.single.toJson())) as Map<String, dynamic>;
      for (final Object? c in json['collections'] as List<Object?>) {
        for (final Object? m
            in (c! as Map<String, dynamic>)['members'] as List<Object?>) {
          (m! as Map<String, dynamic>).remove('pinned');
        }
      }
      cloud[0] = CollectionManifest.fromJson(json);
      expect(cloud.single.collections.single.members.single.pinned, isFalse);
      await syncCollections(a, cloud);
      expect(await pinnedOf(a, 'v1'), isTrue);
      expect(cloud.single.collections.single.members.single.pinned, isTrue);
    });
  });
}
