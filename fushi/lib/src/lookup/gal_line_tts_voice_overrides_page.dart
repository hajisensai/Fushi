/// Galgame 台词 TTS 的「按语言 / 按游戏指定声音」页。
///
/// 同时玩日语和中文游戏时，一个全局声音不够用：日语声音读中文台词（或反过来）
/// 要么读错要么读不出。这里给每种游戏内容语言、每个库内游戏各配一个默认声音，
/// 进哪个游戏就自动用哪个。裁决顺序见 [GalLineTtsSettings.voiceFor]：
/// 规则指定的声音 > 按游戏 > 按语言 > 全局默认声音。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/lookup/gal_hook_text_overlay_controller.dart';
import 'package:fushi/src/lookup/gal_line_tts.dart';
import 'package:fushi/src/lookup/gal_line_tts_settings_page.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/profile/language_binding.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart'
    show GlassSettingsRenderer;
import 'package:fushi/src/settings/settings_kit_core.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/content_language_picker.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

Future<void> openGalLineTtsVoiceOverridesPage(
  BuildContext context,
  TtsServices services,
  GalgameRepository games,
) => Navigator.of(context).push<void>(
  MaterialPageRoute<void>(
    builder: (_) =>
        GalLineTtsVoiceOverridesPage(services: services, games: games),
  ),
);

/// 设置项副标题：配了几条覆盖（没配 = 说明这页做什么）。
String galLineTtsVoiceOverridesSummary(GalLineTtsSettings settings) {
  final int count = settings.languageVoices.length + settings.gameVoices.length;
  return count == 0
      ? t.gal_line_tts_voice_overrides_hint
      : t.gal_line_tts_voice_overrides_count(n: count);
}

/// 语言键的显示顺序：常用内容语言表的顺序在前，其余按键名。
List<String> galLineTtsSortedLanguageKeys(Iterable<String> keys) {
  final List<String> order = <String>[
    for (final ({String? tag, String label}) o in kContentLanguageOptions)
      if (o.tag case final String tag) normalizeLanguageBinding(tag),
  ];
  int rank(String key) {
    final int index = order.indexOf(key);
    return index < 0 ? order.length : index;
  }

  return keys.toList()..sort((String a, String b) {
    final int byRank = rank(a).compareTo(rank(b));
    return byRank != 0 ? byRank : a.compareTo(b);
  });
}

class GalLineTtsVoiceOverridesPage extends StatefulWidget {
  const GalLineTtsVoiceOverridesPage({
    required this.services,
    required this.games,
    super.key,
  });

  final TtsServices services;
  final GalgameRepository games;

  @override
  State<GalLineTtsVoiceOverridesPage> createState() =>
      _GalLineTtsVoiceOverridesPageState();
}

