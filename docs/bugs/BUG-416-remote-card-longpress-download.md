## BUG-416 · 长按远端书/视频卡直接下载(应出选项面板)
- **报告**：2026-06-24（用户：长按远端书籍/视频卡片本应像本地卡那样弹选项页，却直接下载了）
- **真实性**：✅ 真 bug。根因：
  - 远端**书卡** `hibiki/lib/src/pages/implementations/reader_history/remote.part.dart:158-159`：`onTap` 与 `onLongPress` 都绑 `_downloadRemoteBook`（且 `_bookCardShell`（`card_widgets.part.dart:199`）的桌面右键 `onSecondaryTap` 同绑 `onLongPress`）→ 长按 / 右键直接下载，没有选项面板。
  - 远端**视频卡** `hibiki/lib/src/pages/implementations/home_video_page.dart:1021`（`_buildRemoteVideoCard`，`HibikiCard`）：只有 `onTap=_openRemote`（流播），**没有 `onLongPress`** → 长按没反应。
  本地卡长按用 `MediaItemDialogFrame`（`media_item_dialog_page.dart`，纯封面背景动作面板，`quickActions/dangerActions` 可选），本地视频长按 `video.part.dart:_showVideoBookDialog` 已在用——现成可复用。
- **[x] ① 已修复** — 提交 `f82a581ea`
  - 书卡：新增 `_showRemoteBookDialog`（弹 `MediaItemDialogFrame`：下载 / 信息 / 删除[门控]），把 `:158-159` 的 `onLongPress`（连带右键 `onSecondaryTap`）从 `_downloadRemoteBook` 改为 `_showRemoteBookDialog`；`onTap` 保持 `_downloadRemoteBook`（无本地副本不能直接读，短按下载合理）。封面右上角下载 IconButton 保留。
  - 视频卡：`HibikiCard` 加 `onLongPress`/`onSecondaryTap` → `_showRemoteVideoDialog`（弹 `MediaItemDialogFrame`：下载 / 信息）；`onTap` 保持 `_openRemote` 流播。
  - 删除门控：书卡删除动作仅当远端后端是 `HibikiClientSyncBackend`（有 `deleteRemoteBook`/`deleteRemoteAudiobook`）才显示；云盘后端 `CloudRemoteBookClient` 无此能力，隐藏（真实能力边界）。视频侧 `RemoteVideoClient`/`HibikiClientSyncBackend` 无 `deleteRemoteVideo` 能力，故视频卡不提供删除（host/client 流播模型，client 不存视频）。
  - i18n 新增 `remote_book_info` / `remote_book_info_has_audiobook` / `remote_video_info` / `remote_video_info_has_subtitle`（经 `i18n_sync.dart`，17 文件齐 + `slang` 重生成）。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/remote_card_longpress_dialog_test.dart`
  - widget：长按远端书卡 → 弹面板（信息动作可见）且不直接下载；短按书卡仍下载；长按远端视频卡 → 弹面板（信息动作可见）且不进远端播放页。
  - 源码守卫：书卡 `onLongPress` 绑 `_showRemoteBookDialog`（且**不**绑 `_downloadRemoteBook`）、视频卡 `onLongPress` 绑 `_showRemoteVideoDialog`。
  - 回归验证：临时把书卡 `onLongPress` 改回 `_downloadRemoteBook`，长按 widget 测试 + 源码守卫转红，恢复后全绿。
- **备注**：删除动作书卡有（门控），视频卡无（后端无 `deleteRemoteVideo` 能力）。
