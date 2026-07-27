# TODO-1961 ②：改名 / 移动下载内容不掐断做种 —— 可行性评估

- 日期：2026-07-26
- 范围：内置 libtorrent 引擎（`packages/hibiki_torrent` + `native/hibiki_torrent`）+ 视频库路径列
- 结论：**本轮不实现**。①（下载目录可配置）已落地；②需要动 C++ FFI、新增 alert 泵、
  新增库路径迁移 API 三层，且在补上 resume data 之前收益上限极低。

## 1. 用户诉求

用户在下载目录里改名 / 整理文件后，两件事同时断：

1. **做种断** —— libtorrent 的 `torrent_handle` 记着 `save_path` + 种子内相对路径，文件一动，
   引擎读不到数据，上传立刻停。
2. **库条目断** —— 视频入库是**纯引用绝对路径**，没有任何复制：
   - `hibiki/lib/src/media/torrent/anime_download_service.dart:26-44` `resolveVideoAbsolutePaths`
     用 `p.join(info.savePath, f.name)` 拼出绝对路径；
   - `hibiki/lib/src/media/torrent/anime_download_importer.dart:36-86` 直接把这些路径塞进
     `PlaylistEntry`；
   - `hibiki/lib/src/media/video/video_book_repository.dart:190-226` 落 `VideoBooks.videoPath`
     （`packages/hibiki_core/lib/src/database/tables.dart:440`）。
   文件一动，`videoPath` 就是死路径，`subtitleSource` / `secondarySubtitleSource`
   （`tables.dart:441,446`）同理。

## 2. 三条候选路线

### A. 入库改成复制
- 优点：库和做种彻底解耦，用户怎么整理下载目录都不影响库。
- 致命缺点：番剧动辄几十 GB，**磁盘占用直接翻倍**。用户是为了整理文件才提这个需求的，
  给他复制一份显然南辕北辙。**否决**。

### B. 入库改成硬链接
- 优点：不额外占空间，改名/移动「库这一侧」的副本不影响做种那一侧。
- 缺点：
  - 硬链接**不能跨卷**。下载根现在（TODO-1961 ①）可配置到任意盘，库落点若在另一盘就退化，
    需要「跨卷则回退复制/回退引用」的三分支——正是应该消除的特殊情况。
  - Windows 上硬链接需要 NTFS；exFAT / FAT32 外置盘直接不支持。
  - 用户真正想做的是「改名」，而硬链接改的是**另一份**目录项：用户在下载目录里改名，
    库里的链接名字不变；用户在库目录里改名，下载目录里的名字不变。跟直觉不符。
- 结论：能解决「不占双倍空间」，但解决不了「用户在下载目录里动手」这个原始诉求。**否决**。

### C. 引擎侧 `rename_file` / `move_storage` + 库路径迁移（正解，但要三层新代码）

libtorrent 原生支持：
- `torrent_handle::rename_file(file_index_t, std::string)`
- `torrent_handle::move_storage(std::string, move_flags_t)`

现状阻塞点（**全部为零实现**）：

1. **C++ 导出层**：`native/hibiki_torrent/hibiki_torrent_ffi.cpp` 的 `extern "C"` 全表是
   `ht_libtorrent_version` / `ht_session_create` / `ht_session_destroy` /
   `ht_session_listen_port` / `ht_session_set_rate_limits` / `ht_apply_limits` /
   `ht_apply_memory_settings` / `ht_apply_session_settings` / `ht_set_upload_mode` /
   `ht_add_magnet` / `ht_add_torrent_file` / `ht_make_torrent` / `ht_connect_peer` /
   `ht_list_torrents` / `ht_torrent_files` / `ht_torrent_pieces` / `ht_poll_piece_events` /
   `ht_set_piece_deadline` / `ht_apply_first_last_priority` / `ht_torrent_peers` /
   `ht_apply_ip_filter` / `ht_remove_torrent` / `ht_free_string`。
   **没有 rename / move / set_save_path。**
