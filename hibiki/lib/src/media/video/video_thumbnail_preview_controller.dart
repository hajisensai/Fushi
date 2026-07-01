import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
import 'package:media_kit/media_kit.dart';

/// 缩略图预览浮层的四态（TODO-669）。把所有 if 分支收敛成一个枚举，浮层只 switch
/// 一次，消除「在显示 / 在加载 / 取帧失败 / 移动端降级」各写一套条件的特殊情况。
enum ThumbnailPreviewPhase {
  /// 未 hover / 已 onExit → 浮层 `SizedBox.shrink()`，不占位。
  hidden,

  /// 桌面取帧 in-flight → 浮层显时间戳 + spinner（上一帧若有可继续展示）。
  loading,

  /// 帧拿到 → 浮层显缩略图 + 时间戳。
  ready,

  /// 移动端 / 远端流 / 取帧失败兜底 → 只显时间戳气泡，不取帧。
  timestampOnly,
}

/// 不可变状态值对象（TODO-669）：浮层渲染唯一真相源，控制器每次推一个新实例。
@immutable
class ThumbnailPreviewState {
  const ThumbnailPreviewState({
    required this.phase,
    this.fraction,
    this.targetMs,
    this.image,
  });

  /// hidden 初态：浮层不显示。
  static const ThumbnailPreviewState hidden =
      ThumbnailPreviewState(phase: ThumbnailPreviewPhase.hidden);

  final ThumbnailPreviewPhase phase;

  /// hover 位置 `[0,1]`，浮层水平定位用；hidden 时为 null。
  final double? fraction;

  /// 目标时间（毫秒），气泡时间戳文字用。
  final int? targetMs;

  /// ready 时的已解码帧；其它态为 null。所有权归控制器（dispose 时释放）。
  final ui.Image? image;
}

/// 把 hover 比例 [fraction]（`[0,1]`）映射成目标时间（毫秒）。
///
/// [durationMs] <= 0（媒体头未解析 / 无时长）返回 null，调用方据此降级为
/// timestampOnly。比例先 clamp 到 `[0,1]`，结果再 clamp 到 `[0, durationMs]`，
/// 保证不越界。纯函数，便于单测边界。
int? thumbnailTargetMs(double fraction, int durationMs) {
  if (durationMs <= 0) return null;
  final double clamped = fraction.clamp(0.0, 1.0);
  final int ms = (clamped * durationMs).round();
  return ms.clamp(0, durationMs);
}

/// 取帧函数签名：给定目标毫秒返回一帧（已解码 `ui.Image`），失败返回 null。
///
/// 控制器对外只认这个抽象——真实实现内部先走 media_kit `Player.screenshot()`、
/// 失败回退 ffmpeg，对调度逻辑（防抖 / 单飞 / 软取消）完全透明。单测注入 fake，
/// 不碰真 media_kit / libmpv（headless 无 libmpv）。
typedef ThumbnailFrameGrabber = Future<ui.Image?> Function(int targetMs);

/// 视频进度条 hover 缩略图预览调度器（TODO-669，方案 A）。
///
/// 数据流（单向）：seek bar hover(fraction) → [request] → 防抖 120ms → 取帧
/// （单飞 + generation 软取消）→ [state] → 浮层 rebuild。
///
/// 桌面：实时取帧；移动端 / 远端流 / 取帧失败：timestampOnly（只显时间戳）。
/// 三件套保证「最新 hover 胜出、旧请求作废、绝不并发多个取帧 / 第二 Player」：
/// 1. 防抖（[debounce]）：hover 高频只在指针停下后真正发起取帧；移动期间浮层
///    位置 + 时间戳即时跟手（[request] 立即更新 fraction/targetMs），但不每像素 seek。
/// 2. 单飞（in-flight）：同一时刻只允许一个取帧任务；新请求记为 pending，当前
///    任务完成后若 pending 目标不同立即补发（合并掉中间所有过期请求）。
/// 3. 软取消（[_generation]）：每次 [request] / [hide] / [dispose] 自增 generation；
///    取帧完成时比对 generation 是否仍最新，过期则丢结果（不 notify、不渲染过期帧）。
class VideoThumbnailPreviewController extends ChangeNotifier {
  VideoThumbnailPreviewController({
    required ThumbnailFrameGrabber grabber,
    required int Function() durationMsProvider,
    this.debounce = const Duration(milliseconds: 120),
  })  : _grabber = grabber,
        _durationMsProvider = durationMsProvider;

