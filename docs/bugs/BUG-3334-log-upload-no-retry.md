## BUG-3334 · 日志上传遇瞬时网络故障直接失败
- **报告**：2026-10-13（用户：「上传日志失败，应该网络没啥大问题啊，就算有问题重试也应该能过去」）
- **真实性**：✅ 真 bug。服务端正常：本机对 `POST /api/logs` 实测 100KB / 500KB 走代理 6/6 全 200；直连 6 次里 4 次卡在 TCP 建连 21s 超时（`logs.wrds.xyz` 被 fake-ip 解析到 `198.18.1.196`，直连 TUN 路径间歇性不握手），与包大小无关——是瞬时网络故障。App 侧 `fushi/lib/src/utils/misc/log_uploader.dart` 的 `performLogUpload` 只发一次请求，`catch (_)` 把异常吞掉不留原因，网络错 / 5xx / 429 全部落成同一句「上传失败」，用户只能自己反复点。
- **[x] ① 已修复** — `performLogUpload` 拆出 `_postLogOnce`，对瞬时失败（连接异常 / 超时、429、5xx）按 `kLogUploadRetryBackoff`（1s、3s）重发，最多 3 次；401 / 403 / 413 是确定性失败不重发；每次失败经 `engineLog` 记下异常或 HTTP 状态码，下次再失败能从错误日志看到真实原因。请求体只编码一次、各次重发共用。
- **[x] ② 已加自动化测试** — `fushi/test/utils/log_uploader_test.dart`：重试用尽仍报 networkError 且恰好 3 次、建连超时 → 502 → 200 重试成功、429 后重试成功、401/403/413 只发 1 次。
- **备注**：网络本身的不稳定（直连 fake-ip 路径）不在 App 能修的范围；重试只覆盖瞬时故障，链路长时间不通仍会失败，此时错误日志里有 `log_upload` 条目说明原因。
