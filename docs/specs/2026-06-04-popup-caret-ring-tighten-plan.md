# 词典弹窗字级光标焦点环贴合控件 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 词典弹窗里字级光标（`window.hoshiCaret`）停在交互控件（♪/+ 按钮、折叠词典段 `summary` 行等元素停靠点）时，把焦点环从"整个元素 border box"改成"贴合可见内容（ink）"，并排除可见内容为空的退化元素，消除截图里"空角丸方框/细高竖条/与图标错位"的怪异焦点。

**Architecture:** 当前文字停靠点用 `_charRect`（紧贴单字形），而元素停靠点用 `el.getBoundingClientRect()`（含 padding/行盒/transform 的整盒）。两者不对称是怪异之源。新增两个 JS helper：`_elInk(el)`（元素自身内容的 client rects 并集 = 可见 ink）与 `_elRect(el)`（优先 ink，clamp 到 border box，无 ink 回退 box），把所有元素停靠点的 rect 读取统一路由过去；并在 `_interactiveEls` 丢弃"无 ink 且非图片"的空 wrapper。保留手柄/键盘能停到这些控件的设计意图（用户已确认只改观感、不改可达性）。

**Tech Stack:** Dart（`ReaderCaretScripts.source()` 内嵌 JS 字符串）；测试走项目既有"源码扫描守卫"层（`reader_caret_scripts_test.dart` 断言 JS 源串含特定代码形态）；几何真值靠真机肉眼复测（项目验证纪律）。

**唯一改动文件：** `hibiki/lib/src/reader/reader_caret_scripts.dart`（JS 源串）+ `hibiki/test/reader/reader_caret_scripts_test.dart`（守卫测试）+ `docs/BUGS.md`（BUG-017）。`popup.js`/`popup.css` 不动。

---

## File Structure

- `hibiki/lib/src/reader/reader_caret_scripts.dart` —— 在 `source()` 的 JS 对象里新增 `_elInk`/`_elRect`，并改 5 处元素 rect 读取点（`_stopRect` / `_anchorRect` / `_interactiveEls` 过滤 / `_collectVisibleStops` 元素分支 / `refresh`）。
- `hibiki/test/reader/reader_caret_scripts_test.dart` —— `ReaderCaretScripts.source contract` 组内追加 3 条守卫断言。
- `docs/BUGS.md` —— 追加 BUG-017，记根因 `file:line`、① 修复哈希、② 测试文件。

> 注：`_elInk`/`_elRect` 返回的是普通对象，含 `left/top/right/bottom/width/height` 六个字段，与 `getBoundingClientRect()` 的下游用法（`_drawRing`/`_inViewport`/`_geomMove`/`_lineMove`/`_rectJson`/`_collectVisibleStops` 的 `cx/cy`）完全兼容——已逐一核对所有消费者只用这六个字段。

---

### Task 1: 写守卫测试（失败先行）

**Files:**
- Test: `hibiki/test/reader/reader_caret_scripts_test.dart`（在 `group('ReaderCaretScripts.source contract', ...)` 末尾、`scopeSelector` 那条 test 之后追加）

- [ ] **Step 1: 追加 3 条失败断言**

在该 group 内 `test('scopeSelector restricts stops ...')` 之后追加：

```dart
    test('element-stop ring hugs visible ink, not the full border box', () {
      // 元素停靠点（弹窗 ♪/+ 按钮、折叠词典段 summary）必须把焦点环画在元素的
      // 可见内容 rect（_elRect → _elInk：内容 client rects 并集，clamp 到 border
      // box）上，而不是 el.getBoundingClientRect()——后者含 padding/行盒/transform，
      // 渲染成比字形大且错位的空盒子。(BUG-017)
      expect(js, contains('_elInk:'));
      expect(js, contains('_elRect:'));
      expect(js, contains('selectNodeContents'));
      expect(js, contains('getClientRects'));
    });

    test('element stops route ring + geometry through _elRect (no raw box)', () {
      // _stopRect 与 _anchorRect 必须经 _elRect 取元素 rect，使焦点环、命中测试、
      // 方向几何都用收紧后的可见 rect。
      expect(js, contains('if (stop.el) return this._elRect(stop.el);'));
      expect(
        js,
        contains(
            'if (this.el && document.contains(this.el)) return this._elRect(this.el);'),
      );
    });

    test('empty clickable wrappers are not element stops (ink or image only)',
        () {
      // 无文字 ink 且非替换元素（图片）的 clickable 是空 wrapper，必须跳过，
      // 焦点环不得落在空白盒子上；图片本身无文字 ink，其 border box 即内容。
      expect(js, contains('!this._elInk(e)'));
      expect(js, contains('picture, video, canvas, svg'));
    });
```

