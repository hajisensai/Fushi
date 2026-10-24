/// 备份「合并导入」的 SRS 专用步骤（docs/specs/2026-10-14-fushi-srs-design.md 铁律 E）。
///
/// 通用合并路径按业务键逐行 upsert / 按名重映射 profile id，对 SRS 不成立：SRS 的行按
/// `profiles.uid` 归属、事件 ID 全局唯一且不可变。所以 srs_* 表在通用路径登记为跳过
/// （`mergeSkippedDeviceLocalTableNames`），由这里按 profile uid 归位后，经本机
/// [SrsDbStore.applyRemote] 合并——与多设备同步同一套合并函数（按 ID 取并集、修改记录走支配判定）。
///
/// 对备份里每个**有 SRS 数据**的 profile（只有内置行不算）：
/// 1. 本机有同 uid 的 profile → 直接合并进去。
/// 2. 否则本机有同名 profile，且它没有用户笔记、也从未发布过批次 → 该 profile 采用备份的 uid
///    （先删掉它旧 uid 下的 SRS 行：只可能是内置行 / 本机状态 / 缓存，内置行 ID 由 uid 派生，
///    会随新 uid 重新生成），再合并。发布过的不能改 uid：旧同步目录会成孤儿、已关联的设备断开
///    （第六轮审查第 15 条）。
/// 3. 否则为备份的 uid 新建本机 profile「<原名>（备份）」，再合并。
///
/// 不做任何 ID 重映射。合并进来的新事件重新进本机发件箱：备份来源设备可能从未同步过，
/// 不重发这些事件就只活在本机；已在云端的事件重复发布无害（按 ID 取并集）。
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';

/// 只读地读一份备份库里的 SRS 数据。
///
/// 备份库可以是单独打开的 [FushiDatabase]（[SrsBackupSource.database]），也可以是
/// ATTACH 在本机库连接上的附加库（[SrsBackupSource.attached]，合并导入引擎的形态）。
/// 两种都只发 SELECT。
class SrsBackupSource {
  SrsBackupSource.database(FushiDatabase db) : this._(db, '');

  /// [schema] 是 `ATTACH DATABASE ... AS <schema>` 的别名。
  SrsBackupSource.attached(FushiDatabase connection, String schema)
    : this._(connection, '$schema.');

  SrsBackupSource._(this._db, this._prefix);

  final FushiDatabase _db;
  final String _prefix;

  String _t(String table) => '$_prefix$table';

