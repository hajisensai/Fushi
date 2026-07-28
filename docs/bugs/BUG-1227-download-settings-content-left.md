## BUG-1227 · 下载设置宽屏内容整体贴左且开关被推到远端
- **报告**：2026-07-29（用户截图：4K 宽屏设置详情中，下载设置标题、说明和按钮全部贴在卡片最左侧，Switch 被推到最右侧）
- **真实性**：✅ 真 bug。`TorrentSettingsSection` 的根 `Column` 在 `hibiki/lib/src/pages/implementations/torrent_settings_section.dart:309` 继续横向铺满详情卡片；BUG-1084 只把输入框限制为 480px 并左对齐，没有收拢标题、说明、分段按钮和 Switch。设置详情卡片在宽屏下按既定设计铺满 pane 后，这些控件便分散到卡片两端。
- **[x] ① 已修复** — `TorrentSettingsSection` 在 `hibiki/lib/src/pages/implementations/torrent_settings_section.dart:643` 将整组表单约束到 560px 并水平居中；卡片表面仍铺满详情 pane，窄屏继续占满可用宽度。下载中心齿轮页改为复用同一宽度常量（本提交）。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/torrent_settings_field_width_test.dart` 覆盖 2400px pane 下表单 560px 居中、输入框 480px 限宽、分段控件和 Switch 不越出表单，以及 400px 窄 pane 下继续填满。
- **备注**：按用户要求不等待编译验收；本轮只执行格式化与 `git diff --check`，widget 测试留给后续 CI/集成验收。
