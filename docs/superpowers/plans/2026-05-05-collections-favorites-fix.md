# Hoshi 式 Highlight 功能 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把现有"收藏句子"升级为 Hoshi iOS 风格的视觉高亮系统：选中文本 → 彩色 span 渲染 → 导航面板中可跳转/播放/删除。

**Architecture:** 利用已有的 TreeWalker + normCharOffset 基础设施。新增 `_highlightUserFn` JS 注入实现 DOM span 包裹；升级 `FavoriteSentence` 模型加 color/length 字段；在 section 切换时重新应用高亮。不改 ttu-fork（纯 hibiki 侧 JS 注入）。

**Tech Stack:** Flutter/Dart, InAppWebView JS 注入, AudiobookBridge 模式, FavoriteSentenceRepository

---

## 文件映射

| 文件 | 职责 |
|------|------|
| `lib/src/media/audiobook/highlight_bridge.dart` | **新建** — 高亮 JS 注入 + Dart 接口 |
| `lib/src/media/audiobook/favorite_sentence_repository.dart` | 升级模型加 `color` + `normCharLength` 字段 |
| `lib/src/media/audiobook/audiobook_play_bar.dart:416-431` | 导航 section 接入 `_buildFavoritesSection` |
| `lib/src/pages/implementations/reader_ttu_source_page.dart` | 注入高亮 JS + section 切换时 apply + 替换 favoriteMenuAction |

---

### Task 1: 升级 FavoriteSentence 数据模型

**Files:**
- Modify: `lib/src/media/audiobook/favorite_sentence_repository.dart`

- [ ] **Step 1: 添加 color 和 normCharLength 字段**

```dart
class FavoriteSentence {
  FavoriteSentence({
    required this.text,
    required this.bookTitle,
    this.chapterLabel,
    required this.createdAt,
    this.ttuBookId,
    this.sectionIndex,
    this.normCharOffset,
    this.normCharLength,
    this.color,
    String? id,
  }) : id = id ?? const Uuid().v4();

  final String id;
  final String text;
  final String bookTitle;
  final String? chapterLabel;
  final DateTime createdAt;
  final int? ttuBookId;
  final int? sectionIndex;
  final int? normCharOffset;
  final int? normCharLength;
  final String? color; // 'yellow','green','blue','pink','purple'
```

toJson/fromJson 也要加上新字段，`id` 用于 DOM 中 `data-highlight-id` 关联：

```dart
  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'bookTitle': bookTitle,
        if (chapterLabel != null) 'chapterLabel': chapterLabel,
        'createdAt': createdAt.toIso8601String(),
        if (ttuBookId != null) 'ttuBookId': ttuBookId,
        if (sectionIndex != null) 'sectionIndex': sectionIndex,
        if (normCharOffset != null) 'normCharOffset': normCharOffset,
        if (normCharLength != null) 'normCharLength': normCharLength,
        if (color != null) 'color': color,
      };

  factory FavoriteSentence.fromJson(Map<String, dynamic> json) =>
      FavoriteSentence(
        id: json['id'] as String? ?? const Uuid().v4(),
        text: json['text'] as String,
        bookTitle: json['bookTitle'] as String,
        chapterLabel: json['chapterLabel'] as String?,
        createdAt: DateTime.parse(json['createdAt'] as String),
        ttuBookId: json['ttuBookId'] as int?,
        sectionIndex: json['sectionIndex'] as int?,
        normCharOffset: json['normCharOffset'] as int?,
        normCharLength: json['normCharLength'] as int?,
        color: json['color'] as String?,
      );
}
```

需要添加 `uuid` 依赖（或用简单的 `DateTime.now().microsecondsSinceEpoch.toRadixString(36)` 作 ID）。

- [ ] **Step 2: flutter analyze 验证**

---

### Task 2: 创建 highlight_bridge.dart（JS 注入）

**Files:**
- Create: `lib/src/media/audiobook/highlight_bridge.dart`

- [ ] **Step 1: 编写 JS 常量和 Dart 接口**

核心 JS 函数（复用已有的 `__hoshiIsSkippable` 和 TreeWalker 模式）：

