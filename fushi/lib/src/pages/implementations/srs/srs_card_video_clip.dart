/// 原生 Fushi 卡面上的视频片段（视频制卡的 `<video class="fushi-inline-video">`）。
///
/// - 打开即停在第一帧当封面（`play: false`），尺寸与卡面图片同一套规则
///   （[srsCardMediaBoxSize]）：铺满模式下常见比例铺满栏宽、超过 [SrsCardVideoClip.maxFillHeight]
///   就等比缩小；否则按视频比例缩放进 [SrsCardVideoClip.maxWidth] ×
///   [SrsCardVideoClip.maxHeight]。圆角裁切。
/// - **自己不自动播放**：片段自带句子音频，何时出声由复习页的音频序列决定——它经
///   [SrsCardVideoChannel] 找到挂在卡面上的这段片段，从头播到尾（与 WebView 卡面里
///   「先播单词音频、再从头播一次片段」同一顺序）。
/// - 点按画面 = 播放 / 暂停；角上「重播」= 从头播；另一角「放大」= 弹出大画面查看（同一个
///   播放器，#10）。用户的任何点按都会打断正在进行的序列播放（与「手动点了别的音频，序列
///   就此停下」一致）。
/// - 片段不带例句声音（例句音频是另一个文件）时，它是例句音频的陪播画面
///   （[SrsCardSentenceCompanion]）：例句音频开播时从头**静音**播，同一时刻只有一路声音。
/// - 卸载 / 换片段时暂停并释放播放器；卡上引用了片段但本机文件不存在（媒体还没同步过来）
///   或打不开时，画同尺寸的「视频未同步」占位（[SrsCardMediaMissing]），不再什么都不画——
///   否则与「这张卡本来就没有视频」分不出来。
///
/// 播放器经 [srsCardVideoPlayerFactoryProvider] 创建：生产是 media_kit（libmpv），
/// widget 测试换假实现（测试里加载不了 libmpv）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/video/video_mpv_config.dart';
import 'package:fushi/src/srs/srs_card_video_channel.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_color_roles.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 卡面片段用的播放器（生产 = media_kit；测试换假实现）。
abstract class SrsCardVideoPlayer {
  /// 打开本地文件 [path]，停在开头（不出声）。
  Future<void> open(String path);

  Future<void> play();

  Future<void> pause();

  Future<void> seek(Duration position);

  /// [volume] 取 0–1（与 `srsReviewVolumeProvider` 同一刻度）。
  Future<void> setVolume(double volume);

  /// 是否在播。
  Stream<bool> get playingStream;

  /// 播到结尾时发 true（重新 seek 后回到 false）。
  Stream<bool> get completedStream;

  /// 视频画面尺寸（像素；宽高都已知且 > 0 时才发）。
  Stream<Size> get videoSizeStream;

  /// 此刻是否已播到结尾（点按播放时据此先回到开头）。
  bool get isCompleted;

  /// 画面（只有画面，不带任何控件）。
  Widget buildView();

  Future<void> dispose();
}

/// 创建一个卡面片段播放器。
typedef SrsCardVideoPlayerFactory = SrsCardVideoPlayer Function();

/// 卡面片段播放器工厂（测试覆写成假播放器）。
final Provider<SrsCardVideoPlayerFactory> srsCardVideoPlayerFactoryProvider =
    Provider<SrsCardVideoPlayerFactory>(
      (Ref ref) => _MediaKitSrsCardVideoPlayer.new,
    );

/// 生产实现：media_kit [Player] + [VideoController]。
class _MediaKitSrsCardVideoPlayer implements SrsCardVideoPlayer {
  _MediaKitSrsCardVideoPlayer() : _player = Player() {
    // 与视频页 / 反馈视频页同一套硬解取值：Windows 上不让 CUDA 后端进解码链（BUG-1639）。
    _controller = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        hwdec: resolvePlatformHwdec('auto-safe'),
      ),
    );
    _subs.add(_player.stream.width.listen((_) => _emitSize()));
    _subs.add(_player.stream.height.listen((_) => _emitSize()));
  }

  final Player _player;
  late final VideoController _controller;
  final StreamController<Size> _size = StreamController<Size>.broadcast();
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  void _emitSize() {
    final int w = _player.state.width ?? 0;
    final int h = _player.state.height ?? 0;
    if (w > 0 && h > 0 && !_size.isClosed) {
      _size.add(Size(w.toDouble(), h.toDouble()));
    }
  }

  @override
  Future<void> open(String path) => _player.open(Media(path), play: false);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  /// media_kit / mpv 的音量刻度是 0–100。
  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume(volume.clamp(0.0, 1.0) * 100);

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  Stream<bool> get completedStream => _player.stream.completed;

  @override
  Stream<Size> get videoSizeStream => _size.stream;

  @override
  bool get isCompleted => _player.state.completed;

  @override
  Widget buildView() => Video(
    controller: _controller,
    // 卡面片段没有视频页那套生命周期接管（BUG-2544）：用 media_kit 自带的对称策略——
    // 进后台暂停、回前台只续播被它暂停的（序列等着的那段播完照常往下走）。
    pauseUponEnteringBackgroundMode: true,
    resumeUponEnteringForegroundMode: true,
    controls: NoVideoControls,
    fill: Colors.transparent,
    subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
  );

  @override
  Future<void> dispose() async {
    for (final StreamSubscription<Object?> s in _subs) {
      await s.cancel();
    }
    await _size.close();
    await _player.dispose();
  }
}

