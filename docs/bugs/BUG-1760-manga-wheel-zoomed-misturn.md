## BUG-1760 · 漫画放大态滚轮误翻页应页内平移贴边才翻
- **报告**：2026-08-21（用户：Discord moonbeam「i find myself accidentally scrolling
  to the next page decently often; would love to change it to vertically scrolling」）
- **真实性**：✅ 真 bug（UX 缺陷）。spread 模式滚轮无条件翻页（`manga_overlay_html.dart`
  滚轮翻页监听），放大阅读（ZOOM>1，页面超出视口）时页内明明有内容可滚，滚轮却在翻页
  ——「误翻」全部发生在这个状态。
- **[x] ① 已修复** — 收成一条语义：**滚轮滚的是内容；没有内容可滚才翻页**（不加设置
  项，消除特殊情况）。ZOOM>1 时滚轮走 `_panBy`（含钳制，与拖动/方向键平移同一入口），
  动得了就消费事件；贴边后继续滚落入原有 40px 累计阈值 + 反向清账翻页（惯性不会一冲
  跨页），贴边翻页时下一页从顶部、上一页从底部接续；ZOOM<=1 整页放得下，维持滚轮翻页。
  deltaX/deltaY 分别做 deltaMode 归一化。webtoon 不变（原生竖滚）。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_reanchor_raster_guard_test.dart`
  「BUG-1760 放大态滚轮平移优先」组：`_panBy(-wdx, -wdy)` 平移优先 + 「动了就消费」
  判据 + 贴边翻页仍走累计阈值。
- **备注**：产品决策（2026-08-21 用户确认方向）：不加「滚轮行为」偏好项，自动规则
  覆盖两种意图。
