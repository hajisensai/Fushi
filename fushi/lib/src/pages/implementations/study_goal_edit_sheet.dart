/// 添加 / 编辑一条学习目标的面板（设计 A「目标列表」，mockup 第二屏）。
///
/// 四段（第五轮）：统计什么（度量 chip）→ 哪种语言（全部 + 候选语言 + 「其他…」，
/// 中文另有简 / 繁一排；复习 / 制卡不分语言，整段隐藏）→ 多少（数字框 + 校验提示 +
/// 按语言 / 单位的参考预设 + 「近 7 天」参考）→ 多久一次（日 / 周 / 月分段 + 一句话
/// 说明；每日目标另有生效日），保存；编辑时另有删除。
///
/// 设置 › 目标、首页「今日」格（经典外观的「设定目标」）、「语言目标」格的空态都开这一个
/// 面板（2026-11 起取代字数目标对话框 `StatGoalEditDialog`）。
library;

import 'dart:async';

import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, TextInputFormatter;
import 'package:intl/date_symbol_data_local.dart' show dateTimeSymbolMap;
import 'package:intl/date_symbols.dart' show DateSymbols;
import 'package:intl/intl.dart' show Intl;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/stats/study_goal_host.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart'
    show formatStatCharsAxis;
import 'package:fushi/src/stats/stat_format.dart' show formatStatTime;
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/stats/study_goal_language_scope.dart';
import 'package:fushi/src/stats/study_goal_record.dart';
import 'package:fushi/src/stats/study_goals.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/content_language_picker.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiModalSheetFrame;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart'
    show FushiConnectedButtonGroup;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show FushiSnackBar;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/stats/study_goal_language.dart';

/// 度量的图标（设置行、面板 chip 共用）。
IconData studyGoalMetricIcon(StudyGoalId metric) => switch (metric) {
  StudyGoalId.total => FushiIcons.timer,
  StudyGoalId.reading => FushiIcons.books,
  StudyGoalId.listening => FushiIcons.audio,
  StudyGoalId.watching => FushiIcons.video,
  StudyGoalId.reviews => FushiIcons.replay,
  StudyGoalId.mined => FushiIcons.ankiCard,
  StudyGoalId.chars => FushiIcons.textFields,
};

/// 星期几的名字（[weekday] 为 `DateTime.monday`..`sunday`，跟随界面语言；[short] =
/// 缩写「周一」「Mon」）。直接读 intl 自带的同步日期符号表：`DateFormat` 要先异步
/// `initializeDateFormatting`，设置行 / 面板的 build 里等不了。
String studyGoalWeekdayName(int weekday, {bool short = false}) {
  final Map<dynamic, dynamic> symbols = dateTimeSymbolMap();
  final String locale = Intl.verifiedLocale(
    LocaleSettings.currentLocale.languageTag.replaceAll('-', '_'),
    symbols.containsKey,
    onFailure: (_) => 'en',
  )!;
  final DateSymbols data = symbols[locale] as DateSymbols;
  // 符号表的星期从周日起。
  final List<String> names = short ? data.SHORTWEEKDAYS : data.WEEKDAYS;
  return names[weekday % 7];
}

/// 时长目标（分钟）的上限：一个周期的总时长（月按 31 天）。
const int kStudyGoalMaxMinutesDaily = 24 * 60;
const int kStudyGoalMaxMinutesWeekly = 7 * 24 * 60;
const int kStudyGoalMaxMinutesMonthly = 31 * 24 * 60;

/// 面板里度量 chip 的顺序（mockup：字数在前）。
const List<StudyGoalId> kStudyGoalSheetMetrics = <StudyGoalId>[
  StudyGoalId.chars,
  StudyGoalId.total,
  StudyGoalId.reading,
  StudyGoalId.listening,
  StudyGoalId.watching,
  StudyGoalId.reviews,
  StudyGoalId.mined,
];

/// 面板要的异步数据：候选语言与「近 7 天」参考的日面。
class StudyGoalSheetData {
  const StudyGoalSheetData({
    required this.candidateLanguages,
    required this.daily,
    required this.mediaLanguages,
    required this.window,
  });

