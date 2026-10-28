import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:fushi_compute/fushi_compute.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 本地 AVIF 文件（动图 `avis` 或静态图）的播放控件。
///
/// Flutter 自带 codec 对 AVIF 动图只出首帧（静态 AVIF 能否解取决于各平台引擎），所以解码走
/// 原生内核（native/fushi_compute `image/avif/sequence.rs`）：一个常驻后台 isolate 持有
/// Rust 侧的解码句柄，**按需逐帧**解（不把整段动图解进内存），帧以 [TransferableTypedData]
/// 交回 UI isolate 再 [ui.ImageDescriptor.raw] 成 [ui.Image]。总是预取下一帧，按每帧时长用
/// [Ticker] 换帧。
///
/// - 解码宽度：布局约束（宽，以及高 × 宽高比）× devicePixelRatio，只缩不放；[maxDecodeWidth]
///   再封一道顶（物理像素）。约束变大时重开句柄按新宽度解。
/// - 布局尺寸与 `Image(image: FileImage(file))` 相同：自然尺寸 = 源图像素数（逻辑像素），
///   由父约束收；[fit] / [alignment] 同 [RawImage]。
/// - 暂停：[TickerMode] 关（被别的路由盖住 / 页签在后台）、完全滚出视口（[VisibilityDetector]）、
///   装饰性动效关闭（墨水屏 / 系统「减弱动态效果」，见 [fushiMotionEnabled]）时不换帧也不预取；
///   动效关闭时只显示首帧。
/// - 文件要求不循环（`elst` 无 repeat）时停在末帧；坏样本停在已显示的帧上。
/// - 解不开：有 [errorBuilder] 就交给它，否则 [FlutterError.reportError] 并渲染空。原生库缺失
///   （[FushiComputeUnavailableError]）总是 [FlutterError.reportError]，再交给 [errorBuilder]。
class FushiAnimatedAvifImage extends StatefulWidget {
  const FushiAnimatedAvifImage({
    super.key,
    required this.file,
    this.fit,
    this.alignment = Alignment.center,
    this.maxDecodeWidth,
    this.errorBuilder,
    this.semanticLabel,
    this.filterQuality = FilterQuality.medium,
    this.onFirstFrame,
  });

  final File file;

  /// 同 [Image.fit]。
  final BoxFit? fit;

  /// 同 [Image.alignment]。
  final AlignmentGeometry alignment;

  /// 解码宽度上限（物理像素）；null = 只按布局约束 × devicePixelRatio 定。
  final int? maxDecodeWidth;

  /// 同 [Image.errorBuilder]。
  final ImageErrorWidgetBuilder? errorBuilder;

  /// 同 [Image.semanticLabel]。
  final String? semanticLabel;

  /// 同 [Image.filterQuality]。
  final FilterQuality filterQuality;

  /// 首帧解出并画上屏后回调一次（换文件 / 重开后的首帧同样回调）。调用方据此在「新实例」
  /// 出画面之前一直垫着旧实例，避免替换瞬间闪空。
  final VoidCallback? onFirstFrame;

  @override
  State<FushiAnimatedAvifImage> createState() => _FushiAnimatedAvifImageState();
}

/// [FushiAnimatedAvifImage] 解不开文件（不是 AVIF / 坏图）或原生侧报错。
class FushiAnimatedAvifException implements Exception {
  const FushiAnimatedAvifException(this.path, this.message);

  final String path;
  final String message;

  @override
  String toString() => 'FushiAnimatedAvifException($path): $message';
}

