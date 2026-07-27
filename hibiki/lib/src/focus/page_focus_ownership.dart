import 'package:flutter/widgets.dart';

/// 触发「把键盘焦点收回本页正文」的原因。
///
/// 每个回收点必须自证意图：页面的判据谓词按 [FocusReclaimCause] 分流，
/// 而不是靠若干个名字相近的私有方法（`_refocusX` / `_reclaimXIfOwned` /
/// `_settleFocusOnY` / `_reclaimXForTouchPopup`）各自硬编码一套门控——那正是
/// 视频页 29 处、阅读器页 28 处焦点补丁互相漂移、漏一处就丢键的根源。
enum FocusReclaimCause {
  /// 正文内容就绪（WebView 首帧 / 播放器 load 完成 / 恢复定位落地）。
  ///
  /// 整页 `autofocus: true` 会抢在内容就绪之前把焦点落到表面层，故每个
  /// 「内容就绪」落点都要确定性补一次。
  contentReady,

  /// 原生 surface（WebView / 视频画面）上的指针手势之后。
  ///
  /// 原生控件在任一指针手势上捕获 OS 焦点，静默丢掉 Flutter 的 [FocusNode]；
  /// 不回收则此后所有按键都不再抵达页面的 key handler。
  gesture,

  /// 正文 surface 换了宿主重新挂载（进 / 退全屏这类整路由切换）。
  ///
  /// 焦点节点被两棵子树先后 attach，交接期间它可能短暂不在焦点树上，故这类
  /// 回收必须走 [PageFocusOwnership.reclaimAfterFrame]，等新宿主 build 完成、
  /// 节点重新 reparent 之后再请求。
  surfaceRemounted,

  /// 压在本页之上的覆盖层关闭之后（对话框 / bottom sheet / 菜单 /
  /// 系统文件选择器 / 侧栏 / popover）。
  ///
  /// 这类回收应优先用 [PageFocusOwnership.guardOverlay] 包裹覆盖层的 `await`
  /// 点，而不是在每个返回点手写——手写必然漏（如视频页字幕波形对轴弹窗）。
  overlayClosed,

  /// 本页自身的常驻 chrome（底栏 / 工具条）显隐翻转之后。
  ///
  /// 与 [overlayClosed] 区分：chrome **不是**压在本页之上的覆盖层，它整体被
  /// `ExcludeFocus` 排出焦点遍历池、任何时刻都不是合法的焦点所有者。故它显隐时
  /// 「正文该不该持焦」不受「覆盖层可能正当地持着焦点」那套严格门控约束——这里
  /// 只是**重新确认**焦点仍在正文（正文已持焦时是纯 no-op），漏掉就会出现「切了
  /// 一下底栏之后翻页键失灵」。
  chromeToggled,

  /// 查词浮层栈**全部**关闭之后。
  popupDismissed,

  /// 查词浮层**渲染完成**之后（触屏路径）。
  ///
  /// 与 [popupDismissed] 相反：浮层是纯原生 WebView、没有 Flutter 焦点节点，
  /// 指针唤出它时 OS 焦点落在浮层上，若不把 Flutter 焦点拉回正文，关词典键
  /// （Esc / 绑定键）就永远抵达不了页面的 key handler。故此 cause 下页面判据
  /// 通常**刻意不排除**「浮层可见」。
  popupRendered,

  /// app 回到前台（`AppLifecycleState.resumed`）。
  ///
  /// OS 层焦点丢失后 Flutter 不保证归还到原节点；这是全局生命周期回调，页面
  /// 判据必须额外确认自己是当前路由，否则会夺走压在上面的对话框的焦点。
  appResumed,
}

/// 页面键盘焦点的**单一所有者**模型。
///
/// 取代散落在各媒体页里的私有 `requestFocus` 补丁：所有回收走同一入口
/// [reclaim]，页面只需提供一个按 [FocusReclaimCause] 分流的判据谓词。
///
/// 为什么判据留给页面、类本身很薄：各页的「我此刻该不该持焦」天然不同
/// （视频看播放器是否就绪、阅读器看内容就绪/光标态/歌词态、漫画看是否在
/// webtoon 原生滚动模式），把它们塞进本类只会变成一堆互斥 flag。本类负责的是
/// **结构**——单一入口、覆盖层自动归还、跨帧时序，以及让守卫测试能够禁止
/// 页面绕过它裸调 `requestFocus`。
class PageFocusOwnership {
  PageFocusOwnership({
    required this.node,
    required bool Function(FocusReclaimCause cause) canOwn,
  }) : _canOwn = canOwn;

  /// 本页正文的键盘焦点节点（唯一持有者）。
  final FocusNode node;

  final bool Function(FocusReclaimCause cause) _canOwn;

  /// 按 [cause] 判据把焦点收回 [node]。
  ///
  /// 返回是否真的发起了请求——供测试断言，也让调用点能在被判据否决时走别的
  /// 路径（正常业务代码通常忽略返回值）。
  bool reclaim(FocusReclaimCause cause) {
    if (!_canOwn(cause)) return false;
    node.requestFocus();
    return true;
  }

  /// 在下一帧结束后回收。
  ///
  /// 用于「回收动作本身依赖尚未完成的 build/reparent」的时序：例如进出全屏
  /// 时同步 requestFocus 会跑在路由 build 之前，reparent 会把 primary focus
  /// 让给新路由的 ModalScope，导致进全屏后快捷键直接死掉。
  ///
  /// [addPostFrameCallback] **本身不调度帧**：树静止（阅读器停在一页上、视频
  /// 暂停）时没有别的东西请求下一帧，回调就一直挂着、焦点永远回不来。故这里
  /// 显式 [ensureVisualUpdate] 把帧要出来。
  void reclaimAfterFrame(FocusReclaimCause cause) {
    WidgetsBinding.instance.addPostFrameCallback((_) => reclaim(cause));
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 包裹一个会夺走焦点的覆盖层，在它**任何**退出路径上归还焦点。
  ///
  /// 覆盖 `await showDialog(...)` / `FilePicker.platform.pickFiles()` /
  /// `showMenu(...)` 等：正常返回、抛异常、被 pop 掉都会经 `finally` 归还，
  /// 消除「某个返回点忘了写归还」这一类必然发生的遗漏。
  Future<T> guardOverlay<T>(Future<T> Function() body) async {
    try {
      return await body();
    } finally {
      reclaim(FocusReclaimCause.overlayClosed);
    }
  }
}
