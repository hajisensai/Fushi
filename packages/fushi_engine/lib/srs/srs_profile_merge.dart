/// 把本机一个**有用户笔记**的 profile 并入同步目录里已有的另一个 profile（铁律 E 的扩展）。
///
/// 背景：每台设备第一次打开复习时随机生成 profileUid，三台设备各自生成、都叫「默认」，同步目录里于是有多个
/// 同名 profile、复习数据不互通。本机 profile 没有用户笔记时直接采用对方 uid（[srsAdoptProfileUid]）；有用户
/// 笔记时用这里的 [srsMergeProfileUid]：把旧 uid 下的全部用户数据**并入**目标 uid，不覆盖、不丢任何一边。
///
/// ## 为什么要重映射 ID（与铁律 E「不做任何 ID 重映射」的关系）
///
/// 铁律 E 只允许「没有用户笔记」时改 uid，所以从不需要重映射。并入有笔记的 profile 时不重映射是错的：
/// 1. **按 uid 派生、代码每次现算的 ID**（内置默认牌组、内置 Lapis / Fushi 卡片笔记类型及其字段 / 模板，
///    srs_builtin.dart）原样搬过去会指向目标 profile 里不存在的实体：笔记字段键 `f/<旧字段>` 在新 uid 的
///    内置定义里找不到、卡片模板对不上；
/// 2. **卡片 ID 由「笔记 + 模板 + 填空序号」派生**（铁律 D），模板 ID 一换，缓存刷新按新模板算出另一张卡，
///    旧卡的复习历史就挂在一张再也不会生成的卡上；
/// 3. srs.db 的 `id` 是**全局主键**（native/fushi_fsrs/src/store/schema.rs 的 srs_entities / srs_field_edits /
///    srs_review_logs；sync2_edit_ops / sync2_log_meta 同理），投影同 ID 的身份记录时只比内容、不看归属
///    （store/sync2/mod.rs `project_entity`）——同一台设备上新旧两个 profile 共用同一个 ID 会互相吞掉。
///    profile 之间 ID 不相交，正是靠「派生里带 uid / 写入者是集合内的设备」保证的。
///
/// 所以这里按「**假如这份数据一直就在新 uid 下创建**」重算每个按 uid 派生的 ID：能从不可变的来源身份还原
/// 出派生输入（笔记 guid、笔记类型 ankiNum、字段 / 模板 ankiNum 或名字、牌组全名、卡片的笔记 + 模板 + 序号）且用
/// 旧 uid 验算吻合的，用同一条规则换成新 uid 算；还原不出来的用确定性兜底 `uuidV5(NS, profile-merge/<newUid>/<旧 ID>)`。
/// 复习日志不看旧 ID：Anki 导入的原日志按新卡片套导入规则，其余按「新卡片 + HLC + 种类」派生（第 7 步，BUG-4217）。
/// 修改记录的写入者按 `merged-uuidV5(NS, profile-merge/<newUid>/writer/<最初的写入者>)~<最初的写入者>` 一一改名
/// （dot / 因果上下文 / HLC 里的写入者一起改；[_mergedWriterNames]），记录之间的支配关系原样保留，修改记录 ID
/// （由 dot 派生）也就与旧 profile 不相交。
///
/// 全部映射只依赖 (旧 ID 或日志内容, newUid)：重跑得到同一批 ID（幂等）；两台设备各自把同一个旧 profile 并入同一个
/// 新 uid，也得到同一批 ID，合并后是同一行而不是两份。复习日志与写入者还与合并路径无关（A→B→C 与 A→C 相同）。
///
/// ## 怎么落进同步
///
/// 改写后的事件经目标 uid 的 [SrsDbStore.applyRemote] 并入：Rust `apply` 的 stamped 路径把它们追加成**本机
/// 设备在目标集合里的新操作**（保留修改记录的 dot / 上下文 / HLC，与备份合并同一机制），下一轮同步打包成段
/// 上传，别的设备照常收；本机也照常收到目标 profile 已有的数据。已经在目标集合里的事件不重复并（否则每重跑
/// 一次就多一份操作）。
///
/// ## 原子性
///
/// 两个文件不能一起提交，顺序保证任何时刻中断都不丢数据、重跑即收敛：
/// 1. srs.db 记一个进行中标记（[srsPendingProfileMerges]），调用方启动时据此重跑；
/// 2. 并入（旧 uid 的行一行不动）；
/// 3. 主库 `profiles.uid` 改成新 uid——之后本机看到的就是合并后的 profile；
/// 4. 再并一遍（收下 2 与 3 之间旧 store 可能写进的东西），然后**在同一个 srs.db 事务里**核对旧 uid 的每条事件
///    都已在新 uid 下、再删掉旧 uid 的全部行与标记。核对不过（旧 profile 还在被写）就整轮重来，不删。
///
/// 删旧行的理由：并入后旧 uid 的数据在新 uid 下有完整副本，本机再也没有 profile 行指向旧 uid，留着只是
/// 不可见的双份存储（含整条旧操作日志），还会让 hasUserNotes / 备份枚举之类按 uid 扫表的地方多扫一份。
/// 同步目录里旧 uid 下本设备的目录不归这里删（调用方在新 uid 首次同步成功后用 `srsRemoveOwnProfileFolder`）。
///
/// 不去重：两边各自有同一个词的笔记时，并入后是两条（ID 不同）；由 srs_duplicate_notes.dart 的重复笔记建议
/// 让用户合。只有「同一张 Anki 笔记（同 guid）在两边各导入过一次」会按铁律 C 自然落成同一条。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:fushi_core/fushi_core.dart'
    show FushiDatabase, SrsDatabase, srsIdType;
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_backup_merge.dart' show SrsBackupSource;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';

/// srs.db `srs_meta` 里「这个旧 uid 的并入进行中」标记的键前缀（值 = `{"profileId":..,"newUid":..}`）。
const String kSrsProfileMergeMarkerPrefix = 'profile_merge/';

/// 合并后的修改记录写入者前缀（旧写入者确定性改名，见库注释）。
const String kSrsMergedWriterPrefix = 'merged-';

/// 合成的标签行写入者前缀（native/fushi_fsrs/src/registers.rs `SYNTHETIC_WRITER_PREFIX`）：它带着笔记 ID，
/// 按 ID 映射改写，不改名。
const String _kSyntheticWriterPrefix = 'sync2:';

/// 合并后写入者名字里「哈希」与「最初的写入者」之间的分隔符：`merged-<UUIDv5>~<最初的写入者>`（[_mergedWriterNames]）。
const String _kMergedWriterOriginSeparator = '~';

/// UUID 文本长度。
const int _kUuidLength = 36;