```dart
import 'dart:convert';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/src/media/audiobook/favorite_sentence_repository.dart';

class HighlightBridge {
  HighlightBridge._();

  static const String _js = r'''
(function() {
  if (window.__hibikiHighlightsInstalled) return;
  window.__hibikiHighlightsInstalled = true;

  var COLORS = {
    yellow: 'rgba(255,220,0,0.35)',
    green: 'rgba(0,200,83,0.3)',
    blue: 'rgba(68,138,255,0.3)',
    pink: 'rgba(255,64,129,0.3)',
    purple: 'rgba(170,0,255,0.25)'
  };

  // ── 从 selection 计算 normCharOffset + length ──
  window.__hibikiGetSelectionNormRange = function() {
    var sel = window.getSelection();
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) return null;
    var range = sel.getRangeAt(0);
    var text = sel.toString().trim();
    if (!text) return null;

    var root = document.querySelector('.book-content-container')
            || document.querySelector('.book-content')
            || document.body;

    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function(n) {
        var p = n.parentNode;
        while (p && p !== root) {
          var tag = p.nodeName ? p.nodeName.toLowerCase() : '';
          if (tag === 'rt' || tag === 'rp') return NodeFilter.FILTER_REJECT;
          p = p.parentNode;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });

    var normCount = 0;
    var startNorm = -1;
    var endNorm = -1;
    var node;

    while ((node = walker.nextNode()) != null) {
      var nodeText = node.textContent || '';
      for (var i = 0; i < nodeText.length; i++) {
        var inRange = range.isPointInRange
          ? range.isPointInRange(node, i)
          : _fallbackInRange(range, node, i);

        var c = nodeText.charCodeAt(i);
        var skip = (typeof __hoshiIsSkippable === 'function')
          ? __hoshiIsSkippable(c) : false;

        if (!skip) {
          if (inRange && startNorm < 0) startNorm = normCount;
          if (inRange) endNorm = normCount + 1;
          normCount++;
        }
      }
    }

    if (startNorm < 0) return null;
    return { offset: startNorm, length: endNorm - startNorm, text: text };
  };

  function _fallbackInRange(range, node, offset) {
    try {
      var r2 = document.createRange();
      r2.setStart(node, offset);
      r2.setEnd(node, Math.min(offset + 1, node.length));
      return range.intersectsNode
        ? (range.compareBoundaryPoints(Range.START_TO_END, r2) > 0 &&
           range.compareBoundaryPoints(Range.END_TO_START, r2) < 0)
        : true;
    } catch (e) { return false; }
  }

  // ── 应用高亮 span（给定 section 的所有 highlights）──
  window.__hibikiApplyHighlights = function(highlightsJson) {
    // Remove old user highlights
    document.querySelectorAll('[data-highlight-id]').forEach(function(el) {
      var parent = el.parentNode;
      while (el.firstChild) parent.insertBefore(el.firstChild, el);
      parent.removeChild(el);
    });
    // Normalize text nodes after removal
    var root = document.querySelector('.book-content-container')
            || document.querySelector('.book-content')
            || document.body;
    root.normalize();

    if (!highlightsJson || highlightsJson.length === 0) return;

    // Sort by offset descending to avoid invalidating positions
    var sorted = highlightsJson.slice().sort(function(a, b) {
      return b.offset - a.offset;
    });

    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function(n) {
        var p = n.parentNode;
        while (p && p !== root) {
          var tag = p.nodeName ? p.nodeName.toLowerCase() : '';
          if (tag === 'rt' || tag === 'rp') return NodeFilter.FILTER_REJECT;
          p = p.parentNode;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });

    // Build offset map: [{node, rawIdx, normIdx}]
    var map = [];
    var normCount = 0;
    var node;
    while ((node = walker.nextNode()) != null) {
      var txt = node.textContent || '';
      for (var i = 0; i < txt.length; i++) {
        var c = txt.charCodeAt(i);
        var skip = (typeof __hoshiIsSkippable === 'function')
          ? __hoshiIsSkippable(c) : false;
        if (!skip) {
          map.push({ node: node, rawIdx: i, normIdx: normCount });
          normCount++;
        }
      }
    }

    for (var h = 0; h < sorted.length; h++) {
      var hl = sorted[h];
      var startEntry = null, endEntry = null;
      for (var m = 0; m < map.length; m++) {
        if (map[m].normIdx === hl.offset) startEntry = map[m];
        if (map[m].normIdx === hl.offset + hl.length - 1) { endEntry = map[m]; break; }
      }
      if (!startEntry || !endEntry) continue;

      try {
        var r = document.createRange();
        r.setStart(startEntry.node, startEntry.rawIdx);
        r.setEnd(endEntry.node, endEntry.rawIdx + 1);

        var span = document.createElement('span');
        span.setAttribute('data-highlight-id', hl.id);
        span.style.backgroundColor = COLORS[hl.color] || COLORS.yellow;
        span.style.borderRadius = '2px';
        r.surroundContents(span);
      } catch (e) {
        // surroundContents fails on cross-element ranges; skip
      }
    }
  };

  // ── 移除单条高亮 ──
  window.__hibikiRemoveHighlight = function(id) {
    var el = document.querySelector('[data-highlight-id="' + id + '"]');
    if (!el) return;
    var parent = el.parentNode;
    while (el.firstChild) parent.insertBefore(el.firstChild, el);
    parent.removeChild(el);
    parent.normalize();
  };
})();
''';

  /// 注入高亮 JS 到 WebView。
  static Future<void> inject(InAppWebViewController controller) async {
    await controller.evaluateJavascript(source: _js);
  }

  /// 获取当前选区的归一化字符偏移和长度。
  static Future<({int offset, int length, String text})?> getSelectionRange(
    InAppWebViewController controller,
  ) async {
    final Object? raw = await controller.evaluateJavascript(
      source: '(function(){try{var r=window.__hibikiGetSelectionNormRange();return r?JSON.stringify(r):"null";}catch(e){return "null";}})();',
    );
    if (raw is! String || raw.isEmpty || raw == 'null') return null;
    final Map<String, dynamic> json = jsonDecode(raw) as Map<String, dynamic>;
    final int? offset = (json['offset'] as num?)?.toInt();
    final int? length = (json['length'] as num?)?.toInt();
    final String? text = json['text'] as String?;
    if (offset == null || length == null || text == null) return null;
    return (offset: offset, length: length, text: text);
  }

  /// 应用当前 section 的所有高亮。
  static Future<void> applyHighlights(
    InAppWebViewController controller,
    List<FavoriteSentence> highlights,
  ) async {
    final List<Map<String, dynamic>> payload = highlights
        .where((h) => h.normCharOffset != null && h.normCharLength != null)
        .map((h) => {
              return {
                'id': h.id,
                'offset': h.normCharOffset,
                'length': h.normCharLength,
                'color': h.color ?? 'yellow',
              };
            })
        .toList();
    final String json = jsonEncode(payload);
    await controller.evaluateJavascript(
      source: 'window.__hibikiApplyHighlights && window.__hibikiApplyHighlights($json);',
    );
  }

  /// 移除单条高亮 span。
  static Future<void> removeHighlight(
    InAppWebViewController controller,
    String highlightId,
  ) async {
    final String escaped = jsonEncode(highlightId);
    await controller.evaluateJavascript(
      source: 'window.__hibikiRemoveHighlight && window.__hibikiRemoveHighlight($escaped);',
    );
  }
}
```

