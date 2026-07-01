# macOS 原生 UI 外壳（第 0+1+2 期）实现计划

> **For agentic workers:** 用 superpowers:executing-plans 逐任务执行。步骤用 `- [ ]` 勾选追踪。

**Goal:** 让 macOS 构建呈现真正的 Mac 桌面原生观感：`MacosWindow`+`Sidebar`+`ToolBar`+毛玻璃，设置页用 macos_ui 原生控件，其他平台零改动。

**Architecture:** 外壳分叉（Approach A）——MaterialApp 留根，macOS 上 `home` 子树包 `MacosTheme`、`home_page` 渲染 `MacosWindow`；未转换页面在壳内回退 Cupertino。设计系统 schema 单一真相源，加 macos 渲染器分支。

**Tech Stack:** Flutter 3.44.0 / macos_ui 2.2.2 / macos_window_utils（macos_ui 依赖）/ Riverpod。

---

## 文件结构

- `hibiki/pubspec.yaml` — 加 `macos_ui` 依赖
- `hibiki/macos/Runner/MainFlutterWindow.swift` — 接 `macos_window_utils`，保留 HIBIKI_TEST_HIDDEN
- `hibiki/lib/src/utils/adaptive/adaptive_platform.dart` — `HibikiDesignSystem.macos` + `isMacosPlatform()`
- `hibiki/lib/src/utils/adaptive/hibiki_macos_theme.dart` — 新建，ColorScheme→MacosThemeData
- `hibiki/lib/main.dart` — macOS 子树包 `MacosTheme`；main() 调 `WindowManipulator.initialize`
- `hibiki/lib/src/pages/implementations/home_page.dart` — `_buildMacosLayout`（MacosWindow+Sidebar）
- `hibiki/lib/src/settings/settings_renderer_factory.dart` — 新建，`settingsRendererFor(context)` 统一派发
- `hibiki/lib/src/settings/macos_settings_renderer.dart` — 新建，macos 渲染器
- 5 处派发点改用 `settingsRendererFor(context)`
- 测试：`hibiki/test/macos/` 下 widget + 源码守卫

---

## 第 0 期 · 地基

### Task 0.1：加 macos_ui 依赖 + Mac 验证可解析

**Files:** Modify `hibiki/pubspec.yaml`

- [ ] **Step 1:** 在 `dependencies:` 加 `macos_ui: ^2.2.2`（按字母序插入）。
- [ ] **Step 2:** Windows worktree `cd hibiki && flutter pub get`，确认无版本冲突。预期：解析成功，`macos_window_utils` 作为传递依赖出现在 lock。
- [ ] **Step 3:** commit `feat(macos): add macos_ui dependency`。

### Task 0.2：MainFlutterWindow.swift 接 macos_window_utils（保留测试离屏）

**Files:** Modify `hibiki/macos/Runner/MainFlutterWindow.swift`

- [ ] **Step 1:** 顶部加 `import macos_window_utils`。
- [ ] **Step 2:** `awakeFromNib` 把 `contentViewController` 从裸 `FlutterViewController` 换成 `MacOSWindowUtilsViewController(flutterViewController:captureOverlayView:false)`；其余（windowFrame、hiddenTestMode 离屏、accessory、setFrame、RegisterGeneratedPlugins）保留不动。`canBecomeKey/Main` 覆写保留。
- [ ] **Step 3:** Mac 构建验证（见末尾跨机命令），`flutter build macos --debug` 编译通过。
- [ ] **Step 4:** commit `feat(macos): wire macos_window_utils content view, keep test-hidden`。

### Task 0.3：设计系统门控 `isMacosPlatform`

**Files:** Modify `hibiki/lib/src/utils/adaptive/adaptive_platform.dart`

- [ ] **Step 1:** `enum HibikiDesignSystem { auto, material, cupertino, macos }` 加 `macos`。
- [ ] **Step 2:** 加函数：
```dart
bool isMacosPlatform(BuildContext context) {
  final HibikiDesignSystem ds =
      Theme.of(context).extension<HibikiDesignSystemTheme>()?.designSystem ??
          HibikiDesignSystem.auto;
  switch (ds) {
    case HibikiDesignSystem.material:
    case HibikiDesignSystem.cupertino:
      return false;
    case HibikiDesignSystem.macos:
      return true;
    case HibikiDesignSystem.auto:
      break;
  }
  return Theme.of(context).platform == TargetPlatform.macOS;
}
```
保留 `isCupertinoPlatform` 在 macOS（auto）仍返回 true 作回退。`isCupertinoPlatform` 的 `macos` 分支显式返回 false（macos 设计系统不再当 cupertino）。
- [ ] **Step 3:** `flutter analyze` 通过（switch 穷举）。
- [ ] **Step 4:** commit `feat(macos): add isMacosPlatform design-system gate`。

