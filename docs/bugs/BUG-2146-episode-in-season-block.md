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

### [x] ① 已修复 — commit 见下

1. **消除两条通路的规则分叉**（`filename_parser.dart:79-95`）：未识别括号块与括号外文本同质，
   都是「尚未被结构化规则认领的自由文本」，**无条件**让每个块都过一遍 `_parseTitleText`，
   标题仍取第一个非空候选。`_parseTitleText` 全程 first-wins（`st.episode ??=` / `if (st.season == null)`），
   所以这是纯增量：先解出的值不会被后面的块覆盖。
   顺带修好了「括号外已有标题时块里的季号被整个忽略」——`Show Name [第二季][01]` 这类以前季号直接丢。
2. **裸序数词季号**（`_bareOrdinalSeasonOnly`，`filename_parser.dart:462`）：
   锚定整段 `^\s*(\d{1,2})(st|nd|rd|th)\s*$`，只有一段文本除了序数词什么都不剩时才认季号。
   `The 4th Ninja` / `12th man` 这类标题里的序数词不受影响（没有作品叫「4th」）。
3. **资源聚类右边界**（`video_resource_version_groups.dart:21`）：先行断言补上闭括号 `] 】 )`。

### [x] ② 已加自动化测试

- `fushi/test/media/video/scraper/filename_parser_test.dart` → group `季 + 集写在同一个括号块里（BUG-2146）`（6 条）：
  用户实测文件名整条断言（title/season/episode/releaseGroup/resolution）、括号外已有标题时块内季集照解、
  `[4th Season - 14]`/`[第4季 - 14]` 同族、`[总第80]` 不污染已解集号、
  裸序数词只在独占整段时算季号（`The 4th Ninja` 负样本）、多个未识别块时标题不被顶掉。
- `fushi/test/media/video/video_resource_version_groups_test.dart` → group `episodeNumberFromReleaseTitle`（2 条）：
  块内集号右边界 + 原有块外形态不回归。

红/绿验证：把 `_parseTitleText` 循环改回 `break`，第 1、2、3、6 条立刻红；
去掉 `_bareOrdinalSeasonOnly`，第 1 条的 `season` 断言红。

### 备注

`[总第80]` 是**绝对集号**，全仓没有任何字段或消费方（`grep absoluteEpisode|总第` 零命中），
本次不引入——它是新特性不是修复。当前行为是「不解析、也不污染已解出的 14」，已有守卫钉住。
