## BUG-5522 · MDX 词典自带的词性切换 / 页内跳转点了只会查词
- **报告**：2026-11-26（群用户：OALDPE 与自己导入的 OALD10 顶部「词性切换」点不动，只会弹出查词窗口）
- **真实性**：✅ 真 bug。样本为真实 `oaldpe.mdx`（Hazuki 精装版 V2025.02.14）：多词性词条顶部是
  `<div class="oaldpe-nav"><span class="active">noun</span><span>verb</span><span>All</span></div>`，
  两个 `<div id="entryContent" class="oald oald-entry-root [visible]">` 分装各词性，切换全靠词条尾部的
  `oaldpe-jquery.js` + `oaldpe.js`；另有 `<a href="#record_idmgs_1">Idioms</a>` 这类页内跳转。
  带脚本的词条按 BUG-3762 进 `sandbox="allow-scripts"` iframe，点击由沙箱辅助脚本转给父页面：
  - `fushi/assets/popup/popup.js` `DICT_SANDBOX_HELPER_JS`（约 4334 行起）的取词监听挂在 **document 冒泡阶段**，
    且辅助脚本**排在词典脚本之前**注册——词典在 document 上委托的切换处理还没跑，它已经把被点的「verb」
    作为 `select` 报给父页面查词；词典脚本一般既不 `preventDefault` 也不拦传播，旧判据只认 `defaultPrevented`，
    拦不住。折叠块（`.unbox .box_title`）同病。
  - 同一处把一切非 `sound:` 链接都报成 `link`，父页面拿链接文字回查：`#record_idmgs_1` 被查成「Idioms」。
    无脚本的静态释义走 `handleGlossaryAnchorClick`（约 11100 行）也是同样的回查。
- **[x] ① 已修复** —
  - 辅助脚本：取词 / 链接判断挪到 **window 冒泡阶段**（晚于词典挂在元素与 document 上的全部监听），判据是
    「词典脚本**认领**了被点的控件」（`dictScriptClaims`），而不是「点完 DOM 变没变」——后者覆盖不到点
    已选中的那一项（切换是 no-op）和在定时器里才改 DOM 的脚本。辅助脚本排在全部词典脚本之前执行，先装好记录：
    ① 包装 `EventTarget.prototype.addEventListener` / `removeEventListener`，记下词典脚本在哪些元素上挂了
    点击类监听（click / mouse / pointer / touch 的按下抬起），外加 `onclick` 等属性；
    ② 包装 `Element.prototype.closest` / `matches` / `webkitMatchesSelector`，记录这次点击派发期间词典代码对哪些
    元素做过选择器判断并命中（原生委托）；jQuery 委托不走原生 matches（带 seed 的选择器由它自己的匹配器求值），
    按形状在全局里找 jQuery（兼容 `noConflict` 改名），读 `_data(…, 'events')` 里登记的选择器比对；
    ③ 词典 CSS 给控件设了 `cursor: pointer`，且不是从外层大容器继承来的。
    以上都只认被点元素自身或祖先里文字不超过 64 字的「控件」（`<html>` / `<body>` 除外），整条词条 / 释义容器上的
    总监听、每次点击都 closest 一个大容器的全局监听不算认领，正文点词照常查。此外保留 `defaultPrevented` 与
    「派发期间同步改了被点元素的祖先链 / 后代」（`dictScriptReacted`，MutationObserver）两条。
    链接本身就是控件（UA 给 `cursor: pointer`），认领判据只用于点词；链接只在词典 `preventDefault` 或同步改了它时
    不回查（`preventDefault` 状态在辅助脚本替链接 `preventDefault` 之前读）。
  - 页内跳转 `#id` / MDict 的 `entry://#id`：沙箱内报新消息 `scroll`（目标在 frame 内的纵坐标），父页面
    `__dictSandboxHandleMessage` 经 `scrollPopupToElementOffset` 滚到可视区顶端（要求用户激活，不占动作节流）；
    静态释义在 `handleGlossaryAnchorClick` 里只在被点的词典块内找目标滚动。找不到目标就不动，不再回查链接文字。
    `entry://word#id`（指向别的词条）仍按交叉引用回查。
  - 浏览器扩展外层 `dict-frame.js`（两份）白名单加 `scroll`，只转纵坐标并封顶。
- **[x] ② 已加自动化测试** —
  - `fushi/test/pages/popup_dict_sandbox_harness.mjs` 场景 12：真 Chrome 里装生产辅助脚本 + 仿 OALDPE 的词典脚本，
    依次点已选中的 noun（切换 no-op）、verb、折叠标题（监听在 `setTimeout` 里才改 class）、只靠 CSS pointer 的
    发音控件、Idioms 跳转、交叉引用、正文、继承大容器 pointer 的词；同时挂着「每次点击都 closest 大容器 / 改别处」
    的全局监听与根节点总监听。断言只出 `scroll`、`link:champion`、`select:keep`、`select:inherit`，且切换与
    折叠照常生效。场景 13：父页面收 `scroll` 后滚到位；静态释义点 `#id` 滚到目标且零回查。
    `popup_dict_sandbox_test.dart` 场景计数 11 → 13。
  - `tools/browser-extension/dict-script-sandbox.test.js`：外层 frame 转发 `scroll` 只留纵坐标、封顶、丢非数值。
- **备注**：
  - Fushi 推荐词典清单里没有 OALDPE；群里流传的 lng 版 OALDPE10.zip 是 Yomitan 格式，按词性拆成多条，
    本就没有切换控件。本 bug 只涉及 MDX 版。
  - 认领判据认不出的写法：委托监听挂在 document / 大容器上、**不用选择器**（比如 `classList.contains`、比
    `tagName`）认目标，同时不改 DOM 或延迟才改、控件也没有 `cursor: pointer`——这种点了仍会查词。
  - 反方向的代价：词典脚本若在**短文字**元素上挂了点击监听、或用选择器认它，那个元素上就不再点词查词
    （例如给例句里的单个词挂了点击发音）。这是按「词典把它做成了控件」处理。
  - 本机这个会话里 headless Chrome 起不来（Git Bash / PowerShell / dist 外包三条路都是 `chrome exited before
    DevTools was ready (code 0)`，与改动无关），场景 12 / 13 交 PR CI 跑。本地用 jsdom 装生产辅助脚本做了
    新旧对照，另用真 jQuery 3.7.1（`noConflict` 改名，document 与大容器上的委托、元素直绑 + 异步、全局总监听）
    验过：旧版每次点击都报查词；新版只剩正文点词、交叉引用回查与页内跳转滚动，切换与折叠照常生效。
  - 真词典的 `oaldpe.js` 在 `.mdd` / 散文件里，本机只有 `.mdx`，未在 app 里用真脚本跑过。
