# Bug 跟踪

> 约定（Claude/Codex 必须遵守）：用户报一个 bug → **先沿真实代码路径验真伪**（复现或定位根因）。
> - **是真 bug** → 追加一条到本文件（分配 `BUG-NNN`，记报告日期、根因 `file:line`），然后：
>   - **① 修复**这个 bug（根因修，不补丁），完成后勾 `[x] ①`，记提交哈希。
>   - **② 增加自动化测试**（在最强可落地层：真 widget 行为 / CSS 生成器 / 源码扫描守卫；纯视觉像素只能设备截图兜底并注明），完成后勾 `[x] ②`，记测试文件。
> - **不是真 bug / 无法复现** → 也记一条，标「未复现」并说明，不勾 ① ②。
> - reader/WebView/导入/播放/布局类修复：代码正确 + 单测无回归后，仍需**设备肉眼复测原始失败路径**（CLAUDE.md 验证纪律）；未做的在「备注」标注待补。
>
> 分层测试选型见 [docs/specs/2026-06-03-test-flow-refactor-*.md] 与各守卫测试范式
> （源码扫描：`test/pages/reader_paginate_lyrics_guard_static_test.dart` 的 `_functionSource`；
> CSS 生成器：`test/reader/reader_content_styles_test.dart`；widget 行为：`test/settings/`）。

---

## BUG-022 · 调大/调小界面大小后点不到底栏（及右侧）按钮——缩小时整片命中死区
- **报告**：2026-06-04（用户：「调整界面大小会点不到底栏的按钮」）。
- **真实性**：✅ **真 bug（OverflowBox 溢出区命中被丢弃）**。界面大小是浏览器式整体缩放 `HibikiAppUiScale`（`app_ui_scale.dart`，`Transform.scale` 全树缩放 + 反算 MediaQuery 几何）。旧实现：缩放系数 `s` 时 `canvas = view / s`，把 app 子树放进 `SizedBox(canvas)`，外套 `OverflowBox(min/max=canvas, align topLeft)`，再 `Transform.scale(s, topLeft)`（`app_ui_scale.dart:55-83`）。**缩小 (s<1) 时 `canvas > view`，`SizedBox(canvas)` 比 `OverflowBox`（自身 size = 入参约束 `view`）大、向右下溢出**。Flutter `RenderBox.hitTest` 有 `if (size.contains(position))` 短路：`OverflowBox` 自身 size 只有 `view`，缩放后落在 `view` 之外的那部分子树（屏幕底部/右侧）命中测试被整段丢弃 → 底栏「看得到点不到」。定量：屏幕 p∈[0,view]，逆变换后 p′=p/s∈[0,canvas]，仅 p′<view（即 p<s·view）可命中——s=0.5 只剩屏幕**左上 1/4** 可点、底栏全死；s=0.8 底部/右侧 ~20% 死。任何缩小都产生底部死区，越缩越大。**放大 (s>1)** 时 `canvas<view`、子树不溢出，命中正常，故只在缩小时复现。根因 = 用 OverflowBox 让子树「溢出自身」，与 hitTest 的 `size.contains` 短路天然冲突。
- **[x] ① 已修复** — `app_ui_scale.dart` 把 `Transform.scale + OverflowBox` 换成 `FittedBox(fit: BoxFit.fill, alignment: topLeft)` 包 `SizedBox(canvas)`。FittedBox 把子树**装进**自身：box size 恒为 `view`，子树缩放后恰好填满、**绝不溢出**，整个可见区都在 box 的 `size.contains` 内、全部可命中。`canvas = view/s` 各轴等比，`BoxFit.fill` 算出的变换就是均匀 `scale = s`，与原 `Transform.scale(s)` 数值等价——既有「视觉尺寸按 scale 放大」「screenSize 回 GLOBAL/view 空间」等测试全绿，WebView 划词弹窗/高亮的坐标一致性（全树同一均匀变换）不受影响。消除「子树溢出自身」这个与命中测试冲突的特殊情况，非补丁式绕过。
- **[x] ② 已加自动化测试** — `test/widgets/app_ui_scale_test.dart` 新增「缩小 (scale<1)：屏幕底部按钮仍可命中点击」：`scale=0.5` 下左上 + 底部各放 `GestureDetector`，`tester.tap` 两者后断言底部 `bottomTapped` 为真（左上作控制组）。旧码（OverflowBox）下底部 tap 落入死区、`bottomTapped==false` → 红；FittedBox 修复后绿。同文件原有缩放/spacing/textScaler/快路径 4 测仍绿，证明视觉行为未变。
- **备注**：布局/命中测试类，最强可落地层是 widget tap 行为测试（真实 hitTest 派发）。代码 + `test/widgets/app_ui_scale_test.dart` + 相邻 `test/focus/focus_geometry_test` `test/widgets/{hibiki_focus_ring,slider_value_indicator_scale}_test` 全绿、`dart format` 0 改动；全量 `flutter test` 2075 绿（唯一失败 `audiobook_play_bar_reverse_test` 与本改动零交集、单独跑通过，系并发/顺序串扰）。**真机肉眼复测原始失败路径**（设置里把界面调小 → 底栏、右侧按钮仍可点）待用户后补。

## BUG-021 · 反转阅读器底栏把 ⏮⏯⏭ 前进后退也镜像了，方向操作颠倒
- **报告**：2026-06-04（用户：「反转阅读器底栏，不要把前进后退也反转了，操作不对」）。
- **真实性**：✅ **真 bug（镜像粒度过粗）**。有声书播放底栏 `AudiobookPlayBar`（`audiobook_play_bar.dart`）的 `reversed` 开关做的是 `children: reversed ? barItems.reversed.toList() : barItems`（`:131`），把**整条扁平 children 列表**翻转——其中 `barItems` 前三项正是 ⏮(上一句/快退)⏯(播放)⏭(下一句/快进)。reversed=true 时三联键顺序变成 ⏭⏯⏮：快退/上一句跑到右、快进/下一句跑到左，方向语义被镜像 → 用户按左以为后退实际前进。普通设置底栏 `_buildSettingsBar`（`reader_hibiki_page.dart`）只有 headphones/Spacer/tune 无方向键，翻转无害，故问题仅在播放条。根因 = 把「整体布局镜像」和「播放三联键内部方向」耦合在同一个 `List.reversed` 里。
- **[x] ① 已修复** — 把 ⏮⏯⏭ 三键打包成一个 min-size `Row`（`playbackControls`）作为 `barItems` 的单个原子项；`barItems.reversed` 只调换顶层项的左右位置，播放组整体换边但**内部方向恒为 ⏮⏯⏭**。改数据结构消除特殊情况，而非加 `if (reversed)` 分支单独回正三键。cue 文本仍 `Expanded`、follow/tune 仍随镜像换边，符合「反转底栏但不反转前进后退」。
- **[x] ② 已加自动化测试** — `test/media/audiobook/audiobook_play_bar_reverse_test.dart`（真 widget 行为，按图标中心 x 坐标断言）：① 未翻转时 ⏮<⏯<⏭<⚙；② 翻转时 ⏮<⏯<⏭ 仍成立（三联键方向不变）且 ⚙<⏮（整条 bar 确已镜像）。修复前用例②的 `prev<play` 直接红（实测 prev=773 > play=734）。全量 `test/media/audiobook/`（265）绿无回归。
- **备注**：reader/有声书/布局类。代码 + 单测绿、`flutter analyze` 0 issue、`dart format` 0 改动。**真机肉眼复测**原始失败路径（开有声书 → 设置开「反转底栏方向」→ 确认 ⏮⏯⏭ 仍是上一句左/下一句右、其余控件镜像）待用户后补。

