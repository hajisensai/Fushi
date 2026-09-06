## BUG-2146 · 括号块内「季 - 集」形态解不出集数，下载任务报 unable to determine episode number

- **报告**：2026-09-05（用户：截图「任务出错 / 错误详情」）
- **真实性**：✅ 真 bug，根因 `fushi/lib/src/media/video/scraper/filename_parser.dart:82-89`（原实现）

### 现象

下载中心「任务」页一条任务红了，错误详情：

```
unable to determine episode number:
[晚街与灯][Re Zero kara Hajimeru Isekai Seikatsu][4th - 14][总第80][WebRip][1080P_AVC_AAC][简日双语内嵌].mp4
```

抛出点 `fushi/lib/src/media/video/download/video_download_organizer.dart:140`：
`request.kind == episodic && pass.recognizedEpisodes == 0` → `FormatException`
→ `video_download_pipeline_service.dart:2296` 转 `VideoDownloadPipelineActionRequired` → 任务进 needsAttention。

### 根因

`FilenameParser` 里有**两条互不共享规则的通路**：

| 通路 | 入口 | 认得的集数形态 |
|---|---|---|
| A 括号块分类 | `_classifyBlock`（`filename_parser.dart:342`） | 只有纯数字 `[04]`、`[第04话]`、`[13 END]` 三种 |
| B 括号外文本 | `_parseTitleText`（`:593`） | `S01E04` / `第N话` / `12話` / `EP04` / `#04` / **` - 14`（`_dashEpisode`，`:442`）** / 尾部裸集数 |

`[4th - 14]` 在通路 A 三条判据全不匹配 → 落到 `:393` 的兜底分支进 `titleBlocks`（标题候选）。
而原实现只在**标题为空**时才让 titleBlocks 过通路 B，且**取到第一个非空标题就 `break`**：

```dart
String title = _parseTitleText(scan.outside, st);
if (title.isEmpty) {
  for (final String tb in titleBlocks) {
    title = _parseTitleText(tb, st);
    if (title.isNotEmpty) break;   // ← 这里
  }
}
```

于是 `Re Zero kara Hajimeru Isekai Seikatsu` 先中标即 `break`，`[4th - 14]` 从未进入 `_parseTitleText`，
唯一认得它的 `_dashEpisode` 永远跑不到。实测把 `4th - 14` 直接喂通路 B：`title="4th" E=14`——规则本来就认得。

**爆炸半径不止这一条文件名**：只要「季 + 集写在同一个括号块里」，整族都解不出集数——
`[S4 - 14]`、`[4th Season - 14]`、`[第4季 - 14]` 实测全部 `S=null E=null`。
括号外同形（`Show - 14`）则一直正常，两条通路的规则分叉就是这个 bug 的形状。

附带两处同源缺口：

- `4th` 这个季标记本身也解不出：`_ordinalSeason`（`:457`）强制要求 `Season` 字面量，裸序数词不命中。
  只修集数不修季，第 4 季会静默落进 `Season 01/`（`video_download_organizer.dart:190` 回落 `defaultSeasonNumber`）。
- `video_resource_version_groups.dart:18` 的 `_animeEpisodePattern` 是**另一套**简化正则，
  右边界先行断言只认 `[` / `(` / 结尾；`[4th - 14]` 里 `14` 后面是 `]` → 下载模式的资源版本聚类同样解不出集号。

### [x] ① 已修复

**第一版修法被自己的代码审查否掉了，这里记的是修正后的版本。**

第一版是「承认未识别括号块 ≡ 括号外自由文本，无条件让每个块都过 `_parseTitleText`」。
思路对，但**放得太宽**：`_parseTitleText` 里有一半规则是**位置启发式**，只在
「这是整个文件名的自由文本」这个前提下成立，搬进块里全部误伤（实测 old/new 对拍）：

| 规则 | 触发输入 | 改前 | 第一版改后 |
|---|---|---|---|
| ⑩ 尾部裸数字季号 | `[VCB-Studio] Yuru Camp - 05 [Disc 2][Ma10p_1080p].mkv` | `season=null` | `season=2` ❌ |
| ⑧ ` - ` 副标题 | `[幻樱字幕组] 间谍过家家 - 05 [招募新人 - 详情见置顶][1080P].mp4` | `secondaryTitle=null` | `详情见置顶` ❌ |
| ② `_cnEpisodeSuffix` | `[桜都字幕组] 摇曳露营△ [第01-12话][1080p].mkv` | `episode=null` | `episode=12` ❌ |
| ③ `_asciiMovieToken` | `[LoliHouse] Mushoku Tensei - 05 [TV-Movie][...].mkv` | `isMovieHint=false` | `true` 🟡 |

