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

import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/tts/local/gpt_sovits_local_engine.dart';
import 'package:fushi_engine/tts/local/gpt_sovits_local_server.dart';
import 'package:fushi_engine/tts/local/irodori_local_engine.dart';
import 'package:fushi_engine/tts/local/local_service_process.dart';
import 'package:fushi_engine/tts/local/local_service_support.dart';
import 'package:fushi_engine/tts/local/voicevox_local_engine.dart';
import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/providers/gpt_sovits_tts_provider.dart';
import 'package:fushi_engine/tts/providers/irodori_server_tts_provider.dart';
import 'package:fushi_engine/tts/providers/translate_tts_providers.dart';
import 'package:fushi_engine/tts/providers/voicepeak_tts_provider.dart';
import 'package:fushi_engine/tts/providers/voicevox_tts_provider.dart';
import 'package:fushi_engine/tts/tts_audio_probe.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/tts/gpt_sovits_local_page.dart';
import 'package:fushi/src/media/audiobook/tts/irodori_local_page.dart';
import 'package:fushi/src/media/audiobook/tts/system_tts_provider.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_two_pane_layout.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/audiobook/tts/tts_ui_text.dart';
import 'package:fushi/src/media/audiobook/tts/tts_voice_list_layout.dart';
import 'package:fushi/src/media/audiobook/tts/voicevox_local_page.dart';
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

/// 参考音频能选的扩展名（GPT-SoVITS 经 librosa / ffmpeg 读，常见格式都认）。
const Set<String> _kReferenceAudioExtensions = <String>{
  'wav',
  'mp3',
  'flac',
  'ogg',
  'm4a',
};

/// 服务地址是不是本机回环地址：是的话服务端看得到本机文件，参考音频可以直接
/// 在本机选；局域网 / 远端服务只能填服务端那台机器上的路径。
bool ttsEndpointIsLoopback(String endpoint) {
  final Uri? uri = Uri.tryParse(endpoint.trim());
  if (uri == null) return false;
  final String host = uri.host.toLowerCase();
  return host == 'localhost' ||
      host == '::1' ||
      host == '[::1]' ||
      host.startsWith('127.');
}

/// 参考音频的文件名常常就是它的台词（GPT-SoVITS 训练集的惯例，例如
/// `こんにちは、今日もいい天気.wav`）。文件名里有假名或汉字时拿它预填参考文本；
/// `ref.wav` 这类无意义的名字返回 null。
String? ttsPromptTextFromFileName(String path) {
  // 路径可能来自别的平台（Windows 盘符路径同步到 Android / Linux 等），两种分隔符都切，
  // 不能只靠 p.basename 按当前平台切分。
  final String fileName = path.split(RegExp(r'[\\/]')).last;
  String stem = p.basenameWithoutExtension(fileName).trim();
  // 常见的情感 / 序号前缀：`【開心】…`、`[happy]…`、`001_…`。
  stem = stem.replaceFirst(RegExp(r'^(【[^】]*】|\[[^\]]*\]|\d+[_\-\s])+'), '');
  stem = stem.trim();
  if (stem.isEmpty) return null;
  final bool hasCjk = RegExp(r'[぀-ヿ㐀-鿿ｦ-ﾟ]').hasMatch(stem);
  return hasCjk ? stem : null;
}

/// 「选择文件」复制进来的参考音频所在目录名（app 数据目录下）。
const String kTtsReferenceAudioDirName = 'tts_reference_audio';

/// 删掉 [removed] 这份声音后，它的参考音频副本能不能一起删：只认 app 复制进
/// [referenceDir] 的文件（用户手填的任意路径绝不碰），且 [remaining] 里没有别的
/// 声音还在用。能删返回该路径，否则 null。
String? ttsOrphanedReferenceAudio({
  required TtsVoicePreset removed,
  required Iterable<TtsVoicePreset> remaining,
  required String referenceDir,
}) {
  if (removed.providerId != GptSovitsTtsDescriptor.providerId) return null;
  final String path = removed.param(GptSovitsTtsDescriptor.refAudioKey).trim();
  if (path.isEmpty || !p.isWithin(referenceDir, path)) return null;
  final String normalized = p.normalize(path);
  for (final TtsVoicePreset other in remaining) {
    final String used = other.param(GptSovitsTtsDescriptor.refAudioKey).trim();
    if (used.isNotEmpty && p.equals(p.normalize(used), normalized)) {
      return null;
    }
  }
  return path;
}

