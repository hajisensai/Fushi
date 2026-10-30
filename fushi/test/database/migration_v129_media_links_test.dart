import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v129：跨模块作品图谱 `media_links`（spec docs/specs/2026-10-24-cross-media-links.md）。
///
/// 迁移只建表、重跑幂等；读写内核（手动连接 / 建议 / 确认 / 否决墓碑 / 跨端 LWW）
/// 的语义在这里钉死——互联同步、备份合并与推断都只认这套口径。
void main() {
  bool tableExists(sqlite.Database raw, String table) => raw.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[table],
  ).isNotEmpty;

  const MediaLinkEndpoint book = (kind: MediaLinkKind.book, key: 'novel');
  const MediaLinkEndpoint anime = (
    kind: MediaLinkKind.videoCollection,
    key: '7',
  );
  const MediaLinkEndpoint game = (kind: MediaLinkKind.game, key: 'g1');

  test('v128 → v129 建 media_links；重跑幂等、不清数据', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'media_links_v129',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.allMediaLinks(); // 触发建库
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE media_links');
    raw.execute('PRAGMA user_version = 128');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 139);
    await migrated.upsertManualMediaLink(
      relation: MediaLinkRelation.adaptation,
      from: book,
      to: anime,
      at: 10,
    );
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 139);
    expect(tableExists(probe, 'media_links'), isTrue);
    final Set<String> columns = <String>{
      for (final sqlite.Row r in probe.select(
        "PRAGMA table_info('media_links')",
      ))
        r['name'] as String,
    };
    expect(columns, <String>{
      'from_kind',
      'from_key',
      'relation',
      'to_kind',
      'to_key',
      'role',
      'episode_range',
      'source',
      'confidence',
      'is_user_confirmed',
      'reason',
      'created_at',
      'updated_at',
      'deleted_at',
    });
    probe.execute('PRAGMA user_version = 128');
    probe.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(await reopened.allMediaLinks(), hasLength(1));
    await reopened.close();
  });

  group('作品图谱读写内核', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('手动连接恒为已确认；两个端点都查得到；同端点拒绝', () async {
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book,
        to: anime,
        at: 5,
      );
      final List<MediaLinkRow> fromBook = await db.mediaLinksForEndpoint(
        book.kind,
        book.key,
      );
      final List<MediaLinkRow> fromAnime = await db.mediaLinksForEndpoint(
        anime.kind,
        anime.key,
      );
      expect(fromBook, hasLength(1));
      expect(fromAnime, hasLength(1));
      expect(mediaLinkStateOf(fromBook.single), MediaLinkState.confirmed);
      expect(fromBook.single.source, MediaLinkSource.manual);
      expect(fromBook.single.fromKind, 'book', reason: '原作 → 改编，方向保留');
      expect(
        () => db.upsertManualMediaLink(
          relation: MediaLinkRelation.sameWork,
          from: book,
          to: book,
        ),
        throwsArgumentError,
      );
    });

    test('无方向关系两端规范化：(A,B) 与 (B,A) 是同一行', () async {
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.sameWork,
        from: game,
        to: book,
        at: 1,
      );
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.sameWork,
        from: book,
        to: game,
        at: 2,
      );
      final List<MediaLinkRow> all = await db.allMediaLinks();
      expect(all, hasLength(1));
      expect(all.single.fromKind, 'book', reason: 'book < game（按落库值排序）');
      expect(all.single.createdAt, 1, reason: '重连保留首次创建时刻');
      expect(all.single.updatedAt, 2);
    });

    test('建议：同一对条目已有任何行（含否决墓碑、反方向、别的关系）就不再提议', () async {
      expect(
        await db.proposeMediaLink(
          relation: MediaLinkRelation.adaptation,
          from: book,
          to: anime,
          source: MediaLinkSource.mal,
          confidence: 0.6,
          reason: 'r',
          at: 1,
        ),
        isTrue,
      );
      final MediaLinkRow suggestion = (await db.mediaLinksForEndpoint(
        book.kind,
        book.key,
      )).single;
      expect(mediaLinkStateOf(suggestion), MediaLinkState.suggested);

      // 否决 → 墓碑；区块默认不再列出，推断也不会再提。
      expect(
        await db.removeMediaLink(mediaLinkIdOf(suggestion), at: 2),
        isTrue,
      );
      expect(await db.mediaLinksForEndpoint(book.kind, book.key), isEmpty);
      expect(
        (await db.mediaLinksForEndpoint(
          book.kind,
          book.key,
          includeRemoved: true,
        )).single.deletedAt,
        2,
      );
      for (final MediaLinkRelation r in <MediaLinkRelation>[
        MediaLinkRelation.adaptation,
        MediaLinkRelation.sameWork,
      ]) {
        expect(
          await db.proposeMediaLink(
            relation: r,
            from: anime,
            to: book,
            source: MediaLinkSource.ai,
          ),
          isFalse,
          reason: '否决过的同一对条目，换方向 / 换关系都不重复提议',
        );
      }
      // 确认被否决的建议不会复活它。
      expect(await db.confirmMediaLink(mediaLinkIdOf(suggestion)), isFalse);
      // 用户自己手动重连可以复活（清墓碑、改为 manual）。
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book,
        to: anime,
        at: 3,
      );
      final MediaLinkRow revived = (await db.mediaLinksForEndpoint(
        book.kind,
        book.key,
      )).single;
      expect(mediaLinkStateOf(revived), MediaLinkState.confirmed);
      expect(revived.source, MediaLinkSource.manual);
      expect(revived.reason, isNull);
    });

    test('确认建议：变为已确认并推进 updatedAt', () async {
      await db.proposeMediaLink(
        relation: MediaLinkRelation.sameWork,
        from: game,
        to: anime,
        source: MediaLinkSource.ai,
        at: 1,
      );
      final MediaLinkId id = mediaLinkIdFor(
        MediaLinkRelation.sameWork,
        game,
        anime,
      );
      expect(await db.confirmMediaLink(id, at: 9), isTrue);
      final MediaLinkRow row = (await db.mediaLinkById(id))!;
      expect(row.isUserConfirmed, isTrue);
      expect(row.updatedAt, 9);
      expect(row.source, MediaLinkSource.ai, reason: '来源保留，供区块显示');
    });

    test('跨端合并整行 LWW；同时刻 墓碑 > 已确认 > 建议；无变化不写', () async {
      await db.proposeMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: book,
        to: anime,
        source: MediaLinkSource.mal,
        at: 10,
      );
      final MediaLinkRow local = (await db.allMediaLinks()).single;
      expect(
        await db.mergeRemoteMediaLink(
          local.copyWith(isUserConfirmed: true, updatedAt: 5),
        ),
        isFalse,
        reason: '对端更旧：不覆盖、不写库',
      );
      expect(
        await db.mergeRemoteMediaLink(local.copyWith(isUserConfirmed: true)),
        isTrue,
        reason: '同一时刻已确认压过建议',
      );
      final MediaLinkRow confirmed = (await db.allMediaLinks()).single;
      expect(confirmed.isUserConfirmed, isTrue);
      expect(
        await db.mergeRemoteMediaLink(
          confirmed.copyWith(isUserConfirmed: false),
        ),
        isFalse,
        reason: '同一时刻建议压不回已确认',
      );
      expect(
        await db.mergeRemoteMediaLink(
          confirmed.copyWith(deletedAt: const Value<int?>(10)),
        ),
        isTrue,
        reason: '同一时刻墓碑胜',
      );
      expect(await db.mediaLinksForEndpoint(book.kind, book.key), isEmpty);
      expect(
        await db.mergeRemoteMediaLink(
          confirmed.copyWith(updatedAt: 11, deletedAt: const Value<int?>(null)),
        ),
        isTrue,
        reason: '对端更新的复活（用户在那边重连了）照常生效',
      );
      expect(await db.mediaLinksForEndpoint(book.kind, book.key), hasLength(1));
    });
  });
}