## BUG-019 · Windows 上打开「带有声书的 EPUB」阅读器永久白屏（内容空白、窗口可动）
- **报告**：2026-06-04（用户，附截图：纯白 Hibiki 窗口）。用户澄清：导入成功后**开书才白**、**窗口能动但内容空白**，并提供 `win_run.log`（2476 行）。
- **真实性**：✅ **真 bug（COM 未初始化导致 WebView2 环境创建失败）**。日志逐行钉死：`2422 parsed EPUB: 23 chapters` → `2424 restore lookup` → `2425 volume key handlers installed`（=阅读器 init 走到 `reader_hibiki_page.dart:423`，证明 `_resolveAudioSlot()`(`:382`，音频 load)**已正常完成**，排除音频挂起），紧接 `2426 in_app_webview.cpp(67): Error -2147221008: 尚未调用 CoInitialize` + `dealloc InAppWebViewSettings`。`-2147221008 = 0x800401F0 = CO_E_NOTINITIALIZED`：reader 的 WebView2 环境创建（`in_app_webview.cpp:167` `CreateCoreWebView2EnvironmentWithOptions`，其完成回调在 `:67` `failedAndLog(result)` 记此错）在**当前线程 COM 未初始化**时失败 → `completionHandler(nullptr,…)` → controller/webView 均空、settings 立即 dealloc → 正文永不渲染 = 白屏；UI 线程空闲故窗口仍可拖动。**为何只在「带有声书」时白**：打开有声书会经 `_initAudiobookController`→`AudiobookPlayerController.load()` 启动 media_kit/libmpv（桌面 just_audio 后端，本次加载 492MB m4b），libmpv 在主/平台线程把 COM 初始化引用净额打到 0（CoUninitialize 不配对），之后 reader 创建 WebView2 时 COM 已失效。普通 EPUB 不加载 media_kit，COM 不被破坏，故正常。根因 = WebView2 的「调用线程须 CoInitialize」前置条件被其他插件破坏，fork 未在用处重新保证它。
- **[x] ① 已修复** — 在 vendored fork 的两个 WebView2 环境创建点前调用 `CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)`：`flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp`（reader 实际失败路径，`else` 分支创建 env 前）+ `webview_environment/webview_environment.cpp`（显式 environment 路径，同前置条件）。`CoInitializeEx` 按线程引用计数、幂等（已初始化返回 `S_FALSE`），把 WebView2 文档要求的前置条件**在它需要的地方就地恢复**，不依赖全局 COM 状态完好；平台线程存活整个 app 生命周期，故有意不配 `CoUninitialize`。消除「依赖别的插件不破坏 COM」这一隐性前提，非补丁式绕过。两文件各加 `#include <objbase.h>`。`flutter build windows --debug` 通过（√ Built hibiki.exe）。
- **[x] ② 已加自动化测试** — `test/pages/reader_webview_com_focus_guard_static_test.dart`（源码扫描守卫：两个 fork cpp 文件里 `CoInitializeEx(` 必须存在且 index 早于 `CreateCoreWebView2EnvironmentWithOptions(`；去 `//` 注释后比较，避免注释字面量误判）。删掉任一 CoInitializeEx 或挪到 env 创建之后即红。WebView2 真实行为无法单测（需 live 原生层），故源码守卫是最强可落地层。
- **备注**：reader/WebView/平台原生类，改了 Windows fork 的 C++ + 需 `flutter build windows` 重编原生插件（已编过）。**Win11 真机复测原始失败路径**（导入带 m4b 的有声书+EPUB → 开书 → 阅读器正常出正文、不再白屏；并复测普通 EPUB、有声书播放/跟随仍正常）**待用户**。设计层另注：`reader_hibiki_page.dart:382` 把 `await _resolveAudioSlot()`（音频 load）排在首帧渲染关键路径之前、`_navigateToChapter` 的 8s content-ready 兜底之前——本次根因是 COM 不是音频挂起，故未改该串行；但「正文渲染被音频初始化阻塞、且无兜底」是潜在隐患，若日后音频 load 真慢/真挂仍会白屏无超时，留作后续去串行化。

## BUG-020 · 阅读器切换底栏时 `_chromeFocusScope.nextFocus()` 空指针崩（scheduler 异常）
- **报告**：2026-06-04（`win_run.log:2449` 捕获，与 BUG-019 同次复现）。
- **真实性**：✅ **真 bug（未挂载焦点域被走查）**。`══ EXCEPTION CAUGHT BY SCHEDULER LIBRARY ══ _TypeError: Null check operator used on a null value`，栈顶 `FocusNode.nextFocus (focus_manager.dart:1239)` ← `_ReaderHibikiPageState._toggleChrome.<anonymous closure> (reader_hibiki_page.dart:4287)`。`FocusNode.nextFocus()` 内部解引用 `context!`；当 `_chromeFocusScope` 未被任何 `FocusScope` widget 挂载（`context == null`）时抛空指针。`_toggleChrome` 的 post-frame 回调在底栏 chrome 还没 build 出 `FocusScope(node:_chromeFocusScope)`（如 BUG-019 白屏下 `_readerContentReady==false`、chrome 整段不构建）时仍调 `nextFocus()` → 崩。同 `:3614` 手柄 D-pad Down 路径同源未护。`requestFocus()` 不需要 context 故无恙，只有 traversal 需要。
- **[x] ① 已修复** — 两处 `_chromeFocusScope.nextFocus()`（`reader_hibiki_page.dart:4287` post-frame、`:3614` 手柄 Down）各加 `_chromeFocusScope.context != null` 前置守卫：未挂载的焦点域不走查。消除「scope 一定已挂载」的错误前提。
- **[x] ② 已加自动化测试** — 同 `test/pages/reader_webview_com_focus_guard_static_test.dart`（BUG-020 用例：去注释后 `_chromeFocusScope.nextFocus()` 的出现次数 ≤ `_chromeFocusScope.context != null` 守卫次数，且 >0）。新增未护的 nextFocus 即红。
- **备注**：scheduler 异常被框架捕获、非致命，但属真实健壮性 bug。常与 BUG-019 白屏同发（白屏下 chrome 不构建、scope 未挂载）。reader 类无法 widget 测真实 InAppWebView，源码守卫为最强可落地层；真机复测（开书后切底栏不再刷 scheduler 异常）随 BUG-019 一并待用户。

