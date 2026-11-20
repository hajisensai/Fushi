/// 备份还原（覆盖 / 合并）里复习数据的落库步骤（docs/specs/2026-10-14-fushi-srs-design.md 铁律 E；新代口径见
/// 交接说明「G11-4」一节）。
///
/// 通用合并路径按业务键逐行 upsert / 按名重映射 profile id，对 SRS 不成立：复习数据按集合归属（profile 经绑定指向
/// 集合）。所以 srs_* 表在通用路径登记为跳过（`mergeSkippedDeviceLocalTableNames`），由 [mergeSrsFromBackup] 按
/// profile uid / 名字对上本机 profile 之后，交给内核命令落库（新形态 `import`、旧形态 `legacy_backup_import`，
/// srs_backup_bundle.dart）——与 `.fushisrs` 导入同一套认领与确认，不做任何 ID 重映射。
///
/// [SrsBackupSource] 只读 2026-10-23 之前的老形态备份（SRS 表在备份主库里，v1 事件），由调用方写成 JSONL 交给内核。
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_backup_bundle.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_data.dart'
    show srsPurgeProfileRows;
import 'package:fushi_engine/srs/srs_reads.dart';
import 'package:fushi_engine/srs/srs_storage.dart';

/// 只读地读一份老形态备份（2026-10-23 之前：srs_* 表在备份主库里）的 SRS 数据：[SrsBackupSource.database]（单独
/// 打开的备份库）或 [SrsBackupSource.attached]（ATTACH 在本机主库连接上）。只发 SELECT，不碰任何 SRS 库。
class SrsBackupSource {
  SrsBackupSource.database(DatabaseConnectionUser db) : this._(db, '', db, '');

  /// [schema] 是 `ATTACH DATABASE ... AS <schema>` 的别名。
  SrsBackupSource.attached(DatabaseConnectionUser connection, String schema)
    : this._(connection, '$schema.', connection, '$schema.');

  SrsBackupSource._(
    this._profilesDb,
    this._profilesPrefix,
    this._legacy,
    this._prefix,
  );

  final DatabaseConnectionUser _profilesDb;
  final String _profilesPrefix;

  /// srs_* 表所在的连接。
  final DatabaseConnectionUser _legacy;
  final String _prefix;

  String _t(String table) => '$_prefix$table';

  Future<bool> _any(String table, String profileUid) async =>
      await _legacy
          .customSelect(
            'SELECT 1 FROM ${_t(table)} WHERE profile_uid = ? LIMIT 1',
            variables: <Variable<Object>>[Variable<String>(profileUid)],
          )
          .getSingleOrNull() !=
      null;

  /// 该 profile 在备份里是否有内置行之外的 SRS 数据。
  Future<bool> _hasData(String profileUid) async {
    final Set<String> builtin = <String>{
      for (final SrsEntityRecord r in srsBuiltinEntities(profileUid)) r.id,
    };
    final List<QueryRow> ids = await _legacy
        .customSelect(
          'SELECT id FROM ${_t('srs_entities')} WHERE profile_uid = ?',
          variables: <Variable<Object>>[Variable<String>(profileUid)],
        )
        .get();
    if (ids.any((QueryRow r) => !builtin.contains(r.read<String>('id')))) {
      return true;
    }
    for (final String table in const <String>[
      'srs_field_edits',
      'srs_review_logs',
      'srs_unknown_events',
    ]) {
      if (await _any(table, profileUid)) return true;
    }
    return false;
  }

  /// 备份里有 SRS 数据的 profile（按本地自增 id 排序，确定性）。
  Future<List<SrsBackupProfile>> profilesWithSrsData() async {
    final List<QueryRow> rows = await _profilesDb
        .customSelect(
          'SELECT name, uid FROM ${_profilesPrefix}profiles '
          "WHERE uid IS NOT NULL AND uid != '' ORDER BY id",
        )
        .get();
    final List<SrsBackupProfile> out = <SrsBackupProfile>[];
    for (final QueryRow r in rows) {
      final String uid = r.read<String>('uid');
      if (await _hasData(uid)) {
        out.add(SrsBackupProfile(uid: uid, name: r.read<String>('name')));
      }
    }
    return out;
  }

