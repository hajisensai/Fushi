import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/startup/media_handle_registry.dart';
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart';

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

/// 取帧目标的量化格数：整条进度条被切成这么多份，同一份共用同一帧。
///
/// 为什么按**比例**而不是按固定秒数量化：进度条像素宽度与视频时长无关，按秒量化
/// 对 2 分钟的片子过密（每像素一个新目标 → 缓存永不命中）、对 2 小时的片子过疏。
/// 600 份意味着 1200px 宽的进度条上约每 2px 换一个取帧目标——视觉上连续，而同一
/// 目标反复 hover 时缓存必命中。取帧本身是关键帧对齐的（精度 = GOP，通常 2~10s），
/// 所以再细的量化也换不来更准的帧，只会白白多 seek。
const int kThumbnailBuckets = 600;

/// 把 hover 比例量化到 [kThumbnailBuckets] 格后再映射成目标时间（毫秒）。
///
/// 与 [thumbnailTargetMs] 的分工：时间戳气泡要**跟手**，用后者的精确值；取帧目标
/// 要**可缓存**，用本函数的量化值。纯函数，便于单测边界。
int? thumbnailBucketTargetMs(double fraction, int durationMs) {
  if (durationMs <= 0) return null;
  final double clamped = fraction.clamp(0.0, 1.0);
  // 取的是「落在第几格」，代表点是那一格的**起点**——所以 floor 而不是 round，
  // 并且最后一格是 `kThumbnailBuckets - 1`。若允许取到第 600 格，目标就正好等于
  // 总时长，而那里没有帧可取（`ffmpeg -ss <duration>` 必然产不出画面），进度条
  // 最右端就永远只剩时间戳。
  final int bucket =
      (clamped * kThumbnailBuckets).floor().clamp(0, kThumbnailBuckets - 1);
  final int ms = (bucket / kThumbnailBuckets * durationMs).round();
  return ms.clamp(0, durationMs);
}

/// 取帧函数签名：给定目标毫秒返回一帧（已解码 `ui.Image`），失败返回 null。
///
/// 控制器对外只认这个抽象——真实实现（[OffscreenVideoFrameGrabber]）内部怎么取帧
/// 对调度逻辑（防抖 / 单飞 / 软取消 / 缓存）完全透明。单测注入 fake，不碰真
/// ffmpeg / media_kit。
typedef ThumbnailFrameGrabber = Future<ui.Image?> Function(int targetMs);

/// 同步缓存查询签名：命中返回一帧**调用方独占**的图（实现侧 `clone()`），未命中
/// 返回 null。必须同步——它存在的全部意义就是让「已经取过的位置」零延迟切图，
/// 不经过 loading 态、不闪 spinner；只要拐进 `await` 就至少多一个 microtask 的
/// 闪烁窗口，这个语义就没了。
typedef ThumbnailCachedFrameLookup = ui.Image? Function(int targetMs);

/// 视频进度条 hover 缩略图预览调度器（TODO-669，方案 A）。
///
/// 数据流（单向）：seek bar hover(fraction) → [request] → 同步查缓存 → 取帧
/// （单飞 + generation 软取消）→ [state] → 浮层 rebuild。
///
/// 桌面：实时取帧；移动端 / 远端流 / 取帧失败：timestampOnly（只显时间戳）。
///
/// 「最新 hover 胜出、旧请求作废、绝不并发多个取帧」由四件套保证：
/// 1. 缓存（[_cachedFrameLookup]）：已取过的格**同步**命中，零延迟出图、不进
///    loading 态。鼠标在看过的区间来回移动是常态，这条路径必须是免费的。
/// 2. 量化（[thumbnailBucketTargetMs]）：取帧目标按格取整，同一格不重复取；
///    气泡时间戳仍用未量化的精确值，保持跟手。
/// 3. 单飞（[_inFlight]）+ 有界等待（[grabTimeout]）：同一时刻只允许一个取帧；
///    新请求记为 pending，当前任务完成（或超时）后补发最新 pending。
/// 4. 软取消（[_generation]）：每次 [request] / [hide] / [dispose] 自增 generation；
///    取帧完成时比对 generation 是否仍最新，过期则丢结果（不 notify、不渲染过期帧）。
///
/// 这里**没有防抖**，而且不能有：只要 hover 间隔（约 16ms）短于防抖窗，定时器就
/// 被无限重置、一次都不触发，匀速划过进度条时预览一帧都不换——旧实现 120ms 的
/// 「停下才取」正是「鼠标动了预览图不更新」的直接成因，缩到 24ms 一样中招。
class VideoThumbnailPreviewController extends ChangeNotifier {
  VideoThumbnailPreviewController({
    required ThumbnailFrameGrabber grabber,
    required int Function() durationMsProvider,
    ThumbnailCachedFrameLookup? cachedFrameLookup,
    VoidCallback? onWarmUp,
    this.grabTimeout = const Duration(seconds: 6),
  })  : _grabber = grabber,
        _durationMsProvider = durationMsProvider,
        _cachedFrameLookup = cachedFrameLookup,
        _onWarmUp = onWarmUp;

