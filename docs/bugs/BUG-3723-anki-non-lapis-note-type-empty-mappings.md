## BUG-3723 · 选非 Lapis 笔记类型后字段映射为空，制卡全部被拒为空卡
- **报告**：2026-10-21（来源：应用内反馈 AGLC0BuaKB，iOS 3.0.0-debug.20409，标题「无法导入anki」）
- **现象**：「一键制卡」批量页 2/2 全部失败，每条报 `All fields are empty — refusing to create a blank card.`；词条与例句都有内容（韩语）。标题说「导入」，实际是制卡导出失败，与 apkg 导入 / unicase 无关（日志里没有 unicase 报错）。
- **真实性**：✅ 真 bug（映射层，与学习语言无关）。根因：选非 Lapis 笔记类型时映射被置成 `{}`——`fushi/lib/src/anki/anki_view_model.dart:184` 调 `LapisPreset.applyDefaults(noteType, {})`，非 Lapis 原样返回空表（`packages/fushi_anki/lib/src/lapis_preset.dart:22`）；拉取配置后非 Lapis 也原样沿用旧映射（`packages/fushi_anki/lib/src/anki_note_composer.dart:349`），映射里留着别的笔记类型字段名时同样整张空卡。代码里没有任何按字段名自动匹配。批量页把 `allFieldsEmpty` 当单条失败（`fushi/lib/src/media/favorites/favorite_batch_mining_runner.dart:391`），每条各失败一次、不提示去配置。BUG-3652 只把这句报错本地化了，根因未动。
- **[x] ① 已修复** — `cd732f10c7`：新增 `noteTypeDefaultMappings`（按字段名认词条 / 读音 / 释义 / 例句 / 音频 / 图片，别名覆盖英中日韩；认不出时首字段兜底 `{expression}`、次字段 `{glossary}`）；`LapisPreset.applyDefaults` 与 `fieldMappingsAfterFetch` 在映射一个字段都没覆盖到选中笔记类型时补默认映射；`AnkiSettings.fromJson` 载入时修复存量空映射（用户配过的不动）；映射配置类错误码（allFieldsEmpty / fieldMappingMismatch / firstFieldEmpty）让批量制卡整批中止、只报一次。
- **[x] ② 已加自动化测试** — `packages/fushi_anki/test/note_type_default_mappings_test.dart`
- **备注**：用户具体是手动选了 Basic 类笔记类型，还是切换过 `useAnkiConnectOnMobile` 后拉取到非 Lapis 类型，代码判断不了；两条路径修复后都能得到非空映射。
