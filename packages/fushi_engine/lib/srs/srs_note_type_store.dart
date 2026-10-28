/// 笔记类型管理与「更改笔记类型」的存储层操作（[SrsDbStore] 的扩展）。
///
/// 全部写操作经 [SrsDbStore.writeEdits] 写成修改记录（铁律 H），随批次同步、按项合并：
/// - 笔记类型的名字 / CSS / 词条字段各是一个字段键；每个字段定义、每个模板定义各是一个字段键
///   （`fieldDef/<id>`、`tmplDef/<id>`），两台设备离线各加一个字段，合并后两个都在。
/// - 删字段 / 删模板 / 删笔记类型都是软删除（定义上标 deleted / 行上写 deleted），复习历史不动；
///   删模板后它的卡在查询层隐藏（生成门），模板恢复时同一 cardId 带着历史回来。
/// - 加模板不写任何卡片行：各设备刷新缓存时按 (noteId, templateId, clozeOrd) 确定性生成同一张卡。
/// - 更改笔记类型：见 fushi_srs 的 note_type_ops.dart。
///
/// 内置类型（Lapis、Fushi 卡片）：允许改名、改模板 / CSS、加字段 / 模板、改字段名与顺序；**不允许删除笔记类型，
/// 也不允许删除它的内置字段**（挖词与词状态按内置 fieldId 写入 / 读取，删了会让新挖的词落进看不见的字段）。
library;

import 'package:drift/drift.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';

/// 新建笔记类型的起点（Anki「添加笔记类型」里的基础类型）。
enum SrsStockNoteType {
  /// 问答（Front / Back，一张卡）。
  basic,

  /// 问答 + 反向卡（两张卡）。
  basicReversed,

  /// 填空（Text / Back Extra）。
  cloze,
}

/// 新建笔记类型的默认 CSS（Anki 默认样式去掉写死的黑字白底：卡面配色跟随 app 主题）。
const String kSrsDefaultNoteTypeCss =
    '.card {\n'
    '  font-family: arial;\n'
    '  font-size: 20px;\n'
    '  line-height: 1.5;\n'
    '  text-align: center;\n'
    '}\n';

const String _kClozeCss =
    '.cloze {\n'
    '  font-weight: bold;\n'
    '  color: blue;\n'
    '}\n'
    '.nightMode .cloze {\n'
    '  color: lightblue;\n'
    '}\n';

/// 一次「更改笔记类型」的预演结果（对话框据此显示会删掉几张卡）。
class SrsNoteTypeChangePreview {
  const SrsNoteTypeChangePreview({
    required this.from,
    required this.to,
    required this.plans,
  });

  final SrsNoteTypeView from;
  final SrsNoteTypeView to;
  final List<SrsNoteTypeChangePlan> plans;

  /// 换类型后不再出现的卡（原本可见、没有映射到新模板）。
  int get droppedCards => plans.fold<int>(
    0,
    (int sum, SrsNoteTypeChangePlan p) => sum + p.droppedCards.length,
  );

  /// 继承复习历史的卡。
  int get linkedCards => plans.fold<int>(
    0,
    (int sum, SrsNoteTypeChangePlan p) => sum + p.cardLinks.length,
  );
}

extension SrsNoteTypeStoreOps on SrsDbStore {
  Future<SrsNoteTypeView> _requireType(String id) async {
    final SrsNoteTypeView? t = await noteType(id);
    if (t == null || t.deletedAt != null) {
      throw ArgumentError.value(id, 'noteTypeId', 'note type not found');
    }
    return t;
  }

  /// 内置字段（内置类型 Lapis / Fushi 卡片的代码默认字段）：不能删。
  bool isBuiltinField(SrsNoteTypeView t, String fieldId) =>
      srsBuiltinNoteTypeForKey(
        profileUid,
        t.builtinKey,
      )?.fields.any((SrsFieldDef f) => f.id == fieldId) ??
      false;

  /// 内置笔记类型不能删。
  bool canDeleteNoteType(SrsNoteTypeView t) => t.builtinKey == null;

  // ------------------------------------------------------------------ 查询

