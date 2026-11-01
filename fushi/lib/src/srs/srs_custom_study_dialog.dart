/// 「自定义学习」对话框（Anki Custom Study；反馈 -qGgW6_2hS）：提升今日新卡 / 复习上限，或开一个临时会话
/// （复习忘记的卡 / 提前复习 / 按卡片状态或标签）。只收选项；上限追加与选卡规则都在 Rust 排队内核
/// （native/fushi_fsrs/src/store/study.rs），临时会话不建筛选牌组、不挪卡、不改牌组设置。
library;

import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/utils.dart';

/// 对话框里的选项（与 Anki 自定义学习的单选同序）。
enum SrsCustomStudyOption { newLimit, reviewLimit, forgotten, ahead, filter }

/// 对话框的结果：提升今日上限（[extendNew] / [extendReviews]），或一个临时会话（[session]，开始时刻由调用方
/// 填，见 [SrsCustomStudyChoice.sessionAt]）。
class SrsCustomStudyChoice {
  const SrsCustomStudyChoice.extend({
    this.extendNew = 0,
    this.extendReviews = 0,
  }) : mode = null,
       days = 0,
       limit = 0,
       states = const <SrsCustomStudyState>{},
       tags = const <String>[];

  const SrsCustomStudyChoice.session({
    required SrsCustomStudyMode this.mode,
    this.days = 1,
    this.limit = 100,
    this.states = const <SrsCustomStudyState>{},
    this.tags = const <String>[],
  }) : extendNew = 0,
       extendReviews = 0;

  final int extendNew;
  final int extendReviews;

  /// null = 提升上限（不开临时会话）。
  final SrsCustomStudyMode? mode;
  final int days;
  final int limit;
  final Set<SrsCustomStudyState> states;
  final List<String> tags;

  bool get isExtension => mode == null;

  /// 临时会话的排队参数；[sinceMs] = 会话开始时刻（存储时钟）。
  SrsCustomStudy sessionAt(int sinceMs) => SrsCustomStudy(
    mode: mode!,
    sinceMs: sinceMs,
    days: days,
    limit: limit,
    states: states,
    tags: tags,
  );
}

/// 标签输入 → 标签列表（空白 / 逗号分隔，去重，保持顺序）。
List<String> parseSrsCustomStudyTags(String raw) {
  final List<String> out = <String>[];
  for (final String t in raw.split(RegExp(r'[\s,，]+'))) {
    final String tag = t.trim();
    if (tag.isNotEmpty && !out.contains(tag)) out.add(tag);
  }
  return out;
}

/// 弹出对话框；取消返回 null。[todayExtension] = 这个牌组今天已追加的上限（显示用）。
Future<SrsCustomStudyChoice?> showSrsCustomStudyDialog({
  required BuildContext context,
  required String deckName,
  ({int newCards, int reviews}) todayExtension = (newCards: 0, reviews: 0),
}) => showAppDialog<SrsCustomStudyChoice>(
  context: context,
  builder: (BuildContext _) =>
      SrsCustomStudyDialog(deckName: deckName, todayExtension: todayExtension),
);

class SrsCustomStudyDialog extends StatefulWidget {
  const SrsCustomStudyDialog({
    required this.deckName,
    this.todayExtension = (newCards: 0, reviews: 0),
    super.key,
  });

  final String deckName;
  final ({int newCards, int reviews}) todayExtension;

  static const double contentWidth = 520;

  @override
  State<SrsCustomStudyDialog> createState() => _SrsCustomStudyDialogState();
}

class _SrsCustomStudyDialogState extends State<SrsCustomStudyDialog> {
  SrsCustomStudyOption _option = SrsCustomStudyOption.newLimit;
  int _extendNew = 10;
  int _extendReviews = 50;
  int _forgottenDays = 1;
  int _aheadDays = 1;
  int _limit = 100;
  final Set<SrsCustomStudyState> _states = <SrsCustomStudyState>{
    SrsCustomStudyState.newCards,
  };
  final TextEditingController _tags = TextEditingController();

  @override
  void dispose() {
    _tags.dispose();
    super.dispose();
  }

