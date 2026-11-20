/// TTS 文本处理规则（发音词典 / 合成前替换 / 识别后替换）的界面：一个三行入口分组
/// [TtsTextRulesSection]（「制作有声书」页用）与一类规则的编辑页 [TtsTextRulesPage]
/// （设置 › 语音合成 与制作台都推它）。
///
/// 数据只有一份：[TtsTextRulesStore]（`TtsServices.textRules`，偏好表里每类一个
/// JSON 键）。两处界面都是它的视图：保存后经 [TtsTextRulesStore.changes] 通知，
/// 另一处重读，不各存一份再互相同步。
library;

import 'dart:async';

import 'package:fushi_engine/tts/tts_pronunciation.dart';
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
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 一类规则的名称。
String ttsTextRuleKindTitle(TtsTextRuleKind kind) => switch (kind) {
  TtsTextRuleKind.pronunciation => t.audiobook_studio_pronunciation,
  TtsTextRuleKind.preSynthesis => t.tts_text_rules_pre_synthesis,
  TtsTextRuleKind.postRecognition => t.tts_text_rules_post_recognition,
};

/// 一类规则的说明（带例子）。
String ttsTextRuleKindHint(TtsTextRuleKind kind) => switch (kind) {
  TtsTextRuleKind.pronunciation => t.audiobook_studio_pronunciation_hint,
  TtsTextRuleKind.preSynthesis => t.tts_text_rules_pre_synthesis_hint,
  TtsTextRuleKind.postRecognition => t.tts_text_rules_post_recognition_hint,
};

IconData ttsTextRuleKindIcon(TtsTextRuleKind kind) => switch (kind) {
  TtsTextRuleKind.pronunciation => FushiIcons.dictionary,
  TtsTextRuleKind.preSynthesis => FushiIcons.swap,
  TtsTextRuleKind.postRecognition => FushiIcons.swapCircle,
};

/// 规则两栏的标签（左 → 右）。
({String from, String to}) _ttsTextRuleLabels(TtsTextRuleKind kind) =>
    switch (kind) {
      TtsTextRuleKind.pronunciation => (
        from: t.audiobook_studio_pronunciation_written,
        to: t.audiobook_studio_pronunciation_spoken,
      ),
      TtsTextRuleKind.preSynthesis => (
        from: t.tts_substitutions_source,
        to: t.tts_substitutions_replacement,
      ),
      TtsTextRuleKind.postRecognition => (
        from: t.tts_text_rules_heard,
        to: t.tts_text_rules_restore,
      ),
    };

/// 入口行的副标题：没有规则时是说明，有规则时「n 条 · 第一条」。
String ttsTextRulesSummary(
  TtsTextRuleKind kind,
  List<TtsPronunciationRule> rules,
) {
  if (rules.isEmpty) return ttsTextRuleKindHint(kind);
  final TtsPronunciationRule first = rules.first;
  return '${t.tts_text_rules_count(n: rules.length)} · '
      '${first.written} → ${_shownTarget(first.spoken)}';
}

/// 替换成空串的规则显示为 ∅（与系列用词替换表一致）。
String _shownTarget(String spoken) => spoken.isEmpty ? '∅' : spoken;

/// 推一类规则的编辑页。
Future<void> openTtsTextRulesPage(
  BuildContext context,
  TtsTextRulesStore store,
  TtsTextRuleKind kind,
) => Navigator.of(context).push<void>(
  MaterialPageRoute<void>(
    builder: (_) => TtsTextRulesPage(store: store, kind: kind),
  ),
);

/// 「文本处理」分组：三类规则各一行（条数 + 第一条），点开编辑页。任一处保存后自动
/// 刷新。
class TtsTextRulesSection extends StatefulWidget {
  const TtsTextRulesSection({required this.store, super.key});

  final TtsTextRulesStore store;

  @override
  State<TtsTextRulesSection> createState() => _TtsTextRulesSectionState();
}