  /// 该 profile 的卡片 → 笔记（老形态的 `srs_cards_cache`；没有这张表回空）：v1 复习日志写成 JSONL 时要带笔记 ID
  /// （srs_backup_bundle.dart `srsWriteLegacyEventsJsonl`）。
  Future<Map<String, String>> noteOfCard(String profileUid) async {
    final String schema = _prefix.isEmpty
        ? 'main'
        : _prefix.substring(0, _prefix.length - 1);
    final bool has =
        (await _legacy
            .customSelect(
              'SELECT 1 FROM $schema.sqlite_master '
              "WHERE type = 'table' AND name = 'srs_cards_cache'",
            )
            .getSingleOrNull()) !=
        null;
    if (!has) return const <String, String>{};
    return <String, String>{
      for (final QueryRow r
          in await _legacy
              .customSelect(
                'SELECT id, note_id FROM ${_t('srs_cards_cache')} '
                'WHERE profile_uid = ? AND note_id IS NOT NULL',
                variables: <Variable<Object>>[Variable<String>(profileUid)],
              )
              .get())
        r.read<String>('id'): r.read<String>('note_id'),
    };
  }

  /// 该 profile 的全部事件（身份记录 → 修改记录 → 复习日志 → 不认识的事件），
  /// 解码方式与 [SrsDbStore.exportAll] 一致。
  Future<List<SrsEvent>> eventsOf(String profileUid) async {
    final DatabaseConnectionUser db = _legacy;
    final List<Variable<Object>> v = <Variable<Object>>[
      Variable<String>(profileUid),
    ];
    Map<String, Object?> obj(String json) =>
        (jsonDecode(json) as Map).cast<String, Object?>();
    final List<SrsEvent> out = <SrsEvent>[];
    for (final QueryRow r
        in await db
            .customSelect(
              'SELECT id, profile_uid, kind, payload_json FROM '
              '${_t('srs_entities')} WHERE profile_uid = ? ORDER BY id',
              variables: v,
            )
            .get()) {
      out.add(
        SrsEntityEvent(
          SrsEntityRecord(
            id: r.read<String>('id'),
            profileUid: r.read<String>('profile_uid'),
            kind:
                SrsEntityKind.tryParse(r.read<String>('kind')) ??
                SrsEntityKind.note,
            payload: obj(r.read<String>('payload_json')),
          ),
        ),
      );
    }
    for (final QueryRow r
        in await db
            .customSelect(
              'SELECT json FROM ${_t('srs_field_edits')} '
              'WHERE profile_uid = ? ORDER BY id',
              variables: v,
            )
            .get()) {
      out.add(SrsEditEvent(SrsFieldEdit.fromJson(obj(r.read<String>('json')))));
    }
    for (final QueryRow r
        in await db
            .customSelect(
              'SELECT json FROM ${_t('srs_review_logs')} '
              'WHERE profile_uid = ? ORDER BY id',
              variables: v,
            )
            .get()) {
      out.add(SrsLogEvent(SrsReviewLog.fromJson(obj(r.read<String>('json')))));
    }
    for (final QueryRow r
        in await db
            .customSelect(
              'SELECT json FROM ${_t('srs_unknown_events')} '
              'WHERE profile_uid = ? ORDER BY id',
              variables: v,
            )
            .get()) {
      out.add(SrsUnknownEvent(obj(r.read<String>('json'))));
    }
    return out;
  }
}

/// [srs] 里 [profileUid] 的全部事件（身份记录 → 修改记录 → 复习日志 → 不认识的事件，各按 ID 排），内核读命令
/// `events`（native/fushi_fsrs/src/store/reads.rs）。
Future<List<SrsEvent>> srsEventsOf(SrsCore srs, String profileUid) async {
  final Map<String, SrsColumns> t = (await srsRead(
    srs,
    profileUid,
    'events',
    const <String, Object?>{'ordered': true},
  )).tables;
  Map<String, Object?> obj(String json) =>
      (jsonDecode(json) as Map).cast<String, Object?>();
  final List<SrsEvent> out = <SrsEvent>[];
  final SrsColumns entities = t['entities']!;
  final SrsStringColumn id = entities.strings('id');
  final SrsStringColumn kind = entities.strings('kind');
  final SrsStringColumn payload = entities.strings('payload_json');
  for (int i = 0; i < entities.rows; i++) {
    out.add(
      SrsEntityEvent(
        SrsEntityRecord(
          id: id[i],
          profileUid: profileUid,
          kind: SrsEntityKind.tryParse(kind[i]) ?? SrsEntityKind.note,
          payload: obj(payload[i]),
        ),
      ),
    );
  }
  List<String> jsons(String name) => t[name]!.strings('json').toList();
  for (final String j in jsons('edits')) {
    out.add(SrsEditEvent(SrsFieldEdit.fromJson(obj(j))));
  }
  for (final String j in jsons('logs')) {
    out.add(SrsLogEvent(SrsReviewLog.fromJson(obj(j))));
  }
  for (final String j in jsons('unknown')) {
    out.add(SrsUnknownEvent(obj(j)));
  }
  return out;
}

