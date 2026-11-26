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
    无脚本的静态释义走 `handleGlossaryAnchorClick`（约 11071 行）也是同样的回查。
- **[x] ① 已修复** —
  - 辅助脚本：取词 / 链接判断挪到 **window 冒泡阶段**（晚于词典挂在元素与 document 上的全部监听）；
    捕获阶段起一个 `MutationObserver`，冒泡到 window 时 `takeRecords()`——`dictScriptReacted`（约 4423 行）
    只要发现这次点击派发期间被点元素、其祖先（`<html>`/`<body>` 除外）或后代被词典脚本改过，就认定词典已
    接管、不报查词。只认同一祖先链，避免「每次点击都改别处」的全局监听把整本词典的点词查词废掉。
  - 页内跳转 `#id` / MDict 的 `entry://#id`：沙箱内报新消息 `scroll`（目标在 frame 内的纵坐标），父页面
    `__dictSandboxHandleMessage`（约 4546 行）经 `scrollPopupToElementOffset` 滚到可视区顶端（要求用户激活，
    不占动作节流）；静态释义在 `handleGlossaryAnchorClick` 里只在被点的词典块内找目标滚动。找不到目标就
    不动，不再回查链接文字。`entry://word#id`（指向别的词条）仍按交叉引用回查。
  - 浏览器扩展外层 `dict-frame.js`（两份）白名单加 `scroll`，只转纵坐标并封顶。
- **[x] ② 已加自动化测试** —
  - `fushi/test/pages/popup_dict_sandbox_harness.mjs` 场景 12：真 Chrome 里装生产辅助脚本 + 仿 OALDPE 的
    词典脚本（document 委托的词性切换、元素上的折叠监听、一个每次点击都改别处的全局监听），依次点
    verb / 折叠标题 / Idioms 跳转 / 交叉引用 / 正文，断言只出 `scroll`、`link:champion`、`select:keep`，
    且词典的切换与折叠照常生效。场景 13：父页面收 `scroll` 后滚到位；静态释义点 `#id` 滚到目标且零回查。
    `popup_dict_sandbox_test.dart` 场景计数 11 → 13。
  - `tools/browser-extension/dict-script-sandbox.test.js`：外层 frame 转发 `scroll` 只留纵坐标、封顶、丢非数值。
- **备注**：
  - Fushi 推荐词典清单里没有 OALDPE；群里流传的 lng 版 OALDPE10.zip 是 Yomitan 格式，按词性拆成多条，
    本就没有切换控件。本 bug 只涉及 MDX 版。
  - 词典脚本若异步（`setTimeout` 之后）才改 DOM，仍会被判为「没反应」而查词——只能靠同步变动判断。
    同理，点**当前已选中**的那个词性（脚本重设同样的 class、DOM 实际没变）会照旧查这个词。
  - 本机这个会话里 headless Chrome 起不来（Git Bash / PowerShell / dist 外包三条路都是 `chrome exited before
    DevTools was ready (code 0)`，与改动无关），场景 12 / 13 交 PR CI 跑；本地另用 jsdom 装生产辅助脚本做了
    新旧对照：旧版 7 次点击全部报查词（`select:verb`、`select:Verb`、`link:Idioms`…），新版只剩
    `scroll`、`link:champion`、`select:keep`，词典切换与折叠照常生效。
  - 真词典的 `oaldpe.js` 在 `.mdd` / 散文件里，本机只有 `.mdx`，未在 app 里用真脚本跑过；行为由场景 12 的
    仿制脚本覆盖。
