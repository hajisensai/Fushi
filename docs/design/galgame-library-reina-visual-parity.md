# 游戏库视觉对齐 ReinaManager（M1.5 UI overhaul）契约

> 上一轮（PR#400，已合 develop）对齐了**信息架构与数据模型**，但 UI 只是套了 Hibiki 现成的
> 书架网格 / 普通 TabBar，**观感与 ReinaManager 完全不像**。本轮把四个界面的**视觉表现**
> 做到接近 ReinaManager。参考 `references/ReinaManager`（AGPL-3.0），只还原布局观感、
> 不复制其 React/MUI 源码。全部在 Hibiki 现有 Flutter/MD3 设计系统 token 上实现。
>
> ⚠️ MD3 静态守卫（`test/settings/md3_design_system_static_test.dart`）仍然生效：普通页面
> chrome 不许直接用未 token 化的原生构造（裸 `Card(` / `ListTile(` / `BorderRadius.circular(`
> / `fontSize:` / `surfaceContainer*` 等）。新组件要么走 `hibiki_material_components.dart` /
> `hibiki_design_tokens.dart`，要么这些新文件本身是设计系统组件（放 `utils/components/`）。

## 全局视觉基调（ReinaManager `reinaTheme.ts` 实测）

- **卡片圆角**：20（Hibiki 用 `HibikiBorderRadius.card`=10，本轮游戏库自定义一档 `galgameCard`=16~20，
  放进 design tokens，别硬编码）。**按钮**：pill（圆角 999）、weight 700、无大写。
- **强调色 / 数据可视化色**：ReinaManager 全程用 `#1976d2`。Hibiki 走主题色 `colorScheme.primary`
  —— **用主题色，不硬编码 #1976d2**（Hibiki 支持动态主题，硬编码会破坏暗色/自定义配色）。
- **KPI 数值**：大号粗体（h5/22px、weight 700）；标签小号次要色（13px）。

## 1. 库页海报网格（改 `games_library_page.dart`）

- 卡片改成 **3:4 竖版海报**（现在是套书架的 `kShelfBookCardAspectRatio`）。新建共享组件
  `GalgamePosterCard`（放 `utils/components/`，过 MD3 守卫）：
  - 结构：`封面(3:4, object-cover, ClipRRect 圆角 galgameCard) → [底部排序信息渐变浮层] ；封面下方 标题(居中, 单行省略, ~16px)`。
  - 封面轻微滤镜可省（Flutter 不好做 saturate/contrast，跳过，不影响观感大局）。
  - **hover**：放大到 1.05 + 阴影加深（`MouseRegion` + `AnimatedScale`，200ms）。**选中态**：2px 主色边框环。
  - **排序信息浮层**：封面底部 `Align(bottomLeft)`，`px 10 / 顶部 24 渐变 / 底部 6`，
    `LinearGradient(transparent→black54→black87)`，白字 13px weight 600，单行省略。显示当前排序维度的值
    （添加日期 / 发行日 / 评分 X.X / 站点分 #rank / 相对最后游玩），名称排序时不显示。受一个开关控制。
  - 多选角标（20×20 方形主色 + check 18px，左上 6px）—— M1.5 可选，先不做多选，留结构。
- **网格**：`SliverGridDelegateWithMaxCrossAxisExtent` 或按宽度算列数，`crossAxisSpacing/mainAxisSpacing 16`，
  卡片含标题的整体宽高比按 3:4 封面 + 标题条估。列数随宽度（窄屏 3 列、宽屏更多），别再用书架的 extent。
- 顶部工具条（搜索 / 排序 / 筛选入口）保留上一轮的功能，视觉上收成一行。
- 卡片点击**仍启动游戏**；长按/右键进详情（沿用上一轮）。

## 2. 详情页富头部（改 `galgame_detail_page.dart`）

- 头部（tab 之上常驻）：`Row`（窄屏 `Column`），**封面居左**（max 宽 160→320、max 高 260、圆角 8、大阴影），
  右侧信息列：
  - 元信息网格（数据来源 / 开发商 **chips** / 发布时间 / 添加时间 / 预计时长 / 排行 / 评分），
    每项 `label(粗) + value`，flex-wrap，右 24 下 8 间距。
  - 评分行：`站点 X.X`（outlined）+ `我的 X.X`（outlined primary）两个 chip。
  - 标签区：标题行（"游戏标签" + 搜索/清空）+ flex-wrap 的标签 chips（outlined，选中态 filled primary），
    上限 40 + 展开/折叠。
- Tab 栏保留（统计 / 简介 / 编辑；存档·评价是 M2 不做）。tab 下 body `pt 24`。
- 用 `HibikiTagChip` / `HibikiActionChip` 等既有组件，别裸 `Chip(`。

## 3. 游戏首页/仪表盘（新增 `galgame_home_page.dart` 作为游戏模块新默认子页）

placement：`home_game_page.dart` 的 `IndexedStack` 加一个 `GameSection.dashboard` 作**默认首屏**，
`GameSectionTabs` 加一项；库/工作台/诊断顺延。ReinaManager `HomePage` 的布局：

- **区域 A**：4 格 KPI 条（总游戏数 / 总时长 / 今日时长 / 本周·本月时长），单行四等分，
  cell `min-h 88`、图标盒 42、数值 22px/700、标签 13px 次要色。用 `getGalgamePlayTotals` 聚合。
- **左列**：
  - **Focus 卡**（最近游玩）：深色卡、封面出血做背景 + 左→右深色渐变蒙版；内容：状态 chip、
    大标题(26~34px/800, 2 行截断)、副行(实时计时 or 上次游玩 + "本周 X · 总计 Y")、启动/详情按钮行、
    "最近玩过" 4 格缩略图网格。实时计时用 tracker 的当前会话（无则显示上次游玩）。
  - **随机游戏卡**（固定 150 高）：缩略图 + 标题/开发商/标签 + 换一个/启动。
- **右列**：动态时间线（全部/游玩/添加筛选），按日期分组，左侧竖轨 + 圆节点 + 头像行。
  复用 `activity_events`（game 类）。

> 这是 M1.5 最大的一块。若时间/复杂度超预算，优先级：**库页 > 详情页头部 > 统计图 > 游戏首页**。
> 游戏首页可只做 KPI 条 + Focus 卡 + 时间线（随机卡次要）。

## 4. 统计图（详情页统计 tab）

- 每日游玩时长用**折线图**（现在是柱状），高 ~300，线色 `colorScheme.primary`（不硬编码 #1976d2），
  7 天档显点、更长档只线。X 轴日期、Y 轴时长（"Xh Ym" 格式），双向淡网格。
- 时间范围切换 7D/30D/M/1Y/ALL（ToggleButton）。用 `getGalgameDailySeconds`。
- 复用 Hibiki 现有图表绘制方式（先看 `reading_statistics_page.dart` / `home_dashboard_page.dart`
  怎么画的），别引图表库。KPI 四卡 + 时间线列表沿用上一轮统计 tab 的数据。

## 验证
- MD3 静态守卫必须绿；`flutter analyze` 含 test 零 issue；相关 widget 测试绿。
- 真机截图对比（Windows 离屏）：四个界面各留一张证据。
- 主题色不硬编码；暗色/亮色都要看得过去。
