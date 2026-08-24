## BUG-1821 · 实机集成测试把首次引导前的短暂首页误判为可用
- **报告**：2026-08-23（`iPhone pay` / iOS 26.6 物理机运行 `integration_test/feature_flows_test.dart`）
- **真实性**：✅ 真 bug（测试基建）。`fushi/integration_test/test_helpers.dart:13-21` 在主导航第一次短暂出现后固定 pump 1 秒却不重新验证，直接返回 `true`；全新安装同时从 `fushi/lib/src/pages/implementations/home_page.dart:386-407` 的首帧异步分支把 `OnboardingWizardPage` 作为 fullscreen route 推上来。实机探针得到 `material visible=0 / all=1`、`Dialog=0`、`ModalBarrier=1`、可见导航目标 0，证明 Home route 已被首次引导置为 offstage，不是导航未渲染。
- **[x] ① 已修复** — 生产启动判据只读持久化的 `onboardingCompleted`，不再判断
  `WidgetsBinding` 子类，也没有测试环境 define。普通功能集成测试统一通过
  `support/test_app_launcher.dart` 先在隔离数据库写入真实的
  `first_time_setup=false/onboarding_completed=true` fixture，再调用生产 `main()`；非标准
  Flutter 宿主与正式包首启语义完全相同。提交 `bb1f2ddf7` 后于完成前复审根治上述旁路。
- **[ ] ② 尚无有效自动化测试** — 原 `home_onboarding_launch_gate_test.dart` 是空洞的：全文只断言
  `startupOnboardingAutoLaunchAllowed(onboardingCompleted: false) == true` /
  `(true) == false`，而该函数体就是 `!onboardingCompleted`，即断言的是定义式本身，不可能失败；它也
  不验证调用点用了它（有人加回 `|| kDebugMode` 照样绿）。合入前已连同那个恒等包装一起删除，
  `home_page.dart` 还原成 `if (mounted && !appModel.onboardingCompleted)`。真正的隔离由
  `integration_test/support/test_app_launcher.dart:21-22` 写真实偏好完成，那是对的；
  `onboarding_clean_install_itest.dart` 唯一直接调用 `app.main()`，覆盖真实 clean-install 路径，
  **但它不在任何 runner 里**（真单测门 `flutter_test_failures.dart` 只跑 `test/`），只能真机/模拟器手跑。
- **⚠️ 根因缺口未闭合**：本条「真实性」里认定的根因是
  `fushi/integration_test/test_helpers.dart:13-21` 的 `waitForHome`——主导航第一次短暂出现后固定
  pump 1 秒却不重新验证就返回 `true`。**该文件在本轮一行未改**，① 修的是「首启引导会不会被推
  上来」这条并发原因，不是 `waitForHome` 自身的判据缺陷。只要有别的模态在主导航出现后 1 秒内
  盖上来，`waitForHome` 仍会误报可用。这条待后续单独修。
- **备注**：测试隔离通过业务偏好状态建立，不通过 production runtime type 分支建立；
  因此首启引导本身有真覆盖，其它 E2E 也不会被首启模态劫持。