## BUG-018 · 词典弹窗字级光标焦点环落在空盒子/细条上（与图标错位）
- **报告**：2026-06-04（用户，附两张截图：teal 焦点环一处是分隔线附近的细高竖条、一处是 ♪/+ 按钮上方的空角丸方框）。
- **真实性**：✅ **真 bug（焦点环几何与可见内容不对称）**。弹窗里字级光标（`window.hoshiCaret`，`reader_caret_scripts.dart`）按设计会停在交互控件上让手柄可达（`7abc0a92b`）。但**文字停靠点**用 `_charRect`（紧贴单字形），**元素停靠点**却用 `el.getBoundingClientRect()`（含 padding/行盒/`transform` 的整盒）：`_stopRect:334`、`_anchorRect:338`、`_interactiveEls:320`、`_collectVisibleStops:423`、`refresh:832`。后果——折叠词典段 `summary.dict-label`（`display:inline`、10px、半透明、▶ 是 `::before`）框成稀疏细条；`.audio-button`/`.mine-button`（`font-size:18px` 行盒 + flex 居中 + `translateY`）框成比 ♪/+ 大且上移的空角丸方框（`border-radius:3px` 来自焦点环 `:636`）。根因 = 元素停靠点的环用整盒、与文字停靠点不对称，且未排除可见内容为空的退化元素。
- **[x] ① 已修复** — `3db13bd69`（新增 `_elInk`（元素自身内容 client rects 并集 = 可见 ink，排除 `::before` 伪元素）与 `_elRect`（优先 ink、clamp 到 border box、无 ink 回退 box），把上述 5 处元素 rect 读取统一路由过去；`_interactiveEls` 丢弃"无 ink 且非 img/picture/video/canvas/svg/[role=img]"的空 wrapper。保留控件可达性，只收紧环几何——消除不对称而非删停靠点。reader 分支 `window.hoshiReader` 下 `_interactiveEls` 仍走 `img.block-img`，未受影响）。
- **[x] ② 已加自动化测试** — `test/reader/reader_caret_scripts_test.dart` 源码扫描守卫 3 条（先红：`456792148`，后绿：`3db13bd69`）：环走 `_elInk`/`_elRect`/`selectNodeContents`/`getClientRects`；`_stopRect`/`_anchorRect` 经 `_elRect`；空 wrapper（`!this._elInk(e)` 且非图片）被排除。谁把元素环改回裸 `getBoundingClientRect()` 即红。全量 `flutter test` 2039 绿无回归。
- **备注**：reader/WebView 几何类。代码 + 单测已绿、`flutter analyze` 0 issue；几何真值（环是否真贴合 ♪/+ 与 summary 文字、不再有空盒子/细条）需**真机肉眼复测**原始失败路径（开词典弹窗 → 手柄/键盘进字级光标 → 方向键停到 ♪/+ 与折叠词典段，确认环贴字形/标签）——待用户后补。`_elInk` 对 collapsed `summary` 只框标签文字（▶ 由 `::before` 渲染、不入 Range，落在环外），如真机觉得需连 ▶ 一起框可再议。

## BUG-017 · 歌词模式当前行被放大后溢出左右边框、文字贴边裁切
- **报告**：2026-06-04（用户，附截图：蓝色高亮当前行 `麗子はその扉を開けて恐る恐る現場に足を踏み入れた。` 顶满左右边框、右侧 `足を踏み入` 被裁，灰色非当前行有正常边距）。
- **真实性**：✅ **真 bug（布局溢出）**。歌词模式独立页 `LyricsModeHtml.generate`（`lyrics_mode_html.dart`）里 `.cue { max-width: 92vw; }` 让当前行在 92vw 内换行，随后 `.cue.current { transform: scale(1.15); }` 把整盒（含宽度）**视觉放大到 92vw × 1.15 = 105.8vw**，默认 `transform-origin: 50% 50%` 居中放大 → 向左右各溢出 ~7vw；`html, body { overflow-x: hidden }` 把溢出裁掉 → 当前行文字贴边并被切。非当前行 scale 1.0、92vw < 95vw 内容区故有正常边距，只有被放大的当前行溢出，与截图吻合。隐患叠加：`92vw` 是硬编码，既不跟随容器 `padding`（marginLeft/Right，默认各 2.5vw），也不预留 scale 余量——两个魔数静默耦合。根因点旧 `lyrics_mode_html.dart` 的 `max-width: 92vw` 与 `.cue.current { transform: scale(1.15) }`。
- **[x] ① 已修复** — 把 `--cue-scale: 1.15` 提成 `:root` 变量，`.cue.current { transform: scale(var(--cue-scale)) }`，`.cue { max-width: calc(100% / var(--cue-scale) - 1%) }`。`100%` 对 flex 子项解析为容器内容盒（= 100vw − 左右 padding），自动跟随边距；除以最大 scale 预留缩放余量使 `scale × maxWidth ≤ 内容盒`，溢出按构造消失；`- 1%` 是亚像素抗锯齿安全余量；全 `.cue` 统一 max-width 故行变 current 时只缩放不重排（消除动画抖动）；live-update（`__lyricsUpdateStyle`）只改容器 padding，百分比相对值自动重算无需额外 JS（按 `selectorText` 匹配，新增 `:root` 规则不影响其循环）。消除特殊情况 + 去掉魔数静默耦合（提交见下）。
- **[x] ② 已加自动化测试** — `test/media/audiobook/lyrics_mode_html_test.dart` 新增「active cue width reserves headroom for its scale」：断言 `.cue.current` 用 `transform: scale(var(--cue-scale))`、存在 `--cue-scale:`、`.cue` 的 `max-width` 是 `calc(100% / var(--cue-scale)` 且**不含** `92vw`/`100vw`。旧码（`scale(1.15)` 字面量 + `92vw`）四条断言全红——非同义反复。全量 `test/media/audiobook/` + `reader_paginate_lyrics_guard_static_test` + `reader_hibiki_dialog_test` 共 266 绿无回归。
- **备注**：reader/WebView/布局类。代码 + 单测已绿，`dart format` 0 改动。最强可落地层是 CSS 生成器断言（纯字符串生成、无 WebView 渲染）；真机肉眼复测原始失败路径（开有声书→进歌词模式→确认当前高亮行不再贴边裁切、非当前行边距一致）待用户后补。near-1 仍用字面量 `scale(1.05)`（< 1.15，余量更足，无需变量化）。

