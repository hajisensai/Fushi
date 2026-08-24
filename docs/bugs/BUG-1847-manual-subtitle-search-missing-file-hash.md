## BUG-1847 · 播放页手动检索字幕不带 OSDb 文件哈希，精确匹配分支永远走不到
- **报告**：2026-08-25（代码审计，非用户报告）
- **真实性**：✅ 真 bug — 根因 `fushi/lib/src/pages/implementations/jimaku_subtitle_dialog.dart`
  的 `_fetchCandidates` 构造 `VideoSubtitleSearchRequest` 时不传 `fingerprint`
- **[x] ① 已修复** — 见本轮提交
- **[x] ② 已加自动化测试** — `fushi/test/pages/jimaku_search_identity_test.dart` 的
  「BUG-1847 手动检索带 OSDb 文件哈希」组（2 例）
- **备注**：与 [BUG-1842] / [BUG-1843] / [BUG-1844] 同一个对话框。

### 根因

同一个 `VideoSubtitleRegistry`，两个入口能力不对等：

| 入口 | 传 `LocalVideoFingerprint` |
|---|---|
| 下载流水线 `video_download_pipeline_service.dart:2135` | ✅ |
| 播放页手动「找字幕」对话框 | ❌ |

于是 `open_subtitles_client.dart:553` 的 `moviehash` 精确匹配分支在手动路径上**结构上永远
走不到**——用户在播放器里手动找字幕，永远只能按标题模糊搜，拿到的字幕经常对不上这个压制版本
（时轴错位），而按文件哈希搜出来的就是该版本的字幕。

### 修复

对话框新增 `videoPath` 参数（播放页传 `_isRemote ? null : _currentVideoPath`），`_fetchCandidates`
在发请求前算一次指纹：文件体积 + `computeOpenSubtitlesMovieHash` + basename。

无本地文件（远端流）/ 文件不存在 → 直接 null，不报错；读失败降级为「没有指纹」而不是让整次搜索
失败——指纹只是让匹配更准的加分项。**但必须留 `ErrorLogService.logDiagnostic`**：pr955 那版
`_fingerprint()` 写的是 `} on Object { return null; }`（空 catch 无诊断），与同一个 PR 里
`_buildJimakuSeed` 的写法自相矛盾；空 catch 会让「指纹永远算不出来」这种故障彻底隐身，用户只会
觉得「OpenSubtitles 匹配得不准」，没有任何线索指向真实原因。

### 测试上的坑

指纹是**真实文件 I/O**。`testWidgets` 全程跑在 fake-async 里，`dart:io` 的 future 永远不会
完成，直接 `pumpAndSettle` 会挂到超时（表现为「pumpAndSettle timed out」，很容易被误读成 UI
死循环）。测试里改用「假时钟 `pump` 与 `runAsync` 真事件循环交替推进」的 helper。

### 变异实测

从请求里去掉 `fingerprint: fingerprint` → 「本地视频：请求带上文件指纹」转红；还原后文件
sha256 与变异前一致。
