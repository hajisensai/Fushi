# 中键点击 seek 音频实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans。步骤用 `- [ ]` 勾选。

**Goal:** 鼠标中键（进快捷键体系、默认中键、设置页仍隐藏）点击正文/歌词某句 → 音频 `playCueAndContinue` 跳到该句并播放，支持 Sasayaki 原生 EPUB / 合成书 / 歌词三表面。

**Architecture:** 扩展快捷键体系新增 `MouseBinding` 与 `ShortcutAction.audiobookSeekToClickedSentence`（默认中键）。运行时鼠标键是位置型：JS `mousedown` 捕获非左键 → `callHandler` 回 Dart → `resolveMouse` 判定命中绑定 → 正文经新 JS 原语 `hoshiReader.cueIdAtPoint(x,y)`（复用 `cueRangesMap`/`cueWrappers`/`[data-cue-id]` 做包含判定）回 cueId → 反查 `AudioCue` → `playCueAndContinue`；歌词经 `data-cue-index` 直达。

**Tech Stack:** Dart/Flutter, flutter_inappwebview JS 桥, Drift 持久化, Slang i18n。

**关键事实（已核对真实代码）：**
- cue 的 JS `id` = `cue.textFragmentId`（`reader_hibiki_page.dart:2690`），即 `cueRangesMap`/`cueWrappers` 的键（`reader_pagination_scripts.dart:433/452`）。
- 合成书可点 cue 元素带 `[data-cue-id]`=sentenceIndex（`audiobook_bridge.dart:127`）。
- `_cachedAllCues`（`reader_hibiki_page.dart:2660`）是统一 cue 列表，sentenceIndex / textFragmentId 都能反查。
- 正文 JS 手势在 `reader_hibiki_page.dart:1661-1668`（`pointerdown`/`pointerup` 硬过滤 `e.button!==0`）。
- 歌词 click 在 `lyrics_mode_html.dart:195`（标准 click，中键不触发）；cue 元素带 `data-cue-index`（:30）。
- `_actionLabel`（`shortcut_settings_page.dart:13`）穷举无 default → 新枚举必须加 case + i18n key。
- `_mobile`（`shortcut_defaults.dart:156`）用 `_desktop[action]!` 强解包 → 新动作必须进 `_desktop`。

---

### Task 1: `MouseBinding` + `ShortcutBindingSet.mouse`

**Files:**
- Modify: `hibiki/lib/src/shortcuts/input_binding.dart`（在 `GamepadBinding` 类后、`ShortcutBindingSet` 前加 `MouseBinding`；改 `ShortcutBindingSet`）
- Test: `hibiki/test/shortcuts/input_binding_mouse_test.dart`（新建）

- [ ] **Step 1: 写失败测试**

```dart
// hibiki/test/shortcuts/input_binding_mouse_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';

void main() {
  group('MouseBinding', () {
    test('serialize/deserialize round-trip for known buttons', () {
      for (final b in const [1, 2, 3, 4]) {
        final mb = MouseBinding(b);
        expect(MouseBinding.deserialize(mb.serialize()), mb);
      }
    });

    test('middle button serializes to MouseMiddle', () {
      expect(const MouseBinding(1).serialize(), 'MouseMiddle');
    });

    test('unknown button survives round-trip via Mouse<n>', () {
      final mb = const MouseBinding(7);
      expect(mb.serialize(), 'Mouse7');
      expect(MouseBinding.deserialize('Mouse7'), mb);
    });

    test('deserialize returns null for garbage', () {
      expect(MouseBinding.deserialize('Nope'), isNull);
    });

    test('equality and hashCode by button', () {
      expect(const MouseBinding(1), const MouseBinding(1));
      expect(const MouseBinding(1).hashCode, const MouseBinding(1).hashCode);
      expect(const MouseBinding(1) == const MouseBinding(2), isFalse);
    });
  });

  group('ShortcutBindingSet mouse', () {
    test('round-trips mouse bindings through json', () {
      const set = ShortcutBindingSet(mouseBindings: [MouseBinding(1)]);
      final restored = ShortcutBindingSet.fromJson(set.toJson());
      expect(restored.mouseBindings, [const MouseBinding(1)]);
    });

    test('legacy json without mouse field yields empty mouse list', () {
      final restored = ShortcutBindingSet.fromJson(const {
        'keyboard': <String>[],
        'gamepad': <String>[],
      });
      expect(restored.mouseBindings, isEmpty);
    });

    test('copyWith preserves mouse bindings', () {
      const set = ShortcutBindingSet(mouseBindings: [MouseBinding(1)]);
      expect(set.copyWith().mouseBindings, [const MouseBinding(1)]);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run（worktree 内 `hibiki/`）: `flutter test test/shortcuts/input_binding_mouse_test.dart`
Expected: 编译失败 `MouseBinding` / `mouseBindings` 未定义。

- [ ] **Step 3: 实现 `MouseBinding`（input_binding.dart，`GamepadBinding` 类之后插入）**

```dart
@immutable
class MouseBinding {
  const MouseBinding(this.button);

