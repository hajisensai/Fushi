## BUG-2245 · 浏览器嵌套查词没有按App保留父子弹窗层级
- **报告**：2026-09-07（用户明确要求浏览器嵌套查词与 App 相同，保留父子层，拒绝原地替换）
- **真实性**：✅ 真 bug。旧 `content.js` 的 `__fushiOnLinkClick → fushiRenderNested` 仅替换单一窗口内容，和 App `dictionary_page_mixin.dart:807–870` 的截后代/压子层契约不同。此前 BUG-2244 只修事件泄漏，没有修正错误的单窗口语义。
- **[x] ① 已修复** — 移除原地替换；`nested-popup-host.js` 管理父子栈，子层独立 iframe realm 复用共享 popup.js。父层 DOM、词条、滚动不重建；正文/链接开子层，父层普通正文只裁后代，Esc/关闭按钮退层，根窗外点击清栈。请求按父层身份和代次校验，关闭层不接收迟到结果，只有根层关闭恢复视频。父子通过专用 MessageChannel 通信。提交见本文件所在提交。
- **[x] ② 已加自动化测试** — `nested-popup-host.test.js`、`nested-popup-frame.test.js`、`nested-lookup.test.js` 与 `side-panel-lookup-on-page.test.js` 覆盖独立层、父窗保留、裁栈/回退、跨层上下文、异步取消与消息隔离。
- **浏览器验证**：本地 HTTP 夹具加载真实生产脚本与共享 renderer，模拟查词响应；实际点击 `日本語 → 言葉 → 意味` 得到三层，关闭最上层再 Esc 返回原父层，正文点击也新开子层，父词条仍为日本語，无页面错误。夹具仅替换扩展 origin 并提供 chrome API mock，不等同于已安装扩展/视频网站端到端验收；真实视频暂停路径仍待设备复测。
- **最终回归**：MessageChannel 版本重新执行三层展开、X/ESC逐层退出、点击父层正文仅裁子层；全部通过。扩展 Node 490 项通过（退出码 0）、共享 popup 行为脚本通过、镜像一致性通过。
