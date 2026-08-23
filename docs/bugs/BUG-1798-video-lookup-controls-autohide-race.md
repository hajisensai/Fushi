## BUG-1798 · 查词浮层与控制条自动显隐竞态
- **报告**：2026-08-23（用户：在播放控件隐藏的前后几百毫秒内点击查词界面，就可以让查词界面卡住）
- **真实性**：✅ 真 bug（桌面路径）。沿真实代码路径查实四条独立缺陷，全部集中在「查词浮层不被视为 overlay」这一个建模疏漏上。根因见下。

### 根因（真实代码路径取证）

视频页的查词浮层**不走** `lib/src/lookup/`（那是 Windows 原生 app-外覆盖窗），而是 `DictionaryPageMixin` + **根 Overlay**：`video_fushi_page.dart` 的 `_syncPopupOverlay()` 把 `OverlayEntry(builder: _buildPopupOverlay)` 插进 `Overlay.maybeOf(context, rootOverlay: true)`（用根 Overlay 是因为 media_kit 全屏是推到根 navigator 的独立路由，本页 Stack 会被盖住）。

浮层的 dismiss barrier 是 `Positioned.fill` + `ColoredBox(Colors.transparent)`——`ColoredBox` 的 render object 是 `RenderProxyBoxWithHitTestBehavior(behavior: opaque)`，**命中测试上完全不透明**。判据 `shouldShowLookupDismissBarrier`（`dictionary_popup_layer.dart`）在**开始搜索时**就已为真，即弹窗还没出结果，barrier 就已接管全屏命中。

而 `_hasVideoOverlay`（`video_fushi_page.dart`）此前只列了 5 项（`_videoSidePanel` / `_videoControlPopover` / `_subtitleListVisible` / `_episodeListVisible` / `_videoControlEditMode`），**无一项与查词浮层相关**。由此派生出四条独立缺陷：

1. **Hibiki 侧光标被吃**：`controls_visibility.part.dart` 的 `_applyControlsVisibilityFromMediaKit()` 末尾 `_setCursorHidden(!visible && !_hasVideoOverlay)`。弹窗开着、控制条 2s 自动淡出 → `visible=false` 且 `_hasVideoOverlay=false` → `_buildCursorOverlay()`（`layout.part.dart`）铺一层 `MouseRegion(cursor: none)` 盖满视频区。查词浮层子树除右下角 resize 把手外**不声明任何 cursor**，解析必然下穿到这层 → 鼠标悬在弹窗上时 OS 光标直接消失。
2. **fork 侧光标被吃（独立第二层）**：`controls_theme.part.dart` 的 `hideMouseOnControlsRemoval` 只排除了两个 push-aside 侧栏，同样漏了查词浮层 → media_kit fork 的控制条 `MouseRegion` 在 `mount=false` 时取 `cursor:none` 分支。**与第 1 条是两层独立的 `none`，只修一层另一层照样把光标吃掉。**
3. **poke 续命哑火 + 合成事件污染指针记账**：`_pokeControlsVisible()`（`controls_visibility.part.dart`）的全部机理是「派一个合成 `PointerHoverEvent` 命中 media_kit 自己的 `MouseRegion` → 其 `onHover` 重置隐藏 Timer」。barrier 一挂，这条路径 **100% 断掉**（opaque 拦住），派发纯无效；但事件不会凭空消失，它改落进 barrier 的 `Listener(onPointerHover: _onDismissBarrierHover)`。而 `_onDismissBarrierHover` **没有任何合成设备过滤**（同页 `_handleVideoControlsHover` 早就用 `_isSyntheticControlsHover` 滤过，两者不对称纯属遗漏），于是：
   - `_lastGlobalPointerPos` 被写成**视频区几何中心**（`_videoControlsContext` 是 `Positioned.fill`，其 RenderBox 中心 ≈ 画面正中），BUG-880 的「静止光标 + 按 Shift 立即换词」随即在画面中心反查，用户光标下的词查不到；
   - 未按 Shift 的分支把 `_barrierHoverLastPos/_barrierHoverLastSentence/_barrierHoverLastGrapheme` 三个去重键清零 → 用户鼠标在**同一个字**上再抖一下就被判成新词，`_lookupAt(replaceStack: true)` **整栈替换**，正在看的弹窗内容被换掉、滚动位置丢失；
   - 按住 Shift / 开了「悬停即查词」时更直接：合成位置若命中字幕字符即刻换词。
   - 且 `_handleSubtitleHover` 自己就调 `_pokeControlsVisible()`，构成 hover→poke→hover 自激。
