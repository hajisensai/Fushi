## BUG-1878 · 查词弹窗底色被钉成纯白/纯黑，不跟随 MD3 主题
- **报告**：2026-08-26（用户：查词弹窗的背景颜色不对，之前抄的时候抄过头了）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/popup_theme_css.dart:38` 的
  `popupCardSurface()` —— 2026-08-23 的「弹窗窗体观感对齐 Niratan」提交
  `9ba9baea20` 把弹窗卡面从 `overrideDictionaryColor ?? scheme.surface`
  改成了硬编码纯白 `0xFFFFFFFF` / 纯黑 `0xFF000000`（照抄 Niratan
  `DictionaryPopupMaterial.GetOpaqueSurfaceColor`）。那是 Niratan 自己的色彩
  体系；Fushi 全应用走 MD3 种子色，实测种子 `#386A58` 的深色 `scheme.surface`
  是 `rgb(15, 21, 18)`，弹窗改纯黑后与它贴着的阅读器 / 视频页 / 设置页底色
  割裂。同提交的其余观感项（伴随投影窗、系统灰描边、悬停浮现滚动条）与底色
  无关，保留不动 —— 抄过头的只有这一条。
  影响四个注入点（都经该 helper）：`app_model.dart:2938`（浏览器扩展 theme
  下发）、`popup_settings_injection.dart:88`、`dictionary_popup_webview.dart:997`
  （主题变量重注）与 `:1418`（热槽初始 HTML）。
- **[x] ① 已修复** — `popupCardSurface` 回到 `override ?? scheme.surface`，
  用户手动指定的词典底色优先级不变；四个调用点的过时注释同步改正。单一真源
  helper 保留（BUG-688/736 的手抄漂移教训），只改取值。
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/popup_card_surface_follows_theme_test.dart`：
  真行为测试（直接调 helper + `buildPopupThemeCssVars`），不是源码扫描。含一条
  前置断言钉住「种子主题的 surface 确实是 tinted」，防止 fromSeed 恰好给纯白
  时整个文件假绿。**变异实测**：把纯白/纯黑写回 helper → 3 条测试红
  （`rgb(0, 0, 0)` vs 期望 `rgb(15, 21, 18)`）；还原后 sha256 与变异前一致。
- **备注**：popup.css 里 `html[data-theme]` 块的 `--background-color: #fff/#000`
  是**宿主不注入时的兜底**（只有 Android 原生弹窗走到），在这次「抄 Niratan」
  之前就存在，不属于本 bug，未改动。
