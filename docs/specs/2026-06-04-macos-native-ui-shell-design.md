# macOS 原生 UI（macos_ui 全面原生化）设计

- 日期：2026-06-04
- 分支：develop（worktree-macos-native-ui）
- 范围：仅 macOS。iOS / Windows / Linux / Android **零改动**。
- 包：`macos_ui` 2.2.2（要求 Flutter ≥ 3.35.0；项目在 3.44.0，兼容）

## 1. 目标与非目标

### 目标
让 macOS 构建从当前"iOS 风 Cupertino + 部分 Material 桌面外壳"的混合态，变成**真正的 Mac 桌面原生观感**：`MacosWindow` + `Sidebar` + `ToolBar` + 毛玻璃 + 交通灯标题栏融合，逐页、逐控件用 macos_ui 原生控件替换。

### 非目标（明确的边界 / 接受的例外）
- **阅读器、词典的 WebView 内容区不原生化**：它们是 HTML/CSS 渲染，本质上不能用 macos_ui Flutter 控件替换。只把它们的**外壳（工具栏 / 快捷设置 sheet）**换成原生。
- **不动其他平台**：iOS 仍 Cupertino，Windows/Linux 仍 Material 桌面外壳，Android 仍 MD3。
- **不重写业务逻辑 / 状态**：Riverpod、AppModel、设置 schema、导航路由全部复用。

## 2. 架构决策

### 2.1 集成方式：外壳分叉（Approach A）
保留 `MaterialApp` 作为根。macOS 上在 `MaterialApp.home` 子树内：
1. 包一层 `MacosTheme`（从现有 `ColorScheme` 桥接）。
2. `home_page` 渲染 `MacosWindow` + `Sidebar` 托管现有 `buildBody()`。

**为什么 A 成立**：MaterialApp 留在根，所以 Material / Cupertino / macos_ui 三套控件都能拿到各自需要的祖先（Directionality / DefaultTextStyle / MaterialLocalizations / MacosTheme）。`navigatorKey`、`HibikiToast`、全局导航、i18n、主题接线全部不动。

**为什么不选 B（纯 MacosApp 根）**：要重做 navigatorKey/toast/全局导航/Riverpod 主题接线，且内部仍有大量 Material 控件需要 Material 祖先 → 大爆炸、高风险。

### 2.2 平台门控与增量回退（关键）
现状：`adaptive_platform.dart` 的 `isCupertinoPlatform()` 在 macOS（auto）下返回 `true`，macOS 走 Cupertino。

改动：
- 新增设计系统枚举值 `HibikiDesignSystem.macos`，并新增 `bool isMacosPlatform(BuildContext)`：`Platform.isMacOS` 且设计系统为 `auto` 或 `macos`。
- **增量回退原则**：外壳与"已转换"页面查 `isMacosPlatform` 走 macos 分支；**尚未转换的页面/控件仍走 Cupertino 叶子皮肤**作为回退（这些页面在 `MacosWindow` 外壳内照常渲染，不留空白）。
- 实现回退的做法：保持 `isCupertinoPlatform()` 在 macOS 仍返回 `true`（作为未转换路径的回退皮肤）；新增 `isMacosPlatform()` 在已转换路径**优先**判定。已转换的派发点显式写 `if (isMacosPlatform(context)) {...macos...} else if (isCupertinoPlatform) {...} else {...material...}`。

### 2.3 主题桥接
`lib/src/utils/adaptive/hibiki_macos_theme.dart`：
```dart
MacosThemeData hibikiMacosThemeFromColorScheme(ColorScheme cs, Brightness b);
```
映射：`primaryColor=cs.primary`、`canvasColor=cs.surface`、明暗跟随 `themeMode`。**复用现有 ColorScheme 单一真相源**，不另起配色。

### 2.4 macOS 窗口配置
`macos_ui` 的 `MacosWindow` 依赖 `macos_window_utils` 要求窗口透明标题栏 + 全尺寸内容视图。需在 `macos/Runner/MainFlutterWindow.swift` 配置（与已有的 `HIBIKI_TEST_HIDDEN` 离屏逻辑并存，不冲突）。

## 3. 路线图（分期）

每一期是独立的 spec→plan→实现→构建验证→提交循环。