  final List<String> candidateLanguages;
  final List<StatFact> daily;
  final Map<String, String> mediaLanguages;
  final StatWindow window;
}

/// 默认的数据加载：候选语言（[loadStudyGoalCandidateLanguages]）+ 本 Profile 的日面 +
/// 媒体语言表。
Future<StudyGoalSheetData> loadStudyGoalSheetData(
  StudyGoalHost appModel,
) async {
  final StatWindow window = StatWindow(DateTime.now());
  final List<String> candidates = await loadStudyGoalCandidateLanguages(
    appModel.database,
    appModel.prefsRepo,
  );
  final StatFacts facts = await loadStatFacts(
    appModel.database,
    activityLimit: 0,
  );
  final Map<String, String> media = await loadStudyGoalMediaLanguages(
    appModel.database,
  );
  return StudyGoalSheetData(
    candidateLanguages: candidates,
    daily: facts.daily,
    mediaLanguages: media,
    window: window,
  );
}

/// 面板关掉后的结果。
enum StudyGoalSheetResult { saved, deleted }

/// 弹出面板。[goal] 非空 = 编辑这条；否则新建，[metric] / [period] / [language] 是
/// 预填（例如「语言目标」格空态预填它的语言）。保存 / 删除已写穿偏好后返回结果，
/// 关掉返回 null。
///
/// 删除立即生效，随后弹「已删除目标 · 撤销」提示条：撤销把这条记录放回原来的位置
/// （[StudyGoalHost.insertStudyGoal]），之后调 [onRestored]（设置页借它重建行）。
Future<StudyGoalSheetResult?> showStudyGoalEditSheet(
  BuildContext context,
  StudyGoalHost appModel, {
  StudyGoal? goal,
  StudyGoalId metric = StudyGoalId.chars,
  StudyGoalPeriod period = StudyGoalPeriod.daily,
  String? language,
  Future<StudyGoalSheetData> Function(StudyGoalHost appModel)? loadData,
  VoidCallback? onRestored,
}) async {
  // 面板关掉后调用方的 context 可能已失效（设置行随删除消失）：先拿住提示条宿主。
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  final Object? outcome = await adaptiveModalSheet<Object?>(
    context: context,
    builder: (BuildContext sheetContext) => StudyGoalEditSheet(
      appModel: appModel,
      goal: goal,
      initialMetric: metric,
      initialPeriod: period,
      initialLanguage: language,
      data: (loadData ?? loadStudyGoalSheetData)(appModel),
      onSave: (StudyGoal g) => Navigator.of(sheetContext).pop(g),
      onDelete: () => Navigator.of(sheetContext).pop(_SheetOutcome.delete),
    ),
  );
  if (outcome == _SheetOutcome.delete && goal != null) {
    final int index = appModel.studyGoals.indexWhere(
      (StudyGoal g) => g.id == goal.id,
    );
    await appModel.removeStudyGoal(goal.id);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        FushiSnackBar(
          key: const ValueKey<String>('study-goal-deleted-snackbar'),
          content: Text(t.study_goal_deleted),
          // 带动作的提示条默认常驻：撤销窗口过了就自己收起，不钉在之后的页面底部。
          persist: false,
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            key: const ValueKey<String>('study-goal-undo-delete'),
            label: t.undo,
            onPressed: () => unawaited(() async {
              await appModel.insertStudyGoal(goal, index < 0 ? 0 : index);
              onRestored?.call();
            }()),
          ),
        ),
      );
    return StudyGoalSheetResult.deleted;
  }
  if (outcome is! StudyGoal) return null;
  if (goal != null) {
    await appModel.updateStudyGoal(outcome);
  } else {
    await appModel.addStudyGoal(outcome);
  }
  return StudyGoalSheetResult.saved;
}

/// 面板「删除」pop 出来的值（保存 pop 的是 [StudyGoal]）。
enum _SheetOutcome { delete }

class StudyGoalEditSheet extends StatefulWidget {
  const StudyGoalEditSheet({
    super.key,
    required this.appModel,
    required this.data,
    required this.onSave,
    required this.onDelete,
    this.goal,
    this.initialMetric = StudyGoalId.chars,
    this.initialPeriod = StudyGoalPeriod.daily,
    this.initialLanguage,
  });