### Task 0.4：主题桥接 `hibiki_macos_theme.dart`

**Files:** Create `hibiki/lib/src/utils/adaptive/hibiki_macos_theme.dart`

- [ ] **Step 1:** 写：
```dart
import 'package:flutter/material.dart' show ColorScheme, Brightness;
import 'package:macos_ui/macos_ui.dart';

/// 从现有 ColorScheme 单一真相源派生 macos_ui 主题，明暗跟随。
MacosThemeData hibikiMacosThemeFromColorScheme(
  ColorScheme cs,
  Brightness brightness,
) {
  final MacosThemeData base = brightness == Brightness.dark
      ? MacosThemeData.dark()
      : MacosThemeData.light();
  return base.copyWith(
    primaryColor: cs.primary,
    canvasColor: cs.surface,
  );
}
```
- [ ] **Step 2:** `flutter analyze` 通过。
- [ ] **Step 3:** commit `feat(macos): ColorScheme->MacosThemeData bridge`。

### Task 0.5：main() 初始化 WindowManipulator + home 子树包 MacosTheme

**Files:** Modify `hibiki/lib/main.dart`

- [ ] **Step 1:** main() 里 `runApp` 之前，仅 macOS 调 `if (Platform.isMacOS) await WindowManipulator.initialize(enableWindowDelegate: true);`（import macos_ui + dart:io）。
- [ ] **Step 2:** 在已初始化分支的 `MaterialApp` 之上/`home` 注入处，macOS 用 `MacosTheme(data: hibikiMacosThemeFromColorScheme(cs, brightness), child: home)` 包裹（cs 取自 appModel 当前 ColorScheme，brightness 取自 themeMode/平台）。非 macOS 不变。
- [ ] **Step 3:** Mac `flutter build macos --debug` 通过。
- [ ] **Step 4:** commit `feat(macos): init WindowManipulator + wrap home in MacosTheme`。

---

## 第 1 期 · 窗口外壳 + 侧边栏

### Task 1.1：home_page `_buildMacosLayout`

**Files:** Modify `hibiki/lib/src/pages/implementations/home_page.dart`

- [ ] **Step 1:** build 顶层加分支：`if (isMacosPlatform(context)) return _buildMacosLayout();`（在 LayoutBuilder 之前，因为 MacosWindow 自管布局）。
- [ ] **Step 2:** 实现 `_buildMacosLayout()`：
  - `MacosWindow(sidebar: Sidebar(minWidth: 220, builder: (ctx, scroll) => SidebarItems(currentIndex: _currentTab, onChanged: _selectTab, items: [书架/词典/设置])), child: buildBody())`
  - Sidebar item 复用 `_navItems()` 的 label，icon 用 `MacosIcon`。
  - `buildBody()` 包进 `MacosScaffold(children: [ContentArea(builder: ...)])` 或直接作为 child（按 macos_ui API）。
  - 顶部 `ToolBar(title: Text(当前 tab 标签))`。
- [ ] **Step 3:** 加测试钩子 key `hibikiMacosNavKey`（类比 `hibikiMaterialNavKey`）便于集成测试定位。
- [ ] **Step 4:** Mac `flutter build macos --debug` + 启动截图验证窗口/侧边栏出现。
- [ ] **Step 5:** commit `feat(macos): MacosWindow + Sidebar shell in home_page`。

### Task 1.2：widget 测试——macOS 壳建出 MacosWindow + 3 sidebar 项

**Files:** Create `hibiki/test/macos/macos_shell_test.dart`

- [ ] **Step 1:** 写失败测试：pump `HomePage`，`Theme` 注入 `HibikiDesignSystemTheme(macos)` + `platform: TargetPlatform.macOS`，断言 `find.byType(MacosWindow)` 命中且 `find.byType(SidebarItems)` 含 3 项。
- [ ] **Step 2:** 跑测试 `flutter test test/macos/macos_shell_test.dart --no-pub` 确认先失败（若 Task1.1 已实现则直接绿）。
- [ ] **Step 3:** commit `test(macos): shell builds MacosWindow + 3 sidebar items`。