/// 写入者 [w] 最初的名字：`merged-<UUIDv5>~<最初>` 剥出 `<最初>`；别的（设备写入者、旧格式的 `merged-<UUIDv5>`）
/// 就是它自己。
String _mergedWriterOrigin(String w) {
  const int at = kSrsMergedWriterPrefix.length + _kUuidLength;
  if (w.length <= at + 1 ||
      !w.startsWith(kSrsMergedWriterPrefix) ||
      w[at] != _kMergedWriterOriginSeparator ||
      !_uuidToken.hasMatch(w.substring(kSrsMergedWriterPrefix.length, at))) {
    return w;
  }
  return w.substring(at + 1);
}

/// 最初的写入者 [origins] 并入 [newUid] 后的名字：`merged-UUIDv5(NS, profile-merge/<newUid>/writer/<最初>)~<最初>`（一次
/// FFI）。哈希输入与 2026-11 之前的 `merged-<UUIDv5>` 相同，后缀把最初的写入者带下去，下一次合并据此剥回最初的写入者
/// 再算，名字与合并路径无关。
List<String> _mergedWriterNames(String newUid, List<String> origins) {
  final List<String> h = uuidV5Batch(<(String, String)>[
    for (final String o in origins)
      (srsNamespace, 'profile-merge/$newUid/writer/$o'),
  ]);
  return <String>[
    for (int i = 0; i < origins.length; i++)
      '$kSrsMergedWriterPrefix${h[i]}$_kMergedWriterOriginSeparator${origins[i]}',
  ];
}

/// 一次并入的结果。
class SrsProfileMergeResult {
  const SrsProfileMergeResult({
    required this.profileId,
    required this.oldUid,
    required this.newUid,
    required this.appliedEvents,
    required this.exactIds,
    required this.fallbackIds,
    required this.aliasedIds,
  });

  final int profileId;
  final String oldUid;
  final String newUid;

  /// 这次真正并进新 uid 的事件数（已在新 uid 下的不重复并；重跑为 0）。
  final int appliedEvents;

  /// 按同一派生规则换成新 uid 算出的 ID 数（含 profile 自己与内置实体）。
  final int exactIds;

  /// 还原不出派生输入、走确定性兜底的 ID 数。
  final int fallbackIds;

  /// 复习日志里沿用目标已有 ID 的条数：目标里已有同一次复习（同卡片 / 种类 / 评分 / 发生时刻 / HLC），只是 ID 与
  /// 规则 / 兜底算出的不同（例如目标里是原生日志的原 UUIDv7）。
  final int aliasedIds;
}

/// 还没做完的并入（进程在中途退出）。调用方启动时对每一项用同样的参数再调一次 [srsMergeProfileUid]。
class SrsPendingProfileMerge {
  const SrsPendingProfileMerge({
    required this.profileId,
    required this.oldUid,
    required this.newUid,
  });

  final int profileId;
  final String oldUid;
  final String newUid;
}

/// 测试注入点（[srsMergeProfileUid] 的 `debugFault`）。
enum SrsProfileMergeStage {
  /// 第一遍并入之后、改主库 uid 之前。
  afterFirstMerge,

  /// 主库 uid 已改、删旧行之前。
  afterUidSwitch,

  /// 删旧行的事务里，核对通过之后、删除之前（抛出 = 事务回滚）。
  beforeDelete,
}

/// srs.db 里记着、还没做完的并入。
Future<List<SrsPendingProfileMerge>> srsPendingProfileMerges(
  SrsDatabase srs,
) async {
  final List<SrsPendingProfileMerge> out = <SrsPendingProfileMerge>[];
  for (final QueryRow r
      in await srs
          .customSelect(
            'SELECT key, value FROM srs_meta WHERE key LIKE ?',
            variables: <Variable<Object>>[
              Variable<String>('$kSrsProfileMergeMarkerPrefix%'),
            ],
          )
          .get()) {
    final Object? v = jsonDecode(r.read<String>('value'));
    if (v is! Map) continue;
    final Object? id = v['profileId'];
    final Object? neu = v['newUid'];
    if (id is! int || neu is! String) continue;
    out.add(
      SrsPendingProfileMerge(
        profileId: id,
        oldUid: r
            .read<String>('key')
            .substring(kSrsProfileMergeMarkerPrefix.length),
        newUid: neu,
      ),
    );
  }
  return out;
}

