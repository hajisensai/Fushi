## BUG-4007 · 复习卡背面释义展开后底部被截断且其他词典消失
- **报告**：2026-11-04（开发者反馈 #1b5vbu96Ts，标题「展开以后底部被截断了，而且其他字典没了」，Android OnePlus CPH2747 363x792@3.5，3.3.0-debug.23261；正文空。截图第二轮单独导出）。
- **真实性**：✅ 真 bug（代码路径已证实，未上真机）。
  - **截图纠正了第一轮的猜测**：截图 `1b5vbu96Ts_s0.png` 里**没有查词弹窗**。画面是 Fushi 卡片窄版式背面：释义 WebView（主词典「払う」已展开，⑦ 一行在半行处被硬切）下面紧跟原生页脚「来源」。即被截断的是**卡面释义区**，「其他词典没了」是它们在截断线以下。第一轮沿查词弹窗自适应高度链去找，方向错了。
  - **根因**：窄版式释义 WebView 的高度跟内容走（页面上报 `onContentHeight`），超过 `kSrsDefsMaxInlineHeight`（4800）就改成一屏高，打算让 WebView 内部滚动（`fushi/lib/src/pages/implementations/srs/srs_fushi_card_view.dart:1223-1226`）。但纵向拖的归属只看「有没有 `onContentHeight`」：
    - `srs_fushi_card_view.dart:1127` 窄版式恒传 `onContentHeight: _onDefsHeight`；
    - `fushi/lib/src/pages/implementations/srs/srs_card_face.dart:2240` 据此 `scrollsInPage: widget.face.onContentHeight == null`，结果为 false；
    - `srsCardFaceGestureRecognizers`（`srs_card_face.dart:218-230`）在 false 时**不认领** `VerticalDragGestureRecognizer`。

    所以切到「一屏高」以后，触屏纵向拖全被外层 `SingleChildScrollView` 赢走，WebView 的 scrollTop 永远是 0。用户只能看到释义前一屏高，后面的主词典余文和全部其他词典都够不着。桌面滚轮不受影响，页内能原生滚动。「展开」（主词典展开 / 其他词典全部展开）是把内容推过 4800 的那一步。
  - 现有测试 `fushi/test/srs/srs_fushi_card_view_test.dart:354` 只断言超限后高度变成一屏（844），没有断言此时 WebView 能被拖动，所以漏掉了。
- **[ ] ①** — 未修。需要先定嵌套滚动方案（见备注），本轮不擅自定。
- **[ ] ②** —
- **备注**：
  - **为什么不能只认领纵向拖**：WebView 一屏高、认领纵向拖之后，手指落在它上面时外层不再滚动，原生页脚（来源 / 词频）在用户把 WebView 拖到正好铺满屏幕后就够不着了，等于把截断从 WebView 内部挪到了页脚。
  - **为什么上限不能简单去掉**：363 逻辑宽 × 3.5 dpr 下，4800 逻辑高已是 16800 物理像素，超过常见 GPU 最大纹理边长 16384，这是上限存在的理由。
  - **可选方案**（需拍板）：
    - (a) 超限态认领纵向拖，WebView 高度取「视口 − 可抓取余量」，并把页内滚到底 / 顶的 overscroll 转交外层（页内脚本回报，宿主 `_scroll.jumpTo`，与现有 `onWheel` 同一条桥）；
    - (b) 超限态不放 WebView 内滚，改由外层滚动驱动页内 `scrollTo`（WebView 用 sticky 视口窗口，跟随外层偏移）。
  - 方案定了以后，测试层：widget 测试断言超限态 `scrollsInPage == true` 与 overscroll 转交；Android 真机复测原始路径（长词条 + 其他词典全部展开）。
