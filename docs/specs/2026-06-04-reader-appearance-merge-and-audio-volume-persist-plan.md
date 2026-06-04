# 阅读器外观卡片合并 + 有声书音量持久化 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 书内「排版设置」把主题并入字号/行高/段落缩进/视图模式同一张卡片（行间分割线、无大间隔），编辑书籍 CSS 留在最下面独立卡；并补齐有声书音量的按书持久化（音量当前完全不保存）。

**Architecture:**
- UI：`_buildAppearanceInline` 不再单独渲染主题卡 + appearance 卡两张，而是把「主题」作为 appearance 分组的第一个 `SettingsCustomItem` 前插，复用同一个 `buildReaderGroupDestination` → 一个 `SettingsSection` → 一张 `AdaptiveSettingsSection` 卡。主题行仍用自己的 theme-sync `SettingsContext`（保留 reader 实时换肤 + 词典/歌词联动），其余 appearance 行用面板的普通 `_settingsContext()`。
- 持久化：镜像现有 speed/delay/imagePause 三件套（`onXxxPersist` 回调 + `load(initialXxx:)` + repo `readXxx`/`updateXxx`）给 volume 补一套；reader 两条控制器初始化路径（audiobook / srt）各接一遍。speed 经核查已正确配线，不改运行期路径，仅加守卫测试。

**Tech Stack:** Flutter 3.44 / Dart 3.12，Riverpod，Drift（preferences 表），just_audio，schema-projected settings。

---

## File Structure

- `packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart` — 加 `onVolumePersist` 回调、`setVolume` 落持久化、`load(initialVolume:)` 应用。
- `packages/hibiki_audio/lib/src/audiobook/audiobook_repository.dart` — 加 `readVolume` / `updateVolume`（`audiobook_volume_<uid>` 前缀）。
- `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` — 两条 controller 初始化路径读音量、传 `initialVolume`、接 `onVolumePersist`。
- `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart` — 重写 `_buildAppearanceInline`，删 `_buildThemeSelector()`，加 `_themeSettingsContext()`。
- `hibiki/test/media/audiobook/reader_quick_settings_sheet_static_test.dart` — 更新内联区结构断言（主题前插为 custom item）。
- `packages/hibiki_audio/test/audiobook/audiobook_volume_persist_test.dart`（新建）— repo 往复 + 控制器 setVolume 落回调。
- `hibiki/test/media/audiobook/audio_persist_wiring_static_test.dart`（新建）— 源码守卫：volume/speed 在控制器 + reader 两路径都已配线。

---

## Task 1: 控制器音量持久化原语

**Files:**
- Modify: `packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart`（`setVolume` ~191、`load` ~298、回调声明区 ~186）

- [ ] **Step 1: 加 `onVolumePersist` 回调声明**

在 `onSpeedPersist` 声明之后（约 186-187 行）追加：

```dart
  /// 音量变化时的持久化回调。内部在 [setVolume] 调用（与 [onSpeedPersist] 同型）。
  Future<void> Function(double volume)? onVolumePersist;
```

- [ ] **Step 2: `setVolume` 落持久化（镜像 setSpeed 的同值跳过逻辑）**

把现有 `setVolume`（约 191-194）替换为：

```dart
  Future<void> setVolume(double v) async {
    final double clamped = v.clamp(0.0, 2.0);
    final double prev = _player.volume;
    await _player.setVolume(clamped);
    notifyListeners();
    if ((clamped - prev).abs() < 0.001) return;
    final Future<void> Function(double)? persist = onVolumePersist;
    if (persist != null) {
      unawaited(persist(clamped));
    }
  }
```

- [ ] **Step 3: `load` 加 `initialVolume` 参数并应用**

`load(...)` 签名里在 `double initialSpeed = 1.0,` 之后加：

```dart
    double initialVolume = 1.0,
```

并在 load 体内「应用持久化速度」块（约 378-386）之后追加（load 不触发 persist，与 speed/delay 同）：

