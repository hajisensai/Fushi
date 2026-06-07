# 桌面剪贴板查词 实现计划（线4）

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** 桌面（Win/mac/Linux）监听系统剪贴板变化 + 全局热键 → 把 Hibiki 主窗口唤到前台（可选置顶）→ 窗口内弹「分词可点」查词 overlay。

**Architecture:** 新依赖 clipboard_watcher（剪贴板事件）+ hotkey_manager（全局热键）+ window_manager（唤前台/置顶）。`DesktopLookupService`（单例 ChangeNotifier，仿 texthooker host）监听剪贴板+热键 → lastText 去重 → 设「待查文本」+ notify。宿主 overlay（复用 texthooker_page 的分词可点 + DictionaryPageMixin）订阅它弹查词浮层。设置开关默认关，仅桌面可见，开机自启。

**Tech Stack:** Dart, clipboard_watcher 0.3.0, hotkey_manager 0.2.3, window_manager 0.5.1。

依据：`docs/specs/2026-06-05-webext-and-desktop-clipboard-design.md` §5。

---

## 文件结构
- Modify: `hibiki/pubspec.yaml`（加 3 依赖）
- Modify: `hibiki/lib/main.dart`（桌面 windowManager.ensureInitialized + hotKeyManager.unregisterAll）
- Modify: `hibiki/lib/src/models/preferences_repository.dart` + `app_model.dart`（偏好 + 转发 + 自启）
- Create: `hibiki/lib/src/sync/clipboard_dedupe.dart`（纯函数）
- Create: `hibiki/lib/src/sync/desktop_lookup_service.dart`（剪贴板+热键监听单例）
- Create: `hibiki/lib/src/pages/implementations/desktop_lookup_overlay.dart`（宿主 overlay，复用 texthooker 范式）
- Modify: `hibiki/lib/src/pages/implementations/home_page.dart`（挂 overlay 宿主）
- Modify: `hibiki/lib/src/settings/settings_schema.dart` + i18n + `test/settings/settings_schema_coverage_test.dart`
- Tests: `clipboard_dedupe_test.dart`、`desktop_lookup_overlay_test.dart`、`preferences_repository_test.dart`(追加)

---

## Task 1: 加 3 依赖 + main.dart 桌面初始化

**Files:** Modify `hibiki/pubspec.yaml`、`hibiki/lib/main.dart`

- [ ] **Step 1: pubspec 加依赖**（在 web_socket_channel 附近）
```yaml
  clipboard_watcher: ^0.3.0
  hotkey_manager: ^0.2.3
  window_manager: ^0.5.1
```
- [ ] **Step 2: pub get**（worktree hibiki 下）`flutter pub get`，确认三包 direct main（`grep -A1 '^  window_manager:' pubspec.lock`）。
- [ ] **Step 3: main.dart 桌面初始化**——读 main.dart，在 `WidgetsFlutterBinding.ensureInitialized()`（约 L76）之后加桌面门控初始化：
```dart
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    await hotKeyManager.unregisterAll(); // 热重载清理残留全局热键
  }
```
import `package:window_manager/window_manager.dart`、`package:hotkey_manager/hotkey_manager.dart`。（`Platform` 来自已 import 的 dart:io。）
- [ ] **Step 4: 验证**（worktree hibiki）`flutter analyze lib/main.dart` → 0 issue（含新 import）。
- [ ] **Step 5: 提交**
```bash
cd "D:/APP/vs_claude_code/hibiki/.claude/worktrees/yomitan-compat"
git add hibiki/pubspec.yaml hibiki/pubspec.lock hibiki/lib/main.dart
git diff --cached --check && git commit -m "build(deps): add clipboard_watcher/hotkey_manager/window_manager + desktop init"
```

---

## Task 2: clipboard 去重纯函数

**Files:** Create `hibiki/lib/src/sync/clipboard_dedupe.dart`、Test `hibiki/test/sync/clipboard_dedupe_test.dart`