class _FushiAnimatedAvifImageState extends State<FushiAnimatedAvifImage>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  final Key _visibilityKey = UniqueKey();

  /// 每次换文件 / 重开句柄 +1：晚到的旧回复按它丢弃。
  int _generation = 0;
  _AvifWorker? _worker;
  int? _handle;
  bool _opening = false;

  /// 打开时请求的解码宽度（物理像素，0 = 不限）。
  int _requestedWidth = -1;

  _AvifFrame? _current;
  _AvifFrame? _next;
  bool _fetching = false;

  _AvifInfo? _info;
  Object? _error;
  StackTrace? _errorStack;

  /// 当前帧开始显示时的 ticker 时刻。
  Duration _shownAt = Duration.zero;

  bool _finished = false;
  bool _visible = true;
  bool _tickerEnabled = true;
  bool _motionEnabled = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.of(context);
    _motionEnabled = fushiMotionEnabled(context);
    _updateRunning();
  }

  @override
  void didUpdateWidget(FushiAnimatedAvifImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path ||
        oldWidget.maxDecodeWidth != widget.maxDecodeWidth) {
      _closeHandle();
      _current?.image.dispose();
      _current = null;
      _info = null;
      _error = null;
      _errorStack = null;
      _requestedWidth = -1;
      _finished = false;
    }
  }

  @override
  void dispose() {
    _closeHandle();
    _ticker.dispose();
    _current?.image.dispose();
    _current = null;
    super.dispose();
  }

  /// 作废当前句柄与预取（保留正在显示的帧）。
  void _closeHandle() {
    _generation++;
    _ticker.stop();
    final int? handle = _handle;
    if (handle != null) _worker?.close(handle);
    _handle = null;
    _worker = null;
    _opening = false;
    _fetching = false;
    _next?.image.dispose();
    _next = null;
  }

  /// 按布局约束算出需要的解码宽度（物理像素，0 = 不限）。
  int _neededWidth(BoxConstraints constraints, double dpr) {
    double limit = double.infinity;
    if (constraints.hasBoundedWidth) limit = constraints.maxWidth * dpr;
    final _AvifInfo? info = _info;
    if (constraints.hasBoundedHeight && info != null) {
      limit = math.min(
        limit,
        constraints.maxHeight * dpr * info.sourceWidth / info.sourceHeight,
      );
    }
    final int? cap = widget.maxDecodeWidth;
    if (cap != null && cap > 0) limit = math.min(limit, cap.toDouble());
    if (limit.isInfinite) return 0;
    return math.max(1, limit.ceil());
  }

  /// 布局时调用：还没打开就打开；约束变大到超过已解宽度（且源图更宽）就重开。
  void _ensureOpen(BoxConstraints constraints, double dpr) {
    if (_error != null) return;
    final int needed = _neededWidth(constraints, dpr);
    if (_opening) return;
    final _AvifInfo? info = _info;
    if (info == null && _handle == null) {
      _open(needed, constraints, dpr);
      return;
    }
    if (info == null) return;
    final bool grew =
        _requestedWidth != 0 &&
        (needed == 0 || needed > info.width) &&
        info.width < info.sourceWidth;
    if (grew) {
      _closeHandle();
      _open(needed, constraints, dpr);
    }
  }

  void _open(int width, BoxConstraints constraints, double dpr) {
    final int generation = ++_generation;
    _opening = true;
    _requestedWidth = width;
    final _AvifWorker worker = _AvifWorker.acquire();
    _worker = worker;
    // 高度约束要按源宽高比折成宽度，而首次打开时还不知道宽高比：交给 worker 先 probe。
    final int heightLimit = constraints.hasBoundedHeight && _info == null
        ? math.max(1, (constraints.maxHeight * dpr).ceil())
        : 0;
    unawaited(
      worker
          .open(widget.file.path, width, heightLimit)
          .then(
            (_AvifOpened opened) => _onOpened(generation, worker, opened),
            onError: (Object error, StackTrace stack) {
              worker.release();
              if (!mounted || generation != _generation) return;
              _fail(error, stack);
            },
          ),
    );
  }

  Future<void> _onOpened(
    int generation,
    _AvifWorker worker,
    _AvifOpened opened,
  ) async {
    final ui.Image image;
    try {
      image = await opened.frame.toImage(opened.info);
    } on Object catch (error, stack) {
      worker.close(opened.handle);
      if (mounted && generation == _generation) _fail(error, stack);
      return;
    }
    if (!mounted || generation != _generation) {
      image.dispose();
      worker.close(opened.handle);
      return;
    }
    setState(() {
      _opening = false;
      _info = opened.info;
      _current?.image.dispose();
      _current = _AvifFrame(image, opened.frame.index, opened.frame.durationMs);
      _finished = false;
      if (opened.info.frameCount > 1) {
        _handle = opened.handle;
      } else {
        // 静态图：一帧就够，立即还掉原生句柄。
        worker.close(opened.handle);
        _worker = null;
      }
    });
    _updateRunning(restart: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _generation) widget.onFirstFrame?.call();
    });
  }

  void _fail(Object error, StackTrace? stack) {
    _closeHandle();
    // 原生库是硬依赖：缺库不是「这张图坏了」，有 errorBuilder 也照样报出来。
    if (widget.errorBuilder == null || error is FushiComputeUnavailableError) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'fushi animated avif',
          context: ErrorDescription('decoding ${widget.file.path}'),
        ),
      );
    }
    setState(() {
      _error = error;
      _errorStack = stack;
    });
  }

  bool get _shouldRun =>
      _handle != null &&
      _current != null &&
      !_finished &&
      _visible &&
      _tickerEnabled &&
      _motionEnabled;

  void _updateRunning({bool restart = false}) {
    if (_shouldRun) {
      if (restart && _ticker.isActive) _ticker.stop();
      if (!_ticker.isActive) {
        // 重新开始计时：恢复时当前帧再完整显示一个时长，而不是因暂停期间的时间立刻跳帧。
        _shownAt = Duration.zero;
        _ticker.start();
      }
      _prefetch();
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
  }

  void _prefetch() {
    final int? handle = _handle;
    final _AvifWorker? worker = _worker;
    if (handle == null || worker == null || _fetching || _next != null) return;
    _fetching = true;
    final int generation = _generation;
    unawaited(
      worker
          .next(handle)
          .then(
            (_AvifFrameData? data) async {
              final _AvifInfo? info = _info;
              if (data == null || info == null) {
                // 坏样本：停在当前帧。
                if (mounted && generation == _generation) {
                  _fetching = false;
                  _finished = true;
                  _updateRunning();
                }
                return;
              }
              final ui.Image image;
              try {
                image = await data.toImage(info);
              } on Object catch (error, stack) {
                if (mounted && generation == _generation) _fail(error, stack);
                return;
              }
              if (!mounted || generation != _generation) {
                image.dispose();
                return;
              }
              _fetching = false;
              _next = _AvifFrame(image, data.index, data.durationMs);
            },
            onError: (Object error, StackTrace stack) {
              if (!mounted || generation != _generation) return;
              _fail(error, stack);
            },
          ),
    );
  }

  void _onTick(Duration elapsed) {
    final _AvifFrame? current = _current;
    final _AvifFrame? next = _next;
    final _AvifInfo? info = _info;
    if (current == null || next == null || info == null) return;
    if (elapsed - _shownAt < Duration(milliseconds: current.durationMs)) {
      return;
    }
    setState(() {
      current.image.dispose();
      _current = next;
      _next = null;
      _shownAt = elapsed;
    });
    if (!info.repeats && next.index == info.frameCount - 1) {
      _finished = true;
      _updateRunning();
      return;
    }
    _prefetch();
  }

  void _onVisibilityChanged(VisibilityInfo visibility) {
    // 首帧出来之前控件是 0×0，可见比例恒为 0，不代表滚出了视口。
    if (!mounted || _current == null) return;
    final bool visible = visibility.visibleFraction > 0;
    if (visible == _visible) return;
    _visible = visible;
    _updateRunning();
  }

  @override
  Widget build(BuildContext context) {
    final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final Object? error = _error;
    if (error != null) {
      final ImageErrorWidgetBuilder? builder = widget.errorBuilder;
      return builder == null
          ? const SizedBox.shrink()
          : builder(context, error, _errorStack);
    }
    Widget child = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _ensureOpen(constraints, dpr);
        final _AvifFrame? frame = _current;
        final _AvifInfo? info = _info;
        if (frame == null || info == null) return const SizedBox.shrink();
        return RawImage(
          image: frame.image,
          // 自然尺寸 = 源图像素数（同 FileImage 的 scale 1），缩小解码不改变布局。
          scale: frame.image.width / info.sourceWidth,
          fit: widget.fit,
          alignment: widget.alignment,
          filterQuality: widget.filterQuality,
        );
      },
    );
    child = VisibilityDetector(
      key: _visibilityKey,
      onVisibilityChanged: _onVisibilityChanged,
      child: child,
    );
    final String? label = widget.semanticLabel;
    if (label != null) {
      child = Semantics(image: true, label: label, child: child);
    }
    return child;
  }
}

