/// Android 系统画中画（Picture-in-Picture）的唯一 Dart 门面。
///
/// 原生实现在 `android/app/src/main/java/app/fushi/reader/PictureInPictureChannelHandler.java`，
/// 方法名与参数名是跨语言契约，改一边必须改另一边。
///
/// **三条真实陷阱**（原生侧同样写了一份，这里是给 Dart 调用方看的）：
///
/// 1. **版本门**：`PictureInPictureParams` 是 API 26 才有的，而本 app minSdk 24；
///    另外电视 / 部分定制 ROM 会整块关掉 PiP。所以「支不支持」只能问原生，不能
///    靠版本号在 Dart 侧猜。非 Android 平台恒 false，且**不发任何通道调用**——
///    那边压根没注册这条通道，发过去只会换来一个 MissingPluginException。
/// 2. **宽高比钳制**：系统只接受 `[1/2.39, 2.39]` 区间内的比例，越界时
///    `enterPictureInPictureMode` 抛 IllegalArgumentException。视频的真实比例
///    （竖屏短视频、超宽银幕片源）很容易越界，所以送进原生之前先过
///    [clampPictureInPictureAspectRatio]。
/// 3. **退出不走 enter()**：用户从小窗的关闭 / 还原按钮出来时不经过我们的
///    [AndroidPictureInPicture.enter]，只有原生回程 `onChanged` 能告诉我们。
///    因此 [AndroidPictureInPicture.isActive] 的进程内缓存必须由那条回程驱动，
///    不能只在 enter 成功时置位。
/// 4. **小窗上的按钮是 app 给的，不是系统自带的**：Android 只在 app 通过
///    `PictureInPictureParams.setActions` 交了 `RemoteAction`（或有活动的
///    MediaSession）时才在 PiP 窗口上画播放控件，否则只有「展开 / 关闭」。所以
///    播放 / 暂停键由 [PictureInPictureControls] 描述、随
///    [AndroidPictureInPicture.enter] / [AndroidPictureInPicture.update] 送给
///    原生；用户点它时原生经 `onAction` 回程，落到
///    [AndroidPictureInPicture.actions]。图标跟播放态走，播放态一变就得
///    `update` 一次。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// Android PiP 允许的最小宽高比（1:2.39，竖向极限）。
const double kPictureInPictureMinAspectRatio = 1 / 2.39;

/// Android PiP 允许的最大宽高比（2.39:1，横向极限）。
const double kPictureInPictureMaxAspectRatio = 2.39;

/// 拿不到可用比例时的兜底（16:9，落在允许区间内）。
const double kPictureInPictureDefaultAspectRatio = 16 / 9;

/// 把任意宽高比钳制进 Android PiP 允许的 `[1/2.39, 2.39]` 区间；
/// `<= 0` 或非有限值（NaN / ±Infinity）退回 16:9。
///
/// 抽成纯函数是为了让这条「越界就抛」的系统约束有一个可测的落点：视频真实比例
/// 来自解码器，竖屏短视频（9:16 ≈ 0.5625，尚在区间内）与极端裁切片源都可能落到
/// 区间外，而失败形态是原生抛 IllegalArgumentException——在真机上表现为「点了
/// 小窗没反应」，很难反查到比例上。
double clampPictureInPictureAspectRatio(double aspectRatio) {
  if (!aspectRatio.isFinite || aspectRatio <= 0) {
    return kPictureInPictureDefaultAspectRatio;
  }
  if (aspectRatio < kPictureInPictureMinAspectRatio) {
    return kPictureInPictureMinAspectRatio;
  }
  if (aspectRatio > kPictureInPictureMaxAspectRatio) {
    return kPictureInPictureMaxAspectRatio;
  }
  return aspectRatio;
}

/// PiP 窗口上的动作键（用户点了哪一个）。wire 名即枚举名，是跨语言契约。
enum PictureInPictureAction {
  /// 播放 / 暂停。
  playPause,
}