⑩ 那条最严重：它的门 `st.episode != null` 设计语义是「同一段文本里既有集号又有尾部
裸数字」，但 `st` 是**跨块累积**的——括号外文本先解出 episode 后，这个门对每个块恒真，
等于「任何以 2–9 结尾的未识别块，尾部数字直接当季号」。`[Disc 2]` / `[Reseed 2]` /
`[Special 3]` / `[Repack 2]` 全中。后果：`video_resource_relevance.dart:73` 把
`parsed.season` 当**最高优先级**，一条 `[Disc 2]` 的发布被判成第 2 季直接压到搜索最后
（正是那个文件注释里写的、已经修过的 bug 换个入口放回来），并盖掉更保守的
`detectVideoSeasonsInText` 兜底；同时归档进错误的 `Season 02/`。
还实测到**块顺序会改变解析结果**（`[Fix 2] [S1]` → season 2，`[S1] [Fix 2]` → season 1），
这已经不是「偶尔错一下」而是行为不确定。

**修正后的修法**：不动通路结构，改为在 `_classifyBlock` 里加一条**锚定整块**的判据
`_seasonEpisodeBlock`（`filename_parser.dart:227`）：

```
^(?: 第N季 | Nth[ Season] | Season N | SN )\s*[-‐–—]\s*(\d{1,4})(v\d)?( END|Fin|完)?$
```

两条约束都不能松：
- **季标记必需** —— 没有它就分不清 `[01-12]` / `[第01-12话]` 这种合集区间，会把整季
  合集包解成「第 12 集」；
- **整块锚定** —— 块判据的安全性全靠这一条，通路 A 的其它规则（分辨率/校验码/年份/
  `第N话`/纯数字/`13 END`）也都是整块匹配。

`parse()` 的循环、`_bareOrdinalSeasonOnly`、以及 `video_resource_version_groups.dart`
的正则改动**全部回退**，`filename_parser.dart` 的净改动只有这一条新判据 + 它在
`_classifyBlock` 里的分支。

### [x] ② 已加自动化测试

`fushi/test/media/video/scraper/filename_parser_test.dart` 两组：

- `季 + 集写在同一个括号块里（BUG-2146）`（5 条正样本）：用户实测文件名整条断言、
  括号外已有标题时块内季集照解、`[4th Season - 14]`/`[第4季 - 14]` 同族、
  `[总第80]` **两种块顺序**都不得抢走集号、多块时标题不被顶掉。
- `未识别括号块不得被当作自由文本解析（BUG-2146 负样本）`（5 条负样本）：上表四类
  回归逐条钉死，外加「块顺序不得改变解析结果」。

`video_resource_version_groups_test.dart` 的
`episodeNumberFromReleaseTitle 的右边界刻意不放宽` 钉住那处**有意不改**的行为。

**变异实测**（两个方向都做了）：
- 把第一版的宽循环放回去 → 5 条负样本立刻红；
- 把 `_seasonEpisodeBlock` 摘掉 → 5 条正样本立刻红。

### 备注

`[总第80]` 是**绝对集号**，全仓没有任何字段或消费方（`grep absoluteEpisode|总第` 零命中），
本次不引入——它是新特性不是修复。当前行为是「不解析、也不污染已解出的 14」，已由
两种块顺序的用例钉住。

### 已知剩余缺口（另案）

`video_resource_version_groups.dart:21` 的 `_animeEpisodePattern` 右边界只认开括号与
串尾，所以 `[4th - 14]` 这一族在**下载模式的资源版本聚类**里仍解不出集号（表现为版本卡
的集号标签为空）。**刻意不在本 bug 里放宽**：这个函数用 `firstMatch`，放宽右边界会让
更靠左的位置抢答——实测 `[Anime Time - 2] Show - 05` 解成 2、`[Vol.1 - 2] - 05` 解成 2、
合集 `[01 - 12]` 从 null 变成 12、`（1979 - 2005）` 解成 2005，而错值会被填进版本卡集号
标签和 `video_discovery_acquisition_dialogs.dart:744` 的「从第 N 集之后」订阅起点，比留空
更糟。真修需要先用 `isLikelyBatchVideoRelease` 排掉区间形态、并约束命中位置不落在开头的
发布组标签内，是独立改动。顺带记：`【组】作品 - 14 【1080P】` 这种中文字幕组最常见的
全角方括号形态在那里也一直解不出，同一处一起补。
