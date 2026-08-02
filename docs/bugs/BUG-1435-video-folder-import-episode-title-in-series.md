## BUG-1435 · 按文件夹导入：SxxExx 后的分集标题并进系列名，同一部番分不到一组

- **报告**：2026-08-02（用户：按文件夹导入一整季 12 集，库里出现 12 个独立项目，不是一个合集）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/video/scraper/filename_parser.dart:565`（原 `_parseTitleText` ① 处只把 `SxxExx` 本身替换成空格，其后的分集标题原样留在标题里）+ `filename_parser.dart:377`（`_normalizeSeparators` 的「点分隔命名」判定被 `_`→空格 提前污染）。

### 复现

`日々は過ぎれど飯うまし.S01EXX.<每集不同的分集标题>.WEBRip.Netflix.ja[cc].mkv` 一整季，走「导入视频 → 选文件夹」。

修复前 `parseVideoFilename` 实测（8 个真实文件名）：

```
SERIES=[日々は過ぎれど飯うまし お金なくなっちゃった!!] S=1 E=3
SERIES=[日々は過ぎれど飯うまし 出店してみますか!]       S=1 E=9
SERIES=[日々は過ぎれど飯うまし .ドライブ行かない .WEBRip.Netflix.ja] S=1 E=5
...
GROUPS=8   ← 每集自成一组
```

季/集号解得对，但 `series` 每集都不同 → `groupVideosIntoPlaylists`
（`hibiki/lib/src/media/video/video_filename_parser.dart:97`）按 series 分组得到 N 组各 1 集
→ 每组走单片导入分支（`VideoGroup.isPlaylist == false`），一个 playlist 合集都建不出来。

### 根因

1. **主因**：`SxxExx` 是 Jellyfin / Plex / Netflix 系命名的强边界，其后的内容必是「该集独有的分集标题 + 发布元数据」，不属于系列名。原实现走 `_extractFirst`，只把匹配替换成空格，分集标题继续参与标题拼装；`_cutTrailingNoiseTokens` 只截掉 `WEBRip` 起的尾部噪声，截不掉夹在中间的分集标题。
2. **次因**：`_normalizeSeparators` 先把 `_` 换成空格、再判断「串里没有空格且点 ≥2 → 点是分隔符」。文件名里只要有一个下划线（`ドライブ行かない_`、`クリスマス空いてますか!_`），判定就失效，`.WEBRip.Netflix.ja` 整串留在系列名里。

### 影响面

「按文件夹导入」的分组、导入后的合集数量、刮削搜索词（系列名带分集标题 → 相似度被拉低）。

- **[x] ① 已修复** — `filename_parser.dart`：① 处改为命中 `_seasonEpisode` 即在匹配位置截断，其后文本经 `_cutTrailingNoiseTokens` 清洗后归 `secondaryTitle`（信息不丢）；集号之前无标题字符时（`S01E04 - Title` 这类集号前置命名）保留原「替换成空格」行为，避免标题被截空。`_normalizeSeparators` 的点分隔判定前移到 `_`→空格 之前。提交见本分支。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_filename_parser_test.dart`：新增 group「SxxExx 后的分集标题不进系列名（BUG-1435）」4 例（Netflix 命名 / 含下划线 / secondaryTitle 承接 / 集号前置不截空）+ `groupVideosIntoPlaylists` 的「整季分集标题各不相同 → 仍归一组，按集号排序」。变异实测：把截断改回 `replaceRange` 旧行为 → 4 个 error event，守卫有效。

- **备注**：修好后同一部番按文件夹导入直接归一组，且组内已由 `_compareEpisodes` 按 季→集 排好序，导入路径不再需要事后手动整理。合集**手动**建时的成员顺序是另一条独立缺陷，见 [[BUG-1436]]。
