## BUG-1293 · 内置引擎默认关上传误用upload_mode掐死下载
- **报告**：2026-07-31（用户：内置引擎下载速度几乎为 0，进度不涨）
- **真实性**：✅ 真 bug。链路：默认配置 `uploadEnabled = false`
  （`hibiki/lib/src/media/torrent/anime_download_config.dart:20`）→
  `shouldAllowUpload` 对所有种子返回 false
  （`hibiki/lib/src/media/torrent/torrent_upload_policy.dart:42`）→
  `EmbeddedTorrentHost.sweepUploadPolicy` 每 20s tick 下发
  `setUploadMode(enabled: false)`（`embedded_torrent_host.dart` 旧 `:447-451`）→
  native `ht_set_upload_mode` 给种子置 `lt::torrent_flags::upload_mode`
  （`native/hibiki_torrent/hibiki_torrent_ffi.cpp` 旧 `:546-552`）。
  **libtorrent 的 `upload_mode` 语义是「不再发出任何 piece 请求」= 只上不下、
  停止下载**（官方文档；引擎在磁盘写失败时用它停下载保做种），与
  `hibiki_torrent.h` 旧 `:74-78` 注释宣称的「只下不上」正好相反。于是默认
  配置的用户所有种子在 add 后一个 tick 内被打上该 flag → 下载速率归零、
  进度不涨（auto_managed 偶发短暂退出该模式，表现为「几乎为 0」偶尔蹦一下）。
  该 flag 还会随 resume data 持久化，重启复发。
- **[x] ① 已修复** — 停用 upload_mode 表达「关上传」，换正确原语：
  - native：`ht_set_upload_mode` 改为 enabled=1 只清 flag（治愈残留）、0 为
    no-op 恒成功；新增 `ht_set_unchoke_slots`（会话级 0 槽位 = 停上传
    payload，下载不受影响）与 `ht_pause_torrent`（清 auto_managed + pause，
    做种停止）；`add_with_params` / `ht_load_resume_dir` 加载时清 upload_mode
    残留（治愈已升级用户的 resume）。
  - Dart：`EmbeddedTorrentSession.setUnchokeSlots` / `pauseTorrent` /
    `supportsUploadControl`（探符号，老 DLL 整体降级为不动作，绝不回退
    upload_mode）；`EmbeddedTorrentHost.sweepUploadPolicy` 重写——总开关走
    会话级 unchoke（开启时还原 maxUploadSlots/默认），做种超时/分享率达标
    走 per-torrent pause，**绝不 pause 未完成种子**；`applySessionSettings`
    后失效缓存重新裁决（native 会用 maxUploadSlots 覆盖 unchoke 槽位）。
- **[x] ② 已加自动化测试** —
  - 无 DLL 必跑守卫：`hibiki/test/media/torrent/upload_policy_dispatch_guard_test.dart`
    （fromLookup 假绑定断言 C 入参：关上传绝不下发 upload_mode=0、unchoke
    清零、只 pause 已完成种子、老 DLL 降级不动作）。
  - DLL 行为闭环：`packages/hibiki_torrent/test/upload_off_download_test.dart`
    （本地 rig：unchoke=0 钉死后下载仍从 0 推进到完成——旧语义下必超时红）。
- **备注**：`ht_apply_session_settings` 的 `max_upload_slots` 与本修复共用
  unchoke_slots_limit，顺序由 AppModel 保证（applySessionSettings 后紧跟
  setUploadPolicy）。墙内 swarm 下反吸血默认封禁迅雷系 peer、内置引擎无代理
  入口，是速度偏低的次要结构性因素，不在本 bug 范围。
