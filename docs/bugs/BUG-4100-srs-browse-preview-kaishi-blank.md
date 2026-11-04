## BUG-4100 · Kaishi（Anki 卡型）卡在浏览器预览中空白，根因未定位
- **报告**：2026-11-05（PR #2844 审查反馈：浏览页选中 Kaishi 1.5k 入门卡组 / 从 Anki 导入的卡型的卡片时，右侧预览区整块空白；同一张卡在复习页能正常显示）
- **真实性**：⚠️ 已登记、**根因未定位**，尚未在本机复现，不判真伪。现象只出现在走整面 WebView 的 Anki 卡型（Kaishi 不是内置 Fushi 卡片，`SrsRenderedCard.fushiCardDefinitions == null`，按 BUG-4059 的判据预览走 `srsCardFaceBuilderProvider` → `SrsWebCardFace`）。嫌疑点（均未证实）：
  1. `fushi/lib/src/pages/implementations/srs/srs_card_face.dart` 的下发链路里有几处静默 `return`，任何一处命中都会让这一面不上屏且不留痕：`_flush` 开头 `if (!_ready || doc == null) return;`（外壳未就绪时只等 onLoadStop 重放，若外壳就绪回调没再来就永远空白）；`evaluate(...).then` 里 `if (generation != _generation) return;`；`result == false` 分支 `if (_reloadedShell) return;`（外壳已重载过一次后页面再次不是外壳，直接放弃，既不重载也不记日志）。
  2. 平台原生纹理未出帧：预览区是浏览页里新建的平台视图（Windows 上是 WebView2 纹理），脚本 `srsCardFaceCallsScript` 返回 `true` 后纹理仍可能没有提交第一帧（尺寸为 0 / 不可见时创建、之后不重绘），Dart 侧认为已下发、实际屏上无像素。
  3. 卡型模板本身：Kaishi 模板带自有 CSS / 脚本，若页内脚本把 `.card` 隐藏或抛顶层异常（Windows 上顶层异常返回 `null`，走 `invalidate()` 会留 `SrsWebCardFace.setCard` 日志——复现时先查这条日志可排除或确认此项）。
- **与 BUG-4005 的区别**：BUG-4005 是 sync2 同步操作去重（`Body::Dedup`，原生 `fushi_fsrs` 同步协议），与卡面渲染无关；本条只涉及浏览预览的卡面显示。
- **与 BUG-4059 的区别**：BUG-4059 是内置 Fushi 卡片在预览里走了整面 WebView、和复习页原生卡面**不一致**（已修，按 `fushiCardDefinitions` 分流）；本条是非 Fushi 的 Anki 卡型在预览里走整面 WebView 时**完全空白**，不是版式差异，BUG-4059 的修复不覆盖这条路径。
- **[ ] ① 未修复** — 待复现后沿上述嫌疑点定位根因再修；不允许用延迟重试 / 强制重载掩盖。
- **[ ] ② 未加自动化测试** — 定位后在最强可落地层补（`SrsWebCardFace` 下发状态机的 widget 测试，或 Windows 离屏集成测试截像素）。
- **备注**：未做真机 / 桌面复现。复现步骤待补：导入 Kaishi 1.5k → 浏览页宽屏选中任一卡 → 看预览区，同时抓 `SrsWebCardFace.setCard` 日志。
