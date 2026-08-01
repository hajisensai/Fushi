## BUG-1372 · 歌词底栏预留守卫锚在实现写法上，PR#670 合并 Padding 后 develop 单测红

- **报告**：2026-08-02（用户：巡检发现 develop 单测红，TODO-2585）
- **真实性**：✅ 真 bug（**守卫自身的 bug，不是功能回归**）

### 判据坏，不是功能坏

`test/pages/reader_lyrics_progress_bottom_reserve_static_test.dart:38` 断言
`body.contains('EdgeInsets.only(bottom: _readerBottomReserve)')`。PR#670（`df5745832`，
BUG-1343 macOS 独立文档顶部缩进）把 `_buildBody` 里顶/底两笔留白合成同一个
`EdgeInsets.only(top: …, bottom: lyricsBottomInset)`：

```dart
final double lyricsBottomInset =
    _lyricsMode && _hasEverLoaded && _showChrome ? _readerBottomReserve : 0;
```

**底部预留分毫未变**（同门控、同数值、同样包 `Padding`），只有拼写变了。判别依据：
只改生产代码不碰测试时，同一文件里另两条断言
（`'_lyricsMode && _hasEverLoaded && _showChrome'`、`'Padding('`）**照常通过**，只有那条
字面量断言红——红的是「怎么写」，不是「留没留」。

根因是本仓已定案的 B 类「要求型」锚点失效模式：把契约写成实现拼写，下一次重构必再断。
换个匹配器只是把红往后推一次。

- **根因**：`hibiki/test/pages/reader_lyrics_progress_bottom_reserve_static_test.dart:38`
  （被守对象：`hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:2637` `_buildBody`）

### 修复

- **[x] ① 已修复** — 把契约从「实现写法」抬到纯函数：新增
  `hibiki/lib/src/reader/reader_chrome_floating.dart` 的
  `independentDocumentInsets({lyricsMode, spreadDocumentLoaded, chromeOccupiesLayout,
  bottomReserve, titlebarInset}) -> EdgeInsets`，与既有 `bottomChromeReserve` /
  `topProgressReserve` 同一真相源文件；`_buildBody` 只负责喂状态 + 按结果包 `Padding`。
  零行为变更（顶/底两笔取值与 PR#670 后完全一致）。
- **[x] ② 已加自动化测试** — 同名测试文件重写成两层：
  - **行为层**（6 条）直接钉 `independentDocumentInsets` 的数值契约：歌词 + 底栏占位 ⇒
    `bottom == bottomReserve`；预留高变了留白跟着变（禁硬编码）；底栏未占位 / 正文模式 /
    spread ⇒ `bottom == 0`；BUG-1343 顶部缩进；两笔都 0 ⇒ `EdgeInsets.zero`。
    与写法、参数顺序、包几层 widget 无关。
  - **接线层**（2 条）改用共享 `test/helpers/source_guard.dart` 的 `methodBody` +
    `containsIdentifierCall`（替掉原来 `indexOf(start)`/`indexOf(end,…)` 的字面量切片）：
    `_buildBody` 必须调 `independentDocumentInsets` 且包 `Padding`，且**不得**就地出现
    `EdgeInsets` 构造。

- **变异实测**：
  - 生产纯函数 `bottom:` 改成常量 `0` ⇒ 行为层 2 条红（`FAILED … 2 error events`）。
  - `_buildBody` 绕开纯函数、就地拼 `EdgeInsets.only(top: …, bottom: 0)` ⇒ 接线层 2 条红。
  - 两次均反向替换还原，`git status --short` 干净。

- **备注**：本会话第二次「刚合的 PR 带进一条红」。共同点是复核跑的定向测试没覆盖到扫描本
  PR 改动文件的守卫——`reader_hibiki_page.dart` 被 **155** 个测试文件扫描（`grep -l`），
  改这个文件必须至少跑 `test/pages` + `test/reader`。
