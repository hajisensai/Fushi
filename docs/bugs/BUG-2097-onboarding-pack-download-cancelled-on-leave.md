## BUG-2097 · 新手引导推荐包下载在离开向导时被静默取消，且没有任何看进度的地方
- **报告**：2026-09-03（用户：走完新手教程时没等推荐包下完就进了下一步，问「会不会在后台下载」，并要求如果是后台下载就得有地方看进度）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/onboarding_wizard_page.dart:176`（修复前）——下载器、进度 notifier 和 `CancelToken` 全是 `_OnboardingWizardPageState` 的字段，`dispose()` 里一句 `_packCancelToken?.cancel()`。于是：
  - **走完/关掉向导 = 下载被静默掐断**：向导一 pop，State 就 dispose，9.5 GB 的下载当场取消。没有提示、没有通知，用户以为它还在后台跑（半截文件保留可续传，所以进度不算全丢，但不点第二次就永远不会继续）。
  - **走到下一步 = 进度整个消失**：进度条只画在推荐包那一步里，离开那一步就什么都看不到，也没有第二个入口能看到它。
  - 文案 `onboarding_pack_action_download_desc`（「后台从多个来源同时下载，下完自动导入」）承诺的「后台」在页面被销毁时并不成立。
- **[x] ① 已修复** — 任务所有权从向导页 State 上移到 app 级 `RecommendedPackDownloadController`（挂 `AppModel`，与词典下载 BUG-1499 同一条纪律），向导退化成它的一个视图：`dispose()` 不再取消，走下一步/关掉向导下载照跑；下完停在「已下载待导入」（导入要用户确认并重启进程，controller 不替用户按）。新增设置 → 系统里的常驻进度行（下载中报进度+可取消，下完可就地导入），后台下完额外出一次 toast。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/onboarding/recommended_pack_download_controller_test.dart`（任务与视图脱钩、取消不算失败、真失败写 error、互斥、进场按磁盘定阶段、进度文案）、`fushi/test/onboarding/recommended_pack_download_row_test.dart`（设置行三态渲染 + 导入回调）、`fushi/test/onboarding/recommended_pack_background_download_guard_test.dart`（源码守卫：向导页不得再持有 CancelToken/下载器、所有权在 AppModel、存在不依赖向导的可见入口且订阅阶段变化）。
- **备注**：真机复测未做（真实路径要下 9.5 GB 整包）；已验证的是 controller 行为、设置行渲染与结构守卫。修复不改下载器本身（分片并发/续传/sha256 校验一行未动）。
