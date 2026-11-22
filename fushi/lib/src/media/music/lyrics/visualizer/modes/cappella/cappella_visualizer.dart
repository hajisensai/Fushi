/// 全屏歌词动画样式「群唱」（移植自 folia-major `src/components/visualizer/cappella/`）。
///
/// 歌词化成聊天气泡左右往返：TTML 有多位演唱者时按演唱者分配发送者（第一位在右侧当
/// 「我」），否则按强度参数的左右序列 / 翻转 / 短句沿用规则确定性地编排；当前句气泡放大、
/// 逐字淡入、气泡宽度提前补间、斜向高光扫过，唱完后在气泡外侧露出结束时间戳；长间奏
/// 换成表情贴纸，偶尔在句后插一个表情回复。头像 / 表情可换成用户自己的素材包。译文 / 下一句
/// 交给宿主的共享字幕。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_cover.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_assets.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_avatar.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_config.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_messages.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_scene.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 参数键（落库，冻结；与 folia `CappellaTuning` 同名）。
const String kCappellaTuningAvatarSource = 'avatarSource';
const String kCappellaTuningShowEmo = 'showEmoMessages';
const String kCappellaTuningEmojiSource = 'emojiPackSource';

/// 素材包参数键（值是素材包名，见 `LyricVisualizerAssetPackSpec`）。
const String kCappellaTuningAvatarPack = 'avatarPack';
const String kCappellaTuningEmojiPack = 'emojiPack';

/// 表情包来源（落库值冻结，与 folia `emojiPackSource` 一致）。
const String kCappellaEmojiBuiltin = 'builtin';
const String kCappellaEmojiCustom = 'custom';

/// 可调参数（folia `tuning.ts`：头像来源、显示表情包、表情包来源，外加自定义头像 / 表情的素材包）。
/// 动画强度读共享的 `context.intensity`。
final List<LyricVisualizerTuningSpec>
cappellaTunings = <LyricVisualizerTuningSpec>[
  LyricVisualizerChoiceSpec(
    key: kCappellaTuningAvatarSource,
    label: () => t.music_visualizer_cappella_avatar_source,
    options: <(String, String Function())>[
      (
        CappellaAvatarSource.cover.value,
        () => t.music_visualizer_cappella_avatar_cover,
      ),
      (
        CappellaAvatarSource.generated.value,
        () => t.music_visualizer_cappella_avatar_generated,
      ),
      (
        CappellaAvatarSource.color.value,
        () => t.music_visualizer_cappella_avatar_color,
      ),
      (
        CappellaAvatarSource.custom.value,
        () => t.music_visualizer_cappella_avatar_custom,
      ),
    ],
    initial: CappellaAvatarSource.cover.value,
  ),
  LyricVisualizerAssetPackSpec(
    key: kCappellaTuningAvatarPack,
    label: () => t.music_visualizer_cappella_avatar_pack,
    style: kCappellaAssetStyle,
    initial: 'avatars',
    maxFiles: kCappellaMaxPackImages,
    visibleWhen: (LyricVisualizerTuning v) =>
        v.choice(kCappellaTuningAvatarSource, '') ==
        CappellaAvatarSource.custom.value,
  ),
  LyricVisualizerToggleSpec(
    key: kCappellaTuningShowEmo,
    label: () => t.music_visualizer_cappella_show_stickers,
    initial: true,
  ),
  LyricVisualizerChoiceSpec(
    key: kCappellaTuningEmojiSource,
    label: () => t.music_visualizer_cappella_emoji_source,
    options: <(String, String Function())>[
      (kCappellaEmojiBuiltin, () => t.music_visualizer_cappella_emoji_builtin),
      (kCappellaEmojiCustom, () => t.music_visualizer_cappella_emoji_custom),
    ],
    initial: kCappellaEmojiBuiltin,
    visibleWhen: (LyricVisualizerTuning v) =>
        v.flag(kCappellaTuningShowEmo, true),
  ),
  LyricVisualizerAssetPackSpec(
    key: kCappellaTuningEmojiPack,
    label: () => t.music_visualizer_cappella_emoji_pack,
    style: kCappellaAssetStyle,
    initial: 'emoji',
    maxFiles: kCappellaMaxPackImages,
    visibleWhen: (LyricVisualizerTuning v) =>
        v.flag(kCappellaTuningShowEmo, true) &&
        v.choice(kCappellaTuningEmojiSource, '') == kCappellaEmojiCustom,
  ),
];

