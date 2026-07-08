## BUG-616 · m3u8 播放列表来源库重复扫描不去重、封面缺失（判重键错用首集易变路径）

- **报告**：2026-07-08（用户：D:/video/播放列表合集 文件夹「还是没封面，还是没和我已经导入的去重」，TODO-1237）
- **真实性**：✅ 真 bug（核对用户实机 DB `D:/APP/HIBIKI_date/support/hibiki.db`）。根因两处：
  - **去重**：`hibiki/lib/src/media/source/media_source_scanner.dart`（原 `_importPlaylists` 第 627 行）
    `if (!existingPaths.add(normalizeVideoPath(entries.first.path)))` —— 播放列表判重键用的是
    **首集解析后的物理路径**（易变），不是 m3u8 文件本身的稳定身份。用户先经导入对话框导入过
    一份（首集 `D:/video/Bocchi the Rock!/.../S01E01.mp4`，有封面），后又把该文件夹加为**视频来源库**扫描；
    扫描发生在 m3u8 还是**相对反斜杠路径**（如 `Season 01` + 反斜杠 + `X.mp4`，缺剧名一级）时，首集解析成
    不存在的 `D:/video/播放列表合集/Season 01/X.mp4`，与对话框那份的首集路径不同 → 判重不命中 →
    `uniqueVideoBookUid` 加后缀建 `... 播放列表 (2)` 重复条目。
  - **封面**：同一次扫描里首集（及后续 5 集）都解析到不存在的 `播放列表合集/Season 01/...`
    → `extractPlaylistCover` 全部 `File.existsSync()==false` → 无封面（`cover_path=NULL`）。
    绝对路径本身在 Windows 能解析（实测 21/22 首集 `firstExists=true`）；旧 `parseM3u8` 靠
    `p.join(baseDir, entry)` 对绝对第二段的丢弃语义“碰巧”生效，但对 UNC（双反斜杠 host 前缀）会拼成
    伪盘符路径、且在非 Windows 平台把盘符绝对路径当相对路径 —— 解析契约不显式、不稳。
  - **DB 佐证**：42 条 video_books 里 17 条 `src=None`（对话框，有封面、正确路径）+ 22 条 `src=3`
    （来源库扫描，`cover_path=NULL`、`videoPath=D:/video/播放列表合集/Season 01/...`、bookUid 带 ` (2)`）。
- **[x] ① 已修复** — 改法（根因，非补丁）：
  - 新增纯函数 `String resolveM3uEntryPath(String entryRaw, String playlistDir, {p.Context? context})`
    （`hibiki/lib/src/media/video/m3u8_playlist.dart`）：**按字符串形态**判断绝对性（Windows 盘符根 /
    UNC / POSIX 根，不依赖宿主 `p.isAbsolute`），绝对路径原样 normalize、不拼 playlistDir；相对路径
    两种分隔符归一后相对 m3u8 目录解析。`parseM3u8` 改走此 helper：UNC 不再被拼成盘符路径，跨平台 /
    跨设备同步下盘符绝对路径仍判定为绝对。
  - `_importPlaylists` 判重键从「首集物理路径」改为**播放列表稳定身份** `playlistBookUid(item.playlistPath)`
    （取 m3u8 文件名派生，与 bookUid 同源）：身份已存在则 `continue` 跳过（幂等重扫），绝不再加后缀建
    `X (2)`。编辑 manifest（相对→绝对）改变首集路径时不再产生重复。单视频判重仍走物理路径（`_importVideos` 不变）。
  - 用户侧收尾：删掉已有的 `src=3`、无封面的 `... (2)` 重复条目后重扫；对话框那份（有封面）会被身份判重
    跳过、保留；只在库里的剧则以绝对 m3u8 全新导入、抽到封面（磁盘上文件真存在的才有）。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/media/video/m3u8_playlist_test.dart` `group('resolveM3uEntryPath (TODO-1237)')`：
    windows 绝对反斜杠 / 正斜杠、相对反斜杠 / 正斜杠、UNC 保留、posix 绝对 / 相对、posix 宿主下
    Windows 绝对仍判定绝对、空串、parseM3u8 路由绝对不拼 baseDir。
  - `hibiki/test/media/source/media_source_scanner_test.dart`：新增
    `re-scan after manifest episode paths change: identity dedup, no X (2)`（复现用户 bug：首集路径变、
    身份不变 → 仍去重、不产生 `(2)`）；更新 source guard 断言
    `final String bookUid = playlistBookUid(item.playlistPath);` + `existingKeys.contains(bookUid)`。
- **备注**：ffmpeg 抽封面本身 OK（实测对真存在的 mp4 抽出与旧封面逐字节一致 73769B）。「Kamiina Botan」那部首集
  `.ts` 文件在磁盘上真不存在（用户数据缺口，非解析 bug），任何解析都抽不到封面。
