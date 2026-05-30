# 词典弹窗字级光标 + 查词自动转移 — 设计规格

- 日期：2026-05-30（继 [reader char caret](2026-05-30-reader-char-caret-navigation-design.md) 之后）
- 范围：词典弹窗 WebView（`assets/popup/`）、`ReaderCaretScripts`、`DictionaryPopupWebView`、`base_source_page`、`reader_hibiki_page`。

## 1. 目标

把字级光标扩展进词典弹窗:手柄/键盘能在弹窗的释义文本里逐字移动焦点,A/Enter 选当前词做深入查询(叠新弹窗),B/Esc 退回上一层。并且**查词打开弹窗时,自动把光标从当前载体转移到新顶层弹窗**,让控制器流程无需额外"进入弹窗"动作。

非目标(本轮):弹窗里 mine/audio/expression/kanji 等非释义按钮的手柄操作(它们不是释义文本,光标限定在 `.glossary-content` 不会落上去)——后续增强。

## 2. 现状关键事实

- 弹窗结果是独立 WebView(`DictionaryPopupWebView` → `InAppWebView` 加载 `assets/popup/popup.html`)。
- 弹窗有自己的 `window.hoshiSelection`(`assets/popup/selection.js`),与阅读器同构但:`selectText(x,y)` 触发 `callHandler('textSelected', text, rect)`;**无 `selectFromPosition`、无 `getNormalizedOffset`、无 `hoshiReader`**。
- 释义文本在 `.glossary-content`;**既有点击逻辑就是「只在 `.glossary-content` 内点击才 `selectText` 深入」**(popup.js:1802)。链接(`.gloss-sc-a`/`.kanji-tag`/`.expression`)走 `onLinkClick`。
- `popupRendered` 是内容就绪钩子(`callHandler('popupRendered', scrollHeight)`)。弹窗栈每层有 `webViewKey: GlobalKey<DictionaryPopupWebViewState>`,可拿到各自 controller。
- 弹窗无 `hoshiReader` → 复用的 `ReaderCaretScripts` 自动走「横排 + 连续滚动」(`_paged()` 返回 false,移动越界时 JS 内部 `scrollIntoView`,永不要求 Dart 翻页)。

## 3. 数据结构

`_caretSurface ∈ {none, reader, popup}`(在 `reader_hibiki_page`)。
- 「活动光标控制器」= `popup` 时为顶层可见弹窗的 controller,否则阅读器 `_controller`。
- 每个 WebView 各有独立 `window.hoshiCaret`,各记各的 `_memNode/_memOffset`。光标永远活在最上层载体;转移跟随弹窗栈。

## 4. 复用:给 `ReaderCaretScripts` 加 `scopeSelector`

光标模块保持通用,新增一个可选 `scopeSelector`:
- `init({scopeSelector})` 设置;`_isStop(node,offset)` 在原有判断基础上,若 `scopeSelector` 非空则额外要求 `node.parentElement.closest(scopeSelector)`,否则不是停靠点。
- 阅读器不传(全文可停);弹窗传 `'.glossary-content'`(只在释义里停,和点击行为一致)。
- 这样同一份光标 JS 跑在两种 WebView,查词都走 `hoshiSelection.selectFromPosition`。

## 5. 弹窗 selection.js 重构

把 `selectText(x,y,maxLength)` 命中后的逻辑抽成 `selectFromPosition(node, offset, maxLength, x, y)`,触发 `callHandler('textSelected', text, rect)`;`selectText` 命中后委托。与阅读器侧重构同构(无 normalized,弹窗无 hoshiReader)。光标 `lookup()` 调 `selectFromPosition(node, offset, 20)`(与点击 maxLength 一致)。

## 6. DictionaryPopupWebView 接入光标

- `initialUserScripts` 在 DOCUMENT_END 注入 `ReaderCaretScripts.source()`(此时 head 的 selection.js 已执行,`hoshiSelection` 就绪;光标源只定义对象,不立即用 DOM)。
- 新增 `DictionaryPopupWebViewState` 公开方法(与既有 `highlightSelection`/`clearSelection` 同模式,在 `_controller` 上 evaluateJavascript):`caretInit(color,insets)`、`caretEnter()`、`caretExit()`、`caretMove(dir)→status`、`caretLookup()`、`caretReanchor(edge)`、`caretRefresh()`、`caretActive()`。
- 新增 `onRendered` 回调:在既有 `popupRendered` handler 里 `widget.onRendered?.call()`,经 DictionaryPopupLayer 透传到 base_source_page。

