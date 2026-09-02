## BUG-2063 · 词典自带的 JS 从不执行
- **报告**：2026-09-02 / 09-03（用户：NLT 词频的「頻度」列在欧路里是条形图、我们只有裸数字；OALDPEX「js css 文件没有起效」）
- **真实性**：✅ 真 bug — MDX 词典的条目 HTML 是一个完整网页片段，自带 `<link>` 和 `<script>`。样式表走 `styles.css` 内联注入（见 [[BUG-2052]]），脚本则**完全不执行**：渲染路径是 `fushi/assets/popup/popup.js` 的 `wrapper.innerHTML = rewriteDictLinks(content, dictName)`，而**经 `innerHTML` 解析出的 `<script>` 元素被标记为 "already started"，既不执行也不 fetch `src`**（HTML 规范）。所以这类词典在我们这里只剩一个没有交互的骨架。

  两本真实词典的形状：
  - NLT 词频：`<script src="NLT.js">`，脚本读 `td span.rank` 的值把 `td span.freq` 包成 `.freq-container`/`.freq-bar` 条形图。**这是欧路那张截图里绿色条的全部来源**。
  - OALDPEX：一条词条挂 7 个 `<script>`（`scripts/oaldpex-jquery.js` 在 .mdd 里，`oaldpex.js` 是 .mdx 旁的散文件，另有内联段），驱动整套配置界面与中文翻译显示开关。

  直接放回全局作用域**不是**修复：词典脚本按「一个条目 = 一个独立文档」写，NLT 那份直接 `document.querySelectorAll('tr')`，在我们这种把多本词典塞进同一个弹窗文档的宿主里会把**别的词典的表格一起改掉**。而且弹窗是长驻页面，`DOMContentLoaded` 早已过去，照原样注册等于永远不触发——MDict 生态里几乎每份脚本都把入口挂在那上面。

- **[x] ① 已修复** — 分两层：

  **native（资源通道）**：`<script src>` 指名的兄弟 `.js` 此前无处可取。`importer.cpp` 把 `extract_linked_css_names` 泛化成 `extract_referenced_names(tag, attr, ext)`，据此收集条目实际引用的兄弟脚本，经 `import_mdd_into` 的新 `extra_files` 参数并入**同一个媒体库**——于是 .mdd 内的文件和 .mdx 旁的散文件对上层是一条按名取的通道。zip 导入白名单同步放宽到 `.js`。只接受纯文件名（`is_plain_file_name`），带子目录的引用（`scripts/oaldpex-jquery.js`）交给 .mdd。

  **popup（执行）**：`dict-media.js` 新增 `runDictScripts(root, dictName)`，在 `createGlossarySection` 组完该词典的 wrapper 后调用：
  - 源码经新 bridge handler `getDictAsset` 按需取（`dictionary_popup_webview.dart`，只放行 `.js`），并按 `(dict, path)` 缓存——OALDPEX 的脚本 210KB 起步，随每次查词内联就是 [[BUG-1868]] 那条老路。
  - 每份脚本在 `createScopedDocument(root)` 下运行：`querySelector*` / `getElementById` / `getElementsBy*` / `body` / `documentElement` 全部重定向到本词典子树，`DOMContentLoaded`/`load`/`readystatechange` 立即（微任务）回调，`readyState` 报 `complete`；其余属性经 `Proxy` 透传真 document，所以 jQuery 这类通用库照常工作，只是选择器看到的世界缩小到这本词典。
  - 同一词典块的多段脚本**拼成一段**编译执行（同文档多个 `<script>` 共享全局作用域，前段的 `var oaldpexConfig = …` 后段要看得见），每段各自包 `try`，一段出错不带走其余段；编译结果按代码串缓存，避免每个词条重新解析 210KB。
  - 执行完摘掉 `<script>` 节点；每个 wrapper 只跑一次。

- **[x] ② 已加自动化测试** — `tools/browser-extension/dict-script-exec.test.js`（`node --test`，零依赖，手搓最小 DOM + `vm.runInContext`，与既有 `dict-media.test.js` 同款）。10 条断言：内联执行、经 bridge 按 `(dictionary, path)` 取 src、DOMContentLoaded 会触发、**不能碰到另一本词典的行**、多段共享作用域、缺失资源跳过后续仍跑、抛错不阻断后续、每块只跑一次且 script 节点被摘除、源码只取一次、`document.body` 是词典块。

  native 侧：`native/fushidicts/tests/mdx_sibling_script_media_test.cpp`（兄弟脚本进媒体库、.mdd 脚本不回归、没被引用的脚本不收、无 .mdd 的词典也要建库）。

  变异实测（三条各自精准命中，其余不受影响）：① 作用域 `root.querySelectorAll` → `document.querySelectorAll`：8 条红（含「不能碰另一本词典」）；② 拼接改成每段独立 IIFE：只有「共享作用域」红；③ 去掉 DOMContentLoaded 特判：只有该条红。native 侧把 `extract_linked_script_names` 换成空列表 → `mdx_sibling_script_media_test` 报「兄弟脚本不在媒体库」+「无 .mdd 的词典没建库」。

- **备注**：
  - 扩展镜像（`tools/browser-extension/vendor/`）里没有 `window.flutter_inappwebview`，`fetchDictAsset` 返回 null，于是 src 脚本不执行、内联脚本照常执行——优雅退化，不是回归。扩展有自己的 http 媒体端点，将来若要支持可以接到那条通道上。
  - **踩坑记录**：`dict-media.js` 的 vendor 版是 assets 版的**超集**（275 行 vs 175 行，多出扩展专用的 http 媒体端点分支），两者不是镜像关系——`sync-mirrors.mjs` 只在两个 vendor 之间同步，assets→vendor 必须手动移植。一次性 `cp` 覆盖会删掉 `installDictMediaPlaceholderResolver` 等扩展函数并让 `side-panel-lookup-on-page.test.js` 红。
  - 真机未验证：条形图/配置界面在真实 app 里的最终观感未跑过，逻辑层由上述 10 条行为测试覆盖。
