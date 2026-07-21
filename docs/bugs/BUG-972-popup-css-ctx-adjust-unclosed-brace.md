## BUG-972 · popup.css .ctx-adjust-button 缺闭合括号吞掉 .global-lookup-ext-hit 高亮规则
- **报告**：2026-07-21（agent 在做墨水屏适配（PR eink-mode）审读 popup.css 时自查发现，非用户报告）
- **真实性**：✅ 真 bug。根因 `hibiki/assets/popup/popup.css`（修复前尾部 `.ctx-adjust-button` 规则）：该规则只写了 `{ opacity: 0.85;` 没有闭合 `}`（全文件 167 个 `{` vs 166 个 `}`）。CSS 错误恢复把随后的 `.global-lookup-ext-hit { background: …; border-radius: 2px; }` 整条当作无效声明消费掉，最后的 `}` 被用来闭合 `.ctx-adjust-button`——净效果是「面板释义区被点击、正在外部瞬态窗里查的那段文字的高亮」（markGlobalLookupExtHit）从未生效。三镜像（两个 vendor popup.css + 生成的 content.css）同样受影响。
- **[x] ① 已修复** — 给 `.ctx-adjust-button` 补上闭合 `}`，`.global-lookup-ext-hit` 规则恢复；同步两个 vendor popup.css 并重跑 `generate-content-css.mjs` 重生成两份 content.css（与墨水屏模式同一提交，分支 worktree-eink-mode）。
- **[x] ② 已加自动化测试** — `hibiki/test/build/popup_css_eink_guard_test.dart` 的「popup.css braces are balanced (swallowed-rule guard)」：剥注释后断言 `{`/`}` 计数配平，这一类「少个括号、静默吞掉后续规则」直接翻红。
- **备注**：原以 BUG-969 创建，与 PR#312（阅读设置抽屉 120fps）的 BUG-969 撞号后改号 972（PR#312 占 969、develop 已占 970/971；提交信息里的 969 指本条）。括号配平只能挡「数量不平」型；同数量但错位的嵌套错误仍需靠 review。