```dart
    // 恢复持久化音量（默认 1.0 不必设；非默认才下发，避免无谓 platform 调用）。
    if ((initialVolume - 1.0).abs() > 0.001) {
      try {
        await _player.setVolume(initialVolume.clamp(0.0, 2.0));
      } catch (e, stack) {
        debugPrint('AudiobookController.setVolume: $e\n$stack');
        debugPrint(
            '[hibiki-audiobook] initial setVolume $initialVolume failed: $e');
      }
    }
```

- [ ] **Step 4: 编译验证**

Run: `cd packages/hibiki_audio && dart analyze lib/src/audiobook/audiobook_controller.dart`
Expected: No issues（warnings 与本改动无关时可忽略）。

---

## Task 2: 仓库音量读写

**Files:**
- Modify: `packages/hibiki_audio/lib/src/audiobook/audiobook_repository.dart`（key 前缀区 ~109、speed 读写区 ~133-143）

- [ ] **Step 1: 加 key 前缀**

在 `_kSpeedKeyPrefix` 声明（109 行）之后加：

```dart
  static const String _kVolumeKeyPrefix = 'audiobook_volume_';
```

- [ ] **Step 2: 加 `readVolume` / `updateVolume`（镜像 readSpeed/updateSpeed 的 string 存储）**

在 `updateSpeed`（约 139-143）之后追加：

```dart
  Future<double> readVolume(String bookUid) async {
    final raw = await _db.getPref('$_kVolumeKeyPrefix$bookUid');
    if (raw == null) return 1.0;
    return double.tryParse(raw) ?? 1.0;
  }

  Future<void> updateVolume({
    required String bookUid,
    required double volume,
  }) =>
      _db.setPref('$_kVolumeKeyPrefix$bookUid', volume.toString());
```

- [ ] **Step 3: 编译验证**

Run: `cd packages/hibiki_audio && dart analyze lib/src/audiobook/audiobook_repository.dart`
Expected: No issues。

---

## Task 3: 仓库往复 + 控制器回调单测

**Files:**
- Create: `packages/hibiki_audio/test/audiobook/audiobook_volume_persist_test.dart`

> 控制器 `setVolume` 会 `await _player.setVolume`（需 just_audio 平台），单测里不便驱动真实 player；因此本测试只覆盖**两件可单测的事**：repo 往复存储，和「回调被装上后会被同值守卫正确触发/跳过」的纯逻辑——后者用一个轻量假 player 不可行时，退化为 repo 往复 + Task 5 的源码守卫兜底。

- [ ] **Step 1: 写仓库往复失败测试**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