2. **alert 泵**：`rename_file` 与 `move_storage` 都是**异步**的，完成/失败只通过
   `file_renamed_alert` / `file_rename_failed_alert` / `storage_moved_alert` /
   `storage_moved_failed_alert` 回来。现有 FFI 只有 `ht_poll_piece_events` 一条 piece 专用
   事件通道，要新增一条通用 alert 通道（否则「移动完了没有 / 成没成」无从判断，
   只能靠 sleep 猜——正是禁止的补丁式做法）。
3. **Dart 绑定 + 高层封装**：`packages/hibiki_torrent/lib/src/ffi/hibiki_torrent_bindings.dart`
   与 `EmbeddedTorrentSession` / `EmbeddedTorrentBackend` / `TorrentBackend` 接口各加一层
   （外接 qb 侧要用 `POST /api/v2/torrents/setLocation` + `renameFile` 对齐，否则两后端行为分叉）。
4. **库路径迁移 API**：视频库**目前没有任何更新 `videoPath` 的 API**——全仓 `videoPath: Value(...)`
   的写点只有导入/扫描/同步落地。要新增 `updateVideoPath(bookUid, newPath)` 并同时迁移
   `subtitleSource` / `secondarySubtitleSource`。这两件事必须**成对**完成，缺一即断。
5. **Windows 预编译 DLL 要重出**：`native/hibiki_torrent` 的 Windows DLL 随包分发，
   改 C ABI 必须重新构建并更新随包产物，否则用户装上是旧 DLL、新绑定 `lookup` 直接抛。

## 3. 一个会改变优先级的前提：内置引擎没有 resume data

`native/hibiki_torrent/hibiki_torrent_ffi.cpp` 全文只有 `checking_resume_data` 一处
（状态标签映射），**没有** `save_resume_data` / `write_resume_data` / `session::save_state`，
Dart 侧也没有任何「启动时重新 add 已有种子」的路径（`addTorrent` 调用点只有用户主动推种
与订阅推种）。

推论：**每次 app 重启，session 是空的，已完成种子的做种本来就已经断了。**
`AnimeDownloadService` 还会按 `torrentMissingTimeout = 48h` 把仍在 `downloading` 的计划判失败。

所以「改名不掐断做种」在补上 resume data 之前，收益上限只有「同一次 app 会话内改名」这一个窗口。
**resume data 持久化应当是 ② 的前置依赖，而不是并列项。**

## 4. 建议的后续 TODO（按依赖顺序）

1. **TODO-1961-a｜内置引擎 resume data 持久化** —— ✅ **已落地**（见下「6. a/b 落地记录」）
   `save_resume_data` + 启动重新 add。没有它，②、以及「重启后继续做种」「重启后续传」
   全都立不住。这是最高性价比的一步，且**不需要**改名功能就能独立交付价值。
2. **TODO-1961-b｜FFI alert 分派收割** —— ✅ **已落地**（随 a 一起，见下）
   原计划「把 `ht_poll_piece_events` 泛化成 `ht_poll_alerts`」。实际做法更进一步：
   问题不在于「缺一条通用通道」，而在于 **`pop_alerts` 是破坏性的，却有多个消费者**。
   故改成「一个 session 一个收割点 + 按类型分派进各自队列」，加通道不再需要动契约。
3. **TODO-1961-c｜`ht_rename_file` / `ht_move_storage` + Dart 绑定 + qb 后端对齐** —— ✅ **已落地**
4. **TODO-1961-d｜库路径迁移 API** —— ✅ **已落地**
   `updateVideoPath` + 字幕 sidecar 路径同步更新；与 c 在同一个用户操作里原子完成
   （引擎移动成功 → 库改路径；引擎失败 → 库不动）。
