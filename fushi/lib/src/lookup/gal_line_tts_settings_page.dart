/// Galgame 台词 TTS 的「朗读规则」页与声音选择器。
///
/// 规则表照 LunaTranslator「语音指定 / 语音修正」的心智模型：顺序匹配、首条命中生效；
/// 一键预设覆盖群教程里的常见情形（带括号 = 有配音角色、主角名开头照读、配音角色
/// 名单、读之前去括号）。页底的试算框用同一个纯函数 [decideGalLineTts] 实时给出
/// 「认出的人名 / 送进 TTS 的文本 / 读不读」，规则写错当场看得见。
library;

import 'dart:async';

import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:fushi/src/lookup/gal_line_tts.dart';
import 'package:fushi/src/lookup/gal_line_tts_player.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/src/media/audiobook/tts/tts_voice_quick_switch.dart';
import 'package:fushi/src/media/audiobook/tts/tts_voice_settings_page.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart'
    show GlassSettingsRenderer;
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/desktop_audio_playback.dart';
import 'package:fushi/utils.dart';

/// 选择器里「跟随朗读声音」的值。
const String _kFollowActiveVoice = '#active';

/// 选择器里「管理声音」的值。
const String _kManageVoices = '#manage';

/// 声音的显示名（null = 跟随「朗读声音」当前声音）。
String galLineTtsVoiceLabel(TtsServices services, String? presetId) {
  if (presetId == null) {
    final TtsVoicePreset? active = services.store.activePreset();
    return active == null
        ? t.gal_line_tts_voice_follow
        : '${t.gal_line_tts_voice_follow} · ${ttsVoiceDisplayName(active)}';
  }
  for (final TtsVoicePreset preset in services.store.loadPresets()) {
    if (preset.id == presetId) {
      return '${ttsVoiceDisplayName(preset)} · '
          '${ttsProviderLabel(preset.providerId)}';
    }
  }
  return t.models_tts_fallback_voice_missing;
}

/// 选声音。返回 `(picked: true, presetId: …)`；取消 / 去了管理页返回 null。
Future<({String? presetId})?> showGalLineTtsVoicePicker(
  BuildContext context,
  TtsServices services, {
  required String? current,
}) async {
  await services.seedBuiltinVoiceIfUnset();
  if (!context.mounted) return null;
  final String? picked = await showFushiChoiceDialog<String>(
    context: context,
    title: t.gal_line_tts_voice,
    icon: FushiIcons.voice,
    selected: current ?? _kFollowActiveVoice,
    options: <FushiChoiceOption<String>>[
      FushiChoiceOption<String>(
        value: _kFollowActiveVoice,
        label: t.gal_line_tts_voice_follow,
        subtitle: t.gal_line_tts_voice_follow_hint,
        icon: FushiIcons.volumeUp,
      ),
      for (final TtsVoiceSwitchEntry e in ttsVoiceSwitchEntries(
        presets: services.store.loadPresets(),
        activePresetId: null,
        descriptorOf: (String id) => services.registry[id],
      ))
        FushiChoiceOption<String>(
          value: e.preset.id,
          label: e.label,
          subtitle: switch (e.block) {
            TtsVoiceSwitchBlock.unavailable =>
              t.audiobook_tts_failure_unsupported,
            TtsVoiceSwitchBlock.incomplete =>
              t.audiobook_tts_voice_incomplete_status,
            null => ttsProviderLabel(e.preset.providerId),
          },
          icon: FushiIcons.voice,
          enabled: e.selectable,
        ),
      FushiChoiceOption<String>(
        value: _kManageVoices,
        label: t.audiobook_tts_voice_settings,
        subtitle: t.audiobook_tts_voice_settings_hint,
        icon: FushiIcons.settings,
      ),
    ],
  );
  if (picked == null) return null;
  if (picked == _kManageVoices) {
    if (context.mounted) await openTtsVoiceSettingsPage(context, services);
    return null;
  }
  return (presetId: picked == _kFollowActiveVoice ? null : picked);
}

Future<void> openGalLineTtsRulesPage(
  BuildContext context,
  TtsServices services,
) => Navigator.of(context).push<void>(
  MaterialPageRoute<void>(
    builder: (_) => GalLineTtsRulesPage(services: services),
  ),
);

