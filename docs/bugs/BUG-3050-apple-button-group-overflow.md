## BUG-3050 · Apple 设计下标准按钮组窄屏横向溢出（自定义主题 hero）
- **报告**：2026-10-06（PR #1984 wave 1 CI：`custom_theme_page_redesign_layout_test` Apple 窄屏用例）
- **真实性**：✅ 真 bug。`fushi/lib/src/utils/components/glass/fushi_expressive.dart` 的 `FushiButtonGroup.build` 在 Apple（glass）设计系统下非 expanded 时是裸 `Row(mainAxisSize: min)`，子按钮按固有宽排开、放不下也不收窄；自定义主题编辑页 hero（4f886a5e37a，导入 / 分享 / 更多三颗按钮）在 420 宽窄屏下这一行固有宽约 581，可用 340，`RenderFlex overflowed by 241 pixels on the right`。MD3 分支走 `_FushiSqueezeRow`，放不下时按固有宽等比收窄，不溢出。
- **[x] ① 已实现修复**（b9ff4a5150c）— Apple 非 expanded 分支改走同一个 `_FushiSqueezeRow`（press 全 0、不挤压）：放得下时与原 `Row` 同排布，放不下按固有宽等比收窄；expanded 分支不变。影响面：所有 Apple 设计下的 `FushiButtonGroup`（有声书播放条、歌词播放器、下载任务浏览、放送日历、texthooker、设置 kit、自定义主题 hero）——只在原本会溢出时才有差别。
- **[x] ② 已加自动化测试** — `fushi/test/pages/custom_theme_page_redesign_layout_test.dart` 的「Apple · 窄屏 420×900」与「Apple · 编辑列表在进场窗口内错峰进场」两条（溢出即测试失败）。
- **备注**：未做真机像素验收。
