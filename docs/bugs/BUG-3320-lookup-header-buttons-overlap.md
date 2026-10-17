## BUG-3320 · 查词弹窗窄宽时按钮组压住词头
- **报告**：2026-10-13（用户：应用内反馈 ICrzgr8FsV「查词时文字与 ui 重叠」；Android 小米 23116PN5BC，411x914@3.5，竖排阅读，弹窗被挤成窄条）
- **真实性**：✅ 真 bug。`fushi/assets/popup/popup.css` 的 `.entry-header-main { flex: 1 1 0; min-width: 0 }`（10-09 给词头加右侧元数据列时引入）让 M3E 词头行 `flex-wrap: wrap` 的换行判定看到的左簇宽恒为 0，「词头 + 按钮组放不下就整组换行」从不触发：按钮组硬挤在同一行，把词头压到一个字宽，大字与注音画到按钮底下。headless Chrome 用改前 CSS 在 260px 宽复现（词头被压成「ご破」）。
- **[x] ① 已修复** — `html.fushi-m3e .entry-header-main { min-width: min-content }` 给左簇「词头放得下」的下限，放不下时按钮组整组换到下一行（仍右对齐），放得下时左簇照旧吃满剩余宽度；`html.fushi-m3e .entry-header` 声明 `container-type: inline-size`，`.expression-scroll` 用 `max-width: 100cqw` 把超长词头封顶在整行宽、仍横向滚动。自适应优先级：先把元数据列换到词头下方，再换按钮组，词头本身不被挤压。扩展 content.css 已重新生成，两份 vendor 镜像同步。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_dict_style_1009_guard_test.dart`「narrow popup wraps the header buttons instead of covering the headword」。
- **备注**：不认容器单位的旧引擎（iOS 15 的 WKWebView）没有 100cqw 封顶，比整行还宽的注音词头会撑出卡片横向溢出（换行本身照常生效）；不能包 `@supports`，因为 `generate-content-css.mjs` 不处理嵌套 at-rule。按钮组换行后仍带着「与大字同一中线」的 margin-top，第二行与上方多约 20px 间距。
