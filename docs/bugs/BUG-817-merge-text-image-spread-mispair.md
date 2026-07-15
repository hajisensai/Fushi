## BUG-817 · 自动跨页把文本章与固定布局插画章错配成spread导致合并插图失效

- **报告**：2026-07-15（用户：安達としまむら2 手机复现「开启『将插图页并入正文』不生效 + 翻不回去那张插画页」）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/epub/epub_spread_map.dart:250`（`_shouldPairAuto` 的 OPF `_isSpreadPair` 规则未要求两页都是纯图片页）。
- **[x] ① 已修复** — `epub_spread_map.dart:249-258`：OPF page-spread 配对规则加 `book.isImageOnlyChapter(i) && book.isImageOnlyChapter(i+1)` 约束（与下方 rendition:spread / edge-match 规则对齐）。提交见分支 `worktree-reader-merge-spread-mispair`。
- **[x] ② 已加自动化测试** — `hibiki/test/epub/epub_spread_map_test.dart` 新增 `BUG-817: OPF page-spread must NOT pair a reflowable text page with a fixed-layout illustration page`（TDD：撤修复即 `Expected false / Actual true` 失败，含修复后 20 项全绿）。

### 根因

`安達としまむら2`（電撃文庫）是**混合布局**书：正文章是 reflowable（`book-style.css`，如 p-009/p-011），插页插画是固定布局 SVG 页（`fixed-layout-jp.css` + `<svg><image xlink:href="../image/tNNN.jpg"/></svg>`，如 p-010，正文≈0 字符）。其 OPF spine 给**reflowable 文本章**也打了 `page-spread-right`，紧随的固定布局插画章打 `page-spread-left`：

```
p-009  page-spread-right                              （reflowable 正文 3346 字）
p-010  rendition:layout-pre-paginated page-spread-left（SVG 插画 t004.jpg，正文≈0）
p-011  （无 spread 属性）                              （reflowable 正文 クリスマス）
```

`spreadMode='auto'` 下，`_shouldPairAuto` 第一条规则 `_isSpreadPair(a.spreadProperty, b.spreadProperty)`（`epub_spread_map.dart:250` 旧码）**只看 OPF page-spread 属性、不校验两页是否都是纯图片页**，于是把**文本章 p-009 与插画章 p-010 配成畸形「文本+图」spread**。`_mergeImageEntries` 的 `isLeadingImage` 要求 `!entry.isSpread`（`:213`），被 spread 消费的 p-010 不再是「前导单图」→ **merge 永远吸收不到它**（「配对赢过合并」把插画配给了错误的邻居）。表现：

- **功能①**：「将插图页并入正文」对 p-010 完全无效——它既没内联进 p-011，又卡在文本+图 spread 里（滚动模式下图不渲染）→ 用户「没生效」。
- 被吸收章目录/翻页隐藏由 spread 抢占导致 p-010 无独立可达虚拟页 → 用户「翻不回去那张插画页」。
- **功能②（下游）**：音频跨章 `_pauseThroughImageOnlyChapters` 对 p-010 调 `_resolveNavChapter`，因 p-010 未被吸收（在 spread 内）返回自身 → 导航到该畸形 spread 后 `_currentChapter` 停在 p-009 而非 p-011 → `_onCueChanged` 每 tick 命中 `frag.sectionIndex != _currentChapter` 早退（只高亮不 reveal）→「暂停结束后高亮跟、页面不滚」；手动重开跟随经 `snapReaderToAudio → _maybeEmitCrossChapter` 重新对齐到 p-011 才恢复。修复①后 `_resolveNavChapter(p-010)=p-011`，音频路径直接对齐 p-011，功能② 预期随之恢复（待真机复测确认）。

对照：同函数 `rendition:spread`（`:253-256`）与 edge-match（`:261-264`）规则**早已**要求两页都 `isImageOnlyChapter`，唯独 OPF 规则漏了——本修复补齐这个不对称。

### 修复

`_shouldPairAuto` OPF 规则改为：
```dart
if (_isSpreadPair(a.spreadProperty, b.spreadProperty) &&
    book.isImageOnlyChapter(i) &&
    book.isImageOnlyChapter(i + 1)) {
  return true;
}
```
真正的两页插画跨页（两页都 image-only）仍正常配对，无回归（既有「spread pairing wins over merge」测试用两张图，仍绿）。

### 验证

- `flutter test test/epub/` + merged_image 相关：213 项全绿。
- `flutter analyze`：无 issue。
- TDD 红检：`git stash` 撤 lib 修复后 BUG-817 测试 `Expected false / Actual true` 失败。
- **待真机/离屏合成 EPUB 复测**：开合并后 p-010 插画内联到 p-011 顶部可见；有声书跨该插画跟随不失效。**不得用本 dev 构建覆盖用户 release 1.2.0**（schema 更新 → 降级 DROP 毁库红线），真机验证用合成同构 EPUB 或等 CI 出新版。

- **备注**：修复只动 `_shouldPairAuto` 一处判据，影响面 = 混合布局书里被 OPF 错误标注 spread 的文本×图边界。功能② 的独立复测跟进另记。
