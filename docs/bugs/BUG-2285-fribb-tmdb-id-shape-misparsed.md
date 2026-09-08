## BUG-2285 · Fribb 映射表的 themoviedb_id 是对象不是裸数字、TVDB 键是 tvdb_id，解析用错形状导致 TMDB id 恒为 null
- **报告**：2026-09-08（自查：给离线标题索引写真网络探针时发现 `withTmdb=0/12`）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/video/metadata/anime_identity_mapping.dart` 的 `fromRows` 原来按 `_positiveId(row['themoviedb_id'])`（裸数字）与 `row['thetvdb_id']` 解析。抓真文件核对（`https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json`，39304 行）：
  - `themoviedb_id` **恒为对象**：`{"tv": 209867}` 7092 行、`{"movie": [128]}` 1363 行（movie 侧的值还是**数组**），其余 30849 行缺失。从不出现裸数字 → `_positiveId` 恒返回 null。
  - TVDB 键是 `tvdb_id`（int，7471 行）；`thetvdb_id` **零命中** → `tvdbId` 恒为 null。
  - `season` / `episode_offset` 是对象，这两个原本解析正确（所以探针里 `season=1` 有值、`tmdb=null`，恰好掩盖了问题）。
  后果：`AnimeIdentityEntry.tmdbId` / `tvdbId` 全库恒为 null，于是 **A2 的 MAL→TMDB id 接力**（`_tmdbLookupFromMapping`）与 **B 的多季对齐**（`entriesForTmdbTv` → `_expandMalSeasons`）静默失效——两条路径都只是「拿不到映射就安静退回旧行为」，没有任何报错，单测又用同样错误形状的 fixture，所以从头到尾没人发现。
- **[x] ① 已修复** — 按实测形状解析：`themoviedb_id.tv` 取 id；`.movie` 经新增的 `_firstPositiveId` 取数组首个正整数并置 `tmdbIsMovieNamespace`；TVDB 改读 `tvdb_id`。`AnimeIdentityEntry.isMovie` 改为「命名空间优先于 `type` 字段」（movie 命名空间即便 `type` 缺失也不能按 `/tv/{id}` 拉）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/anime_identity_mapping_test.dart` 的 fixture 全部换成实测形状并加注释钉住（含 `{"movie":[128]}` 数组、`type` 缺失的电影行、`{"tv":0,"movie":[]}` 脏值行），新增两条断言验证 movie 命名空间与数组取值；`multi_season_coordinator_test.dart` / `offline_identity_coordinator_test.dart` 的 fixture 同步改真形状（改之前它们是「用错误形状喂错误解析器」的双错相消，改完才真的在测多季对齐）。
- **备注**：真网络探针结果（2026-09-08，15 个中文 / 日文 / 罗马字标题）：修复前 `matched=12/15 withMal=12 withTmdb=0`，修复后 `matched=12/15 withMal=12 withTmdb=12`，TMDB id 抽查正确（Frieren 209867 / 药屋 220542 / 千与千寻 129 / 你的名字 372058）。未命中的 3 个：`我推的孩子`、`间谍过家家` 因 AniDB 标题包里 S1/S2 同名判歧义（按 Sonarr/Taiga 纪律放弃，退回在线搜索），`无职转生` 标题包无此中文名。探针脚本是一次性的，未入库。
