# 桌面外壳 MD3 改造 Roadmap（全 shell，分 4 阶段）

- 日期：2026-06-02
- 范围：Windows/Linux 桌面 **Material** 路径的整个外壳（顶层导航 + 书架 + 词典 + 设置）
- 不在范围：macOS（Cupertino 不动）、iOS、移动端紧凑布局
- 推进方式：**Phase 0→1→2→3 顺序**，每阶段独立可验证/提交，阶段间停下来给用户审

## 缘起与总判断

用户给 macOS 风格「主题编辑器」参考图，要求按 MD3 重做桌面 UI，随后扩大到「整个桌面外壳」，并指向 m3.material.io 实拍图（其自身就是 icon rail + 列表 + 内容的 MD3 桌面布局）。

**诚实说明**：m3.material.io 是 JS SPA，WebFetch 抓不到正文；本 roadmap 的 MD3 依据来自①用户发的官网实拍图②可抓取的 Android/M3 权威镜像（导航栏 3-7 目的地、list-detail 大屏双栏/小屏单栏、tone-based surface：nav=surfaceContainer/content=surface、选中=secondaryContainer pill）③Hibiki 现有代码审计。

**核心结论**：Hibiki 桌面外壳**已约 85% 是地道 MD3**（顶层 80px 图标 rail+pill 指示器、`DesktopContentLayout` 限宽居中、`HibikiPageHeader`/`HibikiCard`/`HibikiSearchField`/`HibikiBadge`/`HibikiTagChip`、设计 token 体系、详情区已是 `HibikiCard` 卡片分组）。本改造是**一致性打磨 + 少数真实结构缺口**，不是推倒重写。

## 全 shell MD3 差距审计（来源：代码 + 两个 Explore 代理）

### 共享外壳（`home_page.dart` / `adaptive_navigation.dart`）
- 顶层 rail 已 MD3（`_HibikiNavTile` 图标后 `secondaryContainer` 圆角 pill + 标签）✓
- spacing 到处魔法数：`gap*0.75`/`gap/2`/`gap/4`/`gap*1.75`/`gap*5.5`（token 仅 page/rowH/rowV/card/gap）
- 桌面仍用 `BouncingScrollPhysics`（iOS 回弹，非桌面 MD3）

### 设置（`settings_home_page.dart` / `material_settings_renderer.dart`）
- list-detail 两栏 ✓、详情 `HibikiCard` 卡片 ✓
- ① 两栏共用 surface 无色差；② 目的地选中=满宽方角(非 pill)；③ 误导 chevron(`pushRoutes:false` 仍显)；④ 详情限宽 760 偏窄；⑤ 间距未到 24
- 已有独立 spec/plan：`2026-06-02-desktop-settings-md3-design.md` / `-plan.md`（= Phase 1）

### 书架（`reader_hibiki_history_page.dart`）
- `DesktopContentLayout(1280)` ✓、`HibikiPageHeader` ✓、`HibikiCard` 网格 ✓、`HibikiBadge`/`HibikiTagChip` ✓
- loading 态 `SizedBox.shrink()` 空白闪屏（:154）
- 卡片选中=自绘 `primary@0.12` 覆盖 + 自绘 check（:580-647），非 MD3 `secondaryContainer`（`HibikiCard.selected` 已支持却没走）
- 标签栏裸 `Container`+0.3 alpha 下边框（:1360-1368），无 tonal surface
- 区标题 ad-hoc（labelMedium+bold+letterSpacing0.8，:486-493）；EPUB-only 时无区结构（:460-461）
- 桌面 `BouncingScrollPhysics`（:393-396,:438-441）

### 词典（`home_dictionary_page.dart` + `dictionary_popup_webview.dart` + `assets/popup/popup.css`）
- `HibikiSearchField`/`HibikiPageHeader`/历史 `HibikiCard`/占位/对话框 ✓、`DesktopContentLayout(1040)` ✓
- **结果列表是全屏 WebView + 手写 CSS**：`popup.css:31-35` 写死 `--surface-container:rgba(128,128,128,.10)`/`--primary-color:#386A58`/`--on-surface-variant:#44483F`，不跟 ColorScheme
  - **已有注入管道**：`dictionary_popup_webview.dart:306-308` 已把 `--hoshi-primary-highlight`/`--text-color`/`--background-color` 从 ColorScheme `setProperty` 注入 WebView
- 搜索框被外层 `SizedBox(kToolbarHeight=56)` 强制（:168-169），非 token `controlHeight=48`
- 单列不利用桌面宽度；子查询用移动端浮窗（maxHeight360）非 MD3 详情区（本期不强改，记为后续）

## 设计决策（已与用户确认）
- 推进顺序：Phase 0→1→2→3 ✓
- 详情区加宽：760→960（Phase 1 ④）✓
- 词典 WebView：**套 MD3 token 配色**（复用现有注入管道，CSS 写死色→消费注入的 MD3 tonal，留 fallback）✓
- macOS：Cupertino 全程不动 ✓
- 选中圆角用**新增 `selectedShape` 参数**而非改 `HibikiListItem` 全局默认（fill 路径逐像素不变，不冲 golden）✓

## 统一 MD3 主线（贯穿各阶段）
1. **Tonal 层次**：content=surface，nav/列表窗格=surfaceContainerLow，卡片=surfaceContainerLow/Container，选中=secondaryContainer pill。
2. **选中态**：一律 `secondaryContainer` 圆角 pill（设置目的地、书架卡片改掉自绘 primary 覆盖）。
3. **桌面物理**：桌面用 `ClampingScrollPhysics`，去回弹。
4. **去误导**：master-detail 不显 chevron。

---

## Phase 0 — 共享 MD3 地基（先做）