class _TtsTextRulesSectionState extends State<TtsTextRulesSection> {
  StreamSubscription<TtsTextRuleKind>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.store.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget chevron = isGlassDesign(context)
        ? const FushiAppleChevron()
        : FushiIcon(
            FushiIcons.chevronRight,
            size: 20,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          );
    return AdaptiveSettingsSection(
      key: const ValueKey<String>('tts-text-rules'),
      title: t.tts_text_rules_section,
      children: <Widget>[
        for (final TtsTextRuleKind kind in TtsTextRuleKind.values)
          FushiPressScale(
            child: AdaptiveSettingsRow(
              key: ValueKey<String>('tts-text-rules-${kind.name}'),
              icon: ttsTextRuleKindIcon(kind),
              showIcon: true,
              title: ttsTextRuleKindTitle(kind),
              subtitle: ttsTextRulesSummary(kind, widget.store.load(kind)),
              trailing: chevron,
              onTap: () =>
                  unawaited(openTtsTextRulesPage(context, widget.store, kind)),
            ),
          ),
      ],
    );
  }
}

/// 一类规则的编辑页：增删改立刻落盘（[TtsTextRulesStore.save]）。
class TtsTextRulesPage extends StatefulWidget {
  const TtsTextRulesPage({required this.store, required this.kind, super.key});

  final TtsTextRulesStore store;
  final TtsTextRuleKind kind;

  @override
  State<TtsTextRulesPage> createState() => _TtsTextRulesPageState();
}