- [ ] **Step 1: 写失败测试**
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/clipboard_dedupe.dart';

void main() {
  group('dedupeClipboard', () {
    test('trims and returns new text', () {
      expect(dedupeClipboard('  見る  ', null), '見る');
    });
    test('returns null when same as last (after trim)', () {
      expect(dedupeClipboard('見る', '見る'), isNull);
      expect(dedupeClipboard('  見る ', '見る'), isNull);
    });
    test('returns null for empty/blank', () {
      expect(dedupeClipboard('', null), isNull);
      expect(dedupeClipboard('   ', null), isNull);
    });
    test('returns new text when changed', () {
      expect(dedupeClipboard('読む', '見る'), '読む');
    });
  });
}
```
- [ ] **Step 2: 确认失败** `flutter test test/sync/clipboard_dedupe_test.dart` → FAIL。
- [ ] **Step 3: 写实现**
```dart
// hibiki/lib/src/sync/clipboard_dedupe.dart

/// 剪贴板去重：trim 后为空或与 [last] 相同返回 null（不触发查词），
/// 否则返回 trim 后的新文本。避免挖词/复制写回剪贴板时自触发循环。
String? dedupeClipboard(String raw, String? last) {
  final String trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed == last) return null;
  return trimmed;
}
```
- [ ] **Step 4: 确认通过** → PASS（4 tests）。
- [ ] **Step 5: 提交**
```bash
git add hibiki/lib/src/sync/clipboard_dedupe.dart hibiki/test/sync/clipboard_dedupe_test.dart
git diff --cached --check && git commit -m "feat(desktop-clip): add clipboard dedupe pure fn"
```

---

## Task 3: 偏好（enabled + always_on_top）

**Files:** Modify `preferences_repository.dart` + `app_model.dart`、Test 追加 `preferences_repository_test.dart`

- [ ] **Step 1: 追加测试**（仿现有 texthooker round-trip）
```dart
  test('desktop clipboard prefs round-trip', () async {
    expect(repo.desktopClipboardEnabled, false);
    expect(repo.desktopClipboardAlwaysOnTop, false);
    await repo.setDesktopClipboardEnabled(true);
    await repo.setDesktopClipboardAlwaysOnTop(true);
    expect(repo.desktopClipboardEnabled, true);
    expect(repo.desktopClipboardAlwaysOnTop, true);
    final repo2 = PreferencesRepository(db);
    await repo2.loadFromDb();
    expect(repo2.desktopClipboardEnabled, true);
    expect(repo2.desktopClipboardAlwaysOnTop, true);
  });
```
（`db`/`repo2` 构造对齐同文件现有写法。）
- [ ] **Step 2: 确认失败** → FAIL（getter 未定义）。
- [ ] **Step 3: 写实现**——`preferences_repository.dart`（texthooker 段之后）：
```dart
  bool get desktopClipboardEnabled =>
      getPref('desktop_clipboard_enabled', defaultValue: false) as bool;
  Future<void> setDesktopClipboardEnabled(bool value) async {
    await setPref('desktop_clipboard_enabled', value);
    notifyListeners();
  }
  bool get desktopClipboardAlwaysOnTop =>
      getPref('desktop_clipboard_always_on_top', defaultValue: false) as bool;
  Future<void> setDesktopClipboardAlwaysOnTop(bool value) async {
    await setPref('desktop_clipboard_always_on_top', value);
    notifyListeners();
  }
```
`app_model.dart`（texthooker 转发之后）：
```dart
  bool get desktopClipboardEnabled => prefsRepo.desktopClipboardEnabled;
  Future<void> setDesktopClipboardEnabled(bool v) =>
      prefsRepo.setDesktopClipboardEnabled(v);
  bool get desktopClipboardAlwaysOnTop => prefsRepo.desktopClipboardAlwaysOnTop;
  Future<void> setDesktopClipboardAlwaysOnTop(bool v) =>
      prefsRepo.setDesktopClipboardAlwaysOnTop(v);