- [ ] **Step 2: 跑测试确认失败**

Run（用项目 Flutter 3.44.0 工具链，在 `hibiki/` 下）：
```
flutter test test/reader/reader_caret_scripts_test.dart --no-pub
```
Expected: 3 条新断言 FAIL（`_elInk:`/`_elRect:` 等子串尚不存在）。

- [ ] **Step 3: 提交失败测试**
```bash
git add hibiki/test/reader/reader_caret_scripts_test.dart
git commit -m "test(reader): popup caret element ring must hug visible ink (BUG-017, red)"
```

---

### Task 2: 新增 `_elInk` / `_elRect` helper

**Files:**
- Modify: `hibiki/lib/src/reader/reader_caret_scripts.dart`（在 `_charRect` 之后、`// ── Interactive element stops ──` 注释块之前插入；约现 line 247 之后）

- [ ] **Step 1: 插入两个 helper**

紧接 `_charRect: function(node, offset) {...},`（现 line 235-247）之后插入：

```javascript
  // ── Element-stop ink rect ──────────────────────────────────────────
  // _elInk: the union of an element's OWN content client rects (text glyphs /
  // inline children), i.e. the visible ink — the ♪/+ glyph, the dict-label
  // text. Pseudo-elements (a summary's ▶ ::before) are not in the Range and are
  // intentionally excluded. Returns null when the element has no own text/inline
  // ink (an <img>, or a truly empty wrapper).
  _elInk: function(el) {
    var range = document.createRange();
    try { range.selectNodeContents(el); } catch (e) { return null; }
    var rects = range.getClientRects();
    var L = Infinity, T = Infinity, R = -Infinity, B = -Infinity, found = false;
    for (var i = 0; i < rects.length; i++) {
      var r = rects[i];
      if (r.width <= 0 || r.height <= 0) continue;
      found = true;
      if (r.left < L) L = r.left;
      if (r.top < T) T = r.top;
      if (r.right > R) R = r.right;
      if (r.bottom > B) B = r.bottom;
    }
    if (!found) return null;
    return { left: L, top: T, right: R, bottom: B, width: R - L, height: B - T };
  },
  // _elRect: rect for an element stop's ring / geometry. Prefer the visible ink
  // (clamped to the border box so a descendant overflow can't paint outside),
  // falling back to the border box for ink-less stops (images fill their box).
  // The element-stop analogue of _charRect for text stops, so element rings hug
  // their glyph/label instead of a padded, line-box-tall, transform-shifted box.
  _elRect: function(el) {
    var box = el.getBoundingClientRect();
    var ink = this._elInk(el);
    if (!ink) return box;
    var left = Math.max(ink.left, box.left);
    var top = Math.max(ink.top, box.top);
    var right = Math.min(ink.right, box.right);
    var bottom = Math.min(ink.bottom, box.bottom);
    if (right <= left || bottom <= top) return box;
    return { left: left, top: top, right: right, bottom: bottom,
             width: right - left, height: bottom - top };
  },
```

- [ ] **Step 2: 不单独跑测试**（helper 尚未被调用，行为未变；Task 3 接线后统一验证）。继续 Task 3。

---

### Task 3: 把 5 处元素 rect 读取点路由到 `_elRect`，并丢弃空 wrapper

**Files:**
- Modify: `hibiki/lib/src/reader/reader_caret_scripts.dart`

- [ ] **Step 1: `_stopRect` 改用 `_elRect`**（现 line 333-336）

把：
```javascript
  _stopRect: function(stop) {
    if (stop.el) return stop.el.getBoundingClientRect();
    return this._charRect(stop.node, stop.offset);
  },
```
改为：
```javascript
  _stopRect: function(stop) {
    if (stop.el) return this._elRect(stop.el);
    return this._charRect(stop.node, stop.offset);
  },
```

- [ ] **Step 2: `_anchorRect` 改用 `_elRect`**（现 line 337-341）

把：
```javascript
  _anchorRect: function() {
    if (this.el && document.contains(this.el)) return this.el.getBoundingClientRect();
    if (this.node && document.contains(this.node)) return this._charRect(this.node, this.offset);
    return null;
  },
```
改为：
```javascript
  _anchorRect: function() {
    if (this.el && document.contains(this.el)) return this._elRect(this.el);
    if (this.node && document.contains(this.node)) return this._charRect(this.node, this.offset);
    return null;
  },
```

- [ ] **Step 3: `_interactiveEls` 用 `_elRect` 过滤 + 丢弃空 wrapper**（现 line 316-331 的循环体）

