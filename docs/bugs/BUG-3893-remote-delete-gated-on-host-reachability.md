## BUG-3893 · 库页远端条目缺「从远端删除」（云盘来源没有、互联来源不看对端是否在线）
- **报告**：2026-10-31（反馈 R8duEiqRuy：「少了把远端的东西也删掉的按钮吧」，截图里书架上一本「远端 · 未下载」的小说，右键菜单只有「仅从本机移除」。所有者确认那本书来自**云盘备份**）
- **真实性**：✅ 真缺口。沿真实代码路径核对：
  1. 云盘备份来源（`CloudRemoteBookClient`）按类型隐藏了远端删除（`fushi/lib/src/pages/implementations/reader_history/remote.part.dart` `_showRemoteBookDialog`，旧判据 `client is InterconnectSyncBackend`），理由写的是「云盘后端没有删除接口」——**不成立**：六种云盘后端（Google Drive / WebDAV / OneDrive / Dropbox / FTP / SFTP）的 `deleteAsset(id, isFolder: true)` 都是递归删、404 视为已删，缺的只是「按书删除」这一层编排。用户截图正是这种情况。
  2. 云盘的「从所有设备删除」只写 `__tombstones__` 标记、书文件夹原样留着（`pendingRemoteDeletionKeys` 注释），而云通道书阶段对每本本地书都 `ensureBookFolder`（`SyncManager.syncAllBooks`），持有旧副本的设备下一轮同步就把被删的书文件夹建回云盘——删除意图在云通道上会被撤销（互联通道早有等价把关，反馈 Et3pmRzo0k）。
  3. 互联 host 来源已有远端删除（反馈 nvlhtczbro），但删除项与对端在不在线无关，离线时照样亮着、确认后才失败；远端 SRT 卡、远端视频卡同一问题。host 侧接口、鉴权、墓碑（BUG-2945）都已具备，不需要新增 host API。
- **[x] ① 已修复** — 所有者 2026-10-31 拍板：可以删远端，但要二次确认，且只在来源在线、可达时可用，离线时禁用并说明原因。
  - **云盘按书删除** `CloudRemoteBookClient.deleteRemoteBook`：一本书在云盘上的全部对象都在它的书文件夹里（内容包、封面、`progress_` / `statistics_` / `audioBook_` JSON、`audiobook.fushiaudio`；跨书的只有合集清单，按键引用）。先发布云删除墓碑（`__tombstones__/` 逐条标记，与「从所有设备删除」同一协议，键 = 文件夹名 = 其它设备的 bookKey）并记进本机墓碑表（标已发布，下一轮并进本机合并清单），再递归删书文件夹，最后逐出并写回书名→folderId 缓存（BUG-202）。墓碑写失败则什么都不删；文件夹删失败如实报错，墓碑已在、可重试。
  - **云通道推送否决** `SyncOrchestrator`：云墓碑同步拆成「扫描」（发布 + 读回 + 写清单）与「消费」（产确认候选）。云通道在书阶段**之前**先扫描一次，管得着本地书的墓碑（删除发生在本机拥有之后，判据与确认候选同源 `peerTombstoneVetoesPush`，对端键按别名换算）让这本书整本跳过书阶段，不再重建书文件夹；墓碑阶段直接复用这次扫描做消费，不重复读。删除之后才在本机重新加入的书照常同步。扫描失败（已记进报告）本轮不否决，墓碑阶段再完整跑一遍。
  - **「从所有设备删除」也删云盘书文件夹**（所有者 2026-10-31 第二次拍板）：云通道发布本机未发布的书墓碑时（`SyncOrchestrator._scanCloudDeletionTombstones`），先写标记、再按墓碑键找同名书文件夹递归删掉（`deleteCloudBookFolder`，与书架远端删除共用），都成了才标「已发布」；删失败如实记错、不标已发布，下一轮重写标记（幂等）并重试。
  - **删了再重新导入不会被自动删**：墓碑的匹配键是 bookKey（= 云盘书文件夹名），重新导入同名书会复用同一个键，所以靠的是时间：墓碑只管 `deletedAt` 之前就在的那份（`tombstoneAppliesTo`：`deletedAt > localAddedAt`）。唯一入库口 `insertEpubBook` 把 `localAddedAt` 记成导入时刻，并清掉本机同键墓碑；本机、另一台下载新书的设备、互联 host 闸门（`kPeerPushPresentSinceHeader`）、云推送否决与删除确认候选全用这一条判据。按根因不需要换新 ID：键相同 + 时间比较已经能区分新旧，换 ID 反而会让其它设备的旧副本对不上墓碑、收不到删除确认。随之修掉一个会让新书「看不见」的口子：云盘书库原来对本机墓碑「一直藏」，别的设备重新导入并上传的书在删除方书架上永远不出现；现在发布墓碑 ⇔ 文件夹已删，云盘书只藏未发布的墓碑（`loadPendingRemoteDeletionKeys`），媒体服务器等来源不变。
  - **可达性**：`InterconnectSyncBackend.probeHostReachability()`（置脏会话后重走选路）与 `CloudRemoteBookClient.probeRemoteReachability()`（列一次同步根），统一返回 `RemoteSourceReachability`（reachable / unreachable / credentialRejected）。`RemoteDeleteAvailabilityBuilder` 菜单打开即探测，探测中 / 连不上 / 配对被拒或登录失效都禁用并写原因，互联说「对端」、云盘说「云盘」。
  - `DialogDangerAction.disabledReason`：三种菜单容器都灰掉、不可点、把原因写在旁边。
  - 远端书卡（互联 + 云盘）与远端 SRT 卡的删除项叫「同时从远端删除」；远端视频卡沿用「删除」。二次确认：互联点名 host 与书名，云盘点名云盘类型与书名并说明其它设备下次同步会确认是否一并删除。