  /// 每个笔记类型的笔记数（未删除的笔记；按笔记**当前**类型计）。SQLite 侧分组计数（走
  /// idx_srs_notes_cache_type），不把笔记缓存行读回来逐行数。
  Future<Map<String, int>> noteCountsByType() async => <String, int>{
    for (final QueryRow r
        in await db
            .customSelect(
              'SELECT note_type_id AS t, COUNT(*) AS c FROM srs_notes_cache '
              'WHERE profile_uid = ? AND deleted_at IS NULL '
              'GROUP BY note_type_id',
              variables: <Variable<Object>>[Variable<String>(profileUid)],
              readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
                db.srsNotesCache,
              },
            )
            .get())
      r.read<String>('t'): r.read<int>('c'),
  };

  /// 某笔记类型下的笔记（未删除），按落库顺序。走 idx_srs_notes_cache_type、只读 id 列；
  /// [limit] 给了就只取前几条（取样本预览用）。
  Future<List<String>> noteIdsOfType(String noteTypeId, {int? limit}) async {
    final $SrsNotesCacheTable n = db.srsNotesCache;
    final JoinedSelectStatement<$SrsNotesCacheTable, SrsNoteCacheRow> q =
        db.selectOnly(n)
          ..addColumns(<Expression<Object>>[n.id])
          ..where(
            n.profileUid.equals(profileUid) &
                n.noteTypeId.equals(noteTypeId) &
                n.deletedAt.isNull(),
          );
    if (limit != null) q.limit(limit);
    return <String>[for (final TypedResult r in await q.get()) r.read(n.id)!];
  }

  /// 这个字段里有内容的笔记数（删字段前的提示用）。
  Future<int> notesWithFieldContent(String noteTypeId, String fieldId) async {
    int n = 0;
    for (final SrsNoteView? v in (await notes(
      await noteIdsOfType(noteTypeId),
    )).values) {
      if (v != null && v.field(fieldId).trim().isNotEmpty) n++;
    }
    return n;
  }

  /// 一组笔记各自的卡片缓存行（按 noteId 分块一次读；没有卡的笔记映射到空表）。
  Future<Map<String, List<SrsCardCacheRow>>> cardsOfNotes(
    Iterable<String> noteIds,
  ) async {
    final List<String> ids = noteIds.toSet().toList();
    final Map<String, List<SrsCardCacheRow>> out =
        <String, List<SrsCardCacheRow>>{
          for (final String id in ids) id: <SrsCardCacheRow>[],
        };
    for (int i = 0; i < ids.length; i += 500) {
      final List<String> chunk = ids.sublist(
        i,
        i + 500 > ids.length ? ids.length : i + 500,
      );
      for (final SrsCardCacheRow c in await (db.select(
        db.srsCardsCache,
      )..where((x) => x.noteId.isIn(chunk))).get()) {
        out[c.noteId]!.add(c);
      }
    }
    return out;
  }

  /// 这个模板现在可见的卡数（删模板前的提示用：删了这些卡就不再出现）。
  Future<int> visibleCardsOfTemplate(String templateId) async =>
      (await (db.select(db.srsCardsCache)..where(
                (c) =>
                    c.profileUid.equals(profileUid) &
                    c.templateId.equals(templateId) &
                    c.hidden.equals(false),
              ))
              .get())
          .length;

  // ------------------------------------------------------------------ 新建 / 删除

  Future<String> _writeNewType(SrsNewNoteType nt) async {
    await writeEdits(
      <SrsEditSpec>[
        SrsEditSpec(SrsEntityKind.noteType, nt.id, SrsFieldKeys.name, nt.name),
        for (final SrsFieldDef f in nt.fields)
          SrsEditSpec(
            SrsEntityKind.noteType,
            nt.id,
            SrsFieldKeys.fieldDef(f.id),
            f.toValue(),
          ),
        // 克隆带过来的字段说明（独立键，见 [SrsFieldKeys.fieldDescription]）。
        for (final SrsFieldDef f in nt.fields)
          if (f.description.isNotEmpty)
            SrsEditSpec(
              SrsEntityKind.noteType,
              nt.id,
              SrsFieldKeys.fieldDescription(f.id),
              f.description,
            ),
        for (final SrsTemplateDef tpl in nt.templates)
          SrsEditSpec(
            SrsEntityKind.noteType,
            nt.id,
            SrsFieldKeys.templateDef(tpl.id),
            tpl.toValue(),
          ),
        SrsEditSpec(SrsEntityKind.noteType, nt.id, SrsFieldKeys.css, nt.css),
        if (nt.termFieldId != null)
          SrsEditSpec(
            SrsEntityKind.noteType,
            nt.id,
            SrsFieldKeys.termField,
            nt.termFieldId,
          ),
        if (nt.freqFieldId != null)
          SrsEditSpec(
            SrsEntityKind.noteType,
            nt.id,
            SrsFieldKeys.freqField,
            nt.freqFieldId,
          ),
      ],
      records: <SrsEntityRecord>[nt.record],
    );
    return nt.id;
  }

  /// 新建一个基础笔记类型。
  Future<String> createStockNoteType(SrsStockNoteType stock, String name) {
    final (int nowMs, _) = now();
    const String answer = '{{FrontSide}}\n\n<hr id=answer>\n\n';
    final SrsNewNoteType nt = switch (stock) {
      SrsStockNoteType.basic => srsBuildNoteType(
        profileUid: profileUid,
        name: name,
        kind: SrsNoteTypeKind.standard,
        fieldNames: const <String>['Front', 'Back'],
        templates: const <SrsTemplateSpec>[
          SrsTemplateSpec(
            name: 'Card 1',
            front: '{{Front}}',
            back: '$answer{{Back}}',
          ),
        ],
        css: kSrsDefaultNoteTypeCss,
        namesToIds: templateNamesToIds,
        createdAt: nowMs,
        termFieldName: 'Front',
      ),
      SrsStockNoteType.basicReversed => srsBuildNoteType(
        profileUid: profileUid,
        name: name,
        kind: SrsNoteTypeKind.standard,
        fieldNames: const <String>['Front', 'Back'],
        templates: const <SrsTemplateSpec>[
          SrsTemplateSpec(
            name: 'Card 1',
            front: '{{Front}}',
            back: '$answer{{Back}}',
          ),
          SrsTemplateSpec(
            name: 'Card 2',
            front: '{{Back}}',
            back: '$answer{{Front}}',
          ),
        ],
        css: kSrsDefaultNoteTypeCss,
        namesToIds: templateNamesToIds,
        createdAt: nowMs,
        termFieldName: 'Front',
      ),
      SrsStockNoteType.cloze => srsBuildNoteType(
        profileUid: profileUid,
        name: name,
        kind: SrsNoteTypeKind.cloze,
        fieldNames: const <String>['Text', 'Back Extra'],
        templates: const <SrsTemplateSpec>[
          SrsTemplateSpec(
            name: 'Cloze',
            front: '{{cloze:Text}}',
            back: '{{cloze:Text}}<br>\n{{Back Extra}}',
          ),
        ],
        css: '$kSrsDefaultNoteTypeCss$_kClozeCss',
        namesToIds: templateNamesToIds,
        createdAt: nowMs,
      ),
    };
    return _writeNewType(nt);
  }

  /// 克隆一个已有笔记类型（字段 / 模板 / CSS 原样，ID 全新）。
  Future<String> cloneNoteType(String sourceId, String name) async {
    final SrsNoteTypeView src = await _requireType(sourceId);
    final (int nowMs, _) = now();
    return _writeNewType(
      srsCloneNoteType(
        profileUid: profileUid,
        source: src,
        name: name,
        createdAt: nowMs,
      ),
    );
  }

  Future<void> renameNoteType(String id, String name) =>
      writeEdits(<SrsEditSpec>[
        SrsEditSpec(SrsEntityKind.noteType, id, SrsFieldKeys.name, name.trim()),
      ]);

  /// 删除笔记类型与它的全部笔记（软删除，Anki 的语义）。内置类型抛 [StateError]。
  Future<void> deleteNoteType(String id) => runExclusive(() async {
    final SrsNoteTypeView t = await _requireType(id);
    if (!canDeleteNoteType(t)) {
      throw StateError('built-in note type cannot be deleted');
    }
    final (int nowMs, _) = now();
    await writeEdits(<SrsEditSpec>[
      for (final String n in await noteIdsOfType(id))
        SrsEditSpec(SrsEntityKind.note, n, SrsFieldKeys.deleted, nowMs),
      SrsEditSpec(SrsEntityKind.noteType, id, SrsFieldKeys.deleted, nowMs),
    ]);
  });

  // ------------------------------------------------------------------ 字段

  /// 加字段（放在最后）。旧笔记里没有这个 fieldId，读出来是空值，不回填。
  Future<String> addField(String noteTypeId, String name) async {
    final SrsNoteTypeView t = await _requireType(noteTypeId);
    final ({String id, int ankiNum}) nid = srsNewFieldId(noteTypeId);
    final int ord = t.fields.isEmpty ? 0 : t.fields.last.ord + 1;
    await writeEdits(<SrsEditSpec>[
      SrsEditSpec(
        SrsEntityKind.noteType,
        noteTypeId,
        SrsFieldKeys.fieldDef(nid.id),
        SrsFieldDef(
          id: nid.id,
          name: name.trim(),
          ord: ord,
          ankiNum: nid.ankiNum,
        ).toValue(),
      ),
    ]);
    return nid.id;
  }

  /// 字段改名：只改字段定义这一项；模板正文按 fieldId 引用，一个字都不动。
  Future<void> renameField(
    String noteTypeId,
    String fieldId,
    String name,
  ) async {
    final SrsNoteTypeView t = await _requireType(noteTypeId);
    final SrsFieldDef? f = t.fieldById(fieldId);
    if (f == null) throw ArgumentError.value(fieldId, 'fieldId');
    await writeEdits(<SrsEditSpec>[
      SrsEditSpec(
        SrsEntityKind.noteType,
        noteTypeId,
        SrsFieldKeys.fieldDef(fieldId),
        f.copyWith(name: name.trim()).toValue(),
      ),
    ]);
  }

  /// 改字段说明：写独立的说明键（[SrsFieldKeys.fieldDescription]），不动字段定义。
  /// 说明没变时不写记录；清空写空串（与「从没写过」可区分，导入不会把它复活）。
  Future<void> setFieldDescription(
    String noteTypeId,
    String fieldId,
    String description,
  ) async {
    final SrsNoteTypeView t = await _requireType(noteTypeId);
    final SrsFieldDef? f = t.fieldById(fieldId);
    if (f == null) throw ArgumentError.value(fieldId, 'fieldId');
    final String next = description.trim();
    if (next == f.description) return;
    await writeEdits(<SrsEditSpec>[
      SrsEditSpec(
        SrsEntityKind.noteType,
        noteTypeId,
        SrsFieldKeys.fieldDescription(fieldId),
        next,
      ),
    ]);
  }

  /// 删字段：定义标删除，模板里对它的引用一起去掉（rslib 同语义）；笔记里残留的值读时忽略。
  /// 最后一个字段、内置字段不能删（抛 [StateError]）。
  ///
  /// [prepareTemplate]：剥引用之前先对每个模板做一次改写（app 用它把可视化模板里引用该字段
  /// 的块整块去掉、重编，免得剥完引用留下小标题 / 外框空壳）。它在校验通过**之后**、基于
  /// 这次读到的同一份笔记类型调用，结果与字段删除标记同在一次 [writeEdits] 里落库：
  /// 校验失败时什么都不写，不会出现「模板改了、字段还在」。返回 null = 这个模板不改写。
  Future<void> deleteField(
    String noteTypeId,
    String fieldId, {
    SrsTemplateDef? Function(SrsNoteTypeView type, SrsTemplateDef tpl)?
    prepareTemplate,
  }) async {
    final SrsNoteTypeView t = await _requireType(noteTypeId);
    final SrsFieldDef? f = t.fieldById(fieldId);
    if (f == null) throw ArgumentError.value(fieldId, 'fieldId');
    if (t.fields.length <= 1) {
      throw StateError('a note type needs at least one field');
    }
    if (isBuiltinField(t, fieldId)) {
      throw StateError('built-in field cannot be deleted');
    }
    await writeEdits(<SrsEditSpec>[
      SrsEditSpec(
        SrsEntityKind.noteType,
        noteTypeId,
        SrsFieldKeys.fieldDef(fieldId),
        f.copyWith(deleted: true).toValue(),
      ),
      for (final SrsTemplateDef tpl in t.templates)
        if (_templateAfterFieldDelete(t, tpl, fieldId, prepareTemplate)
            case final SrsTemplateDef next)
          SrsEditSpec(
            SrsEntityKind.noteType,
            noteTypeId,
            SrsFieldKeys.templateDef(tpl.id),
            next.toValue(),
          ),
      if (t.termFieldId == fieldId)
        SrsEditSpec(
          SrsEntityKind.noteType,
          noteTypeId,
          SrsFieldKeys.termField,
          null,
        ),
      if (t.freqFieldId == fieldId)
        SrsEditSpec(
          SrsEntityKind.noteType,
          noteTypeId,
          SrsFieldKeys.freqField,
          null,
        ),
    ]);
  }

  /// 删字段后这个模板的新定义；没变返回 null（不写记录）。
  static SrsTemplateDef? _templateAfterFieldDelete(
    SrsNoteTypeView type,
    SrsTemplateDef tpl,
    String fieldId,
    SrsTemplateDef? Function(SrsNoteTypeView type, SrsTemplateDef tpl)?
    prepareTemplate,
  ) {
    final SrsTemplateDef prepared = prepareTemplate?.call(type, tpl) ?? tpl;
    final String front = srsRemoveFieldRefs(prepared.front, fieldId);
    final String back = srsRemoveFieldRefs(prepared.back, fieldId);
    if (front == tpl.front && back == tpl.back) return null;
    return tpl.copyWith(front: front, back: back);
  }

  /// 字段调序：只给 ord 真变了的字段写记录。
  Future<void> reorderFields(String noteTypeId, List<String> fieldIds) async {
    final SrsNoteTypeView t = await _requireType(noteTypeId);
    await writeEdits(<SrsEditSpec>[
      for (final SrsFieldDef f in srsReorderFields(t.fields, fieldIds))
        SrsEditSpec(
          SrsEntityKind.noteType,
          noteTypeId,
          SrsFieldKeys.fieldDef(f.id),
          f.toValue(),
        ),
    ]);
  }

  /// 词条字段（词状态查询按它建索引）；null = 不参与词状态。
  Future<void> setTermField(String noteTypeId, String? fieldId) =>
      writeEdits(<SrsEditSpec>[
        SrsEditSpec(
          SrsEntityKind.noteType,
          noteTypeId,
          SrsFieldKeys.termField,
          fieldId,
        ),
      ]);

  /// 词频序字段（新卡按词频出卡读它）；null = 清掉显式设置，回到按字段名 `FreqSort` 认。
  Future<void> setFreqField(String noteTypeId, String? fieldId) =>
      writeEdits(<SrsEditSpec>[
        SrsEditSpec(
          SrsEntityKind.noteType,
          noteTypeId,
          SrsFieldKeys.freqField,
          fieldId,
        ),
      ]);

  Future<void> setCss(String noteTypeId, String css) =>
      writeEdits(<SrsEditSpec>[
        SrsEditSpec(SrsEntityKind.noteType, noteTypeId, SrsFieldKeys.css, css),
      ]);

  // ------------------------------------------------------------------ 模板

  /// 加模板（正文是 fieldId 引用形式）。已有笔记的新卡由各设备按需确定性生成。
  Future<String> addTemplate(
    String noteTypeId, {
    required String name,
    required String front,
    required String back,
  }) async {
    final SrsNoteTypeView t = await _requireType(noteTypeId);
    if (t.isCloze) {
      throw StateError('cloze note types have exactly one template');
    }
    final ({String id, int ankiNum}) nid = srsNewTemplateId(noteTypeId);
    final int ord = t.templates.isEmpty ? 0 : t.templates.last.ord + 1;
    await writeEdits(<SrsEditSpec>[
      SrsEditSpec(
        SrsEntityKind.noteType,
        noteTypeId,
        SrsFieldKeys.templateDef(nid.id),
        SrsTemplateDef(
          id: nid.id,
          name: name.trim(),
          ord: ord,
          front: front,
          back: back,
          ankiNum: nid.ankiNum,
        ).toValue(),
      ),
    ]);
    return nid.id;
  }

  /// 模板编辑器的一次保存：模板正文、类型 CSS、若干字段说明合成**一次** [writeEdits]（一个事务、
  /// 一次缓存刷新）。以前三类各写一次，每次各刷新一遍缓存。没变的项不写（[front] / [back] / [css]
  /// 为 null = 不改；字段说明与现值相同、或字段已不存在的跳过）。返回是否写了记录。
  Future<bool> saveTemplateEdits(
    String noteTypeId,
    String templateId, {
    String? front,
    String? back,
    String? css,
    Map<String, String> fieldDescriptions = const <String, String>{},
  }) async {
    final SrsNoteTypeView t = await _requireType(noteTypeId);
    final List<SrsEditSpec> edits = <SrsEditSpec>[];
    if (front != null || back != null) {
      final SrsTemplateDef? tpl = t.templates
          .where((SrsTemplateDef x) => x.id == templateId)
          .firstOrNull;
      if (tpl == null) throw ArgumentError.value(templateId, 'templateId');
      edits.add(
        SrsEditSpec(
          SrsEntityKind.noteType,
          noteTypeId,
          SrsFieldKeys.templateDef(templateId),
          tpl.copyWith(front: front, back: back).toValue(),
        ),
      );
    }
    if (css != null && css != t.css) {
      edits.add(
        SrsEditSpec(SrsEntityKind.noteType, noteTypeId, SrsFieldKeys.css, css),
      );
    }
    for (final MapEntry<String, String> e in fieldDescriptions.entries) {
      final SrsFieldDef? f = t.fieldById(e.key);
      final String next = e.value.trim();
      if (f == null || next == f.description) continue;
      edits.add(
        SrsEditSpec(
          SrsEntityKind.noteType,
          noteTypeId,
          SrsFieldKeys.fieldDescription(e.key),
          next,
        ),
      );
    }
    if (edits.isEmpty) return false;
    await writeEdits(edits);
    return true;
  }

  /// 改模板的名字 / 正面 / 背面（正文是 fieldId 引用形式）。
  Future<void> updateTemplate(
    String noteTypeId,
    String templateId, {
    String? name,
    String? front,
    String? back,
  }) async {
    final SrsNoteTypeView t = await _requireType(noteTypeId);
    final SrsTemplateDef? tpl = t.templates
        .where((SrsTemplateDef x) => x.id == templateId)
        .firstOrNull;
    if (tpl == null) throw ArgumentError.value(templateId, 'templateId');
    await writeEdits(<SrsEditSpec>[
      SrsEditSpec(
        SrsEntityKind.noteType,
        noteTypeId,
        SrsFieldKeys.templateDef(templateId),
        tpl.copyWith(name: name?.trim(), front: front, back: back).toValue(),
      ),
    ]);
  }

  /// 删模板：定义标删除，它的卡在查询层隐藏（复习历史保留）。最后一个模板不能删。
  Future<void> deleteTemplate(String noteTypeId, String templateId) async {
    final SrsNoteTypeView t = await _requireType(noteTypeId);
    final SrsTemplateDef? tpl = t.templates
        .where((SrsTemplateDef x) => x.id == templateId)
        .firstOrNull;
    if (tpl == null) throw ArgumentError.value(templateId, 'templateId');
    if (t.templates.length <= 1) {
      throw StateError('a note type needs at least one template');
    }
    await writeEdits(<SrsEditSpec>[
      SrsEditSpec(
        SrsEntityKind.noteType,
        noteTypeId,
        SrsFieldKeys.templateDef(templateId),
        tpl.copyWith(deleted: true).toValue(),
      ),
    ]);
  }

  Future<void> reorderTemplates(
    String noteTypeId,
    List<String> templateIds,
  ) async {
    final SrsNoteTypeView t = await _requireType(noteTypeId);
    await writeEdits(<SrsEditSpec>[
      for (final SrsTemplateDef tpl in srsReorderTemplates(
        t.templates,
        templateIds,
      ))
        SrsEditSpec(
          SrsEntityKind.noteType,
          noteTypeId,
          SrsFieldKeys.templateDef(tpl.id),
          tpl.toValue(),
        ),
    ]);
  }

  // ------------------------------------------------------------------ 更改笔记类型

  /// 这些笔记的（共同）当前类型；不是同一个类型时抛 [ArgumentError]（与 Anki 一样一次只换一种源类型）。
  Future<SrsNoteTypeView> sourceTypeOf(List<String> noteIds) async =>
      _sourceTypeIn(noteIds, await notes(noteIds));

  /// [sourceTypeOf] 在一份已读好的笔记上判（笔记按块一次预读，不逐条查）。
  Future<SrsNoteTypeView> _sourceTypeIn(
    List<String> noteIds,
    Map<String, SrsNoteView?> views,
  ) async {
    if (noteIds.isEmpty) throw ArgumentError('no notes');
    String? typeId;
    for (final String id in noteIds) {
      final SrsNoteView? n = views[id];
      if (n == null) throw ArgumentError.value(id, 'noteId', 'not found');
      if (typeId != null && typeId != n.noteTypeId) {
        throw ArgumentError('notes have different note types');
      }
      typeId = n.noteTypeId;
    }
    final SrsNoteTypeView? t = await noteType(typeId!);
    if (t == null) throw ArgumentError.value(typeId, 'noteTypeId');
    return t;
  }

  /// 预演一次更改笔记类型（不写库）。映射见 [srsPlanNoteTypeChange]。
  Future<SrsNoteTypeChangePreview> previewNoteTypeChange({
    required List<String> noteIds,
    required String targetTypeId,
    required Map<String, String?> fieldMap,
    required Map<String, String?> templateMap,
  }) async {
    // 笔记与它们的卡各按块一次读（以前每条笔记各读两遍笔记、一遍卡，BUG-3543）。
    final Map<String, SrsNoteView?> views = await notes(noteIds);
    final SrsNoteTypeView from = await _sourceTypeIn(noteIds, views);
    final SrsNoteTypeView to = await _requireType(targetTypeId);
    final Map<String, List<SrsCardCacheRow>> cards = await cardsOfNotes(
      noteIds,
    );
    final List<SrsNoteTypeChangePlan> plans = <SrsNoteTypeChangePlan>[];
    for (final String id in noteIds) {
      final SrsNoteView n = views[id]!;
      plans.add(
        srsPlanNoteTypeChange(
          note: n,
          from: from,
          to: to,
          fieldMap: fieldMap,
          templateMap: templateMap,
          existingCards: <SrsExistingCard>[
            for (final SrsCardCacheRow c in cards[id]!)
              SrsExistingCard(
                cardId: c.id,
                templateId: c.templateId,
                clozeOrd: c.clozeOrd,
                hidden: c.hidden,
              ),
          ],
        ),
      );
    }
    return SrsNoteTypeChangePreview(from: from, to: to, plans: plans);
  }

  /// 执行更改笔记类型：一个事务写完全部笔记的类型键、字段值与新卡的前身链接。
  /// 复习日志一条不改；新卡的历史 = 自己 + 前身卡的日志（见 [SrsDbStore.history]）。
  /// 预演与写入在同一个独占区里：算计划时读到的现值就是落库时的现值。
  Future<void> changeNoteType({
    required List<String> noteIds,
    required String targetTypeId,
    required Map<String, String?> fieldMap,
    required Map<String, String?> templateMap,
  }) => runExclusive(() async {
    final SrsNoteTypeChangePreview p = await previewNoteTypeChange(
      noteIds: noteIds,
      targetTypeId: targetTypeId,
      fieldMap: fieldMap,
      templateMap: templateMap,
    );
    if (p.from.id == p.to.id) return;
    await sync2Checkpoint(p.to.name, 'note_type');
    await writeEdits(<SrsEditSpec>[
      for (final SrsNoteTypeChangePlan plan in p.plans) ...<SrsEditSpec>[
        SrsEditSpec(
          SrsEntityKind.note,
          plan.noteId,
          SrsFieldKeys.noteType,
          p.to.id,
        ),
        for (final MapEntry<String, String> f in plan.fieldValues.entries)
          SrsEditSpec(
            SrsEntityKind.note,
            plan.noteId,
            SrsFieldKeys.noteField(f.key),
            f.value,
          ),
        for (final MapEntry<String, String> l in plan.cardLinks.entries)
          SrsEditSpec(
            SrsEntityKind.card,
            l.key,
            SrsFieldKeys.cardHistoryFrom(l.value),
            true,
          ),
      ],
    ]);
  });
}
