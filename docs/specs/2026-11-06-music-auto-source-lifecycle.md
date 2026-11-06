# 视频来源自动登记的音乐来源：生命周期（反馈 QAondMh4M5）

叠在 PR #2977（纯音频改归音乐库）上。#2977 把视频来源里扫到的纯音频目录登记成音乐来源；本稿定这些
来源从登记到移除的全过程。同一 PR 修 BUG-4128（同一文件在曲库里两行）。

## 数据（schema v145，Drift / fushi_core）

- `media_sources.auto_owner_source_id`：登记它的视频来源；NULL = 用户手动添加。外键 setNull 只是兜底。
- `music_auto_source_dismissals(owner_source_id, root_path)`：用户单独删掉的自动来源，不再登记回来。
  owner 删除时 cascade。备份规则 rowLevel（随 media_sources）。
- 不含视频的导出：先把 owner 是被裁视频来源的音乐来源 `auto_owner_source_id` 置 NULL、删掉挂在这些
  视频来源上的「不再登记」，再删视频来源。恢复后这些是普通手动音乐来源（音乐库本身不随视频类别裁剪）。

Rust 不持有这份状态（是来源元数据，与 media_sources 同层），不新增 FFI。

## 登记与对账（`MusicAudioIntake.adoptVideoSourceAudio`，串行队列）

- 规划：别的音乐来源（手动、别的视频来源登记的）算覆盖；本视频来源登记过的不算；「不再登记」按递归来源算覆盖。
- 规划出、还没登记的根：登记并记 owner。已登记但「含子文件夹」变了：改了重扫。
- 对账撤销只在本地视频来源**扫描完整成功**（没有部分失败）时做，且不论这次有没有扫到纯音频
  （最后一个音频目录被删时正是要撤的时候）。只凭正面证据（`ownedMusicRootsToRetire`）：
  不在视频根下、目录不在了、目录里直接有视频、递归来源的子树里有视频、已被别的音乐来源覆盖。
  「这次规划里没有它」不算证据（列目录不全、外接盘掉线会误删）。
- 「导入文件夹（仅此一次）」的视频临时行：规划出的根改为「仅此一次」导入音乐库，不留常驻来源。
- 存量迁移（旧版「无画面视频」行）只交来几个文件，不对账。

## 移除（`removeSourceLibrary`，界面与 AI 路由共用）

- 删视频来源：先撤它自动登记的音乐来源（`retireMusicSources`），再删自己。不写「不再登记」。
- 删音乐来源：名下曲目仍被另一个本地音乐来源覆盖的改挂过去，其余软删（`releaseMusicTracksOfSource`）。
  用户直接删一个自动来源时记「不再登记」。
- 用户手动添加与自动来源同根的目录：自动来源转为手动（两份「添加本地文件夹」共用
  `claimLocalSourceRootAsManual` 与 `sameLocalSourceRoot`），并解除所有视频来源对这个目录的「不再登记」。

## 路径变化 / 数据根迁移

来源根没有改路径的入口；「路径变化」是视频根下的音频目录被移动或删除，由对账处理。
`DataRootMigrator` 不改写 `media_sources.root_path`（既定契约）；owner 是 id，不受影响。

## iOS

自动来源不带书签。`SourceFolderAccess` 激活一个没有书签、有 owner 的来源时借 owner 视频来源的
安全作用域（根恒在 owner 根之下），不单独记持有；释放跟着 owner 走。判据不写 `Platform.isIOS`。

## 界面（`MediaSourcesView`，音乐 / 视频来源页共用）

- 自动来源行多一行「由视频来源「X」自动添加」；「⋯」菜单加「保留为我的来源」（转为手动）。
- 删视频来源的确认框（`FushiAlertDialog.adaptive`）：「将一并移除这个来源自动添加的 N 个音乐文件夹（M 首）」。
- i18n：`media_source_auto_added_from`、`media_source_keep_as_own`、`media_source_remove_auto_music_sources`。

## 不在范围

- 无头服务端（fushi_server）的纯音频仍没有去处（服务端无音乐库）。
- 网络视频来源里的纯音频（音乐来源只支持本地目录）。
