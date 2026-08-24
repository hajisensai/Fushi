## BUG-1821 · 实机集成测试把首次引导前的短暂首页误判为可用
- **报告**：2026-08-23（`iPhone pay` / iOS 26.6 物理机运行 `integration_test/feature_flows_test.dart`）
- **真实性**：✅ 真 bug（测试基建）。`fushi/integration_test/test_helpers.dart:13-21` 在主导航第一次短暂出现后固定 pump 1 秒却不重新验证，直接返回 `true`；全新安装同时从 `fushi/lib/src/pages/implementations/home_page.dart:386-407` 的首帧异步分支把 `OnboardingWizardPage` 作为 fullscreen route 推上来。实机探针得到 `material visible=0 / all=1`、`Dialog=0`、`ModalBarrier=1`、可见导航目标 0，证明 Home route 已被首次引导置为 offstage，不是导航未渲染。
- **[x] ① 已修复** — 生产启动判据只读持久化的 `onboardingCompleted`，不再判断
  `WidgetsBinding` 子类，也没有测试环境 define。普通功能集成测试统一通过
  `support/test_app_launcher.dart` 先在隔离数据库写入真实的
  `first_time_setup=false/onboarding_completed=true` fixture，再调用生产 `main()`；非标准
  Flutter 宿主与正式包首启语义完全相同。提交 `bb1f2ddf7` 后于完成前复审根治上述旁路。
- **[x] ② 已加自动化测试** — `home_onboarding_launch_gate_test.dart` 现在在 test binding
  中仍要求“未完成 => 自动展示”，防止生产逻辑再次感知测试运行时。所有普通功能 E2E
  使用完成态 fixture；独立 `onboarding_clean_install_itest.dart` 唯一直接调用 `app.main()`，
  因而继续覆盖真实 clean-install 自动 push、焦点 Skip、关闭后落库的完整路径。
- **备注**：测试隔离通过业务偏好状态建立，不通过 production runtime type 分支建立；
  因此首启引导本身有真覆盖，其它 E2E 也不会被首启模态劫持。