/// 本机 profile [profileId]（当前 uid [oldUid]，有用户笔记）改用 [newUid]，并把旧 uid 下的全部用户数据并入
/// （规则、ID 映射与原子性见库注释）。
///
/// 调用前：旧 uid 的 store 停止写入（调用方不要再用它）；调用后：调用方按新 uid 重开 store、
/// `afterRestore(freshIncarnation: true)`、再同步。[mediaRoot] 是全部 profile 的 SRS 媒体根
/// （`<support>/srs_media`，见 app 的 `SrsMediaStore.mediaRootFor`）：给了就把 `<旧 uid>/` 下的媒体与共享样式
/// 文件拷进 `<新 uid>/`（内容寻址，同名即同内容，不覆盖），删旧行之后删旧目录；不给则不动媒体。
///
/// 中途失败可以用同样的参数重跑（也可以在 profile 已经是 [newUid] 时重跑：只做收尾）。
///
/// [pullTarget]：第一遍并入之前，先把同步位置上 [newUid] 已有的数据收进目标 store（调用方给有界的只拉不发，
/// sync2/srs_sync2_pull_first.dart）。目标里已有同一批修改记录时并入沿用目标的写入者（[_Writers.alias]），不再
/// 改名成 `merged-…` 造出第二份（BUG-4011）。拉取失败 / 到点没拉完照常并入（可能仍有几份改了名，之后靠收敛合并）。
/// 只在旧 uid 还是本机 profile 时拉（profile 已切到 [newUid] 的重跑只做收尾）；拉到一半被杀：已收的批次都已提交，
/// 并入标记还在，下次启动 [srsPendingProfileMerges] 照同样参数重跑，再拉一次（只拉缺的）再并入。
Future<SrsProfileMergeResult> srsMergeProfileUid(
  FushiDatabase db,
  SrsDatabase srs, {
  required SrsCore core,
  required int profileId,
  required String oldUid,
  required String newUid,
  required String deviceId,
  Directory? mediaRoot,
  Future<void> Function(SrsProfileMergeStage stage)? debugFault,
  Future<void> Function(SrsDbStore target)? pullTarget,
  int maxConvergeRounds = 3,
}) async {
  if (oldUid.isEmpty || newUid.isEmpty || oldUid == newUid) {
    throw ArgumentError('cannot merge profile uid $oldUid into $newUid');
  }
  final String current = await db.profileUidOf(profileId);
  if (current != oldUid && current != newUid) {
    throw StateError(
      'profile $profileId has uid $current, neither $oldUid nor $newUid',
    );
  }
  final QueryRow? taken = await db
      .customSelect(
        'SELECT id FROM profiles WHERE uid = ? AND id != ?',
        variables: <Variable<Object>>[
          Variable<String>(newUid),
          Variable<int>(profileId),
        ],
      )
      .getSingleOrNull();
  if (taken != null) {
    // profiles.uid 唯一：目标 uid 已是本机另一个 profile，用户切过去即可，不在这里合。
    throw StateError(
      'uid $newUid already belongs to local profile '
      '${taken.read<int>('id')}',
    );
  }

  await srs.customStatement(
    'INSERT OR REPLACE INTO srs_meta (key, value) VALUES (?, ?)',
    <Object>[
      '$kSrsProfileMergeMarkerPrefix$oldUid',
      jsonEncode(<String, Object?>{'profileId': profileId, 'newUid': newUid}),
    ],
  );
  if (mediaRoot != null) await _copyMedia(mediaRoot, oldUid, newUid);

  final SrsDbStore target = await SrsDbStore.open(
    db: srs,
    core: core,
    profileUid: newUid,
    deviceId: deviceId,
  );
  int applied = 0;
  _MergePlan? plan;
  if (current == oldUid) {
    if (pullTarget != null) await pullTarget(target);
    plan = await _plan(
      srs,
      oldUid: oldUid,
      newUid: newUid,
      targetDots: await _targetDots(target),
    );
    applied += await _applyMissing(target, plan);
    await debugFault?.call(SrsProfileMergeStage.afterFirstMerge);
    await db.adoptProfileUid(profileId, newUid);
    await debugFault?.call(SrsProfileMergeStage.afterUidSwitch);
  }

  for (int round = 0; ; round++) {
    plan = await _plan(
      srs,
      oldUid: oldUid,
      newUid: newUid,
      targetDots: await _targetDots(target),
    );
    applied += await _applyMissing(target, plan);
    if (mediaRoot != null) await _copyMedia(mediaRoot, oldUid, newUid);
    final _MergePlan settled = plan;
    final bool done = await srs.transaction(() async {
      // 核对：旧 uid 此刻的每条事件都在这一轮的计划里（之后没有新写入），且计划里的每条都已在新 uid 下。
      final Set<String> nowOld = await _eventIds(srs, oldUid);
      if (!settled.oldToNew.keys.toSet().containsAll(nowOld)) return false;
      final Set<String> want = <String>{
        for (final String id in nowOld) settled.oldToNew[id]!,
      };
      final Set<String> have = await _presentIn(srs, newUid, want);
      if (have.length != want.length) {
        throw StateError(
          'profile merge $oldUid -> $newUid: ${want.length - have.length} '
          'events did not land under the new uid; old rows kept',
        );
      }
      await debugFault?.call(SrsProfileMergeStage.beforeDelete);
      await _deleteProfile(srs, oldUid);
      return true;
    });
    if (done) break;
    if (round + 1 >= maxConvergeRounds) {
      throw StateError(
        'profile $oldUid kept changing during the merge; old rows kept, '
        'retry after its store stops writing',
      );
    }
  }
  if (mediaRoot != null) {
    final Directory old = Directory(_join(mediaRoot.path, oldUid));
    if (old.existsSync()) await old.delete(recursive: true);
  }
  return SrsProfileMergeResult(
    profileId: profileId,
    oldUid: oldUid,
    newUid: newUid,
    appliedEvents: applied,
    exactIds: plan.exact,
    fallbackIds: plan.fallback,
    aliasedIds: plan.aliased,
  );
}

// ---------------------------------------------------------------- 计划：ID 映射 + 改写后的事件

class _MergePlan {
  _MergePlan({
    required this.structure,
    required this.tail,
    required this.serverTimes,
    required this.oldToNew,
    required this.exact,
    required this.fallback,
    required this.aliased,
  });

  /// 身份记录与修改记录（先并：缓存刷新据此生成卡片，日志并入时才查得到卡片所属笔记）。
  final List<SrsEvent> structure;

  /// 复习日志与不认识的事件。
  final List<SrsEvent> tail;

  /// 新事件 ID → S(e)（沿用旧事件的服务器时间，排序键不变）。
  final Map<String, int> serverTimes;

  /// 旧事件 ID → 新事件 ID（核对用）。
  final Map<String, String> oldToNew;
  final int exact;
  final int fallback;
  final int aliased;
}

final RegExp _uuidToken = RegExp(
  r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
);