/// PiP 窗口上那组动作键此刻该长什么样（目前只有一个播放 / 暂停键）。
@immutable
class PictureInPictureControls {
  const PictureInPictureControls({
    required this.playing,
    required this.playPauseLabel,
  });

  /// 当前是否在播放：决定按钮画「暂停」还是「播放」图标。
  final bool playing;

  /// 按钮的标题 / 无障碍描述（已本地化；原生侧不另存一份文案）。
  final String playPauseLabel;

  @override
  bool operator ==(Object other) =>
      other is PictureInPictureControls &&
      other.playing == playing &&
      other.playPauseLabel == playPauseLabel;

  @override
  int get hashCode => Object.hash(playing, playPauseLabel);
}

/// Android 系统画中画的唯一 Dart 门面。
abstract final class AndroidPictureInPicture {
  static const String _methodIsSupported = 'isSupported';
  static const String _methodEnter = 'enter';
  static const String _methodUpdate = 'update';
  static const String _methodIsActive = 'isActive';
  static const String _methodOnChanged = 'onChanged';
  static const String _methodOnAction = 'onAction';
  static const String _argAspectRatio = 'aspectRatio';
  static const String _argPlaying = 'playing';
  static const String _argPlayPauseLabel = 'playPauseLabel';

  static final StreamController<bool> _modeChanges =
      StreamController<bool>.broadcast();

  static final StreamController<PictureInPictureAction> _actions =
      StreamController<PictureInPictureAction>.broadcast();

  /// 上一次送进原生的参数（[enter] / [update] 共用），供 [update] 去重：
  /// 播放器每个进度 tick 都会通知一次，而 `setPictureInPictureParams` 是一次
  /// binder 往返，不能跟着 tick 发。退出 PiP 时清空——下一次进来一定重新送。
  static double? _sentAspectRatio;
  static PictureInPictureControls? _sentControls;

  /// 能力探测结果缓存：这个答案在一次进程生命周期里不会变（版本门 + 系统特性
  /// 都是安装期就定死的），没必要每次开视频都过一次通道。
  static bool? _supported;

  /// 是否已挂上原生回程的接收 handler。
  static bool _listening = false;

  /// 进程内的「当前在不在 PiP 里」。由原生回程 `onChanged` 与 [enter] 的成功
  /// 结果共同驱动；[refreshActive] 可向原生要一次真值兜底。
  static bool _active = false;

  static MethodChannel get _channel => FushiChannels.pictureInPicture;

  /// 本机是否支持（非 Android 恒 false；Android 上问原生）。结果缓存。
  static Future<bool> isSupported() async {
    final bool? cached = _supported;
    if (cached != null) {
      return cached;
    }
    if (defaultTargetPlatform != TargetPlatform.android) {
      // 其余四端没有这条通道的原生侧。直接定论，不发调用。
      return _supported = false;
    }
    _ensureListening();
    bool supported = false;
    try {
      supported =
          await _channel.invokeMethod<bool>(_methodIsSupported) ?? false;
    } on MissingPluginException {
      // 原生侧没注册（旧版本 app / 非 MainActivity 引擎入口，如弹窗词典）。
      // 「没有」是事实，不是错误。
      supported = false;
    } on PlatformException {
      supported = false;
    }
    return _supported = supported;
  }