  final ThumbnailFrameGrabber _grabber;
  final int Function() _durationMsProvider;

  /// hover 防抖窗口；指针在窗口内连续移动只合并成一次取帧。
  final Duration debounce;

  ThumbnailPreviewState _state = ThumbnailPreviewState.hidden;
  ThumbnailPreviewState get state => _state;

  Timer? _debounceTimer;

  /// 软取消令牌：每次 request/hide/dispose 自增；取帧结果只在 generation 未变时采用。
  int _generation = 0;

  /// 是否有取帧任务在跑（单飞闸门）。
  bool _inFlight = false;

  /// 当前在跑任务完成后要补发的目标（最新 pending），null 表示无待发。
  int? _pendingTargetMs;

  bool _disposed = false;

  /// seek bar 推来一个 hover 位置（[fraction] ∈ `[0,1]`，null = onExit / 隐藏）。
  ///
  /// fraction==null → 立即隐藏（作废在途）。否则即时更新浮层位置 + 时间戳
  /// （跟手），再按平台决定是否取帧（[desktop] && 有时长 → 防抖取帧；
  /// 否则 timestampOnly）。
  void request(double? fraction, {required bool desktop}) {
    if (_disposed) return;
    if (fraction == null) {
      hide();
      return;
    }
    _generation++;
    final int durationMs = _durationMsProvider();
    final int? targetMs = thumbnailTargetMs(fraction, durationMs);

    // 无时长（远端流未就绪 / 媒体头未解析）或非桌面 → 只显时间戳，不取帧。
    if (!desktop || targetMs == null) {
      _debounceTimer?.cancel();
      _setState(ThumbnailPreviewState(
        phase: ThumbnailPreviewPhase.timestampOnly,
        fraction: fraction,
        targetMs: targetMs,
      ));
      return;
    }

    // 即时更新位置 + 时间戳（跟手）；保留上一帧（若 ready）以免移动时闪烁，
    // 仍是 loading 态等取帧。位置 / 时间戳每次都新，帧沿用旧的。
    final ui.Image? keepImage =
        _state.phase == ThumbnailPreviewPhase.ready ? _state.image : null;
    _setState(ThumbnailPreviewState(
      phase: keepImage != null
          ? ThumbnailPreviewPhase.ready
          : ThumbnailPreviewPhase.loading,
      fraction: fraction,
      targetMs: targetMs,
      image: keepImage,
    ));

    // 防抖：指针停下后才真正取帧。
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => _dispatchGrab(targetMs, fraction));
  }

  /// 隐藏浮层并作废在途取帧（onExit / dispose 调）。
  void hide() {
    if (_disposed) return;
    _generation++;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _pendingTargetMs = null;
    _disposeStateImage();
    _setState(ThumbnailPreviewState.hidden);
  }

  /// 发起取帧：单飞闸门 + generation 软取消。
  void _dispatchGrab(int targetMs, double fraction) {
    if (_disposed) return;
    if (_inFlight) {
      // 已有任务在跑 → 只记最新 pending，不并发第二个。
      _pendingTargetMs = targetMs;
      return;
    }
    _inFlight = true;
    final int generation = _generation;
    unawaited(_runGrab(targetMs, fraction, generation));
  }

  Future<void> _runGrab(int targetMs, double fraction, int generation) async {
    ui.Image? image;
    try {
      image = await _grabber(targetMs);
    } catch (_) {
      image = null;
    }
    _inFlight = false;

    // 软取消：本次结果过期（更新的 request/hide/dispose 已 bump generation）→ 丢弃。
    if (_disposed || generation != _generation) {
      image?.dispose();
      _maybeDispatchPending();
      return;
    }

    if (image != null) {
      _disposeStateImage();
      _setState(ThumbnailPreviewState(
        phase: ThumbnailPreviewPhase.ready,
        fraction: _state.fraction ?? fraction,
        targetMs: _state.targetMs ?? targetMs,
        image: image,
      ));
    } else {
      // 取帧失败（screenshot + ffmpeg 都没拿到）→ 降级 timestampOnly。
      _disposeStateImage();
      _setState(ThumbnailPreviewState(
        phase: ThumbnailPreviewPhase.timestampOnly,
        fraction: _state.fraction ?? fraction,
        targetMs: _state.targetMs ?? targetMs,
      ));
    }
    _maybeDispatchPending();
  }

  /// 当前任务完成后，若有 pending 且目标不同则立即补发（合并中间过期请求）。
  void _maybeDispatchPending() {
    if (_disposed) return;
    final int? pending = _pendingTargetMs;
    _pendingTargetMs = null;
    if (pending == null) return;
    _dispatchGrab(pending, _state.fraction ?? 0.0);
  }

  void _setState(ThumbnailPreviewState next) {
    _state = next;
    notifyListeners();
  }

  void _disposeStateImage() {
    _state.image?.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _pendingTargetMs = null;
    _disposeStateImage();
    super.dispose();
  }
}

