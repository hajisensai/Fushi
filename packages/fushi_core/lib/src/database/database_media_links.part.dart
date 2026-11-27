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

/// 一行实际的生效方（[MediaLinkConfirmer]）：`user` / `ai` / null（建议）。
/// `is_user_confirmed` 是 `confirmed_by == 'user'` 的镜像，两者任一说 user 都算
/// user——只写了旧列的行（旧备份、旧对端、迁移前构造的内存行）按旧语义读；`user`
/// 压过 `ai`。未知值（对端未来新增）当建议，不当生效。
String? mediaLinkConfirmerOf(MediaLinkRow row) {
  if (row.isUserConfirmed || row.confirmedBy == MediaLinkConfirmer.user) {
    return MediaLinkConfirmer.user;
  }
  if (row.confirmedBy == MediaLinkConfirmer.ai) return MediaLinkConfirmer.ai;
  return null;
}

/// 一行的可见状态（墓碑优先）。`confirmed_by` 非空 = 已生效（用户确认或 AI 生效），
/// 读「已确认」的地方（详情页区块、主题曲识别、ops 路由）都经这里。
MediaLinkState mediaLinkStateOf(MediaLinkRow row) {
  if (row.deletedAt != null) return MediaLinkState.removed;
  return mediaLinkConfirmerOf(row) != null
      ? MediaLinkState.confirmed
      : MediaLinkState.suggested;
}

/// 同一时刻的状态名次：墓碑 3 > 用户确认 2 > AI 生效 1 > 建议 0。否决与用户确认
/// 都是用户动作，不能被同时刻的 AI 结论或建议压回去；AI 生效压过建议。
int mediaLinkStateRank({required bool deleted, required String? confirmer}) {
  if (deleted) return 3;
  return switch (confirmer) {
    MediaLinkConfirmer.user => 2,
    MediaLinkConfirmer.ai => 1,
    _ => 0,
  };
}

/// 一行连接在跨端 LWW 全序里的位置：`updatedAt` → 状态名次 → 内容指纹。
typedef MediaLinkVersion = ({int updatedAt, int rank, String content});

/// 内容指纹：时钟与名次都相同、内容却不同的两行（两台设备各自写了同一对条目）
/// 按它定胜负，保证任意合并顺序收敛到同一行；互联清单（`media_link_sync.dart`）
/// 用同一函数算，两边口径一致。
String mediaLinkContentKey({
  required String source,
  required double? confidence,
  required String? reason,
  required String? role,
  required String? episodeRange,
  required int createdAt,
  required int? deletedAt,
}) => <String>[
  source,
  confidence?.toString() ?? '',
  reason ?? '',
  role ?? '',
  episodeRange ?? '',
  '$createdAt',
  deletedAt?.toString() ?? '',
].join('\u0000');

MediaLinkVersion mediaLinkVersionOf(MediaLinkRow r) => (
  updatedAt: r.updatedAt,
  rank: mediaLinkStateRank(
    deleted: r.deletedAt != null,
    confirmer: mediaLinkConfirmerOf(r),
  ),
  content: mediaLinkContentKey(
    source: r.source,
    confidence: r.confidence,
    reason: r.reason,
    role: r.role,
    episodeRange: r.episodeRange,
    createdAt: r.createdAt,
    deletedAt: r.deletedAt,
  ),
);

/// [MediaLinkVersion] 的全序比较（正 = [a] 新）。
int compareMediaLinkVersions(MediaLinkVersion a, MediaLinkVersion b) {
  if (a.updatedAt != b.updatedAt) return a.updatedAt.compareTo(b.updatedAt);
  if (a.rank != b.rank) return a.rank.compareTo(b.rank);
  return a.content.compareTo(b.content);
}

/// 跨端 LWW 合并的裁决：[remote] 是否应覆盖 [local]（[compareMediaLinkVersions]
/// 严格更新才覆盖，完全相同保留本机，不来回翻）。
///
/// **AI 生效不推进时钟**（v159，AI 库管家设计稿 §5.3）：[FushiDatabase.applyAiMediaLink]
/// 写出的行 `updatedAt` 停在它所依据的状态上——把建议升为生效时沿用那条建议的
/// `updatedAt`，凭空新建时为 [kMediaLinkAiBaseClock]。于是 `updatedAt` 就是 AI 那一端
/// 的「基线」：对端的否决 / 用户确认只要晚于这个基线（AI 写入时没见过它），按时钟
/// 就压过 AI 生效；同一时刻按名次用户压过 AI。用户动作（手动连接、确认、否决、撤销）
/// 照常盖当前时刻。
bool mediaLinkRemoteWins(MediaLinkRow local, MediaLinkRow remote) =>
    compareMediaLinkVersions(
      mediaLinkVersionOf(remote),
      mediaLinkVersionOf(local),
    ) >
    0;

/// AI 凭空新建（之前没有这一行）的生效连接的 `updatedAt`：它不依据任何已有状态，
/// 任何设备上的任何用户动作都比它新。见 [mediaLinkRemoteWins]。
const int kMediaLinkAiBaseClock = 0;

