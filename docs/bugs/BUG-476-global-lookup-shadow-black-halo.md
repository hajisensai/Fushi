## BUG-476 · 全局查词覆盖窗圆角外黑边(非分层WebView2下box-shadow成黑晕)
- **报告**：2026-07-10（用户：app 外查词卡片圆角外面还有一圈黑边没去干净）
- **真实性**：✅ 真 bug。根因 `hibiki/assets/popup/global_lookup_host.js`（v30 树 line 219/227；origin/develop 同串在 line 280/288）注入的 `.global-lookup-frame-shell { box-shadow:0 3px 12px rgba(0,0,0,0.22) }`（+ dark 变体 0.44）。
  - 覆盖窗是**非分层、不透明的 WebView2 窗口**（`hibiki/windows/runner/global_lookup_window.cpp:193` 明确「No WS_EX_LAYERED」，因 WebView2 合成面与分层窗互斥）。在这种窗口上 WebView2 合成面对桌面**没有逐像素 alpha**，CSS `box-shadow` 无法当作透过桌面的半透明投影渲染：它的 12px 模糊落到窗口自身的硬底（透明=硬黑）上，成为**卡片圆角/边缘外一圈约 11px 的黑晕**，而原生圆角窗口区域 `SetWindowRgn`（`global_lookup_window.cpp:664 ApplyRoundedRegion`）裁不掉它 → 即用户截图里「圆角外面没去干净的黑边」。像素实测残留厚度 ≈ 11px，与 shadow 模糊 12px 定量吻合。
  - 代码注释自己已承认「非分层 WebView2 窗口物理上做不出真投影」，所以这条 shadow 从一开始就只有害（黑晕）无益。
- **[x] ① 已修复** — 删除 `.global-lookup-frame-shell` 的 `box-shadow`（light+dark 两条，dark 变体整条移除，只余 shadow 无其它样式）。圆角轮廓单一真值源改由原生 `SetWindowRgn` 提供，卡片边框由 iframe body 的 1px 边框提供，卡片外不再绘制任何东西。`hibiki/assets/popup/global_lookup_host.js`（commit 见下）。
- **[x] ② 已加自动化测试** — 反转守卫为「禁止 box-shadow 声明」：`hibiki/test/lookup/global_lookup_popup_style_guard_test.dart`（`host.contains('box-shadow:')` isFalse + 说明非分层窗黑晕机理）与 node harness `hibiki/test/lookup/global_lookup_host_test.mjs`（test 16：`!/box-shadow/.test(css)`）。两处均 PASS。
- **备注**：
  - 已核实 **origin/develop（schema v37，+623）同串 box-shadow 仍在**（line 280/288）＝上游未修，本修复对用户实际构建线同样需要（用户运行的是 `D:\APP\Hibiki\hibiki.exe`，DB schema=v37 为 origin 级）。本 worktree base 是 v30（`574fe98c7`），比 local develop（`38eb214d4`，v30）旧 67 commit，`global_lookup_host.js` 三处内容一致，修复可干净落到 develop；落 origin 需按 line 280/288 同样删两条声明。
  - **未在真机跑活的覆盖窗验证**：用户生产 DB 为 v37，本 worktree/构建为 v30，v30 应用打开 v37 DB 会触发降级 DROP 表（`support/hibiki.db.corrupt-downgrade*` / `.WIPED-by-oldexe*` 备份即历史事故），且用户 app 当前正在运行占用 DB —— 起动会毁库，故安全约束下不跑活验证。修复为纯 CSS 删除、机理确定、像素定量吻合、守卫锁死；最终肉眼确认建议用户在自己 v37 构建上做，或在隔离的 v37 环境复现。
