/// 「朗读声音」设置页：声音预设的增删改、选当前声音、试听、缓存管理。
///
/// 形态与 AI 提供商设置同构（本仓「用户自配服务列表」标准件）：列表页一行一个声音，
/// 点进去是这份预设的编辑页；草稿态 + 600ms 防抖落盘 + 离开页面冲刷未落盘的编辑。
/// 参数表来自引擎描述符（[TtsProviderDescriptor.params]），本页不再抄一份校验判据。
library;

import 'dart:async';
import 'dart:math';

import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart'
    show GlassSettingsRenderer;
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/settings/settings_schema_widgets.dart'
    show SettingsSectionFooter;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

const Duration _kSaveDebounce = Duration(milliseconds: 600);

/// 试听默认文本（日语学习场景；用户可改）。
const String _kDefaultTestText = 'こんにちは。これは朗読のテストです。';

Future<void> openTtsVoiceSettingsPage(
  BuildContext context,
  TtsServices tts,
) async {
  final NavigatorState navigator = Navigator.of(context);
  await tts.seedBuiltinVoiceIfUnset();
  await navigator.push<void>(
    MaterialPageRoute<void>(builder: (_) => TtsVoiceSettingsPage(services: tts)),
  );
}

class TtsVoiceSettingsPage extends StatefulWidget {
  const TtsVoiceSettingsPage({required this.services, super.key});

  final TtsServices services;

  @override
  State<TtsVoiceSettingsPage> createState() => _TtsVoiceSettingsPageState();
}

class _TtsVoiceSettingsPageState extends State<TtsVoiceSettingsPage> {
  late List<TtsVoicePreset> _presets = widget.services.store.loadPresets();
  late String? _activeId = widget.services.store.activePreset()?.id;
  Timer? _saveDebounce;
  int? _cacheBytes;

