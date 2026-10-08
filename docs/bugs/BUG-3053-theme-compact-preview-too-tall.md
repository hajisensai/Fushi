## BUG-3053 · MD3 窄屏自定义主题吸顶预览超过视口三分之一（示意开关挤成三行）
- **报告**：2026-10-06（PR #1984 wave 1 CI：`custom_theme_page_redesign_layout_test`「MD3 · 窄屏 420×900」）
- **真实性**：✅ 真 bug（违反 4f886a5e37a 紧凑吸顶预览「不超过视口高度三分之一」的设计契约）。`fushi/lib/src/pages/implementations/custom_theme_page.dart` `_buildAppPreview` 的示意开关 `FushiPreviewSwitch` 在 MD3 下约 66×46，在约 130 宽的 app 截面里把「按钮 / 标签 / 开关」挤成三行，420×900 下预览高 338（> 300）；Apple 开关 57×37 两行放得下（295）。实测探针数据见提交说明。
- **[x] ① 已实现修复**（6d78d7dba24）— 仅紧凑预览里把示意开关按 28 高等比缩小（`FittedBox`），两套设计系统都排成两行；宽屏完整预览不变。
- **[x] ② 已加自动化测试** — `fushi/test/pages/custom_theme_page_redesign_layout_test.dart`「MD3 / Apple · 窄屏 420×900」的 `before.height < 900 / 3` 断言。
- **备注**：视觉改动小（预览里的示意开关变小），未做真机像素验收。
