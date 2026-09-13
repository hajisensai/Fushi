## BUG-2369 · 本地目录集号靠单文件名赌数字位数，1-9 与 10+ 各错一半

- **报告**：2026-09-09（用户：本地文件夹「10 集以上读不出来」，Zankyou no Terror 11 集全对，Chuunibyou 12 集只认 9 集、10–12 被排到第 1 集后面）
- **真实性**：✅ 真 bug，根因 `fushi/lib/src/media/video/scraper/filename_parser.dart:464`（`_bareTrailingEpisode`）+ `fushi/lib/src/media/video/video_filename_parser.dart` 的逐文件解析口径

### 现象与实测

仓内解析器（develop `4b8263aee2`）跑 18 种命名 × 集号 1..12，实测：

| 命名形态 | 1..9 | 10..12 |
|---|---|---|
| 补零（`- 01` / `01` / `[01]` / `S01E01` / `第01话` / `EP01`） | 全对 | 全对 |
| **不补零 + 空格/点分隔**（`Show 1.mkv`、`Show.1.1080p.mkv`） | **全部解不出** | 解得出 |
| **集号紧贴标题无分隔**（`Show!1.mkv`、`Show!-1.mkv`） | 解不出 | 解不出 |

两种坏形态的下游后果一致，且正好复现用户看到的两个症状：

- **集号一半有一半没有** → `_compareEpisodes` 把 null 排到末尾、非 null 排前面，或（全 null 时）退化成裸字符串序 `1, 10, 11, 12, 2, …`；
- **解不出集号的文件，集号还留在系列名里**（`Show 1` / `Show 2` 各成一个系列）→ `_groupingSeries` 按 series 分组，同一部番被拆成一堆单集卡，「主计数」自然对不上文件数。

### 根因

集号被当成了「单个文件名的函数」。单看一个文件名，`Show 2` 是第 2 季还是第 2 集**无法判定**，
所以引擎只能赌：`_bareTrailingEpisode`（`filename_parser.dart:464`）赌「尾部裸数字要两位或带前导零
才算集号」，`_trailingNumericSeason`（`:533`）赌「单个 2–9 算季号」。这个赌局本身没写错——它是为了
不吞掉 `Hibike! Euphonium 2` / `Mob Psycho 100` / `Gundam 00` 这些标题自带数字的作品（BUG-1543）——
但它在「不补零」的目录里必然把同一批兄弟文件劈成两半：`10/11/12` 位数够、赌赢，`1..9` 赌输。

**而一批兄弟文件放在一起时，这个歧义根本不存在**：它们只在集号那一段不同，公共前后缀之外那段
变化的数字就是集号。这是集合的性质，不需要猜。

顺带查出同源的第二处口径分叉：`parseVideoPath` 直接拿路径最后一段解析，**不解码 URL 段**，而
`groupVideosIntoPlaylists` 解码后再解析。`Show%20A%20S01E01.mkv` 里 `S` 前面是 `0`，`SxxEyy` 的
分隔边界不成立 → 同一个文件两条通路一个解得出集号、一个解不出（既有用例 `URL 路径（网络来源）`
在本次改动下立刻把它照了出来）。

### [x] ① 已修复

`fushi/lib/src/media/video/video_filename_parser.dart` 新增**兄弟集合差分定号**：

- `resolveSiblingEpisodeNumbers(paths)` —— 同目录一批文件取公共前缀/后缀，中间那段就是集号，
  同时用公共前缀推出系列名（前缀过一遍同一个 `FilenameParser` 剥字幕组/画质块）；
- `fillEpisodeNumbersFromSiblings(paths, perFile)` / `parsedEpisodeNumbersOf(paths)` —— 批量入口；
- `groupVideosIntoPlaylists` 的集号与分组键都吃差分结果（集号解出来了，系列名里就不能再留着它，
  否则番还是散的）；
- `_compareEpisodes` 的末位判据从裸字符串序改 `naturalCompare`（复用 `shelf_sort.dart` 那套，不另起
  一份）：集号真的解不出时也不能排成 `1, 10, 11, 12, 2`；
- 显示侧两个调用点改批量：`video_fushi/episode.part.dart` 的选集轨道、
  `media_collection_detail_page.dart` 的集卡序号（后者按 `_slots` 对象身份缓存，四个赋值点不必手动失效）；
- `parseVideoPath` 与归组同口径先解码 URL 段。

**零回归靠四道门**（任一不成立就整个目录保持原行为，逐字不变）：

1. 目录里至少 2 个文件、stem 两两不同；
2. **目录里每个文件都自带集号时差分根本不介入**——补零命名一个字节不动；
3. 公共前后缀不得切断数字段（否则 `Show 10/11/12` 会被切成 `0/1/2`），中段必须只剩 1–3 位数字
   （4 位挡掉 `Movie (1979)` 这种按年份区分的目录），且各文件数值两两不同；
4. **只补 null、从不覆盖已解出的集号**，且差分结果必须与该目录每一个已解出的集号都对得上；
   对不上（绝对集号与分季集号混在一个目录）整目录放弃。

差分推出的系列名还要过一道「不许留季/集残词」：公共前缀是按字符切的，`Show S01E01/02` 的公共
前缀会停在 `Show S01E`，直接当番名会把 `S01E` 焊死进去；残词削完为空就等于「推不出系列名」，
回落 BUG-2286 的父目录口径。

### [x] ② 已加自动化测试

`fushi/test/media/video/video_filename_parser_test.dart` 新增 14 条（两组）：

- 正样本 7 条：不补零 12 集目录整批定号并归一组、集号紧贴标题、公共前缀不得切断数字段
  （只有 10/11/12 的目录不得解成 0/1/2）、`parsedEpisodeNumbersOf` 批量、只补不覆盖、
  不同目录各自定号互不偷号、**补零命名不经过差分**（回归钉）；
- 负样本 7 条：混入特典不硬凑、4 位年份不当集号、与已解出集号对不上就整目录放弃、
  stem 重名、单文件不差分、集号解不出时按自然序排。

验证：`video_filename_parser_test.dart` + `episode_display_number_test.dart` 58 条全绿；
`test/media/video` + `test/media/source_library` + `test/media/collections` + 3 个合集页用例
共 3796 条跑完，3 条红全部定性为非本次改动：`long enqueue renews its lease` 与
`anidb real UDP` 在**未改动的 develop 上同样红**（既有 flaky），
`long provider search renews the subscription lease` 只在高负载并跑时红、单独跑与整文件跑
（22 条）在本分支全绿。`flutter analyze` 零问题。

### 备注 / 有意的取舍

- **同目录下「只差一个数字」的一批文件会被当成一部番**：`Ip Man 1/2/3.mkv` 这种电影三部曲放同一个
  目录里，会归成一个播放列表、集号 1/2/3。这与 BUG-2286 「同一目录混着不同番的纯集号文件按目录归组」
  是同一条取舍——单从文件名无法区分，用户可在合集里拆分。**只影响那些今天本来就是散的目录**
  （目录里每个文件都自带集号时差分不介入）。
- `[Disc 1] / [Disc 2]` 这类只差一个数字的分卷目录同理会被编成 1/2 集。同上，今天它们本来也是散的。
- 已入库的老条目要**重扫来源**才会按新口径归组/定号，扫描期改动不追改存量行。
