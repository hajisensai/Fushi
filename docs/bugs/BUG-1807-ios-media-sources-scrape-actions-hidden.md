## BUG-1807 · iOS视频来源页隐藏全部刮削与任务入口
- **报告**：2026-08-24（`iPhone pay` / iOS 26.6 物理机视频来源页寻找直接“全部刮削”按钮）
- **真实性**：❌ 未复现。当前自动设计系统是 MD3，`MediaSourcesPage._buildHeader` 确实构造全部刮削与任务两个动作；375pt 窄屏下 `FushiPageHeader.customTitle` 按 `fushi_material_components.dart:2060-2098` 的既定响应式规则把两个动作收进“更多操作”菜单，避免 6 段导航标题被挤没。直接 `FushiIconButton(scrape_all)` 不在树中不等于能力隐藏。
- **[x] ① 无需修复** — 不向区头重复塞第二套动作，不改生产响应式布局。
- **[x] ② 已验证** — 物理实测由 `video_source_import_flow_itest.dart` 打开“更多操作”并选择“全部刮削”，验证当前后台刮削任务面板；宽屏仍走直接按钮分支。
- **备注**：该记录保留用于区分“响应式收纳”与“能力丢失”。