class _TtsTextRulesPageState extends State<TtsTextRulesPage> {
  late List<TtsPronunciationRule> _rules = widget.store.load(widget.kind);
  StreamSubscription<TtsTextRuleKind>? _sub;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.store.changes.listen((TtsTextRuleKind kind) {
      if (kind != widget.kind || !mounted) return;
      setState(() => _rules = widget.store.load(widget.kind));
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  Future<void> _commit(List<TtsPronunciationRule> next) async {
    if (_saving) return;
    final List<TtsPronunciationRule> previous = _rules;
    setState(() {
      _rules = next;
      _saving = true;
    });
    try {
      await widget.store.save(widget.kind, next);
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsTextRules.save', e, stack);
      FushiToast.show(msg: t.audiobook_studio_failure_internal);
      if (mounted) setState(() => _rules = previous);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit([int? index]) async {
    final TtsPronunciationRule? edited =
        await showAppDialog<TtsPronunciationRule>(
          context: context,
          builder: (_) => TtsTextRuleDialog(
            kind: widget.kind,
            initial: index == null ? null : _rules[index],
          ),
        );
    if (edited == null || !mounted) return;
    final List<TtsPronunciationRule> next = List<TtsPronunciationRule>.of(
      _rules,
    );
    if (index == null) {
      next.add(edited);
    } else {
      next[index] = edited;
    }
    await _commit(next);
  }

  Future<void> _delete(int index) =>
      _commit(List<TtsPronunciationRule>.of(_rules)..removeAt(index));

  Widget _header() => AdaptiveSettingsSection(
    key: const ValueKey<String>('tts-text-rules-header'),
    children: <Widget>[
      AdaptiveSettingsRow(
        key: const ValueKey<String>('tts-text-rules-hint'),
        icon: FushiIcons.info,
        showIcon: true,
        title: ttsTextRuleKindHint(widget.kind),
        titleMaxLines: 6,
        subtitle: widget.kind == TtsTextRuleKind.postRecognition
            ? t.tts_text_rules_post_recognition_applies
            : t.tts_substitutions_rerender_hint,
      ),
      AdaptiveSettingsRow(
        key: const ValueKey<String>('tts-text-rules-add'),
        icon: FushiIcons.add,
        showIcon: true,
        title: t.audiobook_studio_pronunciation_add,
        onTap: _saving ? null : () => unawaited(_edit()),
      ),
    ],
  );

  Widget _row(int index) {
    final TtsPronunciationRule rule = _rules[index];
    return FushiPressScale(
      enabled: !_saving,
      child: FushiListItem(
        key: ValueKey<String>('tts-text-rule-$index'),
        leading: FushiIcon(ttsTextRuleKindIcon(widget.kind)),
        title: Text('${rule.written}  →  ${_shownTarget(rule.spoken)}'),
        onTap: _saving ? null : () => unawaited(_edit(index)),
        trailing: FushiIconButtonControl(
          key: ValueKey<String>('tts-text-rule-$index-delete'),
          tooltip: t.dialog_delete,
          icon: const FushiIcon(FushiIcons.delete),
          onPressed: _saving ? null : () => unawaited(_delete(index)),
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
    final int extra = _rules.isEmpty ? 2 : 1;
    return SettingsKitScaffold(
      title: ttsTextRuleKindTitle(widget.kind),
      leadingIcon: ttsTextRuleKindIcon(widget.kind),
      leadingTone: SettingsIconTone.purple,
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) => FushiEntranceScope(
            child: ListView.builder(
              key: const ValueKey<String>('tts-text-rules-list'),
              controller: controller,
              padding: EdgeInsets.fromLTRB(
                inset,
                tokens.spacing.gap + MediaQuery.paddingOf(context).top,
                inset,
                tokens.spacing.page + bottomSafeInsetOf(context),
              ),
              itemCount: _rules.length + extra,
              itemBuilder: fushiStaggeredItemBuilder((
                BuildContext context,
                int index,
              ) {
                if (index == 0) return _header();
                if (_rules.isEmpty) {
                  return Padding(
                    key: const ValueKey<String>('tts-text-rules-empty'),
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      t.tts_substitutions_empty,
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                return _row(index - 1);
              }),
            ),
          ),
    );
  }
}

/// 一条规则的编辑对话框（左栏必填；发音词典的读法也必填，替换类可以替换成空）。
class TtsTextRuleDialog extends StatefulWidget {
  const TtsTextRuleDialog({required this.kind, this.initial, super.key});

  final TtsTextRuleKind kind;
  final TtsPronunciationRule? initial;

  @override
  State<TtsTextRuleDialog> createState() => _TtsTextRuleDialogState();
}

class _TtsTextRuleDialogState extends State<TtsTextRuleDialog> {
  late final TextEditingController _written = TextEditingController(
    text: widget.initial?.written ?? '',
  );
  late final TextEditingController _spoken = TextEditingController(
    text: widget.initial?.spoken ?? '',
  );

  @override
  void dispose() {
    _written.dispose();
    _spoken.dispose();
    super.dispose();
  }

  bool get _valid =>
      _written.text.trim().isNotEmpty &&
      (widget.kind != TtsTextRuleKind.pronunciation ||
          _spoken.text.trim().isNotEmpty);

  void _submit() {
    if (!_valid) return;
    Navigator.of(context).pop(
      TtsPronunciationRule(
        written: _written.text.trim(),
        spoken: _spoken.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ({String from, String to}) labels = _ttsTextRuleLabels(widget.kind);
    return FushiAlertDialog(
      icon: FushiDialogHeroIcon(icon: ttsTextRuleKindIcon(widget.kind)),
      title: Text(
        widget.initial == null
            ? t.audiobook_studio_pronunciation_add
            : ttsTextRuleKindTitle(widget.kind),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiTextFormFieldControl(
            key: const ValueKey<String>('tts-text-rule-written'),
            controller: _written,
            autofocus: true,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: labels.from,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          FushiTextFormFieldControl(
            key: const ValueKey<String>('tts-text-rule-spoken'),
            controller: _spoken,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: labels.to,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
            onFieldSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.dialog_cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FushiDialogAction(
          label: t.dialog_ok,
          kind: FushiDialogActionKind.primary,
          onPressed: _valid ? _submit : null,
        ),
      ],
    );
  }
}
