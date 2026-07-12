## BUG-748 · VN居中竖排布局下点击空白翻页永不触发(caret clamp到文字)
- **报告**：2026-07-11（用户：Windows 桌面/手机，「VN 模式好像没办法翻页」）
- **真实性**：✅ 真 bug（Windows 桌面离屏真机复现：289 点网格扫描全视口 0 个 blank 点）。根因 `hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart` 的 `_hoshiVnTapIsBlank`。

### 关系
用户「VN 没法翻页」有两层，同属 VN 交互：
1. **boot-abort 杀掉全部手势注册**（滑动/方向键/鼠标拖拽/点击全废）——见 [BUG-718](BUG-718-vn-restore-charoffset-cloak.md)，已修（手势监听器 `webview.part.dart:877-1027` 在 setup IIFE 里 `cloak.remove()` 之前，boot 抛错会连它们一起中断）。Windows 实测修复后 `paginate('forward')` 581→582、监听器已注册。
2. **本条 BUG-748**：即使手势已注册，VN 的「点击空白翻页」(blank-tap advance) 在居中竖排布局下**永不命中 blank 分支** → 点哪都被判成查词，`paginate` 从不被 tap 触发。滑动/方向键/音量键不受此影响。

### 根因
`_hoshiVnTapIsBlank(x,y)` 靠 `_hoshiReaderCaretRangeAtPoint` = `document.caretPositionFromPoint`/`caretRangeFromPoint`。这两个 API **会把任意点 clamp 到最近的字符边界**（即使点在空白边距）。VN 把一屏一个 Block/句子放进 shrink-to-fit + flex 居中的 `.hoshi-vn-content`，正文只占视口中央一小块、四周全是大片边距；但边距上的 tap 也被 clamp 到最近文字节点 → 旧判据「resolve 到 text node 即非空白」把**整个视口（含边距）都判成词** → blank-tap advance 从不触发。Windows 离屏 289 点网格扫描：**0/289 blank**（居中竖排 caret 全程向文字 clamp）。

### 修复（根因层）
`_hoshiVnTapIsBlank`：拿到 clamp 后的 caret 后，**再对该字符做精确 client-rect 命中测试**——用 `Range` 框住 caret offset（及 offset-1，因 clamp 落在边界）那个字符，`getClientRects()` 取字形盒，判 tap 点 (x,y) 是否真落在盒内（±2px 容差）。落在盒内=真点在字上→非空白（查词）；被 clamp 过去但落在盒外（边距/间隙）=空白→翻页。竖排横排通用（命中测试与书写方向无关）。仅影响 VN blank-tap 判定，查词/其他翻页路径不变。

- **[x] ① 已修复** — `webview.part.dart` `_hoshiVnTapIsBlank` 改用 client-rect 命中测试。提交见分支 `worktree-vn-mask-stale-restore`。
- **[x] ② 已加自动化测试** — 源码守卫 `hibiki/test/reader/vn_blank_tap_hittest_guard_test.dart`：断言 `_hoshiVnTapIsBlank` 用 `getClientRects()` 精确命中（非仅 clamp text-node 判据）。headless WebView 跑不到真实几何，真机 Gate 目视：VN 点边距翻页、点字查词。
- **备注**：与 BUG-718 同批（同一 VN 翻页诉求）。真机手感（galgame 式点击前进）留用户确认是否要「点任意处皆前进」（当前设计=点字查词、点边距前进）。