/// 旧 uid 下的事件 → ID 映射 → 改写成新 uid 下的事件。
Future<_MergePlan> _plan(
  SrsDatabase db, {
  required String oldUid,
  required String newUid,
  required Map<String, Map<int, String>> targetDots,
}) async {
  final List<SrsEvent> events = await SrsBackupSource.split(
    profiles: db,
    srs: db,
  ).eventsOf(oldUid);
  final _IdMap ids = _IdMap(oldUid, newUid);

  final List<SrsEntityRecord> entities = <SrsEntityRecord>[];
  final List<SrsFieldEdit> edits = <SrsFieldEdit>[];
  final List<SrsReviewLog> logs = <SrsReviewLog>[];
  final List<SrsUnknownEvent> unknown = <SrsUnknownEvent>[];
  for (final SrsEvent e in events) {
    switch (e) {
      case SrsEntityEvent(:final SrsEntityRecord record):
        entities.add(record);
      case SrsEditEvent(:final SrsFieldEdit edit):
        edits.add(edit);
      case SrsLogEvent(:final SrsReviewLog log):
        logs.add(log);
      case SrsUnknownEvent():
        unknown.add(e);
    }
  }
  final _Registers regs = _Registers(edits);

  // 1. 内置实体（代码按 uid 现算，必须落在新 uid 的同一批 ID 上）。
  ids.exactly(
    SrsIds.builtinDefaultDeck(oldUid),
    SrsIds.builtinDefaultDeck(newUid),
  );
  for (final SrsBuiltinNoteTypeSpec spec in kSrsBuiltinNoteTypes) {
    final SrsBuiltinNoteType o = srsBuiltinNoteType(oldUid, spec);
    final SrsBuiltinNoteType n = srsBuiltinNoteType(newUid, spec);
    ids.exactly(
      srsBuiltinNoteTypeId(oldUid, spec.key),
      srsBuiltinNoteTypeId(newUid, spec.key),
    );
    for (int i = 0; i < o.fields.length; i++) {
      ids.exactly(o.fields[i].id, n.fields[i].id);
    }
    for (int i = 0; i < o.templates.length; i++) {
      ids.exactly(o.templates[i].id, n.templates[i].id);
    }
  }

  // 2. 笔记类型：noteTypeId = UUIDv5(NS, uid/notetype/ankiNum)。
  for (final SrsEntityRecord r in entities) {
    if (r.kind != SrsEntityKind.noteType || ids.has(r.id)) continue;
    final Object? num = r.payload['ankiNum'];
    if (num is int && SrsIds.noteType(oldUid, num) == r.id) {
      ids.exactly(r.id, SrsIds.noteType(newUid, num));
    }
  }
  ids.fallbackAll(<String>[
    for (final SrsEntityRecord r in entities)
      if (r.kind == SrsEntityKind.noteType) r.id,
    for (final SrsFieldEdit e in edits)
      if (e.entityKind == SrsEntityKind.noteType) e.entityId,
  ]);

  // 3. 用户笔记类型的字段 / 模板：UUIDv5(noteTypeId, field/ankiNum) 或按名字回退的 field-name/<名字>。
  for (final SrsFieldEdit e in edits) {
    if (e.entityKind != SrsEntityKind.noteType) continue;
    final String nt = e.entityId;
    final String newNt = ids[nt]!;
    final bool isField = e.fieldKey.startsWith('fieldDef/');
    final bool isTemplate = e.fieldKey.startsWith('tmplDef/');
    if (!isField && !isTemplate) continue;
    final String id = e.fieldKey.substring(e.fieldKey.indexOf('/') + 1);
    if (ids.has(id)) continue;
    final Object? v = e.value;
    if (v is! Map) continue;
    final Object? num = v['ankiNum'];
    final Object? name = v['name'];
    if (num is int &&
        (isField ? SrsIds.field(nt, num) : SrsIds.template(nt, num)) == id) {
      ids.exactly(
        id,
        isField ? SrsIds.field(newNt, num) : SrsIds.template(newNt, num),
      );
    } else if (name is String &&
        (isField
                ? SrsIds.fieldByName(nt, name)
                : SrsIds.templateByName(nt, name)) ==
            id) {
      ids.exactly(
        id,
        isField
            ? SrsIds.fieldByName(newNt, name)
            : SrsIds.templateByName(newNt, name),
      );
    }
  }
  ids.fallbackAll(<String>[
    for (final SrsFieldEdit e in edits)
      if (e.entityKind == SrsEntityKind.noteType)
        for (final String prefix in const <String>[
          'fieldDef/',
          'tmplDef/',
          'fieldDesc/',
        ])
          if (e.fieldKey.startsWith(prefix))
            e.fieldKey.substring(prefix.length),
  ]);

  // 4. 牌组：UUIDv5(NS, uid/deck/<全名>)（撞名时 deck-alt/<n>/<全名>）。全名按此刻的名字与父牌组还原。
  final Set<String> deckIds = <String>{
    for (final SrsEntityRecord r in entities)
      if (r.kind == SrsEntityKind.deck) r.id,
  };
  for (final String d in deckIds) {
    if (ids.has(d)) continue;
    final String? path = regs.deckPath(d);
    if (path == null) continue;
    if (SrsIds.deck(oldUid, path) == d) {
      ids.exactly(d, SrsIds.deck(newUid, path));
      continue;
    }
    for (int n = 1; n <= 8; n++) {
      if (SrsIds.deckAlternate(oldUid, path, n) == d) {
        ids.exactly(d, SrsIds.deckAlternate(newUid, path, n));
        break;
      }
    }
  }
  ids.fallbackAll(<String>[
    ...deckIds,
    for (final SrsFieldEdit e in edits)
      if (e.entityKind == SrsEntityKind.deck) e.entityId,
    for (final SrsFieldEdit e in edits)
      if ((e.fieldKey == SrsFieldKeys.cardDeck &&
              (e.entityKind == SrsEntityKind.card ||
                  e.entityKind == SrsEntityKind.note)) ||
          (e.entityKind == SrsEntityKind.deck &&
              e.fieldKey == SrsFieldKeys.deckParent))
        if (e.value case final String deck) deck,
  ]);

  // 5. 笔记：UUIDv5(NS, uid/note/guid)。
  final List<SrsEntityRecord> notes = <SrsEntityRecord>[
    for (final SrsEntityRecord r in entities)
      if (r.kind == SrsEntityKind.note && !ids.has(r.id))
        if (r.payload['guid'] case String _) r,
  ];
  final List<String> guids = <String>[
    for (final SrsEntityRecord r in notes) r.payload['guid']! as String,
  ];
  final List<String> oldNotes = SrsIds.notes(oldUid, guids);
  final List<String> newNotes = SrsIds.notes(newUid, guids);
  for (int i = 0; i < notes.length; i++) {
    if (oldNotes[i] == notes[i].id) ids.exactly(notes[i].id, newNotes[i]);
  }
  ids.fallbackAll(<String>[
    for (final SrsEntityRecord r in entities) r.id,
    for (final SrsFieldEdit e in edits)
      if (e.entityKind == SrsEntityKind.note) e.entityId,
  ]);

  // 6. 卡片：UUIDv5(noteId, templateId/clozeOrd)，用映射后的笔记与模板重算（缓存刷新就是这么生成卡的）。
  final List<(String, String, String, int)> cards =
      <(String, String, String, int)>[
        for (final QueryRow r
            in await db
                .customSelect(
                  'SELECT id, note_id, template_id, cloze_ord FROM '
                  'srs_cards_cache WHERE profile_uid = ? ORDER BY id',
                  variables: <Variable<Object>>[
                    Variable<String>(oldUid, srsIdType),
                  ],
                )
                .get())
          (
            r.read<String>('id'),
            r.read<String>('note_id'),
            r.read<String>('template_id'),
            r.read<int>('cloze_ord'),
          ),
      ];
  ids.fallbackAll(<String>[
    for (final (String _, String note, String tpl, int _) in cards) ...<String>[
      note,
      tpl,
    ],
  ]);
  final List<String> oldCards = SrsIds.cards(<(String, String, int)>[
    for (final (String _, String note, String tpl, int ord) in cards)
      (note, tpl, ord),
  ]);
  final List<String> newCards = SrsIds.cards(<(String, String, int)>[
    for (final (String _, String note, String tpl, int ord) in cards)
      (ids[note]!, ids[tpl]!, ord),
  ]);
  for (int i = 0; i < cards.length; i++) {
    if (oldCards[i] == cards[i].$1 && !ids.has(cards[i].$1)) {
      ids.exactly(cards[i].$1, newCards[i]);
    }
  }
  ids.fallbackAll(<String>[
    for (final (String id, String _, String _, int _) in cards) id,
    for (final SrsFieldEdit e in edits) ...<String>[
      if (e.entityKind == SrsEntityKind.card) e.entityId,
      if (e.fieldKey.startsWith(SrsFieldKeys.cardHistoryFromPrefix))
        e.fieldKey.substring(SrsFieldKeys.cardHistoryFromPrefix.length),
    ],
    for (final SrsReviewLog l in logs) l.cardId,
  ]);

  // 7. 复习日志（BUG-4217）。一条复习的新 ID 只能取决于「这是哪一次复习」（不可变内容），不能取决于它在旧 profile 里
  //    碰巧叫什么，也不能取决于合并走了哪条路径：同一次复习可能经两条路径进到目标集合（两台设备各自导入过同一份 Anki、
  //    旧 profile 本身是更早一次并入的结果、A→B→C 链式合并与另一台设备 A→C 直接合并、目标里早就有原生日志的原 ID），
  //    只要两条路径算出的 ID 不同，同步按 ID 认身份，就会把一次复习落成两条，间隔 0 天的同评分重复样本直接把 FSRS
  //    优化的 log loss 从 0.6 推到 1.6。所以：
  //    a. **自身身份就是那次 Anki 导入**的日志按导入规则重算，不再验证旧 ID：revlog（origin = anki、HLC =
  //       [srsImportedRevlogHlc]、没有 replayOf）→ UUIDv5(新卡片, anki-revlog/<id>)；锚点（importAnchor、origin = anki、
  //       HLC = [srsImportAnchorHlc]、没有 replayOf）→ UUIDv5(新卡片, anki-anchor/<时刻>)。恢复备份写出的重放副本
  //       （packages/fushi_srs/lib/src/restore_plan.dart `_replayOf`）照抄了 ankiRevlogId / 种类 / 发生时刻，只换了 ID 与
  //       HLC、extra 记了 replayOf——它不是那次导入；套上规则就和已被 undo 撤销的原日志撞成同一个 ID，并入只留一份、
  //       undo 指过来，这次复习整条消失。
  //    b. 其余日志（原生日志、undo、重放副本）→ UUIDv5(新卡片, profile-merge-log/<HLC>/<种类>)。日志的 HLC 在合并中原样
  //       保留（日志不改写入者），一个 HLC 只属于一个事件，所以与路径无关：链式与直接合并得到同一个 ID。
  //    c. 旧 profile 里没有的日志 ID（undo 的目标不在本地）与不认识的事件仍按旧 ID 兜底（没有内容可派生）。
  //    d. 目标里已有同一条复习（映射后的卡片 + 种类 + 评分 + 发生时刻 + HLC 都相同）但 ID 与 a / b 算出的不同 → 沿用目标
  //       里的 ID（与修改记录的 [_Writers.alias] 同一思路，BUG-4011）；目标里同一身份有多条时取 ID 最小的那条。
  //    a / b 之后两条旧日志映射到同一个新 ID 时只认「本来就是同一次复习」，见第 9 步。
  bool replayed(SrsReviewLog l) => l.extra.containsKey(srsReplayOfLogExtraKey);
  final List<SrsReviewLog> anki = <SrsReviewLog>[
    for (final SrsReviewLog l in logs)
      if (l.ankiRevlogId case final int revlog
          when l.origin == SrsLogOrigin.anki &&
              l.hlc == srsImportedRevlogHlc(revlog) &&
              !replayed(l))
        l,
  ];
  final List<String> newRevlogs = SrsIds.importedRevlogsOf(<(String, int)>[
    for (final SrsReviewLog l in anki) (ids[l.cardId]!, l.ankiRevlogId!),
  ]);
  for (int i = 0; i < anki.length; i++) {
    ids.exactly(anki[i].id, newRevlogs[i]);
  }
  final List<SrsReviewLog> anchors = <SrsReviewLog>[
    for (final SrsReviewLog l in logs)
      if (l.kind == SrsLogKind.importAnchor &&
          l.origin == SrsLogOrigin.anki &&
          l.hlc == srsImportAnchorHlc(l.occurredAt) &&
          !replayed(l) &&
          !ids.has(l.id))
        l,
  ];
  final List<String> newAnchors = SrsIds.importAnchorsOf(<(String, int)>[
    for (final SrsReviewLog l in anchors) (ids[l.cardId]!, l.occurredAt),
  ]);
  for (int i = 0; i < anchors.length; i++) {
    ids.exactly(anchors[i].id, newAnchors[i]);
  }
  final List<SrsReviewLog> others = <SrsReviewLog>[
    for (final SrsReviewLog l in logs)
      if (!ids.has(l.id)) l,
  ];
  final List<String> newOthers = uuidV5Batch(<(String, String)>[
    for (final SrsReviewLog l in others)
      (ids[l.cardId]!, 'profile-merge-log/${l.hlc.encode()}/${l.kind}'),
  ]);
  for (int i = 0; i < others.length; i++) {
    ids.derived(others[i].id, newOthers[i]);
  }
  ids.fallbackAll(<String>[
    for (final SrsReviewLog l in logs)
      if (l.revokesId != null) l.revokesId!,
    for (final SrsUnknownEvent u in unknown) u.id,
  ]);
  final Map<String, String> targetLogs = await _logIdsByIdentity(db, newUid);
  for (final SrsReviewLog l in logs) {
    final String? existing = targetLogs[_logIdentity(ids[l.cardId]!, l)];
    if (existing != null) ids.alias(l.id, existing);
  }

  // 8. 修改记录的写入者一一改名（合成的标签行写入者带笔记 ID，按 ID 映射改写）；目标集合里已经有同一批修改记录的
  //    写入者沿用目标里的名字（[_Writers.alias]）。
  final _Writers writers = _Writers(newUid, ids, edits, targetDots);

  // 9. 改写。
  final Map<String, int> oldServer = await _serverTimes(db, oldUid);
  final Map<String, String> oldToNew = <String, String>{};
  final Map<String, int> serverTimes = <String, int>{};
  void track(String oldId, String newId) {
    oldToNew[oldId] = newId;
    final int? s = oldServer[oldId];
    if (s != null) serverTimes[newId] = s;
  }

  final List<SrsEvent> structure = <SrsEvent>[];
  for (final SrsEntityRecord r in entities) {
    final SrsEntityRecord n = SrsEntityRecord(
      id: ids[r.id]!,
      profileUid: newUid,
      kind: r.kind,
      payload: (ids.deep(r.payload)! as Map).cast<String, Object?>(),
    );
    track(r.id, n.id);
    structure.add(SrsEntityEvent(n));
  }
  for (final SrsFieldEdit e in edits) {
    final SrsFieldEdit n = SrsFieldEdit(
      profileUid: newUid,
      entityKind: e.entityKind,
      entityId: ids.sub(e.entityId),
      fieldKey: ids.sub(e.fieldKey),
      dot: SrsDot(writers[e.dot.writerId], e.dot.seq),
      ctx: writers.context(e.ctx),
      value: ids.deep(e.value),
      hlc: Hlc(e.hlc.physical, e.hlc.counter, writers[e.hlc.writerId]),
      timeSource: e.timeSource,
      machine: e.machine,
    );
    track(e.id, n.id);
    structure.add(SrsEditEvent(n));
  }
  final List<SrsEvent> tail = <SrsEvent>[];
  final Map<String, (String, String)> seenLogs = <String, (String, String)>{};
  for (final SrsReviewLog l in logs) {
    final Map<String, Object?> j = (ids.deep(l.toJson())! as Map)
        .cast<String, Object?>();
    j['id'] = ids[l.id];
    j['p'] = newUid;
    j['card'] = ids[l.cardId];
    if (l.revokesId != null) j['revokes'] = ids[l.revokesId!];
    final SrsReviewLog n = SrsReviewLog.fromJson(j);
    track(l.id, n.id);
    // 两条旧日志映射到同一个新 ID：只有它们本来就是同一次复习（旧 profile 里同一次复习有两个 ID，BUG-4217）才只并
    // 一份；身份不同说明映射把两次不同的复习合成了一条，不能静默丢掉其中一条（丢掉的那次复习就没了，撤销还可能指向
    // 剩下那条），整个并入中止，旧 profile 不删。
    final String identity = '${_logIdentity(n.cardId, l)}|${n.revokesId}';
    final (String, String)? seen = seenLogs[n.id];
    if (seen == null) {
      seenLogs[n.id] = (l.id, identity);
      tail.add(SrsLogEvent(n));
    } else if (seen.$2 != identity) {
      throw StateError(
        'profile merge $oldUid -> $newUid: logs ${seen.$1} and ${l.id} are '
        'different reviews but both map to ${n.id}; old rows kept',
      );
    }
  }
  for (final SrsUnknownEvent u in unknown) {
    final Map<String, Object?> raw = (ids.deep(u.raw)! as Map)
        .cast<String, Object?>();
    final Object? x = raw['x'];
    if (x is Map && x.containsKey('p')) {
      raw['x'] = <String, Object?>{...x.cast<String, Object?>(), 'p': newUid};
    }
    final SrsUnknownEvent n = SrsUnknownEvent(raw);
    track(u.id, n.id);
    tail.add(n);
  }
  return _MergePlan(
    structure: structure,
    tail: tail,
    serverTimes: serverTimes,
    oldToNew: oldToNew,
    exact: ids.exact,
    fallback: ids.fallback,
    aliased: ids.aliased,
  );
}