```
- [ ] **Step 4: 确认通过** → PASS。
- [ ] **Step 5: 提交**
```bash
git add hibiki/lib/src/models/preferences_repository.dart hibiki/lib/src/models/app_model.dart hibiki/test/models/preferences_repository_test.dart
git diff --cached --check && git commit -m "feat(desktop-clip): add prefs (enabled + always_on_top)"
```

---

## Task 4: DesktopLookupService（剪贴板+热键监听）

**Files:** Create `hibiki/lib/src/sync/desktop_lookup_service.dart`、Test `hibiki/test/sync/desktop_lookup_service_test.dart`

- [ ] **Step 1: 写测试**（监听难单测；测可注入的「文本喂入 → notify + pendingText」+ 去重，平台原生部分用源码守卫由 reviewer 检）
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';

void main() {
  setUp(() => DesktopLookupService.instance.debugReset());

  test('submitText sets pendingText and notifies, deduped', () {
    int n = 0;
    void l() => n++;
    DesktopLookupService.instance.addListener(l);
    DesktopLookupService.instance.submitText('  見る ');
    expect(DesktopLookupService.instance.pendingText, '見る');
    expect(n, 1);
    DesktopLookupService.instance.submitText('見る'); // 同上句，去重不 notify
    expect(n, 1);
    DesktopLookupService.instance.submitText('読む');
    expect(DesktopLookupService.instance.pendingText, '読む');
    expect(n, 2);
    DesktopLookupService.instance.removeListener(l);
  });

  test('clearPending resets pendingText', () {
    DesktopLookupService.instance.submitText('見る');
    DesktopLookupService.instance.clearPending();
    expect(DesktopLookupService.instance.pendingText, isNull);
  });
}
```
- [ ] **Step 2: 确认失败** → FAIL。
- [ ] **Step 3: 写实现**（`submitText` 纯逻辑可测；剪贴板/热键监听走平台门控，调 submitText）
```dart
// hibiki/lib/src/sync/desktop_lookup_service.dart
import 'dart:io';

import 'package:clipboard_watcher/clipboard_watcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'package:hibiki/src/sync/clipboard_dedupe.dart';

/// 桌面剪贴板 + 全局热键查词触发器。单例 ChangeNotifier（仿 TexthookerService）。
/// 监听系统剪贴板变化与全局热键 → 去重 → 设 pendingText + 唤主窗前台 → 宿主 overlay 订阅查词。
class DesktopLookupService extends ChangeNotifier with ClipboardListener {
  DesktopLookupService._();
  static final DesktopLookupService instance = DesktopLookupService._();

  static bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  String? _pendingText;
  String? get pendingText => _pendingText;
  String? _lastText;
  bool _running = false;
  bool _alwaysOnTop = false;
  HotKey? _hotKey;

  bool get isRunning => _running;

  /// 提交一段待查文本（剪贴板/热键回调统一入口，纯逻辑，可测）。
  void submitText(String raw) {
    final String? deduped = dedupeClipboard(raw, _lastText);
    if (deduped == null) return;
    _lastText = deduped;
    _pendingText = deduped;
    notifyListeners();
  }

  void clearPending() {
    _pendingText = null;
    notifyListeners();
  }

  @visibleForTesting
  void debugReset() {
    _pendingText = null;
    _lastText = null;
  }

  Future<void> start({required bool alwaysOnTop}) async {
    if (!isDesktop || _running) return;
    _running = true;
    _alwaysOnTop = alwaysOnTop;
    clipboardWatcher.addListener(this);
    await clipboardWatcher.start();
    _hotKey = HotKey(
      key: PhysicalKeyboardKey.keyD,
      modifiers: <HotKeyModifier>[HotKeyModifier.control, HotKeyModifier.shift],
      scope: HotKeyScope.system,
    );
    await hotKeyManager.register(_hotKey!, keyDownHandler: (_) => _onHotKey());
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    clipboardWatcher.removeListener(this);
    await clipboardWatcher.stop();
    await hotKeyManager.unregisterAll();
    _hotKey = null;
  }

  @override
  Future<void> onClipboardChanged() async {
    final ClipboardData? d = await Clipboard.getData(Clipboard.kTextPlain);
    final String text = d?.text ?? '';
    if (text.trim().isEmpty) return;
    submitText(text);
    await _bringToFront();
  }

  Future<void> _onHotKey() async {
    final ClipboardData? d = await Clipboard.getData(Clipboard.kTextPlain);
    final String text = d?.text ?? '';
    if (text.trim().isEmpty) return;
    // 热键强制查（即便与上次相同）：重置 lastText 让其通过去重。
    _lastText = null;
    submitText(text);
    await _bringToFront();
  }

  Future<void> _bringToFront() async {
    if (!isDesktop) return;
    await windowManager.show();
    await windowManager.focus();
    if (_alwaysOnTop) await windowManager.setAlwaysOnTop(true);
  }
}
```
- [ ] **Step 4: 确认通过** Run: `flutter test test/sync/desktop_lookup_service_test.dart`（submitText/clearPending 测试不触发平台原生，应过）→ PASS。`flutter analyze lib/src/sync/desktop_lookup_service.dart` → 0 issue。
- [ ] **Step 5: 提交**
```bash
git add hibiki/lib/src/sync/desktop_lookup_service.dart hibiki/test/sync/desktop_lookup_service_test.dart
git diff --cached --check && git commit -m "feat(desktop-clip): add DesktopLookupService (clipboard+hotkey)"
```

