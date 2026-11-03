## BUG-3969 · sync-compare-cards-not-selectable
- **报告**：2026-11-02（用户：反馈 ZqCPfu8-of，Android）
- **真实性**：✅ 真 bug。`fushi/lib/src/sync/sync_compare_dialog.dart` 的 `_dataColumn`（原 :2214）是纯展示的 AnimatedContainer，却画成可选分段块（内角收小、选中铺 primaryContainer + 勾选徽标）；真正写 `_choices` 的只有下面的三段按钮 `_choiceRow`（原 :2158）。同一个「用本地 / 用远端」状态画了两遍，一份能点、一份只能看。
- **[x] ① 已修复** — 人工裁决条目里两张卡本身就是选择控件（InkWell + FushiPressScale + `Semantics(button, selected)`，点哪张用哪侧），删掉三段按钮条，只留一个「跳过」文本按钮撤销选择；手柄 / 键盘仍由 `FushiAdjustableSegmented` 把这对卡片包成一个焦点站，左右键按 本地 / 跳过 / 远端 循环。非人工条目的卡片只做展示：四角同圆角、没有勾选徽标、不可点。MD3 / Apple（accent 淡染）共用同一路径。
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_compare_card_choice_test.dart`（点远端卡 → 远端 selected；点本地卡切换；跳过撤销；没有三段按钮；非人工条目无可点卡片）。
- **备注**：既有测试按 `find.text(t.sync_compare_use_local)` 点选的写法仍有效（英文 / 中文下卡片标题与原分段标签同文）。