/// 离屏取帧实现（TODO-669，桌面真路径）：屏外第二 [Player] + screenshot 主路径 +
/// ffmpeg 兜底，两路径都封装在内部、对调度器透明。仅本地文件视频用；远端流不构造。
///
/// 隔离：第二 Player 用 `PlayerConfiguration(muted:true, vo:'null')`——不出声、
/// 无视频输出窗口，独立 libmpv 实例，不抢主播放音频 / 显示。整个 hover 会话复用
/// 一个实例；换集 / 关页时 [dispose] 销毁。
///
/// M0 真机 Gate（非本施工 agent 职责）决定哪条路径稳定取到非黑帧：默认 screenshot
/// 主、有界重试失败 → ffmpeg → 再不行返回 null（调度器降级 timestampOnly）。
/// 切换主路径只动 [preferFfmpeg]，零 UI 改动。
class OffscreenVideoFrameGrabber {
  OffscreenVideoFrameGrabber({
    required this.videoPath,
    this.preferFfmpeg = false,
    this.thumbnailWidth = 320,
    this.screenshotRetries = 3,
    this.screenshotSettle = const Duration(milliseconds: 30),
    this.ffmpegTempDir,
  });

  /// 本地视频文件绝对路径（远端流不应构造本类，调用方先门控）。
  final String videoPath;

  /// 默认 false（screenshot 主路径）；M0 真机若判定 screenshot 不可靠则翻 true
  /// 切 ffmpeg 主路径——对调度器 / 浮层透明。
  final bool preferFfmpeg;

  /// 缩略图目标宽度（高按视频宽高比，由 [ui.Image] 原始尺寸决定，这里仅 ffmpeg 缩放用）。
  final int thumbnailWidth;

  /// screenshot 有界重试次数（seek 后帧可能尚未 render，等 settle 再试）。
  final int screenshotRetries;

  /// 每次 screenshot 重试前的 settle 延迟（等 seek 后帧就绪）。离屏 Player 已下发
  /// `hr-seek=no`（关键帧 seek），seek 后仅解码 1 个 I 帧、帧就绪极快，故默认 30ms
  /// 即可（对标 mpv 无感预览，TODO-1082 阶段①）。
  final Duration screenshotSettle;

  /// ffmpeg 兜底临时目录（默认系统临时目录）。
  final String? ffmpegTempDir;

  Player? _player;
  bool _disposed = false;
  int _ffmpegSeq = 0;

  /// 懒创建离屏 Player（首次桌面取帧时）。
  Player _ensurePlayer() {
    final Player? existing = _player;
    if (existing != null) return existing;
    final Player player = Player(
      configuration: const PlayerConfiguration(muted: true, vo: 'null'),
    );
    _player = player;
    // 关键帧 seek 提速（TODO-1082 阶段①，对标 mpv 无感预览）：给离屏 Player 下发
    // `hr-seek=no`——seek 只解码最近的 1 个关键帧（I 帧），不再从关键帧逐帧精确解码
    // 到目标帧（长 GOP 精确 seek 数百 ms~1s+）；`hr-seek-framedrop=yes` 允许丢帧进一步
    // 提速。仅本离屏第二 Player 生效，主播放器是独立实例、精确 seek 契约不动（never-break），
    // 绝不改 media_kit 全局默认。best-effort：非 libmpv / 属性不支持时静默吞掉（与
    // video_mpv_config.dart 的属性下发同范式）。
    unawaited(_applyKeyframeSeekProperties(player));
    unawaited(player.open(Media(_sourceUri()), play: false));
    return player;
  }

