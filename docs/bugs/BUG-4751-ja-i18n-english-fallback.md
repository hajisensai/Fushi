## BUG-4751 · 日语界面外观设置与导航速览卡大量文案仍是英文回退
- **报告**：2026-11-17（应用内反馈 R-GL8y9O_j / GitHub issue #3378，版本 3.3.0+24434，Windows）
- **真实性**：✅ 真 bug。截图里「中文串进日语」那一半已由 BUG-4505（cce4b39558）修好；剩下的英文是日文译文缺失：
  `fushi/lib/i18n/strings_ja.i18n.json` 里 `page_backdrop_title`、`theme_pure_black`、`media_jump_history_title`、`nav_peek_open`、`lookup_history_title` 等值就是英文原文
  （消费点 `fushi/lib/src/settings/settings_schema_appearance.dart:256` / `:496` / `:747`、`fushi/lib/src/utils/adaptive/nav_rail/nav_rail_peek.part.dart:486`、`fushi/lib/src/pages/implementations/home_nav_peek.dart:843`）。
  来源是 `fushi/tool/i18n_sync.dart:661` `missingKeyFillValue`：`--add` 只收 en / zh，其余语言填英文占位，后续没人补译；英文原文改过后日文也不跟着动（`app_ui_scale_hint` 留着旧英文，和当前 en 不相等，按「== en」查不出来）。
  slang 只校验 key 齐全，不校验值是否翻译，所以没有任何检查拦住。
- **[x] ① 已修复** — 用 `i18n_sync --set` 给外观设置（含页面背景）与导航速览卡用到的 124 个 key 补了日文译文（含 `app_ui_scale_hint` 旧英文）。全库仍有约 6000 个 ja 值与 en 相同，不在本条范围。
- **[x] ② 已加自动化测试** — `fushi/test/i18n/ja_appearance_nav_peek_localization_guard_test.dart`：扫描这几个源文件用到的 key，日文值必须含假名 / 汉字（修复前红，列出 124 条）。
- **备注**：未在真机 / 日语界面截图复测；守卫只覆盖本条截图涉及的界面，其余页面的日文缺译需分批补。
