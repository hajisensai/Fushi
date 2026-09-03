## BUG-1751 · 漫画滚轮缩放步进取决于本机 deltaY，与右键菜单不同口径
- **报告**：2026-08-20（用户：「the zoom function in the manga reader on the scroll wheel … currently zooms by like..... 112% and it would be super nice to have better granular control」，希望像右键菜单一样按 10% 步进）
- **真实性**：✅ 真 bug（口径不一致 + 不可预期）。根因 `fushi/lib/src/media/manga/manga_overlay_html.dart` 的 Ctrl+wheel 监听：`_zoomAbout(ZOOM * Math.exp(steps * 0.2 * ZOOM_SENS), …)`，其中 `steps = clamp(-deltaY/100, -4, 4)`。
  - 代码注释假设「一格标准滚轮 deltaY=100 ≈ +22%」，但 **WebView2 在高 DPI 上一格根本不是 100**：BUG-1065 实测同款机器（4K / 150% 缩放）app 内一格 `deltaY≈67`。用户实测约 112% 对应 `deltaY≈57`。也就是说「一格缩多少」取决于运行环境的 deltaY 绝对值，用户无法预期、文档也说不准。
  - 另一半是**同一功能两套口径**：右键菜单（`manga_fushi_page.dart` 的 `_MangaContextAction.zoomIn/zoomOut` → `_setZoomPercent(_zoomPercent ± 10)`）和设置滑块（`settings_schema_manga.dart` 的 `manga.default_zoom`，step 10）都是 ±10 个百分点的**线性**步进，只有滚轮是乘法。
  - 历史：最早是「deltaY 只当符号 + 恒 ±0.1 加法」，因「缩放极其不灵敏」改成乘法；这次是把线性步进要回来，但改掉当年真正的毛病（触控板碎 delta 与鼠标一格同等对待）。
- **[x] ① 已修复** — 滚轮改为**对齐到 `ZOOM_STEP` 网格的定量步进**：`ZOOM_STEP = max(1, round(10 * ZOOM_SENS))`（默认灵敏度 → 恰好 10 个百分点），目标值 `dir>0 ? (floor(cur/STEP)+1)*STEP : (ceil(cur/STEP)-1)*STEP`，所以序列恒为 100→110→120…，捏合留下的非整倍率也会被拉回网格。三个要点：
  1. **「一格」的判定复用本文件翻页滚轮的同一套累计口径**（阈值 40 + 反向清账）：鼠标一格无论 deltaY 是 57/67/100 都 ≥40，恒好一步；触控板碎 delta 攒够 40 才走一步。跨阈即清零、不留余数——留余数会让 deltaY=57 攒出 1,1,2,1,1,2 的非匀速台阶，正好毁掉「一格 = 10%」的承诺。
  2. **浮点毛刺**：先 `cur = Math.round(ZOOM*1000)/10` 再取整。否则 `ZOOM=1.2` 常存成 `1.2000000000000002`，`Math.ceil(120.00000000000003/10)=13`，缩小一步算出 120 → 被 `_zoomAbout` 的 0.0005 死区吃掉 → **缩不动**。
  3. **`ZOOM_SENS` 仍然管用**（设置项承诺它覆盖滚轮）：改为缩放**步长本身**而不是指数底数，语义仍是「越大每一步缩得越多」，注释不撒谎。
  锚点数学、clamp、`onMangaZoomChanged` 回传全部复用原 `_zoomAbout`，一行未改（它只接收目标绝对倍率）。触屏捏合**保持连续比例**（`Math.pow(g.dist/pinch.dist, ZOOM_SENS)`）——捏合必须跟手，不能有台阶。Flutter 侧零改动（回传的整数百分比天然是步长的整数倍）。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_overlay_html_test.dart` 的 `desktop zoom and right-button drag/menu contract is embedded` 改写为新契约：正向断言 `ZOOM_STEP` 定义式、网格上下取整两式、消浮点毛刺式、阈值 40 累计式、反向清账式；反向断言 `Math.exp(` 在整份文档里**不再出现**（全文件已无其它 `Math.exp` 用法，实测 grep 为空）。捏合的 `Math.pow` 断言原样保留。
- **备注**：
  - 该测试原本的断言 `expect(doc.contains('Math.exp(steps * 0.2 * ZOOM_SENS)'))` + reason「滚轮缩放必须是按 delta 幅值的乘法缩放，不能是定长加法」与本次需求**语义相反**，是连注释一起改写的，不是放宽。
  - 滚轮缩放仍需按住 Ctrl/Cmd（裸滚轮在 spread 模式归翻页，两个监听器互斥，未动）。
  - 代价：线性步进下 100%→400% 需要 30 格。灵敏度设置（25%~400%）是逃生口——设 400% 时一格 40 个百分点、8 格到顶。
