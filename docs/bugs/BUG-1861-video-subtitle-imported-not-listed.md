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
  - **远端「副字幕」那一半是同一个洞**（审查发现）：`_pickAndImportRemoteSecondarySubtitle` 同样把档案拷进 `<dataRoot>/documents/video_subtitles/` 再应用，而 `_buildSecondarySubtitleRows` 的远端分支只有「关闭 / 打开文件 / host sidecar / host 内封轨」四类行——导入成功、副字幕生效、列表里找不到它也切不回来。已补上对称的登记 + 行渲染（与主字幕完全同形，同样与 host sidecar 按路径去重）。
  - **登记入口不按扩展名门控**：新增纯函数 `isExternalSubtitleFilePathForMenu`（只滤掉 `embedded:<n>` 源指针 / `off:` 哨兵 / 空串）。Jimaku / OpenSubtitles 的 `fileName` 只经 `safeSubtitleFileName` 防路径逃逸、不做白名单，`.sup` / `.smi` / `.ttml` 一样会落盘；拿扩展名当登记门等于「下完之后列表里连名字都看不到」，与本函数两个调用点「坏档也该列出来、不按应用成功门控」的既有约定自相矛盾。原 `isImportedExternalSubtitlePath` **保留不动**——它判的是「一条**持久化值**能不能按路径直接重放」，扩展名是它的必要条件，消费方在 `shouldReusePersistedSubtitleAcrossEpisode` 与视频页换集恢复链路上（`video_subtitle_source.dart` 两处 + `video_fushi_page.dart` 一处），两件事不合并。
  - `_registerImportedSubtitleSource` 首行判 `mounted`：四个调用点全在 FilePicker / 网络下载 / `File.copy` 的 await 之后，而 `_rebuild` 是裸 `setState`。去掉 `if (_isRemote) return;` 之后远端两条导入路径首次成为可达的 setState 路径，用户在拷贝期间退出视频页就会 setState-after-dispose。
  提交：见本分支 `fix(video): ...` commit。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_subtitle_imported_list_guard_test.dart`：`mergeImportedSubtitleSourcesForMenu` / `sameSubtitleFilePath` 的行为单测（含「枚举结果为空时导入档仍可见」这一用户报的那一屏），加调用点静态守卫（登记函数体内不得再出现三个前置门符号中的任何一个；两处渲染都读合并列表且不得再裸遍历枚举结果；远端分支有导入档行；远端两条落盘路径都登记；两条换源路径都清空）。已做变异实测：加回 `if (_isRemote) return;` → 「登记新档没有任何前置门」当场红；主字幕行退回 `_subtitleMenuSources` → 「本地字幕轨行与副字幕行都读合并后的列表」当场红；还原后源文件 sha256 回到基线。同批修正 BUG-1329 守卫里那条已被本次修复取代的断言（它锁的正是被删掉的缓存 key 门）。
- **备注**：media_kit 跑不了 headless、ffmpeg 枚举也不能在单测里真跑，字幕轨行的渲染进不了 widget 测试，故列表行契约只能锁到调用点/源码层；**未做真机复测**（未在手机上重跑一遍 Jimaku 下载 → 看列表出现新行）。
- **审查发现的守卫空转（已修）**：`video_subtitle_imported_list_guard_test.dart` 里「换视频源时导入档一并清空」原来用 `'_importedSubtitleSources = const <SubtitleSource>[]'` 的出现次数 `>= 2` 断两处清空，而**字段声明本身**（`List<SubtitleSource> _importedSubtitleSources = const <SubtitleSource>[];`）也含这个子串、占掉一个名额——把本地那处清空整段删掉，全组照样全绿（变异实测确认）。现改为「总数减去声明数 == 2」+ 本地 `clipExportSourceChanged` 块的 region 断言（含窗口自校验），远端那条 region 断言保留。
- **相邻缺口，本次未修**：`_remoteSubtitlePath` 全仓只有赋值（`video_fushi_page.dart` 三处）、没有任何一处置回 null。远端换集后若新集既无持久化字幕选择也无 `subtitleUrl`，「host 字幕」行仍挂着上一集的档案路径。与本 bug 同形（作用域没跟着视频源走），但属既有缺陷、涉及远端恢复链路的另一条数据流，应单独开条修，不夹带进本次改动。
