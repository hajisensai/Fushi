# 阅读器 chrome 重做（2026-09-13）

用户 2026-09-13 拍板六条，分三个 PR 落地。本文是实现计划 + 决策记录。

## 用户诉求（已确认）

1. 悬浮控制栏开启后顶部仍有 48px 空带（BUG-2387 留下的恒定预留）→ **悬浮态顶栏隐藏时正文满屏、唤出时盖在正文上**。
2. 底栏「也有问题」→ 与顶栏同一套悬浮模型（半透明覆盖、同一显隐状态机）。
3. 控制栏「没有自动恢复」→ 和视频页一样：**鼠标在正文任意位置移动即唤出**，静止 N 秒收起。
4. 有声书面板：桌面居中对话框 → **右侧侧栏**（与设置侧栏同容器）。
5. 统计面板：居中对话框 → **右侧侧栏**，内容按样稿重做（大号计时 + 暂停、本次字数/字时、阅读位置本章/全书进度条、今天含查词/制卡、本书累计、预计读完、打开完整记录）。
6. 底栏统计精简为「百分比 + 本次计时」+ 一条进度条；其余数字进统计侧栏。
7. 插图册：舞台形态像 ttu，**换成按章节分组的网格** + 「已解锁 N/M | 已解锁 | 全部」+ 锁定占位卡（读到第 X 章后自动解锁 / 仍要查看）。
8. 阅读器顶栏/底栏按钮支持与视频页同款**可视化布局编辑**。

## PR A — 阅读器 chrome（1–6）

### 数据结构
- `readerDesktopHeaderReserve` 恢复 `floating` 参数：悬浮 → 0。BUG-2387 的「不盖字」契约改为**只对挤压态成立**；悬浮态唤出即覆盖，是用户明确选择的悬浮语义。
- `bottomBarVisible` / `readerVnBlankTapAction`：悬浮态**不再读** `chromeExpanded`（`_showChrome` 在悬浮态是不可见旗，读它就是 BUG「切开关后残留 false 永远唤不出」的根因）。
- 状态行：悬浮态预留归 0、随 chrome 显隐（`readerStatusFooterReserve` 加 `floating`）；文案精简 `readerProgressLabel` → `xx.x%`、`readerTrackerLabel` → `m:ss`；新增细进度条常驻屏底（2px，`ReaderProgressEdgeLine`）。
- 顶栏/底栏/状态行悬浮态背景改半透明（`readerFloatingChromeColor(bg)`，alpha 0.9），不加 BackdropFilter（每帧光栅代价，见 BUG-969）。

### 唤出通道
- 页面根 `Listener.onPointerHover`（Flutter 腿，`hostOwnsWebViewPointerInput` 为真的 Windows）+ JS `mousemove` 节流回传 `onPointerHoverReveal`（JS 腿，其它平台）。互斥门与 `_handleReaderPointerDown` 同一条。
- 纯函数 `readerHoverRevealAction({floating, transientVisible})`：隐藏→reveal+arm；可见→re-arm。
- 删 6px 顶边热区 `_buildHoverRevealLayer`（被全域悬停取代）。
- 有声书 / 统计侧栏打开期间取消自动收起（沿用 `_presentQuickSettings` 侧栏分支）。

### 侧栏
- `readerAudiobookUsesDialog` → `readerAudiobookUsesSideSheet`（桌面/宽窗侧栏，手机 bottom sheet）。`ReaderAudiobookPanel` 去掉底部「关闭」大按钮。
- `ReaderStatisticsDialog` → `ReaderStatisticsSheet`（新文件 `reader_statistics_sheet.dart`），`ReaderBookStatTotals` 加 `todayLookups` / `todayCards`（`loadStatFacts(includeCounters: true)` 按 bookKey+今日切）。**打开统计侧栏不再停表**（侧栏不遮正文；样稿要求实时秒表 + 暂停键）——BUG-2208 的停表只对遮正文的弹层成立。

### 测试
- 改：`reader_desktop_chrome_test`（reserve 契约）、`reader_chrome_floating_test`、`reader_status_footer_test`（文案）、`reader_statistics_dialog_test` → sheet、`reader_quick_settings_sheet_static_test`。
- 新：hover reveal 纯函数 + 状态机测试；进度线 widget 测试。
- itest `reader_header_overlap_bug2381_itest`：断言改为「挤压态不重叠；悬浮态收起时 `--chrome-top-inset == sysTop`」。

## PR B — 插图册重做（7）
- `ReaderGalleryPage` 改为：顶栏「插图册 | 已解锁 n/N | [已解锁][全部] | 定位 | ×」；主体 `CustomScrollView`，按章节 `SliverList` 分节（章名 + 当前阅读位置标记），每节 `SliverGrid` 卡片；未解锁卡显示占位（`IllustrationProgressIndex` 同判据）；点已解锁卡进全屏查看器（左右切换、滚轮、键盘）。
- 「回到最近已看」= 跳到最后一张已解锁图；「仍要查看」= 单张揭开（写 `revealedImageKeys`）。

## PR C — 阅读器按钮可视化布局（8）
- 抽 `ControlLayout<S, I>` 泛型（槽 map + removed 集 + move/add/remove + encode/decode 骨架），`VideoControlLayout` 变薄包装，JSON v3 逐字节不变（现有 `video_control_layout_test` 钉住）。
- `ReaderControlSlot{topLeft,topCenter,topRight,bottomLeft,bottomCenter,bottomRight,hidden}` + `ReaderControlItem{back,modeToggle,navigation,gallery,statistics,audiobook,fullscreen,settings,audioImport,title}`。
- `_buildDesktopHeader` / `_buildSettingsBar` 按 `layout.itemsIn(slot)` 生成；偏好键 `reader_control_layout`。
- `ControlLayoutEditor` 泛型化编辑器，设置页阅读分区加 `SettingsCustomItem` + 重置。

## 风险
- A 推翻 BUG-2387 itest 契约（有意）；A 改 `_showChrome` 悬浮态语义，VN 测试要跟。
- C 动视频页模型，`test/media/video` 整目录必绿。
