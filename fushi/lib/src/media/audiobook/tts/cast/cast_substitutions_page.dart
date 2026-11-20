/// 系列用词替换表的编辑页（小说制作台的系列分组、漫画有声制作台的系列分组共用）。
///
/// 每行「原文写法 → 替换为」+ 启用开关；逐条显示 [validateCastSubstitutions] 的问题。
/// 每次改动立刻经 [CastSubstitutionsPage.save] 落盘（调用方走
/// `SeriesCastStore.update`，在最新的系列档案上替换整张表），页面换上存盘后的表。
///
/// 表只作用于生成端实际念的文字与成品字幕 / cue 文本（见 `cast_text_substitution.dart`）：
/// 原文、AI 标注输入、手动填写的念法都不经过它。文字变了的句子缓存键随之变，下次
/// 生成自然重做。
library;

import 'dart:async';

import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart'
    show GlassSettingsRenderer;
import 'package:fushi/src/settings/settings_kit_core.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 系列分组里那一行的摘要（条数 / 无）。
String castSubstitutionsSummary(List<CastTextSubstitution> table) =>
    table.isEmpty
    ? t.tts_substitutions_none
    : t.tts_substitutions_summary(n: table.length);

/// 一条的问题文案。
String castSubstitutionProblemText(CastSubstitutionProblem problem) =>
    switch (problem) {
      CastSubstitutionProblem.emptySource => t.tts_substitutions_problem_empty,
      CastSubstitutionProblem.duplicateSource =>
        t.tts_substitutions_problem_duplicate,
      CastSubstitutionProblem.lineBreak =>
        t.tts_substitutions_problem_line_break,
    };

class CastSubstitutionsPage extends StatefulWidget {
  const CastSubstitutionsPage({
    required this.seriesTitle,
    required this.initial,
    required this.save,
    super.key,
  });

  final String seriesTitle;
  final List<CastTextSubstitution> initial;

  /// 把整张表写进系列档案，返回存盘后的表。
  final Future<List<CastTextSubstitution>> Function(
    List<CastTextSubstitution> next,
  )
  save;

  @override
  State<CastSubstitutionsPage> createState() => _CastSubstitutionsPageState();
}

class _CastSubstitutionsPageState extends State<CastSubstitutionsPage> {
  late List<CastTextSubstitution> _table = List<CastTextSubstitution>.of(
    widget.initial,
  );
  bool _saving = false;