## BUG-016 · 同步设置「立即同步/导出/导入」手柄键盘到不了，Compare Data 按下跳到左侧导航
- **报告**：2026-06-04（用户，附截图：焦点环在「Compare Data」行，按下跑到左边；并指出「去不到立即同步」）。
- **真实性**：✅ **真 bug（方向焦点不可达）**。方向导航只走已注册的 `HibikiFocusTarget`（`gamepadMoveFocusInDirection`→`HibikiFocusController.move`，只遍历 `_entries`）。`AdaptiveSettingsRow` **只有传了 `onTap` 才注册焦点目标**（`settings_shared.dart:250` `if (onTap == null) return content;`，否则裸 `content` 不可聚焦）。但同步设置的「立即同步」(`_SyncNowWidget`)、「导出备份」(`_BackupExportWidget`)、「导入备份」(`_BackupImportWidget`) 把动作放在 `controlBelow` 的**尾部裸 `FilledButton`** 上、行本身**没有 `onTap`** → 整行不注册，裸按钮也不是 Hibiki 焦点目标。后果：① 「立即同步」等按钮**永远聚焦不到**；② 焦点在已注册的「Compare Data」(`SettingsActionItem`→带 `onTap`) 按 Down，因为同面板下方没有可达目标，几何评分挑了**跨面板**的左侧导航项 → 焦点「去到左边」。根因点 `sync_settings_schema.dart` 三个 widget 的 `build()`。
- **[x] ① 已修复** — 给这三行的 `AdaptiveSettingsRow` 加 `onTap`（指向各自的 `_syncNow/_export/_import`，并在这些方法首行加 `if (_syncing/_isExporting/_isImporting) return;` 防重入，因为整行 Activate 与尾部按钮会都触发）。整行随之注册成焦点目标，A/Enter 经 `_SettingsRowFocusTarget` 的 `ActivateIntent` 跑动作；尾部按钮保留作视觉/鼠标可达。「立即同步」可达；「Compare Data」按 Down 落到同面板下方的「导出备份」而非跳走。提交见下。
- **[x] ② 已加自动化测试** — `test/settings/sync_action_rows_focus_test.dart`：真实 `AdaptiveSettingsRow` 重建左导航+右详情两面板，从 `detail-top` 连按 Down 走 Compare→Sync，并各用 `ActivateIntent` 验证落点（`syncActivated` 必须为真——修复前 Sync 行未注册，第二次 Down 会跳到导航面板，该断言变红）。
- **备注**：布局/焦点类。代码 + `test/focus/ test/settings/ test/sync/` 全量（329）绿。真机手柄/键盘复测同步设置页（焦点能到「立即同步」「导出」「导入」，Compare 按下到导出而非导航栏）待用户。同类的 `_SyncAccountWidget` 登录/登出按钮、各后端「测试连接」按钮也是行内裸按钮、同源问题，本轮未报未改，留作后续。

## BUG-015 · 外观设置「反转底栏方向」开关按左键焦点跳到「主题」色块
- **报告**：2026-06-04（用户，附截图：焦点在底部整宽开关「反转底栏方向」，按方向键左，焦点回到上方「主题」色块行）。
- **真实性**：✅ **真 bug（方向几何评分错档）**。宽屏设置主从布局：左导航面板、右详情面板各是独立 `Scrollable`。`HibikiFocusController._geometricTarget` 的评分把 `samePane`（同一可滚动面板）排在 `clears`（候选在按压轴上**整体越过**源，即真·下一行/下一列邻居）之上（`hibiki_focus_controller.dart:400-409`）。整宽的开关行没有「同行左邻居」，唯一的同面板「左方」候选只能是**斜上方**的「主题」色块（`clears=0`）；正左方、确实越过源的导航项是跨面板（`samePane=0`）。`samePane` 优先 → 斜上方色块击败正左方导航项 → 左移跳到「主题」。这个 `samePane`-first 档是早先「Down 留在同面板」修复（`focus_pane_locality_test`）叠加上来的，过度泛化到了 Left/Right。
- **[x] ① 已修复** — 把评分档序从 `samePane > clears > along > beam > cross` 改为 `clears > samePane > along > beam > cross`（`hibiki_focus_controller.dart`）。真·方向邻居（clears）优先于同面板斜向候选；同为 clears 时再用 `samePane` 保「Down 留在同面板」（那条 case 里跨面板导航项也 clears，平局由 `samePane` 打破，原行为不变）。`along>beam` 次序不动，故外观 Down 仍落到左对齐紧邻行、网格 Down 仍选同列、键盘右键仍到同行（BUG-011）。消除错档而非加权重。
- **[x] ② 已加自动化测试** — `test/focus/focus_left_escapes_pane_test.dart`：两面板，焦点在整宽 `detail-switch` 按 Left，断言落到 `nav-*`（修复前落 `detail-swatch` → 红）。并以全量 `test/focus/ test/shortcuts/gamepad_focus_nav_test.dart test/widgets/{theme_swatch,settings_segmented_row,gamepad_nav_cluster,focus_reachable_clusters,material_nav}_*` 为回归门槛实跑全绿（含 `focus_pane_locality_test` 的「Down 留同面板」「Right 跨面板」、`focus_geometry_test` 的 along-first、BUG-011 键盘右键）。
- **备注**：focus 核心共享算法改动，已用全 focus/gamepad 测试矩阵把关；真机手柄/键盘在外观设置页复测（开关按左到导航栏、色块行内左右仍切色块）待用户。

## BUG-014 · 同步对比对话框把「良性跳过」误报成「同步错误：<书名>」
- **报告**：2026-06-04（用户附截图：SnackBar 显示「同步错误：Pagination Test Book」）。
- **真实性**：✅ **真 bug（结果分类错误）**。该 SnackBar 唯一来源是 `sync_compare_dialog.dart` 的 `_applyChanges`（`t.sync_error(message: errors.join(', '))`，message 是书名列表）。逐本书应用时旧逻辑 `if (result.direction != SyncResult.skipped) applied++ else errors.add(entry.title)` 把**任何** `SyncResult.skipped` 都归到 `errors`。但 `SyncManager.syncBook`/`_syncBookOnce` 返回 skipped 有两类语义：① 真失败——`syncBook` 把 `SyncBackendError`/通用异常吞进 `SyncBookResult.error` 后以 skipped 返回（`sync_manager.dart:88-108`）；② **良性跳过**——无可传输内容，`error == null`，例如导出方向但本地无阅读位置且未开内容同步（`sync_manager.dart:211-213`）、importOnly 方向不符（`:187-189`）。旧分类只看 `direction` 不看 `error`，把②误报成「同步错误」。「Pagination Test Book」即走②路径（用户选了方向但实际无内容可传）。根因 = 分类信号选错（该看 `result.error`，却只看 `direction == skipped`）。
- **[x] ① 已修复** — `91e82d921`（在 `sync_manager.dart` 旁加纯函数 `classifySyncApply(SyncBookResult) -> SyncApplyOutcome{applied,failed,noop}`：先 `error != null → failed`，再 `imported/exported → applied`、`synced/良性 skipped → noop`；`sync_compare_dialog._applyChanges` 改用它，noop 既不计成功也不报错。消除「skipped 一律 = 错误」的错误前提，真失败（带 error）与抛出的 `SyncAuthError`（仍走外层 catch→errors）报告路径不变）。
- **[x] ② 已加自动化测试** — `test/sync/sync_apply_outcome_test.dart`（6 例钉死分类边界：良性 skipped→noop、skipped+error→failed、imported/exported→applied、synced→noop、传输方向+error→failed）。谁把良性跳过重新归到 failed 即红。全量 `test/sync/` 213 绿无回归。
- **备注**：UI 行为类（SnackBar 误报）。代码+单测已绿，`flutter analyze` 三文件 0 issue。最强可落地层是纯函数分类（分类逻辑已从 widget state 抽出），故未做 widget 级 SnackBar 断言；真机复测原始失败路径（同步对比对话框选一本无内容可传的书→点应用→确认不再弹「同步错误」）待用户后补。

