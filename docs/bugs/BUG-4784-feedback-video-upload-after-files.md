## BUG-4784 · 反馈视频排在样本文件后上传，共用每 IP 每天额度被 429 挤掉
- **报告**：2026-11-17（PR #3565 遗留项核实：样本文件和录屏视频共用每 IP 每天 200 MiB 的额度，客户端又先传文件后传视频）
- **真实性**：✅ 真 bug。根因：
  - 服务端 `services/leaderboard/src/feedback.js:151` `videoBytesPerIpDay = 200 MiB`，`:772-797` 视频（v0）与样本文件（f0..f2）计同一个 `feedback:video:ip:<ip>` 额度，超了 429。`packages/fushi_engine/lib/feedback/feedback_models.dart` 允许 3 个文件、每个 100 MB，三个满额文件就超过当天额度。
  - 客户端 `fushi/lib/src/feedback/feedback_service.dart:671`（修前 `:671-694`）`_submit` 先循环传样本文件、最后才传视频；`retryPending`（修前 `:933` `..sort()`）按槽位名字典序重试，`f*` 也排在 `v0` 前。429 虽算可重试，但额度按天恢复，补传窗口 `FeedbackLimits.attachWindow` 只有 24 小时，复现过程的主证据（录屏）容易永久丢失。
- **[x] ① 已修复** — `_submit` 改成视频先传、样本文件后传（`feedback_service.dart:671` 起）；`retryPending` 的槽位排序把 `v0` 固定排第一个（`:959`）。服务端是否给样本文件单设额度属于额度设计，未动（不做产品取舍）。
- **[x] ② 已加自动化测试** — `fushi/test/feedback/feedback_files_service_test.dart`「视频与样本文件同交：视频先传…重试也是视频先」：提交时请求顺序断言 `v0, f0, f1`、阶段顺序 `video → files`；全部 429 后重试顺序仍是 `v0, f0, f1`。撤掉实现（恢复先文件后视频 / 字典序重试）两处断言都会红。
- **备注**：纯服务层顺序问题，无设备相关路径；真机未复测。
