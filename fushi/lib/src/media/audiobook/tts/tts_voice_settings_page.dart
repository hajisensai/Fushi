/// 「朗读声音」设置页：声音预设的增删改、选当前声音、试听、缓存管理。
///
/// 形态与 AI 提供商设置同构（本仓「用户自配服务列表」标准件）：列表一行一个声音，
/// 行首单选一键设为使用中、行尾删除；窄屏点行推进编辑页，宽屏（与制作台同一副
/// 双栏骨架，见 [TtsVoiceListLayout]）选中即在右侧编辑。草稿态 + 600ms 防抖落盘 +
/// 离开页面冲刷未落盘的编辑。
/// 参数表来自引擎描述符（[TtsProviderDescriptor.params]），本页不再抄一份校验判据。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/providers/gpt_sovits_tts_provider.dart';
import 'package:fushi_engine/tts/providers/translate_tts_providers.dart';
import 'package:fushi_engine/tts/tts_audio_probe.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/src/media/audiobook/tts/tts_voice_list_layout.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart'
    show GlassSettingsRenderer;
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

const Duration _kSaveDebounce = Duration(milliseconds: 600);

/// 声音参数旁边存显示名的键后缀（`voice` → `voice_name`）。
const String _kVoiceNameSuffix = '_name';

/// 非官方在线接口（网页版朗读），编辑页额外提示可能失效。
const Set<String> _kUnofficialProviders = <String>{
  EdgeTtsDescriptor.providerId,
  MicrosoftTranslatorTtsDescriptor.providerId,
  GoogleTranslateTtsDescriptor.providerId,
};

/// 试听默认文本（日语学习场景；用户可改）。
const String _kDefaultTestText = 'こんにちは。これは朗読のテストです。';

/// 新建 / 换引擎时的初始参数：引擎声明的非凭据默认值。
Map<String, String> ttsDefaultParams(TtsProviderDescriptor descriptor) =>
    <String, String>{
      for (final TtsParamSpec spec in descriptor.params)
        if (spec.kind != TtsParamKind.secret && spec.defaultValue != null)
          spec.key: spec.defaultValue!,
    };