4. **第二个记账点同样漏过滤**：页面根 `Listener` 的 `onPointerHover` 也无条件写 `_lastGlobalPointerPos`，只滤 barrier 那一处仍会从这里漏进来。

「控件显隐前后几百毫秒」这个窗口的来源：合成设备一旦被 poke 过就永久留在 Flutter `MouseTracker._mouseStates`，`RendererBinding` 每帧按其最后位置（画面正中）重新 hit-test，故 barrier 每次插拔都必然给 media_kit 发一对 exit/enter，控制条随之被动显隐。

- **[x] ① 已修复** — 把「查词浮层占着指针」收敛成单一门控真值 `_lookupOverlayActive`（`ValueNotifier<bool>`，与 `_hasVideoOverlay` 其余五项同构，因为 `_applyControlsVisibilityFromMediaKit` 的输入必须全是可订阅 notifier，否则值变了没人重跑派生），由 `_syncPopupOverlay()`（浮层栈变化的唯一收口）单向写入，判据与 `shouldShowLookupDismissBarrier` 同源（有可见浮层或正在搜索）。四处消费：① 并入 `_hasVideoOverlay`；② 并入 `controls_theme.part.dart` 的 `hideMouseOnControlsRemoval`，并同步加进 `layout.part.dart` `_buildVideoControlsInner` 的 `ListenableBuilder.merge`（防哑火，r5 同款教训）；③ `_pokeControlsVisible()` 增加与其余四个门控同族的早退；④ `_onDismissBarrierHover` 与页面根 `Listener` 两个指针记账点都补上 `_isSyntheticControlsHover(event)` 早退。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_lookup_controls_autohide_guard_test.dart`（5 tests）。四条不变量各一条断言 + 一条剥注释前置自检。断言全部跑在 `maskComments()` 之后：修复的注释里大量出现 `_lookupOverlayActive` / `_isSyntheticControlsHover`，朴素子串匹配会被注释假阳性命中，「删掉真实代码只留注释」也能骗过守卫。**已做变异实测**：7 条变异（逐条删/改真实修复代码）全部被守卫抓红，全部按 sha256 精确还原，还原后复跑仍绿——守卫不是恒绿空壳。
- **备注**：本轮**未做真机复测**（用户报的是 Windows 桌面路径）。第 1/2 条（光标消失）与第 3/4 条（指针记账污染、换词被打断）的修复都有源码级守卫，但「鼠标悬在弹窗上光标是否真的回来了」属 OS 光标行为，只有 Windows 真机能证；若用户所说的「卡住」实为「点击弹窗无反应 + 鼠标一动刷蓝色选区」，那还有一条**独立**的下游嫌疑没排除：`packages/flutter_inappwebview_windows` 的 `VirtualKeyState` 粘滞位（见 BUG-1419），本轮未触碰。存量 4 个 `.dart` 文件**未跑整文件 `dart format`**：本机 dart 3.44 是 tall style，实测对 HEAD 原版（一行未改）跑 `--set-exit-if-changed` 同样报 `Changed`，整文件 format 会重排存量源码并毁掉源码扫描守卫；改动 hunk 按周边旧风格手写，`flutter analyze` 绿。
