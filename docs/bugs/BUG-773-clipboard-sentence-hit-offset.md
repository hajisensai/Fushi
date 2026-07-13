## BUG-773 · 剪贴板面板句子横幅整词高亮左移吞句首标点
- **报告**：2026-07-13（用户：截图 `『呪術廻戦 第1期』…`，查词 `呪術廻戦` 但高亮不对）
- **真实性**：✅ 真 bug。表面=桌面「剪贴板查词面板」(clipboard panel) 句子横幅整词高亮 `.global-lookup-sentence-hit`。
  根因=**坐标系错位**：`hibiki/lib/src/lookup/clipboard_panel_controller.dart:175` 把 `_rootHitStart=0`
  钉在**原始**句的第 0 字符（=句首 `『`），而 `_renderPanel`（原 `clipboard_panel_controller.dart:314`）
  用 `bestLength` 从该 0 位铺高亮。但 `bestLength` 是引擎在
  **归一化（首尾标点已剥离）后**的串上量出的匹配长度（`app_model.dart` `normalizeSearchTerm`
  用 `_punctuationRegex=^[\p{P}\p{S}]+|[\p{P}\p{S}]+$` 剥掉句首 `『`，引擎才从 `呪術廻戦…` 的 0 位
  匹配、`bestLength=4`）。两端坐标系差一个被剥的句首 `『`：高亮从 `『` 起铺 4 码点 = `『呪術廻`
  （吞了 `『`、缺了词尾 `戦`），而不是 `呪術廻戦`。popup.js 逐字上色见 `hibiki/assets/popup/popup.js:3193-3199`。
- **[x] ① 已修复** — `2fb?`（见提交）。修复=把整词高亮起点从「句首第 0 字符」右移「归一化剥掉的句首标点长度」再从真正词首量 `bestLength`：
  - `hibiki/lib/src/models/app_model.dart`：新增纯函数 `leadingPunctuationStripUnits(raw, punctuationRegex)`（返回句首被剥 UTF-16 长度，复用同一 `_punctuationRegex`=单一真相）+ AppModel 公开包装 `lookupLeadingStripUnits`。
  - `hibiki/lib/src/lookup/clipboard_panel_controller.dart`：新增纯函数 `rootHitRange({query, baseStartCp, leadingUnits, bestLength})`，起点=`baseStartCp + 句首剥离码点`、长度=从词首起量 `bestLength`（复用 `hitLengthCodePoints` 钳位）；`_renderPanel` 改用它；删除多余的私有 `_hitLengthCodePoints` 包装。
  - 点字后缀路径（`_lookupFromBanner`，`_rootHitStart=i`）同链受益：后缀句首标点也补偿。
- **[x] ② 已加自动化测试** — 纯逻辑单测（最强可落地层）：
  - `hibiki/test/lookup/clipboard_panel_controller_test.dart` group `rootHitRange`：5 例，含复现用例「`『呪術廻戦 第1期』…` + leadingUnits=1 + bestLength=4 → start=1,length=4=`呪術廻戦`」、无标点零回归、点字 baseStartCp 叠加、代理对码点折算、越界/空串钳位。
  - `hibiki/test/models/app_model_search_pure_logic_test.dart` group `leadingPunctuationStripUnits`：5 例，含与真实 `normalizeSearchTerm` 句首移除量一致性校验。
  - 全部通过：`flutter test test/models/app_model_search_pure_logic_test.dart test/lookup/clipboard_panel_controller_test.dart` → All tests passed (52)。
- **备注**：`bestLength` 假定=4（`呪術廻戦` 词条长度，大辞泉第二版有此见出）。若真机上高亮**长度**仍越出 `呪術廻戦`（吞到 `第1期』`），那是引擎匹配长度 `bestLength` 本身过大（另一层：远端/词典把标题当长词条），与本坐标系修复无关，届时另立 bug。桌面真机复测（剪贴板复制含句首 `『「（` 的句子→面板高亮对齐词本身）留待用户验收。