String _matchLabel(GalLineTtsRuleMatch match) => switch (match) {
  GalLineTtsRuleMatch.speakerIs => t.gal_line_tts_match_speaker,
  GalLineTtsRuleMatch.startsWith => t.gal_line_tts_match_starts_with,
  GalLineTtsRuleMatch.contains => t.gal_line_tts_match_contains,
  GalLineTtsRuleMatch.regex => t.gal_line_tts_match_regex,
};

String _actionLabel(GalLineTtsRuleAction action) => switch (action) {
  GalLineTtsRuleAction.skip => t.gal_line_tts_action_skip,
  GalLineTtsRuleAction.read => t.gal_line_tts_action_read,
  GalLineTtsRuleAction.voice => t.gal_line_tts_action_voice,
};

class GalLineTtsRulesPage extends StatefulWidget {
  const GalLineTtsRulesPage({required this.services, super.key});

  final TtsServices services;

  @override
  State<GalLineTtsRulesPage> createState() => _GalLineTtsRulesPageState();
}

class _GalLineTtsRulesPageState extends State<GalLineTtsRulesPage> {
  final GalHookTextOverlayController _controller =
      GalHookTextOverlayController.instance;
  late GalLineTtsSettings _settings = _controller.lineTtsSettings;
  final TextEditingController _sample = TextEditingController(
    text: '主人公「おはよう」',
  );

  /// 规则 / 修正每次增删都换一代 key，文本框不会把旧行的内容带到新行上。
  int _generation = 0;

  TtsServices get _services => widget.services;

  @override
  void dispose() {
    _sample.dispose();
    super.dispose();
  }

  void _update(GalLineTtsSettings next, {bool structural = false}) {
    setState(() {
      _settings = next;
      if (structural) _generation++;
    });
    unawaited(_controller.setLineTtsSettings(next));
  }

  void _setRule(int index, GalLineTtsRule rule) {
    final List<GalLineTtsRule> rules = List<GalLineTtsRule>.of(_settings.rules);
    rules[index] = rule;
    _update(_settings.copyWith(rules: rules));
  }

  void _moveRule(int index, int delta) {
    final int target = index + delta;
    if (target < 0 || target >= _settings.rules.length) return;
    final List<GalLineTtsRule> rules = List<GalLineTtsRule>.of(_settings.rules);
    final GalLineTtsRule rule = rules.removeAt(index);
    rules.insert(target, rule);
    _update(_settings.copyWith(rules: rules), structural: true);
  }

  void _removeRule(int index) {
    final List<GalLineTtsRule> rules = List<GalLineTtsRule>.of(_settings.rules)
      ..removeAt(index);
    _update(_settings.copyWith(rules: rules), structural: true);
  }

  void _addRule(GalLineTtsRule rule) => _update(
    _settings.copyWith(rules: insertGalLineTtsRule(_settings.rules, rule)),
    structural: true,
  );

  void _setFix(int index, GalLineTtsTextFix fix) {
    final List<GalLineTtsTextFix> fixes = List<GalLineTtsTextFix>.of(
      _settings.textFixes,
    );
    fixes[index] = fix;
    _update(_settings.copyWith(textFixes: fixes));
  }

  void _removeFix(int index) {
    final List<GalLineTtsTextFix> fixes = List<GalLineTtsTextFix>.of(
      _settings.textFixes,
    )..removeAt(index);
    _update(_settings.copyWith(textFixes: fixes), structural: true);
  }

  void _addFix(GalLineTtsTextFix fix) => _update(
    _settings.copyWith(
      textFixes: <GalLineTtsTextFix>[..._settings.textFixes, fix],
    ),
    structural: true,
  );

  Future<void> _addPreset(GalLineTtsRulePreset preset) async {
    String names = '';
    if (preset != GalLineTtsRulePreset.skipBracketed) {
      final String? input = await showFushiTextInputDialog(
        context: context,
        title: preset == GalLineTtsRulePreset.readProtagonist
            ? t.gal_line_tts_preset_protagonist
            : t.gal_line_tts_preset_voiced_cast,
        message: t.gal_line_tts_names_hint,
        labelText: t.gal_line_tts_names,
        icon: FushiIcons.person,
        maxLines: 4,
      );
      if (input == null || input.trim().isEmpty) return;
      names = input.trim();
    }
    _addRule(galLineTtsRuleFromPreset(preset, names: names));
  }

  Future<void> _pickRuleVoice(int index) async {
    final ({String? presetId})? picked = await showGalLineTtsVoicePicker(
      context,
      _services,
      current: _settings.rules[index].presetId,
    );
    if (picked == null) return;
    _setRule(
      index,
      GalLineTtsRule(
        match: _settings.rules[index].match,
        pattern: _settings.rules[index].pattern,
        action: _settings.rules[index].action,
        presetId: picked.presetId,
        enabled: _settings.rules[index].enabled,
      ),
    );
  }

