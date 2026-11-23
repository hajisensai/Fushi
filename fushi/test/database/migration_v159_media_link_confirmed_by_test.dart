import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v159（AI 库管家设计稿 `docs/specs/2026-11-18-ai-library-curator-design.md`
/// §5.3 / §7）：`media_links.confirmed_by`（谁让连接生效，`user` 压过 `ai`）与
/// `media_collection_items.pinned_by_user`（用户亲手放进合集，AI 不再移出）。
/// 迁移回填与 DB 写入口的语义在这里钉死。
void main() {
  const MediaLinkEndpoint book = (kind: MediaLinkKind.book, key: 'novel');
  const MediaLinkEndpoint anime = (
    kind: MediaLinkKind.videoCollection,
    key: '7',
  );
  const MediaLinkEndpoint game = (kind: MediaLinkKind.game, key: 'g1');

  test('v158 → v159：已确认回填 user、建议留 NULL；成员 pinned 存量 0；重跑幂等', () async {
    final Directory dir = Directory.systemTemp.createTempSync('curator_v159');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.upsertManualMediaLink(
      relation: MediaLinkRelation.adaptation,
      from: book,
      to: anime,
      at: 10,
    );
    await db.proposeMediaLink(
      relation: MediaLinkRelation.sameWork,
      from: game,
      to: anime,
      source: MediaLinkSource.mal,
      at: 11,
    );
    final int col = await db.createMediaCollection('C');
    await db.addToCollection(col, MediaKind.video, 'v1');
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('ALTER TABLE media_links DROP COLUMN confirmed_by');
    raw.execute(
      'ALTER TABLE media_collection_items DROP COLUMN pinned_by_user',
    );
    raw.execute('PRAGMA user_version = 158');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 173);
    final Map<String, String?> byRelation = <String, String?>{
      for (final MediaLinkRow r in await migrated.allMediaLinks())
        r.relation: r.confirmedBy,
    };
    expect(byRelation, <String, String?>{
      'adaptation': MediaLinkConfirmer.user,
      'same_work': null,
    });
    expect(
      (await migrated.getCollectionItems(col)).single.pinnedByUser,
      isFalse,
      reason: '存量成员行 0：老合集的成员 AI 可以整理一次',
    );
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 173);
    probe.execute('PRAGMA user_version = 158');
    probe.dispose();
    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(
      (await reopened.allMediaLinks())
          .where((MediaLinkRow r) => r.confirmedBy == MediaLinkConfirmer.user)
          .length,
      1,
    );
    await reopened.close();
  });

  group('media_links：AI 生效', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    final MediaLinkId id = mediaLinkIdFor(
      MediaLinkRelation.adaptation,
      book,
      anime,
    );

    Future<MediaLinkAiWrite?> applyAi() => db.applyAiMediaLink(
      relation: MediaLinkRelation.adaptation,
      from: book,
      to: anime,
      source: MediaLinkSource.wikidata,
      confidence: 0.9,
      reason: 'shared id',
      at: 50,
    );

    test('凭空新建：confirmed_by=ai、镜像列 false、已生效；时钟停在基线 0', () async {
      final MediaLinkAiWrite? w = await applyAi();
      expect(w!.id, id);
      expect(w.previous, isNull);
      final MediaLinkRow row = (await db.mediaLinkById(id))!;
      expect(row.confirmedBy, MediaLinkConfirmer.ai);
      expect(row.isUserConfirmed, isFalse);
      expect(mediaLinkStateOf(row), MediaLinkState.confirmed);
      expect(row.source, MediaLinkSource.wikidata, reason: '保留证据来源');
      expect(row.reason, 'shared id');
      expect(row.createdAt, 50);
      expect(row.updatedAt, kMediaLinkAiBaseClock);
      expect(await applyAi(), isNull, reason: '已生效的不重复写');
    });

    test('建议 → 升为 AI 生效，updatedAt 不变；回执带写入前的建议', () async {
      await db.proposeMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book,
        to: anime,
        source: MediaLinkSource.mal,
        confidence: 0.45,
        at: 20,
      );
      final MediaLinkAiWrite? w = await applyAi();
      expect(w!.previous!.confirmedBy, isNull);
      expect(w.previous!.source, MediaLinkSource.mal);
      final MediaLinkRow row = (await db.mediaLinkById(id))!;
      expect(row.confirmedBy, MediaLinkConfirmer.ai);
      expect(row.updatedAt, 20, reason: 'AI 不推进时钟：基线 = 它依据的建议');
      expect(row.source, MediaLinkSource.wikidata);
    });

    test('用户确认过的不改；否决墓碑挡住 AI；同一对别的关系也挡住', () async {
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book,
        to: anime,
        at: 5,
      );
      expect(await applyAi(), isNull);
      expect((await db.mediaLinkById(id))!.source, MediaLinkSource.manual);

      await db.removeMediaLink(id, at: 6);
      expect(await applyAi(), isNull, reason: 'AI 不得复活用户否决过的一对');
      expect((await db.mediaLinkById(id))!.deletedAt, 6);

      expect(
        await db.applyAiMediaLink(
          relation: MediaLinkRelation.sameWork,
          from: book,
          to: anime,
          source: MediaLinkSource.ai,
        ),
        isNull,
      );
    });

    test('用户确认 AI 生效的连接 → 升为 user；用户移除 → 否决墓碑，AI 再也不写', () async {
      await applyAi();
      expect(await db.confirmMediaLink(id, at: 70), isTrue);
      MediaLinkRow row = (await db.mediaLinkById(id))!;
      expect(row.confirmedBy, MediaLinkConfirmer.user);
      expect(row.isUserConfirmed, isTrue);
      expect(row.updatedAt, 70);

      await db.unconfirmMediaLink(id, at: 71);
      await db.applyAiMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book,
        to: anime,
        source: MediaLinkSource.ai,
      );
      row = (await db.mediaLinkById(id))!;
      expect(row.confirmedBy, MediaLinkConfirmer.ai);
      expect(await db.removeMediaLink(id, at: 80), isTrue);
      expect(
        mediaLinkStateOf((await db.mediaLinkById(id))!),
        MediaLinkState.removed,
      );
      expect(await applyAi(), isNull);
      expect(
        await db.restoreMediaLinkSuggestion(id),
        isFalse,
        reason: '已生效连接的墓碑不是「不相关」的建议墓碑',
      );
    });

    test('撤销：之前没有 → 写墓碑（不删行，这一对不再自动连）；之前是建议 → 退回建议', () async {
      final MediaLinkAiWrite fresh = (await applyAi())!;
      expect(
        await db.revertAiMediaLink(fresh.id, previous: fresh.previous, at: 40),
        isTrue,
      );
      final MediaLinkRow tomb = (await db.mediaLinkById(id))!;
      expect(
        mediaLinkStateOf(tomb),
        MediaLinkState.removed,
        reason: '物理删除会被已同步出去的副本经 LWW 拉回来',
      );
      expect(tomb.updatedAt, 40, reason: 'max(now, 基线 + 1)');
      expect(await applyAi(), isNull, reason: '撤销 = 否决这一对，AI 不再生效');
      expect(
        await db.proposeMediaLink(
          relation: MediaLinkRelation.sameWork,
          from: book,
          to: anime,
          source: MediaLinkSource.ai,
        ),
        isFalse,
        reason: '也不再换个关系提议',
      );
      await db.delete(db.mediaLinks).go();

      await db.proposeMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book,
        to: anime,
        source: MediaLinkSource.mal,
        confidence: 0.45,
        reason: 'mal',
        at: 30,
      );
      final MediaLinkAiWrite up = (await applyAi())!;
      expect(
        await db.revertAiMediaLink(up.id, previous: up.previous, at: 0),
        isTrue,
      );
      final MediaLinkRow row = (await db.mediaLinkById(id))!;
      expect(mediaLinkStateOf(row), MediaLinkState.suggested);
      expect(row.confirmedBy, isNull);
      expect(row.source, MediaLinkSource.mal);
      expect(row.confidence, 0.45);
      expect(row.reason, 'mal');
      expect(row.updatedAt, 31, reason: '至少压过各端同一份 AI 生效（时钟 30）');
    });

    test('撤销：之后被用户确认 / 否决过 → 报已被覆盖，不动', () async {
      final MediaLinkAiWrite a = (await applyAi())!;
      await db.confirmMediaLink(id, at: 60);
      expect(await db.revertAiMediaLink(a.id, previous: a.previous), isFalse);
      expect(
        (await db.mediaLinkById(id))!.confirmedBy,
        MediaLinkConfirmer.user,
      );

      await db.removeMediaLink(id, at: 61);
      expect(await db.revertAiMediaLink(a.id, previous: a.previous), isFalse);
      expect((await db.mediaLinkById(id))!.deletedAt, 61);
      expect(await db.discardMediaLinkSuggestion(id), isFalse);
    });
  });

  group('media_links：跨端合并', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    final MediaLinkId id = mediaLinkIdFor(
      MediaLinkRelation.adaptation,
      book,
      anime,
    );

    Future<MediaLinkRow> aiAt(int base) async {
      await db.proposeMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book,
        to: anime,
        source: MediaLinkSource.mal,
        at: base,
      );
      await db.applyAiMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book,
        to: anime,
        source: MediaLinkSource.ai,
      );
      return (await db.mediaLinkById(id))!;
    }

    test('同一时钟：user 压过 ai，ai 压过建议', () async {
      final MediaLinkRow ai = await aiAt(10);
      expect(
        await db.mergeRemoteMediaLink(
          ai.copyWith(confirmedBy: const Value<String?>(null)),
        ),
        isFalse,
      );
      expect(
        await db.mergeRemoteMediaLink(
          ai.copyWith(
            confirmedBy: const Value<String?>(MediaLinkConfirmer.user),
          ),
        ),
        isTrue,
      );
      final MediaLinkRow row = (await db.mediaLinkById(id))!;
      expect(row.confirmedBy, MediaLinkConfirmer.user);
      expect(row.isUserConfirmed, isTrue, reason: '镜像列由写入口一并维护');
    });

    test('否决晚于 AI 的基线 → 否决胜；早于基线 → AI 生效胜', () async {
      final MediaLinkRow ai = await aiAt(10);
      expect(
        await db.mergeRemoteMediaLink(
          ai.copyWith(updatedAt: 9, deletedAt: const Value<int?>(9)),
        ),
        isFalse,
        reason: 'AI 那一端见过更新的状态（基线 10）',
      );
      expect(
        await db.mergeRemoteMediaLink(
          ai.copyWith(updatedAt: 11, deletedAt: const Value<int?>(11)),
        ),
        isTrue,
      );
      expect(
        mediaLinkStateOf((await db.mediaLinkById(id))!),
        MediaLinkState.removed,
      );
    });

    test('旧版对端（没说 confirmedBy）回传的未确认行不冲掉 AI 生效', () async {
      final MediaLinkRow ai = await aiAt(10);
      final MediaLinkRow legacy = ai.copyWith(
        confirmedBy: const Value<String?>(null),
        isUserConfirmed: false,
        updatedAt: 15,
        reason: const Value<String?>('legacy'),
      );
      expect(
        await db.mergeRemoteMediaLink(legacy, confirmerKnown: false),
        isTrue,
      );
      MediaLinkRow row = (await db.mediaLinkById(id))!;
      expect(row.confirmedBy, MediaLinkConfirmer.ai, reason: '缺字段 = 未知，不是清空');
      expect(row.updatedAt, 15);
      expect(row.reason, 'legacy');
      // 同一份数据说了「建议」（新版对端）→ 照常 LWW。
      expect(
        await db.mergeRemoteMediaLink(legacy.copyWith(updatedAt: 16)),
        isTrue,
      );
      row = (await db.mediaLinkById(id))!;
      expect(row.confirmedBy, isNull);
      // 旧版对端说了确认 → user。
      expect(
        await db.mergeRemoteMediaLink(
          legacy.copyWith(updatedAt: 17, isUserConfirmed: true),
          confirmerKnown: false,
        ),
        isTrue,
      );
      expect(
        (await db.mediaLinkById(id))!.confirmedBy,
        MediaLinkConfirmer.user,
      );
    });
  });

  group('合集成员 pinned_by_user', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<MediaCollectionItemRow?> member(int col, String key) async {
      for (final MediaCollectionItemRow m in await db.getCollectionItems(col)) {
        if (m.entryKey == key) return m;
      }
      return null;
    }

    test('用户加入置 1；自动加入新行 0、不把 1 改回 0；同步 upsert 取或', () async {
      final int col = await db.createMediaCollection(
        'C',
        origin: CollectionOrigin.ai,
      );
      await db.addToCollection(col, MediaKind.video, 'auto', userIntent: false);
      expect((await member(col, 'auto'))!.pinnedByUser, isFalse);
      await db.addToCollection(col, MediaKind.video, 'mine');
      expect((await member(col, 'mine'))!.pinnedByUser, isTrue);
      await db.addToCollection(col, MediaKind.video, 'mine', userIntent: false);
      expect((await member(col, 'mine'))!.pinnedByUser, isTrue, reason: '单调');

      await db.upsertCollectionItemAt(col, 'video', 'mine', 0);
      expect((await member(col, 'mine'))!.pinnedByUser, isTrue);
      await db.upsertCollectionItemAt(
        col,
        'video',
        'auto',
        1,
        pinnedByUser: true,
      );
      expect((await member(col, 'auto'))!.pinnedByUser, isTrue);
      expect((await member(col, 'auto'))!.sortIndex, 1);
    });

    test('自动移出：钉住的拒绝；没钉的移出、写墓碑、不转所有权；用户加回 → 钉住', () async {
      final int col = await db.createMediaCollection(
        'C',
        origin: CollectionOrigin.ai,
      );
      await db.addToCollection(col, MediaKind.video, 'a', userIntent: false);
      await db.addToCollection(col, MediaKind.video, 'b', userIntent: false);
      await db.addToCollection(col, MediaKind.video, 'c', userIntent: false);
      // 用户合集：所有权同样不转。
      final int mine = await db.createMediaCollection('Mine');
      await db.addToCollection(mine, MediaKind.video, 'x', userIntent: false);
      await db.addToCollection(mine, MediaKind.video, 'y');

      expect(
        await db.removeFromCollectionAutomatically(col, 'video', 'a'),
        CollectionAutoRemoveResult.removed,
      );
      expect(await member(col, 'a'), isNull);
      expect(
        await db.collectionMemberTombstoneKeysFor('C', 'collection'),
        contains('video\u0000a'),
      );
      expect((await db.getMediaCollectionById(col))!.origin, 'ai');
      expect(
        await db.removeFromCollectionAutomatically(col, 'video', 'a'),
        CollectionAutoRemoveResult.notMember,
      );

      expect(
        await db.removeFromCollectionAutomatically(mine, 'video', 'y'),
        CollectionAutoRemoveResult.pinned,
      );
      expect(await member(mine, 'y'), isNotNull);
      expect(
        await db.removeFromCollectionAutomatically(mine, 'video', 'x'),
        CollectionAutoRemoveResult.removed,
      );
      expect((await db.getMediaCollectionById(mine))!.origin, 'user');

      // 用户把被 AI 移出的成员加回去：清墓碑（重新加入胜）、钉住、接手合集。
      await db.addToCollection(col, MediaKind.video, 'a');
      expect((await member(col, 'a'))!.pinnedByUser, isTrue);
      expect(
        await db.collectionMemberTombstoneKeysFor('C', 'collection'),
        isNot(contains('video\u0000a')),
      );
      expect(
        await db.removeFromCollectionAutomatically(col, 'video', 'a'),
        CollectionAutoRemoveResult.pinned,
      );
    });
  });
}