// ---------------------------------------------------------------------------
// 帧与后台 isolate 协议
// ---------------------------------------------------------------------------

@immutable
class _AvifInfo {
  const _AvifInfo({
    required this.width,
    required this.height,
    required this.frameCount,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.repeats,
  });

  /// 解码输出尺寸（物理像素）。
  final int width;
  final int height;
  final int frameCount;
  final int sourceWidth;
  final int sourceHeight;
  final bool repeats;
}

class _AvifFrame {
  _AvifFrame(this.image, this.index, this.durationMs);

  final ui.Image image;
  final int index;
  final int durationMs;
}

/// worker 交回的一帧（RGBA8888 像素在 [TransferableTypedData] 里）。
class _AvifFrameData {
  const _AvifFrameData(this.index, this.durationMs, this.pixels);

  final int index;
  final int durationMs;
  final TransferableTypedData pixels;

  Future<ui.Image> toImage(_AvifInfo info) async {
    final Uint8List rgba = pixels.materialize().asUint8List();
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      rgba,
    );
    final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: info.width,
      height: info.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final ui.Codec codec = await descriptor.instantiateCodec();
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }
}

class _AvifOpened {
  const _AvifOpened(this.handle, this.info, this.frame);

  final int handle;
  final _AvifInfo info;
  final _AvifFrameData frame;
}