## 7. base_source_page 钩子

- `_buildPopupLayer` 给每层传 `onRendered: () => onDictionaryPopupRendered(index)`(可被 reader 覆写的空实现)。
- 暴露顶层弹窗 state:`DictionaryPopupWebViewState? get topPopupCaretTarget`(顶层可见层的 `webViewKey.currentState`)。

## 8. reader_hibiki_page 路由与转移

- `_caretSurface` 状态;`_caretMove/_caretTab/_caretLookup/_caretReanchor/_caretRefresh/_enterCaret/_exitCaret` 改为对「活动载体」分发:`popup` → 顶层弹窗 state 的 caret 方法;`reader` → 既有 `_controller` 路径。
- 路由(`_handleKeyEvent`/`_handleGamepadButton`)在 `_caretSurface != none` 时按当前载体执行 CaretAction:
  - 方向键/Tab → move(弹窗永不 pageForward,纯 'moved'/'blocked')。
  - A/Enter → lookup(弹窗 lookup → `textSelected` → 深入查询 → 叠新弹窗 → onRendered 自动把光标转到新顶层)。
  - B/Esc → 若载体是 popup:关顶层弹窗(`_dismissPopupAt(top)`),转移光标到新顶层弹窗或回阅读器;若载体是 reader:既有(关触摸弹窗 / 退出阅读器光标)。
- **自动转移**`onDictionaryPopupRendered(index)`:仅当 `_caretSurface != none` 且该层是顶层时——退出上一载体光标(隐藏旧环),`_caretSurface=popup`,在该弹窗 `caretInit` + `caretEnter`(落到首个释义可见字)。
- **back-transfer**:顶层弹窗关闭后,若还有父弹窗 → 转到它(`caretEnter` 恢复其记忆位置);否则 `_caretSurface=reader`,阅读器 `caretEnter`(恢复阅读器记忆位置)。
- 纯触摸用户:从不进入光标模式 → `_caretSurface==none` → 弹窗渲染不激活光标,行为不变。

## 9. 测试

- 单测:`scopeSelector` 过滤在 `ReaderCaretScripts.source()` 的存在性断言;selection.js 重构后弹窗资源含 `selectFromPosition` 并触发 `textSelected`(若有资源字符串测试)。
- 集成(模拟器真实 DOM，`integration_test/reader_popup_caret_test.dart`，已通过）：内存生成 Yomitan 词典 → 阅读器进入光标（surface=reader）→ 查词打开弹窗 WebView → **断言同一 caret 模块（`window.hoshiCaret` 的 init/enter/move/lookup）已注入弹窗、`hoshiSelection.selectFromPosition` 到位**。
- `flutter analyze` + `flutter test` 全绿（1500+）。

### 验证范围说明（诚实记录）

光标**转移端到端腿**（弹窗接管光标 → 释义内导航 → B/Esc 逐层回退）在 `flutter drive` 下**无法自动跑**：词典弹窗自身的渲染脚本 `popup.js`（~70KB）在该环境下不经 `<script src>` 执行（`dict-media.js`/`selection.js`/我们注入的 caret 都正常加载，但 `window.renderPopup` 未定义），弹窗渲染不出 `.glossary-content` 供光标落点，且弹窗 controller 上的写/桥 eval 不稳定。这是**词典弹窗在测试环境的既有限制，与本特性无关**。因此：
- 集成测试验证「caret + selectFromPosition 已正确注入弹窗 + 查词打开弹窗」这一**新集成点**；
- 转移状态机（`CaretSurface`）是纯 Dart，由 Opus code review 覆盖；
- caret 自身的真实 DOM 行为（enter/move/竖排/lookup/ring）由 `reader_caret_test.dart` 在真机 WebView 上证明（同一模块）。