## BUG-013 · 非 Android 平台「更新」设置是可见但失效的死开关
- **报告**：2026-06-04（用户问「各个平台的自动更新正常吗」，我沿真实代码路径核查后发现）。
- **真实性**：✅ **真 bug（UI 与能力不匹配）**。自动更新整条链路**仅 Android 实现**：`update_checker.dart:69` 的 `_check()` 第一行 `if (!Platform.isAndroid) return;` 直接早退；原生 `installApk` 通道也只在 Android `MainActivity.java:283-334` 注册（FileProvider + `ACTION_VIEW`，带 HBK-AUDIT-058 路径校验）。全仓无任何第三方更新器（grep `sparkle`/`winget`/`msix`/`in_app_update` 仅命中文档）。但设置页「更新」分区（`settings_schema.dart` `_systemDestination()` 的 `t.section_update` section：更新通道 `system.update_channel` / 不再提醒 `system.update_never_remind` / 自动安装 `system.update_auto_install`）**无平台门控**——对照同文件 Android 专属项都写了 `visible: (_) => Platform.isAndroid`（`:151` 应用图标、`:1051/:1063` 悬浮歌词）。后果：iOS/macOS/Windows/Linux 用户看得到这三个开关，但 `home_page.dart:52` `scheduleCheck` → `_check` 在第 69 行就 return，根本不读这些值 → **拨动毫无作用的死开关**；对 iOS 还是 App Store 审核风险点。根因 = 数据侧能力 Android-only，UI 可见性却没对齐。
- **[x] ① 已修复** — `b83538d40`（给「更新」`SettingsSection` 加 `visible: (_) => Platform.isAndroid`：section 级单一网关消除三个死开关，无特例分支；`visibleSections`(`settings_destination.dart:71-76`) 先 `section.isVisible` 过滤再丢空 section，非 Android 下整段更新分区消失，不影响该 destination 第二个「系统」分区（语言/低内存/github/debug log）。同时 destination `summary` 改 `Platform.isAndroid ? t.section_update : null`，消除非 Android 下指向不存在能力的「更新」副标题——两个 renderer 都 `summary != null ? Text : null` 故 null 安全）。
- **[x] ② 已加自动化测试** — `test/settings/update_settings_android_only_guard_test.dart`（同提交 `b83538d40`）。源码扫描守卫，锚定稳定字面量（持久化 key `system.update_*`、网关表达式、`_selectedUpdateChannel(` 结束标记），用 `gateIdx = indexOf(gate, sectionTitleIdx)` + 断言三个 key 都在 `gateIdx` 之后，确保网关真覆盖更新分区而非第二个系统分区；门控被移除 → `gateIdx=-1` → `isNonNegative` 失败变红。第二个用例钉死数据侧 `update_checker.dart` 的 `!Platform.isAndroid` 早退，二者同进退。另：`settings_schema_coverage_test.dart`（在非 Android 宿主跑真实 `MaterialSettingsRenderer`+真实 schema）实跑全绿（`rows=51 stillUnaccounted=0 destFindings=0`），三项更新设置已不再被焦点遍历到——即非 Android 路径的行为佐证。opus 审查 🟢 可合并，无 Critical/Warning。
- **备注**：非 reader/WebView/导入/播放/布局类，是设置 schema 可见性网关，已由覆盖测试在真实非 Android 渲染路径行为验证；Win11 真机肉眼复测（打开 设置→系统，确认无「更新」分区）可后补，非阻塞。**设计判断**：桌面/iOS 的「无应用内自动更新」是有意的（iOS 靠 App Store、桌面靠手动从 GitHub 下载），本轮只修「死开关」而非新增桌面更新机制——后者是独立大功能，需另立项。**遗留（非阻塞）**：`settings_schema_coverage_test.dart:76-78` 的 `kCoveredElsewhere` 三条 `'system/Update Channel'` 等 `DEVICE:` 登记现在在非 Android 宿主用不到，但若在 Android 宿主跑测试则仍需它们防 `stillUnaccounted` 变红，按 Never-break 保守保留。

## BUG-012 · md3 静态守卫扫已删除的 `_buildRailLeading()`（stale 测试，非产品 bug）
- **报告**：2026-06-03（我，T4 探针全量回归 `flutter test` 时发现的 4 个预存失败之一，用户让查）。
- **真实性**：⚠️ **非产品 bug，是 stale 测试守卫**。`test/settings/md3_design_system_static_test.dart`「page chrome surfaces use shared MD3 spacing tokens」用 `_functionSource(homeSource, 'Widget _buildRailLeading()', 'class _SyncExitWarningDialog')` 扫 `home_page.dart` 的 rail-leading 函数，但 `8fd0fc1fe`（删宽屏 rail logo）已把 `_buildRailLeading()` 整个删除（`grep` 确认 home_page.dart 已无此函数，`_SyncExitWarningDialog` 尚在 `:421`）→ 起始标记找不到 → `indexOf` 返回 `-1` → `expect(..., isNonNegative)` 失败。产品行为（删 rail logo）是**有意的**，不是 bug。
- **[x] ① 已处理** — `3f508995c`（移除那条扫**已删除函数** `_buildRailLeading()` 的废断言；同测试的 collections + tag-management chrome MD3 token 守卫保留不变）。无产品 bug 可修，这是 stale 测试维护。
- **[ ] ② 不适用**（非产品 bug，无回归测试可加）。
- **备注**：rail leading logo 表面在 `8fd0fc1fe` 已整体删除（有意），故该子守卫确定性失效（扫不存在的函数）、非设计判断，直接移除以解全套件唯一红。若并发 agent 的 MD3 nav-shell 重构重新引入 rail leading，应再补对应守卫。

