## BUG-5599 · srs-donation-set-before-mounted
- **报告**：2026-11-27（审查 PR #4576 时发现，非用户报告）
- **真实性**：✅ 代码路径确认（未实测复现）。`fushi/lib/src/srs/donation/srs_donation_page.dart:210`（上传成功）与 `:250`（撤回成功）在 `await` 上传 / 撤回之后才 `ref.read(srsDonationStatusProvider.notifier).set(...)`，随后的 `updateSrsDonationPrefs(ref, ...)` 也用 `ref`，`mounted` 检查排在它们之后。上传期间关掉页面，widget 已 dispose，`ref.read` 抛 StateError，被当作上传失败记一条错误日志；服务端其实已成功，只是本机状态没刷新（下次 GET 会纠正）。PR #4576 之前的 `updateSrsDonationPrefs` 也是同一顺序。
- **[ ] ① 未修复** — 方向：在 `await` 之前取好 notifier 与偏好写入句柄（或把「上传 / 撤回成功后的状态落地」挪进 `srsDonationStatusProvider` 自己的方法），使它不依赖页面生命周期；按类排查 `srs/donation/` 下其它 await 后用 `ref` 的写法。
- **[ ] ② 未加自动化测试** — 方向：widget 测试里上传进行中 pop 页面，断言状态仍落地且没有错误日志。
- **备注**：