---

## Task 5: 宿主 overlay（复用 texthooker 分词可点）

**Files:** Create `hibiki/lib/src/pages/implementations/desktop_lookup_overlay.dart`、Modify `home_page.dart`（挂宿主）、Test `hibiki/test/pages/desktop_lookup_overlay_test.dart`

- [ ] **Step 1: 写 widget 测试**（喂 service 文本 → 验渲染；不依赖 FFI，引擎未初始化 textToWords 逐字降级）
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/pages/implementations/desktop_lookup_overlay.dart';

void main() {
  setUp(() => DesktopLookupService.instance.debugReset());

  testWidgets('shows pending clipboard text reactively, closeable', (tester) async {
    await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: Scaffold(body: DesktopLookupOverlay()))));
    await tester.pump();
    expect(find.textContaining('見'), findsNothing);

    DesktopLookupService.instance.submitText('見る');
    await tester.pump();
    expect(find.textContaining('見'), findsWidgets);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.textContaining('見'), findsNothing);
  });
}
```
- [ ] **Step 2: 确认失败** → FAIL（URI 不存在）。
- [ ] **Step 3: 写实现**（仿 texthooker_page 的分词可点 + DictionaryPageMixin；pendingText 非空时显示卡片）
```dart
// hibiki/lib/src/pages/implementations/desktop_lookup_overlay.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import 'package:hibiki/models.dart'; // AppModel + appProvider
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/pages/implementations/dictionary_page_mixin.dart';

/// 桌面剪贴板查词 overlay：订阅 DesktopLookupService.pendingText，
/// 显示分词可点卡片 + 查词浮层（复用 texthooker 范式）。挂在主 app 顶层 Stack。
class DesktopLookupOverlay extends ConsumerStatefulWidget {
  const DesktopLookupOverlay({super.key});
  @override
  ConsumerState<DesktopLookupOverlay> createState() => _DesktopLookupOverlayState();
}