/// 删掉 [id] 这份声音后的清单与使用中的声音：删的正是使用中的就退回第一份
/// （一份不剩则为 null）。设置页与 `fushi_cli voice rm` 共用。
({List<TtsVoicePreset> presets, String? activeId}) ttsPresetsAfterDelete(
  List<TtsVoicePreset> presets,
  String? activeId,
  String id,
) {
  final List<TtsVoicePreset> remaining = <TtsVoicePreset>[
    for (final TtsVoicePreset preset in presets)
      if (preset.id != id) preset,
  ];
  return (
    presets: remaining,
    activeId: activeId == id
        ? (remaining.isEmpty ? null : remaining.first.id)
        : activeId,
  );
}

/// 删声音时一并清掉它独占的参考音频副本（「选择文件」复制进数据目录的那份）。
/// 设置页与 `fushi_cli voice rm` 共用。
Future<void> deleteOrphanedTtsReferenceAudio(
  TtsVoicePreset removed,
  Iterable<TtsVoicePreset> remaining,
) async {
  try {
    final Directory support = await enginePaths.supportRootDirectory();
    final String? orphan = ttsOrphanedReferenceAudio(
      removed: removed,
      remaining: remaining,
      referenceDir: p.join(support.path, kTtsReferenceAudioDirName),
    );
    if (orphan == null) return;
    final File file = File(orphan);
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // 删不掉（被占用）只是留一个小文件，不影响删除声音本身。
  }
}

/// 新建 / 换引擎时的初始参数：引擎声明的非凭据默认值。
Map<String, String> ttsDefaultParams(TtsProviderDescriptor descriptor) =>
    <String, String>{
      for (final TtsParamSpec spec in descriptor.params)
        if (spec.kind != TtsParamKind.secret && spec.defaultValue != null)
          spec.key: spec.defaultValue!,
    };

/// 新声音预设的 id（随机、不可猜，跨设备不撞）。
String newTtsPresetId() {
  final Random random = Random.secure();
  return 'tts_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${random.nextInt(1 << 32).toRadixString(36)}';
}

/// [openPresetId]：打开后直接定位并编辑这份声音（刚在「本机 GPT-SoVITS」页新建的）。
Future<void> openTtsVoiceSettingsPage(
  BuildContext context,
  TtsServices tts, {
  String? openPresetId,
}) async {
  final NavigatorState navigator = Navigator.of(context);
  await tts.seedBuiltinVoiceIfUnset();
  await navigator.push<void>(
    MaterialPageRoute<void>(
      builder: (_) =>
          TtsVoiceSettingsPage(services: tts, openPresetId: openPresetId),
    ),
  );
}

/// 「添加声音」里「本机一键部署」那一项的值（其余项是 [TtsProviderCategory]）。
const String _kAddLocalGptSovits = 'local_gpt_sovits';

/// 「添加声音」里「本机一键部署 Irodori-TTS」那一项的值。
const String _kAddLocalIrodori = 'local_irodori';

class TtsVoiceSettingsPage extends StatefulWidget {
  const TtsVoiceSettingsPage({
    required this.services,
    this.openPresetId,
    super.key,
  });

