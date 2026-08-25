## BUG-1861 · 获取的字幕能应用上却不出现在字幕轨列表里
- **报告**：2026-08-25（用户：「获取的字幕，能被应用上，但不会出现在列表里」+ 手机端「视频设置 → 字幕轨」截图：列表里只有「获取字幕（Jimaku）」「导入字幕文件…」「关闭字幕」「副字幕」四行固定项，一条可选字幕源都没有）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart` 的 `_registerImportedSubtitleSource`（修复前：`if (_isRemote) return;` + `if (videoPath == null || _subtitleMenuSourcesPath != videoPath) return;`）与同文件 `_buildSubtitleTrackRows` 的远端分支。

  BUG-1329 已经把「下载/导入完当场并入字幕轨列表」接上了，但那条并入路径把**「新档要不要进列表」挂在了「枚举缓存对当前视频是否有效」这个与它无关的前置条件上**，于是四种情况下新档被**静默丢弃**：

  1. **枚举在途**。字幕轨枚举（`_ensureSubtitleMenuSourcesLoaded` → `listAllSubtitleSources`，对整个容器跑 `ffmpeg -i`，超时预算按文件体积放大）由「进入字幕分类」事件驱动，是异步的。用户一进「字幕」分类就点「获取字幕（Jimaku）」——搜索 + 下载要几秒，而大容器探测同样要几秒到数十秒。下载回来时缓存 key 还没写 → 登记静默 return；随后枚举完成，用 `_rebuild` **整体覆盖** `_subtitleMenuSources`，而它带上「当前持久化字幕」用的是**枚举启动时抓的 `_currentSubtitleSource` 快照**（`_subtitleSourcesForMenu` 的入参在 `await` 之前读），刚下载的档案也进不了 `includeCurrentPersistedSubtitleForMenu`。两头都漏。
  2. **枚举失败**。`enumerated == null`（ffmpeg 缺失 / 超时 / 路径不可枚举）时按设计不写缓存 key（留给下次重试），此后**每一次**登记都静默 return。
  3. **换集后没再进过字幕分类**。缓存 key 还是上一集的路径。
  4. **远端模式整个跳过**（`if (_isRemote) return;`）。而远端字幕轨行只覆盖三类：YouTube 轨（`_youtubeCaptionTracks`）、host sidecar（`_remoteSubtitlePath`）、host 内封轨（`_remoteEmbeddedSubtitleTracks`）。远端 Jimaku 下载走 `_applyRemoteSubtitle` 只改内存里的 `_currentSubtitleSource`，**列表里根本没有一行能承载本机下载的档案** —— 字幕在画面上生效了，列表里既看不到它、也切不回它（只有退出重进后，`_loadRemoteEpisode` 的持久化重放把它挂到 `_remoteSubtitlePath` 上，才会以「host 字幕」行出现）。

  用户截图那一屏在两种表面下都成立：生肉视频（正因为没字幕才要去 Jimaku 取）枚举结果恒空，列表本来就只有固定项；下载完之后它**仍然**是空的。

- **[x] ① 已修复** — 把「枚举结果」与「本会话落盘的档案」拆成两份独立真相，渲染时合并：
  - 新增 `_importedSubtitleSources`（视频页字段，换视频源 / 远端换集时清空），`_registerImportedSubtitleSource` **去掉全部前置门**（不看 `_isRemote`、不看 `_currentVideoPath`、不看缓存 key），只按 `isImportedExternalSubtitlePath` 收外挂档案路径、按 `sameExternalSubtitlePathForMenu` 去重。「这个档案就在盘上、刚被应用」是不依赖枚举的既成事实。
  - 新纯函数 `mergeImportedSubtitleSourcesForMenu`（`video_subtitle_source.dart`）在渲染时合并两份列表，导入档排最前。写进独立列表而不是枚举缓存，后到的枚举结果整体覆盖缓存时也冲不掉它。
  - 主字幕轨行与副字幕轨行（BUG-900 起共用同一份可用列表）都改读合并后的 `_menuSubtitleSources`。
  - 远端分支新增「本机导入档」行（点击走 `_applyRemoteSubtitle`），与 host sidecar 行按路径去重；远端 Jimaku 下载 / 远端手动导入两条落盘路径都补上登记。
  提交：见本分支 `fix(video): ...` commit。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_subtitle_imported_list_guard_test.dart`：`mergeImportedSubtitleSourcesForMenu` / `sameSubtitleFilePath` 的行为单测（含「枚举结果为空时导入档仍可见」这一用户报的那一屏），加调用点静态守卫（登记函数体内不得再出现三个前置门符号中的任何一个；两处渲染都读合并列表且不得再裸遍历枚举结果；远端分支有导入档行；远端两条落盘路径都登记；两条换源路径都清空）。已做变异实测：加回 `if (_isRemote) return;` → 「登记新档没有任何前置门」当场红；主字幕行退回 `_subtitleMenuSources` → 「本地字幕轨行与副字幕行都读合并后的列表」当场红；还原后源文件 sha256 回到基线。同批修正 BUG-1329 守卫里那条已被本次修复取代的断言（它锁的正是被删掉的缓存 key 门）。
- **备注**：media_kit 跑不了 headless、ffmpeg 枚举也不能在单测里真跑，字幕轨行的渲染进不了 widget 测试，故列表行契约只能锁到调用点/源码层；**未做真机复测**（未在手机上重跑一遍 Jimaku 下载 → 看列表出现新行）。