/// 全进程共用的一个后台解码 isolate。按打开的句柄计数：最后一个句柄关掉后 isolate 退出，
/// 下次再用时重新拉起（卡片翻页时不会一直攥着一个 isolate）。
class _AvifWorker {
  _AvifWorker._() {
    // 端口与 spawn 的回调都放在根 zone：worker 跨多个控件（乃至测试用例）共用，消息收发不能
    // 挂在第一个打开它的控件所在的 zone 上（那个 zone 结束后就再也收不到 / 发不出）。等待方
    // 各自在自己的 zone 里接 Future 的回调。
    Zone.root.run(() {
      _receive = RawReceivePort(_onMessage, 'fushi-avif-reply');
      Isolate.spawn<SendPort>(
        _avifWorkerMain,
        _receive.sendPort,
        debugName: 'fushi-avif',
      ).then<void>((_) {}, onError: _onSpawnError);
    });
  }

  static _AvifWorker? _instance;

  late final RawReceivePort _receive;

  /// worker 的命令端口；就绪前的请求排在 [_queued] 里。
  SendPort? _commands;
  final List<List<Object?>> _queued = <List<Object?>>[];
  Object? _spawnError;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  int _nextRequest = 0;

  /// 已打开（含打开中）的句柄数。
  int _users = 0;
  bool _exited = false;

  /// 取共用 worker 并占一个名额（[open] 失败或 [close] 时归还）。
  static _AvifWorker acquire() {
    final _AvifWorker worker = _instance ??= _AvifWorker._();
    worker._users++;
    return worker;
  }

  /// 归还 [acquire] 占的名额；归零且没有在途请求时让 isolate 退出。
  void release() {
    _users--;
    _maybeExit();
  }

  void _maybeExit() {
    // 还没握手完不退：此时关掉回复端口，刚起来的 isolate 就收不到 exit、永远挂着。
    if (_exited || _users > 0 || _pending.isNotEmpty || _commands == null) {
      return;
    }
    _exited = true;
    if (identical(_instance, this)) _instance = null;
    _send(<Object?>[-1, 'exit']);
    _receive.close();
  }

  void _send(List<Object?> message) {
    final SendPort? port = _commands;
    if (port != null) {
      port.send(message);
    } else if (_spawnError == null) {
      _queued.add(message);
    }
  }

  void _onSpawnError(Object error, StackTrace stack) {
    _spawnError = error;
    _queued.clear();
    final List<Completer<Object?>> waiting = _pending.values.toList();
    _pending.clear();
    for (final Completer<Object?> c in waiting) {
      c.completeError(error, stack);
    }
    if (identical(_instance, this)) _instance = null;
    _receive.close();
  }

  Future<Object?> _request(List<Object?> message) {
    final Object? spawnError = _spawnError;
    if (spawnError != null) return Future<Object?>.error(spawnError);
    final int id = _nextRequest++;
    final Completer<Object?> completer = Completer<Object?>();
    _pending[id] = completer;
    _send(<Object?>[id, ...message]);
    return completer.future;
  }

  void _onMessage(Object? message) {
    if (message is SendPort) {
      _commands = message;
      for (final List<Object?> m in _queued) {
        message.send(m);
      }
      _queued.clear();
      _maybeExit();
      return;
    }
    final List<Object?> reply = message! as List<Object?>;
    final Completer<Object?>? completer = _pending.remove(reply[0]! as int);
    if (completer == null) return;
    final Object? body = reply[1];
    if (body is _WorkerError) {
      completer.completeError(body.error);
    } else {
      completer.complete(body);
    }
    _maybeExit();
  }

  /// 打开 [path]：`widthLimit` / `heightLimit` 是物理像素上限（0 = 不限；高度按源宽高比
  /// 折成宽度）。成功回首帧；失败抛 [FushiAnimatedAvifException] /
  /// [FushiComputeUnavailableError] 的转述。
  Future<_AvifOpened> open(String path, int widthLimit, int heightLimit) async {
    final List<Object?> r =
        (await _request(<Object?>['open', path, widthLimit, heightLimit]))!
            as List<Object?>;
    return _AvifOpened(
      r[0]! as int,
      _AvifInfo(
        width: r[1]! as int,
        height: r[2]! as int,
        frameCount: r[3]! as int,
        sourceWidth: r[4]! as int,
        sourceHeight: r[5]! as int,
        repeats: r[6]! as bool,
      ),
      _AvifFrameData(
        r[7]! as int,
        r[8]! as int,
        r[9]! as TransferableTypedData,
      ),
    );
  }

