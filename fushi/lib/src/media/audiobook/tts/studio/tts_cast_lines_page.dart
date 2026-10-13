/// 逐句核对说话人：一章一屏，惰性列表；点一句改它的说话人（用户改的不会被重新
/// 标注覆盖）。改动直接写进传入的 [TtsCastLinesPage.cast]，
/// [TtsCastLinesPage.onChanged] 负责落盘。
library;

import 'dart:async';

import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_text.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart'
    show GlassSettingsRenderer;
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

class TtsCastLinesPage extends StatefulWidget {
  const TtsCastLinesPage({
    required this.plan,
    required this.chapters,
    required this.initialSection,
    required this.cast,
    required this.onChanged,
    this.reviewOnly = false,
    super.key,
  });

  final TtsBookPlan plan;

  /// 计划里有句子的章（spine 下标 + 显示名）。
  final List<({int section, String label})> chapters;
  final int initialSection;
  final TtsCast cast;
  final Future<void> Function() onChanged;

  /// 初始只列需要复核的行（页内可切换）。
  final bool reviewOnly;

  @override
  State<TtsCastLinesPage> createState() => _TtsCastLinesPageState();
}

class _TtsCastLinesPageState extends State<TtsCastLinesPage> {
  late int _section = widget.initialSection;
  late bool _reviewOnly = widget.reviewOnly;
  late List<TtsPlanSentence> _lines = _linesOf();

  List<TtsPlanSentence> _linesOf() => <TtsPlanSentence>[
    for (final TtsPlanSentence s in widget.plan.sentences)
      if (s.section == _section &&
          ttsCastIsReviewLine(widget.cast, s, reviewOnly: _reviewOnly))
        s,
  ];

  void _refilter() => _lines = _linesOf();

  Future<void> _pickChapter() async {
    final int? picked = await showFushiChoiceDialog<int>(
      context: context,
      title: t.audiobook_studio_chapters,
      selected: _section,
      options: <FushiChoiceOption<int>>[
        for (final ({int section, String label}) c in widget.chapters)
          FushiChoiceOption<int>(value: c.section, label: c.label),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _section = picked;
      _refilter();
    });
  }

  Future<void> _pickSpeaker(TtsPlanSentence line) async {
    const String newSpeaker = '\u0000new';
    final String current = widget.cast.speakerOf(line.section, line.matchStart);
    final String? picked = await showFushiChoiceDialog<String>(
      context: context,
      title: t.audiobook_studio_cast_line_speaker,
      message: line.text,
      selected: current,
      options: <FushiChoiceOption<String>>[
        FushiChoiceOption<String>(
          value: kTtsNarrator,
          label: t.audiobook_studio_cast_narrator,
        ),
        for (final ({String speaker, int count}) s in widget.cast.speakers())
          if (s.speaker != kTtsUnknown)
            FushiChoiceOption<String>(
              value: s.speaker,
              label: s.speaker,
              subtitle: t.audiobook_studio_cast_lines(n: s.count),
            ),
        // 角色表里有、但还没分到台词的人。
        for (final String name in widget.cast.roster.keys)
          if (!widget.cast.speakers().any(
            (({String speaker, int count}) s) => s.speaker == name,
          ))
            FushiChoiceOption<String>(value: name, label: name),
        FushiChoiceOption<String>(
          value: kTtsUnknown,
          label: t.audiobook_studio_cast_unknown,
        ),
        FushiChoiceOption<String>(
          value: newSpeaker,
          label: t.audiobook_studio_cast_new_speaker,
          icon: FushiIcons.add,
        ),
      ],
    );
    if (picked == null || !mounted) return;
    String speaker = picked;
    if (picked == newSpeaker) {
      final String? typed = await showFushiTextInputDialog(
        context: context,
        title: t.audiobook_studio_cast_new_speaker,
        message: line.text,
        labelText: t.audiobook_studio_cast_line_speaker,
        icon: FushiIcons.edit,
      );
      if (typed == null || typed.isEmpty || !mounted) return;
      speaker = typed;
    }
    if (speaker == current) return;
    // 只看待复核时，改完的行（已成为用户标注）留在列表里直到切换筛选，
    // 免得列表在用户眼前跳动。
    setState(
      () => widget.cast.setUserSpeaker(line.section, line.matchStart, speaker),
    );
    await widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double inset = isGlassDesign(context)
        ? GlassSettingsRenderer.detailHorizontalInset(context)
        : tokens.spacing.page;
    final String chapterLabel =
        widget.chapters
            .where((({int section, String label}) c) => c.section == _section)
            .firstOrNull
            ?.label ??
        '';
    return SettingsKitScaffold(
      title: t.audiobook_studio_cast_lines_title,
      leadingIcon: FushiIcons.checklist,
      leadingTone: SettingsIconTone.purple,
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) => ListView.builder(
            key: const ValueKey<String>('tts-studio-cast-lines-list'),
            controller: controller,
            padding: EdgeInsets.fromLTRB(
              inset,
              tokens.spacing.gap + MediaQuery.paddingOf(context).top,
              inset,
              tokens.spacing.page + bottomSafeInsetOf(context),
            ),
            itemCount: _lines.length + 1,
            itemBuilder: (BuildContext context, int index) {
              if (index == 0) {
                return AdaptiveSettingsSection(
                  key: const ValueKey<String>('tts-studio-cast-lines-header'),
                  children: <Widget>[
                    AdaptiveSettingsRow(
                      key: const ValueKey<String>(
                        'tts-studio-cast-lines-chapter',
                      ),
                      icon: FushiIcons.audiobook,
                      showIcon: true,
                      title: chapterLabel,
                      subtitle: _lines.isEmpty
                          ? t.audiobook_studio_cast_empty
                          : t.audiobook_studio_cast_lines(n: _lines.length),
                      onTap: () => unawaited(_pickChapter()),
                    ),
                    AdaptiveSettingsSwitchRow(
                      key: const ValueKey<String>(
                        'tts-studio-cast-lines-review-only',
                      ),
                      title: t.audiobook_studio_cast_review_only,
                      value: _reviewOnly,
                      onChanged: (bool v) => setState(() {
                        _reviewOnly = v;
                        _refilter();
                      }),
                    ),
                  ],
                );
              }
              final TtsPlanSentence line = _lines[index - 1];
              final String key = ttsLineKey(line.section, line.matchStart);
              return AdaptiveSettingsRow(
                key: ValueKey<String>('tts-studio-cast-line-$key'),
                title: line.text,
                titleMaxLines: 6,
                subtitle: ttsCastLineSubtitle(widget.cast.lines[key]),
                onTap: () => unawaited(_pickSpeaker(line)),
              );
            },
          ),
    );
  }
}