/// 卡面上的一段视频片段。
class SrsCardVideoClip extends ConsumerStatefulWidget {
  const SrsCardVideoClip({
    required this.name,
    required this.radius,
    this.maxWidth,
    this.maxHeight,
    this.fillWidth = false,
    this.maxFillHeight,
    super.key,
  });

  /// 媒体库里的文件名（`<video src>` 的值）。
  final String name;

  /// 最大宽度；null = 只受父级约束。
  final double? maxWidth;

  /// 最大高度；null = 220（与卡面图片同一默认）。不铺满时生效。
  final double? maxHeight;

  /// 与卡面图片同一判据：比例在 [kSrsPictureFillMinAspect]–[kSrsPictureFillMaxAspect]
  /// 之间时铺满父级宽度、按比例定高；超出范围退回 [maxHeight] 限高。
  final bool fillWidth;

  /// 铺满时的高度上限；按比例超过它就整段等比缩小。null = 不封顶。
  final double? maxFillHeight;

  /// 圆角半径。
  final double radius;

  @override
  ConsumerState<SrsCardVideoClip> createState() => _SrsCardVideoClipState();
}

/// 视频尺寸未知时（还没解出第一帧）按 16:9 占位；媒体缺失的占位框同样按它。
const double kSrsCardMediaFallbackAspect = 16 / 9;
const double _kFallbackAspect = kSrsCardMediaFallbackAspect;

/// 铺满栏宽的卡面媒体（图片 / 视频片段）比例范围（宽 / 高）：视频截图 16:9、4:3、方图都在内；
/// 竖长书封、超宽横幅铺满会过高 / 过扁，照旧限高完整显示。
const double kSrsPictureFillMinAspect = 0.9;
const double kSrsPictureFillMaxAspect = 2.5;

/// 卡面媒体（图片 / 视频片段 / 缺失占位）按 [aspect] 的显示尺寸，图片与视频同一套规则：
///
/// - [fillWidth] 且比例在 [kSrsPictureFillMinAspect]–[kSrsPictureFillMaxAspect] 之间、
///   [maxWidth] 有限：宽 = [maxWidth]、按比例定高；高超过 [maxFillHeight] 就整体等比缩小
///   到这个高度。
/// - 否则：在 [maxWidth] × [maxHeight] 内按比例取最大（[srsCardVideoClipSize]）。
Size srsCardMediaBoxSize({
  required double aspect,
  required double maxWidth,
  required double maxHeight,
  bool fillWidth = false,
  double? maxFillHeight,
}) {
  final bool fill =
      fillWidth &&
      maxWidth.isFinite &&
      aspect >= kSrsPictureFillMinAspect &&
      aspect <= kSrsPictureFillMaxAspect;
  if (!fill) {
    return srsCardVideoClipSize(
      aspect: aspect,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
    );
  }
  final double natural = maxWidth / aspect;
  final double cap = maxFillHeight ?? double.infinity;
  return natural > cap ? Size(cap * aspect, cap) : Size(maxWidth, natural);
}

/// 卡面媒体的种类（决定缺失占位的文案）。
enum SrsCardMediaKind { image, video }

/// 卡上引用了媒体、但本机没有这个文件（还没同步过来）或加载失败时的占位：与真实媒体
/// 同尺寸的圆角框，破图图标 +「图片未同步」/「视频未同步」。
class SrsCardMediaMissing extends StatelessWidget {
  const SrsCardMediaMissing({
    super.key,
    required this.kind,
    required this.size,
    required this.radius,
  });

  final SrsCardMediaKind kind;

