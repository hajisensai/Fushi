## BUG-3893 · 库页远端条目的「从远端删除」不看对端是否在线，离线时无从得知为何删不掉
- **报告**：2026-10-31（反馈 R8duEiqRuy：「少了把远端的东西也删掉的按钮吧」，截图里书架上一本「远端 · 未下载」的小说，右键菜单只有「仅从本机移除」）
- **真实性**：部分成立。沿真实代码路径核对：
  1. 互联 host 来源的远端书卡**已有**远端删除（反馈 nvlhtczbro，2026-10-10 起），`fushi/lib/src/pages/implementations/reader_history/remote.part.dart` `_showRemoteBookDialog`：判据 `client is InterconnectSyncBackend`，标签「彻底删除」。菜单里只有「仅从本机移除」只会出现在两种情况：远端来源是**云盘备份**（`CloudRemoteBookClient`，没有删除接口，按类型隐藏，真实能力边界），或反馈来自 2026-10-10 之前的版本。截图看不出用户用的是哪种来源，无法进一步判定。
  2. 真缺口：删除项与对端在不在线无关——对端离线时照样亮着，确认后才收到「无法在对端设备上删除」；标签「彻底删除」也看不出是删远端。远端 SRT 卡（同文件 `_showRemoteSrtDialog`）与远端视频卡（`home_video_page.dart` `_showRemoteVideoDialog`）同一问题。
  3. host 侧接口、鉴权、墓碑都已具备：`DELETE /api/library/books/<id>` 走已配对 peer 的 token 校验；`LocalLibraryHostService.deleteBook` 删行后写 `sync_deletion_tombstones`（BUG-2945），其它 peer 经 `/api/tombstones` 拉到。本条不需要新增 host API。
- **[x] ① 已修复** — 所有者 2026-10-31 拍板：可以删远端，但要二次确认，且只在对端在线、可达时可用，离线时禁用并说明原因。
  - `InterconnectSyncBackend.probeHostReachability()`：把会话置脏后走与所有网络操作同一条选路（`_ensureResolved`），返回 `reachable` / `unreachable` / `credentialRejected`——不信缓存会话，对端在会话解析之后才掉线也判得出来。
  - `fushi/lib/src/sync/remote_delete_availability.dart` `RemoteDeleteAvailabilityBuilder`：菜单打开即探测，结论出来后重建菜单；探测中禁用（「正在检查对端是否在线…」），离线 / 配对被拒各有原因文案。
  - `DialogDangerAction.disabledReason`：删除类动作可以「画出来但不可用」，抽屉宫格 / 宽对话框 / 右键菜单三种容器都灰掉、不可点，并把原因写在旁边（触屏没有悬停 tooltip）。
  - 远端书卡与远端 SRT 卡的删除项改名「同时从远端删除」（与「仅从本机移除」成对）；远端视频卡沿用「删除」，可用性规则相同。二次确认框不变（书卡点名 host 与书名）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/reader_remote_book_remove_test.dart`：离线 → 显示但禁用、写明原因、点了不弹确认；配对被拒 → 提示重新配对；探测中禁用、确认在线后才可点并进入二次确认；云盘来源不探测。`fushi/test/pages/media_item_dialog_disabled_danger_test.dart`：三种容器的禁用项都写原因、不触发。`fushi/test/sync/interconnect_remote_delete_test.dart`（真 `FushiSyncServer` + `LocalLibraryHostService`）：探测三态（含会话已解析后 host 下线 → unreachable）；`DELETE /api/library/books/<id>` 无凭据 / 错凭据 401、书与墓碑不动；client `deleteRemoteBook` 后 host 删行删目录、写 book 墓碑、经 `/api/tombstones` 拉得到。
- **备注**：云盘备份来源的远端书仍没有「从远端删除」（云盘后端没有按书删除的接口，墓碑经同步通道传播是另一条路），不在本条范围。真机未验。