---

## 第 2 期 · 设置原生渲染器

### Task 2.1：统一渲染器派发 `settingsRendererFor`（消除 5 处重复）

**Files:** Create `hibiki/lib/src/settings/settings_renderer_factory.dart`；Modify 5 处派发点

- [ ] **Step 1:** 读 `SettingsRenderer` 抽象接口（cupertino/material renderer 的父类），确认方法签名。
- [ ] **Step 2:** 写工厂：
```dart
SettingsRenderer settingsRendererFor(BuildContext context) {
  if (isMacosPlatform(context)) return const MacosSettingsRenderer();
  if (isCupertinoPlatform(context)) return const CupertinoSettingsRenderer();
  return const MaterialSettingsRenderer();
}
```
- [ ] **Step 3:** 把 `settings_home_page.dart:73` / `hibiki_settings_page.dart:80` / `display_settings_page.dart:59` / `reader_quick_settings_sheet.dart:504` / `settings_detail_page.dart` 五处的三元派发替换成 `settingsRendererFor(context)`。
- [ ] **Step 4:** `flutter analyze` 通过。
- [ ] **Step 5:** commit `refactor(settings): unify renderer dispatch via factory`。

### Task 2.2：`MacosSettingsRenderer` 实现

**Files:** Create `hibiki/lib/src/settings/macos_settings_renderer.dart`

- [ ] **Step 1:** `implements SettingsRenderer`，逐方法映射：
  - switch → `MacosSwitch`
  - slider → `MacosSlider`
  - stepper → `PushButton` ± 或 `MacosStepper`（无则用 +/- PushButton）
  - segmented → `MacosSegmentedControl`
  - dropdown/选择 → `MacosPopupButton`
  - text field → `MacosTextField`
  - tile/list → `MacosListTile`
  - 详情面板 → 可滚动 `ListView`（对齐 cupertino renderer 的滚动策略）
- [ ] **Step 2:** `flutter analyze` 通过。
- [ ] **Step 3:** widget 测试：macos 设计系统下设置页渲染出 `MacosSwitch`/`MacosSlider`，切换真写穿 DB（焦点驱动或直接 onChanged 回调断言）。
- [ ] **Step 4:** Mac `flutter build macos --debug` + 截图验证设置页原生控件。
- [ ] **Step 5:** commit `feat(settings): macos_ui native settings renderer`。

---

## 验证（每期收尾）

```bash
# Windows worktree
cd hibiki && dart format . && flutter test --no-pub

# 真 Mac（ssh shfaifsj@192.168.1.34）——push 分支后
git push mac HEAD:refs/heads/worktree-macos-native-ui
ssh shfaifsj@192.168.1.34 'cd ~/dev/hibiki && git fetch origin && git checkout worktree-macos-native-ui && cd hibiki && export LANG=en_US.UTF-8 && export PATH=$HOME/flutter/bin:$HOME/.gem/ruby/2.6.0/bin:$PATH && flutter pub get && flutter build macos --debug'
```

## 后续期（3/4/5/N）
进入时各自细化为独立 plan：书架/词典外壳、对话框/播放器、阅读器外壳、焦点-手柄共存+测试。模式同上：派发点查 `isMacosPlatform`、WebView 内容保留只换外壳、每期 Mac 构建验证 + 提交。

## 执行进度（2026-06-04，分支 worktree-macos-native-ui）

| 期/任务 | 状态 | 提交 | 验证 |
|---|---|---|---|
| 0.1 macos_ui 依赖 | ✅ | 80ce82f15 | pub get 解析 macos_ui 2.2.2 + macos_window_utils 1.9.1 |
| 0.2 MainFlutterWindow.swift | ✅ | 8bd8b567d | Mac `flutter build macos` 通过（pod 集成 macos_window_utils 原生层） |
| 0.3 isMacosPlatform 门控 | ✅ | bd5d7e240 | analyze 绿（switch 穷举） |
| 0.4 主题桥接 | ✅ | 8e6722cb7 | analyze 绿 |
| 0.5 main.dart 接线 | ✅ | adb22181e | Mac 构建通过 |
| 1.1 MacosWindow+Sidebar 外壳 | ✅ | 642fb8cf3 | Mac 构建通过；CoreGraphics 证实 800x628 不透明主窗口渲染 |
| 1.2 壳静态守卫 | ✅ | 642fb8cf3 | 3 测试绿 |
| 2 · switch 原生化 | ✅ | 932dcf6f1 | analyze+97 设置测试绿；Mac 构建通过 |
| 2 · slider 原生化 | ✅ | 9eac1fe44 | MacosSlider + 保留 onChangeEnd 的拖拽包装；Mac 构建通过 |
| 4 · dialog button 原生化 | ✅ | d82f379fc | adaptiveDialogAction→PushButton（默认/破坏/次要）；Mac 构建通过 |

