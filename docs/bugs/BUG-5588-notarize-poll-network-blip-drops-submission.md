## BUG-5588 · notarize-poll-network-blip-drops-submission
- **报告**：2026-11-27（发 beta 3.4.0-beta.32958 时 macOS job 连续两次在「Sign and notarize macOS dmg」失败）
- **真实性**：✅ 真 bug。`tool/notarize_submit.sh` 用一条 `xcrun notarytool submit --wait` 同时做上传和轮询结论；两次都是上传成功、拿到 submission id 后约 3 分钟，轮询 `appstoreconnect.apple.com/notary/v2/submissions/<id>` 时 runner 报 `NSURLErrorDomain -1009`（Resolved 0 endpoints），`--wait` 随即退出 1，脚本判失败，已在 Apple 审核中的 submission 被丢掉。公证结论在服务端，本地一次查询失败不该让整个发版失败。
- **[x] ① 已修复** — 上传与等结论拆开：`notarytool submit`（不带 `--wait`）拿 id，上传失败仍立即失败；随后按 id 轮询 `notarytool info`，查询失败只 `::warning` 并在下一轮再查同一个 id，直到 Accepted / Invalid / Rejected 或总时限（`NOTARIZE_TIMEOUT_SECONDS`，默认 45 分钟，与原 `--timeout 45m` 一致）。非 Accepted 照旧打 `notarytool log` 后失败。
- **[x] ② 已加自动化测试** — `fushi/test/tools/notarize_submit_script_test.dart` 用假 `xcrun` / `plutil` 跑真脚本四条：查询断网两次后 Accepted 判成功且只上传一次、Invalid 打 log 判失败、上传失败不轮询、一直 In Progress 到时限判失败。旧脚本跑这组测试三条变红（变异实测）。
- **备注**：
