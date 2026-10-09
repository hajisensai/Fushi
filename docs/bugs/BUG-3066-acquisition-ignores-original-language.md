## BUG-3066 · AI video download picks dubbed or hardsubbed releases when original language was requested
- **报告**：2026-10-08（用户：「一口气下载全部哆啦A梦剧场版」，字幕语言选「原语言」）。实测错选：《のび太の南海大冒険》1998 → `[TWiLiGHT_TWiNKLE] … (Disney XD Asia English Dub Restoration)`（英配）；《のび太の恐竜》1980 → `[BYG-RAWS]…[国语中字]`（国语配音 + 烧录中字）；《海底鬼岩城》→ `[YYQ字幕组]…[简日内嵌]`（烧录字幕）。
- **真实性**：✅ 真 bug。根因：用户的语言意图只流到了提交端，从没进选版本这一层。
  - `packages/fushi_engine/lib/media/video/acquisition/video_acquisition_reducer.dart:2414`（修前）`kVideoAcquisitionSubtitleOriginal` 只在 `_submitFranchise` 里换算成字幕语言码交给下载管线挂外挂字幕；`planFranchiseEntry`（`:2284`）与单部 `_onResourcesLoaded`（`:1445`）的候选清洗、`filterResourceGroups` / `rankResourceGroups` 都不看 `state.slots.subtitleLanguage`。
  - `packages/fushi_engine/lib/media/torrent/anime_release_descriptor.dart:3` 的描述符刻意不解析音轨语言，选版本层也没有别的地方认「配音 / 硬字幕」——于是做种多的国语 / 英配 / 内嵌版照样排第一。
- **[x] ① 已修复** — `2bd1f28e16`。新增 `packages/fushi_engine/lib/media/torrent/video_release_language.dart`，只认标题**明写**的事实（不写 = 放行）：
  - `releaseIsDubOnly`：`English Dub` / `Dubbed` / `国语` / `國語` / `粤语` / `中配` / `台配` / `普通话`…，且没写双音轨（`Dual-Audio` / `MULTi` / `国日双语` / `双音轨`）；`简日双语`（双语字幕）不算音轨。
  - `releaseHasBurnedInSubtitles`：`内嵌` / `內嵌` / `硬字幕` / `HardSub`；`中字` 没同写 `外挂` / `内封` 时也算。
  reducer 新增 `wantsOriginalLanguageRelease(state)`（字幕选「原语言」或正好选了作品语言），单部与整套两条路径都把它传给 `cleanResourceCandidates(originalLanguageOnly:)`，命中的发布直接丢弃（留着只会因做种多被选中）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/acquisition/video_acquisition_doraemon_franchise_picks_test.dart`「原语言」组 + reducer 端到端（1998 英配被换成 `[Ommex] … (1998) [1080p]`、单部路径国语中字被清掉）。变异实测：清洗层不看 `originalLanguageOnly`、整套 / 单部 reducer 传 `false`，各自变红。
- **备注**：字幕选了别的具体语言（如 `zh`）或「不要字幕」时不按语言丢弃——用户可能就要中文硬字幕版，这里不替他做主。
- **补修（PR #2008 审查，2026-10-09）**：首版判定不看作品原语言，误杀中文作品。
  - 根因：`packages/fushi_engine/lib/media/torrent/video_release_language.dart` 的 `releaseIsDubOnly` / `releaseHasBurnedInSubtitles` 只看标题——国产片 / 国漫（作品语言 `zh`）、粤语港片（`yue` / `zh-HK` / TMDB `cn`）选「原语言」字幕后，标 `国语` / `普通话` / `粤语` 的原音轨被当成配音、`中字` 的同语言字幕被当成外语硬字幕，几乎全部候选被丢 → noCandidates。
  - **[x] ① 修复**：两函数加 `workLanguage`。作品自己语言的音轨标记不算配音（普通话片：国语 / 普通话 / 国配 / 中配 / 台配；粤语片：粤语 / 粤配；归一化后只剩 `zh`、分不出国粤时两类都放行），至少一个配音标记是别的语言才算只有配音；中文作品上明写中文字幕（中字 / 简中 / 繁中 / 简日…）的硬字幕是同语言字幕不判不合格，没写语言的 `内嵌` / `HardSub` 照旧不合格。`cleanResourceCandidates(workLanguage:)` 透传；单部 `_onResourcesLoaded` 传 `state.contentLanguage`，整套 `planFranchiseEntry` 优先用这一部详情解析出的语言（`resolveVideoWorkContentLanguage(event.work, …)`），解析不出再用会话语言。不传语言（判不出）时保持原「外语作品」判定，日语作品结果不变。
  - 同批修 BUG-3065 身份判据两处误判（`packages/fushi_engine/lib/media/torrent/video_resource_work_match.dart`）：`_isRemake` 的 CJK 插入判据不再认标题**后面**的「新」（`[大雄的恐龙][新版]`），且「新」前紧挨 `最` / `更` / `重` / `全` / `崭`… 时是复合词不是重制（`【最新】哆啦A梦`）；`_isOtherSequel` 把补零写法（`Title 01`）与带集号上下文（` - 12` / `[12]` / `EP12` / `第12话` / `12v2` / `12 END`）的数字认作集号、按没写续作序号算。
  - **[x] ② 测试**：`fushi/test/media/video/acquisition/video_acquisition_original_language_work_test.dart`（中文 / 粤语作品正负样本、日语作品不变、整套与单部 reducer 端到端、「新版」/「最新」/集号不误判、真重制与真续作照判）。
