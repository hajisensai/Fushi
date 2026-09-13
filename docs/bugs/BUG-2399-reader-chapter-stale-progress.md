## BUG-2399 · 小说跨章节晚到进度污染阅读字数和速度
- **报告**：2026-09-10（用户：小说越过新章节时速度直接变成100多万）
- **真实性**：✅ 真 bug（代码路径确认）；`fushi/lib/src/pages/implementations/reader_fushi/navigation.part.dart:1074` 的 `_refreshProgress` 在 JS 往返前检查恢复状态，返回后原来只检查 mounted。请求途中跨章或重载后，旧文档的章内起止偏移会按新 `_currentChapter` 换算，污染账本、阅读速度及恢复锚。同文件 `_syncPositionFromWebViewProgress` 和 `chrome.part.dart` 的 `_reloadWithCurrentSettings` 也消费无文档身份校验的晚到快照。
- **[x] ① 已修复** — 三个入口捕获请求时的 controller、章节和导航代次，返回后先核对再消费；统计入口还复核恢复/歌词状态。实现提交见本文件所在 Git 提交。StudyClock 和速度公式未改，未设置速度上限。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_read_ledger_wiring_guard_static_test.dart` 新增四项源码接线守卫，覆盖身份捕获和消费前拒绝；原有恢复锚错误边界守卫同步变量名。统计基础回归119项、阅读器扩展回归281项通过；flutter analyze --no-pub 无问题。
- **备注**：尚未取得用户的平台、版本和原书复现路径，未完成真实设备跨章节复测；确认的是晚到快照竞态，不能据此断言用户的百万速度已在设备上消失。初次测试因 GitHub PDFium 依赖下载失败而零执行，配置本机代理后正常通过。不修改既有统计数据。
