## BUG-4174 · 设置分段分组末行没有组尾圆角：空的「待发卡片」行以零尺寸混进组尾
- **报告**：2026-11-05（开发者：应用内反馈 ZWr6B6u_RM，Android；「这里选项底部没圆角」，截图 设置 › 制卡 › Fushi 复习 分组末行「后台制卡」下沿是 4dp 小圆角）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/anki_settings_page.dart:349`（develop 9eae475329）把 `PendingMinesEntryRow(hideWhenEmpty: true)` 无条件放进「Fushi 复习」分组末尾，行自己在队列为空时返回 `SizedBox.shrink()`（`fushi/lib/src/anki/pending_mining/pending_mines_page.dart:124`）。`AdaptiveSettingsSection._buildMd3Segmented`（`fushi/lib/src/utils/components/settings_shared.dart:718`）按 children 下标给分段卡定圆角，零尺寸的空行占了组尾，真正的末行「后台制卡」只拿到内侧小圆角。schema「发送与待发卡片」分组（`AnkiSectionRow.pendingMines`）同一形态。
- **[x] ① 已修复** — 「待发卡片」行露不露出改由排版它的分组决定：新增 `pendingMineCountProvider`（队列张数，首帧读 + 表变化重读），「Fushi 复习」分组只在张数 > 0 时放这一行，`ankiDeliveryRowsFor` 只在批量制卡 / 连不上时暂存开着或张数 > 0 时放；`PendingMinesEntryRow` 删掉 `hideWhenEmpty`、不再自缩成零尺寸，张数读同一 provider。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_mining_settings_visibility_test.dart`「待发卡片行只在会用到 / 有卡时入列（pending=0/3）」。
- **备注**：未在真机复测圆角像素。截图里「卡片内容」分组缝隙间的浅黄条纹原因未查明（不在本条）。
