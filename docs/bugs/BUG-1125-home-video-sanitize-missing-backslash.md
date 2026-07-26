## BUG-1125 · home-video-sanitize-missing-backslash
- **报告**：2026-07-26（全库命名统一审计 G1 发现，非用户报告）
- **真实性**：✅ 真 bug（根因 `hibiki/lib/src/pages/implementations/home_video_page.dart:1475`（修复前行号，`_downloadRemoteSubtitleForBook`）：字幕落点的手写清洗字符集 `[\/:*?"<>|]` 只写了 `\/`——raw 串里这是「被冗余转义的正斜杠」，字符类**不含反斜杠**；而同文件封面落点 `_cloudCoverDestination`（原 1454 行）用的是全集 `[\\/:*?"<>|]`）
- **[x] ① 已修复** — 全仓 Windows 文件名安全化收敛到共享 helper `hibiki/lib/src/utils/misc/safe_file_name.dart`（`safeWindowsFileName`，统一字符集 `[\\/:*?"<>|\x00-\x1f]`），字幕/封面/下载落点三处全部改走 helper，字符集不可能再抄漏（``eb6976f00``）
- **[x] ② 已加自动化测试** — `hibiki/test/utils/misc/safe_file_name_test.dart`（含 `\` 输入的行为回归）+ `hibiki/test/tools/safe_file_name_guard_test.dart`（源码扫描守卫：lib/ 下禁止再手写该字符类的任何排列变体）
- **备注**：同批收敛的其余手写副本（desktop_audio_clipper / custom_fonts / collections / profile_management / sync_asset_package / manga_storage / update_checker_download / video_screenshot_filename / hibiki_manga_ocr_host）对全部现实输入输出逐字节不变，见命名统一分支说明。

### 根因

远端/云视频下载建档时，三个落点各自手写了一份「Windows 非法文件名字符 → `_`」清洗：

- 封面：`_cloudCoverDestination` → `[\\/:*?"<>|]`（正确，`\\` 是反斜杠）
- 字幕：`_downloadRemoteSubtitleForBook` → `[\/:*?"<>|]`（**漏了反斜杠**——raw
  字符串里 `\/` 只是被冗余转义的 `/`，字符类里根本没有 `\`）
- 视频文件名：`_remoteDownloadDestination` → `[\\/:*?"<>|]`（正确）

于是当 `RemoteVideoInfo.id` 含 `\` 时（Windows host 侧由路径派生的 id 完全可能）：

- 封面得到 `cloud_a_b.cover.jpg`（`\` → `_`，落在 `remote_videos/` 平级）；
- 字幕的 `safeUid` 保留 `\`，`File(p.join(dir, '$safeUid.$ext'))` 在 Windows 上把
  `\` 当路径分隔符——字幕落进**不存在的子目录**（写入直接抛 `FileSystemException`，
  字幕静默丢失）或与封面不同的目录层级；POSIX 端则得到一个名字里带字面 `\` 的
  文件，与封面命名不再成对。

典型的「复制粘贴同一段正则时抄漏一个字符」——十份手写副本里只有这份错，
恰好说明手写副本本身就是缺陷温床。

### 修复

新建唯一真相源 `hibiki/lib/src/utils/misc/safe_file_name.dart`：

- `windowsUnsafeFileNameChars` = `[\\/:*?"<>|\x00-\x1f]`（Windows 保留字符 +
  控制字符，跨平台取并集）；
- `safeWindowsFileName(String)` 逐字符替换为 `_`（刻意不折叠、不 trim，由调用方
  按各自既有产物命名契约叠加，保证既有磁盘文件名对现实输入字节不变）。

`home_video_page.dart` 三处（封面/字幕/视频文件名）全部改走 helper；字幕落点
由此获得与封面一致的全字符集，`\` 输入两者同目录同配对。其余 8 处手写副本同批
收敛（输出对全部现实输入逐字节不变），源码守卫禁止回潮。
