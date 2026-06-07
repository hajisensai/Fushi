# 查词弹窗统一（共享栈控制器）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: 用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现。步骤用 `- [ ]` 复选框跟踪。

**Goal:** 把书内（`BaseSourcePageState`）与视频/首页/独立窗（`DictionaryPageMixin`）两份近乎重复的查词弹窗栈逻辑，统一到**一个**共享 `DictionaryPopupController`，消除「同一个 bug 要在两处各修一遍」的根因（白屏分歧就是这么来的）。

**Architecture:** 新增一个与 UI 无关的 `DictionaryPopupController`（持栈 + 常驻热槽 + 搜索→就绪才显示 + 关栈保留热槽 + autoRead/历史接线 + 搜索态）。`BaseSourcePageState` **对外 API 完全不变**（reader 30+ 处 `topPopupState`/`prunePopupStack`/`onAllPopupsDismissed`/caret 路由零改），内部改为委托该 controller。`DictionaryPageMixin` 的三个宿主（video/home/standalone）改用同一 controller。渲染仍各表面自管（书内挂页面树、视频挂根 Overlay、首页/独立窗各自卡片），共用已有的 `DictionaryPopupLayer`。

**Tech Stack:** Dart / Flutter / Riverpod；现有 `DictionaryPopupLayer` + `DictionaryPopupWebView`；测试 `flutter_test` + 仓库既有的 fake inappwebview 平台 + 源码守卫范式。

**缓存决策（回应「共享一个缓存」）：**
- **搜索/FFI 结果缓存已是全局共享**：四表面都走 `appModel.searchDictionary` → 同一 `dictRepo.getCachedSearch`（含预构建 `popupJson`）+ `getCachedFfiLookup`。书里查过的词到视频命中缓存，反之亦然。**本计划不动它。**
- **全 app 单个常驻 WebView：否决。** reader 的字符光标系统有 30+ 处 `topPopupState?.caret*`（suspend/move/scroll/lookup/activate/longPress/enter/exit）把「当前可见浮层的 WebView 身份」与每次查词强绑定；单例 WebView 需要重写整套光标路由 + 跨页坐标映射 + 全屏根 Overlay 主题切换，风险极高、用户收益极小（贵的搜索已缓存）。**各表面保留自己的热 WebView，但由同一 controller 驱动**（行为一致即「走同一套」的实质）。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `hibiki/lib/src/pages/implementations/dictionary_popup_controller.dart` | 新：`DictionaryPopupEntry`（统一条目）+ `DictionaryPopupController`（栈/热槽/搜索→显示/关栈/autoRead/历史/搜索态），纯逻辑、不 import 任何页面 | Create |
| `hibiki/lib/src/pages/base_source_page.dart` | 内部 `_PopupStackItem` 栈 → 委托 controller；**公开方法签名与语义不变** | Modify |
| `hibiki/lib/src/pages/implementations/dictionary_page_mixin.dart` | `NestedPopupEntry`/`pushNestedPopup`/`popNestedPopupAt` 改为 controller 的薄适配（保留方法名给三宿主调用，避免大改宿主） | Modify |
| `hibiki/lib/src/pages/implementations/video_hibiki_page.dart` | `_popupStack`/`_seedWarmPopup`/`_lookupAt`/`_popNestedPopupAt` 改用 controller；搜索→就绪才显示（与书内一致） | Modify |
| `hibiki/lib/src/pages/implementations/home_dictionary_page.dart` | 改用 controller（全卡片表面，行为不变） | Modify |
| `hibiki/lib/src/pages/implementations/popup_dictionary_page.dart` | 改用 controller（独立窗，行为不变） | Modify |
| `hibiki/test/pages/dictionary_popup_controller_test.dart` | 新：controller 行为单测（不渲染 WebView） | Create |
| `hibiki/test/pages/popup_unification_guard_test.dart` | 新：源码守卫，断言两侧都委托 controller、无重复栈逻辑 | Create |

**迁移顺序（风险从低到高，每阶段独立可验、可单独提交/回滚）：**
1. 建 controller + 单测（零接线，零风险）。
2. 三个 mixin 宿主迁到 controller（video/home/standalone，非 reader）。
3. base_source_page 内部委托 controller（reader 行为靠现有测试 + 设备复测兜底）。
4. 删除 `NestedPopupEntry` / `_PopupStackItem` 残留，收口为单一类型。

