# Hibiki 平台自适应设计方案 v2

## 核心架构：两层分离

平台自适应分成两个独立的层，不要混在一起：

| 层 | 职责 | 决策方式 |
|----|------|----------|
| **设计层**（布局、组织、信息层次） | 每个界面选一个 A/B/C 变体 | 按 Hibiki Balanced 包，不区分平台 |
| **渲染层**（Widget、控件、动效） | 同一布局用不同平台原生控件渲染 | Android = Material 3 widget，iOS = Cupertino widget |

**为什么不给每个界面选两个 A/B/C？**
- A/B/C 变体定义的是页面的**组织方式**（扫视列表 vs 媒体画廊、步骤流 vs sheet 流），不是 widget 风格
- 如果词典页在 Android 用 A 布局、iOS 用 B 布局，就要维护两套布局代码，每个页面的 bug 修两次
- 真正的「Android MD3 风格 vs iOS Cupertino 风格」体现在 widget 渲染上，不是页面布局上

---

## 第一层：设计选择（统一，不分平台）

沿用 **Hibiki Balanced** 包 + 显式例外。两个平台看到的信息层次、页面组织、交互流程**完全一致**。

| Board | 区域 | 选择 | 方向 | 原因 |
|-------|------|------|------|------|
| 01 | 首页和导航 | **C** | 自适应外壳 | 已包含 mobile + desktop 布局切换 |
| 02 | 书架 | **A** | MD3 网格/列表 | 封面扫视、选择模式最直接 |
| 03 | 词典 | **B** | 安静结果浏览 | 阅读辅助工具，浏览优先于搜索焦点 |
| 04 | Hoshi 阅读器 | **B** | 沉浸安静 | 阅读核心体验 |
| 05 | 设置 | **B** | 分组设置 | 分组布局两端都好用（Android 也有分组设置） |
| 06 | 导入和弹窗 | **A** | 步骤流 | 导入操作需要清晰的步骤引导 |
| 07 | 制卡和 Anki | **C** | 映射面板 | 高密度表单操作 |
| 08 | 收藏和统计 | **A** | 可扫视列表 | 快速定位书签、句子 |
| 09 | 系统和调试 | — | 支撑板 | 继承各子页面所属板的选择 |
| 10 | 词典管理 | **C** | 管理工作区 | 安装、排序、CSS、音频源需要密度 |
| 11 | 阅读器自定义 | **B** | 预览工作室 | 配合阅读器，边改边看 |
| 12 | 媒体和例句弹窗 | **A** | 操作 sheet | 快速操作、明确动作 |
| 13 | 标签和筛选 | **C** | 批量编辑器 | 标签管理需要密度 |
| 14 | 资料/语言/系统 | **A** | 设置中心 | 低频操作，保持朴素 |
| 15 | 日志和调试 | **A** | 朴素查看器 | 功能性，不装饰 |
| 16 | 空/加载/错误 | **A** | 可操作状态 | 诚实状态 + 恢复操作 |
| 18 | 组件系统 | **C** | 混合密度套件 | 共享组件需要同时服务安静页和密集页 |

这跟原始 Hibiki Balanced 推荐一致。不需要改动现有选择文件。

### 高风险界面显式确认

| 界面 | 选择 | 原因 |
|------|------|------|
| `reader_hoshi_page.dart` | B | 阅读器安静 |
| `audiobook_play_bar.dart` | B | 播放栏安静 |
| `lyrics_dialog_page.dart` | B | 歌词跟随 |
| `display_settings_page.dart` | B | 预览工作室 |
| `home_dictionary_page.dart` | B | 浏览优先 |
| `dictionary_result_page.dart` | B | 安静结果 |
| `dictionary_popup_layer.dart` | B | 安静弹出 |
| `dictionary_dialog_page.dart` | C | 管理密度 |
| `dictionary_settings_dialog_page.dart` | C | 管理密度 |
| `anki_settings_page.dart` | C | 映射密度 |
| `tag_management_page.dart` | C | 批量密度 |
| `debug_log_page.dart` | A | 朴素查看 |
| `error_log_page.dart` | A | 朴素查看 |
| `hibiki_bottom_sheet.dart` | C | 共享组件 |
| `hibiki_list_tile.dart` | C | 共享组件 |
| `hibiki_icon_button.dart` | C | 共享组件 |

---

## 第二层：Widget 渲染适配（按平台）

同一个布局，用不同的原生 widget 渲染。这是纯实现层，不需要设计文档——需要的是一份 **widget 映射表**。

### 平台 Widget 映射

