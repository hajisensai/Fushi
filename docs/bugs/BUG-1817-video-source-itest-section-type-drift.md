## BUG-1817 · 视频来源实测仍按旧两段库页导航驱动
- **报告**：2026-08-24（`iPhone pay` / iOS 26.6 物理机运行 `integration_test/video_source_import_flow_itest.dart`）
- **真实性**：✅ 真 bug（测试基建）。用例同时保留多条旧流程假设：旧两段导航、跳过新版来源类型二选一、模态返回后盲扫 Tab、窄屏不走“更多操作”，以及“全部刮削”仍期待已淘汰的 `ScrapeBatchDialog`。生产已是 6 段 `VideoLibrarySection` + 来源类型选择 + 稳定焦点 ID + 响应式动作收纳 + 后台 `VideoSourceScrapeTaskController` 任务面板。物理机逐层暴露了这些漂移。
- **[x] ① 已修复** — 用例对齐六段导航、来源类型、稳定焦点、更多菜单与后台任务面板；提交 `bb1f2ddf7`。
- **[x] ② 已加自动化测试** — iPhone 视频来源全链 GREEN；RED 曾表现为旧导航 finder 为 0 与来源类型模态 12 分 51 秒未完成。
- **备注**：测试改为生产 `VideoLibrarySection` 真值，逐步断言首页→发现→系列→全部视频→来源及反向返回；激活添加后用焦点选“本地文件夹”，由既有 override 接管目录选择；来源模态返回后请求分段导航的具体稳定焦点节点再按方向键，不复制过时流程也不靠无界 Tab 扫描。
