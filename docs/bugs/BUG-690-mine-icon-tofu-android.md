## BUG-690 · 手机制完卡后制卡图标✓乱码/豆腐（Android WebView 缺符号字体）

- **报告**：2026-07-10（用户：TODO-1368「手机制完卡图标会乱码」）
- **真实性**：✅ 真 bug — 根因 `hibiki/assets/popup/popup.css:318-321`（BUG-655 给 `.mine-button` 钉的「单色符号字体栈」`"Segoe UI Symbol","Apple Symbols","Noto Sans Symbols2","Noto Sans Symbols","DejaVu Sans","Segoe UI",sans-serif !important` 全是桌面字体）。
- **根因链**：制卡按钮的 +/✓/✓↩︎ 是文本字形标记（`popup.js` `setMineState`，应用户要求不走 SVG）。BUG-655 用上述字体栈切断了对注入词典字体的继承——桌面三平台各自命中系统符号字体没问题；但 **Android WebView 上这套栈一个都按名解析不到**：Segoe UI Symbol/Apple Symbols/DejaVu Sans 是 Windows/macOS/Linux 字体，Noto Sans Symbols(2) 在 AOSP `fonts.xml` 里是**无名 fallback 项**（CSS 按名解析不到；部分 ROM 更直接缺失/替换该字体），兜底 `sans-serif`=Roboto 实测 cmap 根本不含 U+2713/U+21A9（fontTools 解析 Flutter 工具链自带 roboto-regular.ttf 证实）→ ✓ 只能赌系统 per-character fallback；fallback 链被 ROM 换掉/裁掉时即豆腐/彩色 emoji。AnkiDroid 后端制卡后无 note id、按钮只显裸 `✓`（`popup.js:1999`），字形缺失时最明显。
- **[x] ① 已修复** — 根因修（保留用户要的 ✓/✓↩︎ 文本标记）：
  - `hibiki/assets/popup/popup.css`：内嵌 3.4KB `@font-face "Hibiki Symbols"`（DejaVu Sans 2.37 子集，仅 U+2713/U+21A9 + U+FE0E 零宽空字形，data: URI WOFF，零网络/零系统字体依赖；family 按 Bitstream Vera/DejaVu 许可改名，许可全文 `hibiki/assets/licenses/dejavu-fonts.txt` 并注册进 `AppModel.injectAssetLicenses`），插入 `.mine-button` 字体栈「桌面字体之后、`"Segoe UI"`/`sans-serif` 之前」：桌面三平台仍先命中系统符号字体（BUG-655 现状零回归，VS15 双保险保留），Android/任何 WebView 解析不到前面的桌面字体时命中内嵌字体，任何 ROM 稳定出形。
  - `tools/browser-extension/scripts/generate-content-css.mjs`：`@font-face` 显式 verbatim 透传（原逻辑对未知 document-level 规则抛错）；popup.css 同步到两份扩展 vendor 镜像并重新生成两份 content.css。
  - 提交：`e714731bc`
- **[x] ② 已加自动化测试** —
  - `hibiki/test/dictionary/popup_cards_nav_icon_guard_test.dart` 新增「内嵌 Hibiki Symbols 字形子集（TODO-1368/BUG-690）」组：对 5 份 CSS 镜像（3 份 popup.css + 2 份生成的 content.css）断言 ①`.mine-button` 栈序=桌面字体→Hibiki Symbols→sans-serif；②`@font-face` data:URI 存在且用独立 Dart WOFF/cmap format-4 解析器验证内嵌字体**真含** U+2713/U+21A9/U+FE0E 字形（不是只查字符串）。
  - 提交：`e714731bc`
- **备注**：候选方案 A「字体栈前置 Android 可按名解析的 family」被实证排除——Roboto cmap 无 U+2713/U+21A9，且 Android 无任何「一定按名可解析且一定含该码位」的系统 family；纯 SVG 方案此前已被用户显式否决（TODO-1325 还原为文本标记）。故取「内嵌字形子集」＝文本标记观感不变 + 字形随 CSS 自带。