| 功能 | Android (Material 3) | iOS (Cupertino) |
|------|---------------------|-----------------|
| 底部导航 | `NavigationBar` | `CupertinoTabBar` |
| 顶部栏 | `AppBar` | `CupertinoNavigationBar` (+ 大标题) |
| 开关 | `Switch` | `CupertinoSwitch` |
| 滑块 | `Slider` | `CupertinoSlider` |
| 对话框 | `AlertDialog` | `CupertinoAlertDialog` |
| 底部弹窗 | `showModalBottomSheet` | `showCupertinoModalPopup` |
| 页面路由 | `MaterialPageRoute` | `CupertinoPageRoute` (滑动返回) |
| 加载指示器 | `CircularProgressIndicator` | `CupertinoActivityIndicator` |
| 搜索栏 | `FloatingSearchBar` (当前) | `CupertinoSearchTextField` |
| 分段控件 | `SegmentedButton` | `CupertinoSlidingSegmentedControl` |
| 操作面板 | `BottomSheet` + ListTile | `CupertinoActionSheet` |
| 文本按钮 | `TextButton` / `FilledButton` | `CupertinoButton` |
| 下拉选择 | `DropdownButton` | `CupertinoPicker` (底部弹出) |

### 设置页的特殊处理

设计层选了 B（分组设置），这意味着设置项要以分组形式呈现。两端都用分组，但 widget 不同：

| 元素 | Android | iOS |
|------|---------|-----|
| 分组容器 | `Card` + `Column` | `CupertinoListSection.insetGrouped` |
| 设置行 | `ListTile` | `CupertinoListTile` |
| 分组标题 | `Text` + padding | `CupertinoListSection` 的 `header` |
| 行分隔线 | `Divider` (0.5px) | 内置 0.33px 分隔线 |

### 不需要平台分支的 Widget

以下场景两端用同一个 widget，不需要适配层：

- **WebView 内容**：阅读器、词典 HTML 渲染（由 web 引擎控制）
- **Icon**：`Icons.*` 两端通用（暂不替换 `CupertinoIcons`，风格差异不大）
- **TextField**：Material `TextField` 在 iOS 上也表现良好
- **ScrollView / ListView**：布局组件，跨平台一致
- **自定义绘制**：统计图表、封面网格等自定义 widget

---

## 实现架构

### 适配组件工厂（新建 `lib/src/utils/adaptive/`）

```
adaptive_platform.dart    — isCupertinoPlatform(context) 检测
adaptive_theme.dart       — 从 Material ColorScheme 派生 CupertinoThemeData
adaptive_widgets.dart     — adaptiveSwitch(), adaptiveSlider(), adaptiveIndicator() 等工厂函数
adaptive_navigation.dart  — adaptiveBottomBar(), adaptiveAppBar(), adaptivePageRoute()
adaptive_dialog.dart      — adaptiveAlertDialog(), adaptiveActionSheet()
adaptive_settings.dart    — adaptiveSettingsSection(), adaptiveSettingsRow()
```

### 注入点

1. `main.dart` builder → 包裹 `CupertinoTheme` overlay
2. `show_app_dialog.dart` → 平台自适应对话框呈现
3. `base_page.dart` → 添加 `bool get isCupertino` 便捷 getter + `buildLoading()` 适配
4. 29 处 `MaterialPageRoute` → 替换为 `adaptivePageRoute`

### 实现顺序

1. **适配基础** — adaptive/ 目录、CupertinoTheme overlay、base_page getter
2. **共享组件** — 13 个 hibiki_* 组件的平台分支
3. **应用外壳** — 首页导航栏、AppBar、showAppDialog
4. **设置族** — 分组设置、开关、分段控件
5. **词典族** — 搜索栏适配
6. **剩余页面** — 导入、收藏、媒体等
7. **阅读器** — 最后碰，只改模态呈现方式

---

## 与 v1 的关键差异

| 项目 | v1（已废弃） | v2（当前） |
|------|------------|-----------|
| 设计层 | 每个界面选 Android=A/iOS=B | 每个界面只选一个（Hibiki Balanced） |
| 平台分支数量 | 10 个 board 双布局 | 0 个布局分支，只有 widget 分支 |
| 维护成本 | 约 50 个页面需要双布局代码 | 约 15 个适配工厂函数 |
| 复杂度来源 | 布局层 × widget 层（乘法） | 布局层 + widget 层（加法） |
| 设置页 | Android=A（平列），iOS=B（分组） | 两端都用分组，widget 不同 |
| 词典页 | Android=A（搜索焦点），iOS=B（浏览焦点） | 两端都用 B（浏览焦点），widget 不同 |

---

## 验证清单

- [ ] 设计层：Hibiki Balanced 选择文件无修改，`generate-implementation-spec.mjs` 可生成
- [ ] 渲染层：`flutter analyze` 通过
- [ ] 渲染层：`flutter test` 通过
- [ ] Android 模拟器：Material 3 widget 正确渲染
- [ ] iOS 模拟器（如有）：Cupertino widget 正确渲染
- [ ] 桌面端：NavigationRail + Material 不受影响
