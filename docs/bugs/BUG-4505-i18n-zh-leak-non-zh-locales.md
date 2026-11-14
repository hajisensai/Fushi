## BUG-4505 · 非中文界面里冒出简体中文（Anime4K 首次提示等）
- **报告**：2026-11-15（应用内反馈 / GitHub #3378：系统英文、界面选日语，视频页的 Anime4K 首次提示是中文，按钮却是日文）
- **真实性**：✅ 真 bug。`fushi/lib/i18n/strings_ja.i18n.json` 的 `video_shader_first_use_title` / `_body` 值就是 zh-CN 原文；
  同样的 6 个 key（另有 `video_shader_import_from_mpv_hint`、`game_audio_resource_id`、
  `game_audio_fallback_disabled_missing`、`download_subscription_start_episode`）在 ar / de / es / fr / id / it / ja / ko /
  nl / pt-BR / ru / th / tr / vi 全是简体中文；ja / ko 的 `sync_err_not_paired` 写着「Fushi 互联」，ko 的
  `skip_action_seconds` 是「${n} 秒」。
  - 根因：`fushi/tool/i18n_sync.dart` 无参补全模式 `_syncMissing`（修前 `:653` 起，填值处
    `(zhCnJson[key] as String?) ?? (baseJson[key] ...)`）把缺的 key 一律用 **zh-CN 值**填进所有语言文件。
    没翻译的 key 于是以中文而不是英文出现在日语 / 德语等界面，用户看到的是自己没选的语言。
- **[x] ① 已修复** — `fushi/tool/i18n_sync.dart` 新增 `missingKeyFillValue`：只有 `zh-*` 借 zh-CN，其余语言借英文原文；
  已漏进去的 6 key × 14 语言 + ja/ko `sync_err_not_paired` + ko `skip_action_seconds` 用 `i18n_sync.dart --set` 逐语言改成译文
  （按钮名沿用各语言里 `video_settings_cat_shaders` / `video_shader_download_anime4k` 的现有译名）。
- **[x] ② 已加自动化测试** — `fushi/test/i18n/non_chinese_locale_no_chinese_leak_guard_test.dart`：补全规则
  （非中文借英文、zh-HK 借 zh-CN）+ 现存 json 守卫（13 种非中文非日文语言的汉字只能来自英文原文；ja 不含日文不用的简体字形）。
- **备注**：约 5800 个 key 在 ja 等语言里仍是英文原文（未翻译），不在本 bug 范围。
