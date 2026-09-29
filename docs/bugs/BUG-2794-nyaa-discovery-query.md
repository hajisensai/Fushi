## BUG-2794 · 发现页搜视频资源 Nyaa 常 0 条：查询词只用显式词且无按源状态
- **报告**：2026-09-30（用户：在浏览/发现里直接搜视频资源，有时只有一个源有结果、Nyaa 没结果）
- **真实性**：✅ 真 bug。Nyaa 请求本身正常，拿到的是它匹配不上的查询词（实测 `Frieren` 75 条；`葬送のフリーレン` / `葬送的芙莉莲` 0 条）。
  - 根因 1（查询词）：资源页把 `preferredNyaaSearchQueries` 第一项**预填**进搜索框（`fushi/lib/src/pages/implementations/video_discovery_acquisition_dialogs.dart:533`），搜索时这段文字成为显式查询词；而 `preferredNyaaSearchQueries` 有显式词就只返回显式词（`packages/fushi_engine/lib/media/torrent/nyaa_resource_provider.dart:118`）。TMDB 列表卡片没有罗马字别名（罗马字只有 AniList/MAL 结果带），预填的就是日文原名，作品自己的罗马字拼写再无机会被查。间歇性来自 MAL/AniList 偶发失败，卡片只剩 TMDB 身份。
  - 根因 2（不可见）：Nyaa 0 条算成功、不提示（`packages/fushi_engine/lib/media/external_provider.dart:132` 的 `isPartial` 只看失败）；部分失败横幅不说是哪个源（`video_discovery_acquisition_dialogs.dart:1191`）。
  - 根因 3（解析）：Nyaa HTML 任一行缺字段整页抛 `missingField`（`packages/fushi_engine/lib/media/torrent/nyaa_client.dart:757`）。
  - 核实 4（TMDB 分类）：TMDB 卡片按 `genre_ids` 含 16（Animation）判 anime（`fushi/lib/src/media/video/discovery/video_discovery_adapters.dart:497`），日本动画在 TMDB 上都带 16；不带 16 的条目没有可靠的「其实是动画」判据（原产国 JP 同样覆盖真人剧），不改。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：没有新增外部 provider；别名补齐复用 `VideoDiscoveryService.loadDetails`（TMDB 详情的罗马字来自 `alternative_titles`）。反向风险记录：TMDB 的 genre 16 也会把欧美动画判成 anime（只走 Nyaa、不走 apibay/Knaben），与本 bug 无关，未动。