  Future<void> _commit(List<CastTextSubstitution> next) async {
    if (_saving) return;
    final List<CastTextSubstitution> previous = _table;
    setState(() {
      _table = next;
      _saving = true;
    });
    try {
      final List<CastTextSubstitution> saved = await widget.save(next);
      if (mounted) {
        setState(() => _table = List<CastTextSubstitution>.of(saved));
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('CastSubstitutions.save', e, stack);
      FushiToast.show(msg: t.audiobook_studio_failure_internal);
      if (mounted) setState(() => _table = previous);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 问一条（原文 → 替换）；取消返回 null。
  Future<CastTextSubstitution?> _ask(CastTextSubstitution? current) async {
    final String? source = await showFushiTextInputDialog(
      context: context,
      title: t.tts_substitutions_source,
      initialValue: current?.source ?? '',
      labelText: t.tts_substitutions_source,
      icon: FushiIcons.edit,
      trim: false,
    );
    if (source == null || source.isEmpty || !mounted) return null;
    final String? replacement = await showFushiTextInputDialog(
      context: context,
      title: t.tts_substitutions_replacement,
      message: source,
      initialValue: current?.replacement ?? '',
      labelText: t.tts_substitutions_replacement,
      icon: FushiIcons.edit,
      allowEmpty: true,
      trim: false,
    );
    if (replacement == null || !mounted) return null;
    return CastTextSubstitution(
      source: source,
      replacement: replacement,
      enabled: current?.enabled ?? true,
    );
  }

  Future<void> _add() async {
    final CastTextSubstitution? added = await _ask(null);
    if (added == null) return;
    await _commit(<CastTextSubstitution>[..._table, added]);
  }

  Future<void> _edit(int index) async {
    final CastTextSubstitution? edited = await _ask(_table[index]);
    if (edited == null) return;
    await _commit(List<CastTextSubstitution>.of(_table)..[index] = edited);
  }

  Future<void> _toggle(int index, bool enabled) {
    final CastTextSubstitution e = _table[index];
    return _commit(
      List<CastTextSubstitution>.of(_table)
        ..[index] = CastTextSubstitution(
          source: e.source,
          replacement: e.replacement,
          enabled: enabled,
        ),
    );
  }

  Future<void> _delete(int index) =>
      _commit(List<CastTextSubstitution>.of(_table)..removeAt(index));

  Widget _header() => AdaptiveSettingsSection(
    key: const ValueKey<String>('tts-substitutions-header'),
    title: widget.seriesTitle,
    children: <Widget>[
      AdaptiveSettingsRow(
        key: const ValueKey<String>('tts-substitutions-hint'),
        icon: FushiIcons.info,
        showIcon: true,
        title: t.tts_substitutions_hint,
        titleMaxLines: 6,
        subtitle: t.tts_substitutions_rerender_hint,
      ),
      AdaptiveSettingsRow(
        key: const ValueKey<String>('tts-substitutions-add'),
        icon: FushiIcons.add,
        showIcon: true,
        title: t.tts_substitutions_add,
        onTap: _saving ? null : () => unawaited(_add()),
      ),
    ],
  );

  Widget _row(int index, CastSubstitutionProblem? problem) {
    final CastTextSubstitution e = _table[index];
    final String replacement = e.replacement.isEmpty ? '∅' : e.replacement;
    return FushiPressScale(
      enabled: !_saving,
      child: FushiListItem(
        key: ValueKey<String>('tts-substitution-$index'),
        leading: FushiIcon(
          problem == null ? FushiIcons.swap : FushiIcons.warning,
        ),
        title: Text('${e.source}  →  $replacement'),
        subtitle: problem == null
            ? null
            : Text(castSubstitutionProblemText(problem)),
        onTap: _saving ? null : () => unawaited(_edit(index)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Semantics(
              label: t.tts_substitutions_enabled,
              child: FushiSwitch(
                key: ValueKey<String>('tts-substitution-$index-enabled'),
                value: e.enabled,
                onChanged: _saving
                    ? null
                    : (bool v) => unawaited(_toggle(index, v)),
              ),
            ),
            FushiIconButtonControl(
              key: ValueKey<String>('tts-substitution-$index-delete'),
              tooltip: t.tts_substitutions_delete,
              icon: const FushiIcon(FushiIcons.delete),
              onPressed: _saving ? null : () => unawaited(_delete(index)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double inset = isGlassDesign(context)
        ? GlassSettingsRenderer.detailHorizontalInset(context)
        : tokens.spacing.page;
    final Map<int, CastSubstitutionProblem> problems =
        validateCastSubstitutions(_table);
    final int extra = _table.isEmpty ? 2 : 1;
    return SettingsKitScaffold(
      title: t.tts_substitutions_title,
      leadingIcon: FushiIcons.swap,
      leadingTone: SettingsIconTone.purple,
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) => FushiEntranceScope(
            child: ListView.builder(
              key: const ValueKey<String>('tts-substitutions-list'),
              controller: controller,
              padding: EdgeInsets.fromLTRB(
                inset,
                tokens.spacing.gap + MediaQuery.paddingOf(context).top,
                inset,
                tokens.spacing.page + bottomSafeInsetOf(context),
              ),
              itemCount: _table.length + extra,
              itemBuilder: fushiStaggeredItemBuilder((
                BuildContext context,
                int index,
              ) {
                if (index == 0) return _header();
                if (_table.isEmpty) {
                  return Padding(
                    key: const ValueKey<String>('tts-substitutions-empty'),
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      t.tts_substitutions_empty,
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                return _row(index - 1, problems[index - 1]);
              }),
            ),
          ),
    );
  }
}