5. **TODO-1961-e｜UI：下载页「重命名 / 移动」入口** —— ✅ **已落地**
   让用户在 Hibiki 内做这件事，而不是在资源管理器里改完再来救。
   资源管理器里手动改名**永远**救不回来（app 收不到通知），这一点应当在设置页说明里写清。

## 5. 本轮（①）已经做到的相关部分

- `TorrentSaveRoots.ownsCategoryPath`（`hibiki/lib/src/media/torrent/download_save_root.dart`）
  除了 `<root>/<category>` 全等，还接受它的**子目录**。原实现是 `p.equals` 全等，
  种子一旦被移进分类目录下的子文件夹就从下载页消失。这一步先把「移动后任务从 UI 蒸发」
  这个附带伤害去掉，为 ②-c 铺路。
- 下载根从「单个 final 字符串」变成「活动根 + 历史根集合」，且 `EmbeddedTorrentHost`
  支持**就地**换活动根（不重建 session）。②-c 真正实现时，`move_storage` 的目标根
  可以直接取 `saveRoots.active`。

## 6. a/b 落地记录（2026-07-26）

第 3 节那个「会改变优先级的前提」已经消除：内置引擎现在有 resume data 了。

### 改了什么

| 层 | 改动 |
|---|---|
| C++ | 句柄从裸 `lt::session*` 换成 `ht_session_ctx`（拥有 session + 已收割 alert 队列）；新增唯一收割点 `drain_alerts` 按类型分派；`alert_mask` 加 `storage`；新增 `ht_save_resume_data` / `ht_load_resume_dir` |
| FFI | `hibiki_torrent_bindings.dart` 手写镜像补两个函数（本机无 LLVM，ffigen 跑不了；`ffigen.yaml` 本就声明手写镜像等价） |
| Dart 包 | `EmbeddedTorrentSession.saveResumeData` / `loadResumeDir` + `HtResumeSaveResult` |
| app | `EmbeddedTorrentHost` 持 `resumeDir`，open 时 `restoreFromResume`、每分钟节流保存、dispose 前强制保存；`AppModel` 接线并在启动时按需恢复 |

### 两个必须守住的不变量（都有测试）

1. **计划是真相源**：resume 目录只是计划集合的落盘镜像。load 与 save 之后都按
   `keepIds` 剪枝，用户删掉的任务不会靠残留 `.resume` 复活成「UI 里看不见、却在
   后台占带宽做种」的幽灵种子。
   守卫：`hibiki/test/media/torrent/embedded_torrent_host_test.dart`
   「resume snapshot persists live torrents and prunes plans the user deleted」。
2. **BUG-1053 的边界不许破**：启动时**只有**「resume 目录里存在属于现存计划的
   `.resume`」才建 session。没下载过东西的用户永远不建 session、不绑端口、不起 DHT。
   实现见 `AppModel._restoreEmbeddedTorrentSession`。

### 端到端证据

`packages/hibiki_torrent/test/resume_persistence_test.dart`：本地 rig 下完 →
存 resume → **关掉整个 session** → 新 session（`enableDht: false`、不调
`connectPeer`、纯 btih 磁力无 tracker，即**全程零 peer**）→ `loadResumeDir` →
种子回来、`hasMetadata` 为真、`numPeers == 0`、每个 piece 都在、进入做种态。
零 peer 是这个测试的全部说服力：完成度只可能来自磁盘，不可能是重下的。

## 7. c/d/e 落地记录（2026-07-26，同批）

用户明确选了「**在 Hibiki 内改名/移动**」这条路（另一条「在资源管理器里改完希望
app 跟上」技术上救不回来，见第 8 节）。第 2 节选定的路线 C 全部实现。

### 改了什么