> 目标：补齐被各阶段复用的共享能力，避免 Phase 1-3 各自造轮子。

### Task 0.1：`HibikiListItem` 新增 `selectedShape`（pill 圆角胶囊）
- 文件：`hibiki/lib/src/utils/components/hibiki_material_components.dart`
- 内容：加 `enum HibikiListItemSelectedShape { fill, pill }` + 字段 `selectedShape`（默认 `fill`）；pill 时选中高亮 = `margin: horizontal gap` + `decoration: BoxDecoration(color: tokens.surfaces.selected, borderRadius: tokens.radii.groupRadius)` + `InkWell.borderRadius` 裁水波；fill 时保持现状 `color:`（逐像素不变）。
- 测试：`hibiki/test/widgets/hibiki_list_item_selected_shape_test.dart`（pill 有圆角+margin；fill `decoration==null`、`margin==zero`）；现有 `test/goldens/hibiki_list_tile*` 不回归。
- （= 原设置 plan Task 3，提前到 Phase 0 作共享件）

### Task 0.2：桌面滚动物理 helper
- 文件：`hibiki/lib/src/utils/misc/platform_utils.dart`
- 内容：加 `ScrollPhysics desktopAwareScrollPhysics(BuildContext context)` → 桌面（`isDesktopPlatform` 且非 Cupertino）返回 `const ClampingScrollPhysics()`，否则返回 `const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics())`（保持移动端现状）。
- 测试：`hibiki/test/utils/misc/desktop_scroll_physics_test.dart`（桌面 → ClampingScrollPhysics 类型；非桌面 → Bouncing 链）。
- 采用：书架/词典在 Phase 2/3 替换各自硬编码 physics；本任务只引入 helper，不强改调用点（按阶段渐进）。

### Task 0.3：验证 Phase 0
- `dart format .` + `flutter test test/widgets/hibiki_list_item_selected_shape_test.dart test/utils/ test/goldens/hibiki_list_tile_golden_test.dart test/goldens/hibiki_list_tile_extended_golden_test.dart --no-pub` + `flutter analyze`。

---

## Phase 1 — 设置页（方案 B）

详见 `2026-06-02-desktop-settings-md3-plan.md`。在 Phase 0 之上，Task 3（pill）已由 Task 0.1 提供，Phase 1 只需：
- ① `settings_home_page._buildWideLayout`：导航窗格 `surfaceContainerLow` 背景（`!cupertino` 门控）
- ③ `material_settings_renderer.buildDestinationList`：`trailing: pushRoutes ? chevron : null` + `selectedShape: pushRoutes ? fill : pill`
- ④ `platform_utils`：settings cap 760→960
- ⑤ `material_settings_renderer.buildDetailContent`：详情左内缩 `page+gap`(=24) token 化
- 验证 + 设备复测见该 plan。

---

## Phase 2 — 书架（待 Phase 1 完成后细化为 TDD 任务）

任务级提纲（实施前补全代码级步骤）：
- 2.1 loading 态：`SizedBox.shrink()` → MD3 加载态（`adaptiveIndicator` 居中 或卡片骨架）。
- 2.2 卡片选中：移除 `_bookCardShell` 自绘 `primary@0.12` 覆盖，改走 `HibikiCard.selected`（→ `secondaryContainer`）+ 标准 check 角标。
- 2.3 标签栏：裸 `Container` → tonal surface（`surfaceContainerLow`）+ token 化高度/边距。
- 2.4 区标题：`_buildSectionHeader` 改用 `tokens.type.sectionLabel`（与设置一致）；EPUB-only 也给区结构（或都不给，统一）。
- 2.5 桌面物理：网格 `BouncingScrollPhysics` → `desktopAwareScrollPhysics(context)`（Task 0.2）。
- 2.6（可选）魔法数 spacing 就地 token 化。
- 验证：`flutter test` + 书架 golden（若有）+ 设备复测（选中态/标签栏/加载态/桌面滚动）。

---

## Phase 3 — 词典（待 Phase 2 完成后细化）

任务级提纲：
- 3.1 结果 WebView 套 MD3 token 配色：`dictionary_popup_webview.dart` 在现有 `setProperty`(:306-308) 旁补注入 `colorScheme.surfaceContainer/surfaceContainerHigh/outlineVariant/onSurfaceVariant/primary/secondaryContainer` → 新 CSS 变量；`popup.css:31-35` 改为 `var(--md-*, <旧值 fallback>)`。三处调用方（弹窗/悬浮/划词）共用同管道，统一受益。
- 3.2 搜索框尺寸：去掉外层 `SizedBox(kToolbarHeight)` 强制（:168-169），让 `HibikiSearchField` 走自身 MD3 尺寸（或 token `controlHeight`）。
- 3.3 魔法数 spacing（gap/2、gap/4 等）就地 token 化。
- 3.4（记录但不本期做）单列→list+detail / 子查询浮窗→详情区：列为后续独立项。
- 验证：`flutter test` + 设备复测（深色/动态取色下词典结果跟主题联动）。

---

## 全局验证与纪律
- 每阶段：`dart format .` + `flutter test --no-pub`（项目 Flutter 3.44.0）+ `flutter analyze`。
- 静态测试红线：`material_settings_renderer.dart` 保留必需组件名；渲染器内**禁硬编码 EdgeInsets**（走 token）。
- 阅读器/书架/词典/播放类「修好了」前需真实设备复测原始路径并留证据（`.codex-test/`）。
- 提交只 stage 本轮文件（禁 `git add -A`，本工作区可能有并发 agent）。
- code review spawn subagent 必须 `model: "opus"`。
- 不改持久化 key（`reader_ttu`/`setTtu*`/`ttuBookId`/`ttu_*` i18n 是旧数据兼容残留）。
