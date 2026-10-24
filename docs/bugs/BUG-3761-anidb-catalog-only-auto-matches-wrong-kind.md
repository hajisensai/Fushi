## BUG-3761 · anidb-catalog-only-auto-matches-wrong-kind
- **报告**：2026-10-23（用户：「怎么没让我决策的，又说没刮削出来」→「全部根本性修复，然后pr」）
- **真实性**：✅ 真 bug。三部《劇場版 響け！ユーフォニアム～…～》全被自动绑到 TV 第一季 anidb:10889，《劇場版 少女☆歌劇》绑到 TV 版。根因：AniDB HTTP 详情不可用时 `anidb_video_metadata_provider.dart` 的 `search` / `fetchWork` 退回 `_catalogWork`，类型照抄请求、没有年份；`video_metadata_resolver.dart` `_searchWithProvider` 的类型 / 年份门对它恒放行，「劇場版 X～副标题～」剥成 X 后唯一精确命中 X 的 TV 条目即 matched。离线标题索引阶段按 Fribb 类型过门、本来正确地没绑。
- **[x] ① 已修复** — resolver 里标题目录摘要（`catalogOnlyPayloadKey`）不再当自动精确命中，只进待确认候选；自动路径留给按 Fribb 类型过门的离线标题索引阶段。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/video_metadata_resolver_test.dart`（catalog-only AniDB exact hit is never auto-matched；变异实测：去掉判断即红）。
- **备注**：同批还有 BUG-3744（CLI candidates 只过滤不搜）。本机数据已用 CLI 手工改绑修复。