| 期 | 内容 | 交付物 |
|---|---|---|
| **0** | 地基：加 `macos_ui` 依赖；`HibikiMacosTheme` 桥接；`isMacosPlatform` 门控；`MainFlutterWindow.swift` 窗口配置；根接线包 `MacosTheme` | macOS 子树具备 macos_ui 运行条件 |
| **1** | 窗口外壳：`home_page._buildMacosLayout` = `MacosWindow`+`Sidebar`（书架/词典/设置 3 项）+`ToolBar`+原生窗口铬 | "像 Mac 应用"的头号观感 |
| **2** | 设置原生渲染器：`macos_settings_renderer.dart`，schema 项→`PushButton`/`MacosSwitch`/`MacosSlider`/`MacosPopupButton`/`MacosTextField` | 设置页原生控件 |
| **3** | 书架 + 词典外壳：书架原生工具栏/列表；词典 `MacosSearchField`；WebView 内容保留 | 书架/词典原生外壳 |
| **4** | 对话框 + 播放器：`MacosAlertDialog`/`MacosSheet`；有声书播放控件原生化 | 对话框/播放器原生 |
| **5** | 阅读器外壳：阅读器 WebView 内容保留；快捷设置→`MacosSheet`；阅读器工具栏原生 | 阅读器外壳原生 |
| **N** | 焦点/手柄共存 + 测试 + 打磨：HibikiFocus 与 Sidebar 集成；macos 导航测试钩子；Mac 离屏集成测试 | 焦点完整 + 测试守护 |

## 4. 受影响文件（首批，第 0+1+2 期）

- `hibiki/pubspec.yaml` — 加 `macos_ui` 依赖
- `hibiki/lib/src/utils/adaptive/adaptive_platform.dart` — `HibikiDesignSystem.macos` + `isMacosPlatform`
- `hibiki/lib/src/utils/adaptive/hibiki_macos_theme.dart` — 新建，主题桥接
- `hibiki/lib/main.dart` — macOS 子树包 `MacosTheme`
- `hibiki/lib/src/pages/implementations/home_page.dart` — `_buildMacosLayout`
- `hibiki/lib/src/settings/macos_settings_renderer.dart` — 新建，设置渲染器
- `hibiki/lib/src/settings/<renderer dispatch>` — 加 macos 分派分支
- `hibiki/macos/Runner/MainFlutterWindow.swift` — 透明标题栏 / 全尺寸内容视图

## 5. 测试策略

- **widget 测试**：在 `TargetPlatform.macOS` + macos 设计系统下，`home_page` 建出 `MacosWindow` 且含 3 个 `SidebarItem`；设置页渲染出 macos 控件（`MacosSwitch`/`MacosSlider` 等）。
- **源码扫描守卫**：macos 外壳路径不得裸用 Material `Scaffold` 当顶层壳。
- **真机验证**：用 `tool/run_mac_itest.ps1` 在真 Mac 离屏跑构建 + 焦点遍历。**真机肉眼复测列为待办**（按项目纪律，layout/外壳类声明"修好了"前需设备复测并留证据）。

## 6. 风险

1. **macos_ui 与现有焦点/手柄系统（HibikiFocus）的滚动/焦点冲突** → 本期 Sidebar 用 macos_ui 默认焦点，深度集成推迟到第 N 期。
2. **`MainFlutterWindow.swift` 窗口配置与 `HIBIKI_TEST_HIDDEN` 离屏逻辑的交互** → 两者正交（一个管标题栏样式，一个管窗口位置/激活），需验证并存。
3. **未转换页面在 MacosWindow 内的 Cupertino 回退观感** → 接受为增量过渡态，后续期逐步消除。
4. **跨机构建**：编辑在 Windows worktree，构建验证在真 Mac（ssh）。每期 commit→push mac 分支→Mac checkout→`flutter build macos`。

## 7. 验证命令

```bash
# Windows（编辑机，worktree 内）
cd hibiki && dart format . && flutter test

# 真 Mac（构建验证，经 ssh shfaifsj@192.168.1.34）
cd ~/dev/hibiki/hibiki
export LANG=en_US.UTF-8
flutter pub get && flutter build macos --debug
```
