## BUG-1063 · app 外查词浮窗点已制卡 ✓ 无反应（重复卡操作面板被 native 降级成 null）
- **报告**：2026-07-24（用户：qqbotxiaoxiao，原话「这里app外重复制卡点击没反应……主页这里可以」，
  两张附图：app 外剪贴板查词浮窗点右上 ✓ 毫无反应；app 内查词页同一操作正常弹出
  「卡片已在 Anki 中 → 覆写 / 新增为重复卡」对话框）
- **真实性**：✅ 真 bug，是一次显式降级留下的**静默**缺口，不是偶发。
  - `hibiki/windows/runner/global_lookup_window.cpp:1393`（改前）——app 外的裸 WebView2 窗口
    （剪贴板面板 + 瞬态查词窗共用）把 popup.js 的九根桥里的八根 DEFER 给 Dart，唯独
    `minedCardAction` 不在名单里，落进下面的「立即 `__hibikiBridgeResolve(id, null)`」分支。
    原注释写明了理由：那个操作面板是 Flutter 层的，主窗在外部程序后面（甚至最小化），
    弹出来也看不见，所以 app 外只保留 ✓↩ 原地覆写。
  - `hibiki/assets/popup/popup.js`（改前 2249 行附近）——`dataset.mined === '1'` 分支
    无条件 `await minedCardAction(...)`，把回来的 `null` 交给 `parseMineResult` 得到
    `{ankiConnect:false, noteId:null}`，接着 `duplicateCheck` 仍回 true → `setMineState(true)`。
    即：**按钮态从 ✓ 刷新成 ✓，界面零变化**。降级本身可以理解，缺口在于降级后没有任何
    替代路径也没有任何反馈，用户看到的就是「点了没反应」。
  - app 内（图 2）走的是 `dictionary_popup_webview.dart` 注册的真 handler →
    `DictionaryPageMixin.onMinedCardAction` → `runAnkiMinedCardAction` → BUG-1040 的居中
    `AlertDialog`，所以同一次点击在主页正常。
- **[x] ① 已修复** — 不去改 minedCardAction 的降级前提（那个前提没变：app 外确实呈现不了
  Flutter 对话框，主窗抢焦点更会打断用户在游戏/网页里的沉浸），而是给这条车道补上它缺的
  **呈现层**：popup.js 在自己的 WebView 里画同一套选择。
  - `popup_settings_injection.dart` 注入 `window.__hibikiMinedCardActionNative = !globalLookup`
    ——「宿主自己有没有原生对话框」。app 内三个 dictionary_popup_webview 表面恒 true（行为
    逐字不变，BUG-1040 的对话框原样保留）；app 外裸窗恒 false；浏览器扩展不经此注入 →
    undefined → 同样走页内面板（它的 bridge-shim 对 minedCardAction 也只回 null）。
  - `popup.js`：`showMinedCardActionPanel` / `runInPageMinedCardAction`。面板视觉对齐 app 内
    AlertDialog（居中、圆角、420 宽、列表溢出自身滚动、右下「取消 / 新增为重复卡」）；
    点遮罩不关闭（有副作用的选择，与 `barrierDismissible: false` 一致），Esc 取消且**吃掉
    事件**，否则会冒泡把整个查词窗关了。命中为空（卡在别处被删）→ 不弹面板，直接按新卡
    重制，与 app 内 `matches.isEmpty → mineNew()` 同语义。
  - 数据与副作用仍全在宿主：新增两根 DEFERRED 桥 `findMinedMatches`（`repo.findMatchingNotes`）
    与 `openMinedNote`（`repo.openNoteInAnki`），实现在 `lib/src/lookup/overlay_bridge_handlers.dart`
    （两个表面共用同一权威 handler）；**覆写/新增复用既有的 `updateEntry` / `mineEntry`**，
    本修复不新增任何写路径。C++ 只把这两根新桥加入 deferred 名单。
  - 两个细节是必需的而非装饰：① `popup.css` 面板 `user-select: none`——面板里一旦产生原生
    选区，`selection.js` 会当成「用户选词」触发嵌套查词，在面板上叠出新卡片；②
    `html.mined-action-open{min-height:320px}`——瞬态查词窗的窗口高度被 host
    （`global_lookup_host.js measureAndReport`）收缩到卡片内容高度，矮卡片下 fixed 面板会被
    窗口下沿裁掉，面板打开期间撑最小高度，下一次测量即把窗口放大，关闭后恢复。
  - popup.js / popup.css 按三镜像纪律同步到两份 vendor，并重跑
    `tools/browser-extension/scripts/generate-content-css.mjs` 重新生成两份 content.css。