class _DesktopLookupOverlayState extends ConsumerState<DesktopLookupOverlay>
    with DictionaryPageMixin {
  final List<NestedPopupEntry> _popupStack = <NestedPopupEntry>[];

  @override
  AppModel get mixinAppModel => ref.read(appProvider);
  @override
  ThemeData get mixinTheme => Theme.of(context);

  @override
  void initState() {
    super.initState();
    DesktopLookupService.instance.addListener(_onPending);
  }

  @override
  void dispose() {
    DesktopLookupService.instance.removeListener(_onPending);
    super.dispose();
  }

  void _onPending() {
    if (!mounted) return;
    setState(() {});
  }

  void _close() {
    _popupStack.clear();
    DesktopLookupService.instance.clearPending();
  }

  void _onWordTap(String word, Rect rect) {
    pushNestedPopup(
        query: word, selectionRect: rect, popupStack: _popupStack,
        replaceStack: true, autoRead: true);
  }

  @override
  Widget build(BuildContext context) {
    final String? text = DesktopLookupService.instance.pendingText;
    if (text == null) return const SizedBox.shrink();
    final List<String> words = JapaneseLanguage.instance.textToWords(text);
    return Positioned.fill(
      child: Stack(
        children: <Widget>[
          Positioned(
            right: 16, top: 16, width: 360,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: _close,
                    ),
                    Wrap(
                      children: <Widget>[
                        for (final String w in words)
                          _ClipWordSpan(word: w, onTap: _onWordTap),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          for (int i = 0; i < _popupStack.length; i++)
            buildNestedPopupLayer(
              index: i,
              screen: MediaQuery.sizeOf(context),
              popupStack: _popupStack,
              onPush: (String t, Rect r) =>
                  pushNestedPopup(query: t, selectionRect: r, popupStack: _popupStack),
              onPop: (int idx) => popNestedPopupAt(idx, _popupStack),
            ),
        ],
      ),
    );
  }
}

class _ClipWordSpan extends StatelessWidget {
  const _ClipWordSpan({required this.word, required this.onTap});
  final String word;
  final void Function(String word, Rect rect) onTap;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapUp: (TapUpDetails d) {
        final RenderBox box = context.findRenderObject()! as RenderBox;
        onTap(word, box.localToGlobal(Offset.zero) & box.size);
      },
      child: Text(word,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.6)),
    );
  }
}
```
（注意：用 `Theme.textTheme.bodyLarge` 而非裸 fontSize——md3 守卫禁裸 fontSize，texthooker 已踩过。）
在 `home_page.dart` 的顶层 build 把 `DesktopLookupOverlay` 叠加进根 Stack（仅桌面，门控 `if (DesktopLookupService.isDesktop)`）——读 home_page build 找合适根容器，用 Stack 包裹现有 body + overlay。
- [ ] **Step 4: 确认通过** Run: `flutter test test/pages/desktop_lookup_overlay_test.dart` → PASS。`flutter analyze` 改动文件 + `flutter test test/settings/md3_design_system_static_test.dart`（守卫，确认无裸 fontSize）→ 绿。
- [ ] **Step 5: 提交**
```bash
git add hibiki/lib/src/pages/implementations/desktop_lookup_overlay.dart hibiki/lib/src/pages/implementations/home_page.dart hibiki/lib/pages.dart hibiki/test/pages/desktop_lookup_overlay_test.dart
git diff --cached --check && git commit -m "feat(desktop-clip): add lookup overlay (reuse texthooker word-tap)"
```

---

## Task 6: 设置开关 + 覆盖登记 + i18n + 生命周期接线

**Files:** Modify `settings_schema.dart`、i18n、`settings_schema_coverage_test.dart`、`app_model.dart`（自启）

- [ ] **Step 1: i18n**（worktree hibiki 下）
```bash
dart tool/i18n_sync.dart --add desktop_clipboard_enabled "Desktop clipboard lookup" "桌面剪贴板查词"
dart tool/i18n_sync.dart --add desktop_clipboard_enabled_hint "Watch clipboard + global hotkey to pop a lookup window (desktop)" "监听剪贴板+全局热键弹出查词窗（桌面）"
dart tool/i18n_sync.dart --add desktop_clipboard_always_on_top "Keep lookup window on top" "查词时窗口置顶"
dart run slang && dart format lib/i18n/strings.g.dart
```
- [ ] **Step 2: settings_schema 开关**（lookup_behavior section，仿 lookup.texthooker；仅桌面可见用 visible）
```dart
SettingsSwitchItem(
  id: 'lookup.desktop_clipboard',
  title: t.desktop_clipboard_enabled,
  subtitle: t.desktop_clipboard_enabled_hint,
  icon: Icons.content_paste_search,
  visible: (SettingsContext c) => DesktopLookupService.isDesktop,
  value: (SettingsContext c) => c.appModel.desktopClipboardEnabled,
  onChanged: (SettingsContext c, bool value) async {
    await c.appModel.setDesktopClipboardEnabled(value);
    if (value) {
      await DesktopLookupService.instance
          .start(alwaysOnTop: c.appModel.desktopClipboardAlwaysOnTop);
    } else {
      await DesktopLookupService.instance.stop();
    }
    c.refresh();
  },
),
```
（确认 `SettingsSwitchItem` 有 `visible` 参数——前面 yomitan/texthooker 开关未用 visible，需核对 `settings_destination.dart` 的 SettingsItem 是否支持 visible；调研提到 SettingsItem 构造有可选 `visible`。若签名不符按真实调整。）
import `desktop_lookup_service.dart`。
- [ ] **Step 3: 覆盖守卫登记**——`settings_schema_coverage_test.dart` 的 `kCoveredElsewhere` 加（key 用英文标题）：
```dart
  'lookup/Desktop clipboard lookup':
      'DEVICE: clipboard watcher + hotkey lifecycle (test/sync/desktop_lookup_service_test.dart)',
