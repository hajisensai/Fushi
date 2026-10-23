## BUG-3663 · 应用内浏览器地址栏把本机 / 局域网网址当成搜索，站点也不能手动添加编辑
- **报告**：2026-10-21（应用内反馈 5wWlKU_Rir，macOS 3.0.0-debug.20585：输入 `http://localhost:55000/texthooker` 跳转成 Bing 搜索；追加：不能手动添加或编辑站点）
- **真实性**：✅ 真 bug。`parseWebBrowserAddress`（`fushi/lib/src/web_browser/web_browser_sites.dart`，原 `if (uri.host.isEmpty || !uri.host.contains('.')) return null;`）要求主机必须带点，连用户明写了 `http://` 的 `localhost` / `nas` / `[::1]` 也判「不像网址」，`resolveWebBrowserInput` 随即交给搜索引擎；同一判据也让此类站点书签在 `WebBrowserSite.fromJson` 回读时被丢弃。入口页站点只能从浏览页「加入站点」进来，长按只有删除，没有添加 / 编辑入口。
- **[x] ① 已修复** — 写了 http(s) 协议时任何非空主机都直接打开；没写协议时域名 / IPv4 / `[IPv6]` / 带端口或路径的 `localhost` 算网址（回环与 IP 字面量补 http，其余补 https），裸单词仍搜索。入口页「站点」标题旁加「添加站点」，长按 / 右键站点改为「编辑 / 移除」菜单（地址 → 名称两步输入，地址与地址栏同一份判据校验），`replaceWebBrowserSite` 原位替换、撞 URL 不产生重复。
- **[x] ② 已加自动化测试** — `fushi/test/web_browser/web_browser_sites_test.dart`（本机 / 局域网地址解析、编辑替换与偏好往返）；`fushi/test/pages/fushi_web_browser_page_redesign_test.dart`「手动添加本机地址站点，再长按编辑名称，写穿偏好」。
- **备注**：macOS WKWebView 的 ATS 对 IP / 无点主机名 / `.local` 豁免，明文本机地址可加载；未真机复测。
