## BUG-1249 · 下载发现把空响应或损坏 RSS 伪装成无结果且不说明筛选原因
- **报告**：2026-07-29（用户：下载时无结果且没有任何报错，要求说明原因）
- **真实性**：✅ 真 bug。`hibiki/lib/src/media/torrent/nyaa_client.dart:206` 的宽容解析会把空 body / 损坏 XML 都压成空列表；`hibiki/lib/src/pages/implementations/anime_download_dialog.dart:1575` 又把所有空列表统一渲染成一句「无结果」，真实响应异常与本次查询/筛选条件均不可见。
- **[x] ① 已修复** — 本提交：Nyaa 搜索入口对空响应、非 RSS 与损坏 XML 抛出可见格式错误；有效 RSS 的 0 条结果显示实际查询词、分类和 Trusted 筛选。
- **[x] ② 已加自动化测试** — `hibiki/test/torrent/nyaa_client_test.dart` 覆盖空响应/坏 RSS/有效空 feed 三分支；`hibiki/test/pages/anime_download_dialog_discovery_ux_test.dart` 覆盖真实 0 条原因与损坏 feed 错误态。
- **备注**：定向测试启动前被 `sqlite3` 原生资产从 GitHub 下载超时阻断（0 tests ran）；已保留该环境阻塞，不把它记为断言通过。