/// [FushiDatabase.applyAiMediaLink] 一次写入的回执（撤销用）。
typedef MediaLinkAiWrite = ({MediaLinkId id, MediaLinkRow? previous});

/// 一行是不是**否决**墓碑：墓碑里只有「被新关系取代」（[MediaLinkSource.superseded]）
/// 的不算——那是 AI 改关系类型 / 方向留下的旧行，不是用户说「这一对不相关」。
/// 一对端点上的否决判据（[FushiDatabase.mediaLinkPairVetoed] /
/// [FushiDatabase.enforceMediaLinkVetoes]）都经这里。
bool mediaLinkIsVetoTombstone(MediaLinkRow row) =>
    row.deletedAt != null && row.source != MediaLinkSource.superseded;

/// [FushiDatabase.setAiMediaLinkRelation] 的结论。
enum MediaLinkAiRelationStatus {
  /// 写了：新关系已是 AI 生效，同一对上别的 AI 生效 / 建议行已标成「被取代」。
  written,

  /// 这一对上已经只有这一条 AI 生效的连接：什么都没写。
  unchanged,

  /// 这一对上有用户确认的连接：AI 不改（用户压过 AI）。
  userConfirmed,

  /// 这一对被否决过（有否决墓碑）：AI 不得再让它生效。
  vetoed,
}

/// [FushiDatabase.setAiMediaLinkRelation] 一次写入的回执（撤销用）：
/// [previous] 是目标行写入前的样子（null = 之前没有），[superseded] 是被标成
/// 「被取代」的旧行写入前的快照。
typedef MediaLinkAiRelationWrite = ({
  MediaLinkId id,
  MediaLinkRow? previous,
  List<MediaLinkRow> superseded,
});

