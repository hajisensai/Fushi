## BUG-1687 · 存量 qBittorrent 分类仍是改名前的 hibiki
- **报告**：2026-08-16（用户：「qb分类…没换成fushi」）
- **真实性**：✅ 真 bug，但**不能静默改写**。默认值早已是 `fushi`
  （`fushi/lib/src/media/torrent/anime_download_config.dart:15,51`），改名批次
  `3faab77149` 改了默认值却没有迁移已落盘的 `qb_connection_config` JSON，所以改名前
  配置过的用户，存量值一直是 `hibiki`（新装用户不受影响）。
- **[ ] ① 未修复（刻意不自动迁移）** — 静默改写会破坏进行中的下载：
  * 内置引擎的分类**就是保存目录**（`embedded_torrent_backend.dart:87,103` 的
    `_categoryPath`，`listTorrents` 按 `ownsCategoryPath` 过滤），改名后存量种子直接
    掉出列表，要真迁移得移动几十 GB 并掐断做种；
  * 下载任务行各自存着自己的 `category`，管线在
    `video_download_pipeline_service.dart:1152` 用「当前配置分类 ≠ 任务分类」判任务
    失配并抛「backend/profile/category 不再匹配」，改配置等于把存量任务全判死。
  正确做法是把这条留给用户：分类在 设置 → 下载 里可直接改，等手头没有进行中的任务
  时改成 `fushi` 即可（外接 qBittorrent 侧也可先在 qB 内把旧分类的种子改分类）。
- **[ ] ② 未加自动化测试** — 无行为改动可守。
- **备注**：与 BUG-1684（对外 UA）同一批用户反馈，但性质不同：UA 是每次请求现算的，
  改了立刻生效且无存量数据；分类是落盘的用户配置且与磁盘布局绑定。
