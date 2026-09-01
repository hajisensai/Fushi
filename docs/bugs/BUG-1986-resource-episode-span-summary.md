## BUG-1986 · 资源版本卡把非连续集号显示成连续范围
- **报告**：2026-08-31（用户：资源版本卡显示“共 5 集（EP1–EP17）”）
- **真实性**：✅ 真 bug — `fushi/lib/src/pages/implementations/video_resource_version_group_list.dart:68-82` 的 `_metaLine` 用集号集合的最小值和最大值拼区间；即使真实集合只有 5 个离散集号，也会显示成覆盖 17 集的连续范围，数量与范围自相矛盾。
- **[x] ① 已修复** — 新增 `formatVideoResourceEpisodeSpans`，排序去重后的真实集号按连续段压缩；例如 `{1,2,4,16,17}` 显示为 `EP1–EP2, EP4, EP16–EP17`，只有集合本身连续时才显示单一区间（本分支提交）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_resource_version_group_list_test.dart` 覆盖离散段、单集、连续集，并通过 widget 断言版本卡显示真实段且不再出现 `(EP1–EP17)`。
- **审查补修**（同一 PR 内）：
  - **同源病灶两处，原修复只删了一处**。`fushi/lib/src/pages/implementations/subtitle_version_group_list.dart`
    的 `_metaLine` 有逐字同源的 `min/max` + `'EP$first–EP$last'`，字幕版本卡照样把
    `{1,2,4,16,17}` 显示成「5 集 (EP1–EP17)」。根因是「两处 min/max 伪装成范围」，
    只删一处不叫根因修复。纯函数下沉到 `fushi/lib/src/media/video/episode_span_format.dart`
    的 `formatEpisodeSpans`，两张卡共用同一份真相源；字幕侧补同形 widget 断言。
  - **段串长度无上限，会把做种数挤出可视区**。两张卡的元信息行都是 `maxLines: 1` +
    `ellipsis`，段串排在 `parts` 第一位。实测 24 个离散集号展开成 137 字符，而对话框
    文本列约 560px（labelSmall 下约 90 个拉丁字符）——后面的相对时间 / 体积 /
    **做种数**会被整体截掉，而做种数是这张卡上最重要的选择信号。provider 单次上限
    100 条，最坏 600+ 字符。加 `kMaxEpisodeSpansShown = 4` 显示上限，超限收成
    「前 3 段 + 省略号 + **末段**」——保留末段是刻意的：只截前几段会丢掉上界，
    读者无法判断这个版本覆盖到第几集。收缩后仍不伪装成连续范围。
  - 两条补修都做了变异实测：字幕侧退回 min/max → 新断言红；去掉显示上限 → 上限
    用例红。
- **已知欠账**：`EP` 前缀是存量硬编码（旧代码与 `_buildMemberRow` 同款），本轮新引入的
  段分隔符 `', '`、区间符 `'–'`、省略号 `'…'` 同样硬编码。这些是 locale-neutral 标点，
  但若要按 i18n 纪律清账，应当连同 `EP` 前缀在字幕侧与视频侧一次性处理。
- **备注**：版本卡纯函数与 widget 定向测试通过；Windows 真 app 原始搜索路径待复测。
