## BUG-4005 · 刮削资料语言留空时跟随界面语言而非作品原语言
- **报告**：2026-11-02（反馈 89OkzOAmeR，QQ 群 fushi-bot 代提交，反馈人：咕星总督，Windows，版本未提供）
- **真实性**：⚠️ 现象属实，但**不是实现 bug，是现行设计**；要改成「作品原语言」是产品语义变更，需所有者拍板（见下「选项」），本条不擅自改。
  - 现象链（已沿代码核实）：全局资料语言偏好 `video_metadata_locale` 留空 →
    `VideoSourceScrapeGlobalConfig.fromPreferences` 以界面语言兜底
    （`packages/fushi_engine/lib/media/video/metadata/video_source_scrape_config.dart:238-241`、`:264`
    `locale: locale.isEmpty ? uiLocale : locale`）；`uiLocaleTag` 是 app 的 `AppModel.appLocale`（界面语言，
    界面跟随系统时即 Windows 显示语言）→ 协调器 `_locale`
    （`video_source_scrape_coordinator.dart:278`）→ TMDB `language` / `include_image_language`
    （`tmdb_video_metadata_provider.dart:93`、`:174`、`:1421`）与 AniDB 标题优先语言
    （`anidb_video_metadata_provider.dart:1046` `_preferredLanguages(language)`）。中文界面 → `zh-CN` →
    TMDB 回中文标题 / 简介 / 海报。
  - 这是 BUG-2454 有意定下的语义：设置页占位文案就是「跟随界面语言」
    （`fushi/lib/src/settings/settings_schema_video.dart:2029-2061` 注释与 `placeholder:
    t.video_source_scrape_locale_follow_ui`），引擎侧注释明写「用户没显式设过资料语言时就用它」。
    反馈里「群内开发者也认为默认应取作品语言」来自不可信的群聊转述，不能当所有者的拍板。
  - 用户当下可用的做法：设置 → 视频 → 媒体库 → 资料语言填 `ja`（或来源级「资料语言」覆盖填 `ja`），
    即按日语刮。
- **[ ] ① 未修复（待拍板）** — 需所有者在下列选项里选一个：
  - **A. 保持现状**（留空 = 界面语言），只把设置项副标题写得更醒目（例如「想要日语资料请填 ja」）。零语义变化。
  - **B. 留空 = 作品原语言**（反馈诉求）。改动面：TMDB 要先取一次详情拿 `original_language`
    （`tmdb_video_metadata_provider.dart:731` 已解析该字段）再按它请求文字与图片，缓存键里的
    语言随之按作品变（`:176-179`）；AniDB 主源按 anime XML `type="main"` 标题的 `xml:lang`
    推原语言（`:836`）；MAL / Jikan 取 `title_japanese` 等。会改变所有「从没设过资料语言」的
    存量用户下次刮削 / 资料刷新的结果（中文界面用户会从中文资料变成日文资料），属于同步语义变更。
  - **C. 新增显式取值「作品原语言」**（如一个哨兵值 / 分段选项「跟随界面 / 作品原语言 / 自定义」），
    留空默认仍是界面语言，存量用户不变；想要日语沉浸的用户一键切换。实现面同 B 的取语言逻辑，
    但只在用户选了它时生效。
- **[ ] ② 未加自动化测试** — 拍板后随实现补：`video_source_scrape_config` 单测（留空 / 哨兵值解析）+
  TMDB provider 按 `original_language` 取文字与图片的 fake HTTP 单测。
- **备注**：反馈补充里的「《摇曳露营》《向山进发》刮削卡住（工单 #178）」不在本条范围，未随本条核查。