  String _sourceUri() {
    final Uri? uri = Uri.tryParse(videoPath);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return uri.toString();
    }
    return videoPath;
  }

  /// 给离屏 [player] best-effort 下发关键帧 seek 属性（TODO-1082 阶段①）。
  ///
  /// 经 `player.platform`（NativePlayer）的 `setProperty` 下发，仅 libmpv 后端生效；
  /// 非 libmpv / 该属性不支持运行时设置时单条静默吞掉（与 video_mpv_config.dart
  /// 的 `applyMpvConfigToPlayer` 等同范式）。只影响本离屏 Player，不碰主播放器 /
  /// media_kit 全局默认。
  Future<void> _applyKeyframeSeekProperties(Player player) async {
    final dynamic native = player.platform;
    if (native == null) return;
    const Map<String, String> props = <String, String>{
      'hr-seek': 'no',
      'hr-seek-framedrop': 'yes',
    };
    for (final MapEntry<String, String> e in props.entries) {
      if (_disposed) return;
      try {
        await native.setProperty(e.key, e.value);
      } catch (_) {
        // 非 libmpv / 该属性不支持：跳过这条，继续下一条。
      }
    }
  }

  /// 取帧入口（注入给 [VideoThumbnailPreviewController]）。默认 screenshot 主、
  /// 失败 ffmpeg；[preferFfmpeg] 翻转优先级。
  Future<ui.Image?> grab(int targetMs) async {
    if (_disposed) return null;
    if (preferFfmpeg) {
      final ui.Image? viaFfmpeg = await _grabViaFfmpeg(targetMs);
      if (viaFfmpeg != null) return viaFfmpeg;
      return _grabViaScreenshot(targetMs);
    }
    final ui.Image? viaScreenshot = await _grabViaScreenshot(targetMs);
    if (viaScreenshot != null) return viaScreenshot;
    return _grabViaFfmpeg(targetMs);
  }

  Future<ui.Image?> _grabViaScreenshot(int targetMs) async {
    try {
      final Player player = _ensurePlayer();
      await player.seek(Duration(milliseconds: targetMs));
      // hr-seek=no 关键帧 seek 后帧就绪极快 → 先立即试拍一次（多数情况这一拍就命中，
      // 无需等 settle，对标 mpv 无感预览，TODO-1082 阶段①）。
      final ui.Image? immediate = await _tryScreenshotOnce(player);
      if (immediate != null) return immediate;
      // 首拍未命中（帧尚未 render）：有界重试，每次 settle 后再试。
      for (int attempt = 0; attempt < screenshotRetries; attempt++) {
        if (_disposed) return null;
        await Future<void>.delayed(screenshotSettle);
        if (_disposed) return null;
        final ui.Image? decoded = await _tryScreenshotOnce(player);
        if (decoded != null) return decoded;
      }
    } catch (_) {
      // 落到 ffmpeg 兜底或返回 null。
    }
    return null;
  }

  /// 拍一帧并解码：screenshot 拿到非空字节则解码返回 [ui.Image]，否则返回 null。
  /// 供 [_grabViaScreenshot] 的首拍与 settle 重试复用（消除两处重复）。
  Future<ui.Image?> _tryScreenshotOnce(Player player) async {
    if (_disposed) return null;
    final Uint8List? bytes = await player.screenshot();
    if (bytes == null || bytes.isEmpty) return null;
    return _decode(bytes);
  }

  Future<ui.Image?> _grabViaFfmpeg(int targetMs) async {
    try {
      final String dir = ffmpegTempDir ?? Directory.systemTemp.path;
      final String outPath =
          '$dir/hibiki_thumb_${identityHashCode(this)}_${_ffmpegSeq++}.jpg';
      final String? produced = await extractVideoFrameViaFfmpeg(
        inputPath: _sourceUri(),
        outputPath: outPath,
        atSeconds: targetMs / 1000.0,
      );
      if (produced == null) return null;
      final File outFile = File(produced);
      final Uint8List bytes = await outFile.readAsBytes();
      try {
        outFile.deleteSync();
      } catch (_) {}
      if (bytes.isEmpty) return null;
      return _decode(bytes);
    } catch (_) {
      return null;
    }
  }

  Future<ui.Image?> _decode(Uint8List bytes) async {
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: thumbnailWidth,
      );
      final ui.FrameInfo frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _disposed = true;
    final Player? player = _player;
    _player = null;
    if (player != null) unawaited(player.dispose());
  }
}