| 层 | 改动 |
|---|---|
| C++ (c) | `ht_rename_file` / `ht_move_storage`；`drain_alerts` 增加 `file_renamed` / `file_rename_failed` / `storage_moved` / `storage_moved_failed` 四种回执分派；`StorageOp` 回执槽 + `await_storage_op` 统一等待 |
| Dart 包 (c) | `EmbeddedTorrentSession.renameFile/moveStorage` + `HtStorageOpResult` |
| 后端契约 (c) | `TorrentBackend.renameFile/moveStorage` + `TorrentStorageResult`；内置引擎直通，外接 qb 走 `renameFile` / `setLocation`（qb 认旧相对路径，故 backend 先用文件列表把下标翻成路径） |
| 库 (d) | `video_path_migration.dart`（纯函数重映射规则）+ `VideoBookRepository.migrateMediaPaths`（三列、一个事务） |
| 编排 (c+d) | `DownloadRelocateService`：引擎先动、成了再迁库 |
| UI (e) | 下载任务行「重命名 / 移动」入口 + `_RelocateDialog`（移动整个任务 / 逐文件改名）；8 个 i18n key × 17 语言 |

### 关键判断

- **`move_storage` 用 `fail_if_exist`**。libtorrent 默认是 `always_replace_files`
  —— 直接覆盖目标同名文件，对用户数据太危险；`dont_replace` 则会静默跳过已存在
  的文件、留下搬了一半的内容目录。只有「目标非空就整体失败、让用户自己决定」是
  可接受的默认。守卫：`rename_move_seeding_test.dart` 的
  「refuses to overwrite an existing file at the destination」用例断言占位文件
  一个字节没变、源内容也还在。
- **失败态必须是「什么都没变」**。所以顺序是引擎先、库后：引擎那步才是会失败的
  一步（目标已存在 / 权限 / 超时），它失败就直接返回，库一个字节不动。反过来
  先改库的话，引擎一失败库就指向一个磁盘上不存在的路径。
- **字幕列的哨兵绝不能当路径重写**。`subtitleSource` 是四态编码
  （绝对路径 / `embedded:<n>` / `off:` / null），把 `embedded:0` 当路径拼一遍
  就是静默损坏。`remapMediaPath` 逐个排除哨兵与流媒体 URL，且路径比较一律走
  `package:path`（手写 `startsWith` 会让 `D:\a` 误匹配 `D:\ab`）。
- **三种结局不能混为一谈**：`success` / `engineFailed`（磁盘与库都没动）/
  `libraryFailed`（磁盘动了、库没跟上）。最后一种必须如实告诉用户，不能当成功。

### 证据

- `packages/hibiki_torrent/test/rename_move_seeding_test.dart`（5 用例）：改名 /
  改到子目录 / 移动，每一项都断言**磁盘上真的变了 + 旧路径消失 + 每个 piece 还在
  + 仍处于做种态**。做种态是关键：引擎要是丢了数据，libtorrent 会掉出 seeding
  并把 piece 标成缺失。
- `hibiki/test/media/torrent/download_relocate_service_test.dart`（15 用例）：
  重映射规则的全部边界 + 原子性（引擎失败时库一个字节不动 / 库失败不许报成功 /
  目标同现状时两边都不打扰）。

## 8. 明确做不到的事

用户**在资源管理器里**改名或移动下载内容，Hibiki **永远**无法自动跟上：app 收不到
任何文件系统通知，等下一轮轮询时引擎按旧路径读盘已经失败了。这一点写进了改名
对话框的说明文案（`anime_download_relocate_hint`）。能给的最好结果是本轮实现的
「在 app 内改名/移动」；将来若要缓解手动改名的后果，方向是「检测到文件失踪时提示
用户手动重新定位」，那是另一个独立能力，不属于本 TODO。

### 顺带记录

跑既有测试时发现 `embedded_pipeline_test.dart` 的 ip_filter 用例本地 flaky
（基线与改动后同为 1/5 通过，已用对照实验排除本轮改动）。根因与影响面见
[BUG-1114](../bugs/BUG-1114-local-rig-rate-limit-flake.md)。