  final StudyGoalHost appModel;
  final Future<StudyGoalSheetData> data;
  final StudyGoal? goal;
  final StudyGoalId initialMetric;
  final StudyGoalPeriod initialPeriod;
  final String? initialLanguage;
  final ValueChanged<StudyGoal> onSave;
  final VoidCallback onDelete;

  @override
  State<StudyGoalEditSheet> createState() => _StudyGoalEditSheetState();
}

class _StudyGoalEditSheetState extends State<StudyGoalEditSheet> {
  late StudyGoalId _metric = widget.goal?.metric ?? widget.initialMetric;
  late StudyGoalPeriod _period = widget.goal?.period ?? widget.initialPeriod;
  late String? _language = widget.goal?.language ?? widget.initialLanguage;
  late Set<int> _days = <int>{...?widget.goal?.activeWeekdays};
  late final TextEditingController _target = TextEditingController(
    text: '${widget.goal?.target ?? _presets.elementAt(1)}',
  );

  /// 用户在本次面板里经「其他…」选过的语言（加进候选 chip）。
  final List<String> _extraLanguages = <String>[];
  StudyGoalSheetData? _data;

  @override
  void initState() {
    super.initState();
    _target.addListener(_onTargetChanged);
    unawaited(
      widget.data.then((StudyGoalSheetData d) {
        if (mounted) setState(() => _data = d);
      }),
    );
  }

  @override
  void dispose() {
    _target.removeListener(_onTargetChanged);
    _target.dispose();
    super.dispose();
  }

  void _onTargetChanged() {
    if (mounted) setState(() {});
  }

  StudyGoalUnit get _unit =>
      widget.appModel.readingGoalTextUnit.fixed ?? studyGoalUnitFor(_language);

  List<int> get _presets =>
      studyGoalPresetsFor(_metric, _period, language: _language, unit: _unit);

  int get _targetValue => int.tryParse(_target.text.trim()) ?? 0;

  /// 目标值的校验提示；null = 可以保存。时长目标存分钟，不能超过一个周期的总时长。
  String? get _targetError {
    final int? value = int.tryParse(_target.text.trim());
    if (value == null || value <= 0) return t.study_goal_sheet_target_invalid;
    if (!_metric.isTime) return null;
    return switch (_period) {
      StudyGoalPeriod.daily when value > kStudyGoalMaxMinutesDaily =>
        t.study_goal_sheet_target_over_day,
      StudyGoalPeriod.weekly when value > kStudyGoalMaxMinutesWeekly =>
        t.study_goal_sheet_target_over_week,
      StudyGoalPeriod.monthly when value > kStudyGoalMaxMinutesMonthly =>
        t.study_goal_sheet_target_over_month,
      _ => null,
    };
  }

  /// 「多久一次」下面那句说明：每周目标写出一周从星期几开始（「目标」设置里的
  /// 「一周从星期几开始」）。
  String _periodHint() => switch (_period) {
    StudyGoalPeriod.daily => t.study_goal_sheet_period_daily_hint,
    StudyGoalPeriod.weekly => t.study_goal_sheet_period_weekly_hint(
      day: studyGoalWeekdayName(StatWindow.weekStartDay),
    ),
    StudyGoalPeriod.monthly => t.study_goal_sheet_period_monthly_hint,
  };

  /// 换了度量 / 周期 / 语言：目标框还是上一套预设里的值（或空）时换成新预设的
  /// 同档位，用户手输的值不动。
  void _reselect(VoidCallback change) {
    final List<int> before = _presets;
    final int index = before.indexOf(_targetValue);
    setState(change);
    if (index >= 0 || _target.text.trim().isEmpty) {
      _setTarget(_presets.elementAt(index >= 0 ? index : 1));
    }
  }

