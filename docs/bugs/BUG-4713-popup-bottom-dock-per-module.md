## BUG-4713 · 底部停靠删掉「仅在小说中」特例，改为每个模块独立可选
- **报告**：2026-11-16（维护者应用内反馈待办 5Ubh9VvdJp：「删掉仅在小说中底部停靠，改成每个模块可选」）
- **真实性**：✅ 结构问题。底部停靠的有效值是「总开关 `popup_bottom_docked`（默认 OFF）∧ 模块细分开关（默认 ON）」
  （`fushi/lib/src/models/app_model.dart:11346` `popupBottomDockedFor`），细分开关只在总开关开着时可见
  （`fushi/lib/src/settings/settings_schema_lookup.dart:90-92`）。总开关关着时想只给某一个模块停靠，只能先开总开关
  再逐个关掉其它模块——于是长出了特例开关「仅在小说中底部停靠」（`settings_schema_lookup.dart:117-140`
  `_popupBottomDockedBooksOnlySwitch` + `:104-114` `enablePopupBottomDockedOnlyInBooks`），且只覆盖小说。
- **[x] ① 已修复** — 去掉总开关对模块的门控：每个模块的有效值就是它自己的开关（默认 OFF），四条开关始终可见；
  `popup_bottom_docked` 只管不属于四个媒体模块的宿主（查词页 / 外部弹窗 / 悬浮歌词），设置里改名「其他场景中底部停靠」。
  删掉特例开关、`enablePopupBottomDockedOnlyInBooks` 与 i18n `popup_bottom_docked_books_only(_hint)`；书内快捷设置投影小说那条。
  持久化键名不改，新增语义标记 `popup_bottom_docked_per_module`（随 Profile 快照 / 备份 / 同步一起走）：缺省 = 旧语义，
  读侧按「总开关 ∧ 细分（缺省 ON）」解释，第一次写任一停靠键时把旧语义有效值物化成各模块值、与标记同一次 `setPrefs`
  落盘。老用户升级、老快照 / 老备份恢复后有效值都与保存时一致。
- **[x] ② 已加自动化测试** — `fushi/test/models/popup_bottom_docked_per_module_test.dart`（模块互不牵连、不受非模块开关门控、
  旧语义数据升级后有效值不变、老快照按保存时语义读）；`fushi/test/settings/popup_bottom_docked_switch_test.dart`、
  `fushi/test/settings/reader_lookup_popup_size_settings_test.dart` 改成新结构（开关始终可见、特例开关已删）。
- **备注**：未在真机 / 模拟器上肉眼复测设置页与各模块弹窗落点。