void main() {
  test('AudiobookRepository volume round-trips per book', () async {
    final HibikiDatabase db = HibikiDatabase.forTesting();
    final AudiobookRepository repo = AudiobookRepository(db);

    // 默认未写时回退 1.0。
    expect(await repo.readVolume('book-A'), 1.0);

    await repo.updateVolume(bookUid: 'book-A', volume: 0.4);
    await repo.updateVolume(bookUid: 'book-B', volume: 1.7);

    expect(await repo.readVolume('book-A'), closeTo(0.4, 1e-9));
    expect(await repo.readVolume('book-B'), closeTo(1.7, 1e-9));
    // 不串味：另一本书仍是默认。
    expect(await repo.readVolume('book-C'), 1.0);

    await db.close();
  });
}
```

- [ ] **Step 2: 跑测试确认通过（验证 `HibikiDatabase.forTesting()` 构造名）**

Run: `cd packages/hibiki_audio && flutter test test/audiobook/audiobook_volume_persist_test.dart`
Expected: PASS。若 `HibikiDatabase.forTesting()` 名称不符，改用现有 audiobook repo/db 测试里同款的内存 DB 构造（实现时 grep `HibikiDatabase(` 在 `packages/hibiki_audio/test` 与 `hibiki/test/database` 的现成用法对齐）。

- [ ] **Step 3: 提交**

```bash
git add packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart \
        packages/hibiki_audio/lib/src/audiobook/audiobook_repository.dart \
        packages/hibiki_audio/test/audiobook/audiobook_volume_persist_test.dart
git commit -m "feat(audiobook): persist per-book playback volume"
```

---

## Task 4: reader 两条控制器初始化路径接线

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`
  - `_initAudiobookController`：prefs Future.wait ~763-769、`load(...)` ~771-779、回调装载 ~795-809
  - `_initSrtBookController`：prefs Future.wait ~845-851、`load(...)` ~852-861、回调装载 ~877-891

- [ ] **Step 1: audiobook 路径——读音量**

`_initAudiobookController` 的 `Future.wait([...])`（763-769）末尾、`repo.readImagePauseSec(bookUid)` 之后加一项：

```dart
      repo.readImagePauseSec(bookUid),
      repo.readVolume(bookUid),
    ]);
```

- [ ] **Step 2: audiobook 路径——传 initialVolume**

`controller.load(...)`（771-779）里 `initialImagePauseSec: prefs[4] as int,` 之后加：

```dart
        initialImagePauseSec: prefs[4] as int,
        initialVolume: prefs[5] as double,
      );
```

- [ ] **Step 3: audiobook 路径——接 onVolumePersist**

在 `controller.onSpeedPersist = ...`（801-803）附近、`onImagePausePersist` 装载之后加：

```dart
    controller.onVolumePersist = (double volume) async {
      await repo.updateVolume(bookUid: bookUid, volume: volume);
    };
```

- [ ] **Step 4: srt 路径——同样三处**

`_initSrtBookController` 的 `Future.wait`（845-851）末尾加 `abRepo.readVolume(srtBookUid),`；`load(...)`（852-861）加 `initialVolume: prefs[5] as double,`；回调区（877-891）加：

```dart
    controller.onVolumePersist = (double volume) async {
      await abRepo.updateVolume(bookUid: srtBookUid, volume: volume);
    };
```

- [ ] **Step 5: 编译验证**

Run: `cd hibiki && flutter analyze lib/src/pages/implementations/reader_hibiki_page.dart`
Expected: No issues。`_buildVolumeSection` 的滑条 `onChanged: (v) { ctrl.setVolume(v); setState(); }` 无需改——`setVolume` 现已内部落库。

---

## Task 5: 持久化接线源码守卫

**Files:**
- Create: `hibiki/test/media/audiobook/audio_persist_wiring_static_test.dart`

- [ ] **Step 1: 写守卫测试（volume + speed 在控制器 + reader 两路径都已配线）**

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('controller persists volume the same way it persists speed', () {
    final String src = File(
      '../packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart',
    ).readAsStringSync();

    // 回调存在、setVolume 触发它、load 应用 initialVolume。
    expect(src, contains('onVolumePersist'));
    expect(src, contains('initialVolume'));
    expect(src, contains('onSpeedPersist'));
    expect(src, contains('initialSpeed'));
  });

  test('reader wires volume + speed persistence in both audio init paths', () {
    final String src = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();

    // 两条初始化路径（audiobook / srt）各出现一次音量接线。
    expect(RegExp('onVolumePersist').allMatches(src).length, greaterThanOrEqualTo(2));
    expect(RegExp('readVolume\\(').allMatches(src).length, greaterThanOrEqualTo(2));
    expect(RegExp('initialVolume:').allMatches(src).length, greaterThanOrEqualTo(2));
    // speed 既有接线不许被回归删除。
    expect(RegExp('onSpeedPersist').allMatches(src).length, greaterThanOrEqualTo(2));
    expect(RegExp('initialSpeed:').allMatches(src).length, greaterThanOrEqualTo(2));
  });
}
```

- [ ] **Step 2: 跑测试确认通过（先确认 `..` 相对路径在该测试 cwd 下可达 packages）**

Run: `cd hibiki && flutter test test/media/audiobook/audio_persist_wiring_static_test.dart`
Expected: PASS。若 `../packages/...` 路径在测试 cwd 不可达，改读 `hibiki/test` 既有跨包静态测试用的同款相对前缀（实现时对齐现有 `File('../packages` 用例；没有则只保留 reader 路径那条断言）。

- [ ] **Step 3: 提交**

```bash
git add hibiki/lib/src/pages/implementations/reader_hibiki_page.dart \
        hibiki/test/media/audiobook/audio_persist_wiring_static_test.dart
git commit -m "feat(audiobook): wire per-book volume persistence into reader controllers"
```

---

## Task 6: 外观卡片合并（主题前插同卡）

**Files:**
- Modify: `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart`（`_buildThemeSelector` ~412-429、`_buildAppearanceInline` ~440-482）

- [ ] **Step 1: 删旧的 `_buildThemeSelector()`，换成 theme-sync context 工厂**

把 `_buildThemeSelector()`（412-429，返回 `AdaptiveSettingsSection([buildThemeSelector(...)])` 的版本）整体替换为只产 context 的工厂（refresh 仍走 `_syncThemeSelection`，保留 reader 实时换肤 + 词典/歌词联动）：

```dart
  /// 主题行专用 [SettingsContext]：换肤后除 setState 外还要 `_syncThemeSelection`
  /// （把 appThemeKey 落 reader 设置 + 触发 `onThemeChanged` 的词典/歌词联动）。
  /// 与 appearance 其它行的普通 `_settingsContext()` 区分，故单列一个工厂。
  SettingsContext _themeSettingsContext() {
    return SettingsContext(
      context: context,
      appModel: widget.appModel,
      ref: widget.ref,
      readerSource: ReaderHibikiSource.instance,
      refresh: () {
        if (!mounted) return;
        unawaited(_syncThemeSelection());
        setState(() {});
      },
    );
  }
```

- [ ] **Step 2: 重写 `_buildAppearanceInline`——主题前插进 appearance 分组同一张卡**

把 `_buildAppearanceInline`（440-482）替换为：

```dart
  /// 外观区：单张卡片 = 主题行（首行）+ schema 投影的 appearance 分组（字号/
  /// 行高/段落缩进/视图模式），行间分割线、无大间隔；编辑书籍 CSS 留最下面独立
  /// 卡（live、按书 extractDir，无静态 schema item 能携带，仅在有 extract dir
  /// 时显示）。主题作为前插的 [SettingsCustomItem]，builder 用 `_themeSettingsContext`
  /// 保留实时换肤；其余行用普通 `_settingsContext()`。
  Widget _buildAppearanceInline(ThemeData theme) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final SettingsContext appearanceCtx = _settingsContext();
    final SettingsDestination base = buildReaderGroupDestination(
      appearanceCtx,
      ReaderGroup.appearance,
      t.settings_destination_appearance,
    );
    final List<SettingsItem> mergedItems = <SettingsItem>[
      SettingsCustomItem(
        id: 'reader.theme',
        icon: Icons.color_lens_outlined,
        builder: (_) => buildThemeSelector(_themeSettingsContext()),
      ),
      for (final SettingsSection section in base.sections) ...section.items,
    ];
    final SettingsDestination merged = SettingsDestination(
      id: base.id,
      title: base.title,
      icon: base.icon,
      sections: <SettingsSection>[SettingsSection(items: mergedItems)],
    );

    final List<Widget> children = <Widget>[
      SettingsSectionHeader(
        t.display_settings,
        padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      ),
      _buildSettingsDestinationContent(appearanceCtx, merged),
    ];
    if (widget.extractDir != null) {
      children.add(
        AdaptiveSettingsSection(
          children: [
            AdaptiveSettingsNavigationRow(
              title: t.book_css_editor_edit_css,
              icon: Icons.code_outlined,
              onTap: () async {
                await Navigator.push(
                  context,
                  adaptivePageRoute(
                    builder: (_) =>
                        BookCssEditorPage(extractDir: widget.extractDir!),
                  ),
                );
                await _reloadLayoutLive();
              },
            ),
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
```

- [ ] **Step 3: 编译验证**

Run: `cd hibiki && flutter analyze lib/src/media/audiobook/reader_quick_settings_sheet.dart`
Expected: No issues（确认 `SettingsItem` / `SettingsSection` / `SettingsCustomItem` / `SettingsDestination` 已随现有 `settings_*` import 可见；若缺再补 import）。

---

## Task 7: 更新外观内联区静态断言

**Files:**
- Modify: `hibiki/test/media/audiobook/reader_quick_settings_sheet_static_test.dart:34-42`

- [ ] **Step 1: 改断言匹配合并后的结构**

把（34-42）这段：

```dart
    // 平铺区包含主题选择器 + schema 投影的 appearance 分组 + 编辑书籍CSS。
    final String inlineSource = _between(
      source,
      '  Widget _buildAppearanceInline(ThemeData theme)',
      '  Widget _buildLocationSection(ThemeData theme)',
    );
    expect(inlineSource, contains('_buildThemeSelector()'));
    expect(inlineSource, contains('ReaderGroup.appearance'));
    expect(inlineSource, contains('book_css_editor_edit_css'));
```

替换为：

```dart
    // 平铺区把主题作为前插 custom item 并入 appearance 分组同一张卡（行间分割线、
    // 无大间隔），编辑书籍CSS 留最下面独立卡。
    final String inlineSource = _between(
      source,
      '  Widget _buildAppearanceInline(ThemeData theme)',
      '  Widget _buildLocationSection(ThemeData theme)',
    );
    expect(inlineSource, contains("id: 'reader.theme'"));
    expect(inlineSource, contains('buildThemeSelector(_themeSettingsContext())'));
    expect(inlineSource, contains('ReaderGroup.appearance'));
    expect(inlineSource, contains('book_css_editor_edit_css'));
    // 主题不再是独立卡：内联区不再调用旧的 _buildThemeSelector() 包装。
    expect(source, isNot(contains('Widget _buildThemeSelector()')));
```

- [ ] **Step 2: 跑静态测试**

Run: `cd hibiki && flutter test test/media/audiobook/reader_quick_settings_sheet_static_test.dart`
Expected: PASS（含 `const SizedBox(height: 12)` 等既有 MD3 间距守卫仍绿）。

---

## Task 8: 全量验证 + BUGS.md 登记 + 提交

**Files:**
- Modify: `docs/BUGS.md`（追加 BUG-031；注意 BUG-030 已被并发 agent 占用）

- [ ] **Step 1: 格式化 + 全量测试**

Run:
```bash
cd hibiki && dart format . && flutter test
cd ../packages/hibiki_audio && flutter test
```
Expected: 全绿（新建 2 测试 + 既有静态测试通过；不得新增失败）。

- [ ] **Step 2: BUGS.md 登记 BUG-031（音量不保存）**

按 docs/BUGS.md 流程追加一条：根因 = `AudiobookPlayerController.setVolume` 无 persist 回调、`load()` 无 `initialVolume`、repo 无 volume 读写键（speed/delay/imagePause 均有，唯独 volume 漏配）。① 根因修复（Task 1-4，提交哈希填实）② 自动测试（Task 3 repo 往复 + Task 5 源码守卫，文件名填实）两勾选框都勾。speed 经核查配线正确，备注「未复现，已加源码守卫防回归」。

- [ ] **Step 3: 提交剩余 UI + 文档**

```bash
git status --short
git add hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart \
        hibiki/test/media/audiobook/reader_quick_settings_sheet_static_test.dart \
        docs/BUGS.md
git diff --cached --check
git commit -m "fix(reader): merge theme into appearance card; log BUG-031 audio volume persist"
```
（只 stage 本轮文件，禁 `git add -A`；并发 agent 可能有无关改动。）

- [ ] **Step 4: 设备复测留待用户**

阅读器/播放类改动声明「修好了」前需真机复测原始失败路径：① 书内「排版设置」主题与字号同卡、无间隔，编辑书籍CSS 在最下面；② 调音量→退出重开书→音量保持。复测前在回复里标「设备复测待用户」。

---

## Self-Review

- **Spec coverage：** UI 合并（Task 6-7）；音量持久化（Task 1-5）；speed 守卫（Task 5）；验证 + 登记（Task 8）。覆盖用户两点诉求。
- **Placeholder scan：** 无 TBD；每个代码步给了完整代码；唯二「实现时对齐」点（`HibikiDatabase.forTesting()` 构造名、跨包 `../packages` 相对路径）已显式标出回退方案，因其依赖现有测试约定、需就地核对。
- **Type consistency：** `onVolumePersist: Future<void> Function(double)?`、`initialVolume: double`、`readVolume→Future<double>`、`updateVolume({bookUid, volume})`、`buildReaderGroupDestination(ctx, ReaderGroup.appearance, title)→SettingsDestination`、`SettingsCustomItem(id, icon, builder)`、`_themeSettingsContext()→SettingsContext` 全程一致。