/// 备份里一个有 SRS 数据的 profile。
class SrsBackupProfile {
  const SrsBackupProfile({required this.uid, required this.name});

  final String uid;
  final String name;
}

/// 备份 profile 落到本机的方式（铁律 E 在新代上的三种情况）。
enum SrsBackupMergeAction {
  /// 本机已有同 uid 的 profile。
  sameUid,

  /// 本机有 profile 已经绑在备份的这个集合上（之前合并 / 关联过：集合标识相同，或它的盐里有备份里的 uid）。
  sameCollection,

  /// 本机同名 profile（无用户数据、从未发布）认领了备份的集合（内核 `collection_adopt`，profile 的 uid 不变）。
  adoptedCollection,

  /// 新建了「<原名>（备份）」profile（uid = 备份里的 uid）。
  createdProfile,

  /// 要用户确认（另一个复习库 / 新的旧 profile 标识 / 新设备公钥）而调用方没确认：这一份没落，本机一点没动。
  declined,
}

/// 一个备份集合的合并结果。
class SrsBackupMergeResult {
  const SrsBackupMergeResult({
    required this.profileUid,
    required this.localProfileId,
    required this.action,
    required this.newEvents,
  });

  /// 落进的本机 profile uid（[SrsBackupMergeAction.declined] 时是本该落进的那个）。
  final String profileUid;

  /// 本机 profile 的自增 id（[SrsBackupMergeAction.declined] 且要新建时为 null）。
  final int? localProfileId;
  final SrsBackupMergeAction action;

  /// 内核这次并入的操作数（`applied`）；重复合并同一份备份为 0。
  final int newEvents;
}

/// 新建本机 profile「[name]」并让它用 uid [uid]，返回本地自增 id；由调用方决定建法（合并导入直接插 profiles 行）。
/// 覆盖还原在主库换好之前就落复习数据：先记下、主库换好后再插，此时回 null。
typedef SrsCreateProfile = Future<int?> Function(String name, String uid);

/// 本机一个 profile（主库 `profiles` 的一行）。
typedef SrsLocalProfile = ({int id, String name, String? uid});

/// 读主库 [db] 里的全部 profile（按自增 id 排）。
Future<List<SrsLocalProfile>> srsLocalProfilesOf(
  DatabaseConnectionUser db,
) async => <SrsLocalProfile>[
  for (final QueryRow r
      in await db
          .customSelect('SELECT id, name, uid FROM main.profiles ORDER BY id')
          .get())
    (
      id: r.read<int>('id'),
      name: r.read<String>('name'),
      uid: r.read<String?>('uid'),
    ),
];

/// 新建 profile 的名字：「<原名>（备份）」，撞名时「<原名>（备份 2）」……
String srsBackupProfileName(String original, Set<String> taken) {
  final String base = '$original（备份）';
  if (!taken.contains(base)) return base;
  for (int i = 2; ; i++) {
    final String candidate = '$original（备份 $i）';
    if (!taken.contains(candidate)) return candidate;
  }
}

/// 备份里一份要落库的复习数据：它在备份里属于哪些 profile（第一个的名字用来按名对上本机）+ 文件。
final class SrsBackupLandUnit {
  const SrsBackupLandUnit({required this.profiles, required this.file});

  final List<SrsBackupProfile> profiles;
  final SrsBackupSourceFile file;
}