/// 一条复习日志的身份（不含它自己的 ID）：卡片、种类、评分、发生时刻与 HLC。Anki 导入的 revlog 的 HLC 物理部分
/// 就是 revlog id、写入者是 `anki`，两台设备各自导入同一份 Anki 得到的是同一个身份。
String _logIdentity(String cardId, SrsReviewLog l) =>
    '${cardId.toLowerCase()}|${l.kind}|${l.rating}|${l.occurredAt}|'
    '${l.hlc.physical}:${l.hlc.counter}:${l.hlc.writerId}';

/// [profileUid] 名下已有复习日志的 身份 → ID。
Future<Map<String, String>> _logIdsByIdentity(
  SrsDatabase db,
  String profileUid,
) async {
  final Map<String, String> out = <String, String>{};
  for (final QueryRow r
      in await db
          .customSelect(
            'SELECT json FROM srs_review_logs WHERE profile_uid = ? '
            'ORDER BY id',
            variables: <Variable<Object>>[
              Variable<String>(profileUid, srsIdType),
            ],
          )
          .get()) {
    final SrsReviewLog l = SrsReviewLog.fromJson(
      (jsonDecode(r.read<String>('json')) as Map).cast<String, Object?>(),
    );
    out.putIfAbsent(_logIdentity(l.cardId, l), () => l.id);
  }
  return out;
}

