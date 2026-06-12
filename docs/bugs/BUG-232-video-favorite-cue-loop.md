## BUG-232 · 视频收藏句缺少字幕锚点和收藏页跳回闭环（TODO-176/TODO-177）

- **报告**：2026-06-12（用户）
- **真实性**：真 bug。视频页已有字幕跳转列表和行内收藏按钮，但收藏句缺少稳定 cue/episode 锚点，收藏页也没有完整的视频打开/seek 分支，导致用户能看到视频收藏句，却不能可靠回到对应视频、对应集、对应字幕。
- **根因**：`VideoHibikiPage` 早期只保存 `bookUid + text`，首轮修复补了 `cue.startMs`，但播放列表路径仍只把 `bookUid + startMs` 传回视频页；`_init()` 在 `_episodes.isNotEmpty` 时继续用 `row.currentEpisode` 和 `_episodes[idx].positionMs`，没有消费收藏页传入的 episode/cue 锚点，多 episode 下会打开错集或错位置。
- **[x] ① 已修复**：视频收藏句现在用 `FavoriteSentence.sectionIndex` 保存 playlist episode index，用 `normCharOffset` 保存 `cue.startMs`，用 `normCharLength` 保存 cue duration。收藏页将视频收藏解析为 `episodeIndex + startMs` 后调用 `VideoHibikiPage.neutralized(initialEpisodeIndex, initialCueStartMs, initialSubtitleListVisible: true)`；视频页 playlist 初始化优先消费 `initialEpisodeIndex` 和 `initialCueStartMs`，再回退到上次播放集/位置。控制器加载初始位置后立即刷新当前 cue，使跳回后的字幕列表/当前 cue 高亮可见。
- **[x] ② 已加自动化测试**：`hibiki/test/pages/video_favorite_open_target_test.dart` 覆盖 playlist 收藏页打开目标、旧 playlist 收藏降级、单视频 startMs 保留、过期 episode clamp；`hibiki/test/pages/sentence_favorites_todo047_guard_test.dart` 守住收藏页传参、视频页 playlist 初始化消费 episode/startMs、字幕列表可见；`hibiki/test/media/audiobook/favorite_sentence_source_test.dart` 守住视频收藏句 JSON 锚点字段。
- **降级策略**：旧播放列表收藏如果没有 episode identity，不能只靠 `bookUid + startMs` 假装稳定定位到某集；收藏页只打开视频当前集，不传 startMs。单视频旧收藏仍可按已保存 cue 文本回退解析 startMs。
- **备注**：本轮未跑真实设备/离屏 UI；focused Flutter tests 覆盖数据锚点、收藏页 open target、视频页初始化接线、字幕列表星标/当前 cue 高亮控制器逻辑。