- **[x] ② 已加自动化测试** —
  - `fushi/test/sync/cloud_remote_book_delete_test.dart`：六种云盘后端类型各跑一遍按书删除（书文件夹里五个对象全删、别的书不动、墓碑标记与本机墓碑行、缓存逐出）；书名含转义字符时墓碑键 = 文件夹名；墓碑写失败 → 什么都不删；文件夹删失败 → 抛出、重试成功；无本机库拒绝执行；可达性三态；**其它设备**跑完整云同步 `run()`：持有旧副本 → 不重建书文件夹、收到确认候选、别的书照常同步；删除后重新加入 → 照常同步。「从所有设备删除」组：同步一轮先写墓碑再删文件夹、标已发布、残留不再藏；删文件夹失败 → 记错、不标已发布、继续藏、下一轮删掉；**删除 → 重新导入 → 本机与另一台设备各同步一轮**：本机不弹确认、照常上传、书仍在，新设备书架看得见、下载后不被删，旧副本设备仍收到（只针对旧那份的）确认且不推旧的；别的设备重新导入上传后删除方看得见；书架远端删除后重新导入同样当新书；媒体服务器来源照旧一直藏。
  - `fushi/test/sync/interconnect_push_respects_host_tombstone_test.dart`：新增「删后重新导入的那份经 `/api/tombstones` 拉到旧墓碑也不产候选，旧副本照常产」（重新导入后推回 host、host 清墓碑的既有用例仍在）。
  - `fushi/test/pages/reader_remote_book_remove_test.dart`：互联来源离线 / 配对被拒 / 探测中禁用、在线后二次确认；云盘来源连不上 / 登录失效禁用（云盘措辞）、可达时二次确认点名云盘、取消不删、确认删除并刷新、删除失败如实提示；无删除能力的来源不探测。
  - `fushi/test/pages/media_item_dialog_disabled_danger_test.dart`：三种容器的禁用渲染。
  - `fushi/test/sync/interconnect_remote_delete_test.dart`（真 `FushiSyncServer`）：探测三态、`DELETE` 无凭据 401、删除后 host 写墓碑并经 `/api/tombstones` 拉得到。
- **备注**：
  - 只有 WebDAV / Drive 等的**通用编排**用内存后端测过；各后端 `deleteAsset(isFolder: true)` 的协议实现是既有代码（逐个核对过都是递归删 + 404 幂等），本轮没有对真实云盘跑。
  - 「从所有设备删除」按墓碑键（bookKey）找云盘书文件夹；本机改过书名、云盘文件夹按新书名建的那种，文件夹名与墓碑键对不上，删不到（推送否决仍按两种键都挡，不会被写回）。
  - 本机删除之后、墓碑发布之前，如果别的设备恰好重新导入并上传了同名书，发布时会把那个新文件夹一起删掉；那台设备的书 `localAddedAt` 晚于删除、不受墓碑管，下一轮同步会重新上传，不丢数据。
  - 不带推送否决的旧版客户端仍可能把被删的书建回云盘；建回后在删除方书架上会显示为远端书。
  - 书阶段之外的单本同步（`sync_auto_trigger` 合上书时的单书同步、对比弹窗）不经推送否决：正在读一本被别处删掉的书时仍可能把文件夹建回去，墓碑仍在、确认框照常出现。
  - 真机未验。