/// 把 [units] 逐个落进本机新代库 [localSrs]（Primary）：profile 行在主库 [local]（铁律 E，新代口径）：
///
/// 1. 本机有 uid 与备份里那个集合的某个 profile 相同的 profile → 落进它；否则本机有 profile 已经绑在这个集合上
///    （集合标识相同，或它的盐里有备份里的 uid：之前合并 / 关联过）→ 落进它。
/// 2. 否则本机有同名 profile，且它没有用户数据、也从未发布过（[freshLibrary] = 目标库是覆盖还原新建的空库，本机
///    profile 在里面都还没有数据）→ 它认领备份的集合（内核 `collection_adopt`，profile 的 uid 不变；以前是改 uid）。
/// 3. 否则为备份的 uid 新建本机 profile「<原名>（备份）」，再落进去。
///
/// 落库是内核命令（新形态 `import`、旧形态 `legacy_backup_import`），先认领再读入，一个写事务。并入另一个复习库、
/// 记下新的旧 profile 标识（盐）或新设备公钥要用户确认：[confirmed] 为假时先预检（什么都不写），需要确认的那一份
/// 记成 [SrsBackupMergeAction.declined]、不建 profile、什么都不写。
///
/// 幂等：同一份备份合并两次，第二次全部走第 1 种（第 3 种建出的 profile 用的就是备份 uid；第 2 种认领之后绑在
/// 备份的集合上）、内核回 `unchanged`。
/// 两个文件不能一起原子提交：新建 profile 先写主库再落库，落库失败时留下一个空 profile，重跑时按「同 uid」接着落。
Future<List<SrsBackupMergeResult>> mergeSrsFromBackup({
  required List<SrsBackupLandUnit> units,
  required Future<List<SrsLocalProfile>> Function() localProfiles,
  required SrsCore localSrs,
  required SrsCreateProfile createProfile,
  required bool confirmed,
  required int nowMs,
  bool freshLibrary = false,
}) async {
  final List<SrsBackupMergeResult> results = <SrsBackupMergeResult>[];
  for (final SrsBackupLandUnit unit in units) {
    if (unit.profiles.isEmpty) continue;
    final SrsBackupProfile bp = unit.profiles.first;
    final List<SrsLocalProfile> profiles = await localProfiles();
    final SrsLocalProfile? sameUid = _firstWhere(
      profiles,
      (SrsLocalProfile p) =>
          unit.profiles.any((SrsBackupProfile b) => b.uid == p.uid),
    );
    String target;
    int? localId;
    SrsBackupMergeAction action;
    final SrsLocalProfile? sameCollection = sameUid != null || freshLibrary
        ? null
        : await _boundToUnit(localSrs, profiles, unit);
    if (sameUid != null) {
      target = sameUid.uid!;
      localId = sameUid.id;
      action = SrsBackupMergeAction.sameUid;
    } else if (sameCollection != null) {
      target = sameCollection.uid!;
      localId = sameCollection.id;
      action = SrsBackupMergeAction.sameCollection;
    } else {
      final SrsLocalProfile? sameName = _firstWhere(
        profiles,
        (SrsLocalProfile p) =>
            p.name == bp.name && p.uid != null && p.uid!.isNotEmpty,
      );
      if (sameName != null &&
          (freshLibrary || await _canAdoptUid(localSrs, sameName.uid))) {
        target = sameName.uid!;
        localId = sameName.id;
        action = SrsBackupMergeAction.adoptedCollection;
      } else {
        target = bp.uid;
        localId = null;
        action = SrsBackupMergeAction.createdProfile;
      }
    }
    if (!confirmed) {
      final SrsBackupLanded pre = await srsLandBackupUnit(
        core: localSrs,
        targetUid: target,
        file: unit.file,
        confirmed: false,
        preflight: true,
        nowMs: nowMs,
      );
      if (pre.needsConfirm) {
        results.add(
          SrsBackupMergeResult(
            profileUid: target,
            localProfileId: localId,
            action: SrsBackupMergeAction.declined,
            newEvents: 0,
          ),
        );
        continue;
      }
    }
    if (action == SrsBackupMergeAction.createdProfile) {
      final String name = srsBackupProfileName(bp.name, <String>{
        for (final SrsLocalProfile p in profiles) p.name,
      });
      localId = await createProfile(name, bp.uid);
    }
    final SrsBackupLanded landed = await srsLandBackupUnit(
      core: localSrs,
      targetUid: target,
      file: unit.file,
      confirmed: confirmed,
      nowMs: nowMs,
    );
    if (landed.needsConfirm) {
      // 预检之后绑定变了（别的调用改了这个 profile）：不按旧结论落，交给用户重来。
      throw StateError(
        'srs backup restore: the profile binding changed while restoring; '
        'restore again',
      );
    }
    results.add(
      SrsBackupMergeResult(
        profileUid: target,
        localProfileId: localId,
        action: action,
        newEvents: landed.applied,
      ),
    );
  }
  return results;
}