  /// 编辑页随本 State 重建（草稿只活在这里）。
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  TtsPresetStore get _store => widget.services.store;
  TtsProviderRegistry get _registry => widget.services.registry;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshCacheSize());
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _revision.value++;
  }

  @override
  void dispose() {
    final bool pending = _saveDebounce?.isActive ?? false;
    _saveDebounce?.cancel();
    if (pending) unawaited(_store.savePresets(_presets));
    super.dispose();
  }

  Future<void> _refreshCacheSize() async {
    final TtsAudioCache cache = await widget.services.cache();
    final int bytes = await cache.sizeBytes();
    if (mounted) setState(() => _cacheBytes = bytes);
  }

  void _update(TtsVoicePreset next) {
    setState(() {
      final int at = _presets.indexWhere((TtsVoicePreset p) => p.id == next.id);
      if (at >= 0) _presets[at] = next;
    });
    _saveDebounce?.cancel();
    _saveDebounce = Timer(
      _kSaveDebounce,
      () => unawaited(_store.savePresets(_presets)),
    );
  }

  Future<void> _setActive(String id) async {
    setState(() => _activeId = id);
    await _store.setActivePresetId(id);
  }

  Future<void> _delete(String id) async {
    setState(() {
      _presets.removeWhere((TtsVoicePreset p) => p.id == id);
      if (_activeId == id) {
        _activeId = _presets.isEmpty ? null : _presets.first.id;
      }
    });
    _saveDebounce?.cancel();
    await _store.savePresets(_presets);
    await _store.setActivePresetId(_activeId);
  }

  Future<void> _add() async {
    final List<TtsProviderDescriptor> available = _registry.available;
    final TtsProviderDescriptor? picked =
        await showFushiChoiceDialog<TtsProviderDescriptor>(
          context: context,
          title: t.audiobook_tts_voice_add_title,
          icon: FushiIcons.voice,
          options: <FushiChoiceOption<TtsProviderDescriptor>>[
            for (final TtsProviderDescriptor d in available)
              FushiChoiceOption<TtsProviderDescriptor>(
                value: d,
                label: ttsProviderLabel(d.id),
                icon: d.capabilities.online
                    ? FushiIcons.cloud
                    : FushiIcons.devices,
              ),
          ],
        );
    if (picked == null || !mounted) return;
    final TtsVoicePreset preset = TtsVoicePreset(
      id: _newId(),
      providerId: picked.id,
      name: ttsProviderLabel(picked.id),
      params: <String, String>{
        for (final TtsParamSpec spec in picked.params)
          if (spec.kind != TtsParamKind.secret && spec.defaultValue != null)
            spec.key: spec.defaultValue!,
      },
    );
    setState(() {
      _presets = <TtsVoicePreset>[..._presets, preset];
      _activeId ??= preset.id;
    });
    await _store.savePresets(_presets);
    await _store.setActivePresetId(_activeId);
    if (mounted) unawaited(_openEditor(preset.id));
  }

  static String _newId() {
    final Random random = Random.secure();
    return 'tts_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '${random.nextInt(1 << 32).toRadixString(36)}';
  }

  Future<void> _clearCache() async {
    final TtsAudioCache cache = await widget.services.cache();
    await cache.clear();
    FushiToast.show(msg: t.audiobook_tts_cache_cleared);
    await _refreshCacheSize();
  }

  Future<void> _openEditor(String id) => Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (BuildContext pageContext) => ValueListenableBuilder<int>(
        valueListenable: _revision,
        builder: (BuildContext pageContext, int _, Widget? __) {
          final TtsVoicePreset? preset = _presets
              .where((TtsVoicePreset p) => p.id == id)
              .firstOrNull;
          // 已删除：只兜退场动画那几帧。
          if (preset == null) return const SizedBox.shrink();
          return _TtsVoiceEditorPage(
            key: ValueKey<String>('tts-voice-editor-$id'),
            preset: preset,
            descriptor: _registry[preset.providerId],
            active: preset.id == _activeId,
            services: widget.services,
            onChanged: _update,
            onUse: () => unawaited(_setActive(preset.id)),
            onDelete: () {
              Navigator.of(pageContext).pop();
              unawaited(_delete(preset.id));
            },
          );
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double inset = isGlassDesign(context)
        ? GlassSettingsRenderer.detailHorizontalInset(context)
        : tokens.spacing.page;
    return SettingsKitScaffold(
      title: t.audiobook_tts_voice_settings,
      leadingIcon: FushiIcons.voice,
      leadingTone: SettingsIconTone.purple,
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) => ListView(
            key: const ValueKey<String>('tts-voice-settings'),
            controller: controller,
            padding: EdgeInsets.fromLTRB(
              inset,
              tokens.spacing.gap + MediaQuery.paddingOf(context).top,
              inset,
              tokens.spacing.page + bottomSafeInsetOf(context),
            ),
            children: <Widget>[
              AdaptiveSettingsSection(
                key: const ValueKey<String>('tts-voice-list'),
                title: t.audiobook_tts_voices_section,
                children: <Widget>[
                  for (final TtsVoicePreset preset in _presets)
                    _presetRow(preset),
                  AdaptiveSettingsRow(
                    key: const ValueKey<String>('tts-voice-add'),
                    icon: FushiIcons.add,
                    showIcon: true,
                    title: t.audiobook_tts_voice_add,
                    onTap: () => unawaited(_add()),
                  ),
                ],
              ),
              if (_presets.isEmpty)
                SettingsSectionFooter(
                  t.audiobook_tts_voice_empty,
                  key: const ValueKey<String>('tts-voice-empty'),
                ),
              AdaptiveSettingsSection(
                key: const ValueKey<String>('tts-voice-cache'),
                title: t.audiobook_tts_cache_section,
                children: <Widget>[
                  AdaptiveSettingsRow(
                    key: const ValueKey<String>('tts-voice-cache-clear'),
                    icon: FushiIcons.deleteSweep,
                    showIcon: true,
                    title: t.audiobook_tts_cache_clear,
                    subtitle: _cacheBytes == null
                        ? null
                        : t.audiobook_tts_cache_size(
                            size: _formatBytes(_cacheBytes!),
                          ),
                    onTap: (_cacheBytes ?? 0) > 0
                        ? () => unawaited(_clearCache())
                        : null,
                  ),
                ],
              ),
            ],
          ),
    );
  }

  Widget _presetRow(TtsVoicePreset preset) {
    final TtsProviderDescriptor? descriptor = _registry[preset.providerId];
    final bool usable =
        descriptor != null &&
        descriptor.isAvailable &&
        descriptor.validate(preset).isEmpty;
    final bool active = preset.id == _activeId;
    final String status = !usable
        ? t.audiobook_tts_voice_incomplete_status
        : active
        ? t.audiobook_tts_voice_active
        : '';
    return AdaptiveSettingsRow(
      key: ValueKey<String>('tts-voice-${preset.id}'),
      icon: (descriptor?.capabilities.online ?? false)
          ? FushiIcons.cloud
          : FushiIcons.devices,
      showIcon: true,
      title: preset.name.isEmpty
          ? ttsProviderLabel(preset.providerId)
          : preset.name,
      subtitle: ttsProviderLabel(preset.providerId),
      subtitleMaxLines: 1,
      onTap: () => unawaited(_openEditor(preset.id)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (status.isNotEmpty)
            Text(
              status,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: usable
                    ? fushiNeutralSecondaryForeground(context)
                    : fushiStatusColor(context, FushiStatusTone.warning),
              ),
            ),
          const SizedBox(width: 6),
          if (isGlassDesign(context))
            const FushiAppleChevron()
          else
            FushiIcon(
              FushiIcons.chevronRight,
              size: 20,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
        ],
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _TtsVoiceEditorPage extends StatefulWidget {
  const _TtsVoiceEditorPage({
    required this.preset,
    required this.descriptor,
    required this.active,
    required this.services,
    required this.onChanged,
    required this.onUse,
    required this.onDelete,
    super.key,
  });

  final TtsVoicePreset preset;
  final TtsProviderDescriptor? descriptor;
  final bool active;
  final TtsServices services;
  final ValueChanged<TtsVoicePreset> onChanged;
  final VoidCallback onUse;
  final VoidCallback onDelete;

  @override
  State<_TtsVoiceEditorPage> createState() => _TtsVoiceEditorPageState();
}

class _TtsVoiceEditorPageState extends State<_TtsVoiceEditorPage> {
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};
  final TextEditingController _testText = TextEditingController(
    text: _kDefaultTestText,
  );
  bool _testing = false;
  bool _fetchingVoices = false;
  ({bool ok, String message})? _testResult;
  AudioPlayer? _testPlayer;
  StreamSubscription<PlayerState>? _testPlayerSub;
  TtsCancelToken? _testCancel;

  TtsVoicePreset get _preset => widget.preset;

  @override
  void dispose() {
    _testCancel?.cancel();
    unawaited(_releaseTestPlayer());
    for (final TextEditingController c in _controllers.values) {
      c.dispose();
    }
    _testText.dispose();
    super.dispose();
  }

  TextEditingController _controllerFor(TtsParamSpec spec) =>
      _controllers.putIfAbsent(
        spec.key,
        () => TextEditingController(
          text: _preset.param(spec.key, fallback: spec.defaultValue),
        ),
      );

  void _setParam(TtsParamSpec spec, String value) {
    final bool secret = spec.kind == TtsParamKind.secret;
    widget.onChanged(
      _preset.copyWith(
        params: secret
            ? null
            : <String, String>{..._preset.params, spec.key: value},
        secrets: secret
            ? <String, String>{..._preset.secrets, spec.key: value}
            : null,
      ),
    );
    // 配置变了，上一次试听结论作废。
    if (_testResult != null) setState(() => _testResult = null);
  }

  Future<void> _releaseTestPlayer() async {
    await _testPlayerSub?.cancel();
    _testPlayerSub = null;
    final AudioPlayer? player = _testPlayer;
    _testPlayer = null;
    await player?.dispose();
  }

  Future<void> _test() async {
    final TtsProviderDescriptor? descriptor = widget.descriptor;
    final String text = _testText.text.trim();
    if (descriptor == null || text.isEmpty) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    await _releaseTestPlayer();
    final TtsCancelToken cancel = TtsCancelToken();
    _testCancel = cancel;
    final TtsProvider provider = descriptor.create(
      _preset,
      widget.services.host,
    );
    try {
      final TtsAudioCache cache = await widget.services.cache();
      final String key = TtsAudioCache.keyFor(
        descriptor.audioIdentity(_preset),
        text,
      );
      final TtsCachedAudio audio = await cache.obtain(
        key,
        (String out) =>
            provider.synthesize(text, outputPath: out, cancel: cancel),
      );
      if (!mounted || cancel.isCancelled) return;
      // 播完才释放：just_audio 的 play() 在桌面 media_kit 下发出命令即返回，
      // 立刻 dispose 会把试听截断。
      final AudioPlayer player = AudioPlayer();
      _testPlayer = player;
      cache.pin(key);
      _testPlayerSub = player.playerStateStream.listen((PlayerState state) {
        if (state.processingState == ProcessingState.completed) {
          cache.unpin(key);
          unawaited(_releaseTestPlayer());
        }
      });
      await player.setFilePath(audio.path);
      setState(
        () => _testResult = (
          ok: true,
          message: t.audiobook_tts_voice_test_playing,
        ),
      );
      unawaited(player.play());
    } on TtsFailure catch (failure) {
      if (mounted && failure.code != TtsFailureCode.cancelled) {
        setState(
          () => _testResult = (ok: false, message: ttsFailureText(failure)),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _testResult = (
            ok: false,
            message: t.audiobook_tts_failure_bad_response,
          ),
        );
      }
    } finally {
      await provider.dispose();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _pickVoice(TtsParamSpec spec) async {
    final TtsProviderDescriptor? descriptor = widget.descriptor;
    if (descriptor == null) return;
    setState(() => _fetchingVoices = true);
    final TtsProvider provider = descriptor.create(
      _preset,
      widget.services.host,
    );
    List<TtsVoice> voices = const <TtsVoice>[];
    try {
      voices = await provider.listVoices();
    } on TtsFailure catch (failure) {
      if (mounted) {
        setState(
          () => _testResult = (ok: false, message: ttsFailureText(failure)),
        );
      }
      return;
    } finally {
      await provider.dispose();
      if (mounted) setState(() => _fetchingVoices = false);
    }
    if (!mounted) return;
    if (voices.isEmpty) {
      setState(
        () => _testResult = (
          ok: false,
          message: t.audiobook_tts_voice_list_empty,
        ),
      );
      return;
    }
    // 日语声音排前面（本应用的主场景），其余按语言代码排。
    final List<TtsVoice> sorted = List<TtsVoice>.of(voices)
      ..sort((TtsVoice a, TtsVoice b) {
        final bool aj = a.locale.startsWith('ja');
        final bool bj = b.locale.startsWith('ja');
        if (aj != bj) return aj ? -1 : 1;
        final int byLocale = a.locale.compareTo(b.locale);
        return byLocale != 0 ? byLocale : a.id.compareTo(b.id);
      });
    final String current = _preset.param(spec.key, fallback: spec.defaultValue);
    final String? picked = await showFushiChoiceDialog<String>(
      context: context,
      title: ttsParamLabel(spec.key),
      selected: current,
      options: <FushiChoiceOption<String>>[
        for (final TtsVoice v in sorted)
          FushiChoiceOption<String>(
            value: v.id,
            label: v.displayName == v.id ? v.id : '${v.displayName} · ${v.id}',
            subtitle: <String>[
              v.locale,
              if (v.gender != null) v.gender!,
            ].join(' · '),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    _controllerFor(spec).text = picked;
    _setParam(spec, picked);
  }

  Future<void> _pickChoice(TtsParamSpec spec) async {
    final String current = _preset.param(spec.key, fallback: spec.defaultValue);
    final String? picked = await showFushiChoiceDialog<String>(
      context: context,
      title: ttsParamLabel(spec.key),
      selected: current,
      options: <FushiChoiceOption<String>>[
        for (final String c in spec.choices)
          FushiChoiceOption<String>(value: c, label: c),
      ],
    );
    if (picked == null || !mounted) return;
    _setParam(spec, picked);
  }

  void _regenerate() {
    widget.onChanged(_preset.copyWith(revision: _preset.revision + 1));
    FushiToast.show(msg: t.audiobook_tts_voice_regenerated);
  }

  @override
  Widget build(BuildContext context) {
    final TtsProviderDescriptor? descriptor = widget.descriptor;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double inset = isGlassDesign(context)
        ? GlassSettingsRenderer.detailHorizontalInset(context)
        : tokens.spacing.page;
    final double rowInset = tokens.spacing.rowHorizontal;
    final List<String> problems =
        descriptor?.validate(_preset) ?? const <String>[];
    Widget field(Widget child) => Padding(
      padding: EdgeInsets.fromLTRB(rowInset, 12, rowInset, 10),
      child: child,
    );

    return SettingsKitScaffold(
      title: _preset.name.isEmpty
          ? ttsProviderLabel(_preset.providerId)
          : _preset.name,
      leadingIcon: FushiIcons.voice,
      leadingTone: SettingsIconTone.purple,
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) => ListView(
            controller: controller,
            key: ValueKey<String>('tts-voice-editor-list-${_preset.id}'),
            padding: EdgeInsets.fromLTRB(
              inset,
              tokens.spacing.gap + MediaQuery.paddingOf(context).top,
              inset,
              tokens.spacing.page + bottomSafeInsetOf(context),
            ),
            children: <Widget>[
              if (descriptor != null && descriptor.capabilities.online)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: FushiInlineNotice(
                    key: const ValueKey<String>('tts-voice-online-notice'),
                    severity: FushiNoticeSeverity.info,
                    message: descriptor.id == EdgeTtsDescriptor.providerId
                        ? '${t.audiobook_tts_online_notice}\n'
                              '${t.audiobook_tts_unofficial_notice}'
                        : t.audiobook_tts_online_notice,
                  ),
                ),
              AdaptiveSettingsSection(
                children: <Widget>[
                  AdaptiveSettingsSwitchRow(
                    key: const ValueKey<String>('tts-voice-use'),
                    title: t.audiobook_tts_voice_use,
                    subtitle: problems.isEmpty
                        ? t.audiobook_tts_voice_ready
                        : t.audiobook_tts_voice_incomplete_status,
                    value: widget.active,
                    onChanged: widget.active ? null : (_) => widget.onUse(),
                  ),
                ],
              ),
              AdaptiveSettingsSection(
                title: ttsProviderLabel(_preset.providerId),
                children: <Widget>[
                  field(
                    _textField(
                      key: const ValueKey<String>('tts-voice-name'),
                      label: t.audiobook_tts_voice_name,
                      controller: _controllers.putIfAbsent(
                        '__name',
                        () => TextEditingController(text: _preset.name),
                      ),
                      onChanged: (String v) =>
                          widget.onChanged(_preset.copyWith(name: v)),
                    ),
                  ),
                  if (descriptor != null)
                    for (final TtsParamSpec spec in descriptor.params)
                      _paramRow(spec, problems.contains(spec.key), field),
                ],
              ),
              if (descriptor != null)
                AdaptiveSettingsSection(
                  children: <Widget>[
                    field(
                      _textField(
                        key: const ValueKey<String>('tts-voice-test-text'),
                        label: t.audiobook_tts_voice_test_text,
                        controller: _testText,
                        onChanged: (_) {},
                      ),
                    ),
                    AdaptiveSettingsRow(
                      key: const ValueKey<String>('tts-voice-test'),
                      icon: FushiIcons.play,
                      showIcon: true,
                      title: t.audiobook_tts_voice_test,
                      onTap: problems.isEmpty && !_testing
                          ? () => unawaited(_test())
                          : null,
                      trailing: _testing
                          ? const SizedBox.square(
                              dimension: 18,
                              child: FushiCircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : null,
                    ),
                    AdaptiveSettingsRow(
                      key: const ValueKey<String>('tts-voice-regenerate'),
                      icon: FushiIcons.refresh,
                      showIcon: true,
                      title: t.audiobook_tts_voice_regenerate,
                      subtitle: t.audiobook_tts_voice_regenerate_hint,
                      onTap: _regenerate,
                    ),
                  ],
                ),
              if (_testResult case final ({bool ok, String message}) result)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: FushiInlineNotice(
                    key: const ValueKey<String>('tts-voice-test-result'),
                    severity: result.ok
                        ? FushiNoticeSeverity.success
                        : FushiNoticeSeverity.error,
                    message: result.message,
                  ),
                ),
              Center(
                child: FushiTextButton.icon(
                  key: const ValueKey<String>('tts-voice-delete'),
                  destructive: true,
                  onPressed: widget.onDelete,
                  icon: const FushiIcon(FushiIcons.delete),
                  label: Text(t.audiobook_tts_voice_delete),
                ),
              ),
            ],
          ),
    );
  }

  Widget _paramRow(
    TtsParamSpec spec,
    bool invalid,
    Widget Function(Widget child) field,
  ) {
    final String label = ttsParamLabel(spec.key);
    switch (spec.kind) {
      case TtsParamKind.choice:
        return KeyedSubtree(
          key: ValueKey<String>('tts-voice-param-${spec.key}'),
          child: AdaptiveSettingsRow(
            title: label,
            onTap: () => unawaited(_pickChoice(spec)),
            trailing: Text(
              _preset.param(spec.key, fallback: spec.defaultValue),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: fushiNeutralSecondaryForeground(context),
              ),
            ),
          ),
        );
      case TtsParamKind.url:
      case TtsParamKind.text:
      case TtsParamKind.secret:
      case TtsParamKind.voice:
        return field(
          _textField(
            key: ValueKey<String>('tts-voice-param-${spec.key}'),
            label: label,
            controller: _controllerFor(spec),
            hintText: ttsParamHint(_preset.providerId, spec.key),
            errorText: invalid && _controllerFor(spec).text.isNotEmpty
                ? t.audiobook_tts_param_invalid
                : null,
            obscureText: spec.kind == TtsParamKind.secret,
            keyboardType: spec.kind == TtsParamKind.url
                ? TextInputType.url
                : null,
            suffixIcon: spec.kind == TtsParamKind.voice
                ? FushiIconButtonControl(
                    key: ValueKey<String>('tts-voice-param-${spec.key}-pick'),
                    tooltip: t.audiobook_tts_voice_list_fetch,
                    icon: _fetchingVoices
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: FushiCircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const FushiIcon(FushiIcons.dropDown),
                    onPressed: _fetchingVoices
                        ? null
                        : () => unawaited(_pickVoice(spec)),
                  )
                : null,
            onChanged: (String v) => _setParam(spec, v.trim()),
          ),
        );
    }
  }

  Widget _textField({
    required Key key,
    required String label,
    required TextEditingController controller,
    required ValueChanged<String> onChanged,
    String? hintText,
    String? errorText,
    bool obscureText = false,
    TextInputType? keyboardType,
    Widget? suffixIcon,
  }) => FushiTextFormFieldControl(
    key: key,
    controller: controller,
    obscureText: obscureText,
    enableSuggestions: !obscureText,
    autocorrect: !obscureText,
    keyboardType: keyboardType,
    decoration: InputDecoration(
      labelText: label,
      helperText: hintText,
      helperMaxLines: 3,
      errorText: errorText,
      errorMaxLines: 3,
      suffixIcon: suffixIcon,
      border: const OutlineInputBorder(),
    ),
    onChanged: onChanged,
  );
}