- **同一根因的第二个入口（用户追问「跳转的也没反应修复了吗」）**：✓ 旁边的 ↗
  「在 Anki 中打开卡片」按钮走的是**另一根桥** `openInAnki`（`popup.js` 的
  `openAnkiButton`），它同样不在 C++ 的 deferred 名单里、同样被立刻解析成 null——因为
  它同样要弹 Flutter 的多卡选择框 / toast。第一轮只修了 ✓，↗ 仍然是死的。补修：同一个
  `__hibikiMinedCardActionNative` 分流，app 外由 popup.js 就地按**与 app 内
  `openMinedCardInAnki` 相同的三分支**处理——无命中弹一次性提示（新增
  `showInlineHint`，样式与 `.audio-hint` 同一条规则，锚按钮屏幕坐标，故窗口被裁到卡片
  bbox 时也可见）、命中 1 张直接 `openMinedNote`（失败也提示，不假装成功）、命中多张弹
  面板的 `openOnly` 形态（只列卡片 + 打开，不带覆写/新增——那是 ✓ 的职责，与 app 内
  `showAnkiOpenNotePicker` 的单一语义一致）。无需新桥：复用第一轮加的
  `findMinedMatches` / `openMinedNote`。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/utils/misc/popup_asset_behavior_test.js` 新增四条 app 外行为用例（真跑
    popup.js）：点 ✓ 必须弹页内面板且**绝不**调用 minedCardAction、「新增为重复卡」走
    mineEntry、「覆写这张卡」走 updateEntry 且带正确 noteId、取消不写任何东西、命中为空时
    直接重制。既有的 app 内用例显式声明 `__hibikiMinedCardActionNative = true`，两条车道
    互不遮掩。
  - ↗ 那一半另有四条（同一文件）：单卡直开且不碰 openInAnki、多卡弹 openOnly 面板
    （不得混入覆写 / 新增重复卡）、无命中弹提示而非静默、app 内仍原样交给宿主。
    顺手修了 fake DOM 的一个真缺陷：`classList.add()` 会把构造时的 `className`
    整个覆盖掉（提示气泡淡入时 `inline-hint` 变成只剩 `visible`）。
  - `hibiki/test/pages/anki_mined_card_action_wiring_static_test.dart` 新增 BUG-1063 组源码
    守卫：popup.js 有面板与两根桥、C++ deferred 名单含两根新桥且
    **minedCardAction 仍不得纳入 deferred**、Dart 侧解析两根桥、注入按 `!globalLookup` 分流、
    popup.css 有面板样式 + 禁选 + 撑高规则。
- **备注**：**待用户真机复验**（Windows）：剪贴板浮窗 / 划词浮窗查一个已制卡的词 → 点 ✓ →
  面板居中出现且完整可见 → 覆写 / 新增重复卡 / 在 Anki 中打开 / 取消 四条各走一次；再回
  app 内查词页确认仍是原来的 Flutter 对话框（BUG-1040 行为未变）。
  ↗「在 Anki 中打开」同步复验：单卡直接跳 Anki、同词多卡弹只带「打开」的面板、
  卡已在别处删掉时弹一次性提示。
  浏览器扩展侧顺带受益（同样不再静默），但它的 `findMinedMatches` / `openMinedNote` 尚未在
  bridge-shim 转发，命中列表会是空 → 走「直接重制」分支；扩展要拿到完整面板需另给 server
  加对应端点，属独立跟进项，不在本次范围。