  /// 请求进入 PiP。[aspectRatio] `<= 0`（或非有限值）时用 16:9。
  ///
  /// [controls] 非空时小窗上带播放 / 暂停键（见库注释第 4 条）；不传则只有系统的
  /// 「展开 / 关闭」。
  ///
  /// 返回是否**真的**进去了：原生侧任何异常都被吞成 false，调用方据此决定是否
  /// 保持原状 / 提示用户，而不是假定一定成功。
  static Future<bool> enter({
    required double aspectRatio,
    PictureInPictureControls? controls,
  }) async {
    if (!await isSupported()) {
      // 不支持就别发 enter：省一次无意义的通道往返，也避免在非 Android 上
      // 撞 MissingPluginException。
      return false;
    }
    final double clamped = clampPictureInPictureAspectRatio(aspectRatio);
    bool entered = false;
    try {
      entered =
          await _channel.invokeMethod<bool>(_methodEnter, <String, Object?>{
            _argAspectRatio: clamped,
            if (controls != null) ..._controlsArguments(controls),
          }) ??
          false;
    } on MissingPluginException {
      entered = false;
    } on PlatformException {
      entered = false;
    }
    if (entered) {
      if (!_active) {
        // 原生的 onChanged 通常随后就到，但两者之间有一帧的窗口；先本地置位，
        // 免得调用方在这段窗口里读到过期的 false。重复事件由 _emit 去抖。
        _emit(true);
      }
      _sentAspectRatio = clamped;
      _sentControls = controls;
    }
    return entered;
  }

  /// 已在 PiP 里时刷新小窗参数：播放态变了换按钮图标，换集 / 换源后画面比例变了
  /// 换窗口比例。
  ///
  /// [aspectRatio] 传 null 表示「比例还不知道」（新一集的画面尺寸尚未解析出来）：
  /// 此时只刷按钮、窗口比例保持原样——宁可沿用上一集的比例一小会儿，也不先跳到
  /// 16:9 再跳到真实比例。
  ///
  /// [controls] 传 null 表示「此刻没有可操作的播放器」：把窗口上的动作键撤掉，
  /// 只留系统的「展开 / 关闭」。
  ///
  /// 与上一次送出的内容相同则不发调用。不在 PiP 里也不发：进入时 [enter] 会带上
  /// 当时的全部参数。返回是否真的送了一次。
  static Future<bool> update({
    required double? aspectRatio,
    required PictureInPictureControls? controls,
  }) async {
    if (!_active) return false;
    final double? clamped = aspectRatio == null
        ? _sentAspectRatio
        : clampPictureInPictureAspectRatio(aspectRatio);
    if (clamped == _sentAspectRatio && controls == _sentControls) return false;
    // 先记账再发：调用方是播放器的变更监听，await 期间下一个 tick 就会再进来，
    // 记在后面会把同一份参数重复发出去。
    _sentAspectRatio = clamped;
    _sentControls = controls;
    try {
      await _channel.invokeMethod<void>(_methodUpdate, <String, Object?>{
        _argAspectRatio: clamped,
        if (controls != null) ..._controlsArguments(controls),
      });
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
    return true;
  }

  static Map<String, Object?> _controlsArguments(
    PictureInPictureControls controls,
  ) => <String, Object?>{
    _argPlaying: controls.playing,
    _argPlayPauseLabel: controls.playPauseLabel,
  };

  /// PiP 模式变化流（true = 进入，false = 退出）。多订阅者安全（broadcast）。
  static Stream<bool> get modeChanges {
    _ensureListening();
    return _modeChanges.stream;
  }

  /// 用户在 PiP 窗口上点了动作键（见库注释第 4 条）。多订阅者安全（broadcast）。
  static Stream<PictureInPictureAction> get actions {
    _ensureListening();
    return _actions.stream;
  }

  /// 当前是否在 PiP 中（进程内缓存；要向原生要真值用 [refreshActive]）。
  ///
  /// 同步 getter 是刻意的：调用点在 build / 手势回调这类不能 await 的地方。
  static bool get isActive => _active;

  /// 向原生问一次真值并更新缓存（原生兜底）。
  ///
  /// 缓存唯一可能失真的场景是「原生回程在引擎重建之类的边界上丢了一条」；
  /// 恢复前台之类的时机调一次即可对齐。
  static Future<bool> refreshActive() async {
    if (!await isSupported()) {
      if (_active) _emit(false);
      return false;
    }
    bool active = _active;
    try {
      active = await _channel.invokeMethod<bool>(_methodIsActive) ?? false;
    } on MissingPluginException {
      active = false;
    } on PlatformException {
      // 问不到就保持缓存：把它当成 false 会凭空发一条「退出 PiP」事件。
      return _active;
    }
    if (active != _active) {
      _emit(active);
    }
    return active;
  }

  /// 挂上原生 → Dart 的回程接收 handler（幂等）。
  static void _ensureListening() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      final Object? arguments = call.arguments;
      switch (call.method) {
        case _methodOnChanged:
          debugHandleModeChanged(arguments is bool && arguments);
        case _methodOnAction:
          if (arguments is String) debugHandleAction(arguments);
      }
      return null;
    });
  }

  static void _emit(bool active) {
    if (_active == active) return;
    _active = active;
    if (!active) {
      _sentAspectRatio = null;
      _sentControls = null;
    }
    if (!_modeChanges.isClosed) {
      _modeChanges.add(active);
    }
  }

  /// 测试入口：模拟原生回程。生产路径也复用它，保证测的是同一条路。
  @visibleForTesting
  static void debugHandleModeChanged(bool active) => _emit(active);

  /// 测试入口：模拟原生的动作键回程（[wireName] 是 [PictureInPictureAction] 的
  /// 枚举名）。生产路径也复用它。不认识的名字丢弃——新版原生配旧版 Dart 时多出来
  /// 的键不该被当成别的键执行。
  @visibleForTesting
  static void debugHandleAction(String wireName) {
    final PictureInPictureAction? action = PictureInPictureAction.values
        .asNameMap()[wireName];
    if (action == null || _actions.isClosed) return;
    _actions.add(action);
  }

  /// 测试入口：清掉能力缓存与 PiP 状态缓存。
  ///
  /// 不关 [modeChanges] / [actions] 的 controller——它们是 broadcast 且静态的，关掉之后同一
  /// 进程里的后续用例就再也发不出事件了。
  @visibleForTesting
  static void resetForTesting() {
    _supported = null;
    _active = false;
    _sentAspectRatio = null;
    _sentControls = null;
    _listening = false;
    _channel.setMethodCallHandler(null);
  }
}

