## BUG-2382 · 悬浮顶部工具栏压住正文首行（小窗/分屏下暴露）
- **报告**：2026-09-09（用户：截图，手机小窗/分屏下的阅读界面；后续澄清「是顶部工具栏，
  上面还有文字，上面应该是空的」）
- **真实性**：✅ 真 bug，根因 `fushi/lib/src/reader/reader_desktop_chrome.dart:56-64`
  （修复前）+ `fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart:2224-2225`

  顶部工具栏 `ReaderDesktopHeader`（固定高 `kReaderDesktopHeaderHeight` = 48，
  `reader_desktop_chrome.dart:27`）在**悬浮态**下画成
  `Positioned(top: _stableTopInset)` 的**不透明**叠层（背景 `_themeBackgroundColor()`，
  `chrome.part.dart:2243`）；而正文 WebView 是 `Positioned.fill`，内容盒顶部
  = `marginTop` + `--chrome-top-inset`（`reader_content_styles.dart:947`）。

  悬浮态下 `readerDesktopHeaderReserve(... floating: true)` **恒返回 0**，于是
  `_readerTopOffset = _stableTopInset + 0 + 0`（`reader_fushi_page.dart:2087-2088`），
  `--chrome-top-inset == _stableTopInset`。**工具栏与正文内容盒起点相同**，
  那 48px 整条压在正文首行上。`floating` 取自 `_bottomBarFloating`
  = `tapEmptyToHideChrome`，**默认 true**（`reader_fushi_source.dart:1427`），
  即默认配置就命中。

  **与分屏/小窗无关**（这一点靠实测推翻了最初的假设）。修复前实测：

  | 平台 | vpTop | cssInset | firstTop | OVERLAP | ABOVE_BAR | insetMismatch |
  |---|---|---|---|---|---|---|
  | Android API34 全屏 | 49.45 | 49.45 | 49.45 | **48.01** | 0.01 | 0.00 |
  | Windows 桌面 | 0 | 0 | 0 | **48.0** | — | 0 |

  两端都是满 48px 重叠。小窗只是让它更刺眼——可读行数本就少，被吃掉一行占比大得多。
  另注：`insetMismatch = 0`，说明 Flutter 侧与 WebView 侧的 inset **是同步的**，
  「推送被丢弃导致 CSS 停在旧值」这条曾被怀疑的路径**未被证实**（`_applyChromeInsets`
  确实会在内容未就绪时早返回丢弃，但 BUG-467 加的 `_reapplyChromeInsetsAfterFirstLoad`
  在每条就绪路径上都补下发，实测收敛）。

- **[x] ① 已修复** — 删掉 `readerDesktopHeaderReserve` 里的 `floating → 0` 特例
  （连同 `floating` 参数一起删，消除该分支而非增加条件）：占位即预留工具栏高。
  该特例是顶栏引入时（`afdf667e6e`，2026-09-06）照抄底栏/顶部进度悬浮模型的结果，
  commit message 只写机制、从未论证顶栏为何适用；而顶栏与那两者的关键差异是
  **48px 且不透明**（顶部进度只有 18px 且是半透明毛玻璃，见 BUG-547/BUG-843；
  底栏同样不透明但压的是页尾留白）。

  **「悬浮显隐不重锚」的设计律未被破坏**（`reader_chrome_floating.dart:9-13`）：
  悬浮态的显隐走 `_handleFloatingChromeReveal`，**从不翻转 `_showChrome`**，故
  `barOccupiesLayout` 在悬浮态恒定 ⇒ 预留值恒定 ⇒ 唤出/收起不改 inset、不 reflow、
  不重锚。被去掉的只有「正文可以被盖」这一条——那从来不是悬浮态的收益，是它的代价。

  **代价（需知悉）**：悬浮态下正文顶部恒定让出 48px。这是"不被遮挡"的必要代价：
  若要既满屏又不遮挡，只能改成「唤出时用 CSS transform 整体下移、收起还原」
  （不 reflow、不重锚，锚点走 `getBoundingClientRect` 会自动跟随），成本更高，未采用。

  修复后实测（Android API34）：cssInset 49.45→97.45，正文首行落在工具栏下沿
  （firstTopLogical 97.44 vs header.bottom 97.45），`OVERLAP=0.01`、
  `ABOVE_BAR=-47.99`（负值 = 工具栏那条带是空白的）。

- **[x] ② 已加自动化测试** —
  - `fushi/integration_test/reader_header_overlap_bug2381_itest.dart`（新增）：真 app +
    真 WebView，量工具栏下沿与正文首行上沿的重叠逻辑 px，并断言工具栏**上方**不露出
    正文。DOM→逻辑坐标缩放比由 `webViewRect.height / documentElement.clientHeight`
    **实测**得出（不假设 1:1）。多次采样还钉住「显隐不改 `--chrome-top-inset`」。
    三端可跑（Android 模拟器 / Windows 离屏 runner / Mac）。
  - `fushi/test/reader/reader_desktop_chrome_test.dart`：改为钉「占位即预留」+ 新增
    「同一 barOccupiesLayout 下返回值恒定（显隐不改预留高）」。
  - `fushi/integration_test/reader_chrome_floating_itest.dart` goal2：原断言
    「悬浮 ⇒ `--chrome-top-inset == 0`」会把顶栏预留与进度条预留混成一个数，改为钉
    **差值**——把顶部进度切悬浮应当且仅应当回收进度条那 18px。

- **备注**：
  - **不是 BUG-843 的重复**。BUG-843 修的是顶部进度 **pill**（18px、毛玻璃半透明），
    并明文写「悬浮态 pill 浮在正文上自动收起**属设计内**」。那条「设计内」的前提是
    *小且半透明*；换成 48px **不透明**工具栏后前提不再成立。
  - 用户报告里的「工具栏上方还有文字」在**全屏实测中未复现**（`ABOVE_BAR=0.01`）。
    受限于本机模拟器（API36 AVD 的 surfaceflinger 在 `RegionSampling` 反复 SIGABRT；
    `am task resize` 只能把任务推进沉浸式全屏、拿不到真 freeform 小窗），**真小窗
    形态未能取证**。修复后 `ABOVE_BAR` 变为 -47.99，即便小窗下仍有残余不同步，
    可见症状也会被这 48px 让位吸收掉。若用户复测仍见上方露字，需在真机小窗补测
    `viewPadding.top` 与 `--chrome-top-inset` 的差值。
