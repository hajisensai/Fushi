// 跨模块作品图谱（media_links，schema v129）的读写内核。
// spec `docs/specs/2026-10-24-cross-media-links.md`。
part of 'database.dart';

/// 一条连接的身份（五元组，落库值）。无方向关系的两端已规范化。
typedef MediaLinkId = ({
  String fromKind,
  String fromKey,
  String relation,
  String toKind,
  String toKey,
});

/// [MediaLinkRow] 的身份。
MediaLinkId mediaLinkIdOf(MediaLinkRow row) => (
  fromKind: row.fromKind,
  fromKey: row.fromKey,
  relation: row.relation,
  toKind: row.toKind,
  toKey: row.toKey,
);

/// 由类型化端点构造身份（无方向关系自动规范化两端）。
MediaLinkId mediaLinkIdFor(
  MediaLinkRelation relation,
  MediaLinkEndpoint from,
  MediaLinkEndpoint to,
) {
  final ({MediaLinkEndpoint from, MediaLinkEndpoint to}) c =
      canonicalMediaLinkEndpoints(relation, from, to);
  return (
    fromKind: c.from.kind.dbValue,
    fromKey: c.from.key,
    relation: relation.dbValue,
    toKind: c.to.kind.dbValue,
    toKey: c.to.key,
  );
}

/// 一行的可见状态（墓碑优先）。
MediaLinkState mediaLinkStateOf(MediaLinkRow row) {
  if (row.deletedAt != null) return MediaLinkState.removed;
  return row.isUserConfirmed
      ? MediaLinkState.confirmed
      : MediaLinkState.suggested;
}

/// 跨端 LWW 合并的裁决：[remote] 是否应覆盖 [local]。先比 `updatedAt`（大者胜），
/// 相等时按「墓碑 > 已确认 > 建议」——删除 / 否决与确认都是用户动作，不能被同
/// 时刻的建议压回去。仍相等则保留本机（两端此时内容等价，不来回翻）。
bool mediaLinkRemoteWins(MediaLinkRow local, MediaLinkRow remote) {
  if (remote.updatedAt != local.updatedAt) {
    return remote.updatedAt > local.updatedAt;
  }
  int rank(MediaLinkRow r) =>
      r.deletedAt != null ? 2 : (r.isUserConfirmed ? 1 : 0);
  return rank(remote) > rank(local);
}

