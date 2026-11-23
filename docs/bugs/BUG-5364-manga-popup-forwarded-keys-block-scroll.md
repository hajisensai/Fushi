## BUG-5364 · manga-popup-forwarded-keys-block-scroll
- **报告**：2026-11-24（PR #4309 复审发现）
- **真实性**：✅ 真 bug。漫画查词弹窗持焦时按 PageDown / ↓ / ↑ / 空格滚不动释义，一按就关弹窗翻页。根因 `fushi/lib/src/media/manga/reader/manga_fushi_page.dart` `dictionaryPopupForwardedActions` 含 `mangaPageForward / mangaPageBackward`，基类 `dictionaryPopupInputSpec` 把这两个动作的**全部**键位导出成弹窗回传键表（旧桥只硬编码 ← → Esc，泛化成「注册表导出」时连带把其余翻页键也截走）。
- **[x] ① 已修复** — 新纯函数 `dictionaryPopupInputSpecArrowPageTurn`（`dictionary_popup_input_bridge.dart`）：鼠标键按转发集合全量交回（侧键关弹窗不变），键盘只交回非翻页动作的键位，翻页只追加裸 ← →（与小说 uz_2m0E_Eu ③ 同一个 `withPopupArrowPageTurnKeys`）；漫画页 `dictionaryPopupInputSpec` 改用它。
- **[x] ② 已加自动化测试** — `fushi/test/shortcuts/page_turn_unify_test.dart`「漫画：翻页只交回 ← →…（BUG-5364）」按默认键位断言旧做法会截走的键不再出现、← → / Esc 仍在、鼠标键不变；另有源码守卫钉住漫画页走该函数。
- **备注**：
