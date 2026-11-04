## BUG-4056 · 刮削资料语言留空时跟随界面语言而非作品原语言
- **报告**：2026-11-02（反馈 89OkzOAmeR，QQ 群 fushi-bot 代提交，反馈人：咕星总督，Windows，版本未提供）
- **真实性**：⚠️ 现象属实，**不是实现 bug，是现行设计**（BUG-2454）；所有者已拍板改语义（见下「拍板」）。
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
- **拍板**：2026-11-04 所有者选 **B（留空 = 作品原语言）**。选项原文：A 保持现状只改文案；B 留空 = 作品原语言；
  C 新增显式取值「作品原语言」、留空仍是界面语言。
- **[x] ① 已修复**：
  - 配置：`VideoSourceScrapeGlobalConfig.followsWorkOriginalLanguage`（`video_source_scrape_config.dart`）=
    偏好 `video_metadata_locale` 留空；`locale` 仍是界面语言，但只作「原语言推不出」的兜底与非刮削用途（发现页、AI 提示语）。
    进 `runtimeFingerprint`。无头服务端传 `emptyLocaleFollowsWorkOriginal: false`——它的 `metadata_locale` 是管理员显式配置。
  - 装配：`VideoMetadataProviderRegistry.production`（`video_metadata_resolver.dart`）只在「跟随全局且全局留空」时给三家
    provider `followOriginalLanguage: true`；来源级 `metadata_locale` 显式覆盖不跟随（协调器 `_EffectiveSourceSettings`
    带 `followsOriginalLanguage`，与全局不同就建作用域 registry）。
  - TMDB：按作品取的请求（详情 / 季 / 集 / 别名 / 分组 / 花絮）先轻量查一次 `original_language`（独立缓存键），交给按原语言
    构造的同源实例（共用 transport；`language`、`include_image_language`、缓存键随之换）。搜索不按作品，仍用兜底语言。
  - AniDB：主标题 `xml:lang` 推原语言（`x-jat`→ja、`x-zht`→zh、`x-kot`→ko、`x-tht`→th），按它选标题。
  - MAL：Jikan 没有语言字段，`title_japanese` 就是原文标题，跟随时按 `ja` 选。
  - 协调器合并 / 选图的语言（`_localeOf`）：跟随时取作品原语言（主源给的优先，其次 TMDB 补充源），与请求端同源。
  - 设置页占位文案换成新 key `video_source_scrape_locale_follow_original`（旧 key 意思已变，`--remove` + `--add`，不 `--rename`）。
  - 影响：从没设过资料语言的存量用户，下次刮削 / 资料刷新起按作品原语言出资料（中文界面看日本动画 → 日文资料）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/video_metadata_original_language_test.dart`（配置留空 / 空白 /
  显式 / 服务端、指纹、registry 开关、TMDB 按 `original_language` 取文字与图片且探针走缓存）；
  `fushi/test/media/video/mal_video_metadata_provider_test.dart`「跟随原语言时 MAL 标题取原文」；
  `fushi/test/media/video/metadata/anidb_provider_shoko_chain_test.dart`「跟随原语言时按主标题推出的原语言选标题」；
  守卫 `video_metadata_language_wiring_guard_test.dart` 改钉新语义。
- **备注**：反馈补充里的「《摇曳露营》《向山进发》刮削卡住（工单 #178）」不在本条范围，未随本条核查。
