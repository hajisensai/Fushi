## BUG-3033 · AI识别长结论在待确认清空或刷新时溢出
- **报告**：2026-10-06（PR #1984，Codex 独立复核 CC 视频域修复时发现）
- **真实性**：✅ 真 bug（静态代码路径确认，运行复现待 CI）。冻结提交 `f4e0ed2a14c` 的 `fushi/lib/src/media/video/metadata/video_source_scrape_dialog.dart:237` 在加载、失败、空列表状态将不限制行数的 AI 结论重新放到固定 Column 内、Expanded 外。`_aiOutcome`（该提交 :621）拼接汇总与多条 AI 理由，`_runPendingWork`（:680）保留结论再 reload，因此最后一项识别成功后清空和刷新等待/失败均可重新产生矮窗口溢出。原测试 loader 恒返回同一项，未覆盖此状态转换。
- **[x] ① 根因修复** — `be2b6340c33`：所有待确认正文状态共用滚动列表，AI 结论始终为列表首项；空态、加载、失败和真实作品位于同一正文内，不再把长结论固定在外。
- **[x] ② 自动化测试已加入** — 同提交 `fushi/test/pages/video_source_scrape_ui_test.dart:971` 两条 `long AI conclusion scrolls...` 回归，在 800×600 窗口用 20 行 AI 理由覆盖 reload 等待、最后一项清空、reload 失败及点击真实重试后清空；检查无布局异常与末尾空态/重试按钮可命中。旧断言未放宽。
- **备注**：已完成 format 与 `git diff --cached --check`。用户要求收尾验证交 CI，不在本机 heavy 队列等待；新增测试、全量 analyze 与真机布局验证未在本轮运行，不将“已加入测试”表述为“已验证通过”。
