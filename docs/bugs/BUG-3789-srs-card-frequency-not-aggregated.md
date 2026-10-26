## BUG-3789 · srs-card-frequency-not-aggregated
- **报告**：2026-10-26（用户：「词频没聚合，即使我开了聚合词频，而且是不是有两个词频，重复了」）
- **真实性**：✅ 真 bug。
  1. 「词频聚合」（偏好 `harmonic_frequency`）只注入查词弹窗（`popup_settings_injection.dart`），复习卡面完全不读它：原生 Fushi 卡面默认只出按 `<li>` 逐条拆开的明细（`srs_fushi_card_view.dart` `_footer` + `srsListItems`），聚合值 FreqSort 反而被藏起来。
  2. 制卡把同一词典的多个值（普通形 + 假名形）写成多个 `<li>`，原生卡面把它们拆成多个同名 chip，看起来像重复。
  3. HTML 模板卡面（`packages/fushi_anki/templates/fushi_card/back.html`）读音行的 FreqSort chip 与底部明细列表同时显示——真重复；`fushi-srs-hide-frequency` 的隐藏规则也与原生相反。
- **[x] ① 已修复** — `SrsCardAppearance.aggregateFrequency`（运行时字段，由 `AppModel.srsCardAppearance` 叠上 `harmonic_frequency`，不持久化），原生卡面与模板同一规则：聚合且有平均值 → 只在读音行显示平均值；否则只显示按词典合并的明细（`srsFrequencyGroups` / 模板脚本 `groupFrequency`，与弹窗分组一致）；两者永不同时出现。模板侧经宿主类 `fushi-srs-freq-aggregate` + `:has()` 规则实现，`fushi_card_template_data.dart` 已重新生成。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_frequency_groups_test.dart`、`fushi/test/srs/srs_fushi_card_view_test.dart`（聚合 / 明细 / 关闭三态）、`fushi/test/srs/srs_card_appearance_test.dart`（不持久化、参与相等、宿主类名）。
- **备注**：制卡字段格式不变（一个值一个 `<li>`，外部 Anki / Yomitan 卡依赖它），合并只发生在卡面渲染层。导出到 Anki 的卡没有宿主类，按明细显示。