/// 把播放器的状态持续同步进 PiP 窗口的参数，并把窗口上的播放 / 暂停键接回播放器。
///
/// 不画任何东西（零尺寸），只借 widget 的生命周期管两条订阅：挂在视频页的 controls
/// 子树里，换集 / 退页时随子树自动解绑，不需要页面再记一份「订了没、退了没」。
///
/// **PiP 窗口上有没有动作键，与「有没有同步器挂着」严格同步**：键一旦交给系统就
/// 留在窗口上，而能接住点击的只有挂着的同步器。所以进入时交什么由
/// [currentControls] 决定（没有同步器就不交），PiP 里最后一份同步器卸载时把键撤掉
/// （[AndroidPictureInPicture.update] 的 `controls: null`），再挂上来时补回去。
/// controls 子树不存在的那些状态——换集后新一集还在加载、加载失败、蓝光原盘菜单
/// 阶段——窗口上因此不会留一枚点了没反应、图标也不再更新的键。
///
/// 不在 PiP 里时它只是播放器上的一个监听，[AndroidPictureInPicture.update] 第一行
/// 就早退，不发通道调用。
///
/// 同一个播放器可能同时被两棵 controls 子树引用（页面本身 + 全屏路由复用同一个
/// controls builder），两份都响应的话一次点击会被执行两遍（暂停完立刻又播）。所以
/// 进程内只认**最后挂载的那一份**：其余的既不推参数、也不响应动作键；它卸载后由
/// 前一份接手。
class AndroidPictureInPicturePlaybackSync extends StatefulWidget {
  const AndroidPictureInPicturePlaybackSync({
    required this.playback,
    required this.isPlaying,
    required this.aspectRatio,
    required this.playPauseLabel,
    required this.onPlayPause,
    super.key,
  });