/// 旧 ID → 新 ID。
class _IdMap {
  _IdMap(this.oldUid, this.newUid) {
    _m[oldUid] = newUid;
    exact = 1;
  }

  final String oldUid;
  final String newUid;
  final Map<String, String> _m = <String, String>{};
  int exact = 0;
  int fallback = 0;

  /// 被 [alias] 改到目标里已有 ID 的条数（同一次复习目标里已经有，只是 ID 与规则 / 兜底算出的不同）。
  int aliased = 0;

  bool has(String id) => _m.containsKey(id.toLowerCase());

  String? operator [](String id) => _m[id.toLowerCase()];

  void exactly(String oldId, String newId) {
    final String k = oldId.toLowerCase();
    if (_m.containsKey(k)) return;
    _m[k] = newId;
    exact++;
  }

  /// [oldId] 按不可变内容派生成 [newId]（还原不出原派生输入的兜底，算进 [fallback]）。
  void derived(String oldId, String newId) {
    final String k = oldId.toLowerCase();
    if (_m.containsKey(k)) return;
    _m[k] = newId;
    fallback++;
  }

  /// [oldId] 改映射到 [newId]（目标里已有的同一条记录），与原映射相同时不算。
  void alias(String oldId, String newId) {
    final String k = oldId.toLowerCase();
    if (_m[k]?.toLowerCase() == newId.toLowerCase()) return;
    _m[k] = newId;
    aliased++;
  }

  /// 还没有映射的 [oldIds] 一律走确定性兜底（一次 FFI）。
  void fallbackAll(Iterable<String> oldIds) {
    final List<String> todo = <String>{
      for (final String id in oldIds)
        if (!_m.containsKey(id.toLowerCase())) id.toLowerCase(),
    }.toList();
    if (todo.isEmpty) return;
    final List<String> out = uuidV5Batch(<(String, String)>[
      for (final String id in todo) (srsNamespace, 'profile-merge/$newUid/$id'),
    ]);
    for (int i = 0; i < todo.length; i++) {
      _m[todo[i]] = out[i];
    }
    fallback += todo.length;
  }

  /// 字符串里出现的、已映射的 ID（整串或 `{{fld:<id>}}` / `historyFrom/<id>` 之类的片段）一律换掉。
  String sub(String s) {
    if (s.length < 36) return s;
    final String? whole = _m[s];
    if (whole != null) return whole;
    if (!s.contains('-')) return s;
    return s.replaceAllMapped(
      _uuidToken,
      (Match m) => _m[m[0]!.toLowerCase()] ?? m[0]!,
    );
  }

  /// JSON 值里的全部字符串（含 map 的键）按 [sub] 改写。
  Object? deep(Object? v) => switch (v) {
    final String s => sub(s),
    final List<Object?> l => <Object?>[for (final Object? x in l) deep(x)],
    final Map<Object?, Object?> m => <String, Object?>{
      for (final MapEntry<Object?, Object?> e in m.entries)
        sub('${e.key}'): deep(e.value),
    },
    _ => v,
  };
}

/// 修改记录按（实体种类, 实体, 字段键）分组（只用于还原牌组全名）。
class _Registers {
  _Registers(List<SrsFieldEdit> edits) {
    for (final SrsFieldEdit e in edits) {
      if (e.entityKind != SrsEntityKind.deck) continue;
      final SrsFieldEdit? cur = _latest['${e.entityId}/${e.fieldKey}'];
      if (cur == null || _hlcAfter(e.hlc, cur.hlc)) {
        _latest['${e.entityId}/${e.fieldKey}'] = e;
      }
    }
  }

  final Map<String, SrsFieldEdit> _latest = <String, SrsFieldEdit>{};

  static bool _hlcAfter(Hlc a, Hlc b) {
    if (a.physical != b.physical) return a.physical > b.physical;
    if (a.counter != b.counter) return a.counter > b.counter;
    return a.writerId.compareTo(b.writerId) > 0;
  }