  final TtsServices services;
  final String? openPresetId;

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
    final String? open = widget.openPresetId;
    if (open != null) _focusPreset(open);
  }

  /// 选中 [id]；窄屏再推进它的编辑页（宽屏右侧窗格已经显示它）。
  void _focusPreset(String id) {
    _selectedId = id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!ttsUsesWideLayout(MediaQuery.sizeOf(context).width)) {
        unawaited(_openEditor(id));
      }
    });
  }

  /// 本机部署页（GPT-SoVITS / [irodori] 时 Irodori-TTS / 给了 [voicevox] 时该
  /// VOICEVOX 兼容引擎）新建了声音：重读清单、定位到它。
  Future<void> _openLocalDeploy({
    required bool wide,
    bool irodori = false,
    VoicevoxLocalEngine? voicevox,
  }) async {
    // 那边直接读写预设仓：先把防抖中的编辑落盘，回来重读时才不丢。
    if (_saveDebounce?.isActive ?? false) {
      _saveDebounce!.cancel();
      await _store.savePresets(_presets);
      if (!mounted) return;
    }
    final String? created = voicevox != null
        ? await openVoicevoxLocalPage(context, widget.services, voicevox)
        : irodori
        ? await openIrodoriLocalPage(context, widget.services)
        : await openGptSovitsLocalPage(context, widget.services);
    if (created == null || !mounted) return;
    setState(() {
      _presets = _store.loadPresets();
      _activeId = _store.activePreset()?.id;
      _selectedId = created;
    });
    if (!wide) unawaited(_openEditor(created));
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
    final TtsVoicePreset? removed = _presets
        .where((TtsVoicePreset p) => p.id == id)
        .firstOrNull;
    setState(() {
      final ({List<TtsVoicePreset> presets, String? activeId}) next =
          ttsPresetsAfterDelete(_presets, _activeId, id);
      _presets = next.presets;
      _activeId = next.activeId;
    });
    _saveDebounce?.cancel();
    await _store.savePresets(_presets);
    await _store.setActivePresetId(_activeId);
    if (removed != null) {
      await deleteOrphanedTtsReferenceAudio(removed, _presets);
    }
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
    final Object? choice = await showFushiChoiceDialog<Object>(
      context: context,
      title: t.audiobook_tts_voice_add_title,
      icon: FushiIcons.voice,
      options: <FushiChoiceOption<Object>>[
        // 自己没有服务的用户最该走的一条：放最前。
        if (widget.services.localGptSovits.isSupported)
          FushiChoiceOption<Object>(
            value: _kAddLocalGptSovits,
            label: t.audiobook_tts_local_add,
            subtitle: t.audiobook_tts_local_add_hint,
            icon: FushiIcons.download,
          ),
        if (widget.services.localIrodori.isSupported)
          FushiChoiceOption<Object>(
            value: _kAddLocalIrodori,
            label: t.audiobook_tts_irodori_local_add,
            subtitle: t.audiobook_tts_irodori_local_add_hint,
            icon: FushiIcons.download,
          ),
        for (final VoicevoxLocalEngine engine in <VoicevoxLocalEngine>[
          widget.services.localVoicevox,
          widget.services.localAivisSpeech,
        ])
          if (engine.isSupported)
            FushiChoiceOption<Object>(
              value: engine,
              label: t.audiobook_tts_voicevox_local_add(
                engine: voicevoxLocalEngineName(engine),
              ),
              subtitle: voicevoxLocalAddHint(engine),
              icon: FushiIcons.download,
            ),
        for (final TtsProviderCategory c in categories)
          FushiChoiceOption<Object>(
            value: c,
            label: ttsCategoryLabel(c),
            subtitle: ttsCategoryHint(c),
            icon: _categoryIcon(c),
          ),
      ],
    );
    if (choice == null || !mounted) return;
    if (choice == _kAddLocalGptSovits) {
      await _openLocalDeploy(wide: wide);
      return;
    }
    if (choice == _kAddLocalIrodori) {
      await _openLocalDeploy(wide: wide, irodori: true);
      return;
    }
    if (choice is VoicevoxLocalEngine) {
      await _openLocalDeploy(wide: wide, voicevox: choice);
      return;
    }
    final TtsProviderCategory picked = choice as TtsProviderCategory;
    final TtsProviderDescriptor descriptor = _registry.available.firstWhere(
      (TtsProviderDescriptor d) => d.category == picked,
    );
    final TtsVoicePreset preset = TtsVoicePreset(
      id: newTtsPresetId(),
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
    // 经列表页打开：那边新建的声音要并进本页的 `_presets`，否则下一次防抖落盘会用
    // 旧清单把它覆盖掉。
    onOpenLocalDeploy: () => unawaited(
      _openLocalDeploy(
        wide: embedded,
        irodori: preset.providerId == IrodoriServerTtsDescriptor.providerId,
        voicevox: widget.services.voicevoxLocalFor(preset.providerId),
      ),
    ),
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
    required this.onOpenLocalDeploy,
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
  final VoidCallback onOpenLocalDeploy;

  @override
  State<_TtsVoiceEditorPage> createState() => _TtsVoiceEditorPageState();
}

class _TtsVoiceEditorPageState extends State<_TtsVoiceEditorPage> {
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};
  late final TextEditingController _testText = TextEditingController(
    text: _autoTestText,
  );

  /// 当前自动给出的试听文本（跟随所选语言 / 声音，见 [ttsSampleTextFor]）。
  /// 输入框还是它时换语言 / 声音就跟着换；用户改过文字就不再覆盖。
  late String _autoTestText = ttsSampleTextFor(ttsPresetLanguage(_preset));

  void _followTestLanguage(String? languageTag) {
    final String next = ttsSampleTextFor(languageTag);
    if (_testText.text == _autoTestText && next != _autoTestText) {
      _testText.text = next;
    }
    _autoTestText = next;
  }

  bool _testing = false;
  bool _fetchingVoices = false;
  ({bool ok, String message})? _testResult;
  AudioPlayer? _testPlayer;
  StreamSubscription<PlayerState>? _testPlayerSub;
  TtsCancelToken? _testCancel;

  TtsVoicePreset get _preset => widget.preset;

  GptSovitsLocalEngine get _local => widget.services.localGptSovits;
  IrodoriLocalEngine get _localIrodori => widget.services.localIrodori;

  /// VOICEPEAK 找可执行文件的结果（null = 还没找过 / 不是 VOICEPEAK）。
  ({bool found, String message})? _voicepeakDetect;
  bool _voicepeakDetecting = false;

  @override
  void initState() {
    super.initState();
    _local.addListener(_onLocalEngine);
    _localIrodori.addListener(_onLocalEngine);
    widget.services.localVoicevox.addListener(_onLocalEngine);
    widget.services.localAivisSpeech.addListener(_onLocalEngine);
    _maybeAutoDetectVoicepeak(_preset);
  }

  void _onLocalEngine() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _local.removeListener(_onLocalEngine);
    _localIrodori.removeListener(_onLocalEngine);
    widget.services.localVoicevox.removeListener(_onLocalEngine);
    widget.services.localAivisSpeech.removeListener(_onLocalEngine);
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
    final TtsVoicePreset next = TtsVoicePreset(
      id: _preset.id,
      providerId: picked.id,
      name: defaultName ? ttsProviderLabel(picked.id) : _preset.name,
      params: ttsDefaultParams(picked),
    );
    widget.onChanged(next);
    setState(() {
      _testResult = null;
      _voicepeakDetect = null;
    });
    _maybeAutoDetectVoicepeak(next);
  }

  /// VOICEPEAK 声音的程序路径不存在时自动找一次已装的（默认目录、Windows 注册表
  /// 卸载项、macOS 的 Applications），找到就填进去。
  void _maybeAutoDetectVoicepeak(TtsVoicePreset preset) {
    if (preset.providerId != VoicepeakTtsDescriptor.providerId) return;
    final String current = preset
        .param(
          VoicepeakTtsDescriptor.executableKey,
          fallback: voicepeakDefaultExecutable(),
        )
        .trim();
    if (current.isNotEmpty && File(current).existsSync()) return;
    unawaited(_detectVoicepeak(preset));
  }

  Future<void> _detectVoicepeak([TtsVoicePreset? base]) async {
    if (_voicepeakDetecting) return;
    setState(() => _voicepeakDetecting = true);
    final String? found = await detectVoicepeakExecutable();
    if (!mounted) return;
    setState(() {
      _voicepeakDetecting = false;
      _voicepeakDetect = found == null
          ? (found: false, message: t.audiobook_tts_voicepeak_not_found)
          : (
              found: true,
              message: t.audiobook_tts_voicepeak_found(path: found),
            );
    });
    if (found == null) return;
    final TtsVoicePreset preset = base ?? _preset;
    if (preset.providerId != VoicepeakTtsDescriptor.providerId) return;
    _controllers[VoicepeakTtsDescriptor.executableKey]?.text = found;
    widget.onChanged(
      preset.copyWith(
        params: <String, String>{
          ...preset.params,
          VoicepeakTtsDescriptor.executableKey: found,
        },
      ),
    );
  }

  /// 手动选 VOICEPEAK 的可执行文件（Windows 限 .exe；macOS / Linux 的可执行文件
  /// 没有扩展名，不限）。
  Future<void> _pickExecutable(TtsParamSpec spec) async {
    final String? picked = await pickSystemFilePath(
      context: context,
      allowedExtensions: Platform.isWindows ? const <String>{'exe'} : null,
    );
    if (picked == null || !mounted) return;
    _controllerFor(spec).text = picked;
    _setParam(spec, picked);
    setState(() => _voicepeakDetect = null);
  }

  /// VOICEPEAK 的「查找已安装的 VOICEPEAK」行：找不到时给购买 / 安装指引。
  Widget? _voicepeakRow() {
    if (_preset.providerId != VoicepeakTtsDescriptor.providerId) return null;
    final ({bool found, String message})? detect = _voicepeakDetect;
    return KeyedSubtree(
      key: const ValueKey<String>('tts-voice-voicepeak-detect'),
      child: AdaptiveSettingsRow(
        icon: FushiIcons.search,
        showIcon: true,
        title: t.audiobook_tts_voicepeak_detect,
        subtitle: detect?.message,
        subtitleMaxLines: 5,
        onTap: _voicepeakDetecting ? null : () => unawaited(_detectVoicepeak()),
        trailing: _voicepeakDetecting
            ? const SizedBox.square(
                dimension: 18,
                child: FushiCircularProgressIndicator(strokeWidth: 2),
              )
            : null,
      ),
    );
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
    if (_preset.providerId == GptSovitsTtsDescriptor.providerId &&
        spec.key == GptSovitsTtsDescriptor.textLangKey) {
      _followTestLanguage(ttsLanguageCodeToTag(value));
    }
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
      voices = await provider.listParamOptions(spec.key);
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
        // 非必填的声音类参数（系统语音的引擎 / 声音）可以不选：空 = 引擎默认行为。
        if (!spec.required)
          FushiChoiceOption<String>(
            value: '',
            label: ttsParamEmptyLabel(spec.key),
          ),
        for (final TtsVoice v in sorted)
          FushiChoiceOption<String>(
            value: v.id,
            label: v.displayName == v.id ? v.id : '${v.displayName} · ${v.id}',
            subtitle: <String>[
              if (v.locale.isNotEmpty) v.locale,
              if (v.gender != null) v.gender!,
            ].join(' · '),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    final Map<String, String> params = <String, String>{..._preset.params};
    if (picked.isEmpty) {
      params
        ..remove(spec.key)
        ..remove('${spec.key}$_kVoiceNameSuffix');
    } else {
      final TtsVoice chosen = sorted.firstWhere((TtsVoice v) => v.id == picked);
      // 显示名只给界面用（不在参数表里，不进缓存键）：Irodori 的声音 id 是不透明串。
      params[spec.key] = picked;
      params['${spec.key}$_kVoiceNameSuffix'] = chosen.displayName;
      // 声音带语言（Edge / Azure / 系统语音等）：试听文本换成该语言的示例句。
      if (chosen.locale.isNotEmpty) _followTestLanguage(chosen.locale);
    }
    // 系统语音的声音属于某个引擎：换了引擎，旧引擎的声音名在新引擎里没有意义。
    if (_preset.providerId == SystemTtsDescriptor.providerId &&
        spec.key == SystemTtsDescriptor.engineKey &&
        picked != current) {
      params
        ..remove(SystemTtsDescriptor.voiceKey)
        ..remove('${SystemTtsDescriptor.voiceKey}$_kVoiceNameSuffix');
    }
    widget.onChanged(_preset.copyWith(params: params));
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

  /// 本机服务：选一个本机音频文件，复制进 app 数据目录（原文件挪走 / 删掉也不
  /// 影响朗读）再填进参考音频路径；参考文本还空着时按文件名预填。
  Future<void> _pickReferenceAudio(TtsParamSpec spec) async {
    final String? picked = await pickSystemFilePath(
      context: context,
      allowedExtensions: _kReferenceAudioExtensions,
    );
    if (picked == null || !mounted) return;
    final String stored;
    try {
      final Directory support = await enginePaths.supportRootDirectory();
      final Directory dir = Directory(
        p.join(support.path, kTtsReferenceAudioDirName),
      );
      await dir.create(recursive: true);
      // 同名不同文件互不覆盖：时间戳前缀。原名保留，方便用户认。
      final String target = p.join(
        dir.path,
        '${DateTime.now().millisecondsSinceEpoch}_${p.basename(picked)}',
      );
      stored = (await File(picked).copy(target)).path;
    } on FileSystemException {
      if (mounted) {
        setState(
          () => _testResult = (
            ok: false,
            message: t.audiobook_tts_param_ref_audio_copy_failed,
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    _controllerFor(spec).text = stored;
    final Map<String, String> params = <String, String>{
      ..._preset.params,
      spec.key: stored,
    };
    final String? prompt = ttsPromptTextFromFileName(picked);
    const String promptKey = GptSovitsTtsDescriptor.promptTextKey;
    if (prompt != null && _preset.param(promptKey).trim().isEmpty) {
      params[promptKey] = prompt;
      _controllers[promptKey]?.text = prompt;
    }
    widget.onChanged(_preset.copyWith(params: params));
    setState(() => _testResult = null);
  }

  Future<void> _pickChoice(TtsParamSpec spec) async {
    final String current = _preset.param(spec.key, fallback: spec.defaultValue);
    final String? picked = await showFushiChoiceDialog<String>(
      context: context,
      title: ttsParamLabel(spec.key),
      selected: current,
      options: <FushiChoiceOption<String>>[
        for (final String c in spec.choices)
          FushiChoiceOption<String>(
            value: c,
            label: ttsLanguageLabel(c),
            subtitle: ttsLanguageLabel(c) == c ? null : c,
          ),
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
          if (_localServiceRow() case final Widget row) row,
          if (_voicepeakRow() case final Widget row) row,
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

  /// GPT-SoVITS 声音指向本机时：已部署就显示本机服务状态，没部署就给一键部署入口。
  /// 局域网 / 远端地址、不支持一键部署的平台不显示。
  Widget? _localServiceRow() {
    if (_preset.providerId == IrodoriServerTtsDescriptor.providerId) {
      return _localIrodoriRow();
    }
    if (widget.services.voicevoxLocalFor(_preset.providerId)
        case final VoicevoxLocalEngine engine) {
      return _localVoicevoxRow(engine);
    }
    if (_preset.providerId != GptSovitsTtsDescriptor.providerId ||
        !_local.isSupported) {
      return null;
    }
    final String endpoint = _preset.param(
      GptSovitsTtsDescriptor.endpointKey,
      fallback: 'http://127.0.0.1:9880',
    );
    if (!ttsEndpointIsLoopback(endpoint)) return null;
    final bool installed = _local.isInstalled;
    final bool managed = gptSovitsEndpointIsManaged(
      endpoint,
      _local.settings.port,
    );
    if (installed && !managed) return null;
    final String subtitle = !installed
        ? t.audiobook_tts_local_editor_not_installed
        : switch (_local.server.phase) {
            GptSovitsServerPhase.running =>
              t.audiobook_tts_local_server_running(endpoint: _local.endpoint),
            GptSovitsServerPhase.starting =>
              t.audiobook_tts_local_server_starting,
            _ => t.audiobook_tts_local_server_stopped,
          };
    return KeyedSubtree(
      key: const ValueKey<String>('tts-voice-local-service'),
      child: AdaptiveSettingsRow(
        icon: installed ? FushiIcons.server : FushiIcons.download,
        showIcon: true,
        title: t.audiobook_tts_local_title,
        subtitle: subtitle,
        subtitleMaxLines: 3,
        onTap: widget.onOpenLocalDeploy,
      ),
    );
  }

  /// VOICEVOX / AivisSpeech 声音指向本机时的同一行：已部署显示服务状态，没部署给
  /// 一键部署入口。
  Widget? _localVoicevoxRow(VoicevoxLocalEngine engine) {
    if (!engine.isSupported) return null;
    final String endpoint = _preset.param(
      VoicevoxCompatibleTtsDescriptor.endpointKey,
      fallback: 'http://127.0.0.1:${engine.manifest.defaultPort}',
    );
    if (!ttsEndpointIsLoopback(endpoint)) return null;
    final bool installed = engine.isInstalled;
    final bool managed = localServiceEndpointIsManaged(
      endpoint,
      engine.settings.port,
    );
    if (installed && !managed) return null;
    final String name = voicevoxLocalEngineName(engine);
    final String subtitle = !installed
        ? t.audiobook_tts_voicevox_local_editor_not_installed(engine: name)
        : switch (engine.server.phase) {
            LocalServicePhase.running => t.audiobook_tts_local_server_running(
              endpoint: engine.endpoint,
            ),
            LocalServicePhase.starting => t.audiobook_tts_local_server_starting,
            _ => t.audiobook_tts_local_server_stopped,
          };
    return KeyedSubtree(
      key: const ValueKey<String>('tts-voice-local-voicevox'),
      child: AdaptiveSettingsRow(
        icon: installed ? FushiIcons.server : FushiIcons.download,
        showIcon: true,
        title: t.audiobook_tts_voicevox_local_title(engine: name),
        subtitle: subtitle,
        subtitleMaxLines: 3,
        onTap: widget.onOpenLocalDeploy,
      ),
    );
  }

  /// Irodori-TTS（官方服务）声音指向本机时的同一行：已部署显示服务状态，没部署给
  /// 一键部署入口。
  Widget? _localIrodoriRow() {
    if (!_localIrodori.isSupported) return null;
    final String endpoint = _preset.param(
      IrodoriServerTtsDescriptor.endpointKey,
      fallback: IrodoriServerTtsDescriptor.defaultEndpoint,
    );
    if (!ttsEndpointIsLoopback(endpoint)) return null;
    final bool installed = _localIrodori.isInstalled;
    final bool managed = localServiceEndpointIsManaged(
      endpoint,
      _localIrodori.settings.port,
    );
    if (installed && !managed) return null;
    final String subtitle = !installed
        ? t.audiobook_tts_irodori_local_editor_not_installed
        : switch (_localIrodori.server.phase) {
            LocalServicePhase.running => t.audiobook_tts_local_server_running(
              endpoint: _localIrodori.endpoint,
            ),
            LocalServicePhase.starting => t.audiobook_tts_local_server_starting,
            _ => t.audiobook_tts_local_server_stopped,
          };
    return KeyedSubtree(
      key: const ValueKey<String>('tts-voice-local-irodori'),
      child: AdaptiveSettingsRow(
        icon: installed ? FushiIcons.server : FushiIcons.download,
        showIcon: true,
        title: t.audiobook_tts_irodori_local_title,
        subtitle: subtitle,
        subtitleMaxLines: 3,
        onTap: widget.onOpenLocalDeploy,
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
              ttsLanguageLabel(
                _preset.param(spec.key, fallback: spec.defaultValue),
              ),
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
                ? (spec.required
                      ? t.audiobook_tts_voice_pick
                      : ttsParamEmptyLabel(spec.key))
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
            hintText: _canPickReferenceAudio(spec)
                ? t.audiobook_tts_param_ref_audio_local_hint
                : ttsParamHint(_preset.providerId, spec.key),
            errorText: invalid && _controllerFor(spec).text.isNotEmpty
                ? t.audiobook_tts_param_invalid
                : _localReferenceProblem(spec),
            obscureText: spec.kind == TtsParamKind.secret,
            keyboardType: spec.kind == TtsParamKind.url
                ? TextInputType.url
                : null,
            suffixIcon: _canPickReferenceAudio(spec)
                ? FushiIconButton(
                    key: const ValueKey<String>('tts-voice-ref-audio-pick'),
                    icon: FushiIcons.folderOpen,
                    tooltip: t.audiobook_tts_param_ref_audio_pick,
                    onTap: () => unawaited(_pickReferenceAudio(spec)),
                  )
                : _isVoicepeakExecutable(spec)
                ? FushiIconButton(
                    key: const ValueKey<String>('tts-voice-executable-pick'),
                    icon: FushiIcons.folderOpen,
                    tooltip: t.audiobook_tts_param_executable_pick,
                    onTap: () => unawaited(_pickExecutable(spec)),
                  )
                : null,

            onChanged: (String v) => _setParam(spec, v.trim()),
          ),
        );
    }
  }

  bool _isVoicepeakExecutable(TtsParamSpec spec) =>
      _preset.providerId == VoicepeakTtsDescriptor.providerId &&
      spec.key == VoicepeakTtsDescriptor.executableKey;

  /// 参考音频行带「选择文件」：只在 GPT-SoVITS 服务就是本机时才有意义。
  bool _canPickReferenceAudio(TtsParamSpec spec) =>
      _preset.providerId == GptSovitsTtsDescriptor.providerId &&
      spec.key == GptSovitsTtsDescriptor.refAudioKey &&
      ttsEndpointIsLoopback(
        _preset.param(
          GptSovitsTtsDescriptor.endpointKey,
          fallback: 'http://127.0.0.1:9880',
        ),
      );

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
