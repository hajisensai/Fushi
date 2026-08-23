## BUG-1800 · 实机集成测试把首次引导前的短暂首页误判为可用
- **报告**：2026-08-23（`iPhone pay` / iOS 26.6 物理机运行 `integration_test/feature_flows_test.dart`）
- **真实性**：✅ 真 bug（测试基建）。`fushi/integration_test/test_helpers.dart:13-21` 在主导航第一次短暂出现后固定 pump 1 秒却不重新验证，直接返回 `true`；全新安装同时从 `fushi/lib/src/pages/implementations/home_page.dart:386-407` 的首帧异步分支把 `OnboardingWizardPage` 作为 fullscreen route 推上来。实机探针得到 `material visible=0 / all=1`、`Dialog=0`、`ModalBarrier=1`、可见导航目标 0，证明 Home route 已被首次引导置为 offstage，不是导航未渲染。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** — RED 已由物理机 `flutter test integration_test/feature_flows_test.dart -d 00008030-000E24680CC3402E --no-pub` 复现：第 66 行期望导航目标 `>=3`，实际 `0`，exit 1。修复后本用例作为真实 fresh-install 回归，并补快速 widget 守卫。
- **备注**：这不是把首次引导从产品移除；产品绑定仍照常自动弹出。自动化 binding 下应避免启动期模态劫持其它功能用例，首次引导自身由独立 widget/集成入口验证。
