## BUG-3765 · dictionary-content-network-egress
- **报告**：2026-10-23（用户：开放用户提交词典前的安全审计）
- **真实性**：✅ 真 bug。词典内容能让查词弹窗向任意外部地址发请求（每次查词都泄露查了什么词 / 可做追踪）：`fushi/lib/src/pages/implementations/dictionary_webview_media.dart` `dictionaryMediaWebResourceResponse` 对不认识的 URL 返回 null 即放行真实网络；`dict-media.js` `constructDictCss` 原样透传 `@import` / `url()`；`popup.js` `setStructuredContentElementStyle` 不过滤 `backgroundImage`；HTML 释义的 `<img src="https://…">` 原样保留。
- **[x] ① 已修复** — 在内容层切断（`popup.js`：`stripDictCssRemoteRefs` 作用于词典 styles.css、导出卡片 CSS、内联 `<style>` 与 `style` 属性；结构化内容 style 拒 `url(` / `image-set(` / `expression(`；`sanitizeDictElementAttributes` 删除指向外部的自动请求属性；沙箱 iframe CSP `default-src 'none'`）。**刻意不在原生拦截器拦 http(s)**：弹窗自己 `new Audio(远程 URL)` 播在线发音，一刀切会拦死这条合法路径。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_dict_sandbox_test.dart`（场景 1/2/5：结构化内容外部背景图、HTML 外部 img / style url、styles.css 的 `@import` 与外部 `url()` 被剥，本地 url 保留；去掉 CSS 剥离的变异会打红）。
- **第二轮（独立审查）**：内容层过滤被 CSS 转义、`image-set`、`imagesrcset`、`.mdd` 样式表绕过——正则追不完。补主文档 CSP（popup.js 加载时插 meta）：img/style/font 只认本机来源、`frame-src 'none'`；`media-src` 额外放行 http(s)，因为桌面 / iOS 的在线发音在弹窗里 `new Audio(远程 URL)`。回归：场景 8（页面与攻击者不同源的 http 服务，6 种写法零请求）。
- **备注**：主文档 CSP 不管 script-src（见 spec「已知未做」）。
