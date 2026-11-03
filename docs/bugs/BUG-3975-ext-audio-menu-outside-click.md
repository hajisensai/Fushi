## BUG-3975 · 浏览器扩展：右键音频源菜单点选项即关查词窗、不播放
- **报告**：2026-11-02（用户反馈 fWIaHFV1qD）
- **真实性**：✅ 真 bug（根因 `tools/browser-extension/content.js` document capture mousedown 外部点击判据只认 fushiHost / 缩放把手 / 上下文模态（旧 3678-3693 行）；音频源菜单宿主 `#fushi-audio-menu-host` 由 `fushi/assets/popup/popup.js` `__fushiAudioMenuMount`（5021-5045）建在 documentElement 下、与 fushiHost 平级，事件被当成外部点击 → fushiRemoveContainer + 吞 click）
- **[x] ① 已修复** — 外部点击 / 悬停离开判据收成一个归属谓词 `fushiIsLookupSessionTarget`（composedPath，缺席时沿 parentNode/shadow host 上溯），只认属性 `data-fushi-session-host`；fushiHost、缩放把手、上下文模态（content.js）、递归查词子层（nested-popup-host.js）、音频菜单宿主（assets/popup/popup.js → 两份 vendor）建宿主时统一打标。两份扩展副本经 `scripts/sync-mirrors.mjs` 同步（分支 claude/review-merge-bug-fixes-b183d4，未提交）
- **[x] ② 已加自动化测试** — `tools/browser-extension/audio-menu-outside-click.test.js`（真 content.js + 真 __fushiAudioMenuMount，菜单项 mousedown→click 不关窗且 click 送达；点页面仍关窗吞击）；`hover-leave-resume.test.js` / `sentence-context-modal.test.js` 测试 DOM 的属性改为真存
- **备注**：键盘 Enter 选项不经 mousedown，本来不受影响。未在真浏览器复测。