- [ ] **Step 2: flutter analyze 验证**

---

### Task 3: 替换 favoriteMenuAction 为高亮创建流程

**Files:**
- Modify: `lib/src/pages/implementations/reader_ttu_source_page.dart:2063-2084`

- [ ] **Step 1: 重写 favoriteMenuAction 使用 HighlightBridge**

```dart
  void favoriteMenuAction() async {
    // 1) 获取选区的归一化偏移 + 长度
    final selRange = await HighlightBridge.getSelectionRange(_controller);
    if (selRange == null || selRange.text.isEmpty) return;
    await unselectWebViewTextSelection(_controller);

    final String bookTitle = widget.item?.title ?? '';
    final String? chapterLabel = _tocLabels[_currentTtuSection];
    final int? ttuId = _extractTtuBookId();

    // 2) 默认使用 yellow（后续可加颜色选择器）
    const String color = 'yellow';

    final sentence = FavoriteSentence(
      text: selRange.text,
      bookTitle: bookTitle,
      chapterLabel: chapterLabel,
      createdAt: DateTime.now(),
      ttuBookId: ttuId,
      sectionIndex: _currentTtuSection >= 0 ? _currentTtuSection : null,
      normCharOffset: selRange.offset,
      normCharLength: selRange.length,
      color: color,
    );
    await FavoriteSentenceRepository(appModel.database).add(sentence);

    // 3) 立即在 WebView 中渲染高亮 span
    await _applyHighlightsForCurrentSection();

    if (mounted) {
      Fluttertoast.showToast(msg: t.favorite_added);
    }
  }
```

- [ ] **Step 2: 添加 `_applyHighlightsForCurrentSection` 方法**

```dart
  Future<void> _applyHighlightsForCurrentSection() async {
    if (_currentTtuSection < 0) return;
    final int? ttuId = _extractTtuBookId();
    if (ttuId == null) return;

    final allFavorites =
        await FavoriteSentenceRepository(appModel.database).getAll();
    final sectionHighlights = allFavorites
        .where((f) => f.ttuBookId == ttuId && f.sectionIndex == _currentTtuSection)
        .toList();

    await HighlightBridge.applyHighlights(_controller, sectionHighlights);
  }
```

- [ ] **Step 3: flutter analyze 验证**

---

### Task 4: 在页面加载和 section 切换时应用高亮

**Files:**
- Modify: `lib/src/pages/implementations/reader_ttu_source_page.dart`

- [ ] **Step 1: 在 onLoadStop 中注入高亮 JS 并应用**

在 `onLoadStop` 的 finally 块之前（约 line 1656），插入：

```dart
    // 注入高亮 JS 并应用当前 section 的用户高亮
    await HighlightBridge.inject(controller);
    unawaited(_applyHighlightsForCurrentSection());
```