  final ThumbnailFrameGrabber _grabber;
  final int Function() _durationMsProvider;

  /// 同步缓存查询（可选）；命中即零延迟出图，不进 loading 态。
  final ThumbnailCachedFrameLookup? _cachedFrameLookup;

  /// 首次 hover 时的预热回调（可选）：让取帧器提前探明取帧到底可不可用（不可用就
  /// 尽早熔断，别让用户每挪一次鼠标都等一个注定失败的进程）并暖一格缓存。
  final VoidCallback? _onWarmUp;

  /// 单次取帧的墙钟上限。超时即判失败并放掉单飞闸门——否则一次挂死的取帧会让
  /// [_inFlight] 永远为真，后续 hover 全被并进 pending，预览**永久停更**。
  final Duration grabTimeout;

  ThumbnailPreviewState _state = ThumbnailPreviewState.hidden;
  ThumbnailPreviewState get state => _state;

  /// 软取消令牌：每次 request/hide/dispose 自增；取帧结果只在 generation 未变时采用。
  int _generation = 0;

  /// 是否有取帧任务在跑（单飞闸门）。
  bool _inFlight = false;

  /// 最近一次 hover 请求的量化取帧目标。in-flight 取帧收尾时据此决定要不要立刻
  /// 追发下一次（[_chaseLatestTarget]），保证预览始终朝着当前指针位置收敛。
  int? _latestGrabTargetMs;

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
    // 注意这里**不** bump [_generation]：软取消只表示「用户已离开进度条」，不表示
    // 「又动了一下鼠标」。见 [_runGrab] 里的说明。
    final bool wasHidden = _state.phase == ThumbnailPreviewPhase.hidden;
    final int durationMs = _durationMsProvider();
    final int? targetMs = thumbnailTargetMs(fraction, durationMs);

    // 无时长（远端流未就绪 / 媒体头未解析）或非桌面 → 只显时间戳，不取帧。
    if (!desktop || targetMs == null) {
      _setState(ThumbnailPreviewState(
        phase: ThumbnailPreviewPhase.timestampOnly,
        fraction: fraction,
        targetMs: targetMs,
      ));
      return;
    }

    // 首次 hover（从 hidden 进来）预热取帧器：探明可用性 + 暖一格缓存。
    if (wasHidden) _onWarmUp?.call();

    // 取帧目标量化到格；时间戳仍用未量化的精确值（气泡要跟手）。
    final int grabTargetMs = thumbnailBucketTargetMs(fraction, durationMs)!;
    _latestGrabTargetMs = grabTargetMs;

    // 同步缓存命中 → 直接 ready。这是「鼠标划过已看过的区间」的常态路径：
    // 零 await、零 seek、不闪 spinner。
    final ui.Image? cached = _cachedFrameLookup?.call(grabTargetMs);
    if (cached != null) {
      _disposeStateImage();
      _setState(ThumbnailPreviewState(
        phase: ThumbnailPreviewPhase.ready,
        fraction: fraction,
        targetMs: targetMs,
        image: cached,
      ));
      return;
    }

    // 即时更新位置 + 时间戳（跟手）；沿用上一帧避免移动时闪白，但态是 loading
    // ——这一帧**不是**当前位置的画面，浮层据此决定要不要提示加载中。所有权随
    // state 平移（不 dispose），下一次真正换帧时才释放。
    _setState(ThumbnailPreviewState(
      phase: ThumbnailPreviewPhase.loading,
      fraction: fraction,
      targetMs: targetMs,
      image: _state.image,
    ));