**自主视觉验证闭环——已打通（绕开 Spaces/TCC）**：
- OS 级截图全堵死：`screencapture` 只拍活动 Space（hibiki 窗口稳定在非活动 Space）；`screencapture -l` 对非活动 Space 报错；`CGWindowListCreateImage` macOS15 已废弃；`ScreenCaptureKit` 对 sshd swift 进程 TCC -3801 拒；移窗/切 Space 需辅助功能权限 -609/-1712 拒。
- **解法 = 应用内 RepaintBoundary.toImage**：`integration_test/macos_shell_screenshot_test.dart` 经 `flutter drive -d macos` 启真 app，抓 Flutter **引擎 framebuffer**（非 OS 窗口），写 PNG 到 sandbox 容器 tmp，base64 拉回。`takeScreenshot` 通道在 macOS 未实现（MissingPluginException），故直接遍历 RepaintBoundary 取窗口尺寸那个（排除病态超宽边界，如 100000×31）。**可跨 Space、跨 TCC、可重复**。
- **shell 视觉已验证**：原生 Sidebar（书架/词典/设置）+ 书架内容 + 空状态卡片，无报错。侧边栏毛玻璃在 framebuffer 里偏白是固有现象（NSVisualEffectView 是平台视图不在 Flutter 图层），真显示器上是暗色毛玻璃。

**截图揪出并修复的真 bug**：`No Material widget found — InkResponse 需 Material 祖先`。根因=`buildBody()` 放进 `MacosWindow.child` 后无 Material ink surface（MaterialApp 只给主题不给 Material widget，平时靠 Scaffold 提供）。修复=macos 内容包透明 `Material(type: transparency)`（提供 ink surface 不改观感）。提交 97ffd7b0d，加静态守卫断言 `MaterialType.transparency`。

**可见的待打磨项（真显示器复核）**：侧边栏 vibrancy 明暗是否跟随主题；页面顶栏 chip 与 titlebar 间距。Phase 3/5 页面铬现已可经此闭环视觉验证后再做，不再是盲改。

## 架构精炼（执行中发现，覆盖原 spec）

- **去掉冗余的 MacosSettingsRenderer + settingsRendererFor 工厂**：渲染器只是页面铬，真正的控件渲染在单一层 `lib/src/utils/adaptive/adaptive_widgets.dart`（`adaptiveSwitch/Slider/SegmentedButton…`）。Cupertino 的 inset-grouped 列表本就是 macOS 设置惯用法（系统设置即分组列表），在 MacosWindow 里观感正确。故 macOS 沿用 Cupertino 渲染器铬，**只在 adaptive_widgets.dart 加 `isMacosPlatform` 分支**换原生控件。DRY、避开 MacosScaffold-在路由里耦合 MacosWindowScope 的风险。
- **门控顺序**：macOS auto 下 `isCupertinoPlatform` 仍返回 true（未转换路径回退），所以 adaptive 控件里 `isMacosPlatform` 分支必须排在 `isCupertinoPlatform` 之前。

## 控件原生化逐项 API 注意（后续做时照此，禁草率直换）

- **switch → MacosSwitch**：✅ 已做。onChanged 可空（支持 disabled），activeColor 用系统强调色（传 null 更原生；MacosSwitch.activeColor 是 MacosColor 非 Color）。
- **slider → MacosSlider**：⚠️ 暂留 Cupertino 回退。`MacosSlider` **无 `onChangeEnd`/`onChangeStart`/`divisions`/`label`**，只有 `discrete`+`splits`。设置滑条（如 app_ui_scale）依赖 commit-on-end，硬换会回归（记忆 [[project_app_ui_scale_browser_zoom]] 的 bug 模式）。需先做一个保留 onChangeEnd 语义的包装再换。
- **segmented → ?**：⚠️ 暂留。`MacosSegmentedControl` 是 `MacosTabController` 驱动的 tab 控制器，不适配「值集合」分段。值分段更适合换 `MacosPopupButton` 或自绘 push-button 组；需重映射 `SettingsSegmentedItem` 选项模型。
- **stepper → ?**：⚠️ 暂留。macos_ui 无现成 stepper；用 ± `PushButton` + 文本自绘。
- **text field → MacosTextField**、**indicator → ProgressCircle**、**dialog action → PushButton**、**modal → MacosSheet**：留待 Phase 2 续 / Phase 4。