Future<void> openTtsVoiceSettingsPage(
  BuildContext context,
  TtsServices tts,
) async {
  final NavigatorState navigator = Navigator.of(context);
  await tts.seedBuiltinVoiceIfUnset();
  await navigator.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => TtsVoiceSettingsPage(services: tts),
    ),
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

  /// 宽屏右侧正在编辑的声音（null / 已删除时退回使用中的声音，见
  /// [resolveTtsVoiceSelection]）。
  String? _selectedId;
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

  /// 「添加声音」只按大类选（外部服务 / 在线服务 / 系统语音）；具体是哪个引擎在
  /// 编辑页的「服务类型」里选，默认取该类第一个。
  Future<void> _add({required bool wide}) async {
    final List<TtsProviderCategory> categories = <TtsProviderCategory>[
      for (final TtsProviderCategory c in TtsProviderCategory.values)
        if (_registry.available.any(
          (TtsProviderDescriptor d) => d.category == c,
        ))
          c,
    ];
    final TtsProviderCategory? picked =
        await showFushiChoiceDialog<TtsProviderCategory>(
          context: context,
          title: t.audiobook_tts_voice_add_title,
          icon: FushiIcons.voice,
          options: <FushiChoiceOption<TtsProviderCategory>>[
            for (final TtsProviderCategory c in categories)
              FushiChoiceOption<TtsProviderCategory>(
                value: c,
                label: ttsCategoryLabel(c),
                subtitle: ttsCategoryHint(c),
                icon: _categoryIcon(c),
              ),
          ],
        );
    if (picked == null || !mounted) return;
    final TtsProviderDescriptor descriptor = _registry.available.firstWhere(
      (TtsProviderDescriptor d) => d.category == picked,
    );
    final TtsVoicePreset preset = TtsVoicePreset(
      id: _newId(),
      providerId: descriptor.id,
      name: ttsProviderLabel(descriptor.id),
      params: ttsDefaultParams(descriptor),
    );
    setState(() {
      _presets = <TtsVoicePreset>[..._presets, preset];
      _activeId ??= preset.id;
      _selectedId = preset.id;
    });
    await _store.savePresets(_presets);
    await _store.setActivePresetId(_activeId);
    // 双栏下新声音已经在右侧打开，不再推页。
    if (mounted && !wide) unawaited(_openEditor(preset.id));
  }

  static IconData _categoryIcon(TtsProviderCategory c) => switch (c) {
    TtsProviderCategory.external => FushiIcons.devices,
    TtsProviderCategory.online => FushiIcons.cloud,
    TtsProviderCategory.system => FushiIcons.voice,
  };

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
          return _editor(
            preset,
            embedded: false,
            onDelete: () async {
              if (!await confirmTtsVoiceDelete(
                pageContext,
                _displayName(preset),
              )) {
                return;
              }
              if (pageContext.mounted) Navigator.of(pageContext).pop();
              unawaited(_delete(preset.id));
            },
          );
        },
      ),
    ),
  );

  /// 编辑内容：窄屏是推进的整页，宽屏（[embedded]）是右侧窗格里的滚动视图。
  Widget _editor(
    TtsVoicePreset preset, {
    required bool embedded,
    required Future<void> Function() onDelete,
  }) => _TtsVoiceEditorPage(
    key: ValueKey<String>('tts-voice-editor-${preset.id}'),
    preset: preset,
    descriptor: _registry[preset.providerId],
    active: preset.id == _activeId,
    services: widget.services,
    embedded: embedded,
    onChanged: _update,
    onUse: () => unawaited(_setActive(preset.id)),
    onDelete: () => unawaited(onDelete()),
  );

  static String _displayName(TtsVoicePreset preset) =>
      preset.name.isEmpty ? ttsProviderLabel(preset.providerId) : preset.name;

  TtsVoiceListEntry _entry(TtsVoicePreset preset) {
    final TtsProviderDescriptor? descriptor = _registry[preset.providerId];
    final bool usable =
        descriptor != null &&
        descriptor.isAvailable &&
        descriptor.validate(preset).isEmpty;
    return TtsVoiceListEntry(
      id: preset.id,
      title: _displayName(preset),
      subtitle: descriptor == null
          ? ttsProviderLabel(preset.providerId)
          : '${ttsCategoryLabel(descriptor.category)} · '
                '${ttsProviderLabel(preset.providerId)}',
      icon: _categoryIcon(descriptor?.category ?? TtsProviderCategory.external),
      incomplete: !usable,
    );
  }

  @override
  Widget build(BuildContext context) {
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
          ) => TtsVoiceListLayout(
            voices: <TtsVoiceListEntry>[
              for (final TtsVoicePreset preset in _presets) _entry(preset),
            ],
            activeId: _activeId,
            selectedId: _selectedId,
            scrollController: controller,
            onSelect: (String id) => setState(() => _selectedId = id),
            onOpen: (String id) {
              _selectedId = id;
              unawaited(_openEditor(id));
            },
            onUse: (String id) => unawaited(_setActive(id)),
            onDelete: (String id) => unawaited(_delete(id)),
            onAdd: (bool wide) => unawaited(_add(wide: wide)),
            detailBuilder: (BuildContext context, String id) {
              final TtsVoicePreset preset = _presets.firstWhere(
                (TtsVoicePreset p) => p.id == id,
              );
              return _editor(
                preset,
                embedded: true,
                onDelete: () async {
                  if (await confirmTtsVoiceDelete(
                    context,
                    _displayName(preset),
                  )) {
                    await _delete(preset.id);
                  }
                },
              );
            },
            cacheSubtitle: _cacheBytes == null
                ? null
                : t.audiobook_tts_cache_size(size: _formatBytes(_cacheBytes!)),
            onClearCache: (_cacheBytes ?? 0) > 0
                ? () => unawaited(_clearCache())
                : null,
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
    this.embedded = false,
    super.key,
  });

  final TtsVoicePreset preset;
  final TtsProviderDescriptor? descriptor;
  final bool active;
  final TtsServices services;

  /// true = 宽屏右侧窗格（不带页面壳，自带滚动视图与标题）；false = 推进的整页。
  final bool embedded;
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

  /// 同一大类里可切换的引擎（只有一个时不显示「服务类型」行）。
  List<TtsProviderDescriptor> get _siblings {
    final TtsProviderCategory? category = widget.descriptor?.category;
    if (category == null) return const <TtsProviderDescriptor>[];
    return <TtsProviderDescriptor>[
      for (final TtsProviderDescriptor d in widget.services.registry.available)
        if (d.category == category) d,
    ];
  }

  Future<void> _pickServiceType() async {
    final TtsProviderDescriptor? picked =
        await showFushiChoiceDialog<TtsProviderDescriptor>(
          context: context,
          title: t.audiobook_tts_service_type,
          selected: widget.descriptor,
          options: <FushiChoiceOption<TtsProviderDescriptor>>[
            for (final TtsProviderDescriptor d in _siblings)
              FushiChoiceOption<TtsProviderDescriptor>(
                value: d,
                label: ttsProviderLabel(d.id),
                subtitle: ttsProviderHint(d.id),
              ),
          ],
        );
    if (picked == null || !mounted || picked.id == _preset.providerId) return;
    // 换引擎 = 参数表整个换掉：旧引擎的地址 / 声音 / 密钥对新引擎没有意义。
    for (final TextEditingController c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    _referenceDurations.clear();
    final bool defaultName =
        _preset.name.isEmpty ||
        _preset.name == ttsProviderLabel(_preset.providerId);
    widget.onChanged(
      TtsVoicePreset(
        id: _preset.id,
        providerId: picked.id,
        name: defaultName ? ttsProviderLabel(picked.id) : _preset.name,
        params: ttsDefaultParams(picked),
      ),
    );
    setState(() => _testResult = null);
  }

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
    final TtsVoice chosen = sorted.firstWhere((TtsVoice v) => v.id == picked);
    // 显示名只给界面用（不在参数表里，不进缓存键）：Irodori 的声音 id 是不透明串。
    widget.onChanged(
      _preset.copyWith(
        params: <String, String>{
          ..._preset.params,
          spec.key: picked,
          '${spec.key}$_kVoiceNameSuffix': chosen.displayName,
        },
      ),
    );
    if (_testResult != null) setState(() => _testResult = null);
  }

  /// 参考音频时长缓存（路径 → 毫秒，null = 读不出）。
  final Map<String, int?> _referenceDurations = <String, int?>{};

  /// GPT-SoVITS 只接受 3–10 秒的参考音频（超出直接 400）。路径在本机能读到时
  /// （服务跑在同一台电脑上）当场量时长提示，而不是等到朗读时才失败。
  String? _localReferenceProblem(TtsParamSpec spec) {
    if (_preset.providerId != GptSovitsTtsDescriptor.providerId ||
        spec.key != GptSovitsTtsDescriptor.refAudioKey) {
      return null;
    }
    final String path = _controllerFor(spec).text.trim();
    if (path.isEmpty) return null;
    final int? ms = _referenceDurations.putIfAbsent(path, () {
      try {
        final File file = File(path);
        if (!file.existsSync()) return null;
        final Uint8List bytes = file.readAsBytesSync();
        final TtsAudioFormat? format = sniffTtsAudioFormat(bytes);
        return format == null ? null : probeTtsAudioDurationMs(bytes, format);
      } on FileSystemException {
        return null;
      }
    });
    if (ms == null || (ms >= 3000 && ms <= 10000)) return null;
    return t.audiobook_tts_param_ref_audio_length(
      seconds: (ms / 1000).toStringAsFixed(1),
    );
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

    List<Widget> children(BuildContext context) => <Widget>[
      if (descriptor != null && descriptor.capabilities.online)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: FushiInlineNotice(
            key: const ValueKey<String>('tts-voice-online-notice'),
            severity: FushiNoticeSeverity.info,
            message: _kUnofficialProviders.contains(descriptor.id)
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
        title: descriptor == null
            ? ttsProviderLabel(_preset.providerId)
            : ttsCategoryLabel(descriptor.category),
        children: <Widget>[
          if (_siblings.length > 1)
            KeyedSubtree(
              key: const ValueKey<String>('tts-voice-service-type'),
              child: AdaptiveSettingsRow(
                title: t.audiobook_tts_service_type,
                subtitle: ttsProviderHint(_preset.providerId),
                onTap: () => unawaited(_pickServiceType()),
                trailing: Text(
                  ttsProviderLabel(_preset.providerId),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: fushiNeutralSecondaryForeground(context),
                  ),
                ),
              ),
            ),
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
          if (descriptor != null &&
              descriptor.category != TtsProviderCategory.system)
            _concurrencyRow(descriptor),
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
                      child: FushiCircularProgressIndicator(strokeWidth: 2),
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
    ];

    final String title = _preset.name.isEmpty
        ? ttsProviderLabel(_preset.providerId)
        : _preset.name;
    if (widget.embedded) {
      return ListView(
        key: ValueKey<String>('tts-voice-editor-list-${_preset.id}'),
        primary: false,
        padding: EdgeInsets.fromLTRB(
          inset,
          tokens.spacing.gap,
          inset,
          tokens.spacing.page + bottomSafeInsetOf(context),
        ),
        children: <Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(0, 4, 0, tokens.spacing.gap),
            child: Text(
              title,
              key: const ValueKey<String>('tts-voice-editor-title'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          ...children(context),
        ],
      );
    }
    return SettingsKitScaffold(
      title: title,
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
            children: children(context),
          ),
    );
  }

  /// 并发请求数：默认用引擎的值，用户可按自己的服务端 / 显卡能力调高。
  Widget _concurrencyRow(TtsProviderDescriptor descriptor) {
    final int fallback = descriptor.capabilities.maxConcurrency;
    final bool custom = _preset.param(kTtsConcurrencyParam).trim().isNotEmpty;
    final int effective = ttsEffectiveConcurrency(descriptor, _preset);
    return KeyedSubtree(
      key: const ValueKey<String>('tts-voice-concurrency'),
      child: AdaptiveSettingsRow(
        title: t.audiobook_tts_concurrency,
        subtitle: t.audiobook_tts_concurrency_hint,
        subtitleMaxLines: 3,
        onTap: () => unawaited(_pickConcurrency(fallback)),
        trailing: Text(
          custom
              ? '$effective'
              : t.audiobook_tts_concurrency_default(n: fallback),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: fushiNeutralSecondaryForeground(context),
          ),
        ),
      ),
    );
  }

  Future<void> _pickConcurrency(int fallback) async {
    final String current = _preset.param(kTtsConcurrencyParam).trim();
    final String? picked = await showFushiChoiceDialog<String>(
      context: context,
      title: t.audiobook_tts_concurrency,
      message: t.audiobook_tts_concurrency_hint,
      selected: current,
      options: <FushiChoiceOption<String>>[
        FushiChoiceOption<String>(
          value: '',
          label: t.audiobook_tts_concurrency_default(n: fallback),
        ),
        for (int n = 1; n <= kTtsMaxConcurrency; n++)
          FushiChoiceOption<String>(value: '$n', label: '$n'),
      ],
    );
    if (picked == null || !mounted) return;
    final Map<String, String> params = <String, String>{..._preset.params};
    if (picked.isEmpty) {
      params.remove(kTtsConcurrencyParam);
    } else {
      params[kTtsConcurrencyParam] = picked;
    }
    widget.onChanged(_preset.copyWith(params: params));
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
      case TtsParamKind.voice:
        final String id = _preset.param(spec.key, fallback: spec.defaultValue);
        final String name = _preset.param('${spec.key}$_kVoiceNameSuffix');
        return KeyedSubtree(
          key: ValueKey<String>('tts-voice-param-${spec.key}'),
          child: AdaptiveSettingsRow(
            title: label,
            subtitle: id.isEmpty
                ? t.audiobook_tts_voice_pick
                : (name.isEmpty || name == id ? id : '$name · $id'),
            subtitleMaxLines: 2,
            onTap: _fetchingVoices ? null : () => unawaited(_pickVoice(spec)),
            trailing: _fetchingVoices
                ? const SizedBox.square(
                    dimension: 18,
                    child: FushiCircularProgressIndicator(strokeWidth: 2),
                  )
                : FushiIcon(
                    FushiIcons.chevronRight,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
          ),
        );
      case TtsParamKind.url:
      case TtsParamKind.text:
      case TtsParamKind.secret:
        return field(
          _textField(
            key: ValueKey<String>('tts-voice-param-${spec.key}'),
            label: label,
            controller: _controllerFor(spec),
            hintText: ttsParamHint(_preset.providerId, spec.key),
            errorText: invalid && _controllerFor(spec).text.isNotEmpty
                ? t.audiobook_tts_param_invalid
                : _localReferenceProblem(spec),
            obscureText: spec.kind == TtsParamKind.secret,
            keyboardType: spec.kind == TtsParamKind.url
                ? TextInputType.url
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