    // 直接派发，不做防抖。限流由「量化到格」+「单飞闸门」+「收尾追最新」三层
    // 承担，再加一层「等指针停下」只会制造 bug：只要 hover 间隔（约 16ms）短于
    // 防抖窗，定时器就被无限重置、一次都不触发——匀速划过进度条时预览一帧都不
    // 换。这正是用户报的「鼠标动了还不会重新加载」，24ms 的窗口一样中招。
    _dispatchGrab(grabTargetMs, fraction);
  }

  /// 隐藏浮层并作废在途取帧（onExit / dispose 调）。
  void hide() {
    if (_disposed) return;
    _generation++;
    _latestGrabTargetMs = null;
    _disposeStateImage();
    _setState(ThumbnailPreviewState.hidden);
  }

  /// 发起取帧：单飞闸门。在途时直接返回——完成后 [_chaseLatestTarget] 会去追
  /// [_latestGrabTargetMs]（当前 hover 位置那一格），中间所有过期请求自然合并掉。
  void _dispatchGrab(int targetMs, double fraction) {
    if (_disposed) return;
    if (_inFlight) return;
    _inFlight = true;
    unawaited(_runGrab(targetMs, fraction, _generation));
  }

  Future<void> _runGrab(int targetMs, double fraction, int generation) async {
    ui.Image? image;
    try {
      // 有界等待：取帧挂死（媒体损坏 / ffmpeg 卡住）时必须放掉单飞闸门，否则后续
      // hover 全被挡在闸门外，预览永久停更。
      image = await _grabber(targetMs).timeout(grabTimeout);
    } catch (_) {
      image = null;
    }
    _inFlight = false;

    // 软取消：只有「用户已经离开进度条」（hide / dispose）才作废在途结果。
    //
    // 这里**不能**把「期间又 hover 过」当作过期——那正是旧实现的病理：每次
    // request 都 bump generation，于是只要 hover 事件比取帧快（16ms vs 76ms），
    // 每个结果回来时 generation 都已经变了，**永远**被丢弃，预览一张图都换不出来。
    // 旧实现的 120ms 防抖只是把它掩盖成「停下才更新」。稍微滞后一点的帧远好过
    // 不更新，何况紧接着就会去追最新那一格。
    if (_disposed || generation != _generation) {
      image?.dispose();
      _chaseLatestTarget(targetMs);
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
      // 取帧失败（没装 ffmpeg / 媒体解不了）→ 降级 timestampOnly。
      _disposeStateImage();
      _setState(ThumbnailPreviewState(
        phase: ThumbnailPreviewPhase.timestampOnly,
        fraction: _state.fraction ?? fraction,
        targetMs: _state.targetMs ?? targetMs,
      ));
    }
    _chaseLatestTarget(targetMs);
  }

  /// 一次取帧收尾后，若 hover 已经挪到别的格就立刻去追**当前**那一格。
  ///
  /// 追的是最新位置而不是某个排队的旧请求：指针在取帧期间走过的中间位置没有补取
  /// 的价值，用户早就不在那儿了。
  void _chaseLatestTarget(int justGrabbedMs) {
    if (_disposed) return;
    if (_state.phase == ThumbnailPreviewPhase.hidden) return;
    final int? latest = _latestGrabTargetMs;
    if (latest == null || latest == justGrabbedMs) return;
    _dispatchGrab(latest, _state.fraction ?? 0.0);
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
    _latestGrabTargetMs = null;
    _disposeStateImage();
    super.dispose();
  }
}