  String _optionLabel(SrsCustomStudyOption o) => switch (o) {
    SrsCustomStudyOption.newLimit => t.srs_custom_study_mode_new_limit,
    SrsCustomStudyOption.reviewLimit => t.srs_custom_study_mode_review_limit,
    SrsCustomStudyOption.forgotten => t.srs_custom_study_mode_forgotten,
    SrsCustomStudyOption.ahead => t.srs_custom_study_mode_ahead,
    SrsCustomStudyOption.filter => t.srs_custom_study_mode_filter,
  };

  String _stateLabel(SrsCustomStudyState s) => switch (s) {
    SrsCustomStudyState.newCards => t.srs_count_new,
    SrsCustomStudyState.learning => t.srs_count_learn,
    SrsCustomStudyState.review => t.srs_custom_study_state_review,
    SrsCustomStudyState.due => t.srs_custom_study_state_due,
  };

  SrsCustomStudyChoice get _choice => switch (_option) {
    SrsCustomStudyOption.newLimit => SrsCustomStudyChoice.extend(
      extendNew: _extendNew,
    ),
    SrsCustomStudyOption.reviewLimit => SrsCustomStudyChoice.extend(
      extendReviews: _extendReviews,
    ),
    SrsCustomStudyOption.forgotten => SrsCustomStudyChoice.session(
      mode: SrsCustomStudyMode.forgotten,
      days: _forgottenDays,
      limit: SrsCustomStudy.maxCards,
    ),
    SrsCustomStudyOption.ahead => SrsCustomStudyChoice.session(
      mode: SrsCustomStudyMode.ahead,
      days: _aheadDays,
      limit: SrsCustomStudy.maxCards,
    ),
    SrsCustomStudyOption.filter => SrsCustomStudyChoice.session(
      mode: SrsCustomStudyMode.filter,
      limit: _limit,
      states: Set<SrsCustomStudyState>.of(_states),
      tags: parseSrsCustomStudyTags(_tags.text),
    ),
  };

  Widget _stepper({
    required Key key,
    required String title,
    String? subtitle,
    required int value,
    required int min,
    required int max,
    required int step,
    required String Function(int) format,
    required ValueChanged<int> onChanged,
  }) => AdaptiveSettingsStepperRow(
    key: key,
    title: title,
    subtitle: subtitle,
    value: value.toDouble(),
    step: step.toDouble(),
    min: min.toDouble(),
    max: max.toDouble(),
    format: (double v) => format(v.round()),
    onChanged: (double v) => setState(() => onChanged(v.round())),
  );

