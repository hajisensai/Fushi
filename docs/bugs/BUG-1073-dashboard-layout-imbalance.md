## BUG-1073 · 首页dashboard排版失衡热力图大片空白

- **报告**：2026-07-25（用户：「这个首页的排版烂完了」）
- **真实性**：✅ 真 bug（4K 全屏桌面窗口下必现，两处独立根因）

### 根因

1. **热力图空周不可见**（用户看到的「大片死黑」）
   `hibiki/lib/src/pages/implementations/home_dashboard_page.dart:1055` 传
   `emptyColor: tokens.surfaces.card`（= `ColorScheme.surfaceContainer`），而这张
   区块卡自己的底色是 `_sectionCard` 的 `tokens.surfaces.group`
   （= `surfaceContainerLow`，`hibiki/lib/src/pages/implementations/home_dashboard_page.dart:1684`）。
   两者在 M3 暗色下亮度差极小 → level 0 的格子**画了但看不见**，观感是「只有最近
   几周的彩格，左边一片黑」。格子其实一直在画（`_HeatmapPainter.paint` 只跳过未来
   占位格，`hibiki/lib/src/utils/components/stat_contribution_heatmap.dart:467`）。

2. **列数无上限自适应**
   `hibiki/lib/src/utils/components/stat_contribution_heatmap.dart:351`
   `fitWeeks = (maxWidth + spacing) / (cell + spacing)`，无封顶。4K 全屏时卡内可用
   宽 ~1700 → 铺出 110+ 列（两年多历史），其中只有最近十几列有数据，其余全是上面
   那种「隐形」空格 → 左侧 80% 纯黑。

3. **区块宽高分配**
   `build()` 是「热力图通栏 → 继续|活动 两栏 → 最近添加通栏」的三明治
   （`home_dashboard_page.dart:500-543`）：热力图与最近添加被拉到整页宽（内容只有
   几百 px），继续区一行 4 张卡右侧全空，活动时间轴天然最长 → 左列下方大片空白，
   「设定目标」按钮孤零零挂在热力图下面（`_buildDailyGoalRow` 的 goal<=0 分支）。

### 修复

- **[x] ① 已修复** — 提交哈希：ad4919976
  - `emptyColor` 改 `tokens.surfaces.overlay`（= `surfaceContainerHighest`），空周
    恢复成 GitHub 式浅格子。
  - `StatContributionHeatmap` 新增 `maxWeeks`（默认 53 = 一年）与 `maxCell`
    （默认 18）：列数封顶后把富余宽度分摊给格子边长，既不铺两年空周也不右侧留白；
    命中判定改用本帧实际格子边长（`_onTapGrid(local, model, effCell)`），避免放大后
    点击与绘制错位。
  - 宽屏（>=900）布局改「主列 flex 3（学习活动 → 继续 → 最近添加）+ 侧列 flex 2
    （活动时间轴）」，整页限宽 `_kDashboardMaxWidth = 1600` 居中；窄屏仍单列堆叠。
  - goal<=0 的目标行从「孤零零一个左对齐 TextButton」改成与已设目标态同构的整行
    （图标 + 口径说明 + 右侧设定入口）。
  - 筛选 chips / 点热力图出当日明细 sheet / 目标行 / 继续卡点击 / 活动列表 / 最近
    添加行为全部保留（原有 14 个 widget 测试未改一行断言，全绿）。

- **[x] ② 已加自动化测试** — 测试文件：
  - `hibiki/test/widgets/stat_contribution_heatmap_wide_test.dart`（新增）：超宽
    2000px 下列数封顶 53 + 格子放大到 maxCell 吃满宽度；恰好 53 列自然宽时不放大；
    放大后点击命中仍对齐绘制。
  - `hibiki/test/pages/home_dashboard_page_test.dart`（新增 4 例）：宽屏 1600 主列
    三块左边缘对齐 + 活动列在右 + 热力图不占整宽；空周底色与卡底亮度差 > 0.01 的
    根因守卫；超宽 1920 限宽居中；窄屏 420 仍单列堆叠。

- **备注**：纯排版调整，未引入新依赖、未新增 i18n key。热力图「翻页步长 = 当前屏
  列数」的语义随封顶自动变成「一年一页」，`maxHeatmapPageOffset` 仍按实际列数算，
  历史数据翻页不受影响。