  void _setTarget(int value) {
    final String text = '$value';
    _target.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// 语言片：每门语言一片。有文字之分的语言（中文）只出整门语言那片，「只算简体 /
  /// 繁体」在它下面另一排（[_scriptChoices]）。
  List<String> get _languageChoices {
    final List<String> out = <String>[];
    void add(String? tag) {
      if (tag == null) return;
      final String shown = studyGoalScriptVariantsOf(tag).isEmpty
          ? tag
          : studyGoalCombinedLanguageTag(tag) ?? tag;
      if (out.any((String e) => _sameLanguageChip(e, shown))) return;
      out.add(shown);
    }

    add(widget.goal?.language);
    add(widget.initialLanguage);
    for (final String tag in _data?.candidateLanguages ?? const <String>[]) {
      add(tag);
    }
    final String fallback = widget.appModel.defaultContentLanguage;
    if (fallback.isNotEmpty) add(fallback);
    _extraLanguages.forEach(add);
    return out;
  }

  /// 语言片是否选中：同一门语言（只算某种文字的目标也点亮整门语言那片）。
  bool _sameLanguageChip(String? a, String? b) =>
      studyGoalPrimaryLanguage(a) == studyGoalPrimaryLanguage(b) &&
      (studyGoalScriptVariantsOf(a).isNotEmpty || studyGoalSameLanguage(a, b));

  /// 选中语言可另选的文字（中文：简体 / 繁体）；没有文字之分为空。
  List<String> get _scriptChoices => studyGoalScriptVariantsOf(_language);

  Future<void> _pickOtherLanguage() async {
    await showContentLanguagePicker(
      context: context,
      title: t.stat_goal_language,
      description: t.stat_goal_language_picker_description,
      current: _language,
      autoDetected: '',
      autoLabel: t.stat_goal_language_all,
      onSelected: (String? tag) {
        if (!mounted) return;
        _reselect(() {
          _language = tag;
          if (tag != null) _extraLanguages.add(tag);
        });
      },
    );
  }

  String _presetLabel(int value) => _metric.isTime
      ? studyGoalDurationLabel(value * 60000)
      : formatStatCharsAxis(value);

  String _targetSuffix() {
    final String unit =
        studyGoalUnitLabel(_metric, _unit) ?? t.widget_settings_unit_minutes;
    return switch (_period) {
      StudyGoalPeriod.daily => t.study_goal_target_per_day(unit: unit),
      StudyGoalPeriod.weekly => t.study_goal_target_per_week(unit: unit),
      StudyGoalPeriod.monthly => t.study_goal_target_per_month(unit: unit),
    };
  }

  String? _recentHint() {
    final StudyGoalSheetData? data = _data;
    if (data == null) return null;
    final int? average = studyGoalRecentDailyAverage(
      metric: _metric,
      language: _metric.languageScoped ? _language : null,
      prefs: widget.appModel.prefsRepo,
      daily: data.daily,
      mediaLanguages: data.mediaLanguages,
      window: data.window,
    );
    if (average == null) return null;
    final String value = _metric.isTime
        ? formatStatTime(average)
        : '${formatStatCharsAxis(average)} ${studyGoalUnitLabel(_metric, _unit)}';
    final String? language = _metric.languageScoped ? _language : null;
    return language == null
        ? t.study_goal_sheet_recent(value: value)
        : t.study_goal_sheet_recent_language(
            language: studyGoalLanguageName(language),
            value: value,
          );
  }

  StudyGoal _build() => StudyGoal(
    id: widget.goal?.id ?? newStudyGoalId(),
    metric: _metric,
    period: _period,
    target: _targetValue,
    language: _language,
    activeWeekdays: _days,
  );

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 8),
    child: Text(text, style: context.fushiType.titleSmallEmphasized),
  );

  Widget _hint(String text, {Key? key}) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(
      text,
      key: key,
      style: FushiDesignTokens.of(context).type.metadata,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final List<int> presets = _presets;
    final int current = _targetValue;
    final String? error = _targetError;
    final String? recent = _recentHint();
    final bool editing = widget.goal != null;
    final MaterialLocalizations l10n = MaterialLocalizations.of(context);
    final StudyGoalReviewsHidden? reviewsHidden =
        widget.appModel.studyGoalReviewsHidden;
    final Color fill = Color.alphaBlend(
      theme.colorScheme.primary.withValues(alpha: 0.08),
      theme.colorScheme.surface,
    );
    int section = 0;
    Widget enter(Widget child) =>
        FushiStaggeredEntrance(index: section++, child: child);

    final List<Widget> children = <Widget>[
      enter(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _label(t.study_goal_sheet_section_what),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final StudyGoalId m in kStudyGoalSheetMetrics)
                  FushiChoiceChip(
                    key: ValueKey<String>('study-goal-metric-${m.wire}'),
                    avatar: FushiIcon(studyGoalMetricIcon(m), size: 18),
                    label: Text(studyGoalMetricLabel(m, unit: _unit)),
                    selected: _metric == m,
                    onSelected: (bool _) => _reselect(() => _metric = m),
                  ),
              ],
            ),
            // 选了「复习」但复习数此刻给不出（复习模块关着 / 卡发往 Anki）：说明它在
            // 首页不出现，免得存了找不到。
            if (_metric == StudyGoalId.reviews && reviewsHidden != null)
              _hint(
                studyGoalReviewsHiddenNote(reviewsHidden),
                key: const ValueKey<String>('study-goal-reviews-hidden'),
              ),
          ],
        ),
      ),
      if (_metric.languageScoped)
        enter(
          Column(
            key: const ValueKey<String>('study-goal-language'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _label(t.study_goal_sheet_section_language),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FushiChoiceChip(
                    key: const ValueKey<String>('study-goal-language-all'),
                    label: Text(t.stat_goal_language_all),
                    selected: _language == null,
                    onSelected: (bool _) => _reselect(() => _language = null),
                  ),
                  for (final String tag in _languageChoices)
                    FushiChoiceChip(
                      key: ValueKey<String>('study-goal-language-$tag'),
                      label: Text(studyGoalLanguageName(tag)),
                      selected:
                          _language != null &&
                          _sameLanguageChip(_language, tag),
                      onSelected: (bool _) => _reselect(() => _language = tag),
                    ),
                  FushiActionChipControl(
                    key: const ValueKey<String>('study-goal-language-other'),
                    avatar: const FushiIcon(FushiIcons.language, size: 18),
                    label: Text(t.study_goal_sheet_language_other),
                    onPressed: () => unawaited(_pickOtherLanguage()),
                  ),
                ],
              ),
              if (_scriptChoices.isNotEmpty) ...<Widget>[
                SizedBox(height: tokens.spacing.gap),
                Wrap(
                  key: const ValueKey<String>('study-goal-script'),
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    FushiChoiceChip(
                      key: const ValueKey<String>('study-goal-script-any'),
                      label: Text(t.study_goal_sheet_script_any),
                      selected: !_scriptChoices.any(
                        (String v) => studyGoalSameLanguage(v, _language),
                      ),
                      onSelected: (bool _) => _reselect(
                        () =>
                            _language = studyGoalCombinedLanguageTag(_language),
                      ),
                    ),
                    for (final String variant in _scriptChoices)
                      FushiChoiceChip(
                        key: ValueKey<String>('study-goal-script-$variant'),
                        label: Text(
                          t.study_goal_sheet_script_only(
                            language: studyGoalLanguageName(variant),
                          ),
                        ),
                        selected: studyGoalSameLanguage(variant, _language),
                        onSelected: (bool _) =>
                            _reselect(() => _language = variant),
                      ),
                  ],
                ),
              ],
              _hint(t.study_goal_sheet_language_hint),
            ],
          ),
        ),
      enter(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _label(t.study_goal_sheet_section_amount),
            FushiTextFieldControl(
              key: const ValueKey<String>('study-goal-target-field'),
              controller: _target,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              style: (theme.textTheme.headlineSmall ?? tokens.type.listTitle)
                  .copyWith(fontWeight: FontWeight.w700),
              decoration: InputDecoration(
                errorText: error,
                suffixText: _targetSuffix(),
                suffixStyle: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                filled: true,
                fillColor: fill,
                border: OutlineInputBorder(
                  borderRadius: tokens.radii.cardRadius,
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 8),
            FushiConnectedButtonGroup<int>(
              key: const ValueKey<String>('study-goal-presets'),
              showSelectedIcon: false,
              emptySelectionAllowed: true,
              expandedInsets: EdgeInsets.zero,
              segments: <ButtonSegment<int>>[
                for (final int preset in presets)
                  ButtonSegment<int>(
                    value: preset,
                    label: Text(_presetLabel(preset)),
                  ),
              ],
              selected: presets.contains(current)
                  ? <int>{current}
                  : const <int>{},
              onSelectionChanged: (Set<int> picked) {
                if (picked.isNotEmpty) _setTarget(picked.first);
              },
            ),
            _hint(
              t.study_goal_sheet_presets_hint,
              key: const ValueKey<String>('study-goal-presets-hint'),
            ),
            if (recent != null)
              _hint(recent, key: const ValueKey<String>('study-goal-recent')),
          ],
        ),
      ),
      enter(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _label(t.study_goal_sheet_how_often),
            KeyedSubtree(
              key: const ValueKey<String>('study-goal-period'),
              child: adaptiveSegmentedButton<StudyGoalPeriod>(
                context: context,
                segments: <ButtonSegment<StudyGoalPeriod>>[
                  for (final StudyGoalPeriod p in StudyGoalPeriod.values)
                    ButtonSegment<StudyGoalPeriod>(
                      value: p,
                      label: Text(
                        studyGoalPeriodLabel(p),
                        key: ValueKey<String>('study-goal-period-${p.wire}'),
                      ),
                    ),
                ],
                selected: <StudyGoalPeriod>{_period},
                onSelectionChanged: (Set<StudyGoalPeriod> picked) {
                  if (picked.isEmpty) return;
                  _reselect(() => _period = picked.first);
                },
              ),
            ),
            _hint(
              _periodHint(),
              key: const ValueKey<String>('study-goal-period-hint'),
            ),
          ],
        ),
      ),
      // 每个周期都可限定生效日：每日目标其余日子是休息日；周 / 月目标按这些日子
      // 摊「今日份额」。
      enter(
        Column(
          key: const ValueKey<String>('study-goal-days'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _label(t.study_goal_sheet_active_days),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (int day = DateTime.monday; day <= DateTime.sunday; day++)
                  FushiFilterChip(
                    key: ValueKey<String>('study-goal-day-$day'),
                    showCheckmark: false,
                    // Apple 外观的选中默认铺满强调色；这里与 MD3 一致用淡色块
                    // （每天都选时一排浅色，不是一排实心）。
                    selectedColor: isGlassDesign(context)
                        ? Theme.of(context).colorScheme.secondaryContainer
                        : null,
                    // narrowWeekdays 从周日起。
                    label: Text(l10n.narrowWeekdays[day % 7]),
                    tooltip: l10n.narrowWeekdays[day % 7],
                    selected: _days.isEmpty || _days.contains(day),
                    onSelected: (bool on) => setState(() {
                      final Set<int> next = _days.isEmpty
                          ? <int>{for (int d = 1; d <= 7; d++) d}
                          : <int>{..._days};
                      on ? next.add(day) : next.remove(day);
                      // 一天都不选没有意义：回到每天。
                      _days = next.length == 7 || next.isEmpty ? <int>{} : next;
                    }),
                  ),
              ],
            ),
            _hint(
              _period == StudyGoalPeriod.daily
                  ? t.study_goal_sheet_active_days_hint
                  : t.study_goal_sheet_active_days_split_hint,
              key: const ValueKey<String>('study-goal-days-hint'),
            ),
          ],
        ),
      ),
    ];

    return FushiModalSheetFrame(
      title: editing ? t.study_goal_sheet_edit : t.study_goal_sheet_new,
      leadingIcon: FushiIcons.flag,
      scrollable: true,
      // 与底部动作区同一个左右边距：不给就贴着对话框 / 面板的边（2026-11-20 走查）。
      bodyPadding: EdgeInsetsDirectional.fromSTEB(
        tokens.spacing.page,
        0,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      body: FushiEntranceScope(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
      footer: Row(
        children: <Widget>[
          if (editing)
            FushiTextButton(
              key: const ValueKey<String>('study-goal-delete'),
              onPressed: widget.onDelete,
              child: Text(
                t.study_goal_sheet_delete,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          const Spacer(),
          FushiPressScale(
            enabled: error == null,
            child: FushiFilledButton(
              key: const ValueKey<String>('study-goal-save'),
              onPressed: error == null ? () => widget.onSave(_build()) : null,
              child: Text(t.study_goal_sheet_save),
            ),
          ),
        ],
      ),
    );
  }
}
