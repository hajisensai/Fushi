## BUG-3980 · 浏览器 Netflix 观看页先在网页里建会话再交给播放器，同账号双会话
- **报告**：2026-11-02（用户反馈 G-Vr-zkb5L）
- **真实性**：✅ 真 bug（交接时序已验证；Netflix 限流是推测）（根因 `fushi/lib/src/web_browser/features/play_in_fushi/play_in_fushi_feature.dart:103-117` 交接挂在 onUpdateVisitedHistory，地址已提交、SPA 已进 /watch 并开始建播放会话后才 _openPage）
- **[x] ① 已修复** — 新增 document-start 脚本 `kWebBrowserWatchHandoffScript`（仅有播放页的平台、仅 Netflix 域）：捕获阶段拦指向 /watch/ 的链接点击、文档本身是观看页时先 window.stop()，经 JS handler `fushiHandoffWatch` 交给 Dart，在导航提交前交接；Dart 判据 `webBrowserShouldHandOffWatchPage` 与地址提交后的兜底共用；交不了（无痕 / 无播放页）时脚本带一次性 sessionStorage 放行标记整页前往。onUrlChanged 仍保留为脚本 pushState 等拦不到路径的兜底（分支 claude/review-merge-bug-fixes-b183d4，未提交）
- **[x] ② 已加自动化测试** — `fushi/test/web_browser/web_browser_watch_handoff_script_test.dart`（node 真执行脚本：点击取消并交接、交不了时放行、整页观看页先 stop、放行标记 / 非观看页 / 非 Netflix 不拦；判据单测）
- **备注**：站点用脚本 pushState 进 /watch 的路径仍是地址提交后兜底交接（未拦 pushState：拦了 SPA 路由仍会渲染播放器）。未真机验证 Netflix 是否因此不再限流。