/// 注册项。
final LyricVisualizerEntry cappellaVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.cappella,
  label: () => t.music_visualizer_mode_cappella,
  description: () => t.music_visualizer_cappella_description,
  icon: FushiIcons.forum,
  tunings: cappellaTunings,
  // folia cappella 不改背景：画在用户选的共享背景上。
  background: (LyricVisualizerTuning _) =>
      LyricVisualizerBackgroundRequest.selected,
  sharedSubtitle: true,
  builder: (LyricVisualizerContext c) => CappellaVisualizer(context: c),
);

/// 生效的头像来源（folia：选了自定义但包里没有图时回落默认的封面）。
CappellaAvatarSource cappellaEffectiveAvatarSource(
  LyricVisualizerTuning tuning,
  int customCount,
) {
  final CappellaAvatarSource s = CappellaAvatarSource.fromValue(
    tuning.choice(
      kCappellaTuningAvatarSource,
      CappellaAvatarSource.cover.value,
    ),
  );
  return s == CappellaAvatarSource.custom && customCount == 0
      ? CappellaAvatarSource.cover
      : s;
}

/// 是否用自定义表情包（folia：选了自定义且包里有图）。
bool cappellaUsesCustomEmoji(LyricVisualizerTuning tuning, int customCount) =>
    tuning.choice(kCappellaTuningEmojiSource, kCappellaEmojiBuiltin) ==
        kCappellaEmojiCustom &&
    customCount > 0;

/// 群唱样式本体：纯展示，不接手势（点按退出由宿主处理）。
class CappellaVisualizer extends StatefulWidget {
  const CappellaVisualizer({
    super.key,
    required this.context,
    this.openAssetStore,
  });

  final LyricVisualizerContext context;

  /// 素材库入口（null = app 数据目录下的共享素材库；测试换成临时目录）。
  final CappellaAssetStoreOpener? openAssetStore;

  @override
  State<CappellaVisualizer> createState() => _CappellaVisualizerState();
}

class _CappellaVisualizerState extends State<CappellaVisualizer> {
  late CappellaScene _scene;
  int _revision = 0;

  // 由时间轴 / 参数派生，不变就复用（场景按 identical 判断要不要重置）。
  LyricVisualizerRuntime? _linesFor;
  List<CappellaLine> _lines = const <CappellaLine>[];
  Object? _messagesKey;
  List<CappellaMessage> _messages = const <CappellaMessage>[];

  final LyricVisualizerImageLoader _cover = LyricVisualizerImageLoader();
  late final CappellaAssetPack _avatarPack;
  late final CappellaAssetPack _emojiPack;