  /// DOM `MouseEvent.button`: 1=middle, 2=right, 3=back, 4=forward.
  final int button;

  static const Map<int, String> _knownButtons = {
    1: 'MouseMiddle',
    2: 'MouseRight',
    3: 'MouseBack',
    4: 'MouseForward',
  };

  String serialize() => _knownButtons[button] ?? 'Mouse$button';

  static MouseBinding? deserialize(String s) {
    for (final entry in _knownButtons.entries) {
      if (entry.value == s) return MouseBinding(entry.key);
    }
    if (s.startsWith('Mouse')) {
      final n = int.tryParse(s.substring(5));
      if (n != null) return MouseBinding(n);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MouseBinding && button == other.button;

  @override
  int get hashCode => button.hashCode;

  @override
  String toString() => 'MouseBinding(${serialize()})';
}
```

- [ ] **Step 4: 改 `ShortcutBindingSet` 加 `mouseBindings`**

构造函数加 `this.mouseBindings = const []`；字段 `final List<MouseBinding> mouseBindings;`；`toJson` 加 `'mouse': mouseBindings.map((b) => b.serialize()).toList(growable: false)`；`fromJson` 解析 `json['mouse']`（仿 gamepad，缺省 const []）：

```dart
mouseBindings: (json['mouse'] is List)
    ? (json['mouse'] as List)
        .cast<String>()
        .map(MouseBinding.deserialize)
        .whereType<MouseBinding>()
        .toList(growable: false)
    : const [],
```

`copyWith` 加 `List<MouseBinding>? mouseBindings` 参数与 `mouseBindings: mouseBindings ?? this.mouseBindings`。

- [ ] **Step 5: 跑测试确认通过** — `flutter test test/shortcuts/input_binding_mouse_test.dart` → PASS。

- [ ] **Step 6: 提交** — `git add lib/src/shortcuts/input_binding.dart test/shortcuts/input_binding_mouse_test.dart && git commit -m "feat(shortcuts): add MouseBinding to ShortcutBindingSet"`

---

### Task 2: 新动作 + 默认中键 + `resolveMouse` + i18n + `_actionLabel`

**Files:**
- Modify: `hibiki/lib/src/shortcuts/shortcut_action.dart`
- Modify: `hibiki/lib/src/shortcuts/shortcut_defaults.dart`
- Modify: `hibiki/lib/src/shortcuts/shortcut_registry.dart`
- Modify: `hibiki/lib/src/pages/implementations/shortcut_settings_page.dart`（`_actionLabel` 加 case）
- Modify: i18n（经 `tool/i18n_sync.dart`）+ `strings.g.dart`（slang 生成）
- Test: `hibiki/test/shortcuts/shortcut_registry_mouse_test.dart`（新建）；`shortcut_defaults_test.dart`（追加）

- [ ] **Step 1: 写失败测试**

```dart
// hibiki/test/shortcuts/shortcut_registry_mouse_test.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

void main() {
  test('resolveMouse maps default middle button to seek action', () {
    final reg = HibikiShortcutRegistry()..loadDefaults(TargetPlatform.windows);
    expect(
      reg.resolveMouse(1, scope: ShortcutScope.audiobook),
      ShortcutAction.audiobookSeekToClickedSentence,
    );
  });

  test('resolveMouse returns null for unbound button', () {
    final reg = HibikiShortcutRegistry()..loadDefaults(TargetPlatform.windows);
    expect(reg.resolveMouse(2, scope: ShortcutScope.audiobook), isNull);
  });

  test('resolveMouse respects scope', () {
    final reg = HibikiShortcutRegistry()..loadDefaults(TargetPlatform.windows);
    expect(reg.resolveMouse(1, scope: ShortcutScope.reader), isNull);
  });
}
```

追加到 `hibiki/test/shortcuts/shortcut_defaults_test.dart`（main 内）：

```dart
  test('seek-to-clicked-sentence defaults to middle mouse on desktop & mobile',
      () {
    for (final p in const [
      TargetPlatform.windows,
      TargetPlatform.android,
      TargetPlatform.macOS,
    ]) {
      final set =
          ShortcutDefaults.forPlatform(p)[ShortcutAction.audiobookSeekToClickedSentence];
      expect(set, isNotNull, reason: '$p');
      expect(set!.mouseBindings, [const MouseBinding(1)], reason: '$p');
    }
  });
```

（`shortcut_defaults_test.dart` 顶部若无 `input_binding.dart` 导入则补 `import 'package:hibiki/src/shortcuts/input_binding.dart';`。）

- [ ] **Step 2: 跑测试确认失败** — `flutter test test/shortcuts/shortcut_registry_mouse_test.dart test/shortcuts/shortcut_defaults_test.dart` → 编译失败（枚举值 / `resolveMouse` 未定义）。

- [ ] **Step 3: 加枚举值（shortcut_action.dart）**

把 `audiobookPrevSentence(...)` 行尾 `;` 改 `,`，其后新增：

```dart
  audiobookSeekToClickedSentence(
      ShortcutScope.audiobook, 'audiobook_seek_clicked_sentence');
```

- [ ] **Step 4: 加默认中键绑定（shortcut_defaults.dart）**

在 `_desktop` map 的 `audiobookPrevSentence` 条目之后加：

```dart
    // 中键点句 → 跳到该句并播放。鼠标键是位置型动作，运行时不走
    // _executeShortcutAction，而是 onPointerSeek 经 resolveMouse 判定后定位执行。
    ShortcutAction.audiobookSeekToClickedSentence: const ShortcutBindingSet(
      mouseBindings: [MouseBinding(1)],
    ),
```

改 `_mobile` 的 `case ShortcutScope.audiobook:` 分支，保留鼠标绑定（Android 可接鼠标）：

```dart
          case ShortcutScope.audiobook:
            return ShortcutBindingSet(
              gamepadBindings: desktop.gamepadBindings,
              mouseBindings: desktop.mouseBindings,
            );
```

（`_macOS` 由 `_desktop.entries` 派生，鼠标绑定无 ctrl 修饰自动透传，无需改。）

- [ ] **Step 5: 加 `resolveMouse`（shortcut_registry.dart，`resolveGamepad` 之后）**

```dart
  ShortcutAction? resolveMouse(
    int button, {
    required ShortcutScope scope,
  }) {
    final target = MouseBinding(button);
    for (final action in ShortcutAction.actionsForScope(scope)) {
      final bindings = _bindings[action];
      if (bindings == null) continue;
      for (final mb in bindings.mouseBindings) {
        if (mb == target) return action;
      }
    }
    return null;
  }
```

- [ ] **Step 6: i18n key（worktree 内 `hibiki/`）**

Run:
```bash
dart run tool/i18n_sync.dart --add shortcut_action_audiobook_seek_clicked \
  "Seek audio to clicked sentence" "跳转音频到点击的句子"
dart run slang
dart format lib/i18n/strings.g.dart
```

- [ ] **Step 7: `_actionLabel` 加 case（shortcut_settings_page.dart，`audiobookPrevSentence` case 后）**

```dart
    case ShortcutAction.audiobookSeekToClickedSentence:
      return t.shortcut_action_audiobook_seek_clicked;
```

- [ ] **Step 8: 跑测试确认通过** — `flutter test test/shortcuts/` → 全 PASS（若 `shortcut_action_test.dart` 有动作计数断言，按 +1 更新）。

- [ ] **Step 9: 提交** — stage 上述 7 文件（含 `lib/i18n/*.i18n.json` 与 `strings.g.dart`）+ 两测试，`git commit -m "feat(shortcuts): audiobookSeekToClickedSentence action + resolveMouse (default middle)"`

---

### Task 3: JS 原语 `hoshiReader.cueIdAtPoint(x,y)`

**Files:**
- Modify: `hibiki/lib/src/reader/reader_pagination_scripts.dart`（`_sharedJs` 内，`highlightSasayakiCue` 方法附近加方法）
- Test: `hibiki/test/reader/cue_id_at_point_guard_test.dart`（新建，源码扫描守卫）

- [ ] **Step 1: 写失败守卫测试**

```dart
// hibiki/test/reader/cue_id_at_point_guard_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

void main() {
  test('shared reader JS exposes cueIdAtPoint reverse-lookup primitive', () {
    final js = ReaderPaginationScripts.sharedJsForTest;
    expect(js.contains('cueIdAtPoint'), isTrue);
    // 必须复用既有 cue↔DOM 映射，而非重建 normChar 反查。
    expect(js.contains('cueRangesMap'), isTrue);
    expect(js.contains('cueWrappers'), isTrue);
    expect(js.contains("data-cue-id"), isTrue);
  });
}
```

> 注：若 `_sharedJs` 当前为 `private`，加一个测试可见的 `static const String sharedJsForTest = _sharedJs;`（紧邻 `_sharedJs` 定义）。若已有等价 public 访问点，复用之，本步只加测试。

- [ ] **Step 2: 跑测试确认失败** — `flutter test test/reader/cue_id_at_point_guard_test.dart` → FAIL（不含 `cueIdAtPoint` / 无 `sharedJsForTest`）。

- [ ] **Step 3: 在 `_sharedJs` 加 `cueIdAtPoint`（紧接 `highlightSasayakiCue` 方法后，注意 JS 对象成员以逗号分隔）**

```js
  // 反查：把屏幕坐标解析到所属 cue 的标识，供中键 seek 用。先认合成书可点
  // 的 [data-cue-id]（sentenceIndex），否则用 caret 点在 cueRangesMap /
  // cueWrappers（键=textFragmentId）里做包含判定。命中回 JSON.stringify
  // ({type,id})，无命中回 null。复用既有映射，不碰 normChar 反查数学。
  cueIdAtPoint: function(x, y) {
    var el = document.elementFromPoint(x, y);
    if (el && el.closest) {
      var sidEl = el.closest('[data-cue-id]');
      if (sidEl) {
        var sid = sidEl.getAttribute('data-cue-id');
        if (sid !== null) return JSON.stringify({ type: 'sid', id: sid });
      }
    }
    if (!window.hoshiSelection || !window.hoshiSelection.getCaretRange) return null;
    var caret = window.hoshiSelection.getCaretRange(x, y);
    if (!caret) return null;
    var node = caret.startContainer, off = caret.startOffset;
    var found = null;
    if (this.cueRangesMap && this.cueRangesMap.size) {
      this.cueRangesMap.forEach(function(ranges, id) {
        if (found) return;
        for (var i = 0; i < ranges.length; i++) {
          try { if (ranges[i].comparePoint(node, off) === 0) { found = id; break; } }
          catch (e) {}
        }
      });
      if (found) return JSON.stringify({ type: 'frag', id: found });
    }
    if (this.cueWrappers && this.cueWrappers.size) {
      this.cueWrappers.forEach(function(wrappers, id) {
        if (found) return;
        for (var i = 0; i < wrappers.length; i++) {
          if (wrappers[i].contains(node)) { found = id; break; }
        }
      });
      if (found) return JSON.stringify({ type: 'frag', id: found });
    }
    return null;
  },
```

- [ ] **Step 4: 跑测试确认通过** — `flutter test test/reader/cue_id_at_point_guard_test.dart` → PASS。

- [ ] **Step 5: 提交** — `git add lib/src/reader/reader_pagination_scripts.dart test/reader/cue_id_at_point_guard_test.dart && git commit -m "feat(reader): cueIdAtPoint JS primitive for reverse cue lookup"`

---

### Task 4: 纯函数 `cueForPointerPayload` + 正文 JS 监听 + Dart `onPointerSeek`

**Files:**
- Create: `hibiki/lib/src/media/audiobook/pointer_seek.dart`（纯函数 payload→cue）
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`（JS `mousedown` 监听 + `onPointerSeek` handler + 两 helper）
- Test: `hibiki/test/media/audiobook/pointer_seek_test.dart`（新建）；`hibiki/test/reader/pointer_seek_guard_test.dart`（新建源码守卫）

- [ ] **Step 1: 写失败测试（纯函数）**

```dart
// hibiki/test/media/audiobook/pointer_seek_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/audiobook/pointer_seek.dart';

AudioCue _cue({required int sid, required String frag}) => AudioCue(
      bookKey: 'b',
      chapterHref: 'c',
      sentenceIndex: sid,
      textFragmentId: frag,
      text: 't$sid',
      startMs: sid * 1000,
      endMs: sid * 1000 + 500,
      audioFileIndex: 0,
    );

void main() {
  final cues = [
    _cue(sid: 0, frag: 'sasayaki://s=0&ns=0&ne=5'),
    _cue(sid: 1, frag: 'sasayaki://s=0&ns=5&ne=9'),
  ];

  test('frag payload resolves by textFragmentId', () {
    final cue = cueForPointerPayload(
        '{"type":"frag","id":"sasayaki://s=0&ns=5&ne=9"}', cues);
    expect(cue?.sentenceIndex, 1);
  });

  test('sid payload resolves by sentenceIndex (string id)', () {
    final cue = cueForPointerPayload('{"type":"sid","id":"0"}', cues);
    expect(cue?.sentenceIndex, 0);
  });

  test('unmatched id returns null', () {
    expect(cueForPointerPayload('{"type":"frag","id":"nope"}', cues), isNull);
  });

  test('garbage / null payload returns null', () {
    expect(cueForPointerPayload('null', cues), isNull);
    expect(cueForPointerPayload('not json', cues), isNull);
  });
}
```

> 注：`AudioCue` 构造参数名以 `audiobook_model.dart` 实际定义为准；执行时先打开该文件对齐字段（`bookKey`/`chapterHref`/`sentenceIndex`/`textFragmentId`/`text`/`startMs`/`endMs`/`audioFileIndex`）。

- [ ] **Step 2: 跑测试确认失败** — `flutter test test/media/audiobook/pointer_seek_test.dart` → 编译失败（`cueForPointerPayload` / `pointer_seek.dart` 不存在）。

- [ ] **Step 3: 实现纯函数（新建 pointer_seek.dart）**

```dart
import 'dart:convert';

import 'package:hibiki_audio/hibiki_audio.dart';

/// 把 `hoshiReader.cueIdAtPoint` 回传的 JSON（`{type,id}`）解析到 [allCues]
/// 里的目标 cue。`type=='sid'` 按 sentenceIndex（字符串 id），`type=='frag'`
/// 按 textFragmentId。无法解析或无命中返回 null。
AudioCue? cueForPointerPayload(String json, List<AudioCue> allCues) {
  if (json.isEmpty || json == 'null') return null;
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) return null;
    final String? type = decoded['type'] as String?;
    if (type == 'sid') {
      final int sid = int.tryParse('${decoded['id']}') ?? -1;
      final int i = allCues.indexWhere((c) => c.sentenceIndex == sid);
      return i >= 0 ? allCues[i] : null;
    }
    if (type == 'frag') {
      final String fragId = '${decoded['id']}';
      final int i = allCues.indexWhere((c) => c.textFragmentId == fragId);
      return i >= 0 ? allCues[i] : null;
    }
  } catch (_) {}
  return null;
}

/// 单一真相：哪些 DOM 鼠标按钮触发「seek 到点击句」由快捷键注册表决定。
/// （封装供阅读器与歌词两处复用同一判定。）
```

（若需 `isPointerSeekButton` 复用，可在此加；但注册表 `resolveMouse` 已是真相源，阅读器直接调即可，避免重复封装——YAGNI，不加。）

- [ ] **Step 4: 跑测试确认通过** — `flutter test test/media/audiobook/pointer_seek_test.dart` → PASS。提交纯函数：`git add lib/src/media/audiobook/pointer_seek.dart test/media/audiobook/pointer_seek_test.dart && git commit -m "feat(audiobook): pure cueForPointerPayload lookup"`

- [ ] **Step 5: 正文 JS 加中键监听（reader_hibiki_page.dart，`pointerup` 监听后、`selectstart` 监听前，约 :1668）**

```js
  // 非左键（中键/侧键）：上报 Dart，由 resolveMouse 判定是否绑定「seek 到点击句」。
  // mousedown 一定触发，preventDefault 压掉中键自动滚动。触屏合成事件 button 恒 0，
  // 被首行排除，不干扰。
  document.addEventListener('mousedown', function(e) {
    if (e.button === 0) return;
    e.preventDefault();
    window.flutter_inappwebview.callHandler('onPointerSeek', e.button, e.clientX, e.clientY);
  }, {passive: false});
```

- [ ] **Step 6: Dart 加 `onPointerSeek` handler + 两 helper（reader_hibiki_page.dart，`onCueTap` handler 后，约 :1958）**

handler：

```dart
        controller.addJavaScriptHandler(
          handlerName: 'onPointerSeek',
          callback: (List<dynamic> args) async {
            if (args.length < 3 || _audiobookController == null) return;
            final int button = (args[0] as num?)?.toInt() ?? -1;
            if (!_isSeekToClickedSentenceButton(button)) return;
            final double x = _toDouble(args[1]) ?? 0;
            final double y = _toDouble(args[2]) ?? 0;
            await _seekToClickedSentence(x, y);
          },
        );
```

helper（放在 `_executeShortcutAction` 附近的有声书相关私有方法区）：

```dart
  bool _isSeekToClickedSentenceButton(int button) {
    if (button < 0) return false;
    return appModel.shortcutRegistry.resolveMouse(
          button,
          scope: ShortcutScope.audiobook,
        ) ==
        ShortcutAction.audiobookSeekToClickedSentence;
  }

  Future<void> _seekToClickedSentence(double x, double y) async {
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null) return;
    final Object? raw = await _controller?.evaluateJavascript(
      source: 'window.hoshiReader && window.hoshiReader.cueIdAtPoint'
          ' ? window.hoshiReader.cueIdAtPoint($x, $y) : null',
    );
    if (raw is! String) return;
    final List<AudioCue>? allCues = _cachedAllCues;
    if (allCues == null) return;
    final AudioCue? cue = cueForPointerPayload(raw, allCues);
    if (cue != null) controller.playCueAndContinue(cue);
  }
```

确认顶部已 `import` `pointer_seek.dart`（`import 'package:hibiki/src/media/audiobook/pointer_seek.dart';`）；`ShortcutScope`/`ShortcutAction` 已由现有快捷键导入提供（`_handleKeyEvent` 已用）。

- [ ] **Step 7: 写并跑源码守卫测试**

```dart
// hibiki/test/reader/pointer_seek_guard_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reader page wires middle-button onPointerSeek to cueIdAtPoint seek', () {
    final src = File('lib/src/pages/implementations/reader_hibiki_page.dart')
        .readAsStringSync();
    expect(src.contains("handlerName: 'onPointerSeek'"), isTrue);
    expect(src.contains("'mousedown'"), isTrue);
    expect(src.contains('cueIdAtPoint'), isTrue);
    expect(src.contains('_isSeekToClickedSentenceButton'), isTrue);
    expect(src.contains('playCueAndContinue'), isTrue);
  });
}
```

Run: `flutter test test/reader/pointer_seek_guard_test.dart` → PASS。

- [ ] **Step 8: analyze + 提交** — `flutter analyze lib/src/pages/implementations/reader_hibiki_page.dart`（0 issue）；`git add lib/src/pages/implementations/reader_hibiki_page.dart test/reader/pointer_seek_guard_test.dart && git commit -m "feat(reader): middle-click seek to clicked sentence (reader surface)"`

---

### Task 5: 歌词模式中键 → `onLyricsPointerSeek`

**Files:**
- Modify: `hibiki/lib/src/media/audiobook/lyrics_mode_html.dart`（加 `mousedown` 监听）
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`（加 `onLyricsPointerSeek` handler）
- Test: `hibiki/test/media/audiobook/lyrics_pointer_seek_guard_test.dart`（新建源码守卫）

- [ ] **Step 1: 写失败守卫测试**

```dart
// hibiki/test/media/audiobook/lyrics_pointer_seek_guard_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/lyrics_mode_html.dart';

void main() {
  test('lyrics html wires middle-button seek via data-cue-index', () {
    // 用最小 cue 列表生成歌词 HTML，断言中键接线存在。
    final html = LyricsModeHtml.buildForTest();
    expect(html.contains("'mousedown'"), isTrue);
    expect(html.contains('onLyricsPointerSeek'), isTrue);
    expect(html.contains('data-cue-index'), isTrue);
  });
}
```

> 注：`LyricsModeHtml` 实际生成入口/签名以文件为准；执行时打开 `lyrics_mode_html.dart` 用真实的构建方法（必要时加一个 `buildForTest()` 薄封装传最小 cue 列表），不要臆造 API。

- [ ] **Step 2: 跑测试确认失败** — FAIL（不含 `onLyricsPointerSeek`）。

- [ ] **Step 3: 歌词 JS 加中键监听（lyrics_mode_html.dart，现有 click 监听 :195 之后）**

```js
// 中键点句 → seek 到该 cue 并播放（标准 click 不触发中键，单列 mousedown）。
document.getElementById('lc').addEventListener('mousedown', function(e) {
  if (e.button === 0) return;
  var el = e.target.closest('.cue');
  if (!el) return;
  e.preventDefault();
  var idx = parseInt(el.getAttribute('data-cue-index'), 10);
  if (isNaN(idx)) return;
  window.flutter_inappwebview.callHandler('onLyricsPointerSeek', e.button, idx);
});
```

- [ ] **Step 4: Dart 加 `onLyricsPointerSeek` handler（reader_hibiki_page.dart，紧接 `onPointerSeek` handler 后）**

```dart
        controller.addJavaScriptHandler(
          handlerName: 'onLyricsPointerSeek',
          callback: (List<dynamic> args) {
            if (args.length < 2 || _audiobookController == null) return;
            final int button = (args[0] as num?)?.toInt() ?? -1;
            if (!_isSeekToClickedSentenceButton(button)) return;
            final int idx = (args[1] as num?)?.toInt() ?? -1;
            if (idx < 0 || idx >= _lyricsCueList.length) return;
            _audiobookController!.playCueAndContinue(_lyricsCueList[idx]);
          },
        );
```

- [ ] **Step 5: 跑守卫测试 + analyze** — `flutter test test/media/audiobook/lyrics_pointer_seek_guard_test.dart` → PASS；`flutter analyze lib/src/media/audiobook/lyrics_mode_html.dart lib/src/pages/implementations/reader_hibiki_page.dart` → 0。

- [ ] **Step 6: 提交** — `git add lib/src/media/audiobook/lyrics_mode_html.dart lib/src/pages/implementations/reader_hibiki_page.dart test/media/audiobook/lyrics_pointer_seek_guard_test.dart && git commit -m "feat(lyrics): middle-click seek to clicked cue (lyrics surface)"`

---

### Task 6: 全量验证 + 收尾

- [ ] **Step 1: `dart format .`（worktree 内 `hibiki/`）**
- [ ] **Step 2: `flutter analyze`** → 0 issue（至少本功能触及文件）。
- [ ] **Step 3: `flutter test`** → 全绿（关注 `test/shortcuts/`、`test/reader/`、`test/media/audiobook/`、`test/i18n/`）。
- [ ] **Step 4: 代码审查** — 调 `superpowers:requesting-code-review`，spawn code-reviewer 子代理（`model: "opus"`）。
- [ ] **Step 5: 修审查问题后再次 `flutter test` 全绿。**
- [ ] **Step 6: BUGS/文档** — 本功能为新增非 bug，不记 BUGS.md。真机三表面（Sasayaki/合成书/歌词）中键 seek+播放复测留待用户。

---

## 自检

- **Spec 覆盖**：行为(playCueAndContinue)=Task4/5；选型 A(cueIdAtPoint 复用映射)=Task3；绑定进体系默认中键=Task1/2；设置页隐藏=不动 `settings_schema.dart` 注释；三表面=Task3(sasayaki+合成书)/Task5(歌词)；向后兼容(旧 JSON 无 mouse)=Task1 测试覆盖。✅
- **占位符**：无 TBD/TODO；每步含真实代码与命令。✅（两处「以实际文件为准」注解是执行护栏，非占位——`AudioCue` 字段名与 `LyricsModeHtml` 构建签名执行时对齐。）
- **类型一致**：`MouseBinding(int)` 全程一致；`resolveMouse(int,{required scope})` Task2 定义、Task4 调用一致；`cueForPointerPayload(String,List<AudioCue>)` Task4 定义/调用一致；handler 名 `onPointerSeek`/`onLyricsPointerSeek` JS 与 Dart 一致。✅
