# 平板设置 / 本地音频 / 阅读器底栏 四项修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复用户报告的四个独立问题——① 方向焦点跨面板乱跳（设计系统→主题误跳到左侧「阅读」）、② 本地音频库无法调优先级、③ 阅读器底栏缺独立反转开关、④ 大屏设置导航栏没贴左不利平板。

**Architecture:** 四项彼此独立、各自可单独提交。①改自绘方向焦点几何评分（`hibiki_focus_controller.dart`）加「同一 Scrollable 面板优先」最高优先级档；②把本地音频库列表从只读 `ListView` 换成可重排（镜像同对话框里已有的远端列表）；③新增独立偏好 `reverse_reader_bottom_bar`（不复用 `reverse_navigation_bar`），阅读器两种底栏改读新键；④大屏全屏设置的「宽屏主从布局」不再被居中限宽的 `DesktopContentLayout` 包裹，导航栏贴最左、详情填满（窄屏单列仍居中限宽）。

**Tech Stack:** Flutter 3.44.0 / Dart 3.12.0；Material 3；项目自研 `HibikiFocus*` 方向焦点；Drift 偏好；Slang i18n（17 语言，改键必须走 `tool/i18n_sync.dart`）；`flutter_test` widget/单元测试。所有测试用项目工具链 `flutter test --no-pub`。

**Scope notes（明确不做）：**
- 不动 Cupertino（iOS/桌面 Cupertino）皮肤；不重写焦点系统、不改 `WindowSizeClass` 枚举或 `_geometricTarget` 既有四档的相对顺序（只在最顶加一档）。
- 任务③用户已明确选「独立的阅读器底栏反转」：新键默认 `false`，与首页导航栏反转 `reverse_navigation_bar` 互不影响。这会改变「曾打开导航栏反转并依赖阅读器底栏也反转」用户的观感——这是用户明确要的解耦，记在任务③备注。
- 任务①把「同面板优先」放最顶档，仅在「同一 Scrollable 候选存在时」改变跨面板结果；无 Scrollable 的页面（候选 scrollable 全为 null）该档恒等，行为不变（保护既有手柄导航测试）。

---

## File Structure

| 文件 | 职责 | 改动 |
|---|---|---|
| `hibiki/lib/src/focus/hibiki_focus_controller.dart` | 自绘方向焦点几何评分 | `_geometricTarget` 增「同一最近 Scrollable」最高优先级档 |
| `hibiki/test/focus/focus_pane_locality_test.dart` | 方向焦点跨面板守卫（新） | 双 ListView 面板，断言 Down 留在同面板 |
| `hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart` | 音频来源对话框 | `_buildLocalGroup` 本地库列表换成 `ReorderableListView`＋上下箭头 |
| `hibiki/test/pages/local_audio_reorder_test.dart` | 本地库重排守卫（新） | 上移第二个库，关闭后 `onSave` 收到重排后的顺序 |
| `hibiki/lib/src/models/preferences_repository.dart` | 偏好仓库 | 加 `reverseReaderBottomBar` getter + `toggleReverseReaderBottomBar()` |
| `hibiki/lib/src/models/app_model.dart` | 全局状态委托 | 加 `reverseReaderBottomBar` / `toggleReverseReaderBottomBar()` 透传 |
| `hibiki/lib/src/settings/settings_schema.dart` | 设置 schema | `_readingDestination` 加 `SettingsSwitchItem`（书内 behavior 组可见） |
| `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` | 阅读器页 | 两处底栏 `reversed` 从 `reverseNavigationBar` 改读 `reverseReaderBottomBar` |
| `hibiki/lib/i18n/*.i18n.json` + `strings.g.dart` | i18n | 新 key `reverse_reader_bottom_bar`（走 i18n_sync + slang） |
| `hibiki/test/models/preferences_repository_test.dart` | 偏好单测 | 加新键独立性测试 |
| `hibiki/test/pages/reader_bottom_bar_reverse_static_test.dart` | 源码守卫（新） | 断言阅读器底栏绑定新键、未回退旧键 |
| `hibiki/lib/src/settings/settings_home_page.dart` | 全屏设置外壳 | 宽屏主从不再包居中限宽；窄屏单列仍居中限宽 |
| `hibiki/test/pages/settings_wide_left_aligned_test.dart` | 设置贴左守卫（新） | 宽视口主从导航栏 left≈0 |

---

## Task 1: 方向焦点「同面板优先」——修复设计系统→主题误跳到「阅读」

**根因：** `hibiki_focus_controller.dart:303 _geometricTarget` 在所有可聚焦目标里做全局几何搜索，无面板概念。既有四档优先级 `clears > along > beam > cross`（f165cd475 让 `along` 压过 `beam`，使「段控下方左对齐的主题色板」不被跳过）。但这也让**跨面板**的左侧「阅读」（`along` 更小、更近）压过同面板的「主题」。修法：在最顶加一档「候选与当前项处于同一最近 `Scrollable`」——同面板候选恒优先于跨面板候选，组内排序仍由原四档决定。

