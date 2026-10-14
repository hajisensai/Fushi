## BUG-3363 · 新手引导左上返回箭头与「暂时跳过」重复且被误认为上一步
- **报告**：2026-10-14（用户：反馈 YupByu8gxD，Windows，「左上角的箭头和左下角的暂时跳过重复了，左上角箭头以为是退回上一步」）
- **真实性**：✅ 真 bug（交互）。`fushi/lib/src/pages/implementations/onboarding_wizard_page.dart:858` 页头 leading 是返回箭头，`onTap: maybePop()` 关掉整个向导；底栏已有「暂时跳过」（离开）与「返回」（上一步），箭头与前者重复、与后者语义冲突。
- **[x] ① 已修复** — 去掉页头返回箭头（保留 `automaticallyImplyLeading: false`），向导只剩底栏一组「跳过 / 返回 / 下一步」，MD3 与 Apple 同一页面结构；系统返回手势 / 键照旧可离开。提交 d8830baef6（分支 `cc/fb-misc-ui`）。
- **[x] ② 已加自动化测试** — `fushi/test/onboarding/onboarding_single_exit_guard_test.dart`（源码守卫：页头无 leading / 返回图标，底栏仍有跳过与上一步）。
- **备注**：向导需完整 AppModel，暂无可落地的整页 widget 测试，故用源码守卫。