/// [profiles] 里已经绑在 [unit] 那个集合上的第一个 profile（内核 `collection_info`：集合标识相同，或盐里有备份里
/// 的 uid）；没绑过集合的跳过。
Future<SrsLocalProfile?> _boundToUnit(
  SrsCore core,
  List<SrsLocalProfile> profiles,
  SrsBackupLandUnit unit,
) async {
  final Set<String> uids = <String>{
    for (final SrsBackupProfile b in unit.profiles) b.uid,
  };
  final SrsBackupSourceFile file = unit.file;
  final String? collection = file is SrsBackupStreamFile
      ? file.unit.collection
      : null;
  for (final SrsLocalProfile p in profiles) {
    final String? uid = p.uid;
    if (uid == null || uid.isEmpty) continue;
    final Map<String, Object?> info;
    try {
      info = core.sync2(<String, Object?>{
        'op': 'collection_info',
        'profile': uid,
      }).map;
    } on SrsProfileUnboundException {
      continue;
    }
    if (collection != null && info['collection'] == collection) return p;
    // 协议 3 形态（`srs.db` 条目 / 主库老表）：那时集合 = collection_of(uid)、位置目录名 = uid，认领后绑定的目录名
    // 就是备份里那个 profile 的 uid。
    final Object? dir = info['dir'];
    if (dir is String && uids.contains(dir)) return p;
    final Object? salts = info['salts'];
    if (salts is List && salts.any(uids.contains)) return p;
  }
  return null;
}

T? _firstWhere<T>(Iterable<T> items, bool Function(T) test) {
  for (final T item in items) {
    if (test(item)) return item;
  }
  return null;
}

/// 本机 profile（当前 uid [uid]）能否改用备份的 uid：没有用户数据（[srsProfileHasUserData]：不只是笔记，自建牌组、
/// 改过的预设也算），且从未发布过批次。
///
/// 新代：这个 profile 在库里还没有集合（[SrsProfileUnboundException]）= 没有数据、也没发布过。
Future<bool> _canAdoptUid(SrsCore core, String? uid) async {
  if (uid == null || uid.isEmpty) return true;
  final Object? locations;
  try {
    if (await srsProfileHasUserData(core, uid)) return false;
    // 同步 v2：传到过任何位置就算发布过（别的设备可能已经拿到这个身份下的操作）。只读判断。
    locations = core.sync2(<String, Object?>{
      'op': 'status',
      'profile': uid,
    }).map['locations'];
  } on SrsProfileUnboundException {
    return true;
  }
  final bool published =
      locations is List &&
      locations.any(
        (Object? l) => l is Map && ((l['uploaded'] as int?) ?? 0) > 0,
      );
  return !published;
}

/// 本机 profile（当前 uid [currentUid]）能否改用另一个 uid：没有用户数据、也从未发布过批次（铁律 E）。
/// 复习备份页「从文件恢复」另一台设备的备份时用：新装的设备可以直接接上那个 profile。
Future<bool> srsCanAdoptProfileUid(SrsStorage db, String currentUid) =>
    _canAdoptUid(db.core, currentUid);

/// 本机 profile [profileId] 改用 [newUid]：先删掉旧 uid 下的全部 SRS 行（只可能是内置行 / 本机状态 /
/// 缓存，内置行的 ID 由 uid 派生，换 uid 后随新 uid 重新生成）。调用方先用 [srsCanAdoptProfileUid] 检查。
/// 不是改写 uid：旧 uid 的行没有要带过去的（新 uid 的内置行与同步身份按新 uid 重建），所以是整体删除，经 Rust
/// `profile_purge`（删本机一个 uid 的唯一实现：同步 v2 的操作 / 设备 / 身份、按 profile 记的 srs_meta 键、
/// 没人引用的 sync2_deps 一并删）。
///
/// 两个文件分别提交：先删 [srs] 里旧 uid 的行（一个 savepoint），再写主库 [db] 的 `profiles.uid`。中途失败时
/// 旧 uid 下只剩空（内置行随下次打开重建），重跑即收敛。
Future<void> srsAdoptProfileUid(
  FushiDatabase db,
  SrsCore srs, {
  required int profileId,
  required String oldUid,
  required String newUid,
}) async {
  await srsPurgeProfileRows(srs, oldUid);
  await db.adoptProfileUid(profileId, newUid);
}