把：
```javascript
    var marked = document.body.querySelectorAll('[data-hoshi-clk]');
    var out = [];
    for (var i = 0; i < marked.length; i++) {
      var e = marked[i];
      var r = e.getBoundingClientRect();
      if (r.width < 6 || r.height < 6) continue; // skip degenerate/sliver elements
      // Prefer the innermost control: a clickable that wraps another clickable is
      // a container — descend so the ring lands on the real icon/button — unless
      // it is an atomic disclosure/control we always want whole (summary/role).
      if (!e.matches('summary, [role="button"], [role="link"]') &&
          e.querySelector('[data-hoshi-clk]')) {
        continue;
      }
      out.push(e);
    }
    return out;
```
改为：
```javascript
    var marked = document.body.querySelectorAll('[data-hoshi-clk]');
    var out = [];
    for (var i = 0; i < marked.length; i++) {
      var e = marked[i];
      var r = this._elRect(e);
      if (r.width < 6 || r.height < 6) continue; // skip degenerate/sliver elements
      // A clickable with no visible ink and no replaced content (image) is an
      // empty wrapper — skip it so the ring never lands on a blank box. Images
      // legitimately have no text ink; their border box IS their content.
      if (!this._elInk(e) &&
          !e.matches('img, picture, video, canvas, svg, [role="img"]')) {
        continue;
      }
      // Prefer the innermost control: a clickable that wraps another clickable is
      // a container — descend so the ring lands on the real icon/button — unless
      // it is an atomic disclosure/control we always want whole (summary/role).
      if (!e.matches('summary, [role="button"], [role="link"]') &&
          e.querySelector('[data-hoshi-clk]')) {
        continue;
      }
      out.push(e);
    }
    return out;
```

- [ ] **Step 4: `_collectVisibleStops` 元素分支用 `_elRect`**（现 line 421-431）

把：
```javascript
    var els = this._interactiveEls();
    for (var k = 0; k < els.length; k++) {
      var er = els[k].getBoundingClientRect();
      if (this._inViewport(er)) {
```
改为：
```javascript
    var els = this._interactiveEls();
    for (var k = 0; k < els.length; k++) {
      var er = this._elRect(els[k]);
      if (this._inViewport(er)) {
```

- [ ] **Step 5: `refresh` 的元素分支用 `_elRect`**（现 line 831-833）

把：
```javascript
    if (this.el && document.contains(this.el)) {
      var er = this.el.getBoundingClientRect();
      if (this._inViewport(er)) { this._drawRing(er); return { ok: true, rect: this._rectJson(er) }; }
```
改为：
```javascript
    if (this.el && document.contains(this.el)) {
      var er = this._elRect(this.el);
      if (this._inViewport(er)) { this._drawRing(er); return { ok: true, rect: this._rectJson(er) }; }
```

- [ ] **Step 6: 跑守卫测试确认转绿**

Run（`hibiki/` 下）：
```
flutter test test/reader/reader_caret_scripts_test.dart --no-pub
```
Expected: 全绿（含 Task 1 的 3 条新断言）。

- [ ] **Step 7: dart format + 全量回归**

Run（`hibiki/` 下）：
```
dart format lib/src/reader/reader_caret_scripts.dart test/reader/reader_caret_scripts_test.dart
flutter test --no-pub
```
Expected: 全量绿、无回归（重点关注 `test/reader/`、`test/shortcuts/reader_caret_router_test.dart`、`test/pages/reader_caret_long_press_static_test.dart`）。

- [ ] **Step 8: 提交实现**
```bash
git add hibiki/lib/src/reader/reader_caret_scripts.dart hibiki/test/reader/reader_caret_scripts_test.dart
git commit -m "fix(reader): popup caret ring hugs control ink, not full element box (BUG-017)"
```

---

### Task 4: 记录 BUG-017

**Files:**
- Modify: `docs/BUGS.md`（在 `## BUG-016` 之前插入 `## BUG-017`，编号倒序在最上）

- [ ] **Step 1: 追加 BUG-017 条目**（把 `<hash>`/测试结果按实际填好）

