## BUG-4128 · 复习卡面「跟随设计系统」铺不透明底色盖住壁纸，与 Fushi 卡片不一致
- **报告**：2026-11-04（用户：应用内反馈 slX_WVK_pe，Windows 3.3.0-debug.23315；「不同的卡片，有的显示下方壁纸，有的不显示」，两张截图）
- **真实性**：✅ 代码层不一致属实；用户那张不透壁纸的卡具体是哪种卡片类型、外观开关如何，反馈里没有，**未确认就是这一条**。`fushi/lib/src/srs/srs_card_design_skin.dart:66`（develop 9eae475329）：「跟随设计系统」覆盖层给非 Fushi 卡片的 `body.card` / `#fushi-card-root.card` 铺 `background: scheme.surface !important`（不透明）；而跟随主题的 Fushi 卡片按 `srsCardPaintsOwnSurface`（`srs_card_face.dart:1763`）不铺底、透出复习页背景。同一套壁纸下 Fushi 卡片透得出，其它类型（Anki 导入、Lapis、自建）被盖住。
- **[x] ① 已修复** — 覆盖层的卡面底改为透明（复习页本身就是设计系统表面，无壁纸时观感不变），去掉只为此存在的 `--fushi-ds-bg` 变量；模板自带的中性纸底仍由 `data-fushi-ds="page"` 规则抹成透明，面板色块不变。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_card_design_skin_test.dart`（CSS 生成器：卡面底规则为 `background:transparent!important`）。
- **备注**：若用户那张卡是关了「跟随设计系统」的模板卡，底色归卡片 CSS（对齐 Anki），不在本修复范围；需要用户的卡片类型 / 外观设置才能确认。未在真机复测。
