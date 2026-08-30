## BUG-1901 · 番剧详情页标题不能选中复制：全页只有 2/15 个文本可选
- **报告**：2026-08-28（用户：「这个界面，不能复制文件名，下面的简介可以」，附截图，页面为「薬屋のひとりごと 第2期」详情页）
- **真实性**：✅ 真 bug。

### 根因

**不是 `SelectionArea` 的包裹范围问题**——修改前整个 `fushi/lib` 里 `SelectionArea`
只有一处（`utils/components/fushi_material_components.dart` 的日志查看器），与本页
没有任何祖先关系；`VideoDiscoveryDetailPage` 的根就是 `Scaffold`。

真相是**逐 widget 手工选型**：谁被想起来写成 `SelectableText` 谁能选。
`fushi/lib/src/pages/implementations/video_discovery_detail_page.dart`：

| 元素 | 行 | 类型 | 可选 |
|---|---|---|---|
| 标题 | :274 | `Text` | ❌ |
| 原标题 | :283 | `Text` | ❌ |
| 年份·类型·genre | :291 | `Text` | ❌ |
| 评分 | :308 | `Text` | ❌ |
| **简介 overview** | :493 | `SelectableText` | ✅ |
| **facts 右列值** | :518 | `SelectableText` | ✅ |
| facts 左列字段名 / 演职人员 / 相关作品 / genre chip | :511/:584/:718/:534 | `Text` | ❌ |

15 个文本元素只有 2 个可选，而且标题在 `SliverAppBar.flexibleSpace`、简介在另一个
sliver，本就不共享任何 selection 容器。

### 修复与测试

- **[x] ① 已修复** — 页级 `SelectionArea` 包住 `CustomScrollView`，并把页内两处
  `SelectableText` 收成普通 `Text`。
  逐个补 `SelectableText` 只是把这个特殊情况再复制 13 份、下次加字段照样漏；
  页级 `SelectionArea` 让「可选」成为默认，特殊情况消失，还顺带支持**跨元素拖选**
  （标题连着简介一起选）。嵌套的 `SelectableText` 会自成独立选区、反而切断跨元素
  拖选，所以必须一并收掉。
- **[x] ② 已加自动化测试** —
  `fushi/test/pages/video_discovery_detail_selectable_test.dart` 三个用例：
  标题/原标题/简介/元数据/演职人员全部落在**同一个** `SelectionArea` 子树内；
  页内不再有自建选区的 `SelectableText`；`SelectionArea` 不吞按钮点击（回归守卫）。
  **变异实测**（2026-08-28）：把页级 `SelectionArea` 换成透明包装 → 结构断言转红。
  与既有 `video_discovery_detail_page_test.dart` 一起 7 项全绿。

### 备注

- 未做真机复测（选中/复制的实际手感需要真设备）。widget 层已断言结构不变量。
- 同类页面（`video_work_detail_page.dart` 等）没有一并改：本轮只处理用户报的这一页，
  避免把范围扩大到未验证的页面。若后续要统一，正确做法是同样上页级 `SelectionArea`。