  /// initState 跑完前（缓存命中时图会同步回调）只记下、不 setState。
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _avatarPack = CappellaAssetPack(openStore: widget.openAssetStore)
      ..addListener(_assetsChanged);
    _emojiPack = CappellaAssetPack(openStore: widget.openAssetStore)
      ..addListener(_assetsChanged);
    _cover.addListener(_coverChanged);
    _loadPacks();
    _scene = CappellaScene(_buildConfig());
    _cover.load(widget.context.coverPath);
    _ready = true;
  }

  @override
  void didUpdateWidget(covariant CappellaVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadPacks();
    _scene.update(_buildConfig());
    _revision++;
    _cover.load(widget.context.coverPath);
  }

  @override
  void dispose() {
    _cover
      ..removeListener(_coverChanged)
      ..dispose();
    _avatarPack
      ..removeListener(_assetsChanged)
      ..dispose();
    _emojiPack
      ..removeListener(_assetsChanged)
      ..dispose();
    _scene.dispose();
    super.dispose();
  }

  /// 只在选了自定义来源时读素材包（folia 只在 custom 时用上传的图）。
  void _loadPacks() {
    final LyricVisualizerTuning tuning = widget.context.tuning;
    final bool customAvatar =
        tuning.choice(kCappellaTuningAvatarSource, '') ==
        CappellaAvatarSource.custom.value;
    _avatarPack.load(
      customAvatar
          ? tuning.assetPack(kCappellaTuningAvatarPack, 'avatars')
          : null,
    );
    final bool customEmoji =
        tuning.flag(kCappellaTuningShowEmo, true) &&
        tuning.choice(kCappellaTuningEmojiSource, kCappellaEmojiBuiltin) ==
            kCappellaEmojiCustom;
    _emojiPack.load(
      customEmoji ? tuning.assetPack(kCappellaTuningEmojiPack, 'emoji') : null,
    );
  }

  void _coverChanged() {
    if (!mounted) return;
    _scene.cover = _cover.image;
    if (_ready) setState(() => _revision++);
  }

  /// 素材包的图数变了（列完目录）要重排消息（表情池大小变了）；单张解完只需重画。
  void _assetsChanged() {
    if (!mounted || !_ready) return;
    _scene.update(_buildConfig());
    setState(() => _revision++);
  }

  CappellaSceneConfig _buildConfig() {
    final LyricVisualizerContext c = widget.context;
    if (!identical(_linesFor, c.runtime)) {
      _linesFor = c.runtime;
      _lines = buildCappellaLines(c.runtime.lines);
    }
    final LyricVisualizerIntensity intensity = c.intensity;
    final bool showEmo = c.tuning.flag(kCappellaTuningShowEmo, true);
    final bool customEmoji = cappellaUsesCustomEmoji(
      c.tuning,
      _emojiPack.length,
    );
    final int pool = customEmoji ? _emojiPack.length : kCappellaStickerCount;
    final String title = cappellaTitleText(c);
    final Object key = (_lines, intensity, showEmo, title, pool);
    if (key != _messagesKey) {
      _messagesKey = key;
      _messages = buildCappellaMessages(
        lines: _lines,
        titleText: title,
        sequencing: cappellaIntensityConfig(intensity).sequencing,
        showEmo: showEmo,
        stickerPoolSize: pool,
      );
    }
    return CappellaSceneConfig(
      lines: _lines,
      messages: _messages,
      intensity: cappellaIntensityConfig(intensity),
      palette: c.palette,
      avatarSource: cappellaEffectiveAvatarSource(c.tuning, _avatarPack.length),
      seed: c.seed,
      fontScale: c.fontScale,
      motionEnabled: c.motion,
      initials: cappellaAgentInitials(_lines, c),
      fontWeight: c.theme?.fontWeight ?? kCappellaBubbleFontWeight,
      fontFamily: c.theme?.fontFamily,
      avatarPool: _avatarPack,
      emojiPool: customEmoji ? _emojiPack : null,
    );
  }

  @override
  Widget build(BuildContext context) => LyricVisualizerFrame(
    context: widget.context,
    builder: (BuildContext bc, LyricVisualizerTicks ticks) => RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: CappellaPainter(
          scene: _scene,
          ticks: ticks,
          revision: _revision,
        ),
      ),
    ),
  );
}

/// 标题消息的文字（folia：歌名，没有时「无曲目」；这里退到专辑 / 艺人 / ♪）。
String cappellaTitleText(LyricVisualizerContext c) {
  for (final String? s in <String?>[c.title, c.album, c.artist]) {
    final String v = (s ?? '').trim();
    if (v.isNotEmpty) return v;
  }
  return '♪';
}

/// 演唱者发送者 → 首字母（只在按演唱者分配发送者、且演唱者有名字时有）。
Map<CappellaSender, String> cappellaAgentInitials(
  List<CappellaLine> lines,
  LyricVisualizerContext c,
) {
  final Map<int, CappellaSender>? senders = cappellaAgentSenders(lines);
  if (senders == null) return const <CappellaSender, String>{};
  final Map<CappellaSender, String> out = <CappellaSender, String>{};
  senders.forEach((int agent, CappellaSender sender) {
    if (agent < 0 || agent >= c.timeline.agents.length) return;
    final String? initial = cappellaAvatarInitial(
      c.timeline.agents[agent].name,
    );
    if (initial != null) out.putIfAbsent(sender, () => initial);
  });
  return out;
}