  /// 播放态 / 画面尺寸变化时通知的对象（播放器 controller）。
  final Listenable playback;

  /// 当前是否在播放。
  final bool Function() isPlaying;

  /// 当前画面宽高比；尺寸还没解析出来时返回 null（窗口比例保持原样，见
  /// [AndroidPictureInPicture.update]）。
  final double? Function() aspectRatio;

  /// 播放 / 暂停键的标题（已本地化）。
  final String playPauseLabel;

  /// 用户在 PiP 窗口上点了播放 / 暂停。
  final VoidCallback onPlayPause;

  /// 此刻该交给 PiP 窗口的动作键：有同步器挂着就是它读到的当前播放态，没有则为
  /// null（不交键）。给 [AndroidPictureInPicture.enter] 的调用方用。
  static PictureInPictureControls? currentControls() {
    final List<_AndroidPictureInPicturePlaybackSyncState> mounted =
        _AndroidPictureInPicturePlaybackSyncState._mounted;
    return mounted.isEmpty ? null : mounted.last._controls;
  }

  @override
  State<AndroidPictureInPicturePlaybackSync> createState() =>
      _AndroidPictureInPicturePlaybackSyncState();
}

class _AndroidPictureInPicturePlaybackSyncState
    extends State<AndroidPictureInPicturePlaybackSync> {
  /// 当前挂载着的全部实例，按挂载先后排；只有末尾那一份生效。
  static final List<_AndroidPictureInPicturePlaybackSyncState> _mounted =
      <_AndroidPictureInPicturePlaybackSyncState>[];

  StreamSubscription<PictureInPictureAction>? _actionSub;

  bool get _isCurrent => _mounted.isNotEmpty && identical(_mounted.last, this);

  PictureInPictureControls get _controls => PictureInPictureControls(
    playing: widget.isPlaying(),
    playPauseLabel: widget.playPauseLabel,
  );

  @override
  void initState() {
    super.initState();
    _mounted.add(this);
    widget.playback.addListener(_push);
    _actionSub = AndroidPictureInPicture.actions.listen(_handleAction);
    // 挂载即推一次：本地换集是 pushReplacement 的新页，PiP 窗口上还是上一集留下的
    // 按钮图标与比例。
    _push();
  }

  @override
  void didUpdateWidget(AndroidPictureInPicturePlaybackSync oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.playback, widget.playback)) {
      oldWidget.playback.removeListener(_push);
      widget.playback.addListener(_push);
    }
    _push();
  }

  @override
  void dispose() {
    widget.playback.removeListener(_push);
    unawaited(_actionSub?.cancel());
    _actionSub = null;
    _mounted.remove(this);
    if (_mounted.isNotEmpty) {
      // 接手的那一份立刻对齐一次（它在让位期间没推过参数）。
      _mounted.last._push();
    } else {
      // 没有接手的了：再没有谁能接住窗口上那枚键的点击，把它撤掉（不在 PiP 里时
      // update 自己早退）。比例传 null = 窗口保持原样。
      unawaited(
        AndroidPictureInPicture.update(aspectRatio: null, controls: null),
      );
    }
    super.dispose();
  }

  void _push() {
    // 不在 PiP 里：播放器每个进度 tick 都会进来，别为一次注定早退的 update 去读
    // 播放态、拼参数。
    if (!_isCurrent || !AndroidPictureInPicture.isActive) return;
    unawaited(
      AndroidPictureInPicture.update(
        aspectRatio: widget.aspectRatio(),
        controls: _controls,
      ),
    );
  }

  void _handleAction(PictureInPictureAction action) {
    if (!_isCurrent) return;
    switch (action) {
      case PictureInPictureAction.playPause:
        widget.onPlayPause();
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