  List<Widget> _optionRows() => switch (_option) {
    SrsCustomStudyOption.newLimit => <Widget>[
      _stepper(
        key: const ValueKey<String>('srs-custom-study-extend-new'),
        title: t.srs_custom_study_extra_new,
        subtitle: widget.todayExtension.newCards > 0
            ? t.srs_custom_study_extended_so_far(
                n: widget.todayExtension.newCards,
              )
            : null,
        value: _extendNew,
        min: 1,
        max: SrsDeckLimitExtension.max,
        step: 5,
        format: (int n) => t.srs_custom_study_cards_value(n: n),
        onChanged: (int n) => _extendNew = n,
      ),
    ],
    SrsCustomStudyOption.reviewLimit => <Widget>[
      _stepper(
        key: const ValueKey<String>('srs-custom-study-extend-reviews'),
        title: t.srs_custom_study_extra_reviews,
        subtitle: widget.todayExtension.reviews > 0
            ? t.srs_custom_study_extended_so_far(
                n: widget.todayExtension.reviews,
              )
            : null,
        value: _extendReviews,
        min: 1,
        max: SrsDeckLimitExtension.max,
        step: 10,
        format: (int n) => t.srs_custom_study_cards_value(n: n),
        onChanged: (int n) => _extendReviews = n,
      ),
    ],
    SrsCustomStudyOption.forgotten => <Widget>[
      _stepper(
        key: const ValueKey<String>('srs-custom-study-forgotten-days'),
        title: t.srs_custom_study_days_forgotten,
        value: _forgottenDays,
        min: 1,
        max: 365,
        step: 1,
        format: (int n) => t.srs_custom_study_days_value(n: n),
        onChanged: (int n) => _forgottenDays = n,
      ),
    ],
    SrsCustomStudyOption.ahead => <Widget>[
      _stepper(
        key: const ValueKey<String>('srs-custom-study-ahead-days'),
        title: t.srs_custom_study_days_ahead,
        value: _aheadDays,
        min: 1,
        max: 365,
        step: 1,
        format: (int n) => t.srs_custom_study_days_value(n: n),
        onChanged: (int n) => _aheadDays = n,
      ),
    ],
    SrsCustomStudyOption.filter => <Widget>[
      for (final SrsCustomStudyState s in SrsCustomStudyState.values)
        AdaptiveSettingsSwitchRow(
          key: ValueKey<String>('srs-custom-study-state-${s.wire}'),
          title: _stateLabel(s),
          value: _states.contains(s),
          onChanged: (bool on) => setState(() {
            if (on) {
              _states.add(s);
            } else {
              _states.remove(s);
            }
          }),
        ),
      _stepper(
        key: const ValueKey<String>('srs-custom-study-limit'),
        title: t.srs_custom_study_limit,
        value: _limit,
        min: 1,
        max: SrsCustomStudy.maxCards,
        step: 10,
        format: (int n) => t.srs_custom_study_cards_value(n: n),
        onChanged: (int n) => _limit = n,
      ),
    ],
  };

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Size screen = MediaQuery.sizeOf(context);
    final double insetX = (screen.width * 0.05).clamp(16.0, 40.0);
    final bool session =
        _option != SrsCustomStudyOption.newLimit &&
        _option != SrsCustomStudyOption.reviewLimit;
    int step = 0;
    Widget stagger(Widget child) =>
        FushiStaggeredEntrance(index: step++, child: child);
    return FushiAlertDialog(
      insetPadding: EdgeInsets.symmetric(horizontal: insetX, vertical: 24),
      title: Text('${t.srs_custom_study_title} · ${widget.deckName}'),
      content: SizedBox(
        width: SrsCustomStudyDialog.contentWidth,
        child: SingleChildScrollView(
          child: FushiEntranceScope(
            child: FushiAnimatedSize(
              duration: fushiMotionDuration(context, FushiMotion.short),
              curve: FushiMotion.standard,
              child: Column(
                key: const ValueKey<String>('srs-custom-study'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  stagger(
                    AdaptiveSettingsSection(
                      children: <Widget>[
                        AdaptiveSettingsPickerRow<SrsCustomStudyOption>(
                          key: const ValueKey<String>(
                            'srs-custom-study-option',
                          ),
                          title: t.srs_custom_study_mode,
                          controlBelow: true,
                          options:
                              <
                                AdaptiveSettingsPickerOption<
                                  SrsCustomStudyOption
                                >
                              >[
                                for (final SrsCustomStudyOption o
                                    in SrsCustomStudyOption.values)
                                  AdaptiveSettingsPickerOption<
                                    SrsCustomStudyOption
                                  >(value: o, label: _optionLabel(o)),
                              ],
                          selected: _option,
                          onChanged: (SrsCustomStudyOption o) =>
                              setState(() => _option = o),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: tokens.spacing.gap),
                  stagger(
                    AdaptiveSettingsSection(
                      key: ValueKey<SrsCustomStudyOption>(_option),
                      children: _optionRows(),
                    ),
                  ),
                  if (_option == SrsCustomStudyOption.filter) ...<Widget>[
                    SizedBox(height: tokens.spacing.gap),
                    stagger(
                      AdaptiveSettingsTextField(
                        key: const ValueKey<String>('srs-custom-study-tags'),
                        controller: _tags,
                        labelText: t.srs_custom_study_tags,
                      ),
                    ),
                  ],
                  if (session) ...<Widget>[
                    SizedBox(height: tokens.spacing.gap),
                    stagger(
                      FushiInlineNotice(
                        key: const ValueKey<String>('srs-custom-study-hint'),
                        message: t.srs_custom_study_hint,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('srs-custom-study-confirm'),
          label: t.srs_custom_study_start,
          kind: FushiDialogActionKind.primary,
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(_choice),
        ),
      ],
    );
  }
}