## BUG-011 · 手柄屏幕键盘「右」键落到右下对角键而非同行邻居
- **报告**：2026-06-03（我，全量回归预存失败之一）。
- **真实性**：✅ **真回归**。`HibikiGamepadKeyboard` 焦点在 `q`，按 D-pad 右键焦点落到**下一行的 `a`** 而非同行的 `w`（`test/widgets/hibiki_gamepad_keyboard_test.dart:60` 期望 `['w']` 实得 `['a']`）。根因：`f165cd475`（用户自己的提交「directional nav no longer skips the immediately-next row」）把**「沿按压方向距离 `along`」设成 `HibikiFocusController` 几何导航的绝对主键**（为修向下导航跳行），副作用是横向「右」移时——下一行里只要稍偏右的键（`a`：`along` 极小、`beam`=0 无垂直重叠）会击败同行邻居（`w`：`along`≈1 键宽、`beam`=1 有重叠）。根因点 `hibiki_focus_controller.dart:371-375`。
- **[x] ① 已修复** — `c8017ad8c`。修法不靠调权重（线性 `along+K·cross` 无单一 K 可同时满足键盘 `K>0.68` 与外观 `K<0.224`，恢复 `beam`-first 又反转 `f165cd475`），而是**加一个几何「clears」主层**：候选须在按压轴上**整体越过源**（近边在源远边之后）才进第一层；`a` 在横向与 `q` 重叠 → RIGHT 不 clear → 降到第二层，`w` clear。层内保留 `f165cd475` 的 `along→beam→cross` 序，故外观 DOWN 仍到左对齐紧邻行、网格 DOWN 仍选同列。消除冲突而非折中。
- **[x] ② 已加自动化测试** — `test/widgets/hibiki_gamepad_keyboard_test.dart`（`q`→右→`w`，随修复变绿）即守卫；并以**全套 30+ gamepad/focus 测试**为回归门槛实跑全绿（`+250`），含 `test/shortcuts/gamepad_focus_nav_test.dart`（`f165cd475` 的外观 DOWN）、`test/focus/focus_geometry_test.dart`、`theme_swatch_gamepad`、`settings_value_row_gamepad` 等。
- **备注**：影响手柄/方向键操作屏幕键盘可用性（右键曾走对角）。focus 核心改动，已用全 gamepad/focus 测试矩阵把关；真机手柄复测可后补。

## BUG-010 · 错误日志通知器在无绑定时抛异常，反噬「损坏 JSON 优雅降级」
- **报告**：2026-06-03（我，全量回归预存失败之一，且用户提示「2 个 JSON 容错可能同根因」——确为同根因）。
- **真实性**：✅ **真 bug（健壮性契约）**。`frequency_field`/`preferences_repository` 解析损坏 JSON 时进 catch 块调 `ErrorLogService.log` → `FrameSafeNotifier.notifyListenersFrameSafe`(`frame_safe_notifier.dart:21`) 读 `SchedulerBinding.instance`，**无绑定**（纯 `test()` / 后台 isolate / 绑定初始化前极早期）时抛 "Binding has not yet been initialized" → 把「优雅降级返回空」**反噬成抛异常**。根因：`397d027cd`（make log services reactive via ChangeNotifier）让 error sink 的通知路径假定绑定存在。生产里绑定总在故非用户可见，但 **error sink 永不该 throw** 是真实健壮性契约（否则今后任何会记错误日志的代码做 unit test 都得加 binding）。
- **[x] ① 已修复** — `ae46e9d21`（`notifyListenersFrameSafe` 改用 `_schedulerOrNull()` 安全取绑定：无绑定时一定不在帧渲染管线中 → 直接同步 `notifyListeners()`；消除「无绑定」这个特例，error sink 不再 throw）。
- **[x] ② 已加自动化测试** — `test/creator/frequency_field_test.dart`（malformed extra JSON 返回空）+ `test/models/preferences_repository_test.dart`（corrupted JSON 优雅）——这两个**本就存在**的测试随修复变绿，即回归守卫（谁让 error sink 再抛即红）。
- **备注**：同 `FrameSafeNotifier` 的 `DebugLogService` 也受益。非 reader/WebView，无需设备复测。

## BUG-009 · 桌面端「外观→iOS(Cupertino)」设置页崩坏：三栏拥挤 + 右下角 RenderFlex 溢出 + 无返回出口
- **报告**：2026-06-03（用户，附两张截图：切 iOS 前为正常 Material 全屏二栏；切 iOS 后变成「最左 Material 药丸 3 图标侧栏 + 中间 Cupertino insetGrouped 目标列表 + 右侧详情底部黄黑条纹溢出」，无返回箭头）
- **真实性**：✅ 真 bug（代码追踪 + Win11 真机截图双确证）。两个独立根因：
  - **R1 详情溢出**（右下黄黑条纹）：`CupertinoSettingsRenderer.buildDetailContent`(`hibiki/lib/src/settings/cupertino_settings_renderer.dart:110`)返回**裸 `Column`（不可滚动）**，被 `SettingsHomePage._buildWideLayout`(`settings_home_page.dart:159-165`)塞进 `MaterialSupportingPaneLayout.primary`（`Expanded`，有限高度）→ 内容超高 RenderFlex 溢出。对照 `MaterialSettingsRenderer.buildDetailContent`(`material_settings_renderer.dart:114`)用 `ListView.builder` 自带滚动故不溢出。
  - **R2 结构割裂**（三栏拥挤 + 无返回 + 布局突变）：`home_page.dart:327` 的设置标签全屏分支带 `_currentTab==2 && !isCupertinoPlatform(context)` 门控，cupertino 桌面被排除 → 退化成「3 图标 rail + 嵌入设置」三栏；且 `SettingsHomePage._buildEmbeddedMaterialShell`(`settings_home_page.dart:101-103`)对 cupertino 提前返回裸 content（无页头/返回箭头）。桌面外壳本应「复用 Material 架构、叶子控件按设计系统切皮肤」(CLAUDE.md)，此处 cupertino 桌面是半成品特例路径。同款 overflow/退化在 macOS、iPad 横屏同样存在（同一份 `_buildDesktopLayout`），无人报。
- **[x] ① 已修复** — `918139165`（R1：`CupertinoSettingsRenderer.buildDetailContent` 裸 `Column` → 可滚动 `ListView.builder`，对齐 Material 渲染器，shrinkWrap 时禁自滚由外层 sliver/SingleChildScrollView 滚、底部留安全区；`buildDetailPage` sliver 内调用传 `shrinkWrap:true`；reader 设置弹窗 `shrinkWrap:!cupertino→true`。R2：去掉 `home_page.dart` 设置全屏分支的 `!isCupertinoPlatform` 门控，cupertino 桌面也隐藏 3 图标 rail 走全屏二栏；`settings_home_page._buildEmbeddedShell` 去掉 cupertino 提前返回、给桌面全屏设置补 `HibikiPageHeader`+返回箭头，并短路保留 cupertino 手机原生无页头。消除特例分支，非补丁）
- **[x] ② 已加自动化测试** — `test/settings/settings_renderer_test.dart`（`BUG-009`：cupertino 详情在固定矮高度 pane 里渲染不抛 RenderFlex 溢出、提供可滚动视口；`BUG-009 R2`：`platform=windows + designSystem=cupertino` 下 pump 真实 `SettingsHomePage(embedded,onBack)`，断言渲染返回箭头出口且不溢出）
- **备注**：布局类。代码+单测已绿（settings_renderer_test 14/14；opus 审查 🟢 无致命问题，确认全 5 个 `buildDetailContent` 调用点覆盖、material 弹窗零变化、macOS/iPad/iOS手机/Android 各组合推演只有目标场景改变）。仍需 **Win11 真机肉眼复测**原始失败页（外观切 iOS）确认黄黑条纹消失、二栏、返回箭头可点回来源 tab、视觉协调——待补。R3 配色（Cupertino 列表系统灰 vs app 主题 surface 色不一致）属主观微调，本轮不做，真机看效果再定。
- **预存失败（非本轮）**：`test/settings/md3_design_system_static_test.dart` 的「page chrome surfaces use shared MD3 spacing tokens」用例引用 `home_page.dart` 已被删除的 `_buildRailLeading()`（「删宽屏 rail logo」改动遗留，与 BUG-009 无关），本轮未触碰，待对应改动方同步守卫。

