## BUG-3330 · 首页继续区视频作品海报文件不在时直接显示占位，不回落到集封面
- **报告**：2026-10-14（用户：反馈 5CTpiVJ7-v，Windows，「横屏视频自适应没了而且封面不显示」，截图首页「继续」主角卡与横滑卡的视频画成「图标 + 名字」占位）
- **真实性**：✅ 封面部分是真 bug。`fushi/lib/src/pages/implementations/home_dashboard_page.dart:2229`（`path: posterPath ?? video.coverPath`）只认一个候选：合集主封面路径非空就用它，文件不在（换盘 / 清缓存 / 刮削改过路径）也不回落；这一集没抽帧时也不借同合集其它集的封面——而视频页合集卡（`home_video_page.dart` `_collectionRowCoverProvider`）是「自有封面存在才用，否则借成员」。由 abf7b5ff9d（10-09 统一 2:3 竖卡）引入。「横屏自适应没了」是同一提交按用户要求做的统一竖卡改版（注释写明「按用户要求裁进竖卡」），属设计决定，本条不回滚，交主会话 / 所有者裁决。
- **[x] ① 已修复** — 新增纯函数 `dashboardVideoCoverPath`：海报 → 这一集封面 → 同合集其它集封面，取第一张磁盘上真存在的（成员惰性探测、找到即停）。提交见分支 `cc/fb-misc-ui`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_dashboard_page_test.dart`（海报文件不在时回落到集封面且不画占位 + `dashboardVideoCoverPath` 四条单测）。
- **备注**：无截图外的证据能 100% 确认用户机器上走的是哪一个空缺分支（海报文件缺失 / 集封面未抽帧）；两条都已被回落链覆盖。
