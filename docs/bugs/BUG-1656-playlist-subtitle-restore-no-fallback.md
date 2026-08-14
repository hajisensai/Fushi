## BUG-1656 · 合集里下载的字幕退出再进就没了：恢复链只走一支、零兜底
- **报告**：2026-08-15（用户实测，原话「下载的字幕退出进来以后又没了」）
- **真实性**：✅ 真 bug — 根因 `fushi/lib/src/pages/implementations/video_fushi_page.dart`
  `_loadSingle` 的字幕恢复 else-if 链（兜底三层全挂在链尾，前一支失败即空手收场）
- **[x] ① 已修复** — 兜底链改为独立判据 + 放宽 sidecar 门 + 释放无效外挂路径
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_subtitle_restore_fallback_guard_test.dart`（4 例，变异实测）
- **备注**：与 [BUG-1652] / [BUG-1653] / [BUG-1654] 同一批用户实测反馈。
  另见下方「同批查出、本轮未修」两条。

### 实证（用户真实库，只读查询）

数据根 `D:\APP\HIBIKI_date`：

- 合集 77「Re：从零开始的异世界生活 第四季 丧失篇 (2026)」，`collection_type='playlist'`，
  三个成员各自是独立 `video_books` 行（S04E10/E11/E12）。
- 只有 **S04E12** 有 `subtitle_source`，指向 `documents\video_subtitles\` 下当晚 00:33 下载的
  ABEMA `.srt`；**该文件在磁盘上存在，按 SrtParser 规则可解析出 406 条 cue**。
- 但该行 **`audio_cues` 条数 = 0**。
- 41 行带外挂字幕的 `subtitle_source` 全部在磁盘上存在（排除「文件被清掉」）。

⇒ 「写错行」「文件没了」「双语 `.ja-en.ass` 解析不了」三个最像的假设**全部被证伪**。

### 根因

合集里的每一集**只落字幕源指针、不落 cue**（`_selectSubtitleSource` 的 `_episodes.isEmpty`
分支，BUG-081 有意为之）。于是 `_loadSingle` 的恢复链成了单点故障：

1. `externalSub` 在一开始就被赋成持久化路径（非空）。
2. 分支是 **else-if 链**：只要路径存在且扩展名对（`rehydratePath != null`），就只走「重解析磁盘
   档案」这一支；解析没拿到 cue 时按注释「保留 DB 缓存 cues」——**而合集这一集的缓存恒为空**。
3. 后面的「持久化源精确恢复」挂在同一条链的 `else if (cues.isEmpty)` 上，**永远轮不到**。
4. 即便轮到，sidecar 兜底的门是 `cues.isEmpty && externalSub == null`，被第 1 步那个非空值挡掉。
5. 最后 `_applyLoad` 把非空 `externalSubtitlePath` 传给 controller，而
   `VideoPlayerController.load` 的「无外挂 + 无 cue 才后台抽内封文本轨」判据同样被它挡掉。

⇒ **一次解析就是全部：失败 = 零字幕 + 零兜底 + 零提示**（恢复路径全程只有 `debugPrint`）。
单视频有 `loadCues` 这层 DB cue 安全网，合集没有——这就是「单视频没事、合集必现」的不对称根源，
也是用户「只能重新下载一次」的直接原因。

原注释里「播放列表换集走 `_restorePersistedSubtitle` 已是重解析，故只需修单视频路径」的前提，
在统一合集 Phase 3（换集改为 `pushReplacement` 重建、每集都走 `_loadSingle`）之后已经失效。

### 修复

把兜底从 else-if 链里拆出来，改成「只要还没拿到 cue 就逐级往下试」：

- 独立判据 `if (!subtitleExplicitlyOff && cues.isEmpty)`，上面任何一支「试过但没成功」都能落进来；
- sidecar 门只看 `cues.isEmpty`（去掉 `externalSub == null`）——「有持久化源但它恢复不出内容」时
  也该试 sidecar；
- 最终仍无 cue 且源不是内嵌轨 → 释放 `externalSub`，让 controller 的内封轨自动加载兜底。
  **只影响本次加载，不回写 DB**，用户选过的源仍在库里，下次仍会先试它。
- TODO-818（用户显式关闭字幕）仍然短路整条兜底，判据自身也带 `!subtitleExplicitlyOff` 双保险。

### 同批查出、本轮未修（各自待立项）

1. **内封轨自动加载不落库**：`_handleEmbeddedSubtitleAutoLoad` 只 `setState(_currentSubtitleSource)`
   从不写 DB；而 `_selectSubtitleSource` 在解析失败时早退，早退发生在 `controller.setCues` 之前，
   屏幕上原有的（自动加载的内封）字幕不会被清掉。⇒「下载 → 应用 → 屏幕上确实有字幕」完全可能是
   「这次下载其实没成功，你看到的是内封轨」，退出重进自然「我下的字幕没了」。用户当晚 7 分钟内连下
   三个不同来源的字幕（00:26/00:31/00:33），符合这种反复试探。
2. **跨集字幕继承是死代码**：`crossEpisode: true` 在 lib 里一次都没被传过（两个调用点都是 false），
   `pickEpisodeSubtitleSource` / `shouldReusePersistedSubtitleAcrossEpisode` 在生产路径上不可达。
   合集「继续观看」打开的下一集 `subtitle_source` 为 NULL，⇒ 每集都得手动下一次字幕。
   （`docs/bugs/BUG-1288` 末尾把「字幕记录也无了得重新选」列为未定根因、待单独立项；本次调查补上了
   它缺的那一环——不是没写，是读回时没有兜底。）
