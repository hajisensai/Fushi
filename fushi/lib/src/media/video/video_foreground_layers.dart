/// 视频页「逐级退出」的层级判据（BUG-1862）。
///
/// 视频页同时可能开着好几层前台 chrome：词典浮层、控制布局编辑态、控制按钮 popover、
/// 字幕跳转列表、剧集列表、设置 / 速度 / 章节侧栏、沉浸锁。按「返回上一级」（默认 Esc /
/// 手柄 B / Android 系统返回键）时必须**从最前台往后台一层一层关**，全关完了才轮到退
/// 全屏、退出视频页。
///
/// 判据独立成纯函数的动机：这条顺序此前被抄成两份——Escape 快捷键回调里一份、
/// [PopScope] 的退出汇聚点里一份（而且后者只写了词典浮层一层），两份必然漂。漂的
/// 后果就是 BUG-1862：设置侧栏打开时焦点被 `PanelFocusScope` 领进侧栏，Esc 绕过
/// media_kit controls 子树里的快捷键表冒泡到全局 back，落进只认词典浮层的那份，
/// 于是整页被 pop 掉、侧栏还开着。顺序收进本文件后，页面只剩「读状态 → 查表 →
/// 执行动作」，规则本身可以直接断言。
library;

/// 视频页可被「返回上一级」逐级关闭的前台层，**声明顺序即视觉层序**（越靠前越前台，
/// 越先被关）。
enum VideoForegroundLayer {
  /// 词典查词浮层。挂在根 Overlay 上，全屏路由之上，永远是最前台的一层。
  dictionaryPopup,

  /// 控制按钮布局编辑态（拖拽摆放播放器按钮）。
  controlEdit,

  /// 控制按钮 popover（音量 / 倍速等轻浮层）。点击打开的那次会被 pin 住
  /// （`_controlPopoverPinned`）常驻，只能由再点一次 / 开别的浮层 / 本层关掉。
  ///
  /// 排位依据：在 controls Stack 里它画在 side panel 之上、布局编辑态之下
  /// （`layout.part.dart` 的 `_buildVideoSidePanelOverlay` →
  /// `_buildVideoControlPopoverOverlay` → 编辑态三兄弟）。与 push-aside 字幕列表 /
  /// 剧集轨几何上不重叠（BUG-792 起二者刻意共存、互不关闭），没有真 z 关系，按
  /// 「最后打开的最先关」把它排在两条 push-aside 列表之前。
  controlPopover,

  /// push-aside 字幕跳转列表（TODO-314）。
  subtitleList,

  /// push-aside 剧集列表（TODO-638）。
  episodeList,

  /// 设置 / 速度 / 章节 / 画质 / 弹幕匹配侧栏（同一个 side panel 槽位，互斥）。
  sidePanel,

  /// 沉浸 / 锁定模式（TODO-101）。是最外层沉浸态，故排在所有面板之后。
  immersiveLock,
}

/// 当前最前台的可关层；一层都没开返回 `null`（调用方这才可以退全屏 / 退出视频页）。
///
/// [hasVisibleDictionaryPopup] 必须是「有 **VISIBLE** 浮层」而不是「浮层栈非空」：
/// 常驻隐藏的热槽（BUG-094）让栈长期非空，拿栈长度当判据会永久吞掉退出。
VideoForegroundLayer? topVideoForegroundLayer({
  required bool hasVisibleDictionaryPopup,
  required bool controlEditActive,
  required bool controlPopoverOpen,
  required bool subtitleListVisible,
  required bool episodeListVisible,
  required bool sidePanelOpen,
  required bool immersiveLocked,
}) {
  if (hasVisibleDictionaryPopup) return VideoForegroundLayer.dictionaryPopup;
  if (controlEditActive) return VideoForegroundLayer.controlEdit;
  if (controlPopoverOpen) return VideoForegroundLayer.controlPopover;
  if (subtitleListVisible) return VideoForegroundLayer.subtitleList;
  if (episodeListVisible) return VideoForegroundLayer.episodeList;
  if (sidePanelOpen) return VideoForegroundLayer.sidePanel;
  if (immersiveLocked) return VideoForegroundLayer.immersiveLock;
  return null;
}
