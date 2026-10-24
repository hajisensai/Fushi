## BUG-3770 · 服务端 Anki 落地测试仍按「空映射=等配置」断言，与默认映射契约冲突
- **报告**：2026-10-24（CI：develop@6397b193b0 的 `server` job 红，`packages/fushi_server/test/anki_landing_test.dart` +4 -2）
- **真实性**：✅ 真红（干净 develop 本地复现）。根因：`cd732f10c7 fix(anki): default field mappings for any note type`（反馈 AGLC0BuaKB）让 `AnkiSettings.fromJson`（`packages/fushi_anki/lib/src/anki_models.dart` `withDefaultMappingsIfUncovered`）在载入时把「一个字段都没映射到所选笔记类型」的设置（空表 / 只有旧笔记类型的键）补成 `noteTypeDefaultMappings` 推出的默认映射。服务端 `ServerAnkiLanding.settings`（`packages/fushi_server/lib/src/anki_landing.dart`）每次都经 `fromJson` 读偏好，所以 Vocab(Word/Meaning) 刷新后直接得到 `{Word: {expression}, Meaning: {glossary}}`，`_mine` 的「没配置」门放行，卡按默认映射落进 Anki。两条用例仍断言旧契约：① 映射为空 → 实得默认映射；② 旧键 `Front` → 被换成默认映射、卡已 delivered，`waiting` 为 0。代码行为是 cd732f10c7 有意的五端统一契约（服务端同样受益：不再需要人工配映射才落卡），过时的是断言。
- **[x] ① 已修复** — 不改代码行为；`anki_landing.dart` `_mine` 的「没配置」门注释改写为现状（空表 / 旧键已在载入时补默认映射，走到这里的只剩没选笔记类型或笔记类型无字段）。
- **[x] ② 已加自动化测试** — `packages/fushi_server/test/anki_landing_test.dart` 两条改为新契约：空映射 → 断言补出的默认映射且卡 delivered、不标失败；旧笔记类型的键 → 断言换成默认映射且卡 delivered、不标失败。「还没登录 = 等配置」仍由「开落地 → 登录 → 配映射」用例覆盖。
- **备注**：
