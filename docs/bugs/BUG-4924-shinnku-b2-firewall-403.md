## BUG-4924 · 真红小站合集系列下载 galgamedownload.date 403
- **报告**：2026-11-21（用户：应用内反馈 q8PpdOV6a9，`HttpException: download failed (403) galgamedownload.date`）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/discovery/sources/shinnku_discovery_source.dart:211`（`shinnkuDownloadUrl` 的 `合集系列` 分支）：上游 shinnku-com 于 2026-11-18 提交 df4942d1（`frontend/lib/url.ts`）说明 galgamedownload.date 的 Cloudflare 防火墙开始拦截不带 `X-Amz-Signature` 查询参数的请求，上游链接改为追加 `?X-Amz-Signature=1`；本仓仍按旧规则拼直链，所有「合集系列（生肉）」条目下载必 403。实测（2026-11-21）：同一路径不带参数 → 403，带 `?X-Amz-Signature=1` → 404（防火墙放行，B2 判文件不存在），证明参数是放行条件且值不被校验。`zd.shinnku.top` 分支上游未改，本仓也不变。
- **[x] ① 已修复** — `shinnkuDownloadUrl` 的 B2 分支按上游 `url.ts` 同款追加 `?X-Amz-Signature=1`（常量 `_shinnkuB2FirewallQuery`），路径编码仍照上游逐段 `encodeURIComponent`。
- **[x] ② 已加自动化测试** — `fushi/test/media/discovery/sources/shinnku_discovery_source_test.dart`：`合集系列剥首段换 B2 桶前缀` 断言完整 URL 与查询参数；RSC 解析用例断言合集条目 payload URL 带该参数；zd 用例锁定不加参数。
- **备注**：链接规则以上游 `frontend/lib/url.ts` 为准，上游再改防火墙规则时需同步。