## BUG-008 · 外观设置「设计系统/深色模式」分段选项位置错乱、右侧选项被切掉
- **报告**：2026-06-03（用户，附截图：自动/MD3/iO[S] 与 深色模式 三段控件右端被裁，最后一项漏到屏幕外）
- **真实性**：✅ 真 bug。`buildDesignSystemSelector`(`settings_actions.dart:208`)、`buildBrightnessSelector`(`settings_actions.dart:378`)、以及阅读器快捷设置的 view-mode 行(`reader_quick_settings_sheet.dart:389`)构造 `AdaptiveSettingsSegmentedRow` 时**未传 `controlBelow`，落到默认 `false`** → 走 inline `_buildRowLayout`(`settings_shared.dart:283`)：`Row[ Expanded(label, flex1) , Flexible(loose, strip, flex1) ]`，RenderFlex 按 flex 把行宽 ≈50/50 切分 → 分段条只拿到约半幅（远小于其本征宽）→ 横向 `SingleChildScrollView` 滚动到 0、尾段（iOS/月亮）被裁到视口外。仓库中所有“有意”的分段行都显式写了 `controlBelow: true`，唯独这三处漏写——**inline 作为默认值本身就是这个陷阱**。
- **[x] ① 已修复** — `02411bb16`（把 `AdaptiveSettingsSegmentedRow` 与 `SettingsSegmentedItem` 的 `controlBelow` 默认值翻成 `true`：分段条改为占据 label 下方整行全宽，消除 inline flex 半幅裁切的特例；显式传值的 callsite 不受影响，仅这三处受惠）
- **[x] ② 已加自动化测试** — `test/widgets/settings_segmented_overflow_test.dart`（新增 BUG-008 用例：同一宽 strip 在同一 pane 下，inline 路径 `maxScrollExtent>0`=被迫滚动裁切，默认 below 路径 strip 在 label 之下、`maxScrollExtent==0` 全段可见；原 inline 窄 pane 不溢出用例改为显式 `controlBelow:false` 保留覆盖）
- **备注**：布局类，代码+单测已绿；Win11 真机肉眼复测原始失败页（外观设置）待补。

## BUG-007 · 有声书「遇到图片暂停播放几秒」开了无效（假功能）
- **报告**：2026-06-03（用户）。用户：开了「遇到图片暂停的播放几秒」选项没用。附带说书架「查看插图」(`view_illustrations`)能补看插图、稍微有用（独立功能，不在本 bug 范围）。
- **真实性**：✅ 真 bug（静态全链路追定，待插桩确认断点）。Dart 侧整条链完整：UI 段控(`reader_quick_settings_sheet.dart:1071-1113`)→`setImagePauseSec`/持久化(`audiobook_repository.dart:147-156`)→加载回填(`reader_hibiki_page.dart:767/849`,`audiobook_controller.dart:272`)→每切章注入(`_injectAudiobookBridge`,`:1968/:2576`)→JS 检测→`callHandler('onImageDetected')`→handler(`reader_hibiki_page.dart:1793-1796`)→`triggerImagePause`(`audiobook_controller.dart:214-227`)。**根因在检测数据源选错**：图片检测用 `IntersectionObserver`（root=视口、阈值 0.3，`audiobook_bridge.dart:162-189`），而阅读器是 CSS 多栏 + `body{overflow:hidden}` + `scrollLeft/scrollTop` **离散翻页**（`reader_content_styles.dart:296-324`、`reader_pagination_scripts.dart:611-617`）。有声书播放=高亮 reveal 驱动的离散跳页，整页插图常被一帧直接跳过、从不被渲染成「当前页」→ IO 永远达不到 0.3 阈值 → 永不回调 → 暂停永不发生。附带：即便偶尔落在图片页，若此刻没在播 `triggerImagePause` 首行 `if(sec<=0||!_player.playing)return;` 直接返回。全仓库仅此一处用 IntersectionObserver，无其它处验证它在这套布局下能用。
- **[x] ① 已修复** — `f0f36588c`（图片检测从 IntersectionObserver 视口可见性改为 `__hoshiHighlight` cue 推进时用 `compareDocumentPosition` 判定上一句锚点 `__hoshiPrevHighlight` 到当前句之间是否存在 img/svg；删旧 IO `_imagePauseFn`。离散翻页跳过整页插图也能确定性抓到，两种阅读模式通用）
- **[x] ② 已加自动化测试** — `test/media/audiobook/image_pause_detection_test.dart`（源码扫描守卫：检测须用 cue 推进锚点间 DOM 判定、旧 IO 须移除）+ `integration_test/image_pause_detection_test.dart`（真 WebView 设备验证，`365fd1c05`，已登记 ci）
- **备注**：代码 4 环已确认根因，故直接修（未走插桩）。**设备验证已过**（emulator-5554：真 InAppWebView 注入真实 bridge，`__hoshiHighlight` 从 s1 跨 svg 推进到 s2，`onImageDetected` 真触发，All tests passed）。260 audiobook 单测无回归。整页插图+真实有声书音频播放的端到端复测仍可后补（合成验证用相邻锚点+svg 等价了「reveal 跨过无 cue 的整页插图」）。
- **跟进 · gap 补齐（2026-06-03 同日，另一 agent 插桩复现后续补）**：主修复 `f0f36588c` 只覆盖**选择器型 cue** 路径。另 agent 插桩复现确认根因（F1 视口 IO「落在图片页」能触发 ratio 1.0；F2 reveal 离散翻页把整页插图一帧跳过、IO 永不触发，证据 `.codex-test/itest-logs/image_pause_probe3.log`）后补两缺口 + 一边缘：①**sasayaki cue 路径**接入同套锚点间检测（`957adb586`/`505c8c56f`：新 `__hoshiSasayakiAnchorEl` 从 `cueRangesMap`/`cueWrappers` 解析锚点 → 复用共享 `__hoshiImagePauseAdvance`）；②**命中插图先 reveal 再暂停**（`17364783a`：`__hoshiRevealTarget` 滚到插图而非插图后正文，否则停了看不到图）+ 控制器恢复时 `snapReaderToAudio()` 拉回当前 cue 续播（`68cb055ed`）；③边缘：用户在暂停窗口内手动 play 取消计时器 + snap（`496b19f17`）。共享 helper `__hoshiImageBetween`/`__hoshiRevealTarget`/`__hoshiImagePauseAdvance` 两路径复用。**铁律**：`onImageDetected` 跨图就发（与 reveal 无关，设备测试契约），仅「滚到插图」门控 reveal；禁重引入 IntersectionObserver。**设备验证**（`integration_test/image_pause_detection_test.dart`，emulator-5554）selector + sasayaki 跨图都触发 `onImageDetected` 且 reveal 目标 = 插图，All passed；262 hibiki + 6 hibiki_audio 单测绿。计划 `docs/specs/2026-06-03-bug007-image-pause-gaps-plan.md`（`94aebdbb2`）。**真实分页端到端已验**（`integration_test/image_pause_realreader_test.dart` + 新 `debugInjectAudiobookBridge` 钩子，emulator-5554）：真实阅读器里 cue 跨整页插图 → 插图成为可见页（picFrac 1.0）、恢复 → 插图后正文显示（m101Frac 1.0），翻页轴全程页对齐（rem=0）。**该 e2e 还揪出并修了潜伏 bug**：分页模式 `__hoshiRevealTarget` 原 `scrollToTarget‖scrollIntoView` 是 no-op（分页 `hoshiReader` 无 `scrollToTarget`；`overflow:hidden` body 下原生 `scrollIntoView` 不滚）→ 选择器 cue 的 reveal（含 audio-follow 自动滚）在分页模式一直不生效；改用 reader 页对齐原语 `scrollToRange(selectNode(t))`（连续模式回退 `revealElement`/`scrollToTarget`）修复（`1951b6c31`，opus 审 APPROVED）。**残留**：真实音频文件 cue 时序播放未单独跑（与 reveal 行为无关——reveal 路径已端到端验证）。