  /// 解句柄的下一帧；坏样本回 null。
  Future<_AvifFrameData?> next(int handle) async {
    final List<Object?>? r =
        await _request(<Object?>['next', handle]) as List<Object?>?;
    if (r == null) return null;
    return _AvifFrameData(
      r[0]! as int,
      r[1]! as int,
      r[2]! as TransferableTypedData,
    );
  }

  /// 关闭句柄并归还名额。
  void close(int handle) {
    unawaited(
      _request(<Object?>[
        'close',
        handle,
      ]).then<void>((_) {}, onError: (Object _) {}),
    );
    release();
  }
}

/// worker 侧异常的可传递形态（异常对象本身未必能跨 isolate 发送）。
class _WorkerError {
  const _WorkerError(this.error);

  final Object error;
}

/// 后台 isolate 入口：持有 [FfcAvifAnimation] 句柄，按请求逐帧解码。
void _avifWorkerMain(SendPort reply) {
  final Map<int, FfcAvifAnimation> handles = <int, FfcAvifAnimation>{};
  int nextHandle = 0;
  final RawReceivePort port = RawReceivePort(null, 'fushi-avif-commands');
  port.handler = (Object? message) {
    final List<Object?> m = message! as List<Object?>;
    final int id = m[0]! as int;
    final String op = m[1]! as String;
    Object? body;
    try {
      switch (op) {
        case 'open':
          body = _workerOpen(
            handles,
            nextHandle++,
            m[2]! as String,
            m[3]! as int,
            m[4]! as int,
          );
        case 'next':
          final FfcAvifAnimation? anim = handles[m[2]! as int];
          final FfcAvifFrame? frame = anim?.nextFrame();
          body = frame == null
              ? null
              : <Object?>[
                  frame.index,
                  frame.durationMs,
                  TransferableTypedData.fromList(<TypedData>[frame.pixels]),
                ];
        case 'close':
          handles.remove(m[2]! as int)?.close();
        case 'exit':
          for (final FfcAvifAnimation anim in handles.values) {
            anim.close();
          }
          handles.clear();
          port.close();
          return;
      }
    } on FushiComputeUnavailableError catch (e) {
      // 部署缺陷（库缺失 / 缺符号）：原样转述成同类型，UI 侧不当普通坏图吞掉。
      body = _WorkerError(FushiComputeUnavailableError(e.message, e.attempts));
    } on Object catch (e) {
      body = _WorkerError(
        e is FushiAnimatedAvifException
            ? e
            : FushiAnimatedAvifException(
                op == 'open' ? m[2]! as String : '<handle>',
                e.toString(),
              ),
      );
    }
    reply.send(<Object?>[id, body]);
  };
  reply.send(port.sendPort);
}

List<Object?> _workerOpen(
  Map<int, FfcAvifAnimation> handles,
  int handle,
  String path,
  int widthLimit,
  int heightLimit,
) {
  final Uint8List bytes = File(path).readAsBytesSync();
  int maxWidth = widthLimit;
  if (heightLimit > 0) {
    // 先只读容器拿宽高比，把高度上限折成宽度（静态主图 = 动图首帧的显示尺寸）。
    final ({int width, int height, FfcImageFormat format})? probe =
        FushiComputeImage.instance.probe(bytes);
    if (probe != null && probe.height > 0) {
      final int fromHeight = math.max(
        1,
        (heightLimit * probe.width / probe.height).ceil(),
      );
      maxWidth = maxWidth == 0 ? fromHeight : math.min(maxWidth, fromHeight);
    }
  }
  final FfcAvifAnimation? anim = FfcAvifAnimation.open(
    bytes,
    maxWidth: maxWidth,
  );
  if (anim == null) {
    throw FushiAnimatedAvifException(path, 'not a decodable AVIF');
  }
  final FfcAvifFrame? first = anim.nextFrame();
  if (first == null) {
    anim.close();
    throw FushiAnimatedAvifException(path, 'first frame failed to decode');
  }
  handles[handle] = anim;
  return <Object?>[
    handle,
    anim.width,
    anim.height,
    anim.frameCount,
    anim.sourceWidth,
    anim.sourceHeight,
    anim.repeats,
    first.index,
    first.durationMs,
    TransferableTypedData.fromList(<TypedData>[first.pixels]),
  ];
}
