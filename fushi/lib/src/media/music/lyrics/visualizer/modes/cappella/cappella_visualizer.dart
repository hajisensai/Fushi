/// 全屏歌词动画样式「群唱」（移植自 folia-major `src/components/visualizer/cappella/`）。
///
/// 歌词化成聊天气泡左右往返：TTML 有多位演唱者时按演唱者分配发送者（第一位在右侧当
/// 「我」），否则按强度参数的左右序列 / 翻转 / 短句沿用规则确定性地编排；当前句气泡放大、
/// 逐字淡入、气泡宽度提前补间、斜向高光扫过，唱完后在气泡外侧露出结束时间戳；长间奏
/// 换成表情贴纸，偶尔在句后插一个表情回复。译文 / 下一句交给宿主的共享字幕。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_avatar.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_config.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_messages.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_scene.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_backdrop.dart'
    show musicLyricsBackdropCoverProvider;
import 'package:fushi/src/utils/fushi_icons.dart';

/// 参数键（落库，冻结；与 folia `CappellaTuning` 同名）。
const String kCappellaTuningAvatarSource = 'avatarSource';
const String kCappellaTuningShowEmo = 'showEmoMessages';
const String kCappellaTuningIntensity = 'intensity';

/// 可调参数（folia `tuning.ts`：头像来源、显示表情包；动画强度在 folia 来自主题，这里作参数）。
final List<LyricVisualizerTuningSpec> cappellaTunings =
    <LyricVisualizerTuningSpec>[
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
        ],
        initial: CappellaAvatarSource.cover.value,
      ),
      LyricVisualizerToggleSpec(
        key: kCappellaTuningShowEmo,
        label: () => t.music_visualizer_cappella_show_stickers,
        initial: true,
      ),
      LyricVisualizerChoiceSpec(
        key: kCappellaTuningIntensity,
        label: () => t.music_visualizer_cappella_intensity,
        options: <(String, String Function())>[
          (
            CappellaIntensity.calm.value,
            () => t.music_visualizer_cappella_intensity_calm,
          ),
          (
            CappellaIntensity.normal.value,
            () => t.music_visualizer_cappella_intensity_normal,
          ),
          (
            CappellaIntensity.chaotic.value,
            () => t.music_visualizer_cappella_intensity_chaotic,
          ),
        ],
        initial: CappellaIntensity.normal.value,
      ),
    ];

/// 注册项。
final LyricVisualizerEntry cappellaVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.cappella,
  label: () => t.music_visualizer_mode_cappella,
  description: () => t.music_visualizer_cappella_description,
  icon: FushiIcons.forum,
  tunings: cappellaTunings,
  sharedBackdrop: true,
  sharedSubtitle: true,
  builder: (LyricVisualizerContext c) => CappellaVisualizer(context: c),
);

/// 群唱样式本体：纯展示，不接手势（点按退出由宿主处理）。
class CappellaVisualizer extends StatefulWidget {
  const CappellaVisualizer({super.key, required this.context});

  final LyricVisualizerContext context;

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

  ImageStream? _coverStream;
  ImageStreamListener? _coverListener;
  ImageInfo? _coverInfo;
  String? _coverPath;

  @override
  void initState() {
    super.initState();
    _scene = CappellaScene(_buildConfig());
    _loadCover();
  }

  @override
  void didUpdateWidget(covariant CappellaVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scene.update(_buildConfig());
    _revision++;
    if (widget.context.coverPath != _coverPath) _loadCover();
  }

  @override
  void dispose() {
    _detachCover();
    _coverInfo?.dispose();
    _scene.dispose();
    super.dispose();
  }

  CappellaSceneConfig _buildConfig() {
    final LyricVisualizerContext c = widget.context;
    if (!identical(_linesFor, c.runtime)) {
      _linesFor = c.runtime;
      _lines = buildCappellaLines(c.runtime.lines);
    }
    final CappellaIntensity intensity = CappellaIntensity.fromValue(
      c.tuning.choice(kCappellaTuningIntensity, CappellaIntensity.normal.value),
    );
    final bool showEmo = c.tuning.flag(kCappellaTuningShowEmo, true);
    final String title = cappellaTitleText(c);
    final Object key = (_lines, intensity, showEmo, title);
    if (key != _messagesKey) {
      _messagesKey = key;
      _messages = buildCappellaMessages(
        lines: _lines,
        titleText: title,
        sequencing: cappellaIntensityConfig(intensity).sequencing,
        showEmo: showEmo,
        stickerPoolSize: kCappellaStickerCount,
      );
    }
    return CappellaSceneConfig(
      lines: _lines,
      messages: _messages,
      intensity: cappellaIntensityConfig(intensity),
      palette: c.palette,
      avatarSource: CappellaAvatarSource.fromValue(
        c.tuning.choice(
          kCappellaTuningAvatarSource,
          CappellaAvatarSource.cover.value,
        ),
      ),
      seed: c.seed,
      fontScale: c.fontScale,
      motionEnabled: c.motion,
      initials: cappellaAgentInitials(_lines, c),
    );
  }

  void _detachCover() {
    final ImageStreamListener? l = _coverListener;
    if (l != null) _coverStream?.removeListener(l);
    _coverStream = null;
    _coverListener = null;
  }

  void _loadCover() {
    _coverPath = widget.context.coverPath;
    _detachCover();
    _coverInfo?.dispose();
    _coverInfo = null;
    _scene.cover = null;
    final ImageProvider? provider = musicLyricsBackdropCoverProvider(
      _coverPath,
    );
    if (provider == null) return;
    final ImageStream stream = provider.resolve(ImageConfiguration.empty);
    final ImageStreamListener listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        if (!mounted) {
          info.dispose();
          return;
        }
        _coverInfo?.dispose();
        _coverInfo = info;
        _scene.cover = info.image;
        setState(() => _revision++);
      },
      onError: (Object _, StackTrace? _) {
        // 封面读不出来就用生成头像，不报错。
      },
    );
    _coverStream = stream;
    _coverListener = listener;
    stream.addListener(listener);
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