  Future<bool> _any(String table, String profileUid) async =>
      await _db
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
    final List<QueryRow> ids = await _db
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
    final List<QueryRow> rows = await _db
        .customSelect(
          'SELECT name, uid FROM ${_t('profiles')} '
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

  /// 该 profile 的全部事件（身份记录 → 修改记录 → 复习日志 → 不认识的事件），
  /// 解码方式与 [SrsDbStore.exportAll] 一致。
  Future<List<SrsEvent>> eventsOf(String profileUid) async {
    final List<Variable<Object>> v = <Variable<Object>>[
      Variable<String>(profileUid),
    ];
    Map<String, Object?> obj(String json) =>
        (jsonDecode(json) as Map).cast<String, Object?>();
    final List<SrsEvent> out = <SrsEvent>[];
    for (final QueryRow r
        in await _db
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
        in await _db
            .customSelect(
              'SELECT json FROM ${_t('srs_field_edits')} '
              'WHERE profile_uid = ? ORDER BY id',
              variables: v,
            )
            .get()) {
      out.add(SrsEditEvent(SrsFieldEdit.fromJson(obj(r.read<String>('json')))));
    }
    for (final QueryRow r
        in await _db
            .customSelect(
              'SELECT json FROM ${_t('srs_review_logs')} '
              'WHERE profile_uid = ? ORDER BY id',
              variables: v,
            )
            .get()) {
      out.add(SrsLogEvent(SrsReviewLog.fromJson(obj(r.read<String>('json')))));
    }
    for (final QueryRow r
        in await _db
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

/// 备份里一个有 SRS 数据的 profile。
class SrsBackupProfile {
  const SrsBackupProfile({required this.uid, required this.name});

  final String uid;
  final String name;
}

/// 备份 profile 落到本机的方式（铁律 E 的三种情况）。
enum SrsBackupMergeAction {
  /// 本机已有同 uid 的 profile。
  sameUid,

  /// 本机同名 profile（无用户笔记、从未发布）采用了备份的 uid。
  adoptedUid,

  /// 新建了「<原名>（备份）」profile。
  createdProfile,
}

/// 一个备份 profile 的合并结果。
class SrsBackupMergeResult {
  const SrsBackupMergeResult({
    required this.profileUid,
    required this.localProfileId,
    required this.action,
    required this.newEvents,
  });

  final String profileUid;
  final int localProfileId;
  final SrsBackupMergeAction action;

  /// 本次新落进本机（并重新进发件箱）的事件数；重复合并同一份备份为 0。
  final int newEvents;
}

/// 新建本机 profile（返回本地自增 id）。由调用方决定建法（通用合并路径是直接插 profiles 行）。
typedef SrsCreateProfile = Future<int> Function(String name);

/// 新建 profile 的名字：「<原名>（备份）」，撞名时「<原名>（备份 2）」……
String srsBackupProfileName(String original, Set<String> taken) {
  final String base = '$original（备份）';
  if (!taken.contains(base)) return base;
  for (int i = 2; ; i++) {
    final String candidate = '$original（备份 $i）';
    if (!taken.contains(candidate)) return candidate;
  }
}

/// 本机 SRS 中按 profile_uid 归属的全部表（数据 + 本机状态 + 缓存）。
const List<String> _kSrsProfileTables = <String>[
  'srs_entities',
  'srs_field_edits',
  'srs_review_logs',
  'srs_unknown_events',
  'srs_event_local',
  'srs_local_state',
  'srs_notes_cache',
  'srs_cards_cache',
  // v129：有效复习投影（可重建缓存）。
  'srs_stat_reviews',
  // v121：本机已冻结批次留存。
  'srs_sent_batches',
];

/// 把 [source] 里每个有 SRS 数据的 profile 合并进本机库 [local]（铁律 E，见库注释）。
///
/// 幂等：同一份备份合并两次，第二次全部走「同 uid」且不新增事件。
/// 调用方若在事务里调用，本函数的写入随之一起提交 / 回滚（drift 嵌套事务 = savepoint）。
Future<List<SrsBackupMergeResult>> mergeSrsFromBackup({
  required SrsBackupSource source,
  required FushiDatabase local,
  required String deviceId,
  required SrsCreateProfile createProfile,
}) async {
  final List<SrsBackupMergeResult> results = <SrsBackupMergeResult>[];
  for (final SrsBackupProfile bp in await source.profilesWithSrsData()) {
    final List<_LocalProfile> profiles = await _localProfiles(local);
    final _LocalProfile? sameUid = _firstWhere(
      profiles,
      (_LocalProfile p) => p.uid == bp.uid,
    );
    final int localId;
    final SrsBackupMergeAction action;
    if (sameUid != null) {
      localId = sameUid.id;
      action = SrsBackupMergeAction.sameUid;
    } else {
      final _LocalProfile? sameName = _firstWhere(
        profiles,
        (_LocalProfile p) => p.name == bp.name,
      );
      if (sameName != null &&
          await _canAdoptUid(local, sameName.uid, deviceId)) {
        final String? oldUid = sameName.uid;
        if (oldUid != null && oldUid.isNotEmpty) {
          for (final String table in _kSrsProfileTables) {
            await local.customStatement(
              'DELETE FROM main.$table WHERE profile_uid = ?',
              <Object>[oldUid],
            );
          }
        }
        await local.adoptProfileUid(sameName.id, bp.uid);
        localId = sameName.id;
        action = SrsBackupMergeAction.adoptedUid;
      } else {
        final String name = srsBackupProfileName(bp.name, <String>{
          for (final _LocalProfile p in profiles) p.name,
        });
        localId = await createProfile(name);
        await local.adoptProfileUid(localId, bp.uid);
        action = SrsBackupMergeAction.createdProfile;
      }
    }
    final int added = await _mergeEvents(
      local: local,
      profileUid: bp.uid,
      deviceId: deviceId,
      events: await source.eventsOf(bp.uid),
    );
    results.add(
      SrsBackupMergeResult(
        profileUid: bp.uid,
        localProfileId: localId,
        action: action,
        newEvents: added,
      ),
    );
  }
  return results;
}

class _LocalProfile {
  const _LocalProfile(this.id, this.name, this.uid);

  final int id;
  final String name;
  final String? uid;
}

T? _firstWhere<T>(Iterable<T> items, bool Function(T) test) {
  for (final T item in items) {
    if (test(item)) return item;
  }
  return null;
}

Future<List<_LocalProfile>> _localProfiles(
  FushiDatabase db,
) async => <_LocalProfile>[
  for (final QueryRow r
      in await db
          .customSelect('SELECT id, name, uid FROM main.profiles ORDER BY id')
          .get())
    _LocalProfile(
      r.read<int>('id'),
      r.read<String>('name'),
      r.read<String?>('uid'),
    ),
];

/// 本机 profile（当前 uid [uid]）能否改用备份的 uid：没有用户笔记，且从未发布过批次。
Future<bool> _canAdoptUid(
  FushiDatabase db,
  String? uid,
  String deviceId,
) async {
  if (uid == null || uid.isEmpty) return true;
  final bool hasNotes =
      await db
          .customSelect(
            'SELECT 1 FROM main.srs_entities WHERE profile_uid = ? AND kind = ? '
            'LIMIT 1',
            variables: <Variable<Object>>[
              Variable<String>(uid),
              Variable<String>(SrsEntityKind.note.wire),
            ],
          )
          .getSingleOrNull() !=
      null;
  if (hasNotes) return false;
  // 没有本机同步状态 = 从没发布过（发布进度只记在 srs_local_state）。有状态时才打开副本读
  // everPublished（发布元信息的编码归 SrsDbStore 所有，这里不重复解析）。
  final bool hasLocalState =
      await db
          .customSelect(
            'SELECT 1 FROM main.srs_local_state WHERE profile_uid = ?',
            variables: <Variable<Object>>[Variable<String>(uid)],
          )
          .getSingleOrNull() !=
      null;
  if (!hasLocalState) return true;
  final SrsDbStore store = await SrsDbStore.open(
    db: db,
    profileUid: uid,
    deviceId: deviceId,
  );
  return !store.everPublished && !await store.hasUserNotes();
}

/// 本机 profile（当前 uid [currentUid]）能否改用另一个 uid：没有用户笔记、也从未发布过批次（铁律 E）。
/// 复习备份页「从文件恢复」另一台设备的备份时用：新装的设备可以直接接上那个 profile。
Future<bool> srsCanAdoptProfileUid(
  FushiDatabase db,
  String currentUid,
  String deviceId,
) => _canAdoptUid(db, currentUid, deviceId);

/// 本机 profile [profileId] 改用 [newUid]：先删掉旧 uid 下的全部 SRS 行（只可能是内置行 / 本机状态 /
/// 缓存，内置行的 ID 由 uid 派生，换 uid 后随新 uid 重新生成）。调用方先用 [srsCanAdoptProfileUid] 检查。
Future<void> srsAdoptProfileUid(
  FushiDatabase db, {
  required int profileId,
  required String oldUid,
  required String newUid,
}) async {
  await db.transaction(() async {
    for (final String table in _kSrsProfileTables) {
      await db.customStatement(
        'DELETE FROM main.$table WHERE profile_uid = ?',
        <Object>[oldUid],
      );
    }
    await db.adoptProfileUid(profileId, newUid);
  });
}

/// 本机 SRS 四张事件表里已存在的事件 ID。
Future<Set<String>> _existingEventIds(
  FushiDatabase db,
  List<String> ids,
) async {
  final Set<String> out = <String>{};
  for (int i = 0; i < ids.length; i += 400) {
    final List<String> chunk = ids.sublist(
      i,
      i + 400 > ids.length ? ids.length : i + 400,
    );
    final String marks = List<String>.filled(chunk.length, '?').join(', ');
    final List<Variable<Object>> vars = <Variable<Object>>[
      for (final String id in chunk) Variable<String>(id),
    ];
    for (final String table in const <String>[
      'srs_entities',
      'srs_field_edits',
      'srs_review_logs',
      'srs_unknown_events',
    ]) {
      for (final QueryRow r
          in await db
              .customSelect(
                'SELECT id FROM main.$table WHERE id IN ($marks)',
                variables: vars,
              )
              .get()) {
        out.add(r.read<String>('id'));
      }
    }
  }
  return out;
}

/// 经本机副本合并一组事件，返回新落下的事件数（这些事件重新进发件箱）。
Future<int> _mergeEvents({
  required FushiDatabase local,
  required String profileUid,
  required String deviceId,
  required List<SrsEvent> events,
}) async {
  final SrsDbStore store = await SrsDbStore.open(
    db: local,
    profileUid: profileUid,
    deviceId: deviceId,
  );
  if (events.isEmpty) return 0;
  final List<String> ids = <String>[for (final SrsEvent e in events) e.id];
  final Set<String> before = await _existingEventIds(local, ids);
  await store.applyRemote(events);
  final List<String> fresh = <String>[
    for (final String id in ids)
      if (!before.contains(id)) id,
  ];
  if (fresh.isEmpty) return 0;
  // 被本机更晚的修改支配而丢掉的记录不在库里，不进发件箱（否则发件箱留下永远发不出的行）。
  final Set<String> landed = await _existingEventIds(local, fresh);
  final List<String> requeue = <String>[
    for (final String id in fresh)
      if (landed.contains(id)) id,
  ];
  if (requeue.isNotEmpty) await store.requeue(requeue);
  return requeue.length;
}
