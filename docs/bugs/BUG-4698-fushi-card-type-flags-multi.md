## BUG-4698 · fushi-card-type-flags-multi
- **报告**：2026-11-18（用户：issue [#3494](https://github.com/hajisensai/Fushi/issues/3494) Fushi Card 卡型开关可同时开多个，内置复习与 Anki 显示不一致，音频卡不生效）
- **真实性**：✅ 真 bug。同一张卡的正面卡型有两处判定且语义不同：内置复习 `fushi/lib/src/srs/srs_fushi_card_plan.dart:56` `srsFushiFrontKind` 按 例句 > 单词+例句 > 点击 > 听音 只取一个；Anki 模板 `packages/fushi_anki/templates/fushi_card/front.html` 四段 `{{#Is…Card}}` 相互独立、全部叠加。编辑页 `fushi/lib/src/pages/implementations/srs/srs_note_editor_page.dart`（`_buildField` 的 `toggle`）把四个开关当独立字段，可同时打开多个。Lapis 上游 README 也要求只开一个，组合并无定义语义。
- **[x] ① 已修复** — 用户拍板「四选一」（全关 = 单词卡），老数据不迁移：模板正面改成嵌套 `{{^…}}`，按与 `srsFushiFrontKind` 同一优先级只出一段（老数据多开时两边一致）；编辑页拨开一个卡型开关即关掉其余三个（`srsCardTypeFlagToggle`，`packages/fushi_engine/lib/srs/srs_note_batch_edit.dart`，与批量「设置卡型」同语义），关掉只清自己。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_fushi_card_front_kind_parity_test.dart`（16 种开关组合：真实模板经 Anki 渲染器渲染出的卡型与 `srsFushiFrontKind` 一致且唯一）；`fushi/test/srs/srs_note_editor_visual_test.dart`「打开听音卡会关掉其余卡型开关」；`packages/fushi_engine/test/srs/srs_card_type_flag_toggle_test.dart`。
- **备注**：已导出到 Anki 桌面的 Fushi Card 笔记类型不会自动换新模板，需重新导出 / 推送模板才生效。