  Future<void> _preview(GalLineTtsSpeak speak) async {
    try {
      final String path = await synthesizeGalLineTtsWithServices(
        _services,
        speak.text,
        presetId: speak.presetId,
        cancel: TtsCancelToken(),
      );
      await DesktopAudioPlayback.playFile(path, volume: _settings.volume);
    } catch (error) {
      FushiToast.show(
        msg: t.audiobook_tts_failure_bad_response,
        severity: ToastSeverity.error,
      );
    }
  }

  Widget _secondary(String text) => Text(
    text,
    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: fushiNeutralSecondaryForeground(context),
    ),
  );

  Widget _field({
    required Key key,
    required String initial,
    required String label,
    String? hint,
    String? error,
    required ValueChanged<String> onChanged,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: FushiTextField(
      key: key,
      initialValue: initial,
      labelText: label,
      hintText: hint,
      errorText: error,
      variant: FushiTextFieldVariant.outlined,
      minLines: 1,
      maxLines: 3,
      onChanged: onChanged,
    ),
  );

  Widget _speakerSection() => AdaptiveSettingsSection(
    title: t.gal_line_tts_speaker_section,
    children: <Widget>[
      AdaptiveSettingsSwitchRow(
        key: const ValueKey<String>('gal-tts-strip-speaker'),
        title: t.gal_line_tts_strip_speaker,
        subtitle: t.gal_line_tts_strip_speaker_hint,
        value: _settings.stripSpeaker,
        onChanged: (bool v) => _update(_settings.copyWith(stripSpeaker: v)),
      ),
      _field(
        key: ValueKey<String>('gal-tts-speaker-pattern-$_generation'),
        initial: _settings.speakerPattern,
        label: t.gal_line_tts_speaker_pattern,
        hint: r'^(?<name>[^「]+)「(?<text>.*)」$',
        error:
            _settings.speakerPattern.trim().isNotEmpty &&
                compileGalSpeakerPattern(_settings.speakerPattern) == null
            ? t.gal_line_tts_speaker_pattern_invalid
            : null,
        onChanged: (String v) => _update(_settings.copyWith(speakerPattern: v)),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: _secondary(t.gal_line_tts_speaker_pattern_hint),
      ),
    ],
  );

  Widget _ruleSection(int index) {
    final GalLineTtsRule rule = _settings.rules[index];
    final bool invalidRegex =
        rule.match == GalLineTtsRuleMatch.regex &&
        rule.pattern.isNotEmpty &&
        rule.compiledRegex == null;
    return AdaptiveSettingsSection(
      key: ValueKey<String>('gal-tts-rule-$_generation-$index'),
      title: t.gal_line_tts_rule_title(index: index + 1),
      children: <Widget>[
        AdaptiveSettingsSwitchRow(
          title: t.gal_line_tts_rule_enabled,
          value: rule.enabled,
          onChanged: (bool v) => _setRule(index, rule.copyWith(enabled: v)),
        ),
        AdaptiveSettingsPickerRow<GalLineTtsRuleMatch>(
          title: t.gal_line_tts_rule_match,
          options: <AdaptiveSettingsPickerOption<GalLineTtsRuleMatch>>[
            for (final GalLineTtsRuleMatch m in GalLineTtsRuleMatch.values)
              AdaptiveSettingsPickerOption<GalLineTtsRuleMatch>(
                value: m,
                label: _matchLabel(m),
              ),
          ],
          selected: rule.match,
          onChanged: (GalLineTtsRuleMatch m) =>
              _setRule(index, rule.copyWith(match: m)),
        ),
        _field(
          key: ValueKey<String>('gal-tts-rule-pattern-$_generation-$index'),
          initial: rule.pattern,
          label: rule.match == GalLineTtsRuleMatch.regex
              ? t.gal_line_tts_match_regex
              : t.gal_line_tts_names,
          hint: rule.match == GalLineTtsRuleMatch.regex
              ? null
              : t.gal_line_tts_names_hint,
          error: invalidRegex ? t.gal_line_tts_speaker_pattern_invalid : null,
          onChanged: (String v) => _setRule(index, rule.copyWith(pattern: v)),
        ),
        AdaptiveSettingsPickerRow<GalLineTtsRuleAction>(
          title: t.gal_line_tts_rule_action,
          options: <AdaptiveSettingsPickerOption<GalLineTtsRuleAction>>[
            for (final GalLineTtsRuleAction a in GalLineTtsRuleAction.values)
              AdaptiveSettingsPickerOption<GalLineTtsRuleAction>(
                value: a,
                label: _actionLabel(a),
              ),
          ],
          selected: rule.action,
          onChanged: (GalLineTtsRuleAction a) =>
              _setRule(index, rule.copyWith(action: a)),
        ),
        if (rule.action == GalLineTtsRuleAction.voice)
          AdaptiveSettingsRow(
            icon: FushiIcons.voice,
            showIcon: true,
            title: t.gal_line_tts_voice,
            onTap: () => unawaited(_pickRuleVoice(index)),
            trailing: _secondary(
              galLineTtsVoiceLabel(_services, rule.presetId),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Row(
            children: <Widget>[
              FushiIconButton(
                tooltip: t.gal_line_tts_move_up,
                enabled: index != 0,
                onTap: () => _moveRule(index, -1),
                icon: FushiIcons.arrowUp,
              ),
              FushiIconButton(
                tooltip: t.gal_line_tts_move_down,
                enabled: index != _settings.rules.length - 1,
                onTap: () => _moveRule(index, 1),
                icon: FushiIcons.arrowDown,
              ),
              const Spacer(),
              FushiIconButton(
                tooltip: t.gal_line_tts_delete,
                onTap: () => _removeRule(index),
                icon: FushiIcons.delete,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _addSection() => AdaptiveSettingsSection(
    title: t.gal_line_tts_presets,
    children: <Widget>[
      AdaptiveSettingsRow(
        icon: FushiIcons.filterList,
        showIcon: true,
        title: t.gal_line_tts_preset_skip_bracketed,
        subtitle: t.gal_line_tts_preset_skip_bracketed_hint,
        subtitleMaxLines: 3,
        onTap: () => unawaited(_addPreset(GalLineTtsRulePreset.skipBracketed)),
      ),
      AdaptiveSettingsRow(
        icon: FushiIcons.person,
        showIcon: true,
        title: t.gal_line_tts_preset_protagonist,
        subtitle: t.gal_line_tts_preset_protagonist_hint,
        subtitleMaxLines: 3,
        onTap: () =>
            unawaited(_addPreset(GalLineTtsRulePreset.readProtagonist)),
      ),
      AdaptiveSettingsRow(
        icon: FushiIcons.voice,
        showIcon: true,
        title: t.gal_line_tts_preset_voiced_cast,
        subtitle: t.gal_line_tts_preset_voiced_cast_hint,
        subtitleMaxLines: 3,
        onTap: () => unawaited(_addPreset(GalLineTtsRulePreset.skipVoicedCast)),
      ),
      AdaptiveSettingsRow(
        icon: FushiIcons.textFields,
        showIcon: true,
        title: t.gal_line_tts_preset_strip_brackets,
        subtitle: t.gal_line_tts_preset_strip_brackets_hint,
        subtitleMaxLines: 3,
        onTap: () => _addFix(kGalLineTtsStripBracketsFix),
      ),
      AdaptiveSettingsRow(
        icon: FushiIcons.add,
        showIcon: true,
        title: t.gal_line_tts_add_rule,
        onTap: () => _addRule(
          const GalLineTtsRule(
            match: GalLineTtsRuleMatch.contains,
            pattern: '',
            action: GalLineTtsRuleAction.skip,
          ),
        ),
      ),
      AdaptiveSettingsRow(
        icon: FushiIcons.add,
        showIcon: true,
        title: t.gal_line_tts_add_fix,
        onTap: () => _addFix(const GalLineTtsTextFix(pattern: '')),
      ),
    ],
  );

  Widget _fixSection(int index) {
    final GalLineTtsTextFix fix = _settings.textFixes[index];
    return AdaptiveSettingsSection(
      key: ValueKey<String>('gal-tts-fix-$_generation-$index'),
      title: t.gal_line_tts_fix_title(index: index + 1),
      children: <Widget>[
        AdaptiveSettingsSwitchRow(
          title: t.gal_line_tts_rule_enabled,
          value: fix.enabled,
          onChanged: (bool v) => _setFix(index, fix.copyWith(enabled: v)),
        ),
        _field(
          key: ValueKey<String>('gal-tts-fix-pattern-$_generation-$index'),
          initial: fix.pattern,
          label: t.gal_line_tts_match_regex,
          error: fix.pattern.isNotEmpty && fix.compiled == null
              ? t.gal_line_tts_speaker_pattern_invalid
              : null,
          onChanged: (String v) => _setFix(index, fix.copyWith(pattern: v)),
        ),
        _field(
          key: ValueKey<String>('gal-tts-fix-replace-$_generation-$index'),
          initial: fix.replacement,
          label: t.gal_line_tts_fix_replacement,
          onChanged: (String v) => _setFix(index, fix.copyWith(replacement: v)),
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: FushiIconButton(
              tooltip: t.gal_line_tts_delete,
              onTap: () => _removeFix(index),
              icon: FushiIcons.delete,
            ),
          ),
        ),
      ],
    );
  }

  Widget _testSection() {
    final String raw = _sample.text;
    final GalLineSpeakerSplit split = splitGalLineSpeaker(
      raw,
      customPattern: _settings.speakerPattern,
    );
    final GalLineTtsSettings forced = _settings.copyWith(
      autoPlayEnabled: true,
      autoPlay: GalLineTtsAutoPlay.unvoicedOnly,
    );
    String verdict(GalLineVoiceEvidence evidence) => switch (decideGalLineTts(
      settings: forced,
      rawText: raw,
      evidence: evidence,
      manual: false,
    )) {
      GalLineTtsSpeak() => t.gal_line_tts_test_read,
      GalLineTtsSkip() => t.gal_line_tts_test_skip,
      GalLineTtsWait() => t.gal_line_tts_test_wait,
    };
    final GalLineTtsDecision manual = decideGalLineTts(
      settings: forced,
      rawText: raw,
      evidence: GalLineVoiceEvidence.unvoiced,
      manual: true,
    );
    return AdaptiveSettingsSection(
      title: t.gal_line_tts_test_section,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: FushiTextField(
            key: const ValueKey<String>('gal-tts-test-input'),
            controller: _sample,
            minLines: 1,
            maxLines: 4,
            labelText: t.gal_line_tts_test_input,
            variant: FushiTextFieldVariant.outlined,
            onChanged: (_) => setState(() {}),
          ),
        ),
        AdaptiveSettingsRow(
          title: t.gal_line_tts_test_speaker,
          trailing: _secondary(split.speaker ?? '—'),
        ),
        AdaptiveSettingsRow(
          title: t.gal_line_tts_test_text,
          subtitle: galLineTtsText(_settings, raw),
          subtitleMaxLines: 4,
        ),
        AdaptiveSettingsRow(
          title: t.gal_line_tts_test_no_voice,
          trailing: _secondary(verdict(GalLineVoiceEvidence.unvoiced)),
        ),
        AdaptiveSettingsRow(
          title: t.gal_line_tts_test_has_voice,
          trailing: _secondary(verdict(GalLineVoiceEvidence.voiced)),
        ),
        if (manual case final GalLineTtsSpeak speak)
          AdaptiveSettingsRow(
            icon: FushiIcons.play,
            showIcon: true,
            title: t.gal_line_tts_test_play,
            onTap: () => unawaited(_preview(speak)),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double inset = isGlassDesign(context)
        ? GlassSettingsRenderer.detailHorizontalInset(context)
        : tokens.spacing.page;
    final List<Widget> sections = <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: FushiInlineNotice(
          severity: FushiNoticeSeverity.info,
          message: t.gal_line_tts_rules_intro,
        ),
      ),
      _speakerSection(),
      for (int i = 0; i < _settings.rules.length; i++) _ruleSection(i),
      for (int i = 0; i < _settings.textFixes.length; i++) _fixSection(i),
      _addSection(),
      _testSection(),
    ];
    return SettingsKitScaffold(
      title: t.gal_line_tts_rules,
      leadingIcon: FushiIcons.voice,
      leadingTone: SettingsIconTone.purple,
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) => FushiEntranceScope(
            replayKey: _generation,
            child: ListView(
              controller: controller,
              padding: EdgeInsets.fromLTRB(
                inset,
                tokens.spacing.gap + MediaQuery.paddingOf(context).top,
                inset,
                tokens.spacing.page + bottomSafeInsetOf(context),
              ),
              children: <Widget>[
                for (int i = 0; i < sections.length; i++)
                  FushiStaggeredEntrance(
                    key: ValueKey<String>('gal-tts-entrance-$_generation-$i'),
                    index: i,
                    child: sections[i],
                  ),
              ],
            ),
          ),
    );
  }
}
