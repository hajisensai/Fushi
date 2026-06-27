import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import '_static_channel.dart';

const Map<String, SystemMouseCursor> _cursors = {
  'none': SystemMouseCursors.none,
  'basic': SystemMouseCursors.basic,
  'click': SystemMouseCursors.click,
  'forbidden': SystemMouseCursors.forbidden,
  'wait': SystemMouseCursors.wait,
  'progress': SystemMouseCursors.progress,
  'contextMenu': SystemMouseCursors.contextMenu,
  'help': SystemMouseCursors.help,
  'text': SystemMouseCursors.text,
  'verticalText': SystemMouseCursors.verticalText,
  'cell': SystemMouseCursors.cell,
  'precise': SystemMouseCursors.precise,
  'move': SystemMouseCursors.move,
  'grab': SystemMouseCursors.grab,
  'grabbing': SystemMouseCursors.grabbing,
  'noDrop': SystemMouseCursors.noDrop,
  'alias': SystemMouseCursors.alias,
  'copy': SystemMouseCursors.copy,
  'disappearing': SystemMouseCursors.disappearing,
  'allScroll': SystemMouseCursors.allScroll,
  'resizeLeftRight': SystemMouseCursors.resizeLeftRight,
  'resizeUpDown': SystemMouseCursors.resizeUpDown,
  'resizeUpLeftDownRight': SystemMouseCursors.resizeUpLeftDownRight,
  'resizeUpRightDownLeft': SystemMouseCursors.resizeUpRightDownLeft,
  'resizeUp': SystemMouseCursors.resizeUp,
  'resizeDown': SystemMouseCursors.resizeDown,
  'resizeLeft': SystemMouseCursors.resizeLeft,
  'resizeRight': SystemMouseCursors.resizeRight,
  'resizeUpLeft': SystemMouseCursors.resizeUpLeft,
  'resizeUpRight': SystemMouseCursors.resizeUpRight,
  'resizeDownLeft': SystemMouseCursors.resizeDownLeft,
  'resizeDownRight': SystemMouseCursors.resizeDownRight,
  'resizeColumn': SystemMouseCursors.resizeColumn,
  'resizeRow': SystemMouseCursors.resizeRow,
  'zoomIn': SystemMouseCursors.zoomIn,
  'zoomOut': SystemMouseCursors.zoomOut,
};

SystemMouseCursor _getCursorByName(String name) =>
    _cursors[name] ?? SystemMouseCursors.basic;

/// Pointer button type
// Order must match InAppWebViewPointerEventKind (see in_app_webview.h)
enum PointerButton { none, primary, secondary, tertiary }

/// Pointer Event kind
// Order must match InAppWebViewPointerEventKind (see in_app_webview.h)
enum InAppWebViewPointerEventKind { activate, down, enter, leave, up, update }

/// Attempts to translate a button constant such as [kPrimaryMouseButton]
/// to a [PointerButton]
PointerButton _getButton(int value) {
  switch (value) {
    case kPrimaryMouseButton:
      return PointerButton.primary;
    case kSecondaryMouseButton:
      return PointerButton.secondary;
    case kTertiaryButton:
      return PointerButton.tertiary;
    default:
      return PointerButton.none;
  }
}

const MethodChannel _pluginChannel = IN_APP_WEBVIEW_STATIC_CHANNEL;

/// setSize 去抖判定（TODO-428/420）。
///
/// 喂入 `_setSize` 的三条路径（`SizeChangedLayoutNotification` /
/// `onPointerDown` / postFrame）会在尺寸根本没变时反复调用；每次下发都会经 native
/// `setSurfaceSize` -> `NotifySurfaceSizeChanged` -> `needs_update_=true` ->
/// `OnFrameArrived` 里 `RecreateFramePoolLocked` 退役并重建 WGC 帧池。布局尺寸在两个
/// 值间抖（滚动条出现/消失、DPI 取整、动画）就每帧重建帧池 = 病态 churn，稳定帧出不来。
///
/// 在唯一汇聚点用本判定去重：首次（尚无记录）放行、尺寸真变放行，只拦「与上次下发
/// 完全相等」的重复。纯状态机，便于单测。
class SetSizeDedup {
  double? _width;
  double? _height;
  double? _scaleFactor;

  /// 返回是否应把本次 `(width, height, scaleFactor)` 下发给 native。
  /// 应下发时同时把它记为「最近一次已下发」。
  bool shouldDispatch(double width, double height, double scaleFactor) {
    if (width == _width && height == _height && scaleFactor == _scaleFactor) {
      return false;
    }
    _width = width;
    _height = height;
    _scaleFactor = scaleFactor;
    return true;
  }
}

