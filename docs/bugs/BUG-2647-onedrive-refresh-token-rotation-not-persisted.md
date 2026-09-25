## BUG-2647 · OneDrive 刷新后轮换的 refresh token 不落库，登录约 90 天后同步静默停止
- **报告**：2026-09-25（用户：修复 OneDrive 同步）
- **真实性**：✅ 真 bug（代码路径验证）。每轮同步开头 `_runSyncChannelInner`（`fushi/lib/src/sync/sync_auto_trigger.dart`）都调 `backend.restoreAuth(repo)`，它读落库的 refresh token 去刷新；Microsoft 身份平台每次刷新都**轮换** refresh token，且每一枚有自己的固定寿命（默认 90 天），但 `PkceOAuthBackendMixin.refreshAuth`（`fushi/lib/src/sync/pkce_oauth_backend_mixin.dart`）只把新值放进内存、从不写回存储。存储里于是永远是登录那一刻的那枚：到期后 `restoreAuth` 刷新失败 → catch 里返回 false → 通道 `return null` 静默跳过；而设置页按 `SyncRepository.getOneDriveToken()` 非空判「已登录」，照旧显示已登录——用户看到的就是「OneDrive 同步不动了、也不报错」。Dropbox 刷新不回新 refresh token，不受影响。
  - 已排除：用 client id `49f7e6d1-…` 打 Microsoft token 端点回 `invalid_grant`（AADSTS9002313）而非 AADSTS700016，应用注册存在；Android intent-filter / iOS URL scheme / `main.dart` 的 `fushi://auth/onedrive` 分发都在。
- **[x] ① 已修复** — mixin 在 `exchangeCode` / `restoreAuth` 记下凭据所在 repo，`refreshAuth` 拿到与当前不同的新 refresh token 时立即 `writeStoredToken`；`signOut` 清掉该引用。放在 `refreshAuth` 而非只在 `restoreAuth`，以后任何「401 后刷新重试」的调用点也自动落库。
- **[x] ② 已加自动化测试** — `fushi/test/sync/pkce_oauth_backend_mixin_test.dart`：`BUG-2647` 三条（轮换落库且模拟重启后出示新 token / 未轮换不写库 / 换码登录后的 refreshAuth 同样落库）。
- **备注**：存量用户若存储里那枚已过期，需要重新登录一次 OneDrive；修复后不会再每 90 天掉一次。同一审查里看到但未在本次处理的：内容文件上传走 Graph 简单 PUT（单文件上限 250 MB，大有声书/视频会 413，Dropbox 同类问题）；刷新失败时同步静默跳过、设置页仍显示已登录。
