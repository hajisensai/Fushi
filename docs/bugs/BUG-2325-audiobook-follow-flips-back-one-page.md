## BUG-2325 · 有声书跟随播放时视口自己退回前一页，下一句又翻回来

- **报告**：2026-09-09（用户录屏 `ee86b45ffce1fd7add2efba0022bff58.mp4` + 当晚 adb 现场复现一次；设备 HiBreak 墨水屏 Android 14，824x1648 @300dpi，app 2.3.0-debug.13961，书=無職転生 21 第 10 节，竖排分页 + 有声书跟随）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/reader/reader_pagination_scripts.dart` 的 `alignToPage`（落页列号函数在列边界上是**零余量**的等号判据）+ `getScrollContext` 的 `pageStep` 与浏览器真实列周期之间**每页累积**的亚像素差。
- **[x] ① 已修复** — `alignToPage` 补**下侧容差 column-gap**（`getScrollContext` 把 gap 挂进 context）；`scrollToCharOffset` 的 `charPage` 改走同一个列号函数（旧实现连相位都没减）；章首落点 `alignContentStartToPage` 刻意不吃容差。见本 PR。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reveal_column_grid_drift_test.dart`（真机几何漂移率下第 1~1900 页列顶首字不得退页 + 去掉容差立刻复现症状 + BUG-1764/875 双向回归锁 + JS 源码三段守卫）。
- **备注**：修复在**真机几何的 headless 真渲染**里验证（修前 30~112 次/章 → 修后 0），**未在物理设备上验证**——本机没有 release 签名 keystore，自建包签名不同，装上去必须先卸载，会连同用户阅读进度一起清掉，故不做。真机复验需等一个带签名的 CI 包。

### 症状（用户可见）

竖排分页 + 有声书跟随播放，读到某一句时**没有任何操作**，视口自己退回上一页；约 1~2 秒后下一句又把它翻回来。退回的那一句无一例外是**句首恰好落在列顶**的句子。

### 真机证据（2026-09-09 现场 adb 抓取）

logcat 里 13 秒窗口内只有两类应用日志，**一一配对、间隔恒定 ~0.9 秒**（reveal → 250ms settle 补刷 → 500ms 去抖落库）：

| 时刻 | 日志 | 视口首字 |
|---|---|---|
| 38.939 / 39.848 | `highlightCue` → `save position … charOffset=5126` | A 页（`しかし、`） |
| 41.142 / 42.035 | `highlightCue` → `save … charOffset=5157` | B 页（`「それで納得されないのであれば、`） |
| 42.762 / 43.655 | `highlightCue` → `save … charOffset=5126` | **退回 A 页** |
| 44.560 / 45.456 | `highlightCue` → `save … charOffset=5157` | 又翻回 B 页 |
| 48.302 / 49.187 | `highlightCue` → `save … charOffset=5218` | 继续前进 |

- `charOffset` 是 `fushiProgressDetails` 第三段 = `getFirstVisibleCharOffset()`（视口首字），所以 5126→5157→5126→5157 是**视口真的在两页之间来回**，不是只有落库数字回退。
- 窗口内**没有** `[FushiInit]`（无章节重载）、**没有** `_syncPageSize`（无重分页），无任何 Dart 异常 —— 能动视口的只剩 JS 落页。
- 本机库 `audio_cues` 实证该段坐标（sentence_index 3255..3262）：`しかし、`5126..5129 / … / `「それで納得されないのであれば、`5157..5171 / `せっかく仲良くなりかけた友人と、`5171..5186 / …。三个落库 charOffset（5126/5157/5233）**恰好等于** cue 的 `ns` 起点，两套坐标同一量纲。退回发生在 B 页**首句**（其首字恰在列顶）那次跟随上。

### 根因

分页落页的唯一列号函数是 `alignToPage`：`floor((anchor − contentStart) / pageStep)`。BUG-875 / BUG-1764 已经给它补过**相位** `contentStart`，但它在列边界上仍是**零余量的等号判据**——而 `pageStep` 与浏览器真实列周期之间存在**每页累积**的亚像素差：

