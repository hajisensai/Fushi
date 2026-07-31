## BUG-1264 · 每本词典的折叠开关对前 N 本无效（被自动展开覆盖）

- **报告**：2026-07-31（用户：截图圈出词典管理里两本已折叠的词典，「这里折叠了没用。还是会展开」）
- **真实性**：✅ 真 bug，根因 `hibiki/assets/popup/popup.js:3007`（修复前）

### 现象

在「词典管理」里把某本词典按行首开关设为折叠后，查词弹窗里该词典的释义块仍然是展开的，
折叠开关像是没有生效。

### 根因

展开判定把「批量默认」排在了「显式决定」前面：

```js
// 修复前 popup.js:3007
if (autoExpanded || (!window.collapseDictionaries && !perDictCollapsed)) {
    details.open = true;
}
```

`autoExpanded`（= `dictIdx < autoExpandCount(totalDicts)`，见 `autoExpandCount()`）一旦为真就短路，
`perDictCollapsed` 根本不参与判断。也就是说：**落在自动展开区里的词典，每本折叠开关是空操作**。

自动展开区不是一本，是 `popup_auto_expand_dictionaries`（行数）×
`popup_dictionary_columns`（列数，经 `effectiveDictColumns()` 视口收敛并按该词条卡片数封顶）。
报告用户的生产库实测偏好是 **3 行 × 3 列 = 前 9 本**，且 `dictionary_metadata` 里 20 本 term 词典
`collapsed_languages_json` 全是 `["ja"]`（即全部设了折叠）、`collapse_dictionaries = true`。
于是前 9 本无论点多少次折叠都照常展开 —— 完全对上用户描述。

数据结构层面的错误是**优先级定反**：`collapsedDictionaryNames` 是用户对某一本的显式决定
（词典管理里一行一点），`autoExpandRows` 是给「没有任何显式决定的词典」用的批量默认值。
批量默认压过显式决定，显式开关就必然在该区间内失效。

注入链本身没有问题（`popup_settings_injection.dart:571-574` 按 `Dictionary.isCollapsed` 生成名单，
`toggleDictionaryCollapsed` 直接改内存对象并持久化），所以不是丢状态、不是名字失配。

### [x] ① 已修复

`popup.js` 三镜像（app popup / 扩展 assets 镜像 / 扩展 tools 镜像）统一改为显式决定短路：

```js
if (!perDictCollapsed && (autoExpanded || !window.collapseDictionaries)) {
    details.open = true;
}
```

- 标了折叠的词典：永不自动展开（`<details>` 仍可手动点开，不影响随时查看）。
- 没标折叠的词典：行为与修复前完全一致（落在自动展开区就展开，或全局折叠关时展开），
  即从不碰折叠开关的老用户零改变。

### [x] ② 已加自动化测试

- 行为级（Node 真执行 `createGlossarySection`）：`hibiki/test/pages/popup_auto_expand_dictionaries_test.js`
  新增一组断言 —— 3 行 × 3 列 下 idx0 / idx4 标了折叠必须 `open === false`；同批未标折叠的词典
  在 idx0 / idx8 仍展开、idx9 仍折叠；全局折叠关时标记同样生效；rows=0 未标记仍折叠。
- 源码级三镜像守卫：`hibiki/test/pages/popup_auto_expand_dictionaries_test.dart` 新增
  `per-dictionary collapse outranks auto-expand (three mirrors)`，从 `createGlossarySection`
  **函数体内**取样（不扫全文），避免注释里复述表达式造成假绿。

变异实测（两轮，均按预期变红后恢复变绿）：
1. 把判定改回修复前写法 → `per-dict collapsed beats auto-expand at idx0` 断言失败（true !== false）。
2. 把判定改成 `!perDictCollapsed && false`（过度折叠）→ 未标记词典的展开断言失败。

### 备注

- 三镜像必须同改，否则浏览器扩展里的弹窗与 app 内弹窗行为漂开。
- 全局查词浮窗（Windows native 裸 WebView2）加载的是同一份 `assets/popup/popup.js`，一并覆盖。
