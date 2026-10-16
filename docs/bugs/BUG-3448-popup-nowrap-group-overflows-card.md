## BUG-3448 · 查词卡里词典 nowrap 词组整组画到卡片外
- **报告**：2026-10-16（用户：「这个字典出框了」，截图为日本語シソーラス 類語検索辞典「0231.06 山場」条目，`肝所　0412.05 ≪勘所（意味）≫` 一整行越出词典卡右缘约 115px；前一行 `詰所` 后面留有大片空白，这一组却整体被推到下一行）
- **真实性**：✅ 真 bug。根因 `fushi/assets/popup/popup.js` `setStructuredContentElementStyle`（及 `definition.js` 同名副本）把词典 structured-content 的 `whiteSpace: nowrap` 原样落到行内 span 上。`white-space: nowrap` 会让 `.glossary-group` 的 `overflow-wrap: anywhere`（BUG-1827）失效，CJK 原本到处可断的断点也被一并关掉。词组宽度一旦超过卡片宽度，就只能整组越界。masonry 卡片是 `position:absolute` 加 JS 硬设的 `width`，撑不大。
  - 证据：从截图的排版特征推断，这一组是「整组换行」的原子单元。CJK 文本只有在 nowrap 下才会出现这种表现。本机这本词典在排查期间已不在 `dictionaryResources` 下，**没有拿到它的原始 structured-content JSON**。
  - headless Edge 实测（载入**完整** popup.css，词典卡 `position:absolute; width:300px`，用 `getClientRects()` 逐片段测量右缘与卡片内容盒之差）：
    | 形态 | 结果 |
    |---|---|
    | 未修：`<span style="white-space:nowrap">` | 整组单片段换到下一行，越界 **+132.92px**，与截图一致 |
    | 已修：`display:inline-block; max-width:100%` | 越界 **0px**，组内折成 2 行；`急所`/`触り` 等短组仍整组同行 |
- **[x] ① 已修复** —— 行内节点（`span`/`a`）带 `whiteSpace: nowrap`，且词典没有显式给 `display` 时，改写为原子 `display:inline-block; max-width:100%`，并去掉 nowrap，改继承父级 white-space。效果：放得下时整组换行，保留「这组别拆开」的本意；比一整行还宽时才在组内折行。块级标签上的 nowrap，以及词典显式给了 `display` 的节点保持原样。`popup.js` 与 `definition.js` 两处同改，三份 popup.js 镜像已同步。
- **[x] ② 已加自动化测试** —— `fushi/test/pages/popup_glossary_link_scope_test.js`（由 `popup_glossary_link_scope_test.dart` 驱动），新增 span/a nowrap 组改写、显式 display 不动、块级 nowrap 不动三组断言。变异实测：去掉修复后测试变红。
- **备注**：未在真 app 内用原词典复测（词典已不在本机）。块级 nowrap（div/li）若遇到同类超宽内容仍会出框，本条没有处理，等遇到真实样本再说。