  /// 占位框尺寸（按 [srsCardMediaBoxSize] 算，与媒体正常显示时同一套规则）。
  final Size size;

  final double radius;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String label = switch (kind) {
      SrsCardMediaKind.image => t.srs_card_media_missing_image,
      SrsCardMediaKind.video => t.srs_card_media_missing_video,
    };
    final Color fg = scheme.onContainerOf(FushiTone.neutral);
    return Semantics(
      label: label,
      container: true,
      child: ClipRRect(
        borderRadius: BorderRadius.all(Radius.circular(radius)),
        child: SizedBox.fromSize(
          size: size,
          child: ColoredBox(
            color: scheme.containerOf(FushiTone.neutral),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: ExcludeSemantics(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      FushiIcon(FushiIcons.brokenImage, size: 28, color: fg),
                      const SizedBox(height: 6),
                      Text(
                        label,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: fg),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 片段在 [maxWidth] × [maxHeight] 内按 [aspect] 能放下的最大尺寸。
@visibleForTesting
Size srsCardVideoClipSize({
  required double aspect,
  required double maxWidth,
  required double maxHeight,
}) {
  final double byHeight = maxHeight * aspect;
  final double width = maxWidth.isFinite
      ? math.min(maxWidth, byHeight)
      : byHeight;
  return Size(width, width / aspect);
}

class _SrsCardVideoClipState extends ConsumerState<SrsCardVideoClip>
    implements SrsCardVideoHandle, SrsCardSentenceCompanion {
  late final SrsCardVideoChannel _channel;

  /// 当前挂在 [_channel] 上的名字（换片段时据此撤销旧登记）。
  String? _attachedName;

  SrsCardVideoPlayer? _player;

  /// 打开中的播放器（序列播放要等它打开好）；null 结果 = 打不开 / 已作废。
  Future<SrsCardVideoPlayer?>? _opening;

  /// 每次（重新）加载自增；旧加载据此知道自己作废了。
  int _loadToken = 0;

  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  /// 文件已确认存在（确认前什么也不画）。
  bool _available = false;

  /// 引用了片段但本机文件不存在 / 打不开：画「视频未同步」占位。
  bool _missing = false;
  bool _playing = false;
  Size? _videoSize;

  /// 序列播放：未完成的那次 [playFromStart]、它的代号、是否已开播（之后的
  /// completed 才算它的结尾）。
  Completer<bool>? _run;
  int _runGeneration = 0;
  bool _runArmed = false;

  @override
  void initState() {
    super.initState();
    _channel = ref.read(srsCardVideoChannelProvider);
    _channel.attachCompanion(this);
    _load(widget.name);
  }

  @override
  void didUpdateWidget(SrsCardVideoClip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.name == widget.name) return;
    _interruptRun();
    _teardown();
    setState(() {
      _available = false;
      _missing = false;
      _playing = false;
      _videoSize = null;
    });
    _load(widget.name);
  }

  @override
  void dispose() {
    _channel.detachCompanion(this);
    _interruptRun();
    _teardown();
    super.dispose();
  }

  /// 登记到 [_channel] 并开始加载 [name]。**同步**登记：卡面一挂上，序列就能找到
  /// 这段片段并排队等它打开好，不会因为文件还在解析而退回只播音频。
  void _load(String name) {
    _attachedName = name;
    _channel.attach(name, this);
    _opening = _open(name, ++_loadToken);
  }

  /// 撤销登记、停掉订阅、释放播放器（释放即停止出声）。
  void _teardown() {
    _loadToken++;
    final String? attached = _attachedName;
    if (attached != null) _channel.detach(attached, this);
    _attachedName = null;
    _opening = null;
    for (final StreamSubscription<Object?> s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    final SrsCardVideoPlayer? player = _player;
    _player = null;
    if (player != null) unawaited(player.dispose());
  }

  bool _isCurrent(int token) => mounted && token == _loadToken;

  Future<SrsCardVideoPlayer?> _open(String name, int token) async {
    final SrsMediaStore? store = await ref.read(srsMediaStoreProvider.future);
    final File? file = store?.resolve(name);
    final bool exists = file != null && await file.exists();
    // 两次 await 之间组件可能已卸载：先判 mounted/token 再碰 ref（卸载后读 provider 抛错）。
    if (!_isCurrent(token)) return null;
    if (!exists) {
      ErrorLogService.instance.logDiagnostic(
        'SrsCardVideoClip.open',
        'media missing: $name',
      );
      _giveUp(name);
      return null;
    }
    final SrsCardVideoPlayer player = ref.read(
      srsCardVideoPlayerFactoryProvider,
    )();
    _player = player;
    _subs
      ..add(
        player.playingStream.listen((bool playing) {
          if (mounted && playing != _playing) {
            setState(() => _playing = playing);
          }
        }),
      )
      ..add(
        player.completedStream.listen((bool completed) {
          if (completed && _runArmed) _finishRun(true);
        }),
      )
      ..add(
        player.videoSizeStream.listen((Size size) {
          if (mounted && size != _videoSize) {
            setState(() => _videoSize = size);
          }
        }),
      );
    setState(() => _available = true);
    try {
      await player.setVolume(ref.read(srsReviewVolumeProvider));
      await player.open(file.path);
    } on Object catch (e) {
      if (!_isCurrent(token)) return null;
      ErrorLogService.instance.logDiagnostic(
        'SrsCardVideoClip.open',
        'open failed: $name: $e',
      );
      _teardown();
      setState(() {
        _available = false;
        _missing = true;
      });
      _finishRun(false);
      return null;
    }
    if (!_isCurrent(token)) return null;
    return player;
  }

  /// 文件不存在：撤销登记（序列退回只播音频），未完成的序列播放以 false 结束。
  void _giveUp(String name) {
    _channel.detach(name, this);
    if (_attachedName == name) _attachedName = null;
    _finishRun(false);
    if (mounted) {
      setState(() {
        _available = false;
        _missing = true;
      });
    }
  }

  void _finishRun(bool finished) {
    final Completer<bool>? run = _run;
    _run = null;
    _runArmed = false;
    if (run != null && !run.isCompleted) run.complete(finished);
  }

  /// 作废进行中的序列播放（未开播的不再开播，等待中的以 false 结束）。
  void _interruptRun() {
    _runGeneration++;
    _finishRun(false);
  }

  // ---------------------------------------------------------- SrsCardVideoHandle

  @override
  Future<bool> playFromStart() {
    _interruptRun();
    final int generation = _runGeneration;
    final Completer<bool> run = Completer<bool>();
    _run = run;
    unawaited(_startRun(generation));
    return run.future;
  }

  Future<void> _startRun(int generation) async {
    final SrsCardVideoPlayer? player = await _opening;
    if (generation != _runGeneration) return;
    if (player == null) {
      _finishRun(false);
      return;
    }
    try {
      await player.setVolume(ref.read(srsReviewVolumeProvider));
      if (generation != _runGeneration) return;
      await player.seek(Duration.zero);
      if (generation != _runGeneration) return;
      _runArmed = true;
      await player.play();
    } on Object catch (e) {
      ErrorLogService.instance.logDiagnostic(
        'SrsCardVideoClip.play',
        'play failed: ${widget.name}: $e',
      );
      if (generation == _runGeneration) _finishRun(false);
    }
  }

  @override
  Future<void> stop() async {
    _interruptRun();
    await _player?.pause();
  }

  // ---------------------------------------------------------- 例句陪播

  /// 例句音频（另一个文件）开播：画面从头静音陪播，声音只有例句那一路。
  @override
  void sentenceStarted(String name) {
    _interruptRun();
    final SrsCardVideoPlayer? player = _player;
    if (player == null) return;
    _logged('companion', () async {
      await player.setVolume(0);
      await player.seek(Duration.zero);
      await player.play();
    });
  }

  // ---------------------------------------------------------------- 用户点按

  Future<void> _toggle() async {
    _interruptRun();
    final SrsCardVideoPlayer? player = _player;
    if (player == null) return;
    if (_playing) {
      await player.pause();
      return;
    }
    await player.setVolume(ref.read(srsReviewVolumeProvider));
    if (player.isCompleted) await player.seek(Duration.zero);
    await player.play();
  }

  Future<void> _replay() async {
    _interruptRun();
    final SrsCardVideoPlayer? player = _player;
    if (player == null) return;
    await player.setVolume(ref.read(srsReviewVolumeProvider));
    await player.seek(Duration.zero);
    await player.play();
  }

  /// 放大查看：同一个播放器在对话框里铺满可用区域（按视频比例），点画面播放 / 暂停，
  /// 点外面 / 关闭键收起；画面继续停在原来的位置（不重开文件、不打断播放进度）。
  Future<void> _expand() async {
    final SrsCardVideoPlayer? player = _player;
    if (player == null) return;
    final Size? video = _videoSize;
    final double aspect = video == null || video.height <= 0
        ? _kFallbackAspect
        : video.width / video.height;
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext context) => SrsCardVideoExpandedView(
        aspect: aspect,
        view: player.buildView(),
        onToggle: () => _logged('toggle', _toggle),
      ),
    );
  }

  void _logged(String what, Future<void> Function() action) {
    unawaited(
      action().catchError((Object e) {
        ErrorLogService.instance.logDiagnostic('SrsCardVideoClip.$what', '$e');
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<double>(srsReviewVolumeProvider, (double? _, double volume) {
      final SrsCardVideoPlayer? player = _player;
      if (player != null) _logged('volume', () => player.setVolume(volume));
    });
    if (!_available && !_missing) return const SizedBox.shrink();
    final SrsCardVideoPlayer? player = _player;
    final Size? video = _videoSize;
    final double aspect = video == null || video.height <= 0
        ? _kFallbackAspect
        : video.width / video.height;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = srsCardMediaBoxSize(
          aspect: aspect,
          maxWidth: math.min(
            widget.maxWidth ?? double.infinity,
            constraints.maxWidth,
          ),
          maxHeight: widget.maxHeight ?? 220,
          fillWidth: widget.fillWidth,
          maxFillHeight: widget.maxFillHeight,
        );
        if (_missing) {
          return SrsCardMediaMissing(
            key: const ValueKey<String>('srs-card-video-missing'),
            kind: SrsCardMediaKind.video,
            size: size,
            radius: widget.radius,
          );
        }
        final Widget frame = ClipRRect(
          borderRadius: BorderRadius.all(Radius.circular(widget.radius)),
          child: SizedBox.fromSize(
            size: size,
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  if (player != null) player.buildView(),
                  if (!_playing)
                    IgnorePointer(
                      child: Center(
                        child: DecoratedBox(
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: FushiIcon(
                              FushiIcons.play,
                              size: math.min(28, size.shortestSide * 0.35),
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Semantics(
              button: true,
              label: _playing ? t.srs_card_video_pause : t.srs_card_video_play,
              child: FushiPressScale(
                child: GestureDetector(
                  key: const ValueKey<String>('srs-card-video-toggle'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _logged('toggle', _toggle),
                  child: frame,
                ),
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              child: FushiIconButton(
                key: const ValueKey<String>('srs-card-video-expand'),
                icon: FushiIcons.fullscreen,
                tooltip: t.video_control_fullscreen,
                size: 20,
                padding: const EdgeInsets.all(14),
                backgroundColor: Colors.black45,
                enabledColor: Colors.white,
                onTap: () => _logged('expand', _expand),
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: FushiIconButton(
                key: const ValueKey<String>('srs-card-video-replay'),
                icon: FushiIcons.replay,
                tooltip: t.srs_card_video_replay,
                size: 20,
                // 20 + 2×14 = 48dp 命中区。
                padding: const EdgeInsets.all(14),
                backgroundColor: Colors.black45,
                enabledColor: Colors.white,
                onTap: () => _logged('replay', _replay),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 放大后的片段画面：按视频比例在可用区域里取最大，点画面播放 / 暂停，角上关闭。
@visibleForTesting
class SrsCardVideoExpandedView extends StatelessWidget {
  const SrsCardVideoExpandedView({
    super.key,
    required this.aspect,
    required this.view,
    required this.onToggle,
  });

  /// 视频宽高比。
  final double aspect;

  /// 播放器画面（与卡面上同一个播放器）。
  final Widget view;

  /// 点画面：播放 / 暂停。
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    final Size size = srsCardVideoClipSize(
      aspect: aspect,
      maxWidth: screen.width * 0.92,
      maxHeight: screen.height * 0.86,
    );
    // 对话框路由下面没有 Material：关闭键（InkWell）缺 Material 祖先会构建失败，被错误盒
    // 替换——错误盒在 Positioned 里按最大约束铺满整个画面（debug 半透明红、release 灰块），
    // 视频被盖住、关闭键也没了（BUG-3733）。透明 Material 只提供墨水层，不画任何东西。
    return Center(
      child: SizedBox.fromSize(
        size: size,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(12)),
                child: ColoredBox(
                  color: Colors.black,
                  child: GestureDetector(
                    key: const ValueKey<String>('srs-card-video-expanded'),
                    behavior: HitTestBehavior.opaque,
                    onTap: onToggle,
                    child: view,
                  ),
                ),
              ),
              Positioned(
                right: 0,
                top: 0,
                child: FushiIconButton(
                  key: const ValueKey<String>('srs-card-video-expanded-close'),
                  icon: FushiIcons.close,
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  size: 20,
                  padding: const EdgeInsets.all(14),
                  backgroundColor: Colors.black45,
                  enabledColor: Colors.white,
                  onTap: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
