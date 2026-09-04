## BUG-2124 · 视频墙格滚动时放大态残留在已滚走的卡上
- **报告**：2026-09-04（用户：「滚动的时候，会有另一个地方的卡片呈现被鼠标选中的样式，是因为界面大小吗」。追问确认：视频「系列 / 全部视频」墙格、鼠标滚轮、症状是**卡片变大**）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/components/fushi_hover_lift.dart:71-84`（修复前）：抬升的复位走 `AnimatedScale` 的 `kFushiHoverLiftDuration = 120ms` 缓动，而 Flutter 的鼠标命中判定在帧末 `MouseTracker.updateAllDevices` 才重算——滚轮让卡片位移后，`onExit` 到达时卡片已经移开，接着还要花 8 帧把它从 1.05 缓降回 1.0。**这 8 帧画在卡片的新位置上**，指针早已不在其上。逐帧实测（`VideoLibrarySection.allVideos`，指针固定 `Offset(159.3, 550.1)`，滚一档 120px）：

  | 帧 | 那张卡 | 缩放 | 偏离指针 |
  |---|---|---|---|
  | 1–2 | y=315..546 | 1.050 | 120px |
  | 3–8 | y=315..546 | 1.039 → 1.003 | 120px |
  | 9 | — | 复位 | — |

  同一段里指针**底下**的新卡要到第 17 帧才涨到 1.05（档 2 数据），即滚动全程没有一张放大的卡跟指针对齐；连续拨滚轮就是一串错位高亮接连亮起，正是用户描述的「另一个地方的卡片被选中」。
  用户猜的「界面大小」已被实测否定：`FushiAppUiScale` 取 1.0 / 1.3 / 0.7 三档症状完全一致（缩放走 `FittedBox` 真实变换，命中随之变换，真错位的话静止悬停就已经偏了）。焦点环也已排除——焦点态是 2.5px `primary` 描边、不放大（`fushi_focus_ring.dart:323-334`），与用户所述「变大」不符。
- **[x] ① 已修复** — 把不变式补成「抬升 = 指针悬停 **且** 不在滚动中」：`_FushiHoverLiftState` 经 `ScrollNotificationObserver`（`Scaffold` 提供，能收到**所有**祖先滚动区的通知，横滚行卡在纵向页里滚动同样覆盖）订阅滚动生命周期，滚动起步即以 `Duration.zero` 落回 1.0。残留 8 帧 → **2 帧**（约 32ms 满值，低于人眼可辨阈值）。三条纪律：
  - `_scrolling` 与 `_hovering` 必须是两个正交的位，**不能**顺手清 `_hovering`：`MouseRegion` 只在命中集真变化时发事件，指针不动的话滚动停止后不会补 `onEnter`，清了就再也涨不回来（已实测踩过：既有 BUG-2002 用例全红）。
  - 起点只认 `ScrollStartNotification`，**不能**把 `ScrollUpdateNotification` 也当起点：`jumpTo` / 恢复滚动位置这类一次性位移会单发 update 而无配对 end，`_scrolling` 会永久卡 true、连初次悬停都不再抬升（同样实测踩过）。
  - `_setScrolling` 只在 `_hovering` 为真时 `setState`，一次滚动不会把整墙刷一遍。
  - 剩下的 2 帧是当前实现的物理下限：`AnimatedScale` 是隐式动画，置位那帧只改得动目标值、渲染值下一帧才跟上（时长设 0 也一样），controller 走完零时长再通知 listener 又占一帧。压到 0 帧需把 `AnimatedScale` 换成手写 `AnimationController`（置位时同帧 `value = 0`），代价是 BUG-2002 的既有守卫按 `AnimatedScale` 类型断言、要一起改——按实用主义未做，判据里写明了这个下限的来源。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_video_wall_hover_scroll_test.dart`：真 widget 行为测试（pump `HomeVideoPage` + `TestPointer` 悬停 + `pointer.scroll` 滚轮），滚 4 档 × 每档 14 帧逐帧断言「屏幕上放大的卡必须包含指针」，覆盖 allVideos / series 两条墙格实现与界面缩放 1.3，另一条反向门断言滚动停下后指针仍在卡上时抬升要回来（防止把 hover 真值一起吃掉）。
  **判据必须读渲染矩阵**（`AnimatedScale` 内层 `Transform.transform.getMaxScaleOnAxis()`）而不是 `AnimatedScale.scale`：后者是动画**目标值**，1 帧就归位，先写的目标值版用例全绿——正是它把这 8 帧藏住了，属空壳断言。
- **备注**：同壳的书架 / 漫画 / 游戏库卡（`reader_history/card_widgets.part.dart:295`、`galgame_poster_card.dart:77`）与视频页其余三条路径共用 `FushiHoverLift`，一并受益。合集详情页成员卡 `_HoverableMemberCard`（`media_collection_grid_detail_page.dart:405-450`）是另一套自写 `MouseRegion` 高亮罩、未接本壳，同类拖尾未覆盖，属独立缺口，本条不扩大范围。