- `getScrollContext` 的 `pageStep` 由 `parseFloat(getComputedStyle(body).columnWidth)` 推出，CSSOM 把 used 值**序列化成 3 位小数字符串**；
- 浏览器排版时把 used 列宽**量化到 LayoutUnit（1/64 px）**。

两者只有在列宽恰好是 1/64 的整数倍时才相等。真机 824x1648 @300dpi → Flutter DPR = 300/160 = **1.875** → CSS 视口高 `1648/1.875 = 878.9333…px`（**小数**）→ used 列宽 `878.9333… − 46 = 832.9333…px` 被量化成 **832.921875px**，而 JS 读到的是 `"832.933px"`：

```
pageStep(JS)   = 832.933    + 22 = 854.933
真实列周期      = 832.921875 + 22 = 854.921875
δ = 0.011125 px / 页（累积）
```

于是第 j 列的真实起始坐标比网格线 `j·pageStep` **低 j·δ**：第 9 页低过 0.1px，第 89 页低近 1px。**列顶首字**的 reveal 锚恰好等于该列真实起始坐标，裸 floor 就把它判进**前一列** → 视口退回上一页；下一句 cue 不在列顶、锚离网格线远，于是又翻回来。整数 CSS 视口（列宽本就是 1/64 倍数）δ=0，所以这条**只在小数 DPR 的设备上现形**——也解释了为什么既有用例、既有探针（都用整数几何）一直全绿。

同一个漂移也打在 `scrollToCharOffset` 上（精确锚恢复 / 样式重锚 commit 落到「页首字」时同样退回前一列），而且那里连相位 `contentStart` 都没减，是独立于本 bug 的旧漏。

### 修复

- `getScrollContext` 把 `column-gap` 挂进 context（`columnGap`）。
- `alignToPage` 改成 `floor((offset − contentStart + gap) / pageSize)`：网格线之前那一段恰好是 column-gap，**里面没有任何内容**（前一列内容盒在 gap 之前就结束了），落进 gap 带的锚只可能是后一列被漂移带下来的列顶字，按「gap 归属后一列」定义列号即可。容差是几何真值 22px（按上面的漂移率能兜约 1900 页），不是拍脑袋的 ε；列内任意位置（含列末最后一像素）仍落本列，BUG-875 / BUG-1764 两个方向都不受影响。
- `scrollToCharOffset` 的 `charPage` 改走 `alignToPage`（同时补上它缺的相位）。
- `alignContentStartToPage`（章首 `minScroll`）**刻意不吃**这条容差：那里的语义是「绝不跳过首行」，吃了容差反而会把首行内容边推进下一列（TODO-1179）。

**没有**去改 `pageStep` 本身：把它量化到 1/64 是 Blink 实现细节、跨引擎不成立；改列周期口径会动到 `paginate` / `minScroll` / 全部恢复落页路径（TODO-753/792 的历史）。漂移在渲染上的另一面（第 845 页时页对齐差约 9.4px）属于那条更深的账，本次不动。

### 验证

真渲染探针：`test/reader/reader_headless_shell_dump_test.dart` 产出的**真引擎** shell + 该章**真实 xhtml 正文**（`p-003.xhtml`，1695 段 / 57697 字）+ 从本机库导出的**该节全部 4026 条真实 cue**（含真实 `ns/ne`），按**真机几何**（DPR 1.875、小数 CSS 视口、column-width 用 calc + CSS 变量让浏览器全精度算）逐句走真 `scrollToRange`：

| 配置（字号 / chrome inset） | 修前退回次数 | 修后 |
|---|---|---|
| 22 / 0 | 30 | 0 |
| 40 / 0 | 81 | 0 |
| 46 / 0 | 81 | 0 |
| 52 / 0 | 101 | 0 |
| 46 / 上18 下56（挤压态，contentStart=18） | 112 | 0 |

对照：同一套数据换成**整数** CSS 视口（824x824、DPR 1~3、字号 42~50、行高 1.5~1.9、含高精度小数边距共 20 组、约 8 万次 reveal）修前修后都是 0 —— 与「δ 只在小数视口下非零」的推导一致。

另：本 PR 分支（基于 upstream/develop）上 `flutter analyze` 全绿，分页相关 14 个测试文件共 150 例全绿。