## BUG-006 · 改 String 型 segmented 设置（书写方向/视图模式/振假名/跨页）渲染器崩溃
- **报告**：2026-06-03（由 settings schema 焦点驱动覆盖测试发现，非用户报告）
- **真实性**：✅ 真 bug。`material_/cupertino_settings_renderer.dart` 把 `SettingsSegmentedItem<String>` 经 `as <Object>` 转型，闭包读 `onChanged` 因函数参数逆变抛 `_TypeError`。两渲染器同病；现有测试只渲染不真改 segmented 所以潜伏。
- **[x] ① 已修复** — `07784a786`（两渲染器改 `(segmented as dynamic).onChanged` 绕开读取期检查）
- **[x] ② 已加自动化测试** — `test/settings/settings_renderer_test.dart`（material + cupertino segmented 改值不抛 _TypeError 回归用例）

## BUG-005 · 阅读器 live 设置 hook 异步异常逃逸 zone
- **报告**：2026-06-03（emulator app.main 跑设置覆盖 ~29s 未捕获异步错误，Workflow 根因排查）
- **真实性**：✅ 真 bug。`onSettingsChangedLive`/`onLayoutReloadLive` fire-and-forget 丢 Future；await 后 `_controller!.evaluateJavascript` 在 WebView 半销毁时抛 `PlatformException` 无 try/catch → 逃 zone，绕过所有 handler。改 reader 布局设置时若 reader teardown 竞态即触发。
- **[x] ① 已修复** — `a5b046c40` + `972147a8d`（两 hook unawaited+catchError 归 ErrorLogService；4 个 eval 点包 try/catch no-op）
- **[x] ② 已加自动化测试** — `test/reader/reader_live_settings_guard_test.dart`（源码扫描守卫 5 个 ErrorLogService tag + unawaited 在位）
- **备注**：半销毁竞态难确定性复现（reader 含真实 InAppWebView 无法 widget 挂载）；**设备复测待补**（改 reader 设置无逃异常）。

## BUG-004 · 设置页向下滑动会自动跳回上面，得再滑一下
- **报告**：2026-06-03（用户）
- **真实性**：✅ 真 bug。纯触屏快速滚长设置列表，行回收 → `ensureFocus` 被动修复 re-home + `_maybeRevealOnRepair` reveal（居中）与手指方向相反把视口拽回。
- **[x] ① 已修复** — `f6ef60d27`（`_maybeRevealOnRepair` 门控到 `FocusHighlightMode.traditional`；touch 无光标 → 不 reveal）
- **[x] ② 已加自动化测试** — `test/settings/settings_scroll_no_rollback_test.dart`（真实渲染器，本会话补）+ `test/focus/focus_repair_touch_no_scroll_test.dart`（合成核心路径，已有）
- **备注**：本会话写设置专用测试时一度误把 `jumpTo(maxScrollExtent)` 后弹道 clamp 当成 reveal 拽回（懒加载列表 extent 不稳）；诊断确认 Hibiki reveal 门控正常、bug 已修，测试改成先 settle 再验。

## BUG-003 · 阅读器竖排模式下部分文本显示在刘海/notch 区域
- **报告**：2026-06-03（用户）
- **真实性**：✅ 真 bug。竖排翻页轴是 scrollTop，column-gap（页间周期）须含 chrome insets，否则 pitch 比视口矮，上一页尾部漏进顶部刘海条。
- **[x] ① 已修复** — `ee9b2e1f6`（竖排 `column-gap` 含 `--chrome-top/bottom-inset`，pitch==pageHeight）
- **[x] ② 已加自动化测试** — `test/reader/reader_content_styles_test.dart:273-281`「vertical paginated column-gap includes both chrome insets」（CSS 生成器测试，已有，正是此 bug 的回归）
- **备注**：竖排排版的真实像素结果只能设备截图验；本测试守的是「生成的 CSS 契约正确」。

## BUG-002 · 阅读器切章时底栏（bottom chrome）闪烁
- **报告**：2026-06-03（用户）
- **真实性**：✅ 真 bug。底栏可见性原耦合在「每切章翻转」的 `_readerContentReady`，切章瞬间硬卸载再挂回 → 闪烁。另有 spread（漫画双页）路径漏置位缺口。
- **[x] ① 已修复** — `84f1a22af`（门控改 set-once `_hasEverLoaded`）+ `7a8577347`（补 spreadReady 置 `_hasEverLoaded=true`，否则 spread 冷开底栏等 8s）
- **[x] ② 已加自动化测试** — `test/pages/reader_bottom_chrome_gate_static_test.dart`（源码扫描守卫：门控用 `_hasEverLoaded` 不用 `_readerContentReady`、spreadReady 置位、set-once 无复位）
- **备注**：切章无闪/spread 底栏即时出现的真实帧只能设备复测；**设备复测待补**。

## BUG-001 · 给书本打标签后封面展示异常
- **报告**：2026-06-03（用户）
- **真实性**：✅ 真 bug。标签覆盖层 `_adaptiveTagColumn` 用 `Positioned(top,left)`（无 bottom/height）落进封面卡片 `Stack(fit: StackFit.expand)` → 子树拿到 unbounded `maxHeight==infinity` → `(maxHeight*0.55/22).floor()` 抛 `UnsupportedError: Infinity or NaN toInt`；覆盖层只在带 tag 时存在，故只在打 tag 后崩。
- **[x] ① 已修复** — `22b5bafc8`（抽纯函数 `adaptiveTagSlots` 加 `isFinite` 守卫，无界时渲染全部标签）
- **[x] ② 已加自动化测试** — `test/pages/adaptive_tag_column_layout_test.dart`（widget 真约束传播：`Positioned`-in-`StackFit.expand` 不抛 + 封面 sibling 满尺寸；纯函数 infinity/NaN/clamp 单测）
