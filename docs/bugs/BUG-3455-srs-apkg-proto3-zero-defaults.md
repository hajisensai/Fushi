## BUG-3455 · srs-apkg-proto3-zero-defaults
- **报告**：2026-10-16（用户：Anki 新格式包里每日新卡上限设成 0 的预设，导入 Fushi 后变成 20）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/srs/apkg/srs_anki_package.dart:604-606`（旧）读新格式（protobuf）`DeckConfig.Config` 时用 `c.intOf(9, 20)` / `c.intOf(10, 200)` / `c.intOf(16, 36500)`：「字段缺失 → 回落非零默认」。但这些是 proto3 标量，proto3 根本不写 0 / false / 空——缺失就是零值。于是新卡上限 0 读成 20、复习上限 0 读成 200。同类还有 `:584` 的 `Normal.config_id` 用 `intOf(1, 1)`。逐个核对新格式解码：其余标量（kind、css、desired_retention、rwkv_review_enabled、learn/relearn steps、fsrs_params）本来就按零值 / 空解码；`original_id`、`Field/Template.Config.id`、fork 的 `fsrs_version` 是 optional，按缺失处理（`optInt`）——正确。旧格式 JSON 的缺键默认（`_loadPresetsJson` 的 20 / 200 / 36500）不受影响。
- **[x] ① 已修复** — 三个预设标量改为 `intOf(field)`（零值）；`config_id` 按零值解码后在语义层换算：0 不是任何预设的 id，Anki 取不到牌组预设时用默认预设 1，照此换成 1（解码层不再藏默认值）。最大间隔 0 是无效值，导入端本来就只在 > 0 时写，走本机默认。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/apkg/srs_apkg_import_test.dart`「BUG-3455：新格式预设的 proto3 零值…」：预设 new/day、review/day 不写（= 0）、rwkv 不写（= false），解码后保持 0 / false / null，并端到端导入后牌组上限仍为 0；没写 config_id 的牌组落到默认预设。
- **备注**：Anki 允许学习步长为空，Fushi 的 `srsSanitizeSteps`（fushi_srs）对空列表回落 [1, 10]——这是 Fushi 排程侧的语义选择，不是解码问题，本次未改。
