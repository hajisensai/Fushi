# 音乐库收网络来源的音频（反馈 QAondMh4M5）

叠在 `claude/audio-files-to-music-library`（#2977）之上：纯音频不再进视频库后，网络视频来源里的音频两个库都进不了；本设计让 SFTP / WebDAV / AList 上的音频进音乐库、流式播放。

## 归属

- 音乐来源可直接按 SFTP / WebDAV / AList 添加（FTP 读不了区间，不给）。
- 网络视频来源扫到的纯音频：按 `planMusicRootsForVideoSourceAudio`（`p.url` 语义）登记**同一台服务器**上的常驻网络音乐来源，连接参数照抄、凭据复制到新来源名下。同服务器（`sameRemoteServer`：host / port / baseUrl / username）已有音乐来源覆盖的目录不再登记，避免两个来源重叠时同一首曲目在两次扫描之间来回换 `sourceId`。
- 条目路径与视频行同一命名空间：SFTP 为 `sftp://host:port/远端路径` 稳定地址，WebDAV / AList 为 http(s) 地址。

## 扫描（Rust 胖核心）

- `native/fushi_music/src/remote.rs`：远程扫描游标。Dart 交列表（路径 / mtime / size + CUE 原始字节），Rust 按需回 `NEED(path, ranges)`，Dart 用 `SourceByteReader.readRange` 取字节再喂回。标签解析用和本地同一套 `read_meta_from<R: Read+Seek>`，曲目记录走同一个 `plain_record` / `cue_track_record`，所以 uid 规则和本地一致。
- CUE 以原始字节进 Rust（SJIS 等编码由 Rust 判），FLAC 内嵌 CUESHEET 照样拆轨。
- 已知且 mtime + size 都没变的文件跳过取字节；mtime 未知时一律重新解析。etag 没有落库列，不参与比较。
- 内嵌封面以 COVER 记录（batch 格式 v2）交回，先写进 `music_covers/remote-<sha1>.<ext>` 再写曲目行。
- 取字节失败会中止整次扫描、不软删；单个文件超过 16 MiB 仍未解析完时退回只按扩展名入库。

## 播放

- `MusicPlayItem.sourceId` 不为空且路径是网络地址时，起播那一刻按来源的 **transport** 取流（`music_remote_media.dart`）：WebDAV 用条目地址加 Basic 头（只在来源根内发），AList 走 `fs/get` 换临期直链，SFTP 走回环中继。解析器缓存在进程级单例里（交叉淡入的两个 mpv 后端共用），来源删除时 `forgetSource`。
- 和插件曲目共用「先停旧曲再取、下一首异步补排、403/410 原位重取」。

## 不按本地文件工作的功能

网络来源曲目跳过以下功能：响度测量、AcoustID 声纹、同目录 sidecar / 内嵌歌词、「导出 TTML 到文件旁边」、标签回写（界面会提示「网络来源上的文件不能回写标签」）。判据只有一个，即 `isMusicRemoteSourceTrack`，歌词侧用 `MusicLyricsTrackRef.isLocalFile`。

## 存量迁移

旧版留在视频库里、属于网络视频来源的纯音频行，会走上面同一套登记流程。已被覆盖的会主动重扫覆盖它的来源。只有当路径**原样**（不 canonicalize）等于某首在库曲目的路径时，才删视频行；删之前把观看记录写成 `music_play_events`。连不上就保留这些行，下次启动再试。和视频同目录的音频（外挂音轨）留在视频库。

## 不做 / 未覆盖

- URL 导入（`/api/admin/url-import` 和视频导入对话框）不分流到音乐库。一条裸 URL 没有来源，也就没有 `sourceId`、目录列表和 mtime / size，曲目对账、软删、uid 规则都无从套用。音频直链仍按原样进视频库。
- 媒体服务器（Jellyfin / Emby / Plex）的视频库条目不分流；音乐走既有的服务器曲库。
- fushi_server 没有网络来源，也没有音乐库，本项不适用。
- ASR：网络曲目的转写需要按区间读字节，应复用 `SourceByteReader`，本 PR 未接。