mixin _FushiDbMediaLinks on _$FushiDatabase {
  Expression<bool> _mediaLinkIdIs($MediaLinksTable t, MediaLinkId id) =>
      t.fromKind.equals(id.fromKind) &
      t.fromKey.equals(id.fromKey) &
      t.relation.equals(id.relation) &
      t.toKind.equals(id.toKind) &
      t.toKey.equals(id.toKey);

  /// 生效方的两列一起写：`confirmed_by` 与它的镜像 `is_user_confirmed`。所有写入口
  /// 都经这里，调用方不各写各的。
  static MediaLinksCompanion _confirmerColumns(String? confirmer) =>
      MediaLinksCompanion(
        confirmedBy: Value<String?>(confirmer),
        isUserConfirmed: Value<bool>(confirmer == MediaLinkConfirmer.user),
      );

  /// 一整行落库前把两列规范成一致（[mediaLinkConfirmerOf] 的结论）。
  static MediaLinkRow _normalizedConfirmer(MediaLinkRow row) {
    final String? confirmer = mediaLinkConfirmerOf(row);
    return row.copyWith(
      confirmedBy: Value<String?>(confirmer),
      isUserConfirmed: confirmer == MediaLinkConfirmer.user,
    );
  }

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
            (t) => OrderingTerm.desc(t.confirmedBy.isNotNull()),
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
  }) async {
    if (from.kind == to.kind && from.key == to.key) {
      throw ArgumentError('media link endpoints must differ');
    }
    // 虚拟合集端点（负 id，BUG-5601）先物化，连接落在真合集上。
    from = await _writableLinkEndpoint(from);
    to = await _writableLinkEndpoint(to);
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
          confirmedBy: const Value<String?>(MediaLinkConfirmer.user),
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

  Expression<bool> _mediaLinkPairIs(
    $MediaLinksTable t,
    MediaLinkEndpoint a,
    MediaLinkEndpoint b,
  ) =>
      (t.fromKind.equals(a.kind.dbValue) &
          t.fromKey.equals(a.key) &
          t.toKind.equals(b.kind.dbValue) &
          t.toKey.equals(b.key)) |
      (t.fromKind.equals(b.kind.dbValue) &
          t.fromKey.equals(b.key) &
          t.toKind.equals(a.kind.dbValue) &
          t.toKey.equals(a.key));

  /// 两个端点之间是否已有任何行（任意关系、任意方向、含墓碑）。
  Future<bool> mediaLinkPairExists(
    MediaLinkEndpoint a,
    MediaLinkEndpoint b,
  ) async {
    final MediaLinkRow? row =
        await (select(mediaLinks)
              ..where((t) => _mediaLinkPairIs(t, a, b))
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  /// 两个端点之间是否有墓碑（任意关系、任意方向）——即这一对被否决过
  /// （见 [enforceMediaLinkVetoes]）。
  Future<bool> mediaLinkPairVetoed(
    MediaLinkEndpoint a,
    MediaLinkEndpoint b,
  ) async {
    final MediaLinkRow? row =
        await (select(mediaLinks)
              ..where(
                (t) =>
                    _mediaLinkPairIs(t, a, b) &
                    t.deletedAt.isNotNull() &
                    t.source.equals(MediaLinkSource.superseded).not(),
              )
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  /// AI 直接生效写一条连接（`confirmed_by = ai`，AI 库管家设计稿 §5.2 / §5.3）。
  /// [source] 保留证据来源、[reason] 保留理由。
  ///
  /// - 目标行是建议 → 升为 AI 生效（来源 / 置信度 / 理由换成这次的），`updatedAt`
  ///   **不变**（AI 不推进时钟，见 [mediaLinkRemoteWins]）；
  /// - 没有这一行、这一对条目之间也没有任何别的行 → 新建，`updatedAt` 为
  ///   [kMediaLinkAiBaseClock]；
  /// - 目标行已生效（用户确认 / AI 生效）、是否决墓碑（AI 不得复活用户否决过的一对），
  ///   这一对之间有任何墓碑（别的关系 / 方向被否决或撤销过，[enforceMediaLinkVetoes]
  ///   的不变量），或这一对之间已有别的关系的行 → 不写，返回 null。
  ///
  /// 返回写入回执：[MediaLinkAiWrite.previous] 是写入前的行（null = 之前没有），交
  /// [revertAiMediaLink] 撤销用。
  Future<MediaLinkAiWrite?> applyAiMediaLink({
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
      return Future<MediaLinkAiWrite?>.value();
    }
    final MediaLinkId id = mediaLinkIdFor(relation, from, to);
    return transaction(() async {
      final MediaLinkRow? existing = await mediaLinkById(id);
      if (existing != null) {
        if (existing.deletedAt != null) return null;
        if (mediaLinkConfirmerOf(existing) != null) return null;
        if (await mediaLinkPairVetoed(from, to)) return null;
        await (update(mediaLinks)..where((t) => _mediaLinkIdIs(t, id))).write(
          _confirmerColumns(MediaLinkConfirmer.ai).copyWith(
            source: Value<String>(source),
            confidence: Value<double?>(confidence),
            reason: Value<String?>(reason),
            role: role == null
                ? const Value<String?>.absent()
                : Value<String?>(role),
          ),
        );
        return (id: id, previous: existing);
      }
      if (await mediaLinkPairExists(from, to)) return null;
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
          confirmedBy: const Value<String?>(MediaLinkConfirmer.ai),
          isUserConfirmed: const Value<bool>(false),
          createdAt: now,
          updatedAt: kMediaLinkAiBaseClock,
        ),
      );
      return (id: id, previous: null);
    });
  }

  /// [applyAiMediaLink] 的撤销：把一条 AI 生效的连接退回写入前的状态。撤销是一次
  /// 用户动作，时钟取 `max(now, 当前行 updatedAt + 1)`——必须压过已经同步 / 备份
  /// 出去的同一份 AI 生效（AI 生效不推进时钟，那些副本的 `updatedAt` 都等于当前行）。
  ///
  /// - [previous] 为 null（之前没有这一行）→ **写墓碑，不删行**：这一行可能已同步到
  ///   对端或进了备份，物理删除后下一轮 LWW 合并会把它原样插回来（`updatedAt` 是
  ///   [kMediaLinkAiBaseClock]，本机已没有行可比）。墓碑同时就是「用户撤销过 AI 的这条
  ///   连接」：推断不再对这一对提议或生效（[mediaLinkPairExists] /
  ///   [enforceMediaLinkVetoes]），与「AI 对同一对（合集, 成员）最多移出一次」同一原则，
  ///   避免下一轮自动运行把刚撤销的又做回来；
  /// - 否则按 [previous] 恢复（升级前的建议）。
  ///
  /// 这一行已被用户确认 / 否决（或已不在）时不覆盖，返回 false（调用方报
  /// 「已被后续修改覆盖」，与 [discardMediaLinkSuggestion] 同一语义）。
  Future<bool> revertAiMediaLink(
    MediaLinkId id, {
    MediaLinkRow? previous,
    int? at,
  }) => transaction(() async {
    final MediaLinkRow? row = await mediaLinkById(id);
    if (row == null ||
        row.deletedAt != null ||
        mediaLinkConfirmerOf(row) != MediaLinkConfirmer.ai) {
      return false;
    }
    final int now = at ?? DateTime.now().millisecondsSinceEpoch;
    final int stamp = now > row.updatedAt ? now : row.updatedAt + 1;
    await (update(mediaLinks)..where((t) => _mediaLinkIdIs(t, id))).write(
      previous == null
          ? MediaLinksCompanion(
              deletedAt: Value<int?>(stamp),
              updatedAt: Value<int>(stamp),
            )
          : _confirmerColumns(mediaLinkConfirmerOf(previous)).copyWith(
              role: Value<String?>(previous.role),
              episodeRange: Value<String?>(previous.episodeRange),
              source: Value<String>(previous.source),
              confidence: Value<double?>(previous.confidence),
              reason: Value<String?>(previous.reason),
              deletedAt: Value<int?>(previous.deletedAt),
              updatedAt: Value<int>(stamp),
            ),
    );
    if (previous == null) await enforceMediaLinkVetoes(at: stamp);
    return true;
  });

  /// 否决的作用范围是**一对条目**，不是一行（AI 库管家设计稿 §5.3）：维护不变量
  /// 「同一对端点（不分关系与方向）上有墓碑时，不得有 `confirmed_by = ai` 的生效行」。
  /// 把违反它的 AI 生效行写成墓碑（时钟取 `max(now, updatedAt + 1)`，压过各端同一份
  /// AI 生效）；用户确认的行永远不动。幂等，单事务；返回写了几行。
  ///
  /// 墓碑来源判不清——用户否决一条 AI 生效连接（[removeMediaLink]）与撤销 AI 自己写
  /// 的连接（[revertAiMediaLink]）留下的墓碑在列上没有可靠区别（`confirmed_by` /
  /// `source` 都原样留着），而后者语义上本来也是用户否决——所以任何墓碑都算（宁可
  /// 少连）。
  ///
  /// 违反经合并出现（另一台设备在见到否决之前以别的关系 / 方向让 AI 生效了同一对），
  /// 合并后用户再否决其中一行时也会出现，所以各处各自保证：[applyAiMediaLink] 写入前
  /// 检查、互联清单合并（`applyMediaLinkManifest`）完、备份合并完，以及本机写墓碑的
  /// [removeMediaLink] / [revertAiMediaLink] / [restoreMediaLinkSnapshot]。各端按同一
  /// 份数据执行结果一致，再经 LWW 同步后收敛。
  Future<int> enforceMediaLinkVetoes({int? at}) => transaction(() async {
    final List<MediaLinkRow> rows = await allMediaLinks();
    String end(String kind, String key) => '$kind\u0000$key';
    String pairOf(MediaLinkRow r) {
      final String a = end(r.fromKind, r.fromKey);
      final String b = end(r.toKind, r.toKey);
      return a.compareTo(b) <= 0 ? '$a\u0001$b' : '$b\u0001$a';
    }

    // 「被取代」的旧行（AI 改关系类型留下的）不是否决，见 [mediaLinkIsVetoTombstone]。
    final Set<String> vetoed = <String>{
      for (final MediaLinkRow r in rows)
        if (mediaLinkIsVetoTombstone(r)) pairOf(r),
    };
    if (vetoed.isEmpty) return 0;
    final int now = at ?? DateTime.now().millisecondsSinceEpoch;
    int written = 0;
    for (final MediaLinkRow r in rows) {
      if (r.deletedAt != null ||
          mediaLinkConfirmerOf(r) != MediaLinkConfirmer.ai ||
          !vetoed.contains(pairOf(r))) {
        continue;
      }
      final int stamp = now > r.updatedAt ? now : r.updatedAt + 1;
      final MediaLinkId id = mediaLinkIdOf(r);
      await (update(mediaLinks)..where((t) => _mediaLinkIdIs(t, id))).write(
        MediaLinksCompanion(
          deletedAt: Value<int?>(stamp),
          updatedAt: Value<int>(stamp),
        ),
      );
      written++;
    }
    return written;
  });

  /// 两个端点之间的全部行（任意关系、任意方向、含墓碑）。
  Future<List<MediaLinkRow>> mediaLinksBetween(
    MediaLinkEndpoint a,
    MediaLinkEndpoint b,
  ) => (select(mediaLinks)..where((t) => _mediaLinkPairIs(t, a, b))).get();

  /// 让一对端点之间 AI 认定的关系变成 `from -[relation]-> to`（AI 管库 v3 §3.3 的
  /// `link` / `relink`）：
  ///
  /// - 这一对上有用户确认的连接 → [MediaLinkAiRelationStatus.userConfirmed]，不写；
  /// - 这一对被否决过（[mediaLinkIsVetoTombstone]）→ [MediaLinkAiRelationStatus.vetoed]；
  /// - 已经只剩这一条 AI 生效 → [MediaLinkAiRelationStatus.unchanged]；
  /// - 否则：同一对上别的**未删**行（AI 生效 / 建议）标成「被取代」墓碑（`source =`
  ///   [MediaLinkSource.superseded]，`updatedAt` **不推进**——它和 AI 生效一样是 AI 的
  ///   结论，对端晚于它的用户动作照常压过它；同一时钟上墓碑名次高于 AI 生效 / 建议，
  ///   对端那份旧行照样被它盖掉）；目标行：没有 → 新建 AI 生效（`updatedAt` 为
  ///   [kMediaLinkAiBaseClock]，同 [applyAiMediaLink]）；是建议 → 升为 AI 生效（时钟
  ///   不变）；是「被取代」墓碑（之前改走过的关系又改回来）→ 复活成 AI 生效，时钟取
  ///   墓碑 `updatedAt + 1`（刚好压过那条墓碑，仍输给之后的任何用户动作）。
  ///
  /// 不调 [enforceMediaLinkVetoes]：这里不写否决墓碑。返回结论与回执（交
  /// [revertAiMediaLinkRelation]）。
  Future<({MediaLinkAiRelationStatus status, MediaLinkAiRelationWrite? write})>
  setAiMediaLinkRelation({
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
      throw ArgumentError('media link endpoints must differ');
    }
    final MediaLinkId id = mediaLinkIdFor(relation, from, to);
    return transaction(() async {
      final List<MediaLinkRow> rows = await mediaLinksBetween(from, to);
      if (rows.any(
        (MediaLinkRow r) =>
            r.deletedAt == null &&
            mediaLinkConfirmerOf(r) == MediaLinkConfirmer.user,
      )) {
        return (status: MediaLinkAiRelationStatus.userConfirmed, write: null);
      }
      if (rows.any(mediaLinkIsVetoTombstone)) {
        return (status: MediaLinkAiRelationStatus.vetoed, write: null);
      }
      MediaLinkRow? target;
      final List<MediaLinkRow> others = <MediaLinkRow>[];
      for (final MediaLinkRow r in rows) {
        if (mediaLinkIdOf(r) == id) {
          target = r;
        } else if (r.deletedAt == null) {
          others.add(r);
        }
      }
      if (target != null &&
          target.deletedAt == null &&
          mediaLinkConfirmerOf(target) == MediaLinkConfirmer.ai &&
          others.isEmpty) {
        return (status: MediaLinkAiRelationStatus.unchanged, write: null);
      }
      final int now = at ?? DateTime.now().millisecondsSinceEpoch;
      for (final MediaLinkRow o in others) {
        final MediaLinkId oid = mediaLinkIdOf(o);
        await (update(mediaLinks)..where((t) => _mediaLinkIdIs(t, oid))).write(
          MediaLinksCompanion(
            source: const Value<String>(MediaLinkSource.superseded),
            deletedAt: Value<int?>(now),
          ),
        );
      }
      final MediaLinksCompanion aiColumns =
          _confirmerColumns(MediaLinkConfirmer.ai).copyWith(
            source: Value<String>(source),
            confidence: Value<double?>(confidence),
            reason: Value<String?>(reason),
            role: role == null
                ? const Value<String?>.absent()
                : Value<String?>(role),
          );
      if (target == null) {
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
            confirmedBy: const Value<String?>(MediaLinkConfirmer.ai),
            isUserConfirmed: const Value<bool>(false),
            createdAt: now,
            updatedAt: kMediaLinkAiBaseClock,
          ),
        );
      } else if (target.deletedAt != null) {
        // 只可能是「被取代」墓碑（否决墓碑上面已经挡掉了）。
        await (update(mediaLinks)..where((t) => _mediaLinkIdIs(t, id))).write(
          aiColumns.copyWith(
            deletedAt: const Value<int?>(null),
            updatedAt: Value<int>(target.updatedAt + 1),
          ),
        );
      } else if (mediaLinkConfirmerOf(target) == null) {
        await (update(
          mediaLinks,
        )..where((t) => _mediaLinkIdIs(t, id))).write(aiColumns);
      }
      return (
        status: MediaLinkAiRelationStatus.written,
        write: (id: id, previous: target, superseded: others),
      );
    });
  }

  /// [setAiMediaLinkRelation] 的撤销（一次用户动作，时钟取 `max(now, 涉及各行
  /// updatedAt + 1)`，压过已同步 / 备份出去的同一份 AI 结论）：
  ///
  /// - 目标行已不是 AI 生效（用户确认 / 否决过，或已不在）→ 不动，返回 false
  ///   （「已被后续修改覆盖」）；
  /// - 被取代的旧行：仍是这次留下的「被取代」墓碑的，恢复成写入前的快照；用户之后
  ///   动过的（复活 / 改过）不动；
  /// - 目标行：写入前有行 → 恢复成那一行；之前没有 → 这次是**改关系**（有被取代的
  ///   旧行）就同样标成「被取代」（用户要的是旧关系，不是否决这一对，否则旧行会被
  ///   否决不变量收掉）；是**新连**（没有旧行）就写否决墓碑（与 [revertAiMediaLink]
  ///   同一语义：用户撤销 AI 的连接 = 这一对不相关，AI 不再重复）。
  Future<bool> revertAiMediaLinkRelation(
    MediaLinkAiRelationWrite write, {
    int? at,
  }) => transaction(() async {
    final MediaLinkRow? row = await mediaLinkById(write.id);
    if (row == null ||
        row.deletedAt != null ||
        mediaLinkConfirmerOf(row) != MediaLinkConfirmer.ai) {
      return false;
    }
    final List<MediaLinkRow> restorable = <MediaLinkRow>[];
    int newest = row.updatedAt;
    for (final MediaLinkRow old in write.superseded) {
      final MediaLinkRow? cur = await mediaLinkById(mediaLinkIdOf(old));
      if (cur == null ||
          cur.deletedAt == null ||
          cur.source != MediaLinkSource.superseded) {
        continue;
      }
      restorable.add(old);
      if (cur.updatedAt > newest) newest = cur.updatedAt;
    }
    final int now = at ?? DateTime.now().millisecondsSinceEpoch;
    final int stamp = now > newest ? now : newest + 1;
    for (final MediaLinkRow old in restorable) {
      await into(mediaLinks).insertOnConflictUpdate(
        _normalizedConfirmer(old.copyWith(updatedAt: stamp)).toCompanion(false),
      );
    }
    final MediaLinkRow? previous = write.previous;
    if (previous != null) {
      await into(mediaLinks).insertOnConflictUpdate(
        _normalizedConfirmer(
          previous.copyWith(updatedAt: stamp),
        ).toCompanion(false),
      );
    } else if (write.superseded.isNotEmpty) {
      await (update(
        mediaLinks,
      )..where((t) => _mediaLinkIdIs(t, write.id))).write(
        MediaLinksCompanion(
          source: const Value<String>(MediaLinkSource.superseded),
          deletedAt: Value<int?>(stamp),
          updatedAt: Value<int>(stamp),
        ),
      );
    } else {
      await (update(
        mediaLinks,
      )..where((t) => _mediaLinkIdIs(t, write.id))).write(
        MediaLinksCompanion(
          deletedAt: Value<int?>(stamp),
          updatedAt: Value<int>(stamp),
        ),
      );
      await enforceMediaLinkVetoes(at: stamp);
    }
    return true;
  });

  /// 用户确认一条建议或一条 AI 生效的连接（升为 `user`）。行不存在 / 已是墓碑返回
  /// false（被别处否决的不复活）。
  Future<bool> confirmMediaLink(MediaLinkId id, {int? at}) =>
      transaction(() async {
        final MediaLinkRow? row = await mediaLinkById(id);
        if (row == null || row.deletedAt != null) return false;
        if (mediaLinkConfirmerOf(row) == MediaLinkConfirmer.user) return true;
        await (update(mediaLinks)..where((t) => _mediaLinkIdIs(t, id))).write(
          _confirmerColumns(MediaLinkConfirmer.user).copyWith(
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
        // 否决管一整对：同一对上别的关系 / 方向的 AI 生效（合并带来的）一并收掉。
        await enforceMediaLinkVetoes(at: now);
        return true;
      });

  /// [confirmMediaLink] 的反向（撤销「接受建议」）：一条已生效、未删的**推断**
  /// 连接退回建议，刷新 `updatedAt`（LWW 下这是一次新的用户动作）。手动连接
  /// （`source = manual`）本来就不是建议，不退回。返回是否退回了。
  Future<bool> unconfirmMediaLink(MediaLinkId id, {int? at}) =>
      transaction(() async {
        final MediaLinkRow? row = await mediaLinkById(id);
        if (row == null ||
            row.deletedAt != null ||
            mediaLinkConfirmerOf(row) == null ||
            row.source == MediaLinkSource.manual) {
          return false;
        }
        await (update(mediaLinks)..where((t) => _mediaLinkIdIs(t, id))).write(
          _confirmerColumns(null).copyWith(
            updatedAt: Value<int>(at ?? DateTime.now().millisecondsSinceEpoch),
          ),
        );
        return true;
      });

  /// [removeMediaLink] 否决建议的反向（撤销「不相关」）：未生效的墓碑行恢复成
  /// 建议（清墓碑、刷新 `updatedAt`）。行不在 / 不是墓碑 / 是已生效连接（用户确认
  /// 或 AI 生效）的墓碑返回 false。
  Future<bool> restoreMediaLinkSuggestion(MediaLinkId id, {int? at}) =>
      transaction(() async {
        final MediaLinkRow? row = await mediaLinkById(id);
        if (row == null ||
            row.deletedAt == null ||
            mediaLinkConfirmerOf(row) != null) {
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
        if (row == null ||
            row.deletedAt != null ||
            mediaLinkConfirmerOf(row) != null) {
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
          : _confirmerColumns(mediaLinkConfirmerOf(previous)).copyWith(
              role: Value<String?>(previous.role),
              episodeRange: Value<String?>(previous.episodeRange),
              source: Value<String>(previous.source),
              confidence: Value<double?>(previous.confidence),
              reason: Value<String?>(previous.reason),
              deletedAt: Value<int?>(previous.deletedAt),
              updatedAt: Value<int>(stamp),
            ),
    );
    if (previous == null) await enforceMediaLinkVetoes(at: stamp);
    return true;
  });

  /// 把对端一行（键已换算成本机键）按 LWW 并入。**只在结果与本机不同时写库**，
  /// 返回是否改了（表变更观察者会被无变化的写自激）。
  ///
  /// [confirmerKnown] 为 false：对端没说 `confirmed_by`（v159 之前的对端 / 备份，
  /// 只有 `is_user_confirmed`）。这时对端的「未确认」是**未知**而不是「建议」——旧版
  /// 不认识 AI 生效，会把它当建议显示、原样回传。所以对端未删、未确认的行即便按时钟
  /// 胜出，本机已是 AI 生效的那一行仍保持 AI 生效（只接收其余列），不被冲掉
  /// （AI 库管家设计稿 §13）。对端说了用户确认 / 否决照常按 LWW 生效。
  Future<bool> mergeRemoteMediaLink(
    MediaLinkRow remote, {
    bool confirmerKnown = true,
  }) => transaction(() async {
    final MediaLinkRow? local = await mediaLinkById(mediaLinkIdOf(remote));
    MediaLinkRow incoming = _normalizedConfirmer(remote);
    if (!confirmerKnown &&
        local != null &&
        local.deletedAt == null &&
        mediaLinkConfirmerOf(local) == MediaLinkConfirmer.ai &&
        incoming.deletedAt == null &&
        mediaLinkConfirmerOf(incoming) == null) {
      incoming = incoming.copyWith(
        confirmedBy: const Value<String?>(MediaLinkConfirmer.ai),
        isUserConfirmed: false,
      );
    }
    if (local != null && !mediaLinkRemoteWins(local, incoming)) return false;
    // toCompanion(false)：null 列（deletedAt / role / reason …）必须显式写成
    // NULL。直接传数据类时 drift 按 nullToAbsent 省略 null 列，冲突更新就保留
    // 本机旧值——对端复活一条连接时墓碑会原地不动。
    await into(mediaLinks).insertOnConflictUpdate(incoming.toCompanion(false));
    return true;
  });

  Expression<bool> _mediaLinkTouches(
    $MediaLinksTable t,
    MediaLinkEndpoint endpoint,
  ) =>
      (t.fromKind.equals(endpoint.kind.dbValue) &
          t.fromKey.equals(endpoint.key)) |
      (t.toKind.equals(endpoint.kind.dbValue) & t.toKey.equals(endpoint.key));

  /// 端点本身被删（合集 / 游戏行没了）时，物理删掉它的全部连接（含墓碑）。
  ///
  /// 只用于键是**本机自增 / 本机生成 id** 的端点（[MediaLinkKind.videoCollection] =
  /// `media_collections.id`、[MediaLinkKind.game] = `galgames.id`）：这种 id 删了就永不
  /// 再出现（合集 AUTOINCREMENT 不复用；同一游戏重新入库拿新 id），留下的连接只会在
  /// 「同一作品」里显示成标题是一串 id 的「未入库」死卡。书 / 视频 / 音乐的键跨端稳定、
  /// 条目回来时自然对上，不走这里。
  ///
  /// 物理删除而不写墓碑：墓碑是「否决过这一对」，端点没了谈不上否决；同步 / 备份合并
  /// 落合集 / 游戏端点前都先换算成本机 id、本机没有就跳过（`media_link_sync.dart`、
  /// `backup_merge_engine.dart`），删掉的行不会被拉回来（BUG-5457）。
  Future<int> purgeMediaLinksForEndpoint(MediaLinkEndpoint endpoint) =>
      (delete(mediaLinks)..where((t) => _mediaLinkTouches(t, endpoint))).go();

  /// 端点被并进另一个端点（合集合并、刮削把整部合集原样搬进新合集）时，把它的全部
  /// 连接（含建议与墓碑）改挂到 [to] 上：
  /// - 改挂后两端相同（原本就连着 [to]）的行直接删；
  /// - [to] 上已有同一身份的行时按跨端 LWW 内核（[mergeRemoteMediaLink]）取胜者；
  /// - 认不出种类 / 关系的行（对端未来新增）无从换算身份，删掉（端点已不存在）。
  /// 返回改挂成功的行数。
  Future<int> retargetMediaLinks({
    required MediaLinkEndpoint from,
    required MediaLinkEndpoint to,
  }) => transaction(() async {
    if (from.kind == to.kind && from.key == to.key) return 0;
    int moved = 0;
    for (final MediaLinkRow row in await _mediaLinksTouching(from)) {
      await (delete(
        mediaLinks,
      )..where((t) => _mediaLinkIdIs(t, mediaLinkIdOf(row)))).go();
      final MediaLinkId? id = _retargetedMediaLinkId(row, from, to);
      if (id == null) continue;
      await mergeRemoteMediaLink(
        row.copyWith(
          fromKind: id.fromKind,
          fromKey: id.fromKey,
          toKind: id.toKind,
          toKey: id.toKey,
        ),
      );
      moved++;
    }
    return moved;
  });

  /// [retargetMediaLinks] 会写到 [to] 上的每个身份**改挂前**的样子（撤销用）：
  /// `{'id': 五元组, 'row': 行 JSON 或 null}`（null = 那时 [to] 上没有这一行）。
  ///
  /// 改挂对 [to] 的影响不止「多出几行」：撞同一身份时按 LWW 会改写 [to] 原有的行。
  /// 只把 [from] 自己的连接插回去还原不了这些——同一对端会同时连着 [from] 和 [to]，
  /// 被改写的内容也回不来。可直接 `jsonEncode`，交 [restoreMediaLinkRetargetPreimage]。
  Future<List<Map<String, Object?>>> captureMediaLinkRetargetPreimage({
    required MediaLinkEndpoint from,
    required MediaLinkEndpoint to,
  }) => transaction(() async {
    if (from.kind == to.kind && from.key == to.key) {
      return const <Map<String, Object?>>[];
    }
    final Set<MediaLinkId> seen = <MediaLinkId>{};
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    for (final MediaLinkRow row in await _mediaLinksTouching(from)) {
      final MediaLinkId? id = _retargetedMediaLinkId(row, from, to);
      if (id == null || !seen.add(id)) continue;
      final MediaLinkRow? before = await mediaLinkById(id);
      out.add(<String, Object?>{
        'id': <String, Object?>{
          'fromKind': id.fromKind,
          'fromKey': id.fromKey,
          'relation': id.relation,
          'toKind': id.toKind,
          'toKey': id.toKey,
        },
        'row': before?.toJson(),
      });
    }
    return out;
  });

  /// 按 [captureMediaLinkRetargetPreimage] 的记录把改挂目标上的连接还原：记录里有
  /// 原行的写回原行（覆盖改挂 / LWW 改写后的内容），没有的删掉（那是改挂新插的）。
  /// 读不懂的条目跳过。
  Future<void> restoreMediaLinkRetargetPreimage(List<Object?> preimage) =>
      transaction(() async {
        for (final Object? raw in preimage) {
          if (raw is! Map || raw['id'] is! Map) continue;
          final Map<Object?, Object?> rawId = raw['id'] as Map;
          final Object? fromKind = rawId['fromKind'];
          final Object? fromKey = rawId['fromKey'];
          final Object? relation = rawId['relation'];
          final Object? toKind = rawId['toKind'];
          final Object? toKey = rawId['toKey'];
          if (fromKind is! String ||
              fromKey is! String ||
              relation is! String ||
              toKind is! String ||
              toKey is! String) {
            continue;
          }
          final MediaLinkId id = (
            fromKind: fromKind,
            fromKey: fromKey,
            relation: relation,
            toKind: toKind,
            toKey: toKey,
          );
          await (delete(mediaLinks)..where((t) => _mediaLinkIdIs(t, id))).go();
          final Object? before = raw['row'];
          if (before is Map) {
            await into(mediaLinks).insert(
              MediaLinkRow.fromJson(
                Map<String, dynamic>.from(before),
              ).toCompanion(false),
            );
          }
        }
      });

  Future<List<MediaLinkRow>> _mediaLinksTouching(MediaLinkEndpoint endpoint) =>
      (select(mediaLinks)..where((t) => _mediaLinkTouches(t, endpoint))).get();

  /// [row] 把端点 [from] 换成 [to] 之后的身份；认不出种类 / 关系（无从换算）或换完
  /// 两端相同（自环）返回 null——[retargetMediaLinks] 直接删掉这种行。
  static MediaLinkId? _retargetedMediaLinkId(
    MediaLinkRow row,
    MediaLinkEndpoint from,
    MediaLinkEndpoint to,
  ) {
    final MediaLinkRelation? relation = MediaLinkRelation.tryParse(
      row.relation,
    );
    final MediaLinkKind? fromKind = MediaLinkKind.tryParse(row.fromKind);
    final MediaLinkKind? toKind = MediaLinkKind.tryParse(row.toKind);
    if (relation == null || fromKind == null || toKind == null) return null;
    MediaLinkEndpoint swap(MediaLinkEndpoint e) =>
        e.kind == from.kind && e.key == from.key ? to : e;
    final MediaLinkEndpoint a = swap((kind: fromKind, key: row.fromKey));
    final MediaLinkEndpoint b = swap((kind: toKind, key: row.toKey));
    if (a.kind == b.kind && a.key == b.key) return null;
    return mediaLinkIdFor(relation, a, b);
  }

  /// 清掉端点已不存在的合集 / 游戏连接（[purgeMediaLinksForEndpoint] 之前删合集 /
  /// 游戏不清连接，存量库里留着死行；schema v181 迁移跑一次）。幂等，返回删除行数。
  Future<int> purgeDanglingMediaLinks() {
    final String collection = MediaLinkKind.videoCollection.dbValue;
    final String game = MediaLinkKind.game.dbValue;
    String dead(String side) =>
        "(${side}_kind = '$collection' AND NOT EXISTS (SELECT 1 FROM media_collections "
        'AS c WHERE CAST(c.id AS TEXT) = media_links.${side}_key)) OR '
        "(${side}_kind = '$game' AND NOT EXISTS (SELECT 1 FROM galgames AS g "
        'WHERE g.id = media_links.${side}_key))';
    return customUpdate(
      'DELETE FROM media_links WHERE ${dead('from')} OR ${dead('to')}',
      updates: <TableInfo<Table, Object?>>{mediaLinks},
      updateKind: UpdateKind.delete,
    );
  }
}

Future<MediaLinkEndpoint> _writableLinkEndpoint(MediaLinkEndpoint e) async {
  if (e.kind != MediaLinkKind.videoCollection) return e;
  final int? id = collectionIdOfTagEntryKey(e.key);
  if (id == null || id > 0) return e;
  return (
    kind: e.kind,
    key: collectionTagEntryKey(await _writableCollectionId(id)),
  );
}