/// 视频进度条缩略图取帧器（TODO-669 桌面真路径；TODO-1082 阶段②按实测重写）。
/// 仅本地文件视频用；远端流不构造（调用方门控）。
///
/// ## 为什么这里没有离屏 Player
///
/// 旧实现的主路径是「屏外第二个 media_kit `Player`（`vo:'null'`）+ `screenshot()`，
/// 失败才降级 ffmpeg」。实测（Windows，1080p 素材）这条主路径**一次都没成功过**：
/// media_kit 的 `screenshot()` 取的是 VO 输出的帧，而 VO 只在 `VideoController`
/// attach 之后才配置；离屏 Player 从不 attach，于是 `vo-configured=no`、`dwidth`
/// 为空、`time-pos` 事件从不到达、`screenshot()` 恒返回 null。这不是参数没调对，
/// 是架构上的死路——除非为取缩略图再建一条 GPU 纹理渲染管线。
///
/// 后果不只是「白跑」：每次 hover 都要先把这条死路走完（seek + 首拍 + 3 次 30ms
/// settle 重试）才降级 ffmpeg，凭空给每一帧加约 90ms。实测总耗时 ~218ms，其中
/// ffmpeg 本身只占 ~120ms。
///
/// 所以这里直接删掉那条路径，只留 ffmpeg，并把省下的复杂度投到真正有收益的地方：
/// **缓存**（回扫零成本）、**目标量化**（同一格不重复取）、**熔断**（没装 ffmpeg
/// 时不要每次 hover 都去启动一个必然失败的进程）。顺带少了一个常驻 libmpv 实例。
///
/// ## 缓存
///
/// 键是**已量化的请求时间**（调度器侧 [thumbnailBucketTargetMs] 保证同一格给出同
/// 一个值），LRU 淘汰。ffmpeg 的 `-ss` 输入定位自带关键帧对齐，落点不可读回，也
/// 不需要读回——同一格必然复用同一条缓存。
class OffscreenVideoFrameGrabber {
  OffscreenVideoFrameGrabber({
    required this.videoPath,
    this.thumbnailWidth = 320,
    this.frameCacheCapacity = 64,
    this.consecutiveFailureLimit = 3,
    this.ffmpegTempDir,
  }) {
    _mediaHandleRegistration =
        MediaHandleRegistry.instance.register(_releaseMediaHandles);
  }

  /// 本地视频文件绝对路径（远端流不应构造本类，调用方先门控）。
  final String videoPath;

  /// 缩略图目标宽度。直接下发给 ffmpeg（`-vf scale=W:-2`），让缩放发生在编码之前
  /// ——全尺寸 JPEG 的编码、落盘、读回、解码四段开销全是白花的。
  final int thumbnailWidth;

  /// 已解码帧的缓存容量。320px 宽的帧约 230KB，64 帧约 15MB。
  final int frameCacheCapacity;

  /// 连续失败多少次后停用取帧。机器上没装 ffmpeg、或媒体根本解不了时，每次 hover
  /// 都去启动一个必然失败的子进程只会让整条控制条发卡；停用后调度器降级
  /// timestampOnly（只显时间戳），这正是移动端一直在走的路径。
  final int consecutiveFailureLimit;

  /// ffmpeg 输出临时目录（默认系统临时目录）。
  final String? ffmpegTempDir;

  bool _disposed = false;
  int _ffmpegSeq = 0;
  int _consecutiveFailures = 0;

  /// 本取帧器是否成功取到过哪怕一帧。见 [isUnavailable]。
  bool _everSucceeded = false;

  /// 当前在跑的取帧。数据根迁移前要 `await` 它跑完，别让 ffmpeg 子进程握着视频
  /// 文件句柄去撞同盘 rename（TODO-1212 的约束在换成 ffmpeg 后依然成立）。
  Future<void>? _inFlightGrab;

  /// 量化后的请求时间(ms) → 已解码帧。插入序即 LRU 序（命中时重新插入到尾部）。
  final LinkedHashMap<int, ui.Image> _frames = LinkedHashMap<int, ui.Image>();

  /// TODO-1212：在 [MediaHandleRegistry] 的句柄释放登记（构造时登记，[dispose]
  /// 注销）。数据根迁移前经注册表 `await` 真等在跑的取帧收尾。
  MediaHandleReleaseCallback? _mediaHandleRegistration;

  /// 取帧是否已被熔断停用。
  ///
  /// 熔断要回答的是「这台机器到底有没有可用的 ffmpeg」，所以**一旦成功过就永不
  /// 熔断**：个别位置取不到帧（片尾、损坏的 GOP）是正常的，不该因此把整个视频的
  /// 缩略图关掉。只有从头到尾一次都没成功过，才认定环境不具备取帧能力。
  bool get isUnavailable =>
      !_everSucceeded && _consecutiveFailures >= consecutiveFailureLimit;