  /// 牌组此刻的全名（「父::子」）；名字缺失或父链成环时 null。
  String? deckPath(String deckId) {
    final List<String> parts = <String>[];
    final Set<String> seen = <String>{};
    String? cur = deckId;
    while (cur != null) {
      if (!seen.add(cur)) return null;
      final Object? name = _latest['$cur/${SrsFieldKeys.name}']?.value;
      if (name is! String) return null;
      parts.insert(0, name);
      final Object? parent = _latest['$cur/${SrsFieldKeys.deckParent}']?.value;
      cur = parent is String ? parent : null;
    }
    return parts.join('::');
  }
}

/// 修改记录写入者的确定性改名（一一对应：支配关系与因果上下文原样保留）。
///
/// 例外（[alias]）：目标 uid 下已经有同一批修改记录（某个写入者与它同 seq、同 HLC 物理时刻与计数）时沿用目标里那个
/// 写入者的名字，而不是改成 `merged-…`。（沿用的只能是别的名字：同名同 seq 的记录 ID 相同，`srs_field_edits.id` 是全局
/// 主键，新旧两个 uid 在本机不可能同时有。）否则同一条修改记录在目标集合里就成了两条：dot 不同 → ID 不同，
/// 投影里每个寄存器各一份，操作日志里也各一份（BUG-4011：宿主把旧 profile 并入后，`merged-f18df189…` 的 31 万条与
/// 01a173ca 迁移出的 `2RIr94…#1` 逐条同 seq 同 HLC）。沿用后 dot 相同 → 修改记录 ID 相同，[_applyMissing] 按 ID
/// 认出已在、不再并。
class _Writers {
  _Writers(
    this.newUid,
    this.ids,
    List<SrsFieldEdit> edits,
    Map<String, Map<int, String>> target,
  ) {
    final Set<String> all = <String>{};
    for (final SrsFieldEdit e in edits) {
      all
        ..add(e.dot.writerId)
        ..add(e.hlc.writerId)
        ..addAll(e.ctx.vv.keys)
        ..addAll(e.ctx.cloud.keys);
    }
    final Map<String, Map<int, String>> own = <String, Map<int, String>>{};
    for (final SrsFieldEdit e in edits) {
      (own[e.dot.writerId] ??= <int, String>{})[e.dot.seq] = _hlcStamp(e.hlc);
    }
    final Set<String> taken = <String>{};
    for (final String w in all.toList()..sort()) {
      if (w.startsWith(_kSyntheticWriterPrefix)) continue;
      final String? t = alias(own[w], target, taken: taken);
      if (t == null) continue;
      _m[w] = t;
      taken.add(t);
    }
    final List<String> plain = <String>[
      for (final String w in all.toList()..sort())
        if (!w.startsWith(_kSyntheticWriterPrefix) && !_m.containsKey(w)) w,
    ];
    // 改名只从**最初的写入者**派生（[_mergedWriterOrigin]），不从上一跳的名字派生：A→B→C 链式合并与 A→C 直接
    // 合并得到同一个名字，同一批修改记录 dot 相同 → ID 相同，不会在目标里落成两份。两种情况不剥（按整个名字当最初的
    // 写入者）：这个旧 profile 里还有别的写入者剥出同一个最初写入者（剥了就两个写入者并成一个、同 seq 撞 dot）；
    // 剥完算出来的名字就是它自己（它本来就是为 newUid 改的名，原样留着会和旧 uid 的行同 ID）。
    final Map<String, int> origins = <String, int>{};
    for (final String w in all) {
      if (w.startsWith(_kSyntheticWriterPrefix)) continue;
      final String o = _mergedWriterOrigin(w);
      origins[o] = (origins[o] ?? 0) + 1;
    }
    String originOf(String w) {
      final String o = _mergedWriterOrigin(w);
      return o != w && origins[o]! > 1 ? w : o;
    }

    final List<String> renamed = _mergedWriterNames(newUid, <String>[
      for (final String w in plain) originOf(w),
    ]);
    final List<int> self = <int>[
      for (int i = 0; i < plain.length; i++)
        if (renamed[i] == plain[i]) i,
    ];
    if (self.isNotEmpty) {
      final List<String> again = _mergedWriterNames(newUid, <String>[
        for (final int i in self) plain[i],
      ]);
      for (int k = 0; k < self.length; k++) {
        renamed[self[k]] = again[k];
      }
    }
    for (int i = 0; i < plain.length; i++) {
      _m[plain[i]] = renamed[i];
    }
    // 一一对应是支配关系与 dot 唯一性的前提：任何两个旧写入者改成同一个名字都会让不同的修改记录同 dot。
    final Map<String, String> back = <String, String>{};
    for (final MapEntry<String, String> e in _m.entries) {
      final String? other = back[e.value];
      if (other != null) {
        throw StateError(
          'profile merge into $newUid: writers $other and ${e.key} would both '
          'become ${e.value}; old rows kept',
        );
      }
      back[e.value] = e.key;
    }
  }

  final String newUid;
  final _IdMap ids;
  final Map<String, String> _m = <String, String>{};

  /// 旧写入者（它的修改记录 seq → HLC 戳 [mine]）在目标 uid 下的同一身份：目标里某个写入者 T 至少有一条修改记录与它
  /// 同 seq 同 HLC，同 seq 的没有一条 HLC 不同（不同 = 两条不同的记录，沿用就撞 ID），且旧写入者用到的最大 seq 不超过
  /// T 在目标里的（不会以 T 的名义写出 T 自己将来要用的 seq）。取吻合条数最多的；已被别的旧写入者占用的 [taken] 不再用。
  /// 都不合格返回 null（照常改名）。
  static String? alias(
    Map<int, String>? mine,
    Map<String, Map<int, String>> target, {
    required Set<String> taken,
  }) {
    if (mine == null || mine.isEmpty) return null;
    final int maxMine = mine.keys.reduce((int a, int b) => a > b ? a : b);
    String? best;
    int bestHits = 0;
    for (final String t in target.keys.toList()..sort()) {
      if (taken.contains(t)) continue;
      final Map<int, String> theirs = target[t]!;
      int hits = 0;
      bool clash = false;
      for (final MapEntry<int, String> e in mine.entries) {
        final String? h = theirs[e.key];
        if (h == null) continue;
        if (h != e.value) {
          clash = true;
          break;
        }
        hits++;
      }
      if (clash || hits == 0) continue;
      if (maxMine > theirs.keys.reduce((int a, int b) => a > b ? a : b)) {
        continue;
      }
      if (hits > bestHits) {
        best = t;
        bestHits = hits;
      }
    }
    return best;
  }

  String operator [](String w) =>
      _m[w] ?? (w.startsWith(_kSyntheticWriterPrefix) ? ids.sub(w) : w);

  SrsCausalContext context(SrsCausalContext ctx) => SrsCausalContext.of(
    vv: <String, int>{
      for (final MapEntry<String, int> e in ctx.vv.entries)
        this[e.key]: e.value,
    },
    cloud: <String, Iterable<int>>{
      for (final MapEntry<String, List<int>> e in ctx.cloud.entries)
        this[e.key]: e.value,
    },
  );
}