## 后续期（3/4/5/N）
进入时各自细化为独立 plan：书架/词典外壳、对话框/播放器、阅读器外壳、焦点-手柄共存+测试。模式同上：派发点查 `isMacosPlatform`、WebView 内容保留只换外壳、每期 Mac 构建验证 + 提交。

## 自审
- 覆盖：spec 第 4 节首批文件全部有对应 task；MacosSettingsRenderer/factory 经架构精炼去除（理由见上） ✓
- 占位符：无 TBD/TODO ✓
- 类型一致：`isMacosPlatform` / `hibikiMacosThemeFromColorScheme` / `hibikiMacosNavKey` 命名前后一致 ✓

## 完成状态（2026-06-04，Approach B 全量落地）

macOS 原生适配在 macos_ui (2.2.2) API 范围内**实质完成**。共 ~29 提交，全量 lib analyze 绿，2039 单测绿（唯一 1 个全量套件失败是 `app_model_audio_sources_test` 的跨测试状态污染，隔离运行即过，与本工作无关），关键页面均经 `flutter drive` framebuffer 截图肉眼验证。

### 已原生化（macos_ui 控件，截图验证）
- **外壳**：根 `MacosWindow`（Approach B，包整个 navigator）+ `Sidebar`（书架/词典/设置，notifier 驱动）+ `MacosScaffold`+`ToolBar` + `MacosTheme`（从 ColorScheme 桥接）。
- **设置**：宽屏主从布局；`MacosSwitch`（开关）、`MacosSlider`（滑块，含保留 onChangeEnd 的拖拽包装）。
- **词典**：`MacosTextField` 搜索框（搜索图标 prefix + 原生清除按钮 + onSubmitted）。
- **对话框按钮**：`PushButton`（默认/破坏/次要）。
- **阅读器**：在根 MacosWindow 内打开；阅读时隐藏侧栏沉浸（门控 `appModel.isMediaOpen`）。

### 自主视觉验证闭环
`integration_test/macos_shell_screenshot_test.dart`（home/设置/详情/词典）+ `macos_reader_screenshot_test.dart`（seed EPUB→开阅读器）经 `flutter drive -d macos` 抓 `RepaintBoundary.toImage` framebuffer，写 sandbox 容器 tmp 再 base64 拉回——绕开 Spaces/TCC（OS 截图全堵）。揪出并修复 2 个真崩溃：InkResponse 无 Material ink surface、ToolBar 要 full-size content view。

### 刻意保留的原生-适配回退（macos_ui API 缺口，非遗漏）
- **segmented**：`CupertinoSlidingSegmentedControl`——本身即原生风分段控件；`MacosSegmentedControl` 是 `MacosTabController`+`MacosTab(String)` 式，不适配「值集合 + Widget 标签」，强转脆弱。
- **stepper**：macos_ui 无对应控件；保留设计系统中性的 `_KeyboardStepper`（+/- + 键盘/手柄焦点逻辑，不可丢）。
- **对话框框架/modal sheet**：Material 居中 `Dialog` + 原生按钮 / Cupertino popup——观感可接受，转 MacosSheet 改语义且收益低。
- **普通文本框**（非搜索）：共享 `HibikiTextField`，仅搜索变体转 MacosTextField。

### 本质不可原生化
- 阅读器/词典 **WebView 正文**是 HTML（且 macOS 上是平台视图 WKWebView，不进 Flutter framebuffer，截图为空属正常）——按设计只换外壳不换内容。

### 待用户真显示器复核
侧栏 vibrancy 明暗跟随主题、ToolBar 标题位置、整体观感（framebuffer 抓不到 NSVisualEffectView 平台视图）。

### 待处置
~29 提交在 Mac 裸库 `worktree-macos-native-ui` 分支，**未合并 develop**——正式落地需用户确认后合并。
