## BUG-1712 · 「外部资源与字幕来源」只列用户自配项，Jimaku 与内置 Nyaa 全不可见
- **报告**：2026-08-18（用户：截图反馈「应该默认有自带的来源吧？这里没显示」「字幕缺少 Jimaku 来源」）
- **真实性**：✅ 真 bug。两处漏列，根因是两套配置体系的边界被当成了展示边界：
  - 字幕来源少一家：`fushi/lib/src/pages/implementations/video_external_provider_settings_section.dart:747`（旧版 build 只渲染 `t.video_opensubtitles_settings_title` + `_openSubtitlesFields()`）。Jimaku 的编辑面另在
    `fushi/lib/src/settings/settings_schema_video.dart:1187`（`SettingsTextItem video.subtitle.jimaku_api_key`）与 `:1207`（默认字幕语言），只活在 设置 → 视频 → 字幕。
    但两家 provider 是**并列**参与同一次搜索的（`fushi/lib/src/media/video/download/video_subtitle_registry.dart:25`：全部 provider 参与，动漫把 jimaku 排前），
    注册门控也对称（`fushi/lib/src/models/app_model.dart:3780` jimakuApiKey 非空 / `:3792` OpenSubtitles enabled+key）。清单里只列一家，用户合理推论是「另一家不支持」。
  - 内置来源零露出：`fushi/lib/src/models/app_model.dart:3768` 无条件注册 `NyaaVideoResourceProvider`（零配置、随包内置），
    `fushi/lib/src/media/video/download/video_resource_registry.dart:40` 只在动漫时让它参与（`provider.id == 'torznab' || (anime && provider.id == 'nyaa')`）。
    设置区里 nyaa 一个字都没有，用户看到「Torznab（空）」就以为 app 自己没有任何来源。
  - 顺带：默认字幕语言下拉长在 OpenSubtitles 块里（`video_external_provider_settings_section.dart:594` 旧版），标签是 `video_opensubtitles_languages`（「首选语言」），
    写的却是两家共用的 `jimaku_default_language`（store 侧 `savePreferredSubtitleLanguage` → `AppModel.setJimakuDefaultLanguage`）。位置与标签都在骗人。
- **[x] ① 已修复** — 提交 `<pending>`。
  - `VideoExternalProviderSettingsSection` 成为两家字幕来源的**唯一**编辑面：新增 `jimakuApiKey` 进 snapshot / `saveJimakuApiKey` 进 store 接口，新增 `_jimakuFields()`，
    把语言下拉提升为节级的 `_subtitleLanguageField()`（标签换成「默认字幕语言」），三者收进 `_subtitleSourceBlocks()`，`onlySubtitleSources` 与完整形态渲染同一份。
  - 设置 → 视频 → 字幕的两个 Jimaku schema item 删除（否则同一页出现两份编辑器），改由既有的 `SettingsCustomItem video.subtitle.opensubtitles` 内联这份组件；
    searchTitle 改成 `Jimaku · OpenSubtitles`，搜「Jimaku」仍命中。偏好键（`jimaku_api_key` / `jimaku_default_language`）一个没动。
  - 新增只读的「内置来源」块：列出 Nyaa 并写明「仅用于动漫，电影/剧集需要自行加 Torznab 索引器」。内置项不落 pref，所以是只读一行，不造假的配置卡片。
  - 无用 key `video_opensubtitles_languages` 用 `i18n_sync --remove` 删除。
- **[x] ② 已加自动化测试** — `fushi/test/settings/video_external_provider_settings_section_test.dart`
  - `both subtitle providers are editable in either placement`：两种挂载形态下 Jimaku key / OpenSubtitles key / 默认字幕语言三者都在，Jimaku key 遮罩且输入真写穿 store。
  - `built-in Nyaa source is listed`：内置来源行存在。
  - 变异实测：删掉 `_jimakuFields()` 一行 → 该用例红；还原后文件 sha256 与变异前逐字节一致。
- **备注**：真机复测待补（本条只改设置页与文案，无渲染管线改动）。