```
- [ ] **Step 4: 开机自启**——`app_model.dart` initialise 尾部（texthooker 自启之后，notifyListeners 之前，约 L1221 后）：
```dart
    if (desktopClipboardEnabled && DesktopLookupService.isDesktop) {
      unawaited(DesktopLookupService.instance
          .start(alwaysOnTop: desktopClipboardAlwaysOnTop)
          .catchError((Object _) {}));
    }
```
import `desktop_lookup_service.dart` + `dart:async`(unawaited 若未 import)。
- [ ] **Step 5: 验证**（worktree hibiki）`dart format . && flutter analyze && flutter test test/sync test/settings test/models/preferences_repository_test.dart` → analyze 0 + 相关绿（特别 settings_schema_coverage_test 转绿）。
- [ ] **Step 6: 提交**
```bash
git add hibiki/lib/src/settings/settings_schema.dart hibiki/lib/i18n/ hibiki/test/settings/settings_schema_coverage_test.dart hibiki/lib/src/models/app_model.dart
git diff --cached --check && git commit -m "feat(desktop-clip): wire settings toggle + lifecycle + autostart"
```

---

## Self-Review
- Spec §5.1 依赖（Task 1）、§5.2 DesktopLookupService 去重+门控+唤前台（Task 2/4）、§5.3 宿主 overlay 分词可点（Task 5）、§5.4 设置+守卫+i18n+自启（Task 3/6）。
- 占位符：`SettingsSwitchItem.visible` 与 home_page 根 Stack 挂载点标注「按真实签名/结构对齐」——是接入现有结构的合理裁量，非代码留白（核心 service/overlay/纯函数均完整代码）。
- 类型一致：`dedupeClipboard(String,String?)→String?`、`DesktopLookupService.instance/submitText/clearPending/pendingText/start({alwaysOnTop})/stop/isDesktop/debugReset`、偏好 `desktopClipboardEnabled/AlwaysOnTop`、overlay 复用 mixin 签名，各 Task 一致。
- 真桌面验证留用户（复制文本/热键 → 唤前台 → overlay 分词可点查词挖词；macOS 全局热键权限；Linux keybinder-3.0）。