/// HLC 里比对用的部分（物理时刻:计数；写入者部分随改名变，不比）。
String _hlcStamp(Hlc h) => '${h.physical}:${h.counter}';

/// 目标 uid 下每个写入者的旧修改记录（带旧 dot 的：迁移来的、并入的）：seq → HLC 戳（[_hlcStamp]）。读的是操作
/// 日志（内核 `legacy_dots`，native/fushi_fsrs/src/store/sync2/mod.rs `sync2_legacy_dots`），不是投影：被支配、已不在
/// 投影里的同 seq 记录也看得见，内容不同就判冲突、不沿用。
Future<Map<String, Map<int, String>>> _targetDots(SrsDbStore target) async {
  final Map<String, Object?> r = (await target.sync2Command(
    const <String, Object?>{'op': 'legacy_dots'},
  )).map;
  final Map<String, Map<int, String>> out = <String, Map<int, String>>{};
  for (final MapEntry<String, Object?> e
      in ((r['writers'] as Map?) ?? const <String, Object?>{})
          .cast<String, Object?>()
          .entries) {
    if (e.key.startsWith(_kSyntheticWriterPrefix)) continue;
    final List<Object?> flat = (e.value! as List).cast<Object?>();
    final Map<int, String> dots = out[e.key] = <int, String>{};
    for (int i = 0; i + 2 < flat.length; i += 3) {
      dots[flat[i]! as int] = '${flat[i + 1]}:${flat[i + 2]}';
    }
  }
  return out;
}

// ---------------------------------------------------------------- 落库

/// 把计划里还不在新 uid 下的事件并进去（先身份记录 + 修改记录，再日志 + 不认识的事件）。返回并入条数。
Future<int> _applyMissing(SrsDbStore target, _MergePlan plan) async {
  int n = 0;
  for (final List<SrsEvent> part in <List<SrsEvent>>[
    plan.structure,
    plan.tail,
  ]) {
    final Set<String> have = await _presentIn(
      target.db,
      target.profileUid,
      <String>[for (final SrsEvent e in part) e.id],
    );
    final List<SrsEvent> missing = <SrsEvent>[
      for (final SrsEvent e in part)
        if (!have.contains(e.id)) e,
    ];
    if (missing.isEmpty) continue;
    await target.applyRemote(missing, serverTimes: plan.serverTimes);
    n += missing.length;
  }
  return n;
}

/// [profileUid] 名下已有的事件 ID（含被支配而不在投影里的修改记录、被清除内容的日志：看操作索引）。
Future<Set<String>> _presentIn(
  SrsDatabase db,
  String profileUid,
  Iterable<String> ids,
) async {
  final List<String> all = ids.toSet().toList();
  final Set<String> out = <String>{};
  for (int i = 0; i < all.length; i += 400) {
    final List<String> chunk = all.sublist(
      i,
      i + 400 > all.length ? all.length : i + 400,
    );
    final String marks = List<String>.filled(chunk.length, '?').join(', ');
    final List<Variable<Object>> vars = <Variable<Object>>[
      Variable<String>(profileUid, srsIdType),
      for (final String id in chunk) Variable<String>(id, srsIdType),
    ];
    for (final (String table, String col) in const <(String, String)>[
      ('srs_entities', 'id'),
      ('srs_field_edits', 'id'),
      ('sync2_edit_ops', 'edit_id'),
      ('srs_review_logs', 'id'),
      ('sync2_log_meta', 'log_id'),
      ('srs_unknown_events', 'id'),
    ]) {
      for (final QueryRow r
          in await db
              .customSelect(
                'SELECT $col AS i FROM $table WHERE profile_uid = ? '
                'AND $col IN ($marks)',
                variables: vars,
              )
              .get()) {
        out.add(r.read<String>('i'));
      }
    }
  }
  return out;
}

/// [profileUid] 名下投影里的全部事件 ID。
Future<Set<String>> _eventIds(SrsDatabase db, String profileUid) async {
  final Set<String> out = <String>{};
  for (final String table in const <String>[
    'srs_entities',
    'srs_field_edits',
    'srs_review_logs',
    'srs_unknown_events',
  ]) {
    for (final QueryRow r
        in await db
            .customSelect(
              'SELECT id FROM $table WHERE profile_uid = ?',
              variables: <Variable<Object>>[
                Variable<String>(profileUid, srsIdType),
              ],
            )
            .get()) {
      out.add(r.read<String>('id'));
    }
  }
  return out;
}

Future<Map<String, int>> _serverTimes(
  SrsDatabase db,
  String profileUid,
) async => <String, int>{
  for (final QueryRow r
      in await db
          .customSelect(
            'SELECT event_id, server_time FROM srs_event_local '
            'WHERE profile_uid = ? AND server_time IS NOT NULL',
            variables: <Variable<Object>>[
              Variable<String>(profileUid, srsIdType),
            ],
          )
          .get())
    r.read<String>('event_id'): r.read<int>('server_time'),
};

/// 删掉 [uid] 在 srs.db 里的一切：所有带 `profile_uid` 列的表（数据、投影、缓存、本机状态、同步 v2 的操作日志
/// 与身份）、迁移进行中标记、并入标记。调用方在事务里。
Future<void> _deleteProfile(SrsDatabase db, String uid) async {
  final List<String> tables = <String>[
    for (final QueryRow r
        in await db
            .customSelect(
              "SELECT m.name AS n FROM sqlite_master m WHERE m.type = 'table' "
              'AND EXISTS (SELECT 1 FROM pragma_table_info(m.name) p '
              "WHERE p.name = 'profile_uid')",
            )
            .get())
      r.read<String>('n'),
  ];
  for (final String t in tables) {
    await db.customStatement(
      'DELETE FROM "$t" WHERE profile_uid = srs_id(?)',
      <Object>[uid],
    );
  }
  await db.customStatement('DELETE FROM srs_meta WHERE key IN (?, ?)', <Object>[
    'sync2_migrating/$uid',
    '$kSrsProfileMergeMarkerPrefix$uid',
  ]);
}

// ---------------------------------------------------------------- 媒体

String _join(String a, String b) => '$a${Platform.pathSeparator}$b';

/// `<root>/<old>/` 下的文件拷进 `<root>/<new>/`：已有同名的不动（内容寻址：同名即同内容），先写临时名再改名。
Future<void> _copyMedia(Directory root, String oldUid, String newUid) async {
  final Directory from = Directory(_join(root.path, oldUid));
  if (!from.existsSync()) return;
  final Directory to = Directory(_join(root.path, newUid));
  await to.create(recursive: true);
  await for (final FileSystemEntity f in from.list(followLinks: false)) {
    if (f is! File) continue;
    final String name = f.uri.pathSegments.last;
    final File dest = File(_join(to.path, name));
    if (dest.existsSync()) continue;
    final File tmp = File('${dest.path}.merge-tmp');
    await f.copy(tmp.path);
    await tmp.rename(dest.path);
  }
}