> **铁律（Never break userspace）**：reader 的公开弹窗 API（`topPopupState`、`prunePopupStack`、`searchDictionaryResult`、`onAllPopupsDismissed`、`onDictionaryStackChanged`、`onDictionaryPopupRendered`、`dismissTopPopup`、`topVisiblePopupIndex`、`clearDictionaryResult`、`isDictionaryShown`、`currentResult`、`buildDictionary`、`showDeferredPopup`、`buildPopupAudioControls`）**签名与语义在本计划全程保持不变**。reader_hibiki_page.dart 不在任何任务的 Modify 列表里。

---

## 统一的状态模型（消除特例）

两份条目合一为 `DictionaryPopupEntry`，并采用书内的「**搜索→就绪才显示**」时序作为唯一时序（视频原先的「先显示空槽再搜索」是白屏根因，已被盖板兜住，这里从时序上根治）：

- 字段：`query`、`selectionRect`、`result`、`searchTerm`、`visible`、`isWarmSlot`、`allLoaded`、`webViewKey`、`isSearching`（条目级，供分页 load-more）。
- 热槽（`isWarmSlot`）：开页 seed 一个 `visible=false` 的常驻条目，WebView 全程预热复用。
- 搜索期：controller 暴露 `isSearching` + `pendingRect`，宿主据此渲染轻量加载占位（已有 `DictionaryPopupLayer` 的不透明盖板 + 书内的 `_buildLoadingPlaceholder` 二选一），**不显示空 WebView**。

---

## Task 1: 建 `DictionaryPopupController` + 条目类型（纯逻辑）

**Files:**
- Create: `hibiki/lib/src/pages/implementations/dictionary_popup_controller.dart`
- Test: `hibiki/test/pages/dictionary_popup_controller_test.dart`

- [ ] **Step 1: 写失败测试（栈基本操作 + 热槽语义）**

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';

