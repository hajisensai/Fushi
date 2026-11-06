## BUG-4131 · 字段映射「释义（前 N 条）/（首条）」文案与实际取值（前 N 本词典 / 选中词典）不符
- **报告**：2026-10-28（用户：🙃 与 哈吉千歳，QQ 群经 fushi-bot 代提，应用内反馈 5qvHTjJrbm；Android 平板）
- **真实性**：✅ 真 bug。`packages/fushi_anki/lib/src/anki_models.dart` `_firstGlossaries`（`{glossary-first-N}`）取的是**前 N 本词典**、长按选中的那本排第一；`{glossary-first}` 是选中词典优先、没选才第一本；`{selected-glossary}` 只取选中词典（没选为空）。界面文案 `handlebar_glossary_first_n`「释义（前 N 条）」/ `handlebar_glossary_first`「释义（首条）」/ `handlebar_selected_glossary`「选中的释义」（`fushi/lib/src/pages/implementations/anki_settings_page.dart` `_ankiHandlebarBaseLabel`）把「本词典」说成「条释义」。
- **[x] ① 已修复** — key 不改名（三个 key 本来就按 handlebar 标记命名），只改含义错的语言值：en / zh-CN / zh-HK 三个都改成按词典描述；ja（「件」）、th（「รายการ」）、vi（「mục」）的「前 N 条」改；其余语言是与旧英文同样的「(first)」式中性译法，保留。改值用新加的 `dart tool/i18n_sync.dart --set <key> <locale> <value>`（只改一种语言，其余逐字不动）。PR #2980 初版用 `--remove` + `--add` 换名，15 种语言退成英文，已撤回。取值规则不变（`{glossary-first-N}` 与 `{glossary-first}` 的「选中优先」已在 e4f83d9884 统一）。
- **[ ] ② 未加自动化测试** — 纯文案改动，没有可咬住的行为；取值规则已有 `packages/fushi_anki` 的字段渲染测试覆盖。`--set` 本身有 `fushi/test/tools/i18n_sync_ops_test.dart` 覆盖。
- **备注**：开发者在反馈里提的「重新设计一套字段名（兼顾 Lapis 兼容）」是设计任务，本条不做；`{book-cover}` / `{video-clip}` 旧别名已标弃用，未动。
