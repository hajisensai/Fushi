## BUG-1512 · 发现页同一单集长篇动画电影被重复展示
- **报告**：2026-08-11（用户：Wight）
- **真实性**：✅ 真 bug。`video_discovery_service.dart` 的跨来源合并要求
  `mediaKind` 完全一致；AniList 会把部分只有一集的长篇 ONA 标为 TV，而 TMDB
  把同一作品标为电影。即使规范化标题和年份一致，这两个结果也会被硬拆成两张卡片。
- **[x] ① 已修复** — 聚合层把“动画 + 单集 + 时长不少于 60 分钟”视为电影
  身份，仅在标题、年份和来源 ID 冲突检查也通过时合并；混合身份组优先保留真实
  movie 条目作为主项，同时汇总 AniList 等外部 ID。
- **[x] ② 已加自动化测试** —
  `fushi/test/media/video/discovery/video_discovery_service_test.dart` 覆盖单集长篇
  ONA 与电影合并，以及多集 TV 不得误并入电影。
- **备注**：按用户要求未运行自动化测试；Windows Debug 构建与可见搜索复测另记。
