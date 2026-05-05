# 词典弹窗修复计划

日期：2026-05-05
关联 issue：https://github.com/hdjsadgfwtg/hibiki/issues/1

## 概览

修复词典弹窗的 4 个问题：
1. 例文折叠点击误触发查词（Bug）
2. 图片显示优化
3. Per-dictionary collapse 传递给 WebView
4. Kanji 词典支持

---

## Task 1: 例文折叠点击误触发查词

### 根因

`popup.js:1646-1665` 的 click handler 中，点击 `.glossary-content` 区域无条件调用 `hoshiSelection.selectText()`。structured content 中的 `<details><summary>`（如"例文 x 件"）和 `<a href>` 链接的点击都会被拦截，导致本应展开折叠的操作变成了查词。

### 修复方案

在 `popup.js:1660` 的 `if (target?.closest('.glossary-content'))` 分支内，添加前置检查：

```js
// 不拦截 <summary> 点击（让浏览器原生 toggle details）
if (target?.closest('summary')) return;
// 不拦截 <a> 链接点击（已有 onclick handler）  
if (target?.closest('a[href]')) return;
```

### 涉及文件

- `hibiki/assets/popup/popup.js` — click handler (~line 1660)

---

## Task 2: 图片显示优化

### 现状

图片宽度用 `Math.min(naturalWidth, windowWidth - 20)` 做了基础适配，但：
- 大图没有最大高度限制，会撑满弹窗
- 图片不能点击查看原图

### 修复方案

**CSS 层面：**
- `.gloss-image-container img` 加 `max-height: 40vh; object-fit: contain`
- 确保窄屏下图片不溢出

**JS 层面：**
- 图片点击时创建全屏 overlay（`position: fixed; z-index: 9999`），显示原图
- overlay 点击关闭
- 不需要 pinch-to-zoom（弹窗内操作空间有限，先做简单版）

### 涉及文件

- `hibiki/assets/popup/popup.css` — 图片样式
- `hibiki/assets/popup/popup.js` — `createDefinitionImage()` (~line 586) 加点击事件

---

## Task 3: Per-dictionary collapse 传递给 WebView

### 现状

- Dart 侧：`Dictionary.collapsedLanguages` + `toggleDictionaryCollapsed()` 完整实现
- WebView 侧：只接收 `window.collapseDictionaries`（全局 boolean）
- `popup.js:1335` 只看全局开关，不知道哪些词典被单独标记折叠

### 修复方案

**Dart 侧 (`dictionary_popup_webview.dart`)：**
```dart
final collapsedNames = appModel.dictionaries
    .where((d) => d.isCollapsed(appModel.targetLanguage))
    .map((d) => d.name)
    .toList();
final collapsedJson = jsonEncode(collapsedNames);
// 传给 JS
window.collapsedDictionaryNames = $collapsedJson;
```

**JS 侧 (`popup.js:1333-1337`)：**
```js
function createGlossarySection(dictName, contents, isFirst, entryIdx) {
    const details = el('details', { className: 'glossary-group' });
    const perDictCollapsed = (window.collapsedDictionaryNames || []).includes(dictName);
    if ((!window.collapseDictionaries && !perDictCollapsed) || isFirst) {
        details.open = true;
    }
    // ...
}
```

逻辑：
- 全局折叠开 → 除第一个外全折叠（现有行为）
- 全局折叠关 → 只折叠在 `collapsedDictionaryNames` 列表中的词典
- 第一个词典永远展开

### 涉及文件

- `hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart` — 传递 collapsed 名单
- `hibiki/assets/popup/popup.js` — `createGlossarySection()` 消费名单

---

## Task 4: Kanji 词典支持

### 现状

- `DictionaryType` 只有 `term / frequency / pitch`
- 导入器（C++ `importer.cpp`）只识别 `term_bank_` 和 `term_meta_bank_`
- Yomitan kanji 词典使用 `kanji_bank_*.json` 格式，结构与 term 不同

### Yomitan kanji_bank 格式

```json
[
  ["漢", "onyomi", "kunyomi", "tags", ["meaning1", "meaning2"], {"stats": {}}]
]
```

字段：character, onyomi, kunyomi, tags, meanings, stats

### 修复方案

**Step 1: 类型扩展**
- `dictionary.dart:5` — `DictionaryType` 加 `kanji`

**Step 2: 导入器**
- `importer.cpp` — 识别 `kanji_bank_` 文件
- 将 kanji 条目转换为与 term 兼容的存储格式（character 作为 term，readings 拼接，meanings 作为 glossary）
- 这样查询逻辑不需要大改，复用现有 term 搜索路径

**Step 3: 查询适配**
- 当输入为单字时，额外搜索 `type == kanji` 的词典
- 结果按 type 分组显示（term 词典在前，kanji 在后）

**Step 4: 渲染适配**
- `popup.js` 中为 kanji 类型条目渲染专用布局（音读、训读、含义、笔画数等）
- 可以用 structured content 的现有渲染逻辑，只需在 glossary 区分格式

### 涉及文件

- `hibiki/lib/src/dictionary/dictionary.dart` — DictionaryType
- `hibiki/lib/src/dictionary/hoshidicts.dart` — 导入逻辑
- C++ `importer.cpp` — kanji_bank 解析
- `hibiki/lib/src/models/app_model.dart` — 查询逻辑
- `hibiki/assets/popup/popup.js` — kanji 条目渲染

### 风险

- C++ 导入器改动需要 NDK 编译验证
- kanji 存储格式需要和现有 Isar schema 兼容（避免 migration）
- 推荐做法：将 kanji 条目适配为现有 term 表结构（`expression=字, reading=onyomi+kunyomi, glossary=meanings`），标 `type=kanji`，零 schema 改动

---

## 执行顺序

1. **Task 1**（例文折叠 bug）— 最简单，3 行修改
2. **Task 3**（per-dict collapse）— 中等，Dart + JS 各改几行
3. **Task 2**（图片优化）— 中等，CSS + JS
4. **Task 4**（Kanji 词典）— 最大，跨 C++/Dart/JS

每个 Task 完成后单独 commit + code review。
