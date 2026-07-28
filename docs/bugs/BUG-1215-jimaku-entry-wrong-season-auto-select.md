## BUG-1215 · Jimaku 条目自动选中不校验季号，S1 条目被配给 S2 包
- **报告**：2026-07-28（用户：PR#515 审查建议 b / PR#530 施工方自报未解决的另一半）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/anime_download_dialog.dart:590`
  （改前 `_resolveJimakuEntryFor` 的 `return entries.first;`）——自动选中的判据只有
  「Jimaku 服务端返回的第一条」，既不打相似度分也不核季号。
  BUG-1206（PR#530）把配对推迟到种子 add 之后、按包内真实视频文件名反查，
  落位层 `matchJimakuFilesToVideoNames`（`anime_download_matching.dart:377`）
  要求集号**严格相等**。但当自动选中的条目本身就是 S1（文件编号 1-12）、
  而包是 S2 的 01-12 时，集号照样相等 —— 落位层无从分辨，字幕错季且看起来完全正确。
  这一支在 `_subtitleEpisodesUnverified` 的注释里早已写明（「或自动选中的首条根本是
  别的季」），只是当时没有检测手段，只能整类降级成 `~`。
- **[x] ① 已修复** — 条目选择层加季号校验，收敛成纯函数
  `resolveJimakuEntry` / `jimakuEntrySeasonConflicts` / `jimakuEntrySeason`
  （`hibiki/lib/src/media/torrent/anime_download_matching.dart` 尾部）：
  1. 用户手选过的条目**一律放行**（用户可能就是要另一季的字幕，如合集版编号不同）；
  2. 条目挂的 `anilist_id` 命中所选番 → 放行（AniList 按季拆条目，id 命中即权威），
     于是校验实际只作用在文本回退搜出来的条目上 —— 错季真正的产地；
  3. 种子标题解析不出季号（`NyaaTorrent.season == null`）→ 不校验，维持现状自动选，
     不因信息缺失关掉一个本来能用的功能；
  4. 其余情况按 `jimakuEntrySeason(entry.name)` 比对，条目名不写季号按**第一季**算
     （Jimaku 的 S1 条目名就是光秃秃的作品名，这正是本 bug 的形状）。
  自动选中改成「取第一条季号不冲突的」，全都冲突则不选，并在字幕列表上方用与
  「集号未核对」同一排版的提示行（`_buildSubsHintRow` +
  `anime_download_subs_season_mismatch`）说明原因，不静默。选中种子这一刻
  （`_selectTorrent`）才知道包的季号，故在那里复核选番阶段的自动选中结果；
  `~` 徽标（`_subtitleEpisodesUnverified`）同步补上季号冲突这一支。
  提交：见 PR 分支 `fix/jimaku-season-guard`。
- **[x] ② 已加自动化测试** —
  `hibiki/test/torrent/anime_download_matching_test.dart`（group「条目自动选中的季号校验」，
  10 例：S1×S2 不自动选 / 候选里有对得上的季就选它 / 两边都无季号照常自动选 /
  种子无季号不凭空拦 / 手选不被拦（带对照组）/ 手选已失效则回退且仍受校验 /
  anilist_id 命中放行 + 挂错 id 不放行 / 真实条目名季号解析）；
  `hibiki/test/pages/anime_download_dialog_discovery_ux_test.dart`（2 例 widget 行为：
  S2 包 + S1 条目 → 不拉文件、不配字幕、显示原因提示行、候选仍可手选且手选后照常加载；
  两边都无季号 → 仍自动选首条）。
  变异实测：把 `jimakuEntrySeasonConflicts` 退回恒 false，上述断言转红 6 条。
- **备注**：本轮只动条目选择层，PR#530 的「按包内真实文件名反查」链路未改。
  已知遗留：选番阶段（还没选种）无从知道包的季号，此时仍自动选首条；
  一旦选中种子即复核。合集/跨季包（`S01+S02`）不在本轮判据内，
  种子标题解析出单一季号时才校验。