class CustomFlutterViewControllerValue {
  const CustomFlutterViewControllerValue({
    required this.isInitialized,
  });

  final bool isInitialized;

  CustomFlutterViewControllerValue copyWith({
    bool? isInitialized,
  }) {
    return CustomFlutterViewControllerValue(
      isInitialized: isInitialized ?? this.isInitialized,
    );
  }

  CustomFlutterViewControllerValue.uninitialized()
      : this(
          isInitialized: false,
        );
}

/// Controls a WebView and provides streams for various change events.
class CustomPlatformViewController
    extends ValueNotifier<CustomFlutterViewControllerValue> {
  Completer<void> _creatingCompleter = Completer<void>();
  int _textureId = 0;
  bool _isDisposed = false;

  Future<void> get ready => _creatingCompleter.future;

  late MethodChannel _methodChannel;
  late EventChannel _eventChannel;
  StreamSubscription? _eventStreamSubscription;

  final StreamController<SystemMouseCursor> _cursorStreamController =
      StreamController<SystemMouseCursor>.broadcast();

  // setSize 去抖（TODO-428/420）：在唯一汇聚点 _setSize 拦掉「与上次下发完全相等」的
  // 重复，掐断三条喂入路径（SizeChangedLayoutNotification / onPointerDown / postFrame）
  // 的无谓重复下发，避免 native 端每帧重建 WGC 帧池。判定逻辑见 SetSizeDedup。
  final SetSizeDedup _setSizeDedup = SetSizeDedup();

  /// A stream reflecting the current cursor style.
  Stream<SystemMouseCursor> get _cursor => _cursorStreamController.stream;

  CustomPlatformViewController()
      : super(CustomFlutterViewControllerValue.uninitialized());

  /// Initializes the underlying platform view.
  ///
  /// TODO-904: 失败路径上必须让 [_creatingCompleter] 以错误解放等待者，否则
  /// [dispose] 首行 `await _creatingCompleter.future` 在创建失败时永久挂起、native
  /// `'dispose'` 永远到不了，导致资源不回收（死亡螺旋）。成功路径行为零变化。
  Future<void> initialize(
      {Function(int id)? onPlatformViewCreated, dynamic arguments}) async {
    if (_isDisposed) {
      return;
    }
    try {
      _textureId = (await _pluginChannel.invokeMethod<int>(
          'createInAppWebView', arguments))!;

      _methodChannel =
          MethodChannel('com.pichillilorenzo/custom_platform_view_$_textureId');
      _eventChannel = EventChannel(
          'com.pichillilorenzo/custom_platform_view_${_textureId}_events');
      _eventStreamSubscription =
          _eventChannel.receiveBroadcastStream().listen((event) {
        final map = event as Map<dynamic, dynamic>;
        switch (map['type']) {
          case 'cursorChanged':
            _cursorStreamController.add(_getCursorByName(map['value']));
            break;
        }
      });

      _methodChannel.setMethodCallHandler((call) {
        throw MissingPluginException('Unknown method ${call.method}');
      });

      value = value.copyWith(isInitialized: true);

      _creatingCompleter.complete();

      onPlatformViewCreated?.call(_textureId);
    } catch (error, stackTrace) {
      // 让 dispose() 的等待者带错误解放，绝不留未完成的 completer。
      if (!_creatingCompleter.isCompleted) {
        _creatingCompleter.completeError(error, stackTrace);
      }
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    // TODO-904: 不无条件 await 失败的 completer。创建失败时 completer 带错误，
    // 这里吞掉等待异常即可继续走 native dispose 兜底回收；成功路径 await 正常完成、
    // 行为零变化。
    try {
      await _creatingCompleter.future;
    } catch (_) {
      // 创建失败：completer 已 completeError。不阻断 dispose，继续兜底回收。
    }
    if (_isDisposed) {
      // 已 dispose：第二次调用整体 no-op，绝不重复 super.dispose()（会触发
      // ChangeNotifier 的 used-after-dispose 断言），也不重复发 native dispose。
      return;
    }
    _isDisposed = true;
    await _eventStreamSubscription?.cancel();
    // 失败时 _textureId 保持默认 0：native manager 对未知 id 是纯 no-op
    // （map_contains(webViews, 0) 为 false），不会 double-free。
    await _pluginChannel.invokeMethod('dispose', {"id": _textureId});
    super.dispose();
  }

  /// Limits the number of frames per second to the given value.
  Future<void> setFpsLimit([int? maxFps = 0]) async {
    if (_isDisposed) {
      return;
    }
    assert(value.isInitialized);
    return _methodChannel.invokeMethod('setFpsLimit', maxFps);
  }

  /// Sends a Pointer (Touch) update
  Future<void> _setPointerUpdate(InAppWebViewPointerEventKind kind, int pointer,
      Offset position, double size, double pressure) async {
    if (_isDisposed) {
      return;
    }
    assert(value.isInitialized);
    return _methodChannel.invokeMethod('setPointerUpdate',
        [pointer, kind.index, position.dx, position.dy, size, pressure]);
  }

  /// Moves the virtual cursor to [position].
  Future<void> _setCursorPos(Offset position) async {
    if (_isDisposed) {
      return;
    }
    assert(value.isInitialized);
    return _methodChannel
        .invokeMethod('setCursorPos', [position.dx, position.dy]);
  }

  /// Indicates whether the specified [button] is currently down.
  Future<void> _setPointerButtonState(PointerButton button, bool isDown) async {
    if (_isDisposed) {
      return;
    }
    assert(value.isInitialized);
    return _methodChannel.invokeMethod('setPointerButton',
        <String, dynamic>{'button': button.index, 'isDown': isDown});
  }

  /// Sets the horizontal and vertical scroll delta.
  Future<void> _setScrollDelta(double dx, double dy) async {
    if (_isDisposed) {
      return;
    }
    assert(value.isInitialized);
    return _methodChannel.invokeMethod('setScrollDelta', [dx, dy]);
  }

  /// Sets the surface size to the provided [size].
  Future<void> _setSize(Size size, double scaleFactor) async {
    if (_isDisposed) {
      return;
    }
    assert(value.isInitialized);
    // 尺寸去抖（TODO-428/420）：与上次真正下发的三元组完全相等则直接返回，不再
    // invokeMethod，避免 native 端无谓地置 needs_update_ 并重建 WGC 帧池。首次
    // （尚无记录）和尺寸真变都会被放行下发。
    if (!_setSizeDedup.shouldDispatch(size.width, size.height, scaleFactor)) {
      return;
    }
    return _methodChannel
        .invokeMethod('setSize', [size.width, size.height, scaleFactor]);
  }

  /// Sets the surface size to the provided [size].
  Future<void> _setPosition(Offset position, double scaleFactor) async {
    if (_isDisposed) {
      return;
    }
    assert(value.isInitialized);
    return _methodChannel
        .invokeMethod('setPosition', [position.dx, position.dy, scaleFactor]);
  }
}

class CustomPlatformView extends StatefulWidget {
  /// An optional scale factor. Defaults to [FlutterView.devicePixelRatio] for
  /// rendering in native resolution.
  /// Setting this to 1.0 will disable high-DPI support.
  /// This should only be needed to mimic old behavior before high-DPI support
  /// was available.
  final double? scaleFactor;

  /// The [FilterQuality] used for scaling the texture's contents.
  /// Defaults to [FilterQuality.none] as this renders in native resolution
  /// unless specifying a [scaleFactor].
  final FilterQuality filterQuality;

  final dynamic creationParams;

  final Function(int id)? onPlatformViewCreated;

  /// TODO-904: native WebView2 实例创建失败时的回调（如
  /// `Cannot create the InAppWebView instance!`）。原本 initialize() 是未捕获
  /// Future，失败被 UncaughtZone 静默吞掉、上层永远收不到信号 → reader 永久 spinner。
  /// 此回调把失败冒泡给上层，让 reader 走可见恢复（toast + 退回书架）。
  final void Function(Object error, StackTrace stackTrace)? onCreationError;

  const CustomPlatformView(
      {this.creationParams,
      this.onPlatformViewCreated,
      this.onCreationError,
      this.scaleFactor,
      this.filterQuality = FilterQuality.none});

  @override
  _CustomPlatformViewState createState() => _CustomPlatformViewState();
}

class _CustomPlatformViewState extends State<CustomPlatformView> {
  final GlobalKey _key = GlobalKey();
  final _downButtons = <int, PointerButton>{};

  PointerDeviceKind _pointerKind = PointerDeviceKind.unknown;

  MouseCursor _cursor = SystemMouseCursors.basic;

  final _controller = CustomPlatformViewController();
  final _focusNode = FocusNode();

  StreamSubscription? _cursorSubscription;

  @override
  void initState() {
    super.initState();

    // TODO-904: 不再裸 fire-and-forget。失败时把错误冒泡给上层（onCreationError），
    // 而不是逃逸到 UncaughtZone 被静默吞掉 → reader 可走可见恢复而非永久 spinner。
    _controller
        .initialize(
      onPlatformViewCreated: (id) {
        widget.onPlatformViewCreated?.call(id);
        setState(() {});
      },
      arguments: widget.creationParams,
    )
        .catchError((Object error, StackTrace stackTrace) {
      if (!mounted) return;
      widget.onCreationError?.call(error, stackTrace);
    });

    // Report initial surface size and widget position
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reportSurfaceSize();
      _reportWidgetPosition();
    });

    _cursorSubscription = _controller._cursor.listen((cursor) {
      setState(() {
        _cursor = cursor;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      focusNode: _focusNode,
      canRequestFocus: true,
      debugLabel: "flutter_inappwebview_windows_custom_platform_view",
      onFocusChange: (focused) {},
      child: SizedBox.expand(key: _key, child: _buildInner()),
    );
  }

  Widget _buildInner() {
    return NotificationListener<SizeChangedLayoutNotification>(
        onNotification: (notification) {
          _reportSurfaceSize();
          _reportWidgetPosition();
          return true;
        },
        child: SizeChangedLayoutNotifier(
            child: _controller.value.isInitialized
                ? Listener(
                    onPointerHover: (ev) {
                      // ev.kind is for whatever reason not set to touch
                      // even on touch input
                      if (_pointerKind == PointerDeviceKind.touch) {
                        // Ignoring hover events on touch for now
                        return;
                      }
                      _controller._setCursorPos(ev.localPosition);
                    },
                    onPointerDown: (ev) {
                      _reportSurfaceSize();
                      _reportWidgetPosition();

                      if (!_focusNode.hasFocus) {
                        _focusNode.requestFocus();
                        Future.delayed(const Duration(milliseconds: 50), () {
                          if (!_focusNode.hasFocus) {
                            _focusNode.requestFocus();
                          }
                        });
                      }

                      _pointerKind = ev.kind;
                      if (ev.kind == PointerDeviceKind.touch) {
                        _controller._setPointerUpdate(
                            InAppWebViewPointerEventKind.down,
                            ev.pointer,
                            ev.localPosition,
                            ev.size,
                            ev.pressure);
                        return;
                      }
                      final button = _getButton(ev.buttons);
                      _downButtons[ev.pointer] = button;
                      _controller._setPointerButtonState(button, true);
                    },
                    onPointerUp: (ev) {
                      _pointerKind = ev.kind;
                      if (ev.kind == PointerDeviceKind.touch) {
                        _controller._setPointerUpdate(
                            InAppWebViewPointerEventKind.up,
                            ev.pointer,
                            ev.localPosition,
                            ev.size,
                            ev.pressure);
                        return;
                      }
                      final button = _downButtons.remove(ev.pointer);
                      if (button != null) {
                        _controller._setPointerButtonState(button, false);
                      }
                    },
                    onPointerCancel: (ev) {
                      _pointerKind = ev.kind;
                      final button = _downButtons.remove(ev.pointer);
                      if (button != null) {
                        _controller._setPointerButtonState(button, false);
                      }
                    },
                    onPointerMove: (ev) {
                      _pointerKind = ev.kind;
                      if (ev.kind == PointerDeviceKind.touch) {
                        _controller._setPointerUpdate(
                            InAppWebViewPointerEventKind.update,
                            ev.pointer,
                            ev.localPosition,
                            ev.size,
                            ev.pressure);
                      } else {
                        _controller._setCursorPos(ev.localPosition);
                      }
                    },
                    onPointerSignal: (signal) {
                      if (signal is PointerScrollEvent) {
                        _controller._setScrollDelta(
                            -signal.scrollDelta.dx, -signal.scrollDelta.dy);
                      }
                    },
                    onPointerPanZoomUpdate: (ev) {
                      _controller._setScrollDelta(
                          ev.panDelta.dx, ev.panDelta.dy);
                    },
                    child: MouseRegion(
                        cursor: _cursor,
                        child: Texture(
                          textureId: _controller._textureId,
                          filterQuality: widget.filterQuality,
                        )),
                  )
                : const SizedBox()));
  }

  void _reportSurfaceSize() async {
    final context = _key.currentContext;
    final box = context?.findRenderObject() as RenderBox?;
    if (box != null && context != null) {
      await _controller.ready;
      unawaited(_controller._setSize(
          box.size, widget.scaleFactor ?? View.of(context).devicePixelRatio));
    }
  }

  void _reportWidgetPosition() async {
    final context = _key.currentContext;
    final box = context?.findRenderObject() as RenderBox?;
    if (box != null && context != null) {
      await _controller.ready;
      final position = box.localToGlobal(Offset.zero);
      unawaited(_controller._setPosition(
          position, widget.scaleFactor ?? View.of(context).devicePixelRatio));
    }
  }

  @override
  void dispose() {
    super.dispose();
    _cursorSubscription?.cancel();
    _controller.dispose();
    _focusNode.dispose();
  }
}
