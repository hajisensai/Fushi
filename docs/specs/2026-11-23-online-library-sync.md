# 在线源条目跨设备同步（拍板台 mY5VWg1nD-）

> 2026-11-23。反馈 mY5VWg1nD-：从在线源加进书库的漫画 / 动画希望在手机和电脑之间同步（举例 Google Drive）。
> 所有者拍板「做」，并补充：不只是书库，媒体都弄上；iOS 收到打不开的条目无所谓。

## 范围

只同步**条目**（重开所需的描述符），不传任何内容字节；条目两端都在之后，既有的进度 / 合集 / 标签 / 作品图谱同步原样接管。

| 种类 | 本机判据 | 跨设备身份 | 收到后 |
|---|---|---|---|
| 在线漫画 | `EpubBooks.sourceMetadata` 是在线漫画描述符，运行时 Mihon / 网页漫画 / Kavita | bookKey（`onlineMangaBookKeyFor`，三元组摘要，跨端一致） | 建书架行 + 占位 `manga.json`，uid 跟着走；章表不进清单，打开作品页时照常刷新（空章表的首次刷新不算新章，不触发提醒 / 自动下载），刷新成功时补封面 |
| 在线小说（LNReader） | `isLnReaderOnlineBookMetadata` | `<插件 id>\u001f<作品路径>` | 按描述符章表建占位 EPUB（无封面），走 `EpubImporter`，写回描述符 |
| 网络视频 | `anime-source://` / `media-server://` / `video/stream/` 身份族的 http 地址 | `VideoBooks.bookUid` | 建同 uid 的行（路径 + 重开规格）；在线视频源取作品缩略图、YouTube 取视频缩略图当封面 |
| 远程音乐曲目 | `music_remote_tracks`（在库，或改动过） | trackUid | 整行 LWW（`updatedAt`），加入 / 移出音乐库都传播 |

不同步：Aidoku（运行时已移除）、互联漫画（指向的就是对端自己的库）、来源库扫描出的条目（随来源配置重扫）。

## 通道

每台设备一份清单（`OnlineLibraryManifest`，带设备 id），读的时候把别的设备的逐份并入本机。

- 云（Google Drive / OneDrive / Dropbox / WebDAV / FTP / SFTP）：`__collections__/online-library-<设备>.json`，与作品图谱同形（per-device 文件、清单镜像缓存）。
- 互联：host 端点 `GET|PUT /api/library/online-items`，能力位 `liveLibrary.onlineItems`。host 把各设备清单存进信箱（偏好 `sync_online_library_peer:<设备>`）；app 当 host 时装 `AppOnlineLibraryParticipant`，GET 附上自己的清单、PUT 时并进自己的库；无头服务端只当信箱，两台客户端经它照样互通。老 host 404 → 同步报告记「对端版本过旧」。

代码：引擎 `packages/fushi_engine/lib/sync/online_library_sync.dart`（清单、信箱、host 端点）；app `fushi/lib/src/sync/online_library_items.dart`（读本机清单、并入规则、host 参与方）、`fushi/lib/src/sync/sync_orchestrator/online_library.part.dart`（两条通道，放在合集同步之前）。

## 并入规则

- 书 / 视频**只增不删**。本机账本（偏好 `sync_online_library_known_v1`：条目 → 见过的最大 addedAt）区分「对端新加的」和「本机删掉的」：本机没有且账本没有 → 建；账本有且对端 addedAt 没变大 → 本机删过（「仅本机删除」不写墓碑），不建回；对端删了又重新加（addedAt 变大）→ 建。本机「从所有设备删除」的墓碑（book / video）挡住删除之前就有的那条。跨设备删除仍走既有的删除墓碑通道。
- 本机是否已有按 DB 判（同一 bookUid 的在线集已下载成本地视频、同一部小说已在库，都算有）。
- 音乐曲目整行 LWW；本机没有、对端也不在曲库里的行（只被歌单引用）不建。

## 已知边界（设计取舍，不是遗留）

- 功能上线前就「仅本机删除」过、对端还留着的条目，第一次同步会被补回一次（账本从这一轮才开始记）。
- 媒体服务器条目的封面要带凭据现算，收到的设备不预取；没配同一台服务器时条目显示为不可用。
- 在线小说的 uid 不跨端对齐（导入时新生成）；书的合集 / 标签按 wire bookKey（书名派生）对齐，不受影响。
- iOS 没有在线源宿主：条目照样落库、打不开（所有者拍板可接受）。
