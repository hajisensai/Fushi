/// 内置笔记类型（Lapis、Fushi 卡片）的「恢复内置模板」（[SrsDbStore] 的扩展）。
///
/// 内置类型的模板正文 / CSS 被改过（自己改的、回滚笔记带回的旧版、别的设备同步来的）之后，这几项由修改记录决定、
/// 不再跟随代码。Fushi 卡片的原生卡面判据要求正面、背面、CSS 与代码定义逐字一致
/// （srs_fushi_card_native_media.dart 的 `srsFushiCardNative`）：有一处不一致就退回整面 WebView（背面只调区块布局除外），
/// 外观页的原生选项全部不生效。这里给出一条命令把它们写回代码定义。
///
/// 写法与别的笔记类型编辑相同：经 [SrsDbStore.writeEdits] 写成修改记录（随同步发布、按项合并）。恢复前的值作为
/// [SrsBuiltinTemplateRestore] 交回调用方，[SrsBuiltinTemplateRestoreOps.undoBuiltinTemplateRestore] 再写一次
/// 修改记录把它们放回去（撤销同样会同步）。
library;

import 'package:fushi_srs/fushi_srs.dart';

import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';

/// 一次恢复写下的前后值（撤销用）。
class SrsBuiltinTemplateRestore {
  const SrsBuiltinTemplateRestore({
    required this.noteTypeId,
    required this.previousTemplates,
    required this.previousCss,
  });

  final String noteTypeId;

  /// 被改写的模板在恢复前的定义（恢复时还不存在的内置模板记成 null：撤销时标回删除）。
  final Map<String, SrsTemplateDef?> previousTemplates;

  /// 恢复前的 CSS；CSS 没变时为 null。
  final String? previousCss;
}

extension SrsBuiltinTemplateRestoreOps on SrsDbStore {
  /// [t] 的模板正文 / CSS 是否偏离了内置定义（不是内置类型时为 false）。
  ///
  /// 只看内置模板（按 ID）与 CSS：用户另加的模板不算偏离，恢复也不动它们。
  bool builtinTemplatesModified(SrsNoteTypeView t) =>
      _restoreSpecs(t).isNotEmpty;

  /// 把内置笔记类型 [noteTypeId] 的内置模板正面 / 背面与 CSS 写回代码定义（模板名、顺序、用户另加的模板不动；
  /// 被删掉的内置模板恢复出来）。不是内置类型时抛 [ArgumentError]；已经与内置一致时不写、返回 null。
  Future<SrsBuiltinTemplateRestore?> restoreBuiltinTemplates(
    String noteTypeId,
  ) async {
    final SrsNoteTypeView t = await _requireBuiltinType(noteTypeId);
    final List<_RestoreSpec> specs = _restoreSpecs(t);
    if (specs.isEmpty) return null;
    await writeEdits(<SrsEditSpec>[for (final _RestoreSpec s in specs) s.edit]);
    return SrsBuiltinTemplateRestore(
      noteTypeId: noteTypeId,
      previousTemplates: <String, SrsTemplateDef?>{
        for (final _RestoreSpec s in specs)
          if (s.templateId != null) s.templateId!: s.previousTemplate,
      },
      previousCss: specs
          .where((_RestoreSpec s) => s.templateId == null)
          .firstOrNull
          ?.previousCss,
    );
  }

  /// 撤销一次 [restoreBuiltinTemplates]：把恢复前的模板定义与 CSS 写回去（新的修改记录，随同步发布）。
  Future<void> undoBuiltinTemplateRestore(
    SrsBuiltinTemplateRestore restore,
  ) async {
    final SrsNoteTypeView t = await _requireBuiltinType(restore.noteTypeId);
    final List<SrsEditSpec> edits = <SrsEditSpec>[];
    for (final MapEntry<String, SrsTemplateDef?> e
        in restore.previousTemplates.entries) {
      SrsTemplateDef? previous = e.value;
      if (previous == null) {
        // 恢复前没有这个模板：撤销 = 把恢复出来的那份标回删除。
        final SrsTemplateDef? now = _definedTemplate(t, e.key);
        if (now == null) continue;
        previous = now.copyWith(deleted: true);
      }
      edits.add(
        SrsEditSpec(
          SrsEntityKind.noteType,
          t.id,
          SrsFieldKeys.templateDef(e.key),
          previous.toValue(),
        ),
      );
    }
    final String? css = restore.previousCss;
    if (css != null) {
      edits.add(
        SrsEditSpec(SrsEntityKind.noteType, t.id, SrsFieldKeys.css, css),
      );
    }
    if (edits.isNotEmpty) await writeEdits(edits);
  }

  Future<SrsNoteTypeView> _requireBuiltinType(String id) async {
    final SrsNoteTypeView? t = await noteType(id);
    if (t == null || t.deletedAt != null) {
      throw ArgumentError.value(id, 'noteTypeId', 'note type not found');
    }
    if (srsBuiltinNoteTypeForKey(profileUid, t.builtinKey) == null) {
      throw ArgumentError.value(id, 'noteTypeId', 'not a built-in note type');
    }
    return t;
  }

  /// [t] 里 ID 为 [id] 的模板定义（含已删除的）。
  SrsTemplateDef? _definedTemplate(SrsNoteTypeView t, String id) {
    for (final SrsTemplateDef x in t.templates) {
      if (x.id == id) return x;
    }
    for (final SrsTemplateDef x in t.definedTemplates) {
      if (x.id == id) return x;
    }
    return null;
  }

  /// 要写回内置定义的那几项（与内置一致的不写）。
  List<_RestoreSpec> _restoreSpecs(SrsNoteTypeView t) {
    final SrsBuiltinNoteType? builtin = srsBuiltinNoteTypeForKey(
      profileUid,
      t.builtinKey,
    );
    if (builtin == null) return const <_RestoreSpec>[];
    final List<_RestoreSpec> out = <_RestoreSpec>[];
    for (final SrsTemplateDef b in builtin.templates) {
      final SrsTemplateDef? current = _definedTemplate(t, b.id);
      if (current != null &&
          !current.deleted &&
          current.front == b.front &&
          current.back == b.back) {
        continue;
      }
      final SrsTemplateDef next =
          current?.copyWith(front: b.front, back: b.back, deleted: false) ?? b;
      out.add(
        _RestoreSpec(
          edit: SrsEditSpec(
            SrsEntityKind.noteType,
            t.id,
            SrsFieldKeys.templateDef(b.id),
            next.toValue(),
          ),
          templateId: b.id,
          previousTemplate: current,
        ),
      );
    }
    if (t.css != builtin.css) {
      out.add(
        _RestoreSpec(
          edit: SrsEditSpec(
            SrsEntityKind.noteType,
            t.id,
            SrsFieldKeys.css,
            builtin.css,
          ),
          previousCss: t.css,
        ),
      );
    }
    return out;
  }
}

class _RestoreSpec {
  const _RestoreSpec({
    required this.edit,
    this.templateId,
    this.previousTemplate,
    this.previousCss,
  });

  final SrsEditSpec edit;

  /// 模板项的模板 ID；CSS 项为 null。
  final String? templateId;
  final SrsTemplateDef? previousTemplate;
  final String? previousCss;
}