void main() {
  test('seedWarmSlot 放一个隐藏的常驻热槽', () {
    final c = DictionaryPopupController(lowMemory: false);
    c.seedWarmSlot();
    expect(c.entries.length, 1);
    expect(c.entries.first.isWarmSlot, true);
    expect(c.entries.first.visible, false);
    expect(c.hasVisiblePopup, false);
  });

  test('lowMemory 不 seed 热槽', () {
    final c = DictionaryPopupController(lowMemory: true);
    c.seedWarmSlot();
    expect(c.entries, isEmpty);
  });

  test('reveal 把结果填进热槽并设可见（搜索→就绪才显示）', () {
    final c = DictionaryPopupController(lowMemory: false)..seedWarmSlot();
    c.beginSearch(const Rect.fromLTWH(1, 2, 3, 4), 'あ');
    expect(c.entries.first.visible, false, reason: '搜索期热槽仍隐藏');
    expect(c.isSearching, true);
    c.revealResult(result: null, allLoaded: true);
    expect(c.isSearching, false);
    expect(c.entries.first.visible, true);
  });

  test('dismiss(0) 隐藏并保留热槽（非清空）', () {
    final c = DictionaryPopupController(lowMemory: false)..seedWarmSlot();
    c.beginSearch(Rect.zero, 'あ');
    c.revealResult(result: null, allLoaded: true);
    c.dismissAt(0);
    expect(c.entries.length, 1);
    expect(c.entries.first.isWarmSlot, true);
    expect(c.entries.first.visible, false);
    expect(c.hasVisiblePopup, false);
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `flutter test test/pages/dictionary_popup_controller_test.dart`
Expected: FAIL（`DictionaryPopupController` 未定义）

- [ ] **Step 3: 实现最小 controller**

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';

/// 统一的查词弹窗条目（合并旧 _PopupStackItem 与 NestedPopupEntry）。
class DictionaryPopupEntry {
  DictionaryPopupEntry({
    required this.searchTerm,
    required this.selectionRect,
    this.result,
    this.visible = true,
    this.isWarmSlot = false,
    this.allLoaded = false,
  });
  String searchTerm;
  Rect selectionRect;
  DictionarySearchResult? result;
  bool visible;
  bool isSearching = false;
  bool allLoaded;
  final bool isWarmSlot;
  final GlobalKey<DictionaryPopupWebViewState> webViewKey =
      GlobalKey<DictionaryPopupWebViewState>();
}

/// 与 UI 无关的查词弹窗栈控制器：所有表面（书内/视频/首页/独立窗）共用。
/// 时序统一为「搜索→结果就绪才把浮层设为可见」，搜索期只暴露 [isSearching] +
/// [pendingRect] 供宿主画轻量加载占位，从不显示空 WebView。
class DictionaryPopupController extends ChangeNotifier {
  DictionaryPopupController({required this.lowMemory});
  final bool lowMemory;

  final List<DictionaryPopupEntry> _entries = <DictionaryPopupEntry>[];
  List<DictionaryPopupEntry> get entries => List.unmodifiable(_entries);

  bool _isSearching = false;
  bool get isSearching => _isSearching;
  Rect? _pendingRect;
  Rect? get pendingRect => _pendingRect;

  bool get hasVisiblePopup => _entries.any((e) => e.visible);

  void seedWarmSlot() {
    if (lowMemory || _entries.isNotEmpty) return;
    _entries.add(DictionaryPopupEntry(
      searchTerm: '',
      selectionRect: Rect.zero,
      visible: false,
      isWarmSlot: true,
    ));
    notifyListeners();
  }

  void beginSearch(Rect selectionRect, String term) {
    _isSearching = true;
    _pendingRect = selectionRect;
    notifyListeners();
  }

  void revealResult({
    required DictionarySearchResult? result,
    required bool allLoaded,
  }) {
    _isSearching = false;
    _pendingRect = null;
    final DictionaryPopupEntry slot = _reusableSlot();
    slot
      ..result = result
      ..allLoaded = allLoaded
      ..visible = true
      ..isSearching = false;
    notifyListeners();
  }

  DictionaryPopupEntry _reusableSlot() {
    if (_entries.isNotEmpty) return _entries.first;
    final e = DictionaryPopupEntry(searchTerm: '', selectionRect: Rect.zero);
    _entries.add(e);
    return e;
  }

  void dismissAt(int index) {
    if (index < 0 || index >= _entries.length) return;
    if (index == 0) {
      final first = _entries.first;
      if (first.isWarmSlot && !lowMemory) {
        first
          ..visible = false
          ..selectionRect = Rect.zero;
        _entries
          ..clear()
          ..add(first);
      } else {
        _entries.clear();
      }
    } else {
      _entries.removeRange(index, _entries.length);
    }
    notifyListeners();
  }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `flutter test test/pages/dictionary_popup_controller_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/pages/implementations/dictionary_popup_controller.dart hibiki/test/pages/dictionary_popup_controller_test.dart
git commit -m "feat(dict): 新增共享 DictionaryPopupController + 统一条目类型"
```

---

## Task 2: 视频页迁到 controller（含 home/standalone 同型迁移）

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/dictionary_page_mixin.dart`（`pushNestedPopup`/`popNestedPopupAt` 内部改走 controller，方法名保留）
- Modify: `hibiki/lib/src/pages/implementations/video_hibiki_page.dart:743-800`（`_seedWarmPopup`/`_popNestedPopupAt` 委托 controller；`_lookupAt` 改「搜索→reveal」）
- Modify: `hibiki/lib/src/pages/implementations/home_dictionary_page.dart` / `popup_dictionary_page.dart`（持 controller 替代裸 `List<NestedPopupEntry>`）
- Test: `hibiki/test/pages/dictionary_page_mixin_warm_slot_test.dart`（更新断言到 controller）+ 复用 `video_warm_popup_guard_test.dart`

- [ ] **Step 1: 更新 mixin 热槽行为测试为 controller 语义**（沿用既有 `dictionary_page_mixin_warm_slot_test.dart` 的用例，断言改为查 `controller.entries`/`hasVisiblePopup`/`isSearching`）。
- [ ] **Step 2: 运行确认失败**（Run: `flutter test test/pages/dictionary_page_mixin_warm_slot_test.dart`，Expected: FAIL）。
- [ ] **Step 3: mixin 内部委托 controller**：`pushNestedPopup(reuseWarmSlot:true)` → `controller.beginSearch(rect,term)` + `setState` 画占位 → `await searchDictionary` → `controller.revealResult(...)`；`popNestedPopupAt` → `controller.dismissAt`。**保留 `pushNestedPopup`/`popNestedPopupAt`/`buildNestedPopupLayer` 方法名**，三宿主调用面不变。
- [ ] **Step 4: 运行测试通过 + `flutter analyze` 改动文件 0**。
- [ ] **Step 5: 提交** `refactor(dict): 视频/首页/独立窗弹窗改用共享 controller`。
- [ ] **设备复测检查点（必做，本 agent 无设备 → 交用户）**：视频查词出主题色加载态→出字不白屏；递归查词、点同句另一词换词、关栈恢复播放（BUG-072）、返回键退出均如旧；首页查词 tab、安卓独立查词窗各跑一遍。

---

## Task 3: base_source_page 内部委托 controller（reader API 不变）

**Files:**
- Modify: `hibiki/lib/src/pages/base_source_page.dart`（`_popupStack`/`_PopupStackItem` → controller + `DictionaryPopupEntry`；所有公开方法转调 controller，签名不变）
- Test: 复用 `base_source_page_warm_popup_test.dart` / `base_source_page_hot_popup_test.dart`（`debugPopupStack` 钩子改读 controller，断言不变）

- [ ] **Step 1: 先跑既有书内弹窗测试取绿基线**（Run: `flutter test test/pages/base_source_page_warm_popup_test.dart test/pages/base_source_page_hot_popup_test.dart`，Expected: PASS）。
- [ ] **Step 2: 内部替换**：`_popupStack` 的 `_PopupStackItem` 全换 `DictionaryPopupEntry`；`_seedWarmPopup`/`prunePopupStack`/`_dismissPopupAt`/`_reusableHiddenTopPopup`/`searchDictionaryResult`/`showDeferredPopup` 内部逻辑搬进/转调 controller。`buildDictionary` 渲染保持。**不改任何方法签名**。
- [ ] **Step 3: 跑既有测试全绿 + `flutter analyze` 0**。
- [ ] **Step 4: 提交** `refactor(dict): base_source_page 内部委托共享 controller（reader API 不变）`。
- [ ] **设备复测检查点（必做）**：阅读器查词浮层、嵌套查词、手柄/键盘字符光标全套（move/scroll/lookup/activate/longPress、enter/exit、跨层 `onDictionaryStackChanged`、关栈 `onAllPopupsDismissed`）、低内存模式、`showDeferredPopup`、有声书查词——逐项肉眼复测。

---

## Task 4: 收口单一类型 + 防回归守卫

**Files:**
- Modify: `dictionary_page_mixin.dart`（删 `NestedPopupEntry`，改导出 controller 的 `DictionaryPopupEntry`）/ `base_source_page.dart`（删 `_PopupStackItem`）
- Create: `hibiki/test/pages/popup_unification_guard_test.dart`

- [ ] **Step 1: 写守卫测试**

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('两侧弹窗栈都委托共享 controller，无重复条目类型', () {
    final base = File('lib/src/pages/base_source_page.dart').readAsStringSync();
    final mixin = File(
            'lib/src/pages/implementations/dictionary_page_mixin.dart')
        .readAsStringSync();
    expect(base.contains('DictionaryPopupController'), isTrue);
    expect(mixin.contains('DictionaryPopupController'), isTrue);
    // 旧的两份条目类型已收口为单一 DictionaryPopupEntry。
    expect(base.contains('class _PopupStackItem'), isFalse,
        reason: '_PopupStackItem 应已删除，统一为 DictionaryPopupEntry');
    expect(mixin.contains('class NestedPopupEntry'), isFalse,
        reason: 'NestedPopupEntry 应已删除，统一为 DictionaryPopupEntry');
  });
}
```

- [ ] **Step 2: 删旧类型，全仓引用改 `DictionaryPopupEntry`**（`flutter analyze` 驱动改完所有引用点）。
- [ ] **Step 3: 跑 `flutter test test/pages/` 全绿 + `flutter analyze` 0**。
- [ ] **Step 4: 提交** `refactor(dict): 收口为单一 DictionaryPopupEntry + 统一守卫`。

---

## Self-Review

- **Spec 覆盖**：①统一栈逻辑→Task1-4；②缓存→已说明（搜索缓存已共享、单 WebView 否决），无代码任务；③reader 不破→全程 API 冻结 + Task3 设备检查点。
- **占位符**：Task1 含完整 controller 代码；Task2-4 为行为保持的重构，给出确切转换规则 + 既有测试复用 + 设备检查点（重构不宜逐行伪造 reader/mixin 宿主的全部改动，executor 按规则改并以测试+设备兜底）。
- **类型一致**：全程 `DictionaryPopupController` / `DictionaryPopupEntry` / `seedWarmSlot` / `beginSearch` / `revealResult` / `dismissAt` 命名统一。

---

## 风险与边界

- 最大风险在 Task3（reader 字符光标耦合）。缓解：reader 公开 API 冻结、reader 文件不进 Modify 列表、既有书内/光标测试取绿基线、强制设备逐项复测。
- 本计划**不**引入全局单 WebView、**不**改搜索缓存。若后续仍要「单 WebView」需另立 spec 评估 caret 路由重写成本。
