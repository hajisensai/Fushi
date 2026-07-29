## BUG-1235 · 合集字幕匹配无法区分来源与逐集可用性
- **报告**：2026-07-29（用户：字幕来源看不出哪个是哪个，也看不出每集有没有字幕）
- **真实性**：✅ 真 bug。`hibiki/lib/src/pages/implementations/jimaku_entry_picker.dart:11`
  原先只渲染 `entry.name` 的 chip；`jimaku_batch_dialog.dart` 的成员副标题也只在下载
  完成后显示语言，下载前没有文件清单、来源身份或逐集可用性；同时
  `jimaku_client.dart` 把空白 `name` 当有效值，未回退 `english_name`，会直接画出空条目。
- **[x] ① 已修复** — 搜到来源后，每个 Jimaku 条目只列一次全部文件，汇总可解析字幕
  数、覆盖集数、语言、Jimaku/AniList ID；当前来源再按真实集号把合集成员标成有字幕、
  无字幕或存在未标集号候选。严格预检查会把 HTTP 失败、畸形 200 与合法零字幕分开；
  客户端创建失败也会结束 loading，下载只在当前来源预检查成功且非空时开放，快速切
  系列的迟到响应与数据库写入不会覆盖新选择，实际批量下载不再把请求失败伪装成无匹配。
- **[x] ② 已加自动化测试** —
  `hibiki/test/media/video/jimaku_client_test.dart` 覆盖清单聚合、严格 HTTP/畸形响应与
  合法空数组；`jimaku_batch_test.dart` 覆盖批量失败语义和下载门禁；
  `jimaku_batch_dialog_state_test.dart` 覆盖客户端工厂失败、loading/成功门禁与快速
  切系列竞态；`jimaku_entry_picker_test.dart` 覆盖来源身份、摘要、失败态和选择。
- **修复提交**：`37b101471`
- **备注**：同组定向测试 55/55，`flutter analyze --no-pub` 通过；真实 Jimaku 网络
  与设备 UI E2E 未在本轮执行。
