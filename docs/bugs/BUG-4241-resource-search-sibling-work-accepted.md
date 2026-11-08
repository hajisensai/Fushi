## BUG-4241 · AI 下视频把同系列续作 / 另一季的发布当成所选作品（ガルパ☆ピコ 下成 Fever）
- **报告**：2026-11-08（用户：经 `fushi_cli aidl` 走「AI 下视频」，AI 额度用完走 chip 模式）
- **真实性**：✅ 真 bug。选「BanG Dream! ガルパ☆ピコ」（AniList 101632，2018 TV_SHORT 26 集），计划卡显示「喵萌Production&LoliHouse · 1080p · BD · 26 · 291MB/集」，确认后入队的 26 个种子全是续作《ガルパ☆ピコ ふぃーばー！》（2021）的 `Garupa Pico: Fever! - 01..26 [WebRip]`。三处缺陷叠加：
  1. 剧集不做作品身份过滤：单作品路径 `packages/fushi_engine/lib/media/video/acquisition/video_acquisition_reducer.dart:1451`（修前 `_onResourcesLoaded` 只对电影传 `work`）、系列路径 `planFranchiseEntry`（:2317，修前剧集只在有同名剧集时按年份判）。Nyaa 模糊搜索把 Pico / 大盛 / Fever 全搜回来，相关度排序只重排不丢弃。
  2. 身份判据看不到兄弟作品：`packages/fushi_engine/lib/media/torrent/video_resource_work_match.dart:458` `videoResourceWorkMismatch` 只认年份 / 重制 / 合集 / 数字续作序号；`Garupa Pico: Fever!` 是「基础标题 + 副标题词」，没有数字，判为无矛盾。
  3. 版本分组键不含片源与发布形态：`packages/fushi_engine/lib/media/video/download/video_resource_version_groups.dart:177` `_groupKeyOf` 只有来源 + 发布组 + 分辨率 + trusted，喵萌的《～大盛り～》BDRip 整包与 Fever WebRip 逐集并成一张卡——片源标签取做种最多那条（BD）、每集体积把整包当单集平均（291MB）。
- **[x] ① 已修复** — 待提交（见提交记录）：
  - `VideoResourceWorkTarget` 加兄弟作品维度（`VideoResourceWorkMismatch.sibling`）：兄弟某个标题写法里目标没有的词（`fever` / `ohmori`）全部出现、且目标独有词一个都没出现 → 判为那一部；反方向（目标是续作、发布只写全了基础作标题、没写季号、没有兄弟标题解释不了的 CJK 片段、且目标每个写法都比兄弟多出区分词）→ 判为基础作。拉丁词 ≥3 字并过通用词表（season / movie / live / final…）、CJK 片段 ≥2 字并去掉季号 / 剧场版类片段；同 id / 同年同类型的条目不当兄弟。
  - 剧集也接上身份过滤（`VideoResourceWorkTarget.seriesFromReference`：只启兄弟判据 + 可选年份，不启续作序号判据）。兄弟来源：单作品路径为同一次作品搜索的其它候选（`VideoAcquisitionState.siblingWorks`，`_chooseWork` 记录），系列路径为清单里的其它条目。
  - 版本分组键加片源类别与发布形态（`subscriptionReleaseIsBatch`：逐集 / 整包），新增 `VideoResourceVersionGroup.wholeRelease`。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/acquisition/video_acquisition_franchise_sibling_release_test.dart`（nyaa 原样标题 + AniList 原样标题：兄弟判据正反例、MyGO / Season 01 / S1 / 中文译名不误杀、单作品路径记兄弟并排除、`planFranchiseEntry` 三部各拿各的、BD 整包与 WebRip 逐集分卡）；`video_acquisition_resource_picker_test.dart` 两条用例随分组语义更新。
- **备注**：
  - 剩余缺口：单作品路径的兄弟只来自同一次作品搜索的其它候选；作品搜索只返回一条（直接选中）时没有兄弟可比，不做兄弟判据（未接 MAL / AniList 关联查询）。
  - 剩余缺口：没写 batch / 区间的 BD 整包（如《～大盛り～》喵萌 BDRip）现在单独成卡，但「全集」计划仍只认写明是合集的发布（`isLikelyBatchVideoRelease`），这类包给不出全集计划——它与「Show Special」这类无集号单条分不开，当全集下错更糟。
  - 拉丁 / CJK 写法覆盖不全时会漏判（例如兄弟只有 `大盛り`、发布写 `大盛`），按「宁可漏判不误杀」处理。