class _GalLineTtsVoiceOverridesPageState
    extends State<GalLineTtsVoiceOverridesPage> {
  final GalHookTextOverlayController _controller =
      GalHookTextOverlayController.instance;
  late GalLineTtsSettings _settings = _controller.lineTtsSettings;

  /// 增删条目时换一代 key，入场动效重播、不复用旧行。
  int _generation = 0;

  TtsServices get _services => widget.services;

  void _update(GalLineTtsSettings next) {
    final bool structural =
        next.languageVoices.length != _settings.languageVoices.length ||
        next.gameVoices.length != _settings.gameVoices.length;
    setState(() {
      _settings = next;
      if (structural) _generation++;
    });
    unawaited(_controller.setLineTtsSettings(next));
  }

  Future<String?> _pickOverrideVoice(String? current) async {
    final ({String? presetId})? picked = await showGalLineTtsVoicePicker(
      context,
      _services,
      current: current,
      nullLabel: t.gal_line_tts_voice_use_default,
      nullHint: t.gal_line_tts_voice_use_default_hint,
    );
    if (picked == null) return current;
    return picked.presetId;
  }

  Future<void> _editLanguage(String key) async {
    final String? current = _settings.languageVoices[key];
    final String? next = await _pickOverrideVoice(current);
    if (!mounted || next == current) return;
    _update(_controller.lineTtsSettings.withLanguageVoice(key, next));
  }

  Future<void> _editGame(String gameId) async {
    final String? current = _settings.gameVoices[gameId];
    final String? next = await _pickOverrideVoice(current);
    if (!mounted || next == current) return;
    _update(_controller.lineTtsSettings.withGameVoice(gameId, next));
  }

  Future<void> _addLanguage() async {
    final List<({String key, String label})> candidates =
        <({String key, String label})>[
          for (final ({String? tag, String label}) o in kContentLanguageOptions)
            if (o.tag case final String tag)
              if (normalizeLanguageBinding(tag) case final String key
                  when key.isNotEmpty &&
                      !_settings.languageVoices.containsKey(key))
                (key: key, label: o.label),
        ];
    if (candidates.isEmpty) return;
    final String? key = await showFushiChoiceDialog<String>(
      context: context,
      title: t.gal_line_tts_voice_add_language,
      icon: FushiIcons.language,
      options: <FushiChoiceOption<String>>[
        for (final ({String key, String label}) c in candidates)
          FushiChoiceOption<String>(
            value: c.key,
            label: c.label,
            icon: FushiIcons.language,
          ),
      ],
    );
    if (key == null || !mounted) return;
    final String? presetId = await _pickOverrideVoice(null);
    if (presetId == null || !mounted) return;
    _update(_controller.lineTtsSettings.withLanguageVoice(key, presetId));
  }

  Future<void> _addGame() async {
    final List<GalgameEntry> candidates =
        widget.games.games
            .where((GalgameEntry g) => !_settings.gameVoices.containsKey(g.id))
            .toList()
          ..sort(
            (GalgameEntry a, GalgameEntry b) =>
                a.displayName.compareTo(b.displayName),
          );
    if (candidates.isEmpty) {
      FushiToast.show(msg: t.gal_line_tts_voice_no_games);
      return;
    }
    final String? gameId = await showFushiChoiceDialog<String>(
      context: context,
      title: t.gal_line_tts_voice_add_game,
      icon: FushiIcons.game,
      options: <FushiChoiceOption<String>>[
        for (final GalgameEntry g in candidates)
          FushiChoiceOption<String>(
            value: g.id,
            label: g.displayName,
            subtitle: g.language == null
                ? null
                : contentLanguageLabelOf(g.language!),
            icon: FushiIcons.game,
          ),
      ],
    );
    if (gameId == null || !mounted) return;
    final String? presetId = await _pickOverrideVoice(null);
    if (presetId == null || !mounted) return;
    _update(_controller.lineTtsSettings.withGameVoice(gameId, presetId));
  }

  Widget _secondary(String text) => Text(
    text,
    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: fushiNeutralSecondaryForeground(context),
    ),
  );

  Widget _languageSection() {
    final List<String> keys = galLineTtsSortedLanguageKeys(
      _settings.languageVoices.keys,
    );
    final bool canAdd = kContentLanguageOptions.any(
      (({String? tag, String label}) o) =>
          o.tag != null &&
          !_settings.languageVoices.containsKey(
            normalizeLanguageBinding(o.tag),
          ),
    );
    return AdaptiveSettingsSection(
      title: t.gal_line_tts_voice_by_language,
      children: <Widget>[
        for (final String key in keys)
          AdaptiveSettingsRow(
            key: ValueKey<String>('gal-tts-lang-voice-$key'),
            icon: FushiIcons.language,
            showIcon: true,
            title: contentLanguageLabelOf(key),
            onTap: () => unawaited(_editLanguage(key)),
            trailing: _secondary(
              galLineTtsVoiceLabel(_services, _settings.languageVoices[key]),
            ),
          ),
        if (canAdd)
          AdaptiveSettingsRow(
            key: const ValueKey<String>('gal-tts-lang-voice-add'),
            icon: FushiIcons.add,
            showIcon: true,
            title: t.gal_line_tts_voice_add_language,
            onTap: () => unawaited(_addLanguage()),
          ),
      ],
    );
  }

  Widget _gameSection() {
    final List<MapEntry<String, String>> entries =
        _settings.gameVoices.entries.toList()..sort(
          (MapEntry<String, String> a, MapEntry<String, String> b) =>
              _gameLabel(a.key).compareTo(_gameLabel(b.key)),
        );
    return AdaptiveSettingsSection(
      title: t.gal_line_tts_voice_by_game,
      children: <Widget>[
        for (final MapEntry<String, String> e in entries)
          AdaptiveSettingsRow(
            key: ValueKey<String>('gal-tts-game-voice-${e.key}'),
            icon: FushiIcons.game,
            showIcon: true,
            title: _gameLabel(e.key),
            onTap: () => unawaited(_editGame(e.key)),
            trailing: _secondary(galLineTtsVoiceLabel(_services, e.value)),
          ),
        AdaptiveSettingsRow(
          key: const ValueKey<String>('gal-tts-game-voice-add'),
          icon: FushiIcons.add,
          showIcon: true,
          title: t.gal_line_tts_voice_add_game,
          onTap: () => unawaited(_addGame()),
        ),
      ],
    );
  }

  /// 游戏已移出库时仍列出来（让用户能删掉这条），标成「已移出库的游戏」。
  String _gameLabel(String gameId) =>
      widget.games.byId(gameId)?.displayName ??
      t.gal_line_tts_voice_game_missing;

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
          message: t.gal_line_tts_voice_overrides_intro,
        ),
      ),
      _languageSection(),
      _gameSection(),
    ];
    return SettingsKitScaffold(
      title: t.gal_line_tts_voice_overrides,
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
                    key: ValueKey<String>(
                      'gal-tts-voice-entrance-$_generation-$i',
                    ),
                    index: i,
                    child: sections[i],
                  ),
              ],
            ),
          ),
    );
  }
}