- [ ] **Step 2: 在 _handleTtuSectionChanged 中重新应用高亮**

在 `_handleTtuSectionChanged` 方法末尾（section 变化确认后），添加：

```dart
    unawaited(_applyHighlightsForCurrentSection());
```

具体位置：在 `unawaited(_applySasayakiCuesForSection(idx));` 之后。

- [ ] **Step 3: flutter analyze 验证**

---

### Task 5: 接入导航面板 + 修复播放/删除

**Files:**
- Modify: `lib/src/media/audiobook/audiobook_play_bar.dart:416-431`
- Modify: `lib/src/pages/implementations/reader_ttu_source_page.dart:3197`

- [ ] **Step 1: 将 _buildFavoritesSection 加入 navigation case**

```dart
      case 'navigation':
        title = t.section_navigation;
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSearchSection(theme),
            if (widget.toc.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildTocSection(context, theme),
            ],
            if (widget.bookmarks.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildBookmarkSection(context, theme),
            ],
            if (widget.favoriteSentences.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildFavoritesSection(context, theme),
            ],
          ],
        );
```

- [ ] **Step 2: 过滤 favorites 为当前书**

在 `_showReaderSettingsSheet` 中（约 line 3197），将：
```dart
    final List<FavoriteSentence> favorites =
        await FavoriteSentenceRepository(appModel.database).getAll();
```
改为：
```dart
    final List<FavoriteSentence> allFavorites =
        await FavoriteSentenceRepository(appModel.database).getAll();
    final List<FavoriteSentence> favorites = ttuId != null
        ? allFavorites.where((f) => f.ttuBookId == ttuId).toList()
        : allFavorites;
```

- [ ] **Step 3: 在 _buildFavoritesSection 中增加颜色指示条**

在 `_buildFavoritesSection` 的 ListTile leading 中加入颜色条（模仿 Hoshi iOS）：

```dart
leading: Container(
  width: 4,
  height: 40,
  decoration: BoxDecoration(
    color: _highlightColor(fav.color),
    borderRadius: BorderRadius.circular(2),
  ),
),
```

添加辅助方法：
```dart
  Color _highlightColor(String? color) {
    switch (color) {
      case 'green': return const Color(0xFF00C853);
      case 'blue': return const Color(0xFF448AFF);
      case 'pink': return const Color(0xFFFF4081);
      case 'purple': return const Color(0xFFAA00FF);
      default: return const Color(0xFFFFDC00); // yellow
    }
  }
```

- [ ] **Step 4: 删除后刷新 WebView 高亮**

在 `onDeleteFavorite` 回调中（reader_ttu_source_page.dart 约 line 3245），删除后重新 apply：

```dart
          onDeleteFavorite: (int index) async {
            await FavoriteSentenceRepository(appModel.database).removeAt(index);
            unawaited(_applyHighlightsForCurrentSection());
          },
```

- [ ] **Step 5: flutter analyze 验证**

---

### Task 6: 修复音频 fallback

**Files:**
- Modify: `lib/src/pages/implementations/reader_ttu_source_page.dart:2746-2760`

- [ ] **Step 1: Audiobook 无文件时 fallthrough 到 SrtBook**

将 `_initAudiobookIfAvailable` 中 `audioFiles.isEmpty` 的处理从直接 return 改为尝试 SrtBook：

```dart
      if (audioFiles.isEmpty) {
        debugPrint('[hibiki-audiobook] audiobook found but files empty, '
            'trying SrtBook fallback');
        await _initSrtBookIfAvailable();
        return;
      }
```

- [ ] **Step 2: flutter analyze 验证**

---

### Task 7: 编译验证 + Commit

- [ ] **Step 1: flutter analyze 全项目**

Run: `cd d:\APP\vs_claude_code\hibiki\hibiki && flutter analyze`
Expected: No errors

- [ ] **Step 2: 编译 release APK**

Run: `flutter build apk --release --split-per-abi --target-platform android-arm64`
Expected: BUILD SUCCESSFUL

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(highlight): Hoshi-style visual text highlights

- Add color + normCharLength + id to FavoriteSentence model
- Create HighlightBridge with JS injection for span wrapping
- Replace favoriteMenuAction with selection-based highlight creation
- Apply highlights on section change and page load
- Wire _buildFavoritesSection into navigation panel (was dead code)
- Filter favorites to current book in settings sheet
- Add color indicator strip in highlight list
- Fix audio fallback: try SrtBook when Audiobook files empty"
```

---

## 后续增强（不在此 PR 范围）

- 颜色选择器 UI（当前默认 yellow，后续可在选中文本时弹出 5 色浮条）
- 从外部 CollectionsPage 点击高亮跳转时恢复视觉高亮
- 高亮导出（Anki 卡面中包含高亮上下文）