```markdown
> 注：develop 已有别件 BUG-017（歌词模式放大溢出），本条最终采番 **BUG-018**。

## BUG-018 · 词典弹窗字级光标焦点环落在空盒子/细条上（与图标错位）
- **报告**：2026-06-04（用户，附两张截图：teal 焦点环一处是分隔线附近的细高竖条、一处是 ♪/+ 按钮上方的空角丸方框）。
- **真实性**：✅ **真 bug（焦点环几何与可见内容不对称）**。弹窗里字级光标（`window.hoshiCaret`，`reader_caret_scripts.dart`）按设计会停在交互控件上让手柄可达（`7abc0a92b`）。但**文字停靠点**用 `_charRect`（紧贴单字形），**元素停靠点**却用 `el.getBoundingClientRect()`（含 padding/行盒/`transform` 的整盒）：`_stopRect:334`、`_anchorRect:338`、`_interactiveEls:320`、`_collectVisibleStops:423`、`refresh:832`。后果——折叠词典段 `summary.dict-label`（`display:inline`、10px、半透明、▶ 是 `::before`）框成稀疏细条；`.audio-button`/`.mine-button`（`font-size:18px` 行盒 + flex 居中 + `translateY`）框成比 ♪/+ 大且上移的空角丸方框（`border-radius:3px` 来自焦点环 `:636`）。根因 = 元素停靠点的环用整盒、与文字停靠点不对称，且未排除可见内容为空的退化元素。
- **[x] ① 已修复** — `<hash>`（新增 `_elInk`（元素自身内容 client rects 并集 = 可见 ink，排除 ::before 伪元素）与 `_elRect`（优先 ink、clamp 到 border box、无 ink 回退 box），把上述 5 处元素 rect 读取统一路由过去；`_interactiveEls` 丢弃"无 ink 且非 img/picture/video/canvas/svg/[role=img]"的空 wrapper。保留控件可达性，只收紧环几何——消除不对称而非删停靠点）。
- **[x] ② 已加自动化测试** — `test/reader/reader_caret_scripts_test.dart` 源码扫描守卫 3 条：环走 `_elInk`/`_elRect`/`selectNodeContents`/`getClientRects`；`_stopRect`/`_anchorRect` 经 `_elRect`；空 wrapper（`!this._elInk(e)` 且非图片）被排除。谁把元素环改回裸 `getBoundingClientRect()` 即红。全量 `flutter test` <N> 绿无回归。
- **备注**：reader/WebView 几何类。代码 + 单测已绿；几何真值（环是否真贴合 ♪/+ 与 summary 文字、不再有空盒子/细条）需**真机肉眼复测**原始失败路径（开词典弹窗 → 手柄/键盘进字级光标 → 方向键停到 ♪/+ 与折叠词典段，确认环贴字形/标签）——待用户后补。
```

- [ ] **Step 2: 文档自检 + 提交**
```bash
git diff --cached --check
git add docs/BUGS.md
git commit -m "docs(bugs): record BUG-017 popup caret ring hugs control ink"
```

---

### Task 5: 代码审查（opus）

- [ ] **Step 1: 派生 code-reviewer 子代理审查本轮改动，`model: "opus"`**（项目硬性规则：review 必须走 opus）。审查重点：
  - `_elInk` 的 Range/getClientRects 并集是否正确、`selectNodeContents` 在 detached/异常节点是否安全（已 try/catch 回退 null）；
  - `_elRect` clamp 后退化（right<=left）回退 box 是否覆盖所有边界；
  - 5 处接线是否都改到、下游六字段消费是否仍兼容；
  - 空 wrapper 丢弃规则是否会误杀合法控件（纯图标 SVG/canvas 按钮已在白名单）；
  - 是否破坏既有契约（reader 分支 `window.hoshiReader` 下 `_interactiveEls` 仍走 `img.block-img`，未经 `_elRect` 改写——确认 reader 路径行为不变）。
- [ ] **Step 2: 审查若有 Critical/Warning → 修复后重提审查；通过后结束。**

---

## 真机验证（项目纪律，必做，非阻塞合并但必须留证据/标注待补）

reader/WebView 类修复：代码正确 + 单测无回归后，仍须真机肉眼复测原始失败路径——
开词典弹窗 → 手柄/键盘进字级光标 → 方向键停到 ♪/+ 按钮与折叠词典段 `summary` →
确认焦点环贴合 ♪/+ 字形与 summary 标签文字，不再出现空角丸方框 / 分隔线附近细高竖条。
设备见 `docs/agent/integration-testing.md`（模拟器 / Windows 离屏 / Mac 跨机）。证据留 `.codex-test/`。

---

## Self-Review

1. **Spec coverage**：用户决策"收紧焦点环贴合控件"——Task 2（`_elInk`/`_elRect`）+ Task 3（5 处接线 + 丢空 wrapper）完整覆盖；保留可达性（未删停靠点逻辑）✓。
2. **Placeholder scan**：BUG-017 的 `<hash>`/`<N>` 是提交后回填的真实值，非占位逻辑；其余步骤均含完整代码/命令 ✓。
3. **Type/命名一致**：`_elInk`/`_elRect` 在 Task 2 定义、Task 3 调用、Task 1/Task 4 引用，名称一致；返回对象六字段与所有下游消费者一致（已核对 `_drawRing`/`_inViewport`/`_geomMove`/`_lineMove`/`_rectJson`/`_collectVisibleStops`）✓。
