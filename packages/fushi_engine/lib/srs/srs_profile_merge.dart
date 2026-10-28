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
/// 出派生输入（笔记 guid、笔记类型 ankiNum、字段 / 模板 ankiNum 或名字、牌组全名、卡片的笔记 + 模板 + 序号、
/// Anki revlog id、导入锚点时刻）且用旧 uid 验算吻合的，用同一条规则换成新 uid 算；还原不出来的用确定性兜底
/// `uuidV5(NS, profile-merge/<newUid>/<旧 ID>)`。修改记录的写入者按 `merged-uuidV5(NS, profile-merge/<newUid>/
/// writer/<旧写入者>)` 一一改名（dot / 因果上下文 / HLC 里的写入者一起改），记录之间的支配关系原样保留，
/// 修改记录 ID（由 dot 派生）也就与旧 profile 不相交。复习日志 ID 同理重算。
///
/// 全部映射只依赖 (旧 ID, newUid)：重跑得到同一批 ID（幂等）；两台设备各自把同一个旧 profile 并入同一个
/// 新 uid，也得到同一批 ID，合并后是同一行而不是两份。
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
import 'package:fushi_core/fushi_core.dart' show FushiDatabase, SrsDatabase;
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

/// 一次并入的结果。
class SrsProfileMergeResult {
  const SrsProfileMergeResult({
    required this.profileId,
    required this.oldUid,
    required this.newUid,
    required this.appliedEvents,
    required this.exactIds,
    required this.fallbackIds,
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
    plan = await _plan(srs, oldUid: oldUid, newUid: newUid);
    applied += await _applyMissing(target, plan);
    await debugFault?.call(SrsProfileMergeStage.afterFirstMerge);
    await db.adoptProfileUid(profileId, newUid);
    await debugFault?.call(SrsProfileMergeStage.afterUidSwitch);
  }

  for (int round = 0; ; round++) {
    plan = await _plan(srs, oldUid: oldUid, newUid: newUid);
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
}

final RegExp _uuidToken = RegExp(
  r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
);

/// 旧 uid 下的事件 → ID 映射 → 改写成新 uid 下的事件。
Future<_MergePlan> _plan(
  SrsDatabase db, {
  required String oldUid,
  required String newUid,
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
                  variables: <Variable<Object>>[Variable<String>(oldUid)],
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

  // 7. 复习日志：导入的 revlog = UUIDv5(cardId, anki-revlog/<id>)、导入锚点 = UUIDv5(cardId, anki-anchor/<时刻>)；
  //    原生日志（UUIDv7）与还原不出来的走兜底。
  final List<SrsReviewLog> anki = <SrsReviewLog>[
    for (final SrsReviewLog l in logs)
      if (l.ankiRevlogId != null) l,
  ];
  final List<String> oldRevlogs = SrsIds.importedRevlogsOf(<(String, int)>[
    for (final SrsReviewLog l in anki) (l.cardId, l.ankiRevlogId!),
  ]);
  final List<String> newRevlogs = SrsIds.importedRevlogsOf(<(String, int)>[
    for (final SrsReviewLog l in anki) (ids[l.cardId]!, l.ankiRevlogId!),
  ]);
  for (int i = 0; i < anki.length; i++) {
    if (oldRevlogs[i] == anki[i].id) ids.exactly(anki[i].id, newRevlogs[i]);
  }
  final List<SrsReviewLog> anchors = <SrsReviewLog>[
    for (final SrsReviewLog l in logs)
      if (l.kind == SrsLogKind.importAnchor && !ids.has(l.id)) l,
  ];
  final List<String> oldAnchors = SrsIds.importAnchorsOf(<(String, int)>[
    for (final SrsReviewLog l in anchors) (l.cardId, l.occurredAt),
  ]);
  final List<String> newAnchors = SrsIds.importAnchorsOf(<(String, int)>[
    for (final SrsReviewLog l in anchors) (ids[l.cardId]!, l.occurredAt),
  ]);
  for (int i = 0; i < anchors.length; i++) {
    if (oldAnchors[i] == anchors[i].id) {
      ids.exactly(anchors[i].id, newAnchors[i]);
    }
  }
  ids.fallbackAll(<String>[
    for (final SrsReviewLog l in logs) ...<String>[
      l.id,
      if (l.revokesId != null) l.revokesId!,
    ],
    for (final SrsUnknownEvent u in unknown) u.id,
  ]);

  // 8. 修改记录的写入者一一改名（合成的标签行写入者带笔记 ID，按 ID 映射改写）。
  final _Writers writers = _Writers(newUid, ids, edits);

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
  for (final SrsReviewLog l in logs) {
    final Map<String, Object?> j = (ids.deep(l.toJson())! as Map)
        .cast<String, Object?>();
    j['id'] = ids[l.id];
    j['p'] = newUid;
    j['card'] = ids[l.cardId];
    if (l.revokesId != null) j['revokes'] = ids[l.revokesId!];
    final SrsReviewLog n = SrsReviewLog.fromJson(j);
    track(l.id, n.id);
    tail.add(SrsLogEvent(n));
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
  );
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

  bool has(String id) => _m.containsKey(id.toLowerCase());

  String? operator [](String id) => _m[id.toLowerCase()];

  void exactly(String oldId, String newId) {
    final String k = oldId.toLowerCase();
    if (_m.containsKey(k)) return;
    _m[k] = newId;
    exact++;
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
class _Writers {
  _Writers(this.newUid, this.ids, List<SrsFieldEdit> edits) {
    final Set<String> all = <String>{};
    for (final SrsFieldEdit e in edits) {
      all
        ..add(e.dot.writerId)
        ..add(e.hlc.writerId)
        ..addAll(e.ctx.vv.keys)
        ..addAll(e.ctx.cloud.keys);
    }
    final List<String> plain = <String>[
      for (final String w in all)
        if (!w.startsWith(_kSyntheticWriterPrefix)) w,
    ];
    final List<String> renamed = uuidV5Batch(<(String, String)>[
      for (final String w in plain)
        (srsNamespace, 'profile-merge/$newUid/writer/$w'),
    ]);
    for (int i = 0; i < plain.length; i++) {
      _m[plain[i]] = '$kSrsMergedWriterPrefix${renamed[i]}';
    }
  }

  final String newUid;
  final _IdMap ids;
  final Map<String, String> _m = <String, String>{};

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
      Variable<String>(profileUid),
      for (final String id in chunk) Variable<String>(id),
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
              variables: <Variable<Object>>[Variable<String>(profileUid)],
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
            variables: <Variable<Object>>[Variable<String>(profileUid)],
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
    await db.customStatement('DELETE FROM "$t" WHERE profile_uid = ?', <Object>[
      uid,
    ]);
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