**Files:**
- Modify: `hibiki/lib/src/focus/hibiki_focus_controller.dart:303-407`
- Test: `hibiki/test/focus/focus_pane_locality_test.dart`（新建）

- [ ] **Step 1: 写失败测试**（新建 `hibiki/test/focus/focus_pane_locality_test.dart`）

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';

// 复现 BUG：宽屏设置「外观」详情里，焦点在右侧详情面板（一个 Scrollable）的
// 「设计系统」段控上，按 Down 应去同面板下方的「主题」；但左侧导航面板（另一个
// Scrollable）的「阅读」在纵向上更近，旧评分会误选它。修复后方向焦点优先留在
// 当前项所在的同一 Scrollable 面板内。
Widget _twoPane({
  required GlobalKey rootKey,
}) {
  // 左面板（导航 ListView）：nav0 / nav-阅读 / nav2，各高 56。
  // 右面板（详情 ListView）：seg（高 56）/ 非聚焦留白（高 80）/ theme（高 56）。
  // 两面板顶端对齐：seg 中心≈28，theme 中心≈164；nav-阅读 中心≈84（比 theme 更近）。
  Widget target(String id, double height, double width) => HibikiFocusTarget(
        id: HibikiFocusId(id),
        child: SizedBox(height: height, width: width),
      );
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
    home: Scaffold(
      body: HibikiFocusRoot(
        child: Row(
          key: rootKey,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 200,
              height: 300,
              child: ListView(
                children: <Widget>[
                  target('nav-0', 56, 200),
                  target('nav-reading', 56, 200),
                  target('nav-2', 56, 200),
                ],
              ),
            ),
            SizedBox(
              width: 400,
              height: 300,
              child: ListView(
                children: <Widget>[
                  target('detail-seg', 56, 400),
                  const SizedBox(height: 80, width: 400),
                  target('detail-theme', 56, 400),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
      'Down from a detail-pane control stays in the same Scrollable pane '
      '(does not jump to the closer cross-pane nav item)', (tester) async {
    final GlobalKey rootKey = GlobalKey();
    await tester.pumpWidget(_twoPane(rootKey: rootKey));
    await tester.pump();

    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(rootKey.currentContext!);

    expect(controller.requestById(const HibikiFocusId('detail-seg')), isTrue);
    await tester.pump();

    expect(controller.move(HibikiFocusDirection.down), isTrue);
    await tester.pump();

    expect(
      controller.activeId,
      const HibikiFocusId('detail-theme'),
      reason: 'Down must prefer the same-pane control below, not the closer '
          'cross-pane nav item',
    );
  });

  testWidgets('Right from the nav pane still crosses into the detail pane',
      (tester) async {
    final GlobalKey rootKey = GlobalKey();
    await tester.pumpWidget(_twoPane(rootKey: rootKey));
    await tester.pump();

    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(rootKey.currentContext!);

    expect(controller.requestById(const HibikiFocusId('nav-0')), isTrue);
    await tester.pump();

    // 导航面板单列、右侧无同面板候选 → Right 必须跨到详情面板（不被同面板档锁死）。
    expect(controller.move(HibikiFocusDirection.right), isTrue);
    await tester.pump();
    expect(
      controller.activeId?.value.startsWith('detail-'),
      isTrue,
      reason: 'crossing panes via Left/Right must still work',
    );
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd hibiki && flutter test test/focus/focus_pane_locality_test.dart --no-pub`
Expected: 第 1 个测试 FAIL（`activeId` == `nav-reading` 而非 `detail-theme`）；第 2 个可能已 PASS。

- [ ] **Step 3: 改 `_geometricTarget` 加「同面板」最高优先级档**

在 `hibiki_focus_controller.dart` 顶部确认已 `import 'package:flutter/material.dart';`（已存在，`Scrollable` 即来自此）。

把 `_geometricTarget`（303-407 行）中**循环前**的初始化加上面板基准与新档变量：

```dart
    final Rect? activeRect = globalRectOfContext(active.context);
    if (activeRect == null) return const _GeometricMoveResult.noGeometry();
    // 当前项所在的最近 Scrollable —— 方向导航优先停留在同一面板（同一可滚动
    // 容器）内。设置宽屏主从布局里，导航栏与详情各是独立 ListView；没有这条，
    // 详情里「设计系统」段控按 Down 会被纵向更近的左侧导航项「阅读」抢走。
    final ScrollableState? activeScrollable = Scrollable.maybeOf(active.context);
    final Offset activeCenter = activeRect.center;
    HibikiFocusTargetEntry? best;
    int bestSamePane = -1;
    int bestClears = -1;
    int bestBeam = -1;
    double bestAlong = double.infinity;
    double bestCross = double.infinity;
    const double epsilon = 2;
```

在循环内、`targetRect` 求出后（`final Offset targetCenter = targetRect.center;` 之前或之后均可，需在 `targetRect != null` 之后）加同面板判定：

```dart
      final Rect? targetRect = globalRectOfContext(target.context);
      if (targetRect == null) continue;
      // 同一最近 Scrollable 即同一视觉面板；两者都无 Scrollable(null==null) 也算
      // 「同面板」，使纯展示页（无可滚动容器）该档恒等、行为与改动前一致。
      final bool samePane = identical(
        Scrollable.maybeOf(target.context),
        activeScrollable,
      );
      final Offset targetCenter = targetRect.center;
```

把循环末尾的 `better` 判定与赋值，从：

```dart
      final int beamScore = beam ? 1 : 0;
      final int clearsScore = clears ? 1 : 0;
      // ...（既有注释保留）...
      final bool better = best == null ||
          clearsScore > bestClears ||
          (clearsScore == bestClears &&
              (along < bestAlong - epsilon ||
                  ((along - bestAlong).abs() <= epsilon &&
                      (beamScore > bestBeam ||
                          (beamScore == bestBeam && cross < bestCross)))));
      if (better) {
        best = target;
        bestClears = clearsScore;
        bestBeam = beamScore;
        bestAlong = along;
        bestCross = cross;
      }
```

替换为（在最顶加 `samePaneScore` 档，其余四档原样下沉一层）：

```dart
      final int beamScore = beam ? 1 : 0;
      final int clearsScore = clears ? 1 : 0;
      final int samePaneScore = samePane ? 1 : 0;
      // Ranking, in priority order:
      //  0. `samePane` — a candidate in the SAME nearest Scrollable (same visual
      //     pane) beats any cross-pane candidate. In the wide settings list-detail
      //     the nav pane and the detail pane are separate ListViews; without this
      //     a Down press from a detail control jumps to the vertically-closer nav
      //     item in the OTHER pane. Both-null (no Scrollable) counts as same, so
      //     scrollable-free pages keep the original behaviour.
      //  1. `clears` — fully past the source on the press axis beats mere overlap.
      //  2. `along` — the immediately-next row/column wins even if cross-offset.
      //  3. `beam` — perpendicular overlap breaks an `along` tie.
      //  4. `cross` — centre offset breaks any remaining tie.
      final bool better = best == null ||
          samePaneScore > bestSamePane ||
          (samePaneScore == bestSamePane &&
              (clearsScore > bestClears ||
                  (clearsScore == bestClears &&
                      (along < bestAlong - epsilon ||
                          ((along - bestAlong).abs() <= epsilon &&
                              (beamScore > bestBeam ||
                                  (beamScore == bestBeam &&
                                      cross < bestCross)))))));
      if (better) {
        best = target;
        bestSamePane = samePaneScore;
        bestClears = clearsScore;
        bestBeam = beamScore;
        bestAlong = along;
        bestCross = cross;
      }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd hibiki && flutter test test/focus/focus_pane_locality_test.dart --no-pub`
Expected: 两个测试都 PASS。

- [ ] **Step 5: 跑既有焦点测试确认零回归**

Run:
```bash
cd hibiki
flutter test test/focus test/widgets/material_nav_focus_test.dart test/widgets/settings_focus_traversal_test.dart test/shortcuts/gamepad_focus_nav_test.dart --no-pub
```
Expected: 全部 PASS（既有用例多为单 Scrollable 或无 Scrollable，同面板档恒等，不受影响）。

- [ ] **Step 6: 提交**

```bash
git add hibiki/lib/src/focus/hibiki_focus_controller.dart hibiki/test/focus/focus_pane_locality_test.dart
git commit -m "fix(focus): prefer same-Scrollable pane in directional nav (kill detail->nav cross-jump)"
```

---

## Task 2: 本地音频库可重排（调优先级）

**根因：** `dictionary_settings_dialog_page.dart:316 _buildLocalGroup` 里本地库列表用普通 `ListView.builder`，每行只有 开关/调子源/删除，**无重排**；而同对话框的远端列表 `_buildRemoteList`（162 行）是 `ReorderableListView` + 上下箭头。本地库顺序 = 优先级（`app_model.dart:2500 audioSourceConfigs` 保序 → `setAudioSourceConfigs` → `setEntries(nextDbs)` 按序推 native），缺的只是 UI 重排入口。

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart:316-362`
- Test: `hibiki/test/pages/local_audio_reorder_test.dart`（新建）

- [ ] **Step 1: 写失败测试**（新建 `hibiki/test/pages/local_audio_reorder_test.dart`）

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/pages/implementations/dictionary_settings_dialog_page.dart';

Widget _host(Widget child) => MaterialApp(
      theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('local audio DBs can be reordered to change priority', (
    tester,
  ) async {
    final List<AudioSourceConfig> twoLocal = <AudioSourceConfig>[
      AudioSourceConfig.localAudio(label: 'android.db', path: '/a.db'),
      AudioSourceConfig.localAudio(label: 'cc-switch.sql', path: '/b.db'),
    ];
    List<AudioSourceConfig>? saved;

    await tester.pumpWidget(_host(AudioSourcesDialog(
      sources: twoLocal,
      localAudioEnabled: true, // 让本地分组默认展开
      onToggleLocalAudio: (_) async {},
      onSave: (List<AudioSourceConfig> next) => saved = next,
    )));
    await tester.pumpAndSettle();

    // 第二个库（/b.db）行上的「上移」按钮把它提到第一位。
    final Finder moveUpButtons = find.byTooltip(t.move_up);
    expect(moveUpButtons, findsWidgets,
        reason: 'local audio rows must expose a move-up control');
    // 本地分组里 /b.db 的上移按钮（远端列表此例为空，故首个 enabled 的上移即它）。
    await tester.tap(moveUpButtons.last);
    await tester.pump();

    await tester.tap(find.text(t.dialog_close));
    await tester.pump();

    final List<AudioSourceConfig> local = (saved ?? <AudioSourceConfig>[])
        .where((AudioSourceConfig s) => s.kind == AudioSourceKind.localAudio)
        .toList();
    expect(local.map((AudioSourceConfig s) => s.path).toList(),
        <String>['/b.db', '/a.db'],
        reason: 'reordered local-DB priority must persist through onSave');
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd hibiki && flutter test test/pages/local_audio_reorder_test.dart --no-pub`
Expected: FAIL（`find.byTooltip(t.move_up)` 在本地行找不到，或顺序未变）。

- [ ] **Step 3: 把本地库列表改成可重排**

在 `dictionary_settings_dialog_page.dart` 的 `_buildLocalGroup`，把 316-362 行的 `if (_localSources.isNotEmpty) ListView.builder(...)` 整块替换为 `ReorderableListView.builder`（镜像 `_buildRemoteList` 的重排骨架；保留本行原有的 开关/调子源/删除 三个控件，在开关之后、调子源之前插上下箭头）：

```dart
          if (_localSources.isNotEmpty)
            ReorderableListView.builder(
              shrinkWrap: true,
              // 同 _buildRemoteList：关掉桌面自动 ☰ 手柄（会盖行尾按钮），改整行长按
              // 拖拽；上下箭头是无障碍/手柄重排路径。列表在外层 SingleChildScrollView
              // 内，自身不滚动。
              buildDefaultDragHandles: false,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _localSources.length,
              onReorder: (int oldIndex, int newIndex) {
                setState(() {
                  if (newIndex > oldIndex) newIndex--;
                  final AudioSourceConfig item =
                      _localSources.removeAt(oldIndex);
                  _localSources.insert(newIndex, item);
                });
              },
              itemBuilder: (BuildContext context, int index) {
                final AudioSourceConfig source = _localSources[index];
                return ReorderableDelayedDragStartListener(
                  key: ValueKey<String>('audio_local_${source.path ?? index}'),
                  index: index,
                  child: AdaptiveSettingsRow(
                    title: source.displayLabel,
                    subtitle: source.path ?? '',
                    icon: Icons.audiotrack_outlined,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Switch.adaptive(
                          value: source.enabled,
                          onChanged: (bool enabled) => setState(() {
                            _localSources[index] =
                                source.copyWith(enabled: enabled);
                          }),
                        ),
                        HibikiIconButton(
                          icon: Icons.keyboard_arrow_up,
                          size: 18,
                          tooltip: t.move_up,
                          enabled: index > 0,
                          padding: EdgeInsets.all(tokens.spacing.gap / 2),
                          onTap: () => setState(() {
                            final AudioSourceConfig item =
                                _localSources.removeAt(index);
                            _localSources.insert(index - 1, item);
                          }),
                        ),
                        HibikiIconButton(
                          icon: Icons.keyboard_arrow_down,
                          size: 18,
                          tooltip: t.move_down,
                          enabled: index < _localSources.length - 1,
                          padding: EdgeInsets.all(tokens.spacing.gap / 2),
                          onTap: () => setState(() {
                            final AudioSourceConfig item =
                                _localSources.removeAt(index);
                            _localSources.insert(index + 1, item);
                          }),
                        ),
                        if (widget.onEditLocalSources != null &&
                            (source.path?.isNotEmpty ?? false))
                          HibikiIconButton(
                            icon: Icons.tune,
                            size: 18,
                            tooltip: t.local_audio_edit_sources,
                            padding: EdgeInsets.all(tokens.spacing.gap / 2),
                            onTap: () =>
                                widget.onEditLocalSources!(source.path!),
                          ),
                        HibikiIconButton(
                          icon: Icons.delete_outline,
                          size: 18,
                          tooltip: t.dialog_delete,
                          padding: EdgeInsets.all(tokens.spacing.gap / 2),
                          onTap: () =>
                              setState(() => _localSources.removeAt(index)),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
```

> 注：原 `ListView.builder` 行的 `key: ValueKey('audio_local_...')` 移到 `ReorderableDelayedDragStartListener`（ReorderableListView 要求每个 child 顶层带 key）。`tokens` 已是 `_buildLocalGroup(HibikiDesignTokens tokens)` 入参，直接可用。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd hibiki && flutter test test/pages/local_audio_reorder_test.dart --no-pub`
Expected: PASS。

- [ ] **Step 5: analyze**

Run: `cd hibiki && dart format lib/src/pages/implementations/dictionary_settings_dialog_page.dart test/pages/local_audio_reorder_test.dart && flutter analyze lib/src/pages/implementations/dictionary_settings_dialog_page.dart`
Expected: 无 error。

- [ ] **Step 6: 提交**

```bash
git add hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart hibiki/test/pages/local_audio_reorder_test.dart
git commit -m "feat(audio): make local audio DBs reorderable to set priority"
```

---

## Task 3: 阅读器底栏独立反转开关

**根因/需求：** 全局 `reverse_navigation_bar` 当前同时反转首页导航栏与阅读器底栏（`reader_hibiki_page.dart:4352`／`4371`）。用户要「独立的阅读器底栏反转」。新增偏好 `reverse_reader_bottom_bar`（默认 `false`），阅读器两种底栏改读新键，首页导航栏继续读旧键，二者解耦。

> **行为变更备注：** 此前打开「反转底栏方向」会连带反转阅读器底栏；解耦后阅读器底栏默认不反转，需在「阅读」设置（书内 behavior 组）单独打开新开关。这是用户明确要的独立控制。

**Files:**
- Modify: `hibiki/lib/src/models/preferences_repository.dart:191-197`
- Modify: `hibiki/lib/src/models/app_model.dart:1552-1553`
- Modify: `hibiki/lib/src/settings/settings_schema.dart`（`_readingDestination` 内追加一项）
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:4352,4371`
- i18n: `hibiki/lib/i18n/*.i18n.json` + `strings.g.dart`（新 key `reverse_reader_bottom_bar`）
- Test: `hibiki/test/models/preferences_repository_test.dart`、`hibiki/test/pages/reader_bottom_bar_reverse_static_test.dart`（新建）

- [ ] **Step 1: 加 i18n key（必须走 i18n_sync，禁止手改 17 文件）**

Run:
```bash
cd hibiki
dart run tool/i18n_sync.dart --add reverse_reader_bottom_bar "Reverse reader bottom bar" "反转阅读器底栏"
dart run slang
dart format lib/i18n/strings.g.dart
```
Expected: 17 个 json 各加该 key；`strings.g.dart` 重新生成且 `t.reverse_reader_bottom_bar` 可用。

- [ ] **Step 2: 写失败的偏好单测**（追加到 `hibiki/test/models/preferences_repository_test.dart` 的 `main()` 内；若文件不存在按既有偏好测试夹具新建——参考同目录其它 `*_repository_test.dart` 的内存 DB 搭建）

```dart
  test('reverseReaderBottomBar is independent of reverseNavigationBar', () async {
    // repo: 已在本文件夹具里基于内存 Drift DB 构造的 PreferencesRepository。
    expect(repo.reverseReaderBottomBar, isFalse); // 默认关
    expect(repo.reverseNavigationBar, isFalse);

    repo.toggleReverseReaderBottomBar();
    await Future<void>.delayed(Duration.zero); // 等异步 setPref 落库
    expect(repo.reverseReaderBottomBar, isTrue);
    expect(repo.reverseNavigationBar, isFalse,
        reason: 'toggling reader bottom bar must not touch the nav-bar pref');

    repo.toggleReverseNavigationBar();
    await Future<void>.delayed(Duration.zero);
    expect(repo.reverseNavigationBar, isTrue);
    expect(repo.reverseReaderBottomBar, isTrue,
        reason: 'the two prefs are decoupled');
  });
```

- [ ] **Step 3: 跑测试确认失败**

Run: `cd hibiki && flutter test test/models/preferences_repository_test.dart --no-pub`
Expected: FAIL（`reverseReaderBottomBar` / `toggleReverseReaderBottomBar` 未定义）。

- [ ] **Step 4: 加偏好键**（`preferences_repository.dart`，紧接 `toggleReverseNavigationBar` 之后，197 行附近）

```dart
  bool get reverseReaderBottomBar =>
      getPref('reverse_reader_bottom_bar', defaultValue: false) as bool;

  void toggleReverseReaderBottomBar() async {
    await setPref('reverse_reader_bottom_bar', !reverseReaderBottomBar);
    notifyListeners();
  }
```

- [ ] **Step 5: 加 AppModel 透传**（`app_model.dart`，紧接 1553 行 `toggleReverseNavigationBar` 透传之后）

```dart
  bool get reverseReaderBottomBar => prefsRepo.reverseReaderBottomBar;
  void toggleReverseReaderBottomBar() =>
      prefsRepo.toggleReverseReaderBottomBar();
```

- [ ] **Step 6: 跑偏好单测确认通过**

Run: `cd hibiki && flutter test test/models/preferences_repository_test.dart --no-pub`
Expected: PASS。

- [ ] **Step 7: 写阅读器底栏绑定的源码守卫（失败）**（新建 `hibiki/test/pages/reader_bottom_bar_reverse_static_test.dart`）

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

// 守卫：阅读器两种底栏（有声书播放条 / 设置条）必须绑定独立的
// reverseReaderBottomBar，而不是首页导航栏的 reverseNavigationBar。
void main() {
  test('reader bottom bars bind reverseReaderBottomBar, not reverseNavigationBar',
      () {
    final String src = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();

    // 有声书播放条 reversed: 与设置条 reversed 局部变量都应来自新键。
    expect(src.contains('appModel.reverseReaderBottomBar'), isTrue,
        reason: 'reader bottom bars must read the dedicated reader pref');
    // 确认旧键不再驱动阅读器底栏（reader 页里不应再出现 reverseNavigationBar）。
    expect(src.contains('reverseNavigationBar'), isFalse,
        reason: 'reader bottom bars must be decoupled from the nav-bar reverse');
  });
}
```

- [ ] **Step 8: 跑守卫确认失败**

Run: `cd hibiki && flutter test test/pages/reader_bottom_bar_reverse_static_test.dart --no-pub`
Expected: FAIL（reader 页仍用 `reverseNavigationBar`）。

- [ ] **Step 9: 阅读器底栏改读新键**（`reader_hibiki_page.dart`）

把 4352 行 `reversed: appModel.reverseNavigationBar,` 改为：
```dart
                  reversed: appModel.reverseReaderBottomBar,
```
把 4371 行 `final bool reversed = appModel.reverseNavigationBar;` 改为：
```dart
    final bool reversed = appModel.reverseReaderBottomBar;
```

- [ ] **Step 10: 跑守卫确认通过**

Run: `cd hibiki && flutter test test/pages/reader_bottom_bar_reverse_static_test.dart --no-pub`
Expected: PASS。

- [ ] **Step 11: 在「阅读」设置加开关**（`settings_schema.dart` 的 `_readingDestination`，在 `section_layout` 段（358-543 行那个 `SettingsSection`）的 `items` 列表末尾、`furigana_mode` 段控之后追加）

```dart
          SettingsSwitchItem(
            id: 'reading_display.reverse_reader_bottom_bar',
            title: t.reverse_reader_bottom_bar,
            icon: Icons.swap_horiz_outlined,
            reader: const ReaderPlacement(
              group: ReaderGroup.behavior,
              order: 0,
            ),
            value: (SettingsContext c) => c.appModel.reverseReaderBottomBar,
            onChanged: (SettingsContext c, bool value) {
              c.appModel.toggleReverseReaderBottomBar();
              c.refresh();
            },
          ),
```

> 放 `ReaderGroup.behavior` 让它出现在书内快捷设置面板（用户口中「书籍的底栏」入口）；同时全局「阅读」分类也可见。`c.appModel.toggleReverseReaderBottomBar()` 经 prefsRepo `notifyListeners` 触发监听 `appProvider` 的阅读器页重建（与既有 `reverse_navigation_bar` 实时生效同一机制）。

- [ ] **Step 12: analyze + 相关测试**

Run:
```bash
cd hibiki
dart format lib/src/models/preferences_repository.dart lib/src/models/app_model.dart lib/src/settings/settings_schema.dart lib/src/pages/implementations/reader_hibiki_page.dart
flutter analyze lib/src/settings/settings_schema.dart lib/src/models/preferences_repository.dart lib/src/models/app_model.dart
flutter test test/models/preferences_repository_test.dart test/pages/reader_bottom_bar_reverse_static_test.dart test/i18n --no-pub
```
Expected: analyze 无 error；测试 PASS（i18n 完整性通过证明 17 语言 key 齐全）。

- [ ] **Step 13: 提交**

```bash
git add hibiki/lib/src/models/preferences_repository.dart hibiki/lib/src/models/app_model.dart hibiki/lib/src/settings/settings_schema.dart hibiki/lib/src/pages/implementations/reader_hibiki_page.dart hibiki/lib/i18n hibiki/test/models/preferences_repository_test.dart hibiki/test/pages/reader_bottom_bar_reverse_static_test.dart
git commit -m "feat(reader): independent reader-bottom-bar reverse toggle (decoupled from nav bar)"
```

---

## Task 4: 大屏全屏设置导航栏贴最左（平板友好）

**根因：** `settings_home_page.dart:77-99` 把整块设置（含宽屏主从布局）放进 `DesktopContentLayout(kind: settings)`，该组件对 settings 用 `Center + ConstrainedBox(maxWidth 960) + 左右 padding`，宽屏上整块被居中→左侧导航栏离屏幕左缘留白。修法：宽屏（≥720，主从布局）不再包居中限宽，导航栏贴最左、详情填满；窄屏单列仍居中限宽（单列更易读）。

**Files:**
- Modify: `hibiki/lib/src/settings/settings_home_page.dart:77-99`
- Test: `hibiki/test/pages/settings_wide_left_aligned_test.dart`（新建）

- [ ] **Step 1: 写失败测试**（新建 `hibiki/test/pages/settings_wide_left_aligned_test.dart`）

> 说明：`SettingsHomePage` 需要完整 appModel，widget 测试成本高。本测试在**组合层**复刻修复后宽屏分支的装配（`MaterialSupportingPaneLayout`，`supportingSide: start`，不包 `DesktopContentLayout`），在 1400px 宽视口断言导航（supporting）面板左缘≈0；并对照证明：一旦用旧的 `DesktopContentLayout(kind: settings)` 居中包裹，左缘会被推离 0。装配正确性由 Step 4 设备复测兜底。

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';

Widget _wideViewport(Widget child) => MaterialApp(
      theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 1400, height: 900, child: child),
        ),
      ),
    );

void main() {
  final Key navKey = const Key('settings-nav-pane');

  Widget masterDetail() => MaterialSupportingPaneLayout(
        minSplitWidth: 720,
        supportingSide: SupportingPaneSide.start,
        supporting: Container(key: navKey, color: Colors.blue),
        primary: const ColoredBox(color: Colors.green),
      );

  testWidgets('FIX: wide settings master-detail nav pane hugs the left edge',
      (tester) async {
    await tester.pumpWidget(_wideViewport(masterDetail()));
    await tester.pump();
    final Rect nav = tester.getRect(find.byKey(navKey));
    // 容器本身在 1400 视口里 left==0（不再被居中限宽推走）。
    expect(nav.left, lessThan(1.0),
        reason: 'nav pane must be flush to the left edge for tablet reach');
  });

  testWidgets('REGRESSION DOC: wrapping in centered DesktopContentLayout '
      'pushes the nav pane off the left (why we do NOT wrap the wide branch)',
      (tester) async {
    await tester.pumpWidget(_wideViewport(
      DesktopContentLayout(
        kind: DesktopContentKind.settings,
        child: masterDetail(),
      ),
    ));
    await tester.pump();
    final Rect nav = tester.getRect(find.byKey(navKey));
    // 1400 宽被居中限到 960 → 左缘明显 > 0（这正是我们要避免的旧行为）。
    expect(nav.left, greaterThan(100.0));
  });
}
```

- [ ] **Step 2: 跑测试确认现状**

Run: `cd hibiki && flutter test test/pages/settings_wide_left_aligned_test.dart --no-pub`
Expected: 两个测试此刻都应 PASS（它们测的是组合层不变量，证明「不包裹则贴左、包裹则居中」）。这是把修复要表达的不变量固化下来；真正的代码改动在 Step 3，使 `SettingsHomePage` 宽屏分支走「不包裹」一侧。

> 若想看到 RED→GREEN，可在 Step 3 前先把第 1 个测试的 `masterDetail()` 临时换成包 `DesktopContentLayout` 的版本观察其 FAIL，再还原。非必须。

- [ ] **Step 3: 重构 `SettingsHomePage.build` 的包裹结构**

把 `settings_home_page.dart:77-99` 的 `build` 尾部：

```dart
    final Widget content = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth >= 720) {
          return _buildWideLayout(
            settingsContext: settingsContext,
            renderer: renderer,
            destinations: destinations,
          );
        }
        return renderer.buildHomePage(
          settingsContext: settingsContext,
          destinations: destinations,
          selectedDestinationId: _selectedDestinationId,
          onDestinationSelected: _selectDestination,
          embedded: widget.embedded,
        );
      },
    );
    return DesktopContentLayout(
      kind: DesktopContentKind.settings,
      child: _buildEmbeddedShell(content),
    );
```

替换为（宽屏主从直接全宽贴左；只有窄屏单列才走居中限宽的 `DesktopContentLayout`）：

```dart
    final Widget content = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth >= 720) {
          // 宽屏主从：导航栏贴最左、详情填满整宽（平板友好，不再居中留白）。
          return _buildWideLayout(
            settingsContext: settingsContext,
            renderer: renderer,
            destinations: destinations,
          );
        }
        // 窄屏单列：居中限宽（单列阅读更舒适）。
        return DesktopContentLayout(
          kind: DesktopContentKind.settings,
          child: renderer.buildHomePage(
            settingsContext: settingsContext,
            destinations: destinations,
            selectedDestinationId: _selectedDestinationId,
            onDestinationSelected: _selectDestination,
            embedded: widget.embedded,
          ),
        );
      },
    );
    return _buildEmbeddedShell(content);
```

> 现在 `LayoutBuilder` 看到的是**全宽**（外层不再被 `DesktopContentLayout` 提前限到 960），≥720 走全宽主从、导航栏 `MaterialSupportingPaneLayout(supportingSide: start)` 贴 x=0；<720 单列仍居中限宽。页头 `HibikiPageHeader`（`_buildEmbeddedShell`）保持全宽。`_buildWideLayout` / `_buildEmbeddedShell` / `_selectDestination` 其它逻辑不动。

- [ ] **Step 4: analyze + 全量测试 + 设备复测（布局问题必做）**

Run:
```bash
cd hibiki
dart format lib/src/settings/settings_home_page.dart test/pages/settings_wide_left_aligned_test.dart
flutter analyze lib/src/settings/settings_home_page.dart
flutter test --no-pub
```
Expected: analyze 无 error；全量测试 PASS。

按 CLAUDE.md「布局问题声明修好前必须真机/真窗复测」，在 Windows 真窗或平板模拟器上验证：
1. 把窗口拉到 >960（或平板横屏）打开设置全屏：左侧分类导航栏贴屏幕最左缘，无左侧大留白。
2. 详情面板填满右侧剩余空间；窄屏（<720）单列仍居中。
3. 顺带复测 Task 1：在「外观」详情把焦点移到「设计系统」段控，按 Down/手柄下，焦点落到同面板「主题」而非左侧「阅读」。
留证据（截图）到 `.codex-test/`（不入库）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/settings/settings_home_page.dart hibiki/test/pages/settings_wide_left_aligned_test.dart
git commit -m "fix(settings): left-align wide settings master-detail (flush nav pane for tablets)"
```

---

## Task 5: 全量校验 + 代码审查

- [ ] **Step 1: 全量 analyze + test**

Run:
```bash
cd hibiki
dart format .
flutter analyze
flutter test --no-pub
```
Expected: analyze 无新增 error；全量测试 PASS（注意：仓库已有 4 个预存失败 `frequency_field` / `preferences_repository` JSON / md3 静态 / `gamepad_keyboard`，见 memory，需区分「非本轮引入」）。

- [ ] **Step 2: code review（必须 opus 子代理）**

按 CLAUDE.md：调用 `superpowers:requesting-code-review` 启动 code-reviewer agent（`model: "opus"`），审查四项改动是否符合计划、边界情况、向后兼容（尤其 Task 1 方向焦点对既有手柄导航的影响、Task 3 行为解耦的回归面）。审查问题修复后重新提交审查。

---

## Self-Review

**1. Spec coverage：**
- ① 设计系统→主题误跳「阅读」 → Task 1（同面板最高优先档）✅
- ② 本地音频无法调优先级 → Task 2（本地库 ReorderableListView + 上下箭头，顺序经 setEntries 落 native）✅
- ③ 书籍底栏加独立反转 → Task 3（新独立键 `reverse_reader_bottom_bar` + 阅读设置开关 + 阅读器底栏改读新键）✅
- ④ 大屏设置栏放最左 → Task 4（宽屏主从去掉居中限宽、导航栏贴左）✅
- 向后兼容：Task 1 同面板档对无 Scrollable 页面恒等（保护既有焦点测试）；不改 `WindowSizeClass`；Cupertino 不动；i18n 走 i18n_sync 保 17 语言齐全 ✅

**2. Placeholder scan：** 无 TBD/TODO；每个代码步骤含完整代码与确切命令 ✅

**3. Type consistency：**
- `reverseReaderBottomBar` / `toggleReverseReaderBottomBar`（prefsRepo 定义 = AppModel 透传 = schema 调用 = 守卫断言 = 阅读器读取，统一）✅
- `samePane`/`samePaneScore`/`bestSamePane`（Task 1 实现内自洽，最顶档）✅
- i18n key `reverse_reader_bottom_bar`（i18n_sync 加 = schema `t.reverse_reader_bottom_bar` 引用，一致）✅
- `AudioSourceConfig.localAudio(label/path)` / `AudioSourceKind.localAudio`（Task 2 测试 = 既有 dialog 用法，一致）✅
- `MaterialSupportingPaneLayout(supportingSide: SupportingPaneSide.start, minSplitWidth)` / `DesktopContentLayout(kind: DesktopContentKind.settings)`（Task 4 测试 = 既有 API，一致）✅

无遗漏。
