## BUG-3662 · interconnect-download-unmanageable-without-browse
- **报告**：2026-10-23（用户：应用内反馈 _sZllpFQWm，iPad 3.0.0+19763 经互联看 Windows 主机视频——①「下载远端集」后没有任何地方能暂停 / 取消，重开 app 正在下的那集还会自动续传；② 找不到删除已下载到本机的视频的地方）
- **真实性**：✅ 真 bug，两处根因：
  1. 互联下载任务（`InterconnectDownloadManager`）唯一的列表入口是「浏览 → 下载」：`fushi/lib/src/pages/implementations/browse_page.dart:932` 把 `InterconnectDownloadTasksSection` 链进统一任务列表；而「浏览」整模块的 `ModuleId.browse.availableOn` 委托到 `StoreRestrictedCapability.downloads`（`fushi/lib/src/models/store_compliance.dart`），iOS 上整模块缺席。互联下载（拷用户自己另一台设备上的内容）并不是受限能力，却随下载中心一起没了入口；合集详情页集卡菜单（`media_collection_detail_page.dart` `_showEpisodeMenu`）与远端视频卡动作面板（`home_video_page.dart` `_showRemoteVideoDialog`）只有「下载」，没有暂停 / 取消。另外 `InterconnectDownloadManager.startBatch` 对被暂停的成员只计 failed 然后**继续起跑下一集**——即便能暂停当前集，整批也停不下来。管理器也没有「取消在跑任务」的原语（`discard` 拒绝 running）。
  2. 下载到本机的副本是一行普通本机视频（bookUid = 对端 id），而合集成员在库页折叠进合集卡；合集详情页集卡菜单没有任何删除动作，唯一能删的地方是库页单卡（被折叠看不到）。且通用删除链 `FushiDatabase.deleteVideoBooks` 默认 `removeFromCollections: true`，直接复用会把这一集从合集里摘掉（合集只剩它时连带自删），而不是退回远端集。
- **[x] ① 已修复** — 见本 bug 所在提交（Feedback: _sZllpFQWm）。
  - 管理器：新增 `canCancel` / `cancel`（在跑的先发中止信号、等这一轮真正停下，再 `discard` 删 `.part` 与续传清单，重开 app 不再自动续传）；`startBatch` 遇到用户暂停 / 取消正在跑的成员即停整批（`InterconnectDownloadBatch.skipped` 记没起跑的成员，`isRunning` 随之结束）。
  - 新增独立页 `InterconnectDownloadTasksPage`（复用下载中心同一个 `DownloadTaskBrowser` 与同一条任务映射），不依赖浏览模块、不问任何合规门；入口：设置 › 互联「互联下载」（`interconnect.download_tasks`）、合集详情页「管理」菜单、远端视频卡动作面板。
  - 就地动作：合集详情页集卡菜单给远端集「下载到本机 / 暂停 / 恢复 / 取消下载」；远端视频卡动作面板在有任务时把「下载到本机」换成暂停 / 恢复 / 取消 + 「互联下载」。
  - 删除本机副本：集卡菜单对「id 仍在对端清单里的本机成员」给「删除本机副本」（`CollectionRemoteContext.deleteLocalCopy`，库页实现 `_deleteDownloadedLocalCopy`）：走媒体库删除链（`keepLocalOnly` + 删下载下来的文件），新增 `removeFromCollections: false` 一路透传（`deleteVideoBooksWithDecision` → `VideoBookRepository.deleteVideoBooksAndReclaimAssets` / `deleteVideoBooks` → `FushiDatabase.deleteVideoBooks`），成员行保留，这一集退回远端集；用户自己导入的本机原件（对端清单里没有这个 id）不给这条动作。
  - 合规：未写任何平台特判；`StoreRestrictedCapability` / `ModuleId.browse` 不变，下载中心（torrent / 磁力 / 直链）在 iOS 上照旧缺席。
- **[x] ② 已加自动化测试** —
  - `fushi/test/sync/interconnect_download_resume_test.dart`「取消 / 停整批」三条：取消在跑任务删 part 与清单、取消暂停任务 + 不可暂停的书不能取消、暂停整批里正在跑的那一集后续不再起跑；
  - `fushi/test/media/video/video_delete_local_copy_keeps_collection_test.dart`：`removeFromCollections: false` 删行删文件但成员行留着、该集退回远端槽；默认删除仍摘成员并让空合集自删；
  - `fushi/test/pages/collection_detail_remote_members_test.dart`「集卡菜单…」：远端集给恢复 / 取消（取消后任务移出、part 删除），下载副本给「删除本机副本」、本机原件不给；
  - `fushi/test/pages/interconnect_download_tasks_page_test.dart`：独立页列出任务；页面与设置入口不挂 `StoreRestrictedCapability` / `ModuleId` / `visible:` 门。
- **备注**：入口位置备选——(a) 把整个下载中心页拆出浏览模块、在 iOS 上只隐藏受限来源段：改动面大，且下载中心的添加任务 / 执行设备 / 订阅都是受限能力，iOS 上要逐段剥；(b) 只做设置页入口：离发起下载的地方太远。最终取「就地动作（集卡 / 远端卡）+ 独立互联下载页（三处入口）」。真机（iPad）未验证。
