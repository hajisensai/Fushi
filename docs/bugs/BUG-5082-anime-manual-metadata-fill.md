## BUG-5082 · 手动填元数据：刮削全失败的动画 / 非 EPUB 书无法手填简介、年份、作者等
- **报告**：2026-11-21（用户：应用内反馈 fMicnouU6V ②「其它方式都失败时可以手动填元数据」，拍板台「做」）
- **真实性**：✅ 部分缺口。已有：书 / 漫画「编辑信息」可改标题、封面，作者只有 EPUB 能改（`fushi/lib/src/pages/implementations/media_item_edit_dialog_page.dart:64` `supportsAuthorEdit`）；动画可「手动指定作品」按标题或 AniDB / MAL / TMDB ID 绑定身份（`video_source_scrape_manual_*`），作品集可改名。缺：三家主源都查不到的作品无法手填简介 / 年份 / 类型等字段；漫画 / PDF 不能改作者。
- **[ ] ① 未修复** — 需要设计「用户手填」作为一类元数据来源：动画侧接 `docs/agent/anime-scraping.md` 的覆盖保护（手动字段优先、不被后续刮削覆盖、与 NFO 冲突规则），书侧把作者 / 简介编辑扩到所有书族来源。涉及刮削落库模型与 UI，未在 fMicnouU6V 的 PR 里做。
- **[ ] ② 未加自动化测试** — 修时补：手填字段落库、重刮不覆盖、清除手填后回到刮削值。
- **备注**：不得为此新增动画资料源（白名单只有 AniDB / MAL / TMDB）。