mixin _FushiDbMediaLinks on _$FushiDatabase {
  Expression<bool> _mediaLinkIdIs($MediaLinksTable t, MediaLinkId id) =>
      t.fromKind.equals(id.fromKind) &
      t.fromKey.equals(id.fromKey) &
      t.relation.equals(id.relation) &
      t.toKind.equals(id.toKind) &
      t.toKey.equals(id.toKey);

  /// 按身份取一行（含墓碑）。
  Future<MediaLinkRow?> mediaLinkById(MediaLinkId id) => (select(
    mediaLinks,
  )..where((t) => _mediaLinkIdIs(t, id))).getSingleOrNull();

  /// 全部连接（含建议与墓碑），供同步清单 / 备份 / 推断去重。
  Future<List<MediaLinkRow>> allMediaLinks() => select(mediaLinks).get();

  /// 与某端点相连的连接（两个方向都算）。默认不含墓碑。
  Future<List<MediaLinkRow>> mediaLinksForEndpoint(
    MediaLinkKind kind,
    String key, {
    bool includeRemoved = false,
  }) {
    final SimpleSelectStatement<$MediaLinksTable, MediaLinkRow> q =
        select(mediaLinks)
          ..where((t) {
            final Expression<bool> touches =
                (t.fromKind.equals(kind.dbValue) & t.fromKey.equals(key)) |
                (t.toKind.equals(kind.dbValue) & t.toKey.equals(key));
            return includeRemoved ? touches : touches & t.deletedAt.isNull();
          })
          ..orderBy(<OrderClauseGenerator<$MediaLinksTable>>[
            (t) => OrderingTerm.desc(t.isUserConfirmed),
            (t) => OrderingTerm.asc(t.createdAt),
          ]);
    return q.get();
  }

  /// 手动连接（或重新连接一条被删除 / 否决过的连接）：恒为已确认、清墓碑，
  /// 来源记 `manual`、清掉推断的置信度与理由。已有行保留 `createdAt`。
  Future<MediaLinkId> upsertManualMediaLink({
    required MediaLinkRelation relation,
    required MediaLinkEndpoint from,
    required MediaLinkEndpoint to,
    String? role,
    String? episodeRange,
    int? at,
  }) {
    if (from.kind == to.kind && from.key == to.key) {
      throw ArgumentError('media link endpoints must differ');
    }
    final MediaLinkId id = mediaLinkIdFor(relation, from, to);
    return transaction(() async {
      final int now = at ?? DateTime.now().millisecondsSinceEpoch;
      final MediaLinkRow? existing = await mediaLinkById(id);
      await into(mediaLinks).insertOnConflictUpdate(
        MediaLinksCompanion.insert(
          fromKind: id.fromKind,
          fromKey: id.fromKey,
          relation: id.relation,
          toKind: id.toKind,
          toKey: id.toKey,
          role: Value<String?>(role),
          episodeRange: Value<String?>(episodeRange),
          source: const Value<String>(MediaLinkSource.manual),
          confidence: const Value<double?>(null),
          isUserConfirmed: const Value<bool>(true),
          reason: const Value<String?>(null),
          createdAt: existing?.createdAt ?? now,
          updatedAt: now,
          deletedAt: const Value<int?>(null),
        ),
      );
      return id;
    });
  }

  /// 推断写入一条**建议**（未确认）。同一对条目之间已有任何行（任意关系、任意
  /// 方向、含否决墓碑）就不写，返回 false——用户否决过的不重复提议，已手动连上的
  /// 也不再用另一种关系去打扰。
  Future<bool> proposeMediaLink({
    required MediaLinkRelation relation,
    required MediaLinkEndpoint from,
    required MediaLinkEndpoint to,
    required String source,
    double? confidence,
    String? reason,
    String? role,
    int? at,
  }) {
    if (from.kind == to.kind && from.key == to.key) {
      return Future<bool>.value(false);
    }
    final MediaLinkId id = mediaLinkIdFor(relation, from, to);
    return transaction(() async {
      if (await mediaLinkPairExists(from, to)) return false;
      final int now = at ?? DateTime.now().millisecondsSinceEpoch;
      await into(mediaLinks).insert(
        MediaLinksCompanion.insert(
          fromKind: id.fromKind,
          fromKey: id.fromKey,
          relation: id.relation,
          toKind: id.toKind,
          toKey: id.toKey,
          role: Value<String?>(role),
          source: Value<String>(source),
          confidence: Value<double?>(confidence),
          reason: Value<String?>(reason),
          createdAt: now,
          updatedAt: now,
        ),
      );
      return true;
    });
  }

  /// 两个端点之间是否已有任何行（任意关系、任意方向、含墓碑）。
  Future<bool> mediaLinkPairExists(
    MediaLinkEndpoint a,
    MediaLinkEndpoint b,
  ) async {
    final MediaLinkRow? row =
        await (select(mediaLinks)
              ..where(
                (t) =>
                    (t.fromKind.equals(a.kind.dbValue) &
                        t.fromKey.equals(a.key) &
                        t.toKind.equals(b.kind.dbValue) &
                        t.toKey.equals(b.key)) |
                    (t.fromKind.equals(b.kind.dbValue) &
                        t.fromKey.equals(b.key) &
                        t.toKind.equals(a.kind.dbValue) &
                        t.toKey.equals(a.key)),
              )
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  /// 用户确认一条建议。行不存在 / 已是墓碑返回 false（被别处否决的不复活）。
  Future<bool> confirmMediaLink(MediaLinkId id, {int? at}) =>
      transaction(() async {
        final MediaLinkRow? row = await mediaLinkById(id);
        if (row == null || row.deletedAt != null) return false;
        if (row.isUserConfirmed) return true;
        await (update(mediaLinks)..where((t) => _mediaLinkIdIs(t, id))).write(
          MediaLinksCompanion(
            isUserConfirmed: const Value<bool>(true),
            updatedAt: Value<int>(at ?? DateTime.now().millisecondsSinceEpoch),
          ),
        );
        return true;
      });

  /// 删除一条连接 / 否决一条建议：写墓碑（不删行，见 [MediaLinks] 注释）。
  /// 行不存在返回 false。
  Future<bool> removeMediaLink(MediaLinkId id, {int? at}) =>
      transaction(() async {
        final MediaLinkRow? row = await mediaLinkById(id);
        if (row == null) return false;
        if (row.deletedAt != null) return true;
        final int now = at ?? DateTime.now().millisecondsSinceEpoch;
        await (update(mediaLinks)..where((t) => _mediaLinkIdIs(t, id))).write(
          MediaLinksCompanion(
            deletedAt: Value<int?>(now),
            updatedAt: Value<int>(now),
          ),
        );
        return true;
      });

  /// [confirmMediaLink] 的反向（撤销「接受建议」）：一条已确认、未删的**推断**
  /// 连接退回建议，刷新 `updatedAt`（LWW 下这是一次新的用户动作）。手动连接
  /// （`source = manual`）本来就不是建议，不退回。返回是否退回了。
  Future<bool> unconfirmMediaLink(MediaLinkId id, {int? at}) =>
      transaction(() async {
        final MediaLinkRow? row = await mediaLinkById(id);
        if (row == null ||
            row.deletedAt != null ||
            !row.isUserConfirmed ||
            row.source == MediaLinkSource.manual) {
          return false;
        }
        await (update(mediaLinks)..where((t) => _mediaLinkIdIs(t, id))).write(
          MediaLinksCompanion(
            isUserConfirmed: const Value<bool>(false),
            updatedAt: Value<int>(at ?? DateTime.now().millisecondsSinceEpoch),
          ),
        );
        return true;
      });

  /// [removeMediaLink] 否决建议的反向（撤销「不相关」）：未确认的墓碑行恢复成
  /// 建议（清墓碑、刷新 `updatedAt`）。行不在 / 不是墓碑 / 是已确认连接的墓碑
  /// 返回 false。
  Future<bool> restoreMediaLinkSuggestion(MediaLinkId id, {int? at}) =>
      transaction(() async {
        final MediaLinkRow? row = await mediaLinkById(id);
        if (row == null || row.deletedAt == null || row.isUserConfirmed) {
          return false;
        }
        await (update(mediaLinks)..where((t) => _mediaLinkIdIs(t, id))).write(
          MediaLinksCompanion(
            deletedAt: const Value<int?>(null),
            updatedAt: Value<int>(at ?? DateTime.now().millisecondsSinceEpoch),
          ),
        );
        return true;
      });

  /// [proposeMediaLink] 的反向（撤销一轮「查找相关作品」）：删掉一条用户还没处理过
  /// 的建议行（未确认、无墓碑）。**不写墓碑**——墓碑的语义是「否决过、不再提议」，
  /// 撤销推断不是否决，下次推断仍可以再提。返回是否删了。
  Future<bool> discardMediaLinkSuggestion(MediaLinkId id) =>
      transaction(() async {
        final MediaLinkRow? row = await mediaLinkById(id);
        if (row == null || row.deletedAt != null || row.isUserConfirmed) {
          return false;
        }
        await (delete(mediaLinks)..where((t) => _mediaLinkIdIs(t, id))).go();
        return true;
      });

  /// 把一条连接恢复成某次写入（[upsertManualMediaLink] / [removeMediaLink]）之前的
  /// 快照，撤销 AI 的「关联作品」/「移除关联」用。只有当前行仍是那次写入留下的
  /// （`updatedAt == writtenAt`）才恢复，否则返回 false（用户之后又动过，不覆盖）。
  /// [previous] 为 null = 写入前没有这一行：写墓碑而不删行——行可能已同步到对端，
  /// 物理删除会被 LWW 同步拉回来。恢复也是一次新动作，`updatedAt` 必须大于 [writtenAt]。
  Future<bool> restoreMediaLinkSnapshot(
    MediaLinkId id, {
    required int writtenAt,
    MediaLinkRow? previous,
    int? at,
  }) => transaction(() async {
    final MediaLinkRow? row = await mediaLinkById(id);
    if (row == null || row.updatedAt != writtenAt) return false;
    final int now = at ?? DateTime.now().millisecondsSinceEpoch;
    final int stamp = now > writtenAt ? now : writtenAt + 1;
    await (update(mediaLinks)..where((t) => _mediaLinkIdIs(t, id))).write(
      previous == null
          ? MediaLinksCompanion(
              deletedAt: Value<int?>(stamp),
              updatedAt: Value<int>(stamp),
            )
          : MediaLinksCompanion(
              role: Value<String?>(previous.role),
              episodeRange: Value<String?>(previous.episodeRange),
              source: Value<String>(previous.source),
              confidence: Value<double?>(previous.confidence),
              isUserConfirmed: Value<bool>(previous.isUserConfirmed),
              reason: Value<String?>(previous.reason),
              deletedAt: Value<int?>(previous.deletedAt),
              updatedAt: Value<int>(stamp),
            ),
    );
    return true;
  });

  /// 把对端一行（键已换算成本机键）按 LWW 并入。**只在结果与本机不同时写库**，
  /// 返回是否改了（表变更观察者会被无变化的写自激）。
  Future<bool> mergeRemoteMediaLink(MediaLinkRow remote) => transaction(
    () async {
      final MediaLinkRow? local = await mediaLinkById(mediaLinkIdOf(remote));
      if (local != null && !mediaLinkRemoteWins(local, remote)) return false;
      // toCompanion(false)：null 列（deletedAt / role / reason …）必须显式写成
      // NULL。直接传数据类时 drift 按 nullToAbsent 省略 null 列，冲突更新就保留
      // 本机旧值——对端复活一条连接时墓碑会原地不动。
      await into(mediaLinks).insertOnConflictUpdate(remote.toCompanion(false));
      return true;
    },
  );
}