  /// 预热：hover 刚进入进度条时由调度器调用，取一次片头帧。
  ///
  /// 一举两得——**探明 ffmpeg 到底能不能用**（不能用就尽早熔断，别让用户每挪一次
  /// 鼠标都等一个注定失败的进程），顺带把片头那一格暖进缓存。与用户真正 hover 的
  /// 那一格并发，不占用它的时间。
  Future<void> warmUp() async {
    if (_disposed || isUnavailable) return;
    if (_frames.isNotEmpty) return; // 已经取过帧，可用性无需再探。
    try {
      final ui.Image? image = await grab(0);
      image?.dispose();
    } catch (_) {
      // 预热失败不是错误路径：真正取帧时还会再试并按熔断规则计数。
    }
  }

  /// 同步缓存查询（注入给调度器）。命中返回**调用方独占**的 `clone()`，未命中 null。
  ///
  /// 返回 clone 而不是缓存里那张原图：调度器把帧的所有权当成自己的（换帧时会
  /// `dispose()`），直接交出原图会让缓存里的图被外部销毁，下次命中就是一张已死的
  /// 图（"Cannot draw a disposed image"）。clone 与原图共享像素、只加一次引用计数。
  ui.Image? cachedFrame(int targetMs) {
    if (_disposed) return null;
    final ui.Image? image = _frames.remove(targetMs);
    if (image == null) return null;
    _frames[targetMs] = image; // LRU：命中即提到尾部。
    return image.clone();
  }

  /// 取帧入口（注入给 [VideoThumbnailPreviewController]）。缓存优先，未命中走
  /// ffmpeg。返回的帧所有权归调用方（缓存内部另持一份，靠 `clone()` 分离引用计数）。
  Future<ui.Image?> grab(int targetMs) async {
    if (_disposed) return null;
    final ui.Image? cached = cachedFrame(targetMs);
    if (cached != null) return cached;
    if (isUnavailable) return null;

    final Completer<void> done = Completer<void>();
    _inFlightGrab = done.future;
    try {
      final ui.Image? decoded = await _grabViaFfmpeg(targetMs);
      if (decoded == null) {
        _consecutiveFailures++;
        return null;
      }
      _consecutiveFailures = 0;
      _everSucceeded = true;
      if (_disposed) {
        decoded.dispose();
        return null;
      }
      return _cacheFrame(targetMs, decoded);
    } finally {
      _inFlightGrab = null;
      done.complete();
    }
  }

  /// 把新帧收进缓存并返回调用方独占的 clone。同一格已有帧时替换并释放旧的。
  ui.Image _cacheFrame(int targetMs, ui.Image image) {
    _frames.remove(targetMs)?.dispose();
    _frames[targetMs] = image;
    while (_frames.length > frameCacheCapacity) {
      _frames.remove(_frames.keys.first)?.dispose();
    }
    return image.clone();
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
        // 缩放发生在编码之前：缩略图最终只显示 [thumbnailWidth] 宽，全尺寸编码 +
        // 落盘 + 读回 + 解码全是白花的钱。
        scaleWidth: thumbnailWidth,
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

  String _sourceUri() {
    final Uri? uri = Uri.tryParse(videoPath);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return uri.toString();
    }
    return videoPath;
  }

  Future<ui.Image?> _decode(Uint8List bytes) async {
    try {
      // ffmpeg 已按 [thumbnailWidth] 出图，这里的 targetWidth 只是兜底（老缓存 /
      // 缩放被忽略时仍不至于把整帧原图搬进内存）。
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
    for (final ui.Image image in _frames.values) {
      image.dispose();
    }
    _frames.clear();
    // TODO-1212：注销文件句柄释放登记（迁移路径不再触达已销毁的取帧器）。
    final MediaHandleReleaseCallback? registration = _mediaHandleRegistration;
    if (registration != null) {
      MediaHandleRegistry.instance.unregister(registration);
      _mediaHandleRegistration = null;
    }
  }

  /// TODO-1212：可 await 的文件句柄释放（[MediaHandleRegistry] 迁移前调用）。
  /// 先停用取帧（不再起新的 ffmpeg），再等在跑的那个收尾——ffmpeg 子进程在跑时
  /// 握着视频文件句柄，同盘 rename 会撞「文件被占用」。
  Future<void> _releaseMediaHandles() async {
    _disposed = true;
    final Future<void>? inFlight = _inFlightGrab;
    if (inFlight == null) return;
    try {
      await inFlight.timeout(const Duration(seconds: 35));
    } catch (_) {
      // ffmpeg 自身有 30s 上限；再等不到就不能无限阻塞迁移。
    }
  }
}
