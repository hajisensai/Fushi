## BUG-4716 · 新手引导的功能模块方格没有音乐，向导既不出方格也不写 module_music_enabled
- **报告**：2026-11-16（维护者待办，应用内反馈 Soq3tInVt1）
- **真实性**：✅ 真缺口。根因 `fushi/lib/src/onboarding/onboarding_steps.dart:102-103`（修复前）：模块 → 方格的穷尽表 `onboardingFeatureOfModule` 把 `ModuleId.music` 写死成 `null`（注释「向导暂不出方格」），`OnboardingFeature` 里也没有对应项。向导的方格列表（`_visibleModuleFeatures`）、方格初值（`initState`）和离开功能步时写回 `module_*_enabled` 的循环（`_applyModuleSelection`）全都从这张表推导，于是音乐既不出现、也无法在向导里关掉。
- **[x] ① 已修复** — `OnboardingFeature` 加 `music`，表里 `ModuleId.music => OnboardingFeature.music`；方格图标 / 标题取底栏 `homeNavItemFor(HomeTab.music)` 同一真值，说明新增 `onboarding_feature_music_hint`（i18n_sync）。不进 `kOnboardingLanguageLearningFeatures`：「只看媒体」预设不取消它。
- **[x] ② 已加自动化测试** — `fushi/test/onboarding/onboarding_review_method_wizard_test.dart`「功能步取消音乐：音乐模块关，其余库页保持开」（真向导 + 真偏好仓库，取消勾选后走完向导断言 `module_music_enabled` 为关）；`fushi/test/onboarding/onboarding_steps_test.dart`「music has its own checkbox that maps back to the music module」。两条在修复前均为红（方格不存在 / 映射为 null）。
- **备注**：未在真机 / 模拟器上肉眼复测向导方格布局。
